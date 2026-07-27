// 弹幕核:弹弹Play 官方源(签名)+ 自建源(none/pathToken/headerToken/queryToken)统一由 config 驱动。
// 对齐 Dart lib/core/api/danmaku/(dandan_signing + danmaku_source)、lib/core/utils/
// (danmaku_matcher + danmaku_filter + danmaku_postprocess)、danmaku_cache。
// 签名:X-Signature = Base64(SHA256(AppId + Timestamp + Path + AppSecret))。
pub mod local;
use base64::Engine;
use md5::Md5;
use regex::Regex;
use serde::{Deserialize, Serialize};
use serde_json::Value;
use sha2::{Digest, Sha256};
use std::collections::HashMap;
use std::path::PathBuf;
use std::sync::{Mutex, OnceLock};
use std::time::{SystemTime, UNIX_EPOCH};

#[derive(Serialize, Deserialize, Clone, Copy, PartialEq, Eq, Debug)]
#[serde(rename_all = "camelCase")]
pub enum DanmakuAuthType {
    None,
    DandanplaySignature,
    PathToken,
    HeaderToken,
    QueryToken,
}

#[derive(Clone, Default)]
pub struct DanmakuSourceConfig {
    pub id: String,
    pub name: String,
    pub api_url: String,
    /// 弹弹Play 官方源(固定 base + 强制签名)。
    pub official: bool,
    pub auth_type: Option<DanmakuAuthType>,
    pub token: Option<String>,
    pub app_id: Option<String>,
    pub app_secret: Option<String>,
}

/// 一条弹幕(归一化)。Deserialize 供磁盘缓存回读。
#[derive(Serialize, Deserialize, Clone, Debug, Default, PartialEq)]
pub struct DanmakuComment {
    pub time: f64,
    pub text: String,
    pub mode: i32,  // 1=滚动 4=底 5=顶
    pub color: i32, // RGB int
    pub source: String,
    pub cid: Option<String>,
    pub user_id: Option<String>,
    /// 去重后同一弹幕出现的次数(对齐 Dart DanmakuItem.count),未去重恒为 1。
    #[serde(default = "one")]
    pub count: i32,
}
fn one() -> i32 {
    1
}

#[derive(Serialize, Clone, Debug)]
pub struct DanmakuEpisode {
    pub episode_id: String,
    pub episode_title: String,
    pub episode_number: Option<String>,
}

#[derive(Serialize, Clone, Debug)]
pub struct DanmakuAnime {
    pub anime_id: String,
    pub anime_title: String,
    pub type_: Option<String>,
    pub type_description: Option<String>,
    pub image_url: Option<String>,
    pub year: Option<i64>,
    pub episode_count: Option<i64>,
    pub episodes: Vec<DanmakuEpisode>,
}

/// 文件识别命中项。对齐 Dart DanmakuMatchItem。
#[derive(Serialize, Clone, Debug, Default)]
pub struct DanmakuMatchItem {
    pub episode_id: String,
    pub anime_id: String,
    pub anime_title: String,
    pub episode_title: String,
    pub type_: Option<String>,
    pub type_description: Option<String>,
    pub shift: Option<i64>,
    pub source_id: String,
    pub source_name: String,
}

/// 对齐 Dart DanmakuMatchResult。
#[derive(Serialize, Clone, Debug, Default)]
pub struct DanmakuMatchResult {
    pub is_matched: bool,
    pub matches: Vec<DanmakuMatchItem>,
}

const OFFICIAL_BASE: &str = "https://api.dandanplay.net";

fn now_secs() -> i64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|d| d.as_secs() as i64)
        .unwrap_or(0)
}

/// 从用户粘贴的一条链接里**推导**鉴权方式,不让用户选。
///
/// 依据是两个主流自建端的真实接入方式(2026-07-19 查证,非猜测):
///   - huangxd-/danmu_api:      `http://host:9321/{TOKEN}/api/v2`(README 原文,默认 token 87654321)
///   - l429609201/misaka_danmu_server: `prefix="/{token}/api/v2"`(src/api/dandan/__init__.py 路由定义)
///
/// 两家都把 token 放在**路径**里 —— 也就是说它本来就在用户复制的那条链接内,
/// 我们原样用就行,既不用他选「鉴权方式」,也不用他单独再填一遍 token。
/// (用户 2026-07-19:「用户也不知道啥是鉴权方式」。)
///
/// 唯一需要动手的是把 token 挂在 **query** 上的写法:`?token=xxx`。
/// 那种 URL 不能原样拼接 —— `base_url()` 会在后面接 `/api/v2`,
/// 拼出 `...?token=x/api/v2` 这种废地址。所以要把它拆出来走 QueryToken。
///
/// 返回 (干净的基础地址, 鉴权方式, token)。
pub fn derive_auth(api_url: &str) -> (String, DanmakuAuthType, Option<String>) {
    let raw = api_url.trim();
    let (path_part, query) = match raw.split_once('?') {
        Some((p, q)) => (p, q),
        None => (raw, ""),
    };
    // query 里带 token/api_key → 拆出来单独送,URL 只留路径部分。
    for kv in query.split('&') {
        if let Some((k, v)) = kv.split_once('=') {
            let k = k.trim().to_ascii_lowercase();
            if (k == "token" || k == "api_key" || k == "apikey") && !v.trim().is_empty() {
                return (
                    path_part.trim_end_matches('/').to_string(),
                    DanmakuAuthType::QueryToken,
                    Some(v.trim().to_string()),
                );
            }
        }
    }
    // 其余一律原样用:路径 token(两大自建端)本就含在地址里,无需额外处理。
    (path_part.trim_end_matches('/').to_string(), DanmakuAuthType::None, None)
}

pub fn signature(app_id: &str, path: &str, ts: i64, secret: &str) -> String {
    let mut h = Sha256::new();
    h.update(format!("{app_id}{ts}{path}{secret}").as_bytes());
    base64::engine::general_purpose::STANDARD.encode(h.finalize())
}

impl DanmakuSourceConfig {
    fn auth(&self) -> DanmakuAuthType {
        self.auth_type.unwrap_or(DanmakuAuthType::None)
    }

    /// 归一化到以 /api/v2 结尾的基础地址。
    fn base_url(&self) -> String {
        let url = self.api_url.trim().trim_end_matches('/').to_string();
        if url.ends_with("/api/v2") {
            url
        } else if url.ends_with("/api/v1") {
            format!("{}/api/v2", &url[..url.len() - 7])
        } else {
            format!("{url}/api/v2")
        }
    }

    /// pathToken 插入后的真正请求基址。
    fn request_base_url(&self) -> String {
        let base = self.base_url();
        if self.auth() != DanmakuAuthType::PathToken {
            return base;
        }
        let t = self.token.as_deref().unwrap_or("").trim();
        if t.is_empty() || base.contains(&format!("/{t}/")) {
            return base;
        }
        if let Some(host) = base.strip_suffix("/api/v2") {
            format!("{host}/{t}/api/v2")
        } else {
            format!("{base}/{t}")
        }
    }

    /// endpoint 形如 "/search/anime"。
    fn endpoint_url(&self, endpoint: &str) -> String {
        if self.official {
            format!("{OFFICIAL_BASE}/api/v2{endpoint}")
        } else {
            format!("{}{}", self.request_base_url(), endpoint)
        }
    }

    /// 返回 (headers, query 追加项)。官方或 dandanplaySignature 走签名;其余按 authType。
    fn auth_parts(&self, endpoint: &str) -> (Vec<(String, String)>, Vec<(String, String)>) {
        let mut headers = Vec::new();
        let mut query = Vec::new();
        let sign_path = format!("/api/v2{endpoint}");

        let mut sign_with = |app_id: &str, secret: &str| {
            let ts = now_secs();
            headers.push(("X-AppId".into(), app_id.to_string()));
            headers.push(("X-Timestamp".into(), ts.to_string()));
            headers.push(("X-Signature".into(), signature(app_id, &sign_path, ts, secret)));
        };

        if self.official || self.auth() == DanmakuAuthType::DandanplaySignature {
            let app_id = self.app_id.as_deref().unwrap_or("").trim().to_string();
            // 多 secret 换行分隔;取首个非空(轮换是配额分摊,不影响正确性)。
            let secret = self
                .app_secret
                .as_deref()
                .unwrap_or("")
                .split('\n')
                .map(|s| s.trim())
                .find(|s| !s.is_empty())
                .unwrap_or("")
                .to_string();
            if !app_id.is_empty() && !secret.is_empty() {
                sign_with(&app_id, &secret);
            }
            return (headers, query);
        }

        match self.auth() {
            DanmakuAuthType::HeaderToken => {
                if let Some(t) = self.token.as_deref().map(str::trim).filter(|t| !t.is_empty()) {
                    headers.push(("Authorization".into(), format!("Bearer {t}")));
                    headers.push(("X-Token".into(), t.to_string()));
                    headers.push(("X-Api-Key".into(), t.to_string()));
                }
            }
            DanmakuAuthType::QueryToken => {
                if let Some(t) = self.token.as_deref().map(str::trim).filter(|t| !t.is_empty()) {
                    query.push(("token".into(), t.to_string()));
                }
            }
            _ => {}
        }
        (headers, query)
    }
}

