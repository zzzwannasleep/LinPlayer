//! LinPlayer 弹幕代理 —— 把弹弹Play 的签名从客户端挪到服务器。
//!
//! ## 它解决什么
//! 客户端里的 AppSecret 无论怎么加密都是**可提取**的(解密口令必须和密文一起发出去)。
//! 谁拿到安装包都能用我们的配额,客户端限流拦不住外人。把签名挪到服务端之后:
//!   * 密钥只在这台机器的环境变量里,客户端一个字节都拿不到;
//!   * **出站闸门**把「收到多少」和「转发多少」解耦 —— 被刷爆的后果退化成
//!     「这段时间弹幕慢」,而配额一个不掉;
//!   * **共享缓存**把上游调用量从「播放次数」塌成「不同集数 × TTL 窗口」,
//!     这一条省下来的比限流多一个数量级。
//!
//! ## 部署形态
//! 只监听回环地址,前面挂用户自己的反代(OpenResty/nginx)+ Cloudflare 橙云。
//! 本进程**不做** TLS、不做 IP 封禁、不做 DDoS 防护 —— 那三件事反代和 CF 做得比我好,
//! 在这里再写一遍只会写出一个更差的版本。

mod admin;
mod cache;
mod clients;
mod config;
mod upstream;

use axum::body::Bytes;
use axum::extract::{Path, Query, State};
use axum::http::{HeaderMap, StatusCode};
use axum::response::{IntoResponse, Response};
use axum::routing::{any, get, post};
use axum::Router;
use std::collections::BTreeMap;
use std::net::SocketAddr;
use std::path::PathBuf;
use std::sync::Arc;

pub struct App {
    pub creds: upstream::Creds,
    pub cfg: config::Store,
    pub cache: cache::Cache,
    pub clients: clients::Registry,
    pub gov: upstream::Governor,
    pub http: reqwest::Client,
    pub admin_password: String,
    pub started: i64,
}

pub type Shared = Arc<App>;

#[tokio::main]
async fn main() {
    let data_dir: PathBuf =
        std::env::var("DATA_DIR").unwrap_or_else(|_| "./data".into()).into();
    let port: u16 = std::env::var("PORT").ok().and_then(|s| s.parse().ok()).unwrap_or(8787);
    /* 只绑回环。★ 默认不对外 —— 忘了配反代的后果应该是「外面连不上」,
       而不是「一个没有 TLS、没有防护的服务直接裸奔在公网上」。
       真要直接暴露,显式设 BIND=0.0.0.0。 */
    let bind = std::env::var("BIND").unwrap_or_else(|_| "127.0.0.1".into());

    let creds = match upstream::Creds::from_env() {
        Ok(c) => c,
        Err(e) => {
            eprintln!("[致命] {e}");
            eprintln!("       需要:DANDANPLAY_APP_ID、DANDANPLAY_APP_SECRET");
            std::process::exit(2);
        }
    };
    let admin_password = std::env::var("ADMIN_PASSWORD").unwrap_or_default();
    if admin_password.len() < 8 {
        // 不给默认密码:管理界面能改出站上限和封禁,弱口令等于把闸门交出去。
        eprintln!("[致命] 需要 ADMIN_PASSWORD 环境变量(至少 8 位)");
        std::process::exit(2);
    }

    let cfg = config::Store::load(&data_dir);
    let c0 = cfg.get();
    let app = Arc::new(App {
        creds,
        cache: cache::Cache::open(data_dir.join("cache"), c0.cache_max_mb),
        clients: clients::Registry::load(&data_dir),
        cfg,
        gov: upstream::Governor::new(),
        http: reqwest::Client::builder()
            // 上游黑洞时必须自己断,否则连接一直吊着,闸门名额也一直占着。
            .timeout(std::time::Duration::from_secs(20))
            .user_agent(concat!("LinPlayerDanmakuProxy/", env!("CARGO_PKG_VERSION")))
            .build()
            .expect("构建 HTTP 客户端失败"),
        admin_password,
        started: upstream::now_secs(),
    });

    // 计数器是热路,不能每次请求都写文件;定期落盘 + 退出时再落一次。
    {
        let a = app.clone();
        tokio::spawn(async move {
            loop {
                tokio::time::sleep(std::time::Duration::from_secs(30)).await;
                a.clients.flush();
            }
        });
    }

    let router = Router::new()
        .route("/healthz", get(|| async { "ok" }))
        .route("/api/register", post(register))
        .route("/api/v2/{*rest}", any(forward))
        .merge(admin::routes())
        .with_state(app.clone());

    let addr: SocketAddr = format!("{bind}:{port}").parse().expect("BIND/PORT 不合法");
    let listener = tokio::net::TcpListener::bind(addr).await.expect("监听失败");
    println!("弹幕代理已启动:http://{addr}  (管理界面 /admin)");
    axum::serve(listener, router)
        .with_graceful_shutdown(async move {
            let _ = tokio::signal::ctrl_c().await;
            app.clients.flush();
            println!("已保存状态,退出。");
        })
        .await
        .expect("服务异常退出");
}

