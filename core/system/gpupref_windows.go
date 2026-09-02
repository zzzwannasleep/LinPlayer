//go:build windows

package system

// 混合显卡:把本程序钉到独显(SPEC 之外的平台补丁,来源见 docs/lessons/player-mpv.md
// 「双显卡必须钉独显」)。
//
// ## 症状
//
// 2026-07-15 用户报「Anime4K 非常非常卡」。mpv 日志第一屏就是判决书:
//
//	[v][vo/gpu-next/d3d11] Device Name: Intel(R) UHD Graphics   ← 核显
//
// 整条 CNN 链跑在核显上,独显全程没参与。**根因不是档位、不是着色器、不是动画** ——
// 混合显卡机器上 D3D11 的默认适配器 = 接显示器的那块(核显),而我们是个新面孔,
// 显卡驱动的程序配置库里没有我们 → 落到默认的「集显」档。
//
// ## 为什么不照抄黄金实现
//
// Rust 版的修法是从 **exe** 导出两个数据符号(`NvOptimusEnablement` /
// `AmdPowerXpressRequestHighPerformance`)。那条路在 C#/.NET 宿主上**走不通**:
// apphost 没有可写的导出表,`[UnmanagedCallersOnly]` 导出的是函数不是 DWORD。
//
// 换成 Windows 10 1803 起的 per-exe 显卡偏好 —— 就是「设置 → 系统 → 显示 → 图形」
// 那个界面写的同一个注册表位置。相对导出符号的好处:
//
//   - 一处同时覆盖 N 卡和 A 卡,不认厂商名
//   - 单显卡机器上天然是空操作
//   - 它影响的是**进程的 DXGI 适配器顺序**,所以 ANGLE(Avalonia 在 Windows 上
//     的 GL 后端)拿到的也是独显 —— 我们的画面路径是 `vo=libmpv` + OpenGL,
//     mpv 跟着宿主的 GL 上下文走,钉住宿主就等于钉住 mpv。
//
// ⚠️ **已知限制:偏好是进程启动时读的。** 全新机器上第一次运行仍可能落在核显,
// 从第二次起才生效。这一条要如实写在日志里,别让人以为改完立刻就有。

import (
	"fmt"
	"os"
	"strings"
	"syscall"
	"unsafe"

	"linplayer/core/bus"
)

// GPUPrefKey 是 Windows 自己那套 per-exe 显卡偏好的位置(HKCU 下)。
const GPUPrefKey = `Software\Microsoft\DirectX\UserGpuPreferences`

// gpuPrefHighPerf 值的格式是 Windows 定的:`GpuPreference=<0|1|2>;`
// 0=系统决定 1=省电(核显) 2=高性能(独显)。分号不能省。
const gpuPrefHighPerf = "GpuPreference=2;"

// decideGPUPref 决定要不要写、写什么。
//
// ★ 已经有值就**一律不动**,哪怕它是 1(省电)。那多半是用户自己在系统设置里
// 选的 —— 笔记本外出时故意钉核显是完全合理的诉求。覆盖用户的明确选择是越界。
func decideGPUPref(cur string, exists bool) (string, bool) {
	if exists && strings.Contains(cur, "GpuPreference=") {
		return "", false
	}
	return gpuPrefHighPerf, true
}

// PinHighPerformanceGPU 在混合显卡机器上把本程序钉到独显。幂等,失败只记日志。
//
// 失败不该拦启动:最坏结果是「超分比应有的慢」,而不是「打不开」。
func PinHighPerformanceGPU() {
	exe, err := os.Executable()
	if err != nil {
		bus.Logf("warn", "拿不到自身路径,跳过独显钉死: %v", err)
		return
	}
	switch action, err := applyGPUPref(GPUPrefKey, exe); {
	case err != nil:
		bus.Logf("warn", "独显钉死失败(混合显卡机器上可能仍跑核显): %v", err)
	case action == kept:
		bus.Logf("info", "显卡偏好已有设置,尊重现状不覆盖")
	default:
		bus.Logf("info", "已把本程序钉到高性能显卡 —— **下次启动生效**(偏好是进程启动时读的)")
	}
}

