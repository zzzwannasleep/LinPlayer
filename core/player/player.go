// Package player 是 libmpv 控制层(SPEC §7)。
//
// ★ 这是 SPEC §4.1「ffi/ 之外不许有 C. / unsafe.Pointer」的**唯一例外** ——
//
//	它必须 cgo 调 libmpv。所有 mpv 知识都收在这个包里:
//	外挂字幕必须等 FILE_LOADED 且只能在事件线程挂载;keep-open 下 END_FILE 永远不发,
//	判播完必须读 eof-reached;ASS 字号要用 sub-scale 不是 sub-font-size;
//	seek 闩不能拿粘性值和目标比;双显卡要靠导出符号钉独显……
//	这些知识写一遍就够了。放到 UI 层 = 写三遍 = 错三遍(SPEC §7.1)。
package player

// 视频通道 B —— 真 libmpv 实现(SPEC §7.2)。
//
// 从 S1.2 的 Rust 桩翻过来的,契约一字不差:UI 侧只拿得到 `fbo / w / h / flip_y`,
// 拿不到任何 mpv 类型。
//
// ## 为什么参数数组是在 C 里拼的
//
// `mpv_render_param` 数组里放的是「指向本地结构体的指针」。如果在 Go 侧拼,
// 传进 C 的就是「含 Go 指针的 Go 内存」—— cgo 的指针检查会直接 panic。
// 所以拼数组的活全在下面的 C 辅助函数里做,Go 侧只传标量。
//
// ## libmpv 怎么链的
//
// `#cgo LDFLAGS: -lmpv` 配仓库自带的 `mpv.lib`。
// **它是 MSVC 格式的导入库,而我们的 C 编译器是 zig cc(lld)—— 实测能直接吃**
// (2026-08-31)。运行时需要 `libmpv-2.dll` 在 DLL 搜索路径上。

/*
#cgo LDFLAGS: -L${SRCDIR}/../../crates/mpv/libmpv -lmpv
#include <stdlib.h>
#include <stdint.h>

// ---- libmpv 的公开 API(仓库里只有 client.h,render 那组自己声明)----
typedef struct lp_render_param { int type; void *data; } lp_render_param;

typedef struct lp_gl_init_params {
    void *(*get_proc_address)(void *ctx, const char *name);
    void *get_proc_address_ctx;
    // 新版 mpv 已移除这个字段。多给一个永远安全,少给一个在老版上就是越界读。
    const char *extra_exts;
} lp_gl_init_params;

typedef struct lp_gl_fbo { int fbo; int w; int h; int internal_format; } lp_gl_fbo;

extern void*    mpv_create(void);
extern int      mpv_initialize(void*);
extern int      mpv_set_option_string(void*, const char*, const char*);
extern int      mpv_command(void*, const char**);
extern char*    mpv_get_property_string(void*, const char*);
extern void     mpv_free(void*);
extern void*    mpv_wait_event(void*, double);
extern void     mpv_terminate_destroy(void*);
extern int      mpv_render_context_create(void**, void*, lp_render_param*);
extern int      mpv_render_context_render(void*, lp_render_param*);
extern uint64_t mpv_render_context_update(void*);
extern void     mpv_render_context_report_swap(void*);
extern void     mpv_render_context_free(void*);

// MPV_RENDER_PARAM_*
enum { P_INVALID=0, P_API_TYPE=1, P_GL_INIT=2, P_GL_FBO=3, P_FLIP_Y=4,
       P_ADVANCED_CONTROL=10, P_BLOCK_FOR_TARGET_TIME=12 };

static int lp_rc_create(void **out, void *mpv, void *gpa, void *gpa_ctx) {
    lp_gl_init_params gl;
    gl.get_proc_address = (void*(*)(void*, const char*))gpa;
    gl.get_proc_address_ctx = gpa_ctx;
    gl.extra_exts = 0;
    // ADVANCED_CONTROL=1 是 report_swap 有意义的前提
    int adv = 1;
    lp_render_param ps[4];
    ps[0].type = P_API_TYPE;          ps[0].data = (void*)"opengl";
    ps[1].type = P_GL_INIT;           ps[1].data = &gl;
    ps[2].type = P_ADVANCED_CONTROL;  ps[2].data = &adv;
    ps[3].type = P_INVALID;           ps[3].data = 0;
    return mpv_render_context_create(out, mpv, ps);
}

static int lp_rc_render(void *rc, unsigned int fbo, int w, int h, int flip, int block) {
    lp_gl_fbo f; f.fbo = (int)fbo; f.w = w; f.h = h;
    f.internal_format = 0;  // 0 = 让 mpv 自己问 GL 要;宿主的 FBO 格式由宿主定
    int fy = flip, bl = block;
    lp_render_param ps[4];
    ps[0].type = P_GL_FBO;                 ps[0].data = &f;
    ps[1].type = P_FLIP_Y;                 ps[1].data = &fy;
    ps[2].type = P_BLOCK_FOR_TARGET_TIME;  ps[2].data = &bl;
    ps[3].type = P_INVALID;                ps[3].data = 0;
    return mpv_render_context_render(rc, ps);
}
*/
import "C"

