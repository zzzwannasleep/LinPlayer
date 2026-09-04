package danmaku

// 智能集数匹配:并行向所有源做三路召回,合分排序。
//
// ★★ 三路召回互为补充,任何一路都可能是**唯一**能对上的那一路:
//
//	① 文件识别(/match):真实文件名 + 时长。唯一命中最可信。
//	② 集搜索(/search/episodes):标题 + 集号一起搜。
//	③ 番搜索(/search/anime → /bangumi/{id}):先挑番再挑集,长标题被呛住时靠主名召回。

import (
	"context"
	"fmt"
	"sort"
	"strconv"
	"strings"
	"sync"
	"time"
)

// SearchMinInterval 两次**用户主动**搜索之间的最小间隔。
//
// 用户 2026-08-02:「比如 5 秒内最多搜索 1 次」。
const SearchMinInterval = 5 * time.Second

var (
	gateMu     sync.Mutex
	lastSearch time.Time
	hasSearch  bool
)

// trySearchAt 内部实现,时钟由调用方给 —— 不然这条护栏只能靠 sleep 5 秒去测。
func trySearchAt(now time.Time) (leftSecs float64, ok bool) {
	gateMu.Lock()
	defer gateMu.Unlock()
	if hasSearch {
		if elapsed := now.Sub(lastSearch); elapsed < SearchMinInterval {
			return (SearchMinInterval - elapsed).Seconds(), false
		}
	}
	lastSearch, hasSearch = now, true
	return 0, true
}

// SearchGate 主动搜索闸门。
//
// ★ **只在这次请求会打到官方源时**调用 —— 自建源是用户自己的服务器,
// 没有配额可烧,给它限速纯属添堵。
//
// ★ 选择「拒绝」而不是「排队等待」:排队的话用户按一下搜索键要盯着转圈五秒,
// 连按五下就排出 25 秒的队,比报错难受得多。报错至少说清了还要等几秒。
func SearchGate() error {
	left, ok := trySearchAt(time.Now())
	if ok {
		return nil
	}
	return fmt.Errorf("搜得太快了,请 %.0f 秒后再试(官方弹幕接口有调用配额)", ceil(left))
}

func ceil(f float64) float64 {
	n := float64(int64(f))
	if f > n {
		return n + 1
	}
	return n
}

// episodeMatches 这一集是不是要找的那一集。
func episodeMatches(ep *Episode, epNum *int64) bool {
	if epNum == nil || ep.EpisodeNumber == nil {
		return false
	}
	raw := strings.TrimSpace(*ep.EpisodeNumber)
	if raw == "" {
		return false
	}
	if n, err := strconv.ParseInt(raw, 10, 64); err == nil {
		return n == *epNum
	}
	// episodeNumber 可能是「第3话」/「03」之类,抽首个数字串比对
	if d := digitsRe.FindString(raw); d != "" {
		if n, err := strconv.ParseInt(d, 10, 64); err == nil {
			return n == *epNum
		}
	}
	return false
}

// pickEpisode 从集表里挑要的那一集。
func pickEpisode(eps []Episode, epNum *int64) *Episode {
	if len(eps) == 0 {
		return nil
	}
	if epNum != nil {
		for i := range eps {
			if episodeMatches(&eps[i], epNum) {
				return &eps[i]
			}
		}
		// ★ 集号越界时退回**按位置**取:部分源的 episodeNumber 不规整
		//   (有的从 0 开始,有的带 SP 混在里面)
		if n := *epNum; n >= 1 && n <= int64(len(eps)) {
			return &eps[n-1]
		}
	}
	return &eps[0]
}

// matchByFile ①文件识别。
func matchByFile(ctx context.Context, cfg *SourceConfig, in *MatchInput) ([]MatchCandidate, error) {
	if strings.TrimSpace(in.FileName) == "" {
		return nil, nil
	}
	hash := ""
	if in.FileHash != nil {
		hash = *in.FileHash
	}
	var size int64
	if in.FileSize != nil {
		size = *in.FileSize
	}
	var dur float64
	if in.DurationSecs != nil {
		dur = *in.DurationSecs
	}
	r, err := cfg.MatchFile(ctx, in.FileName, hash, size, dur)
	if err != nil {
		return nil, err
	}
	confident := r.IsMatched && len(r.Matches) == 1
	out := make([]MatchCandidate, 0, len(r.Matches))
	for _, m := range r.Matches {
		// ★ 文件识别唯一命中最可信:给到**高于名字搜索满分**
		//   (标题 1.0 + 集号 0.3 + 季号 0.15 = 1.45)的分,确保排最前
		score := 1.6
		if !confident {
			score = TitleScore(in, m.AnimeTitle) + SeasonTerm(in, m.AnimeTitle) + 0.2
		}
		out = append(out, MatchCandidate{
			SourceID: cfg.ID, SourceName: cfg.Name,
			AnimeID: m.AnimeID, AnimeTitle: m.AnimeTitle,
			EpisodeID: m.EpisodeID, EpisodeTitle: m.EpisodeTitle,
			Score: score,
		})
	}
	return out, nil
}

