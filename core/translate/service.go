package translate

// 服务层:分块 / 并发 / 二分重试 / 缓存 / 取源字幕。

import (
	"context"
	"fmt"
	"io"
	"net/http"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"unicode/utf8"

	"linplayer/core/httpx"
	"linplayer/core/paths"
)

// Progress 翻译进度回调:(已完成条数, 总条数, 阶段描述)。
type Progress func(done, total int, phase string)

// chunkRanges 按引擎能力把 cue 切成批次(返回下标区间)。
//
// 条数超限或累计字符超限即断批;**单条超限也自成一批(不丢)**。
func chunkRanges(cues []Cue, maxSize, maxChars int) [][2]int {
	out := [][2]int{}
	start, chars := 0, 0
	for i := range cues {
		length := utf8.RuneCountInString(cues[i].Text)
		curLen := i - start
		overSize := curLen >= maxSize
		overChars := maxChars > 0 && chars+length > maxChars
		if curLen > 0 && (overSize || overChars) {
			out = append(out, [2]int{start, i})
			start = i
			chars = 0
		}
		chars += length
	}
	if start < len(cues) {
		out = append(out, [2]int{start, len(cues)})
	}
	return out
}

// chunkOutcome 一批的翻译结果。失败条回退原文。
type chunkOutcome struct {
	texts  []string
	failed int
	err    error
}

// translateChunk 翻译一块文本;遇引擎抛错(如回包条数不齐)**二分重试**,
// 单条仍失败则回退原文,保证不中断整体流程。
func translateChunk(ctx context.Context, engine Engine, texts []string, source, target string) chunkOutcome {
	if len(texts) == 0 {
		return chunkOutcome{texts: []string{}}
	}
	v, err := engine.Translate(ctx, texts, source, target)
	if err == nil {
		return chunkOutcome{texts: v}
	}
	if len(texts) == 1 {
		// 单条也失败:回退原文并记账,让上层判断引擎是否整体不可用。
		return chunkOutcome{texts: texts, failed: 1, err: err}
	}
	mid := len(texts) / 2
	l := translateChunk(ctx, engine, texts[:mid], source, target)
	r := translateChunk(ctx, engine, texts[mid:], source, target)
	lastErr := r.err
	if lastErr == nil {
		lastErr = l.err
	}
	return chunkOutcome{
		texts:  append(l.texts, r.texts...),
		failed: l.failed + r.failed,
		err:    lastErr,
	}
}

// TranslateDocument 就地翻译一个已解析的文档(填充每条 cue 的 Translated)。
//
// ★★ **全部条目都失败(回退原文)通常意味着引擎根本不可用**(未开通服务/鉴权错误),
// 此时直接报错而不是静默产出一份未翻译的文件 —— 后者让用户以为「翻译了但没变化」。
func TranslateDocument(ctx context.Context, doc *Document, engine Engine,
	sourceLang, targetLang string, onProgress Progress) error {

	total := len(doc.Cues)
	if total == 0 {
		return nil
	}
	chunks := chunkRanges(doc.Cues, engine.MaxBatchSize(), engine.MaxBatchChars())
	concurrency := max(1, min(engine.MaxConcurrency(), 8))

	done, failed := 0, 0
	var lastErr error

	// 按引擎并发能力分波跑:每波起 concurrency 个批次,等齐再下一波。
	for i := 0; i < len(chunks); i += concurrency {
		wave := chunks[i:min(i+concurrency, len(chunks))]
		results := make([]chunkOutcome, len(wave))
		var wg sync.WaitGroup
		for j, rng := range wave {
			wg.Add(1)
			go func(j int, s, e int) {
				defer wg.Done()
				texts := make([]string, 0, e-s)
				for k := s; k < e; k++ {
					texts = append(texts, doc.Cues[k].Text)
				}
				results[j] = translateChunk(ctx, engine, texts, sourceLang, targetLang)
			}(j, rng[0], rng[1])
		}
		wg.Wait()

		for j, rng := range wave {
			s, e := rng[0], rng[1]
			for k, t := range results[j].texts {
				if s+k < e {
					doc.Cues[s+k].Translated = t
				}
			}
			failed += results[j].failed
			if results[j].err != nil {
				lastErr = results[j].err
			}
			done += e - s
			if onProgress != nil {
				onProgress(done, total, "翻译中…")
			}
		}
		if ctx.Err() != nil {
			return ctx.Err()
		}
	}

	if failed >= total && lastErr != nil {
		return fmt.Errorf("翻译引擎不可用,全部 %d 条均失败: %w", total, lastErr)
	}
	return nil
}

// looksLikeSubtitle 粗判内容是否为字幕文本(SRT/VTT/ASS)。
//
// ★ 为的是**避免把 404/HTML 错误页当字幕** —— 那会解析出 0 条,报一句
// 「源字幕解析为空」,而真实原因是那个地址压根不对。
func looksLikeSubtitle(body string) bool {
	if strings.TrimSpace(body) == "" {
		return false
	}
	head := body
	if len(head) > 4000 {
		head = head[:4000]
	}
	return strings.Contains(head, "-->") ||
		strings.Contains(head, "Dialogue:") ||
		strings.HasPrefix(strings.TrimLeft(head, " \t\r\n"), "WEBVTT") ||
		strings.Contains(head, "[Script Info]")
}

