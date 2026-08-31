package player

// 本包自己注册 `player.*` 与 `danmaku.*`。
//
// 命令归属跟着实现走 —— 不搞一个中央的大 switch。
// 现有 Rust 版最痛的一处正是「桌面与安卓是两份手工拷贝的命令层」,
// 而它的根因就是命令表和实现分家(`TODO.md` N9/N10/N11 的共同根因)。

import (
	"context"
	"errors"
	"fmt"
	"strconv"

	"linplayer/core/bus"
)

// RegisterCommands 由 lp_init 调用。
func RegisterCommands() {
	bus.Register("player.play", func(ctx context.Context, seq int64, args map[string]any) (any, error) {
		path, _ := args["path"].(string)
		if path == "" {
			return nil, bus.NewErr(bus.EInvalid, "缺少 path")
		}
		if err := playFile(path); err != nil {
			return nil, bus.NewErr(bus.EInternal, err.Error())
		}
		return map[string]any{"playing": path}, nil
	})

	bus.Register("player.prop", func(ctx context.Context, seq int64, args map[string]any) (any, error) {
		name, _ := args["name"].(string)
		if name == "" {
			return nil, bus.NewErr(bus.EInvalid, "缺少 name")
		}
		v := prop(name)
		if v == "" {
			// 属性不可用**不是错误** —— UI 探测能力时收到的是信息,不是红字(SPEC §5.4)
			return nil, bus.NewErr(bus.EUnsupported, "属性不可用", name)
		}
		return map[string]any{"name": name, "value": v}, nil
	})

	bus.Register("player.counters", func(ctx context.Context, seq int64, args map[string]any) (any, error) {
		return map[string]any{
			"renderCalls": renderCalls.Load(),
			"swapCalls":   swapCalls.Load(),
		}, nil
	})

	// ---- 弹幕(SPEC §7.5:走 osd-overlay,不占字幕轨)----

	bus.Register("danmaku.load", func(ctx context.Context, seq int64, args map[string]any) (any, error) {
		n := intArg(args, "count", 500)
		span := floatArg(args, "span", 60)
		danmakuLoad(n, span)
		return map[string]any{"loaded": n}, nil
	})

	bus.Register("danmaku.start", func(ctx context.Context, seq int64, args map[string]any) (any, error) {
		if f := intArg(args, "fpsFilter", 0); f > 0 {
			applyFpsFilter(f)
		}
		hz := intArg(args, "hz", 60)
		danmakuStart(hz)
		return map[string]any{"hz": hz}, nil
	})

	bus.Register("danmaku.stop", func(ctx context.Context, seq int64, args map[string]any) (any, error) {
		danmakuStop()
		return map[string]any{"stopped": true}, nil
	})

	bus.Register("danmaku.stats", func(ctx context.Context, seq int64, args map[string]any) (any, error) {
		return danmakuStats(), nil
	})
}

func intArg(a map[string]any, k string, def int) int {
	switch v := a[k].(type) {
	case float64:
		return int(v)
	case string:
		if n, err := strconv.Atoi(v); err == nil {
			return n
		}
	}
	return def
}

func floatArg(a map[string]any, k string, def float64) float64 {
	if v, ok := a[k].(float64); ok {
		return v
	}
	return def
}

// sscanFloat 解析 mpv 属性字符串成 float64。
// 属性拿不到时返回 NaN —— 调用方用 `v != v` 判(mpv 的 time-pos 在没起播时就是这样)。
func sscanFloat(s string, out *float64) (int, error) {
	if s == "" {
		*out = nan()
		return 0, errors.New("空值")
	}
	f, err := strconv.ParseFloat(s, 64)
	if err != nil {
		*out = nan()
		return 0, fmt.Errorf("解析 %q 失败: %w", s, err)
	}
	*out = f
	return 1, nil
}

func nan() float64 {
	var z float64
	return z / z
}
