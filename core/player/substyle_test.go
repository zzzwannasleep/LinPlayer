package player

import (
	"encoding/json"
	"testing"

	"linplayer/core/config"
)

// 描边 / 位置 / 大小的钳位。**越界不许静默夹到别的意思上**。
func Test字幕样式钳位(t *testing.T) {
	for _, c := range []struct{ in, want float64 }{{-1, 0}, {0, 0}, {4, 4}, {99, config.SubBorderMax}} {
		if got := clampSubBorder(c.in); got != c.want {
			t.Errorf("描边 %v 该钳到 %v,实得 %v", c.in, c.want, got)
		}
	}
	// ☠ 位置上限必须是 150 不是 100:100 是画面下沿,再往下才是黑边 ——
	// 「把字压进黑边、一点画面都不挡」是宽银幕片子上最常用的一档。
	if got := subPositionValue(150); got != "150" {
		t.Fatalf("pos 150 该原样通过,实得 %q —— 封在 100 的话那一档永远到不了", got)
	}
	if got := subPositionValue(999); got != "150" {
		t.Fatalf("pos 越界该钳到 150,实得 %q", got)
	}
}

// 老配置里**没有这几个键**,解出来是 0 / nil。
// 0 在这三项上分别是「字幕缩到看不见」「字幕顶到画面最上沿」「一点描边都没有」——
// 必须回哨兵当成「用 mpv 默认值」,不能当成用户的选择。
func Test字幕样式_老配置里的零值不是用户的选择(t *testing.T) {
	p := config.ParsePrefs([]byte(`{"sub_enabled":true}`))
	if p.SubScale != 0 || p.SubPos != -1 || p.SubBorderSize != -1 || p.SubScaleByWindow != nil {
		t.Fatalf("老配置该解成哨兵,实得 scale=%v pos=%v border=%v byWin=%v",
			p.SubScale, p.SubPos, p.SubBorderSize, p.SubScaleByWindow)
	}
	// 哨兵要**原样透给 UI**:翻成具体数字的话,面板一打开就把默认值
	// 当成用户的选择写回去了。
	// 判的是**序列化之后**的形状:UI 看到的是 JSON,不是 Go 结构体。
	// 直接看字段的话 omitempty 漏了都测不出来。
	raw, _ := json.Marshal(subStyleOf(p))
	var m map[string]any
	_ = json.Unmarshal(raw, &m)
	if m["scale"] != 0.0 || m["position"] != -1.0 || m["border_size"] != -1.0 {
		t.Fatalf("哨兵没原样透出去:%v", m)
	}
	if _, ok := m["scale_by_window"]; ok {
		t.Fatalf("没设过的 scale_by_window 不该出现在返回里:%v", m)
	}
}

// 用户真的设过的值要活下来(存进去 → 解出来 → 一字不差)。
func Test字幕样式_设过的值要活过一轮序列化(t *testing.T) {
	yes := true
	p := config.DefaultPrefs()
	p.SubScale, p.SubPos, p.SubBorderSize, p.SubBold, p.SubScaleByWindow = 1.8, 130, 4.5, true, &yes
	c := &config.AppConfig{}
	if err := c.SetPrefs(p); err != nil {
		t.Fatalf("存不进去:%v", err)
	}
	got := c.PrefsOf()
	if got.SubScale != 1.8 || got.SubPos != 130 || got.SubBorderSize != 4.5 || !got.SubBold {
		t.Fatalf("值没活下来:%+v", got)
	}
	if got.SubScaleByWindow == nil || !*got.SubScaleByWindow {
		t.Fatalf("scale_by_window 没活下来:%v", got.SubScaleByWindow)
	}
}
