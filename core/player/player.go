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
#cgo LDFLAGS: -L${SRCDIR}/../../third_party/libmpv -lmpv
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
extern int      mpv_set_property_string(void*, const char*, const char*);
extern int      mpv_command(void*, const char**);
extern char*    mpv_get_property_string(void*, const char*);
extern void     mpv_free(void*);
extern void*    mpv_wait_event(void*, double);
extern void     mpv_terminate_destroy(void*);
extern int      mpv_render_context_create(void**, void*, lp_render_param*);
extern int      mpv_render_context_render(void*, lp_render_param*);
extern int      mpv_render_context_get_info(void*, lp_render_param);
extern long long mpv_get_time_us(void*);
extern long long mpv_get_time_ns(void*);
extern uint64_t mpv_render_context_update(void*);
extern void     mpv_render_context_report_swap(void*);
extern void     mpv_render_context_free(void*);

// MPV_RENDER_PARAM_*
enum { P_INVALID=0, P_API_TYPE=1, P_GL_INIT=2, P_GL_FBO=3, P_FLIP_Y=4,
       P_ADVANCED_CONTROL=10, P_NEXT_FRAME_INFO=11, P_BLOCK_FOR_TARGET_TIME=12 };

// mpv_render_frame_info(render.h)。target_time 和 mpv_get_time_us 同一个时钟基。
typedef struct lp_frame_info { unsigned long long flags; long long target_time; } lp_frame_info;
enum { FRAME_PRESENT=1, FRAME_REDRAW=2, FRAME_REPEAT=4 };

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

// mpv_event / mpv_event_log_message 照 client.h 原样声明。
//
// ★ 原来这里只读第一个 int(event_id)并注释「不碰后面的,读了就是在赌」。
//   现在必须读 data —— 但**不是靠猜偏移**:把 client.h 里这两个结构体
//   原样抄下来,偏移由编译器算。它们是公开且稳定的 ABI(不是那个随版本变的 union)。
typedef struct lp_mpv_event {
    int event_id;
    int error;
    uint64_t reply_userdata;
    void *data;
} lp_mpv_event;

typedef struct lp_log_msg {
    const char *prefix;
    const char *level;
    const char *text;
    int log_level;
} lp_log_msg;

extern int mpv_request_log_messages(void*, const char*);

static int lp_event_id(void *ev) { return ev ? ((lp_mpv_event*)ev)->event_id : 0; }

// lp_event_log_text 取一条 MPV_EVENT_LOG_MESSAGE 的正文。非日志事件返回 0。
static const char* lp_event_log_text(void *ev) {
    if (!ev) return 0;
    void *d = ((lp_mpv_event*)ev)->data;
    return d ? ((lp_log_msg*)d)->text : 0;
}

// get_info 的形参是**按值**传的 mpv_render_param,和 create/render 的数组不一样。
static int lp_rc_next_frame(void *rc, lp_frame_info *out) {
    lp_render_param p; p.type = P_NEXT_FRAME_INFO; p.data = out;
    return mpv_render_context_get_info(rc, p);
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
	"strings"
	"fmt"
	"math"
	"os"
	"sync"
	"sync/atomic"
	"time"
	"unsafe"

	"linplayer/core/bus"
	"linplayer/core/paths"
)

// 一个进程只能有一条 GL 通道(SPEC §7.2 约束 4),所以是全局单例而不是句柄。
var (
	mpvMu   sync.Mutex
	mpvH    unsafe.Pointer // mpv_handle*
	rctx    unsafe.Pointer // mpv_render_context*
	rctxSet atomic.Bool    // 起播要等它(SPEC §7.2 约束 6)

	renderCalls atomic.Int64
	swapCalls   atomic.Int64
	advanceCalls atomic.Int64
	drainStop   atomic.Bool
)

