//! 每插件一份的共享状态,克隆进所有 ctx 绑定闭包。含:权限门控、HTTPS 白名单 http、
//! 存储/宿主句柄、handler/事件/生命周期的 Persistent 表、以及空转看门狗 deadline。

use std::collections::HashMap;
use std::sync::atomic::{AtomicI64, AtomicU64, Ordering};
use std::sync::{Arc, Mutex};
use std::time::{SystemTime, UNIX_EPOCH};

use rquickjs::{Ctx, Exception, Function, IntoJs, Persistent, Value};
use serde_json::{json, Value as Json};

use super::convert::{js_value_to_json, json_to_js};
use super::contributions::ContributionRegistry;
use super::host::PluginHost;
use super::permission;
use super::storage::PluginStorage;

/// 单次进入 JS 的空转墙钟上限(无任何宿主交互超过此值 = 判失控)。
pub const WATCHDOG_MS: i64 = 30_000;

pub type PersistentFn = Persistent<Function<'static>>;

/// `$sourceServer` 令牌展开出来的一条放行:**用户在「添加服务器」里亲手填的**那个地址。
///
/// `allow_http` 跟着用户填的协议走 —— 自建 OpenList/飞牛 绝大多数是局域网
/// `http://192.168.x.x:5244`,一律强制 https 等于开箱即拒。
/// 但明文只对**用户自己输入过的** origin 放行,manifest 里硬编码的域名仍然 https-only。
#[derive(Clone, Debug, PartialEq)]
pub struct SourceHostGrant {
    /// 小写 host(不含端口 —— 白名单一贯按 host 匹配,端口不参与)。
    pub host: String,
    pub allow_http: bool,
}

impl SourceHostGrant {
    /// 从用户填的 base_url 解析。解析不出 host 就返回 None(不放行任何东西)。
    pub fn from_base_url(base_url: &str) -> Option<Self> {
        let url = reqwest::Url::parse(base_url).ok()?;
        let host = url.host_str()?.to_lowercase();
        if host.is_empty() {
            return None;
        }
        Some(Self { host, allow_http: url.scheme() == "http" })
    }
}

pub struct CtxState {
    pub plugin_id: String,
    pub permissions: permission::GrantedPermissions,
    pub allowed_hosts: Vec<String>,
    /// `$sourceServer` 的运行时展开。manager 持同一个 Arc,用户配置源时直接写进来,
    /// 不必重启引擎。
    pub source_hosts: Arc<Mutex<Vec<SourceHostGrant>>>,
    pub http: reqwest::Client,
    pub storage: Arc<PluginStorage>,
    pub host: Arc<dyn PluginHost>,
    pub registry: Arc<ContributionRegistry>,
    /// 动态注册的 handler(id -> JS 函数)。
    pub handlers: Mutex<HashMap<String, PersistentFn>>,
    /// 播放事件监听(event -> [fn])。
    pub events: Mutex<HashMap<String, Vec<PersistentFn>>>,
    /// 生命周期回调(onEnable/onDisable)。
    pub lifecycle: Mutex<HashMap<String, PersistentFn>>,
    pub handler_seq: AtomicU64,
    /// 看门狗:JS 应在此毫秒(UNIX ms)前有宿主交互;0 = 关闭。
    pub deadline: Arc<AtomicI64>,
}

/// host 是否命中 manifest 里**硬编码**的白名单条目。除精确匹配外支持 `*.example.com`
/// 形式的子域通配(线路节点这类由服务端动态分配、事先枚举不全的域名靠它)。
///
/// `$` 开头的条目是运行时令牌,不在这里参与匹配(它们由 `check_request` 单独处理)。
fn host_allowed(allowed: &[String], host: &str) -> bool {
    let h = host.to_lowercase();
    allowed.iter().any(|raw| {
        if raw.starts_with('$') {
            return false;
        }
        let entry = raw.to_lowercase();
        if entry == h {
            return true;
        }
        match entry.strip_prefix('*') {
            // "*.example.com" -> ".example.com";要求点分隔,防 evil-example.com 命中。
            // 只认 "*." 开头:裸 "*" 会让 suffix 为空、ends_with 恒真,
            // 一个字符就把 fail-closed 击穿成放行全网。
            Some(suffix) if suffix.starts_with('.') => h.len() > suffix.len() && h.ends_with(suffix),
            _ => false,
        }
    })
}

