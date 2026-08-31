//! SPIKE S1.2 · 核心层桩:视频通道 B(SPEC §7.2 / §5.1 第 3 组)
//!
//! 只做一件事:把 libmpv 的 render API 包成 SPEC 里那 5 个 `lp_gl_*` 导出,
//! 让 Avalonia 侧**只拿得到 `fbo / w / h / flip_y`**,拿不到任何 mpv 类型。
//! 这正是要验的东西之一 —— SPEC 那个窄接口到底够不够 UI 侧用(SPEC §7.1:UI 层不直接调 libmpv)。
//!
//! ## 契约里的五条硬约束(SPEC §7.2),本文件怎么对应
//!
//! 1. 五个函数必须在同一个线程、且 GL 上下文 current 时调用 —— 所以这里**不加锁**,
//!    全局状态是裸指针。加锁只会掩盖调用方违约,让它变成偶发。
//! 2. `lp_gl_swapped()` 不许省 —— 见 `mpv_render_context_report_swap`。
//!    本桩**故意不替调用方兜底**:漏调就该掉帧,S1.2 要拿这个做反向验证。
//! 3. `lp_gl_uninit()` 阻塞返回 —— `mpv_render_context_free` 本身就是阻塞的。
//! 4. 一个进程只能有一条 GL 通道 —— 全局单例,重复 init 直接返回错误码。
//! 5. `flip_y` 由核心层翻,宿主别再翻一次。
//!
//! ## 不属于契约的部分
//!
//! `lp_spike_*` 系列是 SPIKE 专用的取数口子,**不在 SPEC §5.1 的 13 个导出里**。
//! 真正的核心层用 `lp_call` + 事件队列做这些事,那条链路是 SPIKE-2 的范围。

use std::ffi::{c_char, c_int, c_void, CStr, CString};
use std::ptr;
use std::sync::atomic::{AtomicBool, AtomicU64, Ordering};

// ---------------------------------------------------------------- libmpv FFI

#[link(name = "mpv")]
extern "C" {
    fn mpv_create() -> *mut c_void;
    fn mpv_initialize(ctx: *mut c_void) -> c_int;
    fn mpv_set_option_string(ctx: *mut c_void, name: *const c_char, data: *const c_char) -> c_int;
    fn mpv_command(ctx: *mut c_void, args: *const *const c_char) -> c_int;
    fn mpv_get_property_string(ctx: *mut c_void, name: *const c_char) -> *mut c_char;
    fn mpv_free(data: *mut c_void);
    fn mpv_wait_event(ctx: *mut c_void, timeout: f64) -> *mut c_void;
    fn mpv_terminate_destroy(ctx: *mut c_void);

    fn mpv_render_context_create(
        res: *mut *mut c_void,
        mpv: *mut c_void,
        params: *mut RenderParam,
    ) -> c_int;
    fn mpv_render_context_render(ctx: *mut c_void, params: *mut RenderParam) -> c_int;
    fn mpv_render_context_update(ctx: *mut c_void) -> u64;
    fn mpv_render_context_report_swap(ctx: *mut c_void);
    fn mpv_render_context_free(ctx: *mut c_void);
}

#[repr(C)]
struct RenderParam {
    ty: c_int,
    data: *mut c_void,
}

/// `mpv_opengl_init_params`。第三个字段 `extra_exts` 在新版 mpv 里已移除,
/// 这里保留并置空:多给一个字段永远安全,少给一个在老版上就是越界读。
#[repr(C)]
struct GlInitParams {
    get_proc_address: *mut c_void,
    get_proc_address_ctx: *mut c_void,
    extra_exts: *const c_char,
}

#[repr(C)]
struct GlFbo {
    fbo: c_int,
    w: c_int,
    h: c_int,
    internal_format: c_int,
}

const PARAM_INVALID: c_int = 0;
const PARAM_API_TYPE: c_int = 1;
const PARAM_OPENGL_INIT_PARAMS: c_int = 2;
const PARAM_OPENGL_FBO: c_int = 3;
const PARAM_FLIP_Y: c_int = 4;
const PARAM_ADVANCED_CONTROL: c_int = 10;
const PARAM_BLOCK_FOR_TARGET_TIME: c_int = 12;

