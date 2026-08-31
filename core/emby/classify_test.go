package emby

// 「一直提示没网了,实际上有网络」这条真实故障的护栏(用户 2026-08-31 实测撞上)。

import (
	"crypto/x509"
	"errors"
	"fmt"
	"net/http"
	"strings"
	"testing"

	"linplayer/core/bus"
)

func codeOf(t *testing.T, err error) *bus.Err {
	t.Helper()
	var e *bus.Err
	if !errors.As(err, &e) {
		t.Fatalf("应当是 bus.Err,实得 %T", err)
	}
	return e
}

// ★★ 密码不对必须是 E_AUTH,不能是 E_NETWORK。
//
// 标成 E_NETWORK 的表现是 UI 显示「网络不通,可以重试」——
// 用户明明有网,照着这句话重试一百次也还是进不去。
func TestClassify_密码不对是认证问题不是网络问题(t *testing.T) {
	e := codeOf(t, classify(&StatusError{Status: http.StatusUnauthorized, What: "登录"}))
	if e.Code != bus.EAuth {
		t.Fatalf("401 应当是 %s,实得 %s", bus.EAuth, e.Code)
	}
	// ★ 而且不该标可重试:密码不对时重试是纯浪费,还会把服务器的失败计数刷满
	if e.Retryable {
		t.Fatal("凭据不对不该标成可重试")
	}
}

// ★★ 无论哪一类,真实原因都要带在 Msg 里。
//
// 丢掉 Msg 的表现是 UI 只剩一句笼统的话,用户和开发都看不到到底怎么了。
func TestClassify_真实原因必须带在Msg里(t *testing.T) {
	for _, tc := range []struct {
		name string
		err  error
		want string
	}{
		{"401", &StatusError{Status: 401, What: "登录"}, "401"},
		{"404 要指向地址填错", &StatusError{Status: 404, What: "登录"}, "服务器地址"},
		{"连不上", errors.New("网络错误: dial tcp: connection refused"), "connection refused"},
	} {
		t.Run(tc.name, func(t *testing.T) {
			e := codeOf(t, classify(tc.err))
			if !strings.Contains(e.Msg, tc.want) {
				t.Fatalf("Msg 里应当能看到 %q,实得 %q", tc.want, e.Msg)
			}
		})
	}
}

// ★ 服务器回了 5xx 说明**网络是通的**。标成 E_NETWORK 是误导 ——
// 用户会去查自己的网,而问题在服务器那头。
func TestClassify_服务器回了话就不是网络问题(t *testing.T) {
	e := codeOf(t, classify(&StatusError{Status: 502, What: "取数据"}))
	if e.Code == bus.ENetwork {
		t.Fatal("502 是服务器在说话,网络是通的,不该报成网络不通")
	}
	if !e.Retryable {
		t.Fatal("5xx 应当可重试")
	}
}

// 只有真的连不上才是 E_NETWORK。
func TestClassify_连不上才是网络问题(t *testing.T) {
	e := codeOf(t, classify(errors.New("网络错误: dial tcp 10.0.0.1:8096: i/o timeout")))
	if e.Code != bus.ENetwork {
		t.Fatalf("连不上应当是 %s,实得 %s", bus.ENetwork, e.Code)
	}
}

// ★★ 证书类的错必须**指路**,不能只把 x509 那句英文丢给用户。
//
// 自建 Emby 用自签名证书极常见。用户看到
// 「x509: certificate signed by unknown authority」是不知道该干什么的 ——
// 表现就是「有网,但就是进不去」(用户 2026-08-31 的原话)。
func TestClassify_证书问题要告诉用户去哪儿勾开关(t *testing.T) {
	for _, tc := range []struct {
		name string
		err  error
	}{
		{"自签名", x509.UnknownAuthorityError{}},
		// ★ HostnameError 的 Error() 会读 Certificate —— 不给就 nil 解引用。
		//   夹具不真实的话,测的是「panic 的字符串里没有那句话」,不是真行为。
		{"域名对不上", x509.HostnameError{Host: "a.example", Certificate: &x509.Certificate{}}},
		{"证书过期", x509.CertificateInvalidError{Reason: x509.Expired}},
	} {
		t.Run(tc.name, func(t *testing.T) {
			e := codeOf(t, classify(fmt.Errorf("网络错误: %w", tc.err)))
			if !strings.Contains(e.Msg, "允许这台服务器的自签名证书") {
				t.Fatalf("应当指到那个开关上,实得 %q", e.Msg)
			}
			// ★ 原始英文也要留着 —— 排查时要看它
			if e.Detail == "" || !strings.Contains(e.Detail, "x509") {
				t.Fatalf("原始错误应当留在 Detail 里,实得 %q", e.Detail)
			}
		})
	}
}

// ★ 别把普通网络错也认成证书错。
func TestClassify_普通网络错不该被认成证书问题(t *testing.T) {
	e := codeOf(t, classify(errors.New("网络错误: dial tcp: i/o timeout")))
	if strings.Contains(e.Msg, "自签名") {
		t.Fatalf("超时被认成证书问题了:%q", e.Msg)
	}
}