// ---------- 解析 ----------

fn parse_comment(d: &Value, source: &str) -> DanmakuComment {
    // 弹弹Play p 字段: time,mode,color,userId
    let p: Vec<&str> = d["p"].as_str().unwrap_or("").split(',').collect();
    DanmakuComment {
        time: p.first().and_then(|s| s.parse().ok()).unwrap_or(0.0),
        text: d["m"].as_str().unwrap_or("").to_string(),
        mode: p.get(1).and_then(|s| s.parse().ok()).unwrap_or(1),
        color: p.get(2).and_then(|s| s.parse().ok()).unwrap_or(16777215),
        source: source.to_string(),
        cid: d["cid"]
            .as_str()
            .map(|s| s.to_string())
            .or_else(|| d["cid"].as_i64().map(|n| n.to_string())),
        user_id: p.get(3).map(|s| s.to_string()),
        count: 1,
    }
}

fn parse_comments(raw: &Value, source: &str) -> Vec<DanmakuComment> {
    raw.as_array()
        .map(|a| a.iter().map(|d| parse_comment(d, source)).collect())
        .unwrap_or_default()
}

fn parse_anime(a: &Value) -> DanmakuAnime {
    let episodes = a["episodes"]
        .as_array()
        .map(|arr| {
            arr.iter()
                .map(|ep| DanmakuEpisode {
                    episode_id: ep["episodeId"].as_str().map(String::from).unwrap_or_else(|| {
                        ep["episodeId"].as_i64().map(|n| n.to_string()).unwrap_or_default()
                    }),
                    episode_title: ep["episodeTitle"].as_str().unwrap_or("").to_string(),
                    episode_number: ep["episodeNumber"].as_str().map(String::from),
                })
                .collect()
        })
        .unwrap_or_default();
    DanmakuAnime {
        anime_id: a["animeId"]
            .as_str()
            .map(String::from)
            .or_else(|| a["animeId"].as_i64().map(|n| n.to_string()))
            .unwrap_or_default(),
        anime_title: a["animeTitle"].as_str().unwrap_or("").to_string(),
        type_: a["type"].as_str().map(String::from),
        type_description: a["typeDescription"].as_str().map(String::from),
        image_url: a["imageUrl"].as_str().map(String::from),
        year: a["year"].as_i64(),
        episode_count: a["episodeCount"].as_i64(),
        episodes,
    }
}

// ---------- 请求 ----------

async fn get_json(
    http: &reqwest::Client,
    url: &str,
    headers: &[(String, String)],
    query: &[(String, String)],
) -> Result<Value, String> {
    let mut req = http.get(url);
    for (k, v) in headers {
        req = req.header(k.as_str(), v);
    }
    if !query.is_empty() {
        req = req.query(query);
    }
    let resp = req
        .send()
        .await
        .map_err(|e| format!("弹幕请求失败: {e}"))?;
    resp.json().await.map_err(|e| format!("弹幕解析失败: {e}"))
}

/// 搜番:GET /search/anime?keyword=&v2=true → 只回条目,**不带集列表**。
///
/// 比 `/search/episodes` 快得多(后者要把每部番的整份集表也捞出来),配合
/// [`bangumi_episodes`] 做「先挑番 → 再挑集」两段式。`v2=true` 是官方新搜索引擎
/// (swagger v2 标注「使用新搜索引擎」);自建源不认这个参数会直接忽略,无害。
///
/// 返回字段名新旧引擎都叫 animes/bangumiList,两个都收。
pub async fn search_anime(
    http: &reqwest::Client,
    cfg: &DanmakuSourceConfig,
    keyword: &str,
) -> Result<Vec<DanmakuAnime>, String> {
    let (headers, mut query) = cfg.auth_parts("/search/anime");
    query.push(("keyword".into(), keyword.to_string()));
    query.push(("v2".into(), "true".into()));
    let v = get_json(http, &cfg.endpoint_url("/search/anime"), &headers, &query).await?;
    Ok(parse_anime_list(&v))
}

/// 老引擎回 `animes`,新引擎(v2=true)回 `bangumiList` —— 两个都收,谁在用谁。
fn parse_anime_list(v: &Value) -> Vec<DanmakuAnime> {
    let list = if v["animes"].is_array() { &v["animes"] } else { &v["bangumiList"] };
    list.as_array()
        .map(|a| a.iter().map(parse_anime).collect())
        .unwrap_or_default()
}

/// 取某部番的集列表:GET /bangumi/{animeId} → bangumi.episodes[]。
///
/// 只在用户点了某个条目后才发,所以搜索那一步不用背整份集表。
/// 自建源不一定实现这个端点 —— 空/失败时由调用方退回 `/search/episodes` 按标题捞。
pub async fn bangumi_episodes(
    http: &reqwest::Client,
    cfg: &DanmakuSourceConfig,
    anime_id: &str,
) -> Result<Vec<DanmakuEpisode>, String> {
    let endpoint = format!("/bangumi/{anime_id}");
    let (headers, query) = cfg.auth_parts(&endpoint);
    let v = get_json(http, &cfg.endpoint_url(&endpoint), &headers, &query).await?;
    Ok(parse_bangumi_episodes(&v))
}

/// 集表包在 `bangumi` 下面一层。
fn parse_bangumi_episodes(v: &Value) -> Vec<DanmakuEpisode> {
    parse_anime(&v["bangumi"]).episodes
}

/// 搜集:GET /search/episodes?anime=&episode= → animes[](带 episodes)。
pub async fn search_episodes(
    http: &reqwest::Client,
    cfg: &DanmakuSourceConfig,
    anime: Option<&str>,
    episode: Option<&str>,
) -> Result<Vec<DanmakuAnime>, String> {
    let (headers, mut query) = cfg.auth_parts("/search/episodes");
    if let Some(a) = anime {
        query.push(("anime".into(), a.to_string()));
    }
    if let Some(e) = episode {
        query.push(("episode".into(), e.to_string()));
    }
    let v = get_json(http, &cfg.endpoint_url("/search/episodes"), &headers, &query).await?;
    Ok(v["animes"]
        .as_array()
        .map(|a| a.iter().map(parse_anime).collect())
        .unwrap_or_default())
}

/// 取评论:GET /comment/{episodeId}?withRelated&chConvert → comments[]。
/// ponytail: 自建源的 taskId 异步轮询(misaka 风格)未接 —— 直返 comments;需异步时在桌面层加轮询。
pub async fn get_comments(
    http: &reqwest::Client,
    cfg: &DanmakuSourceConfig,
    episode_id: &str,
    ch_convert: i32,
) -> Result<Vec<DanmakuComment>, String> {
    let endpoint = format!("/comment/{episode_id}");
    let (headers, mut query) = cfg.auth_parts(&endpoint);
    query.push(("withRelated".into(), "true".into()));
    if ch_convert != 0 {
        query.push(("chConvert".into(), ch_convert.to_string()));
    }
    let v = get_json(http, &cfg.endpoint_url(&endpoint), &headers, &query).await?;
    Ok(parse_comments(&v["comments"], &cfg.name))
}

/// 文件识别:POST /match。对齐 Dart DanmakuSource.match。
pub async fn match_file(
    http: &reqwest::Client,
    cfg: &DanmakuSourceConfig,
    file_name: &str,
    file_hash: Option<&str>,
    file_size: Option<i64>,
    video_duration: Option<f64>,
) -> Result<DanmakuMatchResult, String> {
    let (headers, query) = cfg.auth_parts("/match");
    let body = serde_json::json!({
        "fileName": file_name,
        "fileHash": file_hash.unwrap_or(""),
        "fileSize": file_size.unwrap_or(0),
        "videoDuration": video_duration.unwrap_or(0.0),
    });
    let mut req = http.post(cfg.endpoint_url("/match")).json(&body);
    for (k, v) in &headers {
        req = req.header(k.as_str(), v);
    }
    if !query.is_empty() {
        req = req.query(&query);
    }
    let v: Value = req
        .send()
        .await
        .map_err(|e| format!("弹幕匹配失败: {e}"))?
        .json()
        .await
        .map_err(|e| format!("弹幕匹配解析失败: {e}"))?;
    Ok(parse_match_result(&v, cfg))
}

