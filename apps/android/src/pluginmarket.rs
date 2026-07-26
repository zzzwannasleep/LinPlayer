//! 插件市场:多源 registry 订阅 → 聚合 → 下载校验 → 安装。
//!
//! 纯逻辑(版本挑选/聚合/sha256)在核层 `plugins::registry_index`(那里可以单测);
//! 这一层只管 **HTTP + 配置持久化 + 落盘安装** 这些需要 Tauri 上下文的部分。
//!
//! 通道口径(`docs/PLUGINS_V2_PLAN.md` 6.4):registry 和 .ipk **都走 GitHub raw**。
//! 别"优化"到 Cloudflare —— 用户实测国内 CF 有地方会被阻断,GitHub 反而稳。

use std::sync::Mutex;

use linplayer_core::plugins::{
    manifest::API_VERSION, registry_index as reg, PluginSource, RegistryPlugin,
};
use serde_json::{json, Value as Json};
use tauri::State;

use crate::AppState;

/// 官方源。id 是稳定常量,配置里只落一个开关(见 `AppConfig::plugin_official_enabled`)。
const OFFICIAL_ID: &str = "official";
const OFFICIAL_NAME: &str = "LinPlayer 官方源";
const OFFICIAL_URL: &str =
    "https://raw.githubusercontent.com/zzzwannasleep/LinplayerPluginsRepository/main/registry.json";

/// 聚合结果的进程内缓存。市场页每次进出都重新拉一遍网络既慢又白费流量,
/// 而插件源的内容一天也不会变几次 —— 想要最新的用户会点刷新(refresh=true)。
///
/// ★ **错误也要一起缓存**。第一版只存插件列表,于是「某个源挂了」的提示
/// 只在真正联网那一次出现,切走再切回来(命中缓存)警告条就消失了,
/// 剩下一个光秃秃的「没有找到插件」—— 用户第二次看到的是一个**更没线索**的页面。
/// 截图自检时抓到的:DOM 探针那次是刷新路径所以有警告,截图那次走缓存就没了。
type Cached = (Vec<RegistryPlugin>, Vec<Json>);
static CACHE: Mutex<Option<Cached>> = Mutex::new(None);

fn official() -> PluginSource {
    PluginSource {
        id: OFFICIAL_ID.into(),
        name: OFFICIAL_NAME.into(),
        url: OFFICIAL_URL.into(),
        enabled: true,
        builtin: true,
    }
}

/// 官方源 + 用户源。官方**永远排第一** —— 聚合时先到的赢重名,顺序即优先级。
pub fn all_sources(state: &AppState) -> Vec<PluginSource> {
    let cfg = state.config.lock().unwrap();
    let mut out = vec![PluginSource {
        enabled: cfg.plugin_official_enabled,
        ..official()
    }];
    out.extend(cfg.plugin_sources.iter().cloned());
    out
}

/// 源 id 由 URL 派生:同一个 URL 加两次不会变成两条。
///
/// 归一化交给 `Url::parse`(它只把 scheme/host 转小写,**路径保持原样**)——
/// 手写 `to_lowercase()` 会让 `/R.json` 和 `/r.json` 撞成同一个 id,
/// 而在大小写敏感的服务器上那是两份不同的 registry。
fn source_id_for(url: &str) -> String {
    let norm = reqwest::Url::parse(url.trim())
        .map(|u| u.to_string())
        .unwrap_or_else(|_| url.trim().to_string());
    reg::sha256_hex(norm.as_bytes())[..12].to_string()
}

/// registry / 插件包的 URL 准入。明文 http **只对本机放行** ——
/// registry 决定「装什么包」、包本身就是要执行的代码,
/// 在不可信网络上被中间人改一行就等于任意插件安装。
/// 本机例外是给插件作者试自己的源用的。
fn check_fetch_url(url: &str) -> Result<(), String> {
    let u = reqwest::Url::parse(url.trim()).map_err(|e| format!("地址非法: {e}"))?;
    match u.scheme() {
        "https" => Ok(()),
        "http" => {
            let host = u.host_str().unwrap_or("");
            if host == "localhost" || host == "127.0.0.1" || host == "::1" {
                Ok(())
            } else {
                Err("插件源必须是 https(明文 http 只对本机开放)——\
                     registry 决定装哪个包,被中途改一行就等于任意插件安装"
                    .into())
            }
        }
        other => Err(format!("不支持的协议: {other}")),
    }
}

// ---------------- 权限词表 ----------------

