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
mod shaders;
/* 插件系统的三个宿主模块 —— 与 apps/desktop 是**同一份文件**(2026-07-26 从那边复制)。
   引擎(QuickJS)本身在 crates/core::plugins,这三个只是把平台能力落到壳上:
     pluginassets —— `lpplugin://` 协议,插件目录里的图标/逃生舱页面
     pluginmarket —— 插件市场源(命令实现体在这里,不在 lib.rs)
     plugins_host —— PluginHost trait 的壳侧实现(player/ui/emby 通道)
   ★ 它们只依赖 linplayer_core / tauri / tokio / async-trait,不碰 Win32/X11 —— 所以能跨编译。
   ★ 命令必须用**裸名字**注册进 generate_handler!(写成 `pluginmarket::xxx` 虽然编译得过,
     但 Tauri 生成的命令名会带上模块前缀,前端 invoke 不到)——所以这里 `use pluginmarket::*`。 */
mod pluginassets;
mod pluginmarket;
use pluginmarket::*;
mod plugins_host;

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
use linplayer_core::danmaku::{self, DanmakuAuthType, DanmakuComment, DanmakuSourceConfig};
use linplayer_core::config::DanmakuServer;
use linplayer_core::media::{pick_tracks, TrackPrefs};
use linplayer_core::net::cf;
use linplayer_core::plugins::PluginManager;
use linplayer_core::source::quark_tv;
use linplayer_core::watch_history as wh;
use std::collections::HashMap;
use std::sync::atomic::{AtomicU32, AtomicU64, Ordering};
use std::sync::{Arc, Mutex, OnceLock};
use tokio::sync::oneshot;
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

    /* ---- 2026-07-26 手机端接入时补齐(与 apps/desktop 的 AppState 同名同义) ----
       ★ 这些字段和桌面壳是**逐字对应**的。两边漂移不会编译报错,只会让某个命令
         在手机上行为和 PC 不一样 —— 加字段时两边一起加。 */
    /// Ani-RSS 管理接口(listAni/config/…)不在 MediaSourceBackend trait 上,trait object 取不到,
    /// 故另存具体类型。**与 source_backends[Anirss] 是同一个 Arc**,共享同一份 token_cache。
    anirss: Arc<AniRssBackend>,
    /// 当前正在播放的源条目(entry_id, entry_name),供 302 重签重解析;None=非源播放
    source_play_entry: Mutex<Option<(String, String)>>,
    /// 连续 302 重签次数(防死循环),每次新播放清零
    resign_count: AtomicU32,
    /// CF 优选:server_id -> 本地钉 IP 反代句柄
    cf_proxy: Mutex<HashMap<String, linplayer_core::net::cf::CfProxyHandle>>,
    /// 本地观看记录(跨服务器续播)。长驻,自持存盘。
    watch_history: linplayer_core::watch_history::WatchHistory,
    /// 剧 -> TMDB id 缓存(跨服匹配剧集要它;每部剧只查一次)
    series_tmdb: Mutex<HashMap<String, Option<String>>>,
    /// 自动挂弹幕的连号锚点:seriesId|seasonId -> (集号, 弹弹Play episodeId)
    danmaku_anchors: Mutex<HashMap<String, (i64, i64)>>,
    /// 观看记录续播:本次会话已经问过的条目(问过一次就别再弹)
    wh_done: Mutex<std::collections::HashSet<String>>,
    /// 待确认的跨服续播候选
    wh_ctx: Mutex<Option<(String, linplayer_core::watch_history::Candidate, Option<String>)>>,
    /// 插件管理器。OnceLock:setup 里建好后再塞进来。
    plugins: OnceLock<Arc<PluginManager>>,
    /// 插件 ui 通道:等前端 plugin_ui_respond 回填的 oneshot
    ui_pending: Mutex<HashMap<u64, oneshot::Sender<serde_json::Value>>>,
    ui_seq: AtomicU64,
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

    /* 跨服务器续播的上下文。**不接这一段的话,watch_history_* 那几条命令注册了也是死的** ——
       没有人往 wh_ctx 里写,列表永远空、续播永远只认本服进度,而且不报错。
       (2026-07-26 手机端接入时补:桌面早就有,安卓这半边一直缺。)
       ★ 与桌面同构:ctx 和取流地址并发打,两者互不依赖。能 join 的前提是这两条路上
         **没有跨 await 持有的 std Mutex** —— build_wh_ctx→series_tmdb_cached 的锁在 await
         之前就出了作用域。往这两条路上加锁时务必重新确认,否则 join! 把两个 future 放同一
         线程轮询,一方持锁 await、另一方去抢同一把锁 = 自我死锁,症状是起播直接吊死不报错。 */
    let ctx = build_wh_ctx(&state, &s, &item_id).await;
    let resume_secs = match &ctx {
        Some((scope, cand, series_tmdb)) => {
            let cross = state.config.lock().unwrap().prefs.cross_server_resume;
            state
                .watch_history
                .resolve_resume_position_ticks(
                    scope,
                    cand,
                    series_tmdb.as_deref(),
                    Some((resume_secs * wh::TICKS_PER_SEC as f64) as i64),
                    cand.played,
                    cross,
                )
                .map(|t| t as f64 / wh::TICKS_PER_SEC as f64)
                .unwrap_or(resume_secs)
        }
        // 取不到匹配判据(网络抖/权限)不该拦住播放,按前端给的进度走。
        None => resume_secs,
    };
    *state.wh_ctx.lock().unwrap() = ctx;
    /* 回传去重集按「一次播放」计生命周期:不清的话,看完第二集时第一集的去重键还在,
       同一台服务器会被判成"已回传过"而跳过 —— 静默漏传。 */
    state.wh_done.lock().unwrap().clear();
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

