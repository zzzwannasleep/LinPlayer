package emby

// 版本与流(详情页的「媒体信息」卡、播放器的版本切换)。
//

import (
	"bytes"
	"context"
	"encoding/json"
	"fmt"
	"net/http"
	"net/url"
	"strings"

	"linplayer/core/media"
)

// StreamInfo 一条流(视频/音频/字幕),字段照详情页媒体信息卡的 kv 行来。
type StreamInfo struct {
	Index         int64    `json:"index"`
	Type          string   `json:"type_"` // Video | Audio | Subtitle
	Codec         string   `json:"codec"`
	Profile       *string  `json:"profile"`
	DisplayTitle  *string  `json:"display_title"`
	Language      *string  `json:"language"`
	Width         *int64   `json:"width"`
	Height        *int64   `json:"height"`
	Bitrate       *int64   `json:"bitrate"`
	Channels      *int64   `json:"channels"`
	ChannelLayout *string  `json:"channel_layout"`
	FrameRate     *float64 `json:"frame_rate"`
	VideoRange    *string  `json:"video_range"`
	VideoRangeTyp *string  `json:"video_range_type"`
	IsDefault     bool     `json:"is_default"`
	// 外挂字幕(单独文件),需要 mpv 用 sub-add 另外挂载,不在容器的 track-list 里。
	IsExternal bool `json:"is_external"`
	// 服务器给的取字幕地址(可能是相对路径)。缺失时按 index 自己拼。
	DeliveryURL *string `json:"delivery_url"`
}

// MediaVersion 一个版本(= 一个 MediaSource)。
type MediaVersion struct {
	ID          string       `json:"id"`
	Name        string       `json:"name"`
	Container   *string      `json:"container"`
	SizeBytes   *int64       `json:"size_bytes"`
	Bitrate     *int64       `json:"bitrate"`
	RuntimeSecs float64      `json:"runtime_secs"`
	Streams     []StreamInfo `json:"streams"`
	// 版本筛选正则会挑中的就是这一条。
	//
	// ★ 起播时用户没手动选版本 → 真正被播的就是它,所以详情页/播放器的「当前版本」
	// **必须显示它**,否则界面说在放第一条、实际在放另一条,
	// 用户看到的就是「正则根本没生效」—— 这正是 2026-07-30 那次误判的成因。
	// 正则留空 / 没命中 → 全 false,调用方回落第一条(和核心层的回落一致)。
	Preferred bool `json:"preferred"`
}

func versionFrom(m rawMediaSource) MediaVersion {
	streams := make([]StreamInfo, 0, len(m.MediaStreams))
	for _, s := range m.MediaStreams {
		switch deref(s.Type) {
		case "Video", "Audio", "Subtitle":
		default:
			continue // 其它类型(EmbeddedImage / Data…)不进媒体信息卡
		}
		streams = append(streams, StreamInfo{
			Index:         derefI(s.Index),
			Type:          deref(s.Type),
			Codec:         deref(s.Codec),
			Profile:       nonEmpty(s.Profile),
			DisplayTitle:  nonEmpty(s.DisplayTitle),
			Language:      nonEmpty(s.Language),
			Width:         s.Width,
			Height:        s.Height,
			Bitrate:       s.Bitrate,
			Channels:      s.Channels,
			ChannelLayout: nonEmpty(s.ChannelLayout),
			FrameRate:     s.FrameRate,
			// "Unknown" 要当没有 —— 服务端拿它当占位,原样透出去前端会画出「制式:Unknown」
			VideoRange:    notUnknown(s.VideoRange),
			VideoRangeTyp: notUnknown(s.VideoRangeType),
			IsDefault:     derefB(s.IsDefault),
			IsExternal:    derefB(s.IsExternal),
			// ★ 只认 DeliveryUrl。Path 是**服务端本地文件系统路径**(如 /media/x.ass),
			//   客户端取不到,拿来当 URL 只会 404。
			DeliveryURL: nonEmpty(s.DeliveryURL),
		})
	}
	return MediaVersion{
		ID:          deref(m.ID),
		Name:        deref(m.Name),
		Container:   nonEmpty(m.Container),
		SizeBytes:   m.Size,
		Bitrate:     m.Bitrate,
		RuntimeSecs: float64(derefI(m.RunTimeTicks)) / 1e7,
		Streams:     streams,
		// 单条源看不出「有没有被正则挑中」—— 那是整批比出来的,在 MediaVersions 里补
		Preferred: false,
	}
}

