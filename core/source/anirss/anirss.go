// Package anirss Ani-RSS(wushuo894/ani-rss)源。
//
// 移植自 `crates/core/src/source/anirss.rs` 的**媒体源那一半**。
//
// ## 范围:只做播放,不做管理台(TODO C24,用户 2026-08-31 拍板)
//
// 负责人原话:「Ani-RSS 我们只对接播放功能」。于是它从「媒体源 + 远程管理台」
// 变成**只是一个媒体源** —— 51 条 `anirss.*` 管理命令(增删改订阅 / 改服务端
// 125 项设置 / 下载进度 / 日志)**不移植**。
//
// 做成源就白拿:文件浏览页、面包屑、播放链路、服务器列表里的一条、重启免登。
//
// ## 只需上游三个端点里的三个(getSubtitles 那个不要)
//
//	POST /api/login    {username, password=MD5} → data = token
//	POST /api/listAni  → 番剧表(周表,要展平去重)
//	POST /api/playList  body = Ani → PlayItem[]
//	GET  /api/file?filename=<base64>&s=<token> → 字节流,支持 Range
//
// `/api/getSubtitles` **不要**:只支持 mkv,而且给的是 VTT 文本不是 URL ——
// 我们交给 mpv 播,内封字幕 mpv 自己读。
package anirss

import (
	"bytes"
	"context"
	"crypto/md5"
	"encoding/base64"
	"encoding/hex"
	"encoding/json"
	"fmt"
	"net/http"
	"net/url"
	"regexp"
	"sort"
	"strings"
	"sync"

	"linplayer/core/source"
)

// Kind 线上值一律小写。
const Kind source.Kind = "anirss"

// Backend Ani-RSS 后端。token 按 server.ID 缓存。
type Backend struct {
	mu     sync.Mutex
	tokens map[string]string
}

func New() *Backend { return &Backend{tokens: map[string]string{}} }

func (b *Backend) Kind() source.Kind { return Kind }

func normalizeBase(raw string) string {
	return strings.TrimRight(strings.TrimSpace(raw), "/")
}

func md5Hex(s string) string {
	sum := md5.Sum([]byte(s))
	return hex.EncodeToString(sum[:])
}

// login 密码走 MD5(上游就是这么定的,不是我们的选择)。
func login(ctx context.Context, c *http.Client, baseURL, user, pass string) (string, error) {
	body, _ := json.Marshal(map[string]any{"username": user, "password": md5Hex(pass)})
	req, err := http.NewRequestWithContext(ctx, http.MethodPost,
		normalizeBase(baseURL)+"/api/login", bytes.NewReader(body))
	if err != nil {
		return "", err
	}
	req.Header.Set("Content-Type", "application/json")
	resp, err := c.Do(req)
	if err != nil {
		return "", fmt.Errorf("无法连接服务器: %w", err)
	}
	defer resp.Body.Close()
	var out struct {
		Code    int    `json:"code"`
		Message string `json:"message"`
		Data    string `json:"data"`
	}
	if json.NewDecoder(resp.Body).Decode(&out) != nil {
		return "", fmt.Errorf("登录响应异常")
	}
	if out.Code != 200 {
		msg := out.Message
		if msg == "" {
			msg = "登录失败"
		}
		return "", source.Auth("%s", msg)
	}
	if out.Data == "" {
		return "", source.Auth("登录未返回令牌")
	}
	return out.Data, nil
}

// Login 供登录表单调用。
func Login(ctx context.Context, c *http.Client, baseURL, user, pass string) (string, error) {
	return login(ctx, c, baseURL, user, pass)
}

func (b *Backend) cached(s *source.Server) string {
	b.mu.Lock()
	t := b.tokens[s.ID]
	b.mu.Unlock()
	if t != "" {
		return t
	}
	if s.Token != nil {
		return *s.Token
	}
	return ""
}