fn parse_match_result(data: &Value, cfg: &DanmakuSourceConfig) -> DanmakuMatchResult {
    let str_of = |v: &Value| -> String {
        v.as_str()
            .map(String::from)
            .or_else(|| v.as_i64().map(|n| n.to_string()))
            .unwrap_or_default()
    };
    let matches = data["matches"]
        .as_array()
        .map(|arr| {
            arr.iter()
                .map(|m| DanmakuMatchItem {
                    episode_id: str_of(&m["episodeId"]),
                    anime_id: str_of(&m["animeId"]),
                    anime_title: m["animeTitle"].as_str().unwrap_or("").to_string(),
                    episode_title: m["episodeTitle"].as_str().unwrap_or("").to_string(),
                    type_: m["type"].as_str().map(String::from),
                    type_description: m["typeDescription"].as_str().map(String::from),
                    shift: m["shift"].as_i64(),
                    source_id: cfg.id.clone(),
                    source_name: cfg.name.clone(),
                })
                .collect()
        })
        .unwrap_or_default();
    DanmakuMatchResult {
        is_matched: data["isMatched"].as_bool().unwrap_or(false),
        matches,
    }
}

// ---------- 多源并行(用户自己挑) ----------

/// 单个弹幕源的查询结果。对齐 Dart DanmakuSourceGroup —— 一源一组,单源失败不拖累别人。
#[derive(Serialize, Clone, Debug, Default)]
pub struct DanmakuSourceGroup {
    pub source_id: String,
    pub source_name: String,
    pub animes: Vec<DanmakuAnime>,
    pub matches: Vec<DanmakuMatchItem>,
    /// 该源失败时的错误串(其余源照常返回)。
    pub error: Option<String>,
}

impl DanmakuSourceGroup {
    pub fn is_empty(&self) -> bool {
        self.animes.is_empty() && self.matches.is_empty()
    }
}

/// 并行向所有传入源搜**条目**,分源返回(顺序与 `cfgs` 一致,便于 UI 稳定列表)。
///
/// ★ 走 `/search/anime`(新引擎)而非 `/search/episodes`:回来的 animes[] 里
/// `episodes` 是空的,集表要等用户点了条目再单独取([`episodes_for_anime`])。
/// 这既是「快」的来源,也是 UI 要的三段式(条目 → 集 → 弹幕)。
/// ponytail: 不做 Dart 的 searchAllStreamed(边搜边显示)—— Tauri 侧 IPC 一次性返回即可,
/// 真要流式再上 Channel。
pub async fn search_all_grouped(
    http: &reqwest::Client,
    cfgs: &[DanmakuSourceConfig],
    keyword: &str,
) -> Vec<DanmakuSourceGroup> {
    let keyword = keyword.to_string();
    parallel_by_source(http, cfgs, |http, cfg| {
        let keyword = keyword.clone();
        async move {
            match search_anime(&http, &cfg, &keyword).await {
                Ok(animes) => DanmakuSourceGroup {
                    source_id: cfg.id,
                    source_name: cfg.name,
                    animes,
                    ..Default::default()
                },
                Err(e) => DanmakuSourceGroup {
                    source_id: cfg.id,
                    source_name: cfg.name,
                    error: Some(e),
                    ..Default::default()
                },
            }
        }
    })
    .await
    .into_iter()
    .collect()
}

/// 取某源某条目的集列表。先试 `/bangumi/{id}`(官方最快);拿不到再退
/// `/search/episodes?anime={title}` 按标题捞并挑出同 id 的那部。
///
/// 退路不是可选的:自建源(huangxd / misaka)不保证实现 `/bangumi/{id}`,
/// 没退路的话它们的条目点进去永远是空集表。
pub async fn episodes_for_anime(
    http: &reqwest::Client,
    cfg: &DanmakuSourceConfig,
    anime_id: &str,
    anime_title: &str,
) -> Result<Vec<DanmakuEpisode>, String> {
    if let Ok(eps) = bangumi_episodes(http, cfg, anime_id).await {
        if !eps.is_empty() {
            return Ok(eps);
        }
    }
    if anime_title.trim().is_empty() {
        return Ok(Vec::new());
    }
    let animes = search_episodes(http, cfg, Some(anime_title), None).await?;
    Ok(animes
        .iter()
        .find(|a| a.anime_id == anime_id)
        .or_else(|| animes.first())
        .map(|a| a.episodes.clone())
        .unwrap_or_default())
}

/// 并行向所有传入源做文件识别,分源返回候选。对齐 Dart DanmakuService.matchAllGrouped。
pub async fn match_all_grouped(
    http: &reqwest::Client,
    cfgs: &[DanmakuSourceConfig],
    input: &MatchInput,
) -> Vec<DanmakuSourceGroup> {
    let input = input.clone();
    parallel_by_source(http, cfgs, |http, cfg| {
        let input = input.clone();
        async move {
            match match_file(
                &http,
                &cfg,
                &input.file_name,
                input.file_hash.as_deref(),
                input.file_size,
                input.duration_secs,
            )
            .await
            {
                Ok(r) => DanmakuSourceGroup {
                    source_id: cfg.id,
                    source_name: cfg.name,
                    matches: r.matches,
                    ..Default::default()
                },
                Err(e) => DanmakuSourceGroup {
                    source_id: cfg.id,
                    source_name: cfg.name,
                    error: Some(e),
                    ..Default::default()
                },
            }
        }
    })
    .await
}

/// 逐源并行跑 `f`,结果按 `cfgs` 原顺序归位(JoinSet 完成顺序是乱的)。
/// 与 download.rs / net::cf::speedtest 同款 JoinSet 姿势。
async fn parallel_by_source<F, Fut, T>(
    http: &reqwest::Client,
    cfgs: &[DanmakuSourceConfig],
    f: F,
) -> Vec<T>
where
    F: Fn(reqwest::Client, DanmakuSourceConfig) -> Fut,
    Fut: std::future::Future<Output = T> + Send + 'static,
    T: Send + 'static,
{
    let mut set = tokio::task::JoinSet::new();
    for (i, cfg) in cfgs.iter().enumerate() {
        // reqwest::Client 内部是 Arc,clone 极廉价且共享同一连接池。
        let fut = f(http.clone(), cfg.clone());
        set.spawn(async move { (i, fut.await) });
    }
    let mut slots: Vec<Option<T>> = (0..cfgs.len()).map(|_| None).collect();
    while let Some(r) = set.join_next().await {
        if let Ok((i, v)) = r {
            slots[i] = Some(v);
        }
    }
    slots.into_iter().flatten().collect()
}

// ---------- 智能集数匹配(逐字对齐 Dart DanmakuMatcher) ----------

/// 一条匹配候选(某源的某作品的某一集)。对齐 Dart DanmakuMatchCandidate。
#[derive(Serialize, Clone, Debug)]
pub struct DanmakuMatchCandidate {
    pub source_id: String,
    pub source_name: String,
    pub anime_id: String,
    pub anime_title: String,
    pub episode_id: String,
    pub episode_title: String,
    /// 排序分(越大越可信)。
    pub score: f64,
}

/// 匹配输入。core 不认 Emby Item(emby::Item 没有 path 字段,且网盘/聚合源没有 Emby
/// 上下文),由宿主用 [`resolve_title`] / [`resolve_file_name`] 装好再传进来。
#[derive(Clone, Debug, Default, Serialize, Deserialize)]
#[serde(default)]
pub struct MatchInput {
    /// 作品标题(剧集用 seriesName,否则条目名)。
    pub title: String,
    /// 集号(剧集才有)。
    pub episode_no: Option<i64>,
    /// 真实文件名(文件识别用)。
    pub file_name: String,
    pub file_hash: Option<String>,
    pub file_size: Option<i64>,
    /// 视频时长(秒)。
    pub duration_secs: Option<f64>,
}

/// 自动加载可信度阈值:低于此分不该自动上屏。对齐 Dart DanmakuAutoLoader._minScore。
pub const MIN_AUTO_SCORE: f64 = 0.5;

/// 剧集用 seriesName,否则用条目名。对齐 Dart DanmakuMatcher.resolveTitle。
pub fn resolve_title(series_name: Option<&str>, name: &str) -> String {
    match series_name.map(str::trim) {
        Some(s) if !s.is_empty() => s.to_string(),
        _ => name.trim().to_string(),
    }
}

/// 真实文件名:优先 path 的 basename(Emby 存的是发布文件名,文件识别最准),无则退条目名。
/// 对齐 Dart DanmakuMatcher._resolveFileName。
pub fn resolve_file_name(path: Option<&str>, name: &str) -> String {
    if let Some(p) = path.filter(|p| !p.is_empty()) {
        let norm = p.replace('\\', "/");
        let base = norm.rsplit('/').next().unwrap_or(&norm);
        if !base.is_empty() {
            return base.to_string();
        }
    }
    name.to_string()
}

