// CF 优选反代的「路由改写」运行时(全局)。迁自 Dart cf_proxy_runtime.dart。
//
// 这是整套 CF 优选的**唯一改写点**:某条线路开启优选反代后,这里登记
// `线路地址 -> 本地反代基址(http://127.0.0.1:port/<原路径前缀>)`。
// [`crate::config::Account::active_line_url`] 拿**当前生效线路的地址**来查,命中则返回
// 本地基址,于是 Emby API 请求与 mpv 取流 URL 都自动改走优选 CF IP,与播放器实现无关。
//
// ★ 键是**线路**,不是服务器(2026-08-01 改)。
//   原先按 server_id 登记 —— 可一台服有很多条线路,而用户明确说过「有些线路并没有使用
//   Cloudflare」。按服务器登记等于:只要这台服开过一次优选,**它的每一条线路**都被劫持
//   到那个 CF 反代上,连不在 CF 后面的直连线也不放过。而反代的上游 host 是开启时那条线
//   定死的(proxy.rs 的 CfReverseProxy.host 只在 start 时取一次),于是切到别的线路后,
//   请求被送到「A 线的域名 + 钉死的 CF IP」—— 连得上、拿不到东西,表现为加载极慢 /
//   没画面没声音,且**全程不报错**。优选本来就是对线路做的,键就必须是线路。
//
// 为什么是全局静态而不是塞进 AppState:改写点必须能被 `Account` 这个纯数据类型看见,
// 而 Account 在平台无关核里,拿不到宿主的 State。Dart 侧同理用的单例。
// 故意做得极薄、零依赖,避免 config → net 的循环引用变重。

use std::collections::HashMap;
use std::sync::RwLock;

static ROUTES: RwLock<Option<HashMap<String, String>>> = RwLock::new(None);

/// 键归一化。线路地址是用户手填的,`https://a.com/` 与 `https://a.com` 必须同键 ——
/// 不归一化就会出现「明明开了优选,active_line_url 却查不到」的静默失效
/// (config.rs 的 norm_line_url 同理由,那边管入表、这边管查表)。
fn key(line_url: &str) -> String {
    line_url.trim().trim_end_matches('/').to_string()
}

/// 命中则返回本地反代基址,否则 None(走原始线路)。参数是**线路地址**。
pub fn local_url_for(line_url: &str) -> Option<String> {
    ROUTES.read().ok()?.as_ref()?.get(&key(line_url)).cloned()
}

/// 登记改写:此后**这条线路**生效时,`active_line_url()` 返回 `local_url`。
pub fn bind(line_url: &str, local_url: impl Into<String>) {
    if let Ok(mut g) = ROUTES.write() {
        g.get_or_insert_with(HashMap::new).insert(key(line_url), local_url.into());
    }
}

/// 撤销改写,该线路恢复直连。
pub fn unbind(line_url: &str) {
    if let Ok(mut g) = ROUTES.write() {
        if let Some(m) = g.as_mut() {
            m.remove(&key(line_url));
        }
    }
}

pub fn is_active(line_url: &str) -> bool {
    local_url_for(line_url).is_some()
}

/// 当前所有改写(线路地址 -> 本地基址),供设置页展示。
pub fn all() -> HashMap<String, String> {
    ROUTES.read().ok().and_then(|g| g.clone()).unwrap_or_default()
}

/// 拆除所有改写(退出/禁用插件时)。
pub fn clear() {
    if let Ok(mut g) = ROUTES.write() {
        *g = None;
    }
}

/// 把上游线路 URL 的路径前缀嫁接到本地反代端口上。
/// 对齐 Dart:`Uri(scheme:'http', host:'127.0.0.1', port:proxy.port, path: upstream.path)`。
/// 为什么要保留路径:反向代理只换了传输层落点,Emby 若挂在 `https://h/emby` 这种子路径下,
/// 丢掉 `/emby` 会让之后所有 API 打到 404 —— 且是「连得上但全 404」的静默故障。
pub fn local_base(upstream_url: &str, port: u16) -> String {
    let rest = upstream_url.split_once("://").map(|(_, r)| r).unwrap_or(upstream_url);
    let path = rest.find('/').map(|i| &rest[i..]).unwrap_or("");
    let path = path.trim_end_matches('/');
    format!("http://127.0.0.1:{port}{path}")
}

/// 拆出上游的 (scheme, host, port),供起反代用。默认 https:443 / http:80。
pub fn split_upstream(url: &str) -> (String, String, u16) {
    let (scheme, rest) = url.split_once("://").unwrap_or(("https", url));
    let scheme = if scheme.is_empty() { "https" } else { scheme };
    let authority = rest.split('/').next().unwrap_or(rest);
    // IPv6 字面量形如 [::1]:8096 —— 按最后一个 ':' 且在 ']' 之后切,否则会把地址本身切碎。
    let default_port = if scheme.eq_ignore_ascii_case("http") { 80 } else { 443 };
    let split_at = match authority.rfind(']') {
        Some(b) => authority[b..].find(':').map(|i| b + i),
        None => authority.rfind(':'),
    };
    match split_at {
        Some(i) => {
            let (h, p) = (&authority[..i], &authority[i + 1..]);
            (scheme.to_string(), h.to_string(), p.parse().unwrap_or(default_port))
        }
        None => (scheme.to_string(), authority.to_string(), default_port),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn local_base_keeps_upstream_path_prefix() {
        // 丢掉子路径 = 连得上但全 404 的静默故障,必须保住。
        assert_eq!(local_base("https://h.com/emby", 5001), "http://127.0.0.1:5001/emby");
        assert_eq!(local_base("https://h.com:443/emby/", 5001), "http://127.0.0.1:5001/emby");
        assert_eq!(local_base("https://h.com", 5001), "http://127.0.0.1:5001");
        assert_eq!(local_base("https://h.com/", 5001), "http://127.0.0.1:5001");
    }

    #[test]
    fn split_upstream_defaults_and_ipv6() {
        assert_eq!(split_upstream("https://h.com/emby"), ("https".into(), "h.com".into(), 443));
        assert_eq!(split_upstream("http://h.com/x"), ("http".into(), "h.com".into(), 80));
        assert_eq!(split_upstream("https://h.com:8096"), ("https".into(), "h.com".into(), 8096));
        // ':' 出现在 IPv6 地址内部,不能当端口分隔符切。
        assert_eq!(split_upstream("https://[::1]:8096/emby"), ("https".into(), "[::1]".into(), 8096));
        assert_eq!(split_upstream("https://[::1]/emby"), ("https".into(), "[::1]".into(), 443));
    }

    #[test]
    fn bind_and_unbind_roundtrip() {
        let line = "https://cf-runtime-test.example.com";
        assert!(!is_active(line));
        bind(line, "http://127.0.0.1:9999");
        assert_eq!(local_url_for(line).as_deref(), Some("http://127.0.0.1:9999"));
        assert!(is_active(line));
        unbind(line);
        assert!(!is_active(line));
    }

    /* 尾斜杠必须同键。线路表里的地址是用户手打的,同一条线可能写成带斜杠、
       而 direct_line_url() 拿到的是另一种写法 —— 不归一化就是「开了优选没生效」,
       且不报错。反向验证:把 key() 改成原样返回,本测试立刻红。 */
    #[test]
    fn trailing_slash_is_the_same_line() {
        let line = "https://cf-slash-test.example.com/emby";
        bind(&format!("{line}/"), "http://127.0.0.1:9998");
        assert!(is_active(line), "带尾斜杠登记的线路,不带斜杠应查得到");
        unbind(line);
        assert!(!is_active(&format!("{line}/")));
    }
}
