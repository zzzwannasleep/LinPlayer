//! 插件数据源桥:把插件的三个 JS 函数转发成 `MediaSourceBackend`。
//!
//! 这是整个插件系统 v2 的承重梁。`MediaSourceBackend` 只有三个方法,却什么都塞得进去:
//! `source/smb.rs` 用它扛「共享列表 → 目录树 → 随机读」,`source/local.rs` 用它扛本机文件夹,
//! 资源站插件用它扛「分类 → 详情 → 分集」——**接口够用是实测过的,不是推断的**。
//! 把它原样开放给 JS,插件作者
//! 写三个函数就白拿:浏览页 / 搜索 / 播放 / 外挂字幕 / 多清晰度 / 跨服聚合,
//! 零新页面零新命令。
//!
//! 插件侧:
//! ```js
//! ctx.sources.register("mysrc", {
//!   async listDir(dirId, server)                { return [entry, ...] },
//!   async search(query, server)                 { throw ctx.errors.unsupported() },
//!   async resolvePlay(entry, qualityId, server) { return { url, title, ... } },
//! })
//! ```
//!
//! **网络走插件自己的 `ctx.http`**(受域名白名单 + `$sourceServer` 约束),
//! 不把宿主的 `reqwest::Client` 借给它 —— 借了等于绕过整套白名单。

use std::collections::HashMap;
use std::sync::Weak;

use serde_json::{json, Value as Json};

use super::{
    is_video_file_name, MediaCard, MediaCategory, MediaDetail, MediaEpisode, MediaLine, MediaPage,
    MediaSourceBackend, PlayQuality, ResolvedPlay, SourceEntry, SourceError, SourceKind,
    SourceServer, SourceSubtitle,
};
use crate::plugins::{PluginManager, UNSUPPORTED_MARKER};

pub struct PluginSourceBackend {
    plugin_id: String,
    src_id: String,
    /// Weak:manager 持有 backend 注册表,backend 又要回调 manager。
    /// 强引用会成环,插件卸载时整条链都不释放。
    mgr: Weak<PluginManager>,
}

impl PluginSourceBackend {
    pub fn new(plugin_id: impl Into<String>, src_id: impl Into<String>, mgr: Weak<PluginManager>) -> Self {
        Self { plugin_id: plugin_id.into(), src_id: src_id.into(), mgr }
    }

    async fn call(&self, method: &str, args: Json) -> Result<Json, SourceError> {
        let mgr = self
            .mgr
            .upgrade()
            .ok_or_else(|| SourceError::msg("插件系统已关闭"))?;
        mgr.call_source(&self.plugin_id, &self.src_id, method, args)
            .await
            .map_err(|e| js_error_to_source_error(&e))
    }
}

/// 把插件抛出的 JS 异常还原成 `SourceError`。
///
/// `ctx.errors.unsupported()` 带特征前缀 —— 它表示「这个源没有这个能力」,
/// UI 该退回本地过滤,而不是弹一条红色报错。两者混为一谈的话,每个不支持搜索的
/// 插件源都会在用户每次搜索时糊一脸错误。
fn js_error_to_source_error(msg: &str) -> SourceError {
    if let Some(rest) = msg.find(UNSUPPORTED_MARKER) {
        let detail = msg[rest + UNSUPPORTED_MARKER.len()..].trim();
        return if detail.is_empty() {
            SourceError::unsupported()
        } else {
            SourceError::msg(detail)
        };
    }
    // 鉴权失效要能被 UI 认出来并引导重登。插件用文案表达,这里做关键词识别。
    let lowered = msg.to_lowercase();
    if lowered.contains("401") || lowered.contains("unauthorized") || msg.contains("登录") {
        SourceError::auth(msg)
    } else {
        SourceError::msg(msg)
    }
}

/// 下发给插件的服务器信息。**只给连接必需的字段**,不整包丢过去 ——
/// `SourceServer` 将来加字段时,不该自动流进所有插件。
fn server_for_js(server: &SourceServer) -> Json {
    json!({
        "id": server.id,
        "baseUrl": server.base_url,
        "username": server.username,
        "password": server.password,
        "token": server.token,
        "extra": server.extra,
    })
}