/// 权限的人话说明。
///
/// **必须由核层透出,不能在前端抄一份** —— 抄一份的后果是加了新权限而前端不知道,
/// 授权弹窗里显示成一个光秃秃的 `sources` 字符串,用户根本看不懂自己同意了什么。
#[tauri::command]
pub fn plugin_permission_catalog() -> Vec<Json> {
    linplayer_core::plugins::permission::ALL
        .iter()
        .map(|p| {
            json!({
                "id": p.id, "title": p.title,
                "description": p.description, "dangerous": p.dangerous,
            })
        })
        .collect()
}

// ---------------- 源订阅 ----------------

#[tauri::command]
pub fn plugin_market_sources(state: State<'_, AppState>) -> Vec<PluginSource> {
    all_sources(&state)
}

#[tauri::command]
pub fn plugin_market_add_source(
    state: State<'_, AppState>,
    name: String,
    url: String,
) -> Result<Vec<PluginSource>, String> {
    let url = url.trim().to_string();
    check_fetch_url(&url)?;
    let id = source_id_for(&url);
    if id == OFFICIAL_ID || url == OFFICIAL_URL {
        return Err("这已经是官方源了".into());
    }
    {
        let mut cfg = state.config.lock().unwrap();
        if cfg.plugin_sources.iter().any(|s| s.id == id) {
            return Err("这个源已经添加过了".into());
        }
        cfg.plugin_sources.push(PluginSource {
            id,
            name: if name.trim().is_empty() { url.clone() } else { name.trim().into() },
            url,
            enabled: true,
            builtin: false,
        });
        cfg.save();
    }
    *CACHE.lock().unwrap() = None;
    Ok(all_sources(&state))
}

#[tauri::command]
pub fn plugin_market_remove_source(
    state: State<'_, AppState>,
    id: String,
) -> Result<Vec<PluginSource>, String> {
    if id == OFFICIAL_ID {
        return Err("官方源不能删除,只能停用".into());
    }
    {
        let mut cfg = state.config.lock().unwrap();
        cfg.plugin_sources.retain(|s| s.id != id);
        cfg.save();
    }
    *CACHE.lock().unwrap() = None;
    Ok(all_sources(&state))
}

#[tauri::command]
pub fn plugin_market_toggle_source(
    state: State<'_, AppState>,
    id: String,
    enabled: bool,
) -> Result<Vec<PluginSource>, String> {
    {
        let mut cfg = state.config.lock().unwrap();
        if id == OFFICIAL_ID {
            cfg.plugin_official_enabled = enabled;
        } else {
            match cfg.plugin_sources.iter_mut().find(|s| s.id == id) {
                Some(s) => s.enabled = enabled,
                None => return Err("没有这个插件源".into()),
            }
        }
        cfg.save();
    }
    *CACHE.lock().unwrap() = None;
    Ok(all_sources(&state))
}

// ---------------- 列表 ----------------

/// 拉取并聚合全部启用的源。
///
/// **单个源失败不影响其它源**:错误按源收集后一并回给前端展示,
/// 而不是让一个挂掉的第三方源把整个市场变成一张报错页。
#[tauri::command]
pub async fn plugin_market_list(
    state: State<'_, AppState>,
    refresh: Option<bool>,
) -> Result<Json, String> {
    let sources = all_sources(&state);
    let enabled: Vec<PluginSource> = sources.iter().filter(|s| s.enabled).cloned().collect();

    if !refresh.unwrap_or(false) {
        if let Some((plugins, errors)) = CACHE.lock().unwrap().clone() {
            return Ok(json!({
                "plugins": plugins, "errors": errors, "apiVersion": API_VERSION, "cached": true,
            }));
        }
    }

    let http = state.http.clone();
    let mut per_source: Vec<Vec<RegistryPlugin>> = Vec::new();
    let mut errors: Vec<Json> = Vec::new();
    for s in &enabled {
        match fetch_one(&http, s).await {
            Ok(list) => per_source.push(list),
            Err(e) => errors.push(json!({ "source": s.name, "error": e })),
        }
    }
    let merged = reg::merge_sources(per_source);
    *CACHE.lock().unwrap() = Some((merged.clone(), errors.clone()));
    Ok(json!({
        "plugins": merged, "errors": errors, "apiVersion": API_VERSION, "cached": false,
    }))
}

