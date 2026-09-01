package plugin

import (
	"os"
	"path/filepath"
	"testing"
)

func regPlugin(id string, versions [][2]any, builtin bool) RegistryPlugin {
	p := RegistryPlugin{ID: id, Name: id, FromBuiltin: builtin}
	for _, v := range versions {
		p.Versions = append(p.Versions, RegistryVersion{
			Version: v[0].(string), APIVersion: v[1].(int),
		})
	}
	return p
}

// ★★ **不能信数组顺序**。本仓库在 GitHub Releases 上栽过同一个跟头
// (id/created/published 三个键的返回顺序全是反的),预览版渠道因此永远收不到更新。
func TestBestVersion_取最大而不是第一个或最后一个(t *testing.T) {
	p := regPlugin("a.b", [][2]any{{"1.10.0", 2}, {"1.9.0", 2}, {"1.2.0", 2}}, true)
	if got := p.BestVersion(2); got == nil || got.Version != "1.10.0" {
		t.Fatalf("1.10 > 1.9,不是字典序;实得 %#v", got)
	}
	r := regPlugin("a.b", [][2]any{{"0.1.0", 2}, {"2.0.0", 2}}, true)
	if got := r.BestVersion(2); got == nil || got.Version != "2.0.0" {
		t.Fatalf("%#v", got)
	}
}

// ★ 宿主装不了的高 apiVersion 要被跳过,回退到能装的那一版 ——
// 而不是让用户看到一个点了就报错的「最新版」。
func TestBestVersion_跳过装不了的版本(t *testing.T) {
	p := regPlugin("a.b", [][2]any{{"1.0.0", 2}, {"2.0.0", 3}}, true)
	if got := p.BestVersion(2); got == nil || got.Version != "1.0.0" {
		t.Fatalf("%#v", got)
	}
	if got := p.BestVersion(3); got == nil || got.Version != "2.0.0" {
		t.Fatalf("%#v", got)
	}
	all := regPlugin("a.b", [][2]any{{"2.0.0", 9}}, true)
	if all.BestVersion(2) != nil {
		t.Fatal("一个都装不了就该是 nil,不能硬塞一个")
	}
}

func TestCompareSemver_容忍缺段和垃圾(t *testing.T) {
	cases := []struct {
		a, b string
		want int
	}{
		{"1.10.0", "1.9.0", 1},
		{"1.0", "1.0.0", 0},        // 缺段按 0 补
		{"1.0.0-beta", "1.0.0", 0}, // 预发布后缀不参与
		{"x.y.z", "0.0.0", 0},      // 写歪的版本号不该炸
	}
	for _, c := range cases {
		if got := CompareSemver(c.a, c.b); got != c.want {
			t.Fatalf("compare(%s,%s)=%d 想要 %d", c.a, c.b, got, c.want)
		}
	}
}

// ★★ 第三方源不能靠重名覆盖官方插件 —— **那是最直接的一条投毒路径**。
func TestMergeSources_官方源赢重名而且和顺序无关(t *testing.T) {
	official := []RegistryPlugin{regPlugin("com.x.hello", [][2]any{{"1.0.0", 2}}, true)}
	evil := []RegistryPlugin{regPlugin("com.x.hello", [][2]any{{"9.9.9", 2}}, false)}

	for _, order := range [][][]RegistryPlugin{{evil, official}, {official, evil}} {
		merged := MergeSources(order)
		if len(merged) != 1 {
			t.Fatalf("应当去重成 1 条,实得 %d", len(merged))
		}
		if !merged[0].FromBuiltin || merged[0].Versions[0].Version != "1.0.0" {
			t.Fatalf("官方源必须赢:%#v", merged[0])
		}
	}
}

