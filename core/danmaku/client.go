package danmaku

// 弹幕源的请求层:鉴权推导、签名、解析、五个端点。
//
// 移植自 `crates/core/src/danmaku/mod.rs`。

import (
	"context"
	"encoding/json"
	"fmt"
	"net/http"
	"net/url"
	"strconv"
	"strings"
	"time"

	"linplayer/core/httpx"
)

// OfficialBase 弹弹Play 官方接口基址。
const OfficialBase = "https://api.dandanplay.net"

// DeriveAuth 从用户粘贴的一条链接里**推导**鉴权方式,不让用户选。
//
// ★★ 依据是两个主流自建端的真实接入方式(实测,非猜测):
//
//	huangxd-/danmu_api:              http://host:9321/{TOKEN}/api/v2
//	l429609201/misaka_danmu_server:  prefix="/{token}/api/v2"
//
// 两家都把 token 放在**路径**里 —— 也就是说它本来就在用户复制的那条链接内,
// 我们原样用就行,既不用他选「鉴权方式」,也不用他单独再填一遍 token。
// (用户 2026-07-19:「用户也不知道啥是鉴权方式」。)
//
// ★ 唯一需要动手的是把 token 挂在 **query** 上的写法:`?token=xxx`。
// 那种 URL 不能原样拼接 —— baseURL 会在后面接 `/api/v2`,
// 拼出 `...?token=x/api/v2` 这种废地址。所以要把它拆出来走 QueryToken。
func DeriveAuth(apiURL string) (cleanURL string, auth AuthType, token string) {
	raw := strings.TrimSpace(apiURL)
	pathPart, query := raw, ""
	if i := strings.Index(raw, "?"); i >= 0 {
		pathPart, query = raw[:i], raw[i+1:]
	}
	for _, kv := range strings.Split(query, "&") {
		i := strings.Index(kv, "=")
		if i < 0 {
			continue
		}
		k := strings.ToLower(strings.TrimSpace(kv[:i]))
		v := strings.TrimSpace(kv[i+1:])
		if (k == "token" || k == "api_key" || k == "apikey") && v != "" {
			return strings.TrimRight(pathPart, "/"), AuthQueryToken, v
		}
	}
	// 其余一律原样用:路径 token(两大自建端)本就含在地址里,无需额外处理
	return strings.TrimRight(pathPart, "/"), AuthNone, ""
}

// BaseURL 归一化到以 /api/v2 结尾的基础地址。
func (c *SourceConfig) BaseURL() string {
	if c.Official {
		return OfficialBase + "/api/v2"
	}
	u := strings.TrimRight(strings.TrimSpace(c.APIURL), "/")
	switch {
	case strings.HasSuffix(u, "/api/v2"):
		return u
	case strings.HasSuffix(u, "/api/v1"):
		return u[:len(u)-7] + "/api/v2"
	default:
		return u + "/api/v2"
	}
}

// firstSecret 多 secret 换行分隔;取首个非空。
//
// ★★ 整坨 "S1\nS2" 拿去 sha256 必然签错 —— 服务端回 403,而调用方看到的是「空榜」。
// 轮换是配额分摊,不影响正确性。
func firstSecret(raw string) string {
	for _, l := range strings.Split(raw, "\n") {
		if s := strings.TrimSpace(l); s != "" {
			return s
		}
	}
	return ""
}

// authParts 这次请求要带的头与 query。
func (c *SourceConfig) authParts(endpoint string) (http.Header, url.Values) {
	headers := http.Header{}
	query := url.Values{}
	signPath := "/api/v2" + endpoint

	if c.Official || c.AuthType == AuthSignature {
		appID := strings.TrimSpace(c.AppID)
		secret := firstSecret(c.AppSecret)
		if appID != "" && secret != "" {
			ts := time.Now().Unix()
			headers.Set("X-AppId", appID)
			headers.Set("X-Timestamp", strconv.FormatInt(ts, 10))
			headers.Set("X-Signature", Signature(appID, signPath, ts, secret))
		}
		return headers, query
	}

	t := strings.TrimSpace(c.Token)
	switch c.AuthType {
	case AuthHeaderToken:
		if t != "" {
			// 三个头都带:各家自建端认的不一样,而用户不知道自己装的是哪家
			headers.Set("Authorization", "Bearer "+t)
			headers.Set("X-Token", t)
			headers.Set("X-Api-Key", t)
		}
	case AuthQueryToken:
		if t != "" {
			query.Set("token", t)
		}
	}
	return headers, query
}

