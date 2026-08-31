// Package history 是本地观看记录 + 跨服务器续播。
//
// 移植自 `crates/core/src/watch_history.rs`。**Rust 版是黄金实现。**
//
// 三件事:
//  1. 记录:每台服务器(scope)各存一条自己的观看记录,存 watch_history.json
//     (**独立于 config.json**)。
//  2. 匹配:canonicalKey / 指纹**与服务器无关**(TMDB / PresentationUniqueKey /
//     剧名+季集号),所以同一影片在不同服务器之间能对上 —— 跨服续播与回传都建立在这上面。
//  3. 续播:候选进度 = 远端进度 ∪ 本服本地记录 ∪(可选)其它服务器记录,**取最大值**。
//
// ★ 分层:纯逻辑(匹配 / 选择 / 存盘)在这里;需要 HTTP 的那几步(查剧的 TMDB id、
// 搜索候选、往其它服务器写回)由调用方接线后把结果喂进来。
//
// 本文件只放**纯匹配逻辑** —— 它是整个跨服功能的地基,也是最容易静默出错的一层:
// 匹配错了不会崩,只会「从别的片子的进度开始播」。
package history

import (
	"fmt"
	"regexp"
	"strings"
)

// TicksPerSec Emby 的时间单位:1 tick = 100ns。
const TicksPerSec int64 = 10_000_000

// PositionToleranceTicks 已看进度容差:远端比本地记录落后超过 30s 才值得回写。
const PositionToleranceTicks = 30 * TicksPerSec

// MaxScanRecords 扫描恢复时最多看几条记录。
const MaxScanRecords = 15

// MediaKind 记录类型。wire 值与旧栈逐字一致。
type MediaKind string

const (
	KindMovie   MediaKind = "movie"
	KindEpisode MediaKind = "episode"
)

// MediaKindFromItemType Emby 的 Item.Type → 记录类型。
// ★ 其它类型(Series/Season/BoxSet…)**不记录**,返回 ok=false。
func MediaKindFromItemType(t string) (MediaKind, bool) {
	switch strings.ToLower(t) {
	case "movie":
		return KindMovie, true
	case "episode":
		return KindEpisode, true
	}
	return "", false
}

// WriteSource 这条记录是谁写的。
type WriteSource string

const (
	// SourceInternal 内置播放器。**未知 / 缺省一律当它** —— 与旧栈的 fromWire 一致。
	SourceInternal WriteSource = "internal_player"
	SourceExternal WriteSource = "external_mpv"
)

// Confidence 匹配置信度。
//
// ★ 比较靠 rank(),**不是靠字符串** —— 别改成按字典序比。
type Confidence string

const (
	ConfNone     Confidence = "none"
	ConfWeak     Confidence = "weak"
	ConfPossible Confidence = "possible"
	ConfStrong   Confidence = "strong"
)

func (c Confidence) rank() int {
	switch c {
	case ConfStrong:
		return 3
	case ConfPossible:
		return 2
	case ConfWeak:
		return 1
	}
	return 0
}

// IsTrusted 可用于跨服续播 / 回传的置信度。
//
// ★ **只认 strong / possible**。放 weak 进来就会出现「从别的片子的进度开始播」——
// 而用户看到的只是「进度怎么不对」,不会想到是匹配错了。
func (c Confidence) IsTrusted() bool { return c == ConfStrong || c == ConfPossible }

// WritebackRange 看完 / 进度回传到「其它服务器」的目标范围。
type WritebackRange string

const (
	RangeAll    WritebackRange = "all"
	RangeFirst  WritebackRange = "first"
	RangeLatest WritebackRange = "latest"
)

// WritebackRangeFromWire 未知值回落 all。
func WritebackRangeFromWire(v string) WritebackRange {
	switch v {
	case "first":
		return RangeFirst
	case "latest":
		return RangeLatest
	}
	return RangeAll
}

