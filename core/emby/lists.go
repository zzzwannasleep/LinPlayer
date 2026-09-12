package emby

// 首页 / 媒体库 / 收藏这几条列表路径。
//
// **每个函数上面那段注释都是从 Rust 版逐字搬来的**,不是我总结的 ——
// 它们记着「为什么不能写成看起来更简洁的样子」。删注释 = 下一次同样的坑原样炸回来。

import (
	"context"
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"net/url"
	"sort"
	"strconv"
	"strings"

	"linplayer/core/blocklist"
)

// ServerPageCap 是服务端对 Limit 的硬上限。
//
// ★ **服务端把任何 Limit 都夹到这个值**,写 `Limit=500` 只会**静默少拿**。
// 想要「全部」就必须自己按 StartIndex 翻到底。
const ServerPageCap = 200

// 让 Item 满足 blocklist.Item —— 屏蔽判定不依赖 emby 包,反过来也一样。
func (i Item) BlockID() string   { return i.ID }
func (i Item) BlockName() string { return i.Name }
func (i Item) BlockSeriesID() string {
	if i.SeriesID == nil {
		return ""
	}
	return *i.SeriesID
}
func (i Item) BlockSeriesName() string {
	if i.SeriesName == nil {
		return ""
	}
	return *i.SeriesName
}
func (i Item) HasSeriesName() bool { return i.SeriesName != nil }

// filterBlocked 就地滤掉被屏蔽的条目。**名单为空时一个条目都不碰**(常见路径的零开销)。
func filterBlocked(items []Item) []Item {
	if len(blocklist.List()) == 0 {
		return items
	}
	out := items[:0]
	for _, it := range items {
		if !blocklist.IsBlocked(it) {
			out = append(out, it)
		}
	}
	return out
}

// fetchItems 只要条目、不关心总数的调用点(继续观看/接下来看/收藏/合集/搜索/相似/分集…)。
//
// ★ **屏蔽名单在这里生效,不在各端页面里。** 三端共用,一处顶十几处。
// ★ **媒体库网格不走这里**(它直接调 fetchPage):被屏蔽的卡片必须留在媒体库里,
// 否则用户点错一次就再也找不到那部剧去解除屏蔽了。
func (c *Client) fetchItems(ctx context.Context, s *Session, u string) ([]Item, error) {
	p, err := c.fetchPage(ctx, s, u)
	if err != nil {
		return nil, err
	}
	return filterBlocked(p.Items), nil
}

// fetchAllPaged 翻页拉全。
//
// ★ 服务端把任何 Limit 都夹到 ServerPageCap,写 `Limit=500` 只会**静默少拿**。
//
// `max` 是安全闸:防某天对上一个几万条的库把内存和服务端一起打爆。
// 到闸就停并返回已拿到的,**不报错** —— 对收藏/分集这两个场景,
// 拿到前 max 条远好过整页失败。
func (c *Client) fetchAllPaged(ctx context.Context, s *Session, baseURL string, max int) ([]Item, error) {
	// ★ **空切片不是 nil**:nil 序列化成 JSON `null`,而黄金实现给的是 `[]`。
	//   一条收藏都没有时前端拿到 null 直接 `.map()` 会抛错,
	//   在透明窗口下就是**一片黑且不报错** —— 本仓最难查的那类。
	out := []Item{}
	for {
		u := fmt.Sprintf("%s&StartIndex=%d&Limit=%d", baseURL, len(out), ServerPageCap)
		page, err := c.fetchItems(ctx, s, u)
		if err != nil {
			return nil, err
		}
		got := len(page)
		out = append(out, page...)
		// 不足一页 = 到底了;够一页但触闸也停(别无限翻)
		if got < ServerPageCap || len(out) >= max {
			break
		}
	}
	return out, nil
}

// ---------------------------------------------------------------- 媒体库网格

// ItemQuery 是媒体库筛选条件。
type ItemQuery struct {
	Limit      *int     `json:"limit"`
	StartIndex *int     `json:"start_index"`
	SortBy     *string  `json:"sort_by"`
	SortOrder  *string  `json:"sort_order"`
	Genres     []string `json:"genres"`
	Tags       []string `json:"tags"`
	Studios    []string `json:"studios"`
	Years      []int64  `json:"years"`
	RatingMin  *float64 `json:"rating_min"`
	RatingMax  *float64 `json:"rating_max"`
}

func (q *ItemQuery) needsLocalFilter() bool {
	return len(q.Genres) > 0 || len(q.Tags) > 0 || len(q.Studios) > 0 ||
		len(q.Years) > 0 || q.RatingMin != nil || q.RatingMax != nil
}