/// 时长 ticks → 秒。对齐 Dart DanmakuMatcher.resolveDurationSeconds。
pub fn duration_secs_from_ticks(ticks: Option<i64>) -> Option<f64> {
    ticks.filter(|t| *t > 0).map(|t| t as f64 / 10_000_000.0)
}

/// 是否动漫(决定是否放行官方弹弹Play:动漫专库,给电视剧/电影匹配会出乱七八糟的弹幕)。
/// 逐字对齐 Dart MediaItem.isAnime —— genres 与 tags 一起丢进来即可。
/// 注:Dart 的「剧集缺 genres → 拉 series 再判」回退需要 Emby 客户端,留给宿主。
pub fn is_anime(genres_and_tags: &[String]) -> bool {
    const KW: [&str; 11] = [
        "动画", "动漫", "動畫", "動漫", "番剧", "番劇", "二次元", "卡通", "anime", "アニメ",
        "animation",
    ];
    genres_and_tags.iter().any(|g| {
        let l = g.to_lowercase();
        KW.iter().any(|k| l.contains(k))
    })
}

/// 并行向所有传入源做智能匹配,返回按可信度降序的候选。对齐 Dart DanmakuMatcher.matchAll。
/// 官方弹弹Play 是否参与由宿主决定(用 [`is_anime`] 判后从 `cfgs` 里剔除),对齐 Dart 的
/// sourcesFor(allowOfficial:)。
pub async fn match_all(
    http: &reqwest::Client,
    cfgs: &[DanmakuSourceConfig],
    input: &MatchInput,
) -> Vec<DanmakuMatchCandidate> {
    if input.title.trim().is_empty() {
        return Vec::new();
    }
    let input2 = input.clone();
    let per_source = parallel_by_source(http, cfgs, |http, cfg| {
        let input = input2.clone();
        async move { match_one(&http, &cfg, &input).await }
    })
    .await;
    let mut all: Vec<DanmakuMatchCandidate> = per_source.into_iter().flatten().collect();
    // 降序;NaN 不可能出现(分值全是有限算术)。
    all.sort_by(|a, b| b.score.partial_cmp(&a.score).unwrap_or(std::cmp::Ordering::Equal));
    all
}

/// 弹弹Play 官方推荐两条路径都跑:①文件识别 /match ②名字搜索 /search/episodes。
/// 两路**并行**再合并去重(同源同集保留高分)。对齐 Dart DanmakuMatcher._matchOne。
async fn match_one(
    http: &reqwest::Client,
    cfg: &DanmakuSourceConfig,
    input: &MatchInput,
) -> Vec<DanmakuMatchCandidate> {
    let (by_search, by_file) = tokio::join!(
        search_candidates(http, cfg, input),
        match_by_file_candidates(http, cfg, input),
    );
    let mut by_ep: HashMap<String, DanmakuMatchCandidate> = HashMap::new();
    for c in by_search.into_iter().chain(by_file) {
        let key = format!("{}|{}", c.source_id, c.episode_id);
        match by_ep.get(&key) {
            Some(prev) if prev.score >= c.score => {}
            _ => {
                by_ep.insert(key, c);
            }
        }
    }
    by_ep.into_values().collect()
}

/// ②名字搜索:searchEpisodes(anime, episode) 服务端按集号收窄,无果退纯剧名。
/// 对齐 Dart DanmakuMatcher._searchCandidates。失败静默(返回空)。
async fn search_candidates(
    http: &reqwest::Client,
    cfg: &DanmakuSourceConfig,
    input: &MatchInput,
) -> Vec<DanmakuMatchCandidate> {
    let ep_str = input.episode_no.map(|n| n.to_string());
    let mut animes =
        match search_episodes(http, cfg, Some(&input.title), ep_str.as_deref()).await {
            Ok(a) => a,
            Err(_) => return Vec::new(),
        };
    if animes.is_empty() && input.episode_no.is_some() {
        animes = search_episodes(http, cfg, Some(&input.title), None)
            .await
            .unwrap_or_default();
    }
    animes
        .into_iter()
        .filter_map(|anime| {
            if anime.episodes.is_empty() {
                return None;
            }
            let title_score = title_score(&input.title, &anime.anime_title);
            let ep = pick_episode(&anime.episodes, input.episode_no)?;
            Some(DanmakuMatchCandidate {
                source_id: cfg.id.clone(),
                source_name: cfg.name.clone(),
                anime_id: anime.anime_id.clone(),
                anime_title: anime.anime_title.clone(),
                episode_id: ep.episode_id.clone(),
                episode_title: ep.episode_title.clone(),
                score: title_score + if episode_matches(ep, input.episode_no) { 0.3 } else { 0.0 },
            })
        })
        .collect()
}

/// ①文件识别:真实文件名 + 时长调 /match。isMatched 且唯一命中最可信。
/// 对齐 Dart DanmakuMatcher._matchByFileCandidates。失败静默(返回空)。
async fn match_by_file_candidates(
    http: &reqwest::Client,
    cfg: &DanmakuSourceConfig,
    input: &MatchInput,
) -> Vec<DanmakuMatchCandidate> {
    let r = match match_file(
        http,
        cfg,
        &input.file_name,
        input.file_hash.as_deref(),
        input.file_size,
        input.duration_secs,
    )
    .await
    {
        Ok(r) => r,
        Err(_) => return Vec::new(),
    };
    let confident = r.is_matched && r.matches.len() == 1;
    r.matches
        .into_iter()
        .map(|m| DanmakuMatchCandidate {
            source_id: cfg.id.clone(),
            source_name: cfg.name.clone(),
            anime_id: m.anime_id,
            // 文件识别唯一命中最可信:给到高于名字搜索满分(标题1.0+集号0.3=1.3)的分,
            // 确保排最前;否则按标题相似度 + 小加成。
            score: if confident { 1.5 } else { title_score(&input.title, &m.anime_title) + 0.2 },
            anime_title: m.anime_title,
            episode_id: m.episode_id,
            episode_title: m.episode_title,
        })
        .collect()
}

fn pick_episode(episodes: &[DanmakuEpisode], ep_num: Option<i64>) -> Option<&DanmakuEpisode> {
    if episodes.is_empty() {
        return None;
    }
    if let Some(n) = ep_num {
        if let Some(ep) = episodes.iter().find(|ep| episode_matches(ep, Some(n))) {
            return Some(ep);
        }
        // 集号越界时退回按位置取(部分源 episodeNumber 不规整)。
        if n >= 1 && n <= episodes.len() as i64 {
            return episodes.get((n - 1) as usize);
        }
    }
    episodes.first()
}

fn episode_matches(ep: &DanmakuEpisode, ep_num: Option<i64>) -> bool {
    let Some(n) = ep_num else { return false };
    let raw = ep.episode_number.as_deref().unwrap_or("").trim();
    if raw.is_empty() {
        return false;
    }
    if let Ok(parsed) = raw.parse::<i64>() {
        return parsed == n;
    }
    // episodeNumber 可能是 "第3话"/"03" 之类,抽首个数字串比对。
    digits_re()
        .find(raw)
        .and_then(|m| m.as_str().parse::<i64>().ok())
        .is_some_and(|d| d == n)
}

fn digits_re() -> &'static Regex {
    static RE: OnceLock<Regex> = OnceLock::new();
    RE.get_or_init(|| Regex::new(r"\d+").unwrap())
}

/// 逐字对齐 Dart DanmakuMatcher._normalize:小写 → 去标点/空白 → 去「第N季/部」→ trim。
fn normalize(s: &str) -> String {
    static PUNCT: OnceLock<Regex> = OnceLock::new();
    static SEASON: OnceLock<Regex> = OnceLock::new();
    let punct = PUNCT
        .get_or_init(|| Regex::new(r"[\s\-_:：·・,，.。!！?？\[\]\(\)（）]").unwrap());
    let season = SEASON
        .get_or_init(|| Regex::new(r"第[一二三四五六七八九十\d]+[季部]").unwrap());
    let lower = s.to_lowercase();
    let no_punct = punct.replace_all(&lower, "");
    season.replace_all(&no_punct, "").trim().to_string()
}

