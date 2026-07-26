//! ★ 与 apps/desktop/src/plugins_host.rs 是同一份,**只有一处不同**:
//!   安卓的播放器在独立的 `PlayerState` 里(生命周期跟 Surface 走),
//!   所以 `st.player` 全部改成 `ps.player`。改桌面那份时记得同步。
//! 插件宿主实现:把 core 插件引擎要的平台能力(player/ui/emby/cfproxy)落到桌面壳。
//!
//! - player:直连 mpv Player。
//! - emby:走 config 里的当前登录账号(server/token)。
//! - ui:发 `plugin://ui-request` 事件给前端;需返回值的(showForm/render 等)挂 oneshot
//!   等前端 `plugin_ui_respond` 回填。
//!
//! v2 变化:删掉 cfproxy 通道(CF 优选改做宿主内置功能)和 emby.getCredentials
//! (宿主不再持久化明文密码,插件要账密请自己弹表单存自己的 storage)。

use std::sync::Arc;

use async_trait::async_trait;
use linplayer_core::plugins::PluginHost;
use serde_json::{json, Value as Json};
use tauri::{AppHandle, Emitter, Manager};
use tokio::sync::oneshot;

use crate::AppState;

pub struct AndroidPluginHost {
    app: AppHandle,
}

impl AndroidPluginHost {
    pub fn new(app: AppHandle) -> Self {
        Self { app }
    }

    fn state(&self) -> tauri::State<'_, AppState> {
        self.app.state::<AppState>()
    }
}

#[async_trait]
impl PluginHost for AndroidPluginHost {
    async fn call(&self, plugin_id: &str, channel: &str, method: &str, args: Vec<Json>) -> Result<Json, String> {
        match channel {
            "player" => self.player(method, args),
            "emby" => self.emby(method, args).await,
            "ui" => self.ui(plugin_id, method, args).await,
            other => Err(format!("未知能力通道: {other}")),
        }
    }

    fn log(&self, plugin_id: &str, level: &str, msg: &str) {
        crate::poclog(&format!("[plugin:{plugin_id}] {level} {msg}"));
    }

    fn extensions_changed(&self) {
        let _ = self.app.emit("plugin://extensions-changed", ());
    }

    fn sources_changed(&self, plugin_id: &str) {
        // 重建源分派表要在 Tauri 的异步上下文里做(要拿 AppState 的锁),
        // 这里只发信号,真正的重建在 lib.rs 的监听里。
        let _ = self.app.emit("plugin://sources-changed", json!({ "pluginId": plugin_id }));
    }
}

impl AndroidPluginHost {
    fn player(&self, method: &str, args: Vec<Json>) -> Result<Json, String> {
        let st = self.state();
        // ★ 安卓与桌面的唯一差异:播放器不在 AppState 里,而在独立的 PlayerState
        //   (它的生命周期跟 SurfaceView 走,不能跟 AppState 一起建)。
        let ps = self.app.state::<crate::PlayerState>();
        match method {
            "getCurrentMedia" => {
                // 当前 Emby 播放的 scrobble 上下文映射成精简 media(无则 null)。
                let ctx = st.scrobble_ctx.lock().unwrap();
                Ok(match ctx.as_ref() {
                    Some(info) => json!({
                        "name": info.title,
                        "type": info.media_type,
                        "indexNumber": info.episode,
                        "parentIndexNumber": info.season,
                    }),
                    None => Json::Null,
                })
            }
            // ponytail: 缓存上限暂给默认 300MB;接 Prefs 里真实设置项时改读 config。
            "getCacheLimitBytes" => Ok(json!(300u64 * 1024 * 1024)),
            "play" => {
                if let Some(p) = ps.player.lock().unwrap().as_ref() {
                    p.set_pause(false);
                }
                Ok(Json::Null)
            }
            "pause" => {
                if let Some(p) = ps.player.lock().unwrap().as_ref() {
                    p.set_pause(true);
                }
                Ok(Json::Null)
            }
            "seek" => {
                let secs = args.first().and_then(|v| v.as_f64()).unwrap_or(0.0);
                if let Some(p) = ps.player.lock().unwrap().as_ref() {
                    p.seek_abs(secs)?;
                }
                Ok(Json::Null)
            }
            other => Err(format!("未知 player 方法: {other}")),
        }
    }

