package history

// 观看记录「恢复扫描」的 HTTP 编排。
//
// ★★ 分层:**所有判定**(匹配 / 挑候选 / 该不该恢复)都在 match.go,已单测。
// 这里只回答三个问题:**打哪些请求 / 打给谁 / 失败了算什么**。
// 凡是能不带 HTTP 说清的决定,都抽成了纯函数(RestoreAction / RestoreWrite /
// RestoreFallbackTicks),异步壳子只剩「按计划发请求」。

import (
	"context"
	"fmt"
	"strings"

	"linplayer/core/emby"
)

func ticksToSecs(t int64) float64 { return float64(t) / float64(TicksPerSec) }

// Action 一条记录该怎么处理。
type Action string

const (
	// ActionUpdateOnly 服务器上已经有同等或更靠后的进度 —— 只更新本地的匹配信息。
	ActionUpdateOnly Action = "update_only"
	// ActionAuto 强匹配 → 自动回写。
	ActionAuto Action = "auto"
	// ActionPrompt 可能匹配 → 交给用户确认。
	ActionPrompt Action = "prompt"
	// ActionIgnore 匹配不上 → 什么都不做。
	ActionIgnore Action = "ignore"
)

// RestoreAction 决定一条记录怎么处理。**纯函数,不发请求。**
func RestoreAction(record Record, item Candidate, conf Confidence) Action {
	if !NeedsRestore(record, item) {
		return ActionUpdateOnly
	}
	switch conf {
	case ConfStrong:
		return ActionAuto
	case ConfPossible:
		return ActionPrompt
	}
	return ActionIgnore
}

// WriteKind 恢复时往服务器写什么。
type WriteKind int

const (
	// WriteNothing 没看完也没进度 —— 无可写。
	WriteNothing WriteKind = iota
	// WriteMarkPlayed 本地已看完 → POST /PlayedItems。
	WriteMarkPlayed
	// WriteProgress 本地有进度 → start/progress/stopped 三连。
	WriteProgress
)

// RestoreWrite 该写什么 + 写多少 ticks。**纯函数。**
func RestoreWrite(r Record) (WriteKind, int64) {
	if r.Played {
		return WriteMarkPlayed, 0
	}
	if r.LastPositionTicks > 0 {
		return WriteProgress, r.LastPositionTicks
	}
	return WriteNothing, 0
}

// RestoreFallbackTicks 标记已看失败后的兜底进度。
//
// ★ 走一遍 start + stopped(定位到片尾)让**服务器自己判已看** ——
// 有的 fork 的 /PlayedItems 是坏的,而上报这条路一直是通的。
// ★ 只对「本地已看完」成立;拿不到时长就没法兜底。
func RestoreFallbackTicks(r Record, item Candidate) (int64, bool) {
	if !r.Played {
		return 0, false
	}
	for _, v := range []*int64{item.RunTimeTicks, r.RunTimeTicks} {
		if v != nil && *v > 0 {
			return *v, true
		}
	}
	return 0, false
}

// RestoreReport 一轮恢复扫描的结果。
//
// ★★ Errors 存在的意义:单条记录 / 单个请求失败不能毁掉整轮,但**必须留痕** ——
// 这个模块最危险的 bug 是「不崩,只是悄悄少恢复了几条」,那种事没人会发现。
type RestoreReport struct {
	Scanned          int                `json:"scanned"`
	AutoRestored     int                `json:"auto_restored"`
	PromptCandidates []RestoreCandidate `json:"prompt_candidates"`
	UpdatedRecords   int                `json:"updated_records"`
	Errors           []string           `json:"errors"`
}

// reportTarget 造一个纯上报用的 PlaybackTarget(不取流)。
func reportTarget(s *emby.Session, itemID string) *emby.PlaybackTarget {
	return &emby.PlaybackTarget{
		ItemID: itemID,
		// ★ 没有单独的 mediaSourceId 时用 itemId —— 服务器认这个组合。
		MediaSourceID: itemID,
		// ★ PlaySessionId 必须带且**三件套同一个**,否则进度不落地
		//   (见 [[emby-playsessionid-resume]])。
		PlaySessionID: s.DeviceID + "-wh-" + itemID,
		PlayMethod:    "DirectStream",
	}
}

