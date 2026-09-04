package history

// watch_history.json 的读写 + 续播位置决策。
//

import (
	"encoding/json"
	"os"
	"path/filepath"
	"sort"
	"sync"
	"time"

	"linplayer/core/paths"
)

// progressWriteIntervalSecs 同一条记录的进度写盘最小间隔(秒)。
//
// ★ 播放期每秒都调 Capture 也只落一次 —— 不节流的话一部两小时的片子
// 会往盘上写 7200 次「读-改-写整份文档」。
const progressWriteIntervalSecs = 10

// Document watch_history.json 的顶层结构。
type Document struct {
	SchemaVersion int64    `json:"schema_version"`
	UpdatedAt     int64    `json:"updated_at"`
	Records       []Record `json:"records"`
}

// Store 是 watch_history.json 的读写。
//
// ★ 所有写都是「读-改-写」,必须整段串行 —— 否则两次 Capture 并发会互相吃掉对方的记录,
// 表现是「看了的片子有时候记上有时候没记上」。
type Store struct {
	path      string
	writeMu   sync.Mutex
	lastWrite sync.Map // recordID -> epoch 毫秒
}

// DefaultPath 观看记录的落盘位置。
//
// ★ 在**数据根**下不是 cache 下:观看记录删了就真没了,不能被「清理缓存」顺手带走。
func DefaultPath() string { return paths.HistoryFile() }

// New 造一个 Store。
func New(path string) *Store { return &Store{path: path} }

// Default 用默认路径。
func Default() *Store { return New(DefaultPath()) }

func nowMs() int64 { return time.Now().UnixMilli() }

// LoadDocument 读盘。
//
// ★ 文件不存在 / 空 / 损坏**一律当空文档** —— 观看记录不值得为一次解析失败挡住播放。
// (和 config 相反:配置坏了必须报错,因为那会覆盖用户的账号;
//
//	观看记录坏了最多丢一些进度,而挡住播放的代价大得多。)
func (s *Store) LoadDocument() Document {
	b, err := os.ReadFile(s.path)
	if err != nil || len(b) == 0 {
		return Document{SchemaVersion: 1}
	}
	var d Document
	if json.Unmarshal(b, &d) != nil {
		return Document{SchemaVersion: 1}
	}
	if d.Records == nil {
		d.Records = []Record{}
	}
	return d
}

// LoadScope 某服务器的记录,按最近播放倒序。
func (s *Store) LoadScope(scopeKey string) []Record {
	out := []Record{}
	for _, r := range s.LoadDocument().Records {
		if r.ScopeKey == scopeKey {
			out = append(out, r)
		}
	}
	sortRecords(out)
	return out
}

// LoadAll 全部记录(跨服务器)。跨服续播匹配与设置页统计 / 清理用。
func (s *Store) LoadAll() []Record {
	out := s.LoadDocument().Records
	if out == nil {
		out = []Record{}
	}
	sortRecords(out)
	return out
}

// SaveRecord 写一条。replaceIDs 里的旧记录一并删掉。
//
// ★ canonicalKey 变了(比如这次终于查到 TMDB id)时要换 record_id ——
// 不删旧的话一份内容会变成两条,「继续观看」里同一集出现两次。
func (s *Store) SaveRecord(rec Record, replaceIDs []string) error {
	s.writeMu.Lock()
	defer s.writeMu.Unlock()
	drop := map[string]bool{rec.RecordID: true}
	for _, id := range replaceIDs {
		drop[id] = true
	}
	kept := []Record{}
	for _, e := range s.LoadDocument().Records {
		if !drop[e.RecordID] {
			kept = append(kept, e)
		}
	}
	kept = append(kept, rec)
	sortRecords(kept)
	return s.writeDocument(kept)
}

