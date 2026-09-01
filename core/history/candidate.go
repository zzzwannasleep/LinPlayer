package history

// Emby 条目 → 观看记录候选。
//
// ★★ 这份换算**只能有一份**。以前它长在 player 包里,而恢复扫描这条路也要用 ——
// 抄一份的后果是两条路的匹配判据慢慢分家:播放时记下的指纹和恢复时算出的指纹
// 对不上,表现是「明明看过却恢复不出来」,而两边的代码看起来都对。

import "linplayer/core/emby"

// CandidateFromItem 把 Emby 条目折成观看记录的候选。
//
// ★ ProviderIds / PresentationUniqueKey / Path 三样**必须是带 HistoryFields 取回来的**,
// 否则这里全是空,匹配自动降级到「剧名+季集号」—— 跨服续播最容易假装能用的失败形态。
func CandidateFromItem(it emby.Item) Candidate {
	rt := int64(it.RuntimeSecs * float64(TicksPerSec))
	return Candidate{
		ID: it.ID, Name: it.Name, Type: it.Type,
		TmdbID:          ExtractProviderID(it.ProviderIDs, "Tmdb"),
		SeriesID:        it.SeriesID,
		SeriesName:      it.SeriesName,
		PresentationKey: it.PresentationUniqueKey,
		Path:            it.Path,
		SeasonNo:        it.SeasonNo,
		EpisodeNo:       it.EpisodeNo,
		Year:            it.Year,
		RunTimeTicks:    &rt,
		Played:          it.Played,
		PositionTicks:   int64(it.ResumeSecs * float64(TicksPerSec)),
	}
}
