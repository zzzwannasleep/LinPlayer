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

/// 弹弹Play 系接口**从不用 HTTP 状态码报错** —— 一律 200 + body 里的 `errorCode`。
/// 不看这个字段,配额用尽/参数非法/鉴权失败全都长得跟「这个关键词没搜到」一模一样:
/// `animes` 键不存在 → 解析出空表 → 界面说「未找到匹配的弹幕」。
///
/// 2026-08-01 实测(官方 AppId,真签名):`/search/anime`、`/search/episodes` 全部回
/// `{"errorCode":429,"errorMessage":"已达到接口调用配额上限"}`,HTTP 200。
/// 也就是说用户报的「弹弹play搜索不到弹幕」,界面上给的原因是**假的**。
/// 现在如实抛出去 —— 搜不到和搜不了是两件事,用户有权知道是哪件。
fn check_api_error(v: &Value) -> Result<(), String> {
    match v["errorCode"].as_i64() {
        None | Some(0) => Ok(()),
        Some(code) => {
            let msg = v["errorMessage"].as_str().unwrap_or("").trim();
            Err(if msg.is_empty() {
                format!("弹幕接口错误 {code}")
            } else {
                format!("{msg}(错误码 {code})")
            })
        }
    }
}

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
    let v: Value = resp.json().await.map_err(|e| format!("弹幕解析失败: {e}"))?;
    check_api_error(&v)?;
    Ok(v)
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
        "fileHash": normalized_file_hash(file_hash, file_name),
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
    check_api_error(&v)?;
    Ok(parse_match_result(&v, cfg))
}

/// `/match` 的 `fileHash` **必须是形状合法的 32 位十六进制** —— 空串直接被判
/// `errorCode:2 一个或多个参数不符合规则`,整个响应作废。
///
/// 2026-08-01 真接口 A/B 实测(同一文件名、同一签名):
///   `fileHash:""`                 → errorCode 2,matches 0 条
///   `fileHash:"000...0"`(32 位)  → errorCode 0,matches 25 条,第一条就是对的
///   `matchMode` 给不给、给哪个值,结果**一模一样** —— 决定成败的只有 hash 的形状。
/// 也就是说「①文件识别」这条路从接进来的那天起就没通过一次,而且失败得毫无声响
/// (HTTP 200 + `matches:[]`,和「这个文件真的没匹配上」长得一样)。
///
/// 我们播的是服务器上的流,拿不到真 hash(dandanplay 的口径是文件前 16MB 的 md5,
/// 为它多拉 16MB 不值)。所以给一个**由文件名派生的确定性占位 hash**:形状合法、
/// 跨会话稳定、且撞上某个真视频 hash 的概率是 2^-128 —— 服务端于是退化成按文件名匹配,
/// 那正是我们要的。真 hash 由调用方给到时原样透传,绝不覆盖。
fn normalized_file_hash(file_hash: Option<&str>, file_name: &str) -> String {
    let given = file_hash.unwrap_or("").trim();
    if given.len() == 32 && given.bytes().all(|b| b.is_ascii_hexdigit()) {
        return given.to_ascii_lowercase();
    }
    let mut h = Md5::new();
    h.update(file_name.as_bytes());
    format!("{:x}", h.finalize())
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
    /// 同一部作品的**其它写法**:原名(日文/罗马音)、真实发布文件名、条目名……
    ///
    /// 弹弹Play 的条目只有一个标题、没有别名表,所以平行语料只能由我们这边提供。
    /// 媒体库标题是中文而弹弹Play 收录的是日文名(或反过来)时,单靠 `title` 一路
    /// 分数恒为 0 —— 候选明明已经捞回来了,却被自己的评分扔掉。空表 = 只用 title。
    #[serde(default)]
    pub alt_titles: Vec<String>,
    /// 集号(剧集才有)。
    pub episode_no: Option<i64>,
    /// 季号(剧集才有)。用来把「第一季」和「第二季」两个同名条目分开 ——
    /// 剥掉季号之后它们的标题相似度完全一样,只有这一路信号能判。
    pub season_no: Option<i64>,
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
) -> Result<Vec<DanmakuMatchCandidate>, String> {
    if input.title.trim().is_empty() {
        return Ok(Vec::new());
    }
    let input2 = input.clone();
    let per_source = parallel_by_source(http, cfgs, |http, cfg| {
        let input = input2.clone();
        async move { match_one(&http, &cfg, &input).await }
    })
    .await;
    let mut all = Vec::new();
    let mut errs: Vec<String> = Vec::new();
    for (cands, err) in per_source {
        all.extend(cands);
        errs.extend(err);
    }
    // 一条候选都没有、而且确实有源报了错 —— 那就不是「没搜到」,是「搜不了」。
    // 吞掉的话界面只会说「未找到匹配的弹幕」,而真相可能是配额用尽 / 源挂了 / 签名错。
    if all.is_empty() && !errs.is_empty() {
        errs.dedup();
        return Err(errs.join(";"));
    }
    // 降序;NaN 不可能出现(分值全是有限算术)。
    all.sort_by(|a, b| b.score.partial_cmp(&a.score).unwrap_or(std::cmp::Ordering::Equal));
    Ok(all)
}