func (q *ItemQuery) matches(it Item) bool {
	if len(q.Genres) > 0 {
		hit := false
		for _, g := range q.Genres {
			for _, x := range it.Genres {
				if strings.EqualFold(x, g) {
					hit = true
				}
			}
		}
		if !hit {
			return false
		}
	}
	if len(q.Years) > 0 {
		hit := false
		for _, y := range q.Years {
			if it.Year != nil && *it.Year == y {
				hit = true
			}
		}
		if !hit {
			return false
		}
	}
	if q.RatingMin != nil && (it.Rating == nil || *it.Rating < *q.RatingMin) {
		return false
	}
	if q.RatingMax != nil && (it.Rating == nil || *it.Rating > *q.RatingMax) {
		return false
	}
	return true
}

// Items 媒体库网格。
//
// ★ **服务端过滤在部分 Emby 上是假的**:实测某 fork 对
// Genres/GenreIds/Years/MinCommunityRating 一律忽略 —— 传 `Genres=喜剧` 返回的
// TotalRecordCount 与不传完全一致,头几条根本没有喜剧标签。
// 所以参数照发(标准 Emby/Jellyfin 认,服务端过滤能少传数据),
// 同时在客户端按同样条件**复筛一遍**:认参数的服务器上复筛是 no-op,
// 不认的服务器上至少保证**不会显示不匹配的条目**。
//
// ponytail: 复筛只作用于当前这一页 —— 要完整结果需服务端支持,或改成翻页累加。
// **宁可少给,不能给错。**
func (c *Client) Items(ctx context.Context, s *Session, parentID string, q *ItemQuery) (*Page, error) {
	if q == nil {
		q = &ItemQuery{}
	}
	// Fields 必须带 Genres/ProductionYear/CommunityRating,否则客户端复筛没有判据。
	var b strings.Builder
	fmt.Fprintf(&b, "%s/Users/%s/Items?ParentId=%s&Recursive=true&IncludeItemTypes=Movie,Series"+
		"&Fields=PrimaryImageAspectRatio,Genres,ProductionYear,CommunityRating",
		s.Server, url.PathEscape(s.UserID), url.QueryEscape(parentID))

	limit := ServerPageCap
	if q.Limit != nil && *q.Limit < ServerPageCap {
		limit = *q.Limit
	}
	fmt.Fprintf(&b, "&Limit=%d", limit)
	if q.StartIndex != nil {
		fmt.Fprintf(&b, "&StartIndex=%d", *q.StartIndex)
	}
	// ★ SortOrder 必须跟着 SortBy 一起发:实测只发 StartIndex 不发 SortOrder 时排序不稳,
	//   翻页会拿到重复 / 错位的条目。
	sortBy, sortOrder := "SortName", "Ascending"
	if q.SortBy != nil && *q.SortBy != "" {
		sortBy = *q.SortBy
	}
	if q.SortOrder != nil && *q.SortOrder != "" {
		sortOrder = *q.SortOrder
	}
	fmt.Fprintf(&b, "&SortBy=%s&SortOrder=%s", url.QueryEscape(sortBy), url.QueryEscape(sortOrder))

	// Genres/Tags/Studios 竖线分隔,Years 逗号分隔(Emby 约定)
	pushList(&b, "Genres", q.Genres, "|")
	pushList(&b, "Tags", q.Tags, "|")
	pushList(&b, "Studios", q.Studios, "|")
	if len(q.Years) > 0 {
		parts := make([]string, 0, len(q.Years))
		for _, y := range q.Years {
			parts = append(parts, strconv.FormatInt(y, 10))
		}
		fmt.Fprintf(&b, "&Years=%s", strings.Join(parts, ","))
	}
	// Emby 只有下界参数(无 MaxCommunityRating),上界只能靠客户端复筛
	if q.RatingMin != nil {
		fmt.Fprintf(&b, "&MinCommunityRating=%v", *q.RatingMin)
	}

	page, err := c.fetchPage(ctx, s, b.String())
	if err != nil {
		return nil, err
	}
	if q.needsLocalFilter() {
		before := len(page.Items)
		kept := page.Items[:0]
		for _, it := range page.Items {
			if q.matches(it) {
				kept = append(kept, it)
			}
		}
		page.Items = kept
		// ★ 复筛动过手 → 服务端的 TotalRecordCount 不再是筛后总数,报本页实际条数,
		//   免得前端按几千条画出永远翻不满的页码。
		if len(page.Items) != before {
			page.Total = int64(len(page.Items))
		}
	}
	return page, nil
}

