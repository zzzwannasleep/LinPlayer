package webdav

import (
	"context"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"

	"linplayer/core/source"
)

func str(s string) *string { return &s }

// apacheXML Apache mod_dav 的真实形状:大写 `D:` 前缀、href 是绝对路径、目录带尾斜杠。
const apacheXML = `<?xml version="1.0" encoding="utf-8"?>
<D:multistatus xmlns:D="DAV:">
<D:response><D:href>/dav/</D:href><D:propstat><D:prop>
<D:displayname>dav</D:displayname><D:resourcetype><D:collection/></D:resourcetype>
</D:prop></D:propstat></D:response>
<D:response><D:href>/dav/%E5%89%A7%E9%9B%86/</D:href><D:propstat><D:prop>
<D:displayname>剧集</D:displayname><D:resourcetype><D:collection/></D:resourcetype>
</D:prop></D:propstat></D:response>
<D:response><D:href>/dav/movie.mkv</D:href><D:propstat><D:prop>
<D:displayname>movie.mkv</D:displayname><D:getcontentlength>12345</D:getcontentlength>
<D:resourcetype/></D:prop></D:propstat></D:response>
</D:multistatus>`

// nextcloudXML 小写 `d:` 前缀 + 无 displayname(要从 href 反推名字)。
const nextcloudXML = `<?xml version="1.0"?>
<d:multistatus xmlns:d="DAV:">
<d:response><d:href>/remote.php/dav/files/u/</d:href><d:propstat><d:prop>
<d:resourcetype><d:collection/></d:resourcetype></d:prop></d:propstat></d:response>
<d:response><d:href>/remote.php/dav/files/u/a%20b.mp4</d:href><d:propstat><d:prop>
<d:getcontentlength>7</d:getcontentlength><d:resourcetype/></d:prop></d:propstat></d:response>
</d:multistatus>`

// defaultNsXML 服务端把 DAV: 设成默认命名空间,**一个前缀都不带**。
const defaultNsXML = `<?xml version="1.0"?>
<multistatus xmlns="DAV:">
<response><href>/</href><propstat><prop><resourcetype><collection/></resourcetype></prop></propstat></response>
<response><href>/x.mkv</href><propstat><prop><getcontentlength>3</getcontentlength><resourcetype/></prop></propstat></response>
</multistatus>`

// ★★ 命名空间前缀是各家自选的。按 `d:response` 这种字面量匹配的话,
// 换一家服务端就一条都解不出来 —— 而表现是「连上了,目录是空的」。
func TestParse_三种命名空间写法都要认(t *testing.T) {
	for _, c := range []struct {
		name, xml, base string
		want            int
	}{
		{"Apache 大写 D:", apacheXML, "/dav/", 2},
		{"Nextcloud 小写 d:", nextcloudXML, "/remote.php/dav/files/u/", 1},
		{"默认命名空间无前缀", defaultNsXML, "/", 1},
	} {
		got, err := parse(c.xml, c.base)
		if err != nil {
			t.Fatalf("%s: %v", c.name, err)
		}
		if len(got) != c.want {
			t.Fatalf("%s: 解出 %d 条,想要 %d —— 表现是「连上了,目录是空的」", c.name, len(got), c.want)
		}
	}
}

// ★★ Depth:1 的响应**第一条永远是被请求的目录自己**。
//
// 不剔掉的话点进任何目录都会看到一个指向自己的条目,一路点下去无限套娃。
func TestParse_要剔掉指向自己的那条(t *testing.T) {
	got, err := parse(apacheXML, "/dav/")
	if err != nil {
		t.Fatal(err)
	}
	for _, e := range got {
		if strings.TrimRight(e.ID, "/") == "/dav" {
			t.Fatal("目录自己那条没剔掉 —— 点进去会无限套娃")
		}
	}
}