// IsDolbyVision 这条视频流是不是杜比视界。判定顺序 = 从最权威到最兜底:
//
//  1. VideoRangeType == DOVI(新版 Emby/Jellyfin 直接给结论)
//  2. codec 里带 dvhe/dvh1/dav1(DV 独立轨的编码标识)
//  3. profile 里带 "dolby vision"(老服务器只在人类可读串里体现)
//
// ★ 只看 VideoRange=HDR 会把 HDR10 一起误判成 DV → 无谓地掉进软解、白白卡顿。
func IsDolbyVision(s StreamInfo) bool {
	if s.Type != "Video" {
		return false
	}
	rt := strings.ToLower(deref(s.VideoRangeTyp))
	if strings.Contains(rt, "dovi") || strings.Contains(rt, "dolby") {
		return true
	}
	c := strings.ToLower(s.Codec)
	if strings.Contains(c, "dvhe") || strings.Contains(c, "dvh1") || strings.Contains(c, "dav1") {
		return true
	}
	return strings.Contains(strings.ToLower(deref(s.Profile)), "dolby vision")
}

// MediaVersions 取条目全部版本 + 流(走 PlaybackInfo,拿到的才是服务端真判定可播的源)。
//
// ★ versionRegex 只用来标 preferred,**不影响返回哪些版本** —— 它和真起播那条路
// 打的是同一个 PlaybackInfo 端点、同一批 MediaSource、同一套匹配文本,
// 所以这里标出来的那条,就是真起播时会被选中的那条。
func (c *Client) MediaVersions(ctx context.Context, s *Session, itemID, versionRegex string) ([]MediaVersion, error) {
	u := fmt.Sprintf("%s/Items/%s/PlaybackInfo?UserId=%s",
		s.Server, url.PathEscape(itemID), url.QueryEscape(s.UserID))
	req, err := http.NewRequestWithContext(ctx, http.MethodPost, u, bytes.NewReader([]byte("{}")))
	if err != nil {
		return nil, fmt.Errorf("请求构造失败: %w", err)
	}
	req.Header.Set("X-Emby-Token", s.Token)
	req.Header.Set("X-Emby-Authorization", c.authHeader(s.DeviceID))
	req.Header.Set("Content-Type", "application/json")
	req.Header.Set("User-Agent", c.UA)
	resp, err := c.HTTP.Do(req)
	if err != nil {
		return nil, fmt.Errorf("网络错误: %w", err)
	}
	defer resp.Body.Close()
	if resp.StatusCode < 200 || resp.StatusCode >= 300 {
		return nil, fmt.Errorf("请求失败: HTTP %d", resp.StatusCode)
	}
	var w struct {
		MediaSources []rawMediaSource `json:"MediaSources"`
	}
	if err := json.NewDecoder(resp.Body).Decode(&w); err != nil {
		return nil, fmt.Errorf("解析失败: %w", err)
	}
	texts := make([]string, 0, len(w.MediaSources))
	out := make([]MediaVersion, 0, len(w.MediaSources))
	for _, m := range w.MediaSources {
		texts = append(texts, sourceMatchText(m))
		out = append(out, versionFrom(m))
	}
	if i := media.PickIndex(texts, versionRegex); i >= 0 {
		out[i].Preferred = true
	}
	return out, nil
}

// sourceMatchText 把一个版本折成一行「可匹配文本」给版本正则用。
//
// ★ 这段文本的组成**必须和真起播那条路一模一样**,否则详情页标的那条
// 和真播的那条会不是同一条 —— 那就是「界面在撒谎」。
func sourceMatchText(m rawMediaSource) string {
	parts := []string{deref(m.Name), deref(m.Container)}
	for _, st := range m.MediaStreams {
		if deref(st.Type) != "Video" {
			continue
		}
		parts = append(parts, deref(st.DisplayTitle), deref(st.Codec), deref(st.Profile),
			deref(st.VideoRange), deref(st.VideoRangeType))
		if st.Height != nil {
			h := *st.Height
			parts = append(parts, fmt.Sprintf("%d %dp", h, h))
			// 常见口语档位。只补「不会误伤」的两档:4K 与 8K。
			if h >= 4320 {
				parts = append(parts, "8K")
			} else if h >= 2160 {
				parts = append(parts, "4K")
			}
		}
	}
	kept := parts[:0]
	for _, p := range parts {
		if p != "" {
			kept = append(kept, p)
		}
	}
	return strings.Join(kept, " ")
}

