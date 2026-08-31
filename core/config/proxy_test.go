package config

import (
	"encoding/json"
	"strings"
	"testing"
)

// ★★ socks4 必须拼成 **socks4a**。
//
// 差别是域名由谁解析:socks4 在本地解析,而本地解析不了的域名(被污染 / 内网)
// 就直接连不上 —— 表现是「代理明明能用,就是打不开某些站」。
func TestProxyURL_scheme映射(t *testing.T) {
	cases := map[string]string{
		"http":   "http://h:1080",
		"https":  "http://h:1080", // https 代理也是 http 隧道
		"socks5": "socks5://h:1080",
		"socks4": "socks4a://h:1080",
	}
	for typ, want := range cases {
		p := ProxyConfig{Type: typ, Host: "h", Port: 1080}
		if got := p.ProxyURL(); got != want {
			t.Fatalf("type=%s 拼出 %q,想要 %q", typ, got, want)
		}
	}
	if got := (ProxyConfig{Type: "什么鬼", Host: "h", Port: 1}).ProxyURL(); got != "" {
		t.Fatalf("不认识的类型应当返回空串(= 不走代理),实得 %q", got)
	}
}

// ★★ 用户名密码必须 **URL 编码**。
//
// 密码里一个 `@` 或 `:` 就会把地址切碎,而 url.Parse **不报错**,
// 只会解出一个奇怪的 host —— 表现是「代理密码里带特殊字符就连不上」。
func TestProxyURL_凭据要编码(t *testing.T) {
	p := ProxyConfig{Type: "http", Host: "h", Port: 8080, Username: "u@x", Password: "p:w@rd"}
	got := p.ProxyURL()
	if strings.Count(got, "@") != 1 {
		t.Fatalf("凭据没编码,地址被切碎了: %s", got)
	}
	if !strings.HasSuffix(got, "@h:8080") {
		t.Fatalf("host:port 不在末尾: %s", got)
	}
	if strings.Contains(got, "p:w@rd") {
		t.Fatalf("密码原样出现在地址里,没编码: %s", got)
	}
}

// ★ 只填了类型没填 host/port,等于**没配** —— 别拼出一个连不上的地址。
func TestProxyEnabled_缺host或port不算启用(t *testing.T) {
	for _, p := range []ProxyConfig{
		{Type: "socks5", Port: 1080},           // 没 host
		{Type: "socks5", Host: "h"},            // 没 port
		{Type: "none", Host: "h", Port: 1080},  // 关着
		{Type: "", Host: "h", Port: 1080},      // 空类型
		{Type: "socks5", Host: "  ", Port: 10}, // 全空白
	} {
		if p.Enabled() {
			t.Fatalf("%+v 不该算启用", p)
		}
		if u := p.ProxyURL(); u != "" {
			t.Fatalf("%+v 拼出了地址 %q", p, u)
		}
	}
}

// ★★ 默认值**不是零值**:proxy_media 默认是 true。
//
// 这是本仓库最常见的移植坑(见 prefs.go 的包注释):Go 的 json.Unmarshal
// 缺字段一律零值,直接解进空结构体的话,老用户升级后「视频不走代理了」。
func TestParseProxy_缺字段拿默认值不是零值(t *testing.T) {
	p := ParseProxy(json.RawMessage(`{"type":"socks5","host":"h","port":1080}`))
	if !p.ProxyMedia {
		t.Fatal("proxy_media 缺省应当是 true —— 用户开了代理不会想着还要再点一次才让视频也走")
	}
	if p.Type != "socks5" || p.Host != "h" || p.Port != 1080 {
		t.Fatalf("给了的字段没解对: %+v", p)
	}

	// 显式给 false 要能盖住默认值,不能被「先造默认」吃掉
	p2 := ParseProxy(json.RawMessage(`{"type":"http","host":"h","port":1,"proxy_media":false}`))
	if p2.ProxyMedia {
		t.Fatal("显式的 false 被默认值盖掉了 —— 那用户就永远关不掉这个开关")
	}
}

// ★ 空 / 坏 JSON 都退回默认,不能 panic(它在 lp_init 早期被调到)。
func TestParseProxy_空或坏都退回默认(t *testing.T) {
	for _, raw := range []string{"", "null", "不是JSON", "[]"} {
		p := ParseProxy(json.RawMessage(raw))
		if p.Enabled() {
			t.Fatalf("坏输入 %q 解出了一个启用的代理: %+v", raw, p)
		}
		if !p.ProxyMedia {
			t.Fatalf("坏输入 %q 之后 proxy_media 不是默认值", raw)
		}
	}
}

// ★ 往返:存下去再读回来不变形。
func TestProxy往返一致(t *testing.T) {
	c := &AppConfig{}
	in := ProxyConfig{Type: "socks5", Host: "h", Port: 1080, Username: "u", Password: "p", ProxyMedia: false}
	c.SetProxyConf(in)
	if got := c.ProxyConf(); got != in {
		t.Fatalf("往返变形了:\n存 %+v\n取 %+v", in, got)
	}
}