/// JS 返回的一行 -> SourceEntry。
///
/// `isVideo` 允许插件不填 —— 缺省按扩展名自动判定。插件各自维护一份扩展名表必然漂移,
/// 漂移的后果是「某种格式在内置源能播、在插件源里根本不显示」。
fn entry_from_js(v: &Json) -> Option<SourceEntry> {
    let id = v.get("id")?.as_str()?.to_string();
    let name = v
        .get("name")
        .and_then(|x| x.as_str())
        .unwrap_or(&id)
        .to_string();
    let is_dir = v.get("isDir").and_then(|x| x.as_bool()).unwrap_or(false);
    let is_video = v
        .get("isVideo")
        .and_then(|x| x.as_bool())
        .unwrap_or_else(|| !is_dir && is_video_file_name(&name));
    Some(SourceEntry {
        id,
        name,
        is_dir,
        is_video,
        size: v.get("size").and_then(|x| x.as_i64()),
        thumb_url: v
            .get("thumb")
            .or_else(|| v.get("thumbUrl"))
            .and_then(|x| x.as_str())
            .map(|s| s.to_string()),
        raw: v.get("raw").cloned(),
    })
}

fn entries_from_js(v: Json) -> Result<Vec<SourceEntry>, SourceError> {
    let arr = v
        .as_array()
        .ok_or_else(|| SourceError::msg("插件数据源必须返回数组"))?;
    // 逐条跳过畸形项而不是整页失败 —— 一条缺 id 的记录不该让整个目录打不开。
    Ok(arr.iter().filter_map(entry_from_js).collect())
}

fn headers_from_js(v: Option<&Json>) -> HashMap<String, String> {
    let mut out = HashMap::new();
    if let Some(obj) = v.and_then(|x| x.as_object()) {
        for (k, val) in obj {
            let s = match val {
                Json::String(s) => s.clone(),
                other => other.to_string(),
            };
            out.insert(k.clone(), s);
        }
    }
    out
}

fn resolved_from_js(v: &Json, fallback_title: &str) -> Result<ResolvedPlay, SourceError> {
    let url = v
        .get("url")
        .and_then(|x| x.as_str())
        .filter(|s| !s.trim().is_empty())
        .ok_or_else(|| SourceError::msg("插件未返回可播放地址(url)"))?
        .to_string();

    let subtitles = v
        .get("subtitles")
        .and_then(|x| x.as_array())
        .map(|arr| {
            arr.iter()
                .filter_map(|s| {
                    Some(SourceSubtitle {
                        url: s.get("url")?.as_str()?.to_string(),
                        title: s.get("title").and_then(|x| x.as_str()).map(|x| x.to_string()),
                        language: s.get("language").and_then(|x| x.as_str()).map(|x| x.to_string()),
                        http_headers: headers_from_js(s.get("httpHeaders")),
                    })
                })
                .collect()
        })
        .unwrap_or_default();

    let qualities = v
        .get("qualities")
        .and_then(|x| x.as_array())
        .map(|arr| {
            arr.iter()
                .filter_map(|q| {
                    let id = q.get("id")?.as_str()?.to_string();
                    Some(PlayQuality {
                        label: q
                            .get("label")
                            .and_then(|x| x.as_str())
                            .unwrap_or(&id)
                            .to_string(),
                        rank: q.get("rank").and_then(|x| x.as_i64()).unwrap_or(0) as i32,
                        id,
                    })
                })
                .collect()
        })
        .unwrap_or_default();

    Ok(ResolvedPlay {
        url,
        title: v
            .get("title")
            .and_then(|x| x.as_str())
            .filter(|s| !s.is_empty())
            .unwrap_or(fallback_title)
            .to_string(),
        http_headers: headers_from_js(v.get("httpHeaders")),
        user_agent_override: v
            .get("userAgent")
            .and_then(|x| x.as_str())
            .map(|s| s.to_string()),
        subtitles,
        selected_quality_id: v
            .get("quality")
            .or_else(|| v.get("selectedQualityId"))
            .and_then(|x| x.as_str())
            .map(|s| s.to_string()),
        qualities,
    })
}

// ── 影视目录能力的 JS ↔ Rust 映射 ────────────────────────────────────────
// 一律「缺字段就留空」而不是报错:插件少填一个 year 不该让整页打不开。

fn s(v: &Json, k: &str) -> Option<String> {
    v.get(k)
        .and_then(|x| match x {
            Json::String(s) => Some(s.clone()),
            Json::Number(n) => Some(n.to_string()),
            _ => None,
        })
        .filter(|x| !x.trim().is_empty())
}

