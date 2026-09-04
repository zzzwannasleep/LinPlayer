package player

// 字幕样式 / 次字幕 / 截图 / mpv.conf —— 播放页「更多」面板那一批。
//

import (
	"context"
	"fmt"
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"time"

	"linplayer/core/bus"
	"linplayer/core/config"
	"linplayer/core/paths"
)

// registerSubtitleCommands 由 RegisterCommands 调用。
func registerSubtitleCommands() {
	// setSubStyle 字幕样式。每一项都是「没传就不动」。
	bus.Register("player.setSubStyle", func(ctx context.Context, seq int64, a map[string]any) (any, error) {
		if v, ok := a["font"].(string); ok {
			setSubFont(v)
		}
		if v, ok := a["scale"].(float64); ok {
			setSubScale(v)
		}
		if v, ok := a["position"].(float64); ok {
			setSubPosition("sub-pos", v)
		}
		if v, ok := a["background"].(bool); ok {
			// 半透明黑底 vs 全透明;ASS 自带样式的字幕不受此影响
			c := "#00000000"
			if v {
				c = "#80000000"
			}
			setProp("sub-back-color", c)
		}
		if v, ok := a["blend_mode"].(string); ok {
			setProp("blend-subtitles", v)
		}
		return map[string]any{"ok": true}, nil
	})

	// setSecondarySub 次字幕(双字幕)。id 为空 = 关。
	bus.Register("player.setSecondarySub", func(ctx context.Context, seq int64, a map[string]any) (any, error) {
		id, _ := a["id"].(string)
		if id == "" {
			id = "no"
		}
		setProp("secondary-sid", id)
		return map[string]any{"id": id}, nil
	})

	bus.Register("player.setSecondarySubOpts", func(ctx context.Context, seq int64, a map[string]any) (any, error) {
		if v, ok := a["delay"].(float64); ok {
			setProp("secondary-sub-delay", strconv.FormatFloat(v, 'f', 3, 64))
		}
		if v, ok := a["position"].(float64); ok {
			setSubPosition("secondary-sub-pos", v)
		}
		if v, ok := a["ass_override"].(string); ok {
			/* ★ 次字幕的 ASS 处理模式。mpv 默认 `strip`(剥成纯文本)
			   = 用户说的「次字幕不渲染样式」。`scale` 则与主字幕同规矩:保留 ASS 自带样式。
			   ★ 取值必须是 mpv 认的枚举:传错值 mpv 只会**静默拒绝**,
			     这里先挡掉,免得调用方以为设上了。 */
			switch v {
			case "no", "scale", "force", "strip":
				setProp("secondary-sub-ass-override", v)
			default:
				return nil, bus.NewErr(bus.EInvalid, "未知的 ass_override: %s(只认 no/scale/force/strip)", v)
			}
		}
		return map[string]any{"ok": true}, nil
	})

	// ---- 截图 ----
	bus.Register("player.getScreenshotDir", func(ctx context.Context, seq int64, a map[string]any) (any, error) {
		p := config.Current().PrefsOf()
		return map[string]any{"dir": strDeref(p.ScreenshotDir), "resolved": resolveScreenshotDir(p.ScreenshotDir)}, nil
	})
	bus.Register("player.setScreenshotDir", func(ctx context.Context, seq int64, a map[string]any) (any, error) {
		c := config.Current()
		p := c.PrefsOf()
		if v, ok := a["dir"].(string); ok {
			d := strings.TrimSpace(v)
			if d == "" {
				p.ScreenshotDir = nil // 回到「系统图片文件夹」
			} else {
				// ★ 给了路径就必须建得出来 —— 存一个建不了的目录,等到按下截图才炸,
				//   那时用户早忘了自己填过什么(同 external_player 的理由)。
				if err := os.MkdirAll(d, 0o755); err != nil {
					return nil, bus.NewErr(bus.EInvalid, "这个目录建不出来: %v", err)
				}
				p.ScreenshotDir = &d
			}
		}
		if err := savePrefs(c, p); err != nil {
			return nil, err
		}
		return map[string]any{"dir": strDeref(p.ScreenshotDir), "resolved": resolveScreenshotDir(p.ScreenshotDir)}, nil
	})

	bus.Register("player.screenshot", func(ctx context.Context, seq int64, a map[string]any) (any, error) {
		// ★ 调用方没指定 → 用用户在设置页选的目录(没设才回落系统图片文件夹)。
		//   早先这里直接回落系统图片文件夹,等于**把设置项架空** —— 调用方从来不传 dir。
		base := ""
		if v, ok := a["dir"].(string); ok && strings.TrimSpace(v) != "" {
			base = strings.TrimSpace(v)
		} else {
			base = resolveScreenshotDir(config.Current().PrefsOf().ScreenshotDir)
		}
		if err := os.MkdirAll(base, 0o755); err != nil {
			return nil, bus.NewErr(bus.EInternal, "建截图目录失败: %v", err)
		}
		// 文件名用「时间戳 + 播放位置」,避免同一片子连拍互相覆盖
		at := int64(propF("time-pos"))
		if at < 0 {
			at = 0
		}
		p := filepath.Join(base, fmt.Sprintf("shot-%d-%ds.png", time.Now().Unix(), at))
		if err := command("screenshot-to-file", p, "video"); err != nil {
			return nil, bus.NewErr(bus.EInternal, "截图失败: %v", err)
		}
		return map[string]any{"path": p}, nil
	})

	// ---- mpv.conf ----
	//
	// ★ libmpv 默认 `config=no`,是我们显式开了 config-dir 才会读它 ——
	//   所以不用自己写解析器,交给 mpv。
	bus.Register("player.getMpvConf", func(ctx context.Context, seq int64, a map[string]any) (any, error) {
		return mpvConfNow(), nil
	})
	bus.Register("player.setMpvConf", func(ctx context.Context, seq int64, a map[string]any) (any, error) {
		text, _ := a["text"].(string)
		if err := writeUserConf(text); err != nil {
			return nil, bus.NewErr(bus.EInternal, "%v", err)
		}
		return mpvConfNow(), nil
	})

	// opts 播放器当前的实际参数。给「为什么这么卡」那类排查用。
	//
	// ★ 回读的是 mpv 的**当前值**不是我们设进去的值:
	//   显卡不支持时 mpv 会静默回落,只看我们设的值等于在自我确认。
	bus.Register("player.opts", func(ctx context.Context, seq int64, a map[string]any) (any, error) {
		out := map[string]any{}
		for _, k := range []string{
			"hwdec", "hwdec-current", "vo", "gpu-api", "gpu-context",
			"video-codec", "audio-codec-name", "container-fps",
			"sub-scale", "sub-pos", "secondary-sub-ass-override", "speed", "volume",
		} {
			out[k] = Prop(k)
		}
		return out, nil
	})
}

