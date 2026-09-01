package prefs

import "testing"

// ★ 真实源的形状:{name, icons:[{name,url,category?}]}。name + url + source 都要拿到。
func TestParseSource_真实形状(t *testing.T) {
	body := `{
		"name": "某图标库",
		"description": "",
		"icons": [
			{"name": "cattrv", "url": "https://x.example/a.png", "category": "default"},
			{"name": "冰块", "url": "https://x.example/b.png"}
		]
	}`
	e := parseSource(body)
	if len(e) != 2 {
		t.Fatalf("解出 %d 条", len(e))
	}
	if e[0].Name != "cattrv" || e[0].URL != "https://x.example/a.png" {
		t.Fatalf("%+v", e[0])
	}
	if e[0].Source != "某图标库" {
		t.Fatalf("source 要带上(UI 分组用),实得 %q", e[0].Source)
	}
}

// ★★ 空 url / 非 http 的条目必须丢掉。
//
// 留着的话前端拿去当图片地址是坏图;更糟的是被选中当服务器图标 ——
// 那就**存进配置里**了,以后每次打开都是坏图,而且看不出是哪一步错的。
func TestParseSource_丢掉空和非http(t *testing.T) {
	body := `{"name":"s","icons":[
		{"name":"a","url":""},
		{"name":"b","url":"ftp://x/y.png"},
		{"name":"c","url":"https://ok.example/c.png"}
	]}`
	e := parseSource(body)
	if len(e) != 1 || e[0].Name != "c" {
		t.Fatalf("只有 https 那条该留下,实得 %+v", e)
	}
}

// ★ 名字缺失回落成 url —— 空名字的格子搜不到、也看不出是什么。
func TestParseSource_没名字回落url(t *testing.T) {
	e := parseSource(`{"name":"s","icons":[{"name":"","url":"https://x.example/z.png"}]}`)
	if len(e) != 1 || e[0].Name != "https://x.example/z.png" {
		t.Fatalf("%+v", e)
	}
}

// ★★ 坏 JSON **不能 panic 也不能抛**:一个源挂了返回空就行,别拖垮整库。
func TestParseSource_坏JSON返回空不炸(t *testing.T) {
	for _, body := range []string{"not json at all", "", `{"name":"s"}`} {
		if got := parseSource(body); len(got) != 0 {
			t.Fatalf("%q 应当解出空,实得 %+v", body, got)
		}
	}
}

// ★★ 源地址**必须是注入进来的**,源码里不许硬编。
//
// 黄金实现把四条真实地址写死在 icon_library.rs 里 —— 那违反仓库红线
// (域名不许进提交)。这条测试钉住:没注入时就是空,不会有谁「顺手加回来」。
func TestIconSources_默认为空且只收http(t *testing.T) {
	old := iconSources
	defer func() { iconSources = old }()

	iconSources = ""
	if got := IconSources(); len(got) != 0 {
		t.Fatalf("没注入时应当为空,实得 %v —— 源地址不许硬编进仓库", got)
	}
	iconSources = " https://a.example/x.json , 不是地址 ,https://b.example/y.json "
	got := IconSources()
	if len(got) != 2 || got[0] != "https://a.example/x.json" || got[1] != "https://b.example/y.json" {
		t.Fatalf("解出 %v", got)
	}
}
