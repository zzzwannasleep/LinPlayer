package emby

// 搜索 / 相似推荐 / 演职员。
//

import (
	"context"
	"encoding/json"
	"fmt"
	"net/url"
	"strings"
)

// HistoryFields 是跨服务器续播强匹配所需的 Fields
// (见 Item 的 provider_ids / presentation_unique_key / path)。
const HistoryFields = "ProviderIds,PresentationUniqueKey,Path,SeriesId"

// cardFields 卡片渲染要的那几项:海报要 PrimaryImageAspectRatio,角标要 Genres/Year/Rating。
const cardFields = "PrimaryImageAspectRatio,Genres,ProductionYear,CommunityRating"

// Search 全局 / 库内搜索。
func (c *Client) Search(ctx context.Context, s *Session, query string, types []string, limit int, parentID string) ([]Item, error) {
	items, err := c.fetchItems(ctx, s, searchURL(s, query, types, limit, parentID))
	if err != nil {
		return nil, err
	}
	return filterTypes(items, types), nil
}

// filterTypes 显式点了名的类型,**再自己滤一遍**。
//
// 为什么不能只信 `IncludeItemTypes`:某 fork **带 SearchTerm 时把筛选参数一起忽略**
// (2026-08-17 curl 实测,ParentId/Ids/NameContains 一并中招)。
// 搜索浮层的「包括集」开关关着的时候,靠服务端过滤 = 那台上关了也照样出分集,
// 开关是个摆设而且不报错 —— 正是本项目最讨厌的那类静默失效。
// 标准 Emby 上服务端已经滤过,这一遍是 no-op(零成本,不多打一次请求)。
//
// `types` 为空(没点名)时**原样返回** —— 那是「默认全要」,不是「一个都不要」。
func filterTypes(items []Item, types []string) []Item {
	if len(types) == 0 {
		return items
	}
	out := items[:0]
	for _, it := range items {
		for _, t := range types {
			if t == it.Type {
				out = append(out, it)
				break
			}
		}
	}
	return out
}

// searchURL 拆出来只为可测(对应 Rust 侧 tests::search_term_must_be_capitalized)。
func searchURL(s *Session, query string, types []string, limit int, parentID string) string {
	t := "Movie,Series,Episode"
	if len(types) > 0 {
		esc := make([]string, 0, len(types))
		for _, x := range types {
			esc = append(esc, url.QueryEscape(x))
		}
		t = strings.Join(esc, ",")
	}
	/* ★★ 必须是 SearchTerm(**大写 S**)。原实现写的 searchTerm 被服务端**静默忽略**:
	   实测 searchTerm=<两字关键词> 返回 TotalRecordCount=25596(整个服务器!)且头几条与关键词无关,
	   而 SearchTerm=<同一关键词> 返回 6 条正确结果。也就是说搜索一直在吐全库前 N 条冒充结果。
	   Emby 的 query 参数大小写敏感,别再改回小写。

	   ProviderIds/PresentationUniqueKey/Path:跨服务器续播恢复扫描要靠它们做强匹配 ——
	   搜索是恢复扫描的入口,这里不要就只能靠剧名猜(静默匹配不上,不报错)。

	   库内搜索:ParentId + Recursive=true = 只在这棵库树里递归找。
	   没有它,顶栏那个「库内搜索…」和首页的全局搜索打的是同一条 URL ——
	   在「电影」库里搜也能搜出别的库的剧集。
	   **空串当没传**:前端传 "" 比传 null 更常见,拼上去会变成「在 id 为空的库里搜」= 零结果。

	   ★ 2026-08-17 curl 实测,两台服务器结论**相反**,别拿一台的结果给另一台签字:
	     · 接近原版的那台:ParentId 完全生效(12 个库搜同一关键词,回来的集合两两零重叠)。
	     · fork 那台:带 SearchTerm 时把所有筛选参数一起忽略,连 /Search/Hints?ParentId= 也一样。
	       **这台上库内搜索做不到**;参数照发是给标准 Emby/Jellyfin 用的,
	       不为一台 fork 把架构改回去。 */
	parent := ""
	if p := strings.TrimSpace(parentID); p != "" {
		parent = "&ParentId=" + url.QueryEscape(p)
	}
	if limit <= 0 {
		limit = 50
	}
	if limit > ServerPageCap {
		limit = ServerPageCap
	}
	return fmt.Sprintf("%s/Users/%s/Items?SearchTerm=%s&IncludeItemTypes=%s&Recursive=true%s&Fields=%s,%s&Limit=%d",
		s.Server, url.PathEscape(s.UserID), url.QueryEscape(query), t, parent, cardFields, HistoryFields, limit)
}

