// Bangumi 同步内核 —— 迁自 Dart bangumi_sync_service.dart。
// 授权码(浏览器授权后手动粘贴 code)登录 + 令牌刷新 + 收藏/单集进度写入 + 追番日历。
// 换/刷令牌走已部署 CF 代理;其余直连 Bangumi(默认国内加速反代,官方常慢/不通)。
//
// ponytail: 反代/官方切换在 Dart 是 prefs 开关,PoC 默认反代(与 Dart 默认一致);切官方待前端补。

use serde_json::Value;

use super::calendar::CalendarEntry;
use super::{
    bangumi_app_id, proxy_headers, use_sync_proxy, SyncAccount, BANGUMI_API_OFFICIAL,
    BANGUMI_IMG_MIRROR, BANGUMI_OAUTH_OFFICIAL, SYNC_PROXY_BASE,
};

// 用户 2026-07-16:「bangumi 的 api 地址用回官方,图片还是走 anibt 反代」——
// anibt 的 API 反代过不了 CF,官方 api.bgm.tv 没问题;图片则相反(官方 lain 国内不通,anibt 图片反代通)。
const API_BASE: &str = BANGUMI_API_OFFICIAL;
pub const DEFAULT_REDIRECT_URI: &str = "https://291277.xyz/oauth/bangumi";

/* ================= 放送时刻(bangumi-data) =================
   ★ 为什么要引外部数据集:Bangumi 官方 API **根本不提供放送时刻**。实测(2026-07-16):
     - `/calendar` 条目只有 `air_date`("2026-07-06",**日期无时刻**)与 `air_weekday`;
     - subject 详情的完整 infobox 也只有「放送开始/放送星期/播放电视台」,**没有任何 hh:mm**。
   用 air_date 硬凑会显示成 00:00 那种假时间 —— 不做。
   bangumi-data(社区数据集)有 RFC5545 的 `broadcast`,且条目自带 `sites[].site=="bangumi"` 的
   subject id,能和 /calendar **精确对上**(不靠标题模糊匹配)。
   实测本周覆盖率 72/111 ≈ 64%:没覆盖到的条目不显示时刻,保持空白,不编。 */

const BANGUMI_DATA_URL: &str = "https://unpkg.com/bangumi-data@0.3/dist/data.json";
/// 派生索引的磁盘缓存 TTL(数据集更新不频繁,一周足够)。
const BROADCAST_TTL_SECS: u64 = 7 * 24 * 3600;

/// 进程内缓存:避免每次开日历都读盘/重拉。
static BROADCAST_IDX: tokio::sync::OnceCell<std::collections::HashMap<String, String>> =
    tokio::sync::OnceCell::const_new();

fn broadcast_cache_path() -> std::path::PathBuf {
    crate::paths::cache_root().join("bangumi_broadcast.json")
}

/// `"R/2026-07-06T14:30:00.000Z/P7D"` → `"2026-07-06T14:30:00.000Z"`(重复间隔的起始时刻)。
/// 只认 `R/<起始>/<周期>` 这一种形状;取不出就 None。
fn broadcast_start(b: &str) -> Option<String> {
    let mut parts = b.split('/');
    if parts.next()? != "R" {
        return None;
    }
    let start = parts.next()?.trim();
    if start.is_empty() {
        return None;
    }
    Some(start.to_string())
}