// FetchFirstSubtitle 依次尝试候选地址,返回第一个「内容确为字幕」的响应体。
//
// ★ 不同服务端的内封字幕导出路由不一(有的需 StartPositionTicks 段,有的给
// deliveryUrl),故逐个尝试**并校验内容**。
func FetchFirstSubtitle(ctx context.Context, urls []string, authToken string) (string, error) {
	var lastErr error
	tried := 0
	for _, u := range urls {
		if u == "" {
			continue
		}
		tried++
		if !strings.HasPrefix(u, "http") {
			// 本地外挂字幕文件。
			raw, err := os.ReadFile(u)
			if err != nil {
				lastErr = err
				continue
			}
			if looksLikeSubtitle(string(raw)) {
				return string(raw), nil
			}
			continue
		}
		req, err := http.NewRequestWithContext(ctx, http.MethodGet, u, nil)
		if err != nil {
			lastErr = err
			continue
		}
		if authToken != "" {
			req.Header.Set("X-Emby-Token", authToken)
			req.Header.Set("X-MediaBrowser-Token", authToken)
		}
		resp, err := httpx.EmbyClient().Do(req)
		if err != nil {
			lastErr = err
			continue
		}
		ok := resp.StatusCode >= 200 && resp.StatusCode < 300
		raw, _ := io.ReadAll(resp.Body)
		resp.Body.Close()
		if ok && looksLikeSubtitle(string(raw)) {
			return string(raw), nil
		}
	}
	msg := fmt.Sprintf("所有字幕地址均不可用(共 %d 个候选", tried)
	if lastErr != nil {
		msg += fmt.Sprintf(",最后错误: %v", lastErr)
	}
	return "", fmt.Errorf("%s)", msg)
}

func subtitleCacheDir() string { return filepath.Join(paths.CacheDir(), "translated-subtitles") }

func cacheKey(source, engineID, from, to string, layout Layout) string {
	return md5Hex(fmt.Sprintf("%s|%s|%s|%s|%s", source, engineID, from, to, layout))
}

// TranslateSubtitleURL 翻译远程/本地字幕文件,返回生成的 SRT 路径。
//
// 管线:拉取源字幕 → 解析为 cue → 分块并发翻译 → 序列化为 SRT → 写缓存文件。
// ★ 同一 (源, 引擎, 目标语言, 排版) **命中缓存直接复用**,避免重复消耗额度 ——
// 这几家都是按字符计费的。
func TranslateSubtitleURL(ctx context.Context, urls []string, engine Engine,
	sourceLang, targetLang string, layout Layout, authToken, cacheSeed string,
	onProgress Progress) (string, error) {

	dir := subtitleCacheDir()
	seed := cacheSeed
	if seed == "" {
		seed = strings.Join(urls, "|")
	}
	out := filepath.Join(dir, "trans_"+cacheKey(seed, engine.ID(), sourceLang, targetLang, layout)+".srt")
	if st, err := os.Stat(out); err == nil && st.Size() > 0 {
		if onProgress != nil {
			onProgress(1, 1, "已使用缓存")
		}
		return out, nil
	}

	if onProgress != nil {
		onProgress(0, 1, "下载字幕…")
	}
	raw, err := FetchFirstSubtitle(ctx, urls, authToken)
	if err != nil {
		return "", err
	}
	doc := ParseString(raw, "") // 按内容嗅探格式
	if doc.IsEmpty() {
		return "", fmt.Errorf("源字幕解析为空(拉取 %d 字节)。该轨可能无法被服务端导出为文本", len(raw))
	}

	if err := TranslateDocument(ctx, doc, engine, sourceLang, targetLang, onProgress); err != nil {
		return "", err
	}

	if err := os.MkdirAll(dir, 0o755); err != nil {
		return "", fmt.Errorf("建缓存目录失败: %w", err)
	}
	if err := os.WriteFile(out, []byte(doc.ToSRT(layout)), 0o644); err != nil {
		return "", fmt.Errorf("写翻译字幕失败: %w", err)
	}
	return out, nil
}

