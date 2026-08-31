// Package localserve 是数据通道的本地 HTTP 服务(SPEC §6)。
//
// 核心层启动时在 127.0.0.1 绑一个**随机端口**,通过 lp_init 后的首个事件告知宿主。
// 三端的图片加载器直接把 `http://127.0.0.1:PORT/img?src=...` 交给
// Coil / Avalonia Bitmap 去拉 —— 图片字节**不过 FFI**,也不过命令队列。
//
// # 安全约束(SPEC §6)
//
//   - 只绑 127.0.0.1。
//   - 除 /companion/* 外所有路由都要鉴权。
//   - **/img 的 src 必须命中白名单**(已登录服务器 + 已授权插件源),否则 404。
//     没有这一条,它就是一个开放的 SSRF 代理 —— 局域网里任何一个能连到本机
//     回环的东西,都能借我们的进程去打内网。
//
// # 【坑】给 mpv 吃的路由,token 必须在 URL 里,不能在请求头
//
//	三端图片加载器、WebView  →  /img /icon /plugin/*  →  请求头 X-LP-Token
//	libmpv                   →  /stream/* /sub/*      →  URL 路径段
//
// 理由:给 mpv 加请求头只能改 http-header-fields,而那是一个**全局粘连属性** ——
// 现有教训是它把网盘的 Cookie 发给了 Emby。
//
// URL 里的 token 会进 mpv 日志,所以 token **每次启动重新随机生成,不落盘**。
package localserve

import (
	"context"
	"crypto/rand"
	"crypto/subtle"
	"encoding/hex"
	"errors"
	"fmt"
	"io"
	"net"
	"net/http"
	"net/url"
	"strings"
	"sync"
	"time"

	"linplayer/core/imgcache"
)

// Server 一个跑着的本地服务。
type Server struct {
	// Addr 形如 `127.0.0.1:51234`。
	Addr string
	// Token 本次启动的随机 token。**不落盘。**
	Token string

	http *http.Server
	ln   net.Listener

	mu sync.RWMutex
	// allow 是 src 白名单:origin(scheme://host[:port])→ 取图时要带的头。
	allow map[string]http.Header

	// Client 出网口。测试可以换掉。
	Client *http.Client

	// gate 限并发回源。见 fetchSlots。
	gate chan struct{}
}

// fetchSlots 同时最多几张图在**回源**。
//
// ★ 这是「整个 App 都很慢」的一个真因,不只是图慢。封面和 itemDetail / views /
// listLatest 这些 JSON 走的是**同一台服务器**。首页一屏三十几张封面同时回源时,
// 后面点进详情页要的那条 JSON 排在它们后头 —— 用户看到的是「简介也加载得很慢」,
// 而简介本身只有几 KB。反代那边通常还有每 IP 并发上限,超了直接排队。
//
// ★ 6 是折中:比它小,首屏封面填得肉眼可见地慢;比它大,又开始和 API 抢。
// **缓存命中的那条路不占名额**(先查缓存,查到就直接返回)。
const fetchSlots = 6

// fetchTimeout 单张图回源的墙钟上限。
//
// ★ 有闸就必须有超时:一条卡死的连接会把名额**永久**占住,
// 六条卡死 = 整个应用再也加载不出任何一张图,而且一声不吭。
const fetchTimeout = 20 * time.Second

// maxOneImage 单张上限。防「图片地址被填成一部电影的直链」。
const maxOneImage = 32 * 1024 * 1024

// Start 起服务。端口交给系统挑(0)。
func Start() (*Server, error) {
	ln, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		return nil, fmt.Errorf("本地服务起不来: %w", err)
	}
	tok := make([]byte, 24)
	if _, err := rand.Read(tok); err != nil {
		_ = ln.Close()
		return nil, fmt.Errorf("生成 token 失败: %w", err)
	}
	s := &Server{
		Addr:   ln.Addr().String(),
		Token:  hex.EncodeToString(tok),
		ln:     ln,
		allow:  map[string]http.Header{},
		Client: &http.Client{Timeout: fetchTimeout},
		gate:   make(chan struct{}, fetchSlots),
	}
	mux := http.NewServeMux()
	mux.HandleFunc("/img", s.handleImg)
	s.http = &http.Server{Handler: mux, ReadHeaderTimeout: 10 * time.Second}
	go func() {
		if err := s.http.Serve(ln); err != nil && !errors.Is(err, http.ErrServerClosed) {
			// ponytail: 接上 core/log 之后写一条 error。现在静默退出,
			// 表现是「所有图都加载不出来」—— 所以这条日志不能一直欠着。
			_ = err
		}
	}()
	return s, nil
}

// Close 停服务。
func (s *Server) Close() error { return s.http.Close() }

// BaseURL 给宿主的前缀。
func (s *Server) BaseURL() string { return "http://" + s.Addr }

