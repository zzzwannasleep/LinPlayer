// 最小 libmpv 封装。桌面壳与安卓壳共用同一份。
//
// 渲染面在三端是同一个概念、不同的东西 —— mpv 的 `wid` 选项:
//   Windows / Linux:一个【独立顶层无边框窗口】,垫在【透明 Tauri 窗口】正下方并保持对齐。
//     顶层↔顶层 DWM/合成器能正常合成(子窗口无法进逐像素透明窗口,故不能用子窗口)。
//   Android:一个 SurfaceView 的 Surface(jobject),垫在透明 WebView 底下。
//     这里没有「对齐」这回事 —— SurfaceView 铺满 Activity,所以 sync 是空操作。
//
// 三端的差别被关进下面的 `mod overlay`,Player 本身不分平台。
#![allow(non_camel_case_types)]

use linplayer_core::media::Track;
use std::collections::HashMap;
use std::ffi::{c_char, c_int, c_void, CStr, CString};
use std::sync::atomic::{AtomicBool, AtomicU64, Ordering};
use std::sync::Arc;
use std::thread::JoinHandle;

// ---------- libmpv FFI ----------
#[repr(C)]
pub struct mpv_handle {
    _private: [u8; 0],
}

const MPV_FORMAT_DOUBLE: c_int = 5;

// 事件循环:检测直链失效(网盘短链过期)以触发 302 重签。
const MPV_EVENT_END_FILE: c_int = 7;
const MPV_END_FILE_REASON_ERROR: c_int = 4;
/// 正常播放到结尾。★ 原来只latch了 ERROR,自然放完**没有任何人在听** ——
/// Trakt/Bangumi 的「看完」全靠用户手动退出播放页才会触发,看完走人 = 什么都没同步。
const MPV_END_FILE_REASON_EOF: c_int = 0;
/// 文件真正打开完毕。★ `loadfile` 是**异步**命令 —— 它只把条目排进 playlist 就返回,
/// 此刻并没有「当前文件」。紧跟着发 `sub-add` 必然拿到 -12 error running command
/// (ctypes 实跑 libmpv v0.41 复现:立刻挂 → 字幕轨 0 条;等到本事件再挂 → 成功 1 条)。
/// 这就是「外挂字幕挂了等于没挂」的根因,而 `let _ =` 把错误吞得一干二净。
const MPV_EVENT_FILE_LOADED: c_int = 8;

#[repr(C)]
struct mpv_event {
    event_id: c_int,
    error: c_int,
    reply_userdata: u64,
    data: *mut c_void,
}
#[repr(C)]
struct mpv_event_end_file {
    reason: c_int,
    error: c_int,
}

/* ---------- libmpv 的绑定方式:两端故意不同 ----------

   Windows:链接期绑定。仓库自带 mpv.lib + libmpv-2.dll,版本由我们自己说了算。

   Linux:**运行时 dlopen,编译期不绑任何 soname**。
   必须这样,因为发行版之间 libmpv 的 soname 是分裂的:
     Ubuntu 22.04 → libmpv.so.1 (mpv 0.34)
     Ubuntu 24.04 / Fedora / Arch → libmpv.so.2 (mpv 0.36+)
   链接期绑哪个都是错的:绑 .so.1,新系统上一启动就是「找不到 libmpv.so.1」;
   绑 .so.2 就得换更新的构建机,glibc 随之抬到 2.39,又反过来砍掉一批老系统。
   两条路都堵死。dlopen 把这个选择推迟到运行时,一个包适配所有发行版,
   顺带让构建机连 libmpv-dev 都不用装。 */

#[cfg(windows)]
mod ffi {
    use super::{mpv_event, mpv_handle};
    use std::ffi::{c_char, c_int, c_void};

    #[link(name = "mpv")]
    extern "C" {
        pub fn mpv_create() -> *mut mpv_handle;
        pub fn mpv_initialize(ctx: *mut mpv_handle) -> c_int;
        pub fn mpv_terminate_destroy(ctx: *mut mpv_handle);
        pub fn mpv_set_option_string(ctx: *mut mpv_handle, name: *const c_char, data: *const c_char) -> c_int;
        pub fn mpv_set_property_string(ctx: *mut mpv_handle, name: *const c_char, data: *const c_char) -> c_int;
        pub fn mpv_get_property(ctx: *mut mpv_handle, name: *const c_char, format: c_int, data: *mut c_void) -> c_int;
        pub fn mpv_get_property_string(ctx: *mut mpv_handle, name: *const c_char) -> *mut c_char;
        pub fn mpv_free(data: *mut c_void);
        pub fn mpv_command(ctx: *mut mpv_handle, args: *const *const c_char) -> c_int;
        pub fn mpv_error_string(error: c_int) -> *const c_char;
        pub fn mpv_wait_event(ctx: *mut mpv_handle, timeout: f64) -> *mut mpv_event;
    }
}

#[cfg(not(windows))]
mod ffi {
    use super::{mpv_event, mpv_handle};
    use std::ffi::{c_char, c_int, c_void};
    use std::sync::OnceLock;

    type FnCreate = unsafe extern "C" fn() -> *mut mpv_handle;
    type FnCtx = unsafe extern "C" fn(*mut mpv_handle) -> c_int;
    type FnCtxVoid = unsafe extern "C" fn(*mut mpv_handle);
    type FnSetStr = unsafe extern "C" fn(*mut mpv_handle, *const c_char, *const c_char) -> c_int;
    type FnGetProp = unsafe extern "C" fn(*mut mpv_handle, *const c_char, c_int, *mut c_void) -> c_int;
    type FnGetPropStr = unsafe extern "C" fn(*mut mpv_handle, *const c_char) -> *mut c_char;
    type FnFree = unsafe extern "C" fn(*mut c_void);
    type FnCmd = unsafe extern "C" fn(*mut mpv_handle, *const *const c_char) -> c_int;
    type FnErrStr = unsafe extern "C" fn(c_int) -> *const c_char;
    type FnWaitEv = unsafe extern "C" fn(*mut mpv_handle, f64) -> *mut mpv_event;

    pub struct Api {
        // ★ 必须把 Library 留在结构里:它一 drop 就 dlclose,下面那堆函数指针会**全部悬垂**。
        _lib: libloading::Library,
        create: FnCreate,
        initialize: FnCtx,
        terminate_destroy: FnCtxVoid,
        set_option_string: FnSetStr,
        set_property_string: FnSetStr,
        get_property: FnGetProp,
        get_property_string: FnGetPropStr,
        free: FnFree,
        command: FnCmd,
        error_string: FnErrStr,
        wait_event: FnWaitEv,
    }

    /* 依次尝试的候选名。**顺序有意义**:新的在前 —— 同时装了两代库的系统上要用新的。
       不写绝对路径,交给 ld.so 按标准规则搜索 —— 其中包含 build.rs 写进 ELF 的 $ORIGIN,
       所以用户往程序目录丢一个 libmpv.so.2 依然会优先生效,和 Windows 那边
       「DLL 放 exe 同级」的语义对齐。 */
    const CANDIDATES: &[&str] = &["libmpv.so.2", "libmpv.so.1", "libmpv.so"];

    fn api() -> Option<&'static Api> {
        static API: OnceLock<Option<Api>> = OnceLock::new();
        API.get_or_init(|| unsafe {
            let lib = CANDIDATES
                .iter()
                .find_map(|n| libloading::Library::new(n).ok())?;
            // 先把符号全取出来再构造结构体:取符号会借用 lib,而 lib 随后要被移动进去。
            // 少一个符号就整体放弃 —— 半套 API 比没有更危险。
            let create = *lib.get::<FnCreate>(b"mpv_create\0").ok()?;
            let initialize = *lib.get::<FnCtx>(b"mpv_initialize\0").ok()?;
            let terminate_destroy = *lib.get::<FnCtxVoid>(b"mpv_terminate_destroy\0").ok()?;
            let set_option_string = *lib.get::<FnSetStr>(b"mpv_set_option_string\0").ok()?;
            let set_property_string = *lib.get::<FnSetStr>(b"mpv_set_property_string\0").ok()?;
            let get_property = *lib.get::<FnGetProp>(b"mpv_get_property\0").ok()?;
            let get_property_string = *lib.get::<FnGetPropStr>(b"mpv_get_property_string\0").ok()?;
            let free = *lib.get::<FnFree>(b"mpv_free\0").ok()?;
            let command = *lib.get::<FnCmd>(b"mpv_command\0").ok()?;
            let error_string = *lib.get::<FnErrStr>(b"mpv_error_string\0").ok()?;
            let wait_event = *lib.get::<FnWaitEv>(b"mpv_wait_event\0").ok()?;
            Some(Api {
                _lib: lib,
                create,
                initialize,
                terminate_destroy,
                set_option_string,
                set_property_string,
                get_property,
                get_property_string,
                free,
                command,
                error_string,
                wait_event,
            })
        })
        .as_ref()
    }

    /* 同名薄壳,签名与 Windows 那半逐字一致 —— 调用点因此完全不需要知道
       自己链的是哪种。库加载不了时全部安全降级:mpv_create 返回 null,
       Player::new 当场报「mpv_create 失败」,不会带着半死不活的状态往下走。 */
    pub unsafe fn mpv_create() -> *mut mpv_handle {
        match api() {
            Some(a) => (a.create)(),
            None => std::ptr::null_mut(),
        }
    }
    /// MPV_ERROR_GENERIC。库没加载时用它当统一失败码。
    const ERR_GENERIC: c_int = -20;
    pub unsafe fn mpv_initialize(ctx: *mut mpv_handle) -> c_int {
        api().map_or(ERR_GENERIC, |a| (a.initialize)(ctx))
    }
    pub unsafe fn mpv_terminate_destroy(ctx: *mut mpv_handle) {
        if let Some(a) = api() {
            (a.terminate_destroy)(ctx)
        }
    }
    pub unsafe fn mpv_set_option_string(ctx: *mut mpv_handle, n: *const c_char, d: *const c_char) -> c_int {
        api().map_or(ERR_GENERIC, |a| (a.set_option_string)(ctx, n, d))
    }
    pub unsafe fn mpv_set_property_string(ctx: *mut mpv_handle, n: *const c_char, d: *const c_char) -> c_int {
        api().map_or(ERR_GENERIC, |a| (a.set_property_string)(ctx, n, d))
    }
    pub unsafe fn mpv_get_property(ctx: *mut mpv_handle, n: *const c_char, f: c_int, d: *mut c_void) -> c_int {
        api().map_or(ERR_GENERIC, |a| (a.get_property)(ctx, n, f, d))
    }
    pub unsafe fn mpv_get_property_string(ctx: *mut mpv_handle, n: *const c_char) -> *mut c_char {
        match api() {
            Some(a) => (a.get_property_string)(ctx, n),
            None => std::ptr::null_mut(),
        }
    }
    pub unsafe fn mpv_free(d: *mut c_void) {
        if let Some(a) = api() {
            (a.free)(d)
        }
    }
    pub unsafe fn mpv_command(ctx: *mut mpv_handle, args: *const *const c_char) -> c_int {
        api().map_or(ERR_GENERIC, |a| (a.command)(ctx, args))
    }
    pub unsafe fn mpv_error_string(e: c_int) -> *const c_char {
        match api() {
            Some(a) => (a.error_string)(e),
            None => std::ptr::null(),
        }
    }
    pub unsafe fn mpv_wait_event(ctx: *mut mpv_handle, t: f64) -> *mut mpv_event {
        match api() {
            Some(a) => (a.wait_event)(ctx, t),
            None => std::ptr::null_mut(),
        }
    }
}

use ffi::*;

fn err_str(code: c_int) -> String {
    unsafe {
        let p = mpv_error_string(code);
        if p.is_null() { format!("code {code}") } else { CStr::from_ptr(p).to_string_lossy().into_owned() }
    }
}

pub fn mpv_log_path() -> std::path::PathBuf {
    linplayer_core::paths::logs_dir().join("mpv.log")
}

/* 日志出口。原先直接调 `crate::poclog`(桌面壳里的函数),提成共享 crate 后
   两端各有各的日志落点,所以改成宿主启动时插一个钩子进来。
   ★ 不插也能跑(默认丢弃)—— 但下面那些「静默失效」的告警就看不见了,
     而本文件的注释反复强调那类问题只能靠回读日志发现。两个壳都记得插。 */
static LOG: std::sync::OnceLock<fn(&str)> = std::sync::OnceLock::new();

/// 宿主启动时调一次,把自己的日志函数接进来。
pub fn set_logger(f: fn(&str)) {
    let _ = LOG.set(f);
}

fn poclog(msg: &str) {
    if let Some(f) = LOG.get() {
        f(msg);
    }
}

/// mpv 编译好的 shader 产物。放数据根而不是 %TEMP% —— 它就是要跨次启动活着才有意义,
/// 被临时目录清理掉就等于没缓存。能重建,故归 cache/。
fn shader_cache_dir() -> std::path::PathBuf {
    linplayer_core::paths::cache_dir("shader-cache")
}

/* ---------- 用户自定义 mpv 配置 ----------

   libmpv 默认 `config=no`:**一个配置文件都不读**(这正是 libmpv 和 mpv 命令行
   最大的行为差异)。把 `config=yes` + `config-dir=<目录>` 在 mpv_initialize **之前**
   设上,mpv 就会自己去解析 `<目录>/mpv.conf`、`input.conf`、`scripts/` ——
   我们一行 ini 解析器都不用写。

   ★ 配置文件是在 mpv_initialize 里解析的,**晚于** Player::new 里那一串 set_option,
     所以用户写的同名选项会**盖掉**我们的默认值。这就是「自定义内置的 mpv」要的效果,
     代价是写坏了真能把播放搞挂(比如 vo=null)。故:
       - 只在 mpv.conf 真的存在时才打开这条路(没建过文件的用户完全不受影响);
       - 打开后回读 config-dir 确认(见 Player::new 末尾),别又是一次静默失效。 */

