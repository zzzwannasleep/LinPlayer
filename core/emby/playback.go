package emby

// 取流:把一个条目变成一条 mpv 打得开的地址。
//
// 移植自 `crates/core/src/emby.rs`(resolve_stream / abs_url / seekable_path /
// supports_range / emby_prefixed / choose_prefix / subtitle_path)。
//
// **这条链路上每一处怪写法都对应一个真故障**,注释是从 Rust 侧逐字搬来的。

import (
	"bytes"
	"context"
	"encoding/json"
	"fmt"
	"net/http"
	"net/url"
	"strings"
	"sync"
)

// ExternalSub 一条外挂字幕的挂载信息。
//
// ★ 这些**不在容器里**,mpv 拿到视频 URL 后 track-list 里根本看不到它们,
// 必须播放器起来后逐条 sub-add。
type ExternalSub struct {
	URL       string  `json:"url"`
	Title     string  `json:"title"`
	Lang      *string `json:"lang"`
	IsDefault bool    `json:"is_default"`
}

// PlaybackTarget 一次播放会话的目标 + 上报三件套共享的 id。
//
// ★ PlaySessionID **必须贯穿 start/progress/stopped 三次上报** ——
// 不贯穿的表现是「看一半退出,续播进度不落地」。
type PlaybackTarget struct {
	URL           string        `json:"url"`
	ItemID        string        `json:"item_id"`
	MediaSourceID string        `json:"media_source_id"`
	PlaySessionID string        `json:"play_session_id"`
	PlayMethod    string        `json:"play_method"` // "DirectStream" | "Transcode"
	IsDolbyVision bool          `json:"is_dolby_vision"`
	ExternalSubs  []ExternalSub `json:"external_subs"`
}

// deviceProfile 是发给 PlaybackInfo 的宽松档案:声明啥都能直连,促使服务器返回 DirectStreamUrl。
//
// ★★ SubtitleProfiles **绝不能是空表**。空表 = 告诉服务器「本客户端一种字幕都不支持」,
// 服务器于是把 DeliveryMethod 判成 Encode/Drop 且**不发 DeliveryUrl**,
// 外挂字幕从源头就被掐死 —— 这是「外挂字幕不加载」的第一层根因。
var deviceProfile = map[string]any{
	"DeviceProfile": map[string]any{
		"MaxStreamingBitrate": 120000000,
		"MaxStaticBitrate":    100000000,
		"DirectPlayProfiles":  []any{map[string]string{"Type": "Video"}, map[string]string{"Type": "Audio"}},
		"TranscodingProfiles": []any{},
		"ContainerProfiles":   []any{},
		"CodecProfiles":       []any{},
		"SubtitleProfiles": []any{
			map[string]string{"Format": "srt", "Method": "External"},
			map[string]string{"Format": "subrip", "Method": "External"},
			map[string]string{"Format": "ass", "Method": "External"},
			map[string]string{"Format": "ssa", "Method": "External"},
			map[string]string{"Format": "vtt", "Method": "External"},
			map[string]string{"Format": "webvtt", "Method": "External"},
			map[string]string{"Format": "sub", "Method": "External"},
			map[string]string{"Format": "idx", "Method": "External"},
			map[string]string{"Format": "smi", "Method": "External"},
			map[string]string{"Format": "pgssub", "Method": "Embed"},
			map[string]string{"Format": "dvdsub", "Method": "Embed"},
		},
	},
}