// reportTriplet start(0) → progress(pos, 已暂停) → stopped(pos)。
//
// ★ 任一步失败即整体失败:少了 start 的 stopped 服务器不认,
// 而它「成功」返回 200 —— 表现是回写完进度还是没变。
func reportTriplet(ctx context.Context, c *emby.Client, s *emby.Session,
	t *emby.PlaybackTarget, ticks int64) error {
	secs := ticksToSecs(ticks)
	if err := c.ReportStart(ctx, s, t, 0); err != nil {
		return err
	}
	if err := c.ReportProgress(ctx, s, t, secs, true); err != nil {
		return err
	}
	return c.ReportStopped(ctx, s, t, secs)
}

// RestoreOne 把一条候选真的回写到服务器,成功则更新本地记录。
//
// 返回 (false, nil) = 没什么可写(不算失败);返回 error = 请求失败。
//
// ★ 与旧实现的差异:旧的一律返回 false 把失败吞了。**让失败冒出来** ——
// 「恢复了 0 条」和「恢复失败了 8 条」对用户是两件事。
func RestoreOne(ctx context.Context, c *emby.Client, s *emby.Session,
	st *Store, cand RestoreCandidate) (bool, error) {
	r, item := cand.Record, cand.MatchedItem
	t := reportTarget(s, item.ID)

	kind, ticks := RestoreWrite(r)
	var err error
	switch kind {
	case WriteMarkPlayed:
		err = c.SetPlayed(ctx, s, item.ID, true)
	case WriteProgress:
		err = reportTriplet(ctx, c, s, t, ticks)
	default:
		return false, nil
	}
	if err != nil {
		runtime, ok := RestoreFallbackTicks(r, item)
		if !ok {
			return false, err
		}
		if e2 := c.ReportStart(ctx, s, t, 0); e2 != nil {
			return false, fmt.Errorf("%v;兜底上报也失败: %v", err, e2)
		}
		if e2 := c.ReportStopped(ctx, s, t, ticksToSecs(runtime)); e2 != nil {
			return false, fmt.Errorf("%v;兜底上报也失败: %v", err, e2)
		}
	}

	upd := r
	id := item.ID
	upd.LastEmbyItemID = &id
	now := nowMs()
	upd.RestoredAt = &now
	upd.MatchConfidence = cand.Confidence
	_ = st.SaveRecord(upd, nil)
	return true, nil
}

// seriesTmdb 剧集所属剧的 TMDB id,按 seriesID 缓存。
//
// ★ 非剧集 / 没有 series_id → nil,**不是错误**(电影本就没有)。
func seriesTmdb(ctx context.Context, c *emby.Client, s *emby.Session,
	cand Candidate, cache map[string]*string) *string {
	if !strings.EqualFold(cand.Type, "episode") {
		return nil
	}
	if cand.SeriesID == nil || *cand.SeriesID == "" {
		return nil
	}
	sid := *cand.SeriesID
	if v, ok := cache[sid]; ok {
		return v
	}
	v := c.SeriesTmdbID(ctx, s, sid)
	cache[sid] = v
	return v
}

