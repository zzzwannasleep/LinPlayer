package main

// SPIKE-2 · SPEC §5.1 的 13 个导出。
//
// **每个导出函数体顶层都有 defer recover()** —— 不是编码习惯,是契约(SPEC §5.10):
// 参数解析本身就可能 panic(空指针、非法 UTF-8),而一个逃出去的 panic
// 直接终止整个进程,宿主的 try/catch 一个都拦不住。
//
// 内存所有权唯一规则(SPEC §5.3):**Go 分配,宿主释放。**
// 传进来的 const char* 在调用返回后即失效,所以每个入口都**立刻**拷成 Go string,
// 绝不把 C 指针带进 goroutine。

/*
#include <stdlib.h>
#include <stdint.h>
*/
import "C"

import (
	"runtime"
	"runtime/debug"
	"sync"
	"sync/atomic"
	"unsafe"
)

func main() {} // c-shared 需要,但永远不会被调用

// guard 是每个导出的 panic 兜底。ret 是 panic 时该返回的值。
func guard(where string, ret *C.int32_t, code C.int32_t) {
	if r := recover(); r != nil {
		panicCount.Add(1)
		if q != nil {
			logf("error", "导出函数 %s panic: %v\n%s", where, r, string(debug.Stack()))
		}
		if ret != nil {
			*ret = code
		}
	}
}

const (
	eOK       C.int32_t = 0
	eNotInit  C.int32_t = -1
	eShutdown C.int32_t = -2
	eBadArg   C.int32_t = -3
	eInternal C.int32_t = -99
)

var initOnce sync.Once

// C 字符串的分配/释放计数 —— SPEC §5.3「Go 分配,宿主释放」的直接判据。
var cstrAlloc, cstrFree atomic.Int64

// ---------------------------------------------------------- 第 1 组:控制通道(7 个)

// lp_abi_version 必须在 lp_init 之前调,不匹配就不要 init(SPEC §5.0)。
//
// 它天然向后兼容 —— 旧库里没有这个符号,**这件事本身就是信号**
// (宿主会拿到 EntryPointNotFound / dlsym NULL)。
//
//export lp_abi_version
func lp_abi_version() C.int32_t {
	return C.int32_t(LP_ABI)
}

//export lp_init
func lp_init(configJSON *C.char) (ret C.int32_t) {
	ret = eOK
	defer guard("lp_init", &ret, eInternal)

	cfg := goStr(configJSON) // 立刻拷贝:返回后这个指针就失效了
	initOnce.Do(func() {
		q = newQueue()
		// ★ worker 池必须在这里建 —— 见 dispatch.go 顶部那段实测记录
		startWorkers()
		started.Store(true)
		logf("info", "核心层已启动 ABI=%d GOOS=%s config=%s", LP_ABI, runtime.GOOS, cfg)
	})
	return eOK
}

// lp_call 立即返回,不阻塞。结果通过事件队列以 {"t":"result","seq":N,...} 送回。
//
//export lp_call
func lp_call(seq C.int64_t, cmd *C.char, argsJSON *C.char) (ret C.int32_t) {
	ret = eOK
	defer guard("lp_call", &ret, eInternal)

	if !started.Load() {
		return eNotInit
	}
	if shutdown.Load() {
		return eShutdown
	}
	if seq == 0 {
		// seq 由宿主分配,必须单调递增且非 0
		return eBadArg
	}
	dispatch(int64(seq), goStr(cmd), goStr(argsJSON))
	return eOK
}

//export lp_cancel
func lp_cancel(seq C.int64_t) {
	defer guard("lp_cancel", nil, 0)
	inflightMu.Lock()
	cancel, ok := inflight[int64(seq)]
	inflightMu.Unlock()
	if ok {
		cancel() // 对已完成的 seq 是空操作
	}
}

