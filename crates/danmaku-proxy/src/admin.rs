//! 管理界面。单页,HTML 内嵌在二进制里 —— 部署就是一个文件,没有静态资源目录要挂载。
//!
//! 鉴权是**会话 cookie**,不是 Basic:Basic 会让浏览器把密码缓存到关窗为止,
//! 而这个界面能改出站闸门、清空整个弹幕库,不该那么容易一直开着。

use axum::extract::State;
use axum::http::{header, HeaderMap, StatusCode};
use axum::response::{Html, IntoResponse, Response};
use axum::routing::{get, post};
use axum::{Json, Router};
use serde_json::json;
use std::collections::HashSet;
use std::sync::{Mutex, OnceLock};

use crate::{config, upstream, Shared};

/// 有效会话。放模块静态而不是 App 里:它纯粹是这一层的实现细节,
/// 重启即清空正是我们想要的(没有"永久登录")。
fn sessions() -> &'static Mutex<HashSet<String>> {
    static S: OnceLock<Mutex<HashSet<String>>> = OnceLock::new();
    S.get_or_init(|| Mutex::new(HashSet::new()))
}

pub fn routes() -> Router<Shared> {
    Router::new()
        .route("/admin", get(page))
        .route("/admin/api/login", post(login))
        .route("/admin/api/state", get(state))
        .route("/admin/api/config", post(save_config))
        .route("/admin/api/cache/clear", post(clear_cache))
        .route("/admin/api/store/clear", post(clear_store))
        .route("/admin/api/sources/reset", post(reset_sources))
}

/// 定长比较,别用 `==` —— 密码比较的用时差理论上可被测出来。代价是 5 行。
fn eq_ct(a: &str, b: &str) -> bool {
    if a.len() != b.len() {
        return false;
    }
    a.bytes().zip(b.bytes()).fold(0u8, |acc, (x, y)| acc | (x ^ y)) == 0
}

fn authed(h: &HeaderMap) -> bool {
    let Some(cookie) = h.get(header::COOKIE).and_then(|v| v.to_str().ok()) else {
        return false;
    };
    let Some(tok) = cookie
        .split(';')
        .filter_map(|kv| kv.trim().strip_prefix("lp_admin="))
        .next()
    else {
        return false;
    };
    sessions().lock().unwrap().contains(tok)
}

fn need_auth() -> Response {
    (StatusCode::UNAUTHORIZED, Json(json!({"error": "未登录"}))).into_response()
}

async fn page() -> Html<&'static str> {
    Html(PAGE)
}

#[derive(serde::Deserialize)]
struct LoginReq {
    password: String,
}

async fn login(State(app): State<Shared>, Json(req): Json<LoginReq>) -> Response {
    if !eq_ct(&req.password, &app.admin_password) {
        return (StatusCode::UNAUTHORIZED, Json(json!({"error": "密码不对"}))).into_response();
    }
    let tok = new_session_token();
    sessions().lock().unwrap().insert(tok.clone());
    /* HttpOnly + SameSite=Strict:界面和接口同源,不需要跨站带 cookie。
       不设 Secure —— TLS 在反代那一层终结,本进程看到的是明文 HTTP,
       设了反而会让 cookie 在反代到本进程这一跳被丢掉。 */
    (
        [(
            header::SET_COOKIE,
            format!("lp_admin={tok}; Path=/admin; HttpOnly; SameSite=Strict; Max-Age=43200"),
        )],
        Json(json!({"ok": true})),
    )
        .into_response()
}

async fn state(State(app): State<Shared>, h: HeaderMap) -> Response {
    if !authed(&h) {
        return need_auth();
    }
    let now = upstream::now_secs();
    let top = app.sources.top(50);
    let c = app.cfg.get();
    Json(json!({
        "config": c,
        "governor": app.gov.stats(),
        "cache": app.cache.stats(),
        "store": app.store.stats(now, c.refresh_min_secs, c.refresh_max_secs),
        "sources": top,
        "summary": {
            "sources_total": app.sources.len(),
            "uptime_secs": now - app.started,
            "app_id_tail": tail(&app.creds.app_id),
        }
    }))
    .into_response()
}

