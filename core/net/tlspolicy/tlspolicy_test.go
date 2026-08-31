package tlspolicy

import (
	"crypto/tls"
	"net/http"
	"net/http/httptest"
	"testing"
)

// selfSigned 起一台自签名证书的 https 服务器。
func selfSigned(t *testing.T) *httptest.Server {
	t.Helper()
	s := httptest.NewTLSServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		_, _ = w.Write([]byte("ok"))
	}))
	t.Cleanup(s.Close)
	return s
}

func get(c *http.Client, url string) error {
	resp, err := c.Get(url)
	if err != nil {
		return err
	}
	_ = resp.Body.Close()
	return nil
}

// ★ 没勾「允许自签名」时必须**连不上**。连得上说明校验根本没生效。
func TestDefault_没放行时自签名连不上(t *testing.T) {
	Set(nil)
	s := selfSigned(t)
	c := &http.Client{Transport: Transport()}
	if err := get(c, s.URL); err == nil {
		t.Fatal("没放行的自签名服务器居然连上了 —— TLS 校验没生效")
	}
}

// ★ 勾了就要真的能连上。连不上的表现是「我明明勾了允许自签名,还是连不上」。
func TestSet_放行之后连得上(t *testing.T) {
	s := selfSigned(t)
	Set([]string{s.URL})
	defer Set(nil)
	c := &http.Client{Transport: Transport()}
	if err := get(c, s.URL); err != nil {
		t.Fatalf("放行之后仍然连不上: %v", err)
	}
}

// ★★ 安全断言:放行 A **不能**顺带放行 B。
//
// 写成全局 InsecureSkipVerify 的话这条会红 —— 而那个错误的表现是
// 用户为一台自建服勾了个开关,结果**整个应用**的 TLS 校验都没了,
// 更新下载、插件源、图片代理全部跟着不安全,且毫无提示。
func TestSet_放行一台不能连带放行另一台(t *testing.T) {
	a := selfSigned(t)
	b := selfSigned(t)
	Set([]string{a.URL})
	defer Set(nil)
	c := &http.Client{Transport: Transport()}
	if err := get(c, a.URL); err != nil {
		t.Fatalf("放行的那台应当连得上: %v", err)
	}
	if err := get(c, b.URL); err == nil {
		t.Fatal("只放行了 A,B 也连上了 —— 等于全局关掉了 TLS 校验")
	}
}

// ★ 配置里存的是完整 URL,比对时手上只有 host。
//
// 拿 URL 当 key 比对**永远匹配不上** —— 表现是用户勾了却还是连不上,
// 而且开关看上去是生效的(配置里确实存下来了)。
func TestHostOf_从完整URL取host(t *testing.T) {
	for _, tc := range []struct{ in, want string }{
		{"https://a.example:8920", "a.example:8920"},
		{"https://A.Example:8920/", "a.example:8920"},
		{"a.example:8920", "a.example:8920"},
		{"", ""},
	} {
		if got := hostOf(tc.in); got != tc.want {
			t.Fatalf("hostOf(%q) = %q,想要 %q", tc.in, got, tc.want)
		}
	}
}

// ★ http 的请求不该被这套东西影响。
func TestRoundTrip_明文请求不受影响(t *testing.T) {
	Set(nil)
	s := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {}))
	defer s.Close()
	c := &http.Client{Transport: Transport()}
	if err := get(c, s.URL); err != nil {
		t.Fatalf("明文 http 不该受影响: %v", err)
	}
	_ = tls.VersionTLS12
}
