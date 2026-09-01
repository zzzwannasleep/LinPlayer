package plugin

// 贡献点(contributions)—— 插件把能力「挂载」到宿主的预定义位置。
//
// 4 类 × slot(抄 VS Code contribution points)。以后加新位置只加 slot 常量,不加类型。

import "sync"

// Kind 贡献点类型。
type Kind string

// 四类贡献点。**这些字面量是写在用户 manifest 里的,也是前端查询用的键 ——
// 改一个字母,所有已发布插件的那一类贡献静默消失(不报错,只是不出现)。**
const (
	KindDataSources  Kind = "dataSources"
	KindPanels       Kind = "panels"
	KindActions      Kind = "actions"
	KindSandboxViews Kind = "sandboxViews"
)

// AllKinds 四类贡献点,顺序固定。
var AllKinds = []Kind{KindDataSources, KindPanels, KindActions, KindSandboxViews}

// KindFromID 认一个贡献点类型名。v1 的 8 个老扩展点名一律不认 ——
// 认了会让 v1 插件半死不活地跑起来。
func KindFromID(id string) (Kind, bool) {
	for _, k := range AllKinds {
		if string(k) == id {
			return k, true
		}
	}
	return "", false
}

// RequiredPermission 贡献这一类需要的权限。
//
// ★★ **没有这个权限,连 manifest 里静态声明都不许** —— 否则用户在授权弹窗里
// 看不到、却被悄悄挂上了东西。
//
// panels/actions 要的是 `extensions`(权限表原话:「向应用注册侧边栏入口、
// 操作按钮、设置页等界面模块」)而**不是** `ui`(那条管的是 ctx.ui.*)。
// 黄金实现第一版写成 `ui`,而 ctx.extensions.register 那边查的是这里返回的权限,
// 两边规则对不上:只声明了 `ui` 的插件能过静态校验、却在运行时注册面板时被拒,
// 而拒的异常发生在 onEnable 里被吞掉 —— 表现为**插件显示已启用、面板却永远是空的**。
func (k Kind) RequiredPermission() string {
	switch k {
	case KindDataSources:
		return "sources"
	case KindPanels, KindActions:
		return "extensions"
	case KindSandboxViews:
		return "sandbox"
	}
	return ""
}

// PanelSlots panels 的挂载位置。加新位置只往这里加一条,不动类型系统。
var PanelSlots = []string{
	"home.stats",     // 首页统计区
	"sidebar",        // 侧栏入口
	"settings",       // 插件自己的设置页
	"player.overlay", // 播放器叠加层
	"page",           // 独立整页
}

// ActionContexts actions 的出现上下文。
var ActionContexts = []string{"global", "item", "player"}

func inList(list []string, v string) bool {
	for _, s := range list {
		if s == v {
			return true
		}
	}
	return false
}

// Contribution 一条已注册贡献。
//
// Data 里的 handler 已被引擎替换成 `{"__handler__": id}` 标记(真正的 JS 函数
// 在引擎的 handler 表里)。
type Contribution struct {
	PluginID     string         `json:"pluginId"`
	Kind         Kind           `json:"kind"`
	ID           string         `json:"id"`
	Data         map[string]any `json:"data"`
	FromManifest bool           `json:"fromManifest"`
}

// Slot panels 的挂载位置(非 panels 或未声明则为空)。
func (c *Contribution) Slot() string {
	s, _ := c.Data["slot"].(string)
	return s
}

// Registry 全局贡献点注册表(所有插件共享一份)。
type Registry struct {
	mu    sync.Mutex
	items []Contribution
}

// NewRegistry 建一张空注册表。
func NewRegistry() *Registry { return &Registry{} }

