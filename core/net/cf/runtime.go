// Package cf 是线路优选反代:把发往某条线路的请求改走一个**指定的边缘 IP**。
//
// 移植自 `crates/core/src/net/cf/`(runtime.rs / proxy.rs)。
//
// # 原理
//
// CF anycast 按 SNI + Host 调度回源 —— **连到哪个边缘 IP 都能正确回源**,
// 只要 TLS SNI / HTTP Host 仍是你自己的域名。于是就近挑一个最快的边缘 IP 钉住,
// 绕开运营商给的那个慢节点。
//
// # 这是整套优选的**唯一改写点**
//
// 某条线路开启优选后,这里登记「线路地址 → 本地反代基址」。
// `config.Account.ActiveLineURL()` 拿**当前生效线路的地址**来查,命中则返回本地基址,
// 于是 Emby API 请求与 mpv 取流 URL 都自动改走优选 IP,**与播放器实现无关**。
//
// ★★ 键是**线路**,不是服务器。
//
// 原先按服务器登记 —— 可一台服有很多条线路,而用户明确说过「有些线路并没有使用
// Cloudflare」。按服务器登记等于:只要这台服开过一次优选,**它的每一条线路**都被劫持
// 到那个反代上,连不在 CF 后面的直连线也不放过。而反代的上游 host 是开启时那条线定死的,
// 于是切到别的线路后,请求被送到「A 线的域名 + 钉死的 IP」——
// **连得上、拿不到东西,表现为加载极慢 / 没画面没声音,且全程不报错**。
// 优选本来就是对线路做的,键就必须是线路。
package cf

import (
	"fmt"
	"strconv"
	"strings"
	"sync"
)

var (
	routesMu sync.RWMutex
	routes   = map[string]string{}
)

// normKey 键归一化。
//
// ★ 线路地址是**用户手填的**,`https://a.com/` 与 `https://a.com` 必须同键 ——
// 不归一化就会出现「明明开了优选,ActiveLineURL 却查不到」的静默失效。
func normKey(lineURL string) string {
	return strings.TrimRight(strings.TrimSpace(lineURL), "/")
}

// LocalURLFor 命中则返回本地反代基址,否则空串(走原始线路)。参数是**线路地址**。
func LocalURLFor(lineURL string) string {
	routesMu.RLock()
	defer routesMu.RUnlock()
	return routes[normKey(lineURL)]
}

// Bind 登记改写:此后**这条线路**生效时,ActiveLineURL 返回 localURL。
func Bind(lineURL, localURL string) {
	routesMu.Lock()
	defer routesMu.Unlock()
	routes[normKey(lineURL)] = localURL
}

// Unbind 撤销改写,该线路恢复直连。
func Unbind(lineURL string) {
	routesMu.Lock()
	defer routesMu.Unlock()
	delete(routes, normKey(lineURL))
}

// IsActive 这条线路开着优选吗。
func IsActive(lineURL string) bool { return LocalURLFor(lineURL) != "" }

// All 当前所有改写(线路地址 → 本地基址),供设置页展示。
func All() map[string]string {
	routesMu.RLock()
	defer routesMu.RUnlock()
	out := make(map[string]string, len(routes))
	for k, v := range routes {
		out[k] = v
	}
	return out
}

// Clear 拆除所有改写(退出时)。
func Clear() {
	routesMu.Lock()
	defer routesMu.Unlock()
	routes = map[string]string{}
}

// LocalBase 把上游线路 URL 的**路径前缀**嫁接到本地反代端口上。
//
// ★★ 为什么要保留路径:反向代理只换了传输层落点。Emby 若挂在 `https://h/emby`
// 这种子路径下,丢掉 `/emby` 会让之后所有 API 打到 404 ——
// 而且是「连得上但全 404」的**静默故障**。
func LocalBase(upstreamURL string, port int) string {
	rest := upstreamURL
	if _, after, ok := strings.Cut(upstreamURL, "://"); ok {
		rest = after
	}
	path := ""
	if i := strings.Index(rest, "/"); i >= 0 {
		path = strings.TrimRight(rest[i:], "/")
	}
	return fmt.Sprintf("http://127.0.0.1:%d%s", port, path)
}

// SplitUpstream 拆出上游的 (scheme, host, port),供起反代用。默认 https:443 / http:80。
//
// ★ IPv6 字面量形如 `[::1]:8096` —— 端口分隔符必须按**最后一个 `:` 且在 `]` 之后**切,
// 否则会把地址本身切碎(而切碎之后连接的是一个不存在的主机,报的是「连不上」,
// 没人会想到是解析错了)。
func SplitUpstream(rawURL string) (scheme, host string, port int) {
	scheme, rest := "https", rawURL
	if s, after, ok := strings.Cut(rawURL, "://"); ok {
		if s != "" {
			scheme = s
		}
		rest = after
	}
	authority := rest
	if i := strings.Index(rest, "/"); i >= 0 {
		authority = rest[:i]
	}
	defaultPort := 443
	if strings.EqualFold(scheme, "http") {
		defaultPort = 80
	}

	splitAt := -1
	if b := strings.LastIndex(authority, "]"); b >= 0 {
		if i := strings.Index(authority[b:], ":"); i >= 0 {
			splitAt = b + i
		}
	} else {
		splitAt = strings.LastIndex(authority, ":")
	}
	if splitAt < 0 {
		return scheme, authority, defaultPort
	}
	p, err := strconv.Atoi(authority[splitAt+1:])
	if err != nil {
		p = defaultPort
	}
	return scheme, authority[:splitAt], p
}
