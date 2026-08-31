package config

// 代理配置。移植自 `crates/core/src/config.rs` 的 `ProxyConfig`。
//
// ★ 默认值不是零值(proxy_media 默认 true),口径同 prefs.go 那份 —— 先造默认再往上盖。

import (
	"encoding/json"
	"net/url"
	"strconv"
	"strings"
)

// ProxyConfig 用户配的出网代理。
type ProxyConfig struct {
	Type     string `json:"type"` // none | http | https | socks5 | socks4
	Host     string `json:"host"`
	Port     int    `json:"port"`
	Username string `json:"username"`
	Password string `json:"password"`
	// ProxyMedia 让媒体流(mpv 播放)也走代理。仅 HTTP 系列有效。
	ProxyMedia bool `json:"proxy_media"`
}

// DefaultProxy 默认:不走代理,但「媒体也走」这个开关默认是**开**的
// —— 用户一旦打开代理,不会想着还要再点一次才让视频也走。
func DefaultProxy() ProxyConfig {
	return ProxyConfig{Type: "none", ProxyMedia: true}
}

// Enabled 配了没有。type 不是 none 且 host / port 都齐才算。
func (p ProxyConfig) Enabled() bool {
	return p.Type != "" && p.Type != "none" && strings.TrimSpace(p.Host) != "" && p.Port > 0
}

// ProxyURL 拼成 Go / reqwest 都认的代理地址;没启用返回空串。
//
// ★ socks4 要拼成 **socks4a** —— 差别是域名由谁来解析。写成 socks4 的话
// 域名在本地解析,而本地解析不了的域名(被污染 / 内网)就直接连不上,
// 表现是「代理明明能用,就是打不开某些站」。
//
// ★ 用户名密码必须 **URL 编码**:密码里一个 `@` 或 `:` 就会把地址切碎,
// 而 url.Parse 不会报错,只会解出一个奇怪的 host。
func (p ProxyConfig) ProxyURL() string {
	if !p.Enabled() {
		return ""
	}
	var scheme string
	switch p.Type {
	case "http", "https":
		scheme = "http"
	case "socks5":
		scheme = "socks5"
	case "socks4":
		scheme = "socks4a"
	default:
		return ""
	}
	auth := ""
	if p.Username != "" {
		auth = url.QueryEscape(p.Username) + ":" + url.QueryEscape(p.Password) + "@"
	}
	return scheme + "://" + auth + p.Host + ":" + strconv.Itoa(p.Port)
}

// ParseProxy 从原始 JSON 解出代理配置。**先造默认再往上盖**(见包内 prefs.go 的说明)。
func ParseProxy(raw json.RawMessage) ProxyConfig {
	p := DefaultProxy()
	if len(raw) == 0 {
		return p
	}
	if json.Unmarshal(raw, &p) != nil {
		return DefaultProxy()
	}
	if p.Type == "" {
		p.Type = "none"
	}
	return p
}

// ProxyConf 当前代理配置。
func (c *AppConfig) ProxyConf() ProxyConfig { return ParseProxy(c.Proxy) }

// SetProxyConf 写回代理配置。
func (c *AppConfig) SetProxyConf(p ProxyConfig) {
	if b, err := json.Marshal(p); err == nil {
		c.Proxy = b
	}
}