// ensureToken 拿 token。force = 忽略缓存重登(401/403 之后用)。
func (b *Backend) ensureToken(ctx context.Context, c *http.Client, s *source.Server, force bool) (string, error) {
	if !force {
		if t := b.cached(s); t != "" {
			return t, nil
		}
	}
	u, p := "", ""
	if s.Username != nil {
		u = *s.Username
	}
	if s.Password != nil {
		p = *s.Password
	}
	if u == "" {
		return "", source.Auth("这个 Ani-RSS 服务器还没有保存账号密码,需要重新登录")
	}
	t, err := login(ctx, c, s.BaseURL, u, p)
	if err != nil {
		return "", err
	}
	b.mu.Lock()
	b.tokens[s.ID] = t
	b.mu.Unlock()
	return t, nil
}

// ClearToken 移除服务器 / 重新登录时清缓存。
func (b *Backend) ClearToken(serverID string) {
	b.mu.Lock()
	delete(b.tokens, serverID)
	b.mu.Unlock()
}

// call 打一个管理接口。401/403 自动重登一次。
//
// ★ 只重一次:重登本身也可能一直 401(密码改了),无限重试会把服务器打爆
// 而界面永远停在「加载中」。
func (b *Backend) call(ctx context.Context, c *http.Client, s *source.Server, path string, body any) (json.RawMessage, error) {
	do := func(token string) (int, json.RawMessage, string, error) {
		var rd *bytes.Reader
		if body != nil {
			raw, err := json.Marshal(body)
			if err != nil {
				return 0, nil, "", err
			}
			rd = bytes.NewReader(raw)
		} else {
			rd = bytes.NewReader([]byte("null"))
		}
		req, err := http.NewRequestWithContext(ctx, http.MethodPost, normalizeBase(s.BaseURL)+path, rd)
		if err != nil {
			return 0, nil, "", err
		}
		req.Header.Set("Content-Type", "application/json")
		req.Header.Set("Authorization", token)
		resp, err := c.Do(req)
		if err != nil {
			return 0, nil, "", fmt.Errorf("无法连接服务器: %w", err)
		}
		defer resp.Body.Close()
		var out struct {
			Code    int             `json:"code"`
			Message string          `json:"message"`
			Data    json.RawMessage `json:"data"`
		}
		if json.NewDecoder(resp.Body).Decode(&out) != nil {
			return resp.StatusCode, nil, "响应不是合法 JSON", nil
		}
		return resp.StatusCode, out.Data, out.Message, nil
	}

	token, err := b.ensureToken(ctx, c, s, false)
	if err != nil {
		return nil, err
	}
	code, data, msg, err := do(token)
	if err != nil {
		return nil, err
	}
	if code == 401 || code == 403 {
		if token, err = b.ensureToken(ctx, c, s, true); err != nil {
			return nil, err
		}
		if code, data, msg, err = do(token); err != nil {
			return nil, err
		}
	}
	if code < 200 || code >= 300 {
		if code == 401 || code == 403 {
			return nil, source.Auth("登录已失效,需要重新登录")
		}
		if msg == "" {
			msg = fmt.Sprintf("HTTP %d", code)
		}
		return nil, fmt.Errorf("%s", msg)
	}
	return data, nil
}

// flattenWeekList 番剧表是按周分组的,展平并按 id/title 去重。
//
// ★ 同一部番会出现在多个周里(改过播出日的),不去重的话根目录里同一部番
// 会出现两三次 —— 看着像数据坏了。
func flattenWeekList(data json.RawMessage) []map[string]any {
	var week struct {
		WeekList []struct {
			Items []map[string]any `json:"items"`
		} `json:"weekList"`
	}
	out := []map[string]any{}
	seen := map[string]bool{}
	add := func(items []map[string]any) {
		for _, it := range items {
			key, _ := it["id"].(string)
			if key == "" {
				key, _ = it["title"].(string)
			}
			if key == "" || seen[key] {
				continue
			}
			seen[key] = true
			out = append(out, it)
		}
	}
	if json.Unmarshal(data, &week) == nil && len(week.WeekList) > 0 {
		for _, w := range week.WeekList {
			add(w.Items)
		}
		return out
	}
	// 有的版本直接给裸数组。
	var arr []map[string]any
	if json.Unmarshal(data, &arr) == nil {
		add(arr)
	}
	return out
}