/// 拉 bangumi-data(约 7.4MB)→ **只留 id→broadcast 起始时刻的小索引**(约 1800 条)→ 写盘。
/// 下次直接读那份小缓存,不再拉大文件。
async fn build_broadcast_index() -> std::collections::HashMap<String, String> {
    let path = broadcast_cache_path();
    // 1) 磁盘缓存未过期就用它
    if let Ok(meta) = std::fs::metadata(&path) {
        let fresh = meta
            .modified()
            .ok()
            .and_then(|m| m.elapsed().ok())
            .map(|e| e.as_secs() < BROADCAST_TTL_SECS)
            .unwrap_or(false);
        if fresh {
            if let Ok(txt) = std::fs::read_to_string(&path) {
                if let Ok(m) = serde_json::from_str::<std::collections::HashMap<String, String>>(&txt) {
                    return m;
                }
            }
        }
    }
    // 2) 拉数据集并建索引
    let mut map = std::collections::HashMap::new();
    let fetched = async {
        let txt = crate::http::client()
            .get(BANGUMI_DATA_URL)
            .send()
            .await
            .ok()?
            .text()
            .await
            .ok()?;
        serde_json::from_str::<Value>(&txt).ok()
    }
    .await;
    if let Some(j) = fetched {
        if let Some(items) = j["items"].as_array() {
            for it in items {
                let Some(start) = it["broadcast"].as_str().and_then(broadcast_start) else {
                    continue;
                };
                let Some(sites) = it["sites"].as_array() else { continue };
                for s in sites {
                    if s["site"].as_str() == Some("bangumi") {
                        if let Some(id) = s["id"].as_str() {
                            map.insert(id.to_string(), start.clone());
                        }
                    }
                }
            }
        }
    }
    // 3) 写盘(拉失败 map 为空:不写,免得把空索引缓存一周)
    if !map.is_empty() {
        if let Some(dir) = path.parent() {
            let _ = std::fs::create_dir_all(dir);
        }
        if let Ok(txt) = serde_json::to_string(&map) {
            let _ = std::fs::write(&path, txt);
        }
    } else if let Ok(txt) = std::fs::read_to_string(&path) {
        // 拉失败但有过期缓存 → 用旧的,总比没时间强。
        if let Ok(m) = serde_json::from_str::<std::collections::HashMap<String, String>>(&txt) {
            return m;
        }
    }
    map
}

async fn broadcast_index() -> &'static std::collections::HashMap<String, String> {
    BROADCAST_IDX.get_or_init(build_broadcast_index).await
}

/// 把官方图片地址(//lain.bgm.tv/… 或 https://lain.bgm.tv/…)改写到 anibt 图片反代。
/// 协议相对的补上 https,顺带 api.bgm.tv 上的图片路径也一并改。
fn mirror_image(u: &str) -> Option<String> {
    let u = u.trim();
    if u.is_empty() {
        return None;
    }
    let full = if let Some(rest) = u.strip_prefix("//") {
        format!("https://{rest}")
    } else {
        u.to_string()
    };
    Some(
        full.replace("https://lain.bgm.tv", BANGUMI_IMG_MIRROR)
            .replace("http://lain.bgm.tv", BANGUMI_IMG_MIRROR)
            .replace("https://api.bgm.tv", BANGUMI_IMG_MIRROR)
            .replace("http://api.bgm.tv", BANGUMI_IMG_MIRROR),
    )
}

fn now_ms() -> i64 {
    use std::time::{SystemTime, UNIX_EPOCH};
    SystemTime::now().duration_since(UNIX_EPOCH).map(|d| d.as_millis() as i64).unwrap_or(0)
}

/// 构造授权页 URL(用户浏览器打开授权,拿回 code 粘贴)。
/// ★ 授权页在 bgm.tv 主站,不在 api.bgm.tv —— API 切官方后授权必须独立指到 OAuth 主站,
/// 否则 /oauth/authorize 打到 api 子域 404。code 换 token 仍走 CF 代理注入 secret。
pub fn build_authorize_url(redirect_uri: &str) -> String {
    format!(
        "{BANGUMI_OAUTH_OFFICIAL}/oauth/authorize?client_id={}&response_type=code&redirect_uri={}",
        urlencoding::encode(&bangumi_app_id()),
        urlencoding::encode(redirect_uri)
    )
}

/// 用授权码换令牌(走代理)。
pub async fn exchange_code(code: &str, redirect_uri: &str) -> Result<SyncAccount, String> {
    if !use_sync_proxy() {
        return Err("未配置同步代理".into());
    }
    let mut req = crate::http::client()
        .post(format!("{SYNC_PROXY_BASE}/bangumi/token"))
        .json(&serde_json::json!({ "code": code.trim(), "redirect_uri": redirect_uri }));
    for (k, v) in proxy_headers() {
        req = req.header(k, v);
    }
    let resp = req.send().await.map_err(|e| e.to_string())?;
    if !resp.status().is_success() {
        return Err(format!("Bangumi 令牌交换失败: HTTP {}", resp.status().as_u16()));
    }
    let tok: Value = resp.json().await.map_err(|e| e.to_string())?;
    Ok(account_from_token(&tok, None).await)
}

