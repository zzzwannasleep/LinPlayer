package account

import (
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
