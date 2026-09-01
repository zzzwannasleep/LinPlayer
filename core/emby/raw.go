package emby

// 以当前登录身份发一条任意 Emby API 请求。
//
// 只有插件的 `ctx.emby.apiRequest` 用它 —— 那是 `emby.api` 这条**危险权限**的
// 全部内容(授权弹窗原话:「以当前登录身份向 Emby 服务器发起任意 API 请求」)。

import (
	"bytes"
	"context"
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"strings"
)

// RawResponse 一次原始请求的结果。
type RawResponse struct {
	Status int    `json:"status"`
	Body   any    `json:"body"`
	Text   string `json:"text,omitempty"`
}

// RawRequest 发一条任意 API 请求。
//
// path 是**服务器根之下**的路径(如 `/Users/xxx/Items`)。
//
// ★★ path 必须是相对路径,绝对 URL 一律拒。放行绝对 URL 等于让插件拿着用户的
// Emby token 往任意主机发请求 —— 那是把「访问你的 Emby」偷换成「拿你的令牌去
// 访问任何地方」,而授权弹窗上写的是前者。
func (c *Client) RawRequest(ctx context.Context, s *Session, method, path string, body any) (*RawResponse, error) {
	method = strings.ToUpper(strings.TrimSpace(method))
	if method == "" {
		method = http.MethodGet
	}
	switch method {
	case http.MethodGet, http.MethodPost, http.MethodDelete, http.MethodPut:
	default:
		return nil, fmt.Errorf("不支持的方法: %s", method)
	}

	path = strings.TrimSpace(path)
	if path == "" {
		return nil, fmt.Errorf("缺少请求路径")
	}
	lowered := strings.ToLower(path)
	if strings.Contains(lowered, "://") || strings.HasPrefix(path, "//") {
		return nil, fmt.Errorf("只能填服务器根之下的相对路径,不能是完整地址: %s", path)
	}
	if !strings.HasPrefix(path, "/") {
		path = "/" + path
	}

	var reader io.Reader
	contentType := ""
	switch t := body.(type) {
	case nil:
	case string:
		reader = strings.NewReader(t)
	default:
		b, err := json.Marshal(t)
		if err != nil {
			return nil, fmt.Errorf("请求体序列化失败: %w", err)
		}
		reader = bytes.NewReader(b)
		contentType = "application/json"
	}

	req, err := http.NewRequestWithContext(ctx, method, s.Server+path, reader)
	if err != nil {
		return nil, fmt.Errorf("请求构造失败: %w", err)
	}
	req.Header.Set("X-Emby-Token", s.Token)
	req.Header.Set("X-Emby-Authorization", c.authHeader(s.DeviceID))
	req.Header.Set("User-Agent", c.UA)
	if contentType != "" {
		req.Header.Set("Content-Type", contentType)
	}

	resp, err := c.HTTP.Do(req)
	if err != nil {
		return nil, fmt.Errorf("网络错误: %w", err)
	}
	defer resp.Body.Close()
	raw, err := io.ReadAll(resp.Body)
	if err != nil {
		return nil, fmt.Errorf("读响应失败: %w", err)
	}
	out := &RawResponse{Status: resp.StatusCode}
	trimmed := strings.TrimLeft(string(raw), " \t\r\n")
	if strings.HasPrefix(trimmed, "{") || strings.HasPrefix(trimmed, "[") {
		var v any
		if json.Unmarshal(raw, &v) == nil {
			out.Body = v
			return out, nil
		}
	}
	out.Text = string(raw)
	return out, nil
}
