package emby

// 章节:「跳过片头/片尾」与「进度条缩略图预览」共用同一份数据。
//
// 移植自 `crates/core/src/emby.rs`(chapters / name_hits / is_intro_name /
// is_outro_name / intro_range / outro_range)。
//
// 为什么这两个功能合并成一次请求:Emby 的章节既带时间点(拿来判片头片尾区间),
// 又带 ImageTag(拿来当进度条悬停缩略图)。分两条链路去打服务器纯属重复劳动。
//
// ⚠️ 现实边界,**别高估它**:
//   - 章节是**服务端**生成的。没刮削过章节的库 → 返回空表 → 两个功能都自动静默不工作。
//   - 章节图要服务端开了「章节图片提取」才有 ImageTag;只有时间点没有图时,
//     跳过片头照常工作,缩略图则退回纯时间气泡。
//   - 片头识别靠**章节名**。番剧组/刮削器给的名字五花八门,这里只认常见写法,
//     **认不出就不跳** —— 宁可不跳,也不能把正片切掉。

import (
	"context"
	"encoding/json"
	"fmt"
	"net/url"
	"strings"
	"unicode"
)

// Chapter 一个章节点。ImageURL 已经拼好 api_key,调用方直接拿去显示。
type Chapter struct {
	Index     int     `json:"index"`
	StartSecs float64 `json:"start_secs"`
	Name      string  `json:"name"`
	ImageURL  *string `json:"image_url"`
}

// Chapters 取条目章节。
//
// ★ 失败 / 无章节都返回**空表** —— 这两个功能都是增值项,不该拦住播放。
func (c *Client) Chapters(ctx context.Context, s *Session, itemID string, thumbWidth int) []Chapter {
	out := []Chapter{}
	u := fmt.Sprintf("%s/Users/%s/Items/%s?Fields=Chapters",
		s.Server, url.PathEscape(s.UserID), url.PathEscape(itemID))
	b, err := c.getBytes(ctx, s, u)
	if err != nil {
		return out
	}
	var holder struct {
		Chapters []struct {
			Start    *int64  `json:"StartPositionTicks"`
			Name     *string `json:"Name"`
			ImageTag *string `json:"ImageTag"`
		} `json:"Chapters"`
	}
	if err := json.Unmarshal(b, &holder); err != nil {
		return out
	}
	for i, ch := range holder.Chapters {
		item := Chapter{Index: i, StartSecs: float64(derefI(ch.Start)) / 1e7, Name: deref(ch.Name)}
		if tag := nonEmpty(ch.ImageTag); tag != nil {
			img := fmt.Sprintf("%s/Items/%s/Images/Chapter/%d?tag=%s&maxWidth=%d&api_key=%s",
				s.Server, url.PathEscape(itemID), i, url.QueryEscape(*tag), thumbWidth, url.QueryEscape(s.Token))
			item.ImageURL = &img
		}
		out = append(out, item)
	}
	return out
}

// nameHits 章节名匹配。
//
// ★ 短词(op/ed)必须**整词**匹配,不能用 contains —— 否则 "Opera"、"Stop"、
// "Wedding" 都会被当成片头,把正片开头切掉。长词才放开 contains。
func nameHits(name string, wholeWords, substrings []string) bool {
	lower := strings.ToLower(name)
	tokens := strings.FieldsFunc(lower, func(r rune) bool {
		return !unicode.IsLetter(r) && !unicode.IsDigit(r)
	})
	for _, w := range wholeWords {
		for _, t := range tokens {
			if t == w {
				return true
			}
		}
	}
	for _, w := range substrings {
		if strings.Contains(lower, w) {
			return true
		}
	}
	return false
}

func isIntroName(name string) bool {
	return nameHits(name,
		[]string{"op", "intro", "avant"},
		[]string{"opening", "片头", "オープニング", "主题曲"})
}

