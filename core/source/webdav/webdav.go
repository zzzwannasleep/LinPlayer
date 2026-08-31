// Package webdav WebDAV 后端。列目录 = PROPFIND(Depth: 1),
// 播放 = 把同一个 http(s) URL 交给 mpv(mpv 自己会带 Range)。
//
// 移植自 `crates/core/src/source/webdav.rs`。**Rust 版是黄金实现。**
//
// ★ Go 这边用 encoding/xml(标准库),不是 quick-xml。黄金实现里那条
// 「quick-xml 0.41 把 `&amp;` 拆成单独事件」的坑在 Go 这边不存在 ——
// encoding/xml 的 CharData 已经解好实体了。**但别因此以为其它三个坑也没了**,
// 它们和 XML 库无关(href 双前缀 / Depth:1 首条是自己 / 命名空间前缀各家自选)。
package webdav

import (
	"context"
	"encoding/base64"
	"encoding/xml"
	"io"
	"net/http"
	"net/url"
	"strconv"
	"strings"

	"linplayer/core/source"
)

// propfindBody 只问四个属性。
//
// ★ 不用 `<allprop/>`:有的服务端(Nextcloud 尤其)会把一大堆自有属性一起塞回来,
// 响应体大好几倍还更容易解析出岔子。
const propfindBody = `<?xml version="1.0" encoding="utf-8"?>
<d:propfind xmlns:d="DAV:"><d:prop>
<d:displayname/><d:getcontentlength/><d:resourcetype/><d:getcontenttype/>
</d:prop></d:propfind>`

// Backend WebDAV。
type Backend struct{}

// New 造一个。
func New() *Backend { return &Backend{} }

// Kind 源类型。
func (*Backend) Kind() source.Kind { return source.KindWebDAV }

// authHeader `Authorization: Basic`。
//
// ★ WebDAV 没有会话令牌,**每个请求都要重新带** —— 取流那条也一样,
// 所以它必须原样进 ResolvedPlay.HTTPHeaders,否则 mpv 那一路 401。
func authHeader(s *source.Server) string {
	u := ""
	if s.Username != nil {
		u = *s.Username
	}
	if u == "" {
		return "" // 匿名共享(有的 NAS 开放只读匿名)
	}
	p := ""
	if s.Password != nil {
		p = *s.Password
	}
	return "Basic " + base64.StdEncoding.EncodeToString([]byte(u+":"+p))
}

// splitBase 把 base_url 拆成 (origin, 根路径)。
//
// origin = `https://主机:端口`;根路径 = 用户填的地址里带的那截路径
// (Nextcloud 必有:`/remote.php/dav/files/用户名`;群晖也常有)。
func splitBase(baseURL string) (origin, root string) {
	base := source.NormalizeBaseURL(baseURL)
	afterScheme := 0
	if i := strings.Index(base, "://"); i >= 0 {
		afterScheme = i + 3
	}
	j := strings.Index(base[afterScheme:], "/")
	if j < 0 {
		return base, ""
	}
	cut := afterScheme + j
	return base[:cut], strings.TrimRight(base[cut:], "/")
}

// urlFor 把一条**服务端绝对路径**拼成完整 URL。
//
// ★★ 拼的是 **origin**,不是 base_url。entry.ID 来自响应里的 href,而 href
// 是**服务端绝对路径**(已经含了 base_url 里那截前缀)。拿它去接 base_url
// 会拼出 `/dav/dav/剧集` 这种双前缀 —— 根目录能列、点进任何子目录必 404,
// 而且**只在「base_url 带路径」的服务端上犯**(Nextcloud 全中,群晖常中)。
//
// ★ 路径要**逐段**百分号编码,斜杠不能编码。整串 encode 会把 `/` 变成 `%2F`,
// 服务端看到的就成了一个名字里带斜杠的文件,必 404。
func urlFor(baseURL, absPath string) string {
	origin, _ := splitBase(baseURL)
	segs := strings.Split(absPath, "/")
	for i, s := range segs {
		segs[i] = url.PathEscape(s)
	}
	return origin + strings.Join(segs, "/")
}

func propfind(ctx context.Context, c *http.Client, s *source.Server, path string) (string, error) {
	u := urlFor(s.BaseURL, path)
	req, err := http.NewRequestWithContext(ctx, "PROPFIND", u, strings.NewReader(propfindBody))
	if err != nil {
		return "", source.Msg("地址不合法: %v", err)
	}
	req.Header.Set("Depth", "1")
	req.Header.Set("Content-Type", "application/xml; charset=utf-8")
	if a := authHeader(s); a != "" {
		req.Header.Set("Authorization", a)
	}
	resp, err := c.Do(req)
	if err != nil {
		return "", source.Msg("无法连接 WebDAV: %v", err)
	}
	defer resp.Body.Close()
	if resp.StatusCode == http.StatusUnauthorized || resp.StatusCode == http.StatusForbidden {
		return "", source.Auth("WebDAV 账号或密码不对")
	}
	if resp.StatusCode < 200 || resp.StatusCode >= 300 {
		hint := ""
		// 405 = 这个地址不支持 PROPFIND,基本都是把普通 http 服务当 WebDAV 填了。
		if resp.StatusCode == http.StatusMethodNotAllowed {
			hint = "(这个地址不支持 PROPFIND,可能不是 WebDAV 服务)"
		}
		return "", source.Msg("WebDAV 返回 %d%s", resp.StatusCode, hint)
	}
	b, err := io.ReadAll(resp.Body)
	if err != nil {
		return "", source.Msg("读取 WebDAV 响应失败: %v", err)
	}
	return string(b), nil
}

