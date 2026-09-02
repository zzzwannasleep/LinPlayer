//go:build !windows

package system

// PinHighPerformanceGPU 在非 Windows 上是空操作。
//
// Linux 的混合显卡走的是另一套(DRI_PRIME / __NV_PRIME_RENDER_OFFLOAD 环境变量,
// 且要在进程启动**之前**设好,程序自己设没用)—— 那属于发行包的启动脚本,
// 不是核心层能管的。安卓没有这个概念。
func PinHighPerformanceGPU() {}
