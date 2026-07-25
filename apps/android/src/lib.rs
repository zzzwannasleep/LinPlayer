//! LinPlayer Android TV 宿主壳。
//!
//! ## 它和 apps/desktop 是什么关系
//! 仍然**不依赖** apps/desktop —— 那个包绑死 tauri 桌面特性,交叉编译到
//! aarch64-linux-android 第一步就死。两端共用的是 crate:
//!   * `crates/core` —— 平台无关的数据源/网络/配置;
//!   * `crates/mpv`  —— libmpv 封装 + 各平台渲染面(2026-07-20 从桌面壳提出来的)。
//!
//! 本文件里的命令是从 `apps/desktop/src/lib.rs` **逐字照抄签名和返回类型**的。
//! 前端 `ui/shared/api.ts` 的 TS 类型和这些结构体逐字段对应,改一个名字前端就静默拿到
//! undefined —— 不报错,只是数据不见了。加字段/改名请两端一起改。
//!
//! ## 播放链路(安卓)
//! `libmpv.so` 由 Java 层 `System.loadLibrary("mpv")` 加载,渲染面是垫在透明 WebView
//! 底下的 SurfaceView。两条都不能省,理由分别写在 MainActivity.kt 和 crates/mpv 的
//! `mod overlay` 里。
//!
//! ⚠️ **本轮接入未经真机验证** —— 手上没有安卓设备,CI 只能证明它编得过、
//! libmpv.so 确实进了 APK。首次真机跑挂了先看 `adb logcat -s mpv`。

mod imgcache;

use linplayer_core::config::{Account, AppConfig, Prefs};
use linplayer_core::emby::{self, Item, LoginResult, Session};
use linplayer_core::http;
use linplayer_core::media::Track;
use linplayer_core::source::aliyundrive::{self, AliyunDriveBackend};
use linplayer_core::source::anirss::AniRssBackend;
use linplayer_core::source::baidu::{self, BaiduBackend};
use linplayer_core::source::feiniu::FeiniuBackend;
use linplayer_core::source::openlist::OpenListBackend;
use linplayer_core::source::pan115::Pan115Backend;
use linplayer_core::source::pan139::{self, Pan139Backend};
use linplayer_core::source::pan189::{self, Pan189Backend};
use linplayer_core::source::quark::QuarkBackend;
use linplayer_core::source::stremio::StremioBackend;
use linplayer_core::source::{
    MediaSourceBackend, QrPoll, QrStart, SourceEntry, SourceKind, SourceServer,
};
use linplayer_core::sync::{bangumi, trakt};
use std::collections::HashMap;
use std::sync::{Arc, Mutex};
use tauri::{Emitter, Manager, State};

struct AppState {
    http: reqwest::Client,
    config: Mutex<AppConfig>,
    session: Mutex<Option<Session>>,
    // 文件浏览型源:后端注册表(长驻,持 token 缓存)+ 当前活跃源
    source_backends: HashMap<SourceKind, Arc<dyn MediaSourceBackend>>,
    source: Mutex<Option<(SourceKind, SourceServer)>>,
    // 多线程下载管理器(长驻,持久化索引)。
    download: linplayer_core::download::DownloadManager,
    // server_id -> 连通状态三态。probe_accounts 刷新,list_accounts 读;不落盘(重启即重探)。
    account_status: Mutex<HashMap<String, AccountStatus>>,
    // check_update 查到的待装版本。存核层是为了不让前端把资产清单原样传回来。
    pending_update: Mutex<Option<linplayer_core::update::UpdateInfo>>,
    // 本次播放的同步上下文(Trakt/Bangumi)。play 时抓,stop 时消费。与桌面同构。
    scrobble_ctx: Mutex<Option<emby::ScrobbleInfo>>,
    // 手机控制台的局域网小服务(默认开机即起)。Drop 即停服。
    companion: Mutex<Option<linplayer_core::companion::Companion>>,
    // 当前在放什么(标题, 副标题)。mpv 的 Status 里没有片名,而手机控制台要显示。
    now_playing: Mutex<Option<(String, Option<String>)>>,
}

fn session_of(state: &State<'_, AppState>) -> Result<Session, String> {
    state
        .session
        .lock()
        .unwrap()
        .clone()
        .ok_or_else(|| "未登录".to_string())
}

/* ============================================================
   播放器 —— 原生 libmpv(与桌面同一份 crates/mpv)
   ============================================================ */

use linplayer_mpv::{Player, Status};

/// 播放器实例 + 当前 Emby 播放会话。
///
/// ★ 为什么懒创建而不是启动时就建:安卓的 Surface 由系统在 surfaceCreated 回调里给,
///   App 启动那一刻它还不存在。启动时建 Player 必然拿到 wid=0 直接失败。
struct PlayerState {
    player: Mutex<Option<Player>>,
    /// 当前播放会话(Emby 上报三件套共享)。网盘/本地源没有,故 Option。
    playback: Mutex<Option<linplayer_core::emby::PlaybackTarget>>,
}

impl Default for PlayerState {
    fn default() -> Self {
        Self { player: Mutex::new(None), playback: Mutex::new(None) }
    }
}

/// 取播放器;没有就现建一个。
///
/// ★ 建失败的最常见原因是 Surface 还没就绪(用户在页面还没铺好时就按了播放),
///   这时**不缓存失败结果** —— 下次再调会重试,而不是一路错到重启 App。
fn ensure_player(ps: &PlayerState) -> Result<std::sync::MutexGuard<'_, Option<Player>>, String> {
    let mut g = ps.player.lock().unwrap();
    if g.is_none() {
        *g = Some(Player::new()?);
    }
    Ok(g)
}

#[tauri::command]
async fn play(
    state: State<'_, AppState>,
    ps: State<'_, PlayerState>,
    item_id: String,
    resume_secs: f64,
    media_source_id: Option<String>,
) -> Result<f64, String> {
    let s = session_of(&state)?;
    // 版本筛选正则(wiki regex-filters)与桌面同源,先取出再 await(别跨 await 攥 std Mutex)。
    let version_regex = state.config.lock().unwrap().prefs.version_regex.clone();
    let target =
        emby::resolve_stream(&state.http, &s, &item_id, media_source_id.as_deref(), &version_regex)
            .await?;

    // 播放器锁必须在后面那些 await 之前放掉:MutexGuard 不是 Send,
    // 跨 await 持有会让整个 command 的 future 不能在线程间移动(编译期直接拒)。
    {
        let g = ensure_player(&ps)?;
        let p = g.as_ref().unwrap();
        let _ = p.take_error_eof(); // 清历史失效标志
        p.load_at(&target.url, resume_secs)?;
        /* ★ 外挂字幕必须在 load 之后逐条 sub-add —— 它们是服务器上的独立文件,
           不在容器里,mpv 的 track-list 看不到。桌面同一处理,别让两端再分叉。 */
        for sub in &target.external_subs {
            p.add_subtitle(&sub.url, &sub.title);
        }
        if !target.external_subs.is_empty() {
            log::info!("挂载外挂字幕 {} 条", target.external_subs.len());
        }
        p.set_pause(false);
    }
    *ps.playback.lock().unwrap() = Some(target);

    // 播放期同步上下文。任一服务已连接才去抓(多一次请求,不白花)。
    *state.scrobble_ctx.lock().unwrap() = None;
    let (trakt_acc, bangumi_on) = {
        let cfg = state.config.lock().unwrap();
        (cfg.sync_trakt.clone(), cfg.sync_bangumi.is_some())
    };
    if trakt_acc.is_some() || bangumi_on {
        if let Some(info) = emby::fetch_scrobble_info(&state.http, &s, &item_id).await {
            *state.scrobble_ctx.lock().unwrap() = Some(info.clone());
            if let Some(acc) = trakt_acc {
                if info.has_trakt_ids() {
                    let progress = if info.runtime_secs > 0.0 {
                        (resume_secs / info.runtime_secs * 100.0).clamp(0.0, 100.0)
                    } else {
                        0.0
                    };
                    tauri::async_runtime::spawn(async move {
                        trakt::scrobble(&acc, &info.trakt_body(), progress, "start").await;
                    });
                }
            }
        }
    }
    Ok(resume_secs)
}

/* ponytail: 本地下载文件的起播先不接 —— 它还要先把下载索引这条链路在安卓上跑通。
   保持明确报错而不是假装成功:假装成功的表现是黑屏等一个永远不来的 status。 */
#[tauri::command]
fn play_local(_id: String, _resume_secs: f64) -> Result<f64, String> {
    Err("安卓端暂不支持播放本地下载文件".to_string())
}

/// 解析源文件为直链并用 mpv 播放(带逐流 headers)。返回起播秒数。
///
/// 与 `apps/desktop/src/lib.rs` 的同名命令同构。桌面那边多做两件安卓没有的事:
/// `apply_playback_defaults`(硬解/杜比档位是桌面设置项)和观看记录上下文。
#[tauri::command]
async fn source_play(
    state: State<'_, AppState>,
    ps: State<'_, PlayerState>,
    entry_id: String,
    entry_name: String,
    resume_secs: f64,
    raw: Option<serde_json::Value>,
) -> Result<f64, String> {
    // 源播放非 Emby,清 Trakt/Bangumi 上下文 —— 不清会把网盘进度记到上一部 Emby 片上。
    *state.scrobble_ctx.lock().unwrap() = None;
    let (kind, server) = state.source.lock().unwrap().clone().ok_or("未登录源")?;
    let backend = source_backend(&state, &kind)?;
    let entry = SourceEntry {
        id: entry_id,
        name: entry_name,
        is_dir: false,
        is_video: true,
        size: None,
        thumb_url: None,
        raw, // 透传源原始数据(Stremio 的 stream 对象、ani-rss 外挂字幕等靠它)
    };
    let resolved = backend
        .resolve_play(&state.http, &server, &entry, None)
        .await
        .map_err(|e| e.message)?;
    persist_rotated(&state, &kind, &backend);
    {
        // 播放器锁不能跨 await 持有(MutexGuard 不是 Send),所以解析完再取。
        let g = ensure_player(&ps)?;
        let p = g.as_ref().unwrap();
        let _ = p.take_error_eof(); // 清历史失效标志
        p.load_with_headers(
            &resolved.url,
            resume_secs,
            &resolved.http_headers,
            resolved.user_agent_override.as_deref(),
        )?;
        p.set_pause(false);
        // 外挂字幕必须 load 之后逐条 sub-add:它们不在容器里,track-list 看不到。
        for sub in &resolved.subtitles {
            p.add_subtitle(&sub.url, sub.title.as_deref().unwrap_or("字幕"));
        }
    }
    *ps.playback.lock().unwrap() = None; // 源播放不走 Emby 上报
    Ok(resume_secs)
}

/// 添加/切换一个浏览型源。与 `apps/desktop/src/lib.rs::source_login` 同构。
#[tauri::command]
async fn source_login(
    state: State<'_, AppState>,
    kind: SourceKind,
    base_url: String,
    username: String,
    password: String,
    cookie: Option<String>,
    // 与桌面端同构:令牌系源带 refresh_token 与可选 oplist 覆盖。additive。
    extra: Option<HashMap<String, String>>,
) -> Result<(), String> {
    // 夸克 Cookie 模式无 base_url(固定云端 API),用 kind 名做稳定 id。
    let id = if base_url.trim().is_empty() {
        kind.legacy_debug_label()
    } else {
        base_url.clone()
    };
    let server = SourceServer {
        id,
        base_url,
        username: (!username.is_empty()).then_some(username),
        password: (!password.is_empty()).then_some(password),
        token: cookie.filter(|c| !c.is_empty()),
        extra: extra.unwrap_or_default(),
    };
    let backend = source_backend(&state, &kind)?;
    // 列根目录以验证配置可用 —— 不验的话错地址也会"添加成功",进去才发现是空的。
    backend
        .list_dir(&state.http, &server, None)
        .await
        .map_err(|e| e.message)?;
    {
        let mut cfg = state.config.lock().unwrap();
        cfg.upsert(Account {
            server: server.id.clone(),
            user_name: server.username.clone().unwrap_or_else(|| kind.legacy_debug_label()),
            source_kind: kind.clone(),
            source: Some(server.clone()),
            ..Default::default()
        });
        cfg.save();
    }
    *state.source.lock().unwrap() = Some((kind, server));
    *state.session.lock().unwrap() = None; // 切到源 → 上一个 Emby 会话作废
    Ok(())
}

#[tauri::command]
fn seek(ps: State<'_, PlayerState>, pos: f64) -> Result<(), String> {
    let g = ps.player.lock().unwrap();
    g.as_ref().ok_or("播放器未就绪")?.seek_abs(pos)
}

#[tauri::command]
fn set_pause(ps: State<'_, PlayerState>, paused: bool) -> Result<(), String> {
    let g = ps.player.lock().unwrap();
    g.as_ref().ok_or("播放器未就绪")?.set_pause(paused);
    Ok(())
}

