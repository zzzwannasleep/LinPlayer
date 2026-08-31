package danmaku

// 弹幕后处理:屏蔽词 / 用户 / 类型过滤 + 时间窗口去重 + 弹弹Play 屏蔽表导入。
//
// 移植自 `crates/core/src/danmaku/mod.rs`。
//
// ★ 手动搜索面板与自动加载**共用这一段**,保证两条路径得到一致的弹幕。

import (
	"regexp"
	"sort"
	"strings"
)

// FilterOptions 后处理选项。
type FilterOptions struct {
	Blockwords []string `json:"blockwords"`
	// UserBlocklist 被屏蔽的用户 id。
	UserBlocklist []string `json:"user_blocklist"`
	// BlockedModes 屏蔽的弹幕类型(1=滚动 4=底 5=顶)。空 = 不过滤。
	BlockedModes []int `json:"blocked_modes"`
	Dedup        bool  `json:"dedup"`
	// DedupWindow 去重时间窗口(秒)。
	DedupWindow float64 `json:"dedup_window"`
}

// DefaultFilterOptions 默认值。
//
// ★ **不是零值**:去重窗口默认 10 秒。解进零值结构体的话窗口变成 0,
// 去重等于只合并同一时刻的弹幕 —— 开了跟没开一样。
func DefaultFilterOptions() FilterOptions {
	return FilterOptions{
		Blockwords: []string{}, UserBlocklist: []string{}, BlockedModes: []int{},
		Dedup: false, DedupWindow: 10.0,
	}
}

// shouldFilter 是否该被过滤:用户在屏蔽名单,或文本含任一屏蔽词。
func shouldFilter(text string, userID *string, words, users []string) bool {
	if userID != nil {
		for _, u := range users {
			if u == *userID {
				return true
			}
		}
	}
	for _, w := range words {
		if w != "" && strings.Contains(text, w) {
			return true
		}
	}
	return false
}

// ApplyFilterAndDedup 过滤 + 去重。
func ApplyFilterAndDedup(in []Comment, opts FilterOptions) []Comment {
	items := in
	if len(opts.Blockwords) > 0 || len(opts.UserBlocklist) > 0 {
		out := items[:0:0]
		for _, it := range items {
			if !shouldFilter(it.Text, it.UserID, opts.Blockwords, opts.UserBlocklist) {
				out = append(out, it)
			}
		}
		items = out
	}
	if len(opts.BlockedModes) > 0 {
		blocked := map[int]bool{}
		for _, m := range opts.BlockedModes {
			blocked[m] = true
		}
		out := items[:0:0]
		for _, it := range items {
			if !blocked[it.Mode] {
				out = append(out, it)
			}
		}
		items = out
	}
	if opts.Dedup {
		w := opts.DedupWindow
		if w <= 0 {
			w = 10.0 // ★ 兜底:0 窗口等于没去重,而调用方多半只是忘了填
		}
		items = dedup(items, w)
	}
	if items == nil {
		items = []Comment{}
	}
	return items
}

// dedup 时间窗口内同文本同类型合并,Count 记次数。
func dedup(items []Comment, windowSeconds float64) []Comment {
	sorted := append([]Comment(nil), items...)
	sort.SliceStable(sorted, func(i, j int) bool { return sorted[i].Time < sorted[j].Time })
	used := make([]bool, len(sorted))
	out := make([]Comment, 0, len(sorted))
	for i := range sorted {
		if used[i] {
			continue
		}
		count := 1
		for j := i + 1; j < len(sorted); j++ {
			if used[j] {
				continue
			}
			// ★ 已按时间排序,超出窗口就可以停 —— 后面只会更远
			if sorted[j].Time-sorted[i].Time > windowSeconds {
				break
			}
			if sorted[j].Text == sorted[i].Text && sorted[j].Mode == sorted[i].Mode {
				count++
				used[j] = true
			}
		}
		c := sorted[i]
		c.Count = count
		out = append(out, c)
	}
	return out
}

// ImportResult 屏蔽表导入结果。
type ImportResult struct {
	TextWords    []string `json:"text_words"`
	UserIDs      []string `json:"user_ids"`
	SkippedCount int      `json:"skipped_count"`
}

var itemRe = regexp.MustCompile(`(?s)<item([^>]*)>(.*?)</item>`)

// ImportDandanplayBlocklistXML 从弹弹Play XML 屏蔽列表导入。
//
// 格式:`<item enabled="true">t=词</item>` / `<item enabled="true">x=uid=[平台]用户ID</item>`。
//
// ★ 用正则抽 <item> 而不是上 XML 库:这文件就这一种扁平结构。
func ImportDandanplayBlocklistXML(xml string) ImportResult {
	out := ImportResult{TextWords: []string{}, UserIDs: []string{}}
	seenW, seenU := map[string]bool{}, map[string]bool{}
	for _, cap := range itemRe.FindAllStringSubmatch(xml, -1) {
		attrs, body := cap[1], cap[2]
		if strings.Contains(attrs, `enabled="false"`) || strings.Contains(attrs, "enabled='false'") {
			out.SkippedCount++
			continue
		}
		content := unescapeXML(strings.TrimSpace(body))
		if content == "" {
			out.SkippedCount++
			continue
		}
		switch {
		case strings.HasPrefix(content, "t="):
			if w := strings.TrimSpace(content[2:]); w != "" && !seenW[w] {
				seenW[w] = true
				out.TextWords = append(out.TextWords, w)
			}
		case strings.HasPrefix(content, "x=uid="):
			if u := strings.TrimSpace(content[6:]); u != "" && !seenU[u] {
				seenU[u] = true
				out.UserIDs = append(out.UserIDs, u)
			}
		}
	}
	return out
}

func unescapeXML(s string) string {
	s = strings.ReplaceAll(s, "&lt;", "<")
	s = strings.ReplaceAll(s, "&gt;", ">")
	s = strings.ReplaceAll(s, "&quot;", `"`)
	s = strings.ReplaceAll(s, "&apos;", "'")
	// ★ &amp; **必须最后**,否则 `&amp;lt;` 会被二次解码成 `<`
	return strings.ReplaceAll(s, "&amp;", "&")
}