// Similar 相似推荐(详情页底部)。
//
// 2026-07-15 在接近原版的那台实测:
// `GET /Items/{id}/Similar?UserId=..&Limit=12` → `{"Items":[...],"TotalRecordCount":N}`,
// 相似度靠谱(同题材),Limit 生效,条目带 Primary/Backdrop。可能混 Series+Movie。
//
// 复用 fetchItems —— 返回结构和列表端点同构,不另造解析。
func (c *Client) Similar(ctx context.Context, s *Session, itemID string, limit int) ([]Item, error) {
	if limit > ServerPageCap {
		limit = ServerPageCap
	}
	u := fmt.Sprintf("%s/Items/%s/Similar?UserId=%s&Limit=%d&Fields=%s,%s",
		s.Server, url.PathEscape(itemID), url.QueryEscape(s.UserID), limit, cardFields, HistoryFields)
	return c.fetchItems(ctx, s, u)
}

// PersonDetail 演职员详情页要的那点东西。
//
// ★ 演员在 Emby 里就是一个 `Type=Person` 的 Item,和条目走同一条 `/Users/{uid}/Items/{id}`,
//
//	所以头像直接复用图片通道的 Primary —— 不需要另开图片路径。
//
// ★ 生平(Overview)**经常是空的**:只有刮削器抓到 TMDB 人物页才有。
//
//	空是常态不是错误,前端要为「没有生平」排一版,不能留一块空白。
type PersonDetail struct {
	ID   string `json:"id"`
	Name string `json:"name"`
	// 生平。空串 = 服务器上就没有。
	Overview   string `json:"overview"`
	HasPrimary bool   `json:"has_primary"`
	// 出生日期 ISO 串(PremiereDate)。
	Birthday *string `json:"birthday"`
	// 卒年(EndDate)。有值 = 已故。
	DeathDay *string `json:"death_day"`
	// 出生地(ProductionLocations[0])。
	BirthPlace *string `json:"birth_place"`
}

// Person 演职员详情。
func (c *Client) Person(ctx context.Context, s *Session, personID string) (*PersonDetail, error) {
	u := fmt.Sprintf("%s/Users/%s/Items/%s?Fields=Overview,PremiereDate,EndDate,ProductionLocations",
		s.Server, url.PathEscape(s.UserID), url.PathEscape(personID))
	b, err := c.getBytes(ctx, s, u)
	if err != nil {
		return nil, err
	}
	var j map[string]any
	if err := json.Unmarshal(b, &j); err != nil {
		return nil, fmt.Errorf("解析失败: %w", err)
	}
	id := jstr(j, "Id")
	if id == "" {
		// 服务端没回 Id 时退回调用方传的 —— 前端拿它拼头像 URL,空了整页没头像
		id = personID
	}
	// ★ 出生地要**滤掉空串**(有的刮削器写空数组元素),生卒日期不滤 ——
	//   照 Rust 侧原样,别「统一一下」。
	var birthPlace *string
	if arr, _ := j["ProductionLocations"].([]any); len(arr) > 0 {
		if v, ok := arr[0].(string); ok && v != "" {
			birthPlace = &v
		}
	}
	return &PersonDetail{
		ID:         id,
		Name:       jstr(j, "Name"),
		Overview:   jstr(j, "Overview"),
		HasPrimary: jmap(j, "ImageTags")["Primary"] != nil,
		Birthday:   jstrPtr(j, "PremiereDate"),
		DeathDay:   jstrPtr(j, "EndDate"),
		BirthPlace: birthPlace,
	}, nil
}

// PersonItems 某人参演的电影 / 剧集。
//
// ★ 用 `PersonIds` 而不是 `Person=<名字>`:同名演员在库里是两个人,按名字筛会把两个人的
//
//	作品混在一起,而且**不报错**。
//
// ★ 按首播时间倒序 —— 演员页的通用口径是「最近的作品在前」。
func (c *Client) PersonItems(ctx context.Context, s *Session, personID string, limit int) ([]Item, error) {
	if limit > ServerPageCap {
		limit = ServerPageCap
	}
	u := fmt.Sprintf("%s/Users/%s/Items?PersonIds=%s&Recursive=true&IncludeItemTypes=Movie,Series"+
		"&SortBy=PremiereDate&SortOrder=Descending&Limit=%d&Fields=%s",
		s.Server, url.PathEscape(s.UserID), url.QueryEscape(personID), limit, cardFields)
	return c.fetchItems(ctx, s, u)
}
