package sync

// Bangumi:授权 / 个人令牌登录 / 在看状态 / 单集打勾 / 放送表。
//
// 移植自 `crates/core/src/sync/bangumi.rs`。

import (
	"context"
	"encoding/json"
	"fmt"
	"net/http"
	"net/url"
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"sync"
	"time"

	"linplayer/core/httpx"
	"linplayer/core/paths"
)

// bangumiRedirectURI OAuth 回调地址。
//
// ★ 它落在**我们自己的中转**上,所以和代理地址一样是编译期注入的,源码里不留。
var bangumiRedirectURI string

// BangumiRedirectURI 默认回调地址。空 = 这个构建没配(授权码流不可用,个人令牌流照常)。
func BangumiRedirectURI() string { return strings.TrimSpace(bangumiRedirectURI) }

// BangumiAuthorizeURL 构造授权页 URL(用户浏览器打开授权,拿回 code 粘贴)。
//
// ★★ 授权页在 **bgm.tv 主站**,不在 api.bgm.tv —— API 切到官方之后,
// 授权必须独立指到 OAuth 主站,否则 /oauth/authorize 打到 api 子域直接 404。
func BangumiAuthorizeURL(redirectURI string) string {
	if redirectURI == "" {
		redirectURI = BangumiRedirectURI()
	}
	return fmt.Sprintf("%s/oauth/authorize?client_id=%s&response_type=code&redirect_uri=%s",
		BangumiOAuthOfficial, url.QueryEscape(BangumiAppID()), url.QueryEscape(redirectURI))
}

// BangumiExchangeCode 用授权码换令牌(走代理)。
func BangumiExchangeCode(ctx context.Context, code, redirectURI string) (*Account, error) {
	if redirectURI == "" {
		redirectURI = BangumiRedirectURI()
	}
	st, b, err := postProxy(ctx, "/bangumi/token", map[string]string{
		"code": strings.TrimSpace(code), "redirect_uri": redirectURI,
	})
	if err != nil {
		return nil, err
	}
	if st < 200 || st >= 300 {
		return nil, fmt.Errorf("Bangumi 令牌交换失败: HTTP %d", st)
	}
	var tok map[string]any
	if json.Unmarshal(b, &tok) != nil {
		return nil, fmt.Errorf("Bangumi 返回的不是 JSON")
	}
	return bangumiAccountFromToken(ctx, tok, nil), nil
}

// BangumiLoginWithToken 用**个人访问令牌**登录。
//
// 与授权码流的区别:没有 refresh_token,过期时间由 Bangumi 侧决定(通常一年),
// 客户端不做刷新 —— 过期后用户重新生成一个粘进来即可。
//
// ★ 好处是**完全不经代理**:代理挂了 / 共享密钥轮换了,这条路照样能登。
func BangumiLoginWithToken(ctx context.Context, token string) (*Account, error) {
	token = strings.TrimSpace(token)
	if token == "" {
		return nil, fmt.Errorf("请填写 Access Token")
	}
	// ★ 立刻打一次 /v0/me 验一下令牌真的有效,别把一个废令牌存进配置里 ——
	//   存了的话设置页显示「已连接」,而每次同步都静默失败。
	name, uid := bangumiProfile(ctx, token)
	if name == "" && uid == "" {
		return nil, fmt.Errorf("Access Token 无效或已过期(Bangumi 没有返回用户信息)")
	}
	a := &Account{Service: "bangumi", AccessToken: token}
	if name != "" {
		a.Username = &name
	}
	if uid != "" {
		a.UserID = &uid
	}
	return a, nil // ExpiresAt 留空:不主动过期;真过期了 API 会 401,用户重新贴一个
}

// BangumiRefresh 刷新令牌(走代理)。失败返回 nil。
func BangumiRefresh(ctx context.Context, a *Account) *Account {
	if a == nil || a.RefreshToken == nil || *a.RefreshToken == "" {
		return nil
	}
	st, b, err := postProxy(ctx, "/bangumi/refresh", map[string]string{
		"refresh_token": *a.RefreshToken, "redirect_uri": BangumiRedirectURI(),
	})
	if err != nil || st < 200 || st >= 300 {
		return nil
	}
	var tok map[string]any
	if json.Unmarshal(b, &tok) != nil {
		return nil
	}
	return bangumiAccountFromToken(ctx, tok, a)
}