// ResolveStream 解析播放地址:POST PlaybackInfo → 用服务器给的 DirectStreamUrl/TranscodingUrl。
//
// mediaSourceID 选哪个版本。空 = 服务器返回的第一条(或版本正则命中的那条)。
// ★ **指定了却找不到就报错,不静默回落第一条** —— 那会让用户以为在看 4K,
// 实际放的是 1080p,且毫无提示。
//
// versionRegex 只在 mediaSourceID 为空 —— 也就是用户**没有手动指定版本**时才参与。
// 手动选的永远优先。
func (c *Client) ResolveStream(ctx context.Context, s *Session, itemID, mediaSourceID, versionRegex string) (*PlaybackTarget, error) {
	u := fmt.Sprintf("%s/Items/%s/PlaybackInfo?UserId=%s",
		s.Server, url.PathEscape(itemID), url.QueryEscape(s.UserID))
	body, _ := json.Marshal(deviceProfile)
	req, err := http.NewRequestWithContext(ctx, http.MethodPost, u, bytes.NewReader(body))
	if err != nil {
		return nil, fmt.Errorf("请求构造失败: %w", err)
	}
	req.Header.Set("X-Emby-Token", s.Token)
	req.Header.Set("X-Emby-Authorization", c.authHeader(s.DeviceID))
	req.Header.Set("Content-Type", "application/json")
	req.Header.Set("User-Agent", c.UA)
	resp, err := c.HTTP.Do(req)
	if err != nil {
		return nil, fmt.Errorf("PlaybackInfo 网络错误: %w", err)
	}
	defer resp.Body.Close()
	if resp.StatusCode < 200 || resp.StatusCode >= 300 {
		return nil, fmt.Errorf("PlaybackInfo 失败: HTTP %d", resp.StatusCode)
	}
	var info struct {
		MediaSources  []rawMediaSource `json:"MediaSources"`
		PlaySessionID *string          `json:"PlaySessionId"`
	}
	if err := json.NewDecoder(resp.Body).Decode(&info); err != nil {
		return nil, fmt.Errorf("PlaybackInfo 解析失败: %w", err)
	}

	// 服务器发的 PlaySessionId 优先;缺则本地兜底生成(但同一次播放内保持一致)
	psid := ""
	if info.PlaySessionID != nil {
		psid = *info.PlaySessionID
	}
	if psid == "" {
		psid = s.DeviceID + "-" + itemID
	}

	ms, err := pickSource(info.MediaSources, mediaSourceID, versionRegex)
	if err != nil {
		return nil, err
	}
	msID := deref(ms.ID)

	target := &PlaybackTarget{
		ItemID: itemID, MediaSourceID: msID, PlaySessionID: psid,
		// 取流这一跳顺手把 DV 判了 —— MediaStreams 就在同一份响应里,不用再打一次服务器。
		// ★ 在这里算而不是丢给调用方:PlaybackInfo 的 MediaStreams 只有这条路上拿得到,
		//   调用方手里的版本列表是**另一次请求**,两边可能选的不是同一个版本。
		IsDolbyVision: hasDolbyVision(ms),
		ExternalSubs:  externalSubs(s, ms, itemID, msID),
	}

	switch {
	case nonEmpty(ms.DirectStreamURL) != nil:
		target.URL = absURL(s, c.seekablePath(ctx, s, *ms.DirectStreamURL))
		target.PlayMethod = "DirectStream"
	case nonEmpty(ms.TranscodingURL) != nil:
		target.URL = absURL(s, *ms.TranscodingURL)
		target.PlayMethod = "Transcode"
	default:
		// 兜底:用真实 mediaSourceId + container 直拼
		ext := ""
		if ct := deref(ms.Container); ct != "" {
			ext = "." + ct
		}
		target.URL = fmt.Sprintf("%s/Videos/%s/stream%s?static=true&mediaSourceId=%s&api_key=%s",
			s.Server, url.PathEscape(itemID), ext, url.QueryEscape(msID), url.QueryEscape(s.Token))
		target.PlayMethod = "DirectStream"
	}
	return target, nil
}

// pickSource 挑版本。手动指定优先,其次版本正则,再其次第一条。
func pickSource(all []rawMediaSource, want, versionRegex string) (rawMediaSource, error) {
	if want != "" {
		for _, m := range all {
			if deref(m.ID) == want {
				return m, nil
			}
		}
		// ★ 找不到就报错。静默回落第一条 = 用户以为在看 4K,实际放的是 1080p。
		return rawMediaSource{}, fmt.Errorf("该条目没有版本 %s(服务器可能已改动媒体源)", want)
	}
	if len(all) == 0 {
		return rawMediaSource{}, fmt.Errorf("该条目无可播放源")
	}
	texts := make([]string, 0, len(all))
	for _, m := range all {
		texts = append(texts, sourceMatchText(m))
	}
	idx := pickIndex(texts, versionRegex)
	if idx < 0 {
		idx = 0 // 没命中 / 没设 → 第一条(服务器顺序,旧行为)
	}
	return all[idx], nil
}

