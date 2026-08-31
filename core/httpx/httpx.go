// Package httpx 是统一的 HTTP 出口:UA 口径、代理、自签名放行、空闲超时。
//
// 移植自 `crates/core/src/http.rs`。**Rust 版是黄金实现。**
//
// ---------- User-Agent 四分口径(用户 2026-07-19 定,2026-07-21 补第四道)----------
//
//	访问 Emby            → LinPlayer/{版本}          EmbyClient()
//	多线程加载 / 预加载   → LinPlayerPreload/{版本}   PreloadClient()
//	第三方公开 API       → LinPlayer/{版本} (+仓库)   Client()
//	其它                 → 同上(Client)
//
// 为什么分开:预取代理是**我们替 mpv 提前拉流**的旁路请求,和用户真正在看的那一路
// 在服务端日志/风控里必须能区分开。糊成一个 UA,服主看到的就是「一个客户端同时开了
// 四五路并发」,最容易被当成盗刷限速。
//
// ★★ 第三方那道**不能不设 UA**。Go 的 http.Client 不设就是发 `Go-http-client/1.1`,
// reqwest 干脆一个头都不发 —— 带 WAF 的公开 API 会直接判成脚本流量:
// 2026-07-21 实测 api.bgm.tv 同一个 Access Token,带 UA → 200,不带 → **403(Cloudflare)**,
// 而错误信息长得像「AccessToken 无效」。curl 自带 UA,所以手测永远复现不出来。
package httpx

import (
	"context"
	"errors"
	"io"
	"net"
	"net/http"
	"net/url"
	"strings"
	"sync"
	"time"

	"linplayer/core/net/tlspolicy"
)

// AppName 客户端名。三条 UA 都由它派生。
const AppName = "LinPlayer"

// RepoURL 放进第三方 API 的 UA 里,方便对方风控找到人(bgm.tv 开发指引要求)。
const RepoURL = "https://github.com/zzzwannasleep/LinPlayer"

var (
	mu      sync.RWMutex
	version = "0.0.0"
	proxy   string // 空 = 直连

	// 三个客户端各自缓存。改代理时**三个都要作废** ——
	// 漏一个,那条路就还在用旧代理设置,而用户在设置页看到的是「已保存」。
	cached [3]*http.Client
)

// 三条道的下标。
const (
	laneAPI = iota
	laneEmby
	lanePreload
)

// SetVersion 由 lp_init 调用。
func SetVersion(v string) {
	mu.Lock()
	defer mu.Unlock()
	if v = strings.TrimSpace(v); v != "" {
		version = v
	}
	cached = [3]*http.Client{}
}

// UA 访问 Emby 用的 User-Agent。
func UA() string { mu.RLock(); defer mu.RUnlock(); return AppName + "/" + version }

// PreloadUA 多线程加载 / 预加载(预取代理拉上游)用的 User-Agent。
func PreloadUA() string {
	mu.RLock()
	defer mu.RUnlock()
	return AppName + "Preload/" + version
}

// APIUA 第三方公开 API(Bangumi / Trakt / 弹弹Play / 翻译 / 排行榜)用的 User-Agent。
func APIUA() string {
	mu.RLock()
	defer mu.RUnlock()
	return AppName + "/" + version + " (+" + RepoURL + ")"
}

// SetProxy 设置全局代理(如 socks5://host:port);空串 = 直连。
func SetProxy(u string) {
	mu.Lock()
	defer mu.Unlock()
	proxy = strings.TrimSpace(u)
	cached = [3]*http.Client{} // 弃用旧客户端,否则改完代理要重启才生效
}

// ProxyURL 当前代理地址,空 = 直连。
func ProxyURL() string { mu.RLock(); defer mu.RUnlock(); return proxy }