var winDriveRe = regexp.MustCompile(`^[A-Za-z]:`)

// looksLikePath 解出来的东西像不像一个绝对路径。
func looksLikePath(s string) bool {
	return strings.Contains(s, "/") || winDriveRe.MatchString(s)
}

// EncodeFilename 把 PlayItem.filename 归一成**上游要的 base64**。
//
// ★★★ 上游 v3.1.23(2026-05-08 a91b5b76)把 `PlayItem.filename` 从 base64
// 改成了**裸绝对路径**,编码责任移交客户端 —— 我们一直没跟(N15)。
// 在 v3.x 服务端上这个源**点任何一集都放不出来**。
//
// ★★ 判据是**内容嗅探**,不是版本号分支:按版本分支要先拿到版本、还要维护
// 一张对照表,而上游根本没有版本化端点。
//
//	尝试 Base64 解码
//	  ├─ 成功 且 解出来像路径(含 '/' 或 ^[A-Za-z]:) → 原串已是 base64,直接用
//	  └─ 否则                                       → 原串是明文路径,自己编码
//
// ★★ **不能用「含 `/` 就是路径」判** —— 标准 Base64 字符集本身就含 `/`。
// 判据必须落在**解码之后**。
//
// ★★ **不要用 URL-safe Base64**(`-_` 字符集):上游解的是标准字符集,
// 而且它自己做了 `" " → "+"` 的兜底(补 URL 解码把 `+` 变成空格那一步)。
func EncodeFilename(raw string) string {
	if raw == "" {
		return ""
	}
	if dec, err := base64.StdEncoding.DecodeString(raw); err == nil && looksLikePath(string(dec)) {
		return raw // 已经是 base64
	}
	return base64.StdEncoding.EncodeToString([]byte(raw))
}