// Allow 把一个来源加进白名单。
//
// 登录成功 / 授权插件源时调。headers 是取图时要带的头(Emby 是 X-Emby-Token,
// 网盘可能是 Cookie + Referer)。
//
// ★ 白名单按 **origin** 存,不按完整 URL:同一台服务器的图片路径千变万化,
// 按 URL 存等于没有白名单。
func (s *Server) Allow(rawOrigin string, headers http.Header) {
	o, ok := originOf(rawOrigin)
	if !ok {
		return
	}
	s.mu.Lock()
	defer s.mu.Unlock()
	if headers == nil {
		headers = http.Header{}
	}
	s.allow[o] = headers
}

// Revoke 从白名单里去掉一个来源(登出 / 删账号 / 撤销插件授权时调)。
//
// ★ 这条不能忘:删了账号但白名单还留着,那个 origin 就成了永久的 SSRF 出口。
func (s *Server) Revoke(rawOrigin string) {
	o, ok := originOf(rawOrigin)
	if !ok {
		return
	}
	s.mu.Lock()
	defer s.mu.Unlock()
	delete(s.allow, o)
}

// lookup 查白名单。返回(要带的头, 命中没有)。
func (s *Server) lookup(rawURL string) (http.Header, bool) {
	o, ok := originOf(rawURL)
	if !ok {
		return nil, false
	}
	s.mu.RLock()
	defer s.mu.RUnlock()
	h, ok := s.allow[o]
	return h, ok
}

// originOf 取 scheme://host[:port]。
//
// ★ 只认 http/https。放行别的 scheme 等于把 file:// gopher:// 一起放行了,
// 那正是 SSRF 代理最经典的越权路径。
func originOf(raw string) (string, bool) {
	u, err := url.Parse(strings.TrimSpace(raw))
	if err != nil || u.Host == "" {
		return "", false
	}
	if u.Scheme != "http" && u.Scheme != "https" {
		return "", false
	}
	return strings.ToLower(u.Scheme + "://" + u.Host), true
}

// authed 校验 token。
//
// ★ 用 constant-time 比较:token 是本次启动随机生成的,
// 但没有理由把一个可被计时侧信道逐字节猜出来的比较留在这。
func (s *Server) authed(r *http.Request) bool {
	got := r.Header.Get("X-LP-Token")
	if got == "" {
		// 给 mpv 吃的路由才走 URL 参数。/img 是图片加载器在用,只认头。
		return false
	}
	return subtle.ConstantTimeCompare([]byte(got), []byte(s.Token)) == 1
}

// handleImg 图片代理:查缓存 → 回源 → 落缓存。
//
//	GET /img?src=<完整图片 URL>&w=<px>&h=<px>
func (s *Server) handleImg(w http.ResponseWriter, r *http.Request) {
	if !s.authed(r) {
		http.Error(w, "缺少或不正确的 X-LP-Token", http.StatusUnauthorized)
		return
	}
	q := r.URL.Query()
	src := q.Get("src")
	headers, ok := s.lookup(src)
	if !ok {
		// ★ 回 404 不回 403:不告诉调用方「这个地址存在但你没权限」。
		//   而且失败必须有状态码,**不能回 200 + 空体** —— 空体会被当成一张坏图,
		//   前端的 onError 也不触发,又一个「不报错,只是不显示」。
		http.Error(w, "src 不在白名单里", http.StatusNotFound)
		return
	}

	upstream, err := withSize(src, q.Get("w"), q.Get("h"))
	if err != nil {
		http.Error(w, err.Error(), http.StatusBadRequest)
		return
	}

	/* 缓存键用**带尺寸的上游 URL**。约定 src 里**不带凭据**(凭据在白名单登记的
	   headers 里)—— 否则重登一次 token 变了,整盘缓存就全废。 */
	key := upstream
	if b := imgcache.Get2L(key); b != nil {
		writeImage(w, b, true)
		return
	}

	// ★ 到这里才占名额 —— 缓存命中的那条路在上面已经 return 了,不排队。
	select {
	case s.gate <- struct{}{}:
		defer func() { <-s.gate }()
	case <-r.Context().Done():
		return
	}

	ctx, cancel := context.WithTimeout(r.Context(), fetchTimeout)
	defer cancel()
	b, err := s.fetch(ctx, upstream, headers)
	if err != nil {
		http.Error(w, err.Error(), http.StatusBadGateway)
		return
	}
	imgcache.Put2L(key, b)
	writeImage(w, b, false)
}

