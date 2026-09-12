package player

// 弹幕显示设置 + 布局 + 热力图(用户 2026-09-09 点名的九项)。
//
// 为什么排版留在核心层、绘制交给 UI:排一次要遍历上万条并逐轨算避让,
// 那是「换了设置才重来一次」的活;而画一帧只是把定好的坐标乘个缩放,
// 那是「每帧都要做」的活。两端各写一份排版的下场是 PC 和手机上同一集
// 弹幕排得不一样,而两边代码都「对」。

import (
	"context"
	"fmt"
	"math"
	"sort"
	"sync"

	"linplayer/core/bus"
	"linplayer/core/config"
)

// dmStyle 一份弹幕显示设置的快照。
type dmStyle struct {
	Area        float64
	Scale       float64
	Opacity     float64
	Speed       float64
	TopLines    int
	BottomLines int
	Merge       bool
	Bold        bool
}

var (
	styMu sync.RWMutex
	sty   = dmStyleOf(config.DefaultPrefs())
	// dmRaw 灌进来的原始语料。布局的输入,style 一变就重排一次。
	dmRaw []danmakuItem

	dmMu sync.Mutex
	// dmItems 排好版的那一份。UI 层一次性取走,自己按帧插位置。
	dmItems []danmakuItem
)

func dmStyleOf(p config.Prefs) dmStyle {
	return dmStyle{
		Area: p.DanmakuArea, Scale: p.DanmakuScale, Opacity: p.DanmakuOpacity,
		Speed: p.DanmakuSpeed, TopLines: p.DanmakuTopLines, BottomLines: p.DanmakuBottomLines,
		Merge: p.DanmakuMerge, Bold: p.DanmakuBold,
	}
}

func curStyle() dmStyle {
	styMu.RLock()
	defer styMu.RUnlock()
	return sty
}

// loadDanmakuStyle 把落库的设置读进内存并重排。起播时调一次。
func loadDanmakuStyle() {
	styMu.Lock()
	sty = dmStyleOf(config.Current().PrefsOf())
	styMu.Unlock()
	relayout()
}

// ---------------------------------------------------------------- 布局

// fixSeconds 置顶 / 置底弹幕停留多久。
//
// 滚动那条是「横穿画面」所以时长有物理含义,固定弹幕没有 —— 5 秒是
// B 站客户端的口径:够读完一句话,又不至于把那一行长期占死。
const fixSeconds = 5.0

// relayout 按当前设置重排:合并 → 分轨 → 存进 dmItems。
//
// ☠ **合并必须在分轨之前。** 反过来的话被合掉的那些条目已经占过轨道,
// 屏幕上会留下一排排空行,而弹幕总数看起来又是对的。
func relayout() {
	s := curStyle()
	styMu.RLock()
	src := dmRaw
	styMu.RUnlock()

	items := src
	if s.Merge {
		items = mergeSame(items, 10.0)
	}
	out := layout(items, s)
	dmMu.Lock()
	dmItems = out
	dmMu.Unlock()
}

// mergeSame 时间窗口内同文本同类型合并,Count 记次数。
//
// ★ 和 core/danmaku 的 dedup 是**两件事**:那一份在取数时做、决定「存哪些」;
// 这一份在渲染前做、决定「这一屏怎么画」。开关在播放页一拨就要见效,
// 走取数那条的话得重新拉一次弹幕。
func mergeSame(in []danmakuItem, window float64) []danmakuItem {
	sorted := append([]danmakuItem(nil), in...)
	sort.SliceStable(sorted, func(i, j int) bool { return sorted[i].Time < sorted[j].Time })
	used := make([]bool, len(sorted))
	out := make([]danmakuItem, 0, len(sorted))
	for i := range sorted {
		if used[i] {
			continue
		}
		n := 1
		for j := i + 1; j < len(sorted); j++ {
			if used[j] {
				continue
			}
			if sorted[j].Time-sorted[i].Time > window {
				break // 已按时间排序,后面只会更远
			}
			if sorted[j].Text == sorted[i].Text && sorted[j].Mode == sorted[i].Mode {
				n++
				used[j] = true
			}
		}
		c := sorted[i]
		c.Count = n
		out = append(out, c)
	}
	return out
}

