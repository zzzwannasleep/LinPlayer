package httpx

// 这个包的每一条判据都对应一次真事故。测试按**行为**验,不比对常量 ——
// 比对常量的话,「UA 设了但没发出去」这类问题一条都抓不到。

import (
	"context"
	"io"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
	"time"
)

// echoUA 一台只回显 User-Agent 的服务器。
func echoUA(t *testing.T) (*httptest.Server, *string) {
	t.Helper()
	var got string
	s := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		got = r.Header.Get("User-Agent")
		_, _ = w.Write([]byte("ok"))
	}))
	t.Cleanup(s.Close)
	return s, &got
}

// ★★ 三条 UA 道**按行为验**:打真服务器读它收到的头,不比对我们自己的常量。
//
// 「UA 设了但没发出去」比「UA 值写错了」常见得多,而后者才是比对常量抓得到的那种。
func TestUA三条道各走各的(t *testing.T) {
	SetVersion("9.9.9")
	Invalidate()

	for _, c := range []struct {
		name   string
		client func() *http.Client
		want   string
	}{
		{"Emby", EmbyClient, "LinPlayer/9.9.9"},
		{"预加载", PreloadClient, "LinPlayerPreload/9.9.9"},
		{"第三方 API", Client, "LinPlayer/9.9.9 (+" + RepoURL + ")"},
	} {
		srv, got := echoUA(t)
		resp, err := c.client().Get(srv.URL)
		if err != nil {
			t.Fatalf("%s: %v", c.name, err)
		}
		_, _ = io.Copy(io.Discard, resp.Body)
		resp.Body.Close()
		if *got != c.want {
			t.Fatalf("%s 这条道发出去的 UA 是 %q,应当是 %q —— "+
				"三条道糊成一个,服主看到的就是「一个客户端开了四五路并发」", c.name, *got, c.want)
		}
	}
}

// ★★ 第三方那条**绝不能不发 UA**。
//
// 不发的话带 WAF 的公开 API 直接判脚本流量:实测 api.bgm.tv 同一个 token,
// 带 UA → 200,不带 → 403,而错误信息长得像「AccessToken 无效」。
func TestUA第三方道不许为空(t *testing.T) {
	SetVersion("9.9.9")
	Invalidate()
	srv, got := echoUA(t)
	resp, err := Client().Get(srv.URL)
	if err != nil {
		t.Fatal(err)
	}
	resp.Body.Close()
	if *got == "" || strings.HasPrefix(*got, "Go-http-client") {
		t.Fatalf("第三方 API 那条道发出去的 UA 是 %q —— 会被 WAF 判成脚本流量,"+
			"而错误长得像鉴权失败", *got)
	}
}

// ★ UA 是**补**不是**盖**:调用方自己设过就不动它(emby 那边逐个请求自己设)。
func TestUA调用方设过就不覆盖(t *testing.T) {
	Invalidate()
	srv, got := echoUA(t)
	req, _ := http.NewRequest(http.MethodGet, srv.URL, nil)
	req.Header.Set("User-Agent", "调用方自己的UA")
	resp, err := Client().Do(req)
	if err != nil {
		t.Fatal(err)
	}
	resp.Body.Close()
	if *got != "调用方自己的UA" {
		t.Fatalf("把调用方设的 UA 盖掉了,实收 %q", *got)
	}
}

// ★★ 空闲超时,**不是整体超时**。
//
// 慢链路上合法地拉 4MB 要 29~62 秒。整体超时会把这种正常的慢下载一刀切死 ——
// 表现是「网慢的时候视频永远加载不出来」,而日志里只有一句超时。
func TestSlowButAlive慢而不死(t *testing.T) {
	defer setTimeoutsForTest(300*time.Millisecond, 300*time.Millisecond)()

	// 一直在吐字节,但吐得很慢:总时长 1.5s 远超 300ms 的空闲上限
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.WriteHeader(200)
		for i := 0; i < 15; i++ {
			_, _ = w.Write([]byte("x"))
			w.(http.Flusher).Flush()
			time.Sleep(100 * time.Millisecond)
		}
	}))
	defer srv.Close()

	t0 := time.Now()
	resp, err := Client().Get(srv.URL)
	if err != nil {
		t.Fatalf("请求失败: %v", err)
	}
	defer resp.Body.Close()
	b, err := io.ReadAll(resp.Body)
	if err != nil {
		t.Fatalf("读体失败: %v —— 这是**整体超时**的症状:一直在吐字节却被判死", err)
	}
	if len(b) != 15 {
		t.Fatalf("只读到 %d 字节,应当 15", len(b))
	}
	if time.Since(t0) < time.Second {
		t.Fatal("夹具不成立:总时长没超过空闲上限,这条用例分不出整体超时和空闲超时")
	}
}