/// 弹弹Play 官方推荐两条路径都跑:①文件识别 /match ②名字搜索 /search/episodes。
/// 两路**并行**再合并去重(同源同集保留高分)。对齐 Dart DanmakuMatcher._matchOne。
///
/// 返回 (候选, 错误):两路**都**失败才算这个源失败 —— 一路通就还有结果可用。
/// 2026-08-01 实测这不是理论情况:官方源 `/search/*` 回 429 配额用尽的同时,
/// `/match` 照常工作(两者配额是分开的),留着单路结果比整源判死有用得多。
async fn match_one(
    http: &reqwest::Client,
    cfg: &DanmakuSourceConfig,
    input: &MatchInput,
) -> (Vec<DanmakuMatchCandidate>, Option<String>) {
    let (by_search, by_file) = tokio::join!(
        search_candidates(http, cfg, input),
        match_by_file_candidates(http, cfg, input),
    );
    let err = match (&by_search, &by_file) {
        (Err(a), Err(_)) => Some(format!("{}: {a}", cfg.name)),
        _ => None,
    };
    let mut by_ep: HashMap<String, DanmakuMatchCandidate> = HashMap::new();
    for c in by_search.unwrap_or_default().into_iter().chain(by_file.unwrap_or_default()) {
        let key = format!("{}|{}", c.source_id, c.episode_id);
        match by_ep.get(&key) {
            Some(prev) if prev.score >= c.score => {}
            _ => {
                by_ep.insert(key, c);
            }
        }
    }
    (by_ep.into_values().collect(), err)
}