// setSubFont 字幕字体。
//
// ★ 「默认」是 UI 上的占位词,**不该塞给 libass** —— 它会去找一个叫「默认」的字体,
// 找不到就退回内置字体,而用户以为自己选的那个生效了。
func setSubFont(font string) {
	if !shouldSetFont(font) {
		return
	}
	setProp("sub-font", font)
}

// shouldSetFont 拆出来只为可测:这条规则的全部内容就是这个判断。
func shouldSetFont(font string) bool {
	f := strings.TrimSpace(font)
	return f != "" && f != "默认"
}

// setSubScale 字幕缩放倍率。
//
// ★★ **这才是「字幕大小」该拧的那颗旋钮**,别再拿 sub-font-size 当大小用。
//
// 2026-07-16 用 ctypes 直接问 libmpv 实测:
//   - `sub-ass-override` 默认 = `scale` —— 这个模式下 ASS 字幕**只认 sub-scale,
//     完全忽略 sub-font-size**。而内封字幕(尤其番剧)绝大多数是 ASS。
//   - `secondary-sub-ass-override` 默认 = `strip` —— ASS 标记被剥成纯文本,
//     于是它**反过来只认 sub-font-size**。
//
// 合起来正是用户报的那个怪象:「只能调次字幕的字体大小,主字幕的调不动」。
// sub-scale 对 ASS 与纯文本都生效,所以大小统一走它。
func setSubScale(scale float64) {
	setProp("sub-scale", strconv.FormatFloat(clampSubScale(scale), 'f', 2, 64))
}

func clampSubScale(scale float64) float64 {
	if scale < 0.2 {
		return 0.2
	}
	if scale > 4.0 {
		return 4.0
	}
	return scale
}