// ★★ 连上就不吐字节的黑洞,必须在空闲上限内失败,不能永远吊着。
func TestBlackHole停止吐字节要判死(t *testing.T) {
	defer setTimeoutsForTest(300*time.Millisecond, 300*time.Millisecond)()

	release := make(chan struct{})
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.WriteHeader(200)
		_, _ = w.Write([]byte("x"))
		w.(http.Flusher).Flush()
		<-release // 之后一个字节都不给
	}))
	/* ★★ 这两条 defer 的**顺序不能反**(defer 是后进先出:close 先跑、Close 后跑)。
	   反过来的话 srv.Close() 会等这个还吊着的 handler 跑完,而它正等着 release ——
	   整个包**当场死锁**,表现是「测试卡住不动」而不是「测试失败」。
	   同一个坑在 login_servername_test 和 prefetch 那边各踩过一次。 */
	defer srv.Close()
	defer close(release)

	t0 := time.Now()
	resp, err := Client().Get(srv.URL)
	if err != nil {
		t.Fatalf("请求失败: %v", err)
	}
	defer resp.Body.Close()
	if _, err := io.ReadAll(resp.Body); err == nil {
		t.Fatal("上游停止吐字节,读体却成功了 —— 空闲超时没生效,真实表现是永远转圈")
	}
	if d := time.Since(t0); d > 3*time.Second {
		t.Fatalf("等了 %v 才判死,空闲上限是 300ms", d)
	}
}

// ★★ 回环**永不走用户代理**。
//
// 用户一旦同时开了代理,reqwest/Go 的代理是字面意义上的 all,连 127.0.0.1 都会
// 递给代理 —— 代理再去连它自己那边的 127.0.0.1,我们的本地服务不在那头。
// 结果是「开了 CF 优选反而全挂」。
func TestLoopback永不走代理(t *testing.T) {
	Invalidate()
	SetProxy("http://127.0.0.1:1") // 一个必然连不上的代理
	defer SetProxy("")

	srv, _ := echoUA(t) // httptest 起在 127.0.0.1
	resp, err := Client().Get(srv.URL)
	if err != nil {
		t.Fatalf("打本机地址被塞给了代理: %v —— 用户开了代理就会「开 CF 优选反而全挂」", err)
	}
	resp.Body.Close()

	for _, u := range []string{"http://127.0.0.1:8096/x", "http://localhost:1/", "http://[::1]:99/"} {
		if !IsLoopbackURL(u) {
			t.Fatalf("%s 没被判成回环", u)
		}
	}
	for _, u := range []string{"https://a.example/x", "http://10.0.0.1/", "http://127x.example/"} {
		if IsLoopbackURL(u) {
			t.Fatalf("%s 被误判成回环 —— 它会绕过用户配的代理", u)
		}
	}
}

// ★ 改代理要**立刻**生效,不能等重启。三个缓存客户端都得作废。
func TestSetProxy三个客户端都作废(t *testing.T) {
	Invalidate()
	a, b, c := Client(), EmbyClient(), PreloadClient()
	SetProxy("http://127.0.0.1:1")
	defer SetProxy("")
	if Client() == a || EmbyClient() == b || PreloadClient() == c {
		t.Fatal("改代理后还在用旧客户端 —— 用户在设置页切代理、点了保存、没反应")
	}
}

func TestHostOf各种形态(t *testing.T) {
	cases := map[string]string{
		"https://a.example:8920/x": "a.example",
		"a.example":                "a.example",
		"a.example:8096":           "a.example",
		"http://u:p@a.example/x":   "a.example",
		"http://[::1]:8096/x":      "[::1]",
		"[::1]":                    "[::1]",
	}
	for in, want := range cases {
		if got := HostOf(in); got != want {
			t.Fatalf("HostOf(%q) = %q,想要 %q", in, got, want)
		}
	}
}

func TestGetJSON带上自定义头(t *testing.T) {
	var got string
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		got = r.Header.Get("X-Test")
		_, _ = w.Write([]byte(`{"ok":true}`))
	}))
	defer srv.Close()
	b, code, err := GetJSON(context.Background(), Client(), srv.URL, http.Header{"X-Test": {"v"}})
	if err != nil || code != 200 || !strings.Contains(string(b), "ok") {
		t.Fatalf("GetJSON: %v code=%d body=%s", err, code, b)
	}
	if got != "v" {
		t.Fatalf("自定义头没发出去: %q", got)
	}
}