// candidatesFrom 把「番 + 集表」摊成候选。
func candidatesFrom(cfg *SourceConfig, in *MatchInput, animes []Anime) []MatchCandidate {
	out := []MatchCandidate{}
	for i := range animes {
		a := &animes[i]
		base := TitleScore(in, a.AnimeTitle) + SeasonTerm(in, a.AnimeTitle)
		ep := pickEpisode(a.Episodes, in.EpisodeNo)
		if ep == nil {
			continue
		}
		score := base
		if episodeMatches(ep, in.EpisodeNo) {
			score += 0.3 // 集号真对上了,是一路独立信号
		}
		out = append(out, MatchCandidate{
			SourceID: cfg.ID, SourceName: cfg.Name,
			AnimeID: a.AnimeID, AnimeTitle: a.AnimeTitle,
			EpisodeID: ep.EpisodeID, EpisodeTitle: ep.EpisodeTitle,
			Score: score,
		})
	}
	return out
}

// matchOne 对一个源跑完三路召回。
//
// ★★ **半失败必须如实报,不能吞成「没搜到」。**
//
// 弹弹Play 的 /search 和 /match 配额是**分开**的,最常见的形态就是一路 429、
// 另一路正常回空 —— 实测同一入参连打四次,第四次静默变 null,而候选表其实是空的。
// 旧判据是「两路都失败才报错」,于是这种半失败一路传到界面变成「未找到匹配的弹幕」
// —— 又是那句谎话,只是从另一条岔路长回来的。
func matchOne(ctx context.Context, cfg *SourceConfig, in *MatchInput) ([]MatchCandidate, error) {
	var (
		wg   sync.WaitGroup
		mu   sync.Mutex
		out  []MatchCandidate
		errs []string
	)
	add := func(c []MatchCandidate, err error) {
		mu.Lock()
		defer mu.Unlock()
		if err != nil {
			errs = append(errs, err.Error())
			return
		}
		out = append(out, c...)
	}

	wg.Add(3)
	// ① 文件识别
	go func() {
		defer wg.Done()
		add(matchByFile(ctx, cfg, in))
	}()
	// ② 集搜索:标题 + 集号
	go func() {
		defer wg.Done()
		epStr := ""
		if in.EpisodeNo != nil {
			epStr = strconv.FormatInt(*in.EpisodeNo, 10)
		}
		animes, err := cfg.SearchEpisodes(ctx, in.Title, epStr)
		if err != nil {
			add(nil, err)
			return
		}
		add(candidatesFrom(cfg, in, animes), nil)
	}()
	// ③ 番搜索:主名召回 → 逐个取集表
	go func() {
		defer wg.Done()
		// ★ 用**主名**而不是整串:带季号、带副标题的长标题会把全文检索呛住,
		//   整串搜出来常常是 0 条,而只搜主名就有
		animes, err := cfg.SearchAnime(ctx, CoreName(in.Title))
		if err != nil {
			add(nil, err)
			return
		}
		// ★ 只给**最像的前几个**取集表:每个都取要 N 次往返,而排在后面的
		//   本来也进不了候选
		sort.SliceStable(animes, func(i, j int) bool {
			return TitleScore(in, animes[i].AnimeTitle) > TitleScore(in, animes[j].AnimeTitle)
		})
		const topN = 4
		if len(animes) > topN {
			animes = animes[:topN]
		}
		for i := range animes {
			if len(animes[i].Episodes) > 0 {
				continue
			}
			if eps, err := cfg.BangumiEpisodes(ctx, animes[i].AnimeID); err == nil {
				animes[i].Episodes = eps
			}
		}
		add(candidatesFrom(cfg, in, animes), nil)
	}()
	wg.Wait()

	/* ★★ 判据是「**一条候选都没有,而且有路子失败了**」→ 报错。
	   不是「所有路子都失败了」才报 —— 半失败(一路 429 一路回空)会被后者吞掉。 */
	if len(out) == 0 && len(errs) > 0 {
		return nil, fmt.Errorf("%s", strings.Join(dedupStrings(errs), ";"))
	}
	return out, nil
}

// MatchAll 并行向所有传入源做智能匹配,返回按可信度降序的候选。
//
// ★ 官方弹弹Play 参不参与由调用方决定(用 AllowOfficialFor 判后从 cfgs 里剔除)。
func MatchAll(ctx context.Context, cfgs []SourceConfig, in *MatchInput) ([]MatchCandidate, error) {
	if strings.TrimSpace(in.Title) == "" {
		return []MatchCandidate{}, nil
	}
	var (
		wg   sync.WaitGroup
		mu   sync.Mutex
		all  []MatchCandidate
		errs []string
	)
	for i := range cfgs {
		cfg := cfgs[i]
		wg.Add(1)
		go func() {
			defer wg.Done()
			c, err := matchOne(ctx, &cfg, in)
			mu.Lock()
			defer mu.Unlock()
			if err != nil {
				// ★ 带上源名:三个源里哪个挂了,用户得看得出来
				errs = append(errs, cfg.Name+": "+err.Error())
				return
			}
			all = append(all, c...)
		}()
	}
	wg.Wait()

	if len(all) == 0 && len(errs) > 0 {
		return nil, fmt.Errorf("%s", strings.Join(errs, ";"))
	}
	sort.SliceStable(all, func(i, j int) bool { return all[i].Score > all[j].Score })
	if all == nil {
		all = []MatchCandidate{}
	}
	return all, nil
}

func dedupStrings(in []string) []string {
	seen := map[string]bool{}
	out := make([]string, 0, len(in))
	for _, s := range in {
		if !seen[s] {
			seen[s] = true
			out = append(out, s)
		}
	}
	return out
}