// setSubPosition 字幕竖直位置 0(顶)..100(底)。
//
// ★ mpv 只收**整数** —— 给小数它会静默拒绝,而调用方以为设上了。
func setSubPosition(prop string, pos float64) {
	setProp(prop, subPositionValue(pos))
}

// subPositionValue 拆出来只为可测。
func subPositionValue(pos float64) string {
	if pos < 0 {
		pos = 0
	}
	if pos > 100 {
		pos = 100
	}
	return strconv.FormatInt(int64(pos+0.5), 10)
}

// resolveScreenshotDir 截图落在哪。
//
// ★ 截图是**用户要拿去用的产物**,不是程序残留 —— 所以默认落系统图片文件夹(好找),
// 而不是跟着下载一起塞进 userdata/(那儿翻起来费劲)。
func resolveScreenshotDir(configured *string) string {
	if configured != nil && strings.TrimSpace(*configured) != "" {
		return *configured
	}
	if home, err := os.UserHomeDir(); err == nil {
		return filepath.Join(home, "Pictures", "LinPlayer")
	}
	return filepath.Join(paths.Root(), "screenshots")
}

// userConfPath mpv.conf 的位置。
func userConfPath() string { return filepath.Join(paths.Root(), "mpv", "mpv.conf") }

func mpvConfNow() map[string]any {
	p := userConfPath()
	b, _ := os.ReadFile(p)
	st, err := os.Stat(p)
	return map[string]any{
		"text": string(b),
		"path": p,
		// active = 文件真的在。空文件也算在(用户可能就是要一个空的)
		"active": err == nil && !st.IsDir(),
	}
}

// writeUserConf 写 mpv.conf。
//
// ★ **全空 = 删文件**,回到「完全不读配置」的出厂状态 ——
// 留一个空文件和没有文件对 mpv 是两件事(前者仍然会开 config-dir 那条路)。
func writeUserConf(text string) error {
	p := userConfPath()
	if strings.TrimSpace(text) == "" {
		if err := os.Remove(p); err != nil && !os.IsNotExist(err) {
			return fmt.Errorf("删除 mpv.conf 失败: %w", err)
		}
		return nil
	}
	if err := os.MkdirAll(filepath.Dir(p), 0o755); err != nil {
		return fmt.Errorf("建 mpv 配置目录失败: %w", err)
	}
	if err := os.WriteFile(p, []byte(text), 0o644); err != nil {
		return fmt.Errorf("写入 mpv.conf 失败: %w", err)
	}
	return nil
}

// AddTranslatedSubtitle 挂一条翻译好的外挂字幕。
//
// ★ 翻译完**必须挂上**,只返回路径就是「摆了个按钮不接线」:用户点了「翻译字幕」、
// 进度跑完,然后什么都没发生。
//
// ★★ secondary=true 时要**先挂再切次字幕轨**,而且切的是新挂那一条:
// mpv 的 sub-add 会把新轨排在最后,所以挂完读一次 track-list 取最大的 sid。
// 直接 `secondary-sid=1` 会切到内封第一条上 —— 表现是「次字幕出来了,但不是译文」。
func AddTranslatedSubtitle(path string, secondary bool) error {
	if strings.TrimSpace(path) == "" {
		return fmt.Errorf("翻译字幕路径为空")
	}
	flags := "select"
	if secondary {
		// 次字幕不能占掉主字幕位:auto = 挂上但不切主轨。
		flags = "auto"
	}
	if err := command("sub-add", path, flags, "翻译字幕"); err != nil {
		return fmt.Errorf("挂载翻译字幕失败: %w", err)
	}
	if !secondary {
		return nil
	}
	sid := lastSubtitleTrackID()
	if sid == "" {
		return fmt.Errorf("挂上了但找不到新字幕轨,没法设为次字幕")
	}
	setProp("secondary-sid", sid)
	return nil
}

// lastSubtitleTrackID 最后一条字幕轨的 id(刚 sub-add 进来的那条)。
func lastSubtitleTrackID() string {
	best := ""
	bestN := -1
	for _, t := range parseTracks(Prop("track-list")) {
		if t.Kind != "sub" {
			continue
		}
		if n, err := strconv.Atoi(t.ID); err == nil && n > bestN {
			bestN, best = n, t.ID
		}
	}
	return best
}
