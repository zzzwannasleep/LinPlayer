package plugincmd

// `plugin.*` 命令层 —— 22 条。

import (
	"context"
	"fmt"

	"linplayer/core/bus"
	"linplayer/core/config"
	"linplayer/core/plugin"
	"linplayer/core/source"
	"linplayer/core/source/pluginsrc"
)

// mgr 全局唯一的插件管理器。
//
// ★ 单例而不是随用随建:引擎、启用态、贡献点注册表都挂在它上面,
// 建两个就是两份真相 —— 表现是「装了插件但另一处看不到」。
var mgr *plugin.Manager

// Manager 给别的模块拿管理器(播放事件派发等)。init 之前是 nil。
func Manager() *plugin.Manager { return mgr }

// RegisterCommands 由 core/commands 调用。
func RegisterCommands(version string) {
	embyClient = newEmbyClient(version)
	mgr = plugin.NewManager(host{})

	bus.Register("plugin.list", cmdList)
	bus.Register("plugin.install", cmdInstall)
	bus.Register("plugin.enable", cmdEnable)
	bus.Register("plugin.disable", cmdDisable)
	bus.Register("plugin.uninstall", cmdUninstall)
	bus.Register("plugin.reload", cmdReload)
	bus.Register("plugin.devPoll", cmdDevPoll)
	bus.Register("plugin.trigger", cmdTrigger)
	bus.Register("plugin.invokeField", cmdInvokeField)
	bus.Register("plugin.extensions", cmdExtensions)
	bus.Register("plugin.panels", cmdPanels)
	bus.Register("plugin.sources", cmdSources)
	bus.Register("plugin.uiRespond", cmdUIRespond)
	bus.Register("plugin.permissionCatalog", cmdPermissionCatalog)
	bus.Register("plugin.pickInstall", cmdPickInstall)
	bus.Register("plugin.pickDevDir", cmdPickDevDir)

	// 市场七条。
	bus.Register("plugin.marketSources", cmdMarketSources)
	bus.Register("plugin.marketAddSource", cmdMarketAddSource)
	bus.Register("plugin.marketRemoveSource", cmdMarketRemoveSource)
	bus.Register("plugin.marketToggleSource", cmdMarketToggleSource)
	bus.Register("plugin.marketList", cmdMarketList)
	bus.Register("plugin.marketInstall", cmdMarketInstall)
}

// Init 扫描并激活已启用的插件。由 lp_init 在配置就绪之后调用。
//
// ★ 和 RegisterCommands 分开:注册命令必须在 init 最早期完成(命令表是契约),
// 而激活插件要读配置、要出网,得等数据根定下来。合成一个的后果是插件在
// paths 还没定的时候就去读 plugins 目录 —— 读的是空目录,表现为「升级后插件全没了」。
func Init() {
	if mgr == nil {
		return
	}
	mgr.Init()
	syncGrants()
	pluginsrc.Sync(mgr)
}

// syncGrants 把用户已配置的插件源地址灌进各插件的 `$sourceServer` 展开表。
//
// ★ 必须在启用之后做一次全量:引擎起来时展开表是空的,不灌的话
// 插件第一次请求自己那台服务器会被白名单拒掉,而报错文案是
// 「域名不在白名单内」—— 用户完全看不出是「还没同步」。
func syncGrants() {
	byPlugin := map[string][]string{}
	for _, acc := range config.Current().AccountList {
		k := source.Kind(acc.SourceKind())
		pid, _, ok := source.SplitPlugin(k)
		if !ok {
			continue
		}
		if u := acc.ActiveLineURL(); u != "" {
			byPlugin[pid] = append(byPlugin[pid], u)
		}
	}
	for _, t := range mgr.DataSources() {
		pid := t[0]
		mgr.SetSourceGrants(pid, byPlugin[pid])
	}
}

// SyncSourceGrants 供账号变更后重新灌一遍(增删源都要调)。
func SyncSourceGrants() {
	if mgr == nil {
		return
	}
	syncGrants()
}

func str(a map[string]any, k string) string {
	if v, ok := a[k].(string); ok {
		return v
	}
	return ""
}

func requireMgr() error {
	if mgr == nil {
		return bus.NewErr(bus.EInternal, "插件系统未初始化")
	}
	return nil
}

// ---------------------------------------------------------------------------
// 已装插件
// ---------------------------------------------------------------------------

func cmdList(ctx context.Context, seq int64, a map[string]any) (any, error) {
	if err := requireMgr(); err != nil {
		return nil, err
	}
	return mgr.List(), nil
}

