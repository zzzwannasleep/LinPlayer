package cf

// 本地反代:监听 127.0.0.1:<随机端口>,把明文 HTTP 桥接成到**指定边缘 IP** 的 HTTPS。
//
// ★ Rust 侧那份是从 Dart 手写的 TLS 隧道 + 连接池 + chunked 解析一路收敛来的;
// Go 这边 `net/http` + `httputil.ReverseProxy` 把这些全带了 ——
// 钉 IP 只需换掉 Transport 的 DialContext,SNI 仍由 URL 的 host 决定。
// **别再手写一遍入站解析**:那是 Dart 时代的历史包袱,不是设计。

import (
	"context"
	"crypto/tls"
	"fmt"
	"net"
	"net/http"
	"net/http/httputil"
	"net/url"
	"sync"
	"sync/atomic"
	"time"
)

// Handle 一个跑着的反代。**Close 即停服。**
type Handle struct {
	Port int

	mu     sync.Mutex
	ip     string
	srv    *http.Server
	ln     net.Listener
	proxy  *httputil.ReverseProxy
	closed atomic.Bool

	scheme, host  string
	upPort        int
	allowInsecure bool
}

// PinnedIP 当前钉的是哪个 IP。
func (h *Handle) PinnedIP() string {
	h.mu.Lock()
	defer h.mu.Unlock()
	return h.ip
}

// UpdateIP 切换优选 IP。**端口不变** —— 换端口就等于让所有已登记的改写全部作废。
//
// 切 IP 属低频(重测速之后),重建 Transport 的成本可忽略;
// 旧连接自然淘汰,不用去追。
func (h *Handle) UpdateIP(ip string) {
	h.mu.Lock()
	defer h.mu.Unlock()
	if h.ip == ip || ip == "" {
		return
	}
	h.ip = ip
	h.proxy.Transport = transportFor(ip, h.upPort, h.allowInsecure)
}

// Close 停服。
func (h *Handle) Close() {
	if h.closed.Swap(true) {
		return
	}
	_ = h.srv.Close()
	_ = h.ln.Close()
}

// transportFor 把上游 host 的 DNS **钉到指定 IP**,而 TLS SNI / HTTP Host 仍是真实域名。
//
// ★ 这一句就是整套优选的全部技术内容:CF anycast 按 SNI + Host 调度回源,
// 连到哪个边缘 IP 都能正确回源。
//
// ★ Go 在 TLSClientConfig.ServerName 为空时会**用 URL 的 host 做 SNI** ——
// 所以这里千万别顺手把 ServerName 设成 IP,那样握手会被对端拒(或者更糟:
// 拿到一张通配证书然后回源到错的站点)。
func transportFor(ip string, port int, allowInsecure bool) *http.Transport {
	pinned := net.JoinHostPort(ip, fmt.Sprint(port))
	d := &net.Dialer{Timeout: 15 * time.Second, KeepAlive: 30 * time.Second}
	return &http.Transport{
		DialContext: func(ctx context.Context, network, _ string) (net.Conn, error) {
			// 忽略传进来的 addr(它是真实域名),一律连钉住的那个 IP
			return d.DialContext(ctx, network, pinned)
		},
		TLSClientConfig:     &tls.Config{InsecureSkipVerify: allowInsecure}, //nolint:gosec // 由账号的「允许自签名」开关控制
		MaxIdleConnsPerHost: 8,
		IdleConnTimeout:     90 * time.Second,
	}
}

// Start 起反代,返回句柄(本地基址 = http://127.0.0.1:<Port>)。
func Start(scheme, host string, port int, ip string, allowInsecure bool) (*Handle, error) {
	if ip == "" {
		return nil, fmt.Errorf("没有可用的优选 IP")
	}
	target := &url.URL{Scheme: scheme, Host: net.JoinHostPort(host, fmt.Sprint(port))}
	ln, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		return nil, fmt.Errorf("起本地反代失败: %w", err)
	}

	rp := &httputil.ReverseProxy{
		Rewrite: func(r *httputil.ProxyRequest) {
			r.SetURL(target)
			// ★ Host 必须是**真实域名**:CF 靠它调度回源,写成 127.0.0.1 直接 404/403
			r.Out.Host = target.Host
			/* ★ 不要转发 X-Forwarded-For:这是个**本机**反代,不是网关。
			   把用户的内网地址捅到公网上没有任何好处。 */
			r.Out.Header.Del("X-Forwarded-For")
		},
		Transport: transportFor(ip, port, allowInsecure),
		/* ★ 反代**忠实透传,不代客户端跟跳** —— 跟了的话客户端拿不到 302,
		   而 302 的落点(CDN 直链)恰恰是取流那条路要自己缓存的东西。 */
		ModifyResponse: func(resp *http.Response) error {
			/* ★★ 必须显式 `Connection: close`。
			   这和预取代理是**同一个坑**:那边 2026-07-19 修了,这份同构代码当时**漏了**,
			   用户 2026-08-01 报的「没有画面也没有声音…即便有时候显示有流量,
			   也依然加载不出来」和当年一字不差。

			   HTTP/1.1 默认长连接。不写这个头就是在对播放器承诺「这条连接还能再发请求」,
			   而 mpv/ffmpeg 起播必 seek(MKV 索引在末尾),它会把下一个 `Range:`
			   **管线化发在同一条 socket 上** —— 那个请求进黑洞、响应永不来,
			   播放器干等,超时后重连从头线性读 = 有流量、黑屏无声、慢得离谱。 */
			resp.Header.Set("Connection", "close")
			resp.Close = true
			return nil
		},
		ErrorHandler: func(w http.ResponseWriter, r *http.Request, err error) {
			/* ★ 这里回的 502 **不代表签名链失效**。预取代理那边看到 5xx 会去重签,
			   而重签当然还是解析出同一个本地地址 —— 所以那边**不能**据此停用重签
			   (一次网关抖动把重签永久关掉,等片子真的播到签名过期时已经没人能换地址了)。 */
			w.Header().Set("Connection", "close")
			http.Error(w, "反代上游连不上: "+err.Error(), http.StatusBadGateway)
		},
	}

	h := &Handle{
		Port: ln.Addr().(*net.TCPAddr).Port,
		ip:   ip, ln: ln, proxy: rp,
		scheme: scheme, host: host, upPort: port, allowInsecure: allowInsecure,
	}
	h.srv = &http.Server{Handler: rp, ReadHeaderTimeout: 15 * time.Second}
	go func() { _ = h.srv.Serve(ln) }()
	return h, nil
}
