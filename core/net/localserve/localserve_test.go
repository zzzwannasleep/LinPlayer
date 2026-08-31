package localserve

import (
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"testing"

	"linplayer/core/imgcache"
	"linplayer/core/paths"
)

// 一张最小的合法 PNG 头 —— 只要魔数对,Sniff 就该判成 image/png。
var pngBytes = append([]byte{0x89, 'P', 'N', 'G', '\r', '\n', 0x1a, '\n'}, make([]byte, 64)...)

// newTestServer 起一个真的 localserve + 一个假上游,并把缓存指到临时目录。
//
// ★ 缓存是**进程级**的(磁盘目录 + 内存表),不隔离的话测试之间会互相喂缓存,
// 表现是「单跑绿、一起跑红」或者反过来 —— 比失败更糟的那种。
func newTestServer(t *testing.T, upstream http.HandlerFunc) (*Server, *httptest.Server) {
	t.Helper()
	paths.SetRoot(t.TempDir())
	imgcache.Clear()
	t.Cleanup(imgcache.Clear)

	up := httptest.NewServer(upstream)
	t.Cleanup(up.Close)

	s, err := Start()
	if err != nil {
		t.Fatalf("起服务失败: %v", err)
	}
	t.Cleanup(func() { _ = s.Close() })
	return s, up
}

func get(t *testing.T, s *Server, path string, withToken bool) *http.Response {
	t.Helper()
	req, err := http.NewRequest(http.MethodGet, s.BaseURL()+path, nil)
	if err != nil {
		t.Fatal(err)
	}
	if withToken {
		req.Header.Set("X-LP-Token", s.Token)
	}
	resp, err := http.DefaultClient.Do(req)
	if err != nil {
		t.Fatalf("请求失败: %v", err)
	}
	t.Cleanup(func() { _ = resp.Body.Close() })
	return resp
}

// B1.7 判据一:带 token 能取图**并落缓存**。
//
// 「落缓存」不是锦上添花:没有它,每翻一次库就把服务器再打一遍
// (用户 2026-07-15 原话:「每次都要重新加载,服务器压力很大」)。
// 所以这条断言的是**第二次请求不再回源**,而不只是「第一次拿到了字节」。
func TestImgFetchesAndCaches(t *testing.T) {
	hits := 0
	s, up := newTestServer(t, func(w http.ResponseWriter, r *http.Request) {
		hits++
		w.Header().Set("Content-Type", "application/octet-stream") // 反代抹掉真类型是常态
		_, _ = w.Write(pngBytes)
	})
	s.Allow(up.URL, http.Header{"X-Emby-Token": {"tok"}})

	q := "/img?src=" + up.URL + "/Items/x/Images/Primary&h=480"

	r1 := get(t, s, q, true)
	if r1.StatusCode != 200 {
		t.Fatalf("第一次取图应该 200,实得 %d", r1.StatusCode)
	}
	if got := r1.Header.Get("X-LP-Cache"); got != "miss" {
		t.Fatalf("第一次应该是回源(miss),实得 %q", got)
	}
	// ★ 按魔数嗅,不信上游那个 octet-stream
	if ct := r1.Header.Get("Content-Type"); ct != "image/png" {
		t.Fatalf("Content-Type 必须按魔数嗅成 image/png,实得 %q —— 信了上游的话图不显示且不报错", ct)
	}

	r2 := get(t, s, q, true)
	if got := r2.Header.Get("X-LP-Cache"); got != "hit" {
		t.Fatalf("第二次必须命中缓存,实得 %q", got)
	}
	if hits != 1 {
		t.Fatalf("上游只该被打一次,实得 %d 次 —— 没落缓存等于每翻一次库就把服务器再打一遍", hits)
	}

	// 落到磁盘了吗(内存层清掉之后还能供图 = 真落盘了)
	imgcache.MemClear()
	ents, _ := os.ReadDir(paths.ImageCache())
	if len(ents) == 0 {
		t.Fatalf("磁盘缓存目录 %s 是空的 —— 只落内存的话重启就全没了", paths.ImageCache())
	}
	r3 := get(t, s, q, true)
	if got := r3.Header.Get("X-LP-Cache"); got != "hit" || hits != 1 {
		t.Fatalf("清掉内存层后应由磁盘层供图,实得 X-LP-Cache=%q 上游打了 %d 次", got, hits)
	}
}