/// 用**个人访问令牌**登录(https://next.bgm.tv/demo/access-token 自助生成)。
/// 与授权码流的区别:没有 refresh_token,过期时间由 Bangumi 侧决定(通常一年),
/// 客户端不做刷新 —— 过期后用户重新生成一个粘进来即可。
/// 好处是完全不经 CF 代理,代理挂了/共享密钥轮换也能登录。
pub async fn login_with_access_token(token: &str) -> Result<SyncAccount, String> {
    let token = token.trim();
    if token.is_empty() {
        return Err("请填写 Access Token".into());
    }
    // 立刻打一次 /v0/me 验证令牌真的有效,别把一个废令牌存进配置里。
    let (name, uid) = fetch_profile(token)
        .await
        .ok_or("Access Token 无效或已过期(Bangumi 未返回用户信息)")?;
    Ok(SyncAccount {
        service: "bangumi".into(),
        access_token: token.to_string(),
        refresh_token: None,
        expires_at: None, // 不主动过期;真过期了 API 会 401,用户重新贴一个
        username: name,
        user_id: uid,
    })
}

/// 刷新令牌(走代理)。失败 None。
pub async fn refresh(account: &SyncAccount, redirect_uri: &str) -> Option<SyncAccount> {
    let rt = account.refresh_token.as_deref().filter(|s| !s.is_empty())?;
    if !use_sync_proxy() {
        return None;
    }
    let mut req = crate::http::client()
        .post(format!("{SYNC_PROXY_BASE}/bangumi/refresh"))
        .json(&serde_json::json!({ "refresh_token": rt, "redirect_uri": redirect_uri }));
    for (k, v) in proxy_headers() {
        req = req.header(k, v);
    }
    let resp = req.send().await.ok()?;
    if !resp.status().is_success() {
        return None;
    }
    let tok: Value = resp.json().await.ok()?;
    Some(account_from_token(&tok, Some(account)).await)
}

pub async fn ensure_valid(account: &SyncAccount) -> Option<SyncAccount> {
    if !account.is_expired(now_ms()) {
        return Some(account.clone());
    }
    refresh(account, DEFAULT_REDIRECT_URI).await
}

fn build_account(tok: &Value, fallback: Option<&SyncAccount>) -> SyncAccount {
    let access = tok["access_token"]
        .as_str()
        .map(String::from)
        .or_else(|| fallback.map(|f| f.access_token.clone()))
        .unwrap_or_default();
    let expires_at = tok["expires_in"]
        .as_i64()
        .map(|e| now_ms() + e * 1000)
        .or_else(|| fallback.and_then(|f| f.expires_at));
    SyncAccount {
        service: "bangumi".into(),
        access_token: access,
        refresh_token: tok["refresh_token"]
            .as_str()
            .map(String::from)
            .or_else(|| fallback.and_then(|f| f.refresh_token.clone())),
        expires_at,
        username: fallback.and_then(|f| f.username.clone()),
        user_id: tok["user_id"]
            .as_str()
            .map(String::from)
            .or_else(|| fallback.and_then(|f| f.user_id.clone())),
    }
}

async fn account_from_token(tok: &Value, fallback: Option<&SyncAccount>) -> SyncAccount {
    let mut account = build_account(tok, fallback);
    if !account.access_token.is_empty() && account.username.is_none() {
        if let Some((name, uid)) = fetch_profile(&account.access_token).await {
            account.username = name;
            if account.user_id.is_none() {
                account.user_id = uid;
            }
        }
    }
    account
}

async fn fetch_profile(access: &str) -> Option<(Option<String>, Option<String>)> {
    let resp = crate::http::client()
        .get(format!("{API_BASE}/v0/me"))
        .header("Authorization", format!("Bearer {access}"))
        .send()
        .await
        .ok()?;
    if !resp.status().is_success() {
        return None;
    }
    let j: Value = resp.json().await.ok()?;
    let name = j["nickname"].as_str().or_else(|| j["username"].as_str()).map(String::from);
    Some((name, j["id"].as_str().map(String::from).or_else(|| j["id"].as_i64().map(|n| n.to_string()))))
}

