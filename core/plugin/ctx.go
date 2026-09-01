package plugin

// 把宿主能力原生绑进插件的全局 `ctx`。
//
// 每个能力就是一个原生绑定;host 路由类(player/ui/emby)全部收敛到一个 hostFn
// (同构:查权限 -> 转发参数给宿主)。http/storage/sleep 在核心层自持;
// log/extensions/生命周期是同步绑定。

import (
	"fmt"
	"sync"
	"time"

	"github.com/dop251/goja"
	"linplayer/core/source"
)

// Host 平台能力缝。
//
// 核心层保持零 UI 依赖,凡是要碰「活的 App 状态」的能力(ui 渲染 / 播放器控制 /
// 当前 Emby 服务器)都经这个接口交给命令层实现。核心层内自持的能力
// (log/http/storage/sleep/extensions 注册)不走这里。权限检查也在核心层完成,
// Host 只管把已授权的调用落到平台。
type Host interface {
	// Call 平台能力调用。channel ∈ {ui, player, emby},method/args 见各 ctx.* 定义。
	Call(pluginID, channel, method string, args []any) (any, error)
	// Log 写日志(始终允许,无需权限)。
	Log(pluginID, level, msg string)
	// ExtensionsChanged 扩展注册表变化 -> 通知前端重新拉取渲染。
	ExtensionsChanged()
	// SourcesChanged 该插件贡献的数据源变化 -> 宿主重建它在源分派表里的条目。
	//
	// 跟 ExtensionsChanged 分开是因为两者代价差着量级:前者只是让前端重拉一次
	// JSON,后者要动会被播放链路读的那张源分派表。
	SourcesChanged(pluginID string)
}

// NoopHost 测试/无宿主环境用:所有平台能力返回 nil。
type NoopHost struct{}

// Call 什么都不做。
func (NoopHost) Call(string, string, string, []any) (any, error) { return nil, nil }

// Log 什么都不做。
func (NoopHost) Log(string, string, string) {}

// ExtensionsChanged 什么都不做。
func (NoopHost) ExtensionsChanged() {}

// SourcesChanged 什么都不做。
func (NoopHost) SourcesChanged(string) {}

// GrantsSlot 每插件一份的 `$sourceServer` 展开表。
//
// **引擎和管理器持同一个指针**,所以用户新配一个源之后不必重启插件引擎,
// 写这里就立刻生效。
type GrantsSlot struct {
	mu     sync.Mutex
	grants []SourceHostGrant
}

// Set 用「用户已为该插件配置的全部源地址」**整体替换**展开表。
//
// ★ 整体替换而不是追加 —— 用户删掉一个源之后,那台机器必须立刻不再可达;
// 追加语义会让已删除的地址一直留着,是个只增不减的越权口子。
func (g *GrantsSlot) Set(baseURLs []string) {
	out := []SourceHostGrant{}
	for _, u := range baseURLs {
		if gr, ok := GrantFromBaseURL(u); ok {
			out = append(out, gr)
		}
	}
	g.mu.Lock()
	g.grants = out
	g.mu.Unlock()
}

// Snapshot 取一份副本。
func (g *GrantsSlot) Snapshot() []SourceHostGrant {
	g.mu.Lock()
	defer g.mu.Unlock()
	return append([]SourceHostGrant(nil), g.grants...)
}

// ctxState 每插件一份的共享状态。
type ctxState struct {
	pluginID     string
	permissions  Granted
	allowedHosts []string
	grants       *GrantsSlot
	storage      *Storage
	host         Host
	registry     *Registry
	engine       *Engine

	mu sync.Mutex
	// 三张回调表存的是**当初那个 JS 值**,不是 goja.Callable ——
	// Callable 包回 JS 会把第一个实参吃成 this(见 engine.applyJS 的注释)。
	handlers   map[string]goja.Value
	events     map[string][]goja.Value
	lifecycle  map[string]goja.Value
	handlerSeq int
}