// ★ href 是百分号编码的,要解回真实路径才能当下一次 PROPFIND 的入参。
func TestParse_href要解码(t *testing.T) {
	got, _ := parse(apacheXML, "/dav/")
	var found bool
	for _, e := range got {
		if e.Name == "剧集" {
			found = true
			if strings.Contains(e.ID, "%E5") {
				t.Fatalf("id 还是编码态: %q —— 下一次 PROPFIND 会二次编码,必 404", e.ID)
			}
			if !e.IsDir {
				t.Fatal("目录没判成目录")
			}
		}
	}
	if !found {
		t.Fatal("中文目录没解出来")
	}
}

// ★ 没有 displayname 时要从 href 反推名字,而且是**解码后**的。
func TestParse_没有displayname就从href反推(t *testing.T) {
	got, _ := parse(nextcloudXML, "/remote.php/dav/files/u/")
	if len(got) != 1 {
		t.Fatalf("应当一条,实得 %d", len(got))
	}
	if got[0].Name != "a b.mp4" {
		t.Fatalf("名字不对: %q(%%20 要解成空格)", got[0].Name)
	}
	if !got[0].IsVideo || got[0].Size == nil || *got[0].Size != 7 {
		t.Fatalf("字段不对: %+v", got[0])
	}
}

// ★ 判目录看的是 <collection/> 在不在 <resourcetype> 里,不是看 href 尾斜杠。
func TestParse_按collection判目录(t *testing.T) {
	got, _ := parse(apacheXML, "/dav/")
	for _, e := range got {
		if e.Name == "movie.mkv" && e.IsDir {
			t.Fatal("文件被判成了目录")
		}
		if e.Name == "剧集" && !e.IsDir {
			t.Fatal("目录被判成了文件")
		}
	}
}

// ★★ 这条是本文件最要紧的一条:**href 双前缀**。
//
// entry.ID 是服务端绝对路径(已经含了 base_url 里那截前缀)。拿它去接 base_url
// 会拼出 `/dav/dav/剧集` —— 根目录能列、点进任何子目录必 404,
// 而且**只在「base_url 带路径」的服务端上犯**(Nextcloud 全中)。
func TestURLFor_不许拼出双前缀(t *testing.T) {
	base := "https://nas.example/remote.php/dav/files/u"
	got := urlFor(base, "/remote.php/dav/files/u/剧集/")
	want := "https://nas.example/remote.php/dav/files/u/%E5%89%A7%E9%9B%86/"
	if got != want {
		t.Fatalf("拼成了 %q\n想要   %q\n(双前缀的表现:根目录能列,点进任何子目录必 404)", got, want)
	}
	if strings.Count(got, "/remote.php") != 1 {
		t.Fatalf("前缀出现了 %d 次: %s", strings.Count(got, "/remote.php"), got)
	}
}

// ★ 逐段编码,**斜杠不能编码**。整串 encode 会把 `/` 变成 %2F,
// 服务端看到的是一个名字里带斜杠的文件,必 404。
func TestURLFor_斜杠不许编码(t *testing.T) {
	got := urlFor("https://h", "/a b/c d.mkv")
	if strings.Contains(got, "%2F") || strings.Contains(got, "%2f") {
		t.Fatalf("斜杠被编码了: %s", got)
	}
	if !strings.Contains(got, "a%20b") {
		t.Fatalf("空格没编码: %s", got)
	}
}

func TestSplitBase(t *testing.T) {
	cases := map[string][2]string{
		"https://h/remote.php/dav/files/u/": {"https://h", "/remote.php/dav/files/u"},
		"https://h:5006":                    {"https://h:5006", ""},
		"http://h/dav":                      {"http://h", "/dav"},
	}
	for in, want := range cases {
		o, r := splitBase(in)
		if o != want[0] || r != want[1] {
			t.Fatalf("splitBase(%q) = (%q,%q),想要 (%q,%q)", in, o, r, want[0], want[1])
		}
	}
}