/// 用户 mpv 配置目录(`<数据根>/data/mpv/`)。
pub fn user_config_dir() -> std::path::PathBuf {
    linplayer_core::paths::data_dir("mpv")
}
/// 用户 mpv 配置文件路径。
pub fn user_conf_path() -> std::path::PathBuf {
    user_config_dir().join("mpv.conf")
}
/// 读回用户配置。没建过就是空串(不是错误 —— 绝大多数用户永远不会碰它)。
pub fn read_user_conf() -> String {
    std::fs::read_to_string(user_conf_path()).unwrap_or_default()
}
/// 写用户配置。全空 = 删文件,回到「完全不读配置」的出厂状态。
pub fn write_user_conf(text: &str) -> Result<(), String> {
    let p = user_conf_path();
    if text.trim().is_empty() {
        return match std::fs::remove_file(&p) {
            Ok(()) => Ok(()),
            Err(e) if e.kind() == std::io::ErrorKind::NotFound => Ok(()),
            Err(e) => Err(format!("删除 mpv.conf 失败: {e}")),
        };
    }
    std::fs::write(&p, text).map_err(|e| format!("写入 mpv.conf 失败: {e}"))
}

// ---------- 平台相关:视频顶层窗口 ----------
/* 两端同构,只有系统 API 不同:
     建一个**独立顶层**、无边框、不进任务栏、不抢焦点的窗口给 mpv 当渲染面(wid),
     再把它对齐到主窗口客户区、压在主窗口**正下方**。
   为什么不能用子窗口:Windows 上子窗口进不了逐像素透明的分层窗口;X11 上兄弟窗口之间
   根本不做 alpha 混合(合成器只合成顶层窗口)。两边都只有「顶层垫顶层」这一条路。 */

#[cfg(windows)]
mod overlay {
    use std::sync::Once;
    use windows_sys::Win32::Foundation::HWND;
    use windows_sys::Win32::Foundation::{LPARAM, LRESULT, POINT, RECT, WPARAM};
    use windows_sys::Win32::Graphics::Gdi::{ClientToScreen, HBRUSH};
    use windows_sys::Win32::System::LibraryLoader::GetModuleHandleW;
    use windows_sys::Win32::UI::WindowsAndMessaging::{
        CallWindowProcW, CreateWindowExW, DefWindowProcW, GetClientRect,
        GetWindowLongPtrW, GetWindowRect, IsIconic, IsWindow, IsWindowVisible, RegisterClassW,
        SetWindowLongPtrW, SetWindowPos, ShowWindow, GWLP_WNDPROC, SWP_NOACTIVATE, SWP_NOMOVE,
        SWP_NOSIZE, SWP_NOZORDER, SW_HIDE, SW_SHOWNOACTIVATE, WM_WINDOWPOSCHANGED, WNDCLASSW,
        WS_EX_NOACTIVATE, WS_EX_TOOLWINDOW, WS_POPUP,
    };

    static REGISTER: Once = Once::new();
    const CLASS_NAME: &[u16] =
        &[b'l' as u16, b'p' as u16, b'v' as u16, b'i' as u16, b'd' as u16, 0];

    unsafe extern "system" fn wndproc(hwnd: HWND, msg: u32, wp: WPARAM, lp: LPARAM) -> LRESULT {
        DefWindowProcW(hwnd, msg, wp, lp)
    }

    fn ensure_class() {
        REGISTER.call_once(|| unsafe {
            let hinst = GetModuleHandleW(std::ptr::null());
            let wc = WNDCLASSW {
                style: 0,
                lpfnWndProc: Some(wndproc),
                cbClsExtra: 0,
                cbWndExtra: 0,
                hInstance: hinst,
                hIcon: std::ptr::null_mut(),
                hCursor: std::ptr::null_mut(),
                hbrBackground: std::ptr::null_mut() as HBRUSH,
                lpszMenuName: std::ptr::null(),
                lpszClassName: CLASS_NAME.as_ptr(),
            };
            RegisterClassW(&wc);
        });
    }

    pub fn create() -> isize {
        ensure_class();
        unsafe {
            let hinst = GetModuleHandleW(std::ptr::null());
            /* ★ 建出来就**不带 WS_VISIBLE**。老代码是可见的,而 sync() 每次又都带
               SWP_SHOWWINDOW —— 于是这个黑窗从 App 启动那一刻起就一直挂在桌面上。
               平时它被主窗盖住看不出来,主窗一最小化就露出来:用户看到的
               「反复最小化能看到后面层级窗口正在播放」正是这个。
               显隐现在由 sync() 按主窗状态决定,见下。 */
            let hwnd = CreateWindowExW(
                WS_EX_TOOLWINDOW | WS_EX_NOACTIVATE,
                CLASS_NAME.as_ptr(),
                std::ptr::null(),
                WS_POPUP,
                100,
                100,
                800,
                600,
                std::ptr::null_mut(), // 顶层,无父窗口
                std::ptr::null_mut(),
                hinst,
                std::ptr::null(),
            );
            hwnd as isize
        }
    }

    /* 视频窗该不该显示 = **两个条件的与**:
         1) 正在播片(WANT,由 set_visible 从 play/stop 那边置);
         2) 主窗自己还在屏幕上(没最小化、没隐藏)。
       任一不成立就藏。收敛成这一个函数,是因为它有三个调用点(sync / host_proc /
       set_visible)——散着写的话必然出现「A 把它藏了 B 又把它亮出来」。 */
    static WANT_VISIBLE: std::sync::atomic::AtomicBool = std::sync::atomic::AtomicBool::new(false);

    unsafe fn apply_visibility(v: HWND, t: HWND) -> bool {
        let show = WANT_VISIBLE.load(std::sync::atomic::Ordering::Relaxed)
            && IsIconic(t) == 0
            && IsWindowVisible(t) != 0;
        // 状态已经对就别调 ShowWindow:它会动 z 序,而我们正挂在 z 序变化的回调里。
        if (IsWindowVisible(v) != 0) != show {
            ShowWindow(v, if show { SW_SHOWNOACTIVATE } else { SW_HIDE });
        }
        show
    }

    /// 把视频窗压在主窗正下方(hWndInsertAfter = 主窗)。
    unsafe fn restack(v: HWND, t: HWND) {
        SetWindowPos(v, t, 0, 0, 0, 0, SWP_NOACTIVATE | SWP_NOMOVE | SWP_NOSIZE);
    }

    /// 把视频窗铺到主窗**客户区**上,几何直接从主窗现量。
    ///
    /// ★ 这是「全屏后一圈白边、必须窗口化再全屏才消失」的根治点。
    ///
    /// 原来几何**只**由 apps/desktop 的 sync_video 摆,而它挂在 Tauri 的
    /// Resized / Moved / Focused(true) 三个事件上。可主窗的几何还有别的路径会变,
    /// 而那些路径**不产生**这三个事件:Alt-Tab 回来、点任务栏回来、DPI 变化、
    /// 别的全屏应用切走再切回……于是视频窗停在上一次的矩形上,
    /// 主窗已经铺满整个屏幕、视频窗还是窗口大小 —— 四周露出的那一圈就是用户说的白边。
    /// 「窗口化 → 再全屏」能消掉它,恰恰是因为那两步会发 Resized,把事件那条路激活了。
    /// 症状能被一个特定手势稳定治好,就说明缺的不是计算,是**触发**。
    ///
    /// 所以几何跟着 z 序一起挪进 WM_WINDOWPOSCHANGED —— 位置/尺寸/层叠任一变化都发它,
    /// 不管变化是谁引起的。这样就不用再去枚举「还有哪些路径没覆盖到」。
    ///
    /// 之前不在这里做几何的理由是「钩子里拿不到 Tauri 的 inner_position」——
    /// 那个理由不成立:GetClientRect + ClientToScreen 量的就是客户区,
    /// 和 Tauri 的 inner_position/inner_size 是同一个矩形(2026-08-01 实测两边逐像素相同:
    /// 窗口 203,203 1195x729 而客户区 210,204 1180x720,后者正是 Tauri 报的值)。
    unsafe fn align_to_host(v: HWND, t: HWND) {
        let mut rc: RECT = std::mem::zeroed();
        if GetClientRect(t, &mut rc) == 0 {
            return;
        }
        let mut org = POINT { x: 0, y: 0 };
        if ClientToScreen(t, &mut org) == 0 {
            return;
        }
        let mut cur: RECT = std::mem::zeroed();
        let cur = if GetWindowRect(v, &mut cur) != 0 {
            Some((cur.left, cur.top, cur.right - cur.left, cur.bottom - cur.top))
        } else {
            None
        };
        if let Some((x, y, w, h)) =
            align_target((rc.right - rc.left, rc.bottom - rc.top), (org.x, org.y), cur)
        {
            SetWindowPos(v, std::ptr::null_mut(), x, y, w, h, SWP_NOACTIVATE | SWP_NOZORDER);
        }
    }

    /// 纯几何决策:该不该动视频窗、动到哪。返回 None = 什么都别做。
    ///
    /// 抽出来是为了**能测** —— Win32 调用那半截测不了,这半截是整个修复里
    /// 唯一会算错的地方。两条守则各自防一个真实的坏结果:
    ///   · 客户区 0×0(主窗最小化)→ 不动。照着摆会把视频窗缩成 0×0,
    ///     而它之后再也长不回来(mpv 的视口跟着塌了),表现是「最小化再恢复就没画面」。
    ///   · 已经对上了 → 不动。我们跑在 WM_WINDOWPOSCHANGED 回调里,
    ///     SetWindowPos 哪怕没改任何东西也会再发一条消息,白白多绕一圈重入闸。
    fn align_target(
        client: (i32, i32),
        org: (i32, i32),
        cur: Option<(i32, i32, i32, i32)>,
    ) -> Option<(i32, i32, i32, i32)> {
        let (w, h) = client;
        if w <= 0 || h <= 0 {
            return None;
        }
        let want = (org.0, org.1, w, h);
        if cur == Some(want) {
            return None;
        }
        Some(want)
    }

    #[cfg(test)]
    mod tests {
        use super::align_target;

        #[test]
        fn align_target_moves_only_when_it_must() {
            // 窗口化 1180x720 @(210,204) —— 2026-08-01 从真进程量到的实际值。
            let windowed = (210, 204, 1180, 720);
            assert_eq!(align_target((1180, 720), (210, 204), Some(windowed)), None, "对上了就别动");

            // 全屏:主窗客户区变成整块屏幕,而视频窗还停在窗口化的矩形上 —— 那一圈没被盖住的
            // 就是用户看到的白边。这一条红了就说明白边修没了。
            assert_eq!(
                align_target((2560, 1440), (0, 0), Some(windowed)),
                Some((0, 0, 2560, 1440)),
                "主窗铺满了,视频窗必须跟上"
            );
            // 只挪位置不改尺寸(拖动窗口)也要跟。
            assert_eq!(
                align_target((1180, 720), (500, 300), Some(windowed)),
                Some((500, 300, 1180, 720))
            );
            // 量不到视频窗当前矩形 → 照摆一次,不要因为「不知道」就不动。
            assert_eq!(align_target((1180, 720), (210, 204), None), Some(windowed));
            // 主窗最小化时客户区是 0×0:必须原地不动,否则视频窗被缩成 0 再也长不回来。
            assert_eq!(align_target((0, 0), (0, 0), Some(windowed)), None);
            assert_eq!(align_target((1180, 0), (0, 0), Some(windowed)), None);
            assert_eq!(align_target((-1, -1), (0, 0), None), None);
        }
    }

    pub fn sync(video: isize, tauri: isize, x: i32, y: i32, w: i32, h: i32) {
        unsafe {
            let (v, t) = (video as HWND, tauri as HWND);
            // 几何先摆好(不动 z 序),藏着的时候也摆 —— 这样恢复显示时不会闪一下旧位置。
            SetWindowPos(v, std::ptr::null_mut(), x, y, w, h, SWP_NOACTIVATE | SWP_NOZORDER);
            if apply_visibility(v, t) {
                restack(v, t);
            }
        }
    }

    /* ---- 把视频窗**焊死**在主窗背面 ----

       原来只在 Tauri 的 Resized / Moved / Focused(true) 三个事件上重排。
       可主窗的 z 序还会被别的路径改:Alt-Tab、点任务栏、别的窗口插进来、
       WebView2 自己动一下 —— 这些都不产生上面那三个事件,于是视频层就"掉"了。
       用户报的「视频层级掉到应用主界面之下」就是这一类漏网。

       WM_WINDOWPOSCHANGED 是**位置/尺寸/z 序任何一样变了都会发**的那条消息。
       钉住它,上面整类问题一次消掉,也不用起定时器去轮询。 */
    static mut PREV_PROC: isize = 0;
    static mut VIDEO_HWND: isize = 0;
    /// 当前把钩子装在**哪个**宿主窗上。0 = 没装。
    ///
    /// 从「装一次就不管」改成可改挂,是因为播放页现在是**独立窗口**:起播时视频窗要跟
    /// 播放窗走,退播放时再交还主窗。`PREV_PROC` 只有一个槽 —— 不先卸就装第二个,
    /// 第一个宿主的原 wndproc 会被永久覆盖掉,那个窗口从此收不到自己的消息。
    static mut HOOKED_HWND: isize = 0;

    unsafe extern "system" fn host_proc(hwnd: HWND, msg: u32, wp: WPARAM, lp: LPARAM) -> LRESULT {
        let prev = PREV_PROC;
        // 拿不到原 wndproc 就退回默认处理 —— 拿 null 去 CallWindowProcW 是当场崩。
        let r = if prev == 0 {
            DefWindowProcW(hwnd, msg, wp, lp)
        } else {
            CallWindowProcW(std::mem::transmute(prev), hwnd, msg, wp, lp)
        };
        /* ★ 重入闸,少了它就是**当场爆栈**。
           我们在这条回调里调 SetWindowPos/ShowWindow 去摆视频窗,而那会改变主窗的
           相对 z 序 —— Windows 于是又给主窗发一条 WM_WINDOWPOSCHANGED,再进这里,
           再摆一次…… 递归到栈溢出,进程**无声消失**(日志停在最后一行,没有 panic)。
           实测:装上钩子后,鼠标挪一下窗口 App 就没了。 */
        if msg == WM_WINDOWPOSCHANGED
            && VIDEO_HWND != 0
            && !IN_SYNC.swap(true, std::sync::atomic::Ordering::Relaxed)
        {
            /* z 序、显隐、**几何**三件一起跟。几何原来不在这里(交给 Tauri 事件),
               而 Tauri 只在 Resized/Moved/Focused(true) 三个事件上摆几何 ——
               Alt-Tab 回来、点任务栏回来、DPI 变了都不产生那三个事件,
               视频窗于是停在旧矩形上,全屏时四周露出一圈(用户报的白边)。见 align_to_host。 */
            let (v, t) = (VIDEO_HWND as HWND, hwnd);
            /* 句柄可能已经失效:Player 存在 Mutex<Option<Player>> 里,替换/销毁时
               视频窗就没了,而这个 static 还留着旧 HWND。拿失效句柄去 SetWindowPos
               是典型的「无声死亡」来源,先验一下再用。 */
            if IsWindow(v) != 0 {
                align_to_host(v, t);
                if apply_visibility(v, t) {
                    restack(v, t);
                }
            }
            IN_SYNC.store(false, std::sync::atomic::Ordering::Relaxed);
        }
        r
    }

