package aggregate

import (
	"context"
	"strings"
	"sync"

	"linplayer/core/bus"
	"linplayer/core/config"
	"linplayer/core/emby"
	"linplayer/core/history"
)

// VersionGroup 一台服务器上「同一部片」的版本表。
//
// ★ 按服分组而不是拌成一锅:同一档画质在两台服上都有时,拌起来用户看到两条
// 一模一样的「2160p」,而点哪一条会从哪台起播,界面上一个字都没说
// (聚合搜索栽过同一个坑,见 aggregateSearch 的注释)。
type VersionGroup struct {
	ServerID   string `json:"server_id"`
	ServerName string `json:"server_name"`
	// ItemID 是**这台服务器上**的条目 id。跨服起播要带它,不是原来那台的。
	ItemID  string `json:"item_id"`
	Current bool   `json:"current"`
	// Reason 凭什么认为是同一部(本服那组为空)。给用户看的 ——
	// 「剧名 + 季集号匹配」和「剧集 TMDB + 季集号匹配」的可信度差着一档。
	Reason   string              `json:"reason"`
	Versions []emby.MediaVersion `json:"versions"`
}

// 跨服找片时每台服务器最多看几个候选。
//
// ★ 卡这个数是因为**下一步要逐个查 TMDB / 拉全字段**:50 条结果就是 50 个请求,
// 而正确答案几乎总在前几条里(搜索本来就是按相关度排的)。
const versionPoolCap = 10

// registerVersionCommands 由 RegisterCommands 调。
func registerVersionCommands() {
	/* aggregateVersions 把**所有已登录服务器上的同一部片**的版本表并成一张。
	   用户 2026-09-05:「优化集详情页的版本选择……聚合不同服务器的版本」。

	   ★ 本服那一组**不参与匹配**,直接取 —— 它就是用户点开的那个条目,
	     拿指纹再判一次自己只会引入「自己和自己匹配不上」这种荒唐失败。
	   ★ 单台失败隔离:一台连不上 / 没有这部片,那台不出现,其余照出。 */
	bus.Register("emby.aggregateVersions", func(ctx context.Context, seq int64, a map[string]any) (any, error) {
		itemID, _ := a["item_id"].(string)
		if strings.TrimSpace(itemID) == "" {
			return nil, bus.NewErr(bus.EInvalid, "缺少 item_id")
		}
		serverID, _ := a["server_id"].(string)
		regex, _ := a["version_regex"].(string)

		c := config.Current()
		// Resolve 而不是 Find:UI 报回来的多半是**生效线路地址**(见它的注释)
		base := c.Resolve(serverID)
		if base == nil || base.IsFileBrowse() {
			return nil, bus.NewErr(bus.ENotFound, "没有这个 Emby 服务器:"+serverID)
		}
		bs := sessionOf(c, *base)

		/* 本服条目必须走 ItemForHistory(带 HistoryFields)。
		   拿 Detail 的字段去匹配 = ProviderIds / Path 全是空,判据静默降级到
		   「剧名 + 季集号」—— 那正是跨服最容易假装能用的失败形态。 */
		it, err := client.ItemForHistory(ctx, bs, itemID)
		if err != nil {
			return nil, &bus.Err{Code: bus.ENetwork, Msg: err.Error(), Retryable: true}
		}
		self := history.CandidateFromItem(*it)
		selfTmdb := client.SeriesTmdbID(ctx, bs, strDeref(it.SeriesID))

		slots := make([]*VersionGroup, len(c.AccountList))
		var wg sync.WaitGroup
		for i := range c.AccountList {
			acc := c.AccountList[i]
			if acc.IsFileBrowse() {
				continue // 浏览型源没有 Emby 的版本表
			}
			wg.Add(1)
			go func(i int, acc config.Account) {
				defer wg.Done()
				s := sessionOf(c, acc)
				id, reason := self.ID, ""
				if acc.Server != base.Server {
					cand, m := findSame(ctx, s, self, selfTmdb)
					if cand == nil {
						return // 这台没有这部片(或者匹配不到可信的),不出现
					}
					id, reason = cand.ID, m.Reason
				}
				vers, err := client.MediaVersions(ctx, s, id, regex)
				if err != nil || len(vers) == 0 {
					return
				}
				slots[i] = &VersionGroup{
					ServerID: acc.Server, ServerName: acc.DisplayName(),
					ItemID: id, Current: acc.Server == base.Server,
					Reason: reason, Versions: vers,
				}
			}(i, acc)
		}
		wg.Wait()

		// 本服排头,其余按账号表顺序 —— 不按谁先返回,否则每次打开顺序都在跳
		out := []VersionGroup{}
		for _, g := range slots {
			if g != nil && g.Current {
				out = append(out, *g)
			}
		}
		for _, g := range slots {
			if g != nil && !g.Current {
				out = append(out, *g)
			}
		}
		return out, nil
	})
}

// findSame 在另一台服务器上找同一部片。
//
// ★★ 返回 nil = 没找到**可信**的,不是「随便挑一个」。挑错的后果是用户
// 以为在选另一档画质,实际换了一部片 —— 而且从头到尾没有一个报错。
func findSame(ctx context.Context, s *emby.Session, self history.Candidate,
	selfTmdb *string) (*history.Candidate, history.MatchResult) {
	kind, ok := history.MediaKindFromItemType(self.Type)
	if !ok {
		return nil, history.MatchResult{} // 剧 / 季 / 合集没有版本表
	}
	if kind == history.KindEpisode {
		return findEpisode(ctx, s, self, selfTmdb)
	}
	return pick(ctx, s, self, selfTmdb, searchFull(ctx, s, self.Name, []string{"Movie"}))
}

