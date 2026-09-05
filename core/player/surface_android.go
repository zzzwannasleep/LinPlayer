//go:build android

// 视频通道 A —— 安卓的 SurfaceView 绑定(SPEC §7.2)。
//
// 安卓不走 GL 渲染那条:SurfaceView 是独立合成层,系统天然把 View 树画在它上面。
// UI 把 ANativeWindow* 交过来,这里把它设成 mpv 的 wid。
package player

/*
#include <stdlib.h>
#include <stdint.h>
#include <android/native_window.h>

extern int   mpv_set_option_string(void*, const char*, const char*);
extern char* mpv_get_property_string(void*, const char*);
extern void  mpv_free(void*);
*/
import "C"

import (
	"runtime"
	"strconv"
	"sync"
	"sync/atomic"
	"unsafe"

	"linplayer/core/bus"
)

// decodeThreads 封顶 8:再多线程也吃不满,而每条线程都要一份帧缓冲 ——
// 手机上那是几十 MB 的白花。
func decodeThreads() int {
	n := runtime.NumCPU()
	if n > 8 {
		n = 8
	}
	if n < 1 {
		n = 1
	}
	return n
}

var (
	surfMu    sync.Mutex
	surfWin   unsafe.Pointer // ANativeWindow*,由核心层持有并 release
	surfReady atomic.Bool
)

// videoOutReady:安卓的「视频输出就绪」= surface 已绑上。
// 语义和桌面那条(render context 就绪)是同一件事 —— 起播之前视频输出必须存在,
// 否则 vo 初始化失败且 mpv 不重试,表现是全程黑屏而没有任何回调会喊。
func videoOutReady() bool { return surfReady.Load() }

// SetSurface 绑 / 解绑 SurfaceView。
//
// ☠ 解绑必须**阻塞到 mpv 真的不再往里画**:surfaceDestroyed 返回后 Surface 立即失效,
// 还在画就是 use-after-free。屏障是「先把 vo 拆掉,再读一次属性」——
// mpv_get_property_string 是同步往返,它返回时核心已经处理完前面那条 vo=null。
// 光设 vo=null 就 release 是**没有屏障**的,那正是旧栈漏掉的那一条(TODO N5)。
func SetSurface(kind int32, handle int64, width, height int32) int32 {
	if kind != 0 && kind != 1 {
		bus.Logf("warn", "lp_set_surface:安卓只认 kind=1(ANativeWindow),收到 %d", kind)
		return -1
	}
	if rc := ensureMpv(); rc != 0 {
		return rc
	}
	mpvMu.Lock()
	h := mpvH
	mpvMu.Unlock()
	if h == nil {
		return -1
	}

	surfMu.Lock()
	defer surfMu.Unlock()

	if kind == 0 {
		surfReady.Store(false)
		detachLocked(h)
		return 0
	}

	win := unsafe.Pointer(uintptr(handle))
	if win == surfWin {
		// 同一个 surface 只是尺寸变了。重设 wid 会让 vo 整个重建(黑一帧),
		// 而 mpv 自己会跟着 ANativeWindow 的尺寸走,什么都不用做。
		return 0
	}
	detachLocked(h)

	if rc := setOpt(h, "wid", strconv.FormatInt(handle, 10)); rc < 0 {
		bus.Logf("error", "mpv wid 没设上(错误码 %d)—— 这次不会有画面", rc)
		return -1
	}
	if rc := setOpt(h, "vo", "gpu"); rc < 0 {
		bus.Logf("error", "mpv vo=gpu 没设上(错误码 %d)", rc)
		return -1
	}
	surfWin = win
	surfReady.Store(true)
	bus.Logf("info", "surface 已绑定 %dx%d", width, height)
	return 0
}

// detachLocked 拆掉当前 surface。调用方必须持有 surfMu。
func detachLocked(h unsafe.Pointer) {
	if surfWin == nil {
		return
	}
	setOpt(h, "vo", "null")
	setOpt(h, "wid", "0")
	// ★ 同步屏障:读一次属性,等核心把上面两条处理完再 release。
	if s := C.mpv_get_property_string(h, C.CString("vo")); s != nil {
		C.mpv_free(unsafe.Pointer(s))
	}
	C.ANativeWindow_release((*C.ANativeWindow)(surfWin))
	surfWin = nil
	bus.Logf("info", "surface 已解绑")
}

func setOpt(h unsafe.Pointer, k, v string) int {
	ck, cv := C.CString(k), C.CString(v)
	defer C.free(unsafe.Pointer(ck))
	defer C.free(unsafe.Pointer(cv))
	return int(C.mpv_set_option_string(h, ck, cv))
}

// platformOptions 是安卓专属的 mpv 起手选项,追加在 baseOptions 之后(后写的赢)。
//
// vo/gpu-context:桌面那条 vo=libmpv 是给 render API 用的,安卓走 wid。
// 软解调优:安卓端 libmpv 是纯软解,不调的表现是 1080p 以上卡顿(TODO N2 丢过一次)。
// sub-fonts-dir:不给的话 libass 找不到字体,**文本字幕整个不显示**(桌面早有、安卓漏过)。
func platformOptions() [][2]string {
	return [][2]string{
		{"vo", "gpu"},
		{"gpu-context", "android"},
		{"opengl-es", "yes"},
		{"sub-fonts-dir", "/system/fonts"},
		{"vd-lavc-threads", strconv.Itoa(decodeThreads())},
		{"vd-lavc-skiploopfilter", "nonref"},
		{"vd-lavc-fast", "yes"},
		{"hdr-compute-peak", "no"},
	}
}