// Record 一条观看记录。一个 scope(服务器+用户)× 一份内容 = 一条。
//
// 时间戳用 epoch 毫秒。
type Record struct {
	RecordID string `json:"record_id"`
	// ScopeKey 是 `server:user_id`,见 ScopeKey()。
	ScopeKey     string    `json:"scope_key"`
	MediaKind    MediaKind `json:"media_kind"`
	CanonicalKey string    `json:"canonical_key"`

	TmdbID       *string `json:"tmdb_id"`
	SeriesTmdbID *string `json:"series_tmdb_id"`
	Title        string  `json:"title"`
	SeriesTitle  *string `json:"series_title"`
	SeasonNumber *int64  `json:"season_number"`
	EpisodeNo    *int64  `json:"episode_number"`
	Year         *int64  `json:"year"`

	LastPositionTicks int64  `json:"last_position_ticks"`
	RunTimeTicks      *int64 `json:"run_time_ticks"`
	Played            bool   `json:"played"`
	PlayCount         int64  `json:"play_count"`
	LastPlayedAt      int64  `json:"last_played_at"`
	// FirstPlayedAt 该 scope 首次记录此内容的时间。旧记录可能没有,
	// 回退到 LastPlayedAt(见 EffectiveFirstPlayedAt)。
	FirstPlayedAt *int64 `json:"first_played_at"`

	LastEmbyItemID  *string     `json:"last_emby_item_id"`
	MatchConfidence Confidence  `json:"match_confidence"`
	RestoredAt      *int64      `json:"restored_at"`
	LastWriteSource WriteSource `json:"last_write_source"`
	PresentationKey *string     `json:"presentation_unique_key"`
	MediaPath       *string     `json:"media_path"`
}

// EffectiveFirstPlayedAt 首次观看时间,旧记录缺失时回退到 LastPlayedAt。
func (r Record) EffectiveFirstPlayedAt() int64 {
	if r.FirstPlayedAt != nil {
		return *r.FirstPlayedAt
	}
	return r.LastPlayedAt
}

// Candidate 待匹配的条目。
//
// ★ 为什么不直接用 emby.Item:列表端点取到的 Item **没有** ProviderIds /
// PresentationUniqueKey / Path,而这三样正是 canonicalKey 与强匹配的判据。
// 缺了不崩,但匹配会**自动降级**到「剧名+季集号」—— 那正是跨服续播最容易
// 假装能用的失败形态。
type Candidate struct {
	ID   string `json:"id"`
	Name string `json:"name"`
	// Type 是 Emby 的 Item.Type 原值(Movie / Episode / …)。
	Type            string  `json:"type_"`
	TmdbID          *string `json:"tmdb_id"`
	SeriesID        *string `json:"series_id"`
	SeriesName      *string `json:"series_name"`
	PresentationKey *string `json:"presentation_unique_key"`
	Path            *string `json:"path"`
	SeasonNo        *int64  `json:"season_no"`
	EpisodeNo       *int64  `json:"episode_no"`
	Year            *int64  `json:"year"`
	RunTimeTicks    *int64  `json:"run_time_ticks"`
	Played          bool    `json:"played"`
	PositionTicks   int64   `json:"position_ticks"`
}

// Fingerprint 归一化后的匹配判据。
type Fingerprint struct {
	MediaKind             MediaKind
	CanonicalKey          string
	Title                 string
	NormalizedTitle       string
	SeriesTitle           *string
	NormalizedSeriesTitle string
	TmdbID                *string
	SeriesTmdbID          *string
	SeasonNumber          *int64
	EpisodeNumber         *int64
	Year                  *int64
	PresentationKey       *string
	NormalizedPUK         *string
	MediaPath             *string
	NormalizedPathStem    *string
}

// MatchResult 一次匹配的结论。reason 会显示给用户(「为什么认为是同一部」)。
type MatchResult struct {
	Confidence Confidence `json:"confidence"`
	Reason     string     `json:"reason"`
}

// RestoreCandidate 一条「可恢复」的候选:记录 + 在本服匹配到的条目。
type RestoreCandidate struct {
	Record      Record     `json:"record"`
	MatchedItem Candidate  `json:"matched_item"`
	Confidence  Confidence `json:"confidence"`
	Reason      string     `json:"reason"`
}

// ---------------------------------------------------------------- 归一化 / 键

// ExtractProviderID 从 ProviderIds 取值。
// ★ 键名**大小写不敏感**(不同刮削器写 Tmdb / TMDB / tmdb 都有),空串当没有。
func ExtractProviderID(providerIDs map[string]string, key string) *string {
	lk := strings.ToLower(key)
	for k, v := range providerIDs {
		if strings.ToLower(k) == lk {
			t := strings.TrimSpace(v)
			if t == "" {
				return nil
			}
			return &t
		}
	}
	return nil
}

var (
	reBrackets = regexp.MustCompile(`\[[^\]]*\]`)
	reParens   = regexp.MustCompile(`\([^)]*\)`)
	// 非「字母数字汉字」一律折成空格
	reJunk = regexp.MustCompile(`[^a-z0-9\x{4e00}-\x{9fff}]+`)
)

