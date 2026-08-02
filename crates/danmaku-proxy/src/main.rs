//! LinPlayer 弹幕代理 —— 把弹弹Play 的签名从客户端挪到服务器,顺带自己存一份弹幕。
//!
//! ## 它解决什么
//! 客户端里的 AppSecret 无论怎么加密都是**可提取**的(解密口令必须和密文一起发出去)。
//! 谁拿到安装包都能用我们的配额。挪到服务端之后:
//!   * 密钥只在这台机器的环境变量里,客户端一个字节都拿不到;
//!   * **出站闸门**把「收到多少」和「转发多少」解耦 —— 被刷爆的后果退化成
//!     「这段时间弹幕慢」,而配额一个不掉;
//!   * **自托管弹幕库**([`store`])按 cid 求并集长期留着,过期只是「去看看有没有新的」。
//!     由此换来:闸门关着的时候仍然有弹幕可发,而不是回一个错误。
//!
//! ## 不做鉴权
//! 没有客户端令牌、没有注册流程 —— 用户 2026-08-02 定的。理由成立:真正保住配额的是
//! 出站闸门,它对谁来的都一样管用;拦人是 Cloudflare 的活,在这儿再写一套只会更差。
//! 令牌唯一独有的能力是归因,由 [`sources`] 按来源 IP 统计补回来。
//!
//! ## 部署形态
//! 只监听回环地址,前面挂用户自己的反代(OpenResty/nginx)+ Cloudflare 橙云。
//! 本进程**不做** TLS、不做 IP 封禁、不做 DDoS 防护。

mod admin;
mod cache;
mod config;
mod sources;
mod store;
mod upstream;

use axum::body::Bytes;
use axum::extract::{Path, Query, State};
use axum::http::{HeaderMap, StatusCode};
use axum::response::{IntoResponse, Response};
use axum::routing::{any, get};
use axum::Router;
use std::collections::BTreeMap;
use std::net::SocketAddr;
use std::path::PathBuf;
use std::sync::Arc;

pub struct App {
    pub creds: upstream::Creds,
    pub cfg: config::Store,
    /// 搜索/集表/排行榜的短期响应缓存(过期即丢)。
    pub cache: cache::Cache,
    /// 弹幕库(长期持有,过期只代表"该看看有没有新的")。
    pub store: store::Store,
    pub sources: sources::Sources,
    pub gov: upstream::Governor,
    pub http: reqwest::Client,
    pub admin_password: String,
    pub started: i64,
}

pub type Shared = Arc<App>;