async fn fetch_one(
    http: &reqwest::Client,
    src: &PluginSource,
) -> Result<Vec<RegistryPlugin>, String> {
    check_fetch_url(&src.url)?;
    let resp = http
        .get(&src.url)
        .send()
        .await
        .map_err(|e| format!("连不上: {e}"))?;
    if !resp.status().is_success() {
        return Err(format!("HTTP {}", resp.status().as_u16()));
    }
    let raw = resp.text().await.map_err(|e| format!("读取失败: {e}"))?;
    let parsed = reg::parse_registry(&raw)?;
    // 一条都没认出来 ≠ 这个源是空的。不说清楚的话前端只会显示「没有找到插件」,
    // 用户完全看不出真实原因是 schema 对不上(2026-07-23 官方源正是这个状态)。
    if parsed.plugins.is_empty() && parsed.skipped > 0 {
        return Err(format!(
            "这个源里的 {} 条插件全都认不出来 —— 多半是旧版(v1)registry,需要源那边升级到 v2",
            parsed.skipped
        ));
    }
    let mut list = parsed.plugins;
    // 卡片上要标「来自哪个源」,第三方源必须能一眼看出来。
    for p in &mut list {
        p.source_id = src.id.clone();
        p.source_name = src.name.clone();
        p.from_builtin = src.builtin;
    }
    Ok(list)
}

// ---------------- 安装 ----------------

/// 从市场安装(或升级)一个插件。
///
/// 顺序是**先校验再落盘**:sha256 对不上的包连临时文件都不留。
#[tauri::command]
pub async fn plugin_market_install(
    state: State<'_, AppState>,
    id: String,
    version: Option<String>,
) -> Result<Json, String> {
    let plugin = CACHE
        .lock()
        .unwrap()
        .as_ref()
        .and_then(|(list, _)| list.iter().find(|p| p.id == id).cloned())
        .ok_or("插件列表已过期,请刷新市场后重试")?;

    let ver = match &version {
        Some(v) => plugin
            .versions
            .iter()
            .find(|x| &x.version == v)
            .ok_or_else(|| format!("没有 {v} 这个版本"))?,
        None => plugin
            .best_version(API_VERSION)
            .ok_or("这个插件没有当前版本能装的版本,请先升级 LinPlayer")?,
    };

    let url = ver.package_url.trim();
    if url.is_empty() {
        return Err("这个版本没有提供下载地址".into());
    }
    // 和 registry 同一把尺子:https,本机除外(插件作者要能在本地试自己的源)。
    check_fetch_url(url)?;

    let bytes = state
        .http
        .get(url)
        .send()
        .await
        .map_err(|e| format!("下载失败: {e}"))?
        .error_for_status()
        .map_err(|e| format!("下载失败: {e}"))?
        .bytes()
        .await
        .map_err(|e| format!("下载失败: {e}"))?;

    reg::verify_package(ver.sha256.as_deref(), &bytes)?;

    // 临时文件落在自家 temp 根下(不是系统 %TEMP%),遵守「数据全在 userdata/」。
    let dir = linplayer_core::paths::temp_dir();
    std::fs::create_dir_all(&dir).map_err(|e| format!("建临时目录失败: {e}"))?;
    let tmp = dir.join(format!("{id}-{}.ipk", ver.version));
    std::fs::write(&tmp, &bytes).map_err(|e| format!("写临时文件失败: {e}"))?;

    let mgr = crate::plugins_mgr(&state)?;
    let result = mgr.install_ipk(&tmp.to_string_lossy());
    let _ = std::fs::remove_file(&tmp);
    let info = result?;

    Ok(json!({
        "info": info,
        "version": ver.version,
        "verified": ver.sha256.as_deref().map(|s| !s.trim().is_empty()).unwrap_or(false),
    }))
}

#[cfg(test)]
mod tests {
    use super::*;

    /// registry 决定「装哪个包」。明文 http 上被中间人改一行 packageUrl,
    /// 就等于让用户装上任意插件 —— 所以除本机外必须 https。
    #[test]
    fn fetch_url_requires_https_except_loopback() {
        assert!(check_fetch_url("https://example.com/registry.json").is_ok());
        assert!(check_fetch_url("http://127.0.0.1:8080/registry.json").is_ok());
        assert!(check_fetch_url("http://localhost/registry.json").is_ok());

        let e = check_fetch_url("http://example.com/registry.json").unwrap_err();
        assert!(e.contains("https"), "{e}");
        // 靠子串判断 loopback 会被这个骗过去
        assert!(check_fetch_url("http://127.0.0.1.evil.com/r.json").is_err());
        assert!(check_fetch_url("file:///etc/passwd").is_err());
        assert!(check_fetch_url("不是 URL").is_err());
    }

    /// 同一个 URL 加两次不能变成两条源(否则聚合时同一批插件会重复出现)。
    #[test]
    fn source_id_is_derived_from_url_and_is_case_insensitive() {
        let a = source_id_for("https://Example.com/R.json");
        assert_eq!(a, source_id_for("  https://example.com/R.json  "));
        assert_ne!(a, source_id_for("https://example.com/other.json"));
        assert_eq!(a.len(), 12);
    }
}
