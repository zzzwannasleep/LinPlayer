package history

// `emby.watchHistory*` 命令。
//
// ★ 命令名归在 `emby.*` 而不是 `history.*` —— 这是**契约里定死的**
// (`docs/go-migration/COMMANDS.md`),不是随手划的。改名会让三端绑定一起对不上。

import (
	"context"

	"encoding/json"

	"linplayer/core/bus"
	"linplayer/core/config"
	"linplayer/core/emby"
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

	registerRestoreCommands()
}

// sessionOf 从参数里取会话;缺了就回落到当前活跃账号。
//
// ★ 回落是必要的:恢复扫描是个「换服 / 重装之后跑一次」的动作,
// 调用点常常在设置页,而那儿手边没有会话参数。
func sessionOf(a map[string]any) (*emby.Session, error) {
	get := func(k string) string { v, _ := a[k].(string); return v }
	s := &emby.Session{
		Server: get("server"), Token: get("token"),
		UserID: get("user_id"), DeviceID: get("device_id"),
	}
	if s.Server != "" && s.UserID != "" {
		return s, nil
	}
	acc := config.Current().ActiveAccount()
	if acc == nil {
		return nil, bus.NewErr(bus.EInvalid, "没有活跃的服务器账号")
	}
	c := config.Current()
	return &emby.Session{
		Server: acc.Server, Token: acc.Token,
		UserID: acc.UserID, DeviceID: c.DeviceID,
	}, nil
}

func registerRestoreCommands() {
	// emby.watchHistoryScanRestore —— 换服 / 重装后把本地记录推回服务器。
	//
	// ★★ 报告里的 errors 一定要透出去:这个功能最危险的 bug 是
	//   「不崩,只是悄悄少恢复了几条」—— 没有 errors 的话没人会发现。
	// ★ prompt_candidates 是**要用户拍板**的那一批(可能匹配但不确定),
	//   调用方拿去逐条问,确认了再调 watchHistoryRestoreCandidate。
	bus.Register("emby.watchHistoryScanRestore", func(ctx context.Context, seq int64, a map[string]any) (any, error) {
		s, err := sessionOf(a)
		if err != nil {
			return nil, err
		}
		return ScanRestore(ctx, emby.Default(), s, Shared(), ScopeKey(s.Server, s.UserID)), nil
	})

	// emby.watchHistoryRestoreCandidate —— 用户确认了某条候选,真的写回去。
	bus.Register("emby.watchHistoryRestoreCandidate", func(ctx context.Context, seq int64, a map[string]any) (any, error) {
		raw, err := json.Marshal(a["candidate"])
		if err != nil {
			return nil, bus.NewErr(bus.EInvalid, "candidate 不合法: %v", err)
		}
		var cand RestoreCandidate
		if json.Unmarshal(raw, &cand) != nil || cand.MatchedItem.ID == "" {
			return nil, bus.NewErr(bus.EInvalid, "candidate 不合法(缺 matched_item.id)")
		}
		s, err := sessionOf(a)
		if err != nil {
			return nil, err
		}
		done, err := RestoreOne(ctx, emby.Default(), s, Shared(), cand)
		if err != nil {
			return nil, bus.NewErr(bus.ENetwork, "%v", err)
		}
		// ★ 「写成功了」和「没什么可写」要分开:后者不是失败,
		//   但界面不能说「已恢复」——那条记录压根没有进度可写。
		return map[string]any{"restored": done}, nil
	})
}