// B1.7 判据二:不带 token 401。
func TestImgWithoutTokenIs401(t *testing.T) {
	s, up := newTestServer(t, func(w http.ResponseWriter, r *http.Request) {
		t.Error("没 token 的请求不该到达上游 —— 那说明鉴权是摆设")
	})
	s.Allow(up.URL, nil)

	r := get(t, s, "/img?src="+up.URL+"/a.jpg", false)
	if r.StatusCode != http.StatusUnauthorized {
		t.Fatalf("不带 token 应该 401,实得 %d", r.StatusCode)
	}

	// 带一个错的也不行
	req, _ := http.NewRequest(http.MethodGet, s.BaseURL()+"/img?src="+up.URL+"/a.jpg", nil)
	req.Header.Set("X-LP-Token", "不是这个")
	resp, err := http.DefaultClient.Do(req)
	if err != nil {
		t.Fatal(err)
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusUnauthorized {
		t.Fatalf("token 不对也应该 401,实得 %d", resp.StatusCode)
	}
}

// B1.7 判据三:白名单外的 src 404。
//
// ★ 这条是**安全判据**,不是功能判据:没有它,/img 就是一个开放的 SSRF 代理 ——
// 任何能打到本机回环的东西都能借我们的进程去打内网。
func TestImgRejectsSrcOutsideAllowlist(t *testing.T) {
	reached := false
	s, up := newTestServer(t, func(w http.ResponseWriter, r *http.Request) {
		reached = true
		_, _ = w.Write(pngBytes)
	})
	// 故意**不**调 Allow

	for _, bad := range []string{
		up.URL + "/a.jpg",             // 没登记过的 http 源
		"http://127.0.0.1:1/internal", // 内网直连
		"file:///C:/Windows/win.ini",  // 非 http scheme
		"gopher://127.0.0.1:11211/_x", // 经典 SSRF 跳板
		"/Items/x/Images/Primary",     // 相对路径(没有 host)
		"",                            // 空
	} {
		r := get(t, s, "/img?src="+bad, true)
		if r.StatusCode != http.StatusNotFound {
			t.Fatalf("src=%q 不在白名单,应该 404,实得 %d", bad, r.StatusCode)
		}
	}
	if reached {
		t.Fatal("白名单外的 src 竟然打到了上游 —— 这就是一个开放的 SSRF 代理")
	}

	// 登记之后才放行
	s.Allow(up.URL, nil)
	if r := get(t, s, "/img?src="+up.URL+"/a.jpg", true); r.StatusCode != 200 {
		t.Fatalf("登记后应该放行,实得 %d", r.StatusCode)
	}
	// ★ 撤销之后必须立刻失效 —— 删了账号但白名单还留着,那个 origin 就成了永久出口
	s.Revoke(up.URL)
	if r := get(t, s, "/img?src="+up.URL+"/a.jpg", true); r.StatusCode != http.StatusNotFound {
		t.Fatalf("撤销后应该 404,实得 %d", r.StatusCode)
	}
}

// 白名单按 origin 存,不按完整 URL —— 按 URL 存等于没有白名单。
// 同一台服务器的另一条路径要放行,另一台服务器不能因为路径像就放行。
func TestAllowlistIsPerOrigin(t *testing.T) {
	s, up := newTestServer(t, func(w http.ResponseWriter, r *http.Request) {
		_, _ = w.Write(pngBytes)
	})
	s.Allow(up.URL+"/Items/1/Images/Primary", nil) // 登记时给了完整 URL

	if r := get(t, s, "/img?src="+up.URL+"/Items/2/Images/Backdrop", true); r.StatusCode != 200 {
		t.Fatalf("同一 origin 的另一条路径应该放行,实得 %d —— 按完整 URL 存等于没有白名单", r.StatusCode)
	}
	if r := get(t, s, "/img?src=http://192.0.2.1/Items/1/Images/Primary", true); r.StatusCode != http.StatusNotFound {
		t.Fatalf("另一台服务器不能因为路径像就放行,实得 %d", r.StatusCode)
	}
}

// 尺寸参数只放行纯数字,并且拼成上游认得的键。
func TestWithSizeOnlyAcceptsDigits(t *testing.T) {
	u, err := withSize("http://h/img", "480", "270")
	if err != nil {
		t.Fatal(err)
	}
	if !strings.Contains(u, "maxWidth=480") || !strings.Contains(u, "maxHeight=270") {
		t.Fatalf("w/h 要拼成 maxWidth/maxHeight,实得 %s", u)
	}
	u, _ = withSize("http://h/img", "480&evil=1", "abc")
	if strings.Contains(u, "evil") || strings.Contains(u, "abc") {
		t.Fatalf("非纯数字的尺寸参数必须丢掉,实得 %s", u)
	}
}

// 缓存键必须区分尺寸:同一张图要了 480 高又要 1080 高,是两份字节。
// 不区分的话小图会被当成大图供出去,表现是「详情页大图糊」。
func TestCacheKeyIncludesSize(t *testing.T) {
	hits := 0
	s, up := newTestServer(t, func(w http.ResponseWriter, r *http.Request) {
		hits++
		_, _ = w.Write(pngBytes)
	})
	s.Allow(up.URL, nil)
	get(t, s, "/img?src="+up.URL+"/a.jpg&h=480", true)
	get(t, s, "/img?src="+up.URL+"/a.jpg&h=1080", true)
	if hits != 2 {
		t.Fatalf("不同尺寸是两份缓存,上游该被打 2 次,实得 %d", hits)
	}
}

// 缓存目录必须走 paths 这个唯一出口(SPEC §10.1)——
// 别的包自己拼路径的话,「绿色包单一数据根」那条就守不住了。
func TestCacheDirGoesThroughPaths(t *testing.T) {
	paths.SetRoot(t.TempDir())
	want := filepath.Join(paths.Root(), "cache", "img")
	if got := imgcache.Dir(); got != want {
		t.Fatalf("缓存目录应为 %s,实得 %s", want, got)
	}
}

// 白名单**登记时**就只收 http/https。
//
// ★ 这条单拎出来测,是因为上面那条「白名单外的 src 404」**盖不到它** ——
// 那个用例里名单本来就是空的,`file://` 被空名单挡下,scheme 检查有没有都一样红/绿。
// 一条永远不会红的断言不算断言。真正要挡的是「登记环节被喂了一个非 http 的来源」
// (插件 manifest 里声明的源、配置里迁移过来的旧值),让它连进名单的机会都没有。
func TestAllowRejectsNonHTTPScheme(t *testing.T) {
	paths.SetRoot(t.TempDir())
	s, err := Start()
	if err != nil {
		t.Fatal(err)
	}
	defer s.Close()

	for _, bad := range []string{
		"file:///C:/Windows",
		"gopher://127.0.0.1:11211",
		"ftp://127.0.0.1",
		"lpimg://localhost",
	} {
		s.Allow(bad, nil)
		if _, ok := s.lookup(bad); ok {
			t.Fatalf("%q 不该进得了白名单", bad)
		}
	}
	// 对照组:http/https 要进得去,否则这条测试可能只是「Allow 整个坏掉了」
	s.Allow("https://example.invalid:8096", nil)
	if _, ok := s.lookup("https://example.invalid:8096/Items/1/Images/Primary"); !ok {
		t.Fatal("https 来源必须能登记 —— 不然这条测试证明不了任何事")
	}
}
