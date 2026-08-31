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
		v, err := defaultClient.Views(ctx, s)
		if err != nil {
			return nil, err
		}
		/* 屏蔽掉的媒体库不出现在**列表里**(首页的媒体库轨、各库「最新」行、侧栏)。
		   ★ 缺省过滤,`include_blocked=true` 才给全量 —— 只有媒体库页那份列表要全量:
		     它是唯一能把库找回来解除屏蔽的地方,滤掉就成了单向门。
		   ★ 这里**不走**条目那条屏蔽判定(它按 series_id / 名字比):
		     库没有 series_id,而「名字对得上」在库上是错的判据 —— 两台服务器上都叫
		     「电影」的库是两个不同的库,按名字判会一屏两台一起屏蔽。 */
		inc, _ := a["include_blocked"].(bool)
		return FilterBlockedLibraries(v, inc), nil
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

	list("emby.listItems", func(ctx context.Context, s *Session, a map[string]any) (any, error) {
		// ★ 保持返回**数组**而不是 {items,total}:要总数/翻页/筛选走 listItemsPage。
		//   这两条的返回形状不同是故意的,前端各有各的调用点。
		p, err := defaultClient.Items(ctx, s, str(a, "parent_id"), &ItemQuery{})
		if err != nil {
			return nil, err
		}
		return p.Items, nil
	})
	list("emby.listRandom", func(ctx context.Context, s *Session, a map[string]any) (any, error) {
		return defaultClient.RandomPicks(ctx, s, intArg(a, "limit", 8))
	})
	list("emby.getFilters", func(ctx context.Context, s *Session, a map[string]any) (any, error) {
		return defaultClient.FiltersOf(ctx, s, str(a, "parent_id"))
	})
	list("emby.itemMedia", func(ctx context.Context, s *Session, a map[string]any) (any, error) {
		// ★ version_regex 只用来标 preferred,不影响返回哪些版本。
		//   ponytail: 迁移期由调用方传;接进 core/config 之后从设置里读。
		return defaultClient.MediaVersions(ctx, s, str(a, "item_id"), str(a, "version_regex"))
	})

	// ---- 搜索 / 相似 / 演职员 ----
	list("emby.search", func(ctx context.Context, s *Session, a map[string]any) (any, error) {
		// ★ types 缺省 = 全要(不是一个都不要);「包括集」开关关着时前端显式传 Movie,Series
		return defaultClient.Search(ctx, s, str(a, "query"), strList(a, "types"),
			intArg(a, "limit", 50), str(a, "parent_id"))
	})
	list("emby.similarItems", func(ctx context.Context, s *Session, a map[string]any) (any, error) {
		return defaultClient.Similar(ctx, s, str(a, "item_id"), intArg(a, "limit", 12))
	})
	list("emby.personDetail", func(ctx context.Context, s *Session, a map[string]any) (any, error) {
		return defaultClient.Person(ctx, s, str(a, "person_id"))
	})
	list("emby.personItems", func(ctx context.Context, s *Session, a map[string]any) (any, error) {
		return defaultClient.PersonItems(ctx, s, str(a, "person_id"), intArg(a, "limit", 60))
	})

	// ---- 收藏 / 已看 ----
	// ★ 返回体带上刚设成什么:前端拿它对账自己的乐观更新,而不是各自记一份状态
	list("emby.setFavorite", func(ctx context.Context, s *Session, a map[string]any) (any, error) {
		fav, _ := a["fav"].(bool)
		if err := defaultClient.SetFavorite(ctx, s, str(a, "item_id"), fav); err != nil {
			return nil, err
		}
		return map[string]any{"item_id": str(a, "item_id"), "fav": fav}, nil
	})
	list("emby.setPlayed", func(ctx context.Context, s *Session, a map[string]any) (any, error) {
		played, _ := a["played"].(bool)
		if err := defaultClient.SetPlayed(ctx, s, str(a, "item_id"), played); err != nil {
			return nil, err
		}
		return map[string]any{"item_id": str(a, "item_id"), "played": played}, nil
	})

	// ---- 管理员动作 ----
	list("emby.isAdmin", func(ctx context.Context, s *Session, a map[string]any) (any, error) {
		return defaultClient.IsAdmin(ctx, s)
	})
	list("emby.refreshItem", func(ctx context.Context, s *Session, a map[string]any) (any, error) {
		full, _ := a["full"].(bool)
		return nil, defaultClient.RefreshItem(ctx, s, str(a, "item_id"), full)
	})
	list("emby.scanLibraries", func(ctx context.Context, s *Session, a map[string]any) (any, error) {
		return nil, defaultClient.ScanAllLibraries(ctx, s)
	})

	// ★ login 单列:它**没有会话**(会话就是它产出的),走不了 list() 的取会话那步。
	//   密码只在这一处出现,**不进日志、不进事件、不进错误串** —— 错误只说 HTTP 码。
	bus.Register("emby.login", func(ctx context.Context, seq int64, args map[string]any) (any, error) {
		server, user := str(args, "server"), str(args, "username")
		if server == "" || user == "" {
			return nil, bus.NewErr(bus.EInvalid, "缺少 server 或 username")
		}
		dev := str(args, "device_id")
		if dev == "" {
			// 设备 ID 必须**持久**:每次换一个会把服务器的设备列表刷满,续播会话也对不上。
			// ponytail: 迁移期先由调用方传;接进 core/config 之后改成核心层自己存一个。
			return nil, bus.NewErr(bus.EInvalid, "缺少 device_id")
		}
		_, res, err := defaultClient.Login(ctx, server, user, str(args, "password"), dev)
		if err != nil {
			return nil, &bus.Err{Code: bus.ENetwork, Msg: err.Error(), Retryable: true}
		}
		return res, nil
	})

	// ★ logout **尽力而为**:实测某 fork 该端点 404 且 token 登出后仍可用,
	//   所以它的失败**不能**挡住本地删账号 —— 这里永远返回成功,只把结果写进返回体。
	list("emby.logout", func(ctx context.Context, s *Session, a map[string]any) (any, error) {
		err := defaultClient.Logout(ctx, s)
		return map[string]any{"server_ok": err == nil}, nil
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

// strList 取一个字符串数组参数。**空 / 缺省一律返回 nil** ——
// 下游把 nil 当「没点名 = 全要」,把空数组当同一件事,别在这里造出区别。
func strList(a map[string]any, k string) []string {
	raw, _ := a[k].([]any)
	var out []string
	for _, v := range raw {
		if s, ok := v.(string); ok {
			out = append(out, s)
		}
	}
	return out
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