// heroOverfetch 是「要 5 条就先拉多少条」的倍数。
//
// 服务端只能保证「有剧照」,**有没有艺术字要拿回来才知道**(ImageTypes 多值在各 fork
// 上是 AND 还是 OR 不一致,不能指望)。刮了 Logo 的条目在真实库里通常是少数,
// 所以宁可多拉一屏元数据也别让 Hero 空着 —— 这一条请求本来就只要几十条的字段。
const heroOverfetch = 12

// heroMaxFetch 过取上限。库很大时 SortBy=Random 拉几百条纯属浪费。
const heroMaxFetch = 120

// RandomPicks 首页 Hero 的随机推荐。
//
// ★★ **只挑「同时有剧照和艺术字」的条目**【用户定 2026-09-06】:
// Hero 的标题走 TMDB 艺术字(Emby 的 `Logo` 图),取不到就回落排版字 ——
// 于是轮播五张里两张是艺术字、三张是宋体标题,**看着像没做完**。
// 三端(PC / 手机 / 以后的 TV)共用这一条命令,所以判据放在这里,不放在各端页面。
//
// ★ 过滤在**核心层**做而不是加 `has_logo` 字段:加字段要改 Item 的对外 JSON,
// 18 条差分对账语料会全部报「多出字段」,而这件事只有 Hero 一个消费者。
//
// ★ 一条都挑不出来时**退回只按剧照挑**:那种库(一张 Logo 都没刮)如果直接给空表,
// 首页顶上就是一块什么都没有的洞 —— 比风格不统一更糟。
func (c *Client) RandomPicks(ctx context.Context, s *Session, limit int) ([]Item, error) {
	if limit <= 0 {
		limit = 8
	}
	want := limit * heroOverfetch
	if want > heroMaxFetch {
		want = heroMaxFetch
	}
	/* ★ **不要 `Overview`。** `Item` 和 `rawItem` 里都没有这个字段,它从来没被解析过 ——
	   过取 60 条的时候那是几十 KB 的白搭,而首页第一屏正等着这条请求。
	   Hero 上要显示的只有「评分 · 年份 · 类型」。 */
	u := fmt.Sprintf("%s/Users/%s/Items?Recursive=true&IncludeItemTypes=Movie,Series"+
		"&SortBy=Random&Limit=%d&ImageTypes=Backdrop"+
		"&Fields=Genres,ProductionYear,CommunityRating",
		s.Server, url.PathEscape(s.UserID), want)

	b, err := c.getBytes(ctx, s, u)
	if err != nil {
		return nil, err
	}
	var resp itemsResponse
	if err := json.Unmarshal(b, &resp); err != nil {
		return nil, fmt.Errorf("解析失败: %w", err)
	}

	withLogo := make([]Item, 0, limit)
	fallback := make([]Item, 0, limit)
	for _, r := range resp.Items {
		it := fromRaw(r)
		if len(r.BackdropImageTags) == 0 {
			continue // 服务端说它有剧照,但 fork 常常不认 ImageTypes —— 自己再判一次
		}
		if len(fallback) < limit {
			fallback = append(fallback, it)
		}
		if r.ImageTags["Logo"] != nil {
			withLogo = append(withLogo, it)
			if len(withLogo) >= limit {
				break
			}
		}
	}
	if picked := filterBlocked(withLogo); len(picked) > 0 {
		return picked, nil
	}
	return filterBlocked(fallback), nil
}

// pickIndex 是 media.PickIndex 的本包别名 —— 取流和版本列表都要用,收在一处。
func pickIndex(texts []string, pattern string) int { return media.PickIndex(texts, pattern) }

func deref(p *string) string {
	if p == nil {
		return ""
	}
	return *p
}

func derefI(p *int64) int64 {
	if p == nil {
		return 0
	}
	return *p
}

func derefB(p *bool) bool { return p != nil && *p }

// notUnknown 把空串和 "Unknown" 一起折成 nil。
// 服务端拿 "Unknown" 当占位,原样透出去前端会画出「制式:Unknown」。
func notUnknown(p *string) *string {
	if p == nil || *p == "" || *p == "Unknown" {
		return nil
	}
	return p
}
