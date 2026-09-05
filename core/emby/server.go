package emby

// 服务器公开信息 / 备用线路。登录前后各一条,都不走列表那套解析。
//

import (
	"context"
	"encoding/json"
	"fmt"
	"net/http"
	"net/url"
	"strings"
	"sync"
	"time"
)

// ServerInfo `GET /System/Info/Public` 的三样东西。
type ServerInfo struct {
	Name    string `json:"name"`
	Version string `json:"version"`
	ID      string `json:"id"`
}

// ProbeServer 探测服务器(「测试连接」)。
//
// ★ **不需要登录态** —— 这是登录**前**用的,别走 session。
func (c *Client) ProbeServer(ctx context.Context, server string) (*ServerInfo, error) {
	u := NormServer(server) + "/System/Info/Public"
	req, err := http.NewRequestWithContext(ctx, http.MethodGet, u, nil)
	if err != nil {
		return nil, fmt.Errorf("请求构造失败: %w", err)
	}
	req.Header.Set("X-Emby-Authorization", c.authHeader("linplayer-probe"))
	req.Header.Set("User-Agent", c.UA)
	resp, err := c.HTTP.Do(req)
	if err != nil {
		return nil, fmt.Errorf("网络错误: %w", err)
	}
	defer resp.Body.Close()
	if resp.StatusCode < 200 || resp.StatusCode >= 300 {
		return nil, fmt.Errorf("请求失败: HTTP %d", resp.StatusCode)
	}
	var j map[string]any
	if err := json.NewDecoder(resp.Body).Decode(&j); err != nil {
		return nil, fmt.Errorf("解析失败: %w", err)
	}
	return &ServerInfo{Name: jstr(j, "ServerName"), Version: jstr(j, "Version"), ID: jstr(j, "Id")}, nil
}

// ExtDomain 服主下发的一条备用线路。
type ExtDomain struct {
	Name string `json:"name"`
	URL  string `json:"url"`
}

// ExtDomains 拉取服主配置的备用线路(「同步线路」)。
//
// # 这是什么
//
// **不是**某个中心化的域名列表,而是**服主自己部署**的一个小服务,
// 用 nginx 片段挂在**自己 Emby 域名的同一 origin** 下的
// `= /emby/System/Ext/ServerDomains`。所以「匹配」是**隐式同源**的:
// 拿当前这台服务器的地址去打这个端点,回来的就是这台服的备用线路。
// 没有 key、没有 ID、没有分组 —— **别去设计什么匹配逻辑,不存在**。
//
// 鉴权:服务端认 X-Emby-Token / X-Emby-Authorization,我们现有的头原样透传即可。
//
// # 空表与报错的分界(★ 别搞反)
//
// **绝大多数 Emby 服务器没装这玩意 —— 404 是常态,不是错误。**
// 404 / 超时 / 解析不了 → 返回空表,让 UI 说「这台服务器没提供线路表」
// 而不是弹一个红色报错吓人。**只有 401**(token 失效,用户能采取行动)才报错。
func (c *Client) ExtDomains(ctx context.Context, s *Session) ([]ExtDomain, error) {
	/* 端点路径在上游 nginx 里是**精确匹配**,相对 origin。
	   用户填的地址可能已经带了 /emby(反代常见写法),直接拼就成了 /emby/emby/… → 404。
	   故先把结尾的 /emby 削掉再拼。 */
	base := NormServer(s.Server)
	origin := strings.TrimSuffix(base, "/emby")
	u := origin + "/emby/System/Ext/ServerDomains"

	// 上游每次都要回源校验 token(不缓存),给 10s
	ctx, cancel := context.WithTimeout(ctx, 10*time.Second)
	defer cancel()

	req, err := http.NewRequestWithContext(ctx, http.MethodGet, u, nil)
	if err != nil {
		return nil, fmt.Errorf("请求构造失败: %w", err)
	}
	req.Header.Set("X-Emby-Token", s.Token)
	req.Header.Set("X-Emby-Authorization", c.authHeader(s.DeviceID))
	req.Header.Set("User-Agent", c.UA)

	resp, err := c.HTTP.Do(req)
	if err != nil {
		// 超时 / 连不上 —— 大概率是没部署。不是用户能修的事,别报错。
		return []ExtDomain{}, nil
	}
	defer resp.Body.Close()
	if resp.StatusCode == http.StatusUnauthorized {
		return nil, fmt.Errorf("线路服务拒绝了登录凭据(token 可能已失效),请重新登录")
	}
	if resp.StatusCode < 200 || resp.StatusCode >= 300 {
		return []ExtDomain{}, nil // 404 = 服主没部署,常态
	}
	var j struct {
		Data []ExtDomain `json:"data"`
		OK   bool        `json:"ok"`
	}
	if err := json.NewDecoder(resp.Body).Decode(&j); err != nil {
		return []ExtDomain{}, nil // 同路径上挂了别的东西,返回的不是这个格式
	}
	if !j.OK {
		return []ExtDomain{}, nil
	}
	/* ★ 信任边界:url 是**服主在自己配置里自填的裸字符串,上游零校验**。
	   它会被我们直接拿去当 baseUrl 拼 API + 带上 token 请求 —— 配错或被投毒
	   就等于把 token 发到任意地址。这里必须自己把关:只收 http(s),且能解析成合法 URL。 */
	out := []ExtDomain{}
	for _, d := range j.Data {
		u := strings.TrimSpace(d.URL)
		if !strings.HasPrefix(u, "http://") && !strings.HasPrefix(u, "https://") {
			continue
		}
		if _, err := url.Parse(u); err != nil {
			continue
		}
		out = append(out, d)
	}
	return out, nil
}