    static IN_SYNC: std::sync::atomic::AtomicBool = std::sync::atomic::AtomicBool::new(false);

    /// 子类化宿主窗,接管 WM_WINDOWPOSCHANGED。**可改挂**:传入不同的 host 会先把钩子从
    /// 上一个宿主上卸下来再装到新的上面(播放页独立成窗口后,视频窗要在主窗/播放窗之间改挂)。
    ///
    /// ★ 必须在**宿主窗所属的那条线程**上调(= 主线程)。SetWindowLongPtr 对别的线程
    ///   拥有的窗口会直接失败,而且不报错 —— 表现就是「改挂了但 z 序还跟着老窗口」。
    pub fn pin_below(video: isize, tauri: isize) {
        unsafe {
            VIDEO_HWND = video;
            HOST_HWND = tauri;
            if HOOKED_HWND == tauri {
                return; // 已经装在它身上,别重复装(重复装会把自己的 host_proc 存进 PREV_PROC → 无限递归)
            }
            /* 先卸旧的。PREV_PROC 只有一个槽:不卸就装第二个,旧宿主的原 wndproc
               被覆盖后再也找不回来,那个窗口从此不响应 —— 比不改挂糟糕得多。 */
            if HOOKED_HWND != 0 {
                if IsWindow(HOOKED_HWND as HWND) != 0 && PREV_PROC != 0 {
                    SetWindowLongPtrW(HOOKED_HWND as HWND, GWLP_WNDPROC, PREV_PROC);
                }
                HOOKED_HWND = 0;
                PREV_PROC = 0;
            }
            if tauri == 0 {
                return; // 只卸不装(播放窗关掉且暂时没有新宿主)
            }
            let prev = GetWindowLongPtrW(tauri as HWND, GWLP_WNDPROC);
            /* 拿不到原 wndproc 就**别装**。装了却把消息全喂给 DefWindowProcW,
               等于把 Tauri 的窗口过程整个换掉 —— 窗口会彻底不响应。
               降级成「只靠 Tauri 事件重排 z 序」(改这版之前的行为)远比这个好。 */
            if prev == 0 {
                crate::poclog("装 WM_WINDOWPOSCHANGED 钩子失败(取不到原 wndproc),z 序退回事件驱动");
                return;
            }
            PREV_PROC = prev;
            HOOKED_HWND = tauri;
            SetWindowLongPtrW(tauri as HWND, GWLP_WNDPROC, host_proc as *const () as isize);
        }
    }

    static mut HOST_HWND: isize = 0;

    /// 当前宿主是不是它。**还没定过宿主时一律算是**(启动早期主窗自己就是唯一候选,
    /// 那时返 false 会把开机第一次对齐吞掉,画面停在 0×0)。
    pub fn is_host(hwnd: isize) -> bool {
        unsafe { HOST_HWND == 0 || HOST_HWND == hwnd }
    }

    /// 开关「正在播片」。真正显不显示还要看主窗是不是最小化了,见 apply_visibility。
    pub fn set_visible(video: isize, on: bool) {
        WANT_VISIBLE.store(on, std::sync::atomic::Ordering::Relaxed);
        unsafe {
            let v = video as HWND;
            if HOST_HWND != 0 {
                /* 亮之前先对齐。视频窗藏着的这段时间主窗可能已经改过尺寸
                   (退播放页 → 切全屏 → 再进播放页),不对齐就是「一亮出来先是旧矩形」。 */
                if on {
                    align_to_host(v, HOST_HWND as HWND);
                }
                if apply_visibility(v, HOST_HWND as HWND) {
                    restack(v, HOST_HWND as HWND);
                }
            } else {
                // 还没装钩子(启动早期)。藏总是安全的;显示留给之后的 sync/钩子。
                ShowWindow(v, SW_HIDE);
            }
        }
    }
}

#[cfg(target_os = "linux")]
mod overlay {
    use std::ffi::{c_int, c_uint};
    use std::sync::OnceLock;
    use x11_dl::xlib;

    struct X {
        lib: xlib::Xlib,
        dpy: *mut xlib::Display,
    }
    // 只在窗口几何/层叠这条路上用,调用点都在主线程(sync_video 走 run_on_main_thread)。
    unsafe impl Send for X {}
    unsafe impl Sync for X {}

    /* ★ Xlib 默认错误处理器**直接 abort 整个进程**。我们干的正是最容易撞
       BadWindow/BadMatch 的活:窗口可能刚被 WM 重新 reparent、或已经销毁,
       而这些错误是异步回来的。不换掉它,一次竞态就是一次「播放中无故崩溃」。 */
    unsafe extern "C" fn ignore_x_error(
        _d: *mut xlib::Display,
        _e: *mut xlib::XErrorEvent,
    ) -> c_int {
        0
    }

    fn x11() -> Option<&'static X> {
        static X11: OnceLock<Option<X>> = OnceLock::new();
        X11.get_or_init(|| unsafe {
            let lib = xlib::Xlib::open().ok()?;
            (lib.XSetErrorHandler)(Some(ignore_x_error));
            // 自己开一条连接,不蹭 GTK 那条:GTK 的连接由它自己的主循环独占,
            // 从别处往里塞请求是竞态。mpv 拿到 wid 后也会自己开连接,这是 --wid 的常规用法。
            let dpy = (lib.XOpenDisplay)(std::ptr::null());
            if dpy.is_null() {
                return None;
            }
            Some(X { lib, dpy })
        })
        .as_ref()
    }

    unsafe fn root_of(x: &X) -> xlib::Window {
        let screen = (x.lib.XDefaultScreen)(x.dpy);
        (x.lib.XRootWindow)(x.dpy, screen)
    }

    pub fn create() -> isize {
        let Some(x) = x11() else { return 0 };
        unsafe {
            let screen = (x.lib.XDefaultScreen)(x.dpy);
            let root = (x.lib.XRootWindow)(x.dpy, screen);
            let mut attrs: xlib::XSetWindowAttributes = std::mem::zeroed();
            /* override_redirect = WM 完全不管这个窗口:不加装饰、不进任务栏、不抢焦点。
               正是 Win32 那半 WS_POPUP | WS_EX_TOOLWINDOW | WS_EX_NOACTIVATE 的语义。
               附带好处:它不会被 reparent,始终是 root 的直接子窗口 —— 下面的兄弟层叠依赖这点。 */
            attrs.override_redirect = xlib::True;
            attrs.background_pixel = (x.lib.XBlackPixel)(x.dpy, screen);
            let w = (x.lib.XCreateWindow)(
                x.dpy,
                root,
                100,
                100,
                800,
                600,
                0,
                0,                          // depth = CopyFromParent
                xlib::InputOutput as c_uint,
                std::ptr::null_mut(),       // visual = CopyFromParent
                xlib::CWOverrideRedirect | xlib::CWBackPixel,
                &mut attrs,
            );
            if w == 0 {
                return 0;
            }
            /* ★ 建完**不 map**。原来是建完就 map,于是这个窗从 App 启动起就一直在桌面上,
               主窗一最小化就露出来 —— 和 Windows 那半 WS_VISIBLE 是同一个 bug。
               显隐统一交给 set_visible / sync。 */
            (x.lib.XFlush)(x.dpy);
            w as isize
        }
    }

    /* 顺着 parent 链上溯到 root 的那个**直接子窗口**。
       ★ 不能直接拿 Tauri 的 client window 当层叠兄弟:重定向式 WM(绝大多数)会把它
         reparent 进一个装饰框里,于是它和我们这个 root 直属的 override-redirect 窗口
         **不是兄弟**,XConfigureWindow 会 BadMatch —— 而错误被上面的处理器吞掉,
         表现是「静默不排序」:视频窗口盖在 UI 上面,或者干脆看不见。 */
    unsafe fn toplevel_frame(x: &X, mut w: xlib::Window) -> Option<xlib::Window> {
        let root = root_of(x);
        // 上限只是防御:parent 链实际很短(1~2 层),坏掉时别转成死循环。
        for _ in 0..16 {
            let (mut r, mut parent): (xlib::Window, xlib::Window) = (0, 0);
            let mut kids: *mut xlib::Window = std::ptr::null_mut();
            let mut n: c_uint = 0;
            if (x.lib.XQueryTree)(x.dpy, w, &mut r, &mut parent, &mut kids, &mut n) == 0 {
                return None;
            }
            if !kids.is_null() {
                (x.lib.XFree)(kids as *mut _);
            }
            if parent == root || parent == 0 {
                return Some(w);
            }
            w = parent;
        }
        None
    }

    /// 「正在播片」。X11 上没有 IsIconic 那种便宜的查法,而主窗最小化时 Tauri 会
    /// 发 Resized(0,0)/Moved,sync 那边据此不再 map —— 与 Windows 同一个「与」语义。
    static WANT_VISIBLE: std::sync::atomic::AtomicBool = std::sync::atomic::AtomicBool::new(false);

    fn want() -> bool {
        WANT_VISIBLE.load(std::sync::atomic::Ordering::Relaxed)
    }

    /// 显隐视频窗。X11 上就是 map / unmap。
    pub fn set_visible(video: isize, on: bool) {
        WANT_VISIBLE.store(on, std::sync::atomic::Ordering::Relaxed);
        let Some(x) = x11() else { return };
        if video == 0 {
            return;
        }
        unsafe {
            map(x, video as xlib::Window, on);
        }
    }

    unsafe fn map(x: &X, w: xlib::Window, on: bool) {
        if on {
            (x.lib.XMapWindow)(x.dpy, w);
        } else {
            (x.lib.XUnmapWindow)(x.dpy, w);
        }
        (x.lib.XFlush)(x.dpy);
    }

    /* X11 上**没有** WM_WINDOWPOSCHANGED 那种「主窗几何/层叠一变就通知我」的现成消息:
       要等价的效果得 XSelectInput(StructureNotify) 主窗的 frame 再自己跑事件循环,
       而那个 frame 会被 WM 换掉(reparent),得跟着重挂 —— 成本和出错面都不小。
       所以 Linux 这半仍然只靠 Tauri 事件驱动的 sync(),这是**已知的能力差**,
       不是忘了写。真在 X11 上遇到层级掉队,再来补事件循环那条路。 */
    pub fn pin_below(_video: isize, _tauri: isize) {}

    /* X11 这半没有 wndproc 钩子,也就没有「当前宿主」的概念 —— 几何一律由 Tauri 事件
       驱动。恒真即可:调用方拿它当闸门,返 false 会把 Linux 上的对齐整个关掉。
       真要在 X11 上支持独立播放窗的层级跟随,得先补那条事件循环(见 pin_below 上面)。 */
    pub fn is_host(_hwnd: isize) -> bool {
        true
    }

    pub fn sync(video: isize, tauri: isize, x_: i32, y_: i32, w: i32, h: i32) {
        let Some(x) = x11() else { return };
        if video == 0 {
            return;
        }
        unsafe {
            let video = video as xlib::Window;
            /* 主窗最小化时 Tauri 报的尺寸会塌成 0(或极小)。这时不能再 map:
               视频窗是 override_redirect 的,WM 完全不管它,不主动 unmap 的话
               就是一块还在放片的画面留在桌面上(Windows 那半的同款症状)。 */
            let host_ok = w > 1 && h > 1;
            map(x, video, want() && host_ok);
            if !host_ok {
                return;
            }
            // 宽高为 0 在 X11 上是 BadValue(Win32 只是忽略),这里先夹住。
            (x.lib.XMoveResizeWindow)(x.dpy, video, x_, y_, w.max(1) as c_uint, h.max(1) as c_uint);
            let sibling = toplevel_frame(x, tauri as xlib::Window).unwrap_or(tauri as xlib::Window);
            let mut ch: xlib::XWindowChanges = std::mem::zeroed();
            ch.sibling = sibling;
            ch.stack_mode = xlib::Below; // = SetWindowPos 的 hWndInsertAfter=tauri
            (x.lib.XConfigureWindow)(
                x.dpy,
                video,
                (xlib::CWSibling | xlib::CWStackMode) as c_uint,
                &mut ch,
            );
            (x.lib.XFlush)(x.dpy);
        }
    }
}

/* Android:渲染面不是我们建的窗口,而是 Java 层 SurfaceView 给的 Surface。

   ★ 关键差别:桌面上 create() 是**同步造一个窗口**,安卓上 Surface 由系统在
     surfaceCreated 回调里给,时机不由我们定。所以这里只是**取**壳先前存进来的那个,
     没准备好就返回 0 —— Player::new 会把 0 当作「没有渲染面」直接报错,
     正是我们要的行为(带着 wid=0 往下走,mpv 会自己弹窗,那在安卓上是彻底的黑屏)。

   ★ jobject 必须是 **全局引用**,由 apps/android 的 JNI 那侧负责 NewGlobalRef ——
     局部引用出了那次 native 调用就失效,mpv 之后拿它去 ANativeWindow_fromSurface
     会崩在一个和这里毫无关系的地方。 */
#[cfg(target_os = "android")]
mod overlay {
    use std::sync::atomic::{AtomicIsize, Ordering};

    static SURFACE: AtomicIsize = AtomicIsize::new(0);
    /// 高 32 位宽、低 32 位高。0 = 壳还没报过尺寸。
    static SIZE: std::sync::atomic::AtomicU64 = std::sync::atomic::AtomicU64::new(0);

    /// 由壳在 surfaceCreated / surfaceDestroyed 时调用。传 0 表示 Surface 没了。
    pub fn set_surface(ptr: isize) {
        SURFACE.store(ptr, Ordering::SeqCst);
    }