func hasDolbyVision(ms rawMediaSource) bool {
	for _, st := range ms.MediaStreams {
		if deref(st.Type) != "Video" {
			continue
		}
		rt := strings.ToLower(deref(st.VideoRangeType))
		codec := strings.ToLower(deref(st.Codec))
		profile := strings.ToLower(deref(st.Profile))
		if strings.Contains(rt, "dovi") || strings.Contains(rt, "dolby") ||
			strings.Contains(codec, "dvhe") || strings.Contains(codec, "dvh1") ||
			strings.Contains(codec, "dav1") || strings.Contains(profile, "dolby vision") {
			return true
		}
	}
	return false
}

// externalSubs 外挂字幕:优先用服务器给的 DeliveryUrl,没有就按 index 拼标准路由。
func externalSubs(s *Session, ms rawMediaSource, itemID, msID string) []ExternalSub {
	out := []ExternalSub{}
	for _, st := range ms.MediaStreams {
		if deref(st.Type) != "Subtitle" || !derefB(st.IsExternal) || st.Index == nil {
			continue
		}
		index := *st.Index
		codec := strings.ToLower(deref(st.Codec))
		if codec == "" {
			codec = "srt"
		}
		// pgs/dvdsub 是**图形**字幕,外挂形态少见且 mpv 挂载后多半不可用,跳过
		switch codec {
		case "pgssub", "pgs", "dvdsub", "dvbsub":
			continue
		}
		// Emby 的 Stream.{ext} 里 ext 用的是**封装名**:subrip 要写成 srt
		ext := codec
		switch codec {
		case "subrip":
			ext = "srt"
		case "webvtt":
			ext = "vtt"
		}
		u := ""
		if d := nonEmpty(st.DeliveryURL); d != nil {
			u = absURL(s, *d)
		} else {
			u = s.Server + subtitlePath(itemID, msID, index, ext, s.Token)
		}
		title := ""
		if v := nonEmpty(st.DisplayTitle); v != nil {
			title = *v
		} else if v := nonEmpty(st.Language); v != nil {
			title = *v
		} else {
			title = fmt.Sprintf("外挂字幕 %d", index)
		}
		out = append(out, ExternalSub{
			URL: u, Title: title, Lang: nonEmpty(st.Language), IsDefault: derefB(st.IsDefault),
		})
	}
	return out
}

// subtitlePath 服务器不给 DeliveryUrl 时自己拼的取字幕路径(相对路径,不含 host)。
//
// ★ 格式必须和 Emby 自己发的 DeliveryUrl **一模一样**。
func subtitlePath(itemID, mediaSourceID string, index int64, ext, token string) string {
	return fmt.Sprintf("/Videos/%s/%s/Subtitles/%d/0/Stream.%s?api_key=%s",
		itemID, mediaSourceID, index, ext, token)
}

// absURL 补全 server 前缀与 api_key。
func absURL(s *Session, path string) string {
	u := path
	if !strings.HasPrefix(path, "http") {
		u = s.Server + path
	}
	if !strings.Contains(u, "api_key=") {
		if strings.Contains(u, "?") {
			u += "&"
		} else {
			u += "?"
		}
		u += "api_key=" + s.Token
	}
	return u
}