// BangumiEnsureValid 确保令牌有效。
func BangumiEnsureValid(ctx context.Context, a *Account) *Account {
	if a == nil {
		return nil
	}
	if !a.IsExpired(NowMs()) {
		return a
	}
	fresh := BangumiRefresh(ctx, a)
	if fresh != nil {
		_ = Save("bangumi", fresh)
	}
	return fresh
}

func bangumiAccountFromToken(ctx context.Context, tok map[string]any, fallback *Account) *Account {
	access := jstr(tok, "access_token")
	if access == "" && fallback != nil {
		access = fallback.AccessToken
	}
	a := &Account{Service: "bangumi", AccessToken: access}
	if rt := jstr(tok, "refresh_token"); rt != "" {
		a.RefreshToken = &rt
	} else if fallback != nil {
		a.RefreshToken = fallback.RefreshToken
	}
	if v, ok := tok["expires_in"].(float64); ok {
		t := NowMs() + int64(v)*1000
		a.ExpiresAt = &t
	} else if fallback != nil {
		a.ExpiresAt = fallback.ExpiresAt
	}
	if name, uid := bangumiProfile(ctx, access); name != "" || uid != "" {
		if name != "" {
			a.Username = &name
		}
		if uid != "" {
			a.UserID = &uid
		}
	} else if fallback != nil {
		a.Username, a.UserID = fallback.Username, fallback.UserID
	}
	return a
}

func bangumiProfile(ctx context.Context, access string) (name, uid string) {
	if access == "" {
		return "", ""
	}
	b, code, err := httpx.GetJSON(ctx, httpx.Client(), BangumiAPIOfficial+"/v0/me",
		http.Header{"Authorization": {"Bearer " + access}})
	if err != nil || code != 200 {
		return "", ""
	}
	var j map[string]any
	if json.Unmarshal(b, &j) != nil {
		return "", ""
	}
	name = jstr(j, "nickname")
	if name == "" {
		name = jstr(j, "username")
	}
	if v, ok := j["id"].(float64); ok {
		uid = strconv.FormatInt(int64(v), 10)
	}
	return name, uid
}

// BangumiSetCollection 设置在看状态。type_: 1=想看 2=看过 3=在看 4=搁置 5=抛弃。
func BangumiSetCollection(ctx context.Context, a *Account, subjectID int64, typ int) (bool, error) {
	valid := BangumiEnsureValid(ctx, a)
	if valid == nil {
		return false, fmt.Errorf("Bangumi 未登录或登录已失效")
	}
	body, _ := json.Marshal(map[string]any{"type": typ})
	u := fmt.Sprintf("%s/v0/users/-/collections/%d", BangumiAPIOfficial, subjectID)
	req, err := http.NewRequestWithContext(ctx, http.MethodPost, u, strings.NewReader(string(body)))
	if err != nil {
		return false, err
	}
	req.Header.Set("Authorization", "Bearer "+valid.AccessToken)
	req.Header.Set("Content-Type", "application/json")
	resp, err := httpx.Client().Do(req)
	if err != nil {
		return false, err
	}
	defer resp.Body.Close()
	return resp.StatusCode >= 200 && resp.StatusCode < 300, nil
}

// BangumiUpdateEpisode 给单集打勾。
//
// ★★ 路径里 subject 那一位**必须是字面量 `-`**。
// 旧代码往那儿塞 subject_id,于是这条路**永远 404** —— 而调用方只看返回的 bool、
// 不看原因,所以「点格子恒 false」活了好几个月。
func BangumiUpdateEpisode(ctx context.Context, a *Account, subjectID, episodeID int64, typ int) (bool, error) {
	valid := BangumiEnsureValid(ctx, a)
	if valid == nil {
		return false, fmt.Errorf("Bangumi 未登录或登录已失效")
	}
	body, _ := json.Marshal(map[string]any{"type": typ})
	u := fmt.Sprintf("%s/v0/users/-/collections/-/episodes/%d", BangumiAPIOfficial, episodeID)
	req, err := http.NewRequestWithContext(ctx, http.MethodPut, u, strings.NewReader(string(body)))
	if err != nil {
		return false, err
	}
	req.Header.Set("Authorization", "Bearer "+valid.AccessToken)
	req.Header.Set("Content-Type", "application/json")
	resp, err := httpx.Client().Do(req)
	if err != nil {
		return false, err
	}
	defer resp.Body.Close()
	if resp.StatusCode < 200 || resp.StatusCode >= 300 {
		// ★ 把状态码带出来:`-> bool` 吞掉原因正是上一条注释说的那个事故
		return false, fmt.Errorf("Bangumi 拒绝(HTTP %d,subject=%d episode=%d)", resp.StatusCode, subjectID, episodeID)
	}
	return true, nil
}