// apiError 检查弹弹Play 系接口的 errorCode。
//
// ★★ 这类接口**从不用 HTTP 状态码报错** —— 一律 200 + body 里的 errorCode。
// 不看这个字段,配额用尽 / 参数非法 / 鉴权失败全都长得跟「这个关键词没搜到」一模一样:
// animes 键不存在 → 解析出空表 → 界面说「未找到匹配的弹幕」。
//
// 实测(官方 AppId,真签名):/search/anime、/search/episodes 全部回
// `{"errorCode":429,"errorMessage":"已达到接口调用配额上限"}`,HTTP 200。
// 也就是说用户报的「弹弹play 搜索不到弹幕」,界面上给的原因是**假的**。
// 搜不到和搜不了是两件事,用户有权知道是哪件。
func apiError(v map[string]any) error {
	code, ok := v["errorCode"].(float64)
	if !ok || code == 0 {
		return nil
	}
	msg := ""
	if s, ok := v["errorMessage"].(string); ok {
		msg = strings.TrimSpace(s)
	}
	if msg == "" {
		return fmt.Errorf("弹幕接口错误 %d", int(code))
	}
	return fmt.Errorf("%s(错误码 %d)", msg, int(code))
}

func (c *SourceConfig) getJSON(ctx context.Context, endpoint string, extra url.Values) (map[string]any, error) {
	headers, query := c.authParts(endpoint)
	for k, vs := range extra {
		for _, v := range vs {
			query.Add(k, v)
		}
	}
	u := c.BaseURL() + endpoint
	if len(query) > 0 {
		u += "?" + query.Encode()
	}
	b, _, err := httpx.GetJSON(ctx, httpx.Client(), u, headers)
	if err != nil {
		return nil, fmt.Errorf("弹幕请求失败: %w", err)
	}
	var v map[string]any
	if json.Unmarshal(b, &v) != nil {
		return nil, fmt.Errorf("弹幕解析失败:返回的不是 JSON")
	}
	if err := apiError(v); err != nil {
		return nil, err
	}
	return v, nil
}

// ---------- 解析 ----------

// parseComment 弹弹Play 的 p 字段是 `time,mode,color,userId`。
func parseComment(d map[string]any, source string) Comment {
	p := strings.Split(jstr(d, "p"), ",")
	get := func(i int) string {
		if i < len(p) {
			return p[i]
		}
		return ""
	}
	c := Comment{
		Text:   jstr(d, "m"),
		Mode:   1,
		Color:  16777215, // 白色
		Source: source,
		Count:  1,
	}
	if f, err := strconv.ParseFloat(get(0), 64); err == nil {
		c.Time = f
	}
	if n, err := strconv.Atoi(get(1)); err == nil {
		c.Mode = n
	}
	if n, err := strconv.Atoi(get(2)); err == nil {
		c.Color = n
	}
	if u := get(3); u != "" {
		c.UserID = &u
	}
	// cid 可能是字符串也可能是数字,两种都吃得下
	switch v := d["cid"].(type) {
	case string:
		c.CID = &v
	case float64:
		s := strconv.FormatInt(int64(v), 10)
		c.CID = &s
	}
	return c
}

func parseComments(raw any, source string) []Comment {
	arr, _ := raw.([]any)
	out := make([]Comment, 0, len(arr))
	for _, it := range arr {
		if m, ok := it.(map[string]any); ok {
			out = append(out, parseComment(m, source))
		}
	}
	return out
}

func parseAnime(a map[string]any) Anime {
	an := Anime{
		AnimeID:    idStr(a["animeId"]),
		AnimeTitle: jstr(a, "animeTitle"),
		Episodes:   []Episode{},
	}
	if s := jstr(a, "type"); s != "" {
		an.Type = &s
	}
	if s := jstr(a, "typeDescription"); s != "" {
		an.TypeDescription = &s
	}
	if s := jstr(a, "imageUrl"); s != "" {
		an.ImageURL = &s
	}
	if v, ok := a["year"].(float64); ok {
		n := int64(v)
		an.Year = &n
	}
	if v, ok := a["episodeCount"].(float64); ok {
		n := int64(v)
		an.EpisodeCount = &n
	}
	if eps, ok := a["episodes"].([]any); ok {
		for _, e := range eps {
			m, ok := e.(map[string]any)
			if !ok {
				continue
			}
			ep := Episode{
				EpisodeID:    idStr(m["episodeId"]),
				EpisodeTitle: jstr(m, "episodeTitle"),
			}
			if s := jstr(m, "episodeNumber"); s != "" {
				ep.EpisodeNumber = &s
			}
			an.Episodes = append(an.Episodes, ep)
		}
	}
	return an
}

// ---------- 五个端点 ----------

// SearchAnime 搜番:GET /search/anime?keyword=&v2=true → 只回条目,**不带集列表**。
//
// ★ 比 /search/episodes 快得多(后者要把每部番的整份集表也捞出来),
// 配合 BangumiEpisodes 做「先挑番 → 再挑集」两段式。
// v2=true 是官方新搜索引擎;自建源不认这个参数会直接忽略,无害。
func (c *SourceConfig) SearchAnime(ctx context.Context, keyword string) ([]Anime, error) {
	v, err := c.getJSON(ctx, "/search/anime", url.Values{
		"keyword": {keyword}, "v2": {"true"},
	})
	if err != nil {
		return nil, err
	}
	return animesOf(v), nil
}