fn category_from_js(v: &Json) -> Option<MediaCategory> {
    let id = s(v, "id")?;
    Some(MediaCategory {
        name: s(v, "name").unwrap_or_else(|| id.clone()),
        id,
        children: v
            .get("children")
            .and_then(|x| x.as_array())
            .map(|a| a.iter().filter_map(category_from_js).collect())
            .unwrap_or_default(),
    })
}

fn card_from_js(v: &Json) -> Option<MediaCard> {
    let id = s(v, "id")?;
    Some(MediaCard {
        title: s(v, "title").unwrap_or_else(|| id.clone()),
        id,
        poster: s(v, "poster"),
        badge: s(v, "badge"),
        year: s(v, "year"),
        score: s(v, "score"),
        is_series: v.get("isSeries").and_then(|x| x.as_bool()).unwrap_or(false),
    })
}

fn detail_from_js(v: &Json, fallback_id: &str) -> MediaDetail {
    MediaDetail {
        id: s(v, "id").unwrap_or_else(|| fallback_id.to_string()),
        title: s(v, "title").unwrap_or_default(),
        poster: s(v, "poster"),
        badge: s(v, "badge"),
        year: s(v, "year"),
        area: s(v, "area"),
        lang: s(v, "lang"),
        genre: s(v, "genre"),
        score: s(v, "score"),
        overview: s(v, "overview"),
        actors: s(v, "actors"),
        director: s(v, "director"),
        lines: v
            .get("lines")
            .and_then(|x| x.as_array())
            .map(|a| {
                a.iter()
                    .filter_map(|l| {
                        let id = s(l, "id")?;
                        Some(MediaLine {
                            name: s(l, "name").unwrap_or_else(|| id.clone()),
                            id,
                            episodes: l
                                .get("episodes")
                                .and_then(|x| x.as_array())
                                .map(|eps| {
                                    eps.iter()
                                        .filter_map(|e| {
                                            let id = s(e, "id")?;
                                            Some(MediaEpisode {
                                                name: s(e, "name").unwrap_or_else(|| id.clone()),
                                                id,
                                                raw: e.get("raw").cloned(),
                                            })
                                        })
                                        .collect()
                                })
                                .unwrap_or_default(),
                        })
                    })
                    .collect()
            })
            .unwrap_or_default(),
    }
}

#[async_trait::async_trait]
impl MediaSourceBackend for PluginSourceBackend {
    fn kind(&self) -> SourceKind {
        SourceKind::plugin(&self.plugin_id, &self.src_id)
    }

    async fn list_dir(
        &self,
        _http: &reqwest::Client,
        server: &SourceServer,
        dir_id: Option<&str>,
    ) -> Result<Vec<SourceEntry>, SourceError> {
        let out = self
            .call("listDir", json!([dir_id, server_for_js(server)]))
            .await?;
        entries_from_js(out)
    }

    async fn search(
        &self,
        _http: &reqwest::Client,
        server: &SourceServer,
        query: &str,
    ) -> Result<Vec<SourceEntry>, SourceError> {
        // 插件没实现 search 这个字段时,handler 派发返回 Null(不是报错)。
        // 那等同于「不支持」,让 UI 退回本地过滤 —— 而不是当成一次空结果,
        // 否则用户会以为搜到了 0 条。
        let out = self
            .call("search", json!([query, server_for_js(server)]))
            .await?;
        if out.is_null() {
            return Err(SourceError::unsupported());
        }
        entries_from_js(out)
    }

    async fn resolve_play(
        &self,
        _http: &reqwest::Client,
        server: &SourceServer,
        entry: &SourceEntry,
        quality_id: Option<&str>,
    ) -> Result<ResolvedPlay, SourceError> {
        let entry_js = json!({
            "id": entry.id,
            "name": entry.name,
            "isDir": entry.is_dir,
            "isVideo": entry.is_video,
            "size": entry.size,
            "raw": entry.raw,
        });
        let out = self
            .call(
                "resolvePlay",
                json!([entry_js, quality_id, server_for_js(server)]),
            )
            .await?;
        if out.is_null() {
            return Err(SourceError::msg("插件未实现 resolvePlay"));
        }
        resolved_from_js(&out, &entry.name)
    }

    // ── 影视目录能力 ──────────────────────────────────────────────────
    // 插件没实现对应字段时 handler 派发返回 Null(不是抛错),那等同于「不支持」——
    // 必须还原成 unsupported,否则前端会把「这个源是网盘」当成「这个源坏了」。

