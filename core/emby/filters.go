package emby

// 媒体库详情的筛选分面(类型 / 标签 / 年份 / 出品方 / 分级)。
//

import (
	"context"
	"encoding/json"
	"fmt"
	"net/url"
	"sync"
)

// Filters 一个库能筛什么。
type Filters struct {
	Genres          []string `json:"genres"`
	Tags            []string `json:"tags"`
	Years           []int64  `json:"years"`
	Studios         []string `json:"studios"`
	OfficialRatings []string `json:"official_ratings"`
}

// FiltersOf 取某库的筛选分面。
//
// ★ 端点可用性是**实测**出来的,不是照文档抄的(某 fork,Emby 4.9.3):
//
//	/Items/Filters、/Users/{u}/Items/Filters2 → 404(旧栈注释里记的坑,复现了)
//	/Genres、/Studios                          → 200 ✅
//	/Years、/Tags、/OfficialRatings            → 404 ❌(旧栈也在拉这三个并**吞错**,
//	                                              所以旧版的年份/标签分面一直是空的)
//
// 故:genres/studios/tags/official_ratings 走各自分面端点(**各自吞错**,一个挂不能拖垮面板);
// years 因为没有可用端点,改用两次 Limit=1 探针取最早/最晚年份再铺成区间。
func (c *Client) FiltersOf(ctx context.Context, s *Session, parentID string) (*Filters, error) {
	var out Filters
	var wg sync.WaitGroup
	// 五路并行,各自吞错 —— 某个分面 404/500 只让它自己为空。
	for _, f := range []struct {
		endpoint string
		dst      *[]string
	}{
		{"Genres", &out.Genres},
		{"Tags", &out.Tags},
		{"Studios", &out.Studios},
		{"OfficialRatings", &out.OfficialRatings},
	} {
		wg.Add(1)
		go func() {
			defer wg.Done()
			*f.dst = c.facet(ctx, s, f.endpoint, parentID)
		}()
	}
	wg.Add(1)
	go func() {
		defer wg.Done()
		out.Years = c.yearRange(ctx, s, parentID)
	}()
	wg.Wait()
	// ★ 全空也返回成功:某个库确实可能一个分面都没有,那是「筛不了」不是「出错了」。
	//   报错的话整块筛选面板会显示红字重试,而重试永远也不会有结果。
	return &out, nil
}

// facet 某分面端点的库内取值(Items[].Name)。
//
// ★ 失败**吞掉返回空**:分面挂了不该让整个面板报错。
// ★ 返回的是**空切片不是 nil** —— nil 序列化成 JSON `null`,而黄金实现给的是 `[]`。
//
//	前端拿到 null 直接 `.map()` 会抛错,在透明窗口下就是**一片黑且不报错**。
//	这条是差分对账当场抓出来的(2026-08-31):Go 的零值切片和 Rust 的 Vec::new() 不等价。
func (c *Client) facet(ctx context.Context, s *Session, endpoint, parentID string) []string {
	u := fmt.Sprintf("%s/%s?UserId=%s&ParentId=%s&Recursive=true",
		s.Server, endpoint, url.QueryEscape(s.UserID), url.QueryEscape(parentID))
	out := []string{}
	b, err := c.getBytes(ctx, s, u)
	if err != nil {
		return out
	}
	var j struct {
		Items []struct {
			Name string `json:"Name"`
		} `json:"Items"`
	}
	if err := json.Unmarshal(b, &j); err != nil {
		return out
	}
	for _, i := range j.Items {
		if i.Name != "" {
			out = append(out, i.Name)
		}
	}
	return out
}

// yearRange 年份分面。
//
// ★ Emby **没有 /Years 端点**(实测 404),而全量扫出所有年份要翻 17 页(200/页)。
// 折中:按 ProductionYear 正/倒排各取 1 条拿到最早/最晚年,铺成倒序区间。
//
// ponytail: 区间里可能混入该库没有的年份(选了就是空结果),换取 2 次请求而非 17 次;
// 要精确年份列表得等服务端支持分面,或改成全量扫描。
func (c *Client) yearRange(ctx context.Context, s *Session, parentID string) []int64 {
	probe := func(order string) *int64 {
		u := fmt.Sprintf("%s/Users/%s/Items?ParentId=%s&Recursive=true&IncludeItemTypes=Movie,Series"+
			"&SortBy=ProductionYear&SortOrder=%s&Limit=1&Fields=ProductionYear",
			s.Server, url.PathEscape(s.UserID), url.QueryEscape(parentID), order)
		items, err := c.fetchItems(ctx, s, u)
		if err != nil || len(items) == 0 {
			return nil
		}
		return items[0].Year
	}
	var newest, oldest *int64
	var wg sync.WaitGroup
	wg.Add(2)
	go func() { defer wg.Done(); newest = probe("Descending") }()
	go func() { defer wg.Done(); oldest = probe("Ascending") }()
	wg.Wait()
	// 同上:空区间要给 `[]` 不是 nil
	if newest == nil || oldest == nil || *newest < *oldest {
		return []int64{}
	}
	out := []int64{}
	for y := *newest; y >= *oldest; y-- {
		out = append(out, y)
	}
	return out
}