const UPDATE_FRAME: u64 = 1;

// ---------------------------------------------------------------- 全局状态

/// 一个进程只能有一条 GL 通道(SPEC §7.2 约束 4),所以是全局单例而不是句柄。
/// 不加锁:契约要求全部在同一线程调用,加锁只会把违约变成偶发难查的问题。
static mut MPV: *mut c_void = ptr::null_mut();
static mut RCTX: *mut c_void = ptr::null_mut();

static RENDER_CALLS: AtomicU64 = AtomicU64::new(0);
static SWAPPED_CALLS: AtomicU64 = AtomicU64::new(0);
static DRAIN_STOP: AtomicBool = AtomicBool::new(false);

const E_OK: c_int = 0;
const E_ALREADY: c_int = -1; // 重复 init
const E_NO_MPV: c_int = -2; // mpv 还没起来
const E_MPV: c_int = -3; // libmpv 自己返回的错误

/// 事件线程:光渲染不取事件,mpv 的事件队列会一直堆着。
/// 生产环境这条线是 `lp_next_event`(SPEC §5.1 第 1 组),和 GL 线程必须是两条 —— 这里照样分开。
fn spawn_drain(mpv: usize) {
    std::thread::spawn(move || {
        let h = mpv as *mut c_void;
        while !DRAIN_STOP.load(Ordering::Relaxed) {
            unsafe {
                mpv_wait_event(h, 0.1);
            }
        }
    });
}

/// 读一次就够,但每帧读环境变量的开销可以忽略,SPIKE 里不值得为它加缓存。
fn block_for_target_time() -> c_int {
    match std::env::var("LP_BLOCK_FOR_TARGET_TIME").as_deref() {
        Ok("0") => 0,
        _ => 1,
    }
}

unsafe fn set_opt(h: *mut c_void, k: &str, v: &str) -> c_int {
    let ck = CString::new(k).unwrap();
    let cv = CString::new(v).unwrap();
    mpv_set_option_string(h, ck.as_ptr(), cv.as_ptr())
}

// ---------------------------------------------------------------- SPEC §5.1 第 3 组

/// 绑定 GL 上下文,建 mpv render context。
/// `get_proc_address` 签名:`void* (*)(void* ctx, const char* name)`
/// —— SPEC §5.3「禁止传函数指针」的唯一显式例外。
#[no_mangle]
pub extern "C" fn lp_gl_init(get_proc_address: *mut c_void, get_proc_address_ctx: *mut c_void) -> c_int {
    unsafe {
        if !RCTX.is_null() {
            return E_ALREADY;
        }
        if MPV.is_null() {
            return E_NO_MPV;
        }

        let api = CString::new("opengl").unwrap();
        let mut gl = GlInitParams {
            get_proc_address,
            get_proc_address_ctx,
            extra_exts: ptr::null(),
        };
        // ADVANCED_CONTROL=1 是 report_swap 有意义的前提。开了它就**必须**调 lp_gl_swapped,
        // 否则 mpv 不知道帧何时上屏,帧率控制整个是瞎的(SPIKE-1b §7 第 3 条)。
        let mut adv: c_int = 1;

        let mut params = [
            RenderParam { ty: PARAM_API_TYPE, data: api.as_ptr() as *mut c_void },
            RenderParam { ty: PARAM_OPENGL_INIT_PARAMS, data: &mut gl as *mut _ as *mut c_void },
            RenderParam { ty: PARAM_ADVANCED_CONTROL, data: &mut adv as *mut _ as *mut c_void },
            RenderParam { ty: PARAM_INVALID, data: ptr::null_mut() },
        ];

        let mut ctx: *mut c_void = ptr::null_mut();
        let r = mpv_render_context_create(&mut ctx, MPV, params.as_mut_ptr());
        if r < 0 {
            return E_MPV;
        }
        RCTX = ctx;

        E_OK
    }
}

/// 有没有新帧要画。非 0 = 该重绘。暂停时恒 0,不白烧 GPU。
#[no_mangle]
pub extern "C" fn lp_gl_wants_redraw() -> c_int {
    unsafe {
        if RCTX.is_null() {
            return 0;
        }
        ((mpv_render_context_update(RCTX) & UPDATE_FRAME) != 0) as c_int
    }
}