    async fn categories(
        &self,
        _http: &reqwest::Client,
        server: &SourceServer,
    ) -> Result<Vec<MediaCategory>, SourceError> {
        let out = self.call("categories", json!([server_for_js(server)])).await?;
        if out.is_null() {
            return Err(SourceError::unsupported_feature("影视目录"));
        }
        let arr = out
            .as_array()
            .ok_or_else(|| SourceError::msg("categories 必须返回数组"))?;
        Ok(arr.iter().filter_map(category_from_js).collect())
    }

    async fn catalog(
        &self,
        _http: &reqwest::Client,
        server: &SourceServer,
        category_id: Option<&str>,
        keyword: Option<&str>,
        page: u32,
    ) -> Result<MediaPage, SourceError> {
        let req = json!({ "categoryId": category_id, "keyword": keyword, "page": page });
        let out = self
            .call("catalog", json!([req, server_for_js(server)]))
            .await?;
        if out.is_null() {
            return Err(SourceError::unsupported_feature("影视目录"));
        }
        let items = out
            .get("items")
            .and_then(|x| x.as_array())
            .ok_or_else(|| SourceError::msg("catalog 必须返回 { items: [...] }"))?
            .iter()
            .filter_map(card_from_js)
            .collect();
        Ok(MediaPage {
            items,
            page,
            // 插件没明说就按「还有」处理会让前端无限拉空页;默认 false 更安全。
            has_more: out.get("hasMore").and_then(|x| x.as_bool()).unwrap_or(false),
            total: out.get("total").and_then(|x| x.as_u64()).map(|x| x as u32),
        })
    }