func pushList(b *strings.Builder, key string, vals []string, sep string) {
	if len(vals) == 0 {
		return
	}
	parts := make([]string, 0, len(vals))
	for _, v := range vals {
		parts = append(parts, url.QueryEscape(v))
	}
	fmt.Fprintf(b, "&%s=%s", key, strings.Join(parts, sep))
}

// ---------------------------------------------------------------- 首页几条轨道

// Latest 首页「最新更新」轨道:某库最近入库条目
// (GroupItems 让剧集归并到剧,避免刷一堆单集)。
//
// ★ **Latest 端点直接返回裸数组**(非 {Items} 包裹),所以不走 fetchItems ——
// **屏蔽过滤得自己补一句**。漏了的表现就是
// 「首页别的行都干净了,唯独『最新更新』里还挂着」。
func (c *Client) Latest(ctx context.Context, s *Session, parentID string, limit int) ([]Item, error) {
	u := fmt.Sprintf("%s/Users/%s/Items/Latest?ParentId=%s&GroupItems=true&Limit=%d"+
		"&Fields=PrimaryImageAspectRatio",
		s.Server, url.PathEscape(s.UserID), url.QueryEscape(parentID), limit)

	b, err := c.getBytes(ctx, s, u)
	if err != nil {
		return nil, err
	}
	var raws []rawItem
	if err := json.Unmarshal(b, &raws); err != nil {
		return nil, fmt.Errorf("解析失败: %w", err)
	}
	items := make([]Item, 0, len(raws))
	for _, r := range raws {
		items = append(items, fromRaw(r))
	}
	return filterBlocked(items), nil
}

// Resume 继续观看(有播放进度的条目)。
func (c *Client) Resume(ctx context.Context, s *Session, limit int) ([]Item, error) {
	u := fmt.Sprintf("%s/Users/%s/Items/Resume?Limit=%d&MediaTypes=Video&Recursive=true"+
		"&Fields=PrimaryImageAspectRatio", s.Server, url.PathEscape(s.UserID), limit)
	return c.fetchItems(ctx, s, u)
}

// NextUp 接下来播放(/Shows/NextUp)。
// 返回的是 Episode,**靠 SeriesName 才认得出是哪部剧**。
func (c *Client) NextUp(ctx context.Context, s *Session, limit int) ([]Item, error) {
	u := fmt.Sprintf("%s/Shows/NextUp?UserId=%s&Limit=%d"+
		"&Fields=PrimaryImageAspectRatio,Genres,ProductionYear,CommunityRating",
		s.Server, url.QueryEscape(s.UserID), limit)
	return c.fetchItems(ctx, s, u)
}

// Collections 合集。
func (c *Client) Collections(ctx context.Context, s *Session) ([]Item, error) {
	u := fmt.Sprintf("%s/Users/%s/Items?IncludeItemTypes=BoxSet&Recursive=true"+
		"&SortBy=SortName&SortOrder=Ascending"+
		"&Fields=PrimaryImageAspectRatio,Genres,ProductionYear,CommunityRating&Limit=%d",
		s.Server, url.PathEscape(s.UserID), ServerPageCap)
	return c.fetchItems(ctx, s, u)
}

// Favorites 收藏列表(IsFavorite 过滤,跨库递归)。
//
// ★ 原来写 `Limit=300` —— 服务端夹到 200,收藏超过 200 条就**静默丢**,
// 用户看不到也无从察觉。改翻页。
//
// ★ **排序不走服务端。** 实测某 fork 在 `Filters=IsFavorite` 查询上直接无视
// SortBy/SortOrder(`SortName&Ascending` 与 `CommunityRating&Descending` 返回
// **完全相同**的顺序,恒为 DateCreated 降序);原版 Emby 是认的 ——
// **别拿原版的结论替 fork 签字**。所以这里只负责把 Fields 要全,排序交给前端本地做。
func (c *Client) Favorites(ctx context.Context, s *Session) ([]Item, error) {
	base := fmt.Sprintf("%s/Users/%s/Items?Filters=IsFavorite&Recursive=true"+
		"&IncludeItemTypes=Movie,Series,Episode"+
		"&Fields=PrimaryImageAspectRatio,CommunityRating,DateCreated,DateLastMediaAdded,SortName",
		s.Server, url.PathEscape(s.UserID))
	return c.fetchAllPaged(ctx, s, base, 2000)
}

// FavoriteSorts 收藏页的排序档位,**第一条是默认档**
// 【用户定 2026-09-12:「增加 收藏的排序功能,方便及时查看更新内容」】。
//
// 默认给「更新时间」而不是「加入时间」:收藏是用来追更的,要问的是
// 「哪一部刚出新集」,而「什么时候收的」排出来的是另一个问题的答案。
var FavoriteSorts = []string{"更新时间", "名称", "评分", "年份"}

