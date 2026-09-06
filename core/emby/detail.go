package emby

// 详情页那条链:detail / seasons / seasonEpisodes / episodes。
//
// 详情页是 UI 面积最大的一块(`UI_PC.md` §7.3 有四种版式),
// 也是「字段少映射一个 = 界面上少一行」最密集的地方。

import (
	"context"
	"encoding/json"
	"fmt"
	"net/url"
	"sort"
)

// Person 演职人员。
type Person struct {
	ID         string  `json:"id"`
	Name       string  `json:"name"`
	Role       *string `json:"role"`
	Type       string  `json:"type_"`
	HasPrimary bool    `json:"has_primary"`
}

// SeasonInfo 季。
type SeasonInfo struct {
	ID         string `json:"id"`
	Name       string `json:"name"`
	IndexNo    *int64 `json:"index_no"`
	ChildCount int64  `json:"child_count"`
	Unplayed   int64  `json:"unplayed"`
	HasPrimary bool   `json:"has_primary"`
}

// ItemDetail 条目详情。
type ItemDetail struct {
	ID          string   `json:"id"`
	Name        string   `json:"name"`
	Type        string   `json:"type_"`
	Overview    string   `json:"overview"`
	Year        *int64   `json:"year"`
	Genres      []string `json:"genres"`
	Rating      *float64 `json:"rating"`
	RuntimeSecs float64  `json:"runtime_secs"`
	ResumeSecs  float64  `json:"resume_secs"`
	HasPrimary  bool     `json:"has_primary"`
	// ★ 背景图在 **BackdropImageTags 数组**里,不在 ImageTags 里。
	//   写成 ImageTags["Backdrop"] 永远是 false —— 详情页就永远没有大图。
	HasBackdrop bool `json:"has_backdrop"`
	IsFavorite  bool `json:"is_favorite"`
	// Played 看完标记。**详情页的「标为已看」要回显它** —— 缺了它按钮永远是「未看」态,
	// 点一下变已看、重进又变回未看,而且一句错都不报。
	Played     bool    `json:"played"`
	SeriesName *string `json:"series_name"`
	SeriesID   *string `json:"series_id"`
	// SeasonID 这一集所属季的 id。播放器的「选集」面板要拿它去 seasonEpisodes;
	// 只有 season_no 是不够的 —— 那是序号不是主键。
	SeasonID  *string `json:"season_id"`
	SeasonNo  *int64  `json:"season_no"`
	EpisodeNo *int64  `json:"episode_no"`

	OfficialRating *string `json:"official_rating"`
	Status         *string `json:"status"`
	// 标语(Taglines[0])。**实测只有 34% 的条目有** —— 没有就整行不画,不留空位。
	Tagline *string `json:"tagline"`
	// Series → 季数;Season → 集数。手机端详情页拿它决定要不要画季选择条。
	ChildCount *int64 `json:"child_count"`

	Children []Item   `json:"children"` // Series/Season → 剧集;Movie/Episode → 空
	People   []Person `json:"people"`
}