// layout 分轨。返回的每一条都带定好的 lane 和上屏用的文本;排不下的**丢掉**。
//
// ★ 丢掉而不是硬塞:排不下还画等于两条弹幕叠在一行上,那比少一条难看得多。
//   范围调小本来就是用户在要求「少一点」。
func layout(in []danmakuItem, s dmStyle) []danmakuItem {
	items := append([]danmakuItem(nil), in...)
	sort.SliceStable(items, func(i, j int) bool { return items[i].Time < items[j].Time })

	laneH := laneHeight * s.Scale
	roll := rollSeconds / s.Speed
	rollLanes := int(float64(danmakuResY) * s.Area / laneH)
	if rollLanes < 1 {
		rollLanes = 1
	}
	// free[i] = 第 i 轨最早什么时候能再放一条
	rollFree := negInf(rollLanes)
	topFree := negInf(s.TopLines)
	botFree := negInf(s.BottomLines)

	out := make([]danmakuItem, 0, len(items))
	for _, d := range items {
		d.Text = displayText(d)
		d.w = textWidth(d.Text, s.Scale)
		lane := -1
		switch d.Mode {
		case 1:
			lane = pickLane(rollFree, d.Time)
			if lane >= 0 {
				// 这一轨下次能用 = 本条的**尾巴**进了画面的时刻。
				// 用「整条走完」的话一轨一次只放得下一条,屏幕会空得离谱。
				rollFree[lane] = d.Time + d.w/(float64(danmakuResX)+d.w)*roll
			}
		case 5:
			lane = pickLane(topFree, d.Time)
			if lane >= 0 {
				topFree[lane] = d.Time + fixSeconds
			}
		case 4:
			lane = pickLane(botFree, d.Time)
			if lane >= 0 {
				botFree[lane] = d.Time + fixSeconds
			}
		}
		if lane < 0 {
			continue
		}
		d.lane = lane
		out = append(out, d)
	}
	return out
}

func negInf(n int) []float64 {
	out := make([]float64, n)
	for i := range out {
		out[i] = math.Inf(-1)
	}
	return out
}

// pickLane 找一条 now 时刻空着的轨道。都占着返回 -1。
func pickLane(free []float64, now float64) int {
	for i, f := range free {
		if now >= f {
			return i
		}
	}
	return -1
}

// displayText 合并过的带上 xN。
func displayText(d danmakuItem) string {
	if d.Count > 1 {
		return fmt.Sprintf("%s ×%d", d.Text, d.Count)
	}
	return d.Text
}

// textWidth 估算文本像素宽。
//
// ★ 只能估:精确宽度得问两端各自的排字引擎,而排版在核心层跑。
//   估宽只影响「一轨能塞多密」和「什么时候完全走出左边」,偏一点不会画错。
func textWidth(text string, scale float64) float64 {
	w := 0.0
	for _, r := range text {
		if r < 0x2E80 { // 拉丁 / 数字 / 标点:大约半角
			w += 13
		} else {
			w += 26
		}
	}
	return w * scale
}

// ---------------------------------------------------------------- 热力图

// danmakuHeatmap 把当前语料按时间切成 buckets 段,返回每段的密度(0..1)。
//
// ★ 归一化到峰值而不是给绝对条数:进度条上那几十像素高的一条,
//   用户要的是「哪儿热闹」,不是「这里有 417 条」。
func danmakuHeatmap(buckets int, duration float64) []float64 {
	if buckets <= 0 {
		buckets = 120
	}
	styMu.RLock()
	src := dmRaw
	styMu.RUnlock()
	out := make([]float64, buckets)
	if len(src) == 0 {
		return out
	}
	if duration <= 0 {
		// 没给时长就用最后一条弹幕的时刻兜底 —— 画出来的形状仍然对,
		// 只是横轴会比整片短一截(片尾没弹幕时本来也就是这样)
		for _, d := range src {
			if d.Time > duration {
				duration = d.Time
			}
		}
	}
	if duration <= 0 {
		return out
	}
	peak := 0.0
	for _, d := range src {
		i := int(d.Time / duration * float64(buckets))
		if i < 0 || i >= buckets {
			continue
		}
		out[i]++
		if out[i] > peak {
			peak = out[i]
		}
	}
	for i := range out {
		out[i] /= peak
	}
	return out
}

// ---------------------------------------------------------------- 命令