    /// 由壳在 surfaceChanged 里报当前 Surface 的像素尺寸。
    pub fn set_size(w: i32, h: i32) {
        if w > 0 && h > 0 {
            SIZE.store(((w as u64) << 32) | h as u64, Ordering::SeqCst);
        }
    }

    /// `"1920x1080"`,壳还没报过则 None。
    pub fn size_str() -> Option<String> {
        let v = SIZE.load(Ordering::SeqCst);
        if v == 0 {
            return None;
        }
        Some(format!("{}x{}", v >> 32, v & 0xffff_ffff))
    }

    pub fn create() -> isize {
        SURFACE.load(Ordering::SeqCst)
    }

    /// SurfaceView 铺满 Activity,没有「把视频窗对齐到 UI 窗」这回事。
    pub fn sync(_v: isize, _t: isize, _x: i32, _y: i32, _w: i32, _h: i32) {}
    // 安卓的渲染面是 SurfaceView,层级归 Android 的 View 树管,不存在这两件事。
    pub fn set_visible(_v: isize, _on: bool) {}
    pub fn pin_below(_v: isize, _t: isize) {}
}

/// 安卓壳把 SurfaceView 的 Surface(**全局引用**)交进来。见 `mod overlay` 的注释。
#[cfg(target_os = "android")]
pub fn set_android_surface(ptr: isize) {
    overlay::set_surface(ptr);
}

/// 安卓壳报 Surface 的实际像素尺寸(surfaceChanged)。
///
/// ★ 必须报,而且只能靠壳报。mpv 的 android gpu-context 取视口是
///   `vo_android_surface_size()`(video/out/android_common.c):**先读 `android-surface-size`
///   选项,没设才回退 `ANativeWindow_getWidth/Height`**,而它只在 `android_reconfig()`
///   里被调一次 —— 安卓没有窗口 resize 事件通道,mpv 自己永远不知道面变大了。
///   于是视口被冻在 EGL 初始化那一刻的尺寸:那时布局还没定稿(edge-to-edge 生效前
///   SurfaceView 是带 inset 的小尺寸),画面就渲染在一个比屏幕小的矩形里,
///   **四周留下一圈没画到的边** —— 用户报的「播放页有一圈白边、画面没铺满」就是它。
///   mpv-android 官方的 BaseMPVView.kt 在 surfaceChanged 里做的正是这一件事。
///
/// ponytail: 只在起播时读一次(见 Player::new)。SurfaceView 在开机时就建好、
/// 起播远在其后,所以起播时拿到的已是定稿尺寸。播放**中途**改面(分屏/画中画)
/// 才需要把它推给活着的 mpv 实例 —— TV 上没有这些入口,真要支持再加。
#[cfg(target_os = "android")]
pub fn set_android_surface_size(w: i32, h: i32) {
    overlay::set_size(w, h);
}

/* 起播时读一次。上面那些 `set(...)` 走的是运行时 `cfg!()`(不是 `#[cfg]`),
   整段在三端都要编译得过 —— 桌面的 overlay 里没有 size_str,所以在这里分岔。 */
#[cfg(target_os = "android")]
fn android_surface_size() -> Option<String> {
    overlay::size_str()
}
#[cfg(not(target_os = "android"))]
fn android_surface_size() -> Option<String> {
    None
}

/// 安卓壳把 JavaVM 指针交进来。**必须在起播前调一次**,否则视频起不来。
///
/// ★ 一开始我以为靠 Java 侧 `System.loadLibrary("mpv")` 触发 `JNI_OnLoad` 就够了 ——
///   **对这个 libmpv 二进制是错的**。实测(llvm-nm -D,media-kit/libmpv-android-video-build
///   v1.1.11 的 full-arm64-v8a):
///     JNI_OnLoad          → **没有导出**
///     av_jni_set_java_vm  → 有
///   也就是说它把「登记 JavaVM」这一步留给宿主自己调。不调的表现是最难查的那一种:
///   库加载成功、mpv_create 成功、loadfile 也成功,然后 mediacodec 解码器和
///   gpu-context=android 拿不到 JNI 环境 —— **黑屏,不报错**。
///
/// 换 libmpv 版本时请重新 `llvm-nm -D` 确认这两个符号的有无再改这里,别照抄结论。
#[cfg(target_os = "android")]
pub fn set_android_java_vm(vm: *mut c_void) {
    // ffmpeg 原型:int av_jni_set_java_vm(void *vm, void *log_ctx);
    type FnSetVm = unsafe extern "C" fn(*mut c_void, *mut c_void) -> c_int;
    unsafe {
        // 与 mod ffi 里 dlopen 的是同一个库,拿到的是同一个句柄,不会加载两份。
        let Ok(lib) = libloading::Library::new("libmpv.so") else {
            poclog("警告: dlopen libmpv.so 失败,无法登记 JavaVM");
            return;
        };
        match lib.get::<FnSetVm>(b"av_jni_set_java_vm\0") {
            Ok(f) => {
                let rc = f(vm, std::ptr::null_mut());
                if rc < 0 {
                    poclog(&format!("警告: av_jni_set_java_vm 返回 {rc},硬解/渲染可能起不来"));
                }
            }
            // 没有这个符号的 libmpv 说明是另一种构建(靠 JNI_OnLoad 自己抓)。不是错误。
            Err(_) => poclog("提示: libmpv 无 av_jni_set_java_vm,按 JNI_OnLoad 自登记处理"),
        }
        // ★ 别让 lib 在这里 drop —— drop = dlclose,会把上面刚登记好的东西一起卸掉。
        std::mem::forget(lib);
    }
}

// 其它平台(目前不做):给出可编译的空实现,免得本文件变成 Win/Linux/Android 专属。
#[cfg(not(any(windows, target_os = "linux", target_os = "android")))]
mod overlay {
    pub fn create() -> isize {
        0
    }
    pub fn sync(_v: isize, _t: isize, _x: i32, _y: i32, _w: i32, _h: i32) {}
}

/// 建一个独立顶层无边框窗口(不进任务栏/不抢焦点),给 mpv 当渲染面。
fn create_overlay() -> isize {
    overlay::create()
}

/// 把视频窗口对齐到 Tauri 窗口客户区(屏幕坐标 x,y,w,h),并置于 Tauri 窗口正下方。
/// 主窗最小化/隐藏时改为把视频窗藏起来(它是独立顶层窗,系统不会替我们联动)。
pub fn sync_overlay(video: isize, tauri: isize, x: i32, y: i32, w: i32, h: i32) {
    overlay::sync(video, tauri, x, y, w, h)
}

/// 把视频窗焊在主窗背面:Windows 上子类化主窗接管 WM_WINDOWPOSCHANGED,
/// 任何来源的 z 序变化都当场跟回来(Alt-Tab / 点任务栏 / 别的窗口插进来 /
/// WebView2 自己动)。X11 暂为 no-op,见那边的说明。启动时调一次即可。
pub fn pin_overlay_below(video: isize, tauri: isize) {
    overlay::pin_below(video, tauri)
}

/// 显隐视频窗。**不播放时应当隐藏** —— 否则那是一块黑色垫在 UI 底下,
/// 主窗一最小化就露在桌面上。
pub fn set_overlay_visible(video: isize, on: bool) {
    overlay::set_visible(video, on)
}

/// `hwnd` 是不是**当前**的视频窗宿主。
///
/// 播放页独立成窗口后,主窗和播放窗都装了几何同步回调,但视频窗只有一个 ——
/// 非宿主窗发来的 Resized/Moved 必须原地不动,否则主窗一被拖动就会把正在播放窗里
/// 放着的画面拽回主窗的矩形上。
pub fn is_overlay_host(hwnd: isize) -> bool {
    overlay::is_host(hwnd)
}

// ---------- 播放器 ----------

/// 不依赖 `&Player` 的命令发送 —— 事件线程只有裸 ctx,但也要能发 `sub-add`。
/// libmpv 的 mpv_command 是线程安全的(官方文档明示),从事件线程发命令合法。
fn cmd_raw(ctx: *mut mpv_handle, args: &[&str]) -> Result<(), String> {
    let cstrs: Vec<CString> = args.iter().map(|a| CString::new(*a).unwrap()).collect();
    let mut ptrs: Vec<*const c_char> = cstrs.iter().map(|c| c.as_ptr()).collect();
    ptrs.push(std::ptr::null());
    let r = unsafe { mpv_command(ctx, ptrs.as_ptr()) };
    if r < 0 { Err(format!("mpv 命令失败: {}", err_str(r))) } else { Ok(()) }
}

/* 外挂字幕的挂载状态。★ `loaded` 和 `pending` **必须在同一把锁里**,不能拆成
   AtomicBool + Mutex<Vec>:那样会有 TOCTOU —— 调用方读到 loaded=false 正准备写
   pending,事件线程恰好在这一瞬收到 FILE_LOADED 并取走(空的)pending,字幕就永远
   没人挂了,而且**一声不吭**。同款竞态在预取环形缓存上真炸过一次,不重复踩。 */
#[derive(Default)]
struct SubState {
    loaded: bool,                   // 当前文件是否已 FILE_LOADED
    pending: Vec<(String, String)>, // (url, title),等 FILE_LOADED 后由事件线程挂
    /* 起播途中用户拖/点进度条留下的目标位。★ 和外挂字幕**同一个坑、同一个解法**:
       `seek` 发在 FILE_LOADED 之前只会拿到「命令失败」——mpv 那会儿还没有文件可跳。
       而闩在发命令之前就设上了,于是现象是:进度条压着用户拖到的位置 2.5s,然后
       弹回 `start=` 的续播点,画面从头到尾没跳过 —— 用户报的「没加载完就点进度条,
       之后调进度稳定复现、画面不变」正是这个。
       只留最后一条:起播时连点几下,只有最后那次算数(和 seek 的语义一致)。 */
    pending_seek: Option<f64>,
}

impl SubState {
    /// 收下一次 seek。`true` = 文件已开好,调用方现在就发命令;
    /// `false` = 已排进 `pending_seek`,调用方**别发**,等 FILE_LOADED 由事件线程补发。
    fn queue_seek(&mut self, target: f64) -> bool {
        if self.loaded {
            return true;
        }
        self.pending_seek = Some(target);
        false
    }
}

pub struct Player {
    ctx: *mut mpv_handle,
    pub video_hwnd: isize,
    error_eof: Arc<AtomicBool>, // 直链失效标志(END_FILE=error),供 302 重签探测
    eof: Arc<AtomicBool>,       // 正常播完标志(END_FILE=eof),供「看完」同步
    subs: Arc<std::sync::Mutex<SubState>>,
    running: Arc<AtomicBool>,
    event_thread: Option<JoinHandle<()>>,
    /* 最后一次**读到过**的播放位置/时长(f64 的位模式)。
       ★ 为什么要记账:`time-pos` / `duration` 不是「一直有值」的属性 —— seek 进行中、
         换片解码就绪前、缓冲饥饿时,mpv 会返回 MPV_ERROR_PROPERTY_UNAVAILABLE。
         老代码的 get_f64 **不看返回值**,失败时把栈上初值 0.0 原样交出去,于是界面
         每隔几拍就收到一个 time=0 —— 进度条抽回开头再弹回来,和画面完全对不上。
         属性暂时读不到 ≠ 播放位置变成 0,所以读不到就沿用上一次读到的值。 */
    last_pos: Arc<AtomicU64>,
    last_dur: Arc<AtomicU64>,
    /* 缓冲末端时间戳,同样是「暂时读不到 ≠ 变成 0」。原来走 get_f64,缓冲饥饿或
       seek 重开 demuxer 的那几拍读不到,界面就收到 buffered=0 —— 缓冲条整条闪没。 */
    last_buf: Arc<AtomicU64>,
    /* seek 闩。见 [`Player::seek_abs`] / [`Player::status`]。 */
    seek_latch: Arc<std::sync::Mutex<Option<SeekLatch>>>,
}

/// 一次进行中的 seek。
#[derive(Clone, Copy)]
struct SeekLatch {
    target: f64,
    at: std::time::Instant,
    /// 是否亲眼见过 mpv 的 `seeking=yes`。见过之后再变回 no,就是**确定**落地了 ——
    /// 这比「位置和目标差多少」可靠得多(关键帧落点可以离目标好几秒)。
    saw_seeking: bool,
}

/// 认为 seek 已到位的容差。比一个 GOP 略宽 —— mpv 默认按关键帧落点,
/// 精确落在请求秒数上是例外而不是常态。
const SEEK_SETTLE_SECS: f64 = 1.5;
/// seek 闩最长压制多久。**只在 mpv 说自己没在 seek 的时候计时** —— 也就是说它管的
/// 是「命令根本没被执行」这一种失败,而不是「网络慢、seek 做得久」。后者由 `seeking`
/// 属性负责,爱做多久做多久,闩一直压着。
const SEEK_LATCH_TIMEOUT: std::time::Duration = std::time::Duration::from_millis(2500);
/* seek 卡多久算「这条流根本跳不动」,该告诉用户而不是让他干等。

   ★ 真实成因(2026-07-27 在用户两台服务器上实测):服务器**宣称** `Accept-Ranges: bytes`
     却对任何 `Range:` 请求都回 `200 OK` + 完整 Content-Length。ffmpeg 于是拿不到
     206,只能从当前位置**顺读丢弃**到目标字节 —— 往前跳 9 分钟就是 370MB。
     mpv 日志里是 `https: Unexpected offset: expected N, got 0` + `Seek failed`。
     同一份二进制在支持 Range 的服务器上 seek 秒到,所以这不是播放器的问题。
   ★ 门槛必须**明显大于**近距离 seek 的耗时:同样那台服务器上跳 3 秒实测要 7s 才落地
     (2MB 的顺读),12s 能把「慢」和「这辈子到不了」分开。 */
const SEEK_STALL_TIMEOUT: std::time::Duration = std::time::Duration::from_secs(12);

/* 「这次 seek 卡住了」。判据只有一条:mpv 亲口说还在 seek,而这已经是很久以前发出的了。
   不看位置差 —— 卡住的时候 time-pos 通常压根读不到。 */
fn seek_stalled(latch: &Option<SeekLatch>, seeking: bool) -> bool {
    matches!(latch, Some(l) if seeking && l.at.elapsed() >= SEEK_STALL_TIMEOUT)
}