// NormalizeText 标题归一化:小写 → 去 [..]/(..) → 非「字母数字汉字」折成空格 → 压空白。
//
// ★ 去掉方括号和圆括号是为了让「[星尘字幕组] 某剧 (2024)」和「某剧」对得上 ——
// 同一部片在不同服务器上的标题几乎不会完全一样。
func NormalizeText(value string) string {
	lowered := strings.TrimSpace(strings.ToLower(value))
	if lowered == "" {
		return ""
	}
	s := reBrackets.ReplaceAllString(lowered, " ")
	s = reParens.ReplaceAllString(s, " ")
	return strings.TrimSpace(reJunk.ReplaceAllString(s, " "))
}

// NormalizePUK 归一化 PresentationUniqueKey。空串当没有。
func NormalizePUK(value *string) *string {
	if value == nil {
		return nil
	}
	v := strings.ToLower(strings.TrimSpace(*value))
	if v == "" {
		return nil
	}
	return &v
}

// NormalizePathStem 取文件名(去扩展名)后再做标题归一化。
//
// ★ **两种分隔符都认**:记录里存的是**服务器端**路径,与客户端平台无关 ——
// 只认本平台分隔符的话,Windows 客户端连不上 Linux 服务器上的路径。
// ★ `.hidden`(点在首位)不算扩展名。
func NormalizePathStem(value *string) *string {
	if value == nil {
		return nil
	}
	text := strings.TrimSpace(*value)
	if text == "" {
		return nil
	}
	base := text
	if i := strings.LastIndexAny(text, `/\`); i >= 0 {
		base = text[i+1:]
	}
	stem := base
	if i := strings.LastIndex(base, "."); i > 0 {
		stem = base[:i]
	}
	out := NormalizeText(stem)
	return &out
}

func padIndex(v int64) string { return fmt.Sprintf("%02d", v) }

// BuildCanonicalKey 与服务器无关的内容标识 —— **跨服匹配全靠它**。
//
// 优先级:TMDB > PUK > 标题(+年份 / 季集号)> itemId。
// 最后那档退到 itemId 意味着「只在本服有效」—— 跨服就对不上了,那是**信息不足**
// 的诚实结果,不是 bug。
func BuildCanonicalKey(
	kind MediaKind, itemID string,
	tmdbID, seriesTmdbID, presentationKey *string,
	normalizedTitle, normalizedSeriesTitle string,
	seasonNumber, episodeNumber, year *int64,
) string {
	puk := NormalizePUK(presentationKey)
	tmdbID = nonEmptyPtr(tmdbID)
	seriesTmdbID = nonEmptyPtr(seriesTmdbID)

	if kind == KindMovie {
		if tmdbID != nil {
			return "movie:tmdb:" + *tmdbID
		}
		if puk != nil {
			return "movie:puk:" + *puk
		}
		if normalizedTitle != "" {
			y := "unknown"
			if year != nil {
				y = fmt.Sprintf("%d", *year)
			}
			return fmt.Sprintf("movie:title:%s:year:%s", normalizedTitle, y)
		}
		return "movie:item:" + itemID
	}

	if seriesTmdbID != nil && seasonNumber != nil && episodeNumber != nil {
		return fmt.Sprintf("series:tmdb:%s:s%s:e%s", *seriesTmdbID, padIndex(*seasonNumber), padIndex(*episodeNumber))
	}
	if tmdbID != nil && seasonNumber != nil && episodeNumber != nil {
		return fmt.Sprintf("episode:tmdb:%s:s%s:e%s", *tmdbID, padIndex(*seasonNumber), padIndex(*episodeNumber))
	}
	if puk != nil {
		return "episode:puk:" + *puk
	}
	if normalizedSeriesTitle != "" && seasonNumber != nil && episodeNumber != nil {
		return fmt.Sprintf("episode:title:%s:s%s:e%s", normalizedSeriesTitle, padIndex(*seasonNumber), padIndex(*episodeNumber))
	}
	return "episode:item:" + itemID
}

func nonEmptyPtr(p *string) *string {
	if p == nil || *p == "" {
		return nil
	}
	return p
}

// BuildRecordID 记录主键。
func BuildRecordID(scopeKey string, kind MediaKind, canonicalKey string) string {
	return fmt.Sprintf("%s:%s:%s", scopeKey, kind, canonicalKey)
}

// ScopeKey `server:user_id`(server 是归一化后的 URL)。
func ScopeKey(server, userID string) string { return server + ":" + userID }

// ServerFromScope 从 scopeKey 还原 server。
//
// ★ server 是 URL(自带 `https://` 甚至 `:8096`),所以必须按**最后一个**冒号切。
// 按第一个切的话 `https://x:8096:user` 会被切成 `https`。
func ServerFromScope(scopeKey string) string {
	if i := strings.LastIndex(scopeKey, ":"); i > 0 {
		return scopeKey[:i]
	}
	return scopeKey
}

// ---------------------------------------------------------------- 指纹

// FingerprintOfCandidate 候选条目 → 指纹。
// 非 Movie/Episode 返回 ok=false(不记录)。
// seriesTmdbID 由调用方查剧详情后喂进来;**只对 Episode 生效**。
func FingerprintOfCandidate(c Candidate, seriesTmdbID *string) (Fingerprint, bool) {
	kind, ok := MediaKindFromItemType(c.Type)
	if !ok {
		return Fingerprint{}, false
	}
	var resolvedSeriesTmdb *string
	if kind == KindEpisode {
		resolvedSeriesTmdb = seriesTmdbID
	}
	nt := NormalizeText(c.Name)
	nst := NormalizeText(strDeref(c.SeriesName))
	return Fingerprint{
		MediaKind: kind,
		CanonicalKey: BuildCanonicalKey(kind, c.ID, c.TmdbID, resolvedSeriesTmdb,
			c.PresentationKey, nt, nst, c.SeasonNo, c.EpisodeNo, c.Year),
		Title:                 c.Name,
		NormalizedTitle:       nt,
		SeriesTitle:           c.SeriesName,
		NormalizedSeriesTitle: nst,
		TmdbID:                c.TmdbID,
		SeriesTmdbID:          resolvedSeriesTmdb,
		SeasonNumber:          c.SeasonNo,
		EpisodeNumber:         c.EpisodeNo,
		Year:                  c.Year,
		PresentationKey:       c.PresentationKey,
		NormalizedPUK:         NormalizePUK(c.PresentationKey),
		MediaPath:             c.Path,
		NormalizedPathStem:    NormalizePathStem(c.Path),
	}, true
}

// FingerprintOfRecord 记录 → 指纹。
func FingerprintOfRecord(r Record) Fingerprint {
	return Fingerprint{
		MediaKind:             r.MediaKind,
		CanonicalKey:          r.CanonicalKey,
		Title:                 r.Title,
		NormalizedTitle:       NormalizeText(r.Title),
		SeriesTitle:           r.SeriesTitle,
		NormalizedSeriesTitle: NormalizeText(strDeref(r.SeriesTitle)),
		TmdbID:                r.TmdbID,
		SeriesTmdbID:          r.SeriesTmdbID,
		SeasonNumber:          r.SeasonNumber,
		EpisodeNumber:         r.EpisodeNo,
		Year:                  r.Year,
		PresentationKey:       r.PresentationKey,
		NormalizedPUK:         NormalizePUK(r.PresentationKey),
		MediaPath:             r.MediaPath,
		NormalizedPathStem:    NormalizePathStem(r.MediaPath),
	}
}

// ---------------------------------------------------------------- 匹配(跨服的地基)

// MatchRecordToCandidate 记录 ↔ 候选条目的匹配。
//
// uniqueCandidate=true 表示「候选池里只有它」,此时把 weak 提升为 possible ——
// 唯一候选下弱证据也够用。
func MatchRecordToCandidate(record Record, candidate Candidate, candidateSeriesTmdbID *string, uniqueCandidate bool) MatchResult {
	rp := FingerprintOfRecord(record)
	cp, ok := FingerprintOfCandidate(candidate, candidateSeriesTmdbID)
	if !ok || rp.MediaKind != cp.MediaKind {
		return MatchResult{ConfNone, "类型不匹配"}
	}

	// PUK 一致 = 同一台服务器上的同一条目,最强证据
	if rp.NormalizedPUK != nil && cp.NormalizedPUK != nil && *rp.NormalizedPUK == *cp.NormalizedPUK {
		return MatchResult{ConfStrong, "PresentationUniqueKey 匹配"}
	}
	if record.MediaKind == KindMovie {
		return matchMovie(rp, cp, uniqueCandidate)
	}
	return matchEpisode(rp, cp, uniqueCandidate)
}

// sameSome 两个都有值且相等。
// ★ **None == None 不算匹配** —— 两条都没有 TMDB id 不能因此判成同一部。
func sameSome(l, r *string) bool { return l != nil && r != nil && *l == *r }
func sameSomeI(l, r *int64) bool { return l != nil && r != nil && *l == *r }

func matchMovie(record, candidate Fingerprint, unique bool) MatchResult {
	sameTmdb := sameSome(record.TmdbID, candidate.TmdbID)
	sameTitle := record.NormalizedTitle != "" && record.NormalizedTitle == candidate.NormalizedTitle
	closeTitle := titlesCloseEnough(record.NormalizedTitle, candidate.NormalizedTitle)
	sameYear := sameSomeI(record.Year, candidate.Year)
	samePathStem := sameSome(record.NormalizedPathStem, candidate.NormalizedPathStem)

	maybe := ConfWeak
	if unique {
		maybe = ConfPossible
	}
	switch {
	case sameTmdb && sameTitle:
		return MatchResult{ConfStrong, "标题 + TMDB 匹配"}
	case sameTitle && sameYear:
		return MatchResult{maybe, "标题 + 年份匹配"}
	case closeTitle && samePathStem:
		return MatchResult{maybe, "标题 + 文件名匹配"}
	case closeTitle && unique:
		return MatchResult{ConfPossible, "标题接近且候选唯一"}
	}
	return MatchResult{ConfNone, "电影关键信息不足"}
}

func matchEpisode(record, candidate Fingerprint, unique bool) MatchResult {
	sameSeriesTmdb := sameSome(record.SeriesTmdbID, candidate.SeriesTmdbID)
	sameEpisodeTmdb := sameSome(record.TmdbID, candidate.TmdbID)
	sameSeasonEpisode := record.SeasonNumber != nil && record.EpisodeNumber != nil &&
		sameSomeI(record.SeasonNumber, candidate.SeasonNumber) &&
		sameSomeI(record.EpisodeNumber, candidate.EpisodeNumber)
	sameSeriesTitle := record.NormalizedSeriesTitle != "" &&
		record.NormalizedSeriesTitle == candidate.NormalizedSeriesTitle
	samePathStem := sameSome(record.NormalizedPathStem, candidate.NormalizedPathStem)

	maybe := ConfWeak
	if unique {
		maybe = ConfPossible
	}
	switch {
	case sameSeriesTmdb && sameSeasonEpisode:
		return MatchResult{ConfStrong, "剧集 TMDB + 季集号匹配"}
	case sameEpisodeTmdb && sameSeasonEpisode:
		return MatchResult{ConfStrong, "单集 TMDB + 季集号匹配"}
	case sameSeasonEpisode && sameSeriesTitle:
		return MatchResult{maybe, "剧名 + 季集号匹配"}
	case sameSeasonEpisode && samePathStem:
		return MatchResult{maybe, "文件名 + 季集号匹配"}
	}
	return MatchResult{ConfNone, "剧集关键信息不足"}
}

// titlesCloseEnough 一方包含另一方也算接近(「某剧」vs「某剧 第一季」)。
func titlesCloseEnough(l, r string) bool {
	if l == "" || r == "" {
		return false
	}
	return l == r || strings.Contains(l, r) || strings.Contains(r, l)
}

// ---------------------------------------------------------------- 进度

// MaxPositionTicks 取最大进度。任一为 nil 时返回另一个。
//
// ★ 跨服续播的核心就是这一句:候选进度 = 远端 ∪ 本地 ∪ 其它服,**取最大**。
func MaxPositionTicks(l, r *int64) *int64 {
	switch {
	case l == nil:
		return r
	case r == nil:
		return l
	case *l >= *r:
		return l
	}
	return r
}

// NeedsRestore 该记录相对服务器上的现状,是否值得回写。
func NeedsRestore(record Record, item Candidate) bool {
	if record.Played {
		return !item.Played
	}
	if item.Played {
		return false // 服务器上已经看完了,别把它退回「看了一半」
	}
	target := record.LastPositionTicks
	if target <= 0 {
		return false
	}
	if item.PositionTicks <= 0 {
		return true
	}
	// ★ 差得不到 30s 就别折腾服务器
	return item.PositionTicks+PositionToleranceTicks < target
}

// RestoreSearchQuery 恢复时用什么关键词去搜:电影用片名,剧集用剧名(退回片名)。
// 全空 → 搜不了,返回 ok=false。
func RestoreSearchQuery(record Record) (string, bool) {
	q := record.Title
	if record.MediaKind == KindEpisode && strings.TrimSpace(strDeref(record.SeriesTitle)) != "" {
		q = *record.SeriesTitle
	}
	if strings.TrimSpace(q) == "" {
		return "", false
	}
	return q, true
}

func strDeref(p *string) string {
	if p == nil {
		return ""
	}
	return *p
}
