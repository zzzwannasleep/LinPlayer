package prefs

// 线路优选反代的开关命令(`prefs.cfProxyEnable` / `cfProxyDisable` / `cfProxyStatus`)。
//
// ★★ **路由改写表与代理句柄必须同步开关**(TODO C28 的判据就是这一条)。
// 两者错开的后果是两种静默故障:
//
//	表在、代理没了  → 请求打到一个已经关掉的本地端口,连不上而且不报错
//	代理在、表没了  → 优选白开:请求照走原线,用户以为生效了
//
// 所以本文件只有一个写入口 bindProxy / unbindProxy,别在别处各写各的。

import (
	"context"
	"sync"

	"linplayer/core/bus"
	"linplayer/core/config"
	"linplayer/core/net/cf"
)

var (
	cfMu sync.Mutex
	// cfProxies 线路地址(归一化前的原样)→ 句柄。
	cfProxies = map[string]*cf.Handle{}
)

// bindProxy 起反代 + 登记改写。**两件事一起做,一起失败。**
func bindProxy(lineURL, ip string, allowInsecure bool) (*cf.Handle, error) {
	scheme, host, port := cf.SplitUpstream(lineURL)
	h, err := cf.Start(scheme, host, port, ip, allowInsecure)
	if err != nil {
		return nil, err
	}
	// ★ 本地基址要**保留上游的路径前缀**:Emby 挂在 /emby 子路径下时,
	//   丢掉它之后所有 API 打到 404 —— 连得上但全 404 的静默故障。
	cf.Bind(lineURL, cf.LocalBase(lineURL, h.Port))
	return h, nil
}

// unbindProxy 撤销改写 + 停服。**先撤表再停服**:反过来的话中间那一瞬
// 表里还指着一个已经关掉的端口。
func unbindProxy(lineURL string) bool {
	cf.Unbind(lineURL)
	h, ok := cfProxies[lineURL]
	if !ok {
		return false
	}
	h.Close()
	delete(cfProxies, lineURL)
	return true
}

// registerCFCommands 由 RegisterCommands 调用。
func registerCFCommands() {
	bus.Register("prefs.cfProxyEnable", func(ctx context.Context, seq int64, a map[string]any) (any, error) {
		line, _ := a["line_url"].(string)
		ip, _ := a["ip"].(string)
		if line == "" || ip == "" {
			return nil, bus.NewErr(bus.EInvalid, "缺少 line_url 或 ip")
		}
		cfMu.Lock()
		defer cfMu.Unlock()

		// 同一条线路已经开着:只换 IP,**端口不变** —— 换端口等于让已登记的改写作废
		if h, ok := cfProxies[line]; ok {
			h.UpdateIP(ip)
			return map[string]any{"line_url": line, "ip": h.PinnedIP(), "local": cf.LocalURLFor(line)}, nil
		}

		// 「允许自签名」跟着这条线路所属的账号走
		allowInsecure := false
		for _, acc := range config.Current().AccountList {
			if acc.Server == line || lineBelongsTo(acc, line) {
				allowInsecure = acc.AllowInsecureTLS
				break
			}
		}
		h, err := bindProxy(line, ip, allowInsecure)
		if err != nil {
			return nil, bus.NewErr(bus.ENetwork, "%v", err)
		}
		cfProxies[line] = h
		bus.Logf("info", "线路优选已开 %s -> 127.0.0.1:%d(钉 %s)", line, h.Port, ip)
		return map[string]any{"line_url": line, "ip": ip, "local": cf.LocalURLFor(line)}, nil
	})

	bus.Register("prefs.cfProxyDisable", func(ctx context.Context, seq int64, a map[string]any) (any, error) {
		line, _ := a["line_url"].(string)
		if line == "" {
			return nil, bus.NewErr(bus.EInvalid, "缺少 line_url")
		}
		cfMu.Lock()
		defer cfMu.Unlock()
		had := unbindProxy(line)
		return map[string]any{"line_url": line, "was_active": had}, nil
	})

	bus.Register("prefs.cfProxyStatus", func(ctx context.Context, seq int64, a map[string]any) (any, error) {
		cfMu.Lock()
		defer cfMu.Unlock()
		out := []map[string]any{}
		for line, h := range cfProxies {
			out = append(out, map[string]any{
				"line_url": line, "ip": h.PinnedIP(), "port": h.Port,
				"local": cf.LocalURLFor(line),
			})
		}
		return out, nil
	})
}

// lineBelongsTo 这条线路属于这个账号吗。
func lineBelongsTo(acc config.Account, lineURL string) bool {
	want := config.NormLineURL(lineURL)
	for _, l := range acc.Lines {
		if config.NormLineURL(l.URL) == want {
			return true
		}
	}
	return false
}