/// ②名字搜索:searchEpisodes(anime, episode) 服务端按集号收窄。
///
/// 召回是分层的,前一层空了才走下一层 —— 因为**能匹配上的前提是先搜得到**
/// (bangumi2anibt README:「accuracy is capped by recall」)。分数再准,候选表是空的也没用:
///   ① 原标题 + 集号            —— 最窄,命中率也最高
///   ② 原标题(去掉集号约束)     —— 有的源不认 episode 参数
///   ③ 主名(剥季号/副标题)     —— 长标题会把全文检索呛住,只搜主名反而有
///   ④ 其它写法(原名/文件名)   —— 库里是中文名而弹弹Play 收的是日文名时的救命稻草
/// 命中即停:前一层但凡回了东西就用它,后面的层根本不发请求。
/// (官方源有调用配额 —— 2026-08-01 实测整天都在回 429,能少打一次是一次。)
async fn search_candidates(
    http: &reqwest::Client,
    cfg: &DanmakuSourceConfig,
    input: &MatchInput,
) -> Result<Vec<DanmakuMatchCandidate>, String> {
    let title = input.title.trim();
    let ep_str = input.episode_no.map(|n| n.to_string());

    // 逐层放宽的召回尝试。命中即停 —— 后面的层只是「前面全空」时的救命稻草,
    // 每多走一层就是多打一次接口(官方源有配额),没必要一次全打。
    let mut attempts: Vec<(String, Option<String>)> = vec![(title.to_string(), ep_str.clone())];
    if ep_str.is_some() {
        attempts.push((title.to_string(), None)); // ② 有的源不认 episode 参数
    }
    for extra in std::iter::once(core_name(title)).chain(input.alt_titles.iter().cloned()) {
        let extra = extra.trim().to_string();
        // 太短的写法(1~2 字)搜出来全是噪声,不值得多打一次接口。
        if extra.chars().count() >= 3 && !attempts.iter().any(|(k, _)| k.eq_ignore_ascii_case(&extra))
        {
            attempts.push((extra, None));
        }
    }

    let mut animes: Vec<DanmakuAnime> = Vec::new();
    let mut first_err: Option<String> = None;
    for (kw, ep) in &attempts {
        match search_episodes(http, cfg, Some(kw), ep.as_deref()).await {
            Ok(found) => animes = found,
            Err(e) => {
                first_err.get_or_insert(e);
            }
        }
        if !animes.is_empty() {
            break;
        }
    }
    if animes.is_empty() {
        return match first_err {
            Some(e) => Err(e),
            None => Ok(Vec::new()),
        };
    }

    Ok(animes
        .into_iter()
        .filter_map(|anime| {
            if anime.episodes.is_empty() {
                return None;
            }
            let base = title_score(input, &anime.anime_title) + season_term(input, &anime.anime_title);
            let ep = pick_episode(&anime.episodes, input.episode_no)?;
            Some(DanmakuMatchCandidate {
                source_id: cfg.id.clone(),
                source_name: cfg.name.clone(),
                anime_id: anime.anime_id.clone(),
                anime_title: anime.anime_title.clone(),
                episode_id: ep.episode_id.clone(),
                episode_title: ep.episode_title.clone(),
                score: base + if episode_matches(ep, input.episode_no) { 0.3 } else { 0.0 },
            })
        })
        .collect())
}