func isOutroName(name string) bool {
	return nameHits(name,
		[]string{"ed", "outro", "credits"},
		[]string{"ending", "片尾", "エンディング", "end credit", "next episode", "预告"})
}

// IntroRange 片头区间 (开始, 结束)。结束 = 下一个章节的开始(没有下一个就用总时长)。
//
// ★ 只在**前 40%** 里找:有些剧集把片尾曲也叫 "OP"(插入曲/同名主题曲),
// 不设这道闸会在快看完时把人一脚踹到片尾。
//
// 返回 ok=false 表示「不跳」。
func IntroRange(chapters []Chapter, runtimeSecs float64) (start, end float64, ok bool) {
	limit := runtimeSecs * 0.4
	if runtimeSecs <= 0 {
		limit = 1e18
	}
	idx := -1
	for i, c := range chapters {
		if c.StartSecs < limit && isIntroName(c.Name) {
			idx = i
			break
		}
	}
	if idx < 0 {
		return 0, 0, false
	}
	start = chapters[idx].StartSecs
	if idx+1 < len(chapters) {
		end = chapters[idx+1].StartSecs
	} else {
		end = runtimeSecs
	}
	// ★ 结束点必须真的在开始之后,且别长得离谱(>5 分钟的「片头」多半是误判的正片章节)
	if end <= start+1.0 || end-start > 300.0 {
		return 0, 0, false
	}
	return start, end, true
}

// OutroRange 可跳过的片尾区间 (开始, 落点)。只在**后 25%** 里找。
//
// ★ 只有片尾**后面还有内容**(通常是「下集预告」)时才返回 ok=true。
// 片尾是最后一个章节 = 跳过去就等于把这一集直接结束掉 —— 用户要的是「跳过片尾」,
// 不是「提前结束」,这两件事差得远。
//
// ★ 判定放在这里而不是留给调用方:调用方那份总时长在轮询闭包里会过期,
// 拿旧值去判「后面还有没有东西」迟早判错,而且错的方式是**误跳**,最难受的那种。
func OutroRange(chapters []Chapter, runtimeSecs float64) (start, landing float64, ok bool) {
	if runtimeSecs <= 0 {
		return 0, 0, false
	}
	floor := runtimeSecs * 0.75
	idx := -1
	for i, c := range chapters {
		if c.StartSecs >= floor && isOutroName(c.Name) {
			idx = i
			break
		}
	}
	if idx < 0 || idx+1 >= len(chapters) {
		return 0, 0, false // 没有下一章 = 后面没内容,不跳
	}
	start = chapters[idx].StartSecs
	landing = chapters[idx+1].StartSecs
	// 落点太贴近结尾(<5s)也当没内容:跳过去只看到一秒黑屏,不如不跳
	if landing <= start+1.0 || landing >= runtimeSecs-5.0 {
		return 0, 0, false
	}
	return start, landing, true
}

// ChapterInfo 是 player.chapterInfo 的返回体。
type ChapterInfo struct {
	Chapters []Chapter `json:"chapters"`
	// Intro / Outro 为 nil 表示这一集不跳。
	Intro *Range `json:"intro"`
	Outro *Range `json:"outro"`
}

// Range 一个可跳过的区间。
type Range struct {
	Start float64 `json:"start"`
	End   float64 `json:"end"`
}

// ChapterInfoOf 取章节并把片头片尾区间一并算好。
func (c *Client) ChapterInfoOf(ctx context.Context, s *Session, itemID string, runtimeSecs float64, thumbWidth int) *ChapterInfo {
	chs := c.Chapters(ctx, s, itemID, thumbWidth)
	info := &ChapterInfo{Chapters: chs}
	if a, b, ok := IntroRange(chs, runtimeSecs); ok {
		info.Intro = &Range{Start: a, End: b}
	}
	if a, b, ok := OutroRange(chs, runtimeSecs); ok {
		info.Outro = &Range{Start: a, End: b}
	}
	return info
}