/* seek 闩的判定本体。抽成自由函数是为了能**脱离 libmpv 单测** ——
   Player::new 要建叠加窗口、要桌面会话,CI 上跑不了。

   ★ `reported` 必须是**这一拍真读到的** time-pos(`None` = mpv 说读不到),
     绝对不能传「读不到就沿用上次」的那个粘性值。原来传的正是粘性值,而粘性值
     在 seek 期间恰好等于闩的目标位(latched_time 每拍都把目标写回 last_pos)——
     于是 `|reported - target| == 0`,闩在**第一次 time-pos 读不到时就自解除**。
     本地文件 seek 一拍就完事,time-pos 从不缺席,所以看不出问题;网络流 seek 中
     time-pos 频繁不可用,闩当场松掉,下一拍 mpv 报的还是**旧位置**,进度条就跳回去/
     跳到别处 —— 这就是用户报的「本地跟手、服务器上一拖就乱」的根因。 */
fn apply_seek_latch(
    latch: &mut Option<SeekLatch>,
    reported: Option<f64>,
    seeking: bool,
) -> Option<f64> {
    let Some(l) = latch.as_mut() else { return reported };
    if seeking {
        // mpv 亲口说还在 seek:此刻的 time-pos 一定不是新位置,报目标位,别计时超时。
        l.saw_seeking = true;
        return Some(l.target);
    }
    // 位置读不到 -> 继续压制。见上面为什么不能拿粘性值来比。
    let Some(r) = reported else { return Some(l.target) };
    /* 松闩的三条路,任一成立即可:
         1. 见过一整轮 seeking=yes 又回到 no —— mpv 确定落地了,真值就是新位置;
         2. 位置已经落在目标附近(seek 快到一拍都没抓到 seeking=yes,本地文件常见);
         3. 等够了 —— 命令多半压根没生效,继续压着只会变成「进度条永远不动」。 */
    if l.saw_seeking
        || (r - l.target).abs() <= SEEK_SETTLE_SECS
        || l.at.elapsed() >= SEEK_LATCH_TIMEOUT
    {
        *latch = None;
        return Some(r);
    }
    Some(l.target)
}
unsafe impl Send for Player {}

impl Player {
    pub fn new() -> Result<Self, String> {
        let video = create_overlay();
        /* ★ 建窗失败必须当场报错,不能带着 wid=0 往下走。
           mpv 拿到 wid=0 会认为「没给嵌入目标」,配合 force-window=yes **自己弹一个
           独立窗口** —— 用户看到的是「莫名其妙多出来一个播放器窗口,还不受 UI 控制」,
           而不是一条能读懂的错误。Linux 上没 X11(纯 Wayland 没 XWayland)正好走这条路。 */
        if video == 0 {
            return Err(if cfg!(target_os = "android") {
                /* 安卓上 0 = Surface 还没就绪(或已销毁),不是「建窗失败」。
                   最常见的是在 surfaceCreated 之前就按了播放。 */
                "视频渲染面未就绪(SurfaceView 的 Surface 还没创建)".into()
            } else {
                "创建视频窗口失败(Linux 上通常是连不上 X11 显示服务器)".to_string()
            });
        }
        unsafe {
            let ctx = mpv_create();
            if ctx.is_null() {
                /* 非 Windows 上最常见的原因不是 mpv 内部出错,而是**根本没找到 libmpv**
                   (dlopen 三个候选名全失败)。把这句话说清楚,别让用户对着
                   「mpv_create 失败」去查播放器设置。 */
                return Err(if cfg!(windows) {
                    "mpv_create 失败".into()
                } else if cfg!(target_os = "android") {
                    /* 安卓上 dlopen 失败几乎只有一个原因:APK 里没打进 libmpv.so
                       (jniLibs 是 gitignore 的,靠 CI 拉取 —— 那一步没跑就是这个症状)。
                       别让用户对着「没装 libmpv,请 apt install」发呆。 */
                    "mpv_create 失败(APK 里没有 libmpv.so —— 构建时未拉取 jniLibs)"
                        .to_string()
                } else {
                    "mpv_create 失败(通常是没装 libmpv:Debian/Ubuntu `libmpv2`、\
                     Fedora `mpv-libs`、Arch `mpv`;或把 libmpv.so.2 放到程序同级目录)"
                        .to_string()
                });
            }
            let set = |name: &str, val: &str| {
                let n = CString::new(name).unwrap();
                let v = CString::new(val).unwrap();
                mpv_set_option_string(ctx, n.as_ptr(), v.as_ptr());
            };
            set("wid", &video.to_string());
            /* ★ 安卓不用 gpu-next。它要 Vulkan/更新的 libplacebo,机顶盒上的 GPU 驱动
               参差不齐,起不来是**黑屏而不是报错**。gpu + gpu-context=android 是
               mpv-android 多年验证过的组合,先要能出画面。 */
            set("vo", if cfg!(target_os = "android") { "gpu" } else { "gpu-next" });
            /* gpu-context 只在 Windows 上写死 d3d11 —— 那边要它才走得通独显钉定那条链
               (见 [[hybrid-gpu-must-pin-dgpu]])。
               Linux 上**故意不设**:让 mpv 自己在 x11egl / x11vk / wayland 之间挑。
               写死任何一个,都会在缺对应驱动/会话类型的机器上「起不来且不报错」——
               而本项目最不缺的就是这种静默失效。 */
            if cfg!(windows) {
                set("gpu-context", "d3d11");
            }
            /* 安卓必须显式指定 —— mpv 的自动挑选在没有 X11/Wayland 的环境里挑不出东西。 */
            if cfg!(target_os = "android") {
                set("gpu-context", "android");
                /* ★ 视口尺寸。不给这一条,mpv 只能在 reconfig 时问一次 ANativeWindow,
                   之后再也不会更新 —— 画面被冻在一个比屏幕小的矩形里,四周一圈没画到。
                   理由和出处见上面 set_android_surface_size 的注释。 */
                if let Some(sz) = android_surface_size() {
                    set("android-surface-size", &sz);
                }
                /* ★ 声音。安卓上不设 ao 是「有画面没声音」的经典成因:
                   mpv 的 ao 自动列表里 pulse/alsa 全都试不通,最后落到 null,
                   而 **null 是成功的**,所以既不报错也没声音。
                   audiotrack 是安卓唯一真正可用的那个,写死它。 */
                set("ao", "audiotrack");
                /* mediacodec-copy 而不是 mediacodec:后者是直出 Surface 的零拷贝路径,
                   和我们自己的 SurfaceView 抢同一块面,机顶盒上表现为花屏/黑屏;
                   -copy 把帧拷回来交给 vo,慢一点但稳。先要能放,再谈零拷贝。 */
                set("hwdec", "mediacodec-copy");
                /* ★ 文本字幕(SRT/ASS)在安卓上不显示 = libass 找不到任何字体。
                   安卓没有 fontconfig,不指这一条就是**静默不画字幕**。
                   这条在旧 Flutter 版上踩过并记进了 [[android-mpv-subtitle-fonts]],
                   换栈之后是同一个 libass,坑原样还在 —— 直接带上,别再踩一次。 */
                set("sub-fonts-dir", "/system/fonts");
            } else {
                // auto-safe 两端通吃:Win 挑 d3d11va,Linux 挑 vaapi/nvdec,挑不到就软解。
                set("hwdec", "auto-safe");
            }
            set("keep-open", "yes");
            set("force-window", "yes");
            set("osc", "no");
            set("terminal", "no");
            set("input-default-bindings", "no");
            set("input-vo-keyboard", "no");

            /* shader 缓存。libmpv 没有配置目录(日志里 `cache path: '' -> '-'`),
               不显式给路径就**没有任何缓存** —— 每次起播都要把整条 Anime4K 链
               (最重的档 6 个 pass、VL 模型 143K)重新 glsl→SPIR-V(shaderc)
               →HLSL(spirv-cross)→D3D 编译一遍,首帧就得干等这一整轮。
               这条同时打「起播慢」和「一开超分就卡」。 */
            let cache = shader_cache_dir();
            let _ = std::fs::create_dir_all(&cache);
            set("gpu-shader-cache", "yes");
            set("gpu-shader-cache-dir", &cache.to_string_lossy());

            /* ★ mpv 日志默认**关闭** —— 别无条件打开。
               `log-file` 一旦给了路径,mpv 就把日志目标钉在 MSGL_DEBUG,`msg-level=all=v`
               管不住它(证据:日志里全是 [d] 行),而且会连带把 ffmpeg 的 av_log_set_level
               一起拉到 debug → 解码器逐 packet 打日志并**同步写盘**。
               实测:一个文件都没加载、光 mpv 初始化就写了 247 行 / 24KB。
               需要排查时(见 [[prefetch-proxy-deadlock]] 的查法)设环境变量再跑:
                   set LP_MPV_LOG=1 && LinPlayer.exe
               日志仍落 %TEMP%\linplayer_mpv.log。 */
            if std::env::var_os("LP_MPV_LOG").is_some() {
                set("msg-level", "all=v");
                set("log-file", &mpv_log_path().to_string_lossy());
            }

            /* 用户自定义 mpv 配置(设置页「播放器 · mpv 配置」)。理由与风险见
               user_config_dir 上方那段长注释。**必须在 mpv_initialize 之前**设 ——
               配置文件正是在 initialize 里解析的,晚一步就完全不生效且不报错。 */
            let user_conf = user_conf_path();
            let use_user_conf = user_conf.is_file();
            if use_user_conf {
                set("config", "yes");
                set("config-dir", &user_config_dir().to_string_lossy());
            }

            let rc = mpv_initialize(ctx);
            if rc < 0 {
                let e = err_str(rc);
                mpv_terminate_destroy(ctx);
                /* 用户配置里一个非法选项就能让 initialize 直接失败,而错误串里
                   通常只有 "options/…" 这类天书 —— 不点名 mpv.conf 的话,用户
                   根本想不到是自己刚才在设置页写的那几行。 */
                return Err(if use_user_conf {
                    format!(
                        "mpv_initialize 失败: {e}(已启用自定义 mpv.conf,\
                         多半是里面有非法选项 —— 去 设置 › 播放器 › mpv 配置 清空重试)"
                    )
                } else {
                    format!("mpv_initialize 失败: {e}")
                });
            }
            if use_user_conf {
                poclog(&format!("已加载用户 mpv 配置: {}", user_conf.display()));
            }

            /* ★ 回读校验 shader 缓存真设上了。上面那个 set() **吞掉 mpv 的返回码** ——
               选项名写错/该版 mpv 不认,是**静默无效**,不报错,只是缓存永远不生效,
               而「起播慢」这种症状根本看不出是它。本项目吃过太多次「不报错,只是静默不干活」
               的亏,这类优化必须回读确认(同 set_shader_level 回读 glsl-shaders 的理由)。 */
            let got = {
                let n = CString::new("gpu-shader-cache-dir").unwrap();
                let p = mpv_get_property_string(ctx, n.as_ptr());
                if p.is_null() {
                    String::new()
                } else {
                    let s = CStr::from_ptr(p).to_string_lossy().into_owned();
                    mpv_free(p as *mut c_void);
                    s
                }
            };
            if got != cache.to_string_lossy() {
                poclog(&format!(
                    "警告: gpu-shader-cache-dir 没设上(回读={got:?} 期望={:?}) —— \
                     shader 每次起播都要重编译,起播会变慢",
                    cache.to_string_lossy()
                ));
            }

            // 事件循环线程:排空 mpv 事件,捕获 END_FILE=error(直链失效)。
            let error_eof = Arc::new(AtomicBool::new(false));
            let eof = Arc::new(AtomicBool::new(false));
            let running = Arc::new(AtomicBool::new(true));
            let subs: Arc<std::sync::Mutex<SubState>> = Default::default();
            let seek_latch: Arc<std::sync::Mutex<Option<SeekLatch>>> = Default::default();
            let ctx_addr = ctx as usize;
            let (e2, r2, eof2, subs2, latch2) = (
                error_eof.clone(),
                running.clone(),
                eof.clone(),
                subs.clone(),
                seek_latch.clone(),
            );
            let event_thread = std::thread::spawn(move || {
                let ctx = ctx_addr as *mut mpv_handle;
                while r2.load(Ordering::Relaxed) {
                    let ev = mpv_wait_event(ctx, 0.5);
                    if ev.is_null() {
                        continue;
                    }
                    /* 文件真开好了 —— 这才是能挂外挂字幕的**唯一**时机。
                       挂载放在事件线程里做,而不是让调用方阻塞等:两端的调用点都在
                       播放器锁内,在那儿等 FILE_LOADED 等于拿着锁卡住整个 UI。 */
                    if (*ev).event_id == MPV_EVENT_FILE_LOADED {
                        let (queued, seek_to) = {
                            let mut st = subs2.lock().unwrap();
                            st.loaded = true;
                            (std::mem::take(&mut st.pending), st.pending_seek.take())
                        };
                        /* 起播途中攒下的那次 seek,现在才发得出去。
                           ★ 必须重置闩的计时起点:闩是用户拖的那一刻设的,加载花掉的几秒
                             会让它一进来就判超时,真正的 seek 还没落地进度条就弹回去了。 */
                        if let Some(t) = seek_to {
                            if let Some(l) = latch2.lock().unwrap().as_mut() {
                                l.at = std::time::Instant::now();
                            }
                            match cmd_raw(ctx, &["seek", &t.to_string(), "absolute"]) {
                                Ok(()) => poclog(&format!("起播途中的 seek 已补发: {t:.1}s")),
                                Err(e) => {
                                    poclog(&format!("起播途中的 seek 补发失败: {e}"));
                                    *latch2.lock().unwrap() = None;
                                }
                            }
                        }
                        /* 就在事件线程里挂,**不要**另开线程:Drop 的顺序是
                           running=false → join(事件线程) → mpv_terminate_destroy,
                           只有跑在这根线程上才被 join 保护住;另开的线程会绕过它,
                           用户在字幕下载途中关播放器就是 ctx 悬垂。
                           代价是 sub-add 会同步拉取字幕文件(真服实测两条相隔 4s),
                           这期间 END_FILE 只是**延迟**latch(事件在 mpv 队列里不丢),
                           拿几秒的延迟换掉一个 use-after-free,划算。 */
                        for (url, title) in queued {
                            // 正在关闭就别再挂剩下的了 —— 让 drop 那边的 join 早点回来。
                            if !r2.load(Ordering::Relaxed) {
                                break;
                            }
                            // flags=auto:挂上但不自动切,选哪条仍由用户/语言偏好决定。
                            match cmd_raw(ctx, &["sub-add", &url, "auto", &title]) {
                                Ok(()) => poclog(&format!("外挂字幕已挂载: {title}")),
                                // 原来这里是 `let _ =`,失败一声不吭,现象只剩「字幕列表是空的」。
                                Err(e) => poclog(&format!("外挂字幕挂载失败({title}): {e}")),
                            }
                        }
                    }
                    if (*ev).event_id == MPV_EVENT_END_FILE {
                        let ef = (*ev).data as *const mpv_event_end_file;
                        if !ef.is_null() {
                            match (*ef).reason {
                                MPV_END_FILE_REASON_ERROR => e2.store(true, Ordering::Relaxed),
                                MPV_END_FILE_REASON_EOF => eof2.store(true, Ordering::Relaxed),
                                _ => {}
                            }
                        }
                    }
                }
            });

            Ok(Player {
                ctx,
                video_hwnd: video,
                error_eof,
                eof,
                subs,
                running,
                event_thread: Some(event_thread),
                last_pos: Arc::new(AtomicU64::new(0)),
                last_dur: Arc::new(AtomicU64::new(0)),
                last_buf: Arc::new(AtomicU64::new(0)),
                seek_latch,
            })
        }
    }