// SubtitleURLCandidates 构造内封/外挂字幕的候选下载地址(按命中概率排序)。
//
// ★ 不同 Emby/Jellyfin 服务端的字幕导出路由不一:有的是 `/Subtitles/{i}/Stream.srt`,
// 有的需要 `/Subtitles/{i}/0/Stream.srt`(StartPositionTicks 段),还可能直接给
// deliveryUrl/path。逐个尝试以兼容。
func SubtitleURLCandidates(base, token, itemID, mediaSourceID string, index int64,
	deliveryURL, path string) []string {

	base = strings.TrimRight(base, "/")
	out := []string{}
	// 服务端直接给出的地址优先(**仅取绝对地址** —— path 常常是服务端本地路径,
	// 当 URL 用会拼出一个永远 404 的地址)。
	for _, u := range []string{deliveryURL, path} {
		u = strings.TrimSpace(u)
		if strings.HasPrefix(u, "http") {
			out = append(out, u)
		}
	}
	q := ""
	if token != "" {
		q = "?api_key=" + token
	}
	// 各封装格式 × 是否带 StartPositionTicks 段;ticks 变体优先(覆盖面更广)。
	for _, codec := range []string{"srt", "vtt", "ass"} {
		stem := fmt.Sprintf("%s/Videos/%s/%s/Subtitles/%d", base, itemID, mediaSourceID, index)
		out = append(out, stem+"/0/Stream."+codec+q, stem+"/Stream."+codec+q)
	}
	// 去重并保持顺序。
	seen := map[string]bool{}
	dedup := out[:0]
	for _, u := range out {
		if u == "" || seen[u] {
			continue
		}
		seen[u] = true
		dedup = append(dedup, u)
	}
	return dedup
}

// ---------------------------------------------------------------------------
// 流式翻译(cue 级)
// ---------------------------------------------------------------------------

// StreamingTranslator 流式字幕翻译器(用于内封等无法整文件下载的字幕轨)的**核心侧**。
//
// 宿主契约:本结构只管「文本进、显示文本出」+ 缓存。
//   - 宿主观测到当前 cue → OnCue(text) → 拿返回值喂叠加层;缓存命中即秒回
//   - 停止时调 Clear() 释放本集缓存,否则长会话内存只增不减
type StreamingTranslator struct {
	engine     Engine
	sourceLang string
	targetLang string
	// layout 决定叠加层显示「仅译文 / 译文+原文 / 原文+译文」。
	layout Layout

	mu    sync.Mutex
	cache map[string]string
}

// NewStreamingTranslator 造一个流式翻译器。
func NewStreamingTranslator(engine Engine, sourceLang, targetLang string, layout Layout) *StreamingTranslator {
	return &StreamingTranslator{
		engine: engine, sourceLang: sourceLang, targetLang: targetLang,
		layout: layout, cache: map[string]string{},
	}
}

// normCue 缓存键:压平空白 —— 避免同一句因换行/空格差异重复消耗额度。
func normCue(text string) string { return strings.Join(strings.Fields(text), " ") }

// Compose 按排版把原文与译文组合成叠加层文本。
//
// ★ 译文为空(尚未译好)时:双语显示**原文占位**,仅译文显示空 ——
// 双语模式下留空会让字幕整句消失,比显示原文糟得多。
func (s *StreamingTranslator) Compose(original, translated string) string {
	o := strings.TrimSpace(original)
	t := strings.TrimSpace(translated)
	switch s.layout {
	case LayoutTranslatedOnly:
		return t
	case LayoutOriginalFirst:
		if t == "" {
			return o
		}
		return o + "\n" + t
	}
	if t == "" {
		return o
	}
	return t + "\n" + o
}

// CachedDisplay 查缓存;命中则返回可直接显示的文本(不发请求)。
func (s *StreamingTranslator) CachedDisplay(text string) (string, bool) {
	key := normCue(text)
	s.mu.Lock()
	hit, ok := s.cache[key]
	s.mu.Unlock()
	if !ok {
		return "", false
	}
	return s.Compose(text, hit), true
}

// OnCue 翻译并缓存一条 cue,返回该 cue 的显示文本。空文本返回空串。
func (s *StreamingTranslator) OnCue(ctx context.Context, text string) (string, error) {
	key := normCue(text)
	if key == "" {
		return "", nil
	}
	if d, ok := s.CachedDisplay(text); ok {
		return d, nil
	}
	translated, err := s.translateOne(ctx, key)
	if err != nil {
		return "", err
	}
	return s.Compose(text, translated), nil
}

// Warm 预热若干条;已缓存的跳过,错误吞掉不影响播放。
func (s *StreamingTranslator) Warm(ctx context.Context, texts []string) int {
	warmed := 0
	for _, t := range texts {
		key := normCue(t)
		if key == "" {
			continue
		}
		s.mu.Lock()
		_, has := s.cache[key]
		s.mu.Unlock()
		if has {
			continue
		}
		if _, err := s.translateOne(ctx, key); err == nil {
			warmed++
		}
	}
	return warmed
}

func (s *StreamingTranslator) translateOne(ctx context.Context, key string) (string, error) {
	out, err := s.engine.Translate(ctx, []string{key}, s.sourceLang, s.targetLang)
	if err != nil {
		return "", err
	}
	translated := key
	if len(out) > 0 {
		translated = out[0]
	}
	s.mu.Lock()
	s.cache[key] = translated
	s.mu.Unlock()
	return translated, nil
}

// Clear 释放本集累积的翻译缓存(停用翻译/换集时调)。
func (s *StreamingTranslator) Clear() {
	s.mu.Lock()
	s.cache = map[string]string{}
	s.mu.Unlock()
}