func (s *Server) fetch(ctx context.Context, u string, headers http.Header) ([]byte, error) {
	req, err := http.NewRequestWithContext(ctx, http.MethodGet, u, nil)
	if err != nil {
		return nil, fmt.Errorf("请求构造失败: %w", err)
	}
	for k, vs := range headers {
		for _, v := range vs {
			req.Header.Add(k, v)
		}
	}
	/* ★ 必须跟 301。实测某 fork 的 /Items/{id}/Images/Backdrop/0 会 **301 跳到静态文件**。
	   不跟跳只会拿到几十字节的 HTML,然后被 Sniff 判成 octet-stream ——
	   表现为「图不显示但也不报错」。Go 的 http.Client 默认就跟(最多 10 跳),
	   这里依赖那个默认值,别给它装一个拒绝跳转的 CheckRedirect。 */
	resp, err := s.Client.Do(req)
	if err != nil {
		return nil, fmt.Errorf("取图失败: %w", err)
	}
	defer resp.Body.Close()
	if resp.StatusCode < 200 || resp.StatusCode >= 300 {
		return nil, fmt.Errorf("上游 HTTP %d", resp.StatusCode)
	}
	b, err := io.ReadAll(io.LimitReader(resp.Body, maxOneImage))
	if err != nil {
		return nil, fmt.Errorf("读图失败: %w", err)
	}
	if len(b) == 0 {
		return nil, errors.New("上游给了个空响应")
	}
	return b, nil
}

// withSize 把尺寸参数拼成上游认得的形状。
//
// ★ 只放行**纯数字**的 w/h,别把任意 query 拼给上游 —— src 已经过白名单了,
// 但 query 拼接仍是往别人服务器上构造请求,能收窄就收窄。
func withSize(src, w, h string) (string, error) {
	u, err := url.Parse(src)
	if err != nil {
		return "", fmt.Errorf("src 不是合法 URL: %w", err)
	}
	q := u.Query()
	if allDigits(w) {
		q.Set("maxWidth", w)
	}
	if allDigits(h) {
		q.Set("maxHeight", h)
	}
	u.RawQuery = q.Encode()
	return u.String(), nil
}

func allDigits(s string) bool {
	if s == "" {
		return false
	}
	for _, c := range s {
		if c < '0' || c > '9' {
			return false
		}
	}
	return true
}

func writeImage(w http.ResponseWriter, b []byte, cached bool) {
	// ★ 按魔数嗅 MIME,**不信上游的 Content-Type**:反代经常把它抹成
	//   application/octet-stream,那样图片解码器不认,图就是不显示且不报错。
	w.Header().Set("Content-Type", imgcache.Sniff(b))
	w.Header().Set("Cache-Control", "public, max-age=604800")
	// 图片加载器可能在 WebView 里,跨源画进 canvas 取主色要这个头。
	// 没有它 getImageData 抛 SecurityError,表现是「渐变永远不出现」且被 try 吞掉。
	w.Header().Set("Access-Control-Allow-Origin", "*")
	// 自检用:分得清这一张是缓存给的还是回源拿的
	if cached {
		w.Header().Set("X-LP-Cache", "hit")
	} else {
		w.Header().Set("X-LP-Cache", "miss")
	}
	_, _ = w.Write(b)
}

// ---------------------------------------------------------------- 进程级单例

// def 是本进程那一个 localserve。ffi 层起完服务后 SetDefault 一次。
//
// ponytail: 用包级变量而不是把 *Server 一路传下去 —— 白名单的登记点散在
// 登录 / 插件授权 / 删账号好几处,穿参会把 *Server 塞进一堆和它无关的签名里。
// 本包同仓的 blocklist / config 也是这个形状。
var (
	defMu sync.RWMutex
	def   *Server
)

// SetDefault 由 ffi 层在起完服务后调一次。
func SetDefault(s *Server) {
	defMu.Lock()
	defer defMu.Unlock()
	def = s
}

// Default 取当前实例。服务没起来时返回 nil —— 调用方必须判。
func Default() *Server {
	defMu.RLock()
	defer defMu.RUnlock()
	return def
}

// AllowDefault 往当前实例的白名单里加一条。服务没起来时什么也不做。
func AllowDefault(origin string, headers http.Header) {
	if s := Default(); s != nil {
		s.Allow(origin, headers)
	}
}

// RevokeDefault 从当前实例的白名单里去掉一条。
func RevokeDefault(origin string) {
	if s := Default(); s != nil {
		s.Revoke(origin)
	}
}

// ReplaceAllowlist 整表重建白名单。
//
// ★ 为什么是**重建**而不是提供 Allow/Revoke 让调用方增量维护:
// 删账号 / 删线路时忘了 Revoke 的话,那个 origin 会永久留在白名单里 ——
// 一个长期存在、谁也不会再想起来的 SSRF 出口。让调用方每次把「现在应该有哪些」
// 完整报一遍,漏删这件事就不可能发生。
//
// 回调里调 add 逐条登记;回调返回后一次性换上。回调内不要再碰这个 Server。
func (s *Server) ReplaceAllowlist(fill func(add func(origin string, headers http.Header))) {
	next := map[string]http.Header{}
	fill(func(origin string, headers http.Header) {
		o, ok := originOf(origin)
		if !ok {
			return
		}
		if headers == nil {
			headers = http.Header{}
		}
		next[o] = headers
	})
	s.mu.Lock()
	defer s.mu.Unlock()
	s.allow = next
}
