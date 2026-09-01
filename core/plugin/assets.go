package plugin

// `lpplugin://` 静态资源解析:iframe 逃生舱和插件图标从这里读文件。
//
// **为什么逃生舱不能直接把插件界面塞进宿主窗口**:宿主窗口的上下文里有命令通道 ——
// 插件代码进去就等于拿到宿主全部命令,整套权限模型直接变成摆设。
// 所以逃生舱必须是独立 origin 的 iframe,而独立 origin 就需要这个协议来喂文件。

import (
	"errors"
	"os"
	"path/filepath"
	"strings"
)

// 解析失败的原因。分开是因为宿主要按类型回不同 HTTP 状态码。
var (
	// ErrAssetNotEnabled 插件不存在或未启用。
	ErrAssetNotEnabled = errors.New("插件未启用")
	// ErrAssetForbidden 路径越界 / 非法。
	ErrAssetForbidden = errors.New("路径非法")
	// ErrAssetNotFound 文件不存在。
	ErrAssetNotFound = errors.New("文件不存在")
)

// ResolveAsset 把 lpplugin:// 的请求路径解析成插件目录内的真实文件路径。
//
// rel 是 URL 里插件 id 之后的部分。三道防线:
//  1. 逐段检查:.. / 根组件 / 盘符前缀一律拒(在字符串层就挡掉);
//  2. 规范化后必须仍以插件目录为前缀;
//  3. 必须是文件、且真实存在。
func ResolveAsset(pluginDir, rel string) (string, error) {
	rel = strings.TrimLeft(rel, "/")
	if rel == "" {
		return "", ErrAssetForbidden
	}
	// URL 里可能带 query/fragment,先切掉。
	if i := strings.IndexAny(rel, "?#"); i >= 0 {
		rel = rel[:i]
	}
	// ★ 百分号解码后**再**检查 —— 否则 %2e%2e%2f 能绕过下面的逐段检查。
	decoded := percentDecode(rel)
	if decoded == "" {
		return "", ErrAssetForbidden
	}

	// 逐段检查。Windows 上反斜杠也是分隔符,统一成 / 再切。
	for _, seg := range strings.Split(strings.ReplaceAll(decoded, "\\", "/"), "/") {
		if seg == "" || seg == "." || seg == ".." {
			return "", ErrAssetForbidden
		}
		// 盘符前缀(C:)也拒。
		if strings.Contains(seg, ":") {
			return "", ErrAssetForbidden
		}
	}

	joined := filepath.Join(pluginDir, filepath.FromSlash(decoded))

	real, err := filepath.EvalSymlinks(joined)
	if err != nil {
		return "", ErrAssetNotFound
	}
	root, err := filepath.EvalSymlinks(pluginDir)
	if err != nil {
		return "", ErrAssetNotEnabled
	}
	// ★ 比的是「root + 分隔符」前缀,不是裸前缀 ——
	//   裸前缀会让 <root>-evil/ 这种同级目录通过。
	if real != root && !strings.HasPrefix(real, root+string(filepath.Separator)) {
		return "", ErrAssetForbidden
	}
	st, err := os.Stat(real)
	if err != nil || st.IsDir() {
		return "", ErrAssetNotFound
	}
	return real, nil
}

// percentDecode 最小百分号解码。只为把 %2e%2e 这类编码还原出来交给逐段检查 ——
// 不追求完整 URL 语义。非法转义原样保留(保留比吞掉安全:留着会被判非法,
// 吞掉可能拼出合法路径)。
func percentDecode(s string) string {
	b := []byte(s)
	out := make([]byte, 0, len(b))
	for i := 0; i < len(b); {
		if b[i] == '%' && i+2 < len(b) {
			hi, ok1 := hexVal(b[i+1])
			lo, ok2 := hexVal(b[i+2])
			if ok1 && ok2 {
				out = append(out, hi<<4|lo)
				i += 3
				continue
			}
		}
		out = append(out, b[i])
		i++
	}
	return string(out)
}

func hexVal(c byte) (byte, bool) {
	switch {
	case c >= '0' && c <= '9':
		return c - '0', true
	case c >= 'a' && c <= 'f':
		return c - 'a' + 10, true
	case c >= 'A' && c <= 'F':
		return c - 'A' + 10, true
	}
	return 0, false
}

// ContentTypeFor 按扩展名给个 Content-Type。
//
// 认不出一律 octet-stream —— **不猜**:猜错成 text/html 会把任意文件变成可执行页面。
func ContentTypeFor(path string) string {
	switch strings.ToLower(strings.TrimPrefix(filepath.Ext(path), ".")) {
	case "html", "htm":
		return "text/html; charset=utf-8"
	case "js", "mjs":
		return "text/javascript; charset=utf-8"
	case "css":
		return "text/css; charset=utf-8"
	case "json":
		return "application/json; charset=utf-8"
	case "svg":
		return "image/svg+xml"
	case "png":
		return "image/png"
	case "jpg", "jpeg":
		return "image/jpeg"
	case "webp":
		return "image/webp"
	case "gif":
		return "image/gif"
	case "woff2":
		return "font/woff2"
	case "woff":
		return "font/woff"
	case "txt", "md":
		return "text/plain; charset=utf-8"
	}
	return "application/octet-stream"
}