// ---------- 客户端来源 IP ----------

/// 取真实客户端 IP。
///
/// ★ 这些头**任何人都能伪造** —— 只有在「本服务不直接暴露、前面一定有反代」的
///   前提下才可信。所以默认只绑回环(见 main)。顺序照实际链路:
///   Cloudflare 橙云会写 CF-Connecting-IP,反代写 X-Real-IP,都没有就退回 socket。
fn client_ip(h: &HeaderMap, fallback: &str) -> String {
    for k in ["cf-connecting-ip", "x-real-ip"] {
        if let Some(v) = h.get(k).and_then(|v| v.to_str().ok()) {
            let v = v.trim();
            if !v.is_empty() {
                return v.to_string();
            }
        }
    }
    if let Some(v) = h.get("x-forwarded-for").and_then(|v| v.to_str().ok()) {
        if let Some(first) = v.split(',').next().map(str::trim) {
            if !first.is_empty() {
                return first.to_string();
            }
        }
    }
    fallback.to_string()
}

// ---------- 业务错误 ----------

/// 业务错误照弹弹Play 的口径回:**HTTP 200 + body 里的 errorCode**。
///
/// 不是偷懒 —— 客户端已经有一套 `check_api_error` 在解这个结构,并且会把
/// errorMessage 原样显示给用户。走同一条路,限流原因("今日配额已用完")
/// 就能一字不差地出现在播放器上,不用在三端各写一遍解析。
/// 自定义码用 1001+,和弹弹自己的码(429/500…)不撞。
fn biz_err(code: i64, msg: &str) -> Response {
    let body = serde_json::json!({ "errorCode": code, "errorMessage": msg, "success": false });
    (StatusCode::OK, axum::Json(body)).into_response()
}

pub const E_DISABLED: i64 = 1001;
pub const E_RATE: i64 = 1002;
pub const E_QUOTA: i64 = 1003;
pub const E_UPSTREAM: i64 = 1004;
pub const E_PATH: i64 = 1005;

// ---------- 注册 ----------

#[derive(serde::Deserialize, Default)]
#[serde(default)]
struct RegisterReq {
    label: String,
    invite: String,
}

async fn register(
    State(app): State<Shared>,
    headers: HeaderMap,
    body: Option<axum::Json<RegisterReq>>,
) -> Response {
    let req = body.map(|b| b.0).unwrap_or_default();
    let c = app.cfg.get();
    match c.register_mode {
        config::RegisterMode::Closed => {
            return biz_err(E_DISABLED, "暂不接受新设备注册")
        }
        config::RegisterMode::Invite => {
            if c.invite_code.is_empty() || req.invite.trim() != c.invite_code {
                return biz_err(E_DISABLED, "需要邀请码");
            }
        }
        config::RegisterMode::Open => {}
    }
    let ip = client_ip(&headers, "unknown");
    match app.clients.register(&req.label, &ip, upstream::now_secs(), c.register_per_ip_per_day) {
        Ok(token) => axum::Json(serde_json::json!({ "token": token })).into_response(),
        Err(e) => biz_err(E_RATE, &e),
    }
}

// ---------- 转发 ----------