/* ---------- 直连地址必须**实测支持 Range** ----------

   ★ 2026-07-27 用户报「跳到缓存条没缓存到的地方,画面和进度条一起卡死,别的播放器都正常」。
     根因:PlaybackInfo 给的 DirectStreamUrl 是**相对路径**,我们把它拼在服务器根上。
     Emby 本体在根和 `/emby/` 两个前缀上都提供 API,所以我们整套接口一直工作正常 ——
     但用户那两台服务器前面挂了反代,**只有 `/emby/` 那条路由正确处理 Range**:
     根路径下的同一个地址收到 `Range:` 也回 200 OK + 完整 Content-Length。

         GET /videos/…/original.mkv       Range: bytes=1000000-1000099  -> 200(整个文件)
         GET /emby/videos/…/original.mkv  Range: bytes=1000000-1000099  -> 206

     ffmpeg 拿不到 206 就只能从当前位置**顺读丢弃**到目标字节 —— 往前跳 9 分钟就是 370MB。
     别的播放器没事,是因为它们按 Emby 惯例把相对地址拼在 `/emby` API 根上。

   ★ **不写死前缀,而是各发一次 `Range: bytes=0-0` 实测**。写死 `/emby` 会在
     Jellyfin(没有这个前缀)和带 base path 的部署上把好地址改坏;而「哪个前缀能 Range」
     恰恰是我们唯一在乎的性质,直接测它最省事也最准。
     每台服务器每次运行只探一次,结果缓存。 */

var (
	rangePrefixMu sync.Mutex
	rangePrefix   = map[string]string{} // 服务器地址 -> 该用的路径前缀("" 或 "/emby")
)

// ResetRangePrefixCache 清掉探测缓存。**只给测试用。**
func ResetRangePrefixCache() {
	rangePrefixMu.Lock()
	defer rangePrefixMu.Unlock()
	rangePrefix = map[string]string{}
}

// embyPrefixed 生成 `/emby` 前缀的候选路径。已经带前缀、或本来就是绝对地址 = 没有第二个候选。
func embyPrefixed(path string) (string, bool) {
	if strings.HasPrefix(path, "http") || strings.HasPrefix(path, "/emby/") || path == "/emby" {
		return "", false
	}
	if strings.HasPrefix(path, "/") {
		return "/emby" + path, true
	}
	return "/emby/" + path, true
}

// choosePrefix 两次探测结果 -> 该用哪个前缀。
//
// ★ 原地址能 Range 就**别动**(最少惊讶);都不行也保持原样 ——
// 那时换前缀只是换一种坏法。
func choosePrefix(plainOK, embyOK bool) string {
	if plainOK || !embyOK {
		return ""
	}
	return "/emby"
}

// supportsRange 这个地址收到 Range 会不会老老实实回 206。
func (c *Client) supportsRange(ctx context.Context, u string) bool {
	req, err := http.NewRequestWithContext(ctx, http.MethodGet, u, nil)
	if err != nil {
		return false
	}
	// bytes=0-0 = 只要一个字节,探测代价可以忽略
	req.Header.Set("Range", "bytes=0-0")
	req.Header.Set("User-Agent", c.UA)
	resp, err := c.HTTP.Do(req)
	if err != nil {
		return false
	}
	defer resp.Body.Close()
	return resp.StatusCode == http.StatusPartialContent
}

// seekablePath 把相对播放路径换成「实测支持 Range」的那一条。
//
// ★ 失败一律回原样 —— 探测本身**绝不能挡住起播**
// (网络抖一下就播不了,比跳转慢严重得多)。
func (c *Client) seekablePath(ctx context.Context, s *Session, path string) string {
	alt, ok := embyPrefixed(path)
	if !ok {
		return path
	}
	rangePrefixMu.Lock()
	p, cached := rangePrefix[s.Server]
	rangePrefixMu.Unlock()
	if cached {
		if p == "" {
			return path
		}
		return p + path
	}

	plainOK := c.supportsRange(ctx, absURL(s, path))
	// 原地址就没问题的话别白探第二次
	embyOK := !plainOK && c.supportsRange(ctx, absURL(s, alt))
	pre := choosePrefix(plainOK, embyOK)

	rangePrefixMu.Lock()
	rangePrefix[s.Server] = pre
	rangePrefixMu.Unlock()
	if pre == "" {
		return path
	}
	return alt
}