// baseOptions 是 mpv 起手的选项表。
//
// ★★ **抽成纯函数是为了能被测试钉住**,不是为了好看。N1(CVE-2026-8461 的
// magicyuv 防护)已经因为一次重构静默丢过一回 —— 丢了之后编译绿、单测绿、
// 运行时也不报错,只是那条防护没了。文档提醒防不住重构,只有测试能。
// 见 player_options_test.go。
func baseOptions(hwdec, shaderCacheDir string) [][2]string {
	opts := [][2]string{
		{"vo", "libmpv"},
		{"hwdec", hwdec},
		{"terminal", "no"},
		{"keep-open", "yes"},
		// N1:CVE-2026-8461。迁移必带清单的第一条,在这里就带上,别等以后补
		{"vd", "-magicyuv"},
	}
	if shaderCacheDir != "" {
		// libmpv 没有配置目录,这两项不显式给就**不缓存**:每次起播重编整条
		// Anime4K CNN 链,表现是开着超分时第一秒卡一下(mpv 发行版卫生那条)。
		opts = append(opts,
			[2]string{"gpu-shader-cache", "yes"},
			[2]string{"gpu-shader-cache-dir", shaderCacheDir})
	}
	return opts
}

// checkOptionNames 拿一个**临时** mpv 句柄把选项逐条试一遍,返回 libmpv 不认的那些。
//
// ★ 它只被测试调用,却必须住在非测试文件里 —— Go 不允许 `_test.go` 里 `import "C"`。
// 判据来源:实测 libmpv(client api 2.5)对不存在的选项名返回 -5(option not found),
// 对 `vd` / `gpu-shader-cache-dir` / `gpu-shader-cache` 都返回 0。
func checkOptionNames(opts [][2]string) []string {
	h := C.mpv_create()
	if h == nil {
		return []string{"mpv_create 失败"}
	}
	defer C.mpv_terminate_destroy(h)
	var bad []string
	for _, kv := range opts {
		ck, cv := C.CString(kv[0]), C.CString(kv[1])
		r := C.mpv_set_option_string(h, ck, cv)
		C.free(unsafe.Pointer(ck))
		C.free(unsafe.Pointer(cv))
		if r < 0 {
			bad = append(bad, fmt.Sprintf("%s=%s(错误码 %d)", kv[0], kv[1], int(r)))
		}
	}
	return bad
}

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
	hw := os.Getenv("LP_HWDEC")
	if hw == "" {
		hw = "auto"
	}
	// 着色器缓存目录得先存在,mpv 不会替我们建。建不出来就不给这个路径 ——
	// 给一个建不出来的路径,mpv 每帧都会去试,反而更糟。
	sc := paths.ShaderCacheDir()
	if err := os.MkdirAll(sc, 0o755); err != nil {
		bus.Logf("warn", "着色器缓存目录建不出来,本次运行不缓存: %v", err)
		sc = ""
	}
	// 平台专属选项追加在后面(后写的赢)。桌面返回 nil,所以 baseOptions 的
	// 输出一字不变;安卓在这里换 vo 并带上软解调优与字幕字体目录。
	opts := append(baseOptions(hw, sc), platformOptions()...)
	// 日志走 LP_MPV_LOG 门控:log-file 会把 mpv+ffmpeg 钉在 debug 级
	if lp := os.Getenv("LP_MPV_LOG"); lp != "" {
		opts = append(opts, [2]string{"log-file", lp}, [2]string{"msg-level", "all=v"})
	}
	for _, kv := range opts {
		ck, cv := C.CString(kv[0]), C.CString(kv[1])
		r := C.mpv_set_option_string(h, ck, cv)
		C.free(unsafe.Pointer(ck))
		C.free(unsafe.Pointer(cv))
		/* ★★ 返回码**必须看**。这是 N13 记下的「静默失效的机制源头」:
		   选项名写错、或者 libmpv 升级把它改名了,mpv 只是返回 -5 就完事,
		   代码路径一切正常、编译绿、单测绿 —— 而那条 CVE 防护已经没了。
		   N1 就是这么丢过一次的。 */
		if r < 0 {
			bus.Logf("error", "mpv 选项没设上:%s=%s(错误码 %d)—— 这一项的功能现在是关的", kv[0], kv[1], int(r))
		}
	}
	if C.mpv_initialize(h) < 0 {
		C.mpv_terminate_destroy(h)
		return -1
	}
	/* ★ 订阅 error 级日志。**这是「shader 编译失败」唯一的出口** ——
	   mpv 不会把它写进任何属性,也不会让 set 失败:选项照收、画面照渲染,
	   只是渲染出来的是一片纯色。2026-09-02 真机撞到:开 ak_sharp 之后整屏变蓝。 */
	ck := C.CString("error")
	C.mpv_request_log_messages(h, ck)
	C.free(unsafe.Pointer(ck))

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
		ev := C.mpv_wait_event(h, 0.1)
		if ev == nil {
			continue
		}
		switch int(C.lp_event_id(ev)) {
		case evFileLoaded:
			onFileLoaded()
		case evLogMessage:
			if t := C.lp_event_log_text(ev); t != nil {
				txt := C.GoString(t)
				noteMpvLog(txt)
				noteLastError(txt)
				/* ★ 订阅的是 error 级,所以每一条都值得往外走。
				   原来只有 shader 编译错误被留下,别的**一个字都不出来** ——
				   而「起播失败」在界面上只是一直黑屏,mpv 明明报了原因却没人看得到。
				   这和「核心层日志一开始一个字都没往外走」是同一个坑。 */
				bus.Logf("warn", "mpv: %s", strings.TrimSpace(txt))
			}
		case evEndFile:
			// ★ keep-open=yes 时 END_FILE **永远不发**(文件不卸载)。
			//   判「播完」必须读 eof-reached 属性 —— 这是「播完不同步 Trakt/Bangumi」的根因。
			//   这个分支留着只为文档:真走到这儿说明 keep-open 被谁改了。
			bus.Logf("info", "mpv END_FILE(keep-open 下本不该出现)")
		}
	}
}

