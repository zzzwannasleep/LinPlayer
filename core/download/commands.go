package download

// `download.*` 八条命令。

import (
	"context"
	"strings"

	"linplayer/core/bus"
	"linplayer/core/config"
	"linplayer/core/emby"
	"linplayer/core/httpx"
	"linplayer/core/paths"
)

/*
allEpisodes 翻到底拿一季的全部分集。

★ **不能只拿一页**。服务端把任何 Limit 都夹到 ServerPageCap(200),
超过 200 集的季上一趟拿完的写法是**静默少拿**:
界面报「已加入 200 集」,而用户以为整季都在里面了。
*/
func allEpisodes(fetch func(start int) (*emby.Page, error)) ([]emby.Item, error) {
	var out []emby.Item
	for {
		page, err := fetch(len(out))
		if err != nil {
			return nil, err
		}
		out = append(out, page.Items...)
		// 两道出口都要:Total 在某些 fork 上是 0,只看它会死循环。
		if len(page.Items) < emby.ServerPageCap || int64(len(out)) >= page.Total {
			return out, nil
		}
	}
}

// SeasonQueued 整季入队的回执。
//
// Skipped 要单独报:全都已经在队里时 queued=0,只报这一个数字的话
// 界面只能说「加入下载失败」,而其实什么问题都没有。
type SeasonQueued struct {
	Queued  int      `json:"queued"`
	Skipped int      `json:"skipped"`
	IDs     []string `json:"ids"`
}

var shared *Manager

// Shared 全局下载管理器。起播时要问它「这个条目本地有没有」。
func Shared() *Manager { return shared }