// requirePerm 权限门。有权限返回 nil。
func (s *ctxState) requirePerm(permissionID string) error {
	if s.permissions.Has(permissionID) {
		return nil
	}
	return fmt.Errorf("%s", PermissionError(s.pluginID, permissionID))
}

func (s *ctxState) nextHandlerID() string {
	s.mu.Lock()
	defer s.mu.Unlock()
	s.handlerSeq++
	return fmt.Sprintf("h%d", s.handlerSeq-1)
}

// throw 在 VM 线程上抛一个 JS 异常。
func throw(vm *goja.Runtime, msg string) {
	panic(vm.NewGoError(fmt.Errorf("%s", msg)))
}

// asyncFn 把一个「在别的 goroutine 上跑」的宿主活儿包成返回 Promise 的 JS 函数。
//
// ★★ **活儿必须离开 VM goroutine**。就地做完再 resolve 会把网络等待压在
// VM 那条线上 —— 一个插件在等 HTTP,同引擎里的其它回调全部排队。
func (e *Engine) asyncFn(work func(args []any) (any, error)) func(goja.FunctionCall) goja.Value {
	return func(call goja.FunctionCall) goja.Value {
		p, resolve, reject := e.vm.NewPromise()
		args := make([]any, 0, len(call.Arguments))
		for _, a := range call.Arguments {
			args = append(args, exportJSON(e.vm, a, nil))
		}
		go func() {
			v, err := work(args)
			e.post(func() {
				// 宿主交互结束,把看门狗死线推后 —— 否则一次合法的慢请求
				// 会让紧接着的 JS 一进来就被判失控。
				e.bumpDeadline()
				if err != nil {
					reject(e.vm.NewGoError(err))
					return
				}
				resolve(e.vm.ToValue(v))
			})
		}()
		return e.vm.ToValue(p)
	}
}

// hostFn host 路由绑定:查权限 -> 把原始参数转发给宿主。player/ui/emby 共用。
func (e *Engine) hostFn(perm, channel, method string) func(goja.FunctionCall) goja.Value {
	st := e.state
	return e.asyncFn(func(args []any) (any, error) {
		if perm != "" {
			if err := st.requirePerm(perm); err != nil {
				return nil, err
			}
		}
		e.bumpDeadline()
		return st.host.Call(st.pluginID, channel, method, args)
	})
}

func argStr(args []any, i int) string {
	if i < len(args) {
		if s, ok := args[i].(string); ok {
			return s
		}
	}
	return ""
}

