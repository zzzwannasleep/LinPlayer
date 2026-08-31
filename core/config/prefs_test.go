package config

import (
	"encoding/json"
	"strings"
	"testing"
)

// ★★ 这个域最贵的一条:**默认值不是零值**。
//
// Rust 那边一半字段带 serde default,缺字段时拿到 true / 1.0 / "auto-safe" / 512MB。
// Go 的缺字段一律零值 —— 直接 unmarshal 进零值结构体的话,老用户升级之后
// **字幕默认不开了、倍速是 0 放不出来、进度条预览没了**,而配置文件看上去一点问题都没有。
//
// 这条测试拿一份**只有一个键**的 prefs 去解,把每一个「默认非零」的字段都点一遍。
func TestParsePrefs缺字段要拿到默认值不是零值(t *testing.T) {
	p := ParsePrefs(json.RawMessage(`{"skip_intro":true}`))

	if !p.SkipIntro {
		t.Fatal("给了的字段要读到")
	}
	for _, c := range []struct {
		name string
		ok   bool
		got  any
	}{
		{"sub_enabled", p.SubEnabled, p.SubEnabled},
		{"preview_thumbs", p.PreviewThumbs, p.PreviewThumbs},
		{"dolby_auto_sw", p.DolbyAutoSW, p.DolbyAutoSW},
		{"preload_enabled", p.PreloadEnabled, p.PreloadEnabled},
		{"update_auto_check", p.UpdateAutoCheck, p.UpdateAutoCheck},
		{"cross_server_writeback_progress", p.CrossServerWritebackProgress, p.CrossServerWritebackProgress},
		{"hwdec", p.Hwdec == "auto-safe", p.Hwdec},
		{"default_speed", p.DefaultSpeed == 1.0, p.DefaultSpeed},
		{"prefetch_threads", p.PrefetchThreads == 3, p.PrefetchThreads},
		{"prefetch_cache_bytes", p.PrefetchCacheBytes == 512*1024*1024, p.PrefetchCacheBytes},
		{"preload_head_mb", p.PreloadHeadMB == 32, p.PreloadHeadMB},
		{"detail_blur", p.DetailBlur == 40, p.DetailBlur},
		{"update_channel", p.UpdateChannel == "stable", p.UpdateChannel},
		{"cross_server_writeback_range", p.CrossServerWritebackRange == "all", p.CrossServerWritebackRange},
	} {
		if !c.ok {
			t.Errorf("%s 的默认值丢了,实得 %v —— 这是「升级之后字幕默认不开了」那类故障", c.name, c.got)
		}
	}
	// 默认**关**的那几个也要对:默认开了同样是故障(往别人服务器写数据)
	for _, c := range []struct {
		name string
		on   bool
	}{
		{"cross_server_resume", p.CrossServerResume},
		{"cross_server_writeback", p.CrossServerWriteback},
		{"skip_outro", p.SkipOutro},
	} {
		if c.on {
			t.Errorf("%s 默认必须是关的", c.name)
		}
	}
	if len(p.PrefetchServers) != 0 {
		t.Error("多线程加载默认一台都不开")
	}
}

// 完全没有 prefs 段(全新安装)时也要拿到同一份默认值。
func TestParsePrefs空段(t *testing.T) {
	if a, b := ParsePrefs(nil), ParsePrefs(json.RawMessage(`{}`)); a.SubEnabled != b.SubEnabled ||
		a.Hwdec != b.Hwdec || a.DefaultSpeed != b.DefaultSpeed {
		t.Fatal("「没有 prefs 段」和「空的 prefs 段」必须拿到同一份默认值")
	}
}