// ★★ 取流那一路**必须自己带 Authorization**:WebDAV 没有会话令牌。
// 漏了的表现是「目录列得出来,一点播放就 401」。
func TestResolvePlay_必须带Authorization(t *testing.T) {
	s := &source.Server{BaseURL: "https://h/dav", Username: str("u"), Password: str("p")}
	e := &source.Entry{ID: "/dav/a.mkv", Name: "a.mkv"}
	got, err := New().ResolvePlay(context.Background(), nil, s, e, "")
	if err != nil {
		t.Fatal(err)
	}
	if got.HTTPHeaders["Authorization"] == "" {
		t.Fatal("没带 Authorization —— 目录列得出来,一点播放就 401")
	}
	if !strings.HasPrefix(got.HTTPHeaders["Authorization"], "Basic ") {
		t.Fatalf("不是 Basic: %q", got.HTTPHeaders["Authorization"])
	}
	if got.URL != "https://h/dav/a.mkv" {
		t.Fatalf("URL 不对: %q", got.URL)
	}
}

// ★ 匿名共享(有的 NAS 开放只读匿名)不该硬塞一个空的 Basic 头。
func TestResolvePlay_匿名不带头(t *testing.T) {
	s := &source.Server{BaseURL: "https://h/dav"}
	e := &source.Entry{ID: "/dav/a.mkv", Name: "a.mkv"}
	got, _ := New().ResolvePlay(context.Background(), nil, s, e, "")
	if _, ok := got.HTTPHeaders["Authorization"]; ok {
		t.Fatal("匿名源硬塞了一个空的 Basic 头")
	}
}

// ★ 401/403 要判成**鉴权失败**(UI 据此引导重登),不是一句「返回 401」。
func TestPropfind_401判成鉴权失败(t *testing.T) {
	up := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.WriteHeader(http.StatusUnauthorized)
	}))
	defer up.Close()

	s := &source.Server{BaseURL: up.URL, Username: str("u"), Password: str("bad")}
	_, err := New().ListDir(context.Background(), up.Client(), s, "")
	if err == nil {
		t.Fatal("401 却成功了")
	}
	if !source.IsAuthErr(err) {
		t.Fatalf("401 没判成鉴权失败: %v —— UI 就不会引导重登", err)
	}
}

// ★ 405 = 把普通 http 服务当 WebDAV 填了。要给出这句提示,别只报个码。
func TestPropfind_405要提示不是WebDAV(t *testing.T) {
	up := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.WriteHeader(http.StatusMethodNotAllowed)
	}))
	defer up.Close()

	s := &source.Server{BaseURL: up.URL}
	_, err := New().ListDir(context.Background(), up.Client(), s, "")
	if err == nil || !strings.Contains(err.Error(), "PROPFIND") {
		t.Fatalf("405 的提示看不出是填错了地址: %v", err)
	}
}

// ★ 端到端:真起一台会回 207 的服务器,确认方法名 / Depth 头 / body 都对。
func TestListDir_端到端(t *testing.T) {
	var gotMethod, gotDepth, gotPath string
	up := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		gotMethod, gotDepth, gotPath = r.Method, r.Header.Get("Depth"), r.URL.Path
		w.Header().Set("Content-Type", "application/xml")
		w.WriteHeader(http.StatusMultiStatus)
		_, _ = w.Write([]byte(strings.ReplaceAll(apacheXML, "/dav/", "/dav/")))
	}))
	defer up.Close()

	s := &source.Server{BaseURL: up.URL + "/dav"}
	got, err := New().ListDir(context.Background(), up.Client(), s, "")
	if err != nil {
		t.Fatal(err)
	}
	if gotMethod != "PROPFIND" {
		t.Fatalf("方法名不对: %q", gotMethod)
	}
	if gotDepth != "1" {
		t.Fatalf("Depth 头不对: %q —— 不给 1 的话有的服务端会返回整棵树", gotDepth)
	}
	if gotPath != "/dav" {
		t.Fatalf("请求路径不对: %q", gotPath)
	}
	if len(got) != 2 {
		t.Fatalf("解出 %d 条,想要 2", len(got))
	}
	// 目录排最前
	if !got[0].IsDir || got[0].Name != "剧集" {
		t.Fatalf("排序不对: %+v", got)
	}
}