#[tauri::command]
fn set_track(ps: State<'_, PlayerState>, kind: String, id: String) -> Result<(), String> {
    let g = ps.player.lock().unwrap();
    g.as_ref().ok_or("播放器未就绪")?.set_track(&kind, &id);
    Ok(())
}

#[tauri::command]
fn status(ps: State<'_, PlayerState>) -> Result<Status, String> {
    let g = ps.player.lock().unwrap();
    Ok(g.as_ref().ok_or("播放器未就绪")?.status())
}

#[tauri::command]
fn tracks(ps: State<'_, PlayerState>) -> Result<Vec<Track>, String> {
    let g = ps.player.lock().unwrap();
    Ok(g.as_ref().ok_or("播放器未就绪")?.tracks())
}

#[tauri::command]
async fn stop_playback(
    state: State<'_, AppState>,
    ps: State<'_, PlayerState>,
    pos: f64,
) -> Result<(), String> {
    // 先上报再拆播放器:反过来的话 pos 已经取不到了。
    let target = ps.playback.lock().unwrap().take();
    if let Some(t) = target {
        if let Ok(s) = session_of(&state) {
            let _ = emby::report_stopped(&state.http, &s, &t, pos).await;
        }
    }
    sync_on_stop(&state, pos).await;
    /* ★ 必须真的 drop 掉 Player。安卓上留着它 = 一直占着 Surface 和 MediaCodec 实例,
       下次起播要么黑屏要么直接拿不到解码器(硬件解码器数量是有限的)。 */
    ps.player.lock().unwrap().take();
    Ok(())
}

/// 播放收尾时把进度同步到 Trakt / Bangumi。与桌面 stop_playback 里那段等价 ——
/// 安卓原来**整段都没有**,所以 TV 上看完从来不会出现在任何一边。
async fn sync_on_stop(state: &State<'_, AppState>, pos: f64) {
    let ctx = state.scrobble_ctx.lock().unwrap().take();
    let Some(info) = ctx else { return };
    let (trakt_acc, bangumi_acc) = {
        let cfg = state.config.lock().unwrap();
        (cfg.sync_trakt.clone(), cfg.sync_bangumi.clone())
    };
    let progress = if info.runtime_secs > 0.0 {
        (pos / info.runtime_secs * 100.0).clamp(0.0, 100.0)
    } else {
        0.0
    };
    let watched = progress >= WATCHED_PERCENT;
    if let Some(acc) = trakt_acc {
        if info.has_trakt_ids() {
            let body = info.trakt_body();
            let ok = trakt::scrobble(&acc, &body, progress, "stop").await;
            log::info!("[Trakt] scrobble stop {progress:.1}% -> {ok}");
            if watched {
                let ok = trakt::add_to_history(&acc, &body).await;
                log::info!("[Trakt] 写入观看历史 -> {ok}");
            }
        } else {
            log::info!("[Trakt] 跳过:条目和所属剧集都没有外部 ID");
        }
    }
    if let Some(acc) = bangumi_acc {
        if watched && !info.title.is_empty() {
            mark_bangumi_watched(&acc, &info).await;
        }
    }
}

/// 判定「看完」的进度阈值(与 Trakt 自动标记阈值一致)。
const WATCHED_PERCENT: f64 = 80.0;

/// 看完后标 Bangumi:反查 subject/episode → 在看 → 单集看过 →(最后一集)整部看过。
async fn mark_bangumi_watched(acc: &linplayer_core::sync::SyncAccount, info: &emby::ScrobbleInfo) {
    use linplayer_core::sync::bangumi_matcher;
    let matched = if info.media_type == "movie" {
        bangumi_matcher::resolve_movie(
            &info.title,
            info.original_title.as_deref(),
            info.air_date.as_deref(),
        )
        .await
    } else {
        bangumi_matcher::resolve_episode(
            &info.title,
            info.original_title.as_deref(),
            info.air_date.as_deref(),
            info.season,
            info.episode,
        )
        .await
    };
    let Some(r) = matched else {
        log::info!("[Bangumi] 反查不到条目,跳过: {}", info.title);
        return;
    };
    if info.media_type == "movie" {
        let ok = bangumi::set_collection_type(acc, r.subject_id, 2).await;
        log::info!("[Bangumi] 电影标记看过 -> {ok}");
        return;
    }
    let ok = bangumi::set_collection_type(acc, r.subject_id, 3).await;
    log::info!("[Bangumi] 收藏为在看 subject={} -> {ok}", r.subject_id);
    let ok = bangumi::update_episode_status(acc, r.subject_id, r.episode_id, 2).await;
    log::info!("[Bangumi] 单集标看过 ep={} -> {ok}", r.episode_id);
    if r.is_last_episode {
        let ok = bangumi::set_collection_type(acc, r.subject_id, 2).await;
        log::info!("[Bangumi] 最后一集,整部标看过 -> {ok}");
    }
}

/// 详情页背景模糊强度(0~100)。单独一个命令而不是塞进 set_prefs ——
/// set_prefs 只管选轨三项,整体覆盖会把别的偏好重置掉(那个坑上面注释里写着)。
#[tauri::command]
fn set_detail_blur(state: State<'_, AppState>, value: u8) -> Result<(), String> {
    if value > 100 {
        return Err("模糊强度只支持 0~100".into());
    }
    let mut cfg = state.config.lock().unwrap();
    cfg.prefs.detail_blur = value;
    cfg.save();
    Ok(())
}

/// 当前代理配置。TV 上原来完全没有这两个命令,设置页也就画不出代理项 ——
/// 机顶盒恰恰是最需要配代理的场景。
#[tauri::command]
fn get_proxy(state: State<'_, AppState>) -> linplayer_core::ProxyConfig {
    state.config.lock().unwrap().proxy.clone()
}

/// 保存代理并即时生效(新建的 HTTP 客户端全部带上;主 Emby 客户端下次启动完全生效)。
#[tauri::command]
fn set_proxy(state: State<'_, AppState>, config: linplayer_core::ProxyConfig) -> Result<(), String> {
    http::set_proxy(config.proxy_url());
    let mut cfg = state.config.lock().unwrap();
    cfg.proxy = config;
    cfg.save();
    Ok(())
}

/* ---------- Trakt / Bangumi 登录(TV 上原来根本登不上,只能看日历) ---------- */

#[tauri::command]
async fn trakt_device_code() -> Result<linplayer_core::sync::trakt::TraktDeviceCode, String> {
    trakt::request_device_code().await
}

#[tauri::command]
async fn trakt_poll(
    state: State<'_, AppState>,
    device_code: String,
) -> Result<linplayer_core::sync::trakt::TraktPollResult, String> {
    let r = trakt::poll_once(&device_code).await;
    if let Some(acc) = r.account.clone() {
        let mut cfg = state.config.lock().unwrap();
        cfg.sync_trakt = Some(acc);
        cfg.save();
    }
    Ok(r)
}

#[tauri::command]
fn trakt_logout(state: State<'_, AppState>) {
    let mut cfg = state.config.lock().unwrap();
    cfg.sync_trakt = None;
    cfg.save();
}

#[tauri::command]
fn bangumi_authorize_url(redirect_uri: Option<String>) -> String {
    let uri = redirect_uri.unwrap_or_else(|| bangumi::DEFAULT_REDIRECT_URI.to_string());
    bangumi::build_authorize_url(&uri)
}

#[tauri::command]
async fn bangumi_exchange(
    state: State<'_, AppState>,
    code: String,
    redirect_uri: Option<String>,
) -> Result<linplayer_core::sync::SyncAccount, String> {
    let uri = redirect_uri.unwrap_or_else(|| bangumi::DEFAULT_REDIRECT_URI.to_string());
    let acc = bangumi::exchange_code(&code, &uri).await?;
    let mut cfg = state.config.lock().unwrap();
    cfg.sync_bangumi = Some(acc.clone());
    cfg.save();
    Ok(acc)
}

/// 用个人 Access Token 登录 Bangumi(不经 CF 代理,电视上比粘贴 code 好操作得多)。
#[tauri::command]
async fn bangumi_login_token(
    state: State<'_, AppState>,
    token: String,
) -> Result<linplayer_core::sync::SyncAccount, String> {
    let acc = bangumi::login_with_access_token(&token).await?;
    let mut cfg = state.config.lock().unwrap();
    cfg.sync_bangumi = Some(acc.clone());
    cfg.save();
    Ok(acc)
}

#[tauri::command]
fn bangumi_logout(state: State<'_, AppState>) {
    let mut cfg = state.config.lock().unwrap();
    cfg.sync_bangumi = None;
    cfg.save();
}

#[tauri::command]
async fn report_progress(
    state: State<'_, AppState>,
    ps: State<'_, PlayerState>,
    pos: f64,
    paused: bool,
) -> Result<(), String> {
    let target = ps.playback.lock().unwrap().clone();
    let Some(t) = target else { return Ok(()) }; // 无会话(网盘源)跳过
    let s = session_of(&state)?;
    let _ = emby::report_progress(&state.http, &s, &t, pos, paused).await;
    Ok(())
}

/* ============================================================
   Emby 浏览 / 账号
   ============================================================ */

#[tauri::command]
async fn login(
    state: State<'_, AppState>,
    server: String,
    username: String,
    password: String,
) -> Result<LoginResult, String> {
    let device_id = state.config.lock().unwrap().device_id.clone();
    let (session, result) =
        emby::login(&state.http, &server, &username, &password, &device_id).await?;
    {
        let mut cfg = state.config.lock().unwrap();
        // 只在**首次添加**时设图标:upsert 对已存在账号是 `acc.icon_url.or(old)`,
        // 传 Some 会盖掉用户自定义的图标 —— 重登不能把人家换过的图标冲回头像。
        let is_new = cfg.find(&result.server).is_none();
        let icon_url = if is_new {
            result
                .primary_image_tag
                .as_deref()
                .filter(|t| !t.is_empty())
                .map(|tag| {
                    linplayer_core::server_batch::build_icon_url(
                        &result.server,
                        Some(&result.user_id),
                        Some(tag),
                    )
                })
        } else {
            None
        };
        cfg.upsert(Account {
            server: result.server.clone(),
            token: result.token.clone(),
            user_id: result.user_id.clone(),
            user_name: result.user_name.clone(),
            icon_url,
            password: (!password.is_empty()).then_some(password),
            ..Default::default()
        });
        cfg.save();
    }
    *state.session.lock().unwrap() = Some(session);
    *state.source.lock().unwrap() = None; // 登 Emby → 上一个源作废
    Ok(result)
}

/// 已登录的 Emby 账号(启动时跳过登录页直接进库);无则 None。
/// 活跃的是浏览型源时返回 None —— 它没有 Emby token,吐个空 token 的会话会被前端拿去打 401。
#[tauri::command]
fn current_session(state: State<'_, AppState>) -> Option<LoginResult> {
    state
        .config
        .lock()
        .unwrap()
        .active_account()
        .filter(|a| !a.is_file_browse())
        .map(|a| LoginResult {
            // 必须是**当前生效线路**:前端拿它直接拼封面地址,用账号主键会让切线路后
            // API 走新线、封面还打老线 —— 表现为"封面全白但不报错"。
            server: a.active_line_url(),
            token: a.token.clone(),
            user_id: a.user_id.clone(),
            user_name: a.user_name.clone(),
            primary_image_tag: None,
        })
}

#[derive(serde::Serialize)]
struct ServerGroup {
    server_id: String,
    server_name: String,
    items: Vec<Item>,
}

/// 跨所有已登录 Emby 服务器并行搜索,按服分组(单台失败隔离)。
#[tauri::command]
async fn aggregate_search(
    state: State<'_, AppState>,
    query: String,
) -> Result<Vec<ServerGroup>, String> {
    let (accounts, device_id) = {
        let cfg = state.config.lock().unwrap();
        (cfg.accounts.clone(), cfg.device_id.clone())
    };
    if query.trim().is_empty() || accounts.is_empty() {
        return Ok(vec![]);
    }
    let mut handles = Vec::new();
    for a in accounts {
        let http = state.http.clone();
        let device_id = device_id.clone();
        let query = query.clone();
        handles.push(tauri::async_runtime::spawn(async move {
            let s = Session {
                // 必须走生效线路:用账号主键会让聚合搜索永远打主线路,而用户切到备用线
                // 正是因为主线不通 —— 那台服务器会静默变成空结果从搜索里消失。
                server: a.active_line_url(),
                token: a.token.clone(),
                user_id: a.user_id.clone(),
                device_id,
            };
            // 跨服只出剧/电影,不出「集」(emby::search 传 None 默认会带 Episode)。
            let types = ["Movie".to_string(), "Series".to_string()];
            let items = emby::search(&http, &s, &query, Some(&types), None)
                .await
                .unwrap_or_default();
            ServerGroup {
                server_name: a.display_name(),
                server_id: a.server,
                items,
            }
        }));
    }
    let mut groups = Vec::new();
    for h in handles {
        if let Ok(g) = h.await {
            if !g.items.is_empty() {
                groups.push(g);
            }
        }
    }
    Ok(groups)
}

