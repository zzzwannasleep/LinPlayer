package player

// SPIKE-5 · 弹幕走 `osd-overlay` + `format=ass-events`(SPEC §7.5)。
//
// 做法**照抄 uosc_danmaku**(`knowledge/DANMAKU_CARRIER.md` §1.7 的源码拆解),
// 不自创:
//   ① 双层 overlay:滚动一层、顶/底一层,用 z 控堆叠
//   ② 按 time-pos **线性插出**当前 \pos,每拍重发
//   ③ 需要时用 `vf append @danmaku:fps=fps=N` 抬高回调频率
//   ④ display-fps < 58 或 estimated-vf-fps > 58 时跳过插帧
//
// ★ mpv 手册对 osd-overlay 明确写着 `Timing is unused` —— **mpv 不管时间轴**,
//   滚动位置要宿主每拍自己算并重发。所以「交给 libass 就零 IPC」这句话
//   对 osd-overlay **不成立**,只对 sub-add 成立(SPEC §7.5「代价必须说清」)。

/*
#include <stdlib.h>

// cgo 的序言是**按文件**的 —— glchan.go 里声明过的,这里要再声明一次。
extern int mpv_command(void*, const char**);
*/
import "C"

import (
	"fmt"
	"math/rand"
	"strings"
	"sync"
	"sync/atomic"
	"time"
	"unsafe"

	"linplayer/core/bus"
)

// 一条弹幕。字段照 B 站 XML 的 p 属性(载体格式见 SPEC §7.5.1)。
type danmakuItem struct {
	Time  float64 // 出现时刻(秒)
	Mode  int     // 1=滚动 4=底部 5=顶部
	Color uint32
	Text  string
	lane  int // 轨道,布局时算
}

const (
	danmakuResX = 1920
	danmakuResY = 1080
	laneHeight  = 54
	rollSeconds = 8.0 // 一条滚动弹幕从右边走到左边用多久
)

var (
	dmMu      sync.Mutex
	dmItems   []danmakuItem
	dmOn      atomic.Bool
	dmPushes  atomic.Int64 // 推了多少次 overlay
	dmLastPos atomic.Value // float64:上次用的 time-pos
	dmStop    chan struct{}

	// ★ 真正要量的不是「我们推了多少次」,是「**位置变了多少次**」。
	//
	// 弹幕的 \pos 是从 time-pos 线性插出来的,而 time-pos **只在视频帧边界更新**。
	// 24fps 片源上,你推 60 次 overlay 也只得到 24 个不同的位置 ——
	// 弹幕的平滑度被钉死在片源帧率上。这正是 uosc_danmaku 要插
	// `vf append @danmaku:fps=fps=N` 的原因。
	dmTicks    atomic.Int64 // 循环转了多少拍
	dmDistinct atomic.Int64 // 其中 time-pos 真的变了多少次
	jitMu      sync.Mutex
	jitDelta   []float64 // 只记「位置真的变了」的那些间隔
)

// danmakuLoad 造 n 条测试弹幕,均匀铺在 span 秒里。
func danmakuLoad(n int, span float64) {
	dmMu.Lock()
	defer dmMu.Unlock()
	dmItems = dmItems[:0]
	r := rand.New(rand.NewSource(42)) // 固定种子:两次跑的语料一样,数字才可比
	for i := 0; i < n; i++ {
		mode := 1
		switch {
		case i%17 == 0:
			mode = 5 // 顶部
		case i%23 == 0:
			mode = 4 // 底部
		}
		dmItems = append(dmItems, danmakuItem{
			Time:  r.Float64() * span,
			Mode:  mode,
			Color: 0xFFFFFF,
			Text:  fmt.Sprintf("弹幕测试 %d ABCdef", i),
			lane:  i % 16,
		})
	}
	bus.Logf("info", "弹幕语料:%d 条,铺在 %.0f 秒里", n, span)
}

// buildLayers 按当前播放位置算出两层 ASS。
//
// ★ 这是「每拍重算 \pos」的那一步。线性插值:
//
//	一条 t 时刻出现的滚动弹幕,在 now 时刻的横坐标 =
//	从 res_x 走到 -文本宽度,走完用 rollSeconds 秒。
func buildLayers(now float64) (roll string, fix string) {
	dmMu.Lock()
	items := dmItems
	dmMu.Unlock()

	var rb, fb strings.Builder
	for i := range items {
		d := &items[i]
		age := now - d.Time
		if age < 0 || age > rollSeconds {
			continue
		}
		y := 20 + d.lane*laneHeight
		switch d.Mode {
		case 1:
			// 线性插值算 x。文本宽度按字数估,够用 —— 精确宽度要问 libass,
			// 而 osd-overlay 拿不到测量结果(compute_bounds 是另一条路,没走)
			w := len([]rune(d.Text)) * 26
			x := float64(danmakuResX) - age/rollSeconds*float64(danmakuResX+w)
			fmt.Fprintf(&rb, "{\\an7\\pos(%.0f,%d)\\fs40\\bord2\\shad0\\c&H%06X&}%s\n",
				x, y, d.Color, d.Text)
		case 5:
			fmt.Fprintf(&fb, "{\\an8\\pos(%d,%d)\\fs40\\bord2\\shad0\\c&H%06X&}%s\n",
				danmakuResX/2, 20+(d.lane%3)*laneHeight, d.Color, d.Text)
		case 4:
			fmt.Fprintf(&fb, "{\\an2\\pos(%d,%d)\\fs40\\bord2\\shad0\\c&H%06X&}%s\n",
				danmakuResX/2, danmakuResY-20-(d.lane%3)*laneHeight, d.Color, d.Text)
		}
	}
	return rb.String(), fb.String()
}