// parse 解析 207 multistatus。
//
// ★★ **不能按 `d:response` 这种带前缀的字面量匹配。** 命名空间前缀是各家自选的:
// Apache 用 `D:`,Nextcloud 用 `d:`,还有服务端把 DAV: 设成默认命名空间、
// 压根不带前缀。encoding/xml 的 Decoder 给的 Name.Local 已经**剥掉前缀**了,
// 按 Local 匹配就对所有家都成立。
func parse(xmlText, basePath string) ([]source.Entry, error) {
	dec := xml.NewDecoder(strings.NewReader(xmlText))
	// ★ 有的服务端会发非 UTF-8 或带 BOM 的响应;宽松一点,别为一个字符整页列不出来
	dec.Strict = false

	var (
		out            []source.Entry
		cur            string // 当前所在的叶子元素名(Local)
		href, disp     string
		length         int64
		isDir          bool
		inResponse     bool
		inResourceType bool
	)
	reset := func() {
		href, disp, length, isDir = "", "", 0, false
	}
	for {
		tok, err := dec.Token()
		if err == io.EOF {
			break
		}
		if err != nil {
			return nil, source.Msg("WebDAV 响应不是合法 XML: %v", err)
		}
		switch t := tok.(type) {
		case xml.StartElement:
			cur = t.Name.Local
			switch cur {
			case "response":
				inResponse = true
				reset()
			case "resourcetype":
				inResourceType = true
			case "collection":
				// ★ 判目录看的是 <collection/> 在不在 <resourcetype> 里,
				//   不是看 href 有没有尾斜杠 —— 有的服务端两者都不给尾斜杠。
				if inResourceType {
					isDir = true
				}
			}
		case xml.CharData:
			v := strings.TrimSpace(string(t))
			if v == "" {
				break
			}
			switch cur {
			case "href":
				href += v
			case "displayname":
				disp += v
			case "getcontentlength":
				if n, err := strconv.ParseInt(v, 10, 64); err == nil {
					length = n
				}
			}
		case xml.EndElement:
			switch t.Name.Local {
			case "resourcetype":
				inResourceType = false
			case "response":
				if inResponse {
					if e := entryOf(strings.TrimSpace(href), strings.TrimSpace(disp), length, isDir, basePath); e != nil {
						out = append(out, *e)
					}
					inResponse = false
				}
			}
			cur = ""
		}
	}
	source.SortEntries(out)
	return out, nil
}

// entryOf 把一条 response 变成一行。返回 nil 表示这条要丢掉。
func entryOf(href, disp string, length int64, isDir bool, basePath string) *source.Entry {
	if href == "" {
		return nil
	}
	// href 可能是绝对 URL(http://host/dav/a)也可能是绝对路径(/dav/a),两种都合法。
	path := href
	if i := strings.Index(href, "://"); i >= 0 {
		rest := href[i+3:]
		if j := strings.Index(rest, "/"); j >= 0 {
			path = rest[j:]
		} else {
			path = "/"
		}
	}
	// href 是百分号编码的,要解回真实路径才能当下一次 PROPFIND 的入参。
	if d, err := url.PathUnescape(path); err == nil {
		path = d
	}
	trimmed := strings.TrimRight(path, "/")

	// ★★ Depth:1 的响应**第一条永远是被请求的目录自己**。不剔掉的话点进任何目录
	//    都会看到一个指向自己的条目,一路点下去无限套娃。
	if trimmed == strings.TrimRight(basePath, "/") {
		return nil
	}

	name := disp
	if name == "" {
		if i := strings.LastIndex(trimmed, "/"); i >= 0 {
			name = trimmed[i+1:]
		} else {
			name = trimmed
		}
	}
	if name == "" {
		return nil
	}
	id := trimmed
	if isDir {
		id = trimmed + "/"
	}
	e := source.Entry{ID: id, Name: name, IsDir: isDir}
	if !isDir {
		e.IsVideo = source.IsVideoFileName(name)
		if length > 0 {
			n := length
			e.Size = &n
		}
	}
	return &e
}

// ListDir 列目录。
func (b *Backend) ListDir(ctx context.Context, c *http.Client, s *source.Server, dirID string) ([]source.Entry, error) {
	/* 一律用**服务端绝对路径**当 dirID —— 响应里的 href 就是这个口径,
	   两边统一才不用来回换算。根目录 = base_url 里带的那截路径(没带就是 `/`)。 */
	path := dirID
	if path == "" {
		if _, root := splitBase(s.BaseURL); root != "" {
			path = root
		} else {
			path = "/"
		}
	}
	xmlText, err := propfind(ctx, c, s, path)
	if err != nil {
		return nil, err
	}
	return parse(xmlText, path)
}

// ResolvePlay 播放:同一个 URL 交给 mpv,Authorization 原样带上。
func (b *Backend) ResolvePlay(ctx context.Context, _ *http.Client, s *source.Server,
	e *source.Entry, _ string) (*source.ResolvedPlay, error) {
	headers := map[string]string{}
	if a := authHeader(s); a != "" {
		headers["Authorization"] = a
	}
	r := source.Simple(urlFor(s.BaseURL, e.ID), e.Name, headers)
	return &r, nil
}