/// 标题相似度 0~1。完全相等 1,包含 0.7,否则字符二元组 Jaccard ×0.6。
/// 逐字对齐 Dart DanmakuMatcher._titleScore。
fn title_score(query: &str, candidate: &str) -> f64 {
    let q = normalize(query);
    let c = normalize(candidate);
    if q.is_empty() || c.is_empty() {
        return 0.0;
    }
    if q == c {
        return 1.0;
    }
    if c.contains(&q) || q.contains(&c) {
        return 0.7;
    }
    let qg = bigrams(&q);
    let cg = bigrams(&c);
    if qg.is_empty() || cg.is_empty() {
        return 0.0;
    }
    let inter = qg.intersection(&cg).count();
    let union = qg.union(&cg).count();
    if union == 0 {
        0.0
    } else {
        (inter as f64 / union as f64) * 0.6
    }
}

fn bigrams(s: &str) -> std::collections::HashSet<String> {
    // Dart 按 UTF-16 code unit 切;CJK/拉丁(BMP)下与 Rust char 等价。
    let chars: Vec<char> = s.chars().collect();
    let mut set = std::collections::HashSet::new();
    for w in chars.windows(2) {
        set.insert(w.iter().collect::<String>());
    }
    if chars.len() == 1 {
        set.insert(s.to_string());
    }
    set
}

// ---------- 缓存(内存 LRU + 磁盘 JSON) ----------
// 对齐 Dart DanmakuCache:key = `{sourceId}:{episodeId}`,内存 40 条,磁盘 TTL 7 天。
// 磁盘目录走 config_dir()/LinPlayer/danmaku_cache(与 config.json 同根,独立文件不塞进配置)。

const MEM_CAPACITY: usize = 40;
const TTL_SECS: i64 = 7 * 24 * 3600;

/// 访问顺序即 LRU 顺序(尾部最新)。
/// ponytail: Vec 线性扫,40 条上限下 O(n) 无所谓;真要放大再换 LinkedHashMap。
static MEM: Mutex<Vec<(String, Vec<DanmakuComment>)>> = Mutex::new(Vec::new());

#[derive(Serialize, Deserialize)]
struct CacheFile {
    ts: i64,
    source_id: String,
    episode_id: String,
    items: Vec<DanmakuComment>,
}

fn cache_key(source_id: &str, episode_id: &str) -> String {
    format!("{source_id}:{episode_id}")
}

fn cache_dir() -> PathBuf {
    crate::paths::cache_dir("danmaku")
}

fn cache_file(key: &str) -> PathBuf {
    let mut h = Md5::new();
    h.update(key.as_bytes());
    cache_dir().join(format!("{:x}.json", h.finalize()))
}

fn mem_touch(key: &str, items: &[DanmakuComment]) {
    let Ok(mut m) = MEM.lock() else { return };
    m.retain(|(k, _)| k != key);
    m.push((key.to_string(), items.to_vec()));
    while m.len() > MEM_CAPACITY {
        m.remove(0);
    }
}

fn mem_get(key: &str) -> Option<Vec<DanmakuComment>> {
    let mut m = MEM.lock().ok()?;
    let i = m.iter().position(|(k, _)| k == key)?;
    let hit = m.remove(i); // 提升为最近使用
    let items = hit.1.clone();
    m.push(hit);
    Some(items)
}

/// 读缓存。未命中 / 过期返回 None。
/// ponytail: 用同步 std::fs —— 单集弹幕 JSON 几百 KB,阻塞可忽略;真卡了再 tokio::fs。
pub fn cache_get(source_id: &str, episode_id: &str) -> Option<Vec<DanmakuComment>> {
    if source_id.is_empty() || episode_id.is_empty() {
        return None;
    }
    let key = cache_key(source_id, episode_id);
    if let Some(hit) = mem_get(&key) {
        return Some(hit);
    }
    let path = cache_file(&key);
    let raw: CacheFile = serde_json::from_str(&std::fs::read_to_string(&path).ok()?).ok()?;
    if now_secs() - raw.ts > TTL_SECS {
        let _ = std::fs::remove_file(&path);
        return None;
    }
    if raw.items.is_empty() {
        return None;
    }
    mem_touch(&key, &raw.items);
    Some(raw.items)
}

/// 写缓存(内存 + 磁盘)。空列表不写。磁盘写失败不影响内存缓存与本次播放。
pub fn cache_put(source_id: &str, episode_id: &str, items: &[DanmakuComment]) {
    if source_id.is_empty() || episode_id.is_empty() || items.is_empty() {
        return;
    }
    let key = cache_key(source_id, episode_id);
    mem_touch(&key, items);
    let _ = std::fs::create_dir_all(cache_dir());
    if let Ok(json) = serde_json::to_string(&CacheFile {
        ts: now_secs(),
        source_id: source_id.to_string(),
        episode_id: episode_id.to_string(),
        items: items.to_vec(),
    }) {
        let _ = std::fs::write(cache_file(&key), json);
    }
}

/// 清空全部弹幕缓存(内存 + 磁盘)。返回删除的文件数。对齐 Dart DanmakuCache.clear。
pub fn cache_clear() -> usize {
    if let Ok(mut m) = MEM.lock() {
        m.clear();
    }
    let Ok(rd) = std::fs::read_dir(cache_dir()) else { return 0 };
    rd.flatten()
        .filter(|e| e.path().extension().is_some_and(|x| x == "json"))
        .filter(|e| std::fs::remove_file(e.path()).is_ok())
        .count()
}

/// 当前磁盘缓存占用字节数。对齐 Dart DanmakuCache.diskSizeBytes。
pub fn cache_disk_size_bytes() -> u64 {
    let Ok(rd) = std::fs::read_dir(cache_dir()) else { return 0 };
    rd.flatten()
        .filter_map(|e| e.metadata().ok())
        .filter(|m| m.is_file())
        .map(|m| m.len())
        .sum()
}

/// 取某源某集弹幕,命中缓存秒载。对齐 Dart DanmakuService.getComments(sourceId:)。
pub async fn get_comments_cached(
    http: &reqwest::Client,
    cfg: &DanmakuSourceConfig,
    episode_id: &str,
    ch_convert: i32,
    use_cache: bool,
) -> Result<Vec<DanmakuComment>, String> {
    if use_cache {
        if let Some(hit) = cache_get(&cfg.id, episode_id) {
            if !hit.is_empty() {
                return Ok(hit);
            }
        }
    }
    let items = get_comments(http, cfg, episode_id, ch_convert).await?;
    if use_cache && !items.is_empty() {
        cache_put(&cfg.id, episode_id, &items);
    }
    Ok(items)
}

/// 逐源尝试取弹幕,首个非空即返回;`preferred` 优先。对齐 Dart getCommentsFromAll。
pub async fn get_comments_from_all(
    http: &reqwest::Client,
    cfgs: &[DanmakuSourceConfig],
    episode_id: &str,
    preferred: Option<&str>,
    ch_convert: i32,
) -> Vec<DanmakuComment> {
    // 顺序(非并行)——对齐 Dart:命中即停,不给后面的源白发请求。
    let order = cfgs
        .iter()
        .filter(|c| Some(c.id.as_str()) == preferred)
        .chain(cfgs.iter().filter(|c| Some(c.id.as_str()) != preferred));
    for cfg in order {
        if let Ok(items) = get_comments_cached(http, cfg, episode_id, ch_convert, true).await {
            if !items.is_empty() {
                return items;
            }
        }
    }
    Vec::new()
}

// ---------- 过滤 + 去重 ----------

/// 弹幕屏蔽器。对齐 Dart DanmakuFilter:文本屏蔽词 + 用户ID 屏蔽。
#[derive(Clone, Debug, Default)]
pub struct DanmakuFilter {
    text_blockwords: Vec<String>,
    user_blocklist: Vec<String>,
}

impl DanmakuFilter {
    pub fn new() -> Self {
        Self::default()
    }

    pub fn add_text_blockword(&mut self, word: &str) {
        if !word.is_empty() && !self.text_blockwords.iter().any(|w| w == word) {
            self.text_blockwords.push(word.to_string());
        }
    }

    pub fn add_user_block(&mut self, user_id: &str) {
        if !user_id.is_empty() && !self.user_blocklist.iter().any(|u| u == user_id) {
            self.user_blocklist.push(user_id.to_string());
        }
    }

    pub fn remove_text_blockword(&mut self, word: &str) {
        self.text_blockwords.retain(|w| w != word);
    }

    pub fn remove_user_block(&mut self, user_id: &str) {
        self.user_blocklist.retain(|u| u != user_id);
    }

    pub fn import_blockwords(&mut self, words: &[String]) {
        for w in words {
            self.add_text_blockword(w);
        }
    }

    pub fn import_user_blocks(&mut self, ids: &[String]) {
        for u in ids {
            self.add_user_block(u);
        }
    }

    pub fn clear(&mut self) {
        self.text_blockwords.clear();
        self.user_blocklist.clear();
    }

    pub fn text_blockwords(&self) -> &[String] {
        &self.text_blockwords
    }