/// 一次插件出网请求的准入判定。**整个网络边界就这一个函数**,所以它是自由函数、
/// 直接可单测(构造 CtxState 要拉起整个 rquickjs 句柄,那样的测试没人会写)。
///
/// 规则:
/// 1. host 必须命中 manifest 硬编码白名单,**或**(白名单声明了 `$sourceServer` 时)
///    命中用户亲手配置的源 origin;
/// 2. https 一律放行;http **只对用户自己填过 http:// 的那个 origin** 放行。
///
/// 边界仍是 fail-closed:放行的只有「用户亲手输入过的地址」和「作者事先声明的域名」。
pub fn check_request(
    allowed: &[String],
    grants: &[SourceHostGrant],
    scheme: &str,
    host: &str,
) -> Result<(), String> {
    let h = host.to_lowercase();
    let token_declared = allowed.iter().any(|a| a == super::manifest::TOKEN_SOURCE_SERVER);
    let grant = if token_declared {
        grants.iter().find(|g| g.host == h)
    } else {
        None
    };

    if !host_allowed(allowed, &h) && grant.is_none() {
        return Err(format!("域名不在白名单内: {host}"));
    }
    match scheme {
        "https" => Ok(()),
        "http" => {
            if grant.map(|g| g.allow_http).unwrap_or(false) {
                Ok(())
            } else {
                Err(format!(
                    "仅允许 HTTPS 请求(明文 http 只对你自己填写的源服务器地址开放): {host}"
                ))
            }
        }
        other => Err(format!("不支持的协议: {other}")),
    }
}

fn now_ms() -> i64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|d| d.as_millis() as i64)
        .unwrap_or(0)
}

impl CtxState {
    pub fn require(&self, permission_id: &str) -> Result<(), String> {
        if self.permissions.has(permission_id) {
            Ok(())
        } else {
            Err(permission::permission_error(&self.plugin_id, permission_id))
        }
    }

    /// 刷新看门狗:有宿主交互就把死线推后。纯 JS 死循环不碰宿主 -> 不刷新 -> 到点被中断。
    pub fn bump_deadline(&self) {
        self.deadline.store(now_ms() + WATCHDOG_MS, Ordering::Relaxed);
    }

    pub fn next_handler_id(&self) -> String {
        let n = self.handler_seq.fetch_add(1, Ordering::Relaxed);
        format!("h{n}")
    }

    /// 转发平台能力(ui/player/emby/cfproxy)。调用前须已 require 权限。
    pub async fn host_call(&self, channel: &str, method: &str, args: Vec<Json>) -> Result<Json, String> {
        self.bump_deadline();
        let r = self.host.call(&self.plugin_id, channel, method, args).await;
        self.bump_deadline();
        r
    }

    // ---- http:白名单 + `$sourceServer`(fail-closed)----
    // 判定逻辑在下面的自由函数 check_request,不然要构造整个 CtxState(含 rquickjs 句柄)才测得了。

    fn check(&self, scheme: &str, host: &str) -> Result<(), String> {
        let grants = self.source_hosts.lock().unwrap().clone();
        check_request(&self.allowed_hosts, &grants, scheme, host)
    }

