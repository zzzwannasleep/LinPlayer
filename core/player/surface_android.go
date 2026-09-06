//go:build android

// 视频通道 A —— 安卓的 SurfaceView 绑定(SPEC §7.2)。
//
// 安卓不走 GL 渲染那条:SurfaceView 是独立合成层,系统天然把 View 树画在它上面。
// UI 把 `android.view.Surface` 的 global ref 交过来,这里把它设成 mpv 的 wid。
//
// ☠ **交给 mpv 的是 jobject 不是 ANativeWindow\*。** mpv 的 `--wid` 在安卓上
// 就是这么定义的,它自己会去 `ANativeWindow_fromSurface`。给错类型的表现是
// libmpv 线程上 JNI 检查失败 → SIGABRT,而栈顶指着 `ANativeWindow_fromSurface`,
// 看起来像宿主的错。引用的生命周期由 JNI 薄层管(见 core/ffi/jni_android.go)。
package player

/*
#include <stdlib.h>
#include <stdint.h>

extern int   mpv_set_option_string(void*, const char*, const char*);
extern int   mpv_set_property_string(void*, const char*, const char*);
extern char* mpv_get_property_string(void*, const char*);
extern void  mpv_free(void*);
*/
import "C"

import (
	"fmt"
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
	surfWid   int64 // 当前绑着的 Surface(jobject 的地址),0 = 没绑
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
// 光设 vo=null 就让调用方去释放是**没有屏障**的,那正是旧栈漏掉的那一条(TODO N5)。
//
// ☠☠ **`vo` 和 `android-surface-size` 要用 property 接口改,不能用 option 接口。**
// mpv 初始化**之后**,`mpv_set_option_string` 会被转成 `options/<name>` ——
// 那只改存着的选项值,**不会拆掉 / 重建已经跑着的 vo**。于是:
//   第一部片正常(vo 还没建,loadfile 时才读选项)→ 退出重进第二部 →
//   旧 vo 还抓着那个已经没了的 Surface → **有声音没画面**,而一条错不报。
// 写法照 mpv-android 那套(它是这个库在安卓上的参考实现):
// 解绑 = `vo=null`(property) + `force-window=no` + `wid=0`;
// 绑定 = `wid=<jobject>` + `force-window=yes` + `vo=gpu`(property)。
// `force-window` 不切的话,vo 拆掉之后没东西把输出链重新拉起来。
func SetSurface(kind int32, handle int64, width, height int32) int32 {
	if kind != 0 && kind != 1 {
		bus.Logf("warn", "lp_set_surface:安卓只认 kind=1(android.view.Surface),收到 %d", kind)
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

	// 同一个 Surface 只是尺寸变了:**不重设 wid**。重设会让 vo 整个重建,
	// 表现是转屏时黑一帧;mpv 靠 android-surface-size 就能跟上。
	if handle == surfWid {
		setSurfProp(h, "android-surface-size", fmt.Sprintf("%dx%d", width, height))
		return 0
	}
	detachLocked(h)

	// wid 只能走 option:它不是运行期属性,vo 建立时才读它。
	if rc := setOpt(h, "wid", strconv.FormatInt(handle, 10)); rc < 0 {
		bus.Logf("error", "mpv wid 没设上(错误码 %d)—— 这次不会有画面", rc)
		return -1
	}
	setOpt(h, "force-window", "yes")
	setSurfProp(h, "android-surface-size", fmt.Sprintf("%dx%d", width, height))
	if rc := setSurfProp(h, "vo", "gpu"); rc < 0 {
		bus.Logf("error", "mpv vo=gpu 没设上(错误码 %d)", rc)
		return -1
	}
	surfWid = handle
	surfReady.Store(true)
	bus.Logf("info", "surface 已绑定 %dx%d", width, height)
	return 0
}

// detachLocked 拆掉当前 surface。调用方必须持有 surfMu。
// **返回之后 mpv 保证不再往那个 Surface 里画** —— 调用方(JNI 薄层)据此释放引用。
func detachLocked(h unsafe.Pointer) {
	if surfWid == 0 {
		return
	}
	setSurfProp(h, "vo", "null")
	setOpt(h, "force-window", "no")
	setOpt(h, "wid", "0")
	// ★ 同步屏障:读一次属性,等核心把上面两条处理完。
	//   mpv_get_property_string 是同步往返,它返回时前面的选项已经生效。
	ck := C.CString("vo")
	if s := C.mpv_get_property_string(h, ck); s != nil {
		C.mpv_free(unsafe.Pointer(s))
	}
	C.free(unsafe.Pointer(ck))
	surfWid = 0
	bus.Logf("info", "surface 已解绑")
}

func setOpt(h unsafe.Pointer, k, v string) int {
	ck, cv := C.CString(k), C.CString(v)
	defer C.free(unsafe.Pointer(ck))
	defer C.free(unsafe.Pointer(cv))
	return int(C.mpv_set_option_string(h, ck, cv))
}

// setSurfProp 改**运行期属性**—— 和 setOpt 不是一回事,区别见 SetSurface 头上那段。
func setSurfProp(h unsafe.Pointer, k, v string) int {
	ck, cv := C.CString(k), C.CString(v)
	defer C.free(unsafe.Pointer(ck))
	defer C.free(unsafe.Pointer(cv))
	return int(C.mpv_set_property_string(h, ck, cv))
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