    async fn media_detail(
        &self,
        _http: &reqwest::Client,
        server: &SourceServer,
        id: &str,
    ) -> Result<MediaDetail, SourceError> {
        let out = self
            .call("mediaDetail", json!([id, server_for_js(server)]))
            .await?;
        if out.is_null() {
            return Err(SourceError::unsupported_feature("影视目录"));
        }
        Ok(detail_from_js(&out, id))
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    /// `unsupported` 必须能从 JS 异常里还原,否则每个不支持搜索的插件源
    /// 都会在用户每次搜索时糊一脸红字,而正确行为是静默退回本地过滤。
    #[test]
    fn unsupported_marker_round_trips_from_js_exception() {
        // rquickjs 抛出的文案通常带前后缀,所以是「包含」而不是「等于」
        let e = js_error_to_source_error(&format!("Error: {UNSUPPORTED_MARKER}"));
        assert_eq!(e.message, "该源不支持搜索");
        assert!(!e.is_auth);

        let e = js_error_to_source_error(&format!("{UNSUPPORTED_MARKER}这个源只能浏览"));
        assert_eq!(e.message, "这个源只能浏览");

        // 普通错误不该被误判成 unsupported
        let e = js_error_to_source_error("网络超时");
        assert_eq!(e.message, "网络超时");
    }

    /// 鉴权失效要能被 UI 认出来并引导重登,否则用户只会看到一条读不懂的错。
    #[test]
    fn auth_failures_are_flagged_for_the_relogin_prompt() {
        for msg in ["HTTP 401", "Unauthorized", "登录已过期"] {
            assert!(js_error_to_source_error(msg).is_auth, "{msg} 应判为鉴权失效");
        }
        assert!(!js_error_to_source_error("连接被拒绝").is_auth);
    }

    /// isVideo 缺省要按宿主那份扩展名表自动判定。插件各自维护一份必然漂移,
    /// 漂移的后果是「某种格式在内置源能播、在插件源里根本不显示」。
    #[test]
    fn is_video_defaults_to_the_host_extension_table() {
        let e = entry_from_js(&json!({"id":"a","name":"片子.MKV"})).unwrap();
        assert!(e.is_video, "宿主认得 mkv,插件没填也该判为视频");

        let e = entry_from_js(&json!({"id":"b","name":"cover.jpg"})).unwrap();
        assert!(!e.is_video);

        // 目录永远不是视频,哪怕名字带扩展名
        let e = entry_from_js(&json!({"id":"c","name":"season.mkv","isDir":true})).unwrap();
        assert!(e.is_dir && !e.is_video);

        // 插件显式指定时以插件为准(strm/直链这类无扩展名的场景要靠它)
        let e = entry_from_js(&json!({"id":"d","name":"无扩展名","isVideo":true})).unwrap();
        assert!(e.is_video);
    }

    /// 一条畸形记录不该让整个目录打不开。
    #[test]
    fn malformed_rows_are_skipped_not_fatal() {
        let out = entries_from_js(json!([
            {"id":"ok1","name":"A"},
            {"name":"缺 id"},
            "根本不是对象",
            {"id":"ok2","name":"B"}
        ]))
        .unwrap();
        assert_eq!(out.len(), 2);
        assert_eq!(out[0].id, "ok1");
        assert_eq!(out[1].id, "ok2");

        // 但整体不是数组就是插件写错了,必须报出来
        assert!(entries_from_js(json!({"items":[]})).is_err());
    }

    #[test]
    fn resolved_play_maps_headers_subtitles_and_qualities() {
        let r = resolved_from_js(
            &json!({
                "url": "https://cdn.example.com/a.mkv",
                "httpHeaders": { "Referer": "https://example.com", "X-N": 42 },
                "userAgent": "MyPlugin/1.0",
                "subtitles": [
                    { "url": "https://x/a.ass", "title": "中文", "language": "chi",
                      "httpHeaders": { "Cookie": "k=v" } },
                    { "title": "缺 url 的要被跳过" }
                ],
                "qualities": [ { "id": "1080", "label": "1080P", "rank": 2 }, { "id": "720" } ],
                "quality": "1080"
            }),
            "兜底标题",
        )
        .unwrap();

        assert_eq!(r.title, "兜底标题", "插件没给 title 就用条目名");
        assert_eq!(r.http_headers.get("Referer").unwrap(), "https://example.com");
        assert_eq!(r.http_headers.get("X-N").unwrap(), "42", "非字符串头要转成字符串");
        assert_eq!(r.user_agent_override.as_deref(), Some("MyPlugin/1.0"));

        assert_eq!(r.subtitles.len(), 1, "缺 url 的字幕轨要被跳过");
        assert_eq!(r.subtitles[0].http_headers.get("Cookie").unwrap(), "k=v");

        assert_eq!(r.qualities.len(), 2);
        assert_eq!(r.qualities[1].label, "720", "没给 label 就用 id");
        assert_eq!(r.selected_quality_id.as_deref(), Some("1080"));
    }

    /// 没有 url 的返回必须是错误。放过去的话播放器会收到空地址,
    /// 表现是「点了没反应」,比报错难查得多。
    #[test]
    fn resolve_without_url_is_an_error() {
        assert!(resolved_from_js(&json!({ "title": "x" }), "t").is_err());
        assert!(resolved_from_js(&json!({ "url": "   " }), "t").is_err());
    }

    /// 下发给插件的 server 只含连接必需字段 —— `SourceServer` 将来加字段时,
    /// 不该自动流进所有插件。
    #[test]
    fn server_payload_is_an_explicit_allowlist() {
        let mut extra = HashMap::new();
        extra.insert("cookie".to_string(), "c".to_string());
        let s = SourceServer {
            id: "i".into(),
            base_url: "https://h".into(),
            username: Some("u".into()),
            password: Some("p".into()),
            token: Some("t".into()),
            extra,
        };
        let js = server_for_js(&s);
        let keys: Vec<&str> = js.as_object().unwrap().keys().map(|s| s.as_str()).collect();
        assert_eq!(keys, ["baseUrl", "extra", "id", "password", "token", "username"]);
    }

    #[test]
    fn kind_is_the_plugin_scoped_key() {
        let b = PluginSourceBackend::new("com.example.foo", "mysrc", Weak::new());
        assert_eq!(b.kind().as_str(), "plugin:com.example.foo/mysrc");
        assert_eq!(b.kind().as_plugin(), Some(("com.example.foo", "mysrc")));
    }

    /// manager 已经没了(App 正在关闭)时不能 panic,要给一条能读的错误。
    #[tokio::test]
    async fn dead_manager_yields_an_error_not_a_panic() {
        let b = PluginSourceBackend::new("com.example.foo", "mysrc", Weak::new());
        let http = reqwest::Client::new();
        let server = SourceServer::default();
        let e = b
            .list_dir(&http, &server, None)
            .await
            .err()
            .expect("manager 已释放时必须返回错误而不是成功");
        assert!(e.message.contains("插件系统"), "{}", e.message);
    }
}
