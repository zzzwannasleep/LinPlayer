// Package emby 是 Emby 客户端。
//
// 移植自 `crates/core/src/emby.rs`。**Rust 版是黄金实现** —— 这里的每一处行为
// 都要和它逐字对齐,包括那些看起来像 bug 的地方(它们多半是修过的坑)。
// 差分对账(`tools/diffcheck`)就是用来钉住这件事的。
package emby

import (
	"context"
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"net/url"
	"time"
)

// Session 一次会话所需的全部身份信息。
type Session struct {
	Server   string `json:"server"`
	Token    string `json:"token"`
	UserID   string `json:"user_id"`
	DeviceID string `json:"device_id"`
}

// Item 是列表 / 详情通用的条目。字段与 Rust 版 `emby::Item` **一一对应**,
// JSON 名也一致 —— 对账靠的就是这个。
type Item struct {
	ID          string  `json:"id"`
	Name        string  `json:"name"`
	Type        string  `json:"type_"`
	IsFolder    bool    `json:"is_folder"`
	HasPrimary  bool    `json:"has_primary"`
	RuntimeSecs float64 `json:"runtime_secs"`
	ResumeSecs  float64 `json:"resume_secs"`

	// 剧集所属剧名。Emby 的 Episode.Name 只是「第 35 集」,单看无意义 ——
	// 继续观看/收藏/搜索等混排列表必须靠它才说得清是哪部剧。
	SeriesName *string `json:"series_name"`
	EpisodeNo  *int64  `json:"episode_no"`
	SeasonNo   *int64  `json:"season_no"`

	// 以下三项仅在请求带 Fields=MediaSources 时有值。
	VideoHeight *int64 `json:"video_height"`
	Bitrate     *int64 `json:"bitrate"`
	SizeBytes   *int64 `json:"size_bytes"`

	Played bool `json:"played"`
	// 未看子项数。played=true 时必为 0(全看完),前端据此:有勾优先、否则显数字。
	UnplayedItemCount int64 `json:"unplayed_item_count"`

	Genres []string `json:"genres"`
	Year   *int64   `json:"year"`
	Rating *float64 `json:"rating"`

	// 跨服务器续播强匹配的判据。缺了不崩,但匹配会静默降级到「剧名+季集号」——
	// 那正是跨服续播最容易假装能用的失败形态。
	ProviderIDs           map[string]string `json:"provider_ids"`
	PresentationUniqueKey *string           `json:"presentation_unique_key"`
	Path                  *string           `json:"path"`
	SeriesID              *string           `json:"series_id"`

	// 「更新时间」排序用。DateLastMediaAdded 优先(剧集新集入库才动),没有就 DateCreated。
	DateUpdated *string `json:"date_updated"`
	SortName    *string `json:"sort_name"`
}

// Page 一页结果(含总数)。
type Page struct {
	Items []Item `json:"items"`
	Total int64  `json:"total"`
}

// ---------------------------------------------------------------- 线上结构

type rawItem struct {
	ID                    string            `json:"Id"`
	Name                  *string           `json:"Name"`
	Type                  *string           `json:"Type"`
	IsFolder              *bool             `json:"IsFolder"`
	CollectionType        *string           `json:"CollectionType"`
	ImageTags             map[string]any    `json:"ImageTags"`
	RunTimeTicks          *int64            `json:"RunTimeTicks"`
	UserData              *rawUserData      `json:"UserData"`
	SeriesName            *string           `json:"SeriesName"`
	IndexNumber           *int64            `json:"IndexNumber"`
	ParentIndexNumber     *int64            `json:"ParentIndexNumber"`
	MediaSources          []rawMediaSource  `json:"MediaSources"`
	Genres                []string          `json:"Genres"`
	ProductionYear        *int64            `json:"ProductionYear"`
	CommunityRating       *float64          `json:"CommunityRating"`
	ProviderIDs           map[string]string `json:"ProviderIds"`
	PresentationUniqueKey *string           `json:"PresentationUniqueKey"`
	Path                  *string           `json:"Path"`
	SeriesID              *string           `json:"SeriesId"`
	DateCreated           *string           `json:"DateCreated"`
	DateLastMediaAdded    *string           `json:"DateLastMediaAdded"`
	SortName              *string           `json:"SortName"`
}