// SortFavorites 就地排序收藏列表。认不出的档位一律按第一档,不报错。
//
// ★ **只能在本地排。** 某 fork 在 `Filters=IsFavorite` 上直接无视 SortBy
// (见 [Client.Favorites]),送上去等于什么都没做,而且返回 200。
// ★ 排序放核心层不放两端:两端各写一份,改一处漏一处,
// 漏掉的那端只是顺序悄悄不一样 —— 没人会报上来。
func SortFavorites(items []Item, by string) {
	// 缺值一律沉底:排序档位是「按什么看」,而没有那个值的条目回答不了这个问题
	less := map[string]func(a, b *Item) bool{
		"名称": func(a, b *Item) bool { return sortKey(a) < sortKey(b) },
		"评分": func(a, b *Item) bool { return f(a.Rating) > f(b.Rating) },
		"年份": func(a, b *Item) bool { return i64(a.Year) > i64(b.Year) },
	}[by]
	if less == nil {
		less = func(a, b *Item) bool { return sv(a.DateUpdated) > sv(b.DateUpdated) }
	}
	sort.SliceStable(items, func(x, y int) bool { return less(&items[x], &items[y]) })
}

// sortKey 名称排序的判据:优先服务端给的 SortName(「The Matrix」在 M 上而不是 T)。
func sortKey(it *Item) string {
	if s := sv(it.SortName); s != "" {
		return s
	}
	return it.Name
}

func sv(p *string) string {
	if p == nil {
		return ""
	}
	return *p
}

func f(p *float64) float64 {
	if p == nil {
		return -1
	}
	return *p
}

func i64(p *int64) int64 {
	if p == nil {
		return -1
	}
	return *p
}

// ---------------------------------------------------------------- 统计

// Counts 媒体库规模统计。
type Counts struct {
	Movie   uint64 `json:"movie"`
	Series  uint64 `json:"series"`
	Episode uint64 `json:"episode"`
	BoxSet  uint64 `json:"boxset"`
}

// CountsOf `GET /Items/Counts?UserId=` —— **一次调用**拿到全库规模,
// 不要自己翻页数条目。
//
// ★ **`UserId` 必须带。** 不带的话服务端把**该用户看不到的库**也算进去。
// 实测差值:带 UserId → Movie 1579 / Series 2393 / Episode 98476;
// 不带 → 1618 / 2652 / 99346。差 39 部电影、259 部剧、870 集 ——
// 数字看着都「像那么回事」,所以漏了不会有人发现。
//
// ★ 这个端点在某些 fork 上是 404(同文件里 /Items/Filters、/Years、/Tags 就都是)。
// **调用方必须容忍它失败** —— 统计条是锦上添花,不该让首页整个报错。
func (c *Client) CountsOf(ctx context.Context, s *Session) (*Counts, error) {
	u := fmt.Sprintf("%s/Items/Counts?UserId=%s", s.Server, url.QueryEscape(s.UserID))
	b, err := c.getBytes(ctx, s, u)
	if err != nil {
		return nil, err
	}
	var j map[string]any
	if err := json.Unmarshal(b, &j); err != nil {
		return nil, fmt.Errorf("解析失败: %w", err)
	}
	n := func(k string) uint64 {
		if v, ok := j[k].(float64); ok && v > 0 {
			return uint64(v)
		}
		return 0
	}
	return &Counts{
		Movie:   n("MovieCount"),
		Series:  n("SeriesCount"),
		Episode: n("EpisodeCount"),
		BoxSet:  n("BoxSetCount"),
	}, nil
}

// getBytes 是所有「不走 {Items} 包裹」的端点共用的取字节。
func (c *Client) getBytes(ctx context.Context, s *Session, u string) ([]byte, error) {
	req, err := http.NewRequestWithContext(ctx, http.MethodGet, u, nil)
	if err != nil {
		return nil, fmt.Errorf("请求构造失败: %w", err)
	}
	req.Header.Set("X-Emby-Token", s.Token)
	req.Header.Set("User-Agent", c.UA)
	/* ★★ **不要手动设 Accept-Encoding**。
	   Go 的 Transport 会自己加 `Accept-Encoding: gzip` 并把响应**自动解压**;
	   但只要调用方手动设了这个头,Go 就认为「你要自己处理压缩」,于是不再解压,
	   把原始 gzip 字节交给你 —— 表现是每一条列表都报
	   「解析失败: invalid character '' looking for beginning of value」
	   ( 是 gzip 魔数的第一个字节)。

	   黄金实现用的是 reqwest 的 gzip feature,那是**发头 + 解压一起**做的;
	   照抄时只抄了「要发头」这一半,就成了这个洞。
	   2026-08-31 用户拿真 Emby 实测撞上 —— 假 Emby 不开压缩,本地全绿。 */
	resp, err := c.HTTP.Do(req)
	if err != nil {
		return nil, fmt.Errorf("网络错误: %w", err)
	}
	defer resp.Body.Close()
	if resp.StatusCode < 200 || resp.StatusCode >= 300 {
		return nil, &StatusError{Status: resp.StatusCode, What: "取数据"}
	}
	return io.ReadAll(resp.Body)
}