// resolveCandidate 一条记录 → 本服上的条目。先试上次记下的 itemId,不行再按名字搜。
//
// ★★ 返回 nil = 没找到**可信**候选,**不是**「随便挑一个」。
// 随便挑的后果是把进度写到另一部片上,而且看起来一切正常。
func resolveCandidate(ctx context.Context, c *emby.Client, s *emby.Session, r Record,
	cache map[string]*string, errs *[]string) (*Candidate, *MatchResult) {
	// 1) 上次那个条目 id 还在不在。ItemForHistory 带全字段,强匹配判据才齐。
	if r.LastEmbyItemID != nil && *r.LastEmbyItemID != "" {
		id := *r.LastEmbyItemID
		item, err := c.ItemForHistory(ctx, s, id)
		if err != nil {
			// ★ 条目被删 / 换库很正常 → **不算错**,继续走搜索。
			//   但要留痕,免得整轮静默变空。
			*errs = append(*errs, fmt.Sprintf("取条目 %s 失败(改走搜索): %v", id, err))
		} else if item != nil {
			cand := CandidateFromItem(*item)
			m := MatchRecordToCandidate(r, cand, seriesTmdb(ctx, c, s, cand, cache), true)
			if m.Confidence != ConfNone {
				return &cand, &m
			}
		}
	}

	// 2) 搜索
	query, ok := RestoreSearchQuery(r)
	if !ok {
		return nil, nil
	}
	items, err := c.Search(ctx, s, query, nil, 0, "")
	if err != nil {
		*errs = append(*errs, fmt.Sprintf("搜索「%s」失败: %v", query, err))
		return nil, nil
	}

	/* ★ 先按类型过滤 + 取前 10 **再**查 TMDB —— 否则 50 条结果就是 50 个请求,
	   一轮扫描能打出几百个。这一步的过滤规则必须和 PickRestoreCandidate 内部
	   一致,不然下标对不上。 */
	type pair struct {
		c  Candidate
		st *string
	}
	var pool []pair
	for _, it := range items {
		cand := CandidateFromItem(it)
		if k, ok := MediaKindFromItemType(cand.Type); !ok || k != r.MediaKind {
			continue
		}
		if len(pool) >= 10 {
			break
		}
		pool = append(pool, pair{cand, nil})
	}
	for i := range pool {
		pool[i].st = seriesTmdb(ctx, c, s, pool[i].c, cache)
	}

	// 挑候选:强匹配唯一才自动取;多个强匹配 = 分不清,宁可不恢复。
	var matches []int
	var results []MatchResult
	for i, p := range pool {
		m := MatchRecordToCandidate(r, p.c, p.st, false)
		if m.Confidence != ConfNone {
			matches = append(matches, i)
			results = append(results, m)
		}
	}
	if len(matches) == 0 {
		return nil, nil
	}
	var strong []int
	for i, m := range results {
		if m.Confidence == ConfStrong {
			strong = append(strong, i)
		}
	}
	if len(strong) == 1 {
		i := strong[0]
		return &pool[matches[i]].c, &results[i]
	}
	// ★★ 多个强匹配 → **不恢复**。挑一个的后果是把进度写到另一部片上。
	if len(strong) > 1 || len(matches) != 1 {
		return nil, nil
	}
	// 只剩一个候选 → 它就是「唯一候选」,按 unique 重算(weak 会升成 possible)。
	i := matches[0]
	m := MatchRecordToCandidate(r, pool[i].c, pool[i].st, true)
	return &pool[i].c, &m
}

// ScanRestore 换服 / 重装后,把本地记录推回服务器。
//
// ponytail: 逐条串行。15 条 × 数个请求,后台跑得起;真嫌慢再按记录并发,
// 但那样 seriesTmdb 的缓存要换成带锁的。
func ScanRestore(ctx context.Context, c *emby.Client, s *emby.Session,
	st *Store, scopeKey string) RestoreReport {
	rep := RestoreReport{PromptCandidates: []RestoreCandidate{}, Errors: []string{}}
	records := st.LoadScope(scopeKey)
	if len(records) == 0 {
		return rep
	}
	cache := map[string]*string{}
	// ★ 按 recordId 覆盖:同一条记录在一轮里可能被更新两次(先匹配后回写)。
	pending := map[string]Record{}

	for i, r := range records {
		if i >= MaxScanRecords {
			break
		}
		rep.Scanned++
		item, m := resolveCandidate(ctx, c, s, r, cache, &rep.Errors)
		if item == nil || m == nil {
			continue
		}
		upd := r
		id := item.ID
		upd.LastEmbyItemID = &id
		upd.MatchConfidence = m.Confidence

		switch RestoreAction(r, *item, m.Confidence) {
		case ActionUpdateOnly:
			pending[r.RecordID] = upd
		case ActionAuto:
			cand := RestoreCandidate{Record: upd, MatchedItem: *item, Confidence: m.Confidence, Reason: m.Reason}
			done, err := RestoreOne(ctx, c, s, st, cand)
			switch {
			case err != nil:
				rep.Errors = append(rep.Errors, fmt.Sprintf("恢复「%s」失败: %v", r.Title, err))
			case done:
				rep.AutoRestored++
				now := nowMs()
				upd.RestoredAt = &now
				upd.MatchConfidence = ConfStrong
				pending[r.RecordID] = upd
			}
			// done=false(没什么可写)不记 pending —— 和旧实现一致
		case ActionPrompt:
			rep.PromptCandidates = append(rep.PromptCandidates,
				RestoreCandidate{Record: upd, MatchedItem: *item, Confidence: m.Confidence, Reason: m.Reason})
			pending[r.RecordID] = upd
		}
	}

	if len(pending) > 0 {
		rep.UpdatedRecords = len(pending)
		out := make([]Record, 0, len(pending))
		for _, v := range pending {
			out = append(out, v)
		}
		for _, v := range out {
			_ = st.SaveRecord(v, nil)
		}
	}
	return rep
}