// pushOverlay 发一次 osd-overlay。
//
// 用命令**数组**形式(位置参数),避开 mpv_node 那一整套 cgo 结构体:
//
//	osd-overlay <id> <format> <data> <res_x> <res_y> <z> <hidden> <compute_bounds>
func pushOverlay(id int, data string, z int) {
	mpvMu.Lock()
	h := mpvH
	mpvMu.Unlock()
	if h == nil {
		return
	}
	args := []string{
		"osd-overlay",
		fmt.Sprint(id),
		"ass-events",
		data,
		fmt.Sprint(danmakuResX),
		fmt.Sprint(danmakuResY),
		fmt.Sprint(z),
		"no", // hidden
		"no", // compute_bounds
	}
	cs := make([]*C.char, len(args)+1)
	for i, a := range args {
		cs[i] = C.CString(a)
	}
	defer func() {
		for i := range args {
			C.free(unsafe.Pointer(cs[i]))
		}
	}()
	C.mpv_command(h, (**C.char)(unsafe.Pointer(&cs[0])))
	dmPushes.Add(1)
}

// danmakuStart 起弹幕渲染循环。
//
// ★ 循环频率跟着 time-pos 走:每次读到新的 time-pos 就重算并重发。
// uosc_danmaku 在这里会插 `vf append @danmaku:fps=fps=N` 把回调频率抬上去 ——
// 因为 time-pos 的更新频率跟着**视频帧率**,24fps 片源上弹幕会跟着卡。
// applyFpsFilter 插 `vf append @danmaku:fps=fps=N`。
//
// 这是 uosc_danmaku 的解法(`render.lua:196`):time-pos 的更新频率跟着**视频帧率**走,
// 低帧率片源上弹幕会跟着卡。插一个 fps 滤镜把解码后的帧率抬上去,
// time-pos 的更新频率也跟着上去。**代价是多一道滤镜的解码开销**。
func applyFpsFilter(n int) {
	mpvMu.Lock()
	h := mpvH
	mpvMu.Unlock()
	if h == nil {
		return
	}
	var spec string
	if n > 0 {
		spec = fmt.Sprintf("@danmaku:fps=fps=%d", n)
	}
	c1, c2, c3 := C.CString("vf"), C.CString("append"), C.CString(spec)
	defer C.free(unsafe.Pointer(c1))
	defer C.free(unsafe.Pointer(c2))
	defer C.free(unsafe.Pointer(c3))
	argv := []*C.char{c1, c2, c3, nil}
	if n > 0 {
		C.mpv_command(h, (**C.char)(unsafe.Pointer(&argv[0])))
		bus.Logf("info", "已插入 fps 滤镜 @danmaku:fps=fps=%d", n)
	}
}

func danmakuStart(hz int) {
	if !dmOn.CompareAndSwap(false, true) {
		return
	}
	dmStop = make(chan struct{})
	dmPushes.Store(0)
	dmTicks.Store(0)
	dmDistinct.Store(0)
	jitMu.Lock()
	jitDelta = jitDelta[:0]
	jitMu.Unlock()

	go func() {
		t := time.NewTicker(time.Second / time.Duration(hz))
		defer t.Stop()
		var last float64 = -1
		for {
			select {
			case <-dmStop:
				return
			case <-t.C:
			}
			pos := propF("time-pos")
			if pos != pos { // NaN
				continue
			}
			dmTicks.Add(1)
			if pos != last {
				dmDistinct.Add(1)
				if last >= 0 {
					jitMu.Lock()
					jitDelta = append(jitDelta, pos-last)
					jitMu.Unlock()
				}
				last = pos
			}
			dmLastPos.Store(pos)
			roll, fix := buildLayers(pos)
			// 双层:滚动层 z=0,顶/底层 z=1(照 uosc_danmaku 的 low/high 分层)
			pushOverlay(1, roll, 0)
			pushOverlay(2, fix, 1)
		}
	}()
	bus.Logf("info", "弹幕渲染已启动,重发频率 %d Hz", hz)
}

func danmakuStop() {
	if !dmOn.CompareAndSwap(true, false) {
		return
	}
	close(dmStop)
	pushOverlay(1, "", 0)
	pushOverlay(2, "", 1)
}

// danmakuStats 给判据用
func danmakuStats() map[string]any {
	jitMu.Lock()
	d := append([]float64(nil), jitDelta...)
	jitMu.Unlock()

	var mean, varc float64
	if len(d) > 0 {
		for _, x := range d {
			mean += x
		}
		mean /= float64(len(d))
		for _, x := range d {
			varc += (x - mean) * (x - mean)
		}
		varc /= float64(len(d))
	}
	pos, _ := dmLastPos.Load().(float64)
	return map[string]any{
		"pushes":     dmPushes.Load(),
		"ticks":      dmTicks.Load(),
		"distinct":   dmDistinct.Load(),
		"samples":    len(d),
		"meanDelta":  mean,
		"stdDelta":   sqrt(varc),
		"lastPos":    pos,
		"items":      len(dmItems),
		"renderCall": renderCalls.Load(),
	}
}

func sqrt(x float64) float64 {
	if x <= 0 {
		return 0
	}
	z := x
	for i := 0; i < 20; i++ {
		z = (z + x/z) / 2
	}
	return z
}