func cmdInstall(ctx context.Context, seq int64, a map[string]any) (any, error) {
	if err := requireMgr(); err != nil {
		return nil, err
	}
	path := str(a, "path")
	if path == "" {
		return nil, bus.NewErr(bus.EInvalid, "缺少 path")
	}
	out, err := mgr.InstallIPK(path)
	if err != nil {
		return nil, bus.NewErr(bus.EInvalid, "%v", err)
	}
	return out, nil
}

func cmdEnable(ctx context.Context, seq int64, a map[string]any) (any, error) {
	if err := requireMgr(); err != nil {
		return nil, err
	}
	if err := mgr.Enable(str(a, "id")); err != nil {
		return nil, bus.NewErr(bus.EInvalid, "%v", err)
	}
	pluginsrc.Sync(mgr)
	syncGrants()
	return map[string]any{"ok": true}, nil
}

func cmdDisable(ctx context.Context, seq int64, a map[string]any) (any, error) {
	if err := requireMgr(); err != nil {
		return nil, err
	}
	mgr.Disable(str(a, "id"))
	pluginsrc.Sync(mgr)
	return map[string]any{"ok": true}, nil
}

func cmdUninstall(ctx context.Context, seq int64, a map[string]any) (any, error) {
	if err := requireMgr(); err != nil {
		return nil, err
	}
	mgr.Uninstall(str(a, "id"))
	pluginsrc.Sync(mgr)
	return map[string]any{"ok": true}, nil
}

func cmdReload(ctx context.Context, seq int64, a map[string]any) (any, error) {
	if err := requireMgr(); err != nil {
		return nil, err
	}
	if err := mgr.Reload(str(a, "id")); err != nil {
		return nil, bus.NewErr(bus.EInvalid, "%v", err)
	}
	pluginsrc.Sync(mgr)
	return map[string]any{"ok": true}, nil
}

// cmdDevPoll 轮询开发模式插件的入口文件是否变了,变了的自动重载,返回被重载的 id。
func cmdDevPoll(ctx context.Context, seq int64, a map[string]any) (any, error) {
	if err := requireMgr(); err != nil {
		return nil, err
	}
	changed := mgr.DevPluginsChanged()
	for _, id := range changed {
		_ = mgr.Reload(id)
	}
	if len(changed) > 0 {
		pluginsrc.Sync(mgr)
	}
	return changed, nil
}

// ---------------------------------------------------------------------------
// 贡献点
// ---------------------------------------------------------------------------

func argsList(a map[string]any) []any {
	switch v := a["args"].(type) {
	case []any:
		return v
	case nil:
		return []any{}
	default:
		// 单个值也收下:插件作者写 args: {…} 比写 args: [{…}] 自然,
		// 而两种写法的差别在 JS 那边表现为「第一个形参变成了整个对象」。
		return []any{v}
	}
}

func cmdTrigger(ctx context.Context, seq int64, a map[string]any) (any, error) {
	if err := requireMgr(); err != nil {
		return nil, err
	}
	out, err := mgr.TriggerExtension(str(a, "plugin_id"), str(a, "type_id"), str(a, "ext_id"), argsList(a))
	if err != nil {
		return nil, bus.NewErr(bus.EUpstream, "%v", err)
	}
	return out, nil
}

func cmdInvokeField(ctx context.Context, seq int64, a map[string]any) (any, error) {
	if err := requireMgr(); err != nil {
		return nil, err
	}
	out, err := mgr.InvokeExtensionField(str(a, "plugin_id"), str(a, "type_id"),
		str(a, "ext_id"), str(a, "field"), argsList(a))
	if err != nil {
		return nil, bus.NewErr(bus.EUpstream, "%v", err)
	}
	return out, nil
}

func cmdExtensions(ctx context.Context, seq int64, a map[string]any) (any, error) {
	if err := requireMgr(); err != nil {
		return nil, err
	}
	return mgr.ExtensionsByType(str(a, "type_id")), nil
}

func cmdPanels(ctx context.Context, seq int64, a map[string]any) (any, error) {
	if err := requireMgr(); err != nil {
		return nil, err
	}
	return mgr.PanelsInSlot(str(a, "slot")), nil
}

// cmdSources 当前所有已启用插件贡献的数据源。「添加服务器」页据此列出可选的插件源。
func cmdSources(ctx context.Context, seq int64, a map[string]any) (any, error) {
	if err := requireMgr(); err != nil {
		return nil, err
	}
	// ★ 把 manifest 里声明的 auth 表单字段一并带上 —— 前端要靠它渲染通用登录表单,
	//   否则每接一个插件源都得改前端。
	decls := mgr.ExtensionsByType(string(plugin.KindDataSources))
	out := []map[string]any{}
	for _, t := range mgr.DataSources() {
		pid, sid, name := t[0], t[1], t[2]
		var auth any
		for _, d := range decls {
			if d.PluginID == pid && d.ID == sid {
				auth = d.Data["auth"]
			}
		}
		item := map[string]any{
			"kind": string(source.PluginKind(pid, sid)), "pluginId": pid,
			"sourceId": sid, "name": name, "auth": auth,
		}
		// 白名单里含 $sourceServer 的源要提示用户「它会访问你填的这台服务器」。
		if m := mgr.ManifestOf(pid); m != nil {
			item["wantsSourceServer"] = m.WantsSourceServerHost()
		}
		out = append(out, item)
	}
	return out, nil
}