/// 只放行客户端真正会用的那几条路径。不做通配转发 —— 那等于给全世界开了一个
/// 带我们签名的弹弹Play 免费代理,配额照样是我们的。
fn allowed(path: &str) -> bool {
    const OK: [&str; 6] = [
        "search/anime",
        "search/episodes",
        "bangumi/",
        "comment/",
        "match",
        "trending/",
    ];
    OK.iter().any(|p| path == *p || path.starts_with(p))
}

/// 按数据的新鲜度要求选 TTL。弹幕会持续增加,但少了最近几条没人看得出来;
/// 搜索结果几乎不变;排行榜每天变一次。
fn ttl_for(path: &str, c: &config::Config) -> u64 {
    if path.starts_with("comment/") {
        c.ttl_comment_secs
    } else if path.starts_with("trending/") {
        c.ttl_trending_secs
    } else {
        c.ttl_search_secs
    }
}

async fn forward(
    State(app): State<Shared>,
    Path(rest): Path<String>,
    Query(q): Query<BTreeMap<String, String>>,
    headers: HeaderMap,
    method: axum::http::Method,
    body: Bytes,
) -> Response {
    let c = app.cfg.get();
    if !c.enabled {
        return biz_err(E_DISABLED, "弹幕服务暂时关闭");
    }
    if !allowed(&rest) {
        return biz_err(E_PATH, "不支持的接口");
    }
    let Some(token) = headers.get("x-lp-token").and_then(|v| v.to_str().ok()).map(str::trim) else {
        return (StatusCode::UNAUTHORIZED, "missing token").into_response();
    };
    let ip = client_ip(&headers, "unknown");
    let now = upstream::now_secs();

    // 参数已由 BTreeMap 排过序 —— 缓存键和实际发出去的 query 用同一份,不会漂。
    let query: String =
        q.iter().map(|(k, v)| format!("{}={}", enc(k), enc(v))).collect::<Vec<_>>().join("&");
    let ckey = cache::key(method.as_str(), &rest, &query, &body);

    // 先查缓存。命中的话既不占出站名额,也不计客户端的上游额度。
    let hit = app.cache.get(&ckey, now);
    if let Err(e) = app.clients.check(
        token,
        &ip,
        now,
        c.client_per_minute,
        c.client_upstream_per_day,
        hit.is_none(),
    ) {
        return if e.contains("令牌") || e.contains("封禁") {
            // 401 = 客户端应当清掉本地令牌重新注册;业务码做不到这件事。
            (StatusCode::UNAUTHORIZED, e).into_response()
        } else {
            biz_err(E_RATE, &e)
        };
    }
    if let Some(cached) = hit {
        return json_response(cached, true);
    }

    if let Err(e) = app.gov.acquire(c.upstream_per_minute, c.upstream_per_day) {
        return biz_err(E_QUOTA, &e);
    }

    let api_path = format!("/api/v2/{rest}");
    let url = format!("{}{api_path}", upstream::official_base());
    let mut req = if method == axum::http::Method::POST {
        app.http.post(&url).header("Content-Type", "application/json").body(body.to_vec())
    } else {
        app.http.get(&url)
    };
    if !query.is_empty() {
        req = req.query(&q.iter().collect::<Vec<_>>());
    }
    /* ★ 签名的 path 用**不带 query 的** api_path —— 弹弹Play 的签名口径就是这样,
       把 query 拼进去会一律 403,而 403 长得跟「凭据无效」一模一样。 */
    for (k, v) in app.creds.headers(&api_path) {
        req = req.header(k, v);
    }

    match req.send().await {
        Ok(r) => {
            let ok = r.status().is_success();
            let bytes = r.bytes().await.unwrap_or_default();
            /* 只缓存**成功且不含 errorCode** 的响应。
               把 429「配额已用完」缓存下来,等于在 TTL 内把这个错误钉死 ——
               配额恢复了客户端还在看旧错误,而且没人查得出来为什么。 */
            if ok && !looks_like_error(&bytes) {
                app.cache.put(&ckey, &bytes, ttl_for(&rest, &c), now);
            }
            json_response(bytes.to_vec(), false)
        }
        Err(e) => biz_err(E_UPSTREAM, &format!("上游请求失败:{e}")),
    }
}

