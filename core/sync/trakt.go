package sync

// Trakt:设备码登录 / 刷新 / scrobble / 放送表。
//
// 移植自 `crates/core/src/sync/trakt.rs`。
//
// ★ 所有需要 client_secret 的那几步(换 token / 刷新)都经**自建代理**,
// 客户端不持有 secret。代理地址与共享密钥是编译期注入的(见 sync.go 顶部)。

import (
	"context"
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"strings"

	"linplayer/core/httpx"
)

// TraktDeviceCode 设备码流程第一步的返回。
type TraktDeviceCode struct {
	DeviceCode      string `json:"device_code"`
	UserCode        string `json:"user_code"`
	VerificationURL string `json:"verification_url"`
	Interval        int64  `json:"interval"`
	ExpiresIn       int64  `json:"expires_in"`
}

// TraktPollResult 轮询一次的结果。
//
// state:pending | slowDown | authorized | expired | denied | error
type TraktPollResult struct {
	State   string   `json:"state"`
	Account *Account `json:"account"`
}

func traktAPIHeaders(access string) map[string]string {
	return map[string]string{
		"Authorization":     "Bearer " + access,
		"trakt-api-version": "2",
		"trakt-api-key":     TraktClientID(),
	}
}

// postProxy 往自建代理发一条 JSON 请求。
func postProxy(ctx context.Context, path string, body any) (int, []byte, error) {
	if !UseProxy() {
		return 0, nil, fmt.Errorf("这个构建没有配同步服务(需要在构建环境里提供 LP_SYNC_PROXY_BASE)")
	}
	var rd *strings.Reader
	if body != nil {
		b, err := json.Marshal(body)
		if err != nil {
			return 0, nil, err
		}
		rd = strings.NewReader(string(b))
	} else {
		rd = strings.NewReader("")
	}
	req, err := http.NewRequestWithContext(ctx, http.MethodPost, ProxyBase()+path, rd)
	if err != nil {
		return 0, nil, err
	}
	req.Header.Set("Content-Type", "application/json")
	for k, v := range ProxyHeaders() {
		req.Header.Set(k, v)
	}
	resp, err := httpx.Client().Do(req)
	if err != nil {
		return 0, nil, err
	}
	defer resp.Body.Close()
	b, _ := readAll(resp)
	return resp.StatusCode, b, nil
}

// TraktRequestDeviceCode 第一步:申请设备码(走代理)。
func TraktRequestDeviceCode(ctx context.Context) (*TraktDeviceCode, error) {
	code, b, err := postProxy(ctx, "/trakt/device", nil)
	if err != nil {
		return nil, err
	}
	if code < 200 || code >= 300 {
		return nil, fmt.Errorf("Trakt 申请设备码失败: HTTP %d", code)
	}
	var j map[string]any
	if json.Unmarshal(b, &j) != nil {
		return nil, fmt.Errorf("Trakt 返回的不是 JSON")
	}
	return &TraktDeviceCode{
		DeviceCode:      jstr(j, "device_code"),
		UserCode:        jstr(j, "user_code"),
		VerificationURL: jstr(j, "verification_url"),
		Interval:        jint(j, "interval", 5),
		ExpiresIn:       jint(j, "expires_in", 600),
	}, nil
}

// TraktPollOnce 第二步:轮询一次(走代理)。
//
// ★ 状态码语义**照 Trakt 设备码流程原样**:400 是「还没授权」不是错误,
// 429 是「问太快了」。把它们一律当失败的话,用户还没来得及点授权就被告知失败。
func TraktPollOnce(ctx context.Context, deviceCode string) TraktPollResult {
	none := func(s string) TraktPollResult { return TraktPollResult{State: s} }
	code, b, err := postProxy(ctx, "/trakt/token", map[string]string{"device_code": deviceCode})
	if err != nil {
		return none("error")
	}
	switch {
	case code == 200:
		var tok map[string]any
		if json.Unmarshal(b, &tok) != nil {
			return none("error")
		}
		acc := traktAccountFromToken(ctx, tok, nil)
		return TraktPollResult{State: "authorized", Account: acc}
	case code == 400:
		return none("pending") // 仍在等待授权
	case code == 429:
		return none("slowDown") // 轮询过快
	case code == 404 || code == 410 || code == 409:
		return none("expired")
	case code == 418:
		return none("denied")
	}
	return none("error")
}

