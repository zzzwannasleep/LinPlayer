package download

// `download.*` 八条命令。

import (
	"context"
	"strings"

	"linplayer/core/bus"
	"linplayer/core/config"
	"linplayer/core/httpx"
	"linplayer/core/paths"
)

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
		if p := str(a, "poster_url"); p != "" {
			it.PosterURL = &p
		}
		return m.Enqueue(it), nil
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
		return map[string]any{"threads": m.Threads()}, nil
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