// mpv 事件 id(client.h)。
//
// ☠☠ **evFileLoaded 曾经写成 6,而 6 是 START_FILE,8 才是 FILE_LOADED。**
// 后果:onFileLoaded 里的 sub-add 在文件还没打开时就发出去,mpv 回 -12,
// 那条错只进日志 —— 外挂字幕「挂了等于没挂」,一句报错都没有。
// 这正是仓库里 mpv-loadfile-async-subadd 那条经验写过的坑,换栈时又踩了一遍。
//
// ★ 实测顺序(ctypes 直打 libmpv):6 → 8 → 17 → 21。别照记忆写。
const (
	evLogMessage      = 2
	evStartFile       = 6
	evEndFile         = 7
	evFileLoaded      = 8
	evPlaybackRestart = 21
)

// pumpStatus 4 Hz 推 player.status —— 高频状态事件,队列里会被原地合并(SPEC §5.11)。
//
// ☠☠ **闸必须是 `videoOutReady()`,不能直接读 `rctxSet`。**
// `rctxSet` 是**桌面通道 B** 的 render context 标志,只有 `GLInit` 会置位;
// 安卓走通道 A(SurfaceView / wid),那条路上 `GLInit` 一次都不调 ——
// 于是这里恒 continue,`player.status` 在安卓上**一条都发不出去**。
// 表现:mpv 正常出画出声,而 UI 因为「位置一直是 0」永远撤不掉起播黑幕,
// 用户看到的是「有声音、没画面、一直正在缓冲」,退场动画里却能瞥见几帧画面
// (黑幕跟着页面淡出,底下的 SurfaceView 就露出来了)。一条错都不报。
// `videoOutReady()` 是平台抽象(surface_android.go / surface_other.go 各一份),
// 起播闸(见 PlayFile)用的就是它 —— 两处必须是同一个判据。
//
// ★ `paused` / `buffering` 是 UI 直接读的字段。不发的表现是暂停按钮状态永远反着,
// 以及起播兜底那句 `if (!buffering)` 永远不成立。
func pumpStatus() {
	t := time.NewTicker(250 * time.Millisecond)
	defer t.Stop()
	for !drainStop.Load() {
		<-t.C
		if !videoOutReady() {
			continue
		}
		bus.Emit("player.status", statusFields(prop, propF, renderCalls.Load()), "player.status")
	}
}