// TraktRefresh 用 refresh_token 换新令牌(走代理)。失败返回 nil(通常要重登)。
func TraktRefresh(ctx context.Context, a *Account) *Account {
	if a == nil || a.RefreshToken == nil || *a.RefreshToken == "" {
		return nil
	}
	code, b, err := postProxy(ctx, "/trakt/refresh", map[string]string{"refresh_token": *a.RefreshToken})
	if err != nil || code < 200 || code >= 300 {
		return nil
	}
	var tok map[string]any
	if json.Unmarshal(b, &tok) != nil {
		return nil
	}
	return traktAccountFromToken(ctx, tok, a)
}

// TraktEnsureValid 确保令牌有效:过期就刷新。返回可用账号或 nil。
func TraktEnsureValid(ctx context.Context, a *Account) *Account {
	if a == nil {
		return nil
	}
	if !a.IsExpired(NowMs()) {
		return a
	}
	fresh := TraktRefresh(ctx, a)
	if fresh != nil {
		_ = Save("trakt", fresh) // ★ 刷出来的新令牌要落盘,否则每次启动都要刷一遍
	}
	return fresh
}

func traktAccountFromToken(ctx context.Context, tok map[string]any, fallback *Account) *Account {
	access := jstr(tok, "access_token")
	if access == "" && fallback != nil {
		access = fallback.AccessToken
	}
	a := &Account{Service: "trakt", AccessToken: access}
	if rt := jstr(tok, "refresh_token"); rt != "" {
		a.RefreshToken = &rt
	} else if fallback != nil {
		a.RefreshToken = fallback.RefreshToken
	}
	// ★ Trakt 给的是 created_at + expires_in(秒),要自己算出绝对时刻。
	//   只记 expires_in 的话,重启之后就不知道还剩多久了。
	createdAt, hasCreated := tok["created_at"].(float64)
	expiresIn, hasExpires := tok["expires_in"].(float64)
	switch {
	case hasCreated && hasExpires:
		v := int64(createdAt+expiresIn) * 1000
		a.ExpiresAt = &v
	case hasExpires:
		v := NowMs() + int64(expiresIn)*1000
		a.ExpiresAt = &v
	case fallback != nil:
		a.ExpiresAt = fallback.ExpiresAt
	}
	// 顺手拉一次用户名,设置页要显示「已连接 @xxx」
	if u := traktMe(ctx, access); u != "" {
		a.Username = &u
	} else if fallback != nil {
		a.Username = fallback.Username
	}
	return a
}

func traktMe(ctx context.Context, access string) string {
	if access == "" {
		return ""
	}
	b, code, err := httpx.GetJSON(ctx, httpx.Client(), TraktAPI+"/users/me", toHeader(traktAPIHeaders(access)))
	if err != nil || code != 200 {
		return ""
	}
	var j map[string]any
	if json.Unmarshal(b, &j) != nil {
		return ""
	}
	return jstr(j, "username")
}

