// Package main 是 C ABI 导出层 —— **唯一**带 `//export` 的包(SPEC §4.1)。
//
// 本文件**不含任何业务逻辑**。它只做三件事:
//
//	① 把 C 类型翻成 Go 类型(并**立刻**拷贝字符串,见 SPEC §5.3)
//	② 每个导出顶层 `defer recover()`(SPEC §5.10)
//	③ 转给 core/bus 或 core/player
//
// 加业务逻辑到这里 = 那段逻辑再也没法单独测。
package main

/*
#include <stdlib.h>
#include <stdint.h>
*/
import "C"

import (
	"encoding/json"
	"runtime/debug"
	"sync"
	"sync/atomic"
	"unsafe"

	"linplayer/core/account"
	"linplayer/core/aggregate"
	"linplayer/core/bus"
	"linplayer/core/config"
	"linplayer/core/emby"
	"linplayer/core/history"
	"linplayer/core/net/localserve"
	"linplayer/core/paths"
	"linplayer/core/player"
	"linplayer/core/prefs"
	"linplayer/core/system"
)

func main() {} // c-shared 需要,但永远不会被调用

// C 字符串的分配/释放计数 —— SPEC §5.3「Go 分配,宿主释放」的**直接判据**。
//
// ★ 用「进程私有内存涨了多少」当判据是测不出来的:实测 2 万次往返里漏掉的
// C 字符串只有约 2 MB,完全被宿主运行时自己的分配淹没(正常 23.7 MB vs
// 故意不 free 24.5 MB,分不出来)。见 SPIKE-2 §4.3。
var cstrAlloc, cstrFree atomic.Int64

const (
	eOK       C.int32_t = 0
	eNotInit  C.int32_t = -1
	eShutdown C.int32_t = -2
	eBadArg   C.int32_t = -3
	eInternal C.int32_t = -99
)

var initOnce sync.Once

// guard 是每个导出的 panic 兜底。ret 是 panic 时该返回的值。
func guard(where string, ret *C.int32_t, code C.int32_t) {
	if r := recover(); r != nil {
		bus.Logf("error", "导出函数 %s panic: %v | %s", where, r, string(debug.Stack()))
		if ret != nil {
			*ret = code
		}
	}
}

// goStr 把 C 字符串**立刻**拷成 Go string。
// SPEC §5.3:传进来的指针在调用返回后即失效,不许把它带进 goroutine。
func goStr(p *C.char) string {
	if p == nil {
		return ""
	}
	return C.GoString(p)
}

// ---------------------------------------------------------- 第 1 组:控制通道(7 个)

// lp_abi_version 必须在 lp_init 之前调,不匹配就不要 init(SPEC §5.0)。
// 它天然向后兼容 —— 旧库里没有这个符号,**这件事本身就是信号**。
//
// localServer 是本地数据通道(SPEC §6)。lp_init 起、lp_shutdown 停。
var localServer *localserve.Server

//export lp_abi_version
func lp_abi_version() C.int32_t { return C.int32_t(LP_ABI) }

// lp_init 初始化。config_json 传宿主已知的平台信息(数据目录、平台名、版本号)。幂等。
//
//export lp_init
func lp_init(configJSON *C.char) (ret C.int32_t) {
	ret = eOK
	defer guard("lp_init", &ret, eInternal)

	cfg := goStr(configJSON) // 立刻拷贝:返回后这个指针就失效了
	initOnce.Do(func() {
		var hostCfg struct {
			DataDir  string `json:"dataDir"`
			Platform string `json:"platform"`
			Version  string `json:"version"`
		}
		_ = json.Unmarshal([]byte(cfg), &hostCfg)

		// ★ 数据根必须**第一个**定下来。
		//   现有 Rust 版栽过:迁移写成显式调用时,配置加载恰好排在它前面 ——
		//   配置读不到就生成设备 id 并立刻保存,在新根落下一个空配置;
		//   迁移随后看见目标已存在就跳过 → 旧根里的账号 / token 永远搬不过来。
		//   顺序错了不报错,只是用户升级后「服务器全没了」(SPEC §16.1)。
		paths.SetRoot(hostCfg.DataDir)
		if hostCfg.Version != "" {
			system.Version = hostCfg.Version
		}

		bus.Init()
		system.RegisterCommands()
		player.RegisterCommands(system.Version)
		emby.RegisterCommands(system.Version)
		account.RegisterCommands(system.Version)
		prefs.RegisterCommands(system.Version)
		history.RegisterCommands()
		aggregate.RegisterCommands(system.Version)

		// ★ 起本地 HTTP 数据通道(SPEC §6)。地址和 token 通过**首个事件**告知宿主 ——
		//   三端的图片加载器要拿它拼 `/img?src=`,拿不到就是「一张图都没有」。
		//   起不来不算致命:命令通道照走,只是图片全空。所以只记 error 不 return。
		if srv, err := localserve.Start(); err != nil {
			bus.Logf("error", "本地数据通道起不来(图片将全部为空): %v", err)
		} else {
			localServer = srv
			localserve.SetDefault(srv)
			bus.Emit("localserve.ready", map[string]string{
				"baseUrl": srv.BaseURL(),
				"token":   srv.Token,
			}, "")
		}

		if err := paths.EnsureDirs(); err != nil {
			bus.Logf("error", "建数据目录失败: %v", err)
		}
		if _, err := config.Load(); err != nil {
			// ★ 配置坏了**必须冒出来**,不许静默退回空配置 ——
			//   那会在下一次保存时把用户的账号全覆盖掉(见 core/config 包注释)
			bus.Logf("error", "配置加载失败(不会退回空配置): %v", err)
		}
		bus.Logf("info", "核心层已启动 ABI=%d 平台=%s 数据根=%s 命令=%d 条",
			LP_ABI, hostCfg.Platform, paths.Root(), len(bus.Commands()))
	})
	return eOK
}