    /// 执行插件 http 请求。method ∈ get/post/delete。args 已转 JSON。
    pub async fn http_request(&self, method: &str, args: Vec<Json>) -> Result<Json, String> {
        self.require("http")?;
        self.bump_deadline();
        let url = args.first().and_then(|v| v.as_str()).unwrap_or("").to_string();
        let parsed = reqwest::Url::parse(&url).map_err(|_| format!("URL 非法: {url}"))?;
        self.check(parsed.scheme(), parsed.host_str().unwrap_or(""))?;

        // opts:get/delete 在 args[1],post 在 args[2](args[1]=body)。
        let (body, opts) = if method == "post" {
            (args.get(1).cloned(), args.get(2).cloned())
        } else {
            (None, args.get(1).cloned())
        };
        let opts = opts.unwrap_or(Json::Null);
        let discard = opts.get("discardBody").and_then(|v| v.as_bool()).unwrap_or(false);

        let mut req = match method {
            "get" => self.http.get(parsed.clone()),
            "post" => self.http.post(parsed.clone()),
            "delete" => self.http.delete(parsed.clone()),
            other => return Err(format!("不支持的 http 方法: {other}")),
        };

        // query 合并。
        if let Some(q) = opts.get("query").and_then(|v| v.as_object()) {
            let pairs: Vec<(String, String)> = q
                .iter()
                .map(|(k, v)| (k.clone(), json_scalar(v)))
                .collect();
            req = req.query(&pairs);
        }
        // headers。
        if let Some(h) = opts.get("headers").and_then(|v| v.as_object()) {
            for (k, v) in h {
                req = req.header(k.as_str(), json_scalar(v));
            }
        }
        // body(post/delete)。Map/List -> JSON;字符串原样。
        let send_body = body.or_else(|| opts.get("body").cloned());
        if let Some(b) = send_body {
            match b {
                Json::String(s) => {
                    req = req.body(s);
                }
                Json::Null => {}
                other => {
                    req = req.json(&other);
                }
            }
        }

        let resp = req.send().await.map_err(|e| format!("请求失败: {e}"))?;

        // 防重定向绕白名单:最终 URL 必须仍能过同一道准入(含协议降级 —— 302 跳去
        // http:// 的白名单外主机,跟直接请求它是一回事)。
        let final_url = resp.url().clone();
        self.check(final_url.scheme(), final_url.host_str().unwrap_or(""))
            .map_err(|e| format!("请求经重定向后不再被允许: {e}"))?;
        let status = resp.status().as_u16();
        let headers = header_map_json(resp.headers());
        self.bump_deadline();

        if discard {
            // 按流丢弃,只统计字节数(测速用,内存恒定)。
            let mut bytes: u64 = 0;
            let mut resp = resp;
            while let Some(chunk) = resp.chunk().await.map_err(|e| format!("读流失败: {e}"))? {
                bytes += chunk.len() as u64;
                self.bump_deadline();
            }
            return Ok(json!({ "status": status, "headers": headers, "bytes": bytes }));
        }

        let text = resp.text().await.map_err(|e| format!("读响应失败: {e}"))?;
        Ok(json!({ "status": status, "headers": headers, "body": decode_body(&text) }))
    }
}

fn json_scalar(v: &Json) -> String {
    match v {
        Json::String(s) => s.clone(),
        other => other.to_string(),
    }
}

fn header_map_json(headers: &reqwest::header::HeaderMap) -> Json {
    let mut map = serde_json::Map::new();
    for (k, v) in headers {
        if let Ok(s) = v.to_str() {
            map.insert(k.as_str().to_string(), json!(s));
        }
    }
    Json::Object(map)
}

/// 响应体:像 JSON 就解析成对象/数组,否则原样字符串。
fn decode_body(text: &str) -> Json {
    let t = text.trim_start();
    if t.starts_with('{') || t.starts_with('[') {
        if let Ok(v) = serde_json::from_str::<Json>(text) {
            return v;
        }
    }
    json!(text)
}

/// FromJs 包装:在进入 async 绑定前就把 JS 值转成 owned JSON,绕开 'js 借用跨 await。
pub struct JsonVal(pub Json);

impl<'js> rquickjs::FromJs<'js> for JsonVal {
    fn from_js(_ctx: &Ctx<'js>, value: Value<'js>) -> rquickjs::Result<Self> {
        Ok(JsonVal(js_value_to_json(&value)))
    }
}

/// async 绑定的返回:Ok(JSON) 正常 resolve;Err(msg) 抛出真 Error 对象(带 message)。
/// into_js 拿得到 ctx,所以能构造带自定义文案的异常——省掉 Dart 那套 {ok,error} 信封。
pub struct JsOut(pub Result<Json, String>);

impl<'js> IntoJs<'js> for JsOut {
    fn into_js(self, ctx: &Ctx<'js>) -> rquickjs::Result<Value<'js>> {
        match self.0 {
            Ok(v) => json_to_js(ctx, &v),
            Err(msg) => Err(Exception::throw_message(ctx, &msg)),
        }
    }
}

#[cfg(test)]
mod tests {
    use super::host_allowed;

    fn list(v: &[&str]) -> Vec<String> {
        v.iter().map(|s| s.to_string()).collect()
    }

    #[test]
    fn empty_whitelist_denies_everything() {
        assert!(!host_allowed(&[], "www.example.com")); // fail-closed,空 != 放行
    }

    #[test]
    fn exact_and_case_insensitive() {
        let w = list(&["www.example.com"]);
        assert!(host_allowed(&w, "www.example.com"));
        assert!(host_allowed(&w, "WWW.EXAMPLE.COM"));
        assert!(!host_allowed(&w, "example.com"));
    }