// BangumiSummary 按需拉一条简介。
//
// ★ 为什么不在放送表里一次拉齐:实测 /calendar 的 summary 字段整周 111 条**全是空串**
// (字段在、值不给),真简介只在 /v0/subjects/{id}。一周 111 部要 111 次请求。
func BangumiSummary(ctx context.Context, subjectID int64) (*string, error) {
	u := fmt.Sprintf("%s/v0/subjects/%d", BangumiAPIOfficial, subjectID)
	b, code, err := httpx.GetJSON(ctx, httpx.Client(), u, nil)
	if err != nil {
		return nil, err
	}
	if code != 200 {
		return nil, fmt.Errorf("Bangumi 返回 HTTP %d", code)
	}
	var j map[string]any
	if json.Unmarshal(b, &j) != nil {
		return nil, fmt.Errorf("Bangumi 返回的不是 JSON")
	}
	s := strings.TrimSpace(jstr(j, "summary"))
	if s == "" {
		return nil, nil // 没有简介是常态,不是错误
	}
	return &s, nil
}

// mirrorImage 把官方图片地址改写到反代。
//
// ★ 协议相对(`//lain.bgm.tv/…`)要补上 https —— 那是 Web 时代的写法,
// 原样交给图片加载器会当成相对路径,一张都出不来。
func mirrorImage(u string) *string {
	u = strings.TrimSpace(u)
	if u == "" {
		return nil
	}
	full := u
	if strings.HasPrefix(u, "//") {
		full = "https:" + u
	}
	for _, from := range []string{
		"https://lain.bgm.tv", "http://lain.bgm.tv",
		"https://api.bgm.tv", "http://api.bgm.tv",
	} {
		full = strings.ReplaceAll(full, from, BangumiImgMirror)
	}
	return &full
}

// ---------- 放送时刻(bangumi-data)----------
//
// ★★ 为什么要引外部数据集:Bangumi 官方 API **根本不提供放送时刻**。
// /calendar 条目只有 air_date(日期无时刻)与 air_weekday;subject 详情的 infobox
// 也只有「放送开始 / 放送星期 / 播放电视台」,**没有任何 hh:mm**。
// 用 air_date 硬凑会显示成 00:00 那种假时间 —— 不做。
//
// bangumi-data(社区数据集)有 RFC5545 的 broadcast,且条目自带
// `sites[].site == "bangumi"` 的 subject id,能和 /calendar **精确对上**,
// 不靠标题模糊匹配。

const (
	bangumiDataURL     = "https://unpkg.com/bangumi-data@0.3/dist/data.json"
	broadcastTTLSecs   = 7 * 24 * 3600 // 数据集更新不频繁,一周足够
	broadcastCacheName = "bangumi_broadcast.json"
)

var (
	bcastOnce sync.Once
	bcastIdx  map[string]string
)

func broadcastCachePath() string { return filepath.Join(paths.CacheDir(), broadcastCacheName) }

// broadcastStart `"R/2026-07-06T14:30:00.000Z/P7D"` → `"2026-07-06T14:30:00.000Z"`。
// 只认 `R/<起始>/<周期>` 这一种形状;取不出就空串。
func broadcastStart(b string) string {
	parts := strings.Split(b, "/")
	if len(parts) < 2 || parts[0] != "R" {
		return ""
	}
	return strings.TrimSpace(parts[1])
}