// ★★ 单条坏了跳过,但**跳了多少必须报出来**。
//
// 2026-07-23 实测:官方源还是 v1 schema(author 是对象),8 条全部被静默跳过,
// 前端拿到的是「0 个插件、0 个错误」—— 和「这个源本来就是空的」一模一样。
func TestParseRegistry_跳过数要带出去(t *testing.T) {
	p, err := ParseRegistry(`{"plugins":[
		{"id":"a.b","name":"好的","versions":[{"version":"1.0.0"}]},
		{"id":"c.d","name":"没版本","versions":[]},
		{"name":"没id","versions":[{"version":"1.0.0"}]},
		{"id":"e.f","name":"作者是对象","author":{"name":"x"},"versions":[{"version":"1.0.0"}]}
	]}`)
	if err != nil {
		t.Fatal(err)
	}
	if len(p.Plugins) != 1 {
		t.Fatalf("只有一条是好的,实得 %d", len(p.Plugins))
	}
	if p.Skipped != 3 {
		t.Fatalf("跳过数应当是 3,实得 %d —— 报不出来的话前端只会显示「没有找到插件」", p.Skipped)
	}
	if _, err := ParseRegistry(`{"nope":[]}`); err == nil {
		t.Fatal("缺 plugins 数组该报错")
	}
}

// ★★ **声明了 sha256 却对不上一律拒装**。没声明的只能放行(老源没这个字段)。
func TestVerifyPackage(t *testing.T) {
	data := []byte("hello")
	sum := SHA256Hex(data)
	if err := VerifyPackage(sum, data); err != nil {
		t.Fatal(err)
	}
	if err := VerifyPackage("  "+sum+"  ", data); err != nil {
		t.Fatal("前后空白不该影响")
	}
	if VerifyPackage("deadbeef", data) == nil {
		t.Fatal("校验和对不上却放行了 —— 包可能已被篡改")
	}
	if err := VerifyPackage("", data); err != nil {
		t.Fatal("没声明校验和只能放行")
	}
}

// ★★ 路径穿越三道防线。逃生舱的 URL 是插件自己拼的,这里是最后一道。
func TestResolveAsset_挡穿越(t *testing.T) {
	root := t.TempDir()
	inside := filepath.Join(root, "ok.html")
	if err := os.WriteFile(inside, []byte("<i>"), 0o644); err != nil {
		t.Fatal(err)
	}
	outside := filepath.Join(filepath.Dir(root), "secret.txt")
	if err := os.WriteFile(outside, []byte("x"), 0o644); err != nil {
		t.Fatal(err)
	}
	defer os.Remove(outside)

	if _, err := ResolveAsset(root, "ok.html"); err != nil {
		t.Fatalf("正常文件该读得到:%v", err)
	}
	if _, err := ResolveAsset(root, "/ok.html?v=1#x"); err != nil {
		t.Fatalf("query/fragment 要先切掉:%v", err)
	}
	for _, bad := range []string{
		"../secret.txt",
		"..\\secret.txt",
		"/etc/passwd",
		"C:/Windows/win.ini",
		"",
	} {
		if _, err := ResolveAsset(root, bad); err == nil {
			t.Fatalf("%q 穿越成功了", bad)
		}
	}

	/* ★★ 百分号编码的 `..` 必须判 **Forbidden 而不是 NotFound**。
	   这个区别不是吹毛求疵:只断言「报错了」的话这条测试是**空的** ——
	   不解码时 `<root>/%2e%2e/secret.txt` 这个路径本来就不存在,照样报错,
	   于是把 percentDecode 整个删掉测试仍然全绿(2026-09-02 注入实测)。
	   判 Forbidden 才真正说明「解码后被逐段检查拦下了」。 */
	if _, err := ResolveAsset(root, "%2e%2e/secret.txt"); err != ErrAssetForbidden {
		t.Fatalf("编码过的 .. 应当判非法(Forbidden),实得 %v —— 说明没先解码就检查", err)
	}
	if _, err := ResolveAsset(root, "没有这个.html"); err != ErrAssetNotFound {
		t.Fatalf("不存在的文件应当 NotFound,实得 %v", err)
	}
}

// ★ 认不出的扩展名一律 octet-stream:**不猜** —— 猜错成 text/html
// 会把任意文件变成可执行页面。
func TestContentTypeFor(t *testing.T) {
	if ContentTypeFor("a.html") != "text/html; charset=utf-8" {
		t.Fatal("html")
	}
	for _, p := range []string{"a.exe", "a", "a.unknownext"} {
		if ContentTypeFor(p) != "application/octet-stream" {
			t.Fatalf("%s 不该被猜成别的类型", p)
		}
	}
}