/// 渲一帧到宿主给的 FBO。`fbo == 0` 表示默认帧缓冲。
#[no_mangle]
pub extern "C" fn lp_gl_render(fbo: u32, width: c_int, height: c_int, flip_y: c_int) -> c_int {
    unsafe {
        if RCTX.is_null() {
            return E_NO_MPV;
        }
        let mut f = GlFbo {
            fbo: fbo as c_int,
            w: width,
            h: height,
            // 0 = 让 mpv 自己问 GL 要格式。宿主的 FBO 内部格式由宿主定,核心层不该猜。
            internal_format: 0,
        };
        let mut flip: c_int = flip_y;
        // block_for_target_time:mpv 默认在 render 里**阻塞到该帧的呈现时刻**。
        // 对裸 harness 无所谓,对 Avalonia 是把整条 UI 渲染线程按片源帧率钉住
        // (实测 4K24 下循环只转 25 次/秒)。用 LP_BLOCK_FOR_TARGET_TIME=0 关掉做对照。
        let mut block: c_int = block_for_target_time();
        let mut params = [
            RenderParam { ty: PARAM_OPENGL_FBO, data: &mut f as *mut _ as *mut c_void },
            RenderParam { ty: PARAM_FLIP_Y, data: &mut flip as *mut _ as *mut c_void },
            RenderParam { ty: PARAM_BLOCK_FOR_TARGET_TIME, data: &mut block as *mut _ as *mut c_void },
            RenderParam { ty: PARAM_INVALID, data: ptr::null_mut() },
        ];
        // 渲完不做任何 GL 状态复位。实测(S1.2 报告 §5.3):加了复位与不加,
        // Avalonia 侧的崩溃率没有差别(1/10 vs 2/10),而那个崩在**纯 Avalonia
        // 完全不碰核心层**时照样发生(2/10) —— 不是 mpv 弄脏状态造成的。
        let r = mpv_render_context_render(RCTX, params.as_mut_ptr());
        RENDER_CALLS.fetch_add(1, Ordering::Relaxed);
        if r < 0 {
            E_MPV
        } else {
            E_OK
        }
    }
}

/// 报告「上一帧真的上屏了」。渲完并 present 之后必须调。
/// ★ 漏了它 mpv 的帧率控制是瞎的。本桩**故意不兜底** —— S1.2 要拿这个做反向验证。
#[no_mangle]
pub extern "C" fn lp_gl_swapped() {
    unsafe {
        if RCTX.is_null() {
            return;
        }
        mpv_render_context_report_swap(RCTX);
        SWAPPED_CALLS.fetch_add(1, Ordering::Relaxed);
    }
}

/// 解绑并销毁 render context。必须在销毁 GL 上下文之前调,且阻塞返回。
#[no_mangle]
pub extern "C" fn lp_gl_uninit() {
    unsafe {
        if RCTX.is_null() {
            return;
        }
        // mpv_render_context_free 本身就阻塞到 mpv 确认不再碰这个 GL 上下文
        mpv_render_context_free(RCTX);
        RCTX = ptr::null_mut();
    }
}

// ---------------------------------------------------------------- SPIKE 专用(不在 SPEC 契约里)