// BangumiEpisodes 取某部番的集表:GET /bangumi/{animeId}。
func (c *SourceConfig) BangumiEpisodes(ctx context.Context, animeID string) ([]Episode, error) {
	v, err := c.getJSON(ctx, "/bangumi/"+url.PathEscape(animeID), nil)
	if err != nil {
		return nil, err
	}
	if b, ok := v["bangumi"].(map[string]any); ok {
		return parseAnime(b).Episodes, nil
	}
	return []Episode{}, nil
}

// SearchEpisodes 搜集:GET /search/episodes?anime=&episode= → 条目**带**集列表。
func (c *SourceConfig) SearchEpisodes(ctx context.Context, anime, episode string) ([]Anime, error) {
	q := url.Values{"anime": {anime}}
	if episode != "" {
		q.Set("episode", episode)
	}
	v, err := c.getJSON(ctx, "/search/episodes", q)
	if err != nil {
		return nil, err
	}
	return animesOf(v), nil
}

// GetComments 取弹幕:GET /comment/{episodeId}?withRelated=true&chConvert=N。
func (c *SourceConfig) GetComments(ctx context.Context, episodeID string, chConvert int) ([]Comment, error) {
	q := url.Values{"withRelated": {"true"}}
	if chConvert != 0 {
		q.Set("chConvert", strconv.Itoa(chConvert))
	}
	v, err := c.getJSON(ctx, "/comment/"+url.PathEscape(episodeID), q)
	if err != nil {
		return nil, err
	}
	return parseComments(v["comments"], c.ID), nil
}

// MatchFile 文件识别:POST /match。
//
// ★★ fileHash 为空时**不能传空串** —— 那是参数非法,这条路从来没通过。
// 官方的 /match 允许只靠文件名 + 时长匹配,但你得**不传**那个字段,而不是传个空的。
func (c *SourceConfig) MatchFile(ctx context.Context, fileName, fileHash string, fileSize int64, durationSecs float64) (*MatchResult, error) {
	body := map[string]any{"fileName": fileName, "matchMode": "hashAndFileName"}
	if fileHash != "" {
		body["fileHash"] = fileHash
	}
	if fileSize > 0 {
		body["fileSize"] = fileSize
	}
	if durationSecs > 0 {
		body["videoDuration"] = int64(durationSecs)
	}
	raw, _ := json.Marshal(body)

	headers, query := c.authParts("/match")
	u := c.BaseURL() + "/match"
	if len(query) > 0 {
		u += "?" + query.Encode()
	}
	req, err := http.NewRequestWithContext(ctx, http.MethodPost, u, strings.NewReader(string(raw)))
	if err != nil {
		return nil, err
	}
	req.Header = headers.Clone()
	req.Header.Set("Content-Type", "application/json")
	req.Header.Set("Accept", "application/json")
	resp, err := httpx.Client().Do(req)
	if err != nil {
		return nil, fmt.Errorf("弹幕请求失败: %w", err)
	}
	defer resp.Body.Close()

	var v map[string]any
	if json.NewDecoder(resp.Body).Decode(&v) != nil {
		return nil, fmt.Errorf("弹幕解析失败:返回的不是 JSON")
	}
	if err := apiError(v); err != nil {
		return nil, err
	}
	out := &MatchResult{Matches: []MatchItem{}}
	out.IsMatched, _ = v["isMatched"].(bool)
	if arr, ok := v["matches"].([]any); ok {
		for _, it := range arr {
			m, ok := it.(map[string]any)
			if !ok {
				continue
			}
			mi := MatchItem{
				EpisodeID:    idStr(m["episodeId"]),
				AnimeID:      idStr(m["animeId"]),
				AnimeTitle:   jstr(m, "animeTitle"),
				EpisodeTitle: jstr(m, "episodeTitle"),
				SourceID:     c.ID,
				SourceName:   c.Name,
			}
			if s := jstr(m, "type"); s != "" {
				mi.Type = &s
			}
			if s := jstr(m, "typeDescription"); s != "" {
				mi.TypeDescription = &s
			}
			if f, ok := m["shift"].(float64); ok {
				n := int64(f)
				mi.Shift = &n
			}
			out.Matches = append(out.Matches, mi)
		}
	}
	return out, nil
}

// animesOf 新旧搜索引擎的字段名不同(animes / bangumiList),两个都收。
func animesOf(v map[string]any) []Anime {
	out := []Anime{}
	for _, key := range []string{"animes", "bangumiList"} {
		arr, ok := v[key].([]any)
		if !ok {
			continue
		}
		for _, it := range arr {
			if m, ok := it.(map[string]any); ok {
				out = append(out, parseAnime(m))
			}
		}
		if len(out) > 0 {
			return out
		}
	}
	return out
}

func jstr(m map[string]any, k string) string {
	if v, ok := m[k].(string); ok {
		return v
	}
	return ""
}

// idStr id 可能是数字也可能是字符串,两种都要吃得下。
func idStr(v any) string {
	switch t := v.(type) {
	case string:
		return t
	case float64:
		return strconv.FormatInt(int64(t), 10)
	}
	return ""
}
