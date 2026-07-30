mod imgcache;
mod pluginassets;
mod pluginmarket;
/* 命令必须用**裸名字**注册进 generate_handler! —— 写成 `pluginmarket::xxx` 虽然 Tauri
   也认,但 api_contract_tests 那道守门测试只按裸标识符比对,路径形式会被它当成
   「没注册」。宁可它误报,也不能让它漏报。 */
use pluginmarket::*;
use linplayer_mpv as mpv; // 提成共享 crate(crates/mpv):安卓壳也要用同一份
mod plugins_host;
mod shaders;
mod telemetry;
mod updater;

/* 双显卡笔记本切独显。NVIDIA Optimus / AMD Enduro 在**加载进程时**读主 exe 导出表里的
   这两个符号,非 0 = 「这个程序要用独显」。配套的 /EXPORT 在 build.rs(Rust exe 默认
   没有导出表,少了那半这里就是白写,且**不报错、继续用核显**)。
   为什么要它:见 [[hybrid-gpu-must-pin-dgpu]] —— 用户真机 mpv 一直跑在 Intel UHD 上,
   5060 全程没参与,超分自然「非常非常卡」。
   #[used] 不能少:静态量没人读,LTO 会把它整个丢掉,导出表里就空了。 */
#[cfg(windows)]
#[used]
#[no_mangle]
pub static NvOptimusEnablement: u32 = 0x0000_0001;
#[cfg(windows)]
#[used]
#[no_mangle]
pub static AmdPowerXpressRequestHighPerformance: u32 = 0x0000_0001;

use linplayer_core::config::{Account, AppConfig, DanmakuServer, Prefs};
use linplayer_core::plugins::PluginManager;
use linplayer_core::danmaku::{self, DanmakuAuthType, DanmakuComment, DanmakuSourceConfig};
use linplayer_core::emby::{self, Item, LoginResult, PlaybackTarget, Session};
use linplayer_core::http;
use linplayer_core::media::{pick_tracks, Track, TrackPrefs};
use linplayer_core::net::cf;
use linplayer_core::source::aliyundrive::{self, AliyunDriveBackend};
use linplayer_core::source::anirss::AniRssBackend;
use linplayer_core::source::baidu::{self, BaiduBackend};
use linplayer_core::source::feiniu::FeiniuBackend;
use linplayer_core::source::openlist::OpenListBackend;
use linplayer_core::source::pan115::Pan115Backend;
use linplayer_core::source::pan139::{self, Pan139Backend};
use linplayer_core::source::pan189::{self, Pan189Backend};
use linplayer_core::source::quark::QuarkBackend;
use linplayer_core::source::quark_tv;
use linplayer_core::source::stremio::StremioBackend;
use linplayer_core::source::plugin_source::PluginSourceBackend;
use linplayer_core::source::{
    MediaSourceBackend, QrPoll, QrStart, SourceEntry, SourceKind, SourceServer,
};
use mpv::{Player, Status};
use raw_window_handle::{HasWindowHandle, RawWindowHandle};
use std::collections::HashMap;
use std::sync::atomic::{AtomicU32, AtomicU64, Ordering};
use std::sync::{Arc, Mutex, OnceLock};
use tauri::{Manager, State, WindowEvent};
use tokio::sync::oneshot;

struct AppState {
    http: reqwest::Client,
    config: Mutex<AppConfig>,
    session: Mutex<Option<Session>>,
    player: Mutex<Option<Player>>,
    playback: Mutex<Option<PlaybackTarget>>, // 当前播放会话(上报三件套共享)
    // 文件浏览型源:后端注册表(长驻,持 token 缓存)+ 当前活跃源
    source_backends: HashMap<SourceKind, Arc<dyn MediaSourceBackend>>,
    source: Mutex<Option<(SourceKind, SourceServer)>>,
    // Ani-RSS 管理接口(listAni/config/…)不在 MediaSourceBackend trait 上,trait object 取不到,
    // 故另存具体类型。**与 source_backends[Anirss] 是同一个 Arc**(建时 clone 后 unsize 成 dyn),
    // 两边共享同一份 token_cache —— 浏览重登拿到的 token 管理接口直接复用,不会分裂成两套。
    anirss: Arc<AniRssBackend>,
    // 当前正在播放的源条目(entry_id, entry_name),供 302 重签重解析;None=非源播放
    source_play_entry: Mutex<Option<(String, String)>>,
    // 连续 302 重签次数(防死循环:文件本身放不了时不无限重签),每次新播放清零
    resign_count: AtomicU32,
    // 多线程加载:本地预取代理句柄(仅 Emby 直传流);Drop 即停服。None=直连。
    prefetch: Mutex<Option<linplayer_core::net::prefetch::ProxyHandle>>,
    // CF 优选:server_id -> 本地钉 IP 反代句柄;移除即 Drop 停服。
    // 与 cf::runtime 的路由改写表一一对应(那边是纯改写,这边持句柄),开关必须两边同步。
    cf_proxy: Mutex<HashMap<String, linplayer_core::net::cf::CfProxyHandle>>,
    // 多线程下载管理器(长驻,持久化索引)。
    download: linplayer_core::download::DownloadManager,
    // 当前 Emby 播放的 Trakt scrobble 上下文(play 时抓取,stop 时用于收尾上报)。
    scrobble_ctx: Mutex<Option<emby::ScrobbleInfo>>,
    // 本地观看记录(跨服务器续播)。长驻,自持存盘。
    watch_history: linplayer_core::watch_history::WatchHistory,
    // 剧 -> TMDB id 缓存(跨服匹配剧集要它;每部剧只查一次)。对齐 Dart _seriesTmdbCache。
    series_tmdb: Mutex<HashMap<String, Option<String>>>,
    // server_id -> 连通状态三态。probe_accounts 刷新,list_accounts 读;不落盘(重启即重探)。
    account_status: Mutex<HashMap<String, AccountStatus>>,
    // 自动挂弹幕的连号锚点:seriesId|seasonId -> (集号, 弹弹Play episodeId)。
    // 只在内存(重启重新匹配一次即可,不值得落盘)。
    danmaku_anchors: Mutex<HashMap<String, (i64, i64)>>,
    // 实时预读翻译:轮询任务的停止信号。None=没开。
    live_translate: Mutex<Option<LiveTranslate>>,
    // 跨服回传去重集(对齐 Dart _done:一次播放会话内不重复回传同一目标)。play 时清空。
    wh_done: Mutex<std::collections::HashSet<String>>,
    // 当前播放条目的观看记录上下文(play 时装,progress/stop 时用)。
    wh_ctx: Mutex<Option<(String, linplayer_core::watch_history::Candidate, Option<String>)>>,
    // 插件管理器(setup 期建,持 AppHandle 的 host)。
    plugins: OnceLock<Arc<PluginManager>>,
    // 插件 ctx.ui 请求的待回表:id -> oneshot,前端 plugin_ui_respond 回填。
    ui_pending: Mutex<HashMap<u64, oneshot::Sender<serde_json::Value>>>,
    ui_seq: AtomicU64,
    // check_update 查到的待装版本。存在核层是为了让 download_and_apply 直接拿,
    // 不必让前端把资产清单原样传回来(那是白白多一次序列化,还容易被篡改)。
    pending_update: Mutex<Option<linplayer_core::update::UpdateInfo>>,
}

pub(crate) fn plugins_mgr(state: &AppState) -> Result<Arc<PluginManager>, String> {
    state.plugins.get().cloned().ok_or_else(|| "插件系统未就绪".to_string())
}

/// 把「用户已为每个插件配置的全部源地址」同步进各插件的 `$sourceServer` 展开表。
///
/// 不调这个,manifest 里写了 `$sourceServer` 的插件源会展开成空 = 一个请求都发不出去
/// (fail-closed)。**必须在每次账号变动后调**:登录、删除、导入配置、启动。
///
/// 整体替换而非追加 —— 用户删掉一个源之后那台机器必须立刻不再可达。
/// 在**已落盘账号的基础上**临时追加一条 `$sourceServer` 授权。
///
/// 给 `source_login` 的验证请求用:那一刻账号还没入库,只按 config 算的话新地址不在里面。
/// 非插件源直接跳过(它们的出网走宿主自己的 http 客户端,不受插件白名单管)。
fn grant_plugin_source_host(state: &AppState, kind: &SourceKind, base_url: &str) {
    let Some((plugin_id, _)) = kind.as_plugin() else { return };
    let Some(mgr) = state.plugins.get() else { return };
    let mut urls: Vec<String> = {
        let cfg = state.config.lock().unwrap();
        cfg.accounts
            .iter()
            .filter(|a| a.source_kind.as_plugin().map(|(p, _)| p == plugin_id).unwrap_or(false))
            .filter_map(|a| a.source.as_ref().map(|s| s.base_url.clone()))
            .collect()
    };
    if !base_url.trim().is_empty() && !urls.iter().any(|u| u == base_url) {
        urls.push(base_url.to_string());
    }
    mgr.set_source_grants(plugin_id, &urls);
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

/// 诊断日志。旧版直接往 %TEMP% 根丢 linplayer_poc.log —— 现在收进自己的 logs/。
fn app_log_path() -> std::path::PathBuf {
    linplayer_core::paths::logs_dir().join("app.log")
}

fn poclog(msg: &str) {
    use std::io::Write;
    let path = app_log_path();
    if let Ok(mut f) = std::fs::OpenOptions::new().create(true).append(true).open(path) {
        let _ = writeln!(f, "{msg}");
    }
}

/// 把 mpv 视频窗口对齐到 Tauri 窗口客户区(并压在它正下方)。
/// 主窗最小化/隐藏时 sync_overlay 会转而把视频窗藏起来。
fn sync_video(window: &tauri::WebviewWindow, parent: isize, state: &AppState) {
    let video = state.player.lock().unwrap().as_ref().map(|p| p.video_hwnd);
    if let Some(v) = video {
        if let (Ok(pos), Ok(size)) = (window.inner_position(), window.inner_size()) {
            mpv::sync_overlay(v, parent, pos.x, pos.y, size.width as i32, size.height as i32);
        }
    }
}

/* 视频窗的显隐。**不在播放时必须藏起来** —— 它是独立顶层窗口,一直可见的话:
   1) 平时被主窗盖着看不出来,主窗一最小化就是一个黑窗(或还在放的片)留在桌面;
   2) 主窗透明,视频窗那块黑会把 UI 的半透明效果整个压死。
   起播时开、停播/退播放页时关。 */
fn show_video(state: &AppState, on: bool) {
    if let Some(p) = state.player.lock().unwrap().as_ref() {
        mpv::set_overlay_visible(p.video_hwnd, on);
    }
}

/// 主窗口的原生句柄。mpv 的视频窗口要靠它做对齐和层叠的参照物(见 mpv::sync_overlay)。
///
/// Linux 只认 Xlib:整套合成方案要求「自己摆放顶层窗口」,而 **Wayland 协议上就不允许
/// 应用定位自己的顶层窗口** —— 所以 run() 里强制 `GDK_BACKEND=x11` 走 XWayland,
/// 正常情况下这里拿到的就是 Xlib 句柄。真落到 Wayland 分支只能如实报错,
/// 让它走和「拿不到句柄」一样的降级路径(App 能起,视频层不工作),而不是假装成功。
fn hwnd_of(window: &tauri::WebviewWindow) -> Result<isize, String> {
    let handle = window.window_handle().map_err(|e| e.to_string())?;
    match handle.as_raw() {
        RawWindowHandle::Win32(h) => Ok(h.hwnd.get()),
        #[cfg(target_os = "linux")]
        RawWindowHandle::Xlib(h) => Ok(h.window as isize),
        #[cfg(target_os = "linux")]
        RawWindowHandle::Wayland(_) => {
            Err("当前是 Wayland 原生会话(GDK_BACKEND=x11 没生效?),视频窗口无法定位".into())
        }
        _ => Err("不支持的窗口句柄类型".into()),
    }
}

fn session_of(state: &State<'_, AppState>) -> Result<Session, String> {
    state
        .session
        .lock()
        .unwrap()
        .clone()
        .ok_or_else(|| "未登录".to_string())
}

// ---------- Emby 命令 ----------
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
    // 持久化账号 -> 重启免登。upsert 会保住用户编辑过的名称/备注/线路,不会被重登冲掉。
    {
        let mut cfg = state.config.lock().unwrap();
        /* 服务器图标默认取登录用户的 Emby 头像(用户 2026-07-15)。
           ★ 只在**首次添加**时设:upsert 对已存在账号是 `acc.icon_url.or(old)`,
             传 Some 会盖掉用户自定义的图标 —— 重登不能把人家换过的图标冲回头像。
           ★ 只在**真有头像 tag** 时设:没头像就留空 icon_url,由 ServerGlyph 回落
             emby_default.png(不用 build_icon_url 的 /web/touchicon.png 兜底,那玩意常 404)。 */
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
            None // 已存在 → 传 None,upsert 保留旧图标
        };
        cfg.upsert(Account {
            server: result.server.clone(),
            token: result.token.clone(),
            user_id: result.user_id.clone(),
            user_name: result.user_name.clone(),
            icon_url,
            // 存密码供重新登录 + 插件 emby.credentials 权限(对齐旧 Dart ServerConfig.password)。
            password: (!password.is_empty()).then_some(password),
            ..Default::default()
        });
        cfg.save();
    }
    *state.session.lock().unwrap() = Some(session);
    *state.source.lock().unwrap() = None; // 登 Emby → 上一个源作废
    Ok(result)
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

/// 已登录的 Emby 账号(用于启动时跳过登录页直接进库);无则 None。
/// 活跃的是浏览型源时返回 None —— 它没有 Emby token,吐个空 token 的会话会让前端拿去打 401。
/// 前端判断"要不要进登录页"应看 `list_accounts` 是否为空,不是只看这个。
#[tauri::command]
fn current_session(state: State<'_, AppState>) -> Option<LoginResult> {
    state
        .config
        .lock()
        .unwrap()
        .active_account()
        .filter(|a| !a.is_file_browse())
        .map(|a| LoginResult {
            // 前端 api.ts 拿这个 server 直接拼封面/背景图地址,所以必须是**当前生效线路**
            // (经 CF 优选改写),不能是账号主键 a.server ——
            // 否则用户切到备用线路后 API 走新线、封面还打老线,表现为"封面全白但不报错"。
            server: a.active_line_url(),
            token: a.token.clone(),
            user_id: a.user_id.clone(),
            user_name: a.user_name.clone(),
            // 头像 tag 只在登录那一刻有意义(用来建服务器图标,已存进 Account.icon_url);
            // 恢复会话时没有也不需要重新取。
            primary_image_tag: None,
        })
}

/// 启动时的活跃源(浏览型)——前端据此决定落文件浏览页而不是媒体库。
#[tauri::command]
fn current_source(state: State<'_, AppState>) -> Option<AccountInfo> {
    let cfg = state.config.lock().unwrap();
    cfg.active_account().filter(|a| a.is_file_browse()).map(|a| account_info(a, true))
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
                // 必须走生效线路:用 a.server(账号主键)会让聚合搜索永远打主线路,
                // 用户切到备用线是因为主线路不通 —— 那台服务器会 unwrap_or_default() 成空结果
                // 从搜索里静默消失,查都没处查。
                server: a.active_line_url(),
                token: a.token.clone(),
                user_id: a.user_id.clone(),
                device_id,
            };
            /* 用户 2026-07-16:「跨服查找剧/电影、聚合搜索,都只出剧/电影的条目,不要出『集』
               这种条目 —— 这是不一样的」。emby::search 传 None 时默认 IncludeItemTypes=
               Movie,Series,Episode → 分集混进结果。这里显式收敛成 Movie,Series。
               跨服 SourcePicker 与聚合搜索共用本命令,一处收敛两处生效。 */
            let types = ["Movie".to_string(), "Series".to_string()];
            let items = emby::search(&http, &s, &query, Some(&types), None)
                .await
                .unwrap_or_default();
            /* ★ 这里曾拼成 `账户名 @ 地址`。用户 2026-07-15:「聚合搜索的时候
               只显示服务器名称 不显示账户名字和地址」——
               而且拼串这个做法本身就错:前端**拆不开**,想只显示一部分都做不到。
               现在传 display_name()(= 用户在服务器页起的名,空则回落 host),
               账户名/地址一个都不带。要加回去请**加字段**,别再往一个串里塞三样东西。 */
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

/// 切换活跃服务器(聚合搜索点播其它服条目前调用;也用于服务器页切换)。
/// Emby 装 session,浏览型源装 source —— 一张表两种形态,切换必须两边都对齐,
/// 否则会留着上一个服的会话在那儿(切服失败还打错服务器)。
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