    async fn emby(&self, method: &str, args: Vec<Json>) -> Result<Json, String> {
        // 取当前登录账号(server/token/user)。
        let account = self.state().config.lock().unwrap().active_account().cloned();
        let account = account.ok_or_else(|| "未连接服务器".to_string())?;
        match method {
            "getServerUrl" => Ok(json!(account.server)),
            "getServerInfo" => Ok(json!({
                "url": account.server,
                "baseUrl": account.server,
                "name": account.user_name,
                "username": account.user_name,
                "userId": account.user_id,
            })),
            "getCurrentUser" => Ok(json!({ "id": account.user_id, "name": account.user_name })),
            "apiRequest" => {
                let opts = args.into_iter().next().unwrap_or(Json::Null);
                self.emby_api(&account.server, &account.token, opts).await
            }
            other => Err(format!("未知 emby 方法: {other}")),
        }
    }

    async fn emby_api(&self, base: &str, token: &str, opts: Json) -> Result<Json, String> {
        let path = opts.get("path").and_then(|v| v.as_str()).unwrap_or("");
        let http_method = opts.get("method").and_then(|v| v.as_str()).unwrap_or("GET").to_uppercase();
        let base_uri = reqwest::Url::parse(base).map_err(|e| format!("服务器地址非法: {e}"))?;
        let resolved = base_uri.join(path).map_err(|e| format!("path 非法: {e}"))?;
        // 防 SSRF:解析后必须仍指向同一服务器,否则拒绝(避免 X-Emby-Token 外泄)。
        if resolved.scheme() != base_uri.scheme()
            || resolved.host_str() != base_uri.host_str()
            || resolved.port_or_known_default() != base_uri.port_or_known_default()
        {
            return Err(format!("apiRequest 路径越权指向了其它主机: {:?}", resolved.host_str()));
        }

        let http = self.state().http.clone();
        let mut req = http
            .request(reqwest::Method::from_bytes(http_method.as_bytes()).unwrap_or(reqwest::Method::GET), resolved)
            .header("X-Emby-Token", token)
            .header("X-Emby-Client", "LinPlayer");
        if let Some(q) = opts.get("query").and_then(|v| v.as_object()) {
            let pairs: Vec<(String, String)> = q
                .iter()
                .map(|(k, v)| (k.clone(), v.as_str().map(|s| s.to_string()).unwrap_or_else(|| v.to_string())))
                .collect();
            req = req.query(&pairs);
        }
        if let Some(h) = opts.get("headers").and_then(|v| v.as_object()) {
            for (k, v) in h {
                if let Some(s) = v.as_str() {
                    req = req.header(k.as_str(), s);
                }
            }
        }
        if let Some(body) = opts.get("body") {
            if !body.is_null() {
                req = req.json(body);
            }
        }
        let resp = req.send().await.map_err(|e| format!("请求失败: {e}"))?;
        let status = resp.status().as_u16();
        let text = resp.text().await.map_err(|e| format!("读响应失败: {e}"))?;
        let body: Json = serde_json::from_str(&text).unwrap_or(Json::String(text));
        Ok(json!({ "status": status, "body": body }))
    }

    async fn ui(&self, plugin_id: &str, method: &str, args: Vec<Json>) -> Result<Json, String> {
        // 即发即忘:仅通知前端,立即返回。
        let fire_and_forget = matches!(
            method,
            "showToast" | "updateProgress" | "closeProgress" | "openPage" | "render"
        );
        if fire_and_forget {
            let _ = self.app.emit(
                "plugin://ui-request",
                json!({ "id": 0, "pluginId": plugin_id, "method": method, "args": args }),
            );
            return Ok(Json::Null);
        }

        // 需返回值(showForm/showDialog/showList/showProgress):挂 oneshot 等前端回填。
        let st = self.state();
        let id = st.ui_seq.fetch_add(1, std::sync::atomic::Ordering::Relaxed) + 1;
        let (tx, rx) = oneshot::channel::<Json>();
        st.ui_pending.lock().unwrap().insert(id, tx);
        let _ = self.app.emit(
            "plugin://ui-request",
            json!({ "id": id, "pluginId": plugin_id, "method": method, "args": args }),
        );
        rx.await.map_err(|_| "UI 请求未获前端响应".to_string())
    }

}

/// 前端回填一次 UI 请求(showForm 的返回值等)。
pub fn ui_respond(state: &AppState, id: u64, value: Json) {
    if let Some(tx) = state.ui_pending.lock().unwrap().remove(&id) {
        let _ = tx.send(value);
    }
}

/// 供 setup 用:构建 host(Arc<dyn PluginHost>)。
pub fn make_host(app: AppHandle) -> Arc<dyn PluginHost> {
    Arc::new(AndroidPluginHost::new(app))
}
