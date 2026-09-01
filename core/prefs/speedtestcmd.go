package prefs

// prefs.cfSpeedTest —— CF 优选测速。

import (
	"context"

	"linplayer/core/bus"
	"linplayer/core/net/cf"
)

func registerSpeedTest() {
	bus.Register("prefs.cfSpeedTest", func(ctx context.Context, seq int64, a map[string]any) (any, error) {
		o := cf.DefaultOptions()
		if v, ok := a["validate_host"].(string); ok {
			o.ValidateHost = v
		}
		if v, ok := a["test_url"].(string); ok && v != "" {
			o.TestURL = v
		}
		if v, ok := a["ip_mode"].(string); ok && v != "" {
			o.IPMode = v
		}
		/* ★★ 这条要跑几十秒(256 个 IP × 4 次握手 + 8 次下载测速)。
		   调用方必须给它一个可取消的上下文并且显示进度 ——
		   一个转圈转 40 秒没有任何反馈的按钮,用户会当它卡死了然后反复点。 */
		return map[string]any{"results": cf.SpeedTest(ctx, o), "configured": cf.TestURL() != ""}, nil
	})
}
