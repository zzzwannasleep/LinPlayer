package emby

// 版本与流(详情页的「媒体信息」卡、播放器的版本切换)。
//
// 移植自 `crates/core/src/emby.rs`(RawStream / StreamInfo / MediaVersion /
// media_versions / source_match_text / is_dolby_vision / random_picks)。

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

// RandomPicks 首页 Hero 的随机推荐。
// ★ 只要**有剧照**的(ImageTypes=Backdrop),否则 Hero 是一块空白。
func (c *Client) RandomPicks(ctx context.Context, s *Session, limit int) ([]Item, error) {
	u := fmt.Sprintf("%s/Users/%s/Items?Recursive=true&IncludeItemTypes=Movie,Series"+
		"&SortBy=Random&Limit=%d&ImageTypes=Backdrop"+
		"&Fields=Overview,Genres,ProductionYear,CommunityRating",
		s.Server, url.PathEscape(s.UserID), limit)
	return c.fetchItems(ctx, s, u)
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
