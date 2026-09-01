package system

// 几条零散的系统命令。

import (
	"context"
	"os/exec"
	"path/filepath"
	"runtime"

	"linplayer/core/bus"
	"linplayer/core/paths"
)

// afdianSponsorURL 赞助地址。
//
// ★★ **它只能有一份,而且必须在核心层。**
// 2026-07-19 就栽在这:UI 里写死了一个凭空猜的主页,功能看着完全正常,
// **赞助收益却是零**。收款地址是那种「错了也不会报错」的东西。
//
// ★ 由构建期注入(和同步代理一套机制):它是账号地址,不该出现在提交里。
var afdianSponsorURL string

func registerMiscCommands() {
	bus.Register("system.afdianSponsorUrl", func(ctx context.Context, seq int64, a map[string]any) (any, error) {
		return afdianSponsorURL, nil
	})

	// system.openDataDir —— 在系统文件管理器里打开数据目录。
	//
	// ★ sub 只认**白名单**里那几个:直接把用户传的路径拼上去等于给了一个
	//   「用文件管理器打开任意目录」的口子。
	bus.Register("system.openDataDir", func(ctx context.Context, seq int64, a map[string]any) (any, error) {
		sub, _ := a["sub"].(string)
		var p string
		switch sub {
		case "logs":
			p = paths.LogsDir()
		case "downloads":
			p = paths.DownloadsDir()
		case "cache":
			p = paths.CacheDir()
		default:
			p = paths.Root()
		}
		if err := openPath(filepath.Clean(p)); err != nil {
			return nil, bus.NewErr(bus.EInternal, "打开目录失败: %v", err)
		}
		return nil, nil
	})
}

// openPath 用系统默认方式打开一个路径。
//
// ★ 核心层是个库,弹不了对话框 —— 但「用资源管理器打开目录」是起个进程,
// 这个它做得到,而且三端各写一遍反而更容易漏。
func openPath(p string) error {
	switch runtime.GOOS {
	case "windows":
		return exec.Command("explorer", p).Start()
	case "darwin":
		return exec.Command("open", p).Start()
	default:
		return exec.Command("xdg-open", p).Start()
	}
}