// Register 注册/覆盖(同 plugin+kind+id 视为同一条)。返回是否为新增。
//
// ★★ **运行时注册撞上 manifest 静态声明时要合并,不能整条顶掉。**
// manifest 里写的是**描述性**字段(数据源的 name / auth 表单、面板的 title / slot),
// 运行时 `ctx.sources.register('demo', {…})` 交的是**行为**字段(三个回调),
// 两边天然只各写一半。黄金实现第一版直接整条替换,于是插件一注册回调,
// manifest 里的 name 和 auth 就没了 —— 「添加服务器」页拿到一个**没有任何输入框**
// 的插件源,名字还退化成源 id。2026-07-23 真机端到端跑出来的,单测和编译都看不见。
func (r *Registry) Register(c Contribution) bool {
	r.mu.Lock()
	defer r.mu.Unlock()
	for i := range r.items {
		e := &r.items[i]
		if e.PluginID != c.PluginID || e.Kind != c.Kind || e.ID != c.ID {
			continue
		}
		if e.FromManifest && !c.FromManifest {
			if c.Data == nil {
				c.Data = map[string]any{}
			}
			// 新的赢同名键,老的填空缺。
			for k, v := range e.Data {
				if _, has := c.Data[k]; !has {
					c.Data[k] = v
				}
			}
		}
		*e = c
		return false
	}
	r.items = append(r.items, c)
	return true
}

// Unregister 摘掉一条。
func (r *Registry) Unregister(pluginID string, kind Kind, id string) {
	r.mu.Lock()
	defer r.mu.Unlock()
	out := r.items[:0]
	for _, e := range r.items {
		if e.PluginID == pluginID && e.Kind == kind && e.ID == id {
			continue
		}
		out = append(out, e)
	}
	r.items = out
}

// RemoveAllForPlugin 摘掉某插件的全部贡献。
func (r *Registry) RemoveAllForPlugin(pluginID string) {
	r.mu.Lock()
	defer r.mu.Unlock()
	out := r.items[:0]
	for _, e := range r.items {
		if e.PluginID != pluginID {
			out = append(out, e)
		}
	}
	r.items = out
}

// ByKind 取某类贡献的全部条目。
func (r *Registry) ByKind(kind Kind) []Contribution {
	r.mu.Lock()
	defer r.mu.Unlock()
	out := []Contribution{}
	for _, e := range r.items {
		if e.Kind == kind {
			out = append(out, e)
		}
	}
	return out
}

// PanelsInSlot 取挂在某个 slot 的全部 panels。
//
// 首页/侧栏/播放器叠加层各自只关心自己那一撮,让前端拉全量再过滤等于
// 每个位置都要重复一遍 slot 常量。
func (r *Registry) PanelsInSlot(slot string) []Contribution {
	r.mu.Lock()
	defer r.mu.Unlock()
	out := []Contribution{}
	for _, e := range r.items {
		if e.Kind == KindPanels && e.Slot() == slot {
			out = append(out, e)
		}
	}
	return out
}

// Find 精确找一条。
func (r *Registry) Find(pluginID string, kind Kind, id string) (Contribution, bool) {
	r.mu.Lock()
	defer r.mu.Unlock()
	for _, e := range r.items {
		if e.PluginID == pluginID && e.Kind == kind && e.ID == id {
			return e, true
		}
	}
	return Contribution{}, false
}

// HandlerRef 「怎么调这个 handler」。
type HandlerRef struct {
	// Dynamic 动态注册的函数 id(按 id 调引擎 handler 表)。
	Dynamic string
	// Named manifest 声明的全局具名函数。
	Named string
}

// None 这个位置压根没有 handler。
func (h HandlerRef) None() bool { return h.Dynamic == "" && h.Named == "" }

// HandlerRefOf 从 handler 描述值里取出调用方式。
func HandlerRefOf(v any) HandlerRef {
	switch t := v.(type) {
	case map[string]any:
		if id, ok := t["__handler__"].(string); ok && id != "" {
			return HandlerRef{Dynamic: id}
		}
	case string:
		if t != "" {
			return HandlerRef{Named: t}
		}
	}
	return HandlerRef{}
}