// Detail 条目详情。
//
// `withChildren`:是否把**全部分集**一起拉回来。
// ★ 桌面/TV 端传 true(它们的详情页就是一屏铺完所有集)。
// ★ **手机端传 false** —— 手机版详情页按季分页拉集(SeasonEpisodes)。
//
//	实测最长的剧 2648 集,全量拉是 1813.9KB / 1841ms,分页 30 条是 20.0KB / 435ms。
//	`content-visibility` 只省渲染,省不掉这 1.8MB 的下载和解析。
func (c *Client) Detail(ctx context.Context, s *Session, itemID string, withChildren bool) (*ItemDetail, error) {
	// Taglines / OfficialRating / Status:「这剧完结没有」是选片时真会问的问题,
	// 比画质标签有用得多。★ 电影没有 Status,Taglines 常为空数组 ——
	// 两者都是可空,前端没值就**整行不画**,不留空位。
	u := fmt.Sprintf("%s/Users/%s/Items/%s?Fields=Overview,Genres,ProductionYear,"+
		"CommunityRating,PremiereDate,People,Taglines,OfficialRating,Status,ChildCount",
		s.Server, url.PathEscape(s.UserID), url.PathEscape(itemID))

	b, err := c.getBytes(ctx, s, u)
	if err != nil {
		return nil, err
	}
	var j map[string]any
	if err := json.Unmarshal(b, &j); err != nil {
		return nil, fmt.Errorf("解析失败: %w", err)
	}

	typ := jstr(j, "Type")

	// Series/Season 才拉子集(全部集,跨季按季号+集号排序)。手机端不要这一坨。
	var children []Item
	if withChildren && (typ == "Series" || typ == "Season") {
		// ★ 拉失败**不报错**,给空 —— 详情页主体已经有了,不该因为分集拉不动整页失败
		if eps, e := c.episodes(ctx, s, itemID); e == nil {
			children = eps
		}
	}
	if children == nil {
		children = []Item{}
	}

	genres := []string{}
	if arr, ok := j["Genres"].([]any); ok {
		for _, v := range arr {
			if sv, ok := v.(string); ok {
				genres = append(genres, sv)
			}
		}
	}

	// 演职人员:**导演优先排前**(草稿轨道从左读),其余保持服务端顺序(已按重要性)。
	// ★ 必须是**稳定**排序 —— 不稳定的话「其余保持服务端顺序」就不成立了。
	people := []Person{}
	if arr, ok := j["People"].([]any); ok {
		for _, v := range arr {
			p, ok := v.(map[string]any)
			if !ok {
				continue
			}
			name := jstr(p, "Name")
			if name == "" {
				continue // 空名字的条目服务端偶尔会给,画出来是一个没脸没名的圆圈
			}
			var role *string
			if r := jstr(p, "Role"); r != "" {
				role = &r
			}
			_, hasImg := p["PrimaryImageTag"].(string)
			people = append(people, Person{
				ID: jstr(p, "Id"), Name: name, Role: role,
				Type: jstr(p, "Type"), HasPrimary: hasImg,
			})
		}
	}
	sort.SliceStable(people, func(i, k int) bool {
		rank := func(p Person) int {
			if p.Type == "Director" {
				return 0
			}
			return 1
		}
		return rank(people[i]) < rank(people[k])
	})

	ud, _ := j["UserData"].(map[string]any)
	id := jstr(j, "Id")
	if id == "" {
		id = itemID
	}

	// ★ 背景图看 **BackdropImageTags 数组非空**,不是 ImageTags
	hasBackdrop := false
	if arr, ok := j["BackdropImageTags"].([]any); ok {
		hasBackdrop = len(arr) > 0
	}
	_, hasPrimary := jmap(j, "ImageTags")["Primary"]

	// Taglines 是数组,取第一条;空串折 nil
	var tagline *string
	if arr, ok := j["Taglines"].([]any); ok && len(arr) > 0 {
		if sv, ok := arr[0].(string); ok && sv != "" {
			tagline = &sv
		}
	}

	return &ItemDetail{
		ID:          id,
		Name:        jstr(j, "Name"),
		Type:        typ,
		Overview:    jstr(j, "Overview"),
		Year:        jint(j, "ProductionYear"),
		Genres:      genres,
		Rating:      jfloat(j, "CommunityRating"),
		RuntimeSecs: float64(jint64or0(j, "RunTimeTicks")) / 1e7,
		ResumeSecs:  float64(jint64or0(ud, "PlaybackPositionTicks")) / 1e7,
		HasPrimary:  hasPrimary,
		HasBackdrop: hasBackdrop,
		IsFavorite:  jbool(ud, "IsFavorite"),
		Played:      jbool(ud, "Played"),
		SeasonID:    jstrPtr(j, "SeasonId"),
		// ★ 这里**不**折空串 —— 与 Item 的映射不同。Rust 侧是 `.as_str().map(String::from)`,
		//   没有 `.filter(非空)`。照搬,不许「统一一下」。
		SeriesName: jstrPtr(j, "SeriesName"),
		SeriesID:   jstrPtr(j, "SeriesId"),
		SeasonNo:   jint(j, "ParentIndexNumber"),
		EpisodeNo:  jint(j, "IndexNumber"),

		OfficialRating: jstrPtrNonEmpty(j, "OfficialRating"),
		Status:         jstrPtrNonEmpty(j, "Status"),
		Tagline:        tagline,
		ChildCount:     jint(j, "ChildCount"),
		Children:       children,
		People:         people,
	}, nil
}

