package player

import (
	"os"
	"regexp"
	"strings"
	"testing"
)

// 属性名拼错在真机上看不出来:暂停按钮恒反、起播兜底永不放行,两个都不报错。
func TestStatusFields(t *testing.T) {
	props := map[string]string{
		"pause":            "yes",
		"paused-for-cache": "yes",
		"eof-reached":      "no",
		"hwdec-current":    "mediacodec",
	}
	nums := map[string]float64{"time-pos": 12.5, "duration": 1440, "frame-drop-count": 3}
	got := statusFields(
		func(k string) string { return props[k] },
		func(k string) float64 { return nums[k] },
		77,
	)
	want := map[string]any{
		"position": 12.5, "duration": 1440.0, "paused": true, "buffering": true,
		"eof": false, "dropped": 3.0, "hwdec": "mediacodec", "renderFps": int64(77),
	}
	if len(got) != len(want) {
		t.Fatalf("字段数不对:%d,要 %d(%v)", len(got), len(want), got)
	}
	for k, v := range want {
		if got[k] != v {
			t.Errorf("%s = %v(%T),要 %v(%T)", k, got[k], got[k], v, v)
		}
	}
}

// TestPumpStatusGateIsPlatformAbstract 钉住 pumpStatus 的那道闸。
//
// ☠ **这条只能靠读源码,没有别的办法。** 桌面构建里 `videoOutReady()` 的实现
// 就是 `rctxSet.Load()`,两者行为完全一致 —— 任何跑在本机的行为测试都照不到。
// 而在安卓上 `rctxSet` 永远是 false(那是通道 B 的标志,通道 A 不置位),
// 直接读它的后果是 player.status 一条都发不出去:有声音、没画面、一直「正在缓冲」。
func TestPumpStatusGateIsPlatformAbstract(t *testing.T) {
	b, err := os.ReadFile("player.go")
	if err != nil {
		t.Fatal(err)
	}
	body := regexp.MustCompile(`(?s)func pumpStatus\(\) \{.*?\n\}`).FindString(string(b))
	if body == "" {
		t.Fatal("没找到 pumpStatus 的函数体")
	}
	if strings.Contains(body, "rctxSet") {
		t.Error("pumpStatus 里出现了 rctxSet:安卓上它永远是 false,状态事件会整条发不出去")
	}
	if !strings.Contains(body, "videoOutReady()") {
		t.Error("pumpStatus 的闸不是 videoOutReady():起播闸和状态闸必须是同一个判据")
	}
}