    pub fn user_blocklist(&self) -> &[String] {
        &self.user_blocklist
    }

    pub fn total_block_count(&self) -> usize {
        self.text_blockwords.len() + self.user_blocklist.len()
    }

    /// 是否该被过滤:用户在屏蔽名单,或文本含任一屏蔽词。
    pub fn should_filter(&self, text: &str, user_id: Option<&str>) -> bool {
        if let Some(u) = user_id {
            if self.user_blocklist.iter().any(|b| b == u) {
                return true;
            }
        }
        self.text_blockwords.iter().any(|w| text.contains(w.as_str()))
    }
}

/// 屏蔽词导入结果。对齐 Dart DanmakuFilterImportResult。
#[derive(Debug, Default, Serialize)]
pub struct DanmakuFilterImportResult {
    /// 装好的过滤器(Rust 侧直接可用)。不过 IPC:它的内容与下面 text_words/user_ids
    /// 是同一份数据的两种形态,前端只要后者,没必要为过 IPC 给它硬加 derive。
    #[serde(skip)]
    pub filter: DanmakuFilter,
    pub text_words: Vec<String>,
    pub user_ids: Vec<String>,
    pub skipped_count: usize,
}

impl DanmakuFilterImportResult {
    pub fn total_imported(&self) -> usize {
        self.text_words.len() + self.user_ids.len()
    }
}

/// 从弹弹Play XML 屏蔽列表导入。格式:`<item enabled="true">t=词</item>` /
/// `<item enabled="true">x=uid=[平台]用户ID</item>`。对齐 Dart importFromDandanplayXml。
/// ponytail: 用 regex 抽 `<item>` 而非上 XML crate —— 这文件就这一种扁平结构,
/// 为它加个 quick-xml 依赖不值;真要吃任意 XML 再换。
pub fn import_dandanplay_blocklist_xml(xml: &str) -> DanmakuFilterImportResult {
    static RE: OnceLock<Regex> = OnceLock::new();
    let re = RE.get_or_init(|| Regex::new(r"(?s)<item([^>]*)>(.*?)</item>").unwrap());
    let mut out = DanmakuFilterImportResult::default();
    for cap in re.captures_iter(xml) {
        let attrs = cap.get(1).map(|m| m.as_str()).unwrap_or("");
        if attrs.contains("enabled=\"false\"") || attrs.contains("enabled='false'") {
            out.skipped_count += 1;
            continue;
        }
        let content = unescape_xml(cap.get(2).map(|m| m.as_str()).unwrap_or("").trim());
        if content.is_empty() {
            out.skipped_count += 1;
            continue;
        }
        if let Some(word) = content.strip_prefix("t=") {
            let word = word.trim();
            if !word.is_empty() {
                out.text_words.push(word.to_string());
                out.filter.add_text_blockword(word);
            }
        } else if let Some(uid) = content.strip_prefix("x=uid=") {
            let uid = uid.trim();
            if !uid.is_empty() {
                out.user_ids.push(uid.to_string());
                out.filter.add_user_block(uid);
            }
        }
    }
    out
}

fn unescape_xml(s: &str) -> String {
    s.replace("&lt;", "<")
        .replace("&gt;", ">")
        .replace("&quot;", "\"")
        .replace("&apos;", "'")
        .replace("&amp;", "&") // 必须最后,否则 &amp;lt; 会被二次解码
}

/// 后处理选项。对齐 Dart applyDanmakuFilterAndDedup 的入参
/// (danmakuBlockwords / danmakuDedup / danmakuDedupWindow 三个 provider)。
#[derive(Clone, Debug, Serialize, Deserialize)]
#[serde(default)]
pub struct FilterOptions {
    pub blockwords: Vec<String>,
    /// Dart 侧只从 XML 导入用户屏蔽、没接 provider;这里一并暴露,宿主可不填。
    pub user_blocklist: Vec<String>,
    /// 屏蔽的弹幕类型(1=滚动 4=底 5=顶)。**Dart 无对应实现**,按任务书补的;空=不过滤。
    pub blocked_modes: Vec<i32>,
    pub dedup: bool,
    /// 去重时间窗口(秒),Dart 默认 10.0。
    pub dedup_window: f64,
}

impl Default for FilterOptions {
    fn default() -> Self {
        Self {
            blockwords: Vec::new(),
            user_blocklist: Vec::new(),
            blocked_modes: Vec::new(),
            dedup: false,
            dedup_window: 10.0,
        }
    }
}

/// 弹幕后处理:屏蔽词/用户/类型过滤 + 时间窗口去重。手动搜索面板与自动加载共用,
/// 保证两条路径得到一致的弹幕。对齐 Dart applyDanmakuFilterAndDedup。
pub fn apply_filter_and_dedup(
    input: Vec<DanmakuComment>,
    opts: &FilterOptions,
) -> Vec<DanmakuComment> {
    let mut items = input;
    if !opts.blockwords.is_empty() || !opts.user_blocklist.is_empty() {
        let mut filter = DanmakuFilter::new();
        filter.import_blockwords(&opts.blockwords);
        filter.import_user_blocks(&opts.user_blocklist);
        items.retain(|it| !filter.should_filter(&it.text, it.user_id.as_deref()));
    }
    if !opts.blocked_modes.is_empty() {
        items.retain(|it| !opts.blocked_modes.contains(&it.mode));
    }
    if opts.dedup {
        items = dedup(items, opts.dedup_window);
    }
    items
}

/// 时间窗口内同文本同类型合并,count 记次数。逐字对齐 Dart danmaku_postprocess._dedup。
fn dedup(mut items: Vec<DanmakuComment>, window_seconds: f64) -> Vec<DanmakuComment> {
    items.sort_by(|a, b| a.time.partial_cmp(&b.time).unwrap_or(std::cmp::Ordering::Equal));
    let mut used = vec![false; items.len()];
    let mut result = Vec::new();
    for i in 0..items.len() {
        if used[i] {
            continue;
        }
        let mut count = 1;
        for j in (i + 1)..items.len() {
            if used[j] {
                continue;
            }
            if items[j].time - items[i].time > window_seconds {
                break;
            }
            if items[j].text == items[i].text && items[j].mode == items[i].mode {
                count += 1;
                used[j] = true;
            }
        }
        result.push(DanmakuComment { count, ..items[i].clone() });
    }
    result
}

#[cfg(test)]
mod tests {
    use super::*;

    /* 鉴权推导:用户只填「名称 + 链接」,鉴权方式由链接推出来。
       用例是两个主流自建端 README/源码里的**原样地址**,不是我编的:
         - huangxd-/danmu_api            http://{ip}:9321/87654321/api/v2   (路径 token,默认 87654321)
         - l429609201/misaka_danmu_server  prefix="/{token}/api/v2"          (路径 token)
       路径 token 天然含在地址里 → 判 None、地址原样用,请求会打到 /{token}/api/v2/xxx。 */
    #[test]
    fn derive_auth_handles_path_token_servers_verbatim() {
        for url in [
            "http://192.168.1.9:9321/87654321/api/v2",
            "https://my.vercel.app/87654321/api/v2",
            "https://misaka.example.com/mytoken123/api/v2",
        ] {
            let (u, a, t) = derive_auth(url);
            assert_eq!(u, url, "路径 token 的地址必须原样保留");
            assert_eq!(a, DanmakuAuthType::None, "路径 token 不需要额外鉴权动作");
            assert_eq!(t, None);
        }
        // 尾斜杠要吃掉,否则 base_url() 会拼出双斜杠
        let (u, _, _) = derive_auth("http://h:9321/87654321/api/v2/");
        assert_eq!(u, "http://h:9321/87654321/api/v2");
        // 省略默认 token 的写法(danmu_api 允许)也照样原样用
        let (u, a, _) = derive_auth("http://h:9321");
        assert_eq!((u.as_str(), a), ("http://h:9321", DanmakuAuthType::None));
    }

    /* 两段式搜索的解析口径。真接口要签名(裸 curl 一律 403 Missing Authentication
       Headers,2026-07-19 实测),所以这里钉的是 swagger v2 文档的载荷形状:
         - 新引擎 /search/anime?v2=true 回 `bangumiList`(老引擎回 `animes`)
         - 条目层**没有** episodes,集表要另取 —— 这正是「先出条目再出集」的前提
         - /bangumi/{id} 把集表包在 `bangumi.episodes` 里 */
    #[test]
    fn parses_both_v2_bangumi_list_and_legacy_animes() {
        let v2 = serde_json::json!({"bangumiList":[
            {"animeId":18496,"animeTitle":"鬼灭之刃","imageUrl":"http://i/1.jpg","year":2019,"episodeCount":26}
        ]});
        let got = parse_anime_list(&v2);
        assert_eq!(got.len(), 1, "新引擎的 bangumiList 必须认");
        assert_eq!(got[0].anime_id, "18496", "animeId 是数字,要转成字符串");
        assert_eq!(got[0].episode_count, Some(26));
        assert!(got[0].episodes.is_empty(), "条目层不该带集表(带了就说明还在走慢接口)");

        let legacy = serde_json::json!({"animes":[{"animeId":"7","animeTitle":"老引擎"}]});
        assert_eq!(parse_anime_list(&legacy)[0].anime_title, "老引擎");
    }

