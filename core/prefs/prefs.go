// Package prefs 是 `prefs.*` 命令:设置页读写偏好。
//
// ★★ 这一层和 core/config 的分工必须分清,搞反了会出真故障:
//
//	core/config 的 Clamped()  —— **读**的时候钳。老配置里存着离谱值时,
//	                              设置页照样打得开(不然用户连界面都进不去)
//	本包的 setter              —— **写**的时候**拒**。悄悄钳的话,用户设了 8 线程、
//	                              实际生效 4 线程,毫无反馈
//
// Rust 版就是这么分的(`get_prefetch_settings` 钳、`set_prefetch_settings` 拒),
// 移植时别「统一成一种」。
package prefs

import (
	"context"

	"linplayer/core/bus"
	"linplayer/core/config"
)

// RegisterCommands 由 lp_init 调用。version 是发行版本号(更新设置要用)。
func RegisterCommands(version string) {
	registerCFCommands()
	registerIconLibrary()
	registerTransferCommands()
	registerSpeedTest()
	registerProxyCommands()

	// ---- 选轨偏好 ----
	bus.Register("prefs.getPrefs", func(ctx context.Context, seq int64, a map[string]any) (any, error) {
		return config.Current().PrefsOf(), nil
	})

	// ★ **只改选轨三项,别整体覆盖** —— 整体覆盖会把 cross_server_resume 之类的
	//   悄悄重置成默认值(用户改个字幕语言,跨服续播就被关了)。
	bus.Register("prefs.setPrefs", func(ctx context.Context, seq int64, a map[string]any) (any, error) {
		c := config.Current()
		p := c.PrefsOf()
		p.AudioLang = strPtr(a, "audio_lang")
		p.SubLang = strPtr(a, "sub_lang")
		if v, ok := a["sub_enabled"].(bool); ok {
			p.SubEnabled = v
		}
		if v, ok := a["danmaku_enabled"].(bool); ok {
			p.DanmakuEnabled = v
		}
		return p, save(c, p)
	})

	// ---- 多线程加载 ----
	bus.Register("prefs.getPrefetchSettings", func(ctx context.Context, seq int64, a map[string]any) (any, error) {
		p := config.Current().PrefsOf() // PrefsOf 已经钳过
		return map[string]any{
			"servers": p.PrefetchServers, "threads": p.PrefetchThreads,
			"cache_bytes": p.PrefetchCacheBytes,
		}, nil
	})
	bus.Register("prefs.setPrefetchSettings", func(ctx context.Context, seq int64, a map[string]any) (any, error) {
		s := sub(a, "settings")
		c := config.Current()
		p := c.PrefsOf()

		// ★ 引擎内部会 clamp(2,4),但**在这儿拒掉才有反馈** ——
		//   悄悄 clamp 会让用户以为设了 8 线程生效了。
		threads := intArg(s, "threads", p.PrefetchThreads)
		if threads < 2 || threads > 4 {
			return nil, bus.NewErr(bus.EInvalid, "预取线程数只支持 2~4,实得 %d", threads)
		}
		// ★ 上下限都得拒:上限静默夹紧的话,用户设 8GB 实际只生效 4GB,毫无反馈。
		cache := int64Arg(s, "cache_bytes", p.PrefetchCacheBytes)
		if cache < config.PrefetchCacheMin || cache > config.PrefetchCacheMax {
			return nil, bus.NewErr(bus.EInvalid,
				"缓存上限只支持 64MB~4GB(落盘环形缓存,决定磁盘占用),实得 %d 字节", cache)
		}

		// ★ 只留**真实存在**的账号:服务器删了它的 id 还赖在表里的话,
		//   下次加同地址的服会「自己就开着」。
		known := map[string]bool{}
		for _, acc := range c.AccountList {
			known[acc.Server] = true
		}
		kept := []string{}
		for _, srv := range strList(s, "servers") {
			if known[srv] {
				kept = append(kept, srv)
			}
		}
		p.PrefetchServers = kept
		p.PrefetchThreads = threads
		p.PrefetchCacheBytes = cache
		return p, save(c, p)
	})

	// ---- 首页栏目(按服务器)----
	//
	// ★★ 粒度是**服务器**,不是全局:一台服有几百个合集、另一台一个都没有,
	//   用户 2026-09-03 明确要「可以按照不同服去定制」。
	// ★ 作用的服务器是**当前登录的那台**,不让调用方传 —— 传一个不存在的
	//   服务器键会静默写进表里,而用户在界面上永远看不到那一条(第 7 次
	//   「设了没反应」都是这么来的)。
	bus.Register("prefs.getHomeSettings", func(ctx context.Context, seq int64, a map[string]any) (any, error) {
		c := config.Current()
		p := c.PrefsOf()
		srv := ""
		if acc := c.ActiveAccount(); acc != nil {
			srv = acc.Server
		}
		/* ★★ **把每一台服务器都列出来**,不只是当前这台。
		   用户 2026-09-03 要的是「可以按照不同服去定制」—— 只给当前那台的话,
		   他在 A 服关掉、到 B 服看见还在,只能靠一台台切过去才知道自己设了什么。
		   一个「按 X 定制」的开关,必须有一处能看到全部 X 的状态。 */
		servers := []map[string]any{}
		for _, acc := range c.AccountList {
			servers = append(servers, map[string]any{
				"server":  acc.Server,
				"name":    acc.DisplayName(),
				"enabled": p.CollectionsEnabledFor(acc.Server),
				"active":  acc.Server == srv,
			})
		}
		return map[string]any{
			// ★ 连 server 一起回:UI 得能说清「这个开关管的是哪台服」。
			"server":              srv,
			"collections_enabled": srv == "" || p.CollectionsEnabledFor(srv),
			"servers":             servers,
		}, nil
	})
	bus.Register("prefs.setHomeSettings", func(ctx context.Context, seq int64, a map[string]any) (any, error) {
		c := config.Current()
		acc := c.ActiveAccount()
		if acc == nil {
			return nil, bus.NewErr(bus.EInvalid, "还没有登录的服务器,这个开关没有作用对象")
		}
		p := c.PrefsOf()
		st := sub(a, "settings")
		on, ok := st["collections_enabled"].(bool)
		if !ok {
			return nil, bus.NewErr(bus.EInvalid, "缺少 collections_enabled")
		}
		/* ★ 可以指定改**哪一台**(设置页那张多服列表用),不给就是当前登录那台。
		   ★★ 但必须是**已知账号**:传一个不存在的服务器键会静默写进表里,
		     而用户在界面上永远看不到那一条 —— 一个设了没反应的开关。 */
		target := acc.Server
		if v, _ := st["server"].(string); v != "" {
			target = v
		}
		/* ★ 表里记的是**关掉的那几台**(黑名单)。重建时顺手把已经删掉的账号剔出去 ——
		   留着的话,下次加一台同地址的服会「自己就是关着的」,而用户完全不知道为什么。 */
		known := map[string]bool{}
		for _, x := range c.AccountList {
			known[x.Server] = true
		}
		if !known[target] {
			return nil, bus.NewErr(bus.EInvalid, "没有这台服务器: %s", target)
		}
		kept := []string{}
		for _, srv := range p.HideCollectionServers {
			if known[srv] && srv != target {
				kept = append(kept, srv)
			}
		}
		if !on {
			kept = append(kept, target)
		}
		p.HideCollectionServers = kept
		return p, save(c, p)
	})

	// ---- 预加载 ----
	bus.Register("prefs.getPreloadSettings", func(ctx context.Context, seq int64, a map[string]any) (any, error) {
		p := config.Current().PrefsOf()
		return map[string]any{"enabled": p.PreloadEnabled, "head_mb": p.PreloadHeadMB}, nil
	})
	bus.Register("prefs.setPreloadSettings", func(ctx context.Context, seq int64, a map[string]any) (any, error) {
		s := sub(a, "settings")
		c := config.Current()
		p := c.PrefsOf()
		head := int64Arg(s, "head_mb", p.PreloadHeadMB)
		if head < 0 || head > config.PreloadHeadMBMax {
			return nil, bus.NewErr(bus.EInvalid,
				"预热头部量只支持 0~%d MB(再大就不是预热是下载了),实得 %d", config.PreloadHeadMBMax, head)
		}
		if v, ok := s["enabled"].(bool); ok {
			p.PreloadEnabled = v
		}
		p.PreloadHeadMB = head
		return p, save(c, p)
	})

	// ---- 跨服回传 ----
	bus.Register("prefs.getWritebackSettings", func(ctx context.Context, seq int64, a map[string]any) (any, error) {
		p := config.Current().PrefsOf()
		return map[string]any{
			"enabled": p.CrossServerWriteback, "range": p.CrossServerWritebackRange,
			"include_progress": p.CrossServerWritebackProgress,
		}, nil
	})
	bus.Register("prefs.setWritebackSettings", func(ctx context.Context, seq int64, a map[string]any) (any, error) {
		s := sub(a, "settings")
		c := config.Current()
		p := c.PrefsOf()
		// ★ 读的时候对无法识别的值静默回落 "all";**写的时候要拒** ——
		//   静默回落会让用户以为选了「仅初次」,其实在往所有服上写。
		if r, ok := s["range"].(string); ok {
			switch r {
			case "all", "first", "latest":
				p.CrossServerWritebackRange = r
			default:
				return nil, bus.NewErr(bus.EInvalid, "未知的回传范围: %s", r)
			}
		}
		if v, ok := s["enabled"].(bool); ok {
			p.CrossServerWriteback = v
		}
		if v, ok := s["include_progress"].(bool); ok {
			p.CrossServerWritebackProgress = v
		}
		return p, save(c, p)
	})

	// ---- 更新 ----
	bus.Register("prefs.getUpdateSettings", func(ctx context.Context, seq int64, a map[string]any) (any, error) {
		p := config.Current().PrefsOf()
		return map[string]any{
			"channel": p.UpdateChannel, "auto_check": p.UpdateAutoCheck,
			// ★ 比较用**发行版本号**,不是编译期的包版本 —— 后者和发行包版本没有同步机制。
			"current_version": version,
			// ponytail: can_self_update 要等 paths.RootKind() 落地(绿色包被解压到
			// 只写不了的地方时为 false)。**先问再做** —— 覆盖到一半才发现没权限,
			// 用户手上就是个装不上也回不去的半吊子。在那之前保守报 false。
			"can_self_update": false,
		}, nil
	})
	bus.Register("prefs.setUpdateSettings", func(ctx context.Context, seq int64, a map[string]any) (any, error) {
		c := config.Current()
		p := c.PrefsOf()
		if ch, ok := a["channel"].(string); ok {
			if ch != "stable" && ch != "prerelease" {
				return nil, bus.NewErr(bus.EInvalid, "未知的更新渠道: %s", ch)
			}
			p.UpdateChannel = ch
		}
		if v, ok := a["auto_check"].(bool); ok {
			p.UpdateAutoCheck = v
		}
		return p, save(c, p)
	})

	// ---- 观感 ----
	bus.Register("prefs.setDetailBlur", func(ctx context.Context, seq int64, a map[string]any) (any, error) {
		c := config.Current()
		p := c.PrefsOf()
		v := intArg(a, "value", -1)
		if v < 0 || v > 100 {
			return nil, bus.NewErr(bus.EInvalid, "模糊强度只支持 0~100,实得 %d", v)
		}
		p.DetailBlur = v
		return p, save(c, p)
	})
}