import (
	"errors"
	"os"
	"sync"
	"sync/atomic"
	"time"
	"unsafe"

	"linplayer/core/bus"
)

// 一个进程只能有一条 GL 通道(SPEC §7.2 约束 4),所以是全局单例而不是句柄。
var (
	mpvMu   sync.Mutex
	mpvH    unsafe.Pointer // mpv_handle*
	rctx    unsafe.Pointer // mpv_render_context*
	rctxSet atomic.Bool    // 起播要等它(SPEC §7.2 约束 6)

	renderCalls atomic.Int64
	swapCalls   atomic.Int64
	drainStop   atomic.Bool
)

// ensureMpv 起 mpv 但**不起播**。
//
// ★ 起播必须排在 lp_gl_init 之后(SPEC §7.2 约束 6):`vo=libmpv` 在 render context
// 存在之前初始化是致命失败且 mpv 不重试,宿主只看到「全程黑屏 + wants_redraw 恒 0」。
// 挡住这件事是**核心层的责任**,见 waitRenderCtx。
func ensureMpv() int32 {
	mpvMu.Lock()
	defer mpvMu.Unlock()
	if mpvH != nil {
		return 0
	}
	h := C.mpv_create()
	if h == nil {
		return -1
	}
	set := func(k, v string) {
		ck, cv := C.CString(k), C.CString(v)
		defer C.free(unsafe.Pointer(ck))
		defer C.free(unsafe.Pointer(cv))
		C.mpv_set_option_string(h, ck, cv)
	}
	hw := os.Getenv("LP_HWDEC")
	if hw == "" {
		hw = "auto"
	}
	for _, kv := range [][2]string{
		{"vo", "libmpv"},
		{"hwdec", hw},
		{"terminal", "no"},
		{"keep-open", "yes"},
		// N1:CVE-2026-8461。迁移必带清单的第一条,在这里就带上,别等以后补
		{"vd", "-magicyuv"},
	} {
		set(kv[0], kv[1])
	}
	// 日志走 LP_MPV_LOG 门控:log-file 会把 mpv+ffmpeg 钉在 debug 级
	if p := os.Getenv("LP_MPV_LOG"); p != "" {
		set("log-file", p)
		set("msg-level", "all=v")
	}
	if C.mpv_initialize(h) < 0 {
		C.mpv_terminate_destroy(h)
		return -1
	}
	mpvH = h
	go drainEvents(h)
	go pumpStatus()
	return 0
}

// drainEvents 是 mpv 的事件线程。光渲染不取事件,mpv 的队列会一直堆着。
//
// ★ 这条线程和 GL 线程必须是两条(SPEC §7.2 约束 1)。
// 它自己也要有 panic 边界:这条线程死了 = 播放状态永远不再更新而画面还在动,最难查。
func drainEvents(h unsafe.Pointer) {
	defer func() {
		if r := recover(); r != nil {
			bus.Logf("error", "mpv 事件线程 panic: %v", r)
		}
	}()
	for !drainStop.Load() {
		C.mpv_wait_event(h, 0.1)
	}
}

// pumpStatus 4 Hz 推 player.status —— 高频状态事件,队列里会被原地合并(SPEC §5.11)。
func pumpStatus() {
	t := time.NewTicker(250 * time.Millisecond)
	defer t.Stop()
	for !drainStop.Load() {
		<-t.C
		if !rctxSet.Load() {
			continue
		}
		bus.Emit("player.status", map[string]any{
			"position":  propF("time-pos"),
			"duration":  propF("duration"),
			"eof":       prop("eof-reached") == "yes",
			"dropped":   propF("frame-drop-count"),
			"hwdec":     prop("hwdec-current"),
			"renderFps": renderCalls.Load(),
		}, "player.status")
	}
}

func prop(name string) string {
	mpvMu.Lock()
	h := mpvH
	mpvMu.Unlock()
	if h == nil {
		return ""
	}
	cn := C.CString(name)
	defer C.free(unsafe.Pointer(cn))
	p := C.mpv_get_property_string(h, cn)
	if p == nil {
		return ""
	}
	s := C.GoString(p)
	C.mpv_free(unsafe.Pointer(p))
	return s
}

func propF(name string) float64 {
	var f float64
	_, _ = sscanFloat(prop(name), &f)
	return f
}

// ---------------------------------------------------------------- 通道 B 的 5 个