// FilterBlockedLibraries 媒体库列表的屏蔽过滤。**只有命令层调它。**
//
// ★ 缺省过滤,`includeBlocked=true` 才给全量 —— 只有媒体库页那份列表要全量:
// 它是唯一能把库找回来解除屏蔽的地方,滤掉就成了**单向门**。
// 2026-08-02 真发生过(用户屏蔽完两个库来问「那我怎么恢复呢」)。
//
// ★ 这里**不走** blocklist.IsBlocked(那条按 series_id / 名字比,是给条目用的):
// 库没有 series_id,而「名字对得上」在库上是错的判据 —— 两台服务器上都叫
// 「电影」的库是两个不同的库,按名字判会一屏两台一起屏蔽。
func FilterBlockedLibraries(items []Item, includeBlocked bool) []Item {
	if includeBlocked {
		return items
	}
	out := items[:0]
	for _, it := range items {
		if !blocklist.IsBlockedID(it.ID) {
			out = append(out, it)
		}
	}
	return out
}

// CollectionItems 一个合集里的条目,**影片和剧集分开装**。
type CollectionItems struct {
	Movies []Item `json:"movies"`
	Series []Item `json:"series"`
	Others []Item `json:"others"`
}

// Collection 拉合集的成员。
//
// ☠ **合集详情页原来一个字都画不出来**:详情那条链只对 Series/Season 拉子项
// (detail.go 的 withChildren 判断、两端 DetailPage 的 type 判断都一样),
// 而合集本身没有简介、没有年份、没有演职员 —— 于是整页只剩一个标题。
//
// ★ 主查询**不带 Recursive**:合集的成员就是它的直接子项,递归下去会把
// 成员剧里的季和集一起翻出来。空表时才退一步用 Recursive + 类型过滤 ——
// 有的 fork 对 BoxSet 的非递归查询回空,而「回空」和「这个合集是空的」
// 长得一模一样,不退这一步就永远查不出是哪一种。
func (c *Client) Collection(ctx context.Context, s *Session, boxsetID string) (*CollectionItems, error) {
	const fields = "&Fields=PrimaryImageAspectRatio,Genres,ProductionYear,CommunityRating" +
		"&SortBy=SortName&SortOrder=Ascending"
	base := fmt.Sprintf("%s/Users/%s/Items?ParentId=%s",
		s.Server, url.PathEscape(s.UserID), url.QueryEscape(boxsetID))

	items, err := c.fetchItems(ctx, s, base+fields+fmt.Sprintf("&Limit=%d", ServerPageCap))
	if err != nil {
		return nil, err
	}
	if len(items) == 0 {
		items, err = c.fetchItems(ctx, s,
			base+"&Recursive=true&IncludeItemTypes=Movie,Series"+fields+
				fmt.Sprintf("&Limit=%d", ServerPageCap))
		if err != nil {
			return nil, err
		}
	}
	return splitCollection(items), nil
}

// splitCollection 按类型分堆。拆出来是为了可测 —— 分堆规则就是这个函数的全部内容。
//
// ★ 三个字段都保证是**空切片而不是 nil**:nil 序列化成 JSON `null`,
// 前端 `.map()` 当场抛错,而透明窗口下抛错就是一片黑且不报错。
func splitCollection(items []Item) *CollectionItems {
	out := &CollectionItems{Movies: []Item{}, Series: []Item{}, Others: []Item{}}
	for _, it := range items {
		switch it.Type {
		case "Movie":
			out.Movies = append(out.Movies, it)
		case "Series":
			out.Series = append(out.Series, it)
		default:
			// 合集里塞得进音乐视频、纪录片文件夹、甚至另一个合集。
			// 归到「其它」而不是丢掉:丢掉的表现还是「显示不出来东西」。
			out.Others = append(out.Others, it)
		}
	}
	return out
}