/// ①文件识别:真实文件名 + 时长调 /match。isMatched 且唯一命中最可信。
/// 对齐 Dart DanmakuMatcher._matchByFileCandidates。
async fn match_by_file_candidates(
    http: &reqwest::Client,
    cfg: &DanmakuSourceConfig,
    input: &MatchInput,
) -> Result<Vec<DanmakuMatchCandidate>, String> {
    if input.file_name.trim().is_empty() {
        return Ok(Vec::new());
    }
    let r = match_file(
        http,
        cfg,
        &input.file_name,
        input.file_hash.as_deref(),
        input.file_size,
        input.duration_secs,
    )
    .await?;
    let confident = r.is_matched && r.matches.len() == 1;
    Ok(r.matches
        .into_iter()
        .map(|m| DanmakuMatchCandidate {
            source_id: cfg.id.clone(),
            source_name: cfg.name.clone(),
            anime_id: m.anime_id,
            // 文件识别唯一命中最可信:给到高于名字搜索满分(标题1.0+集号0.3+季号0.15=1.45)的分,
            // 确保排最前;否则按标题相似度 + 季号一致性 + 小加成。
            score: if confident {
                1.6
            } else {
                title_score(input, &m.anime_title) + season_term(input, &m.anime_title) + 0.2
            },
            anime_title: m.anime_title,
            episode_id: m.episode_id,
            episode_title: m.episode_title,
        })
        .collect())
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

/* ---------- 标题相似度 ----------

   口径换成 bangumi2anibt(D:\xiaochengxu\bangumi2anibt,matcher.c)那一套:
   **归一化折叠 + Levenshtein 比率 + 长度加权的包含下限**,一条代码路径吃所有语种,
   不写任何按语言分支的规则。

   为什么换掉原来的「字符二元组 Jaccard ×0.6」:
   1) 它给不出 0.6 以上的分。凡是没有完全相等、也没有包含关系的标题,上限就是 0.6,
      而 MIN_AUTO_SCORE 是 0.5 —— 差一个字的标题(「葬送的芙莉莲」vs「葬送之芙莉莲」)
      和毫不相干的标题挤在同一个窄区间里,阈值根本分不开。Levenshtein 比率给的是
      0.86 对 0.1,这才叫可判。
   2) 它不做任何字形折叠。全角(ＦＡＴＥ)、片假名/平假名(フリーレン vs ふりーれん)、
      大小写、标点差异,在二元组集合上全是「不同的字符」,直接把分打到 0。
   3) 包含关系一律记 0.7,不看长度。于是「刀」落在「刀剑神域」里 = 0.7,
      「赛马娘」落在「赛马娘 Pretty Derby」里也 = 0.7 —— 后者显然更该信。
      改成 0.6 + 0.4×(短/长),长度占比自己说话。

   保留的:季号在这一层仍然**剥掉**(见 normalize)。季号不是标题相似度该管的事 ——
   它是个独立且更硬的信号,单独由 season_of / season_term 处理,见下。 */

/// 折叠一个字符到可比较的表面;返回 None 表示整个丢掉。
///
/// 做的是 NFKC + casefold 里「对标题真正有用」的那个子集:全角→半角、大写→小写、
/// 片假名→平假名、所有分隔符/标点丢弃。完整 NFKC 和繁→简要拖进大张 Unicode 表,
/// 不做 —— 下面的 Levenshtein 比率吃得下繁体带来的那几个字的漂移。
fn fold(c: char) -> Option<char> {
    let u = c as u32;
    match u {
        // 各种空白 + 表意空格
        0x20 | 0x09 | 0x0A | 0x0D | 0x3000 => None,
        // ASCII 标点(空格..'/'、':'..'@'、'['..'`'、'{'..'~')
        0x21..=0x2F | 0x3A..=0x40 | 0x5B..=0x60 | 0x7B..=0x7E => None,
        // CJK 标点:、。〈〉「」【】〜… 等
        0x3001..=0x303F => None,
        // 片假名中点「・」(不在下面的片假名区间里,得单独丢)
        0x30FB => None,
        // 全角 ASCII → 半角,然后再走一遍(大写还要转小写、标点还要丢)
        0xFF01..=0xFF5E => fold(char::from_u32(u - 0xFEE0)?),
        // 片假名 → 平假名(把假名的「宽窄」统一掉)
        0x30A1..=0x30F6 => char::from_u32(u - 0x60),
        _ => {
            let lower = c.to_lowercase().next().unwrap_or(c);
            Some(lower)
        }
    }
}

/// 标题长于这个就截断。超长标题的尾巴对匹配没有贡献,却让 Levenshtein 变成 O(n²) 的负担。
const MAX_TITLE_CHARS: usize = 128;

/// 归一化成可比较的字符序列。季号在这一步剥掉(季号由 season_term 单独判)。
fn norm_chars(s: &str) -> Vec<char> {
    season_re()
        .replace_all(s, "")
        .chars()
        .filter_map(fold)
        .take(MAX_TITLE_CHARS)
        .collect()
}

/// 归一化后的字符串。仅供测试读值用(算分全走 norm_chars,不经过这里)。
#[cfg(test)]
fn normalize(s: &str) -> String {
    norm_chars(s).into_iter().collect()
}

/// 两行 DP 的 Levenshtein 编辑距离。
fn levenshtein(a: &[char], b: &[char]) -> usize {
    if a.is_empty() {
        return b.len();
    }
    let mut prev: Vec<usize> = (0..=b.len()).collect();
    let mut cur = vec![0usize; b.len() + 1];
    for (i, ca) in a.iter().enumerate() {
        cur[0] = i + 1;
        for (j, cb) in b.iter().enumerate() {
            let sub = prev[j] + usize::from(ca != cb);
            cur[j + 1] = (prev[j + 1] + 1).min(cur[j] + 1).min(sub);
        }
        std::mem::swap(&mut prev, &mut cur);
    }
    prev[b.len()]
}

/// `small` 是否作为连续子序列出现在 `big` 里。
fn contains_seq(big: &[char], small: &[char]) -> bool {
    !small.is_empty() && small.len() <= big.len() && big.windows(small.len()).any(|w| w == small)
}

/// 单个「查询串 × 候选标题」的相似度,0~1。与脚本无关。
fn similarity(query: &str, title: &str) -> f64 {
    let (q, t) = (norm_chars(query), norm_chars(title));
    if q.is_empty() || t.is_empty() {
        return 0.0;
    }
    if q == t {
        return 1.0;
    }
    let maxl = q.len().max(t.len());
    let mut ratio = 1.0 - levenshtein(&q, &t) as f64 / maxl as f64;
    // 包含:短串整个落在长串里。按长度占比给下限 —— 占比越高越可信,
    // 「赛马娘」在「赛马娘 Pretty Derby」里(3/16)和「刀」在「刀剑神域」里(1/4)
    // 不该拿同一个分。等长时趋近 1.0,极短子串只到 0.6 出头。
    let (short, long_) = if q.len() <= t.len() { (&q, &t) } else { (&t, &q) };
    if contains_seq(long_, short) {
        let floor = 0.6 + 0.4 * (short.len() as f64 / long_.len() as f64);
        ratio = ratio.max(floor);
    }
    ratio.clamp(0.0, 1.0)
}

fn season_re() -> &'static Regex {
    static RE: OnceLock<Regex> = OnceLock::new();
    RE.get_or_init(|| {
        Regex::new(
            r"(?i)第\s*[一二三四五六七八九十两0-9]+\s*[季期部]|\bseason\s*[0-9]+\b|\b[0-9]+(?:st|nd|rd|th)\s+season\b",
        )
        .unwrap()
    })
}

