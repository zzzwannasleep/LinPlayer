//go:build !android

package player

import "linplayer/core/bus"

// SetSurface:桌面走视频通道 B(GL 渲染),这条不会被调到。
// 真被调到说明宿主接错了通道,所以要留一句日志而不是静默返回。
func SetSurface(kind int32, handle int64, width, height int32) int32 {
	if kind == 0 {
		return 0
	}
	bus.Logf("warn", "lp_set_surface 在本平台不适用(桌面走通道 B):kind=%d %dx%d", kind, width, height)
	return 0
}

// videoOutReady:桌面的「视频输出就绪」= GL render context 建好了。
// waitRenderCtx 用它把起播挡到就绪之后(SPEC §7.2 约束 6)。
func videoOutReady() bool { return rctxSet.Load() }

// platformOptions:桌面没有平台专属的 mpv 选项。返回 nil 让 ensureMpv 的
// 追加是空操作 —— baseOptions 的输出因此一字不变,它那条测试照样钉得住。
func platformOptions() [][2]string { return nil }
