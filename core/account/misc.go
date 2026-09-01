package account

// 账号相关的几条零散命令:跨服续播开关、并发探活。

import (
	"context"
	"sync"

	"linplayer/core/bus"
	"linplayer/core/config"
	"linplayer/core/httpx"
)

func registerMiscCommands() {
	// ---- 跨服续播开关 ----
	//
	// ★ 它存在 prefs 里(不是账号里):这是**全局**行为,不是某台服务器的属性。
	bus.Register("account.getCrossServerResume", func(ctx context.Context, seq int64, a map[string]any) (any, error) {
		return config.Current().PrefsOf().CrossServerResume, nil
	})

	bus.Register("account.setCrossServerResume", func(ctx context.Context, seq int64, a map[string]any) (any, error) {
		enabled, ok := a["enabled"].(bool)
		if !ok {
			return nil, bus.NewErr(bus.EInvalid, "缺少 enabled")
		}
		c := config.Current()
		p := c.PrefsOf()
		p.CrossServerResume = enabled
		/* ★ **只改这一项**,不整体覆盖 prefs —— 整体覆盖会把用户改过的选轨语言、
		   预取设置之类一起重置成默认值(「改个开关,别的设置全没了」)。 */
		if err := c.SetPrefs(p); err != nil {
			return nil, bus.NewErr(bus.EInternal, "偏好写回失败: %v", err)
		}
		if err := c.Save(); err != nil {
			return nil, bus.NewErr(bus.EInternal, "配置保存失败: %v", err)
		}
		return nil, nil
	})

	// ---- 并发探活 ----
	//
	// ★★ 探的是 **ActiveLineURL 而不是 Server**:用户切了备用线路,
	// 正是因为主线不通 —— 探主线只会把一台能用的服务器标成红的。
	bus.Register("account.probeAccounts", func(ctx context.Context, seq int64, a map[string]any) (any, error) {
		c := config.Current()
		type result struct {
			Server string `json:"server"`
			OK     bool   `json:"ok"`
			MS     int64  `json:"ms,omitempty"`
			Error  string `json:"error,omitempty"`
		}
		out := make([]result, len(c.AccountList))
		var wg sync.WaitGroup
		for i := range c.AccountList {
			acc := c.AccountList[i]
			wg.Add(1)
			go func(i int) {
				defer wg.Done()
				r := result{Server: acc.Server}
				// 浏览型源没有 /System/Info/Public,探不了,一律当可用
				if acc.IsFileBrowse() {
					r.OK = true
					out[i] = r
					return
				}
				if ms := probeOne(ctx, httpx.Client(), acc.ActiveLineURL()); ms != nil {
					r.OK = true
					r.MS = *ms
				} else {
					r.Error = "连不上(或返回了非 2xx)"
				}
				out[i] = r
			}(i)
		}
		wg.Wait()
		return out, nil
	})
}