/// 从标题里读出季号。读不出来(没有任何季号标记)返回 None —— 调用方按第一季看待。
///
/// 这是**独立于标题相似度**的一路信号,而且比相似度硬:
/// 「孤独摇滚」和「孤独摇滚 第二季」在剥掉季号后是同一个串,相似度分不开;
/// 但季号一对,谁是谁立刻清楚。以前没有这一路 —— 第二季的片配上第一季的弹幕,
/// 从头到尾对不上,而且**不报错**,看起来就像「弹幕匹配得不准」。
fn season_of(title: &str) -> Option<i64> {
    let m = season_re().find(title)?;
    let raw = m.as_str();
    if let Some(d) = digits_re().find(raw) {
        return d.as_str().parse().ok();
    }
    cjk_number(raw)
}

/// 「二」「十」「十二」「二十一」→ 2 / 10 / 12 / 21。读不出来返回 None。
fn cjk_number(s: &str) -> Option<i64> {
    const DIGITS: [(char, i64); 11] = [
        ('零', 0), ('一', 1), ('两', 2), ('二', 2), ('三', 3), ('四', 4),
        ('五', 5), ('六', 6), ('七', 7), ('八', 8), ('九', 9),
    ];
    let val = |c: char| DIGITS.iter().find(|(d, _)| *d == c).map(|(_, v)| *v);
    let chars: Vec<char> = s.chars().filter(|c| val(*c).is_some() || *c == '十').collect();
    if chars.is_empty() {
        return None;
    }
    // 「十」「十N」「N十」「N十M」四种写法,别的(百/千)动漫季号里不存在。
    let n = match chars.iter().position(|c| *c == '十') {
        None => val(chars[0])?,
        Some(i) => {
            let tens = if i == 0 { 1 } else { val(chars[i - 1])? };
            let ones = chars.get(i + 1).copied().and_then(val).unwrap_or(0);
            tens * 10 + ones
        }
    };
    Some(n)
}

/// 季号一致性的加减分。
///
/// 想要的季号优先取**标题自己带的**:媒体库有两种摆法 ——
///   A. 一部剧一个条目、季在里面 → series_name="孤独摇滚",season_no=2
///   B. 每季各一个条目          → series_name="孤独摇滚 第二季",season_no=1
/// 只认 season_no 的话,B 这种摆法会把正确的「第二季」候选判成错季直接压死。
fn season_term(input: &MatchInput, candidate_title: &str) -> f64 {
    let Some(want) = season_of(&input.title).or(input.season_no) else {
        return 0.0; // 不知道要第几季 → 这一路不表态
    };
    let got = season_of(candidate_title).unwrap_or(1);
    if want == got {
        0.15
    } else {
        -0.35
    }
}

