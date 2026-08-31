package sync

// `sync.*` 十五条命令。

import (
	"context"
	"encoding/json"

	"linplayer/core/bus"
)

// RegisterCommands 由 core/commands 调用。
func RegisterCommands() {
	// ---- Trakt ----
	bus.Register("sync.traktAccount", func(ctx context.Context, seq int64, a map[string]any) (any, error) {
		return Load("trakt"), nil // nil = 没连,不是错误
	})

	bus.Register("sync.traktDeviceCode", func(ctx context.Context, seq int64, a map[string]any) (any, error) {
		c, err := TraktRequestDeviceCode(ctx)
		if err != nil {
			return nil, upstream(err)
		}
		return c, nil
	})

	// ★ 轮询**永远返回结果对象**,不抛错。pending / slowDown 都是正常状态 ——
	//   抛错的话前端的重试逻辑要靠解析错误文案来分辨,那是最脆的一种判断。
	bus.Register("sync.traktPoll", func(ctx context.Context, seq int64, a map[string]any) (any, error) {
		r := TraktPollOnce(ctx, str(a, "device_code"))
		if r.State == "authorized" && r.Account != nil {
			if err := Save("trakt", r.Account); err != nil {
				return nil, bus.NewErr(bus.EInternal, "配置保存失败: %v", err)
			}
		}
		return r, nil
	})

	bus.Register("sync.traktLogout", func(ctx context.Context, seq int64, a map[string]any) (any, error) {
		return nil, Save("trakt", nil)
	})

	bus.Register("sync.traktScrobble", func(ctx context.Context, seq int64, a map[string]any) (any, error) {
		acc := Load("trakt")
		if acc == nil {
			return false, nil // 没连 Trakt 不是错误,只是不上报
		}
		var ids json.RawMessage
		if v, ok := a["ids"]; ok {
			if b, err := json.Marshal(v); err == nil {
				ids = b
			}
		}
		return TraktScrobble(ctx, acc, str(a, "type_"), ids, num(a, "progress"), str(a, "action")), nil
	})

	bus.Register("sync.traktCalendar", func(ctx context.Context, seq int64, a map[string]any) (any, error) {
		acc := Load("trakt")
		if acc == nil {
			return nil, bus.NewErr(bus.EAuth, "还没有连接 Trakt")
		}
		// 起点往前 7 天、共 21 天:上周刚播的也要看得到,不然「昨天更新的那集」不在表里
		return TraktCalendar(ctx, acc, 7, 21, boolArg(a, "only_mine")), nil
	})

	// ---- Bangumi ----
	bus.Register("sync.bangumiAccount", func(ctx context.Context, seq int64, a map[string]any) (any, error) {
		return Load("bangumi"), nil
	})

	bus.Register("sync.bangumiAuthorizeUrl", func(ctx context.Context, seq int64, a map[string]any) (any, error) {
		return BangumiAuthorizeURL(str(a, "redirect_uri")), nil
	})

	bus.Register("sync.bangumiExchange", func(ctx context.Context, seq int64, a map[string]any) (any, error) {
		acc, err := BangumiExchangeCode(ctx, str(a, "code"), str(a, "redirect_uri"))
		if err != nil {
			return nil, upstream(err)
		}
		if err := Save("bangumi", acc); err != nil {
			return nil, bus.NewErr(bus.EInternal, "配置保存失败: %v", err)
		}
		return acc, nil
	})

	bus.Register("sync.bangumiLoginToken", func(ctx context.Context, seq int64, a map[string]any) (any, error) {
		acc, err := BangumiLoginWithToken(ctx, str(a, "token"))
		if err != nil {
			return nil, &bus.Err{Code: bus.EAuth, Msg: err.Error()}
		}
		if err := Save("bangumi", acc); err != nil {
			return nil, bus.NewErr(bus.EInternal, "配置保存失败: %v", err)
		}
		return acc, nil
	})

	bus.Register("sync.bangumiLogout", func(ctx context.Context, seq int64, a map[string]any) (any, error) {
		return nil, Save("bangumi", nil)
	})

	bus.Register("sync.bangumiSetCollection", func(ctx context.Context, seq int64, a map[string]any) (any, error) {
		acc := Load("bangumi")
		if acc == nil {
			return nil, bus.NewErr(bus.EAuth, "还没有连接 Bangumi")
		}
		ok, err := BangumiSetCollection(ctx, acc, int64(num(a, "subject_id")), int(num(a, "type_")))
		if err != nil {
			return nil, upstream(err)
		}
		return ok, nil
	})

	bus.Register("sync.bangumiUpdateEpisode", func(ctx context.Context, seq int64, a map[string]any) (any, error) {
		acc := Load("bangumi")
		if acc == nil {
			return nil, bus.NewErr(bus.EAuth, "还没有连接 Bangumi")
		}
		typ := 2 // 默认「看过」
		if v, ok := a["type_"].(float64); ok {
			typ = int(v)
		}
		ok, err := BangumiUpdateEpisode(ctx, acc, int64(num(a, "subject_id")), int64(num(a, "episode_id")), typ)
		if err != nil {
			// ★ 带上原因。`-> bool` 吞掉原因,正是「点格子恒 false」活了几个月的根源。
			return nil, upstream(err)
		}
		return ok, nil
	})

	bus.Register("sync.bangumiSummary", func(ctx context.Context, seq int64, a map[string]any) (any, error) {
		s, err := BangumiSummary(ctx, int64(num(a, "subject_id")))
		if err != nil {
			return nil, upstream(err)
		}
		return s, nil // nil = 这部没有简介,是常态
	})

	bus.Register("sync.bangumiCalendar", func(ctx context.Context, seq int64, a map[string]any) (any, error) {
		onlyMine := boolArg(a, "only_mine")
		// ★ 不登录也能看**全量**放送表 —— 这是产品决定:日历对没连账号的人也有用。
		//   只有「只看我追的」才要求登录。
		var acc *Account
		if onlyMine {
			acc = Load("bangumi")
			if acc == nil {
				return nil, bus.NewErr(bus.EAuth, "「只看我追的」需要先连接 Bangumi")
			}
		}
		return BangumiCalendar(ctx, acc, onlyMine), nil
	})
}

// upstream 上游说了话 → E_UPSTREAM。UI 该原样显示那句,而不是提示「检查网络」。
func upstream(err error) error {
	return &bus.Err{Code: bus.EUpstream, Msg: err.Error(), Retryable: true}
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

func boolArg(a map[string]any, k string) bool {
	v, _ := a[k].(bool)
	return v
}