func registerDanmakuStyle() {
	// player.getDanmakuStyle 回显。面板每次打开都要读回落库的那一份 ——
	// 不读的话滑块从写死的默认值起手,和画面上的弹幕对不上。
	bus.Register("player.getDanmakuStyle", func(ctx context.Context, seq int64, a map[string]any) (any, error) {
		return styleReply(config.Current().PrefsOf()), nil
	})

	// player.setDanmakuStyle 改一项或几项,落库 + 立即重排上屏。
	bus.Register("player.setDanmakuStyle", func(ctx context.Context, seq int64, a map[string]any) (any, error) {
		c := config.Current()
		p := c.PrefsOf()
		if v, ok := numArg(a, "area"); ok {
			p.DanmakuArea = v
		}
		if v, ok := numArg(a, "scale"); ok {
			p.DanmakuScale = v
		}
		if v, ok := numArg(a, "opacity"); ok {
			p.DanmakuOpacity = v
		}
		if v, ok := numArg(a, "speed"); ok {
			p.DanmakuSpeed = v
		}
		if v, ok := numArg(a, "top_lines"); ok {
			p.DanmakuTopLines = int(v)
		}
		if v, ok := numArg(a, "bottom_lines"); ok {
			p.DanmakuBottomLines = int(v)
		}
		if v, ok := a["merge"].(bool); ok {
			p.DanmakuMerge = v
		}
		if v, ok := a["bold"].(bool); ok {
			p.DanmakuBold = v
		}
		if v, ok := a["heatmap"].(bool); ok {
			p.DanmakuHeatmap = v
		}
		if err := c.SetPrefs(p); err != nil {
			return nil, bus.NewErr(bus.EInternal, "偏好序列化失败: %v", err)
		}
		if err := c.Save(); err != nil {
			return nil, bus.NewErr(bus.EInternal, "配置保存失败: %v", err)
		}
		loadDanmakuStyle()
		// 回**钳过之后**的值:UI 照它刷读数,才不会显示一个核心层根本没接受的数
		return styleReply(config.Current().PrefsOf()), nil
	})

	// player.danmakuLayout 排好版的弹幕。灌完语料、改完设置各取一次。
	bus.Register("player.danmakuLayout", func(ctx context.Context, seq int64, a map[string]any) (any, error) {
		return danmakuLayoutReply(), nil
	})

	// player.danmakuHeatmap 当前这一集的弹幕密度。两端画同一份数据。
	bus.Register("player.danmakuHeatmap", func(ctx context.Context, seq int64, a map[string]any) (any, error) {
		n := 120
		if v, ok := numArg(a, "buckets"); ok && v > 0 {
			n = int(v)
		}
		dur, _ := numArg(a, "duration")
		return danmakuHeatmap(n, dur), nil
	})
}

// player.danmakuLayout 把排好版的这一份整个交给 UI。
//
// ★ 一次取走、UI 自己按帧插位置 —— 不是每帧来问一次。
//   每帧一次跨语言往返是上一版走 mpv `osd-overlay` 时的做法,
//   每秒 120 次,而那 120 次全排在 mpv 的核心线程上(见 danmaku.go 顶上那段)。
//
// 字段名用单字母:一集上万条,`"time"` 换成 `"t"` 省掉的是几百 KB 的
// 跨语言字符串。这是唯一一处这么写的地方,所以在这里说清楚:
// t=时刻 m=模式(1滚 4底 5顶) l=轨道 w=估算宽 c=RGB u=正文
func danmakuLayoutReply() map[string]any {
	s := curStyle()
	dmMu.Lock()
	items := dmItems
	dmMu.Unlock()

	out := make([]map[string]any, 0, len(items))
	for i := range items {
		d := &items[i]
		out = append(out, map[string]any{
			"t": d.Time, "m": d.Mode, "l": d.lane, "w": d.w, "c": d.Color, "u": d.Text,
		})
	}
	return map[string]any{
		"res_x": danmakuResX, "res_y": danmakuResY,
		"lane_height": laneHeight * s.Scale,
		// 这两个时长已经把速度算进去了:UI 不该再知道 speed 这一档怎么折算
		"roll_seconds": rollSeconds / s.Speed,
		"fix_seconds":  fixSeconds,
		"font_size":    40 * s.Scale,
		"opacity":      s.Opacity,
		"bold":         s.Bold,
		"items":        out,
	}
}

// DanmakuStyle 弹幕样式面板的回显体。
//
// 具名而不是裸 map:字段名是跨语言契约,拼错了两边都不报错,只是取到 null
// 画成空。有了这个类型 check-android-fields.py 才对得上账。
type DanmakuStyle struct {
	Area        float64 `json:"area"`
	Scale       float64 `json:"scale"`
	Opacity     float64 `json:"opacity"`
	Speed       float64 `json:"speed"`
	TopLines    int     `json:"top_lines"`
	BottomLines int     `json:"bottom_lines"`
	Merge       bool    `json:"merge"`
	Bold        bool    `json:"bold"`
	Heatmap     bool    `json:"heatmap"`
}

func styleReply(p config.Prefs) DanmakuStyle {
	return DanmakuStyle{
		Area: p.DanmakuArea, Scale: p.DanmakuScale, Opacity: p.DanmakuOpacity,
		Speed: p.DanmakuSpeed, TopLines: p.DanmakuTopLines,
		BottomLines: p.DanmakuBottomLines, Merge: p.DanmakuMerge,
		Bold: p.DanmakuBold, Heatmap: p.DanmakuHeatmap,
	}
}

func numArg(a map[string]any, k string) (float64, bool) {
	v, ok := a[k].(float64)
	return v, ok
}
