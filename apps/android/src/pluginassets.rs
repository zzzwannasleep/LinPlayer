//! `lpplugin://` 自定义协议:喂 iframe 逃生舱和插件图标。
//!
//! 范式照抄同目录的 `imgcache.rs` —— 闭包是**同步**的且跑在 webview UI 线程上,
//! 里面不能 await、绝不能阻塞。
//!
//! URL 形如 `lpplugin://<插件id>/<插件目录内的相对路径>`。
//! 路径穿越防护和 Content-Type 判定在核层 `plugins::assets`(那里可以直接单测,
//! 不必拉起一个 Tauri app)。
//!
//! **为什么逃生舱要走独立协议而不是直接塞进主窗口**:主窗口的 JS 上下文里有
//! `__TAURI_INTERNALS__.invoke`,插件代码进去就等于拿到宿主全部命令,
//! 整套权限模型变成摆设。独立 origin 的 iframe 才有边界,而独立 origin 需要这个协议供文件。

use std::borrow::Cow;

use linplayer_core::plugins::{content_type_for, AssetError};
use tauri::http::{header, Request, Response, StatusCode};
use tauri::{Builder, Manager, Runtime, UriSchemeContext, UriSchemeResponder};

use crate::AppState;

pub const SCHEME: &str = "lpplugin";

pub fn register<R: Runtime>(builder: Builder<R>) -> Builder<R> {
    builder.register_asynchronous_uri_scheme_protocol(
        SCHEME,
        |ctx: UriSchemeContext<'_, R>, request: Request<Vec<u8>>, responder: UriSchemeResponder| {
            let app = ctx.app_handle().clone();
            let uri = request.uri().clone();
            // ★ 插件 id 从 **path** 的第一段取,**不能**从 host 取。
            //
            // 原来的写法是 `uri.host()`,注释还写着「Windows 上 host = 插件 id」——
            // 那是错的。Windows 上 Tauri 把自定义协议映射成
            // `http://lpplugin.localhost/<插件id>/<路径>`,host 是 "lpplugin.localhost";
            // Linux 上前端拼出来的是 `lpplugin://localhost/<插件id>/<路径>`,host 是
            // "localhost"。两边都不是插件 id,于是**所有**插件资源(图标、逃生舱页面)
            // 一律 403 —— 而且是「不报错,只是白屏」。
            //
            // 同仓库的 `lpimg` 从第一天起就只认 path(见 imgcache.rs),这里是唯一的
            // 偏离。现已对齐。
            let (plugin_id, rel) = split_asset_path(uri.path());

            tauri::async_runtime::spawn(async move {
                let resp = match load(&app, &plugin_id, &rel) {
                    Ok((bytes, mime)) => Response::builder()
                        .status(StatusCode::OK)
                        .header(header::CONTENT_TYPE, mime)
                        // 逃生舱页面改了要能立刻看到(开发模式插件尤其),不缓存。
                        .header(header::CACHE_CONTROL, "no-store")
                        // 插件资源永远不该被别的页面 fetch 走。
                        .header("X-Content-Type-Options", "nosniff")
                        .body(Cow::Owned(bytes))
                        .unwrap(),
                    Err(e) => {
                        let (code, msg) = match e {
                            AssetError::NotEnabled => (StatusCode::FORBIDDEN, "插件未启用"),
                            AssetError::Forbidden => (StatusCode::FORBIDDEN, "路径不允许"),
                            AssetError::NotFound => (StatusCode::NOT_FOUND, "文件不存在"),
                        };
                        // 失败必须回真实状态码而不是 200+空体 —— 后者会被当成一张坏图或
                        // 一个空白页,前端的 onError 也不触发(「不报错,只是不显示」)。
                        Response::builder()
                            .status(code)
                            .header(header::CONTENT_TYPE, "text/plain; charset=utf-8")
                            .body(Cow::Owned(msg.as_bytes().to_vec()))
                            .unwrap()
                    }
                };
                responder.respond(resp);
            });
        },
    )
}

/// `/com.example.foo/view/index.html` -> `("com.example.foo", "view/index.html")`。
///
/// 纯字符串逻辑,单独拆出来是为了能直接单测 —— 要构造一个真的 UriSchemeContext
/// 得拉起整个 Tauri app,那种测试没人会写,于是这段就永远没人测。
fn split_asset_path(path: &str) -> (String, String) {
    let p = path.trim_start_matches('/');
    match p.split_once('/') {
        Some((id, rest)) => (id.to_string(), rest.to_string()),
        None => (p.to_string(), String::new()),
    }
}

fn load<R: Runtime>(
    app: &tauri::AppHandle<R>,
    plugin_id: &str,
    path: &str,
) -> Result<(Vec<u8>, &'static str), AssetError> {
    if plugin_id.is_empty() {
        return Err(AssetError::Forbidden);
    }
    let state = app.state::<AppState>();
    let mgr = state.plugins.get().ok_or(AssetError::NotEnabled)?;
    let file = mgr.asset_path(plugin_id, path)?;
    let mime = content_type_for(&file);
    let bytes = std::fs::read(&file).map_err(|_| AssetError::NotFound)?;
    Ok((bytes, mime))
}

#[cfg(test)]
mod tests {
    use super::*;

    /// 两个平台的 URL 形状不同,但**插件 id 永远是 path 的第一段**。
    /// 按 host 解析的旧写法在两边都拿不到插件 id(Windows 是 "lpplugin.localhost",
    /// Linux 是 "localhost"),表现为所有插件图标和逃生舱页面静默 403。
    #[test]
    fn plugin_id_comes_from_the_first_path_segment_on_every_platform() {
        // Windows: http://lpplugin.localhost/<id>/<rel>
        // Linux/macOS: lpplugin://localhost/<id>/<rel>
        // 两者交给 uri.path() 之后都是同一个字符串:
        let (id, rel) = split_asset_path("/com.example.foo/view/index.html");
        assert_eq!(id, "com.example.foo");
        assert_eq!(rel, "view/index.html");

        let (id, rel) = split_asset_path("/com.example.foo/icon.svg");
        assert_eq!(id, "com.example.foo");
        assert_eq!(rel, "icon.svg");
    }

    /// 只给插件 id、没有文件路径时,rel 是空串 —— 交给 resolve_asset 去拒
    /// (它对空路径回 Forbidden),而不是在这里当成某个默认文件放行。
    #[test]
    fn a_bare_plugin_id_yields_an_empty_relative_path() {
        assert_eq!(split_asset_path("/com.example.foo"), ("com.example.foo".into(), String::new()));
        assert_eq!(split_asset_path("/"), (String::new(), String::new()));
        assert_eq!(split_asset_path(""), (String::new(), String::new()));
    }

    /// 穿越交给 resolve_asset 挡(它有三道防线并且已单测),这里只负责切分 ——
    /// 但切分本身不能把 `..` 吃掉或规范化,否则下游就看不到它了。
    #[test]
    fn traversal_is_passed_through_untouched_for_the_resolver_to_reject() {
        let (id, rel) = split_asset_path("/com.example.foo/../../secret");
        assert_eq!(id, "com.example.foo");
        assert_eq!(rel, "../../secret", "切分不该悄悄规范化路径");
    }
}