    /* /bangumi/{id} 的集表藏在 `bangumi` 下面一层;直接 parse_anime(&v) 会静默拿到空集表
       (不报错,只是用户点进去永远「没有可用的集」)。 */
    #[test]
    fn parses_episodes_from_bangumi_detail() {
        let v = serde_json::json!({"bangumi":{
            "animeId":18496,"animeTitle":"鬼灭之刃",
            "episodes":[
                {"episodeId":184960001,"episodeTitle":"第1话 残酷","episodeNumber":"1"},
                {"episodeId":184960002,"episodeTitle":"第2话 培育者","episodeNumber":"2"}
            ]}});
        let eps = parse_bangumi_episodes(&v);
        assert_eq!(eps.len(), 2);
        assert_eq!(eps[0].episode_id, "184960001");
        assert_eq!(eps[1].episode_number.as_deref(), Some("2"));
    }

    /* query 带 token 的写法必须拆出来:原样留在 api_url 里,base_url() 会在问号后面
       接上 /api/v2,拼成 `...?token=x/api/v2` 这种打不通的地址(静默失败,最难查)。 */
    #[test]
    fn derive_auth_splits_query_token_out_of_url() {
        for (raw, want_tok) in [
            ("https://d.example.com/api/v2?token=abc123", "abc123"),
            ("https://d.example.com/api/v2?api_key=k9", "k9"),
            ("https://d.example.com/api/v2?foo=1&token=zz", "zz"),
        ] {
            let (u, a, t) = derive_auth(raw);
            assert_eq!(u, "https://d.example.com/api/v2", "query 必须从地址里摘掉");
            assert_eq!(a, DanmakuAuthType::QueryToken);
            assert_eq!(t.as_deref(), Some(want_tok));
        }
        // 空值的 token= 不算,别塞个空 token 进去
        let (_, a, _) = derive_auth("https://d.example.com/api/v2?token=");
        assert_eq!(a, DanmakuAuthType::None);
    }

    #[test]
    fn parse_and_sign() {
        let d = serde_json::json!({ "p": "12.5,5,16711680,user9", "m": "顶部红字", "cid": "88" });
        let c = parse_comment(&d, "弹弹play");
        assert_eq!(c.time, 12.5);
        assert_eq!(c.mode, 5);
        assert_eq!(c.color, 16711680);
        assert_eq!(c.text, "顶部红字");
        assert_eq!(c.user_id.as_deref(), Some("user9"));
        assert_eq!(c.cid.as_deref(), Some("88"));
        // 签名 = base64(sha256(...)) = 32 字节 → 44 字符 base64
        assert_eq!(signature("appid", "/api/v2/x", 0, "secret").len(), 44);
    }

    #[test]
    fn base_url_and_pathtoken() {
        let mut cfg = DanmakuSourceConfig {
            api_url: "https://d.example.com/".into(),
            ..Default::default()
        };
        assert_eq!(cfg.base_url(), "https://d.example.com/api/v2");
        cfg.auth_type = Some(DanmakuAuthType::PathToken);
        cfg.token = Some("tok123".into());
        assert_eq!(cfg.request_base_url(), "https://d.example.com/tok123/api/v2");
    }

    // ---------- 集数匹配 ----------

    fn ep(id: &str, num: Option<&str>) -> DanmakuEpisode {
        DanmakuEpisode {
            episode_id: id.into(),
            episode_title: format!("第{}话", num.unwrap_or("?")),
            episode_number: num.map(String::from),
        }
    }

    #[test]
    fn episode_number_forms() {
        // 纯数字 / 补零 / 「第N话」/ 「N话」 —— 都该抽出数字比对。
        assert!(episode_matches(&ep("1", Some("3")), Some(3)));
        assert!(episode_matches(&ep("1", Some("03")), Some(3)));
        assert!(episode_matches(&ep("1", Some("第3话")), Some(3)));
        assert!(episode_matches(&ep("1", Some(" 3 ")), Some(3)));
        assert!(!episode_matches(&ep("1", Some("4")), Some(3)));
        // 空 / 无数字 / 无集号 → 不匹配。
        assert!(!episode_matches(&ep("1", None), Some(3)));
        assert!(!episode_matches(&ep("1", Some("")), Some(3)));
        assert!(!episode_matches(&ep("1", Some("OVA")), Some(3)));
        assert!(!episode_matches(&ep("1", Some("3")), None));
    }

    #[test]
    fn pick_episode_by_number_then_position() {
        let eps = vec![ep("101", Some("1")), ep("102", Some("2")), ep("103", Some("3"))];
        // ① 按 episodeNumber 命中。
        assert_eq!(pick_episode(&eps, Some(2)).unwrap().episode_id, "102");
        // ② episodeNumber 不规整 → 退回按位置(第 2 集 = 下标 1)。
        let messy = vec![ep("201", Some("SP")), ep("202", Some("OVA")), ep("203", Some("PV"))];
        assert_eq!(pick_episode(&messy, Some(2)).unwrap().episode_id, "202");
        // ③ 集号越界且不匹配 → 退回首集。
        assert_eq!(pick_episode(&messy, Some(9)).unwrap().episode_id, "201");
        // ④ 无集号 → 首集;空列表 → None。
        assert_eq!(pick_episode(&eps, None).unwrap().episode_id, "101");
        assert!(pick_episode(&[], Some(1)).is_none());
    }

    #[test]
    fn title_score_forms() {
        // 完全相等(含标点/大小写/空白差异被 normalize 抹平)。
        assert_eq!(title_score("葬送的芙莉莲", "葬送的芙莉莲"), 1.0);
        assert_eq!(title_score("Frieren: Beyond Journey's End", "frieren beyond journey's end"), 1.0);
        // 「第N季/部」被剥掉 → 与无季号标题相等。
        assert_eq!(title_score("孤独摇滚 第二季", "孤独摇滚"), 1.0);
        assert_eq!(title_score("间谍过家家 第2部", "间谍过家家"), 1.0);
        // 包含关系 → 0.7。
        assert_eq!(title_score("赛马娘", "赛马娘 Pretty Derby"), 0.7);
        // 无交集 → bigram Jaccard ×0.6,必然 < 0.6。
        let s = title_score("葬送的芙莉莲", "咒术回战");
        assert!((0.0..0.6).contains(&s), "无关标题不该高分, got {s}");
        // 部分重叠 → 落在 (0, 0.6)。
        let s2 = title_score("摇曳露营", "摇曳百合");
        assert!(s2 > 0.0 && s2 < 0.6, "部分重叠应在(0,0.6), got {s2}");
        // 空串 → 0。
        assert_eq!(title_score("", "x"), 0.0);
        assert_eq!(title_score("x", ""), 0.0);
        // 单字符标题:bigrams 走 length==1 分支,不该 panic 也不该判 0(相等走 1.0)。
        assert_eq!(title_score("A", "A"), 1.0);
    }

    #[test]
    fn normalize_strips_punct_and_season() {
        assert_eq!(normalize("Re：从零开始的异世界生活 第二季"), "re从零开始的异世界生活");
        assert_eq!(normalize("[Sub] Title (2024)!"), "subtitle2024");
    }

    #[test]
    fn resolve_title_and_file_name() {
        // 剧集用 seriesName。
        assert_eq!(resolve_title(Some(" 孤独摇滚 "), "第 5 集"), "孤独摇滚");
        // seriesName 空 → 条目名。
        assert_eq!(resolve_title(None, " 你的名字 "), "你的名字");
        assert_eq!(resolve_title(Some("  "), "你的名字"), "你的名字");
        // 文件名:Windows 反斜杠 / Unix 斜杠都取 basename。
        assert_eq!(
            resolve_file_name(Some(r"D:\Anime\Bocchi\S01E05.mkv"), "第5集"),
            "S01E05.mkv"
        );
        assert_eq!(
            resolve_file_name(Some("/mnt/media/Bocchi/S01E05.mkv"), "第5集"),
            "S01E05.mkv"
        );
        // 无 path → 条目名。
        assert_eq!(resolve_file_name(None, "第5集"), "第5集");
        assert_eq!(resolve_file_name(Some(""), "第5集"), "第5集");
    }