// installCtx 装配全局 ctx。只在 VM goroutine 上调用。
func installCtx(e *Engine, meta map[string]any) error {
	vm := e.vm
	st := e.state
	c := vm.NewObject()

	// ---- ctx.log(始终可用)----
	logObj := vm.NewObject()
	for _, level := range []string{"info", "warn", "error"} {
		lv := level
		if err := logObj.Set(lv, func(call goja.FunctionCall) goja.Value {
			st.host.Log(st.pluginID, lv, call.Argument(0).String())
			return goja.Undefined()
		}); err != nil {
			return err
		}
	}
	if err := c.Set("log", logObj); err != nil {
		return err
	}

	// ---- ctx.http(仅 HTTPS + 白名单)----
	httpObj := vm.NewObject()
	for _, m := range []string{"get", "post", "delete"} {
		method := m
		if err := httpObj.Set(method, e.asyncFn(func(args []any) (any, error) {
			return st.httpRequest(method, args)
		})); err != nil {
			return err
		}
	}
	if err := c.Set("http", httpObj); err != nil {
		return err
	}

	// ---- ctx.storage ----
	storageObj := vm.NewObject()
	storageBinds := map[string]func(args []any) (any, error){
		"get": func(args []any) (any, error) {
			if err := st.requirePerm("storage"); err != nil {
				return nil, err
			}
			return st.storage.Get(argStr(args, 0)), nil
		},
		"set": func(args []any) (any, error) {
			if err := st.requirePerm("storage"); err != nil {
				return nil, err
			}
			var val any
			if len(args) > 1 {
				val = args[1]
			}
			return nil, st.storage.Set(argStr(args, 0), val)
		},
		"delete": func(args []any) (any, error) {
			if err := st.requirePerm("storage"); err != nil {
				return nil, err
			}
			return nil, st.storage.Delete(argStr(args, 0))
		},
		"keys": func([]any) (any, error) {
			if err := st.requirePerm("storage"); err != nil {
				return nil, err
			}
			return st.storage.Keys(), nil
		},
		"clear": func([]any) (any, error) {
			if err := st.requirePerm("storage"); err != nil {
				return nil, err
			}
			return nil, st.storage.Clear()
		},
	}
	for name, fn := range storageBinds {
		if err := storageObj.Set(name, e.asyncFn(fn)); err != nil {
			return err
		}
	}
	if err := c.Set("storage", storageObj); err != nil {
		return err
	}

	// ---- ctx.player ----
	playerObj := vm.NewObject()
	for method, perm := range map[string]string{
		"getCurrentMedia":    "player.read",
		"getCacheLimitBytes": "player.read",
		"play":               "player.control",
		"pause":              "player.control",
		"seek":               "player.control",
	} {
		if err := playerObj.Set(method, e.hostFn(perm, "player", method)); err != nil {
			return err
		}
	}
	// on(event, fn):需 player.read;存下来供宿主派发事件时回调。
	if err := playerObj.Set("on", func(call goja.FunctionCall) goja.Value {
		if err := st.requirePerm("player.read"); err != nil {
			throw(vm, err.Error())
		}
		if _, ok := goja.AssertFunction(call.Argument(1)); !ok {
			throw(vm, "ctx.player.on 的第二个参数必须是函数")
		}
		event := call.Argument(0).String()
		st.mu.Lock()
		st.events[event] = append(st.events[event], call.Argument(1))
		st.mu.Unlock()
		return goja.Undefined()
	}); err != nil {
		return err
	}
	// off(event):ponytail: 按事件整体清空(不做函数身份匹配)。插件极少用 off,
	//            要精确移除时改存 (id, fn) 并按 id 摘除。
	if err := playerObj.Set("off", func(call goja.FunctionCall) goja.Value {
		st.mu.Lock()
		delete(st.events, call.Argument(0).String())
		st.mu.Unlock()
		return goja.Undefined()
	}); err != nil {
		return err
	}
	if err := c.Set("player", playerObj); err != nil {
		return err
	}

	// ---- ctx.ui(全部需 ui)----
	// render 是声明式 UI 入口:插件交一棵 JSON 描述树,宿主用自己的原生控件渲染
	// (桌面/手机/TV 各一套,TV 的遥控器焦点因此白拿)。其余几个是它的糖。
	uiObj := vm.NewObject()
	for _, m := range []string{
		"render",
		"showToast", "showDialog", "showForm", "showList", "openPage",
		"showProgress", "updateProgress", "closeProgress",
	} {
		if err := uiObj.Set(m, e.hostFn("ui", "ui", m)); err != nil {
			return err
		}
	}
	if err := c.Set("ui", uiObj); err != nil {
		return err
	}

	// ---- ctx.emby ----
	// v2 删除 getCredentials:宿主不再持久化明文密码。插件要账密请自己弹表单
	// 存进自己的 storage(每插件隔离)。见 Removed。
	embyObj := vm.NewObject()
	for method, perm := range map[string]string{
		"getServerUrl":   "emby.read",
		"getServerInfo":  "emby.read",
		"getCurrentUser": "emby.read",
		"apiRequest":     "emby.api",
	} {
		if err := embyObj.Set(method, e.hostFn(perm, "emby", method)); err != nil {
			return err
		}
	}
	if err := c.Set("emby", embyObj); err != nil {
		return err
	}

	// ---- ctx.extensions:动态贡献 panels / actions / sandboxViews ----
	// 权限**按贡献点类型各自校验**,不是一个笼统的 "extensions" 通行证 ——
	// 否则拿到 extensions 就能顺手注册数据源和沙箱视图,而用户在授权弹窗里
	// 只看到「扩展界面」。
	extObj := vm.NewObject()
	if err := extObj.Set("register", func(call goja.FunctionCall) goja.Value {
		kindStr := call.Argument(0).String()
		kind, ok := KindFromID(kindStr)
		if !ok {
			throw(vm, "未知贡献点类型: "+kindStr)
		}
		// 只查 kind 自己要的那一条 —— 和 manifest 静态校验**同一把尺子**。
		// 多查一条 "extensions" 会让「manifest 过了、运行时被拒」成为可能。
		if err := st.requirePerm(kind.RequiredPermission()); err != nil {
			throw(vm, err.Error())
		}
		id, registered := registerContribution(e, kind, call.Argument(1))
		return vm.ToValue(map[string]any{"id": id, "registered": registered})
	}); err != nil {
		return err
	}
	if err := extObj.Set("unregister", func(call goja.FunctionCall) goja.Value {
		if err := st.requirePerm("extensions"); err != nil {
			throw(vm, err.Error())
		}
		kind, ok := KindFromID(call.Argument(0).String())
		if !ok {
			throw(vm, "未知贡献点类型: "+call.Argument(0).String())
		}
		st.registry.Unregister(st.pluginID, kind, call.Argument(1).String())
		st.host.ExtensionsChanged()
		return goja.Undefined()
	}); err != nil {
		return err
	}
	if err := c.Set("extensions", extObj); err != nil {
		return err
	}

	// ---- ctx.sources:插件即数据源 ----
	// 三个函数就是一个完整数据源。宿主把它接进 source.Backend,于是浏览页 /
	// 搜索 / 播放 / 外挂字幕 / 多清晰度 / 跨服聚合全部白拿 —— 零新页面零新命令。
	//
	//   ctx.sources.register("mysrc", { listDir, search, resolvePlay })
	srcObj := vm.NewObject()
	if err := srcObj.Set("register", func(call goja.FunctionCall) goja.Value {
		if err := st.requirePerm("sources"); err != nil {
			throw(vm, err.Error())
		}
		srcID := call.Argument(0).String()
		if srcID == "" || srcID == "undefined" {
			throw(vm, "数据源 id 不能为空")
		}
		handlers, ok := call.Argument(1).(*goja.Object)
		if !ok {
			throw(vm, "第二个参数必须是含 listDir/search/resolvePlay 的对象")
		}
		// 把 id 拍进描述对象,后面统一走 registerContribution 取 id。
		if err := handlers.Set("id", srcID); err != nil {
			throw(vm, err.Error())
		}
		id, registered := registerContribution(e, KindDataSources, handlers)
		st.host.SourcesChanged(st.pluginID)
		return vm.ToValue(map[string]any{"id": id, "registered": registered})
	}); err != nil {
		return err
	}
	if err := srcObj.Set("unregister", func(call goja.FunctionCall) goja.Value {
		if err := st.requirePerm("sources"); err != nil {
			throw(vm, err.Error())
		}
		st.registry.Unregister(st.pluginID, KindDataSources, call.Argument(0).String())
		st.host.SourcesChanged(st.pluginID)
		st.host.ExtensionsChanged()
		return goja.Undefined()
	}); err != nil {
		return err
	}
	if err := c.Set("sources", srcObj); err != nil {
		return err
	}

	// ---- ctx.util:纯函数小工具,无需权限 ----
	// isVideoName 直接复用宿主那份扩展名表 —— 插件各自维护一份必然漂移,
	// 而漂移的后果是「某种格式在内置源能播、在插件源里根本不显示」。
	utilObj := vm.NewObject()
	if err := utilObj.Set("isVideoName", func(call goja.FunctionCall) goja.Value {
		return vm.ToValue(source.IsVideoFileName(call.Argument(0).String()))
	}); err != nil {
		return err
	}
	if err := c.Set("util", utilObj); err != nil {
		return err
	}

	// ---- ctx.errors:让插件表达「不支持」而不是「失败」 ----
	errObj := vm.NewObject()
	if err := errObj.Set("unsupported", func(call goja.FunctionCall) goja.Value {
		extra := ""
		if len(call.Arguments) > 0 {
			extra = call.Argument(0).String()
		}
		throw(vm, UnsupportedMarker+extra)
		return goja.Undefined()
	}); err != nil {
		return err
	}
	if err := c.Set("errors", errObj); err != nil {
		return err
	}

	// ---- ctx.sleep(无需权限,封顶 10s)----
	if err := c.Set("sleep", e.asyncFn(func(args []any) (any, error) {
		ms := 0.0
		if len(args) > 0 {
			if f, ok := args[0].(float64); ok {
				ms = f
			}
		}
		if ms < 0 {
			ms = 0
		}
		if ms > 10_000 {
			ms = 10_000
		}
		time.Sleep(time.Duration(ms) * time.Millisecond)
		return nil, nil
	})); err != nil {
		return err
	}

	// ---- ctx.plugin / 生命周期 ----
	if err := c.Set("plugin", meta); err != nil {
		return err
	}
	for _, name := range []string{"onEnable", "onDisable"} {
		hook := name
		if err := c.Set(hook, func(call goja.FunctionCall) goja.Value {
			if _, ok := goja.AssertFunction(call.Argument(0)); !ok {
				throw(vm, "ctx."+hook+" 的参数必须是函数")
			}
			st.mu.Lock()
			st.lifecycle[hook] = call.Argument(0)
			st.mu.Unlock()
			return goja.Undefined()
		}); err != nil {
			return err
		}
	}

	return vm.GlobalObject().Set("ctx", c)
}

