// Package plugincmd 是 `plugin.*` 命令层 + 插件宿主能力实现。
//
// ★ 为什么不放在 core/plugin 里:那个包被 source/pluginsrc 导入,而这一层要导入
// player / emby / source 去落地 ctx.player / ctx.emby / 源分派表 —— 放一起就是导入环。
package plugincmd

import (
	"context"
	"fmt"
	"sync"
	"sync/atomic"
	"time"

	"linplayer/core/bus"
	"linplayer/core/config"
	"linplayer/core/emby"
	"linplayer/core/source/pluginsrc"
)

// embyClient 插件 apiRequest 用的出网口。版本在 RegisterCommands 时钉进去。
var embyClient = emby.NewClient("0.0.0")

func newEmbyClient(version string) *emby.Client { return emby.NewClient(version) }

// host 把插件的平台能力落到宿主。
type host struct{}

// Log 插件日志统一进事件队列,带插件 id 前缀 —— 不带的话诊断包里分不清是谁写的。
func (host) Log(pluginID, level, msg string) {
	if pluginID == "" {
		bus.Logf(level, "[plugins] %s", msg)
		return
	}
	bus.Logf(level, "[插件 %s] %s", pluginID, msg)
}

// ExtensionsChanged 让前端重新拉一遍贡献点。
func (host) ExtensionsChanged() {
	bus.Emit("plugin.extensionsChanged", map[string]any{}, "plugin.extensionsChanged")
}

// SourcesChanged 重建插件源在分派表里的条目。
func (host) SourcesChanged(pluginID string) {
	pluginsrc.Sync(mgr)
	bus.Emit("plugin.sourcesChanged", map[string]any{"pluginId": pluginID}, "")
}

// Call 平台能力路由。
func (h host) Call(pluginID, channel, method string, args []any) (any, error) {
	switch channel {
	case "ui":
		return uiRequest(pluginID, method, args)
	case "player":
		return playerCall(method, args)
	case "emby":
		return embyCall(method, args)
	}
	return nil, fmt.Errorf("未知的宿主通道: %s", channel)
}

// ---------------------------------------------------------------------------
// ctx.ui —— 请求发给界面,等它回一个值
// ---------------------------------------------------------------------------

// uiWait 一次 ui 请求的等待上限。
//
// ★ 有上限是因为**没上限的那个失败模式最难查**:界面没接这条 method(或者
// 页面被关掉了),插件就永远停在那个 await 上,表现是「点了没反应」,
// 而日志里什么都没有。超时至少给得出一句话。
const uiWait = 5 * time.Minute

var (
	uiSeq     atomic.Int64
	uiMu      sync.Mutex
	uiPending = map[int64]chan any{}
)

func uiRequest(pluginID, method string, args []any) (any, error) {
	id := uiSeq.Add(1)
	ch := make(chan any, 1)
	uiMu.Lock()
	uiPending[id] = ch
	uiMu.Unlock()
	defer func() {
		uiMu.Lock()
		delete(uiPending, id)
		uiMu.Unlock()
	}()

	if args == nil {
		args = []any{}
	}
	bus.Emit("plugin.ui", map[string]any{
		"id": id, "pluginId": pluginID, "method": method, "args": args,
	}, "")

	select {
	case v := <-ch:
		return v, nil
	case <-time.After(uiWait):
		return nil, fmt.Errorf("界面没有响应 ctx.ui.%s(等了 %.0f 分钟)", method, uiWait.Minutes())
	}
}

// uiRespond 前端回填一次 ctx.ui 请求。value=nil 视为取消。
func uiRespond(id int64, value any) {
	uiMu.Lock()
	ch := uiPending[id]
	uiMu.Unlock()
	if ch == nil {
		return
	}
	select {
	case ch <- value:
	default:
	}
}

// ---------------------------------------------------------------------------
// ctx.player / ctx.emby —— 转发到已注册的命令实现
// ---------------------------------------------------------------------------

func argAt(args []any, i int) any {
	if i < len(args) {
		return args[i]
	}
	return nil
}

func numAt(args []any, i int) float64 {
	if f, ok := argAt(args, i).(float64); ok {
		return f
	}
	return 0
}

func playerCall(method string, args []any) (any, error) {
	ctx := context.Background()
	switch method {
	case "getCurrentMedia":
		return bus.Invoke(ctx, "player.status", nil)
	case "getCacheLimitBytes":
		// 预取上限是播放偏好里的一项,直接读偏好而不是另存一份。
		return bus.Invoke(ctx, "player.getPlaybackPrefs", nil)
	case "play":
		return bus.Invoke(ctx, "player.setPause", map[string]any{"paused": false})
	case "pause":
		return bus.Invoke(ctx, "player.setPause", map[string]any{"paused": true})
	case "seek":
		return bus.Invoke(ctx, "player.seek", map[string]any{"pos": numAt(args, 0)})
	}
	return nil, fmt.Errorf("未知的播放器能力: %s", method)
}

func embyCall(method string, args []any) (any, error) {
	acc := config.Current().ActiveAccount()
	if acc == nil || acc.IsFileBrowse() {
		return nil, fmt.Errorf("当前没有已登录的 Emby 服务器")
	}
	switch method {
	case "getServerUrl":
		return acc.ActiveLineURL(), nil
	case "getServerInfo":
		return map[string]any{
			"url": acc.ActiveLineURL(), "name": acc.DisplayName(), "userId": acc.UserID,
		}, nil
	case "getCurrentUser":
		return map[string]any{"id": acc.UserID, "name": acc.UserName}, nil
	case "apiRequest":
		// ★ 以当前登录身份发任意 API 请求 —— 这是 emby.api 那条**危险权限**的全部内容。
		sess := &emby.Session{
			Server: acc.ActiveLineURL(), Token: acc.Token,
			UserID: acc.UserID, DeviceID: config.Current().DeviceID,
		}
		method, _ := argAt(args, 0).(string)
		path, _ := argAt(args, 1).(string)
		return embyClient.RawRequest(context.Background(), sess, method, path, argAt(args, 2))
	}
	return nil, fmt.Errorf("未知的 Emby 能力: %s", method)
}
