package player

import (
	"context"

	"linplayer/core/bus"
	"linplayer/core/config"
	"linplayer/core/emby"
	"linplayer/core/segments"
)

/*
片头片尾的来源有三层,**优先级从高到低**:

	① 手动设定   —— 用户自己量的,压过一切
	② 服务端章节 —— 刮削过章节的库才有
	③ 第三方库   —— 前两层缺什么补什么(IntroDB / TheIntroDB / AniSkip)

为什么要第三层:用户 2026-09-06 —— 「很多 Emby 服务器没有数据」。
只靠章节的话,没刮章节的库上这个功能是**完全静默地不存在**的。
*/

// skipKeyOf 手动设定的存储键 + 三个第三方源要的查询依据。
//
// ★ 键按**剧**取,不按集:一部剧的片头片尾每集都是同一段,按集存等于让用户设一百遍。
// ★ 外部 id 也要取**剧级**的:分集上的 ProviderIds 常常只有一个分集号,
//   而三个源要的都是剧(或影片)的 id。
func skipKeyOf(ctx context.Context, s *emby.Session, itemID string, runtime float64) (string, segments.Meta) {
	it, err := prefsClient.ItemForHistory(ctx, s, itemID)
	if err != nil || it == nil {
		return "", segments.Meta{}
	}
	m := segments.Meta{RuntimeSecs: runtime}
	ids := it.ProviderIDs
	owner := it.ID
	if it.SeriesID != nil && *it.SeriesID != "" {
		owner = *it.SeriesID
		if seriesIDs := prefsClient.SeriesProviders(ctx, s, owner); len(seriesIDs) > 0 {
			ids = seriesIDs
		}
	} else {
		m.IsMovie = it.Type != "Episode"
	}
	if it.SeasonNo != nil {
		m.Season = int(*it.SeasonNo)
	}
	if it.EpisodeNo != nil {
		m.Episode = int(*it.EpisodeNo)
	}
	m.IMDb = emby.ProviderOf(ids, "Imdb")
	m.TMDb = emby.ProviderOf(ids, "Tmdb")
	m.TVDb = emby.ProviderOf(ids, "Tvdb")
	// 两种写法的库都见过,取到哪个算哪个
	if m.MAL = emby.ProviderOf(ids, "MyAnimeList"); m.MAL == "" {
		m.MAL = emby.ProviderOf(ids, "Mal")
	}
	return s.Server + "|" + owner, m
}

// fillSkip 按三层优先级把 info 的 Intro / Outro 填满,返回数据出处(给界面说明用)。
func fillSkip(ctx context.Context, s *emby.Session, itemID string,
	runtime float64, info *emby.ChapterInfo, pf config.Prefs) string {
	// 两个开关都关着就一层都不查 —— 尤其是第三层,那是一次外网请求
	if !pf.SkipIntro && !pf.SkipOutro {
		return ""
	}
	from := ""
	if info.Intro != nil || info.Outro != nil {
		from = "服务端章节"
	}

	key, meta := skipKeyOf(ctx, s, itemID, runtime)
	if ov, ok := pf.SkipOverrides[key]; ok && key != "" {
		if ov.IntroEnd > ov.IntroStart {
			info.Intro = &emby.Range{Start: ov.IntroStart, End: ov.IntroEnd}
			from = "手动设定"
		}
		if ov.OutroEnd > ov.OutroStart {
			info.Outro = &emby.Range{Start: ov.OutroStart, End: ov.OutroEnd}
			from = "手动设定"
		}
	}

	need := (pf.SkipIntro && info.Intro == nil) || (pf.SkipOutro && info.Outro == nil)
	if !pf.SkipUseOnline || !need {
		return from
	}
	r := segments.Lookup(ctx, meta)
	if r == nil {
		return from
	}
	got := false
	if info.Intro == nil && r.Intro != nil {
		info.Intro = &emby.Range{Start: r.Intro.Start, End: r.Intro.End}
		got = true
	}
	if info.Outro == nil && r.Outro != nil {
		info.Outro = &emby.Range{Start: r.Outro.Start, End: r.Outro.End}
		got = true
	}
	if !got {
		return from
	}
	if from == "" {
		return r.From
	}
	return from + " + " + r.From
}

func registerSkip() {
	/* setSkipRange 手动设定片头片尾。四个值全是 0 = 清掉这一条。

	   ★ 键由**核心层**算(按剧),不让调用方传:调用方手里只有当前这一集的 id,
	     让它自己拼键的话每个端拼法一变,同一部剧就会存出好几条。 */
	bus.Register("player.setSkipRange", func(ctx context.Context, seq int64, a map[string]any) (any, error) {
		id, _ := a["item_id"].(string)
		if id == "" {
			return nil, bus.NewErr(bus.EInvalid, "缺少 item_id")
		}
		sess, err := sessionFrom(a)
		if err != nil {
			return nil, err
		}
		num := func(k string) float64 { v, _ := a[k].(float64); return v }
		r := config.SkipRange{
			IntroStart: num("intro_start"), IntroEnd: num("intro_end"),
			OutroStart: num("outro_start"), OutroEnd: num("outro_end"),
		}
		// ★ 拒而不是夹:悄悄夹紧的话用户看到「已保存」,实际存的是另一个值
		if r.IntroEnd < r.IntroStart || r.OutroEnd < r.OutroStart {
			return nil, bus.NewErr(bus.EInvalid, "结束时间不能早于开始时间")
		}
		key, _ := skipKeyOf(ctx, sess, id, 0)
		if key == "" {
			return nil, bus.NewErr(bus.EInternal, "取不到这一集所属的剧,先确认服务器连得上")
		}
		c := config.Current()
		pf := c.PrefsOf()
		if pf.SkipOverrides == nil {
			pf.SkipOverrides = map[string]config.SkipRange{}
		}
		if r == (config.SkipRange{}) {
			delete(pf.SkipOverrides, key)
		} else {
			pf.SkipOverrides[key] = r
		}
		return map[string]any{"key": key, "range": r}, savePrefs(c, pf)
	})

	// getSkipRange 这部剧手动设过什么。设过才有,没设过回 null ——
	// 回一个全 0 的结构会让界面把「没设过」显示成「设成了 0」。
	bus.Register("player.getSkipRange", func(ctx context.Context, seq int64, a map[string]any) (any, error) {
		id, _ := a["item_id"].(string)
		if id == "" {
			return nil, bus.NewErr(bus.EInvalid, "缺少 item_id")
		}
		sess, err := sessionFrom(a)
		if err != nil {
			return nil, err
		}
		key, _ := skipKeyOf(ctx, sess, id, 0)
		pf := config.Current().PrefsOf()
		if ov, ok := pf.SkipOverrides[key]; ok {
			return map[string]any{"key": key, "range": ov}, nil
		}
		return map[string]any{"key": key, "range": nil}, nil
	})
}