/// 切换活跃服务器。Emby 装 session,浏览型源装 source —— 一张表两种形态,
/// 切换必须两边都对齐,否则会留着上一个服的会话在那儿(切服失败还打错服务器)。
#[tauri::command]
fn set_active_server(state: State<'_, AppState>, server_id: String) -> Result<(), String> {
    let (account, device_id) = {
        let mut cfg = state.config.lock().unwrap();
        let idx = cfg
            .accounts
            .iter()
            .position(|a| a.server == server_id)
            .ok_or("找不到该服务器账号")?;
        cfg.active = Some(idx);
        let a = cfg.accounts[idx].clone();
        cfg.save();
        (a, cfg.device_id.clone())
    };
    if account.is_file_browse() {
        let server = account.source.clone().ok_or("该源缺少登录凭据,请重新登录")?;
        *state.source.lock().unwrap() = Some((account.source_kind.clone(), server));
        *state.session.lock().unwrap() = None;
    } else {
        *state.session.lock().unwrap() = Some(Session {
            server: account.active_line_url(),
            token: account.token,
            user_id: account.user_id,
            device_id,
        });
        *state.source.lock().unwrap() = None;
    }
    Ok(())
}

#[tauri::command]
async fn views(state: State<'_, AppState>) -> Result<Vec<Item>, String> {
    let s = session_of(&state)?;
    emby::views(&state.http, &s).await
}

/// 媒体库浏览(翻页 + 排序 + 筛选)。
/// 参数全 Option:Tauri 对缺省字段反序列化成 None,前端只传 parentId 也能调。
#[tauri::command]
async fn list_items_page(
    state: State<'_, AppState>,
    parent_id: String,
    start_index: Option<u32>,
    limit: Option<u32>,
    sort_by: Option<String>,
    sort_order: Option<String>,
    genres: Option<Vec<String>>,
    tags: Option<Vec<String>>,
    years: Option<Vec<i32>>,
    studios: Option<Vec<String>>,
    rating_min: Option<f64>,
    rating_max: Option<f64>,
) -> Result<emby::ItemPage, String> {
    let s = session_of(&state)?;
    let q = emby::ItemQuery {
        start_index,
        limit,
        sort_by,
        sort_order,
        genres,
        tags,
        years,
        studios,
        rating_min,
        rating_max,
    };
    emby::items(&state.http, &s, &parent_id, &q).await
}

/// 媒体库筛选分面(类型/标签/时间/工作室/分级)。
#[tauri::command]
async fn get_filters(state: State<'_, AppState>, parent_id: String) -> Result<emby::Filters, String> {
    let s = session_of(&state)?;
    emby::filters(&state.http, &s, &parent_id).await
}

/// 标记已看/未看。
#[tauri::command]
async fn set_played(state: State<'_, AppState>, item_id: String, played: bool) -> Result<(), String> {
    let s = session_of(&state)?;
    emby::set_played(&state.http, &s, &item_id, played).await
}

/// 接下来播放。
#[tauri::command]
async fn list_next_up(state: State<'_, AppState>, limit: u32) -> Result<Vec<Item>, String> {
    let s = session_of(&state)?;
    emby::next_up(&state.http, &s, limit).await
}

/// 搜索(可指定类型/条数;默认含 Episode)。
#[tauri::command]
async fn search(
    state: State<'_, AppState>,
    query: String,
    types: Option<Vec<String>>,
    limit: Option<u32>,
) -> Result<Vec<Item>, String> {
    let s = session_of(&state)?;
    emby::search(&state.http, &s, &query, types.as_deref(), limit).await
}

/// 相似推荐。空结果不是错误 —— 有些条目就是没有相似项,前端整段不渲染。
#[tauri::command]
async fn similar_items(state: State<'_, AppState>, item_id: String) -> Result<Vec<Item>, String> {
    let s = session_of(&state)?;
    emby::similar(&state.http, &s, &item_id, 12).await
}

/// 首页某库"最新更新"轨道。
#[tauri::command]
async fn list_latest(
    state: State<'_, AppState>,
    parent_id: String,
    limit: u32,
) -> Result<Vec<Item>, String> {
    let s = session_of(&state)?;
    emby::latest(&state.http, &s, &parent_id, limit).await
}

/// 继续观看。
#[tauri::command]
async fn list_resume(state: State<'_, AppState>, limit: u32) -> Result<Vec<Item>, String> {
    let s = session_of(&state)?;
    emby::resume(&state.http, &s, limit).await
}

/// 首页 Hero 随机推荐。
#[tauri::command]
async fn list_random(state: State<'_, AppState>, limit: u32) -> Result<Vec<Item>, String> {
    let s = session_of(&state)?;
    emby::random_picks(&state.http, &s, limit).await
}

/// 详情页:元信息 + 剧集列表。
#[tauri::command]
async fn item_detail(
    state: State<'_, AppState>,
    item_id: String,
) -> Result<emby::ItemDetail, String> {
    let s = session_of(&state)?;
    emby::detail(&state.http, &s, &item_id).await
}

/// 条目的全部版本+流(详情页「版本/音轨/字幕」选择器 + 媒体信息块)。
#[tauri::command]
async fn item_media(
    state: State<'_, AppState>,
    item_id: String,
) -> Result<Vec<emby::MediaVersion>, String> {
    let s = session_of(&state)?;
    emby::media_versions(&state.http, &s, &item_id).await
}

/// 收藏列表。
#[tauri::command]
async fn list_favorites(state: State<'_, AppState>) -> Result<Vec<Item>, String> {
    let s = session_of(&state)?;
    emby::favorites(&state.http, &s).await
}

/// 切换收藏。
#[tauri::command]
async fn set_favorite(state: State<'_, AppState>, item_id: String, fav: bool) -> Result<(), String> {
    let s = session_of(&state)?;
    emby::set_favorite(&state.http, &s, &item_id, fav).await
}

/* ============================================================
   服务器页 —— 账号表 / 线路
   ============================================================ */

/// 服务器连通状态。三态:绿=正常 / 黄=需重登 / 灰=未连。
/// `Unknown` 是「还没探过」,与"探过了确实不通"同色不同义 —— 别在 Rust 侧合并成一个,
/// 合并了就没法区分"没测"和"测了挂了"。
#[derive(serde::Serialize, Clone, Copy, PartialEq, Debug)]
#[serde(rename_all = "snake_case")]
enum AccountStatus {
    Ok,
    Reauth,
    Down,
    Unknown,
}

/// 服务器页:服务器列表(Emby + 浏览型源,统一一张表)。
#[derive(serde::Serialize)]
struct AccountInfo {
    server: String,
    user_name: String,
    user_id: String,
    /// 是否当前选中的服务器。**不是**连通状态 —— 状态看 `status`。
    active: bool,
    status: AccountStatus,
    name: String,
    remark: Option<String>,
    icon_url: Option<String>,
    lines: Vec<linplayer_core::config::ServerLine>,
    active_line: usize,
    /// 当前生效的上游线路地址(未经 CF 反代改写)。
    line_url: String,
    allow_insecure_tls: bool,
    source_kind: SourceKind,
    /// 是否文件浏览型源(非 Emby)——前端据此决定进媒体库还是进文件浏览。
    is_file_browse: bool,
}

fn account_info_with(
    a: &linplayer_core::Account,
    active: bool,
    status: AccountStatus,
) -> AccountInfo {
    AccountInfo {
        server: a.server.clone(),
        user_name: a.user_name.clone(),
        user_id: a.user_id.clone(),
        active,
        status,
        name: a.display_name(),
        remark: a.remark.clone(),
        icon_url: a.icon_url.clone(),
        lines: a.lines.clone(),
        active_line: a.active_line,
        line_url: a.direct_line_url().to_string(),
        allow_insecure_tls: a.allow_insecure_tls,
        source_kind: a.source_kind.clone(),
        is_file_browse: a.is_file_browse(),
    }
}

#[tauri::command]
fn list_accounts(state: State<'_, AppState>) -> Vec<AccountInfo> {
    let cfg = state.config.lock().unwrap();
    let active = cfg.active;
    let statuses = state.account_status.lock().unwrap();
    cfg.accounts
        .iter()
        .enumerate()
        .map(|(i, a)| {
            let st = statuses.get(&a.server).copied().unwrap_or(AccountStatus::Unknown);
            account_info_with(a, Some(i) == active, st)
        })
        .collect()
}

/// 单台探测。**必须走 active_line_url()** —— 用户切了备用线路正是因为主线不通,
/// 拿主线去探会把一台好服务器判成灰,而用户看到的又是"我明明能用"。
async fn probe_account(http: &reqwest::Client, a: &linplayer_core::Account) -> AccountStatus {
    let base = a.active_line_url();
    let base = base.trim_end_matches('/');
    if a.is_file_browse() {
        // 浏览型源没有统一的鉴权探测端点,只判连通,所以只会给出绿/灰两态。
        return match http.get(base).send().await {
            Ok(_) => AccountStatus::Ok,
            Err(_) => AccountStatus::Down,
        };
    }
    // 用 /System/Info(需鉴权)而不是 /System/Info/Public:后者 token 失效也回 200,
    // 那样"需重登"永远探不出来,黄灯就成了摆设。
    let url = format!("{base}/System/Info?api_key={}", a.token);
    match http.get(&url).send().await {
        Ok(r) if r.status().is_success() => AccountStatus::Ok,
        Ok(r) if matches!(r.status().as_u16(), 401 | 403) => AccountStatus::Reauth,
        Ok(_) => AccountStatus::Down,
        Err(_) => AccountStatus::Down,
    }
}

/// 探测所有服务器的连通状态,刷新缓存并返回新的列表。
/// 并发探测:一台慢的不该拖住整页(串行 N 台 × 超时 = 页面空一分钟)。
#[tauri::command]
async fn probe_accounts(state: State<'_, AppState>) -> Result<Vec<AccountInfo>, String> {
    let accounts = state.config.lock().unwrap().accounts.clone();
    let mut handles = Vec::new();
    for a in accounts {
        let http = state.http.clone();
        handles.push(tauri::async_runtime::spawn(async move {
            let status = probe_account(&http, &a).await;
            (a.server.clone(), status)
        }));
    }
    for h in handles {
        if let Ok((server, status)) = h.await {
            state.account_status.lock().unwrap().insert(server, status);
        }
    }
    Ok(list_accounts(state))
}

#[derive(serde::Serialize)]
struct LineProbe {
    index: usize,
    url: String,
    ms: Option<u64>,
}

/// 线路 URL 表。空 lines 回落成「server 本身算一条线」—— 前端渲染行数必须与此一致。
fn line_urls(state: &State<'_, AppState>, server_id: &str) -> Result<Vec<String>, String> {
    let cfg = state.config.lock().unwrap();
    let a = cfg.find(server_id).ok_or("找不到该服务器")?;
    Ok(if a.lines.is_empty() {
        vec![a.server.clone()]
    } else {
        a.lines.iter().map(|l| l.url.clone()).collect()
    })
}

/// 单条线路测速。通 = Some(毫秒),不通/超时 = None。
async fn probe_one(http: &reqwest::Client, url: &str) -> Option<u64> {
    let probe = format!("{}/System/Info/Public", url.trim_end_matches('/'));
    let t0 = std::time::Instant::now();
    let ok = tokio::time::timeout(std::time::Duration::from_secs(6), http.get(&probe).send())
        .await
        .ok()
        .and_then(|r| r.ok())
        .map(|r| r.status().is_success())
        .unwrap_or(false);
    ok.then(|| t0.elapsed().as_millis() as u64)
}

/// 只探**一条**线路:先出线路表、再逐条填延迟。
/// 整表并发探的做法要等最慢那条,一条死线就把整个面板扣住,用户连切到能用的线路都做不到。
#[tauri::command]
async fn probe_line(
    state: State<'_, AppState>,
    server_id: String,
    index: usize,
) -> Result<LineProbe, String> {
    let urls = line_urls(&state, &server_id)?;
    let url = urls.get(index).ok_or("线路下标越界")?.clone();
    let ms = probe_one(&state.http, &url).await;
    Ok(LineProbe { index, url, ms })
}

/* ---------- 手机控制台(扫码遥控) ----------
   电视没摄像头,只能"电视出码手机扫"。核层起一个局域网小网页(crates/core/src/companion.rs),
   业务全在这里:手机那页的每个动作都对应下面 `companion_call` 里的一个分支。

   ★ 为什么处理器能直接调这些 `#[tauri::command]` 函数:`AppHandle::state::<T>()` 在命令
     之外也能拿到同一个 `State`,所以不必把每条业务再抄一份 —— **抄一份就一定会分叉**,
     手机上改的设置和电视上改的走两套代码,迟早有一边落后。

   ★ 遥控按键不能在这里"执行",它要落到 WebView 里的焦点库上 ——
     所以按键只是 `emit` 给前端,由 ui/tv/app/remote.ts 转成真实键事件。 */