/// 剥掉季号与副标题,留下「主名」。**只用于扩大召回**,不参与算分 ——
/// 所以它宽一点也不会造成错配,最多是多捞几个候选回来让评分去筛。
///
/// 长标题会把弹弹Play 的全文检索呛住:带季号、带破折号副标题的整串搜出来常常是 0 条,
/// 而只搜主名就有。参考实现(matcher_http.c 的 core-name recall pass)也是这么干的。
fn core_name(title: &str) -> String {
    static SUB: OnceLock<Regex> = OnceLock::new();
    let sub = SUB.get_or_init(|| {
        // -副标题- / ～副标题～ / (副标题) /(副标题)/ [副标题] / :副标题 / :副标题
        Regex::new(r"\s*[-–—]\s*[^-–—]*[-–—]\s*$|\s*[～~][^～~]*[～~]\s*$|\s*[（(\[][^）)\]]*[）)\]]\s*|\s*[:：].*$")
            .unwrap()
    });
    let no_season = season_re().replace_all(title, " ");
    sub.replace_all(no_season.trim(), "").trim().to_string()
}

/// 标题相似度 0~1:拿**所有已知的查询写法**去比候选的标题,取最好的那个。
///
/// 「所有写法」= 主标题 + alt_titles(原名/真实文件名/条目名,由宿主装)。
/// 这是 bangumi2anibt README 里那句「数据库本身就是平行语料」的镜像 ——
/// 弹弹Play 的条目只有一个标题(没有别名表),平行语料在**我们这边**:
/// 媒体库同时握着中文名、原名和发布文件名。谁都可能是能对上的那一个,所以全试。
fn title_score(input: &MatchInput, candidate: &str) -> f64 {
    std::iter::once(input.title.as_str())
        .chain(input.alt_titles.iter().map(String::as_str))
        .filter(|s| !s.trim().is_empty())
        .map(|q| similarity(q, candidate))
        .fold(0.0, f64::max)
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

    fn q(title: &str) -> MatchInput {
        MatchInput { title: title.into(), ..Default::default() }
    }

    #[test]
    fn title_score_forms() {
        // 完全相等(标点/大小写/空白差异被归一化抹平)。
        assert_eq!(title_score(&q("葬送的芙莉莲"), "葬送的芙莉莲"), 1.0);
        assert_eq!(
            title_score(&q("Frieren: Beyond Journey's End"), "frieren beyond journey's end"),
            1.0
        );
        // 「第N季/部」被剥掉 → 与无季号标题相等(季号由 season_term 单独判,不混进相似度)。
        assert_eq!(title_score(&q("孤独摇滚 第二季"), "孤独摇滚"), 1.0);
        assert_eq!(title_score(&q("间谍过家家 第2部"), "间谍过家家"), 1.0);
        // 包含关系 → 按长度占比给下限,不再一律 0.7。
        let s = title_score(&q("赛马娘"), "赛马娘 Pretty Derby");
        assert!((0.6..0.8).contains(&s), "短串落在长串里应偏低, got {s}");
        // 无交集 → 低分。
        let s = title_score(&q("葬送的芙莉莲"), "咒术回战");
        assert!(s < 0.3, "无关标题不该高分, got {s}");
        // 空串 → 0。
        assert_eq!(title_score(&q(""), "x"), 0.0);
        assert_eq!(title_score(&q("x"), ""), 0.0);
        assert_eq!(title_score(&q("A"), "A"), 1.0);
    }

    /* 新口径必须能做到旧的二元组 Jaccard 做不到的事。
       反向验证:把 similarity 换回原来的 bigram Jaccard×0.6,下面每一条都会红 ——
       它的天花板就是 0.6,而自动挂载门槛是 0.5,一个字之差和毫不相干挤在同一个窄区间里。 */
    #[test]
    fn similarity_beats_the_old_bigram_jaccard() {
        // ① 差一两个字的标题必须明显高于门槛(旧算法:交集/并集×0.6,到不了 0.8)。
        let s = similarity("葬送的芙莉莲", "葬送之芙莉莲");
        assert!(s > 0.8, "一字之差应仍高度相似, got {s}");
        // ② 全角 / 大小写 / 标点差异要被折叠掉(旧算法把全角当完全不同的字符)。
        assert_eq!(similarity("ＳＰＹ×ＦＡＭＩＬＹ", "SPY×FAMILY"), 1.0);
        // ×(U+00D7)和字母 x 是**两个字符**,不该折成一个 —— 但一字之差仍要高分。
        let s = similarity("ＳＰＹ×ＦＡＭＩＬＹ", "SPY x FAMILY");
        assert!(s > 0.85, "全角折叠后只该剩 ×/x 这一处差异, got {s}");
        assert_eq!(similarity("Fate/stay night", "fate stay night"), 1.0);
        // ③ 片假名 / 平假名同形(mpv 之外的库常见混用)。
        assert_eq!(similarity("フリーレン", "ふりーれん"), 1.0);
        // ④ 长度占比要影响包含分:整段占满的比零头的高。
        let big = similarity("赛马娘 Pretty Derby", "赛马娘 Pretty Derby S");
        let small = similarity("刀", "刀剑神域");
        assert!(big > small + 0.2, "包含分必须看长度占比, big={big} small={small}");
        // ⑤ 真正不相干的仍然要低。
        assert!(similarity("葬送的芙莉莲", "间谍过家家") < 0.3);
    }

    /* 季号是一路**独立于标题相似度**的信号。剥掉季号后「孤独摇滚」和
       「孤独摇滚 第二季」的相似度完全一样 —— 没有这一路,第二季的片会配上第一季的弹幕,
       而且不报错。反向验证:让 season_term 恒返回 0.0,下面的断言立刻红。 */
    #[test]
    fn season_signal_separates_same_named_cours() {
        assert_eq!(season_of("孤独摇滚 第二季"), Some(2));
        assert_eq!(season_of("咒术回战 第2季"), Some(2));
        assert_eq!(season_of("某作品 第十二期"), Some(12));
        assert_eq!(season_of("Re:Zero Season 3"), Some(3));
        assert_eq!(season_of("Bocchi the Rock 2nd Season"), Some(2));
        assert_eq!(season_of("孤独摇滚"), None, "没有季号标记就是没有,别瞎猜");

        // 摆法 A:一部剧一个条目,季号在 season_no 上。
        let a = MatchInput { title: "孤独摇滚".into(), season_no: Some(2), ..Default::default() };
        assert!(season_term(&a, "孤独摇滚 第二季") > 0.0, "对季要加分");
        assert!(season_term(&a, "孤独摇滚") < 0.0, "错季要扣分");

        // 摆法 B:每季各一个条目,季号写在标题里而 season_no 恒为 1。
        // 只认 season_no 的话会把正确的「第二季」候选判成错季压死 —— 这条钉的就是那个坑。
        let b = MatchInput { title: "孤独摇滚 第二季".into(), season_no: Some(1), ..Default::default() };
        assert!(season_term(&b, "孤独摇滚 第二季") > 0.0, "标题自带的季号优先于 season_no");
        assert!(season_term(&b, "孤独摇滚") < 0.0);

        // 完全不知道季号 → 这一路不表态,不许凭空加减。
        let c = q("某剧场版");
        assert_eq!(season_term(&c, "某剧场版 第三季"), 0.0);
    }

    /* alt_titles = 我们这边的平行语料。弹弹Play 条目只有一个标题,
       库里是中文名而它收的是日文名时,单靠 title 一路恒为 0 分 ——
       候选明明捞回来了却被自己的评分扔掉。反向验证:去掉 title_score 里的 chain,本测试红。 */
    #[test]
    fn alt_titles_carry_cross_language_matches() {
        let cn_only = q("葬送的芙莉莲");
        assert!(title_score(&cn_only, "葬送のフリーレン") < 0.5, "跨语种字面上就是对不上的");
        let with_alt = MatchInput {
            title: "葬送的芙莉莲".into(),
            alt_titles: vec!["葬送のフリーレン".into(), "Sousou no Frieren".into()],
            ..Default::default()
        };
        assert_eq!(title_score(&with_alt, "葬送のフリーレン"), 1.0, "换个写法就该对上");
        assert_eq!(title_score(&with_alt, "葬送的芙莉莲"), 1.0, "主标题这一路不能因此变差");
    }

    /* 主名召回:长标题会把全文检索呛住,只搜主名反而有。
       剥的是「季号 + 副标题」,而且**只用于扩大召回**,不参与算分。 */
    #[test]
    fn core_name_strips_season_and_subtitle() {
        assert_eq!(core_name("克雷瓦提斯 第二季 -魔兽之王与虚伪的勇者传承-"), "克雷瓦提斯");
        assert_eq!(core_name("某作品 第3季"), "某作品");
        assert_eq!(core_name("鬼灭之刃:锻刀村篇"), "鬼灭之刃");
        assert_eq!(core_name("总之就是非常可爱(第二季)"), "总之就是非常可爱");
        // 没有可剥的就原样返回 —— 不能把正常标题剥没了。
        assert_eq!(core_name("间谍过家家"), "间谍过家家");
    }

    #[test]
    fn normalize_strips_punct_and_season() {
        assert_eq!(normalize("Re：从零开始的异世界生活 第二季"), "re从零开始的异世界生活");
        assert_eq!(normalize("[Sub] Title (2024)!"), "subtitle2024");
    }

    /* `/match` 的 fileHash 必须是形状合法的 32 位 hex,空串会被服务端判
       `errorCode:2 参数不符合规则`,整条「文件识别」路作废(而且静默)。
       2026-08-01 真接口 A/B 实测过:占位 hash 一给,同一请求就从 0 条变 25 条。 */
    #[test]
    fn file_hash_is_always_well_formed() {
        let h = normalized_file_hash(None, "葬送的芙莉莲 S01E01.mkv");
        assert_eq!(h.len(), 32);
        assert!(h.bytes().all(|b| b.is_ascii_hexdigit()));
        // 同名恒定 —— 跨会话稳定,服务端那边才能命中同一条缓存。
        assert_eq!(h, normalized_file_hash(Some(""), "葬送的芙莉莲 S01E01.mkv"));
        assert_ne!(h, normalized_file_hash(None, "别的片.mkv"));
        // 调用方给了真 hash 就原样用(大小写归一),绝不覆盖。
        let real = "ABCDEF0123456789ABCDEF0123456789";
        assert_eq!(normalized_file_hash(Some(real), "x"), real.to_lowercase());
        // 形状不对的(长度不够 / 非 hex)一律当没给。
        assert_eq!(normalized_file_hash(Some("abc"), "x"), normalized_file_hash(None, "x"));
        assert_eq!(normalized_file_hash(Some(&"z".repeat(32)), "x"), normalized_file_hash(None, "x"));
    }

    /* 弹弹Play 系接口从不用 HTTP 状态码报错,一律 200 + body 里的 errorCode。
       不看它 → 配额用尽/参数非法/签名错全都长得跟「这个关键词没搜到」一模一样。
       2026-08-01 实测两个 search 端点全部回 429「已达到接口调用配额上限」,
       而界面上写的是「未找到匹配的弹幕」—— 界面在撒谎。 */
    #[test]
    fn api_error_code_is_not_swallowed() {
        let quota = serde_json::json!({"errorCode":429,"errorMessage":"已达到接口调用配额上限","animes":[]});
        let err = check_api_error(&quota).unwrap_err();
        assert!(err.contains("配额"), "得把服务端给的原因原样带出来, got {err}");
        assert!(err.contains("429"));
        // 参数非法(fileHash 为空时 /match 回的就是这个)。
        assert!(check_api_error(&serde_json::json!({"errorCode":2,"errorMessage":"一个或多个参数不符合规则"})).is_err());
        // 正常响应不能被误判成错误。
        assert!(check_api_error(&serde_json::json!({"errorCode":0,"animes":[]})).is_ok());
        assert!(check_api_error(&serde_json::json!({"animes":[]})).is_ok(), "自建源可能压根没这个字段");
        // 没给 errorMessage 也要能说出个所以然。
        assert!(check_api_error(&serde_json::json!({"errorCode":500})).unwrap_err().contains("500"));
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