// save 写回并落盘。**每条 setter 都走这里** —— 漏了 Save 的表现是「改完看着对了,
// 重启回到改之前」,而这类漏是逐条发生的。
func save(c *config.AppConfig, p config.Prefs) error {
	if err := c.SetPrefs(p); err != nil {
		return bus.NewErr(bus.EInternal, "偏好序列化失败: %v", err)
	}
	if err := c.Save(); err != nil {
		return bus.NewErr(bus.EInternal, "配置保存失败: %v", err)
	}
	return nil
}

// sub 取嵌套的 settings 对象。三端有的传 {settings:{…}},有的把字段摊平传 ——
// 两种都收,少一种就是「某个端上设置页点了没反应」。
func sub(a map[string]any, key string) map[string]any {
	if m, ok := a[key].(map[string]any); ok {
		return m
	}
	return a
}

func strPtr(a map[string]any, k string) *string {
	v, ok := a[k].(string)
	if !ok || v == "" {
		return nil // 空串 = 不限定语言,和「没传」是同一件事
	}
	return &v
}

func strList(a map[string]any, k string) []string {
	raw, _ := a[k].([]any)
	out := []string{}
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

func int64Arg(a map[string]any, k string, def int64) int64 {
	if v, ok := a[k].(float64); ok {
		return int64(v)
	}
	return def
}