// decodeForDisplay 尽力解出可读名字;解不出就原样返回。
func decodeForDisplay(raw string) string {
	if dec, err := base64.StdEncoding.DecodeString(raw); err == nil && looksLikePath(string(dec)) {
		s := string(dec)
		if i := strings.LastIndexAny(s, `/\`); i >= 0 {
			return s[i+1:]
		}
		return s
	}
	if i := strings.LastIndexAny(raw, `/\`); i >= 0 {
		return raw[i+1:]
	}
	return raw
}

// ListDir 根 = 番剧当文件夹;番剧层 = playList 列剧集当文件。
func (b *Backend) ListDir(ctx context.Context, c *http.Client, s *source.Server, dirID string) ([]source.Entry, error) {
	if dirID == "" {
		data, err := b.call(ctx, c, s, "/api/listAni", nil)
		if err != nil {
			return nil, err
		}
		entries := []source.Entry{}
		for _, a := range flattenWeekList(data) {
			raw, err := json.Marshal(a)
			if err != nil {
				continue
			}
			name, _ := a["title"].(string)
			if name == "" {
				name = "未命名"
			}
			e := source.Entry{
				// ★ 目录 id 里装的是**整个 Ani 的 JSON**:上游的 playList
				//   是按 `Ani.url` 在内存表里找的(不是按 id),只传 id 会直接报错。
				ID: "ani:" + string(raw), Name: name, IsDir: true,
			}
			if img, _ := a["image"].(string); strings.HasPrefix(img, "http") {
				e.ThumbURL = &img
			}
			e.Raw = raw
			entries = append(entries, e)
		}
		sort.SliceStable(entries, func(i, j int) bool { return entries[i].Name < entries[j].Name })
		return entries, nil
	}

	body, ok := strings.CutPrefix(dirID, "ani:")
	if !ok {
		return []source.Entry{}, nil
	}
	var ani map[string]any
	if json.Unmarshal([]byte(body), &ani) != nil {
		return nil, fmt.Errorf("番剧数据解析失败")
	}
	data, err := b.call(ctx, c, s, "/api/playList", ani)
	if err != nil {
		return nil, err
	}
	var list []map[string]any
	if json.Unmarshal(data, &list) != nil {
		return []source.Entry{}, nil
	}
	entries := make([]source.Entry, 0, len(list))
	eps := make([]float64, 0, len(list))
	for _, p := range list {
		fn, _ := p["filename"].(string)
		if fn == "" {
			continue
		}
		name, _ := p["title"].(string)
		if name == "" {
			name, _ = p["name"].(string)
		}
		if name == "" {
			name = decodeForDisplay(fn)
		}
		raw, _ := json.Marshal(map[string]any{
			"filename": fn, "episode": p["episode"], "subtitles": p["subtitles"],
		})
		entries = append(entries, source.Entry{
			ID: "file:" + fn, Name: name, IsVideo: true, Raw: raw,
		})
		ep, _ := p["episode"].(float64)
		eps = append(eps, ep)
	}
	// ★ 按集数排,集数相同再按名字 —— 服务端给的顺序是文件系统顺序,
	//   第 10 集会排在第 2 集前面。
	idx := make([]int, len(entries))
	for i := range idx {
		idx[i] = i
	}
	sort.SliceStable(idx, func(a, b int) bool {
		if eps[idx[a]] != eps[idx[b]] {
			return eps[idx[a]] < eps[idx[b]]
		}
		return entries[idx[a]].Name < entries[idx[b]].Name
	})
	out := make([]source.Entry, len(entries))
	for i, j := range idx {
		out[i] = entries[j]
	}
	return out, nil
}

// ResolvePlay 拼 `/api/file?filename=<base64>&s=<token>`。
func (b *Backend) ResolvePlay(ctx context.Context, c *http.Client, s *source.Server,
	e *source.Entry, qualityID string) (*source.ResolvedPlay, error) {
	fn := ""
	if len(e.Raw) > 0 {
		var raw struct {
			Filename  string `json:"filename"`
			Subtitles []struct {
				URL  string `json:"url"`
				Name string `json:"name"`
			} `json:"subtitles"`
		}
		if json.Unmarshal(e.Raw, &raw) == nil {
			fn = raw.Filename
		}
	}
	if fn == "" {
		fn, _ = strings.CutPrefix(e.ID, "file:")
	}
	if fn == "" {
		return nil, fmt.Errorf("缺少文件信息")
	}
	token, err := b.ensureToken(ctx, c, s, false)
	if err != nil {
		return nil, err
	}
	base := normalizeBase(s.BaseURL)

	fileURL := func(name string) string {
		q := url.Values{}
		// ★ 鉴权走查询参数 `s=`,**不走请求头** —— mpv 拿不到请求头(SPEC §6)。
		q.Set("filename", EncodeFilename(name))
		q.Set("s", token)
		return base + "/api/file?" + q.Encode()
	}

	out := source.Simple(fileURL(fn), e.Name, map[string]string{"Authorization": token})

	// 外挂字幕:`subtitles[].url` 是**服务端绝对路径**,和 filename 同一个坑 ——
	// 要自己包成 /api/file 才能给 mpv 挂。
	if len(e.Raw) > 0 {
		var raw struct {
			Subtitles []struct {
				URL  string `json:"url"`
				Name string `json:"name"`
			} `json:"subtitles"`
		}
		if json.Unmarshal(e.Raw, &raw) == nil {
			for _, sub := range raw.Subtitles {
				if strings.TrimSpace(sub.URL) == "" {
					continue
				}
				u := sub.URL
				if !strings.HasPrefix(u, "http") {
					u = fileURL(u)
				}
				st := source.Subtitle{URL: u, HTTPHeaders: map[string]string{}}
				if sub.Name != "" {
					n := sub.Name
					st.Title = &n
				}
				out.Subtitles = append(out.Subtitles, st)
			}
		}
	}
	return &out, nil
}