    #[test]
    fn ticks_and_anime_detection() {
        assert_eq!(duration_secs_from_ticks(Some(14_100_000_000)), Some(1410.0));
        assert_eq!(duration_secs_from_ticks(Some(0)), None);
        assert_eq!(duration_secs_from_ticks(None), None);
        assert!(is_anime(&["动画".to_string()]));
        assert!(is_anime(&["Anime".to_string()])); // 大小写不敏感
        assert!(is_anime(&["Japanese Animation".to_string()])); // 子串命中
        assert!(!is_anime(&["剧情".to_string(), "犯罪".to_string()]));
        assert!(!is_anime(&[]));
    }

    #[test]
    fn match_result_parses_real_payload() {
        // 弹弹Play /match 真实响应形状(animeId/episodeId 是数字,不是字符串)。
        let v = serde_json::json!({
            "isMatched": true,
            "matches": [{
                "episodeId": 178990001i64,
                "animeId": 17899,
                "animeTitle": "葬送的芙莉莲",
                "episodeTitle": "第1话 冒险的结束",
                "type": "tvseries",
                "typeDescription": "TV动画",
                "shift": 0
            }]
        });
        let cfg = DanmakuSourceConfig { id: "official".into(), name: "弹弹Play".into(), ..Default::default() };
        let r = parse_match_result(&v, &cfg);
        assert!(r.is_matched);
        assert_eq!(r.matches.len(), 1);
        assert_eq!(r.matches[0].episode_id, "178990001");
        assert_eq!(r.matches[0].anime_id, "17899");
        assert_eq!(r.matches[0].source_name, "弹弹Play");
        assert_eq!(r.matches[0].shift, Some(0));
        // 空响应不 panic。
        let empty = parse_match_result(&serde_json::json!({}), &cfg);
        assert!(!empty.is_matched && empty.matches.is_empty());
    }

    // ---------- 过滤 / 去重 ----------

    fn c(time: f64, text: &str, mode: i32, user: Option<&str>) -> DanmakuComment {
        DanmakuComment {
            time,
            text: text.into(),
            mode,
            color: 16777215,
            source: "s".into(),
            cid: None,
            user_id: user.map(String::from),
            count: 1,
        }
    }

    #[test]
    fn filter_blocks_words_users_modes() {
        let items = vec![
            c(1.0, "前方高能", 1, Some("u1")),
            c(2.0, "剧透:他死了", 1, Some("u2")),
            c(3.0, "正常弹幕", 1, Some("u3")),
            c(4.0, "顶部广告", 5, Some("u4")),
        ];
        // 关键词屏蔽(子串命中)。
        let out = apply_filter_and_dedup(
            items.clone(),
            &FilterOptions { blockwords: vec!["剧透".into()], ..Default::default() },
        );
        assert_eq!(out.len(), 3);
        assert!(!out.iter().any(|x| x.text.contains("剧透")));
        // 用户屏蔽。
        let out = apply_filter_and_dedup(
            items.clone(),
            &FilterOptions { user_blocklist: vec!["u1".into()], ..Default::default() },
        );
        assert_eq!(out.len(), 3);
        assert!(!out.iter().any(|x| x.user_id.as_deref() == Some("u1")));
        // 类型过滤(屏蔽顶部弹幕 mode=5)。
        let out = apply_filter_and_dedup(
            items.clone(),
            &FilterOptions { blocked_modes: vec![5], ..Default::default() },
        );
        assert_eq!(out.len(), 3);
        assert!(out.iter().all(|x| x.mode != 5));
        // 不配置任何屏蔽 → 原样返回。
        assert_eq!(apply_filter_and_dedup(items, &FilterOptions::default()).len(), 4);
    }

    #[test]
    fn dedup_merges_within_window_only() {
        let items = vec![
            c(1.0, "哈哈哈", 1, None),
            c(3.0, "哈哈哈", 1, None),  // 窗口内同文同类型 → 合并
            c(5.0, "哈哈哈", 5, None),  // 同文但类型不同 → 不合并
            c(30.0, "哈哈哈", 1, None), // 超窗口 → 不合并
            c(2.0, "别的", 1, None),
        ];
        let out = apply_filter_and_dedup(
            items,
            &FilterOptions { dedup: true, dedup_window: 10.0, ..Default::default() },
        );
        // 结果按时间升序:哈哈哈(1,count2) / 别的(2) / 哈哈哈顶(5) / 哈哈哈(30)
        assert_eq!(out.len(), 4);
        assert_eq!(out[0].time, 1.0);
        assert_eq!(out[0].count, 2, "窗口内同文同类型应合并计数");
        assert_eq!(out[1].text, "别的");
        assert_eq!(out[2].mode, 5);
        assert_eq!(out[2].count, 1, "类型不同不该合并");
        assert_eq!(out[3].time, 30.0);
        assert_eq!(out[3].count, 1, "超出窗口不该合并");
    }

    #[test]
    fn dedup_off_keeps_everything() {
        let items = vec![c(1.0, "a", 1, None), c(2.0, "a", 1, None)];
        let out = apply_filter_and_dedup(items, &FilterOptions::default());
        assert_eq!(out.len(), 2);
        assert!(out.iter().all(|x| x.count == 1));
    }

    #[test]
    fn filter_add_remove_dedupes_entries() {
        let mut f = DanmakuFilter::new();
        f.add_text_blockword("剧透");
        f.add_text_blockword("剧透"); // 重复不入
        f.add_text_blockword(""); // 空不入
        f.add_user_block("u1");
        assert_eq!(f.text_blockwords().len(), 1);
        assert_eq!(f.total_block_count(), 2);
        assert!(f.should_filter("有剧透哦", None));
        assert!(f.should_filter("干净", Some("u1")));
        assert!(!f.should_filter("干净", Some("u2")));
        f.remove_text_blockword("剧透");
        f.remove_user_block("u1");
        assert_eq!(f.total_block_count(), 0);
        assert!(!f.should_filter("有剧透哦", Some("u1")));
    }

    #[test]
    fn import_dandanplay_xml_blocklist() {
        // 弹弹Play 导出的真实屏蔽列表形状。
        let xml = r#"<?xml version="1.0" encoding="utf-8"?>
<KeywordFilters>
  <item enabled="true">t=前方高能</item>
  <item enabled="true">t=剧透</item>
  <item enabled="false">t=这条被禁用了</item>
  <item enabled="true">x=uid=[BiliBili]12345678</item>
  <item enabled="true"></item>
  <item enabled="true">t=A&amp;B</item>
</KeywordFilters>"#;
        let r = import_dandanplay_blocklist_xml(xml);
        assert_eq!(r.text_words, vec!["前方高能", "剧透", "A&B"]);
        assert_eq!(r.user_ids, vec!["[BiliBili]12345678"]);
        assert_eq!(r.skipped_count, 2, "禁用的 + 空内容的都该跳过");
        assert_eq!(r.total_imported(), 4);
        assert!(r.filter.should_filter("前方高能预警", None));
        assert!(r.filter.should_filter("x", Some("[BiliBili]12345678")));
        assert!(!r.filter.should_filter("这条被禁用了", None), "禁用项不该生效");
    }

    // ---------- 缓存 ----------

    #[test]
    fn cache_mem_roundtrip_and_lru_cap() {
        // 只验内存层(磁盘层依赖 config_dir,CI 上不该乱写盘)。
        let items = vec![c(1.0, "缓存的弹幕", 1, None)];
        let key = cache_key("srcA", "ep1");
        mem_touch(&key, &items);
        assert_eq!(mem_get(&key).unwrap(), items);
        // 空 source/episode 不写不读。
        cache_put("", "ep1", &items);
        assert!(cache_get("", "ep1").is_none());
        // 空列表不写。
        cache_put("srcB", "ep2", &[]);
        // LRU 上限:塞满 + 1 后最老的被挤掉,最近访问的还在。
        for i in 0..MEM_CAPACITY + 5 {
            mem_touch(&cache_key("s", &i.to_string()), &items);
        }
        assert!(MEM.lock().unwrap().len() <= MEM_CAPACITY);
        assert!(mem_get(&cache_key("s", "0")).is_none(), "最老的该被挤出");
        assert!(mem_get(&cache_key("s", &(MEM_CAPACITY + 4).to_string())).is_some());
    }

    #[test]
    fn cache_file_name_is_stable_md5() {
        // 同 key 稳定、不同 key 相异(换机/重启后仍命中同一文件)。
        assert_eq!(cache_file("a:1"), cache_file("a:1"));
        assert_ne!(cache_file("a:1"), cache_file("a:2"));
        assert!(cache_file("a:1").to_string_lossy().ends_with(".json"));
    }
}