/// 条目收藏端点(POST 新增/覆盖)。
fn collection_endpoint(subject_id: i64) -> String {
    format!("{API_BASE}/v0/users/-/collections/{subject_id}")
}

/// 章节收藏**批量**端点(PATCH)。
/// ★ 2026-08-01:原来「点格子」打的是 `/v0/users/-/collections/{subject_id}/episodes/{episode_id}`
/// —— 这个路径在 Bangumi **根本不存在**(官方 openapi 实证):单集写入是
/// `PUT /v0/users/-/collections/-/episodes/{episode_id}`(subject 位是字面 `-`),
/// 带 subject_id 的只有批量的 `PATCH .../{subject_id}/episodes`。
/// 于是那一发永远 404、`is_success()` 恒 false,还被 `-> bool` 吞掉了原因 ——
/// 这就是「只有『在看』能成、点格子返回 false」的直接根因(在看走的是上面那个正确端点)。
/// 选批量 PATCH 而不是单集 PUT:两个参数都用得上,且官方明确它会**重算条目完成度**
/// (单集 PUT 没这句),用户要的「Bangumi 那边标记看过」包含进度跟着走。
fn episodes_endpoint(subject_id: i64) -> String {
    format!("{API_BASE}/v0/users/-/collections/{subject_id}/episodes")
}

/// 把响应折成 Result:成功 Ok,失败带上状态码和响应体前 200 字。
/// ★ 别再返回裸 bool —— 上一版就是因为 false 不带原因,一个 404 路径活了几个月没人看见。
async fn check(resp: reqwest::Result<reqwest::Response>, what: &str) -> Result<(), String> {
    let resp = resp.map_err(|e| format!("{what}: 请求失败 {e}"))?;
    let code = resp.status();
    if code.is_success() {
        return Ok(());
    }
    let body: String = resp.text().await.unwrap_or_default().chars().take(200).collect();
    Err(format!("{what}: HTTP {} {}", code.as_u16(), body.trim()))
}

/// 设置条目收藏状态(type: 1=想看 2=看过 3=在看 4=搁置 5=抛弃)。
/// 更新单集进度前必须先确保条目已收藏,否则未收藏的番更新单集会失败。
pub async fn set_collection_type(
    account: &SyncAccount,
    subject_id: i64,
    type_: i32,
) -> Result<(), String> {
    let valid = ensure_valid(account).await.ok_or("Bangumi 令牌已过期且刷新失败")?;
    let resp = crate::http::client()
        .post(collection_endpoint(subject_id))
        .header("Authorization", format!("Bearer {}", valid.access_token))
        .json(&serde_json::json!({ "type": type_ }))
        .send()
        .await;
    check(resp, "设置收藏状态").await
}

/// 更新单集观看状态(type: 0=撤销 1=想看 2=看过 3=抛弃)。
pub async fn update_episode_status(
    account: &SyncAccount,
    subject_id: i64,
    episode_id: i64,
    type_: i32,
) -> Result<(), String> {
    let valid = ensure_valid(account).await.ok_or("Bangumi 令牌已过期且刷新失败")?;
    let resp = crate::http::client()
        .patch(episodes_endpoint(subject_id))
        .header("Authorization", format!("Bearer {}", valid.access_token))
        .json(&serde_json::json!({ "episode_id": [episode_id], "type": type_ }))
        .send()
        .await;
    check(resp, "标记单集看过").await
}

/// 单个 subject 的简介。**按需拉**,不在放送表里做。
///
/// ## 为什么不在 fetch_anime_calendar 里一次拉好
/// 2026-07-16 实测:`/calendar` 的 summary 字段整周 111 条**全是空串**(字段在、值不给),
/// 真简介只在 `/v0/subjects/{id}` —— 一周 111 部就是 111 次请求,压在放送表加载路径上
/// 会把整页拖到几秒。而聚焦视图**一次只看一条**,按需拉才是对的量级。
///
/// ## 缓存
/// 进程内 Map,只增不删:简介是静态文案,一个 session 里同一部拉一次就够;
/// 用户在聚焦视图里来回滚时,滚回来必须是**瞬时**的,不能每次都重发请求。
/// 条数上限就是放送表的番剧数(百量级),不会涨爆。
static SUMMARY_CACHE: std::sync::OnceLock<std::sync::Mutex<std::collections::HashMap<i64, String>>> =
    std::sync::OnceLock::new();