/// 上游用 HTTP 200 + errorCode 报错(它从不用状态码)。缓存前必须看这个字段。
fn looks_like_error(body: &[u8]) -> bool {
    serde_json::from_slice::<serde_json::Value>(body)
        .ok()
        .and_then(|v| v["errorCode"].as_i64())
        .is_some_and(|c| c != 0)
}

fn json_response(body: Vec<u8>, from_cache: bool) -> Response {
    Response::builder()
        .status(StatusCode::OK)
        .header("Content-Type", "application/json; charset=utf-8")
        // 便于线上自查命中率(客户端不看它)。
        .header("X-LP-Cache", if from_cache { "HIT" } else { "MISS" })
        .body(axum::body::Body::from(body))
        .unwrap_or_else(|_| StatusCode::INTERNAL_SERVER_ERROR.into_response())
}

fn enc(s: &str) -> String {
    s.bytes()
        .map(|b| match b {
            b'A'..=b'Z' | b'a'..=b'z' | b'0'..=b'9' | b'-' | b'_' | b'.' | b'~' => {
                (b as char).to_string()
            }
            _ => format!("%{b:02X}"),
        })
        .collect()
}

#[cfg(test)]
mod tests {
    use super::*;

    /* 通配转发 = 给全世界开了一个带我们签名的弹弹Play 免费代理。
       ★ 反向验证:把 allowed() 改成恒 true,本测试立刻红。 */
    #[test]
    fn only_the_endpoints_clients_actually_use_are_forwarded() {
        for p in ["search/anime", "search/episodes", "bangumi/123", "comment/456", "match", "trending/anime"] {
            assert!(allowed(p), "{p} 是客户端要用的,不该被挡");
        }
        for p in ["", "login", "user/profile", "../admin", "v2/search/anime"] {
            assert!(!allowed(p), "{p} 不该放行 —— 白名单之外一律拒");
        }
    }

    /* 把上游的错误缓存下来 = 在 TTL 内把这个错误钉死,配额恢复了客户端还在看旧错误。
       ★ 反向验证:让 looks_like_error 恒返回 false,本测试立刻红。 */
    #[test]
    fn upstream_errors_are_never_cached() {
        // 真实响应体是 UTF-8 中文,这里用 .as_bytes() 而不是 br#""# (裸字节串只收 ASCII)。
        assert!(looks_like_error(
            r#"{"errorCode":429,"errorMessage":"已达到接口调用配额上限"}"#.as_bytes()
        ));
        assert!(looks_like_error(br#"{"errorCode":500}"#));
        assert!(!looks_like_error(br#"{"errorCode":0,"animes":[]}"#), "errorCode=0 是成功");
        assert!(!looks_like_error(br#"{"animes":[]}"#), "没有这个字段也是成功");
        assert!(!looks_like_error(b"not json"), "解不出来别当成错误,那会让缓存永远不生效");
    }

    #[test]
    fn ttl_is_picked_per_endpoint_class() {
        let c = config::Config::default();
        assert_eq!(ttl_for("comment/123", &c), c.ttl_comment_secs);
        assert_eq!(ttl_for("trending/anime", &c), c.ttl_trending_secs);
        assert_eq!(ttl_for("search/anime", &c), c.ttl_search_secs);
    }

    /// 代理头是可伪造的,取值顺序要和真实链路一致(CF → 反代 → socket)。
    #[test]
    fn client_ip_prefers_the_closest_trusted_hop() {
        let mut h = HeaderMap::new();
        assert_eq!(client_ip(&h, "10.0.0.1"), "10.0.0.1", "什么都没有就用 socket 地址");
        h.insert("x-forwarded-for", "1.2.3.4, 5.6.7.8".parse().unwrap());
        assert_eq!(client_ip(&h, "10.0.0.1"), "1.2.3.4");
        h.insert("x-real-ip", "9.9.9.9".parse().unwrap());
        assert_eq!(client_ip(&h, "10.0.0.1"), "9.9.9.9");
        h.insert("cf-connecting-ip", "7.7.7.7".parse().unwrap());
        assert_eq!(client_ip(&h, "10.0.0.1"), "7.7.7.7", "挂了 CF 就以 CF 的为准");
    }
}
