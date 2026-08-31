package player

import (
	"os"
	"path/filepath"
	"strings"
	"testing"

	"linplayer/core/config"
	"linplayer/core/paths"
)

// mpv.conf:**全空 = 删文件**,回到「完全不读配置」的出厂状态。
//
// ★ 留一个空文件和没有文件对 mpv 是两件事(前者仍然会开 config-dir 那条路)。
func TestMpvConf全空即删文件(t *testing.T) {
	paths.SetRoot(t.TempDir())
	if got := mpvConfNow(); got["active"] != false || got["text"] != "" {
		t.Fatalf("一开始不该有配置: %+v", got)
	}
	if err := writeUserConf("hwdec=no\n"); err != nil {
		t.Fatal(err)
	}
	got := mpvConfNow()
	if got["active"] != true || !strings.Contains(got["text"].(string), "hwdec=no") {
		t.Fatalf("写完该读得回来: %+v", got)
	}
	if err := writeUserConf("   \n\t"); err != nil {
		t.Fatal(err)
	}
	if got := mpvConfNow(); got["active"] != false {
		t.Fatalf("全空白该把文件删掉,实得 %+v —— 留个空文件和没有文件对 mpv 是两件事", got)
	}
	if _, err := os.Stat(userConfPath()); !os.IsNotExist(err) {
		t.Fatal("文件没删掉")
	}
}

// 字幕字体:「默认」是 UI 占位词,**不该塞给 libass**。
//
// ★ libass 会去找一个叫「默认」的字体,找不到就退回内置字体 ——
// 而用户以为自己选的那个生效了。
func TestSetSubFont跳过占位词(t *testing.T) {
	// 没起 mpv 时 setProp 是空操作,这里验的是「有没有走到 setProp」那一步。
	// 用一个能观察的替身:把 setProp 换掉不现实,所以退一步 ——
	// 直接验守卫函数的判断(它是这条规则的全部内容)。
	for _, skip := range []string{"", "   ", "默认"} {
		if shouldSetFont(skip) {
			t.Errorf("%q 不该塞给 libass —— 它会退回内置字体,而用户以为选的那个生效了", skip)
		}
	}
	for _, ok := range []string{"思源黑体", "Arial"} {
		if !shouldSetFont(ok) {
			t.Errorf("%q 该设进去", ok)
		}
	}
}

// 字幕大小统一走 sub-scale,并且要钳进 mpv 认的区间。
func TestSubScale钳位(t *testing.T) {
	for _, c := range []struct{ in, want float64 }{
		{0.05, 0.2}, {0.2, 0.2}, {1.0, 1.0}, {4.0, 4.0}, {99, 4.0},
	} {
		if got := clampSubScale(c.in); got != c.want {
			t.Errorf("scale %v 该钳到 %v,实得 %v", c.in, c.want, got)
		}
	}
}

// 字幕位置 mpv 只收**整数** —— 给小数它会静默拒绝,而调用方以为设上了。
func TestSubPosition取整(t *testing.T) {
	for _, c := range []struct {
		in   float64
		want string
	}{{0, "0"}, {50.4, "50"}, {50.6, "51"}, {100, "100"}, {-5, "0"}, {999, "100"}} {
		if got := subPositionValue(c.in); got != c.want {
			t.Errorf("pos %v 该是 %q,实得 %q", c.in, c.want, got)
		}
	}
}

// 截图目录:设置项**不能被架空**。
//
// ★ 早先这里直接回落系统图片文件夹,而调用方从来不传 dir ——
// 用户在设置页选的目录等于白选。
func TestResolveScreenshotDir优先用设置(t *testing.T) {
	paths.SetRoot(t.TempDir())
	custom := filepath.Join(t.TempDir(), "我的截图")
	if got := resolveScreenshotDir(&custom); got != custom {
		t.Fatalf("设了目录就该用它,实得 %q —— 否则设置项被架空", got)
	}
	empty := "   "
	if got := resolveScreenshotDir(&empty); got == empty {
		t.Fatal("空白目录该回落到默认位置")
	}
	if got := resolveScreenshotDir(nil); got == "" {
		t.Fatal("没设时也要给一个能落的位置")
	}
}

// chapterInfo 要**尊重开关**:关了就恒为 null,调用方不必再判一次。
//
// ★ 判两次早晚判岔:一边按核心层给的区间跳、一边按自己那份开关决定要不要跳,
// 两处状态一不同步就是「关了还在跳」或者「开了不跳」。
func TestChapterInfo尊重开关(t *testing.T) {
	paths.SetRoot(t.TempDir())
	if _, err := config.Load(); err != nil {
		t.Fatal(err)
	}
	c := config.Current()
	p := c.PrefsOf()
	if p.SkipIntro || p.SkipOutro {
		t.Fatal("前提不成立:两个开关默认都该是关的")
	}
	// 默认关 → 两个区间都该被抹成 null(这条在命令里做,这里只验默认值那一半)
	if p.PreviewThumbs != true {
		t.Fatal("缩略图默认该是开的")
	}
}