/// 手机控制台的真实状态。**不再只返回一个 Option<String>** ——
/// 上一版就是这么写的,界面拿到 null 只能猜"没开或没联网",用户看到的提示和真实原因
/// 无关,连往下查都没法查(2026-07-21 的现场:真因是默认值 false,提示却说没联网)。
#[derive(serde::Serialize)]
struct CompanionStatus {
    /// 用户开关。false = 用户自己在设置里关的。
    enabled: bool,
    /// 服务是否真的在监听。
    running: bool,
    /// 可扫地址;None = 服务在跑但探不到本机 IP。
    url: Option<String>,
    /// 监听端口(探不到 IP 时给用户一条能自查的线索)。
    port: Option<u16>,
    /// 说人话的失败原因;None = 一切正常。
    error: Option<String>,
}

/// 查状态。**顺带自愈**:开关是开的却没在跑(开机时网卡还没就绪等),就地重试起服 ——
/// 否则用户得重启 App 才能好,而他根本不知道该重启。
#[tauri::command]
async fn companion_url(app: tauri::AppHandle) -> CompanionStatus {
    let enabled = app.state::<AppState>().config.lock().unwrap().companion_enabled;
    if !enabled {
        return CompanionStatus {
            enabled: false,
            running: false,
            url: None,
            port: None,
            error: Some("手机遥控被关掉了,把上面的开关打开".into()),
        };
    }

    let running = app.state::<AppState>().companion.lock().unwrap().is_some();
    if !running {
        // 自愈一次。失败原因原样带回界面,不再糊成"没联网"。
        if let Err(e) = try_start_companion(app.clone()).await {
            return CompanionStatus {
                enabled: true,
                running: false,
                url: None,
                port: None,
                error: Some(e),
            };
        }
    }

    let st = app.state::<AppState>();
    let g = st.companion.lock().unwrap();
    match g.as_ref() {
        Some(c) => CompanionStatus {
            enabled: true,
            running: true,
            url: c.url.clone(),
            port: Some(c.port),
            error: c.ip_error.clone(),
        },
        None => CompanionStatus {
            enabled: true,
            running: false,
            url: None,
            port: None,
            error: Some("服务没能起来(日志里搜 companion)".into()),
        },
    }
}

/// 开关手机控制台。关掉即停服(Companion 的 Drop 干这件事),再开会换一个新 token。
#[tauri::command]
async fn companion_set_enabled(app: tauri::AppHandle, enabled: bool) -> Result<(), String> {
    {
        let st = app.state::<AppState>();
        let mut cfg = st.config.lock().unwrap();
        cfg.companion_enabled = enabled;
        cfg.save();
    }
    if !enabled {
        *app.state::<AppState>().companion.lock().unwrap() = None;
        return Ok(());
    }
    /* 开启失败要**报给界面**:静默返回 None 的话,用户拨了开关什么也没发生,
       还以为是自己没拨到位。 */
    try_start_companion(app.clone()).await.map(|_| ())
}

/// 起服;失败把原因**原样返回**(给界面用)。
async fn try_start_companion(app: tauri::AppHandle) -> Result<Option<String>, String> {
    match start_companion_inner(app).await {
        Ok(url) => Ok(url),
        Err(e) => Err(e),
    }
}

/// 开机路径:失败只记日志,不拦启动。
async fn start_companion(app: tauri::AppHandle) -> Option<String> {
    match start_companion_inner(app).await {
        Ok(url) => url,
        Err(e) => {
            log::warn!("[companion] 起服失败(不影响其它功能): {e}");
            None
        }
    }
}

async fn start_companion_inner(app: tauri::AppHandle) -> Result<Option<String>, String> {
    let h = app.clone();
    let handler: linplayer_core::companion::Handler = std::sync::Arc::new(move |name, body| {
        let app = h.clone();
        Box::pin(async move {
            match companion_call(&app, &name, &body).await {
                Ok(v) => v.to_string(),
                Err(e) => serde_json::json!({ "error": e }).to_string(),
            }
        })
    });
    let c = linplayer_core::companion::start(handler).await?;
    let url = c.url.clone();
    log::info!(
        "[companion] 手机控制台已开: 端口 {} 地址 {}",
        c.port,
        url.clone().unwrap_or_else(|| "(探不到本机 IP)".into())
    );
    *app.state::<AppState>().companion.lock().unwrap() = Some(c);
    Ok(url)
}

/// 手机页的动作 → 电视上的真实行为。返回的 Value 原样发回手机。
async fn companion_call(
    app: &tauri::AppHandle,
    name: &str,
    body: &str,
) -> Result<serde_json::Value, String> {
    use serde_json::{json, Value};
    let req: Value = serde_json::from_str(body).unwrap_or(Value::Null);
    let s = |k: &str| req.get(k).and_then(|v| v.as_str()).unwrap_or("").to_string();

    match name {
        /* 手机每隔几秒问一次:连的哪台、在放什么。**必须便宜** —— 它是全页的心跳。 */
        "state" => {
            let session = current_session(app.state::<AppState>());
            let playing = match status(app.state::<PlayerState>()) {
                Ok(st) if st.duration > 0.0 => {
                    let np = app.state::<AppState>().now_playing.lock().unwrap().clone();
                    Some(json!({
                        "title": np.as_ref().map(|(t, _)| t.clone()),
                        "sub": np.as_ref().and_then(|(_, x)| x.clone()),
                        "pos": st.time, "dur": st.duration, "paused": st.paused,
                    }))
                }
                /* 没在放 / 播放器还没建起来都算"没有正在播放" —— 手机上不该看见报错。 */
                _ => None,
            };
            Ok(json!({ "session": session, "playing": playing }))
        }

        /* 遥控按键。这里只转发,真正的"按下"发生在 WebView 里(见 ui/tv/app/remote.ts)。 */
        "key" => {
            let k = s("k");
            if !matches!(
                k.as_str(),
                "up" | "down" | "left" | "right" | "enter" | "back" | "home"
            ) {
                return Err(format!("不认识的按键: {k}"));
            }
            app.emit("lp://remote-key", k).map_err(|e| e.to_string())?;
            Ok(json!({ "ok": true }))
        }

        "play_ctl" => {
            match s("a").as_str() {
                "pause" => {
                    let paused =
                        req.get("v").and_then(|v| v.as_f64()).unwrap_or(0.0) != 0.0;
                    set_pause(app.state::<PlayerState>(), paused)?;
                }
                "seek" => {
                    let pos = req.get("v").and_then(|v| v.as_f64()).unwrap_or(0.0).max(0.0);
                    seek(app.state::<PlayerState>(), pos)?;
                }
                "stop" => {
                    let pos = status(app.state::<PlayerState>()).map(|x| x.time).unwrap_or(0.0);
                    stop_playback(app.state::<AppState>(), app.state::<PlayerState>(), pos).await?;
                    /* 播放页是前端的一条路由,核层停流不会让它自己退 —— 得叫它退。 */
                    app.emit("lp://remote-key", "back").map_err(|e| e.to_string())?;
                }
                other => return Err(format!("不认识的播放动作: {other}")),
            }
            Ok(json!({ "ok": true }))
        }

        "accounts" => Ok(json!({ "accounts": list_accounts(app.state::<AppState>()) })),

        /* ★ 这三条都改了账号表。前端每个页面各持一份副本,**不发这条广播的话
           电视那边毫无察觉** —— 最明显的是首次启动:手机上登录成功了,
           电视还停在"添加服务器"那一屏不动。 */
        "switch" => {
            set_active_server(app.state::<AppState>(), s("server"))?;
            app.emit("lp://accounts-changed", ()).ok();
            Ok(json!({ "ok": true }))
        }

        "remove" => {
            remove_account(app.state::<AppState>(), s("server")).await?;
            app.emit("lp://accounts-changed", ()).ok();
            Ok(json!({ "ok": true }))
        }

        "login" => {
            let r = login(app.state::<AppState>(), s("server"), s("user"), s("pass")).await?;
            app.emit("lp://accounts-changed", ()).ok();
            Ok(json!({ "ok": true, "name": r.user_name }))
        }

        /* 加浏览型源(目前手机页只开了 Stremio 一种)。
           ★ 电视上加源只能走这条路:遥控器打一行 URL 已经很痛,Stremio 还是**多行**配置。
             TV 的 OnboardingPage 明确把「打字」判成非主路径,不给它开表单。 */
        "source_login" => {
            let kind: SourceKind = serde_json::from_value(json!(s("kind")))
                .map_err(|_| format!("不认识的源类型: {}", s("kind")))?;
            source_login(
                app.state::<AppState>(),
                kind,
                s("base_url"),
                s("user"),
                s("pass"),
                Some(s("cookie")),
                // 遥控网页这条路目前只加 Stremio,不需要令牌覆盖。
                None,
            )
            .await?;
            app.emit("lp://accounts-changed", ()).ok();
            Ok(json!({ "ok": true }))
        }

        /* 手机上打字搜片 —— 这是遥控器最痛的场景,所以搜的是**全部服务器**,
           省得用户先切服再搜。点结果时把 server 一起带回来。 */
        "search" => {
            let q = s("q");
            if q.is_empty() {
                return Ok(json!({ "items": [] }));
            }
            let groups = aggregate_search(app.state::<AppState>(), q).await?;
            let mut items = Vec::new();
            for g in groups {
                for it in g.items.into_iter().take(20) {
                    items.push(json!({
                        "id": it.id, "name": it.name, "type": it.type_,
                        "year": it.year, "from": g.server_name, "server": g.server_id,
                    }));
                }
            }
            items.truncate(60);
            Ok(json!({ "items": items }))
        }

        /* 让电视打开某个条目。切服要在前端跳页之前做完,否则详情页拿当前服的 token
           去问一个不存在的 itemId —— 表现是"点开是空白页"(TV 搜索页踩过同一个坑)。 */
        "open" => {
            let server = s("server");
            if !server.is_empty() {
                let cur = current_session(app.state::<AppState>()).map(|x| x.server);
                if cur.as_deref() != Some(server.as_str()) {
                    set_active_server(app.state::<AppState>(), server)?;
                    /* 切了服就得让电视那边重问会话 —— 否则页面还揣着上一台的
                       session 副本去画新服的条目(TV 搜索页当年就是这么"点进去是空白页"的)。 */
                    app.emit("lp://accounts-changed", ()).ok();
                }
            }
            app.emit("lp://remote-open", s("id")).map_err(|e| e.to_string())?;
            Ok(json!({ "ok": true }))
        }

        "settings" => {
            let p = get_prefs(app.state::<AppState>());
            let proxy = get_proxy(app.state::<AppState>());
            let bytes = cache_size().await.unwrap_or(0);
            let theme = app.state::<AppState>().config.lock().unwrap().theme.clone();
            Ok(json!({
                "theme": theme,
                "audio_lang": p.audio_lang, "sub_lang": p.sub_lang, "sub_enabled": p.sub_enabled,
                "proxy_type": proxy.type_, "proxy_host": proxy.host, "proxy_port": proxy.port,
                "cache_human": human_size(bytes),
            }))
        }

        "set_settings" => {
            /* 空串 = "自动"。**必须转成 None** —— 传 Some("") 会让选轨规则去匹配一个
               空语言码,表现是"设了自动却一条音轨都选不中"。 */
            let opt = |v: String| if v.is_empty() { None } else { Some(v) };
            set_prefs(
                app.state::<AppState>(),
                opt(s("audio_lang")),
                opt(s("sub_lang")),
                req.get("sub_enabled").and_then(|v| v.as_bool()).unwrap_or(true),
            )?;
            let mut proxy = get_proxy(app.state::<AppState>());
            proxy.type_ = s("proxy_type");
            proxy.host = s("proxy_host");
            proxy.port = req.get("proxy_port").and_then(|v| v.as_u64()).unwrap_or(0) as u16;
            set_proxy(app.state::<AppState>(), proxy)?;
            /* 主题是前端的东西(localStorage),核层只存一份好让手机读得到当前值,
               真正生效靠这条 emit —— 不发的话手机上拨了主题,电视要等下次重启才变。 */
            let theme = s("theme");
            if !theme.is_empty() {
                {
                    let st = app.state::<AppState>();
                    let mut cfg = st.config.lock().unwrap();
                    cfg.theme = theme.clone();
                    cfg.save();
                }
                app.emit("lp://remote-theme", theme).map_err(|e| e.to_string())?;
            }
            Ok(json!({ "ok": true }))
        }

        "clear_cache" => {
            clear_cache().await?;
            Ok(json!({ "ok": true }))
        }

        other => Err(format!("不认识的接口: {other}")),
    }
}