    #[test]
    fn wildcard_matches_subdomains_only() {
        let w = list(&["*.example.com"]);
        assert!(host_allowed(&w, "china-vod4.example.com"));
        assert!(host_allowed(&w, "a.b.example.com")); // 多级子域也算
        assert!(!host_allowed(&w, "example.com")); // 裸主域要单独列
        assert!(!host_allowed(&w, "evil-example.com")); // 点分隔,防前缀拼接
        assert!(!host_allowed(&w, "example.com.evil.net")); // 只看后缀,不看包含
    }

    #[test]
    fn bare_star_is_not_a_wildcard() {
        // 裸 "*" 若被当通配,一个字符就把 fail-closed 击穿成放行全网。
        assert!(!host_allowed(&list(&["*"]), "attacker.com"));
        assert!(!host_allowed(&list(&["*com"]), "attacker.com"));
    }

    // ---- $sourceServer 令牌 ----

    use super::{check_request, SourceHostGrant};

    fn grant(host: &str, http: bool) -> SourceHostGrant {
        SourceHostGrant { host: host.into(), allow_http: http }
    }

    /// 令牌**没声明**时,用户配了源也不该放行 —— 否则任何插件只要用户配过一个源
    /// 就能访问那台机器,而作者从没在 manifest 里申明过。
    #[test]
    fn grants_do_nothing_unless_the_token_is_declared() {
        let g = [grant("nas.lan", true)];
        assert!(check_request(&list(&["api.example.com"]), &g, "https", "nas.lan").is_err());
        assert!(check_request(&[], &g, "https", "nas.lan").is_err());
        // 声明了才生效
        assert!(check_request(&list(&["$sourceServer"]), &g, "https", "nas.lan").is_ok());
    }

    /// 没配任何源时,`$sourceServer` 展开为空 = 拒绝一切。fail-closed 不能因为
    /// 多了个令牌就破功。
    #[test]
    fn token_with_no_configured_source_denies_everything() {
        let w = list(&["$sourceServer"]);
        assert!(check_request(&w, &[], "https", "anything.com").is_err());
        assert!(check_request(&w, &[], "http", "192.168.1.5").is_err());
    }

    /// 配了 A 服不等于能访问 B 服。
    #[test]
    fn grant_is_scoped_to_the_exact_host_user_typed() {
        let w = list(&["$sourceServer"]);
        let g = [grant("a.example.com", false)];
        assert!(check_request(&w, &g, "https", "a.example.com").is_ok());
        assert!(check_request(&w, &g, "https", "b.example.com").is_err());
        // 令牌不是通配:子域也不放行
        assert!(check_request(&w, &g, "https", "sub.a.example.com").is_err());
    }

    /// 明文 http **只**对用户自己填过 http:// 的那个 origin 放行;
    /// manifest 里硬编码的域名永远 https-only。这是整条设计的安全支点。
    #[test]
    fn plain_http_only_for_the_address_the_user_typed_as_http() {
        let w = list(&["$sourceServer", "cdn.example.com"]);
        let g = [grant("192.168.1.5", true), grant("secure.example.com", false)];

        assert!(check_request(&w, &g, "http", "192.168.1.5").is_ok(), "局域网自建必须能用");
        assert!(check_request(&w, &g, "https", "192.168.1.5").is_ok(), "升级到 https 当然也行");

        // 用户填的是 https 的源,插件不能偷偷降级成 http
        let e = check_request(&w, &g, "http", "secure.example.com").unwrap_err();
        assert!(e.contains("HTTPS"), "{e}");

        // manifest 硬编码的域名不吃这套
        assert!(check_request(&w, &g, "https", "cdn.example.com").is_ok());
        assert!(check_request(&w, &g, "http", "cdn.example.com").is_err(), "硬编码域名必须 https");
    }

    #[test]
    fn non_http_schemes_are_rejected() {
        let w = list(&["$sourceServer"]);
        let g = [grant("nas.lan", true)];
        for s in ["file", "ftp", "data", "javascript"] {
            assert!(check_request(&w, &g, s, "nas.lan").is_err(), "{s} 不该被放行");
        }
    }

    #[test]
    fn grant_parses_scheme_and_host_from_user_input() {
        let g = SourceHostGrant::from_base_url("http://192.168.1.5:5244").unwrap();
        assert_eq!(g, grant("192.168.1.5", true));
        // 端口不参与匹配(白名单一贯按 host)
        let g = SourceHostGrant::from_base_url("https://Alist.Example.COM:443/x").unwrap();
        assert_eq!(g, grant("alist.example.com", false), "host 要归一化成小写");
        assert!(SourceHostGrant::from_base_url("不是个地址").is_none());
        assert!(SourceHostGrant::from_base_url("").is_none());
    }
}
