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
	/* setSubStyle 字幕样式。每一项都是「没传就不动」。
	   ★ **设上就落库。** 这几项是 mpv 的运行时属性,mpv 每次冷启动都是新的 ——
	     不落库的表现是「调好了,关掉软件再打开又回默认」,用户会当成没生效。
	     UI 那边要在**松手时**调,不是每挪一像素调一次(每次都写一遍配置文件)。 */
	bus.Register("player.setSubStyle", func(ctx context.Context, seq int64, a map[string]any) (any, error) {
		c := config.Current()
		p := c.PrefsOf()
		touched := false
		if v, ok := a["font"].(string); ok {
			setSubFont(v)
		}
		if v, ok := a["scale"].(float64); ok {
			setSubScale(v)
			p.SubScale, touched = clampSubScale(v), true
		}
		if v, ok := a["position"].(float64); ok {
			setSubPosition("sub-pos", v)
			p.SubPos, touched = clampSubPos(v), true
		}
		if v, ok := a["border_size"].(float64); ok {
			setSubBorder(v)
			p.SubBorderSize, touched = clampSubBorder(v), true
		}
		if v, ok := a["bold"].(bool); ok {
			setSubBold(v)
			p.SubBold, touched = v, true
		}
		if v, ok := a["scale_by_window"].(bool); ok {
			setSubScaleByWindow(v)
			p.SubScaleByWindow, touched = &v, true
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
		if touched {
			if err := savePrefs(c, p); err != nil {
				return nil, err
			}
		}
		return map[string]any{"ok": true}, nil
	})

	/* getSubStyle 读回落库的那份。
	   ★ UI **必须**有这条:没有的话面板每次打开都从写死的默认值起手,
	     滑块位置和画面上的字幕对不上 —— 那比不给这个面板更糟。 */
	bus.Register("player.getSubStyle", func(ctx context.Context, seq int64, a map[string]any) (any, error) {
		return subStyleOf(config.Current().PrefsOf()), nil
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

	// opts 播放器当前的实际参数。给「为什么这么卡」「为什么没画面」那类排查用。
	//
	// ★ 回读的是 mpv 的**当前值**不是我们设进去的值:
	//   显卡不支持时 mpv 会静默回落,只看我们设的值等于在自我确认。
	//
	// ★★ `current-vo` / `dwidth` / `dheight` 三条是**「有声音没画面」的分诊表**:
	//   current-vo 空 = 视频输出压根没建起来;
	//   建了但 dwidth/dheight 为 0 = 一帧都没解出来;
	//   两者都有值 = 画面出来了但被上面某层挡住(那一类只能靠眼睛)。
	//   不给这三条的话,这类报告在界面上全长一个样,每次都要来回好几轮。
	// ★★ `last_error` 是 mpv 自己那句话。它一直只进日志,而用户看到的是
	//   「原因在日志里」—— 等于让人去导诊断包。
	bus.Register("player.opts", func(ctx context.Context, seq int64, a map[string]any) (any, error) {
		out := map[string]any{}
		for _, k := range []string{
			"hwdec", "hwdec-current", "vo", "current-vo", "gpu-api", "gpu-context",
			"video-codec", "audio-codec-name", "container-fps",
			"dwidth", "dheight", "video-format",
			"sub-scale", "sub-pos", "secondary-sub-ass-override", "speed", "volume",
		} {
			out[k] = Prop(k)
		}
		out["last_error"] = LastMpvError()
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

// setSubPosition 字幕竖直位置 0(顶)..150。
//
// ★ mpv 只收**整数** —— 给小数它会静默拒绝,而调用方以为设上了。
// ★ 上限 150 不是 100:100 是画面下沿,再往下是黑边。宽银幕片子上
//
//	「把字压到黑边里、一点画面都不挡」是最常用的一档,封在 100 就永远到不了。
func setSubPosition(prop string, pos float64) {
	setProp(prop, subPositionValue(pos))
}

// subPositionValue 拆出来只为可测。
func subPositionValue(pos float64) string {
	if pos < 0 {
		pos = 0
	}
	if pos > config.SubPosMax {
		pos = config.SubPosMax
	}
	return strconv.FormatInt(int64(pos+0.5), 10)
}

func clampSubPos(pos float64) int {
	v, _ := strconv.Atoi(subPositionValue(pos))
	return v
}

/*
setSubBorder 描边粗细。

	☠ **属性名在 mpv 0.38 改过。** 老名 `sub-border-size` / 新名 `sub-outline-size`,
	而 mpv 对不认识的属性只回一个错误码就完事 —— 写死哪一个都会在另一半的
	构建上静默失效(N13 记的就是这类)。两个都发,谁在就谁生效。
*/
func setSubBorder(px float64) {
	v := strconv.FormatFloat(clampSubBorder(px), 'f', 2, 64)
	setProp("sub-outline-size", v)
	setProp("sub-border-size", v)
	// 颜色钉死黑色:描边的用处是「压在雪地上和压在夜景上一样清楚」,
	// 只有黑边同时做得到这两件事。
	setProp("sub-outline-color", "#FF000000")
	setProp("sub-border-color", "#FF000000")
}

func clampSubBorder(px float64) float64 {
	if px < 0 {
		return 0
	}
	if px > config.SubBorderMax {
		return config.SubBorderMax
	}
	return px
}

// setSubBold 粗体。对 ASS 字幕**不生效** —— ASS 自带样式,mpv 默认的
// sub-ass-override=scale 只让缩放穿过去。面板上要写清这一条,别让用户
// 拧一个在番剧上永远没反应的开关。
func setSubBold(on bool) { setProp("sub-bold", boolProp(on)) }

// setSubScaleByWindow 字号跟窗口走(true,mpv 默认)还是跟片源分辨率走(false)。
// 全屏时两者一样,窗口化时差得很远。
func setSubScaleByWindow(on bool) { setProp("sub-scale-by-window", boolProp(on)) }

func boolProp(on bool) string {
	if on {
		return "yes"
	}
	return "no"
}

// subStyleOf 把落库的那份翻成 UI 认的形状。
//
// ★ 哨兵(0 / -1 / nil)原样透出去,让 UI 知道「这一项用的是 mpv 默认值」——
// 翻成具体数字的话,面板一打开就把默认值当成用户的选择写回去了。
// SubStyle 字幕样式面板的回显体。量程一起发 —— 滑块的上下限只能有一个出处。
type SubStyle struct {
	Scale      float64 `json:"scale"`
	Position   int     `json:"position"`
	BorderSize float64 `json:"border_size"`
	Bold       bool    `json:"bold"`
	// ScaleByWindow 没记过就不发,让 UI 显示 mpv 的默认而不是我们猜的 false。
	ScaleByWindow *bool   `json:"scale_by_window,omitempty"`
	ScaleMax      float64 `json:"scale_max"`
	ScaleMin      float64 `json:"scale_min"`
	PositionMax   int     `json:"position_max"`
	BorderMax     float64 `json:"border_max"`
}

func subStyleOf(p config.Prefs) SubStyle {
	return SubStyle{
		Scale: p.SubScale, Position: p.SubPos,
		BorderSize: p.SubBorderSize, Bold: p.SubBold,
		ScaleByWindow: p.SubScaleByWindow,
		ScaleMax:      config.SubScaleMax, ScaleMin: config.SubScaleMin,
		PositionMax: config.SubPosMax, BorderMax: config.SubBorderMax,
	}
}

/*
applySubStyle 把落库的字幕样式重新压给刚起来的 mpv。

	☠ 没有这一步的话整个功能是**半个** —— 设置当场生效、下次冷启动全回默认,
	而配置文件里明明存着用户的值。调用点在 ensureMpv 之后(属性得在 mpv 起来了才设)。
*/
func applySubStyle() {
	p := config.Current().PrefsOf()
	if p.SubScale != 0 {
		setSubScale(p.SubScale)
	}
	if p.SubPos >= 0 {
		setSubPosition("sub-pos", float64(p.SubPos))
	}
	if p.SubBorderSize >= 0 {
		setSubBorder(p.SubBorderSize)
	}
	if p.SubBold {
		setSubBold(true)
	}
	if p.SubScaleByWindow != nil {
		setSubScaleByWindow(*p.SubScaleByWindow)
	}
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

// ensureConfDir 起 mpv 时要不要开 config-dir,开在哪。
//
// ☠☠ **不能直接把用户那个目录交给 mpv。** 实测(probeConfDirPrecedence):
// mpv.conf 里的值会**顶掉**我们在 mpv_initialize 之前设的选项 —— 也就是说一行
// `vo=gpu` 就能把 `vo=libmpv` 换掉,而那是 render context 的前提:表现是桌面端
// 全程黑屏、一条错都不报。所以交给 mpv 的是**过滤过的副本**,用户那份原文一字不动。
//
// ★ 过滤而不是自己解析:profile / include / 引号这些 mpv 自己解析得最准,
// 我们只负责把会砸掉画面的那几行摘掉。
func ensureConfDir() string {
	p := userConfPath()
	b, err := os.ReadFile(p)
	if err != nil || len(b) == 0 {
		return "" // 没导入过 = 完全不读配置(libmpv 的出厂状态)
	}
	clean, dropped := sanitizeMpvConf(string(b))
	for _, d := range dropped {
		bus.Logf("warn", "mpv.conf 里这一行被忽略(它会砸掉画面输出):%s", d)
	}
	dir := filepath.Join(filepath.Dir(p), "effective")
	if err := os.MkdirAll(dir, 0o755); err != nil {
		bus.Logf("warn", "生成 mpv 有效配置目录失败,本次不读用户配置: %v", err)
		return ""
	}
	if err := os.WriteFile(filepath.Join(dir, "mpv.conf"), []byte(clean), 0o644); err != nil {
		bus.Logf("warn", "写有效 mpv.conf 失败,本次不读用户配置: %v", err)
		return ""
	}
	return dir
}

// mpvConfBanned 不许从用户配置里生效的选项。
//
// 只有两类进这张表:**会让画面整个没掉的**(vo/wid/gpu-context —— 它们决定
// mpv 往哪儿画),和**会绕过这张表本身的**(config/config-dir/include)。
// 别往里加「我们也设了的项」——那种冲突已经由「我们的值写在后面」解决了。
var mpvConfBanned = map[string]bool{
	"vo": true, "wid": true, "gpu-context": true, "opengl-es": true,
	"config": true, "config-dir": true, "include": true,
	"terminal": true,
}

// sanitizeMpvConf 把危险行注释掉,返回过滤后的正文和被摘掉的原文。
//
// ★ 保留行号(注释掉而不是删掉):用户拿我们的日志对着自己那份文件看时,
// 行号对得上才找得到是哪一行。
func sanitizeMpvConf(text string) (string, []string) {
	lines := strings.Split(text, "\n")
	dropped := []string{}
	for i, ln := range lines {
		t := strings.TrimSpace(ln)
		if t == "" || strings.HasPrefix(t, "#") || strings.HasPrefix(t, "[") {
			continue
		}
		key := t
		if j := strings.IndexAny(key, "="); j >= 0 {
			key = key[:j]
		}
		key = strings.ToLower(strings.TrimSpace(strings.TrimLeft(key, "-")))
		if mpvConfBanned[key] {
			dropped = append(dropped, t)
			lines[i] = "# [LinPlayer 忽略] " + ln
		}
	}
	return strings.Join(lines, "\n"), dropped
}

// MpvConf 用户那份 mpv.conf 的当前状态。
type MpvConf struct {
	Text string `json:"text"`
	Path string `json:"path"`
	// Active 文件真的在。空文件也算在(用户可能就是要一个空的)。
	Active bool `json:"active"`
}

func mpvConfNow() MpvConf {
	p := userConfPath()
	b, _ := os.ReadFile(p)
	st, err := os.Stat(p)
	return MpvConf{Text: string(b), Path: p, Active: err == nil && !st.IsDir()}
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