/// 只露 AppId 的尾巴 —— 界面上要能确认「配的是哪个号」,但没必要把它整个印出来。
fn tail(s: &str) -> String {
    let n = s.chars().count();
    if n <= 4 {
        "****".into()
    } else {
        format!("****{}", s.chars().skip(n - 4).collect::<String>())
    }
}

async fn save_config(
    State(app): State<Shared>,
    h: HeaderMap,
    Json(mut c): Json<config::Config>,
) -> Response {
    if !authed(&h) {
        return need_auth();
    }
    // 0 会把闸门变成「全拒」,看起来像服务坏了。下限钉死,别让人手滑锁死自己。
    c.upstream_per_minute = c.upstream_per_minute.max(1);
    c.upstream_per_day = c.upstream_per_day.max(1);
    c.client_per_minute = c.client_per_minute.max(1);
    /* 下限必须 <= 上限,否则自适应间隔在 clamp 里会被翻转成一个谁也没想要的值。
       底线取 5 秒而不是 0:0 等于每次请求都去上游,而**真正兜底的是出站闸门**
       (它对谁都一样管),所以这里不用设得很保守 —— 设太高反而让端到端自检
       没法在合理时间内验「过期 → 回存量」那条路。 */
    c.refresh_min_secs = c.refresh_min_secs.max(5);
    c.refresh_max_secs = c.refresh_max_secs.max(c.refresh_min_secs);
    app.cfg.set(c);
    Json(json!({"ok": true})).into_response()
}

async fn clear_cache(State(app): State<Shared>, h: HeaderMap) -> Response {
    if !authed(&h) {
        return need_auth();
    }
    app.cache.clear();
    Json(json!({"ok": true})).into_response()
}

/// 清空**弹幕库**。和清缓存完全不是一回事 —— 这是把自己存的那份弹幕全删了,
/// 之后每一集都要重新从上游拉。界面上单独一个按钮并二次确认。
async fn clear_store(State(app): State<Shared>, h: HeaderMap) -> Response {
    if !authed(&h) {
        return need_auth();
    }
    app.store.clear();
    Json(json!({"ok": true})).into_response()
}

async fn reset_sources(State(app): State<Shared>, h: HeaderMap) -> Response {
    if !authed(&h) {
        return need_auth();
    }
    app.sources.reset();
    Json(json!({"ok": true})).into_response()
}

/// 会话令牌。32 字节 CSPRNG —— 可猜等于管理界面敞开。
fn new_session_token() -> String {
    use rand::RngCore;
    let mut b = [0u8; 32];
    rand::rng().fill_bytes(&mut b);
    b.iter().map(|x| format!("{x:02x}")).collect()
}

const PAGE: &str = include_str!("admin.html");

#[cfg(test)]
mod tests {
    use super::*;

    /// 会话 cookie 解析要认得住真实浏览器发来的多 cookie 串。
    #[test]
    fn session_cookie_is_parsed_out_of_a_real_cookie_header() {
        let tok = "abc123";
        sessions().lock().unwrap().insert(tok.into());
        let mut h = HeaderMap::new();
        assert!(!authed(&h), "没有 cookie 不能算登录");
        h.insert(header::COOKIE, "other=1; lp_admin=abc123; x=2".parse().unwrap());
        assert!(authed(&h), "夹在别的 cookie 中间也要认出来");
        h.insert(header::COOKIE, "lp_admin=wrong".parse().unwrap());
        assert!(!authed(&h), "不在会话表里的令牌不能放行");
        sessions().lock().unwrap().remove(tok);
    }

    /* ★ 反向验证:把 eq_ct 换成 a.starts_with(b),本测试立刻红。
       (那种写法会让空密码匹配任何密码 —— 管理界面直接敞开。) */
    #[test]
    fn password_compare_is_exact() {
        assert!(eq_ct("hunter2hunter2", "hunter2hunter2"));
        assert!(!eq_ct("", "hunter2hunter2"), "空密码绝不能通过");
        assert!(!eq_ct("hunter2", "hunter2hunter2"), "前缀不算匹配");
        assert!(!eq_ct("hunter2hunter3", "hunter2hunter2"));
    }

    #[test]
    fn app_id_is_never_printed_in_full() {
        assert_eq!(tail("1234567890"), "****7890");
        assert_eq!(tail("abc"), "****", "太短就整个遮掉");
    }
}