func cmdUIRespond(ctx context.Context, seq int64, a map[string]any) (any, error) {
	var id int64
	switch v := a["id"].(type) {
	case float64:
		id = int64(v)
	case int64:
		id = v
	}
	if id == 0 {
		return nil, bus.NewErr(bus.EInvalid, "缺少 id")
	}
	uiRespond(id, a["value"])
	return map[string]any{"ok": true}, nil
}

// cmdPermissionCatalog 权限的人话说明。
//
// ★★ **必须由核心层透出,不能在界面里抄一份** —— 抄一份的后果是加了新权限
// 而界面不知道,授权弹窗里显示成一个光秃秃的 `sources` 字符串,
// 用户根本看不懂自己同意了什么。
func cmdPermissionCatalog(ctx context.Context, seq int64, a map[string]any) (any, error) {
	return plugin.All, nil
}

// ---------------------------------------------------------------------------
// 文件选择器两条
//
// ★ 文件选择器**属于 UI 层**:核心层是个 DLL,弹不了系统对话框
// (和 system.pickFile 一个口径)。宿主自己弹,拿到路径后用 path 参数传进来 ——
// 命令仍然在契约里,只是「不给路径就做不了」。
// ---------------------------------------------------------------------------

func cmdPickInstall(ctx context.Context, seq int64, a map[string]any) (any, error) {
	if err := requireMgr(); err != nil {
		return nil, err
	}
	path := str(a, "path")
	if path == "" {
		return nil, bus.NewErr(bus.EUnsupported,
			"plugin.pickInstall 由宿主弹选择器:核心层是个库,弹不了系统对话框。选中 .ipk 后用 path 传进来")
	}
	out, err := mgr.InstallIPK(path)
	if err != nil {
		return nil, bus.NewErr(bus.EInvalid, "%v", err)
	}
	return out, nil
}

func cmdPickDevDir(ctx context.Context, seq int64, a map[string]any) (any, error) {
	if err := requireMgr(); err != nil {
		return nil, err
	}
	path := str(a, "path")
	if path == "" {
		return nil, bus.NewErr(bus.EUnsupported,
			"plugin.pickDevDir 由宿主弹选择器:核心层是个库,弹不了系统对话框。选中目录后用 path 传进来")
	}
	out, err := mgr.InstallDevDir(path)
	if err != nil {
		return nil, bus.NewErr(bus.EInvalid, "%v", err)
	}
	return out, nil
}

// ---------------------------------------------------------------------------
// 市场
// ---------------------------------------------------------------------------

func cmdMarketSources(ctx context.Context, seq int64, a map[string]any) (any, error) {
	return plugin.AllSources(), nil
}

func cmdMarketAddSource(ctx context.Context, seq int64, a map[string]any) (any, error) {
	out, err := plugin.AddSource(str(a, "name"), str(a, "url"))
	if err != nil {
		return nil, bus.NewErr(bus.EInvalid, "%v", err)
	}
	return out, nil
}

func cmdMarketRemoveSource(ctx context.Context, seq int64, a map[string]any) (any, error) {
	out, err := plugin.RemoveSource(str(a, "id"))
	if err != nil {
		return nil, bus.NewErr(bus.EInvalid, "%v", err)
	}
	return out, nil
}

func cmdMarketToggleSource(ctx context.Context, seq int64, a map[string]any) (any, error) {
	enabled, _ := a["enabled"].(bool)
	out, err := plugin.ToggleSource(str(a, "id"), enabled)
	if err != nil {
		return nil, bus.NewErr(bus.EInvalid, "%v", err)
	}
	return out, nil
}

func cmdMarketList(ctx context.Context, seq int64, a map[string]any) (any, error) {
	refresh, _ := a["refresh"].(bool)
	out, err := plugin.MarketList(ctx, refresh)
	if err != nil {
		return nil, bus.NewErr(bus.ENetwork, "%v", err)
	}
	return out, nil
}

func cmdMarketInstall(ctx context.Context, seq int64, a map[string]any) (any, error) {
	if err := requireMgr(); err != nil {
		return nil, err
	}
	out, err := plugin.MarketInstall(ctx, mgr, str(a, "id"), str(a, "version"))
	if err != nil {
		return nil, bus.NewErr(bus.ENetwork, "%v", err)
	}
	return out, nil
}

var _ = fmt.Sprintf