/// 播放页告诉核层"现在放的是什么" —— 手机控制台要显示片名,而 mpv 的 Status 里没有。
/// 前端本来就有标题,让它顺手报一次比核层再打一次 Emby 请求便宜。
#[tauri::command]
fn set_now_playing(state: State<'_, AppState>, title: Option<String>, sub: Option<String>) {
    *state.now_playing.lock().unwrap() = title.map(|t| (t, sub));
}

/// 前端把当前主题镜像到核层 —— 手机控制台读不到 WebView 的 localStorage,
/// 没有这份镜像它只能瞎猜一个默认值显示。**权威仍在前端**,这里只存不判。
#[tauri::command]
fn set_theme_pref(state: State<'_, AppState>, theme: String) {
    let mut cfg = state.config.lock().unwrap();
    if cfg.theme != theme {
        cfg.theme = theme;
        cfg.save();
    }
}

fn human_size(b: u64) -> String {
    const U: [&str; 4] = ["B", "KB", "MB", "GB"];
    let mut v = b as f64;
    let mut i = 0;
    while v >= 1024.0 && i < 3 {
        v /= 1024.0;
        i += 1;
    }
    format!("{v:.1} {}", U[i])
}

/// 删除某账号;若删的是活跃账号,回落到第一个(无账号则清空会话)。
/// 删本地前尽力通知服务端登出,失败不影响本地删除(实测有的服 /Sessions/Logout 直接 404)。
#[tauri::command]
async fn remove_account(state: State<'_, AppState>, server_id: String) -> Result<(), String> {
    {
        let sess = {
            let cfg = state.config.lock().unwrap();
            cfg.accounts
                .iter()
                .find(|a| a.server == server_id)
                .map(|a| Session {
                    server: a.active_line_url(),
                    token: a.token.clone(),
                    user_id: a.user_id.clone(),
                    device_id: cfg.device_id.clone(),
                })
        };
        if let Some(s) = sess {
            let _ = emby::logout(&state.http, &s).await;
        }
    }
    let new_session = {
        let mut cfg = state.config.lock().unwrap();
        if !cfg.remove(&server_id) {
            return Err("找不到该账号".into());
        }
        cfg.save();
        let device_id = cfg.device_id.clone();
        // 回落后的活跃账号若是浏览型源,它没有 Emby 会话 —— 别硬造一个假的。
        cfg.active_account()
            .filter(|a| !a.is_file_browse())
            .map(|a| Session {
                server: a.active_line_url(),
                token: a.token.clone(),
                user_id: a.user_id.clone(),
                device_id,
            })
    };
    *state.session.lock().unwrap() = new_session;
    Ok(())
}

/// 服务器列表拖拽排序。
#[tauri::command]
fn reorder_accounts(state: State<'_, AppState>, from: usize, to: usize) -> Result<(), String> {
    let mut cfg = state.config.lock().unwrap();
    cfg.reorder(from, to)?;
    cfg.save();
    Ok(())
}

/// 覆写某服务器的备用线路表。
#[tauri::command]
fn set_lines(
    state: State<'_, AppState>,
    server_id: String,
    lines: Vec<linplayer_core::config::ServerLine>,
) -> Result<(), String> {
    let mut cfg = state.config.lock().unwrap();
    let a = cfg.find_mut(&server_id).ok_or("找不到该服务器")?;
    // 线路变少时把选中项钳回合法区间,别留悬空下标。
    if !lines.is_empty() && a.active_line >= lines.len() {
        a.active_line = lines.len() - 1;
    }
    a.lines = lines;
    cfg.save();
    Ok(())
}

/// 切换生效线路;若切的是当前活跃服务器,同步刷新会话让后续请求立刻走新线路。
#[tauri::command]
fn set_active_line(
    state: State<'_, AppState>,
    server_id: String,
    index: usize,
) -> Result<(), String> {
    let mut cfg = state.config.lock().unwrap();
    let a = cfg.find_mut(&server_id).ok_or("找不到该服务器")?;
    if !a.lines.is_empty() && index >= a.lines.len() {
        return Err("线路下标越界".into());
    }
    a.active_line = index;
    cfg.save();
    let is_active = cfg.active_account().map(|x| x.server == server_id).unwrap_or(false);
    if is_active {
        if let Some(s) = state.session.lock().unwrap().as_mut() {
            s.server = cfg.find(&server_id).unwrap().active_line_url();
        }
    }
    Ok(())
}

/// 「同步线路」的结果。`supported=false` 时 UI 该说「这台服务器没提供线路表」,不是报错。
#[derive(serde::Serialize)]
struct SyncedLines {
    supported: bool,
    added: usize,
    total: usize,
}

/// 同步线路:从服主部署的 emby_ext_domains 拉取备用域名,并入本地线路表。
///
/// **只增不删,按 url 去重**:用户手填的线路(内网地址)服主表里不可能有,整表覆写等于
/// 把用户配置删了 —— 而他多半是在「当前线路连不上」时点的同步,那一刻删掉他仅有的能用
/// 线路是灾难。active_line 是**下标**不是 id,插行会让它指到别的线路上,所以合并后要按
/// 原 url 找回下标(core::merge_lines 负责,那边有测试钉)。
#[tauri::command]
async fn sync_lines(state: State<'_, AppState>, server_id: String) -> Result<SyncedLines, String> {
    // ★ 锁不能跨 await(见 [[prefetch-proxy-deadlock]]):先取完数据立刻放锁。
    let sess = {
        let cfg = state.config.lock().unwrap();
        let a = cfg.find(&server_id).ok_or("找不到该服务器")?;
        if a.is_file_browse() {
            return Err("网盘/聚合源没有线路表".into());
        }
        Session {
            server: a.direct_line_url().to_string(),
            token: a.token.clone(),
            user_id: a.user_id.clone(),
            device_id: cfg.device_id.clone(),
        }
    };
    let remote = emby::ext_domains(&state.http, &sess).await?;
    if remote.is_empty() {
        let total = {
            let cfg = state.config.lock().unwrap();
            cfg.find(&server_id).map(|a| a.lines.len()).unwrap_or(0)
        };
        return Ok(SyncedLines { supported: false, added: 0, total });
    }

    let mut cfg = state.config.lock().unwrap();
    let a = cfg.find_mut(&server_id).ok_or("找不到该服务器")?;
    let added = linplayer_core::config::merge_lines(a, &remote);
    let total = a.lines.len();
    cfg.save();
    Ok(SyncedLines { supported: true, added, total })
}

/// 取服务器图标(data URI)。首次调用会下载并缓存,之后直接读缓存。
/// 取不到返回 Err —— 由前端回退内置图标,别在这儿吞成空串让 UI 显示碎图。
#[tauri::command]
async fn account_icon(state: State<'_, AppState>, server_id: String) -> Result<String, String> {
    let url = {
        let cfg = state.config.lock().unwrap();
        cfg.find(&server_id).and_then(|a| a.icon_url.clone())
    };
    // 服务器图标是用户填的任意外链,不是 Emby → 默认 UA。
    linplayer_core::icon_cache::get(&http::client(), &server_id, url.as_deref()).await
}

/* ============================================================
   文件浏览型源
   ============================================================ */

fn source_backend(
    state: &State<'_, AppState>,
    kind: &SourceKind,
) -> Result<Arc<dyn MediaSourceBackend>, String> {
    // 插件源:**现建现用,不进静态表**。PluginSourceBackend 是无状态的
    // (只有 plugin_id + src_id + Weak),建一个的成本可忽略;而往这张会被播放链路读的
    // 表里动态增删要引入锁和生命周期同步,是白挨的复杂度。
    // 插件被禁用时自然失效 —— 贡献点注册表里查不到,调用直接报错。
    // 安卓端插件系统尚未接入(本轮范围只做桌面,见 docs/PLUGINS_V2_PLAN.md D2)。
    // 明确报错而不是回落成「该源类型暂未接入」—— 后者会让人以为是内置源没写,
    // 而真实原因是这个端根本还没有插件宿主。
    if kind.is_plugin() {
        return Err("安卓端暂未接入插件系统,该源无法使用".to_string());
    }
    state
        .source_backends
        .get(kind)
        .cloned()
        .ok_or_else(|| "该源类型暂未接入".to_string())
}

/// 扫码登录:出码。与 `apps/desktop/src/lib.rs::source_qr_start` 同构。
#[tauri::command]
async fn source_qr_start(state: State<'_, AppState>, kind: SourceKind) -> Result<QrStart, String> {
    let http = &state.http;
    match kind.as_str() {
        SourceKind::BAIDU => baidu::qr_start(http).await,
        SourceKind::ALIYUNDRIVE => aliyundrive::qr_start(http).await,
        SourceKind::PAN189 => pan189::qr_start(http).await,
        SourceKind::PAN139 => pan139::qr_start(http).await,
        _ => return Err("该源不支持扫码登录".to_string()),
    }
    .map_err(|e| e.message)
}

/// 扫码登录:轮询一次。Confirmed 的 credentials 由前端塞进 source_login 的 extra 落库。
#[tauri::command]
async fn source_qr_poll(
    state: State<'_, AppState>,
    kind: SourceKind,
    ctx: String,
) -> Result<QrPoll, String> {
    let http = &state.http;
    match kind.as_str() {
        SourceKind::BAIDU => baidu::qr_poll(http, &ctx).await,
        SourceKind::ALIYUNDRIVE => aliyundrive::qr_poll(http, &ctx).await,
        SourceKind::PAN189 => pan189::qr_poll(http, &ctx).await,
        SourceKind::PAN139 => pan139::qr_poll(http, &ctx).await,
        _ => return Err("该源不支持扫码登录".to_string()),
    }
    .map_err(|e| e.message)
}

/// 账密登录:手机号+密码换令牌。与 `apps/desktop/src/lib.rs::source_password_login` 同构。
#[tauri::command]
async fn source_password_login(
    state: State<'_, AppState>,
    kind: SourceKind,
    username: String,
    password: String,
) -> Result<HashMap<String, String>, String> {
    let http = &state.http;
    match kind.as_str() {
        SourceKind::PAN189 => pan189::password_login(http, &username, &password).await,
        SourceKind::PAN139 => pan139::password_login(http, &username, &password).await,
        _ => return Err("该源不支持账密登录".to_string()),
    }
    .map_err(|e| e.message)
}

/// 后端轮换出的新凭据落盘。与 `apps/desktop/src/lib.rs::persist_rotated` 同构 ——
/// 少了它,一次性 refresh_token 的源(阿里云盘/天翼189/夸克扫码)重启后必掉登录且不报错。
fn persist_rotated(
    state: &State<'_, AppState>,
    kind: &SourceKind,
    backend: &Arc<dyn MediaSourceBackend>,
) {
    let Some((cur_kind, mut server)) = state.source.lock().unwrap().clone() else {
        return;
    };
    if &cur_kind != kind {
        return;
    }
    let Some(updates) = backend.take_rotated_credentials(&server.id) else {
        return;
    };
    server.extra.extend(updates);
    {
        let mut cfg = state.config.lock().unwrap();
        if let Some(acc) = cfg.accounts.iter_mut().find(|a| a.server == server.id) {
            acc.source = Some(server.clone());
        }
        cfg.save();
    }
    *state.source.lock().unwrap() = Some((cur_kind, server));
}

#[tauri::command]
async fn source_list_dir(
    state: State<'_, AppState>,
    dir_id: Option<String>,
) -> Result<Vec<SourceEntry>, String> {
    let (kind, server) = state.source.lock().unwrap().clone().ok_or("未登录源")?;
    let backend = source_backend(&state, &kind)?;
    let r = backend
        .list_dir(&state.http, &server, dir_id.as_deref())
        .await
        .map_err(|e| e.message);
    persist_rotated(&state, &kind, &backend);
    r
}

/// 源端全盘搜索。与桌面端同构;返回 Err 时前端退回本地过滤。
#[tauri::command]
async fn source_search(
    state: State<'_, AppState>,
    query: String,
) -> Result<Vec<SourceEntry>, String> {
    let (kind, server) = state.source.lock().unwrap().clone().ok_or("未登录源")?;
    let backend = source_backend(&state, &kind)?;
    let r = backend
        .search(&state.http, &server, &query)
        .await
        .map_err(|e| e.message);
    persist_rotated(&state, &kind, &backend);
    r
}

/* ============================================================
   设置 / 数据目录 / 更新
   ============================================================ */

/// 数据根 + 各子目录的真实绝对路径,直接给设置页显示。存在的意义就是**别让用户猜**。
#[derive(serde::Serialize)]
struct DataPaths {
    root: String,
    config: String,
    data: String,
    cache: String,
    temp: String,
    webview: String,
    logs: String,
    downloads: String,
    kind: linplayer_core::paths::RootKind,
    exe_dir: String,
}

