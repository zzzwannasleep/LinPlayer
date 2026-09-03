package account

import (
	"context"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

// ★★ server_id 是个 URL,里面有 `:` 和 `/` —— Windows 上直接建不了这个文件。
// 不净化的表现是「图标缓存永远写不进去」,而且写失败被吞掉,每次都重新下。
func TestIconKey_能当文件名(t *testing.T) {
	k := iconKey("https://smart.example.com:8096/emby")
	if strings.ContainsAny(k, `:/\`) {
		t.Fatalf("净化后还有非法字符: %q", k)
	}
	if k != "https___smart_example_com_8096_emby" {
		t.Fatalf("%q", k)
	}
	// ★ 两台服务器**绝不能共用一个缓存槽**,否则 A 的图标会显示成 B 的
	if iconKey("https://a.example") == iconKey("https://b.example") {
		t.Fatal("不同服务器撞了同一个缓存槽")
	}
}

// ★★ MIME 按**内容**嗅探,不看扩展名也不看 Content-Type。
//
// Emby 的 /Users/x/Images/Primary 不带扩展名,而有些反代会把 Content-Type
// 抹成 application/octet-stream —— 那样拼出来的 data URI 浏览器不认,
// 图标变成碎图标,**不报错,只是不显示**。
func TestSniffMime(t *testing.T) {
	cases := []struct {
		b    []byte
		want string
	}{
		{[]byte{0x89, 'P', 'N', 'G', 0, 0}, "image/png"},
		{[]byte{0xFF, 0xD8, 0xFF, 0xE0}, "image/jpeg"},
		{[]byte("GIF89a"), "image/gif"},
		{[]byte("RIFF\x00\x00\x00\x00WEBPVP8 "), "image/webp"},
		{[]byte(`<svg xmlns="x">`), "image/svg+xml"},
	}
	for _, c := range cases {
		if got := sniffMime(c.b); got != c.want {
			t.Fatalf("%q → %q,想要 %q", c.b[:4], got, c.want)
		}
	}
}

func TestToDataURI_前缀(t *testing.T) {
	u := toDataURI([]byte{0x89, 'P', 'N', 'G', 1, 2, 3})
	if !strings.HasPrefix(u, "data:image/png;base64,") {
		t.Fatalf("拼错前缀浏览器就不认: %s", u)
	}
}

// ★★ **空文件必须报错**,不能悄悄成功。
//
// 返回一个 `data:image/png;base64,` 空串的话,UI 显示成碎图标 —— 查都没处查,
// 而且用户会以为是自己那张图有问题。
func TestIconSetFromFile_空文件与不存在都要报错(t *testing.T) {
	id := "https://icon-test.example"
	if _, err := IconSetFromFile(id, "definitely/not/here.png"); err == nil {
		t.Fatal("文件不存在应当报错")
	}
	dir := t.TempDir()
	empty := filepath.Join(dir, "empty.png")
	if err := os.WriteFile(empty, nil, 0o644); err != nil {
		t.Fatal(err)
	}
	if _, err := IconSetFromFile(id, empty); err == nil {
		t.Fatal("空文件应当报错,不能返回一个空的 data URI")
	}
}

// 存进去要能读回来,清掉要真的没了 —— 否则每次开服务器页都重下一遍。
func TestIcon_落盘往返(t *testing.T) {
	dir := t.TempDir()
	src := filepath.Join(dir, "pic.png")
	if err := os.WriteFile(src, []byte{0x89, 'P', 'N', 'G', 9, 9}, 0o644); err != nil {
		t.Fatal(err)
	}
	id := "https://icon-roundtrip.example"
	uri, err := IconSetFromFile(id, src)
	if err != nil {
		t.Fatal(err)
	}
	if !strings.HasPrefix(uri, "data:image/png;base64,") {
		t.Fatalf("%s", uri)
	}
	if _, err := os.Stat(iconPath(id)); err != nil {
		t.Fatalf("没落盘: %v", err)
	}
	IconClear(id)
	if _, err := os.Stat(iconPath(id)); err == nil {
		t.Fatal("清了却还在")
	}
}

// ★★ 用户 2026-09-03:「获取服务器图标,一个是官方 API,一个是从用户头像获取,
// 这两个都是 Emby 服常见的服图标获取方式」。
//
// 核心层原本只试**一条**地址(登录那一刻算出来的那条:有头像就是头像,
// 没头像才退 touchicon)。问题是那条地址会**后来失效** ——
// 用户把头像删了 / 换了,icon_url 还指着旧的头像地址,一个 404 之后就再没有图标了,
// 而「官方那条」明明还好好的。
//
// 判据:第一条 404 时必须接着试后面几条,而不是直接放弃。
func TestIconGetAny_第一条挂了要接着试后面的(t *testing.T) {
	// ★ 用完就清 —— 图标缓存落在真的数据根下（paths.Root），
	//   不清的话第二次跑会**直接命中缓存**，一次 HTTP 都不发 ——
	//   那时候 hit 是空的，断言会失败得莫名其妙。
	defer IconClear("https://icon-fallback.example")

	var hit []string
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		hit = append(hit, r.URL.Path)
		if r.URL.Path == "/web/touchicon.png" {
			w.Header().Set("Content-Type", "image/png")
			_, _ = w.Write([]byte("\x89PNG\r\n\x1a\nfake"))
			return
		}
		w.WriteHeader(http.StatusNotFound)
	}))
	defer srv.Close()

	uri, err := IconGetAny(context.Background(), "https://icon-fallback.example",
		srv.URL+"/Users/u1/Images/Primary", // 头像:已经被删了 → 404
		srv.URL+"/web/touchicon.png",       // 官方图标:还在
	)
	if err != nil {
		t.Fatalf("两条里有一条是通的,不该整体失败: %v (试过 %v)", err, hit)
	}
	if !strings.HasPrefix(uri, "data:image/png;base64,") {
		t.Fatalf("应当是 PNG 的 data URI,实得 %.40q", uri)
	}
	if len(hit) != 2 {
		t.Fatalf("应当依次试两条,实际试了 %v", hit)
	}
}

// ★ 全都不通时要如实报错,不能返回一个空的 data URI ——
// 那会让 UI 画出一个碎图标,而且查都没处查。
func TestIconGetAny_全不通要报错(t *testing.T) {
	defer IconClear("https://icon-none.example")
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.WriteHeader(http.StatusNotFound)
	}))
	defer srv.Close()
	if _, err := IconGetAny(context.Background(), "https://icon-none.example",
		srv.URL+"/a.png", srv.URL+"/b.png"); err == nil {
		t.Fatal("全不通时必须报错")
	}
}