    /// 取并清「直链失效」标志(网盘短链过期 → 触发 302 重签)。
    /// 取走「已播完」标志(取一次即清零,保证同一次播放只触发一次同步)。
    pub fn take_eof(&self) -> bool {
        self.eof.swap(false, Ordering::Relaxed)
    }
    pub fn take_error_eof(&self) -> bool {
        self.error_eof.swap(false, Ordering::Relaxed)
    }

    fn cmd(&self, args: &[&str]) -> Result<(), String> {
        cmd_raw(self.ctx, args)
    }

    fn set_str(&self, name: &str, val: &str) {
        let n = CString::new(name).unwrap();
        let v = CString::new(val).unwrap();
        unsafe { mpv_set_property_string(self.ctx, n.as_ptr(), v.as_ptr()); }
    }

    fn get_str(&self, name: &str) -> Option<String> {
        let n = CString::new(name).unwrap();
        unsafe {
            let p = mpv_get_property_string(self.ctx, n.as_ptr());
            if p.is_null() { return None; }
            let s = CStr::from_ptr(p).to_string_lossy().into_owned();
            mpv_free(p as *mut c_void);
            Some(s)
        }
    }

    /* ★ 必须看 mpv_get_property 的返回值。
       它 < 0 时**不写** out —— 老写法把栈上初值 0.0 当成「位置=0」交出去了。
       time-pos/duration 在 seek 中、换片解码就绪前、缓冲饥饿时都会返回
       MPV_ERROR_PROPERTY_UNAVAILABLE(-10),属于常态而非异常。 */
    fn try_f64(&self, name: &str) -> Option<f64> {
        let n = CString::new(name).unwrap();
        let mut out: f64 = 0.0;
        let rc = unsafe {
            mpv_get_property(self.ctx, n.as_ptr(), MPV_FORMAT_DOUBLE, &mut out as *mut f64 as *mut c_void)
        };
        // NaN 也当读不到:mpv 偶尔会在换片瞬间给出 NaN,直接吐给前端会变成 JSON null。
        (rc >= 0 && out.is_finite()).then_some(out)
    }

    fn get_f64(&self, name: &str) -> f64 {
        self.try_f64(name).unwrap_or(0.0)
    }

    /// 读一个「读不到就沿用上次」的属性。用于 time-pos / duration 这类
    /// **暂时不可用 ≠ 值变成 0** 的属性。
    fn sticky_f64(&self, name: &str, cell: &AtomicU64) -> f64 {
        match self.try_f64(name) {
            Some(v) => {
                cell.store(v.to_bits(), Ordering::Relaxed);
                v
            }
            None => f64::from_bits(cell.load(Ordering::Relaxed)),
        }
    }

    /// 设置/清除 mpv HTTP 代理(media 走代理时用;空串=直连)。SOCKS 不被 mpv 支持,只传 http://。
    pub fn set_http_proxy(&self, proxy: Option<&str>) {
        self.set_str("http-proxy", proxy.unwrap_or(""));
    }

    /// 带续播起点加载:用 mpv 的 `start` 选项(下一次 loadfile 生效),避免 seek 早于解码就绪失败。
    ///
    /// 这条路是 **Emby 直连取流**(网盘源走 load_with_headers)。
    pub fn load_at(&self, url: &str, start_secs: f64) -> Result<(), String> {
        self.load_inner(url, start_secs, "", None)
    }
    /// 带逐流 HTTP headers / UA 加载(网盘直链取流用:Authorization/Cookie/Referer)。
    // ponytail: http-header-fields 用逗号分隔 "Key: Value";含逗号的值会串味,当前源(OpenList Authorization)不涉及,够用。
    pub fn load_with_headers(
        &self,
        url: &str,
        start_secs: f64,
        headers: &HashMap<String, String>,
        user_agent: Option<&str>,
    ) -> Result<(), String> {
        let joined = headers
            .iter()
            .map(|(k, v)| format!("{k}: {v}"))
            .collect::<Vec<_>>()
            .join(",");
        self.load_inner(url, start_secs, &joined, user_agent)
    }

    /* ★ 每次 loadfile 都**无条件重设** UA 和 header,不是「有才设」。
       mpv 的 user-agent / http-header-fields 是实例级属性,设了就一直在。原先只有
       load_with_headers 会设、谁都不复位,于是放过一次网盘源之后再放 Emby:
         1) 还顶着网盘的 UA,并把网盘的 Authorization/Cookie **发给 Emby 服务器**;
         2) Emby 直连取流从来没带过 LinPlayer/{版本},用的是 mpv 自带默认 UA。
       两个都是静默的 —— 画面照放,只有服务端日志里看得出来。 */
    fn load_inner(
        &self,
        url: &str,
        start_secs: f64,
        header_fields: &str,
        user_agent: Option<&str>,
    ) -> Result<(), String> {
        // 换片先清 eof —— 否则上一集播完的标志会被下一集的第一次轮询读到,
        // 刚起播就被判成「已看完」。
        self.eof.store(false, Ordering::Relaxed);
        /* 位置/时长的记账跟着换片一起清:不清的话新片刚 loadfile、time-pos 还没就绪的
           那几拍会把**上一集的位置**当成本集位置吐出去(进度条一起播就停在别人的进度上)。
           起点直接落 start_secs,续播时第一拍就是对的。 */
        self.last_pos.store(start_secs.max(0.0).to_bits(), Ordering::Relaxed);
        self.last_dur.store(0f64.to_bits(), Ordering::Relaxed);
        self.last_buf.store(0f64.to_bits(), Ordering::Relaxed);
        *self.seek_latch.lock().unwrap() = None; // 上一集没落地的 seek 别压制新片的位置
        /* 字幕状态跟着换片一起复位:loaded 不清的话,下一集的 set_external_subs 会
           以为文件已经开好而立刻 sub-add(其实新文件还没加载完,又回到 -12);
           pending 不清的话,上一集没挂成的字幕会漏到这一集。 */
        {
            let mut st = self.subs.lock().unwrap();
            st.loaded = false;
            st.pending.clear();
            st.pending_seek = None; // 上一集没发出去的 seek 别落到新片头上
        }
        self.set_str("http-header-fields", header_fields);
        // 源没指定 UA 就用访问 Emby 的那个(用户 2026-07-19 定的 UA 口径)。
        self.set_str(
            "user-agent",
            user_agent.unwrap_or(&linplayer_core::http::user_agent()),
        );
        self.set_str(
            "start",
            &if start_secs > 1.0 { start_secs.to_string() } else { "none".to_string() },
        );
        self.cmd(&["loadfile", url])
    }
    pub fn set_pause(&self, paused: bool) {
        self.set_str("pause", if paused { "yes" } else { "no" });
    }
    /* 挂一条外挂字幕(独立 .ass/.srt,不在容器里,mpv 的 track-list 看不到它们)。

       ★ 调用时机不确定,所以由**这里**兜住,而不是让五个调用点各自小心:
         - 起播路径(两端 play + 网盘源)紧跟在 `load_at` 之后,那时 `loadfile` 还没
           真正打开文件,直接 sub-add 拿到的是 -12 —— 这就是「外挂字幕全都挂不上」;
         - 播放中路径(用户手动加字幕、翻译字幕)文件早就开好了,可以当场挂。
       锁内判一次 loaded 就把两种都覆盖:没开好就排队,等事件线程收到 FILE_LOADED
       再挂;已开好就当场挂。判断和入队在同一把锁内完成,不留 TOCTOU 缝。 */
    pub fn add_subtitle(&self, url: &str, title: &str) {
        let mut st = self.subs.lock().unwrap();
        if !st.loaded {
            st.pending.push((url.to_string(), title.to_string()));
            return;
        }
        // sub-add <url> [<flags> [<title>]];flags=auto 不自动切,让用户/偏好选。
        match self.cmd(&["sub-add", url, "auto", title]) {
            Ok(()) => poclog(&format!("外挂字幕已挂载: {title}")),
            // 原来是 `let _ =`,失败一声不吭,现象只剩「字幕列表里什么都没有」。
            Err(e) => poclog(&format!("外挂字幕挂载失败({title}): {e}")),
        }
    }
    /* ★ 先把目标位置记账,再发 seek。
       mpv 的 seek 是**排队命令**:cmd 返回只代表「收到」,time-pos 要等解码器真跳过去
       才更新(网络流上 50~500ms)。这中间的每一次 status 轮询读到的都还是**旧位置** ——
       界面于是把刚拖到的位置弹回原处,而画面已经跳走了,这就是「条和画面对不上」。
       记账放在发命令**之前**:seek 失败最坏是记了个没到达的位置,下一拍就被真值盖掉;
       放在之后则会和「命令已生效、属性已更新」的那一拍抢写,把新值又盖回旧值。 */
    pub fn seek_abs(&self, secs: f64) -> Result<(), String> {
        let t = secs.max(0.0);
        self.last_pos.store(t.to_bits(), Ordering::Relaxed);
        /* 缓冲末端跟着跳:seek 会重开 demuxer,旧的 buffered 是**跳之前**那一段的末端。
           往回拖时它比新位置大一大截,粘性值再把它兜住,缓冲条就停在用户跳走的地方不动。 */
        self.last_buf.store(t.to_bits(), Ordering::Relaxed);
        *self.seek_latch.lock().unwrap() = Some(SeekLatch {
            target: t,
            at: std::time::Instant::now(),
            saw_seeking: false,
        });
        /* 文件还没开好 -> 排队,等 FILE_LOADED 由事件线程补发。判断和入队在同一把锁内,
           不留 TOCTOU 缝(理由同 add_subtitle)。这里返回 Ok:命令确实收下了,只是晚点发。 */
        if !self.subs.lock().unwrap().queue_seek(t) {
            return Ok(());
        }
        // ★ 发 `t` 不是 `secs`:负数被 max(0.0) 夹过,闩记的是 0 而命令送 -30,两边对不上。
        let r = self.cmd(&["seek", &t.to_string(), "absolute"]);
        if r.is_err() {
            // 命令根本没发出去就别让闩压着 —— 压满 2.5s 只是把进度条钉在一个到不了的位置上。
            *self.seek_latch.lock().unwrap() = None;
        }
        r
    }
    /* seek 之后、mpv 真正跳过去之前,`time-pos` 仍**报得出**旧位置(不是读不到)。
       轮询正好落在这个窗口里,界面就会把用户刚拖到的位置弹回原处 —— 而画面已经跳走了。
       这就是「拖完进度条自己跳回去、条和画面对不上」的直接来源。
       所以在 seek 到位之前一律报目标位置;到位(或等超时)就立刻放行真值。 */
    /// 返回 (对外报的位置, 这次 seek 是不是卡住了)。
    fn latched_time(&self) -> (f64, bool) {
        /* ★ 传**这一拍真读到的**值(try_f64,读不到就是 None),不能传 sticky_f64 ——
           理由见 apply_seek_latch 上方那段。粘性回落只在闩已经松掉、且属性确实
           读不到时才用得上,所以放在返回 None 的那条分支里。 */
        let fresh = self.try_f64("time-pos");
        let seeking = self.get_str("seeking").as_deref() == Some("yes");
        let mut latch = self.seek_latch.lock().unwrap();
        // 先判卡死再套闩:apply_seek_latch 可能把闩清掉,清掉之后就无从判断了。
        let stalled = seek_stalled(&latch, seeking);
        let out = apply_seek_latch(&mut latch, fresh, seeking);
        drop(latch);
        let pos = match out {
            Some(v) => {
                self.last_pos.store(v.to_bits(), Ordering::Relaxed);
                v
            }
            None => f64::from_bits(self.last_pos.load(Ordering::Relaxed)),
        };
        (pos, stalled)
    }

    pub fn status(&self) -> Status {
        let (time, seek_stalled) = self.latched_time();
        Status {
            time,
            seek_stalled,
            duration: self.sticky_f64("duration", &self.last_dur),
            paused: self.get_str("pause").as_deref() == Some("yes"),
            /* demuxer-cache-time 是**已缓冲数据的最后一个时间戳(绝对)**,不是时长
               (那是 demuxer-cache-duration)。界面按 buffered/duration 画缓冲条,
               口径正是绝对位置,别顺手改成 duration 版。 */
            buffered: self.sticky_f64("demuxer-cache-time", &self.last_buf),
            /* ★ 用 `eof-reached` 属性判播完,**不能**只靠 END_FILE 事件:
               我们开着 keep-open=yes,mpv 到结尾时是「暂停在最后一帧」而**不卸载文件**,
               这种情况下 END_FILE 压根不发 —— 只监听事件就是个永远不触发的死分支。
               mpv 文档里 eof-reached 正是为 keep-open 场景准备的。
               事件那条线仍保留(reason=EOF 时会置位),两者取或,谁先到算谁。 */
            eof: self.get_str("eof-reached").as_deref() == Some("yes")
                || self.eof.load(Ordering::Relaxed),
            video: self.video_diag(),
        }
    }