#[tokio::main]
async fn main() {
    let data_dir: PathBuf = std::env::var("DATA_DIR").unwrap_or_else(|_| "./data".into()).into();
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
        // 不给默认密码:管理界面能改出站上限,弱口令等于把闸门交出去。
        eprintln!("[致命] 需要 ADMIN_PASSWORD 环境变量(至少 8 位)");
        std::process::exit(2);
    }

    let cfg = config::Store::load(&data_dir);
    let c0 = cfg.get();
    let app = Arc::new(App {
        creds,
        cache: cache::Cache::open(data_dir.join("cache"), c0.cache_max_mb),
        store: store::Store::open(data_dir.join("danmaku")),
        sources: sources::Sources::new(),
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

    // 弹幕库容量维护。放后台定时而不是每次写入都算:淘汰要遍历全表,不该挂在热路上。
    {
        let a = app.clone();
        tokio::spawn(async move {
            loop {
                tokio::time::sleep(std::time::Duration::from_secs(300)).await;
                let n = a.store.evict(a.cfg.get().store_max_mb.saturating_mul(1024 * 1024));
                if n > 0 {
                    println!("弹幕库超容量,淘汰了 {n} 集(最久没人看的)");
                }
            }
        });
    }

    let router = Router::new()
        .route("/healthz", get(|| async { "ok" }))
        .route("/api/v2/{*rest}", any(forward))
        .merge(admin::routes())
        .with_state(app);

    let addr: SocketAddr = format!("{bind}:{port}").parse().expect("BIND/PORT 不合法");
    let listener = tokio::net::TcpListener::bind(addr).await.expect("监听失败");
    println!("弹幕代理已启动:http://{addr}  (管理界面 /admin)");
    axum::serve(listener, router)
        .with_graceful_shutdown(async {
            let _ = tokio::signal::ctrl_c().await;
            println!("退出。");
        })
        .await
        .expect("服务异常退出");
}

// ---------- 客户端来源 IP ----------

/// 取真实客户端 IP。
///
/// ★ 这些头**任何人都能伪造** —— 只在「本服务不直接暴露、前面一定有反代」的前提下
///   才有意义。所以默认只绑回环(见 main)。而且这个值**不用于鉴权**,只用于统计和
///   自我保护,伪造它也就骗过一张本来就不拦人的表。顺序照实际链路:
///   Cloudflare 橙云写 CF-Connecting-IP,反代写 X-Real-IP,都没有就退回 socket。
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

// ---------- 转发 ----------

/// 只放行客户端真正会用的那几条路径。不做通配转发 —— 那等于给全世界开了一个
/// 带我们签名的弹弹Play 免费代理,配额照样是我们的。
fn allowed(path: &str) -> bool {
    const OK: [&str; 6] =
        ["search/anime", "search/episodes", "bangumi/", "comment/", "match", "trending/"];
    OK.iter().any(|p| path == *p || path.starts_with(p))
}

/// `comment/{episodeId}` → episodeId。只有这一类走弹幕库,其余走普通响应缓存。
fn episode_of(path: &str) -> Option<&str> {
    path.strip_prefix("comment/").map(|s| s.split('/').next().unwrap_or(s)).filter(|s| !s.is_empty())
}

/// 按数据的新鲜度要求选缓存 TTL(弹幕不走这里,它有自己的自适应间隔)。
fn ttl_for(path: &str, c: &config::Config) -> u64 {
    if path.starts_with("trending/") {
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
    let ip = client_ip(&headers, "unknown");
    let now = upstream::now_secs();

    // 参数已由 BTreeMap 排过序 —— 缓存键和实际发出去的 query 用同一份,不会漂。
    let query: String =
        q.iter().map(|(k, v)| format!("{}={}", enc(k), enc(v))).collect::<Vec<_>>().join("&");

    // ---- 弹幕:走自托管的库 ----
    if let Some(ep) = episode_of(&rest) {
        let ep = ep.to_string();
        let taken = app.store.take(&ep, now, c.refresh_min_secs, c.refresh_max_secs);
        let need_upstream = !matches!(taken, store::Take::Fresh(_));
        if let Err(e) = app.sources.hit(&ip, now, c.client_per_minute, need_upstream) {
            return biz_err(E_RATE, &e);
        }
        if let store::Take::Fresh(b) = taken {
            return json_response(b, "FRESH");
        }
        // 过期或没有 → 去上游看看。★ 拿不到就退回存量,而不是报错:
        // 「自己存」最实在的收益就是配额烧光时仍然有弹幕可发。
        let stale = match taken {
            store::Take::Stale(b) => Some(b),
            _ => None,
        };
        match fetch_upstream(&app, &c, &rest, &q, &query, &method, &body).await {
            Ok(bytes) => {
                let (merged, added) =
                    app.store.merge(&ep, &bytes, now, c.refresh_min_secs, c.refresh_max_secs);
                json_response(merged, if added > 0 { "UPDATED" } else { "NOCHANGE" })
            }
            Err(e) => match stale {
                Some(b) => json_response(b, "STALE"),
                None => e,
            },
        }
    } else {
        // ---- 其余:普通响应缓存 ----
        let ckey = cache::key(method.as_str(), &rest, &query, &body);
        let hit = app.cache.get(&ckey, now);
        if let Err(e) = app.sources.hit(&ip, now, c.client_per_minute, hit.is_none()) {
            return biz_err(E_RATE, &e);
        }
        if let Some(b) = hit {
            return json_response(b, "HIT");
        }
        match fetch_upstream(&app, &c, &rest, &q, &query, &method, &body).await {
            Ok(bytes) => {
                app.cache.put(&ckey, &bytes, ttl_for(&rest, &c), now);
                json_response(bytes.to_vec(), "MISS")
            }
            Err(e) => e,
        }
    }
}

/// 过闸门 → 签名 → 发。Err 里已经是可直接返回给客户端的响应。
///
/// ★ 上游用 HTTP 200 + errorCode 报错(它从不用状态码)。带 errorCode 的响应
///   一律当失败返回 —— 存下来等于在 TTL 内把这个错误钉死,配额恢复了客户端还在看旧错。
async fn fetch_upstream(
    app: &Shared,
    c: &config::Config,
    rest: &str,
    q: &BTreeMap<String, String>,
    query: &str,
    method: &axum::http::Method,
    body: &Bytes,
) -> Result<Vec<u8>, Response> {
    if let Err(e) = app.gov.acquire(c.upstream_per_minute, c.upstream_per_day) {
        return Err(biz_err(E_QUOTA, &e));
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
            if !ok || looks_like_error(&bytes) {
                return Err(json_response(bytes.to_vec(), "UPSTREAM-ERR"));
            }
            Ok(bytes.to_vec())
        }
        Err(e) => Err(biz_err(E_UPSTREAM, &format!("上游请求失败:{e}"))),
    }
}

fn looks_like_error(body: &[u8]) -> bool {
    serde_json::from_slice::<serde_json::Value>(body)
        .ok()
        .and_then(|v| v["errorCode"].as_i64())
        .is_some_and(|c| c != 0)
}

/// `X-LP-Cache` 只为线上自查存在(客户端不看它):
/// FRESH=库里还新鲜 / UPDATED=去上游拿到了新弹幕 / NOCHANGE=拉了但一条没长 /
/// STALE=上游拿不到,回的是存量 / HIT|MISS=普通响应缓存。
fn json_response(body: Vec<u8>, tag: &str) -> Response {
    Response::builder()
        .status(StatusCode::OK)
        .header("Content-Type", "application/json; charset=utf-8")
        .header("X-LP-Cache", tag)
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
        for p in
            ["search/anime", "search/episodes", "bangumi/123", "comment/456", "match", "trending/all/hot/week"]
        {
            assert!(allowed(p), "{p} 是客户端要用的,不该被挡");
        }
        for p in ["", "login", "user/profile", "../admin", "v2/search/anime"] {
            assert!(!allowed(p), "{p} 不该放行 —— 白名单之外一律拒");
        }
    }

    /* 只有 /comment/ 该走弹幕库。判错的后果很脏:把搜索结果并进弹幕库,
       或者把弹幕当成短期缓存过期就丢(那就白存了)。 */
    #[test]
    fn only_comment_requests_go_to_the_danmaku_store() {
        assert_eq!(episode_of("comment/183170001"), Some("183170001"));
        assert_eq!(episode_of("comment/183170001/extra"), Some("183170001"), "多余路径段不能混进 id");
        assert_eq!(episode_of("comment/"), None, "空 id 不能当成一集");
        assert_eq!(episode_of("search/anime"), None);
        assert_eq!(episode_of("trending/all/hot/week"), None);
    }

    /* 把上游的错误存下来 = 在 TTL 内把这个错误钉死,配额恢复了客户端还在看旧错误。
       ★ 反向验证:让 looks_like_error 恒返回 false,本测试立刻红。 */
    #[test]
    fn upstream_errors_are_never_stored() {
        // 真实响应体是 UTF-8 中文,用 .as_bytes() 而不是 br#""#(裸字节串只收 ASCII)。
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
        assert_eq!(ttl_for("trending/all/hot/week", &c), c.ttl_trending_secs);
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
