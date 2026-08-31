package prefs

// 代理设置的两条命令。

import (
	"context"
	"encoding/json"

	"linplayer/core/bus"
	"linplayer/core/config"
	"linplayer/core/httpx"
)

func registerProxyCommands() {
	bus.Register("prefs.getProxy", func(ctx context.Context, seq int64, a map[string]any) (any, error) {
		return config.Current().ProxyConf(), nil
	})

	// ★★ 保存**必须立刻生效**,不能等重启。
	//
	// Rust 侧那句注释写着「主 Emby 客户端下次重启完全生效」—— 那是当时的将就。
	// Go 这边 httpx 的三个客户端是**带缓存的**,SetProxy 会把三个一起作废,
	// 所以这里改完就是真改完了。漏掉这一步的表现是:用户在设置页切代理、
	// 点了保存、界面显示成功、**行为一点没变** —— 只会以为代理功能坏了。
	bus.Register("prefs.setProxy", func(ctx context.Context, seq int64, a map[string]any) (any, error) {
		raw, ok := a["config"]
		if !ok {
			return nil, bus.NewErr(bus.EInvalid, "缺少 config")
		}
		b, err := json.Marshal(raw)
		if err != nil {
			return nil, bus.NewErr(bus.EInvalid, "config 解析失败: %v", err)
		}
		p := config.ParseProxy(b)

		// ★ 启用了却缺 host/port,要**拒绝**不要静默存下 ——
		//   存下的话 ProxyURL() 返回空串,行为等同于「没开代理」,
		//   而设置页显示的是「已启用」。
		if p.Type != "" && p.Type != "none" && !p.Enabled() {
			return nil, bus.NewErr(bus.EInvalid, "启用代理必须同时给出 host 和 port")
		}

		c := config.Current()
		c.SetProxyConf(p)
		if err := c.Save(); err != nil {
			return nil, bus.NewErr(bus.EInternal, "配置保存失败: %v", err)
		}
		httpx.SetProxy(p.ProxyURL()) // 立刻生效:三个客户端一起作废
		return nil, nil
	})
}