// Seasons 某剧的季列表。
//
// ★ 有些剧**没有季**(单季番剧直接挂集)。那种情况这里返回空切片,
// 调用方要回落到「拿 seriesId 当 parent 直接分页拉集」——
// 不回落的表现是「点进去一集都没有」,而且不报错。
func (c *Client) Seasons(ctx context.Context, s *Session, seriesID string) ([]SeasonInfo, error) {
	u := fmt.Sprintf("%s/Users/%s/Items?ParentId=%s&IncludeItemTypes=Season"+
		"&SortBy=IndexNumber&SortOrder=Ascending&Fields=ChildCount",
		s.Server, url.PathEscape(s.UserID), url.QueryEscape(seriesID))
	b, err := c.getBytes(ctx, s, u)
	if err != nil {
		return nil, err
	}
	var j map[string]any
	if err := json.Unmarshal(b, &j); err != nil {
		return nil, fmt.Errorf("解析失败: %w", err)
	}
	out := []SeasonInfo{}
	arr, _ := j["Items"].([]any)
	for _, v := range arr {
		m, ok := v.(map[string]any)
		if !ok {
			continue
		}
		ud, _ := m["UserData"].(map[string]any)
		_, hasImg := jmap(m, "ImageTags")["Primary"]
		out = append(out, SeasonInfo{
			ID:         jstr(m, "Id"),
			Name:       jstr(m, "Name"),
			IndexNo:    jint(m, "IndexNumber"),
			ChildCount: jint64or0(m, "ChildCount"),
			Unplayed:   jint64or0(ud, "UnplayedItemCount"),
			HasPrimary: hasImg,
		})
	}
	return out, nil
}

// SeasonEpisodes 某季(或某剧)的分集**分页**拉取。手机端详情页滚到底续拉靠它。
//
// ★ `parentID` 可以是季 id,也可以是剧 id(没分季的剧)。
// ★ **不走 fetchAllPaged** —— 这里要的就是「只拿这一页」,全量拉正是要避开的那件事。
// ★ 带 `Fields=MediaSources` 才有分集卡那行「2160p · 45M · 18.4G」。
func (c *Client) SeasonEpisodes(ctx context.Context, s *Session, parentID string, startIndex, limit int) (*Page, error) {
	if limit > ServerPageCap {
		limit = ServerPageCap
	}
	u := fmt.Sprintf("%s/Users/%s/Items?ParentId=%s&IncludeItemTypes=Episode&Recursive=true"+
		"&SortBy=ParentIndexNumber,IndexNumber&SortOrder=Ascending"+
		"&Fields=PrimaryImageAspectRatio,MediaSources,Overview,PremiereDate"+
		"&StartIndex=%d&Limit=%d",
		s.Server, url.PathEscape(s.UserID), url.QueryEscape(parentID), startIndex, limit)
	return c.fetchPage(ctx, s, u)
}

// episodes 全量拉某剧的分集(跨季按季号+集号排序)。带 MediaSources。
func (c *Client) episodes(ctx context.Context, s *Session, seriesID string) ([]Item, error) {
	base := fmt.Sprintf("%s/Users/%s/Items?ParentId=%s&IncludeItemTypes=Episode&Recursive=true"+
		"&SortBy=ParentIndexNumber,IndexNumber&SortOrder=Ascending"+
		"&Fields=PrimaryImageAspectRatio,MediaSources",
		s.Server, url.PathEscape(s.UserID), url.QueryEscape(seriesID))
	return c.fetchAllPaged(ctx, s, base, 3000)
}

// ---------------------------------------------------------------- JSON 小工具
//
// 详情这条链在 Rust 侧是直接对 serde_json::Value 索引的(不是强类型结构),
// 所以这里也用同样的取法 —— 结构不同会引入「字段缺失时的行为」差异。

func jstr(m map[string]any, k string) string {
	v, _ := m[k].(string)
	return v
}

func jstrPtr(m map[string]any, k string) *string {
	v, ok := m[k].(string)
	if !ok {
		return nil
	}
	return &v
}

func jstrPtrNonEmpty(m map[string]any, k string) *string {
	v, ok := m[k].(string)
	if !ok || v == "" {
		return nil
	}
	return &v
}

func jint(m map[string]any, k string) *int64 {
	v, ok := m[k].(float64)
	if !ok {
		return nil
	}
	n := int64(v)
	return &n
}

func jint64or0(m map[string]any, k string) int64 {
	v, _ := m[k].(float64)
	return int64(v)
}

func jfloat(m map[string]any, k string) *float64 {
	v, ok := m[k].(float64)
	if !ok {
		return nil
	}
	return &v
}

func jbool(m map[string]any, k string) bool {
	v, _ := m[k].(bool)
	return v
}

func jmap(m map[string]any, k string) map[string]any {
	v, _ := m[k].(map[string]any)
	if v == nil {
		return map[string]any{}
	}
	return v
}