// DeleteRecord 删一条。
func (s *Store) DeleteRecord(recordID string) error {
	s.writeMu.Lock()
	defer s.writeMu.Unlock()
	s.lastWrite.Delete(recordID)
	kept := []Record{}
	for _, e := range s.LoadDocument().Records {
		if e.RecordID != recordID {
			kept = append(kept, e)
		}
	}
	return s.writeDocument(kept)
}

// ClearAll 清空。
func (s *Store) ClearAll() error {
	s.writeMu.Lock()
	defer s.writeMu.Unlock()
	s.lastWrite.Range(func(k, _ any) bool { s.lastWrite.Delete(k); return true })
	return s.writeDocument([]Record{})
}

func (s *Store) writeDocument(records []Record) error {
	if err := os.MkdirAll(filepath.Dir(s.path), 0o755); err != nil {
		return err
	}
	if records == nil {
		records = []Record{}
	}
	b, err := json.MarshalIndent(Document{SchemaVersion: 1, UpdatedAt: nowMs(), Records: records}, "", "  ")
	if err != nil {
		return err
	}
	// 原子写:观看记录写到一半断电,剩下的半份 JSON 会被下次读当成「损坏」而整份丢掉
	tmp := s.path + ".tmp"
	if err := os.WriteFile(tmp, append(b, '\n'), 0o644); err != nil {
		return err
	}
	return os.Rename(tmp, s.path)
}

func sortRecords(rs []Record) {
	sort.SliceStable(rs, func(i, j int) bool { return rs[i].LastPlayedAt > rs[j].LastPlayedAt })
}

// findExisting 本服里找同一份内容的既有记录:canonicalKey → lastEmbyItemId → PUK,**三级兜底**。
//
// ★ 三级缺一不可:canonicalKey 会随元数据补全而变(查到 TMDB 之后就换了),
// 只按它找会在那一刻把同一份内容判成新记录。
func findExisting(records []Record, fp Fingerprint, itemID string) *Record {
	for i := range records {
		if records[i].CanonicalKey == fp.CanonicalKey {
			return &records[i]
		}
	}
	for i := range records {
		if records[i].LastEmbyItemID != nil && *records[i].LastEmbyItemID == itemID {
			return &records[i]
		}
	}
	if fp.NormalizedPUK == nil {
		return nil
	}
	for i := range records {
		if p := NormalizePUK(records[i].PresentationKey); p != nil && *p == *fp.NormalizedPUK {
			return &records[i]
		}
	}
	return nil
}

// ---------------------------------------------------------------- 续播位置决策

// ResolveResumeTicks 是这个模块的**主产出**。
//
// 候选进度取**最大值**:远端进度、本服本地记录,外加(crossServer=true 时)其它服务器的记录。
//
// ★ 已看完就不续播:远端 played 直接返回 nil;本服本地记录 played 时**只信远端**
// —— 避免跨服记录覆盖用户在本服的「已看完」。
func (s *Store) ResolveResumeTicks(scopeKey string, candidate Candidate, seriesTmdbID *string,
	remoteTicks *int64, remotePlayed bool, crossServer bool) *int64 {
	if remotePlayed {
		return nil
	}
	normalizedRemote := normalizeTicks(remoteTicks, candidate.RunTimeTicks)
	fp, ok := FingerprintOfCandidate(candidate, seriesTmdbID)
	if !ok {
		return normalizedRemote
	}

	records := s.LoadScope(scopeKey)
	existing := findExisting(records, fp, candidate.ID)
	if existing != nil && existing.Played {
		return normalizedRemote
	}

	best := normalizedRemote
	if existing != nil {
		rt := candidate.RunTimeTicks
		if rt == nil {
			rt = existing.RunTimeTicks
		}
		best = MaxPositionTicks(best, normalizeTicks(&existing.LastPositionTicks, rt))
	}
	if crossServer {
		best = MaxPositionTicks(best, s.crossServerTicks(candidate, seriesTmdbID, scopeKey))
	}
	return best
}