// GLInit 绑定 GL 上下文,建 mpv render context(SPEC §5.1 第 3 组)。
func GLInit(getProcAddress unsafe.Pointer, ctx unsafe.Pointer) int32 {
	if getProcAddress == nil {
		return -3
	}
	if r := ensureMpv(); r != 0 {
		bus.Logf("error", "mpv 起不来")
		return -99
	}
	mpvMu.Lock()
	defer mpvMu.Unlock()
	if rctx != nil {
		return 0 // 幂等
	}
	var out unsafe.Pointer
	if C.lp_rc_create(&out, mpvH, getProcAddress, ctx) < 0 {
		bus.Logf("error", "mpv_render_context_create 失败")
		return -99
	}
	rctx = out
	rctxSet.Store(true)
	bus.Logf("info", "视频通道 B 已就绪(render context 已建立)")
	return 0
}

// GLWantsRedraw 有没有新帧要画。暂停时恒 0,不白烧 GPU。
func GLWantsRedraw() int32 {
	mpvMu.Lock()
	rc := rctx
	mpvMu.Unlock()
	if rc == nil {
		return 0
	}
	if C.mpv_render_context_update(rc)&1 != 0 {
		return 1
	}
	return 0
}

// GLRender 渲一帧到宿主给的 FBO。
func GLRender(fbo uint32, w, h, flipY int32) int32 {
	mpvMu.Lock()
	rc := rctx
	mpvMu.Unlock()
	if rc == nil {
		return -1
	}
	// block_for_target_time:mpv 默认阻塞到该帧的呈现时刻。在 Avalonia 上这等于
	// 把整条 UI 渲染线程按片源帧率钉住(S1.2 实测:4K24 下循环只转 25 次/秒)。
	block := C.int(1)
	if os.Getenv("LP_BLOCK_FOR_TARGET_TIME") == "0" {
		block = 0
	}
	r := C.lp_rc_render(rc, C.uint(fbo), C.int(w), C.int(h), C.int(flipY), block)
	renderCalls.Add(1)
	if r < 0 {
		return -99
	}
	return 0
}

// glSwapped 报告「上一帧真的上屏了」。
// S1.2 实测漏调它在本机复现不出掉帧,但它是 mpv 规定的上报口且代价为零,继续调。
// GLSwapped 报告上一帧已上屏。
func GLSwapped() {
	mpvMu.Lock()
	rc := rctx
	mpvMu.Unlock()
	if rc == nil {
		return
	}
	C.mpv_render_context_report_swap(rc)
	swapCalls.Add(1)
}

// GLUninit 解绑并销毁 render context。必须在销毁 GL 上下文之前调,且阻塞返回。
func GLUninit() {
	mpvMu.Lock()
	rc := rctx
	rctx = nil
	rctxSet.Store(false)
	mpvMu.Unlock()
	if rc != nil {
		C.mpv_render_context_free(rc) // 本身就阻塞到 mpv 不再碰这个 GL 上下文
	}
}

// ---------------------------------------------------------------- 播放命令

// waitRenderCtx 是 SPEC §7.2 约束 6 的落实:**核心层把起播挡到 render context 就绪之后**,
// 不指望每个端自觉。超时就明确报错,而不是发出去一条注定黑屏的 loadfile。
func waitRenderCtx(d time.Duration) bool {
	deadline := time.Now().Add(d)
	for time.Now().Before(deadline) {
		if rctxSet.Load() {
			return true
		}
		time.Sleep(20 * time.Millisecond)
	}
	return false
}

func playFile(path string) error {
	if r := ensureMpv(); r != 0 {
		return errors.New("mpv 起不来")
	}
	if !waitRenderCtx(5 * time.Second) {
		return errors.New("视频通道未就绪:UI 还没调 lp_gl_init。起播必须排在它之后(SPEC §7.2 约束 6)")
	}
	mpvMu.Lock()
	h := mpvH
	mpvMu.Unlock()
	c1, c2 := C.CString("loadfile"), C.CString(path)
	defer C.free(unsafe.Pointer(c1))
	defer C.free(unsafe.Pointer(c2))
	argv := []*C.char{c1, c2, nil}
	if C.mpv_command(h, (**C.char)(unsafe.Pointer(&argv[0]))) < 0 {
		return errors.New("loadfile 失败")
	}
	return nil
}

// Close 关停 mpv。必须排在 GLUninit 之后。
func Close() {
	drainStop.Store(true)
	mpvMu.Lock()
	h := mpvH
	mpvH = nil
	mpvMu.Unlock()
	if h != nil {
		C.mpv_terminate_destroy(h)
	}
}

// SetSurface 是视频通道 A(SPEC §7.2)。桌面端走通道 B,这条在 Windows 上不会被调到。
//
// ★ 解绑(kind=0)**必须阻塞到 mpv 真的不再往里画**,否则是 use-after-free。
// 这是安卓端最容易漏的一条 —— 而现有 Rust 版**现在就漏着**(TODO N5)。
// 安卓端接上时在这里实现同步屏障,别再漏一次。
func SetSurface(kind int32, handle int64, width, height int32) int32 {
	if kind == 0 {
		bus.Logf("info", "lp_set_surface 解绑")
		return 0
	}
	bus.Logf("warn", "lp_set_surface 在本平台不适用(桌面走通道 B):kind=%d %dx%d", kind, width, height)
	return 0
}