type rawUserData struct {
	PlaybackPositionTicks *int64 `json:"PlaybackPositionTicks"`
	Played                *bool  `json:"Played"`
	UnplayedItemCount     *int64 `json:"UnplayedItemCount"`
}

type rawMediaSource struct {
	Size         *int64           `json:"Size"`
	Bitrate      *int64           `json:"Bitrate"`
	MediaStreams []rawMediaStream `json:"MediaStreams"`
}

type rawMediaStream struct {
	Type   *string `json:"Type"`
	Height *int64  `json:"Height"`
}

type itemsResponse struct {
	Items            []rawItem `json:"Items"`
	TotalRecordCount *int64    `json:"TotalRecordCount"`
}

// nonEmpty 把空字符串折成 nil。
//
// ★ 这不是洁癖:Rust 版对 series_name / presentation_unique_key / path /
// series_id / date_updated / sort_name **都做了 `.filter(|s| !s.is_empty())`**。
// 少做一处,对账就会在那个字段上报 "" vs null 的差异 —— 而那个差异到了 UI 上
// 是「本该空着的地方显示了一个空标签」。
func nonEmpty(p *string) *string {
	if p == nil || *p == "" {
		return nil
	}
	return p
}

func fromRaw(r rawItem) Item {
	_, hasPrimary := r.ImageTags["Primary"]
	isFolder := (r.IsFolder != nil && *r.IsFolder) || r.CollectionType != nil

	// 主版本(第一个 MediaSource)的规格,只为分集卡那行小字;没请求 Fields 时全 nil。
	var ms *rawMediaSource
	if len(r.MediaSources) > 0 {
		ms = &r.MediaSources[0]
	}
	var videoHeight, bitrate, sizeBytes *int64
	if ms != nil {
		bitrate, sizeBytes = ms.Bitrate, ms.Size
		for i := range ms.MediaStreams {
			s := ms.MediaStreams[i]
			if s.Type != nil && *s.Type == "Video" {
				videoHeight = s.Height
				break
			}
		}
	}

	var resumeTicks int64
	var played bool
	var unplayed int64
	if r.UserData != nil {
		if r.UserData.PlaybackPositionTicks != nil {
			resumeTicks = *r.UserData.PlaybackPositionTicks
		}
		if r.UserData.Played != nil {
			played = *r.UserData.Played
		}
		if r.UserData.UnplayedItemCount != nil {
			unplayed = *r.UserData.UnplayedItemCount
		}
	}

	str := func(p *string) string {
		if p == nil {
			return ""
		}
		return *p
	}
	i64 := func(p *int64) int64 {
		if p == nil {
			return 0
		}
		return *p
	}

	// ★ Rust 原文:`r.date_last_media_added.or(r.date_created).filter(|s| !s.is_empty())`
	//
	// `Option::or` 只在 **None** 时取后者 —— `Some("")` 会让它直接短路,
	// **不回退到 DateCreated**,再被 filter 折成 None。
	// 我第一版写成了「空串也回退」,差分对账当场抓到:
	//   [0].date_updated 值不同:期望 null,实得 "2024-01-01T00:00:00Z"
	// 这条差异在 UI 上是「本该没有更新时间的条目显示了入库时间」,排序会跟着错。
	// **黄金实现里看起来像 bug 的地方也不许顺手改** —— 那会破坏对账基准。
	dateUpdated := r.DateLastMediaAdded
	if dateUpdated == nil {
		dateUpdated = r.DateCreated
	}

	genres := r.Genres
	if genres == nil {
		genres = []string{}
	}
	providers := r.ProviderIDs
	if providers == nil {
		providers = map[string]string{}
	}

	return Item{
		ID:                    r.ID,
		Name:                  str(r.Name),
		Type:                  str(r.Type),
		IsFolder:              isFolder,
		HasPrimary:            hasPrimary,
		RuntimeSecs:           float64(i64(r.RunTimeTicks)) / 1e7,
		ResumeSecs:            float64(resumeTicks) / 1e7,
		SeriesName:            nonEmpty(r.SeriesName),
		EpisodeNo:             r.IndexNumber,
		SeasonNo:              r.ParentIndexNumber,
		VideoHeight:           videoHeight,
		Bitrate:               bitrate,
		SizeBytes:             sizeBytes,
		Played:                played,
		UnplayedItemCount:     unplayed,
		Genres:                genres,
		Year:                  r.ProductionYear,
		Rating:                r.CommunityRating,
		ProviderIDs:           providers,
		PresentationUniqueKey: nonEmpty(r.PresentationUniqueKey),
		Path:                  nonEmpty(r.Path),
		SeriesID:              nonEmpty(r.SeriesID),
		DateUpdated:           nonEmpty(dateUpdated),
		SortName:              nonEmpty(r.SortName),
	}
}