// 越界值**读出来的时候就要钳**,不能只在保存时钳。
//
// ★ 否则设置页拿到一个越界值,用户什么都没改点一下保存就被核层拒,
// 而他根本不知道哪儿不对(Rust 侧真发生过:旧配置里存着 1GB,
// 新校验是 16~32MB,用户连「打开某台服务器」都点不动)。
func TestParsePrefs越界值读出来就钳(t *testing.T) {
	p := ParsePrefs(json.RawMessage(`{
		"prefetch_cache_bytes": 1099511627776,
		"prefetch_threads": 64,
		"default_speed": 99,
		"preload_head_mb": 99999,
		"detail_blur": 500,
		"cross_server_writeback_range": "乱写的",
		"hwdec": "   ",
		"update_channel": "nightly"
	}`))
	if p.PrefetchCacheBytes != PrefetchCacheMax {
		t.Errorf("缓存上限没钳: %d", p.PrefetchCacheBytes)
	}
	if p.PrefetchThreads != 4 {
		t.Errorf("线程数没钳: %d", p.PrefetchThreads)
	}
	if p.DefaultSpeed != 1.0 {
		t.Errorf("越界倍速要回默认 1.0(0 倍速根本放不出来): %v", p.DefaultSpeed)
	}
	if p.PreloadHeadMB != PreloadHeadMBMax {
		t.Errorf("预热量没钳: %d", p.PreloadHeadMB)
	}
	if p.DetailBlur != 100 {
		t.Errorf("模糊强度没钳: %d", p.DetailBlur)
	}
	if p.CrossServerWritebackRange != "all" {
		t.Errorf("非法回传范围要回 all: %q", p.CrossServerWritebackRange)
	}
	if p.Hwdec != "auto-safe" {
		t.Errorf("空 hwdec 直接喂 mpv 会变成软解(用户:我没关硬解啊怎么这么卡): %q", p.Hwdec)
	}
	if p.UpdateChannel != "stable" {
		t.Errorf("未知渠道要回 stable: %q", p.UpdateChannel)
	}
}

// 偏好里**还没接的键**要原样留住。
func TestPrefs未接的键不丢(t *testing.T) {
	p := ParsePrefs(json.RawMessage(`{"skip_intro":true,"某个还没移植的开关":123}`))
	b, err := json.Marshal(p)
	if err != nil {
		t.Fatal(err)
	}
	if !strings.Contains(string(b), "某个还没移植的开关") {
		t.Fatalf("没接的键被抹掉了:%s", b)
	}
}

// 偏好解不动时回默认值,**不能让整个应用起不来**。
// (和账号不同:账号丢了不可恢复,所以那边是报错;偏好丢了用户重新勾一遍就是。)
func TestParsePrefs坏了回默认(t *testing.T) {
	p := ParsePrefs(json.RawMessage(`{这不是 JSON`))
	if !p.SubEnabled || p.Hwdec != "auto-safe" {
		t.Fatal("偏好坏了应回默认值")
	}
}

// 存进配置再读回来,值不变(往返一致)。
func TestPrefs往返一致(t *testing.T) {
	c := defaults()
	p := DefaultPrefs()
	p.SubEnabled = false
	p.DefaultSpeed = 1.5
	p.PrefetchServers = []string{"https://a"}
	p.VersionRegex = "4K"
	if err := c.SetPrefs(p); err != nil {
		t.Fatal(err)
	}
	got := c.PrefsOf()
	if got.SubEnabled || got.DefaultSpeed != 1.5 || got.VersionRegex != "4K" {
		t.Fatalf("往返之后值变了: %+v", got)
	}
	if !got.PrefetchEnabledFor("https://a") || got.PrefetchEnabledFor("https://b") {
		t.Fatal("按服务器的开关判错了")
	}
}

// 片头片尾是**两个**开关。一个字段喂两行会出现「点片头把片尾也翻了」。
func TestSkipIntroOutro是两个开关(t *testing.T) {
	p := ParsePrefs(json.RawMessage(`{"skip_intro":true}`))
	if !p.SkipIntro || p.SkipOutro {
		t.Fatalf("只开片头时片尾必须还是关的: intro=%v outro=%v", p.SkipIntro, p.SkipOutro)
	}
}
