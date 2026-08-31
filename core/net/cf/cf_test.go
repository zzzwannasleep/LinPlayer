package cf

import (
	"fmt"
	"io"
	"net"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
	"time"
)

// ★★ 本地基址必须**保留上游的路径前缀**。
//
// 反向代理只换了传输层落点。Emby 若挂在 `https://h/emby` 这种子路径下,
// 丢掉 `/emby` 会让之后所有 API 打到 404 —— 而且是「连得上但全 404」的**静默故障**。
func TestLocalBase保留路径前缀(t *testing.T) {
	for _, c := range []struct{ in, want string }{
		{"https://h.com/emby", "http://127.0.0.1:5001/emby"},
		{"https://h.com:443/emby/", "http://127.0.0.1:5001/emby"},
		{"https://h.com", "http://127.0.0.1:5001"},
		{"https://h.com/", "http://127.0.0.1:5001"},
		{"http://h.com/a/b/", "http://127.0.0.1:5001/a/b"},
	} {
		if got := LocalBase(c.in, 5001); got != c.want {
			t.Errorf("LocalBase(%q) = %q,期望 %q", c.in, got, c.want)
		}
	}
}

// IPv6 字面量的端口分隔符要按**最后一个 `:` 且在 `]` 之后**切。
//
// ★ 按普通的「最后一个冒号」切会把地址本身切碎,而切碎之后连接的是一个不存在的主机,
// 报的是「连不上」—— 没人会想到是解析错了。
func TestSplitUpstream(t *testing.T) {
	for _, c := range []struct {
		in     string
		scheme string
		host   string
		port   int
	}{
		{"https://h.com/emby", "https", "h.com", 443},
		{"http://h.com/x", "http", "h.com", 80},
		{"https://h.com:8096", "https", "h.com", 8096},
		{"https://[::1]:8096/emby", "https", "[::1]", 8096},
		{"https://[::1]/emby", "https", "[::1]", 443},
		{"h.com/emby", "https", "h.com", 443}, // 没写 scheme 时按 https
	} {
		s, h, p := SplitUpstream(c.in)
		if s != c.scheme || h != c.host || p != c.port {
			t.Errorf("SplitUpstream(%q) = (%q,%q,%d),期望 (%q,%q,%d)",
				c.in, s, h, p, c.scheme, c.host, c.port)
		}
	}
}

// 登记 / 撤销往返,而且**尾斜杠必须同键**。
//
// ★ 线路表里的地址是用户手打的,同一条线可能写成带斜杠、而 DirectLineURL 拿到的是
// 另一种写法 —— 不归一化就是「开了优选没生效」,且不报错。
func TestBindUnbind与尾斜杠同键(t *testing.T) {
	Clear()
	defer Clear()
	const line = "https://x.example.invalid/emby"
	if IsActive(line) {
		t.Fatal("一开始不该是开着的")
	}
	Bind(line+"/", "http://127.0.0.1:9999/emby")
	if !IsActive(line) {
		t.Fatal("带尾斜杠登记的线路,不带斜杠应查得到 —— 否则「开了优选没生效」且不报错")
	}
	if got := LocalURLFor(line); got != "http://127.0.0.1:9999/emby" {
		t.Fatalf("查出来的基址不对: %q", got)
	}
	if len(All()) != 1 {
		t.Fatal("状态表该有一条")
	}
	Unbind(line)
	if IsActive(line + "/") {
		t.Fatal("撤销之后不该还在")
	}
}

// ★★ 反代要**钉住 IP、保住 SNI/Host**。
//
// 这一条是整套优选的全部技术内容:CF anycast 按 SNI + Host 调度回源,
// 连到哪个边缘 IP 都能正确回源 —— 前提是 Host 仍是真实域名。
// 把 Host 写成 127.0.0.1 的话直接 404/403,而且那个错误看起来像「服务器有问题」。
func TestProxy钉IP同时保住Host(t *testing.T) {
	var gotHost, gotPath string
	up := httptest.NewTLSServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		gotHost, gotPath = r.Host, r.URL.Path
		w.Header().Set("X-Upstream", "yes")
		_, _ = w.Write([]byte("上游的字节"))
	}))
	defer up.Close()

	_, _, port := SplitUpstream(up.URL)
	// 上游其实就监听在 127.0.0.1,这里假装「域名是 emby.example.invalid、
	// 边缘 IP 是 127.0.0.1」—— 正是优选的形状:DNS 钉到 IP,SNI/Host 仍是域名。
	h, err := Start("https", "emby.example.invalid", port, "127.0.0.1", true)
	if err != nil {
		t.Fatal(err)
	}
	defer h.Close()

	resp, err := http.Get(fmt.Sprintf("http://127.0.0.1:%d/Items/x", h.Port))
	if err != nil {
		t.Fatal(err)
	}
	defer resp.Body.Close()
	b, _ := io.ReadAll(resp.Body)

	if string(b) != "上游的字节" || resp.Header.Get("X-Upstream") != "yes" {
		t.Fatalf("响应没透传过来: %q %v", b, resp.Header)
	}
	if gotHost != "emby.example.invalid:"+fmt.Sprint(port) {
		t.Fatalf("上游收到的 Host 是 %q —— 必须是真实域名,写成 127.0.0.1 会 404/403", gotHost)
	}
	if gotPath != "/Items/x" {
		t.Fatalf("路径没透传: %q", gotPath)
	}
}