#[tauri::command]
async fn list_items(state: State<'_, AppState>, parent_id: String) -> Result<Vec<Item>, String> {
    let s = session_of(&state)?;
    // 保持返回 Vec<Item>:现有前端 invoke<Item[]>("list_items", { parentId }) 直接 .map,
    // 改成 ItemPage 会在运行时炸(tsc 是泛型断言,拦不住)。要总数/翻页/筛选走 list_items_page。
    Ok(emby::items(&state.http, &s, &parent_id, &emby::ItemQuery::default())
        .await?
        .items)
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

/// 相似推荐(剧集/电影详情页底部)。空结果不是错误 —— 有些条目没有相似项,前端整段不渲染。
#[tauri::command]
async fn similar_items(state: State<'_, AppState>, item_id: String) -> Result<Vec<Item>, String> {
    let s = session_of(&state)?;
    emby::similar(&state.http, &s, &item_id, 12).await
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

/// 首页 Hero 随机推荐。
#[tauri::command]
async fn list_random(state: State<'_, AppState>, limit: u32) -> Result<Vec<Item>, String> {
    let s = session_of(&state)?;
    emby::random_picks(&state.http, &s, limit).await
}

/// 继续观看。
#[tauri::command]
async fn list_resume(state: State<'_, AppState>, limit: u32) -> Result<Vec<Item>, String> {
    let s = session_of(&state)?;
    emby::resume(&state.http, &s, limit).await
}

/// 收藏列表。
#[tauri::command]
async fn list_favorites(state: State<'_, AppState>) -> Result<Vec<Item>, String> {
    let s = session_of(&state)?;
    emby::favorites(&state.http, &s).await
}

/// 切换收藏。
#[tauri::command]
async fn set_favorite(
    state: State<'_, AppState>,
    item_id: String,
    fav: bool,
) -> Result<(), String> {
    let s = session_of(&state)?;
    emby::set_favorite(&state.http, &s, &item_id, fav).await
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

/// 服务器连通状态。草稿 06 的状态点三态:绿=正常 / 黄=需重登 / 灰=未连。
/// `Unknown` 是「还没探过」,前端按灰显示 —— 与"探过了确实不通"同色不同义,
/// 别在 Rust 侧合并成一个:合并了就没法区分"没测"和"测了挂了"。
#[derive(serde::Serialize, Clone, Copy, PartialEq, Debug)]
#[serde(rename_all = "snake_case")]
enum AccountStatus {
    /// 绿:能连且 token 有效。
    Ok,
    /// 黄:服务器活着,但 token 被吊销/过期 —— 用户重登一次就好。
    Reauth,
    /// 灰:压根连不上(域名挂了/线路不通/超时)。
    Down,
    /// 灰:尚未探测。
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
    /// 连通状态三态(需先调 probe_accounts 刷新,否则恒为 unknown)。
    status: AccountStatus,
    /// 显示名(用户起的名,空则回落 host)。
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

fn account_info(a: &linplayer_core::Account, active: bool) -> AccountInfo {
    account_info_with(a, active, AccountStatus::Unknown)
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

/// 探测所有服务器的连通状态,刷新缓存并返回新的列表。前端进服务器页时调一次。
/// 并发探测:一台慢的不该拖住整页(串行 N 台 × 8s 超时 = 页面空一分钟)。
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

/// 单台探测。**必须走 active_line_url()** —— 用户切了备用线路正是因为主线不通,
/// 拿主线去探会把一台好服务器判成灰,而用户看到的又是"我明明能用"。
async fn probe_account(http: &reqwest::Client, a: &linplayer_core::Account) -> AccountStatus {
    let base = a.active_line_url();
    let base = base.trim_end_matches('/');
    if a.is_file_browse() {
        // 浏览型源没有统一的鉴权探测端点(各家 API 差太多),只判连通:
        // 能要到任何 HTTP 响应就算活着。判不了"需重登",所以只会给出绿/灰两态。
        return match http.get(base).send().await {
            Ok(_) => AccountStatus::Ok,
            Err(_) => AccountStatus::Down,
        };
    }
    // Emby:/System/Info 需要鉴权 —— 正好一次分出三态。
    // 用 /System/Info/Public 是不行的:它不校验 token,token 失效也回 200,
    // 那样"需重登"永远探不出来,黄灯就成了摆设。
    let url = format!("{base}/System/Info?api_key={}", a.token);
    match http.get(&url).send().await {
        Ok(r) if r.status().is_success() => AccountStatus::Ok,
        Ok(r) if matches!(r.status().as_u16(), 401 | 403) => AccountStatus::Reauth,
        // 其它状态码(5xx / 404 / 网关错误)说明连上了但这服务器不正常,归为不可用。
        Ok(_) => AccountStatus::Down,
        Err(_) => AccountStatus::Down,
    }
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

/// 「同步线路」的结果。`supported=false` 时 UI 该说「这台服务器没提供线路表」,不是报错。
#[derive(serde::Serialize)]
struct SyncedLines {
    /// 服主是否部署了 emby_ext_domains(端点 200 且 ok:true)。
    supported: bool,
    /// 新增了几条(已有的 url 不会重复加)。
    added: usize,
    /// 同步后的线路总数。
    total: usize,
}

/// 同步线路:从服主部署的 emby_ext_domains 拉取备用域名,并入本地线路表。
///
/// 用户 2026-07-15 点名要接的就是这个(https://github.com/uhdnow/emby_ext_domains)。
/// 此前「同步线路」这个按钮**名不副实** —— 它调的是 probe_lines(测延迟),
/// 一条线路都不会拉。草稿 pin 29 写的是「点一下一键拉取/更新全部线路」,是我做错了。
///
/// ## 合并策略:只增不删,按 url 去重
/// **绝不整表覆写。** 用户手填的线路(内网地址、自建 CDN)服主的表里不可能有,
/// 覆写等于把用户的配置删了 —— 而且他多半是在「当前线路连不上」时点的同步,
/// 那一刻把他仅有的能用线路删掉是灾难。
///
/// ## active_line 必须跟着原来那条 url 走
/// active_line 是**下标**不是 id。往表里插行会让下标指到别的线路上 ——
/// 用户点个「同步线路」结果生效线路被悄悄换了,还是那句:不报错,只是干了别的事。
/// 这里先把当前 url 记下来,合并完按 url 找回下标。有测试钉。
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

/// 切换生效线路;若切的是当前活跃服务器,同步刷新会话让后续请求立刻走新线路。
#[tauri::command]
fn set_active_line(state: State<'_, AppState>, server_id: String, index: usize) -> Result<(), String> {
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

/// 注册 `linplayer://` 协议(Windows)。
///
/// 用「写 .reg 文件 + reg import」而非 `reg add`:后者对空值(`URL Protocol`)和带空格的
/// 路径引号处理不可靠,会把命令存成没引号、一运行就失败。这是 Dart 侧踩过的坑,照搬。
///
/// 每次启动都跑一遍:本项目是绿色压缩包分发,用户挪个文件夹 exe 路径就变了,
/// 注册表里还钉着老路径的话,深链点了会启动失败或启动到旧副本 —— 而且不报错。
#[cfg(windows)]
fn register_deep_link_scheme() {
    let Ok(exe) = std::env::current_exe() else { return };
    let exe = exe.to_string_lossy().replace('\\', "\\\\").replace('"', "\\\"");
    let content = format!(
        "Windows Registry Editor Version 5.00\r\n\
         \r\n\
         [HKEY_CURRENT_USER\\Software\\Classes\\linplayer]\r\n\
         @=\"URL:LinPlayer Protocol\"\r\n\
         \"URL Protocol\"=\"\"\r\n\
         \r\n\
         [HKEY_CURRENT_USER\\Software\\Classes\\linplayer\\shell\\open\\command]\r\n\
         @=\"\\\"{exe}\\\" \\\"%1\\\"\"\r\n"
    );
    // 写在自己的数据根里而不是 %TEMP% 根:import 完就删,但也别在别人地盘上留哪怕一秒。
    let f = linplayer_core::paths::logs_dir().join("scheme.reg");
    // .reg 必须是无 BOM 的 UTF-8,reg import 才认。
    if std::fs::write(&f, content.as_bytes()).is_ok() {
        use std::os::windows::process::CommandExt;
        // CREATE_NO_WINDOW:注册协议时不弹黑 cmd 窗(同 translation.rs 的处理)。
        let _ = std::process::Command::new("reg")
            .arg("import")
            .arg(&f)
            .creation_flags(0x0800_0000)
            .status();
        let _ = std::fs::remove_file(&f);
    }
}

/// 注册 `linplayer://` 协议(Linux)。
///
/// 对应 Windows 那半的注册表写法,这边是 freedesktop 的规矩:往用户的 applications 目录
/// 放一个带 `MimeType=x-scheme-handler/linplayer` 的 .desktop,再把它设成该 scheme 的默认处理器。
/// 同样**每次启动都重写** —— 绿色包用户挪了文件夹,Exec= 里的老路径就是死的,而且不报错。
///
/// 显式走真实 home 而不是 `dirs::data_local_dir()`:这个文件**必须**让桌面环境扫得到,
/// 是少数几个「该落在包外」的东西之一(和注册表键同理,删文件夹带不走)。写死路径比
/// 依赖某个会被环境变量左右的抽象更稳 —— 早期劫持 XDG 时就险些把它写进包里。
#[cfg(target_os = "linux")]
fn register_deep_link_scheme() {
    let Ok(exe) = std::env::current_exe() else { return };
    let Some(home) = dirs::home_dir() else { return };
    let apps = home.join(".local").join("share").join("applications");
    if std::fs::create_dir_all(&apps).is_err() {
        return;
    }
    // Exec 的 %u 是 freedesktop 规定的「传一个 URL 进来」占位符,深链靠它拿到 linplayer://…
    let content = format!(
        "[Desktop Entry]\n\
         Type=Application\n\
         Name=LinPlayer\n\
         Exec=\"{}\" %u\n\
         NoDisplay=false\n\
         Terminal=false\n\
         Categories=AudioVideo;Player;\n\
         MimeType=x-scheme-handler/linplayer;\n",
        exe.display()
    );
    let f = apps.join("linplayer.desktop");
    if std::fs::write(&f, content).is_err() {
        return;
    }
    // 两个工具在精简发行版上都可能没有;失败就算了,不该因为注册不上协议就影响启动。
    let _ = std::process::Command::new("update-desktop-database").arg(&apps).status();
    let _ = std::process::Command::new("xdg-mime")
        .args(["default", "linplayer.desktop", "x-scheme-handler/linplayer"])
        .status();
}

#[cfg(not(any(windows, target_os = "linux")))]
fn register_deep_link_scheme() {}

/// 启动参数里的 `linplayer://...`(系统通过协议拉起我们时会作为 argv 传进来)。
/// 前端进主界面后调一次;有值就走确认流程。
///
/// ⚠️ 只在**冷启动**时有效。App 已经开着时再点深链,系统会拉起第二个进程 ——
/// 那需要单实例守卫(tauri-plugin-single-instance),没接,已知缺口。
#[tauri::command]
fn startup_deep_link() -> Option<String> {
    std::env::args().skip(1).find(|a| a.starts_with("linplayer://"))
}

// ---------- 服务器图标:下载 / 缓存 / 本地上传 ----------

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

// ---------- 批量解析添加服务器 + linplayer:// 深链(草稿页 06)----------

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

#[derive(serde::Serialize)]
struct BatchAddResult {
    /// 加成功的服务器主键(= 生效线路 URL);失败为 None。
    server_id: Option<String>,
    /// 展示名。
    name: String,
    /// 失败原因;成功为 None。
    error: Option<String>,
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

/// 线路测速:并发 HEAD 各线路的 /System/Info/Public,返回毫秒;不通为 None。
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

/// 只探**一条**线路。给「先出线路表、再逐条填延迟」用(用户 2026-07-16:
/// 「不需要做延迟探测,要做也是先显示线路再去探测,不然一条探得久就一直卡在那」)。
///
/// ★ 为什么不能复用 probe_lines:它要**等最慢的那条**(最坏 6s)才整表返回 ——
/// 一条死线就把整个面板扣住,用户连切到能用的线路都做不到。逐条探则各回各的,
/// 死线只是它自己那一行慢慢转,不牵连别人。
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

/// 删除某账号;若删的是活跃账号,回落到第一个(无账号则清空会话)。
/// 删本地前尽力通知服务端登出(吊销 token),失败不影响本地删除。
#[tauri::command]
async fn remove_account(state: State<'_, AppState>, server_id: String) -> Result<(), String> {
    // ★ 先尽力登出:服务端不可达/端点不存在也必须能删账号。
    // 实测 smart.uhdnow.com 的 /Sessions/Logout 直接 404,所以这里只能忽略结果 ——
    // 认这个端点的服务器上 token 会被吊销,不认的照旧本地删。
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

// image_url 命令已删:前端 src/lib/api.ts 自己拼图片地址,grep 全仓无人 invoke("image_url"),
// 且原实现写死 Primary?maxHeight=360 表达不了 Thumb/Backdrop/Logo —— 死代码,不留。

// ---------- 播放命令 ----------
/// 把设置页的播放器默认值应用到 mpv。**每次 loadfile 之前**调一次。
///
/// 为什么不是"初始化时设一次":用户在设置页改完不重启也得生效,而且杜比软解是**逐片**
/// 判定的 —— 上一部是 DV 切了软解,下一部是普通片必须切回硬解,否则白白吃一部片的 CPU。
/// 所以每次起播都从配置重新算一遍,不留跨片残留状态。
fn apply_playback_defaults(state: &State<'_, AppState>, p: &Player, is_dolby_vision: bool) {
    let (hwdec, speed, dolby_auto) = {
        let pf = &state.config.lock().unwrap().prefs;
        (pf.hwdec.clone(), pf.default_speed, pf.dolby_auto_sw)
    };
    // 杜比视界:开着自动软解且这片是 DV → 强制软解,压过用户的默认解码方式。
    // 理由见 [[dolby-auto-decode]]:DV 走硬解在多数 Windows 显卡上出色偏移(发绿/发紫)。
    let effective = if dolby_auto && is_dolby_vision { "no" } else { hwdec.as_str() };
    p.set_hwdec(effective);
    p.set_speed(speed);
    if effective != hwdec {
        poclog("杜比视界:自动切软解(hwdec=no)");
    }
    poclog(&format!("播放默认值 hwdec={effective} speed={speed} dv={is_dolby_vision}"));
}

/// 播放:解析流 -> 从 resume_secs 起播 -> 上报 start;返回起播秒数供前端定位进度条。
#[tauri::command]
async fn play(
    state: State<'_, AppState>,
    item_id: String,
    resume_secs: f64,
    media_source_id: Option<String>,
) -> Result<f64, String> {
    let s = session_of(&state)?;

    /* 观看记录上下文 与 取流地址 **并发**打 —— 两者互不依赖,却曾经一前一后串着 await,
       白白多等 1~2 个 RTT(远程 Emby 每个 100~300ms)才轮到 mpv loadfile。
       ★ 能 join 的前提是这两条路上**没有跨 await 持有的 std Mutex**:
         build_wh_ctx→series_tmdb_cached 的锁在 await 前就出了作用域,resolve_stream 只用 http。
         往这两条路上加锁时务必重新确认,否则 join! 把两个 future 放同一线程轮询,
         一方持锁 await、另一方去抢同一把锁 = 自我死锁(本项目在 [[prefetch-proxy-deadlock]]
         上栽过同一类跟头:症状是起播直接吊死,不报错)。 */
    // 版本筛选正则先在 await 之前从 config 取出来 —— 上面那段注释讲的就是这件事:
    // join! 里两个 future 同线程轮询,谁跨 await 攥着 std Mutex 谁就自己锁死自己。
    let version_regex = state.config.lock().unwrap().prefs.version_regex.clone();
    let (ctx, target) = tokio::join!(
        build_wh_ctx(&state, &s, &item_id),
        emby::resolve_stream(
            &state.http,
            &s,
            &item_id,
            media_source_id.as_deref(),
            &version_regex,
        ),
    );
    let target = target?;

    // 前端传进来的 resume_secs 只是 Emby 本服的进度;跨服续播开启时,
    // 本地记录里别的服务器上更靠后的进度会覆盖它(取最大)。
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
    // 回传去重集按「一次播放」计生命周期(对齐 Dart _done):不清的话,看完第二集时
    // 第一集的去重键还在,同一台服务器会被判成"已回传过"而跳过 —— 静默漏传。
    state.wh_done.lock().unwrap().clear();

    poclog(&format!(
        "PLAY item={item_id} resume={resume_secs} psid={} url={} method={}",
        target.play_session_id, target.url, target.play_method
    ));

    // 多线程加载:仅直传流走本地预取代理(转码 URL 是分段流,跳过直连)。
    // 起服失败/非直传/这台服没开 → 回退直连;旧句柄被替换即 Drop 停服。
    // ★ 开关按**服务器**查(Account.server 身份键),不是全局:线路只是同一台服的入口,
    //   所以这里认账号 id 而非 session.server(后者是 active_line_url,还可能被 CF 反代改写)。
    let (pf_on, pf_threads, pf_cache) = {
        let cfg = state.config.lock().unwrap();
        let on = cfg
            .active_account()
            .is_some_and(|a| cfg.prefs.prefetch_servers.iter().any(|s| *s == a.server));
        (on, cfg.prefs.prefetch_threads, cfg.prefs.prefetch_cache_bytes)
    };
    let play_url = if pf_on && target.play_method == "DirectStream" {
        let resign: linplayer_core::net::prefetch::ResignFn = {
            let http = state.http.clone();
            let sess = s.clone();
            let iid = item_id.clone();
            // ★ 必须把 media_source_id 一起带上重签:不带的话 URL 过期重签会
            //   悄悄退回默认版本 —— 用户选的 4K 播到一半变 1080p,且无任何提示。
            let msid = target.media_source_id.clone();
            Arc::new(move || {
                let (http, sess, iid, msid) = (http.clone(), sess.clone(), iid.clone(), msid.clone());
                Box::pin(async move {
                    // 已经钉死 media_source_id 了,正则不参与(手动/既定选择永远优先)。
                    emby::resolve_stream(&http, &sess, &iid, Some(&msid), "")
                        .await
                        .ok()
                        .map(|t| t.url)
                })
            })
        };
        // 线程数与读前缓冲上限来自设置页(prefetch::start 内部会把线程数 clamp 到 2~4)。
        match linplayer_core::net::prefetch::start(target.url.clone(), pf_threads, pf_cache, Some(resign)).await {
            Some(h) => {
                let u = h.url.clone();
                *state.prefetch.lock().unwrap() = Some(h);
                poclog(&format!("prefetch 代理起服 {u}"));
                u
            }
            None => {
                *state.prefetch.lock().unwrap() = None;
                target.url.clone()
            }
        }
    } else {
        *state.prefetch.lock().unwrap() = None; // 转码/非直传:停旧代理走直连
        target.url.clone()
    };

    // 加载(不跨 await 持锁)
    {
        let guard = state.player.lock().unwrap();
        let p = guard.as_ref().ok_or_else(|| {
            poclog("PLAY 失败: 播放器未就绪(mpv 初始化没成功)");
            "播放器未就绪".to_string()
        })?;
        let _ = p.take_error_eof();
        // media 代理:仅 HTTP 系列 + 开启 proxyMedia 时给 mpv 挂 http-proxy(SOCKS mpv 不支持)。
        // ★ 播放地址是本机回环(CF 优选反代 / 多线程加载预取代理)时**不给 mpv 挂代理**:
        //   理由同 http.rs 的 LOOPBACK_NO_PROXY —— mpv 会把 127.0.0.1 的请求递给用户代理,
        //   代理再去连**它自己那头**的 127.0.0.1,我们的本地服务根本不在那儿。
        //   真正出网的那一跳由 CF 反代/预取代理自己完成,代理设置在那一层已经生效过了。
        let mpv_proxy = if linplayer_core::http::is_loopback_url(&play_url) {
            None
        } else {
            state.config.lock().unwrap().proxy.mpv_http_proxy()
        };
        p.set_http_proxy(mpv_proxy.as_deref());
        apply_playback_defaults(&state, p, target.is_dolby_vision);
        p.load_at(&play_url, resume_secs)?;
        /* ★ 外挂字幕(和视频同级的独立 .ass/.srt)**不在容器里**,mpv 拿到视频 URL 后
           track-list 里根本看不到它们 —— 这就是「外挂字幕不加载」。必须逐条 sub-add。
           放在 load_at 之后:sub-add 挂的是**当前文件**,先挂会被 loadfile 冲掉。
           flags=auto 表示挂上但不自动切,选哪条仍由用户/语言偏好决定。 */
        for sub in &target.external_subs {
            p.add_subtitle(&sub.url, &sub.title);
        }
        if !target.external_subs.is_empty() {
            poclog(&format!("挂载外挂字幕 {} 条", target.external_subs.len()));
        }
        p.set_pause(false);
    }
    // 起播了才让视频窗露面(平时它藏着,见 show_video)。必须在上面那把播放器锁**之外**。
    show_video(&state, true);
    *state.source_play_entry.lock().unwrap() = None; // Emby 播放,非源
    // 上报 start(失败不阻断播放)
    if let Err(e) = emby::report_start(&state.http, &s, &target, resume_secs).await {
        poclog(&format!("report_start ERR: {e}"));
    }
    *state.playback.lock().unwrap() = Some(target);

    // 播放期同步:Trakt/Bangumi 任一连接就抓元数据,存上下文供 stop 收尾。
    *state.scrobble_ctx.lock().unwrap() = None;
    let (trakt_acc, bangumi_on) = {
        let cfg = state.config.lock().unwrap();
        (cfg.sync_trakt.clone(), cfg.sync_bangumi.is_some())
    };
    if trakt_acc.is_some() || bangumi_on {
        if let Some(info) = emby::fetch_scrobble_info(&state.http, &s, &item_id).await {
            *state.scrobble_ctx.lock().unwrap() = Some(info.clone());
            // Trakt 有外部 ID 才上报 start(后台,不阻塞起播)。
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
    // 派发 onPlay 给插件(eventListeners)。
    if let Some(mgr) = state.plugins.get() {
        let media = state
            .scrobble_ctx
            .lock()
            .unwrap()
            .as_ref()
            .map(|i| serde_json::json!({ "name": i.title, "type": i.media_type }))
            .unwrap_or(serde_json::Value::Null);
        mgr.fire_player_event("onPlay", media);
    }
    poclog("load OK");
    Ok(resume_secs)
}

// ---------- 本地观看记录 / 跨服务器续播 ----------
use linplayer_core::watch_history as wh;

fn scope_of(s: &Session) -> String {
    wh::scope_key(&s.server, &s.user_id)
}

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

/// 周期/暂停切换时上报进度(前端每 ~5s 及暂停切换时调)。仅 Emby 播放有会话时上报。
/// 顺带落本地观看记录(core 内部按 10s 节流,不会每次都写盘)。
#[tauri::command]
async fn report_progress(state: State<'_, AppState>, pos: f64, paused: bool) -> Result<(), String> {
    let target = state.playback.lock().unwrap().clone();
    let Some(t) = target else {
        // 无 Emby 会话 = 浏览型源在播。有服务端观看记录的源(飞牛)在这里落进度。
        return report_source_progress(&state, pos, false).await;
    };
    let s = session_of(&state)?;
    let _ = emby::report_progress(&state.http, &s, &t, pos, paused).await;
    capture_history(&state, pos, false);
    Ok(())
}

/// 浏览型源的进度上报。多数网盘没有服务端进度(默认空实现),飞牛有。
/// 一律吞错:进度没记上是小事,把正在看的片子打断是大事。
async fn report_source_progress(
    state: &State<'_, AppState>,
    pos: f64,
    is_stop: bool,
) -> Result<(), String> {
    let Some((entry_id, entry_name)) = state.source_play_entry.lock().unwrap().clone() else {
        return Ok(());
    };
    let Some((kind, server)) = state.source.lock().unwrap().clone() else {
        return Ok(());
    };
    let Ok(backend) = source_backend(state, &kind) else {
        return Ok(());
    };
    // 时长从播放器现读 —— 前端那一拍只传了位置。
    let duration = state
        .player
        .lock()
        .unwrap()
        .as_ref()
        .map(|p| p.status().duration)
        .unwrap_or(0.0);
    let entry = SourceEntry {
        id: entry_id,
        name: entry_name,
        is_dir: false,
        is_video: true,
        size: None,
        thumb_url: None,
        raw: None,
    };
    // 「看完」的判据与 Emby 一致(90%),只在停止那一次判 —— 中途每 5s 一拍不该置已看。
    let finished = is_stop && duration > 0.0 && pos >= duration * 0.9;
    let _ = backend
        .report_progress(&state.http, &server, &entry, pos, duration, finished)
        .await;
    Ok(())
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

/// 观看记录列表。scope=None 取全部(跨服务器);否则只取当前服务器。
#[tauri::command]
fn watch_history_list(state: State<'_, AppState>, current_only: bool) -> Vec<wh::Record> {
    if current_only {
        match session_of(&state) {
            Ok(s) => state.watch_history.load_scope(&scope_of(&s)),
            Err(_) => Vec::new(),
        }
    } else {
        state.watch_history.load_all()
    }
}

#[tauri::command]
fn watch_history_clear(state: State<'_, AppState>) {
    state.watch_history.clear_all();
}

#[tauri::command]
fn watch_history_delete(state: State<'_, AppState>, record_id: String) {
    state.watch_history.delete_record(&record_id);
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

/// 跨服回传设置(主开关 / 范围 / 是否带进度)。
#[derive(serde::Serialize, serde::Deserialize)]
struct WritebackSettings {
    enabled: bool,
    /// "all" | "first" | "latest"
    range: String,
    include_progress: bool,
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

/// 所有已登录 Emby 账号的会话(跨服回传/恢复扫描要挨个打)。浏览型源没有 Emby 会话,跳过。
fn all_emby_sessions(state: &AppState) -> Vec<Session> {
    let cfg = state.config.lock().unwrap();
    let device_id = cfg.device_id.clone();
    cfg.accounts
        .iter()
        .filter(|a| !a.is_file_browse() && !a.token.is_empty())
        .map(|a| Session {
            server: a.active_line_url(),
            token: a.token.clone(),
            user_id: a.user_id.clone(),
            device_id: device_id.clone(),
        })
        .collect()
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

/// 停播时把这次的进度/已看状态回传到**其它**看过同一内容的服务器。
/// 判定逻辑全在 core 的 writeback_targets/writeback_plan(已测),这里只做 HTTP 编排。
///
/// 默认不跑:主开关默认关,因为它会往用户的其它服务器写数据。
async fn writeback_on_stop(
    state: &State<'_, AppState>,
    scope: &str,
    cand: &wh::Candidate,
    pos: f64,
) -> Result<(), String> {
    let (enabled, range, include_progress) = {
        let p = &state.config.lock().unwrap().prefs;
        (
            p.cross_server_writeback,
            wh::WritebackRange::from_wire(&p.cross_server_writeback_range),
            p.cross_server_writeback_progress,
        )
    };
    if !enabled {
        return Ok(());
    }
    let s = session_of(state)?;
    let sessions = all_emby_sessions(state);
    let ticks = (pos * wh::TICKS_PER_SEC as f64) as i64;
    // 「已看完」判定必须与 capture_history 落本地记录时用的是同一个阈值(90%),
    // 否则会出现"本地记成看完了、回传给别的服务器却说没看完"这种自相矛盾。
    let played = cand
        .run_time_ticks
        .filter(|r| *r > 0)
        .map(|r| (ticks as f64 / r as f64) * 100.0 >= 90.0)
        .unwrap_or(false);

    let mut done = state.wh_done.lock().unwrap().clone();
    let report = linplayer_core::watch_history_sync::run_writeback(
        &state.http,
        &s,
        &sessions,
        &state.watch_history,
        scope,
        cand,
        ticks,
        played,
        range,
        include_progress,
        &mut done,
    )
    .await?;
    *state.wh_done.lock().unwrap() = done;
    if !report.errors.is_empty() {
        poclog(&format!("[跨服回传] 部分失败: {:?}", report.errors));
    }
    poclog(&format!(
        "[跨服回传] 目标 {} 台,写成功 {},跳过 {}",
        report.targets,
        report.written,
        report.skipped.len()
    ));
    Ok(())
}

/// 停止播放:暂停 mpv + 上报 stopped(写回最终进度 -> 续播落地)+ 清会话。
#[tauri::command]
async fn stop_playback(state: State<'_, AppState>, pos: f64) -> Result<(), String> {
    {
        let guard = state.player.lock().unwrap();
        if let Some(p) = guard.as_ref() {
            p.set_pause(true);
        }
    }
    // 退出播放页 → 视频窗藏起来。不藏的话主窗一最小化,桌面上就露出一个黑窗。
    show_video(&state, false);
    *state.source_play_entry.lock().unwrap() = None; // 退出播放,停止 302 看门狗
    *state.prefetch.lock().unwrap() = None; // 停预取代理(Drop 关服)

    // 观看记录:最终进度必须落地(force 绕开 10s 节流),否则看一半退出这段就丢了。
    capture_history(&state, pos, true);
    // 跨服回传要用 ctx 里的 Candidate,得在清空前取走。
    let wh_ctx = state.wh_ctx.lock().unwrap().take();
    if let Some((scope, cand, _)) = wh_ctx {
        if let Err(e) = writeback_on_stop(&state, &scope, &cand, pos).await {
            poclog(&format!("[跨服回传] 失败: {e}"));
        }
    }

    // 播放期同步收尾:按最终进度上报。
    let ctx = state.scrobble_ctx.lock().unwrap().take();
    let (trakt_acc, bangumi_acc) = {
        let cfg = state.config.lock().unwrap();
        (cfg.sync_trakt.clone(), cfg.sync_bangumi.clone())
    };
    if let Some(info) = ctx {
        let progress = if info.runtime_secs > 0.0 {
            (pos / info.runtime_secs * 100.0).clamp(0.0, 100.0)
        } else {
            0.0
        };
        let watched = progress >= WATCHED_PERCENT;
        // Trakt:先 scrobble/stop(维护「继续观看」),看完再显式写一次历史。
        if let Some(acc) = trakt_acc {
            if info.has_trakt_ids() {
                let body = info.trakt_body();
                let ok = trakt::scrobble(&acc, &body, progress, "stop").await;
                poclog(&format!("[Trakt] scrobble stop {:.1}% -> {}", progress, ok));
                /* ★ 只靠 scrobble/stop 是不够的 —— 它只在 Trakt 认可这次会话时才落历史,
                   于是出现「继续观看有、历史观看空」。看完就显式 POST /sync/history,
                   它是幂等的,重复写不会产生重复记录。 */
                if watched {
                    let ok = trakt::add_to_history(&acc, &body).await;
                    poclog(&format!("[Trakt] 写入观看历史 -> {ok}"));
                }
            } else {
                poclog("[Trakt] 跳过:该条目和它所属剧集都没有外部 ID(Imdb/Tmdb/Tvdb)");
            }
        }
        // Bangumi:看过阈值才反查标记(反查耗多次 API,不到阈值不触发)。
        if let Some(acc) = bangumi_acc {
            if watched && !info.title.is_empty() {
                mark_bangumi_watched(&acc, &info).await;
            }
        }
    }

    let target = state.playback.lock().unwrap().take();
    match target {
        Some(t) => {
            if let Ok(s) = session_of(&state) {
                if let Err(e) = emby::report_stopped(&state.http, &s, &t, pos).await {
                    poclog(&format!("report_stopped ERR: {e}"));
                }
            }
        }
        // 浏览型源:把最终进度落到服务端观看记录(飞牛),够 90% 顺带置已看。
        None => {
            let _ = report_source_progress(&state, pos, true).await;
        }
    }
    // 派发 onPlayEnd 给插件(eventListeners,如 telegram-notify)。
    if let Some(mgr) = state.plugins.get() {
        mgr.fire_player_event("onPlayEnd", serde_json::json!({ "position": pos }));
    }
    Ok(())
}

#[tauri::command]
fn set_pause(state: State<'_, AppState>, paused: bool) -> Result<(), String> {
    let guard = state.player.lock().unwrap();
    guard.as_ref().ok_or("播放器未就绪")?.set_pause(paused);
    Ok(())
}

#[tauri::command]
fn seek(state: State<'_, AppState>, pos: f64) -> Result<(), String> {
    let guard = state.player.lock().unwrap();
    guard.as_ref().ok_or("播放器未就绪")?.seek_abs(pos)
}

#[tauri::command]
fn status(state: State<'_, AppState>) -> Result<Status, String> {
    let guard = state.player.lock().unwrap();
    Ok(guard.as_ref().ok_or("播放器未就绪")?.status())
}

#[tauri::command]
fn tracks(state: State<'_, AppState>) -> Result<Vec<Track>, String> {
    let guard = state.player.lock().unwrap();
    Ok(guard.as_ref().ok_or("播放器未就绪")?.tracks())
}

#[tauri::command]
fn set_track(state: State<'_, AppState>, kind: String, id: String) -> Result<(), String> {
    let guard = state.player.lock().unwrap();
    guard.as_ref().ok_or("播放器未就绪")?.set_track(&kind, &id);
    Ok(())
}

// ================= 播放器能力命令 =================
// 对齐旧 Flutter 三端契约 lib/core/services/video_player_service.dart。
// 迁移文档只列到「播放器」模块粒度,没列能力清单 → 上一轮把倍速/音量/截图/画面比例/
// 延迟/字幕样式/超分全漏了,UI 上就是一排死按钮。这里按旧契约补齐。

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

/// 取播放器当前可调项。
#[tauri::command]
fn player_opts(state: State<'_, AppState>) -> Result<PlayerOpts, String> {
    // ★ 先取 DV 标志再拿 player 锁。反过来会在两把锁之间形成固定的持有顺序依赖,
    //   本项目在 [[prefetch-proxy-deadlock]] 上栽过同类跟头,不给它长出来的机会。
    let dolby_vision = state
        .playback
        .lock()
        .unwrap()
        .as_ref()
        .is_some_and(|t| t.is_dolby_vision);
    let guard = state.player.lock().unwrap();
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

macro_rules! with_player {
    ($state:expr, $p:ident => $body:expr) => {{
        let guard = $state.player.lock().unwrap();
        let $p = guard.as_ref().ok_or("播放器未就绪")?;
        $body;
        Ok(())
    }};
}

#[tauri::command]
fn set_speed(state: State<'_, AppState>, speed: f64) -> Result<(), String> {
    with_player!(state, p => p.set_speed(speed))
}

#[tauri::command]
fn set_volume(state: State<'_, AppState>, volume: f64) -> Result<(), String> {
    with_player!(state, p => p.set_volume(volume))
}

#[tauri::command]
fn set_mute(state: State<'_, AppState>, mute: bool) -> Result<(), String> {
    with_player!(state, p => p.set_mute(mute))
}

#[tauri::command]
fn set_audio_delay(state: State<'_, AppState>, secs: f64) -> Result<(), String> {
    with_player!(state, p => p.set_audio_delay(secs))
}

#[tauri::command]
fn set_sub_delay(state: State<'_, AppState>, secs: f64) -> Result<(), String> {
    with_player!(state, p => p.set_sub_delay(secs))
}

#[tauri::command]
fn set_aspect_ratio(state: State<'_, AppState>, ratio: String) -> Result<(), String> {
    with_player!(state, p => p.set_aspect_ratio(&ratio))
}

#[tauri::command]
fn set_hwdec(state: State<'_, AppState>, mode: String) -> Result<(), String> {
    with_player!(state, p => p.set_hwdec(&mode))
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
    state: State<'_, AppState>,
    font: Option<String>,
    scale: Option<f64>,
    position: Option<f64>,
    background: Option<bool>,
    blend_mode: Option<String>,
) -> Result<(), String> {
    let guard = state.player.lock().unwrap();
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
fn set_secondary_sub(state: State<'_, AppState>, id: String) -> Result<(), String> {
    with_player!(state, p => p.set_secondary_sub(&id))
}

#[tauri::command]
fn set_secondary_sub_opts(
    state: State<'_, AppState>,
    delay: Option<f64>,
    position: Option<f64>,
    ass_override: Option<String>,
) -> Result<(), String> {
    let guard = state.player.lock().unwrap();
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
    state: State<'_, AppState>,
    url: String,
    title: Option<String>,
    secondary: Option<bool>,
) -> Result<(), String> {
    let guard = state.player.lock().unwrap();
    let p = guard.as_ref().ok_or("播放器未就绪")?;
    let t = title.unwrap_or_else(|| "外挂字幕".into());
    if secondary.unwrap_or(false) {
        p.add_secondary_sub(&url, &t)
    } else {
        p.add_subtitle(&url, &t);
        Ok(())
    }
}

// ---------- 字幕翻译 ----------
use linplayer_core::translation as tr;

/// 把一段阻塞活儿(磁盘读、进程 spawn)挪到 tokio 的阻塞线程池。
///
/// ★ 为什么需要它:**Tauri 的非 async 命令跑在主线程**,里面任何同步 IO 都直接冻 UI。
///   改成 `async fn` 只是让它进 tokio 的**异步**运行时 —— 阻塞调用在那儿一样会占死 worker,
///   必须再套一层 spawn_blocking 才真的挪走。别只加 async 就以为好了。
async fn blocking<T, F>(f: F) -> T
where
    F: FnOnce() -> T + Send + 'static,
    T: Send + 'static,
{
    // JoinError 只在任务自己 panic 或被 abort 时出现 —— 两者都是 bug,不该悄悄吞掉。
    tokio::task::spawn_blocking(f).await.expect("阻塞任务崩了")
}

#[tauri::command]
async fn get_translation_settings() -> tr::TranslationSettings {
    // ★ async + spawn_blocking:Tauri 的**非 async 命令跑在主线程**,而 load() 是磁盘读。
    //   见 whisper_deps 上那段完整说明。
    blocking(tr::TranslationSettings::load).await
}

#[tauri::command]
fn set_translation_settings(settings: tr::TranslationSettings) -> Result<(), String> {
    settings.save()
}

/// 各引擎是否已配好(设置页的状态点)。key=引擎 storage_key。
// ---------- 实时预读翻译:挂在播放器上 ----------
//
// 「字幕 cue 观测」听着像要新建一套观测机制,其实 mpv 的 `sub-text` / `sub-start` /
// `sub-end` 就是普通属性,get_property 直接读得到 —— 播放器侧没有任何前置缺口。
// 内嵌字幕也不用隐藏:我们不改字幕轨,只是把 mpv 当前显示的这句原样取出来译好,
// 通过事件推给前端叠加层渲染,mpv 那句由前端决定盖不盖。

/// 停掉实时翻译轮询的信号。Drop/置 false 即停。
struct LiveTranslate {
    stop: Arc<std::sync::atomic::AtomicBool>,
}

/// 开启实时预读翻译。轮询 mpv 的 sub-text,每换一句就译一句,译完 emit 给前端叠加层。
///
/// source_lang=None 表示让引擎自动判断源语言。
#[tauri::command]
fn translate_live_start(
    app: tauri::AppHandle,
    state: State<'_, AppState>,
    source_lang: Option<String>,
) -> Result<(), String> {
    let settings = tr::TranslationSettings::load();
    let engine = tr::active_engine(&settings)
        .ok_or("当前翻译引擎还没配好(缺 API Key 或地址),先去设置里填")?;
    let translator = Arc::new(tr::StreamingTranslator::new(
        engine,
        source_lang.unwrap_or_default(),
        settings.target_lang.clone(),
        settings.layout,
    ));

    // 先停旧的:不停的话切换引擎/语言会留下两个轮询,两句译文交替闪。
    translate_live_stop(state.clone());
    let stop = Arc::new(std::sync::atomic::AtomicBool::new(false));
    *state.live_translate.lock().unwrap() = Some(LiveTranslate { stop: stop.clone() });

    tauri::async_runtime::spawn(async move {
        use tauri::Emitter;
        let mut last = String::new();
        loop {
            if stop.load(Ordering::SeqCst) {
                break;
            }
            // 每轮重新拿 state:播放器可能中途被换掉(换片),持着旧引用会译到上一部的字幕。
            let cur = {
                let st: State<'_, AppState> = app.state();
                let guard = st.player.lock().unwrap();
                guard.as_ref().and_then(|p| p.get_property("sub-text"))
            }
            .unwrap_or_default();

            if cur != last {
                last = cur.clone();
                if cur.trim().is_empty() {
                    // 空 cue = 这句结束了,清掉叠加层,否则上一句会一直挂着。
                    let _ = app.emit("subtitle-translated", String::new());
                } else if let Some(hit) = translator.cached_display(&cur) {
                    // 命中缓存就直接推,不必等一个网络往返(重复台词/回看很常见)。
                    let _ = app.emit("subtitle-translated", hit);
                } else {
                    match translator.on_cue(&cur).await {
                        Ok(text) => {
                            let _ = app.emit("subtitle-translated", text);
                        }
                        // 单句失败不该停掉整个轮询(限流/抖动),但要让前端知道这句没译出来,
                        // 不能静默显示原文让用户以为翻译在工作。
                        Err(e) => {
                            let _ = app.emit("subtitle-translate-error", e);
                        }
                    }
                }
            }
            tokio::time::sleep(std::time::Duration::from_millis(200)).await;
        }
    });
    Ok(())
}

#[tauri::command]
fn translate_live_stop(state: State<'_, AppState>) {
    if let Some(lt) = state.live_translate.lock().unwrap().take() {
        lt.stop.store(true, Ordering::SeqCst);
    }
}

#[tauri::command]
async fn translation_engine_status() -> HashMap<String, bool> {
    blocking(|| {
        let s = tr::TranslationSettings::load();
        use tr::TranslationEngineKind::*;
        [Openai, Anthropic, BaiduGeneral, BaiduLlm, Tencent]
            .into_iter()
            .map(|k| (k.storage_key().to_string(), tr::build_engine(k, &s).is_some()))
            .collect()
    })
    .await
}

/// 整轨翻译:取当前播放条目的某条字幕流 → 翻译 → 落 SRT → 挂给 mpv。
/// 返回落盘的 SRT 路径。secondary=true 挂成次字幕(原文在下,译文在上)。
#[tauri::command]
async fn translate_subtitle(
    state: State<'_, AppState>,
    item_id: String,
    media_source_id: String,
    index: i64,
    delivery_url: Option<String>,
    source_lang: Option<String>,
    secondary: Option<bool>,
) -> Result<String, String> {
    let settings = tr::TranslationSettings::load();
    let engine = tr::active_engine(&settings)
        .ok_or("当前翻译引擎还没配好(缺 API Key 或地址),先去设置里填")?;
    let s = session_of(&state)?;
    // 走当前生效线路 —— 用户切了线路,字幕也得跟着走。
    let candidates = tr::subtitle_url_candidates(
        &s.server,
        Some(&s.token),
        &item_id,
        &media_source_id,
        index,
        delivery_url.as_deref(),
        None,
    );
    let seed = format!("{}:{item_id}:{media_source_id}:{index}", s.server);
    let path = tr::translate_subtitle_url(
        &candidates,
        engine,
        source_lang.as_deref().unwrap_or(tr::lang::AUTO),
        &settings.target_lang,
        settings.layout,
        Some(&s.token),
        &seed,
        None,
    )
    .await?;
    // 翻完直接挂上 —— 只返回路径不挂载,那就是「摆了个按钮不接线」。
    {
        let guard = state.player.lock().unwrap();
        let p = guard.as_ref().ok_or("播放器未就绪")?;
        if secondary.unwrap_or(false) {
            p.add_secondary_sub(&path, "翻译字幕")?;
        } else {
            p.add_subtitle(&path, "翻译字幕");
        }
    }
    Ok(path)
}

// ---------- Whisper 离线转录 ----------
#[derive(serde::Serialize)]
struct WhisperModelInfo {
    key: String,
    display_name: String,
    size_label: String,
    downloaded: bool,
    downloaded_bytes: u64,
}

const WHISPER_MODELS: [tr::WhisperModel; 4] = {
    use tr::WhisperModel::*;
    [Tiny, Base, Medium, Large]
};

/// key → 模型。`from_key` 对无效值静默回落默认档,故先白名单校验。
fn whisper_model_of(key: &str) -> Result<tr::WhisperModel, String> {
    WHISPER_MODELS
        .into_iter()
        .find(|m| m.storage_key() == key)
        .ok_or_else(|| format!("未知的 Whisper 模型:{key}"))
}

#[tauri::command]
async fn whisper_models() -> Vec<WhisperModelInfo> {
    blocking(|| {
        WHISPER_MODELS
            .into_iter()
            .map(|m| WhisperModelInfo {
                key: m.storage_key().to_string(),
                display_name: m.display_name().to_string(),
                size_label: m.size_label().to_string(),
                downloaded: tr::whisper::is_downloaded(m),
                downloaded_bytes: tr::whisper::downloaded_size(m),
            })
            .collect()
    })
    .await
}

/// 模型下载(1-3GB)。不报进度用户会以为卡死。
/// 注意 `WhisperModel::from_key` 无效值会**静默回落默认档**(core 的既有语义),
/// 所以这里先对着 storage_key 白名单校验 —— 别让前端传错字就悄悄下了另一个模型。
#[tauri::command]
async fn whisper_download(app: tauri::AppHandle, model: String) -> Result<String, String> {
    use tauri::Emitter;
    let m = whisper_model_of(&model)?;
    let mirror = tr::TranslationSettings::load().whisper_mirror;
    let progress: tr::whisper::DownloadProgress = {
        let app = app.clone();
        Arc::new(move |done: u64, total: u64, pct: f64| {
            let _ = app.emit("whisper-download", (done, total, pct));
        })
    };
    tr::whisper::download_model(m, &mirror, None, Some(progress))
        .await
        .map(|p| p.to_string_lossy().into_owned())
}

#[tauri::command]
fn whisper_delete(model: String) -> Result<(), String> {
    tr::whisper::delete_model(whisper_model_of(&model)?)
}

/// Whisper/ffmpeg 可执行文件是否就位(设置页据此决定能不能开转录)。
#[derive(serde::Serialize)]
struct WhisperDeps {
    whisper: Option<String>,
    ffmpeg: Option<String>,
}

#[tauri::command]
async fn whisper_deps() -> WhisperDeps {
    /* ★★ 这是「每次打开字幕翻译都卡」的元凶(用户 2026-07-15 报)。
       resolve_whisper/resolve_ffmpeg 在前面几步都落空时会走到 runs_ok,
       而 runs_ok 用 `Command::status()` **同步等子进程退出** —— 最多 4 次进程创建。

       Tauri 的**非 async 命令默认在主线程执行**,于是这 4 次 spawn 全程冻 UI。
       两道一起上:
         1) 这里 async + spawn_blocking → 挪出主线程,首次打开也不冻;
         2) runs_ok 自己按 exe 名缓存 → 第二次打开根本不 spawn(见那边的正确性论证)。 */
    blocking(|| {
        let s = tr::TranslationSettings::load();
        WhisperDeps {
            whisper: tr::whisper::resolve_whisper(&s.whisper_binary),
            ffmpeg: tr::whisper::resolve_ffmpeg(&s.ffmpeg_path),
        }
    })
    .await
}

/// 自动下载 ffmpeg(Win/macOS)。Linux 是 .tar.xz,core 解不了 —— 会返回明确错误让用户装包管理器。
#[tauri::command]
async fn whisper_download_ffmpeg(app: tauri::AppHandle) -> Result<String, String> {
    use tauri::Emitter;
    let progress: tr::whisper::DownloadProgress = Arc::new(move |done: u64, total: u64, pct: f64| {
        let _ = app.emit("ffmpeg-download", (done, total, pct));
    });
    tr::whisper::download_ffmpeg(Some(progress)).await
}

/// 截图到图片文件,返回落盘路径。dir 为空则落到 图片/LinPlayer。
#[tauri::command]
fn screenshot(state: State<'_, AppState>, dir: Option<String>) -> Result<String, String> {
    // 调用方没指定 → 用用户在设置页选的目录(没设才回落系统图片文件夹)。
    // 早先这里直接回落 picture_dir(),等于把设置项架空 —— 前端 screenshot() 从来不传 dir。
    let base = match dir.filter(|d| !d.trim().is_empty()) {
        Some(d) => std::path::PathBuf::from(d),
        None => resolve_screenshot_dir(state.config.lock().unwrap().prefs.screenshot_dir.clone()),
    };
    std::fs::create_dir_all(&base).map_err(|e| format!("建截图目录失败: {e}"))?;
    // 文件名用播放位置,避免同一片子连拍互相覆盖(不引 chrono,时间戳够用)。
    let guard = state.player.lock().unwrap();
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

/* ============================================================
   数据目录 —— 让"软件把东西放哪了"这件事在 UI 上可见
   ============================================================ */

/// 数据根 + 各子目录的真实绝对路径,直接给设置页显示。
/// 存在的意义就是**别让用户猜**:重构前数据散在 6 个根里,UI 里一个字都没提过。
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
    /// Portable / Overridden / SystemFallback。UI 据此解释"为什么在这个位置"——
    /// SystemFallback 意味着数据**没能**留在包里,必须显眼告警,不能装没事。
    kind: linplayer_core::paths::RootKind,
    /// exe 所在目录。UI 用它说明"包在哪儿"。
    exe_dir: String,
}

/// 弹系统原生「选择文件夹」对话框。返回 `None` = 用户取消(不是错误,别弹提示)。
///
/// 包成我们自己的命令而不是让前端直接调插件:这样既不用装 npm 包,也不用往 capabilities
/// 里放 dialog 权限(那是给前端直连插件命令用的)。`start` 是初始定位目录,可空。
#[tauri::command]
async fn pick_directory(app: tauri::AppHandle, start: Option<String>) -> Result<Option<String>, String> {
    use tauri_plugin_dialog::DialogExt;
    let (tx, rx) = tokio::sync::oneshot::channel();
    let mut b = app.dialog().file();
    // 定位到当前值,省得用户每次从头翻。路径不存在时插件会自行忽略。
    if let Some(s) = start.filter(|s| !s.trim().is_empty()) {
        b = b.set_directory(s);
    }
    b.pick_folder(move |p| {
        let _ = tx.send(p);
    });
    let picked = rx.await.map_err(|_| "选择目录被中断".to_string())?;
    Ok(picked.map(|p| p.to_string()))
}

/// 原生文件选择器(外部播放器可执行文件用)。取消返回 None。
#[tauri::command]
async fn pick_file(
    app: tauri::AppHandle,
    start: Option<String>,
    filter_name: Option<String>,
    extensions: Option<Vec<String>>,
) -> Result<Option<String>, String> {
    use tauri_plugin_dialog::DialogExt;
    let (tx, rx) = tokio::sync::oneshot::channel();
    let mut b = app.dialog().file();
    // 定位到当前值所在目录(start 传的是**文件**路径,得取它的父目录)。
    if let Some(s) = start.filter(|s| !s.trim().is_empty()) {
        if let Some(parent) = std::path::Path::new(&s).parent() {
            b = b.set_directory(parent);
        }
    }
    if let (Some(name), Some(exts)) = (filter_name, extensions) {
        let refs: Vec<&str> = exts.iter().map(|s| s.as_str()).collect();
        b = b.add_filter(name, &refs);
    }
    b.pick_file(move |p| {
        let _ = tx.send(p);
    });
    let picked = rx.await.map_err(|_| "选择文件被中断".to_string())?;
    Ok(picked.map(|p| p.to_string()))
}

/// 截图目录设置。`dir` 为空 = 用默认(系统图片文件夹/LinPlayer);`effective` 是实际会用的路径。
#[derive(serde::Serialize)]
struct ScreenshotDir {
    dir: Option<String>,
    effective: String,
}

#[tauri::command]
fn get_screenshot_dir(state: State<'_, AppState>) -> ScreenshotDir {
    let dir = state.config.lock().unwrap().prefs.screenshot_dir.clone();
    ScreenshotDir {
        effective: resolve_screenshot_dir(dir.clone()).to_string_lossy().into_owned(),
        dir,
    }
}

/// 设截图目录。空串/None = 恢复默认。**当场建一次目录验证可写** ——
/// 存下一个写不进去的路径,用户要到按下截图键才发现,那时提示离设置页已经很远了。
#[tauri::command]
fn set_screenshot_dir(state: State<'_, AppState>, dir: Option<String>) -> Result<ScreenshotDir, String> {
    let dir = dir.map(|d| d.trim().to_string()).filter(|d| !d.is_empty());
    if let Some(d) = &dir {
        let p = std::path::Path::new(d);
        if !p.is_absolute() {
            return Err("请填绝对路径(如 D:\\Shots)".into());
        }
        std::fs::create_dir_all(p).map_err(|e| format!("这个目录建不出来/写不进去: {e}"))?;
    }
    let mut cfg = state.config.lock().unwrap();
    cfg.prefs.screenshot_dir = dir.clone();
    cfg.save();
    Ok(ScreenshotDir {
        effective: resolve_screenshot_dir(dir.clone()).to_string_lossy().into_owned(),
        dir,
    })
}

/// 截图落点:显式参数 > 用户设置 > 系统图片文件夹/LinPlayer。
///
/// 默认**故意在包外**:截图是用户要拿去用的东西,塞进 userdata/ 反而难找。
/// 这跟"绿色包不留残留"不冲突 —— 它只在用户主动截图时才产生,且位置就是他自己选的。
fn resolve_screenshot_dir(configured: Option<String>) -> std::path::PathBuf {
    configured
        .map(std::path::PathBuf::from)
        .unwrap_or_else(|| {
            dirs::picture_dir()
                .unwrap_or_else(|| std::path::PathBuf::from("."))
                .join("LinPlayer")
        })
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
        /* 内存层必须一起清:只删磁盘的话内存里那份还在继续供图,
           用户看着占用变 0、封面却还是旧的 —— 那不叫清理,叫骗人。 */
        linplayer_core::image_cache::mem_clear();
        Ok(())
    })
    .await
    .map_err(|e| format!("清理缓存失败: {e}"))?
}

/// 在系统文件管理器里打开数据目录。
#[tauri::command]
fn open_data_dir(app: tauri::AppHandle, sub: Option<String>) -> Result<(), String> {
    use tauri_plugin_opener::OpenerExt;
    let p = match sub.as_deref() {
        Some("logs") => linplayer_core::paths::logs_dir(),
        Some("downloads") => linplayer_core::paths::downloads_dir(),
        _ => linplayer_core::paths::root(),
    };
    app.opener()
        .open_path(p.to_string_lossy(), None::<&str>)
        .map_err(|e| format!("打开目录失败: {e}"))
}

/// 超分档位清单 `(id, 显示名, 滤镜家族)`。第三个字段是家族名(Anime4K/FSR/NVIDIA),UI 按它分三组。
#[tauri::command]
fn shader_levels() -> Vec<(&'static str, &'static str, &'static str)> {
    shaders::levels()
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

/// 应用超分档位。挂载后**双重回读**:glsl-shaders 校验挂没挂上,尺寸校验会不会真跑
/// (见 [[superres-and-toast]]:旧 Flutter 桌面软件纹理根本不跑 glsl,必须回读校验)。
#[tauri::command]
fn set_shader_level(state: State<'_, AppState>, level: String) -> Result<ShaderApplied, String> {
    // .glsl 是 include_str! 编进二进制、首次用时落盘的 —— 丢了能重生成,归 cache/。
    let dir = linplayer_core::paths::cache_dir("shaders");
    let paths = shaders::shader_paths(&dir, &level)?;
    let guard = state.player.lock().unwrap();
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
fn mpv_get(state: State<'_, AppState>, name: String) -> Result<Option<String>, String> {
    let guard = state.player.lock().unwrap();
    Ok(guard.as_ref().ok_or("播放器未就绪")?.get_property(&name))
}

#[tauri::command]
fn mpv_set(state: State<'_, AppState>, name: String, value: String) -> Result<(), String> {
    with_player!(state, p => p.set_property(&name, &value))
}

#[tauri::command]
fn mpv_command(state: State<'_, AppState>, args: Vec<String>) -> Result<(), String> {
    let guard = state.player.lock().unwrap();
    guard.as_ref().ok_or("播放器未就绪")?.command(&args)
}

/// 按已存偏好自动选轨(起播后前端调一次)。返回实际选中的 (aid, sid)。
#[tauri::command]
fn apply_prefs(state: State<'_, AppState>) -> Result<(Option<String>, Option<String>), String> {
    let prefs = state.config.lock().unwrap().prefs.clone();
    let guard = state.player.lock().unwrap();
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

// ---------- 应用内更新 ----------

#[derive(serde::Serialize)]
struct UpdateSettings {
    channel: linplayer_core::update::UpdateChannel,
    auto_check: bool,
    /// 当前版本(tauri.conf.json 的 version,由 build.rs 注入)。**比较用它**,
    /// 不是 http::APP_VERSION —— 后者读 Cargo.toml,和发行包版本没有同步机制。
    current_version: String,
    /// 能不能就地自更新。绿色包被解压到 Program Files 这类只写不了的地方时为 false,
    /// 这时只能引导用户去网页下载。**先问再做** —— 覆盖到一半才发现没权限,
    /// 用户手上就是个装不上也回不去的半吊子。
    can_self_update: bool,
}

#[tauri::command]
fn get_update_settings(state: State<'_, AppState>) -> UpdateSettings {
    let cfg = state.config.lock().unwrap();
    UpdateSettings {
        channel: cfg.prefs.update_channel,
        auto_check: cfg.prefs.update_auto_check,
        current_version: env!("LP_VERSION").to_string(),
        can_self_update: !matches!(
            linplayer_core::paths::root_kind(),
            linplayer_core::paths::RootKind::SystemFallback
        ),
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
    // 存一份:download_and_apply 直接用它,免得让前端把 assets 清单原样传回来。
    *state.pending_update.lock().unwrap() = found.clone();
    Ok(found)
}

/// 下载 + 校验 + 覆盖 + 重启。进度走 `update-download` 事件 `(已下载, 总大小)`。
/// 成功后**本进程会退出** —— 覆盖动作由复制到 temp 的 applier 副本完成。
#[tauri::command]
async fn download_and_apply_update(
    app: tauri::AppHandle,
    state: State<'_, AppState>,
) -> Result<(), String> {
    use tauri::Emitter;

    let info = state
        .pending_update
        .lock()
        .unwrap()
        .clone()
        .ok_or("没有待安装的更新,请先检查更新")?;

    // 先拦一道:没写权限就别开始下 200MB(用户等半天才发现装不上)。
    if matches!(
        linplayer_core::paths::root_kind(),
        linplayer_core::paths::RootKind::SystemFallback
    ) {
        return Err("安装目录不可写(装在 Program Files?),请手动下载覆盖".into());
    }

    let dir = linplayer_core::paths::temp_dir();
    let zip = {
        let app = app.clone();
        linplayer_core::update::download(&info, &dir, move |done, total| {
            let _ = app.emit("update-download", (done, total));
        })
        .await?
    };

    updater::spawn_applier(&zip)?;
    // applier 起来后会等我们放开 exe/dll 的锁。这里必须真退出,不能只关窗口。
    app.exit(0);
    Ok(())
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

/// 弹弹Play 官方源配置(编译期加密注入凭据齐才有);无凭据返回 None。
/// 官方弹弹Play 源的 id。★ 是 "official",不是 Dart 那边的 "dandanplay" ——
/// 自动挂弹幕的 episodeId 连号快路径要按它认源,写错了不报错,只是快路径永远不命中。
const DANDAN_OFFICIAL_SOURCE_ID: &str = "official";

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

fn require_danmaku_sources(state: &State<'_, AppState>) -> Result<Vec<DanmakuSourceConfig>, String> {
    let v = danmaku_sources(state, true);
    if v.is_empty() {
        return Err("未配置弹幕服务器(且无官方弹弹Play凭据)".into());
    }
    Ok(v)
}

/// 自建弹幕源列表(设置页增删改查)。
#[tauri::command]
fn get_danmaku_config(state: State<'_, AppState>) -> Vec<DanmakuServer> {
    state.config.lock().unwrap().danmaku_sources.clone()
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
    let sources = require_danmaku_sources(&state)?;
    Ok(danmaku::match_all(&state.http, &sources, &input).await)
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
    let sources = require_danmaku_sources(&state)?;
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

    let candidates = danmaku::match_all(&state.http, &sources, &input).await;
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


// ---------- 文件浏览型源命令(网盘/追番)----------
fn source_backend(
    state: &State<'_, AppState>,
    kind: &SourceKind,
) -> Result<Arc<dyn MediaSourceBackend>, String> {
    // 插件源:**现建现用,不进静态表**。PluginSourceBackend 是无状态的
    // (只有 plugin_id + src_id + Weak),建一个的成本可忽略;而往这张会被播放链路读的
    // 表里动态增删要引入锁和生命周期同步,是白挨的复杂度。
    // 插件被禁用时自然失效 —— 贡献点注册表里查不到,调用直接报错。
    if let Some((plugin_id, src_id)) = kind.as_plugin() {
        let mgr = plugins_mgr(state)?;
        return Ok(Arc::new(PluginSourceBackend::new(
            plugin_id,
            src_id,
            Arc::downgrade(&mgr),
        )));
    }
    state
        .source_backends
        .get(kind)
        .cloned()
        .ok_or_else(|| "该源类型暂未接入".to_string())
}

#[tauri::command]
async fn source_login(
    state: State<'_, AppState>,
    kind: SourceKind,
    base_url: String,
    username: String,
    password: String,
    cookie: Option<String>,
    // 令牌系源用它带 refresh_token(也可走 cookie)与可选的 oplist 地址/driver 覆盖。
    // additive:老调用不传即空,行为不变。
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

    // ★ 插件源:**先授权再验证**。
    //
    // 下面那次 list_dir 是插件的第一次出网,而 `$sourceServer` 白名单令牌要展开成
    // 用户刚填的这个地址 —— 授权原本写在整个函数末尾(账号落盘之后),于是验证请求
    // 撞上「域名不在白名单内」,**任何需要 $sourceServer 的插件数据源都永远添加不上**。
    // 也就是「用户自己填地址」的那一整类,正是插件数据源最主要的形态。
    //
    // P1 的端到端演示插件没撞上,因为它的 listDir 返回写死数据、一个请求都不发。
    grant_plugin_source_host(&state, &kind, &server.base_url);

    // 列根目录以验证登录可用
    if let Err(e) = backend.list_dir(&state.http, &server, None).await {
        // 验证没过就不该留下授权 —— 按已落盘的账号重算一遍,把刚才那条临时的撤掉。
        sync_plugin_source_grants(&state);
        return Err(e.message);
    }
    // 落盘:源和 Emby 共用同一张账号表 —— 重启免登 + 多源并存全靠这一步。
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
    // 插件源:把用户刚填的地址喂进 `$sourceServer` 展开表,否则插件发不出请求。
    sync_plugin_source_grants(&state);
    Ok(())
}

/// 扫码登录:出码。返回二维码(data URI 或图 URL)+ 轮询上下文。
/// 只有扫码型源(百度/阿里/天翼189)支持;其余源用 source_login 表单登录。
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

/// 扫码登录:轮询一次。Confirmed 时返回的 credentials 由前端原样塞进 source_login 的 extra 落库。
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

/// 账密登录:手机号(或邮箱)+ 密码换取令牌。返回的 credentials 由前端塞进 source_login 落库。
/// 天翼189 / 移动云139 支持(账密是可稳做的手机号登录路径)。
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

/// 后端轮换出的新凭据落盘 + 更新内存里的活跃源。
///
/// 不做这件事的后果:阿里云盘/天翼189 的 refresh_token 是**一次性的**,刷新一次旧值当场作废。
/// 会话内因为有内存缓存看不出问题,一重启就拿着死 token 去刷 —— 表现为「用得好好的,
/// 重开就要重新授权」,而且不会报任何错。夸克扫码登录此前就欠着这一笔。
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

/// 源端全盘搜索。返回 Err("该源不支持搜索") 时前端退回当前目录本地过滤。
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

/// 解析源文件为直链并用 mpv 播放(带逐流 headers)。返回起播秒数。
#[tauri::command]
async fn source_play(
    state: State<'_, AppState>,
    entry_id: String,
    entry_name: String,
    resume_secs: f64,
    raw: Option<serde_json::Value>,
) -> Result<f64, String> {
    *state.scrobble_ctx.lock().unwrap() = None; // 源播放非 Emby,清 Trakt scrobble 上下文
    *state.wh_ctx.lock().unwrap() = None; // 同理清观看记录上下文,别把网盘进度记到上一部 Emby 片上
    let (kind, server) = state.source.lock().unwrap().clone().ok_or("未登录源")?;
    let backend = source_backend(&state, &kind)?;
    let entry = SourceEntry {
        id: entry_id,
        name: entry_name,
        is_dir: false,
        is_video: true,
        size: None,
        thumb_url: None,
        raw, // 透传源原始数据(ani-rss 外挂字幕等靠它)
    };
    let resolved = backend
        .resolve_play(&state.http, &server, &entry, None)
        .await
        .map_err(|e| e.message)?;
    persist_rotated(&state, &kind, &backend);
    poclog(&format!("SOURCE PLAY url={}", resolved.url));
    {
        let guard = state.player.lock().unwrap();
        let p = guard.as_ref().ok_or("播放器未就绪")?;
        let _ = p.take_error_eof(); // 清历史失效标志
        // 源播放没有 Emby 的 MediaStreams,判不出 DV → 按用户设的默认解码方式走。
        apply_playback_defaults(&state, p, false);
        p.load_with_headers(
            &resolved.url,
            resume_secs,
            &resolved.http_headers,
            resolved.user_agent_override.as_deref(),
        )?;
        p.set_pause(false);
        // 挂外挂字幕(URL 自鉴权的源,如 ani-rss ?s=token)
        for sub in &resolved.subtitles {
            p.add_subtitle(&sub.url, sub.title.as_deref().unwrap_or("字幕"));
        }
    }
    *state.playback.lock().unwrap() = None; // 网盘源不走 Emby 上报
    *state.source_play_entry.lock().unwrap() = Some((entry.id.clone(), entry.name.clone()));
    state.resign_count.store(0, Ordering::Relaxed);
    Ok(resume_secs)
}

// ---------- 夸克 TV 扫码登录 ----------
#[derive(serde::Serialize)]
struct QuarkScan {
    device_id: String,
    qr_data: String,
    query_token: String,
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
async fn source_watchdog(state: State<'_, AppState>, pos: f64) -> Result<bool, String> {
    // 无失效信号 or 非源播放 -> 什么都不做
    let errored = {
        let guard = state.player.lock().unwrap();
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
    let guard = state.player.lock().unwrap();
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

// ---------- Ani-RSS 管理命令 ----------
// 对齐 core `AniRssBackend` 的管理接口全集(Dart AniRssApi 的移植)。
//
// 为什么 Ani/Config 参数一律 serde_json::Value:core 注释已写明 —— Ani 55 字段、Config ~123
// 字段且随服务端版本增删,addAni/setAni/setConfig 都要把**整个对象**原样回传;在宿主层收窄成
// struct 会把未覆盖字段静默丢掉(用户的服务端设置直接被抹)。故 Value 进 Value 出,字段取舍
// 留给 UI(与 Dart 同构)。
type Json = serde_json::Value;

/// 取(ani-rss 后端 + 当前服务器)。当前活跃源不是 ani-rss 时直接报错 —— 管理接口只对 ani-rss 有意义。
fn anirss_ctx(state: &State<'_, AppState>) -> Result<(Arc<AniRssBackend>, SourceServer), String> {
    let (kind, server) = state.source.lock().unwrap().clone().ok_or("未登录源")?;
    if kind != SourceKind::anirss() {
        return Err("当前源不是 Ani-RSS".to_string());
    }
    Ok((state.anirss.clone(), server))
}

// ---- 浏览 / 详情 ----

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

// ---- 下载进度 ----

#[tauri::command]
async fn anirss_torrents_infos(state: State<'_, AppState>) -> Result<Json, String> {
    let (b, s) = anirss_ctx(&state)?;
    b.torrents_infos(&state.http, &s).await.map_err(|e| e.message)
}

// ---- 订阅管理 ----

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

// ---- 设置 / 关于 ----

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

// ---- 订阅预览 / 标题解析 / 刮削 / 下载位置 ----

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

// ---- BGM 评分 / 账号 ----

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

// ---- 多搜索源(添加订阅):Mikan / AniBT / AnimeGarden ----

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

// ---- 播放:字幕 ----

/// 取某文件的字幕。filename = PlayItem.filename 的 base64 原文(**勿再编码**)。
#[tauri::command]
async fn anirss_get_subtitles(state: State<'_, AppState>, filename: String) -> Result<Json, String> {
    let (b, s) = anirss_ctx(&state)?;
    b.get_subtitles(&state.http, &s, &filename).await.map_err(|e| e.message)
}

// ---- 诊断 / 日志 / 维护 ----

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

/// 为某台服务器开启 CF 优选反代,并**登记路由改写** —— 之后该服的 `active_line_url()`
/// 返回本地反代基址,Emby API / 封面图 / mpv 取流全部自动改走优选 IP。
/// 已开则热切换 IP(端口与本地基址不变,对进行中的会话无感)。
#[tauri::command]
async fn cf_proxy_enable(
    state: State<'_, AppState>,
    server_id: String,
    ip: String,
) -> Result<String, String> {
    // 已开 → 只热切 IP。注意别在持锁期间 await。
    let existing = {
        let m = state.cf_proxy.lock().unwrap();
        m.get(&server_id).map(|h| h.port)
    };
    if existing.is_some() {
        let handle = state.cf_proxy.lock().unwrap().remove(&server_id);
        if let Some(h) = handle {
            h.update_ip(ip).await;
            let url = cf::runtime::local_url_for(&server_id).unwrap_or_default();
            state.cf_proxy.lock().unwrap().insert(server_id, h);
            return Ok(url);
        }
    }

    let (upstream, allow_insecure) = {
        let cfg = state.config.lock().unwrap();
        let a = cfg.find(&server_id).ok_or("找不到该服务器")?;
        // 上游必须用 direct_line_url:用 active_line_url 会在反代已开时把反代自己当上游,
        // 打成 127.0.0.1 → 127.0.0.1 的自环。
        (a.direct_line_url().to_string(), a.allow_insecure_tls)
    };
    let (scheme, host, port) = cf::runtime::split_upstream(&upstream);
    let handle = linplayer_core::net::cf::start_proxy(scheme, host, port, ip, allow_insecure)
        .await
        .ok_or("CF 反代起服失败(IP 非法?)")?;
    let local = cf::runtime::local_base(&upstream, handle.port);
    cf::runtime::bind(&server_id, &local);
    state.cf_proxy.lock().unwrap().insert(server_id.clone(), handle);
    refresh_session_base(&state, &server_id);
    Ok(local)
}

/// 关闭某服的反代,撤销路由改写,恢复直连原线路。
#[tauri::command]
fn cf_proxy_disable(state: State<'_, AppState>, server_id: String) -> Result<(), String> {
    cf::runtime::unbind(&server_id);
    state.cf_proxy.lock().unwrap().remove(&server_id); // Drop 停服
    refresh_session_base(&state, &server_id);
    Ok(())
}

#[derive(serde::Serialize)]
struct CfProxyStatus {
    server_id: String,
    local_url: String,
    pinned_ip: String,
}

/// 当前所有生效的反代改写(设置页展示"哪台服在走优选、钉的哪个 IP")。
#[tauri::command]
async fn cf_proxy_status(state: State<'_, AppState>) -> Result<Vec<CfProxyStatus>, String> {
    let ports: Vec<(String, String)> = cf::runtime::all().into_iter().collect();
    let mut out = Vec::new();
    for (server_id, local_url) in ports {
        // pinned_ip 要 await,不能在持锁时取;先把句柄摘出来问完再放回。
        let handle = state.cf_proxy.lock().unwrap().remove(&server_id);
        let pinned_ip = match handle {
            Some(h) => {
                let ip = h.pinned_ip().await;
                state.cf_proxy.lock().unwrap().insert(server_id.clone(), h);
                ip
            }
            None => String::new(),
        };
        out.push(CfProxyStatus { server_id, local_url, pinned_ip });
    }
    Ok(out)
}

// ---------- 多线程下载命令 ----------
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
fn download_list(
    state: State<'_, AppState>,
) -> Vec<linplayer_core::download::DownloadItem> {
    state.download.list()
}

#[tauri::command]
fn download_pause(state: State<'_, AppState>, id: String) {
    state.download.pause(&id);
}

#[tauri::command]
fn download_resume(state: State<'_, AppState>, id: String) {
    state.download.resume(&id);
}

#[tauri::command]
fn download_remove(state: State<'_, AppState>, id: String) {
    state.download.remove(&id);
}

/// 批量清除已完成的下载记录(下载页「清除已完成」)。返回清掉的条数。
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

/// 多线程加载(预取代理)设置。threads 引擎内部 clamp 到 2~4。
/// `servers` = 开了这功能的账号 id(Account.server);空表 = 全关。
#[derive(serde::Serialize, serde::Deserialize)]
struct PrefetchSettings {
    servers: Vec<String>,
    threads: usize,
    cache_bytes: u64,
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

/// 播放器默认行为(设置页「播放器」区)。
///
/// 这一组 2026-07-19 之前只躺在前端 localStorage 里,**改了不影响播放**。现在
/// get/set 走核心配置,消费点在 `play()` / `play_local()` / `play_external()`。
/// 加字段时记得同步 `apply_playback_defaults` —— 存得下但没人读,就是又一次「假落地」。
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
    // 拒而不是夹:静默夹紧 = 用户以为设上了。同 set_prefetch_settings 的理由。
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
    // 外部播放器:给了路径就必须真的存在。存一个打不开的路径,等到起播时才炸,
    // 那时用户早忘了自己填过什么。
    let ext = settings.external_player.trim().to_string();
    if !ext.is_empty() && !std::path::Path::new(&ext).is_file() {
        return Err(format!("找不到外部播放器: {ext}"));
    }
    let mut cfg = state.config.lock().unwrap();
    cfg.prefs.hwdec = settings.hwdec;
    cfg.prefs.default_speed = settings.default_speed;
    cfg.prefs.skip_intro = settings.skip_intro;
    cfg.prefs.skip_outro = settings.skip_outro;
    cfg.prefs.preview_thumbs = settings.preview_thumbs;
    cfg.prefs.dolby_auto_sw = settings.dolby_auto_sw;
    cfg.prefs.external_player = ext;
    cfg.save();
    Ok(())
}

/* ---------- 自定义 mpv 配置(设置页「播放器 › mpv 配置」)----------

   存的就是 `<数据根>/data/mpv/mpv.conf` **这个文件本身**,不塞进 config.json ——
   它是要原样交给 libmpv 去解析的文本,在 JSON 里绕一圈只是多两轮转义,
   而且用户完全可以直接拿编辑器改那个文件(路径在界面上给了)。
   加载时机与风险见 crates/mpv 里 `user_config_dir` 上方的长注释。 */
#[derive(serde::Serialize)]
struct MpvConf {
    text: String,
    /// 文件绝对路径 —— 界面要显示它,用户才知道能直接拿编辑器改。
    path: String,
    /// 文件在不在(= 下次启动会不会真去加载它)。空内容 = 不建文件 = 出厂状态。
    active: bool,
}

fn mpv_conf_now() -> MpvConf {
    MpvConf {
        text: mpv::read_user_conf(),
        path: mpv::user_conf_path().to_string_lossy().into_owned(),
        active: mpv::user_conf_path().is_file(),
    }
}

#[tauri::command]
fn get_mpv_conf() -> MpvConf {
    mpv_conf_now()
}

#[tauri::command]
fn set_mpv_conf(text: String) -> Result<MpvConf, String> {
    mpv::write_user_conf(&text)?;
    Ok(mpv_conf_now())
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

#[tauri::command]
fn download_set_threads(state: State<'_, AppState>, threads: usize) {
    state.download.set_threads(threads);
}

/// 播放已下载完成的本地文件(下载页 ▶)。离线可用:不碰网络、不走 Emby 上报。
/// 返回起播秒数供前端定位进度条。
#[tauri::command]
fn play_local(state: State<'_, AppState>, id: String, resume_secs: f64) -> Result<f64, String> {
    let path = state.download.completed_path(&id).ok_or("该任务尚未下载完成")?;
    // 索引说完成了不代表文件还在(用户可能手动删了/挪走了)——放给 mpv 之前先确认。
    if !std::path::Path::new(&path).is_file() {
        return Err(format!("文件已不存在:{path}"));
    }
    poclog(&format!("PLAY LOCAL id={id} path={path}"));
    {
        let guard = state.player.lock().unwrap();
        let p = guard.as_ref().ok_or("播放器未就绪")?;
        let _ = p.take_error_eof();
        apply_playback_defaults(&state, p, false); // 本地文件同理:无服务端流信息
        p.load_at(&path, resume_secs)?;
        p.set_pause(false);
    }
    show_video(&state, true);
    *state.playback.lock().unwrap() = None; // 本地文件不走 Emby 上报
    *state.source_play_entry.lock().unwrap() = None; // 非源播放,停 302 看门狗
    *state.scrobble_ctx.lock().unwrap() = None;
    *state.wh_ctx.lock().unwrap() = None; // 本地文件无 Emby 条目,清观看记录上下文
    state.resign_count.store(0, Ordering::Relaxed);
    Ok(resume_secs)
}

// ---------- Trakt 同步命令 ----------
use linplayer_core::sync::trakt;

/// 设备码登录第一步:申请设备码(展示 verification_url + user_code 给用户浏览器授权)。
#[tauri::command]
async fn trakt_device_code() -> Result<trakt::TraktDeviceCode, String> {
    trakt::request_device_code().await
}

/// 轮询一次;授权成功则持久化账号。前端按 interval 反复调,直到非 pending/slowDown。
#[tauri::command]
async fn trakt_poll(
    state: State<'_, AppState>,
    device_code: String,
) -> Result<trakt::TraktPollResult, String> {
    let r = trakt::poll_once(&device_code).await;
    if let Some(acc) = &r.account {
        let mut cfg = state.config.lock().unwrap();
        cfg.sync_trakt = Some(acc.clone());
        cfg.save();
    }
    Ok(r)
}

/// 当前已连接的 Trakt 账号(None=未连接)。
#[tauri::command]
fn trakt_account(state: State<'_, AppState>) -> Option<linplayer_core::sync::SyncAccount> {
    state.config.lock().unwrap().sync_trakt.clone()
}

#[tauri::command]
fn trakt_logout(state: State<'_, AppState>) {
    let mut cfg = state.config.lock().unwrap();
    cfg.sync_trakt = None;
    cfg.save();
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

// ---------- Bangumi 同步命令 ----------
use linplayer_core::sync::bangumi;
use linplayer_core::sync::bangumi_matcher;

/// 播放看完(≥80%)自动标 Bangumi:反查 subject/episode → 收藏为「在看」→ 单集标「看过」。
/// 反查失败(非番剧/搜不到)静默跳过。更新单集前必须先收藏,否则未收藏的番更新会失败。
async fn mark_bangumi_watched(acc: &linplayer_core::sync::SyncAccount, info: &emby::ScrobbleInfo) {
    let matched = if info.media_type == "movie" {
        bangumi_matcher::resolve_movie(&info.title, info.original_title.as_deref(), info.air_date.as_deref()).await
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
        poclog(&format!("[Bangumi] 反查不到条目,跳过: {}", info.title));
        return;
    };
    /* 电影没有「在看」这个中间态,看完就是看过(2)。
       剧集先收藏成在看(3)—— 这是用户说的「在看不会加进来」;
       再标单集看过(2);若这是最后一集,把整个条目也推到看过(2)。
       顺序不能反:未收藏的条目直接更新单集会被 Bangumi 拒。 */
    if info.media_type == "movie" {
        let ok = bangumi::set_collection_type(acc, r.subject_id, 2).await;
        poclog(&format!("[Bangumi] 电影标记看过 subject={} -> {ok}", r.subject_id));
        return;
    }
    let ok = bangumi::set_collection_type(acc, r.subject_id, 3).await;
    poclog(&format!("[Bangumi] 收藏为在看 subject={} -> {ok}", r.subject_id));
    let ok = bangumi::update_episode_status(acc, r.subject_id, r.episode_id, 2).await;
    poclog(&format!("[Bangumi] 单集标看过 ep={} -> {ok}", r.episode_id));
    if r.is_last_episode {
        let ok = bangumi::set_collection_type(acc, r.subject_id, 2).await;
        poclog(&format!("[Bangumi] 最后一集,整部标看过 -> {ok}"));
    }
}

/// 判定「看完」的进度阈值(与 Trakt 的自动标记阈值一致)。
const WATCHED_PERCENT: f64 = 80.0;

/// 构造 Bangumi 授权页 URL(前端用浏览器打开,用户授权后粘贴 code 回来)。
#[tauri::command]
fn bangumi_authorize_url(redirect_uri: Option<String>) -> String {
    let uri = redirect_uri.unwrap_or_else(|| bangumi::DEFAULT_REDIRECT_URI.to_string());
    bangumi::build_authorize_url(&uri)
}

/// 用粘贴回来的授权码换令牌并持久化。
#[tauri::command]
async fn bangumi_exchange(
    state: State<'_, AppState>,
    code: String,
    redirect_uri: Option<String>,
) -> Result<linplayer_core::sync::SyncAccount, String> {
    let uri = redirect_uri.unwrap_or_else(|| bangumi::DEFAULT_REDIRECT_URI.to_string());
    let acc = bangumi::exchange_code(&code, &uri).await?;
    {
        let mut cfg = state.config.lock().unwrap();
        cfg.sync_bangumi = Some(acc.clone());
        cfg.save();
    }
    Ok(acc)
}

/// 用**个人 Access Token** 登录(https://next.bgm.tv/demo/access-token 自助生成)。
///
/// 为什么要这条路:授权码流的 code→token 那一跳必须经我们自己的 CF 代理注入 client_secret,
/// 代理挂了/共享密钥轮换,登录就整个失效且报错含糊。个人令牌直连 api.bgm.tv,不依赖代理。
/// 命令里先打一次 /v0/me 验真,不把废令牌写进配置。
#[tauri::command]
async fn bangumi_login_token(
    state: State<'_, AppState>,
    token: String,
) -> Result<linplayer_core::sync::SyncAccount, String> {
    let acc = bangumi::login_with_access_token(&token).await?;
    {
        let mut cfg = state.config.lock().unwrap();
        cfg.sync_bangumi = Some(acc.clone());
        cfg.save();
    }
    Ok(acc)
}

#[tauri::command]
fn bangumi_account(state: State<'_, AppState>) -> Option<linplayer_core::sync::SyncAccount> {
    state.config.lock().unwrap().sync_bangumi.clone()
}

#[tauri::command]
fn bangumi_logout(state: State<'_, AppState>) {
    let mut cfg = state.config.lock().unwrap();
    cfg.sync_bangumi = None;
    cfg.save();
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
    Ok(bangumi::set_collection_type(&acc, subject_id, type_).await)
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
    Ok(bangumi::update_episode_status(&acc, subject_id, episode_id, type_.unwrap_or(2)).await)
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

#[tauri::command]
async fn bangumi_calendar(
    state: State<'_, AppState>,
    only_mine: Option<bool>,
) -> Result<Vec<linplayer_core::sync::calendar::CalendarEntry>, String> {
    let only_mine = only_mine.unwrap_or(true);
    let acc = state.config.lock().unwrap().sync_bangumi.clone();
    // 未登录时:个性化「我追的」拉不了(空);通用放送表 /calendar 是公开端点,用匿名账号照拉
    // (用户 2026-07-16:不登录也要出正常每周放送表)。
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

// ---------- 排行榜命令 ----------
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

// ---------- 自定义代理命令 ----------
#[tauri::command]
fn get_proxy(state: State<'_, AppState>) -> linplayer_core::ProxyConfig {
    state.config.lock().unwrap().proxy.clone()
}

/// 保存代理配置并即时生效(新建的 HTTP 客户端全部带上;主 Emby 客户端下次重启完全生效)。
/// ponytail: state.http 是启动期单例,live 切换只覆盖新建客户端;彻底 live-rebuild 留待需要时。
#[tauri::command]
fn set_proxy(state: State<'_, AppState>, config: linplayer_core::ProxyConfig) -> Result<(), String> {
    http::set_proxy(config.proxy_url());
    {
        let mut cfg = state.config.lock().unwrap();
        cfg.proxy = config;
        cfg.save();
    }
    Ok(())
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

/// 用原生文件选择器挑一个 .ipk 装上。
///
/// 走 Rust 侧的 `tauri_plugin_dialog`(已在 `.plugin(tauri_plugin_dialog::init())` 注册),
/// **不加 `@tauri-apps/plugin-dialog` 前端依赖、不动 capabilities** —— 后者是本仓库
/// 已知的坑(窗口写操作漏放行导致全屏静默失效那次)。
/// 返回 None 表示用户取消。
#[tauri::command]
async fn plugin_pick_install(
    app: tauri::AppHandle,
    state: State<'_, AppState>,
) -> Result<Option<serde_json::Value>, String> {
    use tauri_plugin_dialog::DialogExt;
    let (tx, rx) = tokio::sync::oneshot::channel();
    app.dialog()
        .file()
        .add_filter("LinPlayer 插件", &["ipk", "zip"])
        .pick_file(move |p| {
            let _ = tx.send(p);
        });
    let picked = rx.await.map_err(|_| "文件选择器未返回".to_string())?;
    let Some(path) = picked else { return Ok(None) };
    let path = path.into_path().map_err(|e| format!("路径无效: {e}"))?;
    plugins_mgr(&state)?
        .install_ipk(&path.to_string_lossy())
        .map(Some)
}

/// 开发模式:挑一个**本地目录**直接挂上,不复制文件。改完存盘即可重载。
#[tauri::command]
async fn plugin_pick_dev_dir(
    app: tauri::AppHandle,
    state: State<'_, AppState>,
) -> Result<Option<serde_json::Value>, String> {
    use tauri_plugin_dialog::DialogExt;
    let (tx, rx) = tokio::sync::oneshot::channel();
    app.dialog().file().pick_folder(move |p| {
        let _ = tx.send(p);
    });
    let picked = rx.await.map_err(|_| "目录选择器未返回".to_string())?;
    let Some(path) = picked else { return Ok(None) };
    let path = path.into_path().map_err(|e| format!("路径无效: {e}"))?;
    plugins_mgr(&state)?
        .install_dev_dir(&path.to_string_lossy())
        .map(Some)
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

/// 把**进程级**的临时目录指进包里。
///
/// 为什么要动环境变量而不是逐个改自家 `temp_dir()` 调用:后者是白名单,漏一个就又往系统
/// `%TEMP%` 拉一坨,而且我们管不到第三方库和 ffmpeg/whisper 子进程 —— 它们只认 TEMP/TMP。
/// 改环境变量是**结构性**的:整个进程树的临时文件一次性全按进 userdata/temp。
///
/// ⚠️ 只能在 main 最前面调:`set_var` 在有别的线程跑时是 UB。
fn redirect_process_dirs() {
    /* ★ 这一句必须排在最前面:temp_dir() 会触发 paths::root() 的首次解析(以及挂在它上面的
       旧数据迁移),而迁移读的正是 dirs::{config,cache,data}_dir() —— 也就是下面要改的
       那批 XDG 变量。顺序反了,迁移就会去一个我们刚刚伪造出来的空目录里找旧数据,
       结果是「升级后账号全没了」且不报错。 */
    let t = linplayer_core::paths::temp_dir();
    for k in ["TEMP", "TMP", "TMPDIR"] {
        std::env::set_var(k, &t);
    }

    /* 这里**故意不劫持 XDG_{DATA,CACHE}_HOME**。曾经这么干过,理由是「WebKitGTK 没有
       data_directory」—— 那是个错误前提:该方法两端都有效(见建窗处的注释)。
       劫持 XDG 的代价是真的:它让整个进程的 dirs::* 跟着说谎,深链要写的 .desktop
       差点因此落进包内、桌面环境永远扫不到。Windows 那边也没有去动 %APPDATA%,
       两端保持同一个口径:只按住自家数据根,不改系统的用户目录语义。 */
}

/// Linux:强制走 X11(必要时经 XWayland)。**必须在 GTK 初始化之前**。
///
/// 不是偷懒,是协议层的硬约束:mpv 的合成方案要求我们自己摆放一个顶层视频窗口并把它
/// 压到主窗口下面,而 **Wayland 根本不提供「应用定位自己的顶层窗口」这种能力**,
/// mpv 的 `wid` 在 Wayland 上也不受支持。所以 Linux 端明确钉在 X11 语义上。
/// 已经显式指定过 GDK_BACKEND 的用户不覆盖 —— 那是他自己的选择,替他做主只会更难查。
#[cfg(target_os = "linux")]
fn force_x11_backend() {
    if std::env::var_os("GDK_BACKEND").is_none() {
        std::env::set_var("GDK_BACKEND", "x11");
    }
}

#[cfg_attr(mobile, tauri::mobile_entry_point)]
pub fn run() {
    /* mpv 提成共享 crate 后,它自己没有日志落点 —— 把桌面的接进去。
       不接的话它那些「静默失效」告警(shader 缓存没设上之类)会被丢掉。 */
    mpv::set_logger(poclog);

    /* ★ 必须在 Tauri 起任何线程/子进程**之前**:把进程的 TEMP 指进包里。
       set_var 在多线程下是 UB,这里是 main 的第一步,还没有别的线程。
       (旧数据迁移不在这儿调 —— 它挂在 paths::root() 首次调用上自己会跑,
        曾经是这里的一句显式调用,排在 AppConfig::load() 后面就会静默丢账号,见 paths::root() 注释。) */
    /* ★ 必须是**最最前面**一行。本次启动如果是「以 applier 身份跑」(下面那句
       redirect_process_dirs 会按 current_exe 推数据根,而 applier 跑在
       userdata/temp/ 下,推出来是错的),就干完覆盖活直接返回,别启动 App。 */
    if updater::run_applier_if_requested() {
        return;
    }
    // 上一次更新留下的 applier 副本(它自己删不掉运行中的自己)。
    updater::cleanup_stale_applier();

    redirect_process_dirs();
    // 同样要赶在任何线程/GTK 初始化之前(set_var 在多线程下是 UB)。
    #[cfg(target_os = "linux")]
    force_x11_backend();

    /* Sentry 紧跟其后:它会起自己的传输线程,所以**必须**排在 redirect_process_dirs() 之后
       (上面那条 set_var 要求当时还没有别的线程),但又要排在其余一切之前 —— 从这行往下
       任何一处 panic 才有人接得住。guard 绑在 run() 的栈上活到进程结束;
       写成 `let _ = ...` 会当场 drop 掉 client,之后崩溃全部静默丢弃。 */
    let _sentry = telemetry::init();

    // 每次启动重注册 linplayer://—— 绿色包用户挪了文件夹,老路径就是死的。
    // 它会在 HKCU 留一个键(删文件夹带不走),这是有意保留的:没有它深链就没法自动拉起本程序。
    register_deep_link_scheme();
    let config = AppConfig::load();
    // 先把代理写进全局,再建各 HTTP 客户端(含 Emby 主客户端/下载),使其启动即带代理。
    http::set_proxy(config.proxy.proxy_url());
    let http = http::emby_client();

    // 源后端注册表(长驻,持各自 token 缓存)。逐 Phase 增量接入更多源。
    let mut source_backends: HashMap<SourceKind, Arc<dyn MediaSourceBackend>> = HashMap::new();
    source_backends.insert(SourceKind::openlist(), Arc::new(OpenListBackend::new()));
    // ani-rss 建一次、两处引用同一实例:注册表里当 dyn 走浏览/播放,AppState.anirss 里当具体类型
    // 走管理接口。clone 只加引用计数(不复制 token_cache),故两条路共用同一份登录令牌。
    let anirss = Arc::new(AniRssBackend::new());
    source_backends.insert(SourceKind::anirss(), anirss.clone());
    source_backends.insert(SourceKind::feiniu(), Arc::new(FeiniuBackend::new()));
    source_backends.insert(SourceKind::quark(), Arc::new(QuarkBackend::new()));
    // ★ 这张表安卓侧(apps/android/src/lib.rs)有一份**独立的拷贝**。只加这边,
    //   安卓上的表现是「源加得进去、点进去报『该源类型暂未接入』」,而且编译全绿。
    source_backends.insert(SourceKind::stremio(), Arc::new(StremioBackend::new()));
    // 国内网盘(全部扫码/Cookie 登录,不依赖任何在线令牌中继 —— oplist 已作废):
    //   阿里=扫码→网页版 API + secp256k1 签名;百度=扫码→BDUSS Cookie;
    //   115=Cookie + 私有编解码;天翼189=扫码→会话签名;移动云139=粘贴 Authorization + mcloud-sign。
    source_backends.insert(SourceKind::aliyundrive(), Arc::new(AliyunDriveBackend::new()));
    source_backends.insert(SourceKind::baidu(), Arc::new(BaiduBackend::new()));
    source_backends.insert(SourceKind::pan115(), Arc::new(Pan115Backend::new()));
    source_backends.insert(SourceKind::pan189(), Arc::new(Pan189Backend::new()));
    source_backends.insert(SourceKind::pan139(), Arc::new(Pan139Backend::new()));

    // 有活跃账号 -> 用存盘凭据重建会话/源(重启免登)。
    // 活跃的是 Emby 就装 session,是浏览型源就装 source —— 两者互斥,别同时留着。
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

    // 下载目录:数据根下的 downloads/。旧实现放 exe 同级 —— 装进 Program Files 就写不动。
    let download = tauri::async_runtime::block_on(
        linplayer_core::download::DownloadManager::new(linplayer_core::paths::downloads_dir()),
    );

    // 清旧诊断日志(上次运行的,不是别人的)
    let _ = std::fs::remove_file(app_log_path());
    let _ = std::fs::remove_file(mpv::mpv_log_path());

    let builder = pluginassets::register(imgcache::register(tauri::Builder::default()));
    builder
        .plugin(tauri_plugin_opener::init())
        .plugin(tauri_plugin_dialog::init())
        .manage(AppState {
            http,
            config: Mutex::new(config),
            session: Mutex::new(session),
            player: Mutex::new(None),
            playback: Mutex::new(None),
            source_backends,
            anirss,
            source: Mutex::new(source),
            watch_history: linplayer_core::watch_history::WatchHistory::default(),
            series_tmdb: Mutex::new(HashMap::new()),
            wh_ctx: Mutex::new(None),
            source_play_entry: Mutex::new(None),
            resign_count: AtomicU32::new(0),
            prefetch: Mutex::new(None),
            cf_proxy: Mutex::new(HashMap::new()),
            account_status: Mutex::new(HashMap::new()),
            live_translate: Mutex::new(None),
            danmaku_anchors: Mutex::new(HashMap::new()),
            wh_done: Mutex::new(std::collections::HashSet::new()),
            download,
            scrobble_ctx: Mutex::new(None),
            plugins: OnceLock::new(),
            ui_pending: Mutex::new(HashMap::new()),
            ui_seq: AtomicU64::new(0),
            pending_update: Mutex::new(None),
        })
        .setup(|app| {
            /* 主窗口在这儿建而不是在 tauri.conf.json 里声明 —— 唯一的原因是 data_directory:
               不显式给它,WebView2 就会自己在 %LOCALAPPDATA%\<identifier>\EBWebView 建 profile
               (实测 126MB,还装着前端 localStorage),而我们是压缩包分发,数据必须全在包里。
               config 里的 dataDirectory 只吃相对路径且强制拼在 %LOCALAPPDATA% 下,够不到 exe 同级。
               尺寸/透明/无边框这些原本在 conf 里的属性一并搬来了,改窗口属性请改这里。 */
            let win_builder = tauri::WebviewWindowBuilder::new(
                app,
                "main",
                tauri::WebviewUrl::default(),
            )
            .title("LinPlayer")
            .inner_size(1180.0, 720.0)
            .min_inner_size(900.0, 560.0)
            .transparent(true)
            .decorations(false)
            /* data_directory 两端都有效,**不要给它加平台门**。
               Windows → WebView2 的 profile(不给就自己在 %LOCALAPPDATA% 建,实测 126MB)。
               Linux   → wry 用它构造 WebsiteDataManager 的 base_data/base_cache_directory
                        (wry-0.55 webkitgtk/web_context.rs;tauri-runtime-wry 拿它当 WebContext key)。
               曾经误以为这是 `#[cfg(windows)]` 方法而在 Linux 上绕道劫持 XDG_* —— 那不但多余,
               还会让整个进程的 dirs::* 跟着说谎(深链的 .desktop 差点因此写进包里)。
               核对过 tauri-2.11.5 的 webview_window.rs:1022,方法上没有任何 cfg。 */
            .data_directory(linplayer_core::paths::webview_dir());
            let window = win_builder.build()?;
            let parent = match hwnd_of(&window) {
                Ok(p) => {
                    poclog(&format!("hwnd OK parent={p}"));
                    Some(p)
                }
                Err(e) => {
                    poclog(&format!("hwnd ERR: {e}"));
                    None
                }
            };
            match Player::new() {
                Ok(p) => {
                    poclog(&format!("player init OK video_hwnd={}", p.video_hwnd));
                    *app.state::<AppState>().player.lock().unwrap() = Some(p);
                }
                Err(e) => poclog(&format!("player init ERR: {e}")),
            }
            if let Some(parent) = parent {
                let st = app.state::<AppState>();
                sync_video(&window, parent, &st);
                /* 视频窗默认藏着 —— 没在播片就不该有一块黑垫在 UI 底下(而且主窗一
                   最小化它就露在桌面上)。play/stop 负责开关,见 show_video。 */
                show_video(&st, false);
                /* ★ 把视频窗焊在主窗背面。原来只靠下面那三个 Tauri 事件重排 z 序,
                   而 Alt-Tab、点任务栏、别的窗口插进来、WebView2 自己动**都不产生**
                   那三个事件 —— 视频层于是「掉」到 UI 后面去了(用户 2026-07-26 报的)。
                   WM_WINDOWPOSCHANGED 是位置/尺寸/z 序任一变化都发的那条,钉住它
                   整类问题一次消掉,也不用起定时器轮询。 */
                let video = st.player.lock().unwrap().as_ref().map(|p| p.video_hwnd);
                if let Some(v) = video {
                    mpv::pin_overlay_below(v, parent);
                }
            }

            // 窗口移动/缩放/激活 -> 重新对齐视频窗口
            let app_handle = app.handle().clone();
            let win2 = window.clone();
            // 全屏进/出、拖拽缩放会连发多个 Resized,末帧几何要等窗口 settle 才准。
            // 立即同步一次(跟手)+ 代际防抖补一发延时同步 catch 最终尺寸/z 序 —— 否则
            // 退出全屏后 mpv 独立窗口可能仍停在全屏尺寸并压在上面,看着像「没退出去」
            // (用户 2026-07-16:全屏修好后又多了这个问题)。
            let settle_gen = std::sync::Arc::new(std::sync::atomic::AtomicU64::new(0));
            window.on_window_event(move |ev| {
                if matches!(
                    ev,
                    WindowEvent::Resized(_) | WindowEvent::Moved(_) | WindowEvent::Focused(true)
                ) {
                    let Some(parent) = parent else { return };
                    sync_video(&win2, parent, &app_handle.state::<AppState>());
                    // ponytail: 每个 resize 事件起一个短线程等 settle;只有末代那发真重同步,
                    // 拖拽连发的中间线程 220ms 后发现代际过期即退,不重复动窗口。
                    let gen = settle_gen.fetch_add(1, std::sync::atomic::Ordering::SeqCst) + 1;
                    let gen_arc = settle_gen.clone();
                    let ah = app_handle.clone();
                    let w3 = win2.clone();
                    std::thread::spawn(move || {
                        std::thread::sleep(std::time::Duration::from_millis(220));
                        if gen_arc.load(std::sync::atomic::Ordering::SeqCst) != gen {
                            return; // 又来了新事件,交给它那一发
                        }
                        let ah2 = ah.clone();
                        let _ = ah.run_on_main_thread(move || {
                            sync_video(&w3, parent, &ah2.state::<AppState>());
                        });
                    });
                }
            });

            /* 插件系统:host 持 AppHandle 落平台能力。
               基目录**不再用 app_config_dir()** —— 那是由 tauri.conf.json 的 identifier 推出来的
               (com.linplayer.poc),等于在 %APPDATA% 下又开了一个跟 LinPlayer 无关的根,
               而且改 identifier 就让已装插件静默失联。现在和其它数据一起进 data/plugins。 */
            let base = linplayer_core::paths::data_dir("plugins");
            let host = plugins_host::make_host(app.handle().clone());
            let mgr = PluginManager::new(base, host);
            let _ = app.state::<AppState>().plugins.set(mgr.clone());
            sync_plugin_source_grants(&app.state::<AppState>());
            tauri::async_runtime::spawn(async move { mgr.init().await });
            Ok(())
        })
        .invoke_handler(tauri::generate_handler![
            login,
            relogin,
            current_session,
            aggregate_search,
            aggregate_overview,
            set_active_server,
            views,
            list_items,
            list_items_page,
            get_filters,
            set_played,
            test_connection,
            list_collections,
            list_next_up,
            search,
            similar_items,
            icon_library,
            list_latest,
            list_resume,
            list_random,
            item_detail,
            series_seasons,
            season_episodes,
            item_media,
            list_favorites,
            set_favorite,
            is_admin,
            refresh_item,
            scan_libraries,
            list_accounts,
            remove_account,
            update_account,
            reorder_accounts,
            set_lines,
            set_active_line,
            sync_lines,
            probe_accounts,
            startup_deep_link,
            account_icon,
            set_account_icon_file,
            clear_account_icon,
            batch_parse,
            parse_deep_link,
            batch_add_servers,
            probe_lines,
            probe_line,
            current_source,
            play,
            report_progress,
            stop_playback,
            set_pause,
            seek,
            status,
            tracks,
            set_track,
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
            screenshot,
            data_paths,
            pick_directory,
            pick_file,
            get_screenshot_dir,
            set_screenshot_dir,
            cache_size,
            clear_cache,
            open_data_dir,
            shader_levels,
            set_shader_level,
            mpv_get,
            mpv_set,
            mpv_command,
            apply_prefs,
            validate_track_regex,
            set_track_regexes,
            get_prefs,
            set_prefs,
            get_update_settings,
            set_update_settings,
            check_update,
            download_and_apply_update,
            source_login,
            source_qr_start,
            source_qr_poll,
            source_password_login,
            source_list_dir,
            source_search,
            source_play,
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
            download_enqueue,
            download_list,
            download_pause,
            download_resume,
            download_remove,
            download_set_threads,
            download_clear_completed,
            get_prefetch_settings,
            set_prefetch_settings,
            get_playback_prefs,
            set_playback_prefs,
            get_mpv_conf,
            set_mpv_conf,
            chapter_info,
            play_external,
            play_local,
            watch_history_list,
            watch_history_scan_restore,
            watch_history_restore_candidate,
            get_writeback_settings,
            set_writeback_settings,
            watch_history_clear,
            watch_history_delete,
            get_cross_server_resume,
            set_cross_server_resume,
            get_translation_settings,
            set_translation_settings,
            translation_engine_status,
            translate_live_start,
            translate_live_stop,
            translate_subtitle,
            whisper_models,
            whisper_download,
            whisper_delete,
            whisper_deps,
            whisper_download_ffmpeg,
            get_proxy,
            set_proxy,
            set_detail_blur,
            ranking_categories,
            ranking_fetch,
            afdian_verify,
            afdian_sponsor_url,
            trakt_device_code,
            trakt_poll,
            trakt_account,
            trakt_logout,
            trakt_scrobble,
            trakt_calendar,
            bangumi_authorize_url,
            bangumi_exchange,
            bangumi_login_token,
            bangumi_account,
            bangumi_logout,
            bangumi_set_collection,
            bangumi_update_episode,
            bangumi_calendar,
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
            plugin_pick_install,
            plugin_pick_dev_dir,
            plugin_reload,
            plugin_dev_poll,
            plugin_permission_catalog,
            plugin_market_sources,
            plugin_market_add_source,
            plugin_market_remove_source,
            plugin_market_toggle_source,
            plugin_market_list,
            plugin_market_install
        ])
        .run(tauri::generate_context!())
        .expect("error while running tauri application");
}

/// 去掉 api.ts 里 `@shell-only:android` 标记之间的内容(含标记行本身)。
/// 桌面测试用它剪枝,安卓测试用同一对标记取出那一段 —— 解析规则必须一致,
/// 所以两边都只认这一对字符串。
#[cfg(test)]
fn strip_android_only(src: &str) -> String {
    let mut out = String::with_capacity(src.len());
    let mut rest = src;
    while let Some(i) = rest.find("@shell-only:android 开始") {
        out.push_str(&rest[..i]);
        let after = &rest[i..];
        match after.find("@shell-only:android 结束") {
            Some(j) => {
                // 跳过结束标记那一行的剩余部分
                let tail = &after[j..];
                rest = tail.find('\n').map(|k| &tail[k..]).unwrap_or("");
            }
            None => panic!("api.ts 里 @shell-only:android 只有开始没有结束 —— 标记必须成对"),
        }
    }
    out.push_str(rest);
    out
}

#[cfg(test)]
mod api_contract_tests {
    /// 前端 src/lib/api.ts 里 ACCOUNT_MUTATIONS 这个集合决定「改完账号表要不要广播给侧栏」。
    /// **名字写错 = 永远不广播 = 侧栏永远不刷新,而且不报任何错**(第一版我就写了个
    /// 根本不存在的 `add_source_server`,真名是 `source_login`,它还恰好是添加网盘的入口)。
    ///
    /// 这条测试把那个集合和本文件真实注册的命令表对一遍 —— TS 那边没有测试环境,
    /// 就让 Rust 来当这份跨语言契约的守门人。
    /// 播放页 OSD 上的「死开关」清单守卫。
    ///
    /// App.tsx 的 `soon(...)` = 点了只弹「核层暂无对应命令,待接」的占位开关。它的问题是
    /// **不报错、看着像做好了**:2026-07-19 用户发现「自动跳过片头/片尾」在设置页已接好、
    /// 播放页却还是两个写死 false 的 soon() —— 后端早就有了,前端没跟上
    /// (同 [[stale-waijie-lies]]:「待接」多半是谎)。
    ///
    /// 这条把占位项钉成一份白名单:接好了一个就从名单里删一个,新加占位必须显式登记。
    /// 名单和代码对不上就红,不用再靠人眼扫 UI。
    /// 源类型的**线上字符串**必须和 api.ts 的 `SourceKind` 联合完全对上。
    ///
    /// 2026-07-23 抓到:api.ts 里写的是首字母大写的 `"Emby" | "Openlist" | …`,
    /// 而线上格式一直是全小写。后果全部**静默**——
    ///   · `sourceLogin("Openlist", …)` 送出一个后端不认识的 kind;
    ///   · 服务器卡的类型徽标 `KIND_LABEL[a.source_kind]` 恒 undefined,六张卡全空白;
    ///   · `a.source_kind === "Anirss"` 恒 false,Ani-RSS 卡点进去落到网盘页。
    /// 两边都不报错,只是功能不对 —— 正是 [[stale-waijie-lies]] 那一类。
    /// TS 那边没有测试环境,就让 Rust 当这份跨语言契约的守门人。
    #[test]
    fn source_kind_wire_strings_match_the_frontend_union() {
        use linplayer_core::source::SourceKind;
        let ts = include_str!("../../../ui/shared/api.ts");
        let start = ts
            .find("export type SourceKind =")
            .expect("api.ts 里找不到 SourceKind 类型声明 —— 改名了就同步改这条测试");
        let block = &ts[start..start + ts[start..].find(';').expect("SourceKind 声明没有结尾分号")];

        let quoted: Vec<&str> = block
            .match_indices('"')
            .map(|(i, _)| i)
            .collect::<Vec<_>>()
            .chunks(2)
            .filter(|c| c.len() == 2)
            .map(|c| &block[c[0] + 1..c[1]])
            .collect();

        for kind in SourceKind::BUILTIN {
            assert!(
                quoted.contains(kind),
                "api.ts 的 SourceKind 联合里没有 {kind:?}(实际有 {quoted:?})—— \
                 少一个成员意味着前端拿它做的每一次比较都恒为 false、每一次 sourceLogin \
                 都会送出后端不认识的值,而且两边都不报错"
            );
        }
        // 反向:联合里不能出现后端根本不认的值(比如首字母大写的老写法)。
        for q in &quoted {
            assert!(
                SourceKind::new(*q).is_builtin(),
                "api.ts 的 SourceKind 里有个后端不认识的成员 {q:?}"
            );
        }
    }

    /// CI 里写死的产物路径,必须跟 tauri.conf.json 的 `mainBinaryName` 一致。
    ///
    /// d9a24706 加 mainBinaryName 把产物从 `app` 改名成 `LinPlayer` 时,**只同步了
    /// Windows job** —— Linux job 还在找 `target/release/app`,于是 Windows 全绿、
    /// Linux 在打包步骤炸「缺少产物 target/release/app」。这类「两处只改了一处」的漂移
    /// 光靠人眼扫 YAML 是拦不住的(本仓库已在 @shared 别名、SHADER_FAMILIES 上各栽过一次)。
    ///
    /// 注意 `.pdb` 跟的是 **crate 名**(app),不是 mainBinaryName —— 那是 MSVC 的规矩,
    /// 故意放行,别"顺手改整齐"了。
    #[test]
    fn ci_binary_paths_match_main_binary_name() {
        let conf: serde_json::Value =
            serde_json::from_str(include_str!("../tauri.conf.json")).unwrap();
        let name = conf["mainBinaryName"]
            .as_str()
            .expect("tauri.conf.json 缺 mainBinaryName");
        let yml = include_str!("../../../.github/workflows/build.yml");

        let mut checked = 0;
        for (i, _) in yml.match_indices("target/release/") {
            let rest = &yml[i + "target/release/".len()..];
            let tok: String = rest
                .chars()
                .take_while(|c| c.is_ascii_alphanumeric() || matches!(c, '.' | '_' | '-'))
                .collect();
            if tok.is_empty() || tok.ends_with(".pdb") || tok.ends_with(".dll") {
                continue; // pdb 跟 crate 名;dll 是第三方库,都不归 mainBinaryName 管
            }
            let stem = tok.strip_suffix(".exe").unwrap_or(&tok);
            assert_eq!(
                stem, name,
                "build.yml 里的 target/release/{tok} 和 tauri.conf.json 的 \
                 mainBinaryName={name:?} 对不上 —— 产物改名只改一半,另一个平台的 job 会\
                 在打包步骤炸「缺少产物」,而先跑完的那个平台是绿的"
            );
            checked += 1;
        }
        assert!(
            checked >= 2,
            "只扫到 {checked} 处 target/release/ 产物路径 —— Windows 和 Linux 两个 job 都该有,\
             扫不到说明 build.yml 换了写法,这条测试已经形同虚设"
        );
    }

    /// 打包脚本必须是**纯 ASCII**。
    ///
    /// 它自己的文件头就写着 "ASCII-only on purpose",但没有任何东西拦着人违反 ——
    /// 2026-07-19 重构时加了一行中文注释,而该文件**没有 BOM**:Windows PowerShell 5.1
    /// 把无 BOM 的 UTF-8 当 GBK 解,中文行的字节错位后**把行尾换行一起吃掉**,
    /// 紧跟其后的 `$root = Split-Path -Parent $PSScriptRoot` 整行被吸进注释里
    /// → `$repoRoot` 恒为 null → `npm run pack` 一上来就死在 Join-Path。
    ///
    /// 为什么拖到现在才发现:CI 是**自己组包**的(df89d598),不跑这个脚本 —— CI 全绿,
    /// 只有本地出包是坏的。所以这条守卫必须在 cargo test 里,不能指望构建流水线。
    /// 见 [[powershell-gbk-utf8-corruption]]。
    ///
    /// ⚠️ 这个脚本**被 .gitignore 排除、不在仓库里**(df89d598:CI 自己组包,不依赖它)。
    /// 所以这里**不能用 `include_str!`** —— 那是编译期读文件,在干净 clone / CI 上直接
    /// 「file not found」把 `cargo test --workspace` 编译都跑不起来(差点这么推上去)。
    /// 改成运行时读:本地有这个脚本的人受保护,没有的环境静默跳过。
    #[test]
    fn pack_script_stays_ascii_only() {
        let p = concat!(env!("CARGO_MANIFEST_DIR"), "/../../scripts/pack-portable.ps1");
        let Ok(s) = std::fs::read_to_string(p) else {
            return; // 脚本不在仓库里(CI/干净 clone),没什么可守的
        };
        if let Some((i, c)) = s.char_indices().find(|(_, c)| !c.is_ascii()) {
            let line = s[..i].lines().count();
            panic!(
                "scripts/pack-portable.ps1 第 {line} 行出现非 ASCII 字符 {c:?} —— \
                 该文件无 BOM,PS 5.1 会按 GBK 解码并吞掉紧随其后的那行代码(实测把 $root 的赋值\
                 整行吃掉,npm run pack 直接死)。注释请写英文,或给文件加 UTF-8 BOM 后再改这条测试。"
            );
        }
    }

    /// 超分面板按**家族**折叠,分组表写在 App.tsx 的 `SHADER_FAMILIES` 里,而档位的家族名
    /// 是核层 `shaders::levels()` 给的。两边对不上**不报错**:核层多一个家族而前端没登记,
    /// 那一整族档位就从面板里静默消失(2026-07-20 加「锐化」族时正是这个风险 ——
    /// 新族有 7 档,漏登记就等于白做)。反过来前端多写一个,则渲染出一个空标题行。
    ///
    /// TS 那边没有测试环境,继续让 Rust 当这份跨语言契约的守门人(同下面那条 soon() 白名单)。
    #[test]
    fn shader_family_groups_match_the_core_level_table() {
        let app_tsx = include_str!("../../../ui/desktop/App.tsx");
        let body = app_tsx
            .split_once("const SHADER_FAMILIES")
            .expect("App.tsx 里找不到 SHADER_FAMILIES —— 改名了就同步这条测试")
            .1;
        let body = body.split_once("];").expect("SHADER_FAMILIES 没有结尾 ];").0;
        // 每行形如 ["Sharpen", "标题", "说明"],取第一个带引号的串 = 家族键
        let mut ui: Vec<&str> = body
            .lines()
            .filter_map(|l| l.trim().strip_prefix("[\""))
            .filter_map(|r| r.split('"').next())
            .collect();
        ui.sort_unstable();
        assert!(!ui.is_empty(), "没从 SHADER_FAMILIES 解析出任何家族名 —— 先查它是不是换了写法");

        let mut core: Vec<&str> = crate::shaders::levels()
            .iter()
            .map(|(_, _, f)| *f)
            .filter(|f| !f.is_empty()) // "off" 档没有家族
            .collect();
        core.sort_unstable();
        core.dedup();

        assert_eq!(
            core, ui,
            "核层家族 {core:?} 与 App.tsx 的 SHADER_FAMILIES {ui:?} 对不上 —— \
             核层有而前端没有的那一族,它的所有档位会从超分面板里静默消失"
        );
    }

    #[test]
    fn player_panel_placeholder_switches_are_declared() {
        let app_tsx = include_str!("../../../ui/desktop/App.tsx");
        // 抠出所有 soon("xxx") 的参数
        let mut found: Vec<&str> = app_tsx
            .match_indices("soon(\"")
            .map(|(i, _)| {
                let rest = &app_tsx[i + 6..];
                rest.split('"').next().unwrap_or("")
            })
            .filter(|s| !s.is_empty())
            .collect();
        found.sort_unstable();
        found.dedup();

        /* 仍未实现、且**有意**留占位的项。删项时连这里一起删。
           画中画:mpv 渲染在独立顶层窗口里,PiP 要另起一个小窗 + 重新对齐合成,
           是独立一摊活,不在 2026-07-19 那批播放器默认值里。 */
        let allowed = ["画中画"];

        for f in &found {
            assert!(
                allowed.contains(f),
                "App.tsx 里「{f}」还是 soon() 占位开关(点了只弹「待接」)。\
                 要么把它接到真命令上,要么显式加进本测试的 allowed 名单说明为什么还留着。"
            );
        }
        for a in allowed {
            assert!(
                found.contains(&a),
                "allowed 里的「{a}」在 App.tsx 里已经没有 soon() 了 —— 接好了就把它从名单删掉,\
                 别留着一条永远为真的豁免(那这条测试就白写了)。"
            );
        }
    }

    /* `.page` 的入场动画里**不能有 transform**。
       带 transform 关键帧的动画会让元素永久成为 fixed 定位的包含块(Chromium 实测:
       动画播完、fill-mode 改成 backwards 也照样保持)。于是页面里所有 position:fixed 的
       浮层 —— 右键菜单、.toast —— 都不再相对视口,而是相对 .page,被侧栏宽度 + 标题栏
       高度整体顶偏。2026-07-19 用户报的「右键条目菜单飘到隔壁条目上」就是这个。
       肉眼看 .page 毫无异常(transform 终值 none),只能靠这条守着。
       反向验证:把 page-enter 的关键帧改回带 translateY,此测试立刻红。 */
    #[test]
    fn page_entrance_animation_must_not_use_transform() {
        let css = include_str!("../../../ui/desktop/theme/ui.css");
        // .page 用的是哪个动画?
        let page_rule = css
            .split(".page {")
            .nth(1)
            .and_then(|s| s.split('}').next())
            .expect("ui.css 里找不到 .page 规则");
        let anim = page_rule
            .lines()
            .find(|l| l.trim_start().starts_with("animation:"))
            .expect(".page 没有 animation —— 若是刻意去掉的,把本测试一并改掉");
        let name = anim
            .split(':')
            .nth(1)
            .and_then(|v| v.split_whitespace().next())
            .expect("解析不出 .page 的动画名");
        assert_ne!(
            name, "enter",
            ".page 不能复用 .enter 那个动画:它的关键帧带 translateY,会把 .page 变成 \
             fixed 的包含块,右键菜单和 toast 会整体偏移到错误位置。"
        );
        let frames = css
            .split(&format!("@keyframes {name}"))
            .nth(1)
            .and_then(|s| s.split('}').next())
            .unwrap_or_else(|| panic!("找不到 @keyframes {name}"));
        assert!(
            !frames.contains("transform"),
            "@keyframes {name} 里出现了 transform —— 这会让 .page 成为 fixed 包含块,\
             页面内所有右键菜单/toast 都会偏位。入场只用 opacity。实际内容:{frames}"
        );
    }

    /* 收款地址只能有一份 —— 前端不许出现任何硬编的爱发电 URL。
       2026-07-19 用户发现:CalendarPage.tsx 写死了 `https://afdian.com/a/linplayer`,
       而核层 AFDIAN_SPONSOR_URL 一直是正确的 `.../zzzwannasleep`。仓库里 README ×3、
       Dart 侧、Rust 核层**全都是对的**,只有这一个前端副本是错的,偏偏它是用户唯一
       会点到的那个按钮 —— 功能看着完全正常,赞助收益却全部流去了别人的页面。
       这类错误没有任何运行期信号,只能靠这条钉死。
       反向验证:在任意 .tsx/.ts 里写一个 afdian.com/a/xxx,此测试立刻红。 */
    #[test]
    fn frontend_never_hardcodes_a_sponsor_url() {
        let mut offenders = Vec::new();
        let mut walk = |dir: &std::path::Path| {
            let mut stack = vec![dir.to_path_buf()];
            while let Some(d) = stack.pop() {
                for e in std::fs::read_dir(&d).into_iter().flatten().flatten() {
                    let p = e.path();
                    if p.is_dir() {
                        stack.push(p);
                    } else if matches!(
                        p.extension().and_then(|x| x.to_str()),
                        Some("ts") | Some("tsx")
                    ) {
                        let s = std::fs::read_to_string(&p).unwrap_or_default();
                        for line in s.lines() {
                            // 注释里可以提(本次就留了说明这段历史的注释),代码里不行。
                            let t = line.trim_start();
                            let is_comment =
                                t.starts_with("//") || t.starts_with("*") || t.starts_with("/*");
                            if !is_comment && (line.contains("afdian.com") || line.contains("afdian.net"))
                            {
                                offenders.push(format!("{}: {}", p.display(), line.trim()));
                            }
                        }
                    }
                }
            }
        };
        walk(std::path::Path::new(concat!(env!("CARGO_MANIFEST_DIR"), "/../src")));
        assert!(
            offenders.is_empty(),
            "前端硬编了赞助/收款地址,必须改用 afdianSponsorUrl() 从核层取 —— \
             写错一个字母,钱就进别人口袋,而且没有任何报错。\n{}",
            offenders.join("\n")
        );
    }

    #[test]
    fn frontend_account_mutation_list_names_only_real_commands() {
        let api_ts = include_str!("../../../ui/shared/api.ts");
        let me = include_str!("lib.rs");

        // 抠出 ACCOUNT_MUTATIONS = new Set([...]) 里的字符串字面量
        let block = api_ts
            .split_once("const ACCOUNT_MUTATIONS = new Set([")
            .expect("api.ts 里找不到 ACCOUNT_MUTATIONS —— 契约变了,先更新本测试")
            .1
            .split_once("]);")
            .expect("ACCOUNT_MUTATIONS 没有收尾")
            .0;
        let listed: Vec<&str> = block
            .lines()
            .filter_map(|l| l.trim().strip_prefix('"'))
            .filter_map(|l| l.split('"').next())
            .filter(|s| !s.is_empty())
            .collect();
        assert!(listed.len() >= 10, "只抠出 {} 个命令,解析多半坏了", listed.len());

        // generate_handler! 的注册块
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

        for cmd in &listed {
            assert!(
                registered.contains(cmd),
                "api.ts 的 ACCOUNT_MUTATIONS 里有 `{cmd}`,但它不是已注册的 tauri 命令 —— \
                 这个名字永远不会命中,侧栏改完账号不会刷新,且不报错"
            );
        }
    }

    /* 前端 `invoke<T>("xxx")` 的每一个命令名都必须真的注册过。
       漏注册**不会编译报错**,只在用户点到那个功能时抛「command not found」——
       典型如新加了命令、写了 api.ts 绑定,却忘了往 generate_handler! 里加一行。
       (本次加 get/set_screenshot_dir 就正好踩在这条路上,故把守门人补齐。)
       反向验证:把 generate_handler! 里任意一行注释掉,此测试立刻红。 */
    #[test]
    fn every_frontend_invoke_names_a_registered_command() {
        /* ★ 先剪掉 `@shell-only:android` 区块:那几条命令**只有安卓壳注册**
           (手机控制台/遥控),桌面壳没有也不该有。它们不是没人把门 ——
           apps/android 里有一条对称的测试**只查**这个区块。
           两条测试合起来才覆盖全 api.ts,谁也别单独放宽。 */
        let api_ts = &crate::strip_android_only(include_str!("../../../ui/shared/api.ts"));
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

        /* 抠 invoke<...>("cmd") / invoke("cmd") 里的命令名。
           ★ 第一版是 `rest.find('(')` 再用「中间有没有 ; 或换行」判断是不是调用。
           泛型里出现**内联对象类型**时会踩空:
               invoke<{ info: X; version: string }>("plugin_market_install", …)
           泛型里的 `;` 让它直接 continue —— 那条命令就**悄悄不受这道闸门保护**了。
           2026-07-23 实测:我一次漏注册 7 条命令,它只报出 6 条,漏的正是这一条。
           现在按尖括号配对真跳泛型;`invoke` 之后第一个非空字符必须是 `<` 或 `(`,
           注释/import 里的 "invoke" 字样自然排除,也不再怕换行和分号。 */
        let mut names: Vec<&str> = Vec::new();
        for (i, _) in api_ts.match_indices("invoke") {
            let rest = &api_ts[i + "invoke".len()..];
            let Some((mut pos, mut c)) = rest.char_indices().find(|(_, c)| !c.is_whitespace())
            else {
                continue;
            };
            if c == '<' {
                let mut depth = 0i32;
                let mut closed = None;
                for (j, ch) in rest[pos..].char_indices() {
                    match ch {
                        '<' => depth += 1,
                        '>' => {
                            depth -= 1;
                            if depth == 0 {
                                closed = Some(pos + j + 1);
                                break;
                            }
                        }
                        _ => {}
                    }
                }
                let Some(after_generic) = closed else { continue };
                let Some((k, ch)) = rest[after_generic..]
                    .char_indices()
                    .find(|(_, ch)| !ch.is_whitespace())
                else {
                    continue;
                };
                pos = after_generic + k;
                c = ch;
            }
            if c != '(' {
                continue; // 不是调用
            }
            let after = rest[pos + 1..].trim_start();
            let Some(q) = after.strip_prefix('"') else { continue };
            let Some(end) = q.find('"') else { continue };
            names.push(&q[..end]);
        }
        names.sort_unstable();
        names.dedup();
        assert!(names.len() > 50, "只抠出 {} 个 invoke,解析多半坏了", names.len());

        let missing: Vec<&&str> = names
            .iter()
            .filter(|n| !registered.contains(*n))
            .collect();
        assert!(
            missing.is_empty(),
            "api.ts 调了这些命令,但它们没在 generate_handler! 注册 —— \
             用户点到就报 command not found:{missing:?}"
        );
    }
}