// ItemForHistory 取单条 Item(带跨服续播强匹配所需的**全部** Fields)。
//
// ★ 与 Detail 的区别:Detail 面向详情页(要 Overview/People/子集),
// 这个面向观看记录 —— **只要匹配判据**。
// 少要 HistoryFields 的话匹配会静默降级到「剧名+季集号」,那正是跨服续播
// 最容易假装能用的失败形态。
func (c *Client) ItemForHistory(ctx context.Context, s *Session, itemID string) (*Item, error) {
	u := fmt.Sprintf("%s/Users/%s/Items/%s?Fields=Genres,ProductionYear,CommunityRating,%s",
		s.Server, url.PathEscape(s.UserID), url.PathEscape(itemID), HistoryFields)
	b, err := c.getBytes(ctx, s, u)
	if err != nil {
		return nil, err
	}
	var raw rawItem
	if err := json.Unmarshal(b, &raw); err != nil {
		return nil, fmt.Errorf("解析失败: %w", err)
	}
	it := fromRaw(raw)
	return &it, nil
}

// tmdbCache 剧 → TMDB id 的缓存。**含负结果**。
//
// ★★ 这一条是<b>起播路径上的一次网络往返</b>,而追剧就是同一部剧一集接一集地放 ——
// 不缓存的话每集都要重打一次,而答案永远一样。
// ★ 必须缓存「查过但没有」:没刮削的库返回 nil,不记负结果就等于完全没缓存,
// 而那正是最需要缓存的场景(整库都没刮 TMDB)。
// ★ 键要带 server —— 同一个 seriesID 在两台服务器上不是同一部剧(分隔符用竖线:
// 它不会出现在服务器地址里,而拼接时不加分隔的话 "a"+"bc" 和 "ab"+"c" 会撞成同一个键)。
var (
	tmdbMu    sync.Mutex
	provCache = map[string]map[string]string{}
)

// SeriesProviders 取某剧的外部 id 表(Tmdb / Imdb / Tvdb / MyAnimeList …)。
//
// ★ 缓存的是**整张表**而不是某一个 id:跨服续播要 TMDB、片头片尾数据源要 IMDb 和 MAL,
// 各缓各的等于同一部剧问好几趟,而答案在同一个响应里。
// 剧不存在 / 没刮削 → 返回 nil,**不是错误**:没刮削的库属正常。
func (c *Client) SeriesProviders(ctx context.Context, s *Session, seriesID string) map[string]string {
	key := s.Server + "|" + seriesID
	tmdbMu.Lock()
	if v, ok := provCache[key]; ok {
		tmdbMu.Unlock()
		return v
	}
	tmdbMu.Unlock()

	var found map[string]string
	if it, err := c.ItemForHistory(ctx, s, seriesID); err == nil && it != nil {
		found = it.ProviderIDs
	} else if err != nil {
		// ★ 网络错**不进缓存**:那不是「这剧没有外部 id」,是这次没问到。
		//   记下来的话一次抖动会让这部剧到重启前都匹配不上。
		return nil
	}

	tmdbMu.Lock()
	provCache[key] = found
	tmdbMu.Unlock()
	return found
}

// ProviderOf 按名字取一个外部 id(大小写不敏感)。取不到回空串。
func ProviderOf(ids map[string]string, name string) string {
	for k, v := range ids {
		if strings.EqualFold(k, name) {
			return strings.TrimSpace(v)
		}
	}
	return ""
}

// SeriesTmdbID 取某剧的 TMDB id。跨服务器匹配剧集时用:
// 同一部剧在两台服的 item_id 不同,但 TMDB id 相同。
func (c *Client) SeriesTmdbID(ctx context.Context, s *Session, seriesID string) *string {
	if t := ProviderOf(c.SeriesProviders(ctx, s, seriesID), "Tmdb"); t != "" {
		return &t
	}
	return nil
}