    /* ★ 「有声音没画面」的自诊断。
       这类故障在安卓上**一声不吭**:mpv 起得来、文件也加载了、音频照放,只是
       vo 那条链没出画面。日志默认关着(见 LP_MPV_LOG 那段的理由),机顶盒上又没有终端,
       于是唯一能拿到的信息就是用户一句"黑屏" —— 我已经因此猜了两轮。
       现在把 mpv 自己知道的三件事读回来交给界面:有没有视频轨、vo 有没有起来、
       解出来的尺寸是多少。三者一比就能分清是"片子本来就没视频轨"、"vo 没起来"
       还是"起来了但没帧",而不必再猜。

       用 get_str 读现成属性,不额外引 mpv_request_log_messages —— 那要在两套 ffi
       (Windows 链接期 + Linux/安卓 dlopen)里各加一份声明,为一条诊断不值当。 */
    fn video_diag(&self) -> VideoDiag {
        let n = |k: &str| self.get_str(k).and_then(|s| s.parse::<i64>().ok()).unwrap_or(0);
        VideoDiag {
            // 空字符串 = vo 没配置起来(而不是"没有这个属性")
            vo: self.get_str("current-vo").unwrap_or_default(),
            width: n("dwidth"),
            height: n("dheight"),
            has_video_track: self.get_str("video-codec").is_some_and(|s| !s.is_empty()),
            hwdec: self.get_str("hwdec-current").unwrap_or_default(),
        }
    }
    pub fn tracks(&self) -> Vec<Track> {
        let count = self.get_str("track-list/count").and_then(|s| s.parse::<usize>().ok()).unwrap_or(0);
        let mut v = Vec::new();
        for i in 0..count {
            let kind = self.get_str(&format!("track-list/{i}/type")).unwrap_or_default();
            if kind != "audio" && kind != "sub" { continue; }
            v.push(Track {
                kind,
                id: self.get_str(&format!("track-list/{i}/id")).unwrap_or_default(),
                title: self.get_str(&format!("track-list/{i}/title")).unwrap_or_default(),
                lang: self.get_str(&format!("track-list/{i}/lang")).unwrap_or_default(),
                selected: self.get_str(&format!("track-list/{i}/selected")).as_deref() == Some("yes"),
                // 正则筛选要匹配编码和声道(wiki regex-filters 的口径),所以这两个必须取。
                codec: self.get_str(&format!("track-list/{i}/codec")).unwrap_or_default(),
                channels: self
                    .get_str(&format!("track-list/{i}/demux-channel-count"))
                    .and_then(|s| s.parse().ok())
                    .unwrap_or(0),
            });
        }
        v
    }
    pub fn set_track(&self, kind: &str, id: &str) {
        let prop = if kind == "audio" { "aid" } else { "sid" };
        self.set_str(prop, id);
    }
    /// 按偏好一次性应用音轨/字幕(None=不动)。
    pub fn apply_tracks(&self, aid: Option<String>, sid: Option<String>) {
        if let Some(a) = aid {
            self.set_str("aid", &a);
        }
        if let Some(s) = sid {
            self.set_str("sid", &s);
        }
    }

    // ================= 播放器能力面 =================
    // 对齐旧 Flutter 三端契约 lib/core/services/video_player_service.dart。
    // 之前只搬了 load/pause/seek/track 这几样,草稿要的倍速/音量/截图/画面比例/延迟/
    // 字幕样式/超分全没搬 → UI 上就是一排"点了没反应"的死按钮。这里补齐。

    /// 通用属性读/写 + 命令。插件桥和一次性调参靠它(Flutter 的 mpvGetProperty/
    /// mpvSetProperty/mpvCommand 同源);有专用方法的优先用专用方法。
    pub fn get_property(&self, name: &str) -> Option<String> {
        self.get_str(name)
    }
    pub fn set_property(&self, name: &str, value: &str) {
        self.set_str(name, value);
    }
    pub fn command(&self, args: &[String]) -> Result<(), String> {
        let refs: Vec<&str> = args.iter().map(|s| s.as_str()).collect();
        self.cmd(&refs)
    }

    /// 倍速。mpv 的 speed 同时变调,配 audio-pitch-correction(默认开)保音高。
    pub fn set_speed(&self, speed: f64) {
        self.set_str("speed", &speed.clamp(0.1, 6.0).to_string());
    }
    pub fn speed(&self) -> f64 {
        let v = self.get_f64("speed");
        if v <= 0.0 { 1.0 } else { v }
    }

    /// 音量 0..=130(mpv 上限 130 是软增益)。
    pub fn set_volume(&self, vol: f64) {
        self.set_str("volume", &vol.clamp(0.0, 130.0).to_string());
    }
    pub fn volume(&self) -> f64 {
        self.get_f64("volume")
    }
    pub fn set_mute(&self, mute: bool) {
        self.set_str("mute", if mute { "yes" } else { "no" });
    }
    pub fn muted(&self) -> bool {
        self.get_str("mute").as_deref() == Some("yes")
    }

    /// 截图到文件。用 screenshot-to-file 而非 screenshot-raw:后者要走 mpv_node
    /// 取原始像素再自己编码,而我们只需要落一个 png 给用户。
    /// each-frame=no;"video" = 不带 OSD/字幕的原始画面。
    pub fn screenshot_to(&self, path: &str) -> Result<(), String> {
        self.cmd(&["screenshot-to-file", path, "video"])
    }

    /// 音画同步:音频延迟(秒,可负)。
    pub fn set_audio_delay(&self, secs: f64) {
        self.set_str("audio-delay", &secs.to_string());
    }
    pub fn audio_delay(&self) -> f64 {
        self.get_f64("audio-delay")
    }
    /// 字幕延迟(秒,可负)。
    pub fn set_sub_delay(&self, secs: f64) {
        self.set_str("sub-delay", &secs.to_string());
    }
    pub fn sub_delay(&self) -> f64 {
        self.get_f64("sub-delay")
    }

    /// 画面比例。"" / "-1" = 还原源比例(mpv 用 video-aspect-override=-1 复位)。
    pub fn set_aspect_ratio(&self, ratio: &str) {
        let v = if ratio.is_empty() || ratio == "auto" { "-1" } else { ratio };
        self.set_str("video-aspect-override", v);
    }

    /// 硬解档位。零拷贝(d3d11va)在 Win 上是默认最佳;软解排查问题用 "no"。
    /// 见 [[desktop-double-audio-orphan-player]]:Win 默认 d3d11va 零拷贝。
    pub fn set_hwdec(&self, mode: &str) {
        self.set_str("hwdec", mode);
    }
    pub fn hwdec(&self) -> String {
        self.get_str("hwdec-current")
            .or_else(|| self.get_str("hwdec"))
            .unwrap_or_default()
    }

    // ---- 字幕样式(对齐 Flutter setSubtitleFont/Size/Position/Background/BlendMode)----
    pub fn set_sub_font(&self, font: &str) {
        // 「默认」是 UI 占位,不该塞给 libass(见 [[android-mpv-subtitle-fonts]] 同款守卫)。
        if font.is_empty() || font == "默认" {
            return;
        }
        self.set_str("sub-font", font);
    }
    /// 字幕缩放倍率。**这才是「字幕大小」该拧的那颗旋钮**。
    ///
    /// 2026-07-16 用 ctypes 直接问 libmpv(v0.41.0-744)实测:
    ///   - `sub-ass-override` 默认 = `scale` —— 这个模式下 ASS 字幕**只认 `sub-scale`,
    ///     完全忽略 `sub-font-size`**。而内封字幕(尤其番剧)绝大多数是 ASS。
    ///   - `secondary-sub-ass-override` 默认 = `strip` —— ASS 标记被剥成纯文本,
    ///     于是它**反过来只认 `sub-font-size`**。
    /// 合起来正是用户 2026-07-16 报的那个怪象:「只能调次字幕的字体大小,主字幕的调不动」——
    /// 同一个 sub-font-size,对主(ASS 保样式)无效、对次(被 strip 成纯文本)有效。
    /// `sub-scale` 对 ASS 与纯文本都生效,所以大小统一走它。别再拿 sub-font-size 当大小旋钮。
    pub fn set_sub_scale(&self, scale: f64) {
        self.set_str("sub-scale", &format!("{:.2}", scale.clamp(0.2, 4.0)));
    }
    /// 次字幕的 ASS 处理模式。mpv 默认 `strip`(剥成纯文本)= 用户说的「次字幕不渲染样式」。
    /// `scale` 则与主字幕同规矩:保留 ASS 自带样式。取值必须是 mpv 认的枚举,别乱传。
    pub fn set_secondary_sub_ass_override(&self, mode: &str) {
        if !matches!(mode, "no" | "scale" | "force" | "strip") {
            return; // 传错值 mpv 只会静默拒绝,这里先挡掉,免得以为设上了
        }
        self.set_str("secondary-sub-ass-override", mode);
    }
    /// 字幕竖直位置 0(顶)..100(底)。mpv 只收整数(见 [[macos-no-video-hwdec]])。
    pub fn set_sub_position(&self, pos: f64) {
        self.set_str("sub-pos", &(pos.clamp(0.0, 100.0).round() as i64).to_string());
    }
    pub fn set_sub_background(&self, enabled: bool) {
        // 半透明黑底 vs 全透明;ASS 自带样式的字幕不受此影响。
        self.set_str("sub-back-color", if enabled { "#80000000" } else { "#00000000" });
    }
    pub fn set_sub_blend_mode(&self, mode: &str) {
        self.set_str("blend-subtitles", mode);
    }

    // ---- 次字幕/双字幕(对齐 Flutter loadSecondarySubtitle/selectSecondary…)----
    pub fn set_secondary_sub(&self, id: &str) {
        self.set_str("secondary-sid", if id.is_empty() { "no" } else { id });
    }
    pub fn add_secondary_sub(&self, url: &str, title: &str) -> Result<(), String> {
        // sub-add 挂上后再指给 secondary-sid;取新挂那条(sub 列表末尾)。
        self.cmd(&["sub-add", url, "auto", title])?;
        if let Some(id) = self.last_sub_id() {
            self.set_secondary_sub(&id);
        }
        Ok(())
    }
    pub fn set_secondary_sub_delay(&self, secs: f64) {
        self.set_str("secondary-sub-delay", &secs.to_string());
    }
    pub fn set_secondary_sub_position(&self, pos: f64) {
        self.set_str("secondary-sub-pos", &(pos.clamp(0.0, 100.0).round() as i64).to_string());
    }
    /// 最后一条字幕轨的 id(sub-add 之后取新挂的那条)。
    fn last_sub_id(&self) -> Option<String> {
        self.tracks()
            .into_iter()
            .filter(|t| t.kind == "sub")
            .next_back()
            .map(|t| t.id)
    }

    /// 超分(Anime4K):按档位挂 glsl-shaders。空列表 = 关。
    /// 传绝对路径列表;mpv 的 glsl-shaders 用 ; 分隔,路径里的 ; 和 " 需转义。
    pub fn set_shaders(&self, paths: &[String]) {
        if paths.is_empty() {
            self.set_str("glsl-shaders", "");
            return;
        }
        let joined = paths.join(";");
        self.set_str("glsl-shaders", &joined);
    }
    /// shader 参数(mpv glsl-shader-opts)。hooke007 那套 shader 全靠参数调强度,
    /// 不设 = 一直吃默认值(CAS STR=0.5 只开一半)。返回是否设上了 —— 参数名写错
    /// mpv 会拒掉整个选项,而且**不会有任何提示**,必须回读。
    pub fn set_shader_opts(&self, opts: &str) -> bool {
        self.set_str("glsl-shader-opts", opts);
        self.get_str("glsl-shader-opts").as_deref() == Some(opts)
    }

    /// 源画面尺寸(dwidth/dheight 是**显示**尺寸,已算进非方像素/裁剪,正是 shader 里的 MAIN)。
    /// 没在播 → None。
    pub fn video_size(&self) -> Option<(f64, f64)> {
        let w = self.get_str("dwidth")?.parse().ok()?;
        let h = self.get_str("dheight")?.parse().ok()?;
        Some((w, h))
    }
    /// mpv 输出区尺寸(= shader 里的 OUTPUT)。窗口大小,不是屏幕大小。
    pub fn output_size(&self) -> Option<(f64, f64)> {
        let w = self.get_str("osd-width")?.parse().ok()?;
        let h = self.get_str("osd-height")?.parse().ok()?;
        Some((w, h))
    }

    /// 实际挂上的 shader 数(用于校验超分是否真生效 —— 见 [[superres-and-toast]]:
    /// 旧 Flutter 桌面端软件纹理根本不跑 glsl-shader,回读才知道)。
    /// ⚠️ 它只说明 mpv **收下了**路径,**不代表 shader 会跑** —— 见 will_run()。
    pub fn shader_count(&self) -> usize {
        self.get_str("glsl-shaders")
            .map(|s| s.split(';').filter(|x| !x.trim().is_empty()).count())
            .unwrap_or(0)
    }
}

impl Drop for Player {
    fn drop(&mut self) {
        // 先停事件线程并 join,避免它在 ctx 销毁后仍访问(悬垂)。
        self.running.store(false, Ordering::Relaxed);
        if let Some(h) = self.event_thread.take() {
            let _ = h.join();
        }
        unsafe { mpv_terminate_destroy(self.ctx); }
    }
}

#[derive(serde::Serialize)]
pub struct Status {
    pub time: f64,
    pub duration: f64,
    pub paused: bool,
    pub buffered: f64,
    /// 本片是否已正常播放到结尾(keep-open=yes 时画面停在最后一帧,时间不再前进)。
    pub eof: bool,
    /// mpv 已经在这一次 seek 上卡了很久(见 [`SEEK_STALL_TIMEOUT`])。
    /// 界面拿它把「跳过去以后画面和进度条都不动」这件事**说出来**,而不是让用户干等。
    pub seek_stalled: bool,
    /// 画面这条链的自检结果。见 [`Player::video_diag`]。
    pub video: VideoDiag,
}