// broadcastIndex 拉 bangumi-data(约 7.4MB)→ **只留 id→起始时刻的小索引**(约 1800 条)→ 写盘。
//
// ★ 下次直接读那份小缓存,不再拉大文件。取不到就整体没时刻,**不影响放送表本身**。
func broadcastIndex(ctx context.Context) map[string]string {
	bcastOnce.Do(func() {
		bcastIdx = map[string]string{}
		path := broadcastCachePath()
		if st, err := os.Stat(path); err == nil && time.Since(st.ModTime()).Seconds() <= broadcastTTLSecs {
			if raw, err := os.ReadFile(path); err == nil {
				if json.Unmarshal(raw, &bcastIdx) == nil {
					return
				}
				bcastIdx = map[string]string{}
			}
		}
		b, code, err := httpx.GetJSON(ctx, httpx.Client(), bangumiDataURL, nil)
		if err != nil || code != 200 {
			return // 拉不到就没时刻,放送表照出
		}
		var doc struct {
			Items []struct {
				Broadcast string `json:"broadcast"`
				Sites     []struct {
					Site string `json:"site"`
					ID   string `json:"id"`
				} `json:"sites"`
			} `json:"items"`
		}
		if json.Unmarshal(b, &doc) != nil {
			return
		}
		for _, it := range doc.Items {
			start := broadcastStart(it.Broadcast)
			if start == "" {
				continue
			}
			for _, s := range it.Sites {
				if s.Site == "bangumi" && s.ID != "" {
					bcastIdx[s.ID] = start
				}
			}
		}
		if len(bcastIdx) > 0 {
			if out, err := json.Marshal(bcastIdx); err == nil {
				_ = os.MkdirAll(filepath.Dir(path), 0o755)
				_ = os.WriteFile(path, out, 0o644)
			}
		}
	})
	return bcastIdx
}

// BangumiCalendar 当季放送表。onlyMine=true 只留「在看」的。
func BangumiCalendar(ctx context.Context, a *Account, onlyMine bool) []CalendarEntry {
	out := []CalendarEntry{}

	// 1) 只看我追的:先取在看动画(subject_type=2, type=3)的 id 集合(要登录)
	watching := map[int64]bool{}
	if onlyMine {
		valid := BangumiEnsureValid(ctx, a)
		if valid == nil {
			return out
		}
		u := BangumiAPIOfficial + "/v0/users/-/collections?subject_type=2&type=3&limit=50"
		if b, code, err := httpx.GetJSON(ctx, httpx.Client(), u,
			http.Header{"Authorization": {"Bearer " + valid.AccessToken}}); err == nil && code == 200 {
			var j struct {
				Data []struct {
					SubjectID int64 `json:"subject_id"`
				} `json:"data"`
			}
			if json.Unmarshal(b, &j) == nil {
				for _, it := range j.Data {
					watching[it.SubjectID] = true
				}
			}
		}
		if len(watching) == 0 {
			return out
		}
	}

	// 2) 当季放送表
	b, code, err := httpx.GetJSON(ctx, httpx.Client(), BangumiAPIOfficial+"/calendar", nil)
	if err != nil || code != 200 {
		return out
	}
	var groups []struct {
		Weekday struct {
			ID *int `json:"id"`
		} `json:"weekday"`
		Items []map[string]any `json:"items"`
	}
	if json.Unmarshal(b, &groups) != nil {
		return out
	}

	bcast := broadcastIndex(ctx)
	for _, g := range groups {
		for _, item := range g.Items {
			idF, ok := item["id"].(float64)
			if !ok {
				continue
			}
			id := int64(idF)
			if onlyMine && !watching[id] {
				continue
			}
			// ★ 中文名优先,没有才用原名
			title := strings.TrimSpace(jstr(item, "name_cn"))
			if title == "" {
				title = strings.TrimSpace(jstr(item, "name"))
			}
			if title == "" {
				title = "未知番剧"
			}
			e := CalendarEntry{
				Title:   title,
				Weekday: g.Weekday.ID,
				Source:  "bangumi",
				// ★ AirDate 保持空:Bangumi 的 air_date 是**首播日**,不是本周这一集的日期。
				//   传上去前端会拿它和本周日期比对,比不上就整条丢掉 —— 放送表直接空。
				//   用 weekday 归组才对。
			}
			bid := id
			e.BangumiID = &bid
			if v, ok := bcast[strconv.FormatInt(id, 10)]; ok {
				e.BroadcastAt = &v
			}
			// ★ 海报优先 large:common 是小缩略图,放大到卡片上发虚(用户 2026-07-16「好模糊」)
			if imgs, _ := item["images"].(map[string]any); imgs != nil {
				for _, k := range []string{"large", "common", "medium"} {
					if s, ok := imgs[k].(string); ok && s != "" {
						e.ImageURL = mirrorImage(s)
						break
					}
				}
			}
			// ★★ 0 分 = **没人评过**(新番常见),不是「这片 0 分」—— 滤掉,别让前端画出诽谤
			if r, _ := item["rating"].(map[string]any); r != nil {
				if s, ok := r["score"].(float64); ok && s > 0 {
					e.Rating = &s
				}
			}
			out = append(out, e)
		}
	}
	return out
}