// RegisterCommands 由 core/commands 调用。
func RegisterCommands() {
	m, err := New(paths.DownloadsDir(), httpx.EmbyClient())
	if err != nil {
		bus.Logf("error", "下载目录建不出来,下载功能不可用: %v", err)
		return
	}
	shared = m

	// download.enqueue —— 走 Emby /Items/{id}/Download(服务端按下载权限放行)。
	//
	// ★ 权限在**服务端**判。客户端不预判「这个用户能不能下」——
	//   预判错了要么白挡(能下的说不能),要么白放(点下去才 403)。
	bus.Register("download.enqueue", func(ctx context.Context, seq int64, a map[string]any) (any, error) {
		itemID := str(a, "item_id")
		if itemID == "" {
			return nil, bus.NewErr(bus.EInvalid, "缺少 item_id")
		}
		acc := config.Current().ActiveAccount()
		if acc == nil || acc.IsFileBrowse() {
			return nil, bus.NewErr(bus.EAuth, "请先登录 Emby 服务器")
		}
		server := strings.TrimRight(acc.ActiveLineURL(), "/")
		url := server + "/Items/" + itemID + "/Download?api_key=" + acc.Token

		it := &Item{
			ItemID:    itemID,
			Type:      str(a, "type_"),
			Title:     str(a, "title"),
			Container: str(a, "container"),
			URL:       url,
		}
		// 剧名 / 季集号是**文件名**要用的:只给「第 12 集」的话两部剧各下一集
		// 就撞成同一个文件(见 fileBase)。调用方给不出就算了,不强求。
		if v := str(a, "series_name"); v != "" {
			it.SeriesName = &v
		}
		if v, ok := a["season_number"].(float64); ok {
			n := int64(v)
			it.SeasonNumber = &n
		}
		if v, ok := a["episode_number"].(float64); ok {
			n := int64(v)
			it.EpisodeNumber = &n
		}
		if p := str(a, "poster_url"); p != "" {
			it.PosterURL = &p
		}
		return m.Enqueue(it), nil
	})

	/* download.enqueueSeason —— 把一季的分集**逐条**入队(草稿 03 页第 13 条)。

	   ★ 展开放核心层。三端各写一遍循环的话,「已经在队里的要不要跳过」
	     这件事迟早会分叉,而分叉的表现是「点两下就下了两份」。
	   ★ 已经在队里 / 已下好的**跳过而不是报错**:整季下载天然会重复点
	     (追更时每周点一次),每次都从头排一遍队才是错的。 */
	bus.Register("download.enqueueSeason", func(ctx context.Context, seq int64, a map[string]any) (any, error) {
		parentID := str(a, "parent_id")
		if parentID == "" {
			return nil, bus.NewErr(bus.EInvalid, "缺少 parent_id")
		}
		acc := config.Current().ActiveAccount()
		if acc == nil || acc.IsFileBrowse() {
			return nil, bus.NewErr(bus.EAuth, "请先登录 Emby 服务器")
		}
		sess := &emby.Session{
			Server: acc.ActiveLineURL(), Token: acc.Token,
			UserID: acc.UserID, DeviceID: config.Current().DeviceID,
		}
		eps, err := allEpisodes(func(start int) (*emby.Page, error) {
			return emby.Shared().SeasonEpisodes(ctx, sess, parentID, start, emby.ServerPageCap)
		})
		if err != nil {
			return nil, &bus.Err{Code: bus.ENetwork, Msg: err.Error(), Retryable: true}
		}
		/* parent_id 给季 id 就不用 season。给**剧 id** 时拿回来的是整部分集
		   (Recursive=true),这时候必须靠 season 筛—— 因为剧详情页上
		   界面只有季号,拿不到那一季的 id。 */
		if season, ok := a["season"].(float64); ok {
			kept := eps[:0]
			for _, ep := range eps {
				if ep.SeasonNo != nil && *ep.SeasonNo == int64(season) {
					kept = append(kept, ep)
				}
			}
			eps = kept
		}
		if len(eps) == 0 {
			return nil, bus.NewErr(bus.ENotFound, "这一季一集都没有")
		}

		queued := map[string]bool{}
		for _, one := range m.List() {
			queued[one.ItemID] = true
		}
		server := strings.TrimRight(acc.ActiveLineURL(), "/")
		out := SeasonQueued{IDs: []string{}}
		for i := range eps {
			ep := eps[i]
			if queued[ep.ID] {
				out.Skipped++
				continue
			}
			it := &Item{
				ItemID: ep.ID,
				Type:   ep.Type,
				Title:  ep.Name,
				// 列表命令不发 container,交给核心层兜底(默认 mkv)——
				// 和卡片右键那条「下载」同一个口径。
				URL:           server + "/Items/" + ep.ID + "/Download?api_key=" + acc.Token,
				SeriesID:      ep.SeriesID,
				SeriesName:    ep.SeriesName,
				SeasonNumber:  ep.SeasonNo,
				EpisodeNumber: ep.EpisodeNo,
			}
			if p := str(a, "poster_url"); p != "" {
				it.PosterURL = &p
			}
			out.IDs = append(out.IDs, m.Enqueue(it))
			out.Queued++
		}
		return out, nil
	})

	bus.Register("download.list", func(ctx context.Context, seq int64, a map[string]any) (any, error) {
		return m.List(), nil // List 已经保证是空切片不是 nil
	})

	bus.Register("download.pause", func(ctx context.Context, seq int64, a map[string]any) (any, error) {
		m.Pause(str(a, "id"))
		return nil, nil
	})

	bus.Register("download.resume", func(ctx context.Context, seq int64, a map[string]any) (any, error) {
		m.Resume(str(a, "id"))
		return nil, nil
	})

	bus.Register("download.remove", func(ctx context.Context, seq int64, a map[string]any) (any, error) {
		m.Remove(str(a, "id"))
		return nil, nil
	})

	bus.Register("download.clearCompleted", func(ctx context.Context, seq int64, a map[string]any) (any, error) {
		return m.ClearCompleted(), nil
	})

	/* download.setThreads —— 设并回读。
	   ★ **不传 threads = 只读当前值**。
	     UI_PC §7.9 要求「并发数归核心层持久化,UI 只读不灌」,而契约里
	     (COMMANDS.md 生成自 Rust 注册表)**没有一条读它的命令** ——
	     黄金实现那边这个值只活在内存里,每次启动回到 2,所以从来不需要读。
	     迁移期不动契约,于是把「只读」并进这一条:少一个参数就是问,不是设。
	   ⚠️ 契约冻结(B3)时应当拆成 download.threads 一条独立命令。 */
	bus.Register("download.setThreads", func(ctx context.Context, seq int64, a map[string]any) (any, error) {
		if v, ok := a["threads"]; ok && v != nil {
			m.SetThreads(int(num(a, "threads")))
		}
		// ★ 回读**实际生效**的档位:核心层会钳在 1~4。
		//   只回 nil 的话,用户设了 8 线程、实际生效 4 线程,毫无反馈。
		return ThreadsReply{Threads: m.Threads()}, nil
	})

	// download.andApplyUpdate —— 自更新的下载 + 应用那一步。
	//
	// ★ 它**不属于**下载管理器:更新包不进下载列表、不占那条并发、
	//   下完还要重启进程换掉自己。等 core/update(C4)落地时接上,
	//   现在如实说「还没做」,不假装成功。
	bus.Register("download.andApplyUpdate", func(ctx context.Context, seq int64, a map[string]any) (any, error) {
		return nil, bus.NewErr(bus.EUnsupported, "自动更新还没接上(等 core/update)")
	})
}

// Close 关停。lp_shutdown 调它。
func Close() {
	if shared != nil {
		shared.Close()
	}
}

func str(a map[string]any, k string) string {
	if v, ok := a[k].(string); ok {
		return v
	}
	return ""
}

func num(a map[string]any, k string) float64 {
	if v, ok := a[k].(float64); ok {
		return v
	}
	return 0
}

// ThreadsReply 分段数的回读。**不传 threads 就是只读** —— 两端的下载页
// 都靠它显示当前档位,而它此前是个裸 map,字段名门禁对不上账。
type ThreadsReply struct {
	Threads int `json:"threads"`
}
