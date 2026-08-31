// Package tlspolicy 按 host 决定要不要放行自签名证书。
//
// ★★ **只对用户明确勾了「允许自签名」的那几台 host 放行**,别的一律严格校验。
// 全局关掉校验会顺带把更新下载、WebDAV、插件源、图片代理全都变成不安全的 ——
// 而用户勾的只是「我这台自建 Emby 用的是自签名证书」。
//
// 做法是两个 Transport 分派,不是一个 Transport 加 InsecureSkipVerify:
// 后者一旦写错条件就是**静默全放行**,而且看日志看不出来。
package tlspolicy

import (
	"crypto/tls"
	"net/http"
	"net/url"
	"strings"
	"sync"
)

var (
	mu sync.RWMutex
	// allowed 放行的 host(含端口,小写)。key 是 host,不是完整 URL。
	allowed = map[string]bool{}
)

// hostOf 从配置里存的地址取 host。
//
// ★ 配置里存的是完整 URL(https://a.example:8920),但比对时手上只有 r.URL.Host。
// 直接拿 URL 当 key 比对,**永远匹配不上** —— 表现是用户勾了却还是连不上。
func hostOf(raw string) string {
	s := strings.TrimSpace(raw)
	if s == "" {
		return ""
	}
	if !strings.Contains(s, "://") {
		s = "http://" + s
	}
	u, err := url.Parse(s)
	if err != nil || u.Host == "" {
		return ""
	}
	return strings.ToLower(u.Host)
}

// Set 覆写白名单。每条改账号的路径末尾都要调一次(和图片白名单同一个道理)。
func Set(addrs []string) {
	next := make(map[string]bool, len(addrs))
	for _, a := range addrs {
		if h := hostOf(a); h != "" {
			next[h] = true
		}
	}
	mu.Lock()
	allowed = next
	mu.Unlock()
}

// AllowsHost 这个 host 放行自签名吗。
func AllowsHost(host string) bool {
	mu.RLock()
	defer mu.RUnlock()
	return allowed[strings.ToLower(host)]
}

// byHost 按 host 在「严格」和「放行」两个 Transport 之间分派。
type byHost struct{ strict, lax http.RoundTripper }

func (p *byHost) RoundTrip(r *http.Request) (*http.Response, error) {
	// http 的请求根本没有 TLS,走严格那条即可(两条对 http 行为一致)
	if r.URL.Scheme == "https" && AllowsHost(r.URL.Host) {
		return p.lax.RoundTrip(r)
	}
	return p.strict.RoundTrip(r)
}

// Transport 造一个按 host 分派的 RoundTripper。
func Transport() http.RoundTripper {
	strict := http.DefaultTransport.(*http.Transport).Clone()
	lax := http.DefaultTransport.(*http.Transport).Clone()
	lax.TLSClientConfig = &tls.Config{InsecureSkipVerify: true} //nolint:gosec // 仅对用户勾选的 host 生效,见包注释
	return &byHost{strict: strict, lax: lax}
}