// ---------------------------------------------------------------- 出网

// Client 出网口。UA 走「Emby 道」(SPEC §14.1 三条 UA 道,不许合并)。
type Client struct {
	HTTP *http.Client
	UA   string
}

// NewClient 造一个默认客户端。
//
// ★ 超时是**空闲超时**不是整体超时(SPEC §14.1)—— 慢链路上拉一个大响应
// 合法地要几十秒,整体超时会把正常请求掐掉。这里先用整体超时占位,
// 空闲超时要在 net 层实现(TODO C33)。
func NewClient(version string) *Client {
	return &Client{
		HTTP: &http.Client{Timeout: 60 * time.Second},
		UA:   "LinPlayer/" + version,
	}
}

// fetchPage 取一页(含总数)。**所有 {Items} 包裹的列表端点都从这里过。**
func (c *Client) fetchPage(ctx context.Context, s *Session, u string) (*Page, error) {
	req, err := http.NewRequestWithContext(ctx, http.MethodGet, u, nil)
	if err != nil {
		return nil, fmt.Errorf("请求构造失败: %w", err)
	}
	req.Header.Set("X-Emby-Token", s.Token)
	// ★ 不设 UA = reqwest/Go 一个头都不发,某些 fork 的 CF 会直接 403,
	//   而且伪装成「AccessToken 无效」。curl 自带 UA,所以手测永远复现不出来。
	req.Header.Set("User-Agent", c.UA)
	// Emby 支持 gzip;不声明的话大列表会白跑很多带宽
	req.Header.Set("Accept-Encoding", "gzip")

	resp, err := c.HTTP.Do(req)
	if err != nil {
		return nil, fmt.Errorf("网络错误: %w", err)
	}
	defer resp.Body.Close()
	if resp.StatusCode < 200 || resp.StatusCode >= 300 {
		return nil, fmt.Errorf("请求失败: HTTP %d", resp.StatusCode)
	}
	b, err := io.ReadAll(resp.Body)
	if err != nil {
		return nil, fmt.Errorf("读响应失败: %w", err)
	}
	var data itemsResponse
	if err := json.Unmarshal(b, &data); err != nil {
		return nil, fmt.Errorf("解析失败: %w", err)
	}
	items := make([]Item, 0, len(data.Items))
	for _, r := range data.Items {
		items = append(items, fromRaw(r))
	}
	total := int64(len(items))
	if data.TotalRecordCount != nil {
		// 端点没给 TotalRecordCount 时退回本页条数,别让前端看到 0。
		total = *data.TotalRecordCount
	}
	return &Page{Items: items, Total: total}, nil
}

// Views 列出用户可见的全部媒体库。
//
// ★★ **这里故意不过滤屏蔽名单。**
//
// 屏蔽名单在 fetchItems 那条路上生效(继续观看/搜索/推荐…),**媒体库网格不走那条**:
// 被屏蔽的卡片必须留在媒体库里,否则用户点错一次就再也找不到那部剧去解除屏蔽了。
// 这条在 Rust 版是一个带长注释的断言(`emby.rs` 的 views 测试),别在移植时「顺手修好」。
func (c *Client) Views(ctx context.Context, s *Session) ([]Item, error) {
	u := fmt.Sprintf("%s/Users/%s/Views", s.Server, url.PathEscape(s.UserID))
	p, err := c.fetchPage(ctx, s, u)
	if err != nil {
		return nil, err
	}
	return p.Items, nil
}