// crossServerTicks 扫描**其它** scope 下的记录,找与当前条目匹配的最远进度。
//
// ★ 仅采用 strong / possible,避免误续播。
// ★ 匹配时 unique=true:跨服扫描是「这一条记录和当前这个条目」的一对一比较,
// 候选天然唯一。
func (s *Store) crossServerTicks(candidate Candidate, seriesTmdbID *string, currentScope string) *int64 {
	all := s.LoadAll()
	var best *int64
	for _, rec := range all {
		if rec.ScopeKey == currentScope {
			continue // 本服记录已在上层处理
		}
		if rec.Played || rec.LastPositionTicks <= 0 {
			continue
		}
		if !MatchRecordToCandidate(rec, candidate, seriesTmdbID, true).Confidence.IsTrusted() {
			continue
		}
		rt := candidate.RunTimeTicks
		if rt == nil {
			rt = rec.RunTimeTicks
		}
		p := rec.LastPositionTicks
		best = MaxPositionTicks(best, normalizeTicks(&p, rt))
	}
	return best
}

// normalizeTicks 进度归一化:<=0 视为「没有进度」;有时长则夹到时长内。
func normalizeTicks(pos *int64, runtime *int64) *int64 {
	if pos == nil || *pos <= 0 {
		return nil
	}
	v := *pos
	if runtime != nil && *runtime > 0 && v > *runtime {
		v = *runtime
	}
	return &v
}

// ---------------------------------------------------------------- 落记录

// CaptureOpts 落记录的入参。
type CaptureOpts struct {
	ScopeKey      string
	Candidate     Candidate
	SeriesTmdbID  *string
	PositionTicks int64
	Source        WriteSource
	// WatchedThresholdPercent 看过百分之多少算看完。
	WatchedThresholdPercent int64
	IncrementPlayCount      bool
	/* ForcePlayed 直接指定「已看 / 未看」,不按阈值算。**只给手动标记那条路用。**

	   ☠ 不能拿「位置 = 片长 + 阈值 100」去凑:片长未知(RunTimeTicks 为 nil)时
	   isPlayed 恒为 false,于是「标记为已看」会**静默地什么都没标上** ——
	   而服务器那边已经标上了,两边从此对不上。
	   把意图写成字段,比把意图编码进两个参数的组合安全。

	   ★ 位置不用额外处理:手动标记这条路本来就不传 PositionTicks,
	     缺省 0 —— 标已看 / 标未看都会把旧进度覆盖掉,正是想要的。
	     (试过加一条「标已看就把位置推到片尾」的分支,注入验红时发现
	      它一条断言都影响不到 —— 死代码,删了。) */
	ForcePlayed *bool
	// Force 跳过节流。停播时要用 —— 那一下必须落盘,否则最后几秒的进度丢了。
	Force bool
}

