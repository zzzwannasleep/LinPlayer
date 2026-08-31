package emby

// 本包自己注册 `emby.*`。命令归属跟着实现走(理由见 core/player/commands.go)。

import (
	"context"
	"encoding/json"

	"linplayer/core/blocklist"
	"linplayer/core/bus"
)

var defaultClient *Client

// RegisterCommands 由 lp_init 调用。
func RegisterCommands(version string) {
	defaultClient = NewClient(version)

	// list 把「取会话 → 调实现 → 网络错误归到可重试」这段样板收成一处。
	// 网络错误是**可重试**的 —— UI 据此显示「重试」而不是「重新登录」(SPEC §5.4)
	list := func(name string, fn func(context.Context, *Session, map[string]any) (any, error)) {
		bus.Register(name, func(ctx context.Context, seq int64, args map[string]any) (any, error) {
			s, err := sessionFrom(args)
			if err != nil {
				return nil, err
			}
			out, err := fn(ctx, s, args)
			if err != nil {
				return nil, &bus.Err{Code: bus.ENetwork, Msg: err.Error(), Retryable: true}
			}
			return out, nil
		})
	}

	list("emby.views", func(ctx context.Context, s *Session, a map[string]any) (any, error) {
		return defaultClient.Views(ctx, s)
	})
	list("emby.listLatest", func(ctx context.Context, s *Session, a map[string]any) (any, error) {
		return defaultClient.Latest(ctx, s, str(a, "parent_id"), intArg(a, "limit", 16))
	})
	list("emby.listResume", func(ctx context.Context, s *Session, a map[string]any) (any, error) {
		return defaultClient.Resume(ctx, s, intArg(a, "limit", 12))
	})
	list("emby.listNextUp", func(ctx context.Context, s *Session, a map[string]any) (any, error) {
		return defaultClient.NextUp(ctx, s, intArg(a, "limit", 12))
	})
	list("emby.listFavorites", func(ctx context.Context, s *Session, a map[string]any) (any, error) {
		return defaultClient.Favorites(ctx, s)
	})
	list("emby.listCollections", func(ctx context.Context, s *Session, a map[string]any) (any, error) {
		return defaultClient.Collections(ctx, s)
	})
	list("emby.listItemsPage", func(ctx context.Context, s *Session, a map[string]any) (any, error) {
		q := &ItemQuery{}
		if raw, ok := a["query"]; ok {
			b, _ := json.Marshal(raw)
			_ = json.Unmarshal(b, q)
		}
		return defaultClient.Items(ctx, s, str(a, "parent_id"), q)
	})

	// ---- 详情页那条链 ----
	list("emby.itemDetail", func(ctx context.Context, s *Session, a map[string]any) (any, error) {
		id := str(a, "item_id")
		if id == "" {
			return nil, bus.NewErr(bus.EInvalid, "缺少 item_id")
		}
		// ★ 桌面/TV 传 true(一屏铺完所有集),**手机端传 false**(按季分页拉)。
		//   实测最长的剧全量拉 1.8MB/1841ms,分页 30 条 20KB/435ms。
		wc, _ := a["with_children"].(bool)
		return defaultClient.Detail(ctx, s, id, wc)
	})
	list("emby.seriesSeasons", func(ctx context.Context, s *Session, a map[string]any) (any, error) {
		return defaultClient.Seasons(ctx, s, str(a, "series_id"))
	})
	list("emby.seasonEpisodes", func(ctx context.Context, s *Session, a map[string]any) (any, error) {
		return defaultClient.SeasonEpisodes(ctx, s, str(a, "parent_id"),
			intArg(a, "start_index", 0), intArg(a, "limit", 30))
	})

	// ★ counts 单列不走 list():这个端点在某些 fork 上是 404,
	//   调用方**必须容忍它失败** —— 统计条是锦上添花,不该让首页整个报错。
	//   所以它的错误码是 E_UNSUPPORTED(信息,UI 静默降级)而不是 E_NETWORK(红字 + 重试)。
	bus.Register("emby.counts", func(ctx context.Context, seq int64, args map[string]any) (any, error) {
		s, err := sessionFrom(args)
		if err != nil {
			return nil, err
		}
		c, err := defaultClient.CountsOf(ctx, s)
		if err != nil {
			return nil, bus.NewErr(bus.EUnsupported, "这台服务器没有 /Items/Counts", err.Error())
		}
		return c, nil
	})

	// ---- 屏蔽名单 ----
	bus.Register("emby.blockedList", func(ctx context.Context, seq int64, args map[string]any) (any, error) {
		return blocklist.List(), nil
	})
	bus.Register("emby.setBlocked", func(ctx context.Context, seq int64, args map[string]any) (any, error) {
		id := str(args, "id")
		if id == "" {
			return nil, bus.NewErr(bus.EInvalid, "缺少 id")
		}
		on, _ := args["blocked"].(bool)
		// ★ id 和名字**都要存**:分集靠 series_id 认,跨服的同一部剧 id 不同、只有名字对得上
		blocklist.Set(id, str(args, "name"), on)
		return map[string]any{"id": id, "blocked": on}, nil
	})
}

func str(a map[string]any, k string) string {
	v, _ := a[k].(string)
	return v
}

func intArg(a map[string]any, k string, def int) int {
	if v, ok := a[k].(float64); ok {
		return int(v)
	}
	return def
}

// sessionFrom 从命令参数里取会话。
//
// ponytail: 迁移期先由调用方显式传。等 core/config 把 accounts 接进来之后,
// 改成「传 account 下标,会话由核心层自己组装」—— 那才是 §5.6 命令表里的形状。
func sessionFrom(args map[string]any) (*Session, error) {
	get := func(k string) string {
		v, _ := args[k].(string)
		return v
	}
	s := &Session{
		Server:   get("server"),
		Token:    get("token"),
		UserID:   get("user_id"),
		DeviceID: get("device_id"),
	}
	if s.Server == "" || s.UserID == "" {
		return nil, bus.NewErr(bus.EInvalid, "缺少 server 或 user_id")
	}
	return s, nil
}