// statusFields 把 mpv 的属性折成 UI 那边读的那张表。
//
// 抽成纯函数只为一件事:**属性名拼错在真机上是看不出来的**。
// `pause` 写成 `paused` 的表现是暂停按钮状态恒反,
// `paused-for-cache` 写错的表现是起播那句 4 秒兜底永远不放行 ——
// 两个都不报错,而单测能当场逮住。
func statusFields(get func(string) string, getF func(string) float64, fps int64) map[string]any {
	return map[string]any{
		"position":  getF("time-pos"),
		"duration":  getF("duration"),
		"paused":    get("pause") == "yes",
		"buffering": get("paused-for-cache") == "yes",
		"eof":       get("eof-reached") == "yes",
		"dropped":   getF("frame-drop-count"),
		"hwdec":     get("hwdec-current"),
		"renderFps": fps,
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

// propF 读一个数值属性。
//
// ☠☠ **NaN / ±Inf 一律折成 0。**
// mpv 在文件还没装好、或者流不可 seek 的时候会把 duration / time-pos 报成
// `nan` —— 而 `encoding/json` 序列化 NaN 会**直接报错**,于是
// `player.status` 那条事件整条发不出去(日志里只有一行
// 「事件 player.status 序列化失败: json: unsupported value: NaN」,
// 而 UI 那边只是「状态不更新」,没有任何别的迹象)。
// 2026-09-03 真机自检里每秒刷一条这个错,而所有功能看起来都正常。
//
// ★ 折成 0 而不是 -1:调用方(进度条、时长、倍速)对 0 的处理本来就是
//
//	「还不知道,先不画」,而 -1 会被当成一个合法的负数位置。
func propF(name string) float64 {
	var f float64
	_, _ = sscanFloat(prop(name), &f)
	if math.IsNaN(f) || math.IsInf(f, 0) {
		return 0
	}
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

/* GLWantsRedraw 有没有新帧。**宿主已经不拿它决定画不画了** —— 见 GLRender 上面那段:
   跳过 render 的那一个合成帧,宿主的 FBO 里是黑的。留着它只为分统计口径。 */
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


/* lead:这一帧被推上屏的时刻,比 mpv 给的呈现时刻早多少毫秒。

   它就是**画面比声音早多少** —— block_for_target_time=1 时 mpv 在 render 里等到点
   才放行,所以恒为 0;设成 0 之后我们拿到帧就画,早多少完全取决于 mpv 提前多久交货。
   2026-09-05 实测:提前约一帧(24fps 片子 ≈ +36ms),而且**改不掉** ——
   `video-latency-hacks=yes` 试过,render 仍然堵 38.4ms,mpv 照样提前一帧交。

   ☠ 单位是**纳秒**,和 mpv_get_time_ns 同基,不是 render.h 注释里写的 mpv_get_time_us。
     按微秒算会得到 99 万毫秒,然后被护栏静默丢光 —— 这里对不上量纲就吼一声,不许静默。 */
var (
	leadMu    sync.Mutex
	leadN     int64
	leadSum   float64
	leadBad   atomic.Int64
)

func noteLead(rc unsafe.Pointer, h unsafe.Pointer) {
	if h == nil {
		return
	}
	var fi C.lp_frame_info
	if C.lp_rc_next_frame(rc, &fi) < 0 || fi.target_time == 0 ||
		uint64(fi.flags)&C.FRAME_REDRAW != 0 {
		return // 重画帧没有呈现时刻,不是节奏的一部分
	}
	ms := float64(int64(fi.target_time)-int64(C.mpv_get_time_ns(h))) / 1e6
	if ms > 2000 || ms < -2000 {
		if leadBad.Add(1)%600 == 1 {
			bus.Logf("warn", "[提前量] target_time 和本地时钟差 %.0fms —— libmpv 多半换了单位", ms)
		}
		return
	}
	leadMu.Lock()
	leadN++
	leadSum += ms
	leadMu.Unlock()
}

// Lead 画面比 mpv 给的呈现时刻平均早多少毫秒,和样本数。
// ★ 门禁要看样本数:样本为 0 时均值是 0,而 0 恰好满足「偏差很小」。
func Lead() (mean float64, n int64) {
	leadMu.Lock()
	defer leadMu.Unlock()
	if leadN < 2 {
		return 0, leadN
	}
	return leadSum / float64(leadN), leadN
}

// GLRender 渲一帧到宿主给的 FBO。
func GLRender(fbo uint32, w, h, flipY int32) int32 {
	mpvMu.Lock()
	// mh 不叫 h —— h 是这个函数的高度参数
	rc, mh := rctx, mpvH
	mpvMu.Unlock()
	if rc == nil {
		return -1
	}
	/* block_for_target_time=0:**等待已经挪到 GLWantsRedraw 里了**,这里不许再等。

	   2026-09-04 也把它设成过 0,当天被打回(「暂停了画面还是在抽搐」)——
	   区别在于那次只是把等待删掉,帧改成按解码完成时刻上屏;这次是把等待
	   搬到了合成线程之外,授时判据仍然是 mpv 给的 target_time。见 GLWantsRedraw。

	   在这里等的代价是量过的:24fps 的片子,合成线程 90% 的时间堵在这一行里。 */
	block := C.int(1)
	if os.Getenv("LP_BLOCK_FOR_TARGET_TIME") == "0" {
		block = 0
	}
	/* 先问一句「这一次会不会推进一帧」。**不是拿来决定画不画的**(那条路已经废了),
	   只是分统计口径:重画也算进出帧节奏的话,量出来的是合成帧率不是出帧节奏。 */
	advance := C.mpv_render_context_update(rc)&1 != 0
	if advance {
		noteLead(rc, mh) // 必须在 render 之前问 —— render 一跑,这一帧就不是「下一帧」了
	}
	t0 := time.Now()
	r := C.lp_rc_render(rc, C.uint(fbo), C.int(w), C.int(h), C.int(flipY), block)
	noteRenderCost(float64(time.Since(t0).Microseconds()) / 1000)
	renderCalls.Add(1)
	if advance {
		advanceCalls.Add(1)
		noteCadence()
	}
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
		if videoOutReady() {
			return true
		}
		time.Sleep(20 * time.Millisecond)
	}
	return false
}

// command 发一条 mpv 命令。可变参数,自己管 C 字符串的生命周期。
func command(args ...string) error {
	mpvMu.Lock()
	h := mpvH
	mpvMu.Unlock()
	if h == nil {
		return errors.New("mpv 未就绪")
	}
	cargs := make([]*C.char, 0, len(args)+1)
	for _, a := range args {
		ca := C.CString(a)
		defer C.free(unsafe.Pointer(ca))
		cargs = append(cargs, ca)
	}
	cargs = append(cargs, nil)
	if C.mpv_command(h, (**C.char)(unsafe.Pointer(&cargs[0]))) < 0 {
		return fmt.Errorf("mpv 命令失败: %v", args)
	}
	return nil
}

// setProp 设一个 mpv 属性。
//
// ★ 失败只记日志不返回错误:这些属性有的在没在播时设不上(mpv 会拒),
// 那是正常的,不该让调用方以为整件事失败了。
func setProp(name, value string) {
	mpvMu.Lock()
	h := mpvH
	mpvMu.Unlock()
	if h == nil {
		return
	}
	cn, cv := C.CString(name), C.CString(value)
	defer C.free(unsafe.Pointer(cn))
	defer C.free(unsafe.Pointer(cv))
	if C.mpv_set_property_string(h, cn, cv) < 0 {
		bus.Logf("debug", "mpv 属性设不上 %s=%s(没在播时是正常的)", name, value)
	}
}

// Prop 读一个 mpv 属性(字符串)。给命令层用。
func Prop(name string) string { return prop(name) }

func playFile(path string) error {
	// 上一部片的报错不能算在这一部头上 —— 那会让排查指向一个早就过去的问题
	ClearMpvError()
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

// SetSurface 是视频通道 A(SPEC §7.2)。实现按平台分:
// 安卓在 surface_android.go(真绑 mpv 的 wid),其余平台在 surface_other.go(桩)。


/* ★★ 出帧节奏。**「画面抽不抽搐」唯一量得出来的东西。**

   用户 2026-09-04 报「正常播放的画面都会抽搐」,而这件事:
     · 截图看不出来 —— 抽搐是帧和帧之间的关系,截图只有一帧;
     · mpv 的 avsync 也看不出来 —— 实测把 block_for_target_time 关掉,
       它照样一路 0.0ms(音频时钟没受影响,受影响的是**画面上屏的时刻**)。
       第一版判据就写在 avsync 上,反向注入之后是绿的 —— 一条假绿的门禁。

   真正变的是**相邻两次上屏之间隔了多久**:
     · block=1:mpv 阻塞到该帧的呈现时刻才返回,间隔贴着帧间隔走;
     · block=0:解码完就交,间隔随解码耗时上下跳 —— 那就是抽搐。

   所以量**间隔的标准差**(抖动)。★ 不是量平均帧率:抽搐的时候平均帧率是对的。 */
var (
	cadMu    sync.Mutex
	cadLast  int64 // 上一次 render 的时刻(ns)
	cadN     int64
	cadSum   float64 // 毫秒
	cadSumSq float64
)

func noteCadence() {
	now := time.Now().UnixNano()
	cadMu.Lock()
	if cadLast > 0 {
		d := float64(now-cadLast) / 1e6
		// ★ 丢掉大空档:暂停、切页、窗口最小化都会留下几百毫秒的洞,
		//   把它们算进去的话标准差被这几个洞主导,真正的抖动反而看不见了。
		if d > 0 && d < 200 {
			cadN++
			cadSum += d
			cadSumSq += d * d
		}
	}
	cadLast = now
	cadMu.Unlock()
}

/* renderCost:lp_rc_render **这一次调用本身**耗了多久(毫秒)。

   量这个是因为 block_for_target_time=1 的语义就是「阻塞到该帧的呈现时刻」——
   而这个调用跑在宿主的合成/UI 线程上。它堵多久,整个界面就有多久画不了新东西。
   2026-09-04 那次「合成线程被堵 83ms」是猜的,从来没量过,于是拿这个猜测去动了
   mpv 的默认值,把正常播放弄坏了。这次先有数再动手。 */
var (
	rcMu   sync.Mutex
	rcN    int64
	rcSum  float64
	rcMax  float64
	rcSlow int64 // 超过 16ms = 至少错过一个 60Hz 合成帧
)

func noteRenderCost(ms float64) {
	rcMu.Lock()
	rcN++
	rcSum += ms
	if ms > rcMax {
		rcMax = ms
	}
	if ms > 16 {
		rcSlow++
	}
	rcMu.Unlock()
}

// RenderCost 累计耗时 / 最大 / 超过 16ms 的次数 / 样本数。给的是**累计量**:
// 要某一段的均值,读两次做差。
func RenderCost() (sum, max float64, slow, n int64) {
	rcMu.Lock()
	defer rcMu.Unlock()
	return rcSum, rcMax, rcSlow, rcN
}

// AdvanceCalls 其中有多少次真的推进了一帧。和 renderCalls 一比 = 一帧画面被重复画了几遍。
func AdvanceCalls() int64 { return advanceCalls.Load() }

// ResetCadence 换片 / 起播时清零。
func ResetCadence() {
	cadMu.Lock()
	cadLast, cadN, cadSum, cadSumSq = 0, 0, 0, 0
	cadMu.Unlock()
}

// Cadence 出帧节奏:平均间隔、抖动(标准差)、样本数,单位毫秒。
func Cadence() (mean, jitter float64, n int64) {
	cadMu.Lock()
	defer cadMu.Unlock()
	if cadN < 2 {
		return 0, 0, cadN
	}
	mean = cadSum / float64(cadN)
	v := cadSumSq/float64(cadN) - mean*mean
	if v < 0 {
		v = 0
	}
	return mean, math.Sqrt(v), cadN
}