// Capture 播放期落记录。返回落盘后的记录;非 Movie/Episode 返回 nil(不记录)。
//
// ★ 节流:同一条记录 10s 内重复调用直接返回既有记录(Force / IncrementPlayCount 例外)。
func (s *Store) Capture(o CaptureOpts) *Record {
	fp, ok := FingerprintOfCandidate(o.Candidate, o.SeriesTmdbID)
	if !ok {
		return nil
	}
	records := s.LoadScope(o.ScopeKey)
	existing := findExisting(records, fp, o.Candidate.ID)
	recordID := BuildRecordID(o.ScopeKey, fp.MediaKind, fp.CanonicalKey)

	if !o.Force && existing != nil && !o.IncrementPlayCount && !s.shouldPersist(recordID) {
		return existing
	}

	now := nowMs()
	hi := o.PositionTicks
	if o.Candidate.RunTimeTicks != nil {
		hi = *o.Candidate.RunTimeTicks
	}
	if hi < 0 {
		hi = 0
	}
	pos := o.PositionTicks
	if pos < 0 {
		pos = 0
	}
	if pos > hi {
		pos = hi
	}
	played := isPlayed(pos, o.Candidate.RunTimeTicks, o.WatchedThresholdPercent)
	if o.ForcePlayed != nil {
		played = *o.ForcePlayed
	}

	playCount := int64(0)
	if existing != nil {
		playCount = existing.PlayCount
	}
	if o.IncrementPlayCount || existing == nil {
		playCount++
	}

	firstAt := now
	if existing != nil {
		if existing.FirstPlayedAt != nil {
			firstAt = *existing.FirstPlayedAt
		} else {
			firstAt = existing.LastPlayedAt
		}
	}

	conf := ConfNone
	var restoredAt *int64
	if existing != nil {
		if existing.MatchConfidence != "" {
			conf = existing.MatchConfidence
		}
		restoredAt = existing.RestoredAt
	}

	rec := Record{
		RecordID:          recordID,
		ScopeKey:          o.ScopeKey,
		MediaKind:         fp.MediaKind,
		CanonicalKey:      fp.CanonicalKey,
		TmdbID:            fp.TmdbID,
		SeriesTmdbID:      fp.SeriesTmdbID,
		Title:             o.Candidate.Name,
		SeriesTitle:       o.Candidate.SeriesName,
		SeasonNumber:      o.Candidate.SeasonNo,
		EpisodeNo:         o.Candidate.EpisodeNo,
		Year:              o.Candidate.Year,
		LastPositionTicks: pos,
		RunTimeTicks:      o.Candidate.RunTimeTicks,
		Played:            played,
		PlayCount:         playCount,
		LastPlayedAt:      now,
		FirstPlayedAt:     &firstAt,
		LastEmbyItemID:    &o.Candidate.ID,
		MatchConfidence:   conf,
		RestoredAt:        restoredAt,
		LastWriteSource:   o.Source,
		PresentationKey:   o.Candidate.PresentationKey,
		MediaPath:         o.Candidate.Path,
	}

	// ★ canonicalKey 变了 → 旧 id 的记录要删掉,不然一份内容两条
	var replaced []string
	if existing != nil && existing.RecordID != rec.RecordID {
		replaced = []string{existing.RecordID}
	}
	if err := s.SaveRecord(rec, replaced); err != nil {
		return nil
	}
	s.lastWrite.Store(recordID, now)
	for _, old := range replaced {
		s.lastWrite.Delete(old)
	}
	return &rec
}

func (s *Store) shouldPersist(recordID string) bool {
	v, ok := s.lastWrite.Load(recordID)
	if !ok {
		return true
	}
	at, _ := v.(int64)
	return (nowMs()-at)/1000 >= progressWriteIntervalSecs
}

// isPlayed 已看判定:看过 threshold% 即算看完。
//
// ★ **无时长 → 判不了,不算看完** —— 猜错的方向是「把没看完的标成看完」,那更糟。
//
// ☠ **阈值 ≤ 0 也一律不算看完。** 0 的字面含义是「位置 ≥ 0 就算看完」,
// 也就是**每一条落进来的记录都是已看完** —— 而 0 从来不是谁的本意,
// 它是「调用方忘了填这个字段」的样子(Go 的缺省是零值)。
// 把「忘了填」翻译成「全都看完了」是这一层最贵的一种沉默。
func isPlayed(positionTicks int64, runTimeTicks *int64, thresholdPercent int64) bool {
	if runTimeTicks == nil || *runTimeTicks <= 0 || thresholdPercent <= 0 {
		return false
	}
	return float64(positionTicks)/float64(*runTimeTicks) >= float64(thresholdPercent)/100.0
}

// RecordWritebackResult 回传成功后同步本地的目标记录,保持本地状态一致。
func (s *Store) RecordWritebackResult(target Record, played bool, positionTicks int64) error {
	updated := target
	updated.Played = played || target.Played
	if positionTicks > target.LastPositionTicks && !target.Played {
		updated.LastPositionTicks = positionTicks
	}
	return s.SaveRecord(updated, nil)
}