// typeNameOf 给报错用的人话类型名。
func typeNameOf(v any) string {
	switch v.(type) {
	case nil:
		return "null"
	case bool:
		return "布尔值"
	case float64:
		return "数字"
	case string:
		return "字符串"
	case []any:
		return "数组"
	case map[string]any:
		return "对象"
	}
	return "未知类型"
}

// registerContribution 抽出描述对象里的函数存进 handler 表、原位换成
// `{__handler__:id}`,然后注册成贡献点。返回 (贡献id, 是否新增)。
//
// `ctx.extensions.register` 和 `ctx.sources.register` 共用。
func registerContribution(e *Engine, kind Kind, descriptor goja.Value) (string, bool) {
	vm, st := e.vm, e.state
	pending := map[string]goja.Value{}
	data := exportJSON(vm, descriptor, func(f goja.Value) string {
		id := st.nextHandlerID()
		pending[id] = f
		return id
	})

	/* ★ 描述必须是**对象**,而且必须有 id。
	   挡的是这一类真实错误:`ctx.extensions.register('panels', 'stats', {…})`
	   —— 多写了一个参数(它的签名是 (kind, 描述),而隔壁 ctx.sources.register 是
	   (源id, 描述),两个形状不一样,写混很自然)。descriptor 收到的是字符串
	   'stats',老代码照单全收:data 存成一个裸字符串、id 编一个 ext_7,
	   注册**成功**返回。表现是插件已启用、面板出现在 slot 列表里、
	   render 调用却永远返回 null —— 一路无声。现在当场抛。 */
	obj, ok := data.(map[string]any)
	if !ok {
		throw(vm, fmt.Sprintf(
			"%s.register 的描述必须是一个对象;收到的是 %s —— "+
				"参数写多了?ctx.extensions.register(类型, 描述) / ctx.sources.register(源id, 描述)",
			kind, typeNameOf(data)))
	}
	cid, _ := obj["id"].(string)
	if cid == "" {
		throw(vm, fmt.Sprintf("%s.register 的描述必须带一个非空的 id 字段", kind))
	}

	st.mu.Lock()
	for id, f := range pending {
		st.handlers[id] = f
	}
	st.mu.Unlock()

	registered := st.registry.Register(Contribution{
		PluginID: st.pluginID, Kind: kind, ID: cid, Data: obj, FromManifest: false,
	})
	st.host.ExtensionsChanged()
	return cid, registered
}
