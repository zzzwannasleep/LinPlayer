// Package system 注册 `system.*` 与测试构建才有的 `debug.*`。
package system

import (
	"context"
	"os"
	"runtime"
	"time"

	"linplayer/core/bus"
	"linplayer/core/paths"
)

// Version 由 -ldflags -X 注入(SPEC §10.4 编译期凭据同款机制)。
var Version = "dev"

// RegisterCommands 由 lp_init 调用。
func RegisterCommands() {
	bus.Register("system.ping", func(ctx context.Context, seq int64, args map[string]any) (any, error) {
		return map[string]any{"pong": true, "ts": bus.MonoMillis()}, nil
	})

	bus.Register("system.capabilities", func(ctx context.Context, seq int64, args map[string]any) (any, error) {
		return Capabilities(), nil
	})

	bus.Register("system.exportDiagnostics", func(ctx context.Context, seq int64, args map[string]any) (any, error) {
		var ms runtime.MemStats
		runtime.ReadMemStats(&ms)
		return map[string]any{
			"version":    Version,
			"platform":   runtime.GOOS,
			"arch":       runtime.GOARCH,
			"uptimeMs":   bus.MonoMillis(),
			"dataRoot":   paths.Root(),
			"queue":      bus.QueueStats(),
			"panicCount": bus.PanicCount(),
			"commands":   len(bus.Commands()),
			"goHeapMB":   float64(ms.HeapAlloc) / 1048576.0,
			"goroutines": runtime.NumGoroutine(),
		}, nil
	})

	// ---- 只在开了 LP_DEBUG_CMDS 时存在。SPEC §5.10 的先红要求靠它们。----
	//
	// ★ 故意分成两条:它们在 .NET 宿主下的行为**不一样**(SPIKE-2 §4.2)。
	//   只测显式 panic 会得到「recover 有效」的假结论,
	//   而真实世界里的 panic 大多是运行时故障那一类。
	if os.Getenv("LP_DEBUG_CMDS") == "1" {
		bus.Register("debug.panic", func(ctx context.Context, seq int64, args map[string]any) (any, error) {
			panic("故意的显式 panic:验证 SPEC §5.10 的 recover 边界")
		})
		bus.Register("debug.panicnil", func(ctx context.Context, seq int64, args map[string]any) (any, error) {
			var p *int
			_ = *p // 运行时故障,走硬件异常那条路
			return nil, nil
		})
		bus.Register("debug.echo", func(ctx context.Context, seq int64, args map[string]any) (any, error) {
			return map[string]any{"args": args}, nil
		})
		// 长任务 + 流式中间结果(SPEC §5.7),顺带给 lp_cancel 当靶子
		bus.Register("debug.slow", func(ctx context.Context, seq int64, args map[string]any) (any, error) {
			n := 5
			if v, ok := args["steps"].(float64); ok {
				n = int(v)
			}
			for i := 1; i <= n; i++ {
				select {
				case <-ctx.Done():
					return nil, bus.NewErr(bus.EShutdown, "已取消")
				case <-time.After(80 * time.Millisecond):
				}
				bus.Partial(seq, map[string]any{"step": i, "of": n})
			}
			return map[string]any{"done": n}, nil
		})
		bus.Register("debug.unsupported", func(ctx context.Context, seq int64, args map[string]any) (any, error) {
			return nil, bus.NewErr(bus.EUnsupported, "该源不支持这个能力")
		})
	}
}

// Capabilities 让 UI 探测平台差异,而不是靠三份拷贝各自维护(SPEC §5.6)。
func Capabilities() map[string]any {
	return map[string]any{
		"version":   Version,
		"platform":  runtime.GOOS,
		"arch":      runtime.GOARCH,
		"videoChan": VideoChannel(),
		// 字幕翻译是桌面独占(COMMANDS.md:translate.* 9 条,安卓 0 条)。
		// Q6 已定:模型不打进主包,首次使用时下载到 userdata/models/
		"translate": runtime.GOOS == "windows" || runtime.GOOS == "linux",
		"pluginUI":  true,
		// 插件逃生舱要 WebView。Windows 上是 WebView2(§16.4:已从「必需」降为「可选」)
		"webviewEscape": runtime.GOOS == "windows" || runtime.GOOS == "linux",
	}
}

// VideoChannel 报告本平台走哪条视频通道(SPEC §7.2)。
func VideoChannel() string {
	switch runtime.GOOS {
	case "android", "darwin", "ios":
		return "surface" // 通道 A:原生合成能把 UI 画在视频上
	default:
		return "gl" // 通道 B:UI 持有 GL 上下文,核心层渲进它给的 FBO
	}
}