#[tauri::command]
fn data_paths() -> DataPaths {
    use linplayer_core::paths as p;
    let s = |x: std::path::PathBuf| x.to_string_lossy().into_owned();
    DataPaths {
        root: s(p::root()),
        config: s(p::config_file()),
        data: s(p::data_root()),
        cache: s(p::cache_root()),
        temp: s(p::temp_dir()),
        webview: s(p::webview_dir()),
        logs: s(p::logs_dir()),
        downloads: s(p::downloads_dir()),
        kind: p::root_kind(),
        // 安卓上 current_exe() 指向 /system/bin/app_process(zygote),对用户毫无意义,
        // 但也不该编造 —— 如实给,UI 那栏本来就是"包在哪儿"的诊断信息。
        exe_dir: std::env::current_exe()
            .ok()
            .and_then(|e| e.parent().map(|d| s(d.to_path_buf())))
            .unwrap_or_default(),
    }
}

/// 缓存占用字节数。**同步递归遍历目录**,缓存大时会卡几百毫秒 —— 丢去阻塞线程池,别堵住 UI。
#[tauri::command]
async fn cache_size() -> Result<u64, String> {
    tauri::async_runtime::spawn_blocking(linplayer_core::paths::cache_size)
        .await
        .map_err(|e| format!("统计缓存失败: {e}"))
}

/// 清空缓存。只动 cache/,config/data/downloads 一根汗毛都不碰。
#[tauri::command]
async fn clear_cache() -> Result<(), String> {
    tauri::async_runtime::spawn_blocking(|| {
        linplayer_core::paths::clear_cache()?;
        // 内存层必须一起清:只删磁盘的话内存里那份还在继续供图,
        // 用户看着占用变 0、封面却还是旧的 —— 那不叫清理,叫骗人。
        linplayer_core::image_cache::mem_clear();
        Ok(())
    })
    .await
    .map_err(|e| format!("清理缓存失败: {e}"))?
}

#[tauri::command]
fn get_prefs(state: State<'_, AppState>) -> Prefs {
    state.config.lock().unwrap().prefs.clone()
}

/// 记住偏好(用户手动切轨时持久化,下次同语言自动命中)。
#[tauri::command]
fn set_prefs(
    state: State<'_, AppState>,
    audio_lang: Option<String>,
    sub_lang: Option<String>,
    sub_enabled: bool,
) -> Result<(), String> {
    let mut cfg = state.config.lock().unwrap();
    // 只改选轨三项。别整体覆盖 —— 那会把 cross_server_resume 悄悄重置成默认值
    // (用户改个字幕语言,跨服续播就被关了)。
    cfg.prefs = Prefs { audio_lang, sub_lang, sub_enabled, ..cfg.prefs.clone() };
    cfg.save();
    Ok(())
}

/// 播放器默认行为(设置页「播放器」区)。
#[derive(serde::Serialize, serde::Deserialize)]
struct PlaybackPrefs {
    /// "auto-safe"(硬解) | "no"(软解)
    hwdec: String,
    default_speed: f64,
    skip_intro: bool,
    skip_outro: bool,
    preview_thumbs: bool,
    dolby_auto_sw: bool,
    external_player: String,
}

#[tauri::command]
fn get_playback_prefs(state: State<'_, AppState>) -> PlaybackPrefs {
    let p = &state.config.lock().unwrap().prefs;
    PlaybackPrefs {
        hwdec: p.hwdec.clone(),
        default_speed: p.default_speed,
        skip_intro: p.skip_intro,
        skip_outro: p.skip_outro,
        preview_thumbs: p.preview_thumbs,
        dolby_auto_sw: p.dolby_auto_sw,
        external_player: p.external_player.clone(),
    }
}

#[tauri::command]
fn set_playback_prefs(state: State<'_, AppState>, settings: PlaybackPrefs) -> Result<(), String> {
    // 拒而不是夹:静默夹紧 = 用户以为设上了。
    if !matches!(settings.hwdec.as_str(), "auto-safe" | "no") {
        return Err(format!("未知的解码方式: {}", settings.hwdec));
    }
    if !(linplayer_core::config::SPEED_MIN..=linplayer_core::config::SPEED_MAX)
        .contains(&settings.default_speed)
    {
        return Err(format!(
            "默认倍速只支持 {:.2}~{:.2}×",
            linplayer_core::config::SPEED_MIN,
            linplayer_core::config::SPEED_MAX
        ));
    }
    /* ★ 桌面版在这里校验「外部播放器路径必须是个存在的文件」。安卓**不校验**:
       那边根本没有「给出一个 exe 路径」这回事(要拉起别的播放器得走 Intent),
       沿用 is_file() 只会把用户填的任何东西一律判错。字段照存不动,留着两端结构一致。 */
    let mut cfg = state.config.lock().unwrap();
    cfg.prefs.hwdec = settings.hwdec;
    cfg.prefs.default_speed = settings.default_speed;
    cfg.prefs.skip_intro = settings.skip_intro;
    cfg.prefs.skip_outro = settings.skip_outro;
    cfg.prefs.preview_thumbs = settings.preview_thumbs;
    cfg.prefs.dolby_auto_sw = settings.dolby_auto_sw;
    cfg.prefs.external_player = settings.external_player.trim().to_string();
    cfg.save();
    Ok(())
}

/// 跨服务器续播开关(设置页)。
#[tauri::command]
fn get_cross_server_resume(state: State<'_, AppState>) -> bool {
    state.config.lock().unwrap().prefs.cross_server_resume
}

#[tauri::command]
fn set_cross_server_resume(state: State<'_, AppState>, enabled: bool) -> Result<(), String> {
    let mut cfg = state.config.lock().unwrap();
    cfg.prefs.cross_server_resume = enabled;
    cfg.save();
    Ok(())
}

#[derive(serde::Serialize)]
struct UpdateSettings {
    channel: linplayer_core::update::UpdateChannel,
    auto_check: bool,
    /// 当前版本(tauri.conf.json 的 version,由 build.rs 注入)。**比较用它**。
    current_version: String,
    /// 能不能就地自更新。安卓上恒为 false —— APK 的替换必须走系统安装器,
    /// 应用自己覆盖不了自己的 apk。UI 据此只提示「去下载」,不给「一键更新」。
    can_self_update: bool,
}

#[tauri::command]
fn get_update_settings(state: State<'_, AppState>) -> UpdateSettings {
    let cfg = state.config.lock().unwrap();
    UpdateSettings {
        channel: cfg.prefs.update_channel,
        auto_check: cfg.prefs.update_auto_check,
        current_version: env!("LP_VERSION").to_string(),
        can_self_update: false,
    }
}

#[tauri::command]
fn set_update_settings(
    state: State<'_, AppState>,
    channel: linplayer_core::update::UpdateChannel,
    auto_check: bool,
) -> Result<(), String> {
    let mut cfg = state.config.lock().unwrap();
    // 逐字段改,别整体覆盖 Prefs —— 见 set_prefs 上的说明。
    cfg.prefs.update_channel = channel;
    cfg.prefs.update_auto_check = auto_check;
    cfg.save();
    Ok(())
}

/// 查更新。`Ok(None)` = 确实已是最新;`Err` = 没查成(断网/限流)。
/// 两者必须分开:把「查不动」显示成「已是最新」是在骗用户。
#[tauri::command]
async fn check_update(
    state: State<'_, AppState>,
) -> Result<Option<linplayer_core::update::UpdateInfo>, String> {
    let channel = state.config.lock().unwrap().prefs.update_channel;
    let found = linplayer_core::update::check(channel, env!("LP_VERSION")).await?;
    *state.pending_update.lock().unwrap() = found.clone();
    Ok(found)
}

/* ============================================================
   下载
   ============================================================ */

/// 入队下载:走 Emby /Items/{id}/Download(服务端按下载权限放行),返回任务 id。
#[tauri::command]
fn download_enqueue(
    state: State<'_, AppState>,
    item_id: String,
    type_: String,
    title: String,
    container: String,
    poster_url: Option<String>,
) -> Result<String, String> {
    let s = session_of(&state)?;
    let url = format!(
        "{}/Items/{}/Download?api_key={}",
        s.server.trim_end_matches('/'),
        item_id,
        s.token
    );
    let c = if container.trim().is_empty() { "mkv".into() } else { container };
    let item =
        linplayer_core::download::DownloadItem::new(item_id, type_, title, c, url, poster_url);
    Ok(state.download.enqueue(item))
}

#[tauri::command]
fn download_list(state: State<'_, AppState>) -> Vec<linplayer_core::download::DownloadItem> {
    state.download.list()
}

#[tauri::command]
fn download_pause(state: State<'_, AppState>, id: String) {
    state.download.pause(&id);
}

#[tauri::command]
fn download_remove(state: State<'_, AppState>, id: String) {
    state.download.remove(&id);
}

#[tauri::command]
fn download_resume(state: State<'_, AppState>, id: String) {
    state.download.resume(&id);
}

#[tauri::command]
fn download_set_threads(state: State<'_, AppState>, threads: usize) {
    state.download.set_threads(threads);
}

/// 批量清除已完成的下载记录。返回清掉的条数。
/// 只清记录,不删已下好的文件 —— 用户点「清除已完成」是想收拾列表,不是想丢文件。
#[tauri::command]
fn download_clear_completed(state: State<'_, AppState>) -> usize {
    let done: Vec<String> = state
        .download
        .list()
        .into_iter()
        .filter(|i| i.status == linplayer_core::download::DownloadStatus::Completed)
        .map(|i| i.id)
        .collect();
    let mut n = 0;
    for id in done {
        // forget 而非 remove:remove 会 delete_files 把已下好的片子删掉,与本命令的契约相反。
        if state.download.forget(&id) {
            n += 1;
        }
    }
    n
}

/* ============================================================
   排行榜 / 追剧日历
   ============================================================ */

/// 当前构建可用的榜单分类(动漫需弹弹凭据、影视需 TMDB 密钥,均编译期注入)。
#[tauri::command]
fn ranking_categories() -> Vec<linplayer_core::ranking::RankingCategory> {
    linplayer_core::ranking::available_categories()
}

/// 拉取某分类榜单(默认命中 6h 缓存)。
#[tauri::command]
async fn ranking_fetch(
    category_id: String,
    force_refresh: Option<bool>,
) -> Result<Vec<linplayer_core::ranking::RankingEntry>, String> {
    linplayer_core::ranking::fetch(&category_id, force_refresh.unwrap_or(false)).await
}

/// 当前已连接的 Trakt 账号(None=未连接)。
#[tauri::command]
fn trakt_account(state: State<'_, AppState>) -> Option<linplayer_core::sync::SyncAccount> {
    state.config.lock().unwrap().sync_trakt.clone()
}

/// 追剧日历(only_mine=只看我追的)。未连接返回空。
#[tauri::command]
async fn trakt_calendar(
    state: State<'_, AppState>,
    only_mine: Option<bool>,
) -> Result<Vec<linplayer_core::sync::calendar::CalendarEntry>, String> {
    let acc = state.config.lock().unwrap().sync_trakt.clone();
    let Some(acc) = acc else { return Ok(vec![]) };
    Ok(trakt::fetch_shows_calendar(&acc, 3, 21, only_mine.unwrap_or(true)).await)
}

#[tauri::command]
fn bangumi_account(state: State<'_, AppState>) -> Option<linplayer_core::sync::SyncAccount> {
    state.config.lock().unwrap().sync_bangumi.clone()
}

#[tauri::command]
async fn bangumi_calendar(
    state: State<'_, AppState>,
    only_mine: Option<bool>,
) -> Result<Vec<linplayer_core::sync::calendar::CalendarEntry>, String> {
    let only_mine = only_mine.unwrap_or(true);
    let acc = state.config.lock().unwrap().sync_bangumi.clone();
    // 未登录时:个性化「我追的」拉不了(空);通用放送表 /calendar 是公开端点,用匿名账号照拉。
    match acc {
        Some(a) => Ok(bangumi::fetch_anime_calendar(&a, only_mine).await),
        None if !only_mine => {
            let anon = linplayer_core::sync::SyncAccount {
                service: "bangumi".into(),
                access_token: String::new(),
                refresh_token: None,
                expires_at: None,
                username: None,
                user_id: None,
            };
            Ok(bangumi::fetch_anime_calendar(&anon, false).await)
        }
        None => Ok(vec![]),
    }
}

