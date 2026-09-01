package plugin

// 插件出网的准入判定。**整个网络边界就这两个函数**,所以它们是自由函数、
// 不依赖引擎句柄 —— 这样穿透测试写得出来(要构造整个引擎才测得了的边界,没人会写)。

import (
	"fmt"
	"net/url"
	"strings"
)

// SourceHostGrant `$sourceServer` 令牌展开出来的一条放行:**用户在「添加服务器」
// 里亲手填的**那个地址。
//
// AllowHTTP 跟着用户填的协议走 —— 自建 OpenList / 飞牛绝大多数是局域网
// http://<内网地址>:5244,一律强制 https 等于开箱即拒。
// 但明文只对**用户自己输入过的** origin 放行,manifest 里硬编码的域名仍然 https-only。
type SourceHostGrant struct {
	// Host 小写 host(不含端口 —— 白名单一贯按 host 匹配,端口不参与)。
	Host      string
	AllowHTTP bool
}

// GrantFromBaseURL 从用户填的 base_url 解析。解析不出 host 就返回 false(不放行任何东西)。
func GrantFromBaseURL(baseURL string) (SourceHostGrant, bool) {
	u, err := url.Parse(strings.TrimSpace(baseURL))
	if err != nil || u.Hostname() == "" {
		return SourceHostGrant{}, false
	}
	return SourceHostGrant{Host: strings.ToLower(u.Hostname()), AllowHTTP: u.Scheme == "http"}, true
}

// hostAllowed host 是否命中 manifest 里**硬编码**的白名单条目。
//
// 除精确匹配外支持 `*.example.com` 形式的子域通配(线路节点这类由服务端动态分配、
// 事先枚举不全的域名靠它)。`$` 开头的条目是运行时令牌,不在这里参与匹配。
func hostAllowed(allowed []string, host string) bool {
	h := strings.ToLower(host)
	for _, raw := range allowed {
		if strings.HasPrefix(raw, "$") {
			continue
		}
		entry := strings.ToLower(raw)
		if entry == h {
			return true
		}
		// 只认 "*." 开头:裸 "*" 会让 suffix 为空、HasSuffix 恒真,
		// 一个字符就把 fail-closed 击穿成放行全网。
		if suffix, ok := strings.CutPrefix(entry, "*"); ok && strings.HasPrefix(suffix, ".") {
			// 要求点分隔,防 evil-example.com 命中。
			if len(h) > len(suffix) && strings.HasSuffix(h, suffix) {
				return true
			}
		}
	}
	return false
}

// CheckRequest 一次插件出网请求的准入判定。
//
// 规则:
//  1. host 必须命中 manifest 硬编码白名单,**或**(白名单声明了 $sourceServer 时)
//     命中用户亲手配置的源 origin;
//  2. https 一律放行;http **只对用户自己填过 http:// 的那个 origin** 放行。
//
// 边界仍是 fail-closed:放行的只有「用户亲手输入过的地址」和「作者事先声明的域名」。
func CheckRequest(allowed []string, grants []SourceHostGrant, scheme, host string) error {
	h := strings.ToLower(host)
	tokenDeclared := inList(allowed, TokenSourceServer)

	var grant *SourceHostGrant
	if tokenDeclared {
		for i := range grants {
			if grants[i].Host == h {
				grant = &grants[i]
				break
			}
		}
	}

	if !hostAllowed(allowed, h) && grant == nil {
		return fmt.Errorf("域名不在白名单内: %s", host)
	}
	switch scheme {
	case "https":
		return nil
	case "http":
		if grant != nil && grant.AllowHTTP {
			return nil
		}
		return fmt.Errorf("仅允许 HTTPS 请求(明文 http 只对你自己填写的源服务器地址开放): %s", host)
	default:
		return fmt.Errorf("不支持的协议: %s", scheme)
	}
}

// CheckFetchURL registry / 插件包的 URL 准入。
//
// 明文 http **只对本机放行** —— registry 决定「装什么包」、包本身就是要执行的代码,
// 在不可信网络上被中间人改一行就等于任意插件安装。本机例外是给插件作者试自己的源用的。
func CheckFetchURL(raw string) error {
	u, err := url.Parse(strings.TrimSpace(raw))
	if err != nil || u.Host == "" {
		return fmt.Errorf("地址非法: %s", raw)
	}
	switch u.Scheme {
	case "https":
		return nil
	case "http":
		// ★ 靠**子串**判 loopback 会被 http://127.0.0.1.evil.com/ 骗过去,
		//   所以这里比的是解析出来的 Hostname 全等。
		switch u.Hostname() {
		case "localhost", "127.0.0.1", "::1":
			return nil
		}
		return fmt.Errorf("插件源必须是 https(明文 http 只对本机开放)——" +
			"registry 决定装哪个包,被中途改一行就等于任意插件安装")
	default:
		return fmt.Errorf("不支持的协议: %s", u.Scheme)
	}
}