// lp_call 发起一条命令。立即返回(不阻塞)。结果通过事件队列以 {"t":"result"} 送回。
//
//export lp_call
func lp_call(seq C.int64_t, cmd *C.char, argsJSON *C.char) (ret C.int32_t) {
	ret = eOK
	defer guard("lp_call", &ret, eInternal)

	if !bus.Started() {
		return eNotInit
	}
	if bus.ShuttingDown() {
		return eShutdown
	}
	if err := bus.Call(int64(seq), goStr(cmd), goStr(argsJSON)); err != nil {
		return eBadArg
	}
	return eOK
}

//export lp_cancel
func lp_cancel(seq C.int64_t) {
	defer guard("lp_cancel", nil, 0)
	bus.Cancel(int64(seq))
}

// lp_next_event 阻塞取下一个事件。timeout_ms < 0 表示无限等;超时返回 NULL。
// **调用方必须用 lp_free 释放返回的指针。**
//
//export lp_next_event
func lp_next_event(timeoutMs C.int32_t) (ret *C.char) {
	defer func() {
		if r := recover(); r != nil {
			ret = nil
		}
	}()
	b := bus.NextEvent(int32(timeoutMs))
	if b == nil {
		return nil
	}
	cstrAlloc.Add(1)
	// C.CString 用 malloc 分配 —— 与 lp_free 的 free() 配对(SPEC §5.3)
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
	// ★ 关 mpv 必须排在 lp_gl_uninit 之后(S1.2 实测:反过来宿主合成器当场抛异常)。
	//   这里只关核心;GL 通道由宿主在销毁 GL 上下文前自己调 lp_gl_uninit。
	player.Close()
	// ★ 停在 bus.Shutdown 之前:队列一发 EOF 消费者就走了,再有日志也没人收。
	if localServer != nil {
		_ = localServer.Close()
		localServer = nil
	}
	bus.Shutdown()
}

// ---------------------------------------------------------- 第 2 组:视频通道 A(1 个)

// kind: 0=none(解绑) 1=ANativeWindow* 4=CAMetalLayer*
// 解绑(kind=0)**必须阻塞到 mpv 真的不再往里画**,否则是 use-after-free。
//
//export lp_set_surface
func lp_set_surface(kind C.int32_t, handle C.int64_t, width C.int32_t, height C.int32_t) (ret C.int32_t) {
	ret = eOK
	defer guard("lp_set_surface", &ret, eInternal)
	return C.int32_t(player.SetSurface(int32(kind), int64(handle), int32(width), int32(height)))
}

// ---------------------------------------------------------- 第 3 组:视频通道 B(5 个)
//
// ★ 这 5 个必须在「持有 GL 上下文、且上下文已 current」的那一个线程上调用,
//   且和事件线程(lp_next_event)必须是不同线程(SPEC §7.2 约束 1)。

//export lp_gl_init
func lp_gl_init(getProcAddress unsafe.Pointer, ctx unsafe.Pointer) (ret C.int32_t) {
	ret = eOK
	defer guard("lp_gl_init", &ret, eInternal)
	return C.int32_t(player.GLInit(getProcAddress, ctx))
}

//export lp_gl_wants_redraw
func lp_gl_wants_redraw() (ret C.int32_t) {
	defer guard("lp_gl_wants_redraw", &ret, 0)
	return C.int32_t(player.GLWantsRedraw())
}

//export lp_gl_render
func lp_gl_render(fbo C.uint32_t, width C.int32_t, height C.int32_t, flipY C.int32_t) (ret C.int32_t) {
	ret = eOK
	defer guard("lp_gl_render", &ret, eInternal)
	return C.int32_t(player.GLRender(uint32(fbo), int32(width), int32(height), int32(flipY)))
}

// lp_gl_swapped 报告「上一帧真的上屏了」。渲完并 present 之后必须调。
//
// ★ 2026-08-31 订正:「漏了它 4K60 掉到 18fps」复现不出来(S1.2,10 组 A/B)。
//
//	仍然必须调 —— 代价是零、是 mpv 规定的上报口;但别再拿那个数字去反查性能问题。
//
//export lp_gl_swapped
func lp_gl_swapped() {
	defer guard("lp_gl_swapped", nil, 0)
	player.GLSwapped()
}

// lp_gl_uninit 解绑并销毁 render context。
// **必须在销毁 GL 上下文之前调,且阻塞返回;也必须排在 lp_shutdown 之前。**
//
//export lp_gl_uninit
func lp_gl_uninit() {
	defer guard("lp_gl_uninit", nil, 0)
	player.GLUninit()
}

// ---------------------------------------------------------- 内存所有权自检
//
// 不是契约的一部分,但 B1.4 的压测判据靠它 —— 见 SPIKE-2 §4.3
// 为什么不能用进程内存当判据。

//export lp_debug_cstr_counters
func lp_debug_cstr_counters(alloc *C.int64_t, freed *C.int64_t) {
	defer guard("lp_debug_cstr_counters", nil, 0)
	if alloc != nil {
		*alloc = C.int64_t(cstrAlloc.Load())
	}
	if freed != nil {
		*freed = C.int64_t(cstrFree.Load())
	}
}