/// 把旧的内部沙盒数据搬到新的外部应用目录(一次性,幂等)。
///
/// 只搬**配置和用户数据**,不搬 cache —— 缓存重建就好,搬它纯属浪费开机时间。
/// 目标已存在同名文件就跳过:重装后旧目录还在时,不能拿旧配置盖掉新的。
/// 搬完在旧目录留一个 `.migrated` 记号,避免每次启动都遍历一遍。
#[cfg(target_os = "android")]
fn migrate_internal_data(old: &std::path::Path, new: &std::path::Path) {
    let flag = old.join(".migrated");
    if flag.exists() || !old.exists() {
        return;
    }
    let mut moved = 0usize;
    for name in ["config.json", "translation.json", "data", "plugins", "logs"] {
        let src = old.join(name);
        if !src.exists() {
            continue;
        }
        let dst = new.join(name);
        if dst.exists() {
            continue;
        }
        if copy_tree(&src, &dst).is_ok() {
            moved += 1;
        }
    }
    let _ = std::fs::write(&flag, b"1");
    if moved > 0 {
        log::info!(
            "数据已从内部沙盒迁到外部应用目录({moved} 项): {} -> {}",
            old.display(),
            new.display()
        );
    }
}

#[cfg(target_os = "android")]
fn copy_tree(src: &std::path::Path, dst: &std::path::Path) -> std::io::Result<()> {
    if src.is_file() {
        if let Some(p) = dst.parent() {
            std::fs::create_dir_all(p)?;
        }
        std::fs::copy(src, dst)?;
        return Ok(());
    }
    std::fs::create_dir_all(dst)?;
    for e in std::fs::read_dir(src)? {
        let e = e?;
        copy_tree(&e.path(), &dst.join(e.file_name()))?;
    }
    Ok(())
}

/* ============================================================
   入口
   ============================================================ */

#[cfg_attr(mobile, tauri::mobile_entry_point)]
pub fn run() {
    let builder = imgcache::register(tauri::Builder::default());
    builder
        .setup(|app| {
            /* ★ 这里的顺序是有讲究的,别挪。
               安卓没有 XDG/AppData,更没有「exe 同级 userdata/」—— `paths::root()` 的默认
               解析在安卓上会落到一个进程无权写的地方。所以必须由宿主显式喂沙盒目录,
               而 `set_root` **只在 root() 被第一次调用之前有效**(设晚了直接 Err,免得
               一半模块用旧根一半用新根)。
               `AppConfig::load()` 会读 config 路径 = 会触发 root() —— 所以 set_root 必须
               排在它前面,而拿到沙盒目录又必须有 AppHandle,于是整块搬进 setup。
               (桌面壳能在 run() 顶部就把状态建好,是因为它的根不依赖 AppHandle。) */
            #[cfg(target_os = "android")]
            {
                /* ★ 数据根放**外部应用专属目录** `/sdcard/Android/data/<pkg>/files`,
                   而不是 `app_data_dir()`(= `/data/user/0/<pkg>`)。
                   后者是内部沙盒:文件管理器看不见、adb pull 不到、用户捞日志/配置无从下手,
                   正是用户说的「Android/data 里没有包的文件夹,找都找不到」。
                   外部应用专属目录**不需要任何存储权限**(API19 起豁免分区存储),卸载即清。

                   Tauri 没暴露 getExternalFilesDir(null),但 document_dir() 返回的是
                   `.../files/Documents` —— 取它的父目录就是 `.../files`。
                   外置存储未挂载时 document_dir() 会 Err,此时退回内部目录,宁可不好找也要能跑。 */
                let external = app
                    .path()
                    .document_dir()
                    .ok()
                    .and_then(|d| d.parent().map(std::path::Path::to_path_buf));
                let dir = match external {
                    Some(d) => d,
                    None => app.path().app_data_dir().map_err(|e| e.to_string())?,
                };
                std::fs::create_dir_all(&dir)?;
                // 老版本的数据在内部沙盒里,搬过来,否则升级后账号全丢。
                if let Ok(old) = app.path().app_data_dir() {
                    if old != dir {
                        migrate_internal_data(&old, &dir);
                    }
                }
                // 已被用过就说明有人抢跑了,如实报错而不是继续跑一个数据分裂的 App。
                linplayer_core::paths::set_root(dir).map_err(std::io::Error::other)?;
            }

            let config = AppConfig::load();
            // 先把代理写进全局,再建各 HTTP 客户端,使其启动即带代理。
            http::set_proxy(config.proxy.proxy_url());
            let http = http::emby_client();

            // 源后端注册表(长驻,持各自 token 缓存)。
            let mut source_backends: HashMap<SourceKind, Arc<dyn MediaSourceBackend>> =
                HashMap::new();
            source_backends.insert(SourceKind::openlist(), Arc::new(OpenListBackend::new()));
            source_backends.insert(SourceKind::anirss(), Arc::new(AniRssBackend::new()));
            source_backends.insert(SourceKind::feiniu(), Arc::new(FeiniuBackend::new()));
            source_backends.insert(SourceKind::quark(), Arc::new(QuarkBackend::new()));
            // 与 apps/desktop/src/lib.rs 的同名表必须逐条对齐,漏一条那一端就静默不可用。
            source_backends.insert(SourceKind::stremio(), Arc::new(StremioBackend::new()));
            // 国内网盘(扫码/Cookie 登录,不依赖任何在线令牌中继 —— oplist 已作废)。
            source_backends
                .insert(SourceKind::aliyundrive(), Arc::new(AliyunDriveBackend::new()));
            source_backends.insert(SourceKind::baidu(), Arc::new(BaiduBackend::new()));
            source_backends.insert(SourceKind::pan115(), Arc::new(Pan115Backend::new()));
            source_backends.insert(SourceKind::pan189(), Arc::new(Pan189Backend::new()));
            source_backends.insert(SourceKind::pan139(), Arc::new(Pan139Backend::new()));

            // 有活跃账号 -> 用存盘凭据重建会话/源(重启免登)。Emby 与浏览型源互斥。
            let active = config.active_account();
            let session = active.filter(|a| !a.is_file_browse()).map(|a| Session {
                server: a.active_line_url(),
                token: a.token.clone(),
                user_id: a.user_id.clone(),
                device_id: config.device_id.clone(),
            });
            let source = active
                .filter(|a| a.is_file_browse())
                .and_then(|a| a.source.clone().map(|s| (a.source_kind.clone(), s)));

            let download = tauri::async_runtime::block_on(
                linplayer_core::download::DownloadManager::new(
                    linplayer_core::paths::downloads_dir(),
                ),
            );

            app.manage(AppState {
                http,
                config: Mutex::new(config),
                session: Mutex::new(session),
                source_backends,
                source: Mutex::new(source),
                download,
                account_status: Mutex::new(HashMap::new()),
                pending_update: Mutex::new(None),
                scrobble_ctx: Mutex::new(None),
                companion: Mutex::new(None),
                now_playing: Mutex::new(None),
            });
            /* 播放器状态单独一份 State:它的生命周期和 Surface 绑,不跟 AppState 一起建。 */
            app.manage(PlayerState::default());
            /* mpv 提成共享 crate 后自带的日志出口是空的,把安卓这边的接进去,
               否则它那些「静默失效」告警(如 shader 缓存没设上)全被丢掉。 */
            linplayer_mpv::set_logger(|m| log::info!("[mpv] {m}"));

            /* 手机控制台:开机即起(除非用户关了)。**不能阻塞 setup** ——
               起服要等网卡就绪,拿它挡住启动就是开机白屏。失败只写日志。 */
            if app.state::<AppState>().config.lock().unwrap().companion_enabled {
                let h = app.handle().clone();
                tauri::async_runtime::spawn(async move {
                    start_companion(h).await;
                });
            }
            Ok(())
        })
        .invoke_handler(tauri::generate_handler![
            // --- Emby 浏览 ---
            login,
            current_session,
            aggregate_search,
            set_active_server,
            views,
            list_items_page,
            get_filters,
            set_played,
            list_next_up,
            search,
            similar_items,
            list_latest,
            list_resume,
            list_random,
            item_detail,
            item_media,
            list_favorites,
            set_favorite,
            // --- 服务器 / 线路 ---
            list_accounts,
            probe_accounts,
            probe_line,
            companion_url,
            companion_set_enabled,
            set_now_playing,
            set_theme_pref,
            remove_account,
            reorder_accounts,
            set_lines,
            set_active_line,
            sync_lines,
            account_icon,
            // --- 源 ---
            source_login,
            source_qr_start,
            source_qr_poll,
            source_password_login,
            source_list_dir,
            source_search,
            // --- 设置 / 数据 / 更新 ---
            data_paths,
            cache_size,
            clear_cache,
            get_prefs,
            set_prefs,
            get_playback_prefs,
            set_playback_prefs,
            get_cross_server_resume,
            set_cross_server_resume,
            get_update_settings,
            set_update_settings,
            check_update,
            // --- 下载 ---
            download_enqueue,
            download_list,
            download_pause,
            download_remove,
            download_resume,
            download_set_threads,
            download_clear_completed,
            // --- 排行 / 日历 ---
            ranking_categories,
            ranking_fetch,
            set_detail_blur,
            get_proxy,
            set_proxy,
            trakt_account,
            trakt_calendar,
            trakt_device_code,
            trakt_poll,
            trakt_logout,
            bangumi_account,
            bangumi_calendar,
            bangumi_authorize_url,
            bangumi_exchange,
            bangumi_login_token,
            bangumi_logout,
            // --- 播放器(桩:缺 libmpv .so,调用即报错,详见文件头)---
            play,
            play_local,
            source_play,
            seek,
            set_pause,
            set_track,
            status,
            tracks,
            stop_playback,
            report_progress,
        ])
        .run(tauri::generate_context!())
        .expect("error while running tauri application");
}

#[cfg(test)]
mod tests {
    /// 「视频透出」这条链上的四层,一层都不能少。
    ///
    /// 视频是垫在 WebView 底下的 SurfaceView,画面从窗口下面透上来。任何一层不透明
    /// 都是**有声音没画面、且完全不报错**的黑屏 —— 2026-07-21 就栽在第 3 层
    /// (Activity 窗口背景跟着 DayNight 走,浅色白屏/深色黑屏),而前三层当时看着都对,
    /// 于是只能靠猜。这条测试把四层钉住,以后谁删掉哪一层都会在 CI 上当场红。
    ///
    /// 反向验证:把 values/themes.xml 里的 windowBackground 那行删掉 → 本测试立刻红。
    #[test]
    fn video_transparency_chain_is_intact() {
        let cases: [(&str, &str, &str); 5] = [
            (
                "Activity 窗口(浅色)",
                include_str!("../gen/android/app/src/main/res/values/themes.xml"),
                "@android:color/transparent",
            ),
            (
                "Activity 窗口(深色)",
                include_str!("../gen/android/app/src/main/res/values-night/themes.xml"),
                "@android:color/transparent",
            ),
            (
                "Tauri 窗口配置",
                include_str!("../tauri.conf.json"),
                "\"transparent\": true",
            ),
            (
                "WebView 背景",
                include_str!("../gen/android/app/src/main/java/xyz/linplayer/tv/MainActivity.kt"),
                "setBackgroundColor(Color.TRANSPARENT)",
            ),
            (
                "前端渲染链",
                include_str!("../../../ui/tv/theme/tv.css"),
                "html.playing",
            ),
        ];
        for (layer, src, needle) in cases {
            assert!(
                src.contains(needle),
                "视频透出链断了一层「{layer}」:找不到 {needle:?}。\
                 少这一层的表现是有声音没画面,而且一句日志都没有。"
            );
        }
    }

    /// Surface 尺寸必须一路从 surfaceChanged 报到 mpv 的 `android-surface-size`。
    ///
    /// ★ 这条挡的是 2026-07-22 那个「播放页四周一圈没画到」的 bug:
    ///   mpv 的 android gpu-context 只在 reconfig 时取一次视口,安卓又没有
    ///   resize 事件通道 —— 断了这条链,画面就冻在 EGL 初始化那一刻的小尺寸,
    ///   **不报错、不崩,只是画面比屏幕小一圈**。
    ///   三段任缺一段都是同样的静默失效,所以三段一起钉。
    ///   反向验证:删掉 MainActivity 里的 `nativeSetSurfaceSize(w, ht)` → 本测试立刻红。
    #[test]
    fn surface_size_reaches_mpv() {
        let cases: [(&str, &str, &str); 3] = [
            (
                "壳在 surfaceChanged 里报尺寸",
                include_str!("../gen/android/app/src/main/java/xyz/linplayer/tv/MainActivity.kt"),
                "nativeSetSurfaceSize(w, ht)",
            ),
            (
                "JNI 导出接住它",
                include_str!("lib.rs"),
                "Java_xyz_linplayer_tv_MainActivity_nativeSetSurfaceSize",
            ),
            (
                "mpv 起播时读进去",
                include_str!("../../../crates/mpv/src/lib.rs"),
                "set(\"android-surface-size\"",
            ),
        ];
        for (seg, src, needle) in cases {
            assert!(
                src.contains(needle),
                "Surface 尺寸链断在「{seg}」:找不到 {needle:?}。\
                 断了的表现是画面渲染在一个比屏幕小的矩形里,四周一圈没画到,且毫无日志。"
            );
        }
    }

