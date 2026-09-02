// Package translate 是字幕翻译 + Whisper 本地转写(桌面独占)。
//
// 移植自 `crates/core/src/translation.rs`(2827 行)。**Rust 版是黄金实现。**
//
// 分层:文档模型 / 语言映射 / 引擎(4 家)/ 设置 / 服务层(分块·并发·二分重试·缓存)
// / 流式翻译 / Whisper。
package translate

import (
	"fmt"
	"os"
	"path/filepath"
	"regexp"
	"strconv"
	"strings"
)

// Cue 一条字幕对白(归一化后的中间表示)。
//
// ★ 时间用**毫秒整数**:既方便跨 FFI/JSON 传给宿主,也免掉序列化歧义。
type Cue struct {
	StartMS uint64 `json:"start_ms"`
	EndMS   uint64 `json:"end_ms"`
	// Text 原文(多行以 \n 连接,已去除 ASS 覆盖标签)。
	Text string `json:"text"`
	// Translated 译文,翻译完成后填充。
	Translated string `json:"translated_text"`
}

// Layout 双语字幕排版方式。
type Layout string

// 三种排版。**这些字面量是存盘键**,改了等于把用户存的设置作废。
const (
	// LayoutTranslatedOnly 仅译文。
	LayoutTranslatedOnly Layout = "translatedOnly"
	// LayoutTranslatedFirst 译文在上,原文在下(默认)。
	LayoutTranslatedFirst Layout = "translatedFirst"
	// LayoutOriginalFirst 原文在上,译文在下。
	LayoutOriginalFirst Layout = "originalFirst"
)

// LayoutFromKey 认一个排版键。认不出一律回默认档。
func LayoutFromKey(k string) Layout {
	switch k {
	case string(LayoutTranslatedOnly):
		return LayoutTranslatedOnly
	case string(LayoutOriginalFirst):
		return LayoutOriginalFirst
	}
	return LayoutTranslatedFirst
}

// Document 字幕文档:把各格式解析成 Cue,并序列化成 SRT。
type Document struct {
	Cues []Cue
}

// ParseFile 从文件解析;按扩展名选解析器,未知扩展名时按内容嗅探。
func ParseFile(path string) (*Document, error) {
	raw, err := os.ReadFile(path)
	if err != nil {
		return nil, fmt.Errorf("读取字幕文件失败: %w", err)
	}
	ext := strings.ToLower(strings.TrimPrefix(filepath.Ext(path), "."))
	return ParseString(string(raw), ext), nil
}

// ParseString 按扩展名解析;ext 传空则按内容嗅探(SRT 兜底)。
func ParseString(content, ext string) *Document {
	switch ext {
	case "srt":
		return &Document{Cues: parseSRT(content)}
	case "vtt", "webvtt":
		return &Document{Cues: parseVTT(content)}
	case "ass", "ssa":
		return &Document{Cues: parseASS(content)}
	}
	// 内容嗅探兜底。
	trimmed := strings.TrimLeft(content, " \t\r\n")
	switch {
	case strings.HasPrefix(trimmed, "[Script Info]") || strings.Contains(trimmed, "[Events]"):
		return &Document{Cues: parseASS(content)}
	case strings.HasPrefix(trimmed, "WEBVTT"):
		return &Document{Cues: parseVTT(content)}
	}
	return &Document{Cues: parseSRT(content)}
}

// IsEmpty 有没有解出对白。
func (d *Document) IsEmpty() bool { return len(d.Cues) == 0 }

// ToSRT 序列化为 SRT。Layout 控制是否带原文双语。
func (d *Document) ToSRT(layout Layout) string {
	var b strings.Builder
	index := 1
	for i := range d.Cues {
		body := composeBody(&d.Cues[i], layout)
		if strings.TrimSpace(body) == "" {
			continue
		}
		fmt.Fprintf(&b, "%d\n%s --> %s\n%s\n\n",
			index, fmtSRT(d.Cues[i].StartMS), fmtSRT(d.Cues[i].EndMS), body)
		index++
	}
	return b.String()
}

func composeBody(c *Cue, layout Layout) string {
	translated := strings.TrimSpace(c.Translated)
	original := strings.TrimSpace(c.Text)
	if translated == "" {
		return original
	}
	switch layout {
	case LayoutTranslatedOnly:
		return translated
	case LayoutOriginalFirst:
		return original + "\n" + translated
	}
	return translated + "\n" + original
}

// ---------- SRT / VTT 解析 ----------

// srtTimeRe SRT/VTT 时间轴行。逗号/点号小数分隔符都吃。
var srtTimeRe = regexp.MustCompile(
	`(\d{1,2}):(\d{2}):(\d{2})[,.](\d{1,3})\s*-->\s*(\d{1,2}):(\d{2}):(\d{2})[,.](\d{1,3})`)

func capsMS(c []string, g int) uint64 {
	n := func(i int) uint64 {
		v, _ := strconv.ParseUint(c[i], 10, 64)
		return v
	}
	// ★ 毫秒位数不足要**右补零**:`,5` 是 500ms 不是 5ms。
	raw := c[g+3]
	for len(raw) < 3 {
		raw += "0"
	}
	ms, _ := strconv.ParseUint(raw[:3], 10, 64)
	return n(g)*3_600_000 + n(g+1)*60_000 + n(g+2)*1000 + ms
}

// blocks 拆成空行分隔的块(先归一化 CRLF)。
func blocks(content string) [][]string {
	norm := strings.ReplaceAll(content, "\r\n", "\n")
	var out [][]string
	var cur []string
	for _, line := range strings.Split(norm, "\n") {
		if strings.TrimSpace(line) == "" {
			if len(cur) > 0 {
				out = append(out, cur)
				cur = nil
			}
			continue
		}
		cur = append(cur, line)
	}
	if len(cur) > 0 {
		out = append(out, cur)
	}
	return out
}