// findEpisode 剧集要**两跳**:先按剧名找剧,再在那部剧里按季集号取集。
//
// ★ 不能直接搜集名:Emby 的 Episode.Name 是「第 35 集」这种,
// 搜出来的是全库所有剧的第 35 集。
func findEpisode(ctx context.Context, s *emby.Session, self history.Candidate,
	selfTmdb *string) (*history.Candidate, history.MatchResult) {
	name := strDeref(self.SeriesName)
	if name == "" || self.SeasonNo == nil || self.EpisodeNo == nil {
		return nil, history.MatchResult{}
	}
	series, err := client.Search(ctx, s, name, []string{"Series"}, versionPoolCap, "")
	if err != nil {
		return nil, history.MatchResult{}
	}
	var pool []emby.Item
	for _, sr := range series {
		ep := episodeAt(ctx, s, sr.ID, *self.SeasonNo, *self.EpisodeNo)
		if ep != nil {
			pool = append(pool, *ep)
		}
		if len(pool) >= 3 {
			break // 同名剧超过三部就别再打请求了,后面几乎全是错的
		}
	}
	return pick(ctx, s, self, selfTmdb, pool)
}

// episodeAt 在某剧里取第 season 季第 episode 集。没有就 nil。
//
// ★ 先走 Seasons 再拉那一季,不是把整部剧的集全拉下来:上千集的剧那是一次几 MB
// 的响应,而我们只要其中一条。没分季的剧(Seasons 空)才回落到按剧 id 拉。
func episodeAt(ctx context.Context, s *emby.Session, seriesID string, season, episode int64) *emby.Item {
	parent := seriesID
	if seasons, err := client.Seasons(ctx, s, seriesID); err == nil {
		for _, sn := range seasons {
			if sn.IndexNo != nil && *sn.IndexNo == season {
				parent = sn.ID
				break
			}
		}
	}
	page, err := client.SeasonEpisodes(ctx, s, parent, 0, emby.ServerPageCap)
	if err != nil || page == nil {
		return nil
	}
	for i := range page.Items {
		e := page.Items[i]
		if e.SeasonNo != nil && *e.SeasonNo == season && e.EpisodeNo != nil && *e.EpisodeNo == episode {
			return &e
		}
	}
	return nil
}

// searchFull 搜一批候选。出错当没搜到 —— 单台失败隔离。
func searchFull(ctx context.Context, s *emby.Session, query string, types []string) []emby.Item {
	if strings.TrimSpace(query) == "" {
		return nil
	}
	items, err := client.Search(ctx, s, query, types, versionPoolCap, "")
	if err != nil {
		return nil
	}
	return items
}

// pick 从候选池里挑出可信的那一条。判据与恢复扫描(history.resolveCandidate)一致:
// 唯一强匹配才自动取,多个强匹配 = 分不清,宁可不给。
func pick(ctx context.Context, s *emby.Session, self history.Candidate, selfTmdb *string,
	items []emby.Item) (*history.Candidate, history.MatchResult) {
	if len(items) == 0 {
		return nil, history.MatchResult{}
	}
	/* 候选必须**重新按 HistoryFields 取一遍**:搜索 / 分集列表返回的条目里
	   没有 ProviderIds / Path,拿它们算指纹只会得到「关键信息不足」。 */
	var pool []history.Candidate
	for i := range items {
		if len(pool) >= versionPoolCap {
			break
		}
		full, err := client.ItemForHistory(ctx, s, items[i].ID)
		if err != nil {
			continue
		}
		pool = append(pool, history.CandidateFromItem(*full))
	}
	if len(pool) == 0 {
		return nil, history.MatchResult{}
	}

	unique := len(pool) == 1
	var hit []int
	var res []history.MatchResult
	for i := range pool {
		m := history.MatchCandidates(self, pool[i], selfTmdb,
			client.SeriesTmdbID(ctx, s, strDeref(pool[i].SeriesID)), unique)
		if m.Confidence != history.ConfNone {
			hit = append(hit, i)
			res = append(res, m)
		}
	}
	var strong []int
	for i, m := range res {
		if m.Confidence == history.ConfStrong {
			strong = append(strong, i)
		}
	}
	if len(strong) == 1 {
		i := strong[0]
		return &pool[hit[i]], res[i]
	}
	// ★★ 多个强匹配 → 不给。挑一个的后果是「选了 4K,放出来是另一部片」。
	if len(strong) > 1 || len(hit) != 1 {
		return nil, history.MatchResult{}
	}
	// 只剩一个候选 → 按 unique 重算(weak 会升成 possible),仍不可信就不给
	i := hit[0]
	m := history.MatchCandidates(self, pool[i], selfTmdb,
		client.SeriesTmdbID(ctx, s, strDeref(pool[i].SeriesID)), true)
	if !m.Confidence.IsTrusted() {
		return nil, history.MatchResult{}
	}
	return &pool[i], m
}

func strDeref(p *string) string {
	if p == nil {
		return ""
	}
	return *p
}