    /// 壳往前端喊的每一个按键名,前端必须**真的有人处理**。
    ///
    /// ★ 这条挡的是 2026-07-22 那个 bug:`menu` 在 focus.ts 的 TvKey 里定义了、
    ///   MainActivity 也转发了 KEYCODE_MENU,**唯独没有任何页面写 `k === "menu"`** ——
    ///   于是菜单键按下去静默无事。类型系统对此一声不吭(联合类型里多一个成员
    ///   不强制你处理它),只有用户按了才发现。
    ///
    /// 只查"有没有人处理",不查"处理得对不对" —— 后者不是静态能查的。
    /// 反向验证:把 PlayerPage 里 `k === "menu"` 那行删掉 → 本测试立刻红。
    #[test]
    fn every_shell_key_is_handled_by_the_frontend() {
        let kt = include_str!(
            "../gen/android/app/src/main/java/xyz/linplayer/tv/MainActivity.kt"
        );
        // 抠出 __lpTvKey('xxx') 里的 xxx
        let mut emitted: Vec<&str> = Vec::new();
        for (i, _) in kt.match_indices("__lpTvKey('") {
            let rest = &kt[i + "__lpTvKey('".len()..];
            if let Some(end) = rest.find('\'') {
                emitted.push(&rest[..end]);
            }
        }
        // 壳里还有一张 keyCode -> 名字的映射表,形如 `KeyEvent.KEYCODE_X -> "name"`
        for (i, _) in kt.match_indices("-> \"") {
            let rest = &kt[i + "-> \"".len()..];
            if let Some(end) = rest.find('"') {
                emitted.push(&rest[..end]);
            }
        }
        emitted.retain(|k| *k != "$name"); // 模板串本身不是键名
        emitted.sort_unstable();
        emitted.dedup();
        assert!(
            emitted.len() >= 5,
            "只从 MainActivity 抠出 {} 个键名,解析多半坏了:{emitted:?}",
            emitted.len()
        );

        /* 前端的**处理点**。
           ★ 这里**绝不能**把 focus.ts 算进来 —— 那里是 `TvKey` 联合类型的**声明**,
             每个键名都在,搜什么都命中。第一版就是这么写的,把 menu 处理器删掉
             测试照样绿(2026-07-22 实测),等于什么都没守住。声明 ≠ 处理。 */
        let front = concat!(
            include_str!("../../../ui/tv/pages/PlayerPage.tsx"),
            include_str!("../../../ui/tv/App.tsx"),
        );

        /* 明知没做的键。写在这里是为了**逼人显式承认**:
           next/prev(上一集/下一集)核层根本没有对应命令,stop 与返回键重复。
           哪天做了就从这里删掉;在此之前它们至少是"记录在案的没做",
           而不是"以为做了其实没有"。 */
        const KNOWN_UNHANDLED: [&str; 3] = ["next", "prev", "stop"];

        /* ★ 必须匹配 `k === "x"` 这个**处理**形态,不能只搜 `"x"`。
           只搜引号串会撞上同名的图标/标签:PlayerPage 里有 `icon="next"`(下一集按钮的
           图标名),于是 "next" 被判成"已处理" —— 又一条假绿(2026-07-22 实测撞到)。 */
        let handled = |k: &str| front.contains(&format!("k === \"{k}\""));

        let unhandled: Vec<&&str> = emitted
            .iter()
            .filter(|k| !KNOWN_UNHANDLED.contains(k))
            .filter(|k| !handled(k))
            .collect();
        assert!(
            unhandled.is_empty(),
            "壳把这些按键喊给了前端,前端却没有任何地方处理:{unhandled:?}\n\
             (表现是按下去静默无事 —— 用户只会说「这个键坏了」)"
        );

        // 反过来:allowlist 里躺着已经做了的键,说明它该被删掉了。
        for k in KNOWN_UNHANDLED {
            assert!(
                !handled(k),
                "「{k}」已经有人处理了,把它从 KNOWN_UNHANDLED 里删掉"
            );
        }
    }

    /// TV 前端 `ui/tv` 会调的命令,一个都不能漏注册 —— 漏了**不会编译报错**,
    /// 只在用户走到那个页面时抛 "command not found"。这条把 ui/tv(含它 import 的
    /// ui/shared/api.ts)里出现的 invoke 名和本文件的注册表对一遍。
    ///
    /// 反向验证:把 generate_handler! 里任意一行注释掉,此测试立刻红(已实测)。
    #[test]
    fn every_tv_invoke_names_a_registered_command() {
        let me = include_str!("lib.rs");
        let handlers = me
            .split_once("generate_handler![")
            .expect("找不到 generate_handler!")
            .1
            .split_once("])")
            .expect("generate_handler! 没有收尾")
            .0;
        let registered: Vec<&str> = handlers
            .lines()
            .map(|l| l.trim().trim_end_matches(','))
            .filter(|s| !s.is_empty() && !s.starts_with("//"))
            .collect();

        // api.ts 是 TV 页面唯一的命令出口(ui/tv 不直接 invoke)。
        let api_ts = include_str!("../../../ui/shared/api.ts");
        let mut names: Vec<&str> = Vec::new();
        for (i, _) in api_ts.match_indices("invoke") {
            let rest = &api_ts[i + "invoke".len()..];
            let Some(lp) = rest.find('(') else { continue };
            if rest[..lp].contains(';') || rest[..lp].contains('\n') {
                continue; // 不是调用(import / 注释里的 invoke 字样)
            }
            let after = rest[lp + 1..].trim_start();
            let Some(q) = after.strip_prefix('"') else { continue };
            let Some(end) = q.find('"') else { continue };
            names.push(&q[..end]);
        }
        assert!(names.len() > 50, "只抠出 {} 个 invoke,解析多半坏了", names.len());

        // api.ts 是三端共用的,里面有大量 PC 专属命令(mpv 系、whisper 系、插件系)。
        // TV 壳按需注册,所以这里只校验**清单内**的那批,而不是全表。
        // 清单来自 ui/tv 的真实 import 反推(见 apps/android/README.md)。
        let tv_cmds = include_str!("../tv-commands.txt");
        for cmd in tv_cmds.lines().map(str::trim).filter(|l| !l.is_empty()) {
            assert!(
                registered.contains(&cmd),
                "TV 命令清单里的 `{cmd}` 没在 generate_handler! 注册 —— \
                 用户走到那个页面就报 command not found"
            );
            assert!(
                names.contains(&cmd),
                "`{cmd}` 在 TV 清单里,但 ui/shared/api.ts 里没有对应的 invoke —— \
                 清单和前端漂移了,先查是不是前端改了命令名"
            );
        }
    }
}

/* ============================================================
   JNI:Java 层的 SurfaceView ←→ mpv 的渲染面
   ============================================================ */

/* 由 MainActivity 的 SurfaceHolder.Callback 调用。见那边的注释。

   ★ 必须 NewGlobalRef。传进来的 jobject 是**局部引用**,这次 native 调用一返回就失效;
     而 mpv 是在之后某个时刻(Player::new → mpv_initialize)才拿它去
     ANativeWindow_fromSurface。用局部引用的表现不是「不工作」,是**在一个和这里
     毫无关系的地方崩溃**,极难反查。

   ★ 旧的全局引用要显式 DeleteGlobalRef,否则每次转屏/回前台都漏一个 Surface。 */
#[cfg(target_os = "android")]
#[no_mangle]
pub extern "system" fn Java_xyz_linplayer_tv_MainActivity_nativeSetSurface(
    env: jni::JNIEnv,
    _this: jni::objects::JObject, // 实例方法 → 第二个参数是 this,不是 jclass
    surface: jni::objects::JObject,
) {
    /* 全局引用存这里。**用 GlobalRef 而不是裸 jobject**:它的 Drop 会自己
       DeleteGlobalRef,换面/退出时不会漏 Surface。手工管裸指针的版本写过一版,
       jni 0.21 根本没有 delete_global_ref 这个方法(交叉编译时才报出来 ——
       宿主 cargo check 编不到 cfg(android) 这段代码,查这类错只能真交叉编)。 */
    static CUR: std::sync::Mutex<Option<jni::objects::GlobalRef>> = std::sync::Mutex::new(None);

    let g = if surface.is_null() {
        None
    } else {
        match env.new_global_ref(&surface) {
            Ok(g) => Some(g),
            Err(e) => {
                log::error!("[mpv] NewGlobalRef 失败,视频将没有渲染面: {e}");
                None
            }
        }
    };

    /* ★ 顺手把 JavaVM 登记给 libmpv —— 这个 libmpv 没有导出 JNI_OnLoad,
       不登记就是「一切成功但黑屏」。理由和实测见 crates/mpv 的 set_android_java_vm。
       挂在这里是因为这是**唯一**天然带 JNIEnv 又必定早于起播的入口。
       重复调无害(ffmpeg 侧是幂等的设值)。 */
    match env.get_java_vm() {
        Ok(vm) => linplayer_mpv::set_android_java_vm(vm.get_java_vm_pointer() as *mut _),
        Err(e) => log::error!("[mpv] 取 JavaVM 失败,硬解/渲染会起不来: {e}"),
    }

    let ptr = g.as_ref().map(|g| g.as_raw() as isize).unwrap_or(0);
    // 先把新的存住再交给 mpv;旧的在这一行被 drop → 自动 DeleteGlobalRef。
    *CUR.lock().unwrap() = g;
    linplayer_mpv::set_android_surface(ptr);
}

/* 由 surfaceChanged 报 Surface 的实际像素尺寸。
   不报的表现不是崩,是**画面渲染在一个比屏幕小的矩形里、四周一圈没画到**。
   理由和出处全在 linplayer_mpv::set_android_surface_size 的注释里。 */
#[cfg(target_os = "android")]
#[no_mangle]
pub extern "system" fn Java_xyz_linplayer_tv_MainActivity_nativeSetSurfaceSize(
    _env: jni::JNIEnv,
    _this: jni::objects::JObject,
    w: jni::sys::jint,
    h: jni::sys::jint,
) {
    linplayer_mpv::set_android_surface_size(w, h);
}

/* ============================================================
   契约测试:api.ts 里标了「只有安卓壳有」的命令,安卓壳必须真的注册过。

   ★ 为什么需要这一条:桌面壳那条同名守门人(apps/desktop 的
     `every_frontend_invoke_names_a_registered_command`)会**跳过**这个区块 ——
     不在这边补一条对称的,那几条命令就成了两边都不查的盲区,
     漏注册不会编译报错,只在用户按到遥控器时抛「command not found」。
   ★ 反向验证:把下面 generate_handler! 里的 companion_url 注释掉,本测试立刻红。
   ============================================================ */
#[cfg(test)]
mod api_contract_tests {
    /// 取 api.ts 里 `@shell-only:android` 标记之间那一段。
    /// 标记的解析规则必须和桌面那边**逐字一致**,否则一边剪多了、一边查漏了。
    fn android_only_block(src: &str) -> String {
        let i = src
            .find("@shell-only:android 开始")
            .expect("api.ts 里没有 @shell-only:android 区块 —— 标记被删了?");
        let after = &src[i..];
        let j = after
            .find("@shell-only:android 结束")
            .expect("@shell-only:android 只有开始没有结束 —— 标记必须成对");
        after[..j].to_string()
    }

    #[test]
    fn android_only_commands_are_registered() {
        let block = android_only_block(include_str!("../../../ui/shared/api.ts"));
        let me = include_str!("lib.rs");

        let handlers = me
            .split_once("generate_handler![")
            .expect("找不到 generate_handler!")
            .1
            .split_once("])")
            .expect("generate_handler! 没有收尾")
            .0;
        let registered: Vec<&str> = handlers
            .split(',')
            .map(|s| s.trim())
            .filter(|s| !s.is_empty() && !s.starts_with("//"))
            .collect();

        // 抠 invoke<...>("cmd") / invoke("cmd") 里的命令名(与桌面那条同一套解析)
        let mut names: Vec<&str> = Vec::new();
        for (i, _) in block.match_indices("invoke") {
            let rest = &block[i + "invoke".len()..];
            let Some(lp) = rest.find('(') else { continue };
            if rest[..lp].contains(';') || rest[..lp].contains('\n') {
                continue;
            }
            let after = rest[lp + 1..].trim_start();
            let Some(q) = after.strip_prefix('"') else { continue };
            let Some(end) = q.find('"') else { continue };
            names.push(&q[..end]);
        }
        names.sort_unstable();
        names.dedup();
        assert!(
            names.len() >= 4,
            "只从安卓专属区块抠出 {} 个命令,解析多半坏了(或区块被搬空了)",
            names.len()
        );

        let missing: Vec<&&str> = names.iter().filter(|n| !registered.contains(*n)).collect();
        assert!(
            missing.is_empty(),
            "api.ts 标了「只有安卓壳有」,但安卓壳没注册:{missing:?}"
        );
    }
}