const (
	kept    = "kept"
	written = "written"
)

// applyGPUPref 读—判—写。subkey / valueName 是参数而不是常量,测试才能拿一个
// 一次性的键去验真正的注册表读写链路 —— 只测 decideGPUPref 等于没测下面这半截。
func applyGPUPref(subkey, valueName string) (string, error) {
	h, err := regCreateKey(subkey)
	if err != nil {
		return "", err
	}
	defer procRegCloseKey.Call(uintptr(h))

	cur, exists, err := regQueryString(h, valueName)
	if err != nil {
		return "", err
	}
	want, need := decideGPUPref(cur, exists)
	if !need {
		return kept, nil
	}
	if err := regSetString(h, valueName, want); err != nil {
		return "", err
	}
	return written, nil
}

// ---------------------------------------------------------------- 注册表最小封装
//
// ★ 不引 golang.org/x/sys/registry:核心层「零第三方依赖是刻意的」(go.mod 包注释)。
// 用到的就四个函数,不值得为它多一条依赖线。

const (
	hkeyCurrentUser = 0x80000001
	keyReadWrite    = 0x2001F // KEY_READ | KEY_WRITE
	regSZ           = 1
	errFileNotFound = 2
)

var (
	advapi32            = syscall.NewLazyDLL("advapi32.dll")
	procRegCreateKeyEx  = advapi32.NewProc("RegCreateKeyExW")
	procRegQueryValueEx = advapi32.NewProc("RegQueryValueExW")
	procRegSetValueEx   = advapi32.NewProc("RegSetValueExW")
	procRegCloseKey     = advapi32.NewProc("RegCloseKey")
	procRegDeleteKey    = advapi32.NewProc("RegDeleteKeyW")
)

func regCreateKey(subkey string) (syscall.Handle, error) {
	s, err := syscall.UTF16PtrFromString(subkey)
	if err != nil {
		return 0, err
	}
	var h syscall.Handle
	r, _, _ := procRegCreateKeyEx.Call(hkeyCurrentUser, uintptr(unsafe.Pointer(s)),
		0, 0, 0, keyReadWrite, 0, uintptr(unsafe.Pointer(&h)), 0)
	if r != 0 {
		return 0, fmt.Errorf("RegCreateKeyExW(%s) 返回 %d", subkey, r)
	}
	return h, nil
}

func regQueryString(h syscall.Handle, name string) (string, bool, error) {
	n, err := syscall.UTF16PtrFromString(name)
	if err != nil {
		return "", false, err
	}
	var typ uint32
	buf := make([]uint16, 512)
	sz := uint32(len(buf) * 2) // 字节数,不是字符数
	r, _, _ := procRegQueryValueEx.Call(uintptr(h), uintptr(unsafe.Pointer(n)), 0,
		uintptr(unsafe.Pointer(&typ)), uintptr(unsafe.Pointer(&buf[0])), uintptr(unsafe.Pointer(&sz)))
	if r == errFileNotFound {
		return "", false, nil
	}
	if r != 0 {
		return "", false, fmt.Errorf("RegQueryValueExW 返回 %d", r)
	}
	return syscall.UTF16ToString(buf), true, nil
}

func regSetString(h syscall.Handle, name, val string) error {
	n, err := syscall.UTF16PtrFromString(name)
	if err != nil {
		return err
	}
	v, err := syscall.UTF16FromString(val)
	if err != nil {
		return err
	}
	r, _, _ := procRegSetValueEx.Call(uintptr(h), uintptr(unsafe.Pointer(n)), 0, regSZ,
		uintptr(unsafe.Pointer(&v[0])), uintptr(len(v)*2))
	if r != 0 {
		return fmt.Errorf("RegSetValueExW 返回 %d", r)
	}
	return nil
}

// regDeleteKey 只给测试收尾用。删不掉就算了(键非空时本来就该失败)。
func regDeleteKey(subkey string) {
	if s, err := syscall.UTF16PtrFromString(subkey); err == nil {
		procRegDeleteKey.Call(hkeyCurrentUser, uintptr(unsafe.Pointer(s)))
	}
}