pub async fn fetch_subject_summary(subject_id: i64) -> Option<String> {
    let cache = SUMMARY_CACHE.get_or_init(Default::default);
    // ★ 锁不能跨 await(见 [[prefetch-proxy-deadlock]]):查完立刻放,别把 guard 带进请求。
    if let Some(hit) = cache.lock().unwrap().get(&subject_id).cloned() {
        return Some(hit);
    }
    let url = format!("{API_BASE}/v0/subjects/{subject_id}");
    // UA 不用自己带:http::client() 已统一设了(见 http.rs::user_agent)。
    let resp = crate::http::client()
        .get(&url)
        .header("Accept", "application/json")
        .send()
        .await
        .ok()?;
    if !resp.status().is_success() {
        return None;
    }
    let j = resp.json::<Value>().await.ok()?;
    let s = j["summary"].as_str().map(str::trim).filter(|s| !s.is_empty())?;
    cache.lock().unwrap().insert(subject_id, s.to_string());
    Some(s.to_string())
}

/// 追番日历:当季放送表按每周放送日归组。only_mine=只保留我在看的番。
/// ★ 用户 2026-07-16:「哪怕不登录、选了不看我追的,也要出正常每周放送表」。
/// /calendar 是公开端点,不需要 token —— 故 only_mine=false 时**跳过账号校验**直接公开拉取;
/// 只有 only_mine=true(个性化「我追的」)才要求已登录并读在看集合。
pub async fn fetch_anime_calendar(account: &SyncAccount, only_mine: bool) -> Vec<CalendarEntry> {
    let client = crate::http::client();

    // 1) 只看我追的:先取在看动画(subject_type=2,type=3)的 subject id 集合(需登录)。
    let mut watching = std::collections::HashSet::new();
    if only_mine {
        let Some(valid) = ensure_valid(account).await else {
            return vec![];
        };
        let col = client
            .get(format!("{API_BASE}/v0/users/-/collections"))
            .header("Authorization", format!("Bearer {}", valid.access_token))
            .query(&[("subject_type", "2"), ("type", "3"), ("limit", "50")])
            .send()
            .await;
        if let Ok(r) = col {
            if let Ok(j) = r.json::<Value>().await {
                if let Some(arr) = j["data"].as_array() {
                    for it in arr {
                        if let Some(id) = it["subject_id"].as_i64() {
                            watching.insert(id);
                        }
                    }
                }
            }
        }
        if watching.is_empty() {
            return vec![];
        }
    }

    // 2) 当季放送表(onlyMine 时过滤出在看的)。
    let Ok(resp) = client.get(format!("{API_BASE}/calendar")).send().await else {
        return vec![];
    };
    let Ok(Value::Array(groups)) = resp.json::<Value>().await else {
        return vec![];
    };
    // 放送时刻索引(Bangumi 官方无此数据,见上方 bangumi-data 段注释)。取不到就整体没时刻,不影响放送表。
    let bcast = broadcast_index().await;
    let mut out = Vec::new();
    for group in groups {
        let weekday = group["weekday"]["id"].as_i64().map(|w| w as i32);
        let Some(items) = group["items"].as_array() else {
            continue;
        };
        for item in items {
            let Some(id) = item["id"].as_i64() else { continue };
            if only_mine && !watching.contains(&id) {
                continue;
            }
            let name_cn = item["name_cn"].as_str().filter(|s| !s.is_empty());
            let title = name_cn
                .or_else(|| item["name"].as_str())
                .unwrap_or("未知番剧")
                .to_string();
            // ★ 优先 large:Bangumi 的 common 是小缩略图,放在卡片上发虚(用户 2026-07-16「好模糊」)。
            let img = ["large", "common", "medium"]
                .iter()
                .find_map(|k| item["images"][k].as_str())
                .and_then(mirror_image);
            // 0 分 = 没人评过(新番常见),不是「这片 0 分」 —— 滤掉,别让前端画出诽谤。
            let rating = item["rating"]["score"].as_f64().filter(|r| *r > 0.0);
            /* /calendar 也有个 summary 字段,但 2026-07-16 实测**整周 111 条全是空串** ——
               字段在、值不给。这里仍读一次:真给了就白捡,不给也不额外发请求。
               真简介在 /v0/subjects/{id},由 bangumi_summary 命令按需拉(见 CalendarEntry.summary)。 */
            let summary = item["summary"]
                .as_str()
                .map(str::trim)
                .filter(|s| !s.is_empty())
                .map(str::to_string);
            out.push(CalendarEntry {
                title,
                // 以前这里塞的是 format!("评分 {r}") —— 拿副标题位存评分。现在评分有自己的字段。
                subtitle: None,
                // air_date 保持 None:Bangumi 的 air_date 是**首播日**,不是本周这一集的日期 ——
                // 传上去前端会拿它去和本周日期比对,比不上就整条丢掉,放送表直接空。用 weekday 归组才对。
                air_date: None,
                weekday,
                broadcast_at: bcast.get(&id.to_string()).cloned(),
                image_url: img,
                tmdb_id: None,
                rating,
                summary,
                bangumi_id: Some(id),
                source: "bangumi".into(),
            });
        }
    }
    out
}

