package plugin

// ctx.http 的实现:白名单 + `$sourceServer`,fail-closed。

import (
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"net/url"
	"strings"

	"linplayer/core/httpx"
)

// check 一次请求的准入。
func (s *ctxState) check(scheme, host string) error {
	return CheckRequest(s.allowedHosts, s.grants.Snapshot(), scheme, host)
}

// jsonScalar 把一个 JSON 值拍成 header / query 用的字符串。
func jsonScalar(v any) string {
	switch t := v.(type) {
	case string:
		return t
	case nil:
		return ""
	default:
		b, _ := json.Marshal(t)
		return string(b)
	}
}

func optObj(args []any, i int) map[string]any {
	if i < len(args) {
		if m, ok := args[i].(map[string]any); ok {
			return m
		}
	}
	return nil
}

// httpRequest 执行插件 http 请求。method ∈ get/post/delete。
//
// 参数排布跟黄金实现一致:opts 在 get/delete 是 args[1],在 post 是 args[2]
// (args[1] 是 body)。
func (s *ctxState) httpRequest(method string, args []any) (any, error) {
	if err := s.requirePerm("http"); err != nil {
		return nil, err
	}
	rawURL := argStr(args, 0)
	parsed, err := url.Parse(rawURL)
	if err != nil || parsed.Host == "" {
		return nil, fmt.Errorf("URL 非法: %s", rawURL)
	}
	if err := s.check(parsed.Scheme, parsed.Hostname()); err != nil {
		return nil, err
	}

	var body any
	var opts map[string]any
	if method == "post" {
		if len(args) > 1 {
			body = args[1]
		}
		opts = optObj(args, 2)
	} else {
		opts = optObj(args, 1)
	}
	discard, _ := opts["discardBody"].(bool)

	// query 合并。
	if q, ok := opts["query"].(map[string]any); ok {
		vals := parsed.Query()
		for k, v := range q {
			vals.Set(k, jsonScalar(v))
		}
		parsed.RawQuery = vals.Encode()
	}

	// body(post/delete)。对象/数组 -> JSON;字符串原样。
	if body == nil {
		body = opts["body"]
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
		reader = strings.NewReader(string(b))
		contentType = "application/json"
	}

	var verb string
	switch method {
	case "get":
		verb = http.MethodGet
	case "post":
		verb = http.MethodPost
	case "delete":
		verb = http.MethodDelete
	default:
		return nil, fmt.Errorf("不支持的 http 方法: %s", method)
	}

	req, err := http.NewRequest(verb, parsed.String(), reader)
	if err != nil {
		return nil, fmt.Errorf("构造请求失败: %w", err)
	}
	if contentType != "" {
		req.Header.Set("Content-Type", contentType)
	}
	if h, ok := opts["headers"].(map[string]any); ok {
		for k, v := range h {
			req.Header.Set(k, jsonScalar(v))
		}
	}

	client := httpx.Client()
	resp, err := client.Do(req)
	if err != nil {
		return nil, fmt.Errorf("请求失败: %w", err)
	}
	defer resp.Body.Close()

	/* ★★ 防重定向绕白名单:最终 URL 必须仍能过同一道准入。
	   含协议降级 —— 302 跳去 http:// 的白名单外主机,跟直接请求它是一回事。
	   Go 的 Client 默认会跟随重定向,resp.Request.URL 是**最终**那一个。 */
	final := resp.Request.URL
	if err := s.check(final.Scheme, final.Hostname()); err != nil {
		return nil, fmt.Errorf("请求经重定向后不再被允许: %w", err)
	}

	headers := map[string]any{}
	for k, v := range resp.Header {
		if len(v) > 0 {
			headers[strings.ToLower(k)] = v[0]
		}
	}

	if discard {
		// 按流丢弃,只统计字节数(测速用,内存恒定)。
		n, err := io.Copy(io.Discard, resp.Body)
		if err != nil {
			return nil, fmt.Errorf("读流失败: %w", err)
		}
		return map[string]any{
			"status": float64(resp.StatusCode), "headers": headers, "bytes": float64(n),
		}, nil
	}

	raw, err := io.ReadAll(resp.Body)
	if err != nil {
		return nil, fmt.Errorf("读响应失败: %w", err)
	}
	return map[string]any{
		"status": float64(resp.StatusCode), "headers": headers, "body": decodeBody(string(raw)),
	}, nil
}

// decodeBody 响应体:像 JSON 就解析成对象/数组,否则原样字符串。
func decodeBody(text string) any {
	t := strings.TrimLeft(text, " \t\r\n")
	if strings.HasPrefix(t, "{") || strings.HasPrefix(t, "[") {
		var v any
		if json.Unmarshal([]byte(text), &v) == nil {
			return v
		}
	}
	return text
}
