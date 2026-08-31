package history

// `emby.watchHistory*` 命令。
//
// ★ 命令名归在 `emby.*` 而不是 `history.*` —— 这是**契约里定死的**
// (`docs/go-migration/COMMANDS.md`),不是随手划的。改名会让三端绑定一起对不上。

import (
	"context"

	"linplayer/core/bus"
	"linplayer/core/config"
)

var store *Store

// Store 返回进程级的那一个。播放链路要用它落记录。
func Shared() *Store {
	if store == nil {
		store = Default()
	}
	return store
}

// SetShared 换掉进程级实例。**只给测试用。**
func SetShared(s *Store) { store = s }

// RegisterCommands 由 lp_init 调用。
func RegisterCommands() {
	store = Default()

	// watchHistoryList 观看记录列表。
	//
	// current_only=true 只看当前服务器的;false 给全部(设置页的「观看记录」页要全部,
	// 因为跨服记录正是那一页存在的理由)。
	bus.Register("emby.watchHistoryList", func(ctx context.Context, seq int64, a map[string]any) (any, error) {
		if only, _ := a["current_only"].(bool); only {
			acc := config.Current().ActiveAccount()
			if acc == nil {
				return []Record{}, nil
			}
			return Shared().LoadScope(ScopeKey(acc.Server, acc.UserID)), nil
		}
		return Shared().LoadAll(), nil
	})

	bus.Register("emby.watchHistoryDelete", func(ctx context.Context, seq int64, a map[string]any) (any, error) {
		id, _ := a["record_id"].(string)
		if id == "" {
			return nil, bus.NewErr(bus.EInvalid, "缺少 record_id")
		}
		if err := Shared().DeleteRecord(id); err != nil {
			return nil, bus.NewErr(bus.EInternal, "删除失败: %v", err)
		}
		return map[string]any{"deleted": id}, nil
	})

	// watchHistoryClear 清空。
	//
	// ★ 这是**不可逆**的:观看记录只在本地,删了服务器上也没有备份。
	//   调用方必须先弹二次确认 —— 核心层这里不拦(拦了就没法做「设置页里带确认的清空」),
	//   但返回体里带上删了多少条,让 UI 能说清楚。
	bus.Register("emby.watchHistoryClear", func(ctx context.Context, seq int64, a map[string]any) (any, error) {
		n := len(Shared().LoadAll())
		if err := Shared().ClearAll(); err != nil {
			return nil, bus.NewErr(bus.EInternal, "清空失败: %v", err)
		}
		return map[string]any{"cleared": n}, nil
	})
}