// IsLoopbackURL 这个地址是不是本机回环(= 我们自己起的 CF 反代 / 预取代理)。
//
// ★★ 回环**永不走用户代理**。我们在 127.0.0.1 上起了两层本地服务,它们的地址会经
// ActiveLineURL 进到播放 / API 链路里。代理是**字面意义上的 all**,连 127.0.0.1
// 都会被塞给那个代理,而代理再去连**它自己那边**的 127.0.0.1 —— 本机的服务不在那头:
//
//	代理在远端 → 直接连不上,「开了 CF 优选反而全挂」
//	代理在本机 → 侥幸能通,但每个分段都白绕一圈
//
// ★ 这个函数还得**导出**:mpv 不是我们的 client,它自己带 http-proxy 选项,
// 同样不能让它把 127.0.0.1 递给用户配的代理。
func IsLoopbackURL(raw string) bool {
	h := strings.ToLower(HostOf(raw))
	h = strings.TrimSuffix(strings.TrimPrefix(h, "["), "]") // IPv6 字面量
	return h == "localhost" || h == "::1" || strings.HasPrefix(h, "127.")
}

// HostOf 从任意形态(URL / host:port / 裸 host)里取出纯 host。IPv6 字面量保留方括号。
func HostOf(input string) string {
	rest := input
	if i := strings.Index(rest, "://"); i >= 0 {
		rest = rest[i+3:]
	}
	if i := strings.IndexAny(rest, "/?#"); i >= 0 {
		rest = rest[:i]
	}
	if i := strings.LastIndex(rest, "@"); i >= 0 {
		rest = rest[i+1:]
	}
	if b := strings.LastIndex(rest, "]"); b >= 0 {
		return rest[:b+1]
	}
	if i := strings.Index(rest, ":"); i >= 0 {
		return rest[:i]
	}
	return rest
}

// ---------------------------------------------------------------------------
// 超时:**空闲超时**,不是整体超时
// ---------------------------------------------------------------------------
//
// ★★ 这一段的写法是被真事故定死的。
//
// 三个 reqwest client 原本一个 timeout 都没设 —— 上游黑洞时永远吊着,而且零日志。
// 我第一版修成 `http.Client{Timeout: …}` 差点发出去:那是**整体超时**,
// 慢链路上合法地拉 4MB 要 29~62 秒,整体超时会把正常的慢下载一刀切死。
//
// 正确的判据是「**还在不在吐字节**」:
//
//	响应头阶段 → Transport.ResponseHeaderTimeout
//	响应体阶段 → 每次 Read 都重置计时(idleBody)
//
// 所以 http.Client.Timeout 这个字段在本包里**必须保持为 0**。
var (
	// headerIdle 连响应头都等不到 = 这个地址不灵。
	headerIdle = 30 * time.Second
	// bodyIdle 响应体停止吐字节多久算死。
	bodyIdle = 30 * time.Second
	// dialTimeout 连不上就是连不上,不用等太久。
	dialTimeout = 15 * time.Second
)

// testMu 串行化改全局超时的测试。
//
// ★ 这不是洁癖:两条护栏测试共用同一个全局覆盖值,并发跑时后一条会把前一条的值
// 改掉 —— 表现是**随机红**,而且每次红的那条都不一样,看起来像「flaky」。
var testMu sync.Mutex

// setTimeoutsForTest 覆盖超时并返回还原函数。只给本包测试用。
func setTimeoutsForTest(header, body time.Duration) func() {
	testMu.Lock()
	oh, ob := headerIdle, bodyIdle
	headerIdle, bodyIdle = header, body
	Invalidate()
	return func() {
		headerIdle, bodyIdle = oh, ob
		Invalidate()
		testMu.Unlock()
	}
}

// idleBody 把「整体超时」换成「空闲超时」:每读到一次数据就重置计时器。
type idleBody struct {
	rc  io.ReadCloser
	d   time.Duration
	t   *time.Timer
	one sync.Once
}

func newIdleBody(rc io.ReadCloser, d time.Duration) io.ReadCloser {
	b := &idleBody{rc: rc, d: d}
	// ★ 计时器到点就**关掉底层 body**,让阻塞中的 Read 立刻返回错误。
	//   不这么做的话,Read 会一直挂在 socket 上,超时形同虚设。
	b.t = time.AfterFunc(d, func() { _ = rc.Close() })
	return b
}

func (b *idleBody) Read(p []byte) (int, error) {
	n, err := b.rc.Read(p)
	if n > 0 {
		b.t.Reset(b.d) // 还在吐 → 重新计时
	}
	if err != nil && !errors.Is(err, io.EOF) {
		// 分不清「上游断了」和「我们自己超时关的」时,给个能查的说法
		err = &IdleTimeoutError{Err: err, After: b.d}
	}
	return n, err
}