// ★★ 响应必须带 `Connection: close`。
//
// 这和预取代理是**同一个坑**:那边 2026-07-19 修了,而这份同构代码当时**漏了** ——
// 用户 2026-08-01 报的「没有画面也没有声音…即便有时候显示有流量,也依然加载不出来」
// 和当年一字不差。
//
// HTTP/1.1 默认长连接。不写这个头 = 对播放器承诺「这条连接还能再发请求」,
// 而 ffmpeg 起播必 seek,它会把下一个 Range 管线化到同一条 socket 上 ——
// 那个请求进黑洞、响应永不来。
func TestProxy必须带Connection_close(t *testing.T) {
	up := httptest.NewTLSServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		_, _ = w.Write([]byte("x"))
	}))
	defer up.Close()
	_, _, port := SplitUpstream(up.URL)
	h, err := Start("https", "emby.example.invalid", port, "127.0.0.1", true)
	if err != nil {
		t.Fatal(err)
	}
	defer h.Close()

	// ★ 在**原始字节**上验:Go 的 http 客户端把 Connection 当逐跳头吃掉了,
	//   用客户端读断言恒空,看起来像我们没发。
	raw := rawGet(t, h.Port, "/x")
	head, _, _ := strings.Cut(raw, "\r\n\r\n")
	if !strings.Contains(strings.ToLower(head), "connection: close") {
		t.Fatalf("必须带 Connection: close,实得:\n%s", head)
	}
}

// 上游连不上时回 502,**不能**把连接吊在那儿。
func TestProxy上游连不上回502(t *testing.T) {
	// 127.0.0.1:1 上没人听
	h, err := Start("https", "emby.example.invalid", 1, "127.0.0.1", true)
	if err != nil {
		t.Fatal(err)
	}
	defer h.Close()
	resp, err := http.Get(fmt.Sprintf("http://127.0.0.1:%d/x", h.Port))
	if err != nil {
		t.Fatal(err)
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusBadGateway {
		t.Fatalf("上游连不上该回 502,实得 %d", resp.StatusCode)
	}
}

// 换 IP **端口不变** —— 换端口就等于让所有已登记的改写全部作废。
func TestUpdateIP端口不变(t *testing.T) {
	up := httptest.NewTLSServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {}))
	defer up.Close()
	_, _, port := SplitUpstream(up.URL)
	h, err := Start("https", "emby.example.invalid", port, "127.0.0.1", true)
	if err != nil {
		t.Fatal(err)
	}
	defer h.Close()
	before := h.Port
	h.UpdateIP("127.0.0.2")
	if h.Port != before {
		t.Fatalf("换 IP 不该换端口(%d -> %d)—— 已登记的改写会全部指向一个死端口", before, h.Port)
	}
	if h.PinnedIP() != "127.0.0.2" {
		t.Fatalf("IP 没换上: %q", h.PinnedIP())
	}
	// 空 IP 不该把已有的钉子弄丢
	h.UpdateIP("")
	if h.PinnedIP() != "127.0.0.2" {
		t.Fatal("空 IP 不该覆盖掉当前的钉子")
	}
}

// 反代**不代客户端跟跳**:302 要原样透传。
//
// ★ 跟了的话客户端拿不到 302,而 302 的落点(CDN 直链)恰恰是取流那条路
// 要自己缓存下来的东西(不缓存就是每 4MB 重走一遍 302)。
func TestProxy不跟随重定向(t *testing.T) {
	up := httptest.NewTLSServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.URL.Path == "/redir" {
			http.Redirect(w, r, "https://cdn.example.invalid/real.mkv", http.StatusFound)
			return
		}
		_, _ = w.Write([]byte("不该走到这儿"))
	}))
	defer up.Close()
	_, _, port := SplitUpstream(up.URL)
	h, err := Start("https", "emby.example.invalid", port, "127.0.0.1", true)
	if err != nil {
		t.Fatal(err)
	}
	defer h.Close()

	c := &http.Client{CheckRedirect: func(*http.Request, []*http.Request) error {
		return http.ErrUseLastResponse
	}}
	resp, err := c.Get(fmt.Sprintf("http://127.0.0.1:%d/redir", h.Port))
	if err != nil {
		t.Fatal(err)
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusFound {
		t.Fatalf("302 该原样透传,实得 %d —— 代客户端跟跳会让取流那条路拿不到 CDN 落点", resp.StatusCode)
	}
	if loc := resp.Header.Get("Location"); loc != "https://cdn.example.invalid/real.mkv" {
		t.Fatalf("Location 没透传: %q", loc)
	}
}

// rawGet 手写一次 HTTP 请求,把原始响应字节读回来。
func rawGet(t *testing.T, port int, path string) string {
	t.Helper()
	conn, err := net.DialTimeout("tcp", fmt.Sprintf("127.0.0.1:%d", port), 5*time.Second)
	if err != nil {
		t.Fatal(err)
	}
	defer conn.Close()
	_ = conn.SetReadDeadline(time.Now().Add(10 * time.Second))
	fmt.Fprintf(conn, "GET %s HTTP/1.1\r\nHost: 127.0.0.1\r\n\r\n", path)
	b, _ := io.ReadAll(conn)
	return string(b)
}