// TraktScrobble 上报播放状态。action = start | pause | stop。
//
// ★ 失败**不抛**,只返回 false:上报是记账,播放是主线。
// 把上报失败弹给用户,只会在网断的时候不停打断看片。
func TraktScrobble(ctx context.Context, a *Account, kind string, ids json.RawMessage, progress float64, action string) bool {
	valid := TraktEnsureValid(ctx, a)
	if valid == nil {
		return false
	}
	body := map[string]any{"progress": progress}
	var idObj any
	_ = json.Unmarshal(ids, &idObj)
	if kind == "episode" {
		body["episode"] = map[string]any{"ids": idObj}
	} else {
		body["movie"] = map[string]any{"ids": idObj}
	}
	b, _ := json.Marshal(body)
	req, err := http.NewRequestWithContext(ctx, http.MethodPost,
		TraktAPI+"/scrobble/"+action, strings.NewReader(string(b)))
	if err != nil {
		return false
	}
	req.Header.Set("Content-Type", "application/json")
	for k, v := range traktAPIHeaders(valid.AccessToken) {
		req.Header.Set(k, v)
	}
	resp, err := httpx.Client().Do(req)
	if err != nil {
		return false
	}
	defer resp.Body.Close()
	return resp.StatusCode >= 200 && resp.StatusCode < 300
}

// TraktCalendar 放送表。
//
// ★ onlyMine=false 走 `/calendars/all`,那是**全站火喉** —— 必须截断,
// 否则一次拉回来几千条,前端画到卡死。
func TraktCalendar(ctx context.Context, a *Account, startOffsetDays, days int64, onlyMine bool) []CalendarEntry {
	out := []CalendarEntry{}
	valid := TraktEnsureValid(ctx, a)
	if valid == nil {
		return out
	}
	const allCap = 200
	scope := "all"
	if onlyMine {
		scope = "my"
	}
	u := fmt.Sprintf("%s/calendars/%s/shows/%s/%d", TraktAPI, scope, DateStrDaysAgo(startOffsetDays), days)
	b, code, err := httpx.GetJSON(ctx, httpx.Client(), u, toHeader(traktAPIHeaders(valid.AccessToken)))
	if err != nil || code < 200 || code >= 300 {
		return out
	}
	var list []map[string]any
	if json.Unmarshal(b, &list) != nil {
		return out
	}
	for _, raw := range list {
		if !onlyMine && len(out) >= allCap {
			break
		}
		show, _ := raw["show"].(map[string]any)
		if show == nil {
			continue
		}
		title := jstr(show, "title")
		if title == "" {
			title = "未知剧集"
		}
		e := CalendarEntry{Title: title, Source: "trakt"}
		if ids, _ := show["ids"].(map[string]any); ids != nil {
			if v, ok := ids["tmdb"].(float64); ok {
				id := int64(v)
				e.TMDBID = &id
			}
		}
		if ad := jstr(raw, "first_aired"); ad != "" {
			e.AirDate = &ad
		}
		// 副标题 = SxxExx · 集名。两截各自可能没有,拼出来是空就不给。
		if ep, _ := raw["episode"].(map[string]any); ep != nil {
			var parts []string
			s, hasS := ep["season"].(float64)
			n, hasN := ep["number"].(float64)
			if hasS && hasN {
				parts = append(parts, fmt.Sprintf("S%02dE%02d", int(s), int(n)))
			}
			if t := jstr(ep, "title"); t != "" {
				parts = append(parts, t)
			}
			if len(parts) > 0 {
				sub := strings.Join(parts, " · ")
				e.Subtitle = &sub
			}
		}
		out = append(out, e)
	}
	return out
}

// ---------- 小工具 ----------

func jstr(m map[string]any, k string) string {
	if v, ok := m[k].(string); ok {
		return v
	}
	return ""
}

func jint(m map[string]any, k string, def int64) int64 {
	if v, ok := m[k].(float64); ok {
		return int64(v)
	}
	return def
}

func toHeader(m map[string]string) http.Header {
	h := http.Header{}
	for k, v := range m {
		h.Set(k, v)
	}
	return h
}

// readAll 读响应体,**封顶 4MB**。代理不该回大响应,回了就是出事了 ——
// 不封顶的话一个坏掉的上游能把内存吃干。
func readAll(resp *http.Response) ([]byte, error) {
	return io.ReadAll(io.LimitReader(resp.Body, 4<<20))
}