/// 视频输出的实况。**给"有声音没画面"用** —— 界面拿它说出具体是哪一环断了,
/// 而不是让用户对着一块黑屏猜。
#[derive(serde::Serialize, Clone, Default)]
pub struct VideoDiag {
    /// 实际生效的 vo。空 = 视频输出根本没起来。
    pub vo: String,
    pub width: i64,
    pub height: i64,
    /// 当前文件里有没有视频轨(纯音频文件是正常的,不该报错)。
    pub has_video_track: bool,
    /// 实际生效的硬解。安卓上期望是 mediacodec-copy;空 = 退回软解。
    pub hwdec: String,
}

impl VideoDiag {
    /// 说人话的故障描述;None = 没毛病(或本来就是纯音频)。
    pub fn problem(&self) -> Option<String> {
        if !self.has_video_track {
            return None; // 纯音频文件,黑屏是对的
        }
        if self.vo.is_empty() {
            return Some(format!(
                "有视频轨但视频输出没起来(current-vo 是空的,hwdec={})。\
                 多半是渲染面没接上或 GPU 上下文初始化失败。",
                if self.hwdec.is_empty() { "无" } else { &self.hwdec }
            ));
        }
        if self.width <= 0 || self.height <= 0 {
            return Some(format!(
                "视频输出({})起来了,但解不出画面尺寸 —— 解码器没吐帧。",
                self.vo
            ));
        }
        None
    }
}


#[cfg(test)]
mod tests {
    use super::*;

    /* 「有声音没画面」的自诊断必须分得清三种情况 —— 分不清就等于没有诊断,
       用户看到的还是一句放之四海而皆准的废话,而我又得靠猜。

       反向验证(2026-07-21 实跑):把 problem() 里 `if !self.has_video_track` 那条
       提前 return 删掉 → 「纯音频」这条立刻红(纯音频文件被当成故障报出去,
       用户放一首歌就会看到"视频输出没起来"的吓人提示)。 */
    #[test]
    fn video_diag_tells_the_three_failures_apart() {
        let ok = VideoDiag {
            vo: "gpu".into(), width: 1920, height: 1080,
            has_video_track: true, hwdec: "mediacodec-copy".into(),
        };
        assert_eq!(ok.problem(), None, "一切正常时不该报任何问题");

        /* 纯音频:黑屏是对的,绝不能报错。
           ★ 这里必须照**真实**的纯音频状态构造 —— vo 空、尺寸 0,而不是只把
             has_video_track 翻成 false 却留着 vo=gpu/1920x1080。
             照后者写出来的是一条**假绿**测试:把 has_video_track 那道守卫整个删掉
             它也照样过(实测过),等于什么都没守住。 */
        let audio_only = VideoDiag {
            vo: String::new(), width: 0, height: 0,
            has_video_track: false, hwdec: String::new(),
        };
        assert_eq!(audio_only.problem(), None, "纯音频文件不是故障");

        // vo 没起来 —— 安卓上「有声音没画面」最可能的那一种。
        let no_vo = VideoDiag { vo: String::new(), ..ok.clone() };
        let m = no_vo.problem().expect("vo 空必须报出来");
        assert!(m.contains("视频输出没起来"), "说法要具体,实际是:{m}");
        assert!(m.contains("mediacodec-copy"), "得带上 hwdec,否则没法判断是哪一层断的");

        // vo 起来了但没帧。
        let no_frame = VideoDiag { width: 0, height: 0, ..ok.clone() };
        let m = no_frame.problem().expect("尺寸为 0 必须报出来");
        assert!(m.contains("没吐帧"), "要和 vo 没起来区分开,实际是:{m}");
    }

    /* 回归:起播路径上的外挂字幕必须真的挂上。

       这条测试盯的是一个**静默**的 bug:`loadfile` 是异步命令,它只把条目排进
       playlist 就返回,此刻并没有「当前文件」。紧跟着发 `sub-add` 会拿到
       -12 error running command,而旧代码是 `let _ = self.cmd(...)` —— 错误被吞掉,
       日志里还照打一行「挂载外挂字幕 N 条」。于是两端表现完全一致:
       详情页看得见字幕(那是 Emby 的 MediaStreams),播放页字幕列表却是空的。

       反向验证方式:把 add_subtitle 里的 `if !st.loaded { …排队…; return; }` 删掉
       (退回成无条件立刻 sub-add),这条测试立刻红。

       要真 libmpv + 桌面会话(Player::new 会建叠加窗口),所以默认 ignore。
       跑:cargo test -p linplayer-mpv --lib external_subtitle -- --ignored --nocapture */
    #[test]
    #[ignore]
    fn external_subtitle_survives_async_loadfile() {
        let srt = std::env::temp_dir().join("lp_ext_sub_test.srt");
        std::fs::write(&srt, "1\n00:00:00,000 --> 00:00:04,000\nHELLO-EXTERNAL\n").unwrap();

        let p = Player::new().expect("mpv 起不来(需要 libmpv-2.dll 与桌面会话)");
        // lavfi 造一段本地视频源,不依赖任何服务器。
        p.load_at("av://lavfi:testsrc=size=320x240:duration=10", 0.0)
            .expect("loadfile 失败");
        // ★ 复刻真实调用时序:load 之后**立刻**挂,不做任何等待 —— 两端的起播路径就是这样。
        p.add_subtitle(&srt.to_string_lossy(), "外挂测试");

        // 挂载由事件线程在 FILE_LOADED 时完成,给它一点时间(本地源通常几十毫秒)。
        let mut subs = Vec::new();
        for _ in 0..50 {
            std::thread::sleep(std::time::Duration::from_millis(100));
            subs = p.tracks().into_iter().filter(|t| t.kind == "sub").collect();
            if !subs.is_empty() {
                break;
            }
        }

        assert!(
            !subs.is_empty(),
            "外挂字幕没挂上 —— 播放页的字幕列表就会是空的(这正是用户报的现象)"
        );
        assert!(
            subs.iter().any(|t| t.title == "外挂测试"),
            "挂上了但标题丢了 —— 字幕列表里会是一条空白项,等于选不了。实到:{:?}",
            subs.iter().map(|t| &t.title).collect::<Vec<_>>()
        );
    }

    /* 用户报的「拖完进度条自己跳回去 / 条和画面对不上」的回归钉。

       时序:seek(600) 发出后,mpv 的 time-pos **仍报得出**旧位置 120s(不是读不到),
       要等解码器真跳过去才变。前端每 250ms 轮询一次,必然打进这个窗口 ——
       没有闩的话界面就把 120 画上去,而画面已经在 600 了。

       反向验证:把 status() 里的 `self.latched_time(reported)` 改回 `reported`,
       第一条断言立刻红(1000 != 600)。 */
    fn latch_at(target: f64, at: std::time::Instant) -> Option<SeekLatch> {
        Some(SeekLatch { target, at, saw_seeking: false })
    }
    fn latch(target: f64) -> Option<SeekLatch> {
        latch_at(target, std::time::Instant::now())
    }

    #[test]
    fn seek_latch_reports_target_until_mpv_catches_up() {
        let mut l = latch(600.0);

        // 刚发完 seek,mpv 还报旧位置 -> 必须报目标位,不能弹回旧位置。
        assert_eq!(apply_seek_latch(&mut l, Some(120.0), false), Some(600.0));
        assert!(l.is_some(), "还没到位,闩不能提前松");

        // mpv 落到最近关键帧(599.2,差 0.8s < 容差)-> 算到位,放行真值并松闩。
        assert_eq!(apply_seek_latch(&mut l, Some(599.2), false), Some(599.2));
        assert!(l.is_none(), "到位后必须松闩,否则真值永远出不来");

        // 松闩之后一律透传,进度条继续正常走。
        assert_eq!(apply_seek_latch(&mut l, Some(601.5), false), Some(601.5));
    }

    /* 闩必须有超时。seek 失败(网络流跳不过去)时若一直压制,
       现象会从「弹回旧位置」变成更难查的「进度条永远不动」—— 那是拿一个 bug 换另一个。 */
    #[test]
    fn seek_latch_gives_up_after_timeout() {
        let stale =
            std::time::Instant::now() - SEEK_LATCH_TIMEOUT - std::time::Duration::from_millis(1);
        let mut l = latch_at(600.0, stale);
        assert_eq!(
            apply_seek_latch(&mut l, Some(120.0), false),
            Some(120.0),
            "超时后必须放行真值"
        );
        assert!(l.is_none());
    }

    /* ★ 用户 2026-07-27 报的「服务器上一拖就乱」的回归钉。

       网络流 seek 期间 time-pos 会**时有时无**。老实现把「读不到就沿用上次」的粘性值
       喂给闩,而粘性值此刻正好等于目标位 —— 一比就相等,闩当场自解除;下一拍 mpv 报的
       还是旧位置,进度条于是跳回去(或跳到缓冲位置),画面和读数彻底对不上。

       反向验证(必须做,见 [[test-must-fail-first]]):把 latched_time 里的
       `self.try_f64("time-pos")` 换回 `Some(self.sticky_f64(...))`,或把本函数第一行
       的 `let Some(r) = reported else ...` 删掉,这条立刻红。 */
    #[test]
    fn seek_latch_survives_unreadable_time_pos() {
        let mut l = latch(600.0);
        // 第一拍:位置读不到(网络流 seek 中的常态)。绝不能因此松闩。
        assert_eq!(apply_seek_latch(&mut l, None, false), Some(600.0));
        assert!(l.is_some(), "位置暂时读不到不等于 seek 到位了,闩不能松");
        // 第二拍:位置回来了,但 mpv 还没跳过去,报的仍是旧位置 -> 继续压制。
        assert_eq!(apply_seek_latch(&mut l, Some(120.0), false), Some(600.0));
        assert!(l.is_some());
    }

    /* mpv 的 seek 落点可以离目标很远(只能落关键帧,或服务端 Range 给的位置)。
       只靠 1.5s 容差的话,这种 seek 要一直压到超时才放行 —— 中间进度条是钉住的。
       `seeking` 属性给的是权威信号:见过 yes 再回到 no = 确定落地,立刻放行真值。 */
    #[test]
    fn seek_latch_releases_when_mpv_finishes_seeking() {
        let mut l = latch(600.0);
        assert_eq!(apply_seek_latch(&mut l, Some(120.0), true), Some(600.0), "seek 中报目标位");
        assert!(l.is_some());
        // seeking 落回 no,而落点离目标 5s(远超容差)—— 照样必须松闩放行真值。
        assert_eq!(apply_seek_latch(&mut l, Some(595.0), false), Some(595.0));
        assert!(l.is_none(), "mpv 已经 seek 完了,闩没有理由再压");
    }

    /* seek 做得久(慢服务器)不该被超时打断:只要 mpv 还在 seek,就一直报目标位。
       否则超时一到就放行旧位置 —— 正是「画面回退了、进度条反而前进」的来源。 */
    #[test]
    fn seek_latch_timeout_does_not_fire_while_still_seeking() {
        let stale =
            std::time::Instant::now() - SEEK_LATCH_TIMEOUT - std::time::Duration::from_secs(5);
        let mut l = latch_at(600.0, stale);
        assert_eq!(apply_seek_latch(&mut l, Some(120.0), true), Some(600.0));
        assert!(l.is_some(), "mpv 还在 seek,超时不该生效");
    }

    /* 「跳到缓存条没缓存到的地方就卡死,画面和进度条都不动」。
       根因在服务器:它宣称 Accept-Ranges 却对 Range 请求回 200 + 整个文件,
       ffmpeg 只能顺读丢弃到目标字节(跳 9 分钟 = 370MB)。我们改不了那件事,
       但**不能让用户对着一个不动的进度条干等** —— 卡够久就得说出来。

       反向验证(见 [[test-must-fail-first]]):把 seek_stalled 里的 `seeking &&`
       删掉,第一条断言(没在 seek 就不算卡)当场红;把 `l.at.elapsed() >= …`
       改成 `true`,第二条(刚发出去的 seek 不算卡)当场红。 */
    #[test]
    fn seek_stall_is_only_reported_when_mpv_is_stuck_seeking() {
        let fresh = latch(600.0);
        assert!(!seek_stalled(&fresh, true), "刚发出去的 seek 不算卡");
        assert!(!seek_stalled(&fresh, false), "没在 seek 更不算卡");

        let old = latch_at(
            600.0,
            std::time::Instant::now() - SEEK_STALL_TIMEOUT - std::time::Duration::from_secs(1),
        );
        assert!(seek_stalled(&old, true), "mpv 还在 seek 且已经过了很久 = 卡住了");
        /* ★ 这一条是关键:seeking=no 说明 mpv 早就跳完了,闩只是还没被下一拍收掉。
           不判 seeking 的话,任何一次超过 12 秒没再动过的播放都会被误报成"卡住"。 */
        assert!(!seek_stalled(&old, false), "mpv 说自己没在 seek,那就不是卡在 seek 上");
        assert!(!seek_stalled(&None, true), "没有闩就没有正在进行的 seek");
    }

    /* 用户报的「视频还没加载完就点进度条跳转」。
       mpv 在 FILE_LOADED 之前**没有文件可跳**,那时发 `seek` 只会拿回一个命令错误 ——
       而闩已经设上了,于是进度条压着用户点的位置 2.5s,再弹回 `start=` 的续播点,
       画面从头到尾没动过。解法和外挂字幕同一个:没开好就排队,FILE_LOADED 再补发。

       反向验证(见 [[test-must-fail-first]]):把 queue_seek 的 `if self.loaded` 分支
       删掉、改成无条件 `return true`,本测试第一条断言当场红。 */
    #[test]
    fn seek_before_file_loaded_is_queued_not_sent() {
        let mut st = SubState::default(); // loaded=false —— loadfile 刚发出去的状态
        assert!(!st.queue_seek(300.0), "文件没开好就不能发 seek,必须排队");
        assert_eq!(st.pending_seek, Some(300.0));

        // 起播途中连点几下:只有最后那次算数(和 seek 的语义一致,排成队会跳一串)。
        assert!(!st.queue_seek(900.0));
        assert_eq!(st.pending_seek, Some(900.0));

        // FILE_LOADED 之后就该当场发,不再入队。
        st.loaded = true;
        st.pending_seek = None;
        assert!(st.queue_seek(120.0), "文件已开好,seek 必须立刻发出去");
        assert_eq!(st.pending_seek, None, "已开好的文件不该再往队列里塞");
    }
}