#[cfg(test)]
mod tests {
    use super::*;

    /// broadcast 解析:样本取自 bangumi-data 真实数据(2026-07 档实拉)。
    /// 解错会静默显示成错误的更新时间 —— 比不显示更坏,故钉住。
    #[test]
    fn broadcast_start_parses_rfc5545_repeat() {
        assert_eq!(
            broadcast_start("R/2026-07-06T14:30:00.000Z/P7D").as_deref(),
            Some("2026-07-06T14:30:00.000Z")
        );
        // 非 R/ 重复间隔、缺段、空 → None(宁可不显示,也不能猜出个时间)
        assert_eq!(broadcast_start("2026-07-06T14:30:00.000Z"), None);
        assert_eq!(broadcast_start("R/"), None);
        assert_eq!(broadcast_start(""), None);
    }

    /// 端点拼接钉死在官方 openapi 的形状上。
    /// 上一版把单集写成 `.../collections/{subject_id}/episodes/{episode_id}` —— 该路径不存在,
    /// 永远 404。这条断言就是那个 bug 的复现闸门:改回旧形状它立刻红。
    #[test]
    fn endpoints_match_official_openapi() {
        assert_eq!(collection_endpoint(303864), "https://api.bgm.tv/v0/users/-/collections/303864");
        assert_eq!(
            episodes_endpoint(303864),
            "https://api.bgm.tv/v0/users/-/collections/303864/episodes"
        );
        // 单集 id 绝不能出现在路径里(它只能进 PATCH 的 body)。
        assert!(!episodes_endpoint(303864).contains("/episodes/"));
    }

    /// 图片改写:官方 /calendar 实测回的是 **http://** 的 lain 地址(不是 https),
    /// 漏掉 http 那半就等于图片全走官方源 → 国内加载不出。
    #[test]
    fn mirror_image_rewrites_lain_to_anibt() {
        assert_eq!(
            mirror_image("http://lain.bgm.tv/pic/cover/l/ce/e2/456080_C4q4C.jpg").as_deref(),
            Some("https://bgmimg.anibt.net/pic/cover/l/ce/e2/456080_C4q4C.jpg")
        );
        assert_eq!(
            mirror_image("https://lain.bgm.tv/pic/cover/l/x.jpg").as_deref(),
            Some("https://bgmimg.anibt.net/pic/cover/l/x.jpg")
        );
        // 协议相对地址要补 https,否则 webview 里会当成相对路径
        assert_eq!(
            mirror_image("//lain.bgm.tv/pic/cover/l/x.jpg").as_deref(),
            Some("https://bgmimg.anibt.net/pic/cover/l/x.jpg")
        );
        assert_eq!(mirror_image("   "), None);
    }
}