func parseSRT(content string) []Cue {
	cues := []Cue{}
	for _, lines := range blocks(content) {
		// 时间轴只可能在块的前两行(第一行常是序号)。
		limit := min(len(lines), 2)
		idx := -1
		for i := 0; i < limit; i++ {
			if srtTimeRe.MatchString(lines[i]) {
				idx = i
				break
			}
		}
		if idx < 0 {
			continue
		}
		c := srtTimeRe.FindStringSubmatch(lines[idx])
		if c == nil {
			continue
		}
		text := stripTags(strings.Join(lines[idx+1:], "\n"))
		if text == "" {
			continue
		}
		cues = append(cues, Cue{StartMS: capsMS(c, 1), EndMS: capsMS(c, 5), Text: text})
	}
	return cues
}

var vttTagRe = regexp.MustCompile(`<[^>]+>`)

func parseVTT(content string) []Cue {
	cues := []Cue{}
	for _, lines := range blocks(content) {
		// VTT 块可能带 cue 标识行,时间轴**不限定在前两行**。
		idx := -1
		for i := range lines {
			if srtTimeRe.MatchString(lines[i]) {
				idx = i
				break
			}
		}
		if idx < 0 {
			continue
		}
		c := srtTimeRe.FindStringSubmatch(lines[idx])
		if c == nil {
			continue
		}
		// 去掉 VTT 内联标签 <c>、<v Name> 等。
		body := strings.Join(lines[idx+1:], "\n")
		text := stripTags(vttTagRe.ReplaceAllString(body, ""))
		if text == "" {
			continue
		}
		cues = append(cues, Cue{StartMS: capsMS(c, 1), EndMS: capsMS(c, 5), Text: text})
	}
	return cues
}

// ---------- ASS/SSA 解析 ----------

var assDefaultFormat = []string{
	"Layer", "Start", "End", "Style", "Name", "MarginL", "MarginR", "MarginV", "Effect", "Text",
}

func parseASS(content string) []Cue {
	cues := []Cue{}
	inEvents := false
	format := append([]string(nil), assDefaultFormat...)
	for _, raw := range strings.Split(strings.ReplaceAll(content, "\r\n", "\n"), "\n") {
		line := strings.TrimSpace(raw)
		if strings.HasPrefix(line, "[") {
			inEvents = line == "[Events]"
			continue
		}
		if !inEvents {
			continue
		}
		if rest, ok := strings.CutPrefix(line, "Format:"); ok {
			format = nil
			for _, e := range strings.Split(rest, ",") {
				format = append(format, strings.TrimSpace(e))
			}
			continue
		}
		body, ok := strings.CutPrefix(line, "Dialogue:")
		if !ok {
			continue
		}
		fields := splitASSFields(strings.TrimLeft(body, " \t"), len(format))
		idx := func(name string) int {
			for i, f := range format {
				if f == name {
					return i
				}
			}
			return -1
		}
		si, ei, ti := idx("Start"), idx("End"), idx("Text")
		if si < 0 || ei < 0 || ti < 0 || len(fields) <= ti {
			continue
		}
		text := stripASS(fields[ti])
		if text == "" {
			continue
		}
		cues = append(cues, Cue{
			StartMS: parseASSTime(strings.TrimSpace(fields[si])),
			EndMS:   parseASSTime(strings.TrimSpace(fields[ei])),
			Text:    text,
		})
	}
	return cues
}

// splitASSFields 按逗号切前 expected-1 段,**余下整块当最后一个字段** ——
// Text 里的逗号不能被切碎。
func splitASSFields(input string, expected int) []string {
	if expected <= 1 {
		return []string{input}
	}
	var out []string
	start := 0
	for i, ch := range input {
		if ch != ',' {
			continue
		}
		if len(out) >= expected-1 {
			break
		}
		out = append(out, input[start:i])
		start = i + 1
	}
	return append(out, input[start:])
}

var (
	assNewlineRe  = regexp.MustCompile(`(?i)\\N`)
	assOverrideRe = regexp.MustCompile(`\{[^}]*\}`)
)

func stripASS(text string) string {
	r := assNewlineRe.ReplaceAllString(text, "\n")
	r = assOverrideRe.ReplaceAllString(r, "") // 覆盖标签 {\an8} 等
	return stripTags(r)
}

// stripTags 逐行 trim 并丢空行。
func stripTags(text string) string {
	var keep []string
	for _, l := range strings.Split(text, "\n") {
		l = strings.TrimSpace(l)
		if l != "" {
			keep = append(keep, l)
		}
	}
	return strings.Join(keep, "\n")
}

// parseASSTime ASS 时间 `H:MM:SS.cc`(**百分秒**,不是毫秒)。
func parseASSTime(t string) uint64 {
	parts := strings.Split(t, ":")
	if len(parts) != 3 {
		return 0
	}
	u := func(s string) uint64 {
		v, _ := strconv.ParseUint(s, 10, 64)
		return v
	}
	sec := strings.Split(parts[2], ".")
	var cs uint64
	if len(sec) > 1 {
		frac := sec[1]
		for len(frac) < 2 {
			frac += "0"
		}
		cs = u(frac[:2])
	}
	return u(parts[0])*3_600_000 + u(parts[1])*60_000 + u(sec[0])*1000 + cs*10
}

func fmtSRT(ms uint64) string {
	return fmt.Sprintf("%02d:%02d:%02d,%03d",
		ms/3_600_000, (ms/60_000)%60, (ms/1000)%60, ms%1000)
}