/// 播放已下载完成的本地文件。传的是**任务 id**,不是路径。
///
/// 2026-07-26 接上(此前是个直接返回错的桩)。下载功能在手机上价值最高 ——
/// 离线通勤看片正是手机独有的场景,下得了却播不了等于下载页是个摆设。
///
/// 与桌面同名命令同构,少的两件事安卓本来就没有:
///   - `apply_playback_defaults`(硬解档位/杜比开关是桌面设置项)
///   - `show_video`(桌面要显隐那个独立的 mpv 顶层窗口;安卓是 SurfaceView,一直在)
#[tauri::command]
fn play_local(
    state: State<'_, AppState>,
    ps: State<'_, PlayerState>,
    id: String,
    resume_secs: f64,
) -> Result<f64, String> {
    let path = state.download.completed_path(&id).ok_or("该任务尚未下载完成")?;
    /* 索引说完成了不代表文件还在 —— 用户可能自己删了/挪走了,或者外部存储被卸载。
       不先确认的话 mpv 会拿着一个不存在的路径静默失败,表现是黑屏等一个永远不来的 status。 */
    if !std::path::Path::new(&path).is_file() {
        return Err(format!("文件已不存在:{path}"));
    }
    poclog(&format!("PLAY LOCAL id={id} path={path}"));
    {
        let guard = ensure_player(&ps)?;
        let p = guard.as_ref().ok_or("播放器未就绪")?;
        let _ = p.take_error_eof();
        p.load_at(&path, resume_secs)?;
        p.set_pause(false);
    }
    /* 本地文件不属于任何 Emby 条目 —— 三个上下文都要清干净,否则:
         playback 不清 → 进度会被上报到**上一部**在线播放的条目上
         scrobble_ctx 不清 → Trakt/Bangumi 记成看了那一部
         wh_ctx 不清 → 本地观看记录也记到那一部头上
       三个都是"不报错但记错账"的静默 bug。 */
    *ps.playback.lock().unwrap() = None;
    *state.source_play_entry.lock().unwrap() = None; // 非源播放,停 302 看门狗
    *state.scrobble_ctx.lock().unwrap() = None;
    *state.wh_ctx.lock().unwrap() = None;
    state.resign_count.store(0, Ordering::Relaxed);
    Ok(resume_secs)
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
    // 验证配置可用 —— 不验的话错地址也会"添加成功",进去才发现是空的。
    // 探测口径(为什么不能只试 list_dir)见 core 里 probe_backend 的注释;
    // 那个函数放在核层就是为了不让桌面/安卓这两份拷贝各写一遍、各改一遍。
    linplayer_core::source::probe_backend(backend.as_ref(), &state.http, &server)
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
    // 停止时必须落地,不受节流 —— 漏了它就是"看完退出,进度没记住"。
    capture_history(&state, pos, true);
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
    // 反查失败要说清楚是**哪一步**失败:搜不到 / 相似度不够 / 分集表里没这集。
    let r = match matched {
        Ok(r) => r,
        Err(e) => {
            log::warn!("[Bangumi] 反查失败,跳过标记({}):{e}", info.title);
            return;
        }
    };
    // 失败必须把原因打出来:上一版只打 true/false,一个 404 端点藏了几个月。
    fn say(what: &str, r: Result<(), String>) {
        match r {
            Ok(()) => log::info!("[Bangumi] {what} OK"),
            Err(e) => log::warn!("[Bangumi] {what} 失败: {e}"),
        }
    }
    if info.media_type == "movie" {
        say("电影标记看过", bangumi::set_collection_type(acc, r.subject_id, 2).await);
        return;
    }
    say(
        &format!("收藏为在看 subject={}", r.subject_id),
        bangumi::set_collection_type(acc, r.subject_id, 3).await,
    );
    say(
        &format!("单集标看过 ep={}", r.episode_id),
        bangumi::update_episode_status(acc, r.subject_id, r.episode_id, 2).await,
    );
    if r.is_last_episode {
        say("最后一集,整部标看过", bangumi::set_collection_type(acc, r.subject_id, 2).await);
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
    // 本地观看记录(跨服续播的数据来源)。force=false → 走内部节流,不会每几秒写一次盘。
    capture_history(&state, pos, false);
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

#[derive(serde::Serialize)]
struct SourceOverview {
    server_id: String,
    server_name: String,
    source_kind: String,
    is_file_browse: bool,
    active: bool,
    counts: emby::Counts,
    resume: Vec<Item>,
}

/// 聚合视界 / 首页统计的数据源:每个已登录源的**规模 + 最近观看记录**,一次拿齐。
///
/// ★ 为什么合成一条命令而不是「counts 一条、resume 一条」:手机端首页顶栏和聚合视界
///   要的是同一批数据(N 台服务器 × 两个请求)。拆成两条前端就得发 2N 次 invoke,
///   而且两批数据到达时间不同 —— 页面会先画出"有数字没内容"再补上,那是可见的抖动。
///
/// ★ 单台失败隔离:某台服务器不通 / 不支持 /Items/Counts(fork 上是真会 404 的,
///   本文件里 /Items/Filters、/Years、/Tags 就都是 404),只让它那一节是零,
///   不能让整页报错。counts 和 resume **各自**吞错。
///
/// ★ 文件浏览型源(网盘)没有 Emby 那套接口,直接给零 —— 它们仍然出现在列表里,
///   因为用户确实有这么一台源,藏起来只会让人以为"我的网盘丢了"。
#[tauri::command]
async fn aggregate_overview(state: State<'_, AppState>) -> Result<Vec<SourceOverview>, String> {
    /* ★ `active` 在 config 上不在 Account 上——先把“哪一台是当前”读出来再放手锁，
       别在 spawn 里再去拿锁（那是跨线程持锁）。 */
    let (accounts, device_id, active_server) = {
        let cfg = state.config.lock().unwrap();
        (
            cfg.accounts.clone(),
            cfg.device_id.clone(),
            cfg.active_account().map(|a| a.server.clone()),
        )
    };
    let mut handles = Vec::new();
    for a in accounts {
        let http = state.http.clone();
        let device_id = device_id.clone();
        let is_active = active_server.as_deref() == Some(a.server.as_str());
        handles.push(tauri::async_runtime::spawn(async move {
            let base = SourceOverview {
                server_id: a.server.clone(),
                server_name: a.display_name(),
                source_kind: a.source_kind.as_str().to_string(),
                is_file_browse: a.is_file_browse(),
                active: is_active,
                counts: emby::Counts::default(),
                resume: Vec::new(),
            };
            if a.is_file_browse() {
                return base;
            }
            let s = Session {
                // 必须走生效线路 —— 理由同 aggregate_search:用户切到备用线是因为主线不通,
                // 打主线的结果是这台服静默变成"零条目",查都没处查。
                server: a.active_line_url(),
                token: a.token.clone(),
                user_id: a.user_id.clone(),
                device_id,
            };
            let (counts, resume) = tokio::join!(emby::counts(&http, &s), emby::resume(&http, &s, 12));
            SourceOverview {
                counts: counts.unwrap_or_default(),
                resume: resume.unwrap_or_default(),
                ..base
            }
        }));
    }
    let mut out = Vec::new();
    for h in handles {
        if let Ok(v) = h.await {
            out.push(v);
        }
    }
    Ok(out)
}

/// 截图。手机版播放页左中那颗相机键（用户 2026-07-28 定的九宫格）。
///
/// ★ 和桌面版的区别：不读 `prefs.screenshot_dir`。
///   那个设置项靠桌面文件对话框选目录，而 `pick_directory` 在安卓上是
///   明确不做的（SAF 是另一套交互）。所以这里直接落到数据根下的
///   `screenshots/` —— 它就是外部应用专属目录，文件管理器看得见、不需任何权限。
///   **不是系统相册** —— 往相册写要过 MediaStore，那是宏层的活；
///   前端的提示文案必须跟实话说，别写"已保存到相册"。
#[tauri::command]
fn screenshot(ps: State<'_, PlayerState>, dir: Option<String>) -> Result<String, String> {
    let base = match dir.filter(|d| !d.trim().is_empty()) {
        Some(d) => std::path::PathBuf::from(d),
        None => linplayer_core::paths::root().join("screenshots"),
    };
    std::fs::create_dir_all(&base).map_err(|e| format!("建截图目录失败: {e}"))?;
    let guard = ps.player.lock().unwrap();
    let p = guard.as_ref().ok_or("播放器未就绪")?;
    let at = p.status().time.max(0.0) as i64;
    let stamp = std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map(|d| d.as_secs())
        .unwrap_or(0);
    let path = base.join(format!("shot-{stamp}-{at}s.png"));
    let s = path.to_string_lossy().into_owned();
    p.screenshot_to(&s)?;
    Ok(s)
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
async fn views(state: State<'_, AppState>, include_blocked: Option<bool>) -> Result<Vec<Item>, String> {
    let s = session_of(&state)?;
    let mut v = emby::views(&state.http, &s).await?;
    /* 屏蔽掉的媒体库不出现在**列表里**(首页的媒体库轨、各库「最新」行、侧栏)。
       ★ 缺省过滤,`include_blocked=true` 才给全量 —— 只有媒体库页那份列表要全量:
         它是唯一能把库找回来解除屏蔽的地方,滤掉就成了单向门。
       ★ 这里不走 blocklist::filter(那条按 series_id/名字比,是给条目用的):
         库没有 series_id,而"名字对得上"在库上是错的判据 —— 两台服务器上都叫
         「电影」的库是两个不同的库,按名字判会一屏两台一起屏蔽。 */
    if !include_blocked.unwrap_or(false) {
        v.retain(|x| !linplayer_core::blocklist::is_blocked_id(&x.id));
    }
    Ok(v)
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
///
/// ★ 手动标「看过」也要同步 Bangumi:在这之前只有播到 80% 走 sync_on_stop 那条路才会同步,
/// 用户在详情页/卡片上手点「标为看完」Bangumi 那边毫无反应。
/// 反查要打好几次 Bangumi API(搜条目 + 拉分集表),放后台跑,别让 UI 的勾等它。
/// 取消已看不回滚 Bangumi —— 那是另一个语义(撤销收藏),用户没要。
#[tauri::command]
async fn set_played(state: State<'_, AppState>, item_id: String, played: bool) -> Result<(), String> {
    let s = session_of(&state)?;
    emby::set_played(&state.http, &s, &item_id, played).await?;
    let acc = state.config.lock().unwrap().sync_bangumi.clone();
    if let (true, Some(acc)) = (played, acc) {
        let http = state.http.clone();
        tauri::async_runtime::spawn(async move {
            // 非 Movie/Episode(整季、整剧)拿不到 info,静默跳过。
            let Some(info) = emby::fetch_scrobble_info(&http, &s, &item_id).await else { return };
            if info.title.is_empty() {
                return;
            }
            mark_bangumi_watched(&acc, &info).await;
        });
    }
    Ok(())
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

/// 演职员详情(生平/出生地/生卒)。生平为空是常态 —— 只有刮到 TMDB 人物页才有。
#[tauri::command]
async fn person_detail(
    state: State<'_, AppState>,
    person_id: String,
) -> Result<emby::PersonDetail, String> {
    let s = session_of(&state)?;
    emby::person_detail(&state.http, &s, &person_id).await
}

/// 某人参演的电影 / 剧集(按首播倒序)。
#[tauri::command]
async fn person_items(
    state: State<'_, AppState>,
    person_id: String,
    limit: Option<u32>,
) -> Result<Vec<Item>, String> {
    let s = session_of(&state)?;
    emby::person_items(&state.http, &s, &person_id, limit.unwrap_or(60)).await
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
    // 缺省 = true（桌面/TV 的旧调用点不传，行为不变）。
    // 手机端传 false：它按季分页拉集，不需要这一坨。
    with_children: Option<bool>,
) -> Result<emby::ItemDetail, String> {
    let s = session_of(&state)?;
    emby::detail(&state.http, &s, &item_id, with_children.unwrap_or(true)).await
}

/// 某剧的季列表（手机端详情页的季 Tab 条）。
/// ★ 季名用**服务器返回的 Name**，前端不要拼「第 N 季」。
#[tauri::command]
async fn series_seasons(
    state: State<'_, AppState>,
    series_id: String,
) -> Result<Vec<emby::SeasonInfo>, String> {
    let s = session_of(&state)?;
    emby::seasons(&state.http, &s, &series_id).await
}

/// 分集分页。parent_id 可以是季 id，也可以是剧 id（没分季的剧）。
#[tauri::command]
async fn season_episodes(
    state: State<'_, AppState>,
    parent_id: String,
    start_index: Option<i64>,
    limit: Option<i64>,
) -> Result<emby::ItemPage, String> {
    let s = session_of(&state)?;
    emby::season_episodes(
        &state.http,
        &s,
        &parent_id,
        start_index.unwrap_or(0),
        limit.unwrap_or(30),
    )
    .await
}

/// 条目的全部版本+流(详情页「版本/音轨/字幕」选择器 + 媒体信息块)。
#[tauri::command]
async fn item_media(
    state: State<'_, AppState>,
    item_id: String,
) -> Result<Vec<emby::MediaVersion>, String> {
    let s = session_of(&state)?;
    // 版本正则只用来标 preferred:前端据此显示「当前版本」,和真起播时挑的那条对齐。
    let version_regex = state.config.lock().unwrap().prefs.version_regex.clone();
    emby::media_versions(&state.http, &s, &item_id, &version_regex).await
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

/* ── 影视目录能力(资源站这类源) ─────────────────────────────────────
   ★ 桌面侧(apps/desktop/src/lib.rs)有一份**同构的拷贝** —— 改一边必须改另一边。
   网盘走 source_list_dir(文件树),资源站走这三条。不支持的源返回带
   __LP_UNSUPPORTED__ 前缀的错误,前端据此静默退回文件浏览页。 */

#[tauri::command]
async fn source_categories(
    state: State<'_, AppState>,
) -> Result<Vec<linplayer_core::source::MediaCategory>, String> {
    let (kind, server) = state.source.lock().unwrap().clone().ok_or("未登录源")?;
    let backend = source_backend(&state, &kind)?;
    let r = backend.categories(&state.http, &server).await.map_err(|e| e.message);
    persist_rotated(&state, &kind, &backend);
    r
}

#[tauri::command]
async fn source_catalog(
    state: State<'_, AppState>,
    category_id: Option<String>,
    keyword: Option<String>,
    page: u32,
) -> Result<linplayer_core::source::MediaPage, String> {
    let (kind, server) = state.source.lock().unwrap().clone().ok_or("未登录源")?;
    let backend = source_backend(&state, &kind)?;
    let kw = keyword.as_deref().filter(|s| !s.trim().is_empty());
    let r = backend
        .catalog(&state.http, &server, category_id.as_deref(), kw, page.max(1))
        .await
        .map_err(|e| e.message);
    persist_rotated(&state, &kind, &backend);
    r
}

#[tauri::command]
async fn source_media_detail(
    state: State<'_, AppState>,
    id: String,
) -> Result<linplayer_core::source::MediaDetail, String> {
    let (kind, server) = state.source.lock().unwrap().clone().ok_or("未登录源")?;
    let backend = source_backend(&state, &kind)?;
    let r = backend
        .media_detail(&state.http, &server, &id)
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

/* 与桌面同名的辅助项(同样是 2026-07-26 从 apps/desktop 搬来的,理由见下一段注释)。 */
type Json = serde_json::Value;

/// 取某剧的 TMDB id,按 seriesId 缓存(含「查过但没有」的负缓存,别对没刮削的剧反复打服务器)。
/// 对齐 Dart 的 _seriesTmdbCache。
async fn series_tmdb_cached(state: &State<'_, AppState>, s: &Session, series_id: &str) -> Option<String> {
    if let Some(hit) = state.series_tmdb.lock().unwrap().get(series_id) {
        return hit.clone();
    }
    let got = emby::series_tmdb_id(&state.http, s, series_id).await;
    state.series_tmdb.lock().unwrap().insert(series_id.to_string(), got.clone());
    got
}

/// 装配播放条目的观看记录上下文:取带匹配判据的 Item -> Candidate(+剧的 TMDB id)。
/// 失败不该阻断播放 —— 观看记录是增值功能,不是播放的前置。
async fn build_wh_ctx(
    state: &State<'_, AppState>,
    s: &Session,
    item_id: &str,
) -> Option<(String, wh::Candidate, Option<String>)> {
    let item = emby::item_for_history(&state.http, s, item_id).await.ok()?;
    let cand = wh::Candidate::from(&item);
    let series_tmdb = match cand.series_id.as_deref() {
        Some(sid) => series_tmdb_cached(state, s, sid).await,
        None => None,
    };
    Some((scope_of(s), cand, series_tmdb))
}

/// 把当前进度记进本地观看记录。force=true 用于停止播放(必须落地,不受节流)。
fn capture_history(state: &State<'_, AppState>, pos: f64, force: bool) {
    let ctx = state.wh_ctx.lock().unwrap().clone();
    let Some((scope, cand, series_tmdb)) = ctx else { return };
    state.watch_history.capture_playback(
        &scope,
        &cand,
        series_tmdb.as_deref(),
        (pos * wh::TICKS_PER_SEC as f64) as i64,
        wh::WriteSource::InternalPlayer,
        90, // 看过阈值:与 Emby 默认一致
        false,
        force,
    );
}

// ---------- 弹幕 ----------
fn danmaku_cfg(s: &DanmakuServer) -> DanmakuSourceConfig {
    /* 鉴权**不再让用户选**,由地址推导(见 danmaku::derive_auth 上的查证依据)。
       ★ 但老配置里显式存过 auth_type 的源要继续按老的走 —— 用户可能配着 headerToken
         的自建端,推导不出来;为了「简化 UI」把人家配好的源弄失效,那是砸招牌。
       所以:auth_type 为空 = 新源,走推导;非空 = 老源,尊重原值。 */
    /* "" 和 "none" 都当「没选过」→ 走推导。
       ★ 不能只认空串:老 UI 新建源时写死的就是 "none",全端存量源多半都是它。
         只认空串的话推导对绝大多数源永远不生效(而且不报错)。
         "none" 本身也不携带信息,推导出来只会更准(比如把 ?token= 拆对)。 */
    let auto = matches!(s.auth_type.trim(), "" | "none");
    let (api_url, auth_type, token) = if auto {
        let (u, a, t) = linplayer_core::danmaku::derive_auth(&s.api_url);
        (u, a, t)
    } else {
        let a = match s.auth_type.as_str() {
            "pathToken" => DanmakuAuthType::PathToken,
            "headerToken" => DanmakuAuthType::HeaderToken,
            "queryToken" => DanmakuAuthType::QueryToken,
            _ => DanmakuAuthType::None,
        };
        (s.api_url.clone(), a, (!s.token.is_empty()).then(|| s.token.clone()))
    };
    // id/name 必须逐源取,不能写死 —— 多源下写死会让所有源撞成同一身份,分组结果串台。
    DanmakuSourceConfig {
        id: if s.id.trim().is_empty() { s.api_url.clone() } else { s.id.clone() },
        name: if s.name.trim().is_empty() { "自建源".into() } else { s.name.clone() },
        api_url,
        official: false,
        auth_type: Some(auth_type),
        token,
        app_id: None,
        app_secret: None,
    }
}

fn official_danmaku_cfg() -> Option<DanmakuSourceConfig> {
    let (app_id, app_secret) = linplayer_core::secrets::dandan_creds()?;
    Some(DanmakuSourceConfig {
        id: DANDAN_OFFICIAL_SOURCE_ID.into(),
        name: "弹弹Play".into(),
        api_url: String::new(), // official=true 走固定 OFFICIAL_BASE
        official: true,
        auth_type: Some(DanmakuAuthType::None),
        token: None,
        app_id: Some(app_id),
        app_secret: Some(app_secret),
    })
}

/// 诊断日志。旧版直接往 %TEMP% 根丢 linplayer_poc.log —— 现在收进自己的 logs/。
fn app_log_path() -> std::path::PathBuf {
    linplayer_core::paths::logs_dir().join("app.log")
}

fn account_info(a: &linplayer_core::Account, active: bool) -> AccountInfo {
    account_info_with(a, active, AccountStatus::Unknown)
}

fn scope_of(s: &Session) -> String {
    wh::scope_key(&s.server, &s.user_id)
}

/// 播放器可调项快照(前端 OSD 一次拉齐,不用逐个 get)。
#[derive(serde::Serialize)]
struct PlayerOpts {
    speed: f64,
    volume: f64,
    muted: bool,
    audio_delay: f64,
    sub_delay: f64,
    hwdec: String,
    shader_count: usize,
    /// 当前在播的这一版是不是杜比视界。
    ///
    /// 给前端的用途:播放页「更多」里那行「杜比视界软解」开关**必须照实反映现状**。
    /// 核层现在会按设置自动给 DV 切软解 —— 前端要是还把这行初始化成写死的 false,
    /// 用户看到的就是「明明已经在软解,开关却显示关着」,典型的 UI 撒谎。
    dolby_vision: bool,
}

/// 应用超分档位的结果。
/// ★ 为什么不只回一个数:`count>0` 只能证明 mpv **收下了**路径,**证明不了 shader 会跑**。
///   Anime4K 每个 pass 都带 `//!WHEN 输出>源*1.2`,窗口没比源大就整条链空转 —— 画面一点没变,
///   而旧版 UI 照样报「超分已生效 · 挂载 6 个 shader」。那就是在撒谎,正是本项目最贵的那类 bug。
#[derive(serde::Serialize)]
struct ShaderApplied {
    /// mpv 收下的 shader 数(0 而档位非 off = 连挂都没挂上)。
    count: usize,
    /// 当前尺寸下这条链会不会真的跑。None = 没在播,尺寸未知,不下结论。
    will_run: Option<bool>,
    /// will_run=false 时的人话解释(带真实数字),UI 直接显示。
    note: Option<String>,
}

/// 组装参与本次请求的弹幕源:启用的自建源(按 priority)+ 官方弹弹Play(有编译期凭据才有)。
/// 对齐 Dart 的 `sourcesFor(allowOfficial:)` —— 启用/排序/官方过滤都在宿主这层决定。
fn danmaku_sources(state: &State<'_, AppState>, allow_official: bool) -> Vec<DanmakuSourceConfig> {
    let mut out: Vec<DanmakuSourceConfig> = state
        .config
        .lock()
        .unwrap()
        .enabled_danmaku_sources()
        .iter()
        .filter(|s| !s.api_url.trim().is_empty())
        .map(danmaku_cfg)
        .collect();
    if allow_official {
        out.extend(official_danmaku_cfg());
    }
    out
}

/// 内置的弹弹Play 默认源在设置页的展示信息。
///
/// 它**不在** `danmaku_sources` 里(凭据是编译期注入的,不落配置文件),所以设置页
/// 原来根本看不见它 —— 用户会以为「一个弹幕源都没有」,而实际上默认源一直在工作。
/// 这里单独透出来给 UI 显示,只读:名字固定、地址是官方的、凭据不给前端。
#[derive(serde::Serialize)]
struct OfficialDanmaku {
    name: String,
    /// 编译期没注入凭据的构建里它就是不可用的,得如实说,别显示成「已启用」。
    available: bool,
}

/// 活跃会话的基址跟随当前生效线路(含 CF 改写)重新对齐。
/// 开关反代后必须调:否则改写只对**之后**新建的会话生效,当前这条还打老地址 ——
/// 表现为"开了优选没反应,重启才生效"。
fn refresh_session_base(state: &AppState, server_id: &str) {
    let cfg = state.config.lock().unwrap();
    let is_active = cfg.active_account().map(|a| a.server == server_id).unwrap_or(false);
    if !is_active {
        return;
    }
    if let Some(url) = cfg.find(server_id).map(|a| a.active_line_url()) {
        if let Some(s) = state.session.lock().unwrap().as_mut() {
            s.server = url;
        }
    }
}

pub(crate) fn plugins_mgr(state: &AppState) -> Result<Arc<PluginManager>, String> {
    state.plugins.get().cloned().ok_or_else(|| "插件系统未就绪".to_string())
}

fn sync_plugin_source_grants(state: &AppState) {
    let Some(mgr) = state.plugins.get() else { return };
    let mut per_plugin: HashMap<String, Vec<String>> = HashMap::new();
    {
        let cfg = state.config.lock().unwrap();
        for a in &cfg.accounts {
            if let Some((plugin_id, _)) = a.source_kind.as_plugin() {
                if let Some(src) = a.source.as_ref() {
                    per_plugin
                        .entry(plugin_id.to_string())
                        .or_default()
                        .push(src.base_url.clone());
                }
            }
        }
    }
    // 已启用但一个源都没配的插件也要显式清空,否则上一轮的授权会留着。
    for (plugin_id, _, _) in mgr.data_sources() {
        per_plugin.entry(plugin_id).or_default();
    }
    for (plugin_id, urls) in per_plugin {
        mgr.set_source_grants(&plugin_id, &urls);
    }
}

fn poclog(msg: &str) {
    use std::io::Write;
    let path = app_log_path();
    if let Ok(mut f) = std::fs::OpenOptions::new().create(true).append(true).open(path) {
        let _ = writeln!(f, "{msg}");
    }
}

#[derive(serde::Serialize)]
struct BatchAddResult {
    /// 加成功的服务器主键(= 生效线路 URL);失败为 None。
    server_id: Option<String>,
    /// 展示名。
    name: String,
    /// 失败原因;成功为 None。
    error: Option<String>,
}

/// 跨服回传设置(主开关 / 范围 / 是否带进度)。
#[derive(serde::Serialize, serde::Deserialize)]
struct WritebackSettings {
    enabled: bool,
    /// "all" | "first" | "latest"
    range: String,
    include_progress: bool,
}

/// 弹弹Play 官方源配置(编译期加密注入凭据齐才有);无凭据返回 None。
/// 官方弹弹Play 源的 id。★ 是 "official",不是 Dart 那边的 "dandanplay" ——
/// 自动挂弹幕的 episodeId 连号快路径要按它认源,写错了不报错,只是快路径永远不命中。
const DANDAN_OFFICIAL_SOURCE_ID: &str = "official";

fn require_danmaku_sources(state: &State<'_, AppState>) -> Result<Vec<DanmakuSourceConfig>, String> {
    let v = danmaku_sources(state, true);
    if v.is_empty() {
        return Err("未配置弹幕服务器(且无官方弹弹Play凭据)".into());
    }
    Ok(v)
}

/// 主动搜索限流:只在这次请求会打到**官方**源时才拦(自建源是用户自己的服务器,无配额)。
/// 桌面端同款,见 apps/desktop/src/lib.rs::danmaku_search_gate。
fn danmaku_search_gate(sources: &[DanmakuSourceConfig]) -> Result<(), String> {
    if sources.iter().any(|s| s.official) {
        danmaku::search_gate()?;
    }
    Ok(())
}

// ---------- 夸克 TV 扫码登录 ----------
#[derive(serde::Serialize)]
struct QuarkScan {
    device_id: String,
    qr_data: String,
    query_token: String,
}

/// 取(ani-rss 后端 + 当前服务器)。当前活跃源不是 ani-rss 时直接报错 —— 管理接口只对 ani-rss 有意义。
fn anirss_ctx(state: &State<'_, AppState>) -> Result<(Arc<AniRssBackend>, SourceServer), String> {
    let (kind, server) = state.source.lock().unwrap().clone().ok_or("未登录源")?;
    if kind != SourceKind::anirss() {
        return Err("当前源不是 Ani-RSS".to_string());
    }
    Ok((state.anirss.clone(), server))
}

#[derive(serde::Serialize)]
struct CfProxyStatus {
    /// 走优选的**线路**地址(改写表的键)。粒度是线路不是服务器,见 net::cf::runtime 顶部。
    line_url: String,
    /// 它属于哪台服务器(供设置页显示服务器名);查不到时为空串。
    server_id: String,
    /// 这条线路在账号线路表里的名字(「主线」/「CDN」…),查不到为空串。
    line_name: String,
    local_url: String,
    pinned_ip: String,
}

/// 多线程加载(预取代理)设置。threads 引擎内部 clamp 到 2~4。
/// `servers` = 开了这功能的账号 id(Account.server);空表 = 全关。
#[derive(serde::Serialize, serde::Deserialize)]
struct PrefetchSettings {
    servers: Vec<String>,
    threads: usize,
    cache_bytes: u64,
}

/// 章节(跳过片头片尾 + 进度条缩略图)。两个功能同一份数据,前端只拉一次。
/// 返回 `(章节表, 片头区间, 片尾起点)` —— 区间判定放核层,免得前端各写一套匹配规则。
#[derive(serde::Serialize)]
struct ChapterInfo {
    chapters: Vec<linplayer_core::emby::Chapter>,
    /// 用户开了「自动跳过」且真识别出片头时才非空。关着开关时这里恒为 None ——
    /// 前端不必再判一次开关(判两次早晚判岔)。
    intro: Option<(f64, f64)>,
    /// 片尾 `(开始, 结束)`。结束 == 总时长 = 片尾之后没别的了(别 seek,那等于强行结束播放)。
    outro: Option<(f64, f64)>,
    /// 缩略图开关(关着时前端别去加载章节图,白费流量)。
    thumbs: bool,
}

/* ============================================================
   2026-07-26 从 apps/desktop/src/lib.rs 搬过来的命令实现体。

   ★ 为什么是复制而不是共享一个 crate:
     `apps/android` 刻意**不依赖 apps/desktop**(那个包绑死 Win32/X11,交叉编译第一步就死),
     而 `#[tauri::command]` 又不能放进 `crates/core`(core 是故意不依赖 tauri 的)。
     真正的解法是再抽一个 `crates/shell`,但那是把 5800 行的桌面壳整体重构 ——
     不能顺手做。所以这里沿用本仓库既有的做法:壳侧薄包装各自一份,
     **真逻辑全在 crates/core 和 crates/mpv**(这批 146 个命令平均 10.5 行)。

   ★ 这是一处「两处只改一处」的风险面。改这批命令时两边一起改。

   ★ 与桌面的唯一系统性差异:播放器在安卓是独立的 `PlayerState`(它的生命周期跟 Surface 走,
     不能跟 AppState 一起建),所以凡是碰播放器的命令,签名里的 `state.player`
     都改成了 `ps.player`。
   ============================================================ */

/// 取播放器再执行一段操作。与桌面同名宏,只是这里吃的是 `PlayerState`。
macro_rules! with_player {
    ($state:expr, $p:ident => $body:expr) => {{
        let guard = $state.player.lock().unwrap();
        let $p = guard.as_ref().ok_or("播放器未就绪")?;
        $body;
        Ok(())
    }};
}

/// 重新登录:**地址不用填**,拿账号当前生效的线路去认证,只换凭据。
///
/// 用户 2026-07-15:「重新登录是重新填写账密,线路不用重新填写,用的还是服务器线路里面的线路」。
///
/// ## 为什么不能复用 `login`
/// `login` 是按**登录时用的那个地址**做 upsert 的(`result.server`)。
/// 而这里认证走的是 `direct_line_url()`(可能是某条 CDN 线路),它 ≠ 账号主键 `a.server`。
/// 拿 login 顶替 → upsert 命中不到原账号 → **凭空多出一台服务器**,原账号还在,
/// 用户以为重登好了,其实是加了一台。EditDialog 上原本就有一段注释在警告这个坑,
/// 现在地址挪进线路表,这个坑就更近了 —— 所以这里 find_mut 定点改字段,不 upsert。
///
/// ## 用户名也能改
/// 编辑框的「账号」现在可编辑。改账号 = 换了个人,token/user_id 全得换 —— 必须真登一次,
/// 不能只把 user_name 字段改掉(那样 token 还是旧用户的,表现为「显示是新账号、
/// 看到的还是旧账号的媒体库」这种要命的静默错位)。
#[tauri::command]
async fn relogin(
    state: State<'_, AppState>,
    server_id: String,
    username: String,
    password: String,
) -> Result<(), String> {
    // ★ 锁不跨 await。
    let (line_url, device_id) = {
        let cfg = state.config.lock().unwrap();
        let a = cfg.find(&server_id).ok_or("找不到该服务器")?;
        (a.direct_line_url().to_string(), cfg.device_id.clone())
    };
    let (_, result) = emby::login(&state.http, &line_url, &username, &password, &device_id).await?;

    let is_active = {
        let mut cfg = state.config.lock().unwrap();
        let a = cfg.find_mut(&server_id).ok_or("找不到该服务器")?;
        // 定点换凭据。**不动 server/name/remark/icon/lines/active_line** —— 那些是用户的编辑。
        a.token = result.token.clone();
        a.user_id = result.user_id.clone();
        a.user_name = result.user_name.clone();
        a.password = (!password.is_empty()).then_some(password);
        cfg.save();
        cfg.active_account().map(|x| x.server == server_id).unwrap_or(false)
    };
    // 是当前活跃账号就顺手把内存会话也换了,否则后续请求还在拿旧 token 打 401。
    if is_active {
        let cfg = state.config.lock().unwrap();
        let a = cfg.find(&server_id).ok_or("找不到该服务器")?;
        *state.session.lock().unwrap() = Some(Session {
            server: a.active_line_url(),
            token: a.token.clone(),
            user_id: a.user_id.clone(),
            device_id: cfg.device_id.clone(),
        });
    }
    Ok(())
}

/// 启动时的活跃源(浏览型)——前端据此决定落文件浏览页而不是媒体库。
#[tauri::command]
fn current_source(state: State<'_, AppState>) -> Option<AccountInfo> {
    let cfg = state.config.lock().unwrap();
    cfg.active_account().filter(|a| a.is_file_browse()).map(|a| account_info(a, true))
}

#[tauri::command]
async fn list_items(state: State<'_, AppState>, parent_id: String) -> Result<Vec<Item>, String> {
    let s = session_of(&state)?;
    // 保持返回 Vec<Item>:现有前端 invoke<Item[]>("list_items", { parentId }) 直接 .map,
    // 改成 ItemPage 会在运行时炸(tsc 是泛型断言,拦不住)。要总数/翻页/筛选走 list_items_page。
    Ok(emby::items(&state.http, &s, &parent_id, &emby::ItemQuery::default())
        .await?
        .items)
}

/// 测试连接 / 取服务器公开信息(草稿页 06「测试连接」)。★ 登录前调用,故不走 session_of。
#[tauri::command]
async fn test_connection(state: State<'_, AppState>, server: String) -> Result<emby::ServerInfo, String> {
    emby::server_info(&state.http, &server).await
}

/// 合集(BoxSet)。
#[tauri::command]
async fn list_collections(state: State<'_, AppState>) -> Result<Vec<Item>, String> {
    let s = session_of(&state)?;
    emby::collections(&state.http, &s).await
}

/// 网络图标库(改图标弹窗浏览用)。默认命中 24h 缓存,force=true 重新拉四源。
/// 返回空 = 从没拉成功过且本次也失败 → 前端提示「拉取失败」。
#[tauri::command]
// 不再收 State:图标库拉的是公共图标仓库、不是 Emby,用默认 UA 的通用客户端就够
// (见 http.rs 的 UA 口径),不需要 AppState 里那个 Emby 客户端。
async fn icon_library(force: bool) -> Result<Vec<linplayer_core::icon_library::IconEntry>, String> {
    // async 命令 tauri 要求返 Result;库本身不报错(失败回退旧缓存/空)。
    Ok(linplayer_core::icon_library::library(&http::client(), force).await)
}

/// 当前账号是不是该服务器的管理员。前端据此决定右键菜单里出不出那三项管理动作。
#[tauri::command]
async fn is_admin(state: State<'_, AppState>) -> Result<bool, String> {
    let s = session_of(&state)?;
    emby::is_admin(&state.http, &s).await
}

/// 刷新某个库/条目的元数据。full=false 只补缺失,full=true 强制重刮。
#[tauri::command]
async fn refresh_item(
    state: State<'_, AppState>,
    item_id: String,
    full: bool,
) -> Result<(), String> {
    let s = session_of(&state)?;
    emby::refresh_item(&state.http, &s, &item_id, full).await
}

/// 扫描整台服务器的媒体库文件(找新加进来的片子)。
#[tauri::command]
async fn scan_libraries(state: State<'_, AppState>) -> Result<(), String> {
    let s = session_of(&state)?;
    emby::scan_all_libraries(&state.http, &s).await
}

/// 编辑服务器:名称/备注/图标/TLS 放行/密码。None=不改该字段。
#[tauri::command]
fn update_account(
    state: State<'_, AppState>,
    server_id: String,
    name: Option<String>,
    remark: Option<String>,
    icon_url: Option<String>,
    allow_insecure_tls: Option<bool>,
    password: Option<String>,
) -> Result<(), String> {
    let mut cfg = state.config.lock().unwrap();
    let a = cfg.find_mut(&server_id).ok_or("找不到该服务器")?;
    if let Some(v) = name {
        a.name = v;
    }
    // 备注/图标传空串 = 清空,传 None = 不动。
    if let Some(v) = remark {
        a.remark = (!v.trim().is_empty()).then_some(v);
    }
    if let Some(v) = icon_url {
        a.icon_url = (!v.trim().is_empty()).then_some(v);
    }
    if let Some(v) = allow_insecure_tls {
        a.allow_insecure_tls = v;
    }
    if let Some(v) = password {
        a.password = (!v.is_empty()).then_some(v);
    }
    cfg.save();
    Ok(())
}

/// 启动参数里的 `linplayer://...`(系统通过协议拉起我们时会作为 argv 传进来)。
/// 前端进主界面后调一次;有值就走确认流程。
///
/// ⚠️ 只在**冷启动**时有效。App 已经开着时再点深链,系统会拉起第二个进程 ——
/// 那需要单实例守卫(tauri-plugin-single-instance),没接,已知缺口。
#[tauri::command]
fn startup_deep_link() -> Option<String> {
    std::env::args().skip(1).find(|a| a.starts_with("linplayer://"))
}

/// 用户从本地挑一张图当服务器图标。返回 data URI 供前端立刻显示。
#[tauri::command]
fn set_account_icon_file(
    state: State<'_, AppState>,
    server_id: String,
    file_path: String,
) -> Result<String, String> {
    let uri = linplayer_core::icon_cache::set_from_file(&server_id, &file_path)?;
    // icon_url 记成本地路径:重装/清缓存后还能从原文件重建,不用让用户再挑一次。
    let mut cfg = state.config.lock().unwrap();
    let a = cfg.find_mut(&server_id).ok_or("找不到该服务器")?;
    a.icon_url = Some(file_path);
    cfg.save();
    Ok(uri)
}

/// 清掉图标缓存,下次 account_icon 会重新下载(服务器换了 logo 时用)。
#[tauri::command]
fn clear_account_icon(server_id: String) {
    linplayer_core::icon_cache::clear(&server_id);
}

/// 解析分享文本 → 结构化账号块。**纯解析,不登录、不落盘** ——
/// 前端拿去展示让用户核对/补用户名,确认后再调 batch_add_servers。
#[tauri::command]
fn batch_parse(text: String) -> Vec<linplayer_core::server_batch::ParsedServerBlock> {
    linplayer_core::server_batch::parse_share_text(&text)
}

/// 解析 `linplayer://add-server?...` 深链。
///
/// ⚠️ 返回 Some **不等于**可以直接加号 —— 深链可能来自任何网页/聊天窗口。
/// 前端必须弹确认框展示服务器地址和用户名,由用户点头后才调 batch_add_servers。
#[tauri::command]
fn parse_deep_link(url: String) -> Option<linplayer_core::server_batch::DeepLinkAddServer> {
    linplayer_core::server_batch::parse_deep_link(&url)
}

/// 批量添加:逐块逐线路试登录,第一条通的线路即设为生效线路,其余线路留着备用。
///
/// 为什么要逐线路试:分享文本里的「主线路」经常是最不通的那条(被墙/限速),
/// 直接钉死第 0 条会让用户加完就连不上,还得自己去线路列表里一条条点。
///
/// 参数:
/// - `fallback_username` / `fallback_password`:用户在 UI 里补的,套用到所有 username 为空的块。
/// - `fallback_name`:深链带来的服务器名(`?name=`);取不到 SystemInfo.serverName 时用。
#[tauri::command]
async fn batch_add_servers(
    state: State<'_, AppState>,
    blocks: Vec<linplayer_core::server_batch::ParsedServerBlock>,
    fallback_username: Option<String>,
    fallback_password: Option<String>,
    fallback_name: Option<String>,
) -> Result<Vec<BatchAddResult>, String> {
    use linplayer_core::server_batch as sb;
    let device_id = state.config.lock().unwrap().device_id.clone();
    let mut out = Vec::new();

    for block in &blocks {
        let lines = sb::server_lines(block);
        if lines.is_empty() {
            continue;
        }
        // 空串要当「缺用户名」处理,不能 unwrap_or_default 后闷头登 ——
        // 深链里 ?user= 显式给空串正是这种情况。
        let username = block
            .username
            .clone()
            .or_else(|| fallback_username.clone())
            .filter(|s| !s.trim().is_empty());
        let password = block
            .password
            .clone()
            .or_else(|| fallback_password.clone())
            .unwrap_or_default();
        let display = lines[0].name.clone();
        let Some(username) = username else {
            out.push(BatchAddResult {
                server_id: None,
                name: display,
                error: Some("缺用户名".into()),
            });
            continue;
        };

        let mut added = None;
        let mut last_err = String::new();
        for (i, line) in lines.iter().enumerate() {
            match emby::login(&state.http, &line.url, &username, &password, &device_id).await {
                Ok((session, result)) => {
                    let name = emby::server_info(&state.http, &line.url)
                        .await
                        .map(|si| si.name)
                        .ok()
                        .filter(|n| !n.trim().is_empty())
                        .or_else(|| fallback_name.clone())
                        .unwrap_or_default();
                    let icon = sb::build_icon_url(
                        &line.url,
                        Some(&result.user_id),
                        result.primary_image_tag.as_deref(),
                    );
                    {
                        let mut cfg = state.config.lock().unwrap();
                        cfg.upsert(Account {
                            server: result.server.clone(),
                            token: result.token.clone(),
                            user_id: result.user_id.clone(),
                            user_name: result.user_name.clone(),
                            name,
                            icon_url: Some(icon),
                            password: (!password.is_empty()).then(|| password.clone()),
                            lines: lines.clone(),
                            active_line: i, // 试通的那条即生效线路
                            ..Default::default()
                        });
                        // 块里带的弹幕线路并进全局弹幕源(接着现有源的 priority 往后排)。
                        let base = cfg.danmaku_sources.len() as i32;
                        for src in sb::danmaku_sources_of(block, base) {
                            if !cfg.danmaku_sources.iter().any(|x| x.id == src.id) {
                                cfg.danmaku_sources.push(src);
                            }
                        }
                        cfg.save();
                    }
                    *state.session.lock().unwrap() = Some(session);
                    *state.source.lock().unwrap() = None;
                    added = Some(result.server);
                    break;
                }
                Err(e) => last_err = e,
            }
        }
        match added {
            Some(id) => out.push(BatchAddResult {
                server_id: Some(id),
                name: display,
                error: None,
            }),
            None => out.push(BatchAddResult {
                server_id: None,
                name: display,
                // 所有线路都没通才算失败,报最后一条的错。
                error: Some(if last_err.is_empty() {
                    "所有线路均无法连接".into()
                } else {
                    last_err
                }),
            }),
        }
    }
    Ok(out)
}

#[tauri::command]
async fn probe_lines(state: State<'_, AppState>, server_id: String) -> Result<Vec<LineProbe>, String> {
    let urls = line_urls(&state, &server_id)?;
    // 并发探测:线路多时别串行等超时(6s × N 会把用户等睡着)。
    let tasks: Vec<_> = urls
        .into_iter()
        .enumerate()
        .map(|(index, url)| {
            let http = state.http.clone();
            tokio::spawn(async move {
                let ms = probe_one(&http, &url).await;
                LineProbe { index, url, ms }
            })
        })
        .collect();
    let mut out = Vec::with_capacity(tasks.len());
    for t in tasks {
        out.push(t.await.map_err(|e| format!("线路测速任务失败:{e}"))?);
    }
    Ok(out)
}

/// 观看记录列表。scope=None 取全部(跨服务器);否则只取当前服务器。
#[tauri::command]
fn watch_history_list(state: State<'_, AppState>, current_only: bool) -> Vec<wh::Record> {
    let mut v = if current_only {
        match session_of(&state) {
            Ok(s) => state.watch_history.load_scope(&scope_of(&s)),
            Err(_) => Vec::new(),
        }
    } else {
        state.watch_history.load_all()
    };
    // 只滤展示;理由见桌面端同名命令的注释(不动 Store,别把屏蔽做成丢进度)。
    v.retain(|r| !linplayer_core::blocklist::is_blocked_title(&r.title, r.series_title.as_deref()));
    v
}

// ---------- 媒体库屏蔽 ----------
/// 当前屏蔽名单。桌面端同名命令,行为一致。
#[tauri::command]
fn blocked_list() -> Vec<linplayer_core::blocklist::BlockedItem> {
    linplayer_core::blocklist::list()
}

/// 屏蔽 / 解除屏蔽。`name` 传剧名(分集卡传 series_name),观看记录靠它跨服对齐。
#[tauri::command]
fn set_blocked(item_id: String, name: String, blocked: bool) {
    linplayer_core::blocklist::set(&item_id, &name, blocked);
}

#[tauri::command]
fn watch_history_clear(state: State<'_, AppState>) {
    state.watch_history.clear_all();
}

#[tauri::command]
fn watch_history_delete(state: State<'_, AppState>, record_id: String) {
    state.watch_history.delete_record(&record_id);
}

#[tauri::command]
fn get_writeback_settings(state: State<'_, AppState>) -> WritebackSettings {
    let p = &state.config.lock().unwrap().prefs;
    WritebackSettings {
        enabled: p.cross_server_writeback,
        range: p.cross_server_writeback_range.clone(),
        include_progress: p.cross_server_writeback_progress,
    }
}

#[tauri::command]
fn set_writeback_settings(
    state: State<'_, AppState>,
    settings: WritebackSettings,
) -> Result<(), String> {
    let mut cfg = state.config.lock().unwrap();
    cfg.prefs.cross_server_writeback = settings.enabled;
    // from_wire 对无法识别的值静默回落 "all" —— 那会让用户以为选了"仅初次"其实在写所有服。
    // 宁可在这里拒掉。
    if !matches!(settings.range.as_str(), "all" | "first" | "latest") {
        return Err(format!("未知的回传范围: {}", settings.range));
    }
    cfg.prefs.cross_server_writeback_range = settings.range;
    cfg.prefs.cross_server_writeback_progress = settings.include_progress;
    cfg.save();
    Ok(())
}

/// 恢复扫描:拿本地观看记录去当前服务器找对应条目,strong 匹配的自动回写进度,
/// possible 匹配的放进 prompt_candidates 交给用户确认。
///
/// ⚠️ 这会**往当前服务器写**播放进度,不是只读扫描。前端别在进页面时自动跑,
/// 要给用户一个明确的「扫描并恢复」按钮。
#[tauri::command]
async fn watch_history_scan_restore(
    state: State<'_, AppState>,
) -> Result<linplayer_core::watch_history_sync::RestoreReport, String> {
    let s = session_of(&state)?;
    let scope = scope_of(&s);
    linplayer_core::watch_history_sync::scan_restore(&state.http, &s, &state.watch_history, &scope)
        .await
}

/// 用户确认某个 possible 候选后,把它写进当前服务器。
#[tauri::command]
async fn watch_history_restore_candidate(
    state: State<'_, AppState>,
    candidate: wh::RestoreCandidate,
) -> Result<bool, String> {
    let s = session_of(&state)?;
    linplayer_core::watch_history_sync::restore_candidate(
        &state.http,
        &s,
        &state.watch_history,
        &candidate,
    )
    .await
}

/// 取播放器当前可调项。
#[tauri::command]
fn player_opts(ps: State<'_, PlayerState>) -> Result<PlayerOpts, String> {
    // ★ 先取 DV 标志再拿 player 锁。反过来会在两把锁之间形成固定的持有顺序依赖,
    //   本项目在 [[prefetch-proxy-deadlock]] 上栽过同类跟头,不给它长出来的机会。
    let dolby_vision = ps
        .playback
        .lock()
        .unwrap()
        .as_ref()
        .is_some_and(|t| t.is_dolby_vision);
    let guard = ps.player.lock().unwrap();
    let p = guard.as_ref().ok_or("播放器未就绪")?;
    Ok(PlayerOpts {
        dolby_vision,
        speed: p.speed(),
        volume: p.volume(),
        muted: p.muted(),
        audio_delay: p.audio_delay(),
        sub_delay: p.sub_delay(),
        hwdec: p.hwdec(),
        shader_count: p.shader_count(),
    })
}

#[tauri::command]
fn set_speed(ps: State<'_, PlayerState>, speed: f64) -> Result<(), String> {
    with_player!(ps, p => p.set_speed(speed))
}

#[tauri::command]
fn set_volume(ps: State<'_, PlayerState>, volume: f64) -> Result<(), String> {
    with_player!(ps, p => p.set_volume(volume))
}

#[tauri::command]
fn set_mute(ps: State<'_, PlayerState>, mute: bool) -> Result<(), String> {
    with_player!(ps, p => p.set_mute(mute))
}

#[tauri::command]
fn set_audio_delay(ps: State<'_, PlayerState>, secs: f64) -> Result<(), String> {
    with_player!(ps, p => p.set_audio_delay(secs))
}

#[tauri::command]
fn set_sub_delay(ps: State<'_, PlayerState>, secs: f64) -> Result<(), String> {
    with_player!(ps, p => p.set_sub_delay(secs))
}

#[tauri::command]
fn set_aspect_ratio(ps: State<'_, PlayerState>, ratio: String) -> Result<(), String> {
    with_player!(ps, p => p.set_aspect_ratio(&ratio))
}

#[tauri::command]
fn set_hwdec(ps: State<'_, PlayerState>, mode: String) -> Result<(), String> {
    with_player!(ps, p => p.set_hwdec(&mode))
}

/// 字幕样式(字体/缩放/字号/位置/背景/混合)。None 的项不动。
///
/// ★ 这些 `sub-*` 属性**主次字幕共用** —— 不是偷懒,是 mpv 就没有分开的那一份:
/// 2026-07-16 用 ctypes 拉 libmpv 的 `property-list` 实测,`secondary-*` 名下总共只有
/// sid / ass-override / delay / pos / visibility / text / start / end / lines,
/// **不存在 secondary-sub-font-size / -font / -color**(set 回 -8 property not found)。
/// 所以「次字幕单独设字体大小」在 mpv 层面无法实现,UI 上就该如实标成主次共用,
/// 别造一个假的次字幕字号 stepper 骗人。
#[tauri::command]
fn set_sub_style(
    ps: State<'_, PlayerState>,
    font: Option<String>,
    scale: Option<f64>,
    position: Option<f64>,
    background: Option<bool>,
    blend_mode: Option<String>,
) -> Result<(), String> {
    let guard = ps.player.lock().unwrap();
    let p = guard.as_ref().ok_or("播放器未就绪")?;
    if let Some(f) = font {
        p.set_sub_font(&f);
    }
    if let Some(sc) = scale {
        p.set_sub_scale(sc);
    }
    if let Some(pos) = position {
        p.set_sub_position(pos);
    }
    if let Some(b) = background {
        p.set_sub_background(b);
    }
    if let Some(m) = blend_mode {
        p.set_sub_blend_mode(&m);
    }
    Ok(())
}

/// 次字幕(双字幕)。id 为空 = 关。
#[tauri::command]
fn set_secondary_sub(ps: State<'_, PlayerState>, id: String) -> Result<(), String> {
    with_player!(ps, p => p.set_secondary_sub(&id))
}

#[tauri::command]
fn set_secondary_sub_opts(
    ps: State<'_, PlayerState>,
    delay: Option<f64>,
    position: Option<f64>,
    ass_override: Option<String>,
) -> Result<(), String> {
    let guard = ps.player.lock().unwrap();
    let p = guard.as_ref().ok_or("播放器未就绪")?;
    if let Some(d) = delay {
        p.set_secondary_sub_delay(d);
    }
    if let Some(pos) = position {
        p.set_secondary_sub_position(pos);
    }
    if let Some(m) = ass_override {
        p.set_secondary_sub_ass_override(&m);
    }
    Ok(())
}

/// 加载外挂字幕(本地路径或 URL)。secondary=true 挂成次字幕。
#[tauri::command]
fn add_subtitle(
    ps: State<'_, PlayerState>,
    url: String,
    title: Option<String>,
    secondary: Option<bool>,
) -> Result<(), String> {
    let guard = ps.player.lock().unwrap();
    let p = guard.as_ref().ok_or("播放器未就绪")?;
    let t = title.unwrap_or_else(|| "外挂字幕".into());
    if secondary.unwrap_or(false) {
        p.add_secondary_sub(&url, &t)
    } else {
        p.add_subtitle(&url, &t);
        Ok(())
    }
}

/// 超分档位清单 `(id, 显示名, 滤镜家族)`。第三个字段是家族名(Anime4K/FSR/NVIDIA),UI 按它分三组。
#[tauri::command]
fn shader_levels() -> Vec<(&'static str, &'static str, &'static str)> {
    shaders::levels()
}

/// 应用超分档位。挂载后**双重回读**:glsl-shaders 校验挂没挂上,尺寸校验会不会真跑
/// (见 [[superres-and-toast]]:旧 Flutter 桌面软件纹理根本不跑 glsl,必须回读校验)。
#[tauri::command]
fn set_shader_level(ps: State<'_, PlayerState>, level: String) -> Result<ShaderApplied, String> {
    // .glsl 是 include_str! 编进二进制、首次用时落盘的 —— 丢了能重生成,归 cache/。
    let dir = linplayer_core::paths::cache_dir("shaders");
    let paths = shaders::shader_paths(&dir, &level)?;
    let guard = ps.player.lock().unwrap();
    let p = guard.as_ref().ok_or("播放器未就绪")?;
    /* 强度是**档位设计的一部分**(见 shaders::preset 的注释),每次挂载都得重设:
       glsl-shader-opts 是全局的,不设就吃 shader 自带默认(CAS STR=0.5,只开一半)——
       用户实测「看不太出来」正是这个。切到 off 时 opts 为空串,顺带把上一档的参数清掉。 */
    let opts = shaders::shader_opts(&level);
    if !p.set_shader_opts(opts) {
        poclog(&format!("警告: glsl-shader-opts 没设上({level} 的强度 {opts} 不会生效)"));
    }
    p.set_shaders(&paths);
    let count = p.shader_count();
    if !paths.is_empty() && count == 0 {
        return Err("超分未生效(mpv 未接受 shader)".into());
    }
    if paths.is_empty() {
        return Ok(ShaderApplied { count, will_run: None, note: None });
    }

    let (video, output) = (p.video_size(), p.output_size());
    let will_run = shaders::will_run(&level, video, output);
    let note = match (will_run, video, output) {
        (Some(false), Some((vw, vh)), Some((ow, oh))) => Some(format!(
            "这档是**放大**滤镜,当前尺寸下不会生效:要求画面区大于源的 {:.1} 倍才工作。\
             现在源 {vw:.0}×{vh:.0}、画面区只有 {ow:.0}×{oh:.0}({:.2}×)—— 你在缩小画面,没有可放大的。\
             按 F 全屏即可生效;想在窗口里就见效,请选「锐化」「去噪」「锐化+去噪」这三档。",
            shaders::WHEN_RATIO,
            ow / vw,
        )),
        _ => None,
    };
    Ok(ShaderApplied { count, will_run, note })
}

/// mpv 属性直读/直写 + 命令直通。插件桥和一次性调参用(对齐 Flutter 的
/// mpvGetProperty/mpvSetProperty/mpvCommand);有专用命令的优先用专用命令。
#[tauri::command]
fn mpv_get(ps: State<'_, PlayerState>, name: String) -> Result<Option<String>, String> {
    let guard = ps.player.lock().unwrap();
    Ok(guard.as_ref().ok_or("播放器未就绪")?.get_property(&name))
}

#[tauri::command]
fn mpv_set(ps: State<'_, PlayerState>, name: String, value: String) -> Result<(), String> {
    with_player!(ps, p => p.set_property(&name, &value))
}

#[tauri::command]
fn mpv_command(ps: State<'_, PlayerState>, args: Vec<String>) -> Result<(), String> {
    let guard = ps.player.lock().unwrap();
    guard.as_ref().ok_or("播放器未就绪")?.command(&args)
}

/// 按已存偏好自动选轨(起播后前端调一次)。返回实际选中的 (aid, sid)。
#[tauri::command]
fn apply_prefs(state: State<'_, AppState>,
    ps: State<'_, PlayerState>) -> Result<(Option<String>, Option<String>), String> {
    let prefs = state.config.lock().unwrap().prefs.clone();
    let guard = ps.player.lock().unwrap();
    let p = guard.as_ref().ok_or("播放器未就绪")?;
    let tracks = p.tracks();
    let (aid, sid) = pick_tracks(
        &tracks,
        TrackPrefs {
            audio_lang: prefs.audio_lang.as_deref(),
            sub_lang: prefs.sub_lang.as_deref(),
            sub_enabled: prefs.sub_enabled,
            audio_regex: &prefs.audio_regex,
            sub_regex: &prefs.sub_regex,
        },
    );
    p.apply_tracks(aid.clone(), sid.clone());
    Ok((aid, sid))
}

/// 设置页的正则合法性校验。**必须问 Rust**:前端的 JS RegExp 语法集和 Rust 的
/// regex crate 不同(Rust 无前后瞻/反向引用),用 JS 校验会放过 Rust 编译不过的写法,
/// 于是设置存下了却永不命中,还一声不吭。空串合法(= 关闭该项)。
#[tauri::command]
fn validate_track_regex(pattern: String) -> Result<(), String> {
    linplayer_core::media::validate_track_regex(&pattern)
}

/// 保存三条筛选正则(版本/字幕/音频)。非法直接拒,不落盘。
#[tauri::command]
fn set_track_regexes(
    state: State<'_, AppState>,
    version_regex: String,
    sub_regex: String,
    audio_regex: String,
) -> Result<(), String> {
    for p in [&version_regex, &sub_regex, &audio_regex] {
        linplayer_core::media::validate_track_regex(p)?;
    }
    let mut cfg = state.config.lock().unwrap();
    // 同 set_prefs:只改这三项,别整体覆盖 Prefs。
    cfg.prefs = Prefs { version_regex, sub_regex, audio_regex, ..cfg.prefs.clone() };
    cfg.save();
    Ok(())
}

/// 自建弹幕源列表(设置页增删改查)。
#[tauri::command]
fn get_danmaku_config(state: State<'_, AppState>) -> Vec<DanmakuServer> {
    state.config.lock().unwrap().danmaku_sources.clone()
}

#[tauri::command]
fn get_official_danmaku() -> OfficialDanmaku {
    OfficialDanmaku {
        name: "弹弹Play".into(),
        available: linplayer_core::secrets::dandan_creds().is_some(),
    }
}

/// 覆写自建弹幕源表。id 为空的自动补一个(用 api_url 做稳定身份)。
#[tauri::command]
fn set_danmaku_config(
    state: State<'_, AppState>,
    sources: Vec<DanmakuServer>,
) -> Result<(), String> {
    let mut cfg = state.config.lock().unwrap();
    cfg.danmaku_sources = sources
        .into_iter()
        .map(|mut s| {
            if s.id.trim().is_empty() {
                s.id = s.api_url.trim().trim_end_matches('/').to_string();
            }
            s
        })
        .collect();
    cfg.save();
    Ok(())
}

/// 按标题搜弹幕**条目**(不带集列表)。多源并行,分组返回供用户挑源。
/// 集列表在用户点了条目之后走 [`danmaku_episodes`] 单独取 —— 一次搜索出几百集
/// 用户「眼都看花了」,而且 /search/episodes 也慢得多。
#[tauri::command]
async fn danmaku_search(
    state: State<'_, AppState>,
    keyword: String,
) -> Result<Vec<danmaku::DanmakuSourceGroup>, String> {
    let sources = require_danmaku_sources(&state)?;
    danmaku_search_gate(&sources)?;
    Ok(danmaku::search_all_grouped(&state.http, &sources, &keyword).await)
}

/// 取某源某条目的集列表(用户点开某部番时才发)。
#[tauri::command]
async fn danmaku_episodes(
    state: State<'_, AppState>,
    source_id: String,
    anime_id: String,
    anime_title: String,
) -> Result<Vec<danmaku::DanmakuEpisode>, String> {
    let sources = require_danmaku_sources(&state)?;
    let cfg = sources
        .iter()
        .find(|c| c.id == source_id)
        .ok_or_else(|| format!("弹幕源不存在: {source_id}"))?;
    danmaku::episodes_for_anime(&state.http, cfg, &anime_id, &anime_title).await
}

/// 智能匹配:按标题/集号/文件名多源并行匹配,返回候选(带评分)供自动或手动挑。
#[tauri::command]
async fn danmaku_match(
    state: State<'_, AppState>,
    input: danmaku::MatchInput,
) -> Result<Vec<danmaku::DanmakuMatchCandidate>, String> {
    // 手动重新匹配也走一整轮 /match + /search/episodes,和搜索一样烧配额,一样要限流。
    let sources = require_danmaku_sources(&state)?;
    danmaku_search_gate(&sources)?;
    // 匹配打不通(配额用尽/签名错/源挂了)时这里是 Err —— 别吞成空表,
    // 否则界面只会说「未找到匹配的弹幕」,而那不是真相。桌面端同款口径。
    danmaku::match_all(&state.http, &sources, &input).await
}

/// 自动匹配的分数门槛(前端据此决定「自动挂上」还是「让用户挑」)。
#[tauri::command]
fn danmaku_min_auto_score() -> f64 {
    danmaku::MIN_AUTO_SCORE
}

/// 取某集弹幕评论(走缓存)。preferred_source 指定用哪个源;不指定则按 priority 依次试。
#[tauri::command]
async fn danmaku_load(
    state: State<'_, AppState>,
    episode_id: String,
    source_id: Option<String>,
    ch_convert: Option<i32>,
) -> Result<Vec<DanmakuComment>, String> {
    let sources = require_danmaku_sources(&state)?;
    Ok(danmaku::get_comments_from_all(
        &state.http,
        &sources,
        &episode_id,
        source_id.as_deref(),
        ch_convert.unwrap_or(0),
    )
    .await)
}

/// 播放开始时自动匹配并挂弹幕。对齐 Dart DanmakuAutoLoader。
///
/// 返回 None = 没自动挂(没匹配上 / 分数不够 / 取到空弹幕)。这不是错误:
/// 给非动漫内容硬塞错配弹幕比不挂更糟,用户仍可手动搜索。
///
/// 快路径:弹弹Play 同一作品的 episodeId 是连号的(第 N 集 +1 = 第 N+1 集)。
/// 追番看下一集时直接 +1 取,省一次 match 往返。猜错(跨季/特殊编号)会取到空弹幕,
/// 自动退回全量匹配 —— 所以「取到非空」就是这条快路径的兜底校验,别去掉。
///
/// `anchor_key`:剧集锚点键(seriesId|seasonId);网盘/无剧集上下文传 None 即关掉快路径。
#[tauri::command]
async fn danmaku_auto_load(
    state: State<'_, AppState>,
    input: danmaku::MatchInput,
    options: danmaku::FilterOptions,
    ch_convert: Option<i32>,
    anchor_key: Option<String>,
) -> Result<Option<Vec<DanmakuComment>>, String> {
    /* ★ 官方源只在「可能是番」时才带上 —— 判据和取舍见桌面端同名命令的长注释。
       一句话:非动漫内容往官方接口打一整轮是纯烧配额,而元数据为空时必须放行。 */
    let allow_official = danmaku::allow_official_for(&input.genres);
    let sources = danmaku_sources(&state, allow_official);
    if sources.is_empty() {
        return if allow_official {
            Err("未配置弹幕服务器(且无官方弹弹Play凭据)".into())
        } else {
            Ok(None) // 非动漫 + 无自建源 = 这片本来就不该有弹幕,不是错误
        };
    }
    let ch = ch_convert.unwrap_or(0);
    let finish = |raw: Vec<DanmakuComment>| danmaku::apply_filter_and_dedup(raw, &options);

    // 快路径:紧邻下一集。
    if let (Some(key), Some(ep)) = (anchor_key.as_ref(), input.episode_no) {
        let guess = {
            let anchors = state.danmaku_anchors.lock().unwrap();
            anchors.get(key).and_then(|(a_ep, a_id)| (ep == a_ep + 1).then_some(a_id + 1))
        };
        if let Some(gid) = guess {
            let raw = danmaku::get_comments_from_all(
                &state.http,
                &sources,
                &gid.to_string(),
                Some(DANDAN_OFFICIAL_SOURCE_ID),
                ch,
            )
            .await;
            if !raw.is_empty() {
                state
                    .danmaku_anchors
                    .lock()
                    .unwrap()
                    .insert(key.clone(), (ep, gid));
                return Ok(Some(finish(raw)));
            }
        }
    }

    let candidates = danmaku::match_all(&state.http, &sources, &input).await?;
    let Some(best) = candidates.into_iter().next().filter(|c| c.score >= danmaku::MIN_AUTO_SCORE)
    else {
        return Ok(None);
    };
    let raw = danmaku::get_comments_from_all(
        &state.http,
        &sources,
        &best.episode_id,
        Some(&best.source_id),
        ch,
    )
    .await;
    if raw.is_empty() {
        return Ok(None);
    }
    // 只有官方源 + episodeId 是纯数字时才记锚点 —— 自建源的 id 未必连号,
    // 拿去 +1 会取到隔壁作品的弹幕(不报错,只是全篇对不上)。
    if best.source_id == DANDAN_OFFICIAL_SOURCE_ID {
        if let (Some(key), Some(ep), Ok(id)) =
            (anchor_key, input.episode_no, best.episode_id.parse::<i64>())
        {
            state.danmaku_anchors.lock().unwrap().insert(key, (ep, id));
        }
    }
    Ok(Some(finish(raw)))
}

/// 过滤 + 去重(屏蔽词/屏蔽用户/合并重复)。渲染参数不在这层 —— 那是前端的事。
#[tauri::command]
fn danmaku_filter(
    comments: Vec<DanmakuComment>,
    options: danmaku::FilterOptions,
) -> Vec<DanmakuComment> {
    danmaku::apply_filter_and_dedup(comments, &options)
}

/// 导入弹弹Play 导出的屏蔽词 XML。
#[tauri::command]
fn danmaku_import_blocklist(xml: String) -> danmaku::DanmakuFilterImportResult {
    danmaku::import_dandanplay_blocklist_xml(&xml)
}

#[tauri::command]
fn danmaku_cache_clear() -> usize {
    danmaku::cache_clear()
}

#[tauri::command]
fn danmaku_cache_size() -> u64 {
    danmaku::cache_disk_size_bytes()
}

/// 加载本地弹幕文件(xml / json / ass / ssa)。格式按**内容**嗅探,不只信扩展名 ——
/// 用户从别处存下来的弹幕改过名是常事。
///
/// 整文件解析失败返回 Err:绝不能返回空 Vec 假装成功,那会让用户看到
/// 「加载成功但一条弹幕都没有」然后无从排查。单条畸形则跳过。
#[tauri::command]
fn danmaku_load_local(path: String) -> Result<Vec<DanmakuComment>, String> {
    let p = std::path::Path::new(&path);
    let content = std::fs::read(p).map_err(|e| format!("读不到弹幕文件: {e}"))?;
    // 弹幕文件常见 GBK/UTF-16 编码,但 from_utf8_lossy 至少不会整个失败;
    // 真乱码时下面的解析会因为找不到 <d>/cues 而报错,不会静默返回空。
    let text = String::from_utf8_lossy(&content);
    let name = p.file_name().and_then(|s| s.to_str()).unwrap_or("");
    linplayer_core::danmaku::local::parse(name, &text)
}

/// 起扫码:生成 device_id,拿二维码内容 + query_token。
#[tauri::command]
async fn quark_scan_start(state: State<'_, AppState>) -> Result<QuarkScan, String> {
    let device_id = quark_tv::gen_device_id();
    let (qr_data, query_token) = quark_tv::get_login_code(&state.http, &device_id)
        .await
        .map_err(|e| e.message)?;
    Ok(QuarkScan { device_id, qr_data, query_token })
}

/// 轮询扫码结果:用户确认后拿 code→换 refresh_token→建立夸克 TV 源为活跃源。
/// 返回 true=登录成功;false=尚未确认(继续轮询)。
#[tauri::command]
async fn quark_scan_poll(
    state: State<'_, AppState>,
    device_id: String,
    query_token: String,
) -> Result<bool, String> {
    let code = match quark_tv::get_code(&state.http, &device_id, &query_token).await {
        Ok(c) if !c.is_empty() => c,
        _ => return Ok(false), // 未确认/接口报错 -> 继续轮询
    };
    let (_access, refresh) = quark_tv::exchange_token(&state.http, &device_id, &code, false)
        .await
        .map_err(|e| e.message)?;
    let mut extra = HashMap::new();
    extra.insert("device_id".to_string(), device_id);
    extra.insert("refresh_token".to_string(), refresh);
    let server = SourceServer {
        id: "quark-tv".to_string(),
        base_url: String::new(),
        username: None,
        password: None,
        token: None,
        extra,
    };
    *state.source.lock().unwrap() = Some((SourceKind::quark(), server));
    Ok(true)
}

/// 302 看门狗:探测直链是否失效(END_FILE=error),失效则重解析并从 pos 续播。返回是否重签了。
/// 前端播放中每轮轮询调用;仅对网盘源播放生效(Emby 直链稳定,不重签)。
#[tauri::command]
async fn source_watchdog(state: State<'_, AppState>,
    ps: State<'_, PlayerState>, pos: f64) -> Result<bool, String> {
    // 无失效信号 or 非源播放 -> 什么都不做
    let errored = {
        let guard = ps.player.lock().unwrap();
        match guard.as_ref() {
            Some(p) => p.take_error_eof(),
            None => return Ok(false),
        }
    };
    let entry = state.source_play_entry.lock().unwrap().clone();
    let (Some((entry_id, entry_name)), true) = (entry, errored) else {
        return Ok(false);
    };
    let Some((kind, server)) = state.source.lock().unwrap().clone() else {
        return Ok(false);
    };
    // 连续重签超上限:文件本身放不了(非过期),放弃以免死循环。
    if state.resign_count.load(Ordering::Relaxed) >= 3 {
        *state.source_play_entry.lock().unwrap() = None;
        poclog("302 重签连续 3 次仍失败,放弃");
        return Ok(false);
    }
    state.resign_count.fetch_add(1, Ordering::Relaxed);
    let backend = source_backend(&state, &kind)?;
    let entry = SourceEntry {
        id: entry_id,
        name: entry_name,
        is_dir: false,
        is_video: true,
        size: None,
        thumb_url: None,
        raw: None,
    };
    // 重解析拿新直链,从原位置续播。
    let resolved = backend
        .resolve_play(&state.http, &server, &entry, None)
        .await
        .map_err(|e| e.message)?;
    poclog(&format!("302 重签 -> {}", resolved.url));
    let guard = ps.player.lock().unwrap();
    let p = guard.as_ref().ok_or("播放器未就绪")?;
    p.load_with_headers(
        &resolved.url,
        pos,
        &resolved.http_headers,
        resolved.user_agent_override.as_deref(),
    )?;
    p.set_pause(false);
    Ok(true)
}

#[tauri::command]
async fn anirss_list_ani(state: State<'_, AppState>) -> Result<Vec<Json>, String> {
    let (b, s) = anirss_ctx(&state)?;
    b.list_ani(&state.http, &s).await.map_err(|e| e.message)
}

#[tauri::command]
async fn anirss_play_list(state: State<'_, AppState>, ani: Json) -> Result<Json, String> {
    let (b, s) = anirss_ctx(&state)?;
    b.play_list(&state.http, &s, ani).await.map_err(|e| e.message)
}

#[tauri::command]
async fn anirss_get_themoviedb_group(state: State<'_, AppState>, ani: Json) -> Result<Json, String> {
    let (b, s) = anirss_ctx(&state)?;
    b.get_themoviedb_group(&state.http, &s, ani).await.map_err(|e| e.message)
}

#[tauri::command]
async fn anirss_torrents_infos(state: State<'_, AppState>) -> Result<Json, String> {
    let (b, s) = anirss_ctx(&state)?;
    b.torrents_infos(&state.http, &s).await.map_err(|e| e.message)
}

#[tauri::command]
async fn anirss_search_bgm(state: State<'_, AppState>, name: String) -> Result<Json, String> {
    let (b, s) = anirss_ctx(&state)?;
    b.search_bgm(&state.http, &s, &name).await.map_err(|e| e.message)
}

#[tauri::command]
async fn anirss_get_ani_by_subject_id(state: State<'_, AppState>, id: String) -> Result<Json, String> {
    let (b, s) = anirss_ctx(&state)?;
    b.get_ani_by_subject_id(&state.http, &s, &id).await.map_err(|e| e.message)
}

#[tauri::command]
async fn anirss_add_ani(state: State<'_, AppState>, ani: Json) -> Result<(), String> {
    let (b, s) = anirss_ctx(&state)?;
    b.add_ani(&state.http, &s, ani).await.map_err(|e| e.message)
}

#[tauri::command]
async fn anirss_set_ani(state: State<'_, AppState>, ani: Json) -> Result<(), String> {
    let (b, s) = anirss_ctx(&state)?;
    b.set_ani(&state.http, &s, ani).await.map_err(|e| e.message)
}

#[tauri::command]
async fn anirss_delete_ani(
    state: State<'_, AppState>,
    ids: Vec<String>,
    delete_files: bool,
) -> Result<(), String> {
    let (b, s) = anirss_ctx(&state)?;
    b.delete_ani(&state.http, &s, &ids, delete_files).await.map_err(|e| e.message)
}

#[tauri::command]
async fn anirss_refresh_ani(state: State<'_, AppState>, id: String) -> Result<(), String> {
    let (b, s) = anirss_ctx(&state)?;
    b.refresh_ani(&state.http, &s, &id).await.map_err(|e| e.message)
}

#[tauri::command]
async fn anirss_refresh_all(state: State<'_, AppState>) -> Result<(), String> {
    let (b, s) = anirss_ctx(&state)?;
    b.refresh_all(&state.http, &s).await.map_err(|e| e.message)
}

#[tauri::command]
async fn anirss_update_total_episode_number(
    state: State<'_, AppState>,
    ids: Vec<String>,
    force: bool,
) -> Result<(), String> {
    let (b, s) = anirss_ctx(&state)?;
    b.update_total_episode_number(&state.http, &s, &ids, force).await.map_err(|e| e.message)
}

#[tauri::command]
async fn anirss_batch_enable(
    state: State<'_, AppState>,
    ids: Vec<String>,
    value: bool,
) -> Result<(), String> {
    let (b, s) = anirss_ctx(&state)?;
    b.batch_enable(&state.http, &s, &ids, value).await.map_err(|e| e.message)
}

#[tauri::command]
async fn anirss_get_config(state: State<'_, AppState>) -> Result<Json, String> {
    let (b, s) = anirss_ctx(&state)?;
    b.get_config(&state.http, &s).await.map_err(|e| e.message)
}

/// 回写设置。前端**必须**回传 anirss_get_config 拿到的完整 map 改字段后的结果,否则丢字段。
#[tauri::command]
async fn anirss_set_config(state: State<'_, AppState>, config: Json) -> Result<(), String> {
    let (b, s) = anirss_ctx(&state)?;
    b.set_config(&state.http, &s, config).await.map_err(|e| e.message)
}

#[tauri::command]
async fn anirss_about(state: State<'_, AppState>) -> Result<Json, String> {
    let (b, s) = anirss_ctx(&state)?;
    b.about(&state.http, &s).await.map_err(|e| e.message)
}

#[tauri::command]
async fn anirss_preview_ani(state: State<'_, AppState>, ani: Json) -> Result<Json, String> {
    let (b, s) = anirss_ctx(&state)?;
    b.preview_ani(&state.http, &s, ani).await.map_err(|e| e.message)
}

/// 从 previewAni 的返回里提取条目列表(服务端装 List 的 key 不定,core 按形状找)。纯解析,不发请求。
#[tauri::command]
fn anirss_preview_items(preview: Json) -> Vec<Json> {
    linplayer_core::source::anirss::preview_items(&preview)
}

#[tauri::command]
async fn anirss_download_path(state: State<'_, AppState>, ani: Json) -> Result<Json, String> {
    let (b, s) = anirss_ctx(&state)?;
    b.download_path(&state.http, &s, ani).await.map_err(|e| e.message)
}

#[tauri::command]
async fn anirss_get_bgm_title(state: State<'_, AppState>, ani: Json) -> Result<String, String> {
    let (b, s) = anirss_ctx(&state)?;
    b.get_bgm_title(&state.http, &s, ani).await.map_err(|e| e.message)
}

#[tauri::command]
async fn anirss_get_themoviedb_name(state: State<'_, AppState>, ani: Json) -> Result<Json, String> {
    let (b, s) = anirss_ctx(&state)?;
    b.get_themoviedb_name(&state.http, &s, ani).await.map_err(|e| e.message)
}

#[tauri::command]
async fn anirss_refresh_cover(state: State<'_, AppState>, ani: Json) -> Result<String, String> {
    let (b, s) = anirss_ctx(&state)?;
    b.refresh_cover(&state.http, &s, ani).await.map_err(|e| e.message)
}

#[tauri::command]
async fn anirss_scrape(state: State<'_, AppState>, ani: Json, force: bool) -> Result<(), String> {
    let (b, s) = anirss_ctx(&state)?;
    b.scrape(&state.http, &s, ani, force).await.map_err(|e| e.message)
}

#[tauri::command]
async fn anirss_batch_scrape(
    state: State<'_, AppState>,
    ids: Vec<String>,
    force: bool,
) -> Result<(), String> {
    let (b, s) = anirss_ctx(&state)?;
    b.batch_scrape(&state.http, &s, &ids, force).await.map_err(|e| e.message)
}

#[tauri::command]
async fn anirss_rate(state: State<'_, AppState>, ani: Json) -> Result<i64, String> {
    let (b, s) = anirss_ctx(&state)?;
    b.rate(&state.http, &s, ani).await.map_err(|e| e.message)
}

#[tauri::command]
async fn anirss_set_rate(state: State<'_, AppState>, ani: Json) -> Result<i64, String> {
    let (b, s) = anirss_ctx(&state)?;
    b.set_rate(&state.http, &s, ani).await.map_err(|e| e.message)
}

#[tauri::command]
async fn anirss_me_bgm(state: State<'_, AppState>) -> Result<Json, String> {
    let (b, s) = anirss_ctx(&state)?;
    b.me_bgm(&state.http, &s).await.map_err(|e| e.message)
}

#[tauri::command]
async fn anirss_mikan(
    state: State<'_, AppState>,
    text: String,
    season: Option<Json>,
) -> Result<Json, String> {
    let (b, s) = anirss_ctx(&state)?;
    b.mikan(&state.http, &s, &text, season).await.map_err(|e| e.message)
}

#[tauri::command]
async fn anirss_mikan_group(state: State<'_, AppState>, url: String) -> Result<Json, String> {
    let (b, s) = anirss_ctx(&state)?;
    b.mikan_group(&state.http, &s, &url).await.map_err(|e| e.message)
}

#[tauri::command]
async fn anirss_ani_bt(state: State<'_, AppState>) -> Result<Json, String> {
    let (b, s) = anirss_ctx(&state)?;
    b.ani_bt(&state.http, &s).await.map_err(|e| e.message)
}

#[tauri::command]
async fn anirss_ani_bt_group(state: State<'_, AppState>, bgm_id: String) -> Result<Json, String> {
    let (b, s) = anirss_ctx(&state)?;
    b.ani_bt_group(&state.http, &s, &bgm_id).await.map_err(|e| e.message)
}

#[tauri::command]
async fn anirss_anime_garden_list(state: State<'_, AppState>) -> Result<Json, String> {
    let (b, s) = anirss_ctx(&state)?;
    b.anime_garden_list(&state.http, &s).await.map_err(|e| e.message)
}

#[tauri::command]
async fn anirss_anime_garden_group(state: State<'_, AppState>, bgm_id: String) -> Result<Json, String> {
    let (b, s) = anirss_ctx(&state)?;
    b.anime_garden_group(&state.http, &s, &bgm_id).await.map_err(|e| e.message)
}

/// 由 RSS 生成订阅 Ani(之后 anirss_add_ani 添加)。kind = mikan/ani-bt/anime-garden/other。
#[tauri::command]
async fn anirss_rss_to_ani(
    state: State<'_, AppState>,
    url: String,
    kind: String,
    bgm_url: Option<String>,
    subgroup: String,
    enable: bool,
) -> Result<Json, String> {
    let (b, s) = anirss_ctx(&state)?;
    b.rss_to_ani(&state.http, &s, &url, &kind, bgm_url.as_deref(), &subgroup, enable)
        .await
        .map_err(|e| e.message)
}

/// 取某文件的字幕。filename = PlayItem.filename 的 base64 原文(**勿再编码**)。
#[tauri::command]
async fn anirss_get_subtitles(state: State<'_, AppState>, filename: String) -> Result<Json, String> {
    let (b, s) = anirss_ctx(&state)?;
    b.get_subtitles(&state.http, &s, &filename).await.map_err(|e| e.message)
}

#[tauri::command]
async fn anirss_logs(state: State<'_, AppState>) -> Result<Json, String> {
    let (b, s) = anirss_ctx(&state)?;
    b.logs(&state.http, &s).await.map_err(|e| e.message)
}

#[tauri::command]
async fn anirss_download_logs(state: State<'_, AppState>) -> Result<String, String> {
    let (b, s) = anirss_ctx(&state)?;
    b.download_logs(&state.http, &s).await.map_err(|e| e.message)
}

#[tauri::command]
async fn anirss_clear_logs(state: State<'_, AppState>) -> Result<(), String> {
    let (b, s) = anirss_ctx(&state)?;
    b.clear_logs(&state.http, &s).await.map_err(|e| e.message)
}

#[tauri::command]
async fn anirss_clear_cache(state: State<'_, AppState>) -> Result<(), String> {
    let (b, s) = anirss_ctx(&state)?;
    b.clear_cache(&state.http, &s).await.map_err(|e| e.message)
}

#[tauri::command]
async fn anirss_ping(state: State<'_, AppState>) -> Result<(), String> {
    let (b, s) = anirss_ctx(&state)?;
    b.ping(&state.http, &s).await.map_err(|e| e.message)
}

#[tauri::command]
async fn anirss_download_login_test(state: State<'_, AppState>, config: Json) -> Result<(), String> {
    let (b, s) = anirss_ctx(&state)?;
    b.download_login_test(&state.http, &s, config).await.map_err(|e| e.message)
}

#[tauri::command]
async fn anirss_test_proxy(
    state: State<'_, AppState>,
    url: String,
    config: Json,
) -> Result<Json, String> {
    let (b, s) = anirss_ctx(&state)?;
    b.test_proxy(&state.http, &s, &url, config).await.map_err(|e| e.message)
}

#[tauri::command]
async fn anirss_test_ip_whitelist(state: State<'_, AppState>) -> Result<(), String> {
    let (b, s) = anirss_ctx(&state)?;
    b.test_ip_whitelist(&state.http, &s).await.map_err(|e| e.message)
}

/// 触发服务端自更新(升级 ani-rss 本体)。
#[tauri::command]
async fn anirss_server_update(state: State<'_, AppState>) -> Result<(), String> {
    let (b, s) = anirss_ctx(&state)?;
    b.server_update(&state.http, &s).await.map_err(|e| e.message)
}

/// 停止/重启服务(status 由服务端定义,0 通常为停止)。
#[tauri::command]
async fn anirss_stop(state: State<'_, AppState>, status: i64) -> Result<(), String> {
    let (b, s) = anirss_ctx(&state)?;
    b.stop(&state.http, &s, status).await.map_err(|e| e.message)
}

#[tauri::command]
async fn anirss_new_notification(state: State<'_, AppState>) -> Result<Json, String> {
    let (b, s) = anirss_ctx(&state)?;
    b.new_notification(&state.http, &s).await.map_err(|e| e.message)
}

#[tauri::command]
async fn anirss_get_emby_views(
    state: State<'_, AppState>,
    notification_config: Json,
) -> Result<Json, String> {
    let (b, s) = anirss_ctx(&state)?;
    b.get_emby_views(&state.http, &s, notification_config).await.map_err(|e| e.message)
}

/// 导出设置的下载 URL(带令牌;交给浏览器/系统打开)。
#[tauri::command]
async fn anirss_export_config_url(state: State<'_, AppState>) -> Result<String, String> {
    let (b, s) = anirss_ctx(&state)?;
    b.export_config_url(&state.http, &s).await.map_err(|e| e.message)
}

/// 导入设置(bytes = 配置文件字节;前端用 File.arrayBuffer() 传数字数组)。
#[tauri::command]
async fn anirss_import_config(
    state: State<'_, AppState>,
    bytes: Vec<u8>,
    filename: String,
) -> Result<(), String> {
    let (b, s) = anirss_ctx(&state)?;
    b.import_config(&state.http, &s, &bytes, &filename).await.map_err(|e| e.message)
}

/// 经服务端代理取图的 URL(TMDB 相对路径等)。
#[tauri::command]
async fn anirss_proxy_image_url(state: State<'_, AppState>, img_url: String) -> Result<String, String> {
    let (b, s) = anirss_ctx(&state)?;
    b.proxy_image_url(&state.http, &s, &img_url).await.map_err(|e| e.message)
}

/// 清 token 缓存(重新登录前调;下次请求会用账密重登)。
#[tauri::command]
fn anirss_clear_token(state: State<'_, AppState>, server_id: String) {
    state.anirss.clear_token(&server_id);
}

// ---------- CF 优选反代命令 ----------
/// 跑 CF 优选测速,返回排好序的候选 IP(最优在前)。validate_host 传 Emby 域名可剔除
/// 「TCP 通但 HTTP 死」的边缘;传 None/空则跳过 HTTP 校验。
#[tauri::command]
async fn cf_speed_test(
    validate_host: Option<String>,
    test_url: Option<String>,
) -> Result<Vec<linplayer_core::net::cf::CfTestResult>, String> {
    let mut o = linplayer_core::net::cf::CfSpeedTestOptions::default();
    if let Some(h) = validate_host {
        o.validate_host = h;
    }
    if let Some(u) = test_url.filter(|s| !s.is_empty()) {
        o.test_url = u;
    }
    Ok(linplayer_core::net::cf::speed_test(o).await)
}

/// 归一化线路地址 —— 必须和 `net::cf::runtime::key` 同口径,否则句柄表和改写表会错开:
/// 改写生效了但句柄找不到(= 关不掉),或者反过来。
fn norm_line(u: &str) -> String {
    u.trim().trim_end_matches('/').to_string()
}

/// 按**线路**找它属于哪台服务器(关优选 / 刷会话时要用)。
fn server_of_line(state: &AppState, line_url: &str) -> Option<String> {
    let want = norm_line(line_url);
    let cfg = state.config.lock().unwrap();
    cfg.accounts
        .iter()
        .find(|a| {
            norm_line(&a.server) == want || a.lines.iter().any(|l| norm_line(&l.url) == want)
        })
        .map(|a| a.server.clone())
}

/// 为**某一条线路**开启 CF 优选反代,并登记路由改写 —— 之后这条线生效时,
/// `active_line_url()` 返回本地反代基址,Emby API / 封面图 / mpv 取流全部改走优选 IP。
/// 已开则热切换 IP(端口与本地基址不变,对进行中的会话无感)。
///
/// ★ 粒度是线路不是服务器(2026-08-01 改)。理由详见 net::cf::runtime 顶部那段。
#[tauri::command]
async fn cf_proxy_enable(
    state: State<'_, AppState>,
    line_url: String,
    ip: String,
) -> Result<String, String> {
    let key = norm_line(&line_url);
    // 已开 → 只热切 IP。注意别在持锁期间 await。
    let existing = {
        let m = state.cf_proxy.lock().unwrap();
        m.get(&key).map(|h| h.port)
    };
    if existing.is_some() {
        let handle = state.cf_proxy.lock().unwrap().remove(&key);
        if let Some(h) = handle {
            h.update_ip(ip).await;
            let url = cf::runtime::local_url_for(&key).unwrap_or_default();
            state.cf_proxy.lock().unwrap().insert(key, h);
            return Ok(url);
        }
    }

    let server_id = server_of_line(&state, &key).ok_or("找不到这条线路所属的服务器")?;
    let allow_insecure = {
        let cfg = state.config.lock().unwrap();
        cfg.find(&server_id).map(|a| a.allow_insecure_tls).unwrap_or(false)
    };
    // 上游就是这条线路的原始地址 —— 绝不能用 active_line_url,反代已开时会把反代自己
    // 当上游,打成 127.0.0.1 → 127.0.0.1 的自环。
    let (scheme, host, port) = cf::runtime::split_upstream(&key);
    let handle = linplayer_core::net::cf::start_proxy(scheme, host, port, ip, allow_insecure)
        .await
        .ok_or("CF 反代起服失败(IP 非法?)")?;
    let local = cf::runtime::local_base(&key, handle.port);
    cf::runtime::bind(&key, &local);
    state.cf_proxy.lock().unwrap().insert(key, handle);
    refresh_session_base(&state, &server_id);
    Ok(local)
}

/// 关掉**这条线路**的反代,撤销路由改写,恢复直连。
#[tauri::command]
fn cf_proxy_disable(state: State<'_, AppState>, line_url: String) -> Result<(), String> {
    let key = norm_line(&line_url);
    cf::runtime::unbind(&key);
    state.cf_proxy.lock().unwrap().remove(&key); // Drop 停服
    if let Some(server_id) = server_of_line(&state, &key) {
        refresh_session_base(&state, &server_id);
    }
    Ok(())
}

/// 当前所有生效的反代改写(设置页展示"哪条线路在走优选、钉的哪个 IP")。
#[tauri::command]
async fn cf_proxy_status(state: State<'_, AppState>) -> Result<Vec<CfProxyStatus>, String> {
    let routes: Vec<(String, String)> = cf::runtime::all().into_iter().collect();
    let mut out = Vec::new();
    for (line_url, local_url) in routes {
        // pinned_ip 要 await,不能在持锁时取;先把句柄摘出来问完再放回。
        let handle = state.cf_proxy.lock().unwrap().remove(&line_url);
        let pinned_ip = match handle {
            Some(h) => {
                let ip = h.pinned_ip().await;
                state.cf_proxy.lock().unwrap().insert(line_url.clone(), h);
                ip
            }
            None => String::new(),
        };
        let (server_id, line_name) = {
            let cfg = state.config.lock().unwrap();
            let want = norm_line(&line_url);
            cfg.accounts
                .iter()
                .find_map(|a| {
                    if norm_line(&a.server) == want && a.lines.is_empty() {
                        return Some((a.server.clone(), "主线".to_string()));
                    }
                    a.lines
                        .iter()
                        .find(|l| norm_line(&l.url) == want)
                        .map(|l| (a.server.clone(), l.name.clone()))
                })
                .unwrap_or_default()
        };
        out.push(CfProxyStatus { line_url, server_id, line_name, local_url, pinned_ip });
    }
    Ok(out)
}

#[tauri::command]
fn get_prefetch_settings(state: State<'_, AppState>) -> PrefetchSettings {
    let p = &state.config.lock().unwrap().prefs;
    PrefetchSettings {
        servers: p.prefetch_servers.clone(),
        threads: p.prefetch_threads,
        // 钳回合法区间再给前端:老配置可能存着 16/32MB 这类小值或离谱值,
        // 原样透出去会让设置页一保存就被拒,连开关服务器都点不动。
        cache_bytes: p.prefetch_cache_bytes.clamp(
            linplayer_core::config::PREFETCH_CACHE_MIN,
            linplayer_core::config::PREFETCH_CACHE_MAX,
        ),
    }
}

#[tauri::command]
fn set_prefetch_settings(
    state: State<'_, AppState>,
    settings: PrefetchSettings,
) -> Result<(), String> {
    // 引擎会 clamp(2,4),但在这儿拒掉才有反馈 —— 悄悄 clamp 会让用户以为设了 8 线程生效了。
    if !(2..=4).contains(&settings.threads) {
        return Err("预取线程数只支持 2~4".into());
    }
    // 上下限都得拒:上限静默夹紧的话,用户设 8GB 实际只生效 4GB,毫无反馈。
    // 区间由来见 net/prefetch.rs 的 DiskCache —— 它现在是**磁盘**占用上限(环形复用),
    // 不再是每连接内存缓冲,所以敢给到 GB 级。
    if !(linplayer_core::config::PREFETCH_CACHE_MIN..=linplayer_core::config::PREFETCH_CACHE_MAX)
        .contains(&settings.cache_bytes)
    {
        return Err("缓存上限只支持 64MB~4GB(落盘环形缓存,决定磁盘占用)".into());
    }
    let mut cfg = state.config.lock().unwrap();
    // 只留真实存在的账号:服务器删了它的 id 还赖在表里,下次加同地址的服会「自己就开着」。
    let known: Vec<String> = cfg.accounts.iter().map(|a| a.server.clone()).collect();
    cfg.prefs.prefetch_servers = settings
        .servers
        .into_iter()
        .filter(|s| known.contains(s))
        .collect();
    cfg.prefs.prefetch_threads = settings.threads;
    cfg.prefs.prefetch_cache_bytes = settings.cache_bytes;
    cfg.save();
    Ok(())
}

#[tauri::command]
async fn chapter_info(
    state: State<'_, AppState>,
    item_id: String,
    runtime_secs: f64,
) -> Result<ChapterInfo, String> {
    let s = session_of(&state)?;
    let (skip_intro, skip_outro, thumbs) = {
        let p = &state.config.lock().unwrap().prefs;
        (p.skip_intro, p.skip_outro, p.preview_thumbs)
    };
    // 三个开关都关 = 不用打服务器。省一次请求,也省得白拉几十张章节图。
    if !skip_intro && !skip_outro && !thumbs {
        return Ok(ChapterInfo { chapters: Vec::new(), intro: None, outro: None, thumbs: false });
    }
    let chapters = linplayer_core::emby::chapters(&state.http, &s, &item_id, 320).await;
    let intro = skip_intro
        .then(|| linplayer_core::emby::intro_range(&chapters, runtime_secs))
        .flatten();
    let outro = skip_outro
        .then(|| linplayer_core::emby::outro_range(&chapters, runtime_secs))
        .flatten();
    poclog(&format!(
        "chapters item={item_id} n={} intro={intro:?} outro={outro:?}",
        chapters.len()
    ));
    Ok(ChapterInfo {
        chapters: if thumbs { chapters } else { Vec::new() },
        intro,
        outro,
        thumbs,
    })
}

/// 外部播放器起播。前端在进播放页**之前**调:返回 Ok 就别再进内置播放器了。
///
/// 为什么单独一个命令而不是塞进 play():play() 的返回值是「起播秒数」,
/// 全前端都按这个契约用。硬塞一个「其实没在本机播」的语义进去,调用点迟早判漏。
#[tauri::command]
async fn play_external(
    state: State<'_, AppState>,
    item_id: String,
    resume_secs: f64,
    media_source_id: Option<String>,
) -> Result<String, String> {
    let exe = state.config.lock().unwrap().prefs.external_player.clone();
    if exe.is_empty() {
        return Err("未设置外部播放器".into());
    }
    if !std::path::Path::new(&exe).is_file() {
        return Err(format!("外部播放器不存在: {exe}"));
    }
    let s = session_of(&state)?;
    let version_regex = state.config.lock().unwrap().prefs.version_regex.clone();
    let target =
        emby::resolve_stream(&state.http, &s, &item_id, media_source_id.as_deref(), &version_regex)
            .await?;
    // mpv 系通吃 --start=;不是 mpv 的播放器会忽略未知参数或直接报错,
    // 所以进度参数只在文件名像 mpv 时才给 —— 给错参数导致压根打不开,比不续播糟得多。
    let is_mpv = std::path::Path::new(&exe)
        .file_stem()
        .and_then(|x| x.to_str())
        .is_some_and(|x| x.to_ascii_lowercase().contains("mpv"));
    let mut cmd = std::process::Command::new(&exe);
    if is_mpv && resume_secs > 1.0 {
        cmd.arg(format!("--start={resume_secs}"));
    }
    cmd.arg(&target.url);
    cmd.spawn().map_err(|e| format!("启动外部播放器失败: {e}"))?;
    poclog(&format!("外部播放器 {exe} <- {}", target.url));
    // 上报 start:交给外部播放器后我们收不到进度了,但至少让服务器知道这次播放发生过。
    if let Err(e) = emby::report_start(&state.http, &s, &target, resume_secs).await {
        poclog(&format!("report_start(外部) ERR: {e}"));
    }
    Ok(exe)
}

/// Scrobble 一次(start/pause/stop);ids 如 {"imdb":"tt..","tmdb":123}。未连接返回 false。
#[tauri::command]
async fn trakt_scrobble(
    state: State<'_, AppState>,
    type_: String,
    ids: serde_json::Value,
    progress: f64,
    action: String,
) -> Result<bool, String> {
    let acc = state.config.lock().unwrap().sync_trakt.clone();
    let Some(acc) = acc else { return Ok(false) };
    let item = serde_json::json!({ type_: { "ids": ids } });
    Ok(trakt::scrobble(&acc, &item, progress, &action).await)
}

/// 设置条目收藏(type:1想看2看过3在看4搁置5抛弃)。更新单集前须先收藏。
#[tauri::command]
async fn bangumi_set_collection(
    state: State<'_, AppState>,
    subject_id: i64,
    type_: i32,
) -> Result<bool, String> {
    let acc = state.config.lock().unwrap().sync_bangumi.clone();
    let Some(acc) = acc else { return Ok(false) };
    match bangumi::set_collection_type(&acc, subject_id, type_).await {
        Ok(()) => Ok(true),
        Err(e) => {
            log::warn!("[Bangumi] 设置收藏失败: {e}");
            Ok(false)
        }
    }
}

/// 更新单集观看状态(type:2看过)。
#[tauri::command]
async fn bangumi_update_episode(
    state: State<'_, AppState>,
    subject_id: i64,
    episode_id: i64,
    type_: Option<i32>,
) -> Result<bool, String> {
    let acc = state.config.lock().unwrap().sync_bangumi.clone();
    let Some(acc) = acc else { return Ok(false) };
    match bangumi::update_episode_status(&acc, subject_id, episode_id, type_.unwrap_or(2)).await {
        Ok(()) => Ok(true),
        Err(e) => {
            log::warn!("[Bangumi] 更新单集失败: {e}");
            Ok(false)
        }
    }
}

/// 单部番的简介(Bangumi)。**按需**拉,聚焦视图只对当前那条调。
///
/// 为什么不在 bangumi_calendar 里一次带回:`/calendar` 的 summary 字段实测整周全空
/// (2026-07-16),真简介只在 /v0/subjects/{id} —— 一周 111 部 = 111 次请求,
/// 压在放送表加载路径上会把整页拖到几秒。核层带进程内缓存,滚回来是瞬时的。
/// 取不到返回 None:**前端就别画简介**,不要编。
#[tauri::command]
async fn bangumi_summary(subject_id: i64) -> Result<Option<String>, String> {
    Ok(bangumi::fetch_subject_summary(subject_id).await)
}

// ---------- 配置迁移(扫码搬服务器)命令 ----------
/// 导出当前所有账号为二维码载荷字符串(LPSYNC1:...);前端渲染成二维码,他机扫码导入。
/// 全程离线,载荷内账号凭据 AES 加密 + gzip。
#[tauri::command]
fn config_export_qr(state: State<'_, AppState>) -> String {
    let accounts = state.config.lock().unwrap().accounts.clone();
    let now = std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map(|d| d.as_secs())
        .unwrap_or(0);
    linplayer_core::config_transfer::encode(&accounts, now)
}

/// 导入扫到的载荷:解码 → 按 server 合并进现有账号 → 落盘。返回导入的账号数。
#[tauri::command]
fn config_import_qr(state: State<'_, AppState>, payload: String) -> Result<usize, String> {
    let incoming = linplayer_core::config_transfer::decode(&payload)?;
    let count = incoming.len();
    let mut cfg = state.config.lock().unwrap();
    let merged = linplayer_core::config_transfer::merge(&cfg.accounts, incoming);
    cfg.accounts = merged;
    if cfg.active.is_none() && !cfg.accounts.is_empty() {
        cfg.active = Some(0);
    }
    cfg.save();
    Ok(count)
}

// ---------- 付费(爱发电)命令 ----------
/// 校验爱发电订单号(经已部署的 CF 代理,客户端不接触 afdian token)。软锁。
#[tauri::command]
async fn afdian_verify(
    order_no: String,
) -> Result<linplayer_core::sync::AfdianVerifyResult, String> {
    Ok(linplayer_core::sync::afdian_verify(&order_no).await)
}

/// 赞助下单页地址。
///
/// ★ 前端**不许自己写这个 URL**。2026-07-19 踩过:核层早有正确的
/// `AFDIAN_SPONSOR_URL`,CalendarPage.tsx 却自己硬编了一个 `afdian.com/a/linplayer`
/// —— 页面不是作者本人的,点「前往爱发电赞助」的人全被送错地方,赞助收益直接落空,
/// 而功能本身看起来一切正常。付款地址这种东西必须只有一份。
#[tauri::command]
fn afdian_sponsor_url() -> String {
    linplayer_core::sync::AFDIAN_SPONSOR_URL.to_string()
}

// ---------- 插件命令 ----------
#[tauri::command]
fn plugin_list(state: State<'_, AppState>) -> Result<Vec<serde_json::Value>, String> {
    Ok(plugins_mgr(&state)?.list())
}

#[tauri::command]
fn plugin_install(state: State<'_, AppState>, path: String) -> Result<serde_json::Value, String> {
    plugins_mgr(&state)?.install_ipk(&path)
}

#[tauri::command]
async fn plugin_enable(state: State<'_, AppState>, id: String) -> Result<(), String> {
    plugins_mgr(&state)?.enable(&id).await
}

#[tauri::command]
async fn plugin_disable(state: State<'_, AppState>, id: String) -> Result<(), String> {
    plugins_mgr(&state)?.disable(&id).await;
    Ok(())
}

#[tauri::command]
async fn plugin_uninstall(state: State<'_, AppState>, id: String) -> Result<(), String> {
    plugins_mgr(&state)?.uninstall(&id).await;
    Ok(())
}

/// 触发某扩展的 handler(actions/settingsPages 的入口按钮等)。
#[tauri::command]
async fn plugin_trigger(
    state: State<'_, AppState>,
    plugin_id: String,
    type_id: String,
    ext_id: String,
    args: Option<serde_json::Value>,
) -> Result<serde_json::Value, String> {
    let args = args.unwrap_or_else(|| serde_json::json!([]));
    plugins_mgr(&state)?.trigger_extension(&plugin_id, &type_id, &ext_id, args).await
}

/// 触发扩展 data 里某具名字段的 handler(设置页的 load/submit)。
#[tauri::command]
async fn plugin_invoke_field(
    state: State<'_, AppState>,
    plugin_id: String,
    type_id: String,
    ext_id: String,
    field: String,
    args: Option<serde_json::Value>,
) -> Result<serde_json::Value, String> {
    let args = args.unwrap_or_else(|| serde_json::json!([]));
    plugins_mgr(&state)?
        .invoke_extension_field(&plugin_id, &type_id, &ext_id, &field, args)
        .await
}

/// 取某类贡献点全部条目(dataSources / panels / actions / sandboxViews)。
#[tauri::command]
fn plugin_extensions(state: State<'_, AppState>, type_id: String) -> Result<Vec<serde_json::Value>, String> {
    Ok(plugins_mgr(&state)?.extensions_by_type(&type_id))
}

/// 取挂在某个 slot 的全部面板。首页/侧栏/播放器叠加层各自只关心自己那一撮,
/// 让前端拉全量再过滤等于每个位置都要重复一遍 slot 常量。
#[tauri::command]
fn plugin_panels(state: State<'_, AppState>, slot: String) -> Result<Vec<serde_json::Value>, String> {
    Ok(plugins_mgr(&state)?.panels_in_slot(&slot))
}

/// 当前所有已启用插件贡献的数据源。「添加服务器」页据此列出可选的插件源。
#[tauri::command]
fn plugin_sources(state: State<'_, AppState>) -> Result<Vec<serde_json::Value>, String> {
    let mgr = plugins_mgr(&state)?;
    // 把 manifest 里声明的 auth 表单字段一并带上 —— 前端要靠它渲染通用登录表单,
    // 否则每接一个插件源都得改前端。
    let decls = mgr.extensions_by_type(linplayer_core::plugins::ContributionKind::DataSources.id());
    Ok(mgr
        .data_sources()
        .into_iter()
        .map(|(plugin_id, src_id, name)| {
            let auth = decls
                .iter()
                .find(|d| d["pluginId"] == plugin_id.as_str() && d["id"] == src_id.as_str())
                .and_then(|d| d["data"].get("auth").cloned());
            serde_json::json!({
                "kind": linplayer_core::source::SourceKind::plugin(&plugin_id, &src_id).as_str(),
                "pluginId": plugin_id,
                "sourceId": src_id,
                "name": name,
                "auth": auth,
            })
        })
        .collect())
}



/// 重载一个插件(禁用 -> 重读 manifest -> 重新启用)。
#[tauri::command]
async fn plugin_reload(state: State<'_, AppState>, id: String) -> Result<(), String> {
    plugins_mgr(&state)?.reload(&id).await
}

/// 轮询开发模式插件的入口文件是否变了,变了的自动重载,返回被重载的 id。
///
/// `ponytail:` 轮询 mtime 而不是上 `notify` crate —— 零新依赖,开发模式插件通常
/// 就一两个。真嫌慢再换 notify。前端在插件页开着时每秒调一次。
#[tauri::command]
async fn plugin_dev_poll(state: State<'_, AppState>) -> Result<Vec<String>, String> {
    let mgr = plugins_mgr(&state)?;
    let changed = mgr.dev_plugins_changed();
    for id in &changed {
        let _ = mgr.reload(id).await;
    }
    Ok(changed)
}

/// 前端回填一次 ctx.ui 请求(showForm 的返回值等)。value=null 视为取消。
#[tauri::command]
fn plugin_ui_respond(state: State<'_, AppState>, id: u64, value: Option<serde_json::Value>) {
    plugins_host::ui_respond(&state, id, value.unwrap_or(serde_json::Value::Null));
}

#[cfg_attr(mobile, tauri::mobile_entry_point)]
pub fn run() {
    let builder = pluginassets::register(imgcache::register(tauri::Builder::default()));
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
            /* ★ Ani-RSS 建一次、存两处:管理接口(listAni/config/…)不在 MediaSourceBackend
                  trait 上,trait object 取不到,所以 AppState 另存一份具体类型的 Arc。
                  **必须是同一个 Arc**(clone 后 unsize 成 dyn),否则浏览时重登拿到的 token
                  和管理接口用的是两套缓存,表现是"刚登录过,管理页还说未登录"。与桌面同构。 */
            let anirss_backend = Arc::new(AniRssBackend::new());
            source_backends.insert(SourceKind::anirss(), anirss_backend.clone());
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
                // ---- 2026-07-26 手机端接入补齐,与 apps/desktop 的初始化逐字对应 ----
                anirss: anirss_backend,
                source_play_entry: Mutex::new(None),
                resign_count: AtomicU32::new(0),
                cf_proxy: Mutex::new(HashMap::new()),
                watch_history: linplayer_core::watch_history::WatchHistory::default(),
                series_tmdb: Mutex::new(HashMap::new()),
                        danmaku_anchors: Mutex::new(HashMap::new()),
                wh_done: Mutex::new(Default::default()),
                wh_ctx: Mutex::new(None),
                plugins: OnceLock::new(),
                ui_pending: Mutex::new(HashMap::new()),
                ui_seq: AtomicU64::new(0),
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
            /* 插件系统:host 持 AppHandle 落平台能力。
               基目录和其它数据一起进 data/plugins(**不用 app_config_dir()** —— 那是由
               tauri.conf.json 的 identifier 推出来的,改 identifier 就让已装插件静默失联)。 */
            let base = linplayer_core::paths::data_dir("plugins");
            let host = plugins_host::make_host(app.handle().clone());
            let mgr = PluginManager::new(base, host);
            let _ = app.state::<AppState>().plugins.set(mgr.clone());
            sync_plugin_source_grants(&app.state::<AppState>());
            tauri::async_runtime::spawn(async move { mgr.init().await });
            Ok(())
        })
        .invoke_handler(tauri::generate_handler![
            // --- Emby 浏览 ---
            login,
            current_session,
            aggregate_search,
            aggregate_overview,
            screenshot,
            set_active_server,
            views,
            list_items_page,
            get_filters,
            set_played,
            list_next_up,
            search,
            similar_items,
            person_detail,
            person_items,
            list_latest,
            list_resume,
            list_random,
            item_detail,
            series_seasons,
            season_episodes,
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
            source_categories,
            source_catalog,
            source_media_detail,
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
        
            // ---- 2026-07-26 手机端接入补齐(实现体见本文件「从 apps/desktop 搬过来」那一节)----
            relogin,
            list_items,
            test_connection,
            list_collections,
            icon_library,
            is_admin,
            refresh_item,
            scan_libraries,
            update_account,
            startup_deep_link,
            set_account_icon_file,
            clear_account_icon,
            batch_parse,
            parse_deep_link,
            batch_add_servers,
            probe_lines,
            current_source,
            player_opts,
            set_speed,
            set_volume,
            set_mute,
            set_audio_delay,
            set_sub_delay,
            set_aspect_ratio,
            set_hwdec,
            set_sub_style,
            set_secondary_sub,
            set_secondary_sub_opts,
            add_subtitle,
            shader_levels,
            set_shader_level,
            mpv_get,
            mpv_set,
            mpv_command,
            apply_prefs,
            validate_track_regex,
            set_track_regexes,
            source_watchdog,
            quark_scan_start,
            quark_scan_poll,
            anirss_list_ani,
            anirss_play_list,
            anirss_get_themoviedb_group,
            anirss_torrents_infos,
            anirss_search_bgm,
            anirss_get_ani_by_subject_id,
            anirss_add_ani,
            anirss_set_ani,
            anirss_delete_ani,
            anirss_refresh_ani,
            anirss_refresh_all,
            anirss_update_total_episode_number,
            anirss_batch_enable,
            anirss_get_config,
            anirss_set_config,
            anirss_about,
            anirss_preview_ani,
            anirss_preview_items,
            anirss_download_path,
            anirss_get_bgm_title,
            anirss_get_themoviedb_name,
            anirss_refresh_cover,
            anirss_scrape,
            anirss_batch_scrape,
            anirss_rate,
            anirss_set_rate,
            anirss_me_bgm,
            anirss_mikan,
            anirss_mikan_group,
            anirss_ani_bt,
            anirss_ani_bt_group,
            anirss_anime_garden_list,
            anirss_anime_garden_group,
            anirss_rss_to_ani,
            anirss_get_subtitles,
            anirss_logs,
            anirss_download_logs,
            anirss_clear_logs,
            anirss_clear_cache,
            anirss_ping,
            anirss_download_login_test,
            anirss_test_proxy,
            anirss_test_ip_whitelist,
            anirss_server_update,
            anirss_stop,
            anirss_new_notification,
            anirss_get_emby_views,
            anirss_export_config_url,
            anirss_import_config,
            anirss_proxy_image_url,
            anirss_clear_token,
            get_danmaku_config,
            get_official_danmaku,
            set_danmaku_config,
            danmaku_search,
            danmaku_episodes,
            danmaku_load,
            danmaku_match,
            danmaku_min_auto_score,
            danmaku_filter,
            danmaku_import_blocklist,
            danmaku_cache_clear,
            danmaku_cache_size,
            danmaku_load_local,
            danmaku_auto_load,
            cf_speed_test,
            cf_proxy_enable,
            cf_proxy_disable,
            cf_proxy_status,
            get_prefetch_settings,
            set_prefetch_settings,
            chapter_info,
            play_external,
            watch_history_list,
            blocked_list,
            set_blocked,
            watch_history_scan_restore,
            watch_history_restore_candidate,
            get_writeback_settings,
            set_writeback_settings,
            watch_history_clear,
            watch_history_delete,
            afdian_verify,
            afdian_sponsor_url,
            trakt_scrobble,
            bangumi_set_collection,
            bangumi_update_episode,
            bangumi_summary,
            config_export_qr,
            config_import_qr,
            plugin_list,
            plugin_install,
            plugin_enable,
            plugin_disable,
            plugin_uninstall,
            plugin_trigger,
            plugin_invoke_field,
            plugin_ui_respond,
            plugin_extensions,
            plugin_panels,
            plugin_sources,
            plugin_reload,
            plugin_dev_poll,
            plugin_permission_catalog,
            plugin_market_sources,
            plugin_market_add_source,
            plugin_market_remove_source,
            plugin_market_toggle_source,
            plugin_market_list,
            plugin_market_install,
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
        let cases: [(&str, &str, &str); 8] = [
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
            /* ★ API 31+ 的两份是**整条替换**不是叠加,windowBackground 必须各写一遍。
               而且限定符优先级里 -night 排在 -vXX 前面,所以「深色 + Android 12 以上」
               命中的是 values-night-v31 —— 那一份漏了就是安卓 12 以上深色模式黑屏。 */
            (
                "Activity 窗口(浅色 / API31+)",
                include_str!("../gen/android/app/src/main/res/values-v31/themes.xml"),
                "@android:color/transparent",
            ),
            (
                "Activity 窗口(深色 / API31+)",
                include_str!("../gen/android/app/src/main/res/values-night-v31/themes.xml"),
                "@android:color/transparent",
            ),
            /* ★ 手机端的页面栈容器 `.pg` 自己写着 `background: var(--bg)` ——
               一块不透明的底,正正盖在 SurfaceView 上。html/body 清干净了也没用。
               2026-08-02 用户报的「播放页只有声音没有画面」就是这一层,
               而上一版这个测试只看 tv.css,手机端整条链一个字都没检。 */
            (
                "前端渲染链(手机端页面栈)",
                include_str!("../../../ui/mobile/theme/mobile.css"),
                "html.playing .pg,",
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
                "前端渲染链(TV)",
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

    /// 四份主题文件的开屏配置必须一致。
    ///
    /// ★ 挡的是 2026-08-02 那个「点开软件先看见一个被放大的图标」:
    ///   安卓的资源限定符优先级里 **-night 排在 -vXX 前面**,所以
    ///   「Android 12 以上 + 系统深色模式」命中的是 `values-night-v31`。
    ///   2026-08-01 只建了 `values-v31`,于是这条修复对**默认深色的手机一台都没生效**,
    ///   而浅色模式下一切正常 —— 最典型的"我这儿是好的"。
    ///   开屏配置本身是 API 31+ 才有的属性,所以只校验带 v31 的那两份。
    /// 反向验证:删掉 `values-night-v31/themes.xml` 里任意一行 → 本测试立刻红。
    #[test]
    fn splash_config_covers_both_ui_modes() {
        /* ★ 连 `<item name="android:` 一起匹配,**不能只搜属性名** ——
           这两个文件里的长注释本身就把三个属性名逐个写了一遍,
           光搜名字的话把 `<item>` 整行删掉测试照样绿。
           (第一次写这条测试就是这么假绿的,反向注入才照出来。) */
        let keys = [
            "<item name=\"android:windowSplashScreenBackground\">",
            "<item name=\"android:windowSplashScreenAnimatedIcon\">",
            "<item name=\"android:windowSplashScreenAnimationDuration\">",
        ];
        let files = [
            (
                "values-v31(浅色)",
                include_str!("../gen/android/app/src/main/res/values-v31/themes.xml"),
            ),
            (
                "values-night-v31(深色)",
                include_str!("../gen/android/app/src/main/res/values-night-v31/themes.xml"),
            ),
        ];
        for (name, src) in files {
            for k in keys {
                assert!(
                    src.contains(k),
                    "{name} 缺 {k}。少了它,那个 UI 模式下开屏会回落到系统默认 —— \
                     图标被放大铺满图标槽、底色跟着透明的 windowBackground 走,\
                     和随后的 #boot 交接时看得见一次跳变。"
                );
            }
            assert!(
                src.contains("#0e0e13"),
                "{name} 的开屏底色必须和 index-mobile.html 的 #boot、mobile.css 的 --bg \
                 逐位一致,差一个灰阶在 OLED 上就是一记暗闪。"
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

    /* ★ 官方弹幕配额的护栏,与桌面端 `auto_match_actually_gates_the_official_danmaku_source`
       同款、同理由(核层 `is_anime` 写了却从没被任何宿主调用过,非动漫内容照样烧配额)。
       两端**各钉一份**:合并成一条的话删掉其中一端的调用不会红。
       反向验证:把 allow_official_for 改回 true,本测试立刻红。 */
    #[test]
    fn auto_match_actually_gates_the_official_danmaku_source() {
        let me = include_str!("lib.rs");
        let auto = me
            .split_once("async fn danmaku_auto_load(")
            .expect("找不到 danmaku_auto_load")
            .1;
        let body = &auto[..auto.len().min(2000)];
        assert!(
            body.contains("danmaku::allow_official_for(&input.genres)"),
            "danmaku_auto_load 必须用 allow_official_for 判官方源参不参与"
        );
        assert!(
            !body.contains("require_danmaku_sources(&state)"),
            "别退回无条件取全部源(那个函数恒带官方源)"
        );
    }

    /// 手机前端 `ui/mobile` 会调的命令,一个都不能漏注册 —— 与 TV 那条同形态,
    /// 但**清单分开两份**:合并了就分不清某条命令是谁要的,砍 TV 功能时会误伤手机端。
    ///
    /// 清单 `mobile-commands.txt` 是从 `ui/mobile/**` 对 `@shared/api` 的真实 import
    /// 反推出来的(含 `ui/desktop/pages/sources/sourceForms` —— 手机端的登录/添加源
    /// 复用的就是那一份表单)。加页面/加调用后重新生成一次。
    ///
    /// 反向验证:把 generate_handler! 里任意一条手机端要用的命令注释掉 → 本测试立刻红。
    #[test]
    fn every_mobile_invoke_names_a_registered_command() {
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

        let api_ts = include_str!("../../../ui/shared/api.ts");
        let cmds = include_str!("../mobile-commands.txt");
        let mut n = 0;
        for cmd in cmds.lines().map(str::trim).filter(|l| !l.is_empty()) {
            n += 1;
            assert!(
                registered.contains(&cmd),
                "手机端命令清单里的 `{cmd}` 没在 generate_handler! 注册 ——                  用户走到那个页面就报 command not found(而且编译期一声不吭)"
            );
            assert!(
                api_ts.contains(&format!("\"{cmd}\"")),
                "`{cmd}` 在手机端清单里,但 ui/shared/api.ts 里找不到它 ——                  清单和前端漂移了,先查是不是命令改名了"
            );
        }
        assert!(n > 60, "手机端清单只有 {n} 条,多半是文件读岔了");
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