func (b *idleBody) Close() error {
	b.one.Do(func() { b.t.Stop() })
	return b.rc.Close()
}

// IdleTimeoutError 读体过程中出错。调用方要区分「上游拒绝」和「上游黑洞」时用得上。
type IdleTimeoutError struct {
	Err   error
	After time.Duration
}

func (e *IdleTimeoutError) Error() string {
	return "读响应体中断(空闲上限 " + e.After.String() + "): " + e.Err.Error()
}
func (e *IdleTimeoutError) Unwrap() error { return e.Err }

// uaAndIdle 给请求补 UA、给响应体套空闲超时。
//
// ★ UA 是**补**不是**盖**:调用方已经设过就不动它(emby 那边逐个请求自己设)。
type uaAndIdle struct {
	next http.RoundTripper
	ua   string
}

func (t *uaAndIdle) RoundTrip(r *http.Request) (*http.Response, error) {
	if r.Header.Get("User-Agent") == "" && t.ua != "" {
		r = r.Clone(r.Context())
		r.Header.Set("User-Agent", t.ua)
	}
	resp, err := t.next.RoundTrip(r)
	if err != nil || resp == nil || resp.Body == nil {
		return resp, err
	}
	resp.Body = newIdleBody(resp.Body, bodyIdle)
	return resp, nil
}

// proxyFor 决定这一条请求走不走代理。回环一律直连(见 IsLoopbackURL)。
func proxyFor(r *http.Request) (*url.URL, error) {
	p := ProxyURL()
	if p == "" || IsLoopbackURL(r.URL.String()) {
		return nil, nil
	}
	return url.Parse(p)
}

func build(ua string) *http.Client {
	tr := tlspolicy.TransportWith(func(t *http.Transport) {
		t.Proxy = proxyFor
		t.ResponseHeaderTimeout = headerIdle
		t.DialContext = (&net.Dialer{Timeout: dialTimeout, KeepAlive: 30 * time.Second}).DialContext
	})
	// ★ Timeout 故意留 0 —— 见上面那段。整体超时会把合法的慢下载一刀切死。
	return &http.Client{Transport: &uaAndIdle{next: tr, ua: ua}}
}

func clientFor(lane int, ua func() string) *http.Client {
	mu.RLock()
	c := cached[lane]
	mu.RUnlock()
	if c != nil {
		return c
	}
	/* ★★ UA 必须在**拿写锁之前**算好。
	   UA()/APIUA() 自己要读锁,而 Go 的 RWMutex **不可重入** ——
	   持着写锁去调它就是当场死锁。表现不是报错,是**整个测试包卡住不动**,
	   连哪一条卡的都要靠 goroutine dump 才看得出来。 */
	s := ua()
	mu.Lock()
	defer mu.Unlock()
	if cached[lane] == nil {
		cached[lane] = build(s)
	}
	return cached[lane]
}

// Client 第三方公开 API 与其它一切。
func Client() *http.Client { return clientFor(laneAPI, APIUA) }

// EmbyClient 访问 Emby。
func EmbyClient() *http.Client { return clientFor(laneEmby, UA) }

// PreloadClient 多线程加载 / 预加载拉上游。
func PreloadClient() *http.Client { return clientFor(lanePreload, PreloadUA) }

// Invalidate 让三个缓存的客户端全部作废(自签名白名单变了时调)。
func Invalidate() {
	mu.Lock()
	defer mu.Unlock()
	cached = [3]*http.Client{}
}

// GetJSON 一次性 GET,读全响应体。ctx 负责整体取消,空闲超时由 client 负责。
func GetJSON(ctx context.Context, c *http.Client, u string, hdr http.Header) ([]byte, int, error) {
	req, err := http.NewRequestWithContext(ctx, http.MethodGet, u, nil)
	if err != nil {
		return nil, 0, err
	}
	req.Header.Set("Accept", "application/json")
	for k, vs := range hdr {
		for _, v := range vs {
			req.Header.Add(k, v)
		}
	}
	resp, err := c.Do(req)
	if err != nil {
		return nil, 0, err
	}
	defer resp.Body.Close()
	b, err := io.ReadAll(resp.Body)
	return b, resp.StatusCode, err
}