/// 起 mpv(不起播)。生产环境这是 `lp_init`。
///
/// ★★ 时序约束(2026-08-31 实测):**起播必须排在 `lp_gl_init` 之后。**
/// `vo=libmpv` 在 render context 存在之前初始化会致命失败:
///   `[f][vo/libmpv] No render context set.`
///   `[f][cplayer] Error opening/initializing the selected video_out (--vo) device.`
/// 而且 **mpv 不会重试** —— 轨道当场被 deselect,`Video: no video`,整个文件就此作废。
/// 宿主侧看到的只是「一直黑屏、wants_redraw 恒 0」,没有任何回调会喊。
/// 所以起播和起 GL 通道分成两个函数,顺序由调用方保证。见 `lp_spike_play`。
#[no_mangle]
pub extern "C" fn lp_spike_open(hwdec: *const c_char) -> c_int {
    unsafe {
        if !MPV.is_null() {
            return E_ALREADY;
        }
        let h = mpv_create();
        if h.is_null() {
            return E_MPV;
        }
        let hw = if hwdec.is_null() {
            "auto".to_string()
        } else {
            CStr::from_ptr(hwdec).to_string_lossy().into_owned()
        };
        // audio=no:和 SPIKE-1b 的口径一致,否则音频时钟会替我们兜住节奏,量不出渲染循环的问题
        for (k, v) in [
            ("vo", "libmpv"),
            ("hwdec", hw.as_str()),
            ("terminal", "no"),
            ("keep-open", "yes"),
            ("audio", "no"),
        ] {
            set_opt(h, k, v);
        }
        // report_swap 喂的是 mpv 的 vsync 估计,只有 video-sync=display-* 才用得上。
        // 默认口径(video-sync=audio)下漏调它没有可测影响 —— 见 S1.2 报告 §5.4。
        if let Ok(vs) = std::env::var("LP_VIDEO_SYNC") {
            set_opt(h, "video-sync", &vs);
        }
        // 日志走 LP_MPV_LOG 门控,和仓库既有约定一致:log-file 会把 mpv+ffmpeg 钉在 debug 级,
        // 平时开着就是白烧磁盘(docs/lessons/player-mpv.md「mpv 发行版卫生」)
        if let Ok(path) = std::env::var("LP_MPV_LOG") {
            set_opt(h, "log-file", &path);
            set_opt(h, "msg-level", "all=v");
        }
        if mpv_initialize(h) < 0 {
            mpv_terminate_destroy(h);
            return E_MPV;
        }
        MPV = h;
        spawn_drain(h as usize);
        E_OK
    }
}

/// 起播。**必须在 `lp_gl_init` 返回 0 之后调**,理由见 `lp_spike_open` 的注释。
#[no_mangle]
pub extern "C" fn lp_spike_play(path: *const c_char) -> c_int {
    unsafe {
        if MPV.is_null() {
            return E_NO_MPV;
        }
        // 这里**故意不校验 RCTX**:桩不替调用方兜底,顺序错了就该像实测那样黑屏,
        // 这样下一个人踩到时看到的是和文档一致的现象,而不是一个被悄悄修好的假象。
        let cmd = CString::new("loadfile").unwrap();
        let file = CStr::from_ptr(path).to_owned();
        let argv: [*const c_char; 3] = [cmd.as_ptr(), file.as_ptr(), ptr::null()];
        if mpv_command(MPV, argv.as_ptr()) < 0 {
            return E_MPV;
        }
        E_OK
    }
}

/// 读一个 mpv 属性到调用方给的缓冲区。返回写入的字节数(不含结尾 0);属性不存在返回 -1。
/// 这样不需要跨语言的内存所有权约定 —— 那是 SPEC §5.3 的事,SPIKE 里不必重演。
#[no_mangle]
pub extern "C" fn lp_spike_prop(name: *const c_char, buf: *mut c_char, cap: c_int) -> c_int {
    unsafe {
        if MPV.is_null() || buf.is_null() || cap <= 1 {
            return -1;
        }
        let p = mpv_get_property_string(MPV, name);
        if p.is_null() {
            *buf = 0;
            return -1;
        }
        let s = CStr::from_ptr(p).to_bytes();
        let n = s.len().min(cap as usize - 1);
        ptr::copy_nonoverlapping(s.as_ptr() as *const c_char, buf, n);
        *buf.add(n) = 0;
        mpv_free(p as *mut c_void);
        n as c_int
    }
}

/// 取本桩内部的调用计数。`lp_gl_render` 与 `lp_gl_swapped` 各被调了多少次。
#[no_mangle]
pub extern "C" fn lp_spike_counters(renders: *mut u64, swaps: *mut u64) {
    unsafe {
        if !renders.is_null() {
            *renders = RENDER_CALLS.load(Ordering::Relaxed);
        }
        if !swaps.is_null() {
            *swaps = SWAPPED_CALLS.load(Ordering::Relaxed);
        }
    }
}

/// 关停 mpv。必须在 `lp_gl_uninit` 之后调。
#[no_mangle]
pub extern "C" fn lp_spike_close() {
    unsafe {
        DRAIN_STOP.store(true, Ordering::Relaxed);
        if !MPV.is_null() {
            mpv_terminate_destroy(MPV);
            MPV = ptr::null_mut();
        }
    }
}