// lp_next_event 阻塞取下一个事件。timeout_ms < 0 表示无限等;超时返回 NULL。
// **调用方必须用 lp_free 释放返回的指针。**
//
//export lp_next_event
func lp_next_event(timeoutMs C.int32_t) (ret *C.char) {
	defer func() {
		if r := recover(); r != nil {
			panicCount.Add(1)
			ret = nil
		}
	}()
	if q == nil {
		return nil
	}
	e := q.pop(int32(timeoutMs))
	if e == nil {
		return nil
	}
	b, err := marshalEvent(e)
	if err != nil {
		return nil
	}
	// C.CString 用 malloc 分配 —— 与 lp_free 的 free() 配对(SPEC §5.3)
	//
	// ★ 计数是判据本身。用「进程私有内存涨了多少」当判据是测不出来的:
	//   实测 2 万次往返里,漏掉的 C 字符串只有约 2 MB,完全被宿主运行时
	//   自己的分配淹没(正常 23.7 MB vs 故意不 free 24.5 MB,分不出来)。
	//   直接数 alloc/free 才是在测这条契约。
	cstrAlloc.Add(1)
	return C.CString(string(b))
}

//export lp_free
func lp_free(p *C.char) {
	defer guard("lp_free", nil, 0)
	if p != nil {
		cstrFree.Add(1)
		C.free(unsafe.Pointer(p))
	}
}

// lp_shutdown 关停。之后所有调用返回 E_SHUTDOWN。阻塞直到落盘完成。
//
//export lp_shutdown
func lp_shutdown() {
	defer guard("lp_shutdown", nil, 0)
	if !shutdown.CompareAndSwap(false, true) {
		return
	}
	// 取消所有在途命令
	inflightMu.Lock()
	for _, c := range inflight {
		c()
	}
	inflightMu.Unlock()
	closeMpv() // 关 mpv 必须排在 lp_gl_uninit 之后(S1.2 实测:反过来宿主合成器当场抛异常)
	if q != nil {
		q.close() // 发 eof,让消费者退出循环
	}
}

// ---------------------------------------------------------- 第 2 组:视频通道 A(1 个)

// kind: 0=none(解绑) 1=ANativeWindow* 4=CAMetalLayer*
// 解绑(kind=0)**必须阻塞到 mpv 真的不再往里画**,否则是 use-after-free。
//
//export lp_set_surface
func lp_set_surface(kind C.int32_t, handle C.int64_t, width C.int32_t, height C.int32_t) (ret C.int32_t) {
	ret = eOK
	defer guard("lp_set_surface", &ret, eInternal)
	// 桌面端走通道 B,这条在 Windows 上不会被调到。安卓端接上时在这里实现同步屏障。
	logf("warn", "lp_set_surface 在本平台不适用(桌面走通道 B):kind=%d %dx%d", int(kind), int(width), int(height))
	return eOK
}

// ---------------------------------------------------------- 第 3 组:视频通道 B(5 个)
//
// ★ 这 5 个必须在「持有 GL 上下文、且上下文已 current」的那一个线程上调用,
//   且和事件线程(lp_next_event)必须是不同线程(SPEC §7.2 约束 1)。

//export lp_gl_init
func lp_gl_init(getProcAddress unsafe.Pointer, ctx unsafe.Pointer) (ret C.int32_t) {
	ret = eOK
	defer guard("lp_gl_init", &ret, eInternal)
	return glInit(getProcAddress, ctx)
}

//export lp_gl_wants_redraw
func lp_gl_wants_redraw() (ret C.int32_t) {
	defer guard("lp_gl_wants_redraw", &ret, 0)
	return glWantsRedraw()
}

//export lp_gl_render
func lp_gl_render(fbo C.uint32_t, width C.int32_t, height C.int32_t, flipY C.int32_t) (ret C.int32_t) {
	ret = eOK
	defer guard("lp_gl_render", &ret, eInternal)
	return glRender(fbo, width, height, flipY)
}

//export lp_gl_swapped
func lp_gl_swapped() {
	defer guard("lp_gl_swapped", nil, 0)
	glSwapped()
}

//export lp_gl_uninit
func lp_gl_uninit() {
	defer guard("lp_gl_uninit", nil, 0)
	glUninit()
}

// ---------------------------------------------------------- 辅助

// goStr 把 C 字符串**立刻**拷成 Go string。
// SPEC §5.3:传进来的指针在调用返回后即失效,不许把它带进 goroutine。
func goStr(p *C.char) string {
	if p == nil {
		return ""
	}
	return C.GoString(p)
}

func platformName() string { return runtime.GOOS }

func videoChannel() string {
	switch runtime.GOOS {
	case "android", "darwin", "ios":
		return "surface" // 通道 A
	default:
		return "gl" // 通道 B
	}
}
