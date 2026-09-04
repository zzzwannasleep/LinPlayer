// Package plugin 是插件系统(SPEC §7)。JS 插件跑在 goja 里,宿主能力经 ctx 原生绑进去。
//
// **Rust 版是黄金实现。**
// 与 Rust 版的唯一实现差异:JS 引擎从 rquickjs(QuickJS)换成 goja(纯 Go)。
// 换的理由是交叉编译 —— quickjs-go 要 cgo + 每平台一份预编译静态库,
// 而本项目要出 Windows / Linux / Android(arm64+arm) 四个目标。
// 语义面已实测对齐:async/await、宿主返回真 Promise、中断(看门狗)三样都在。
// goja 没有内存上限,所以 MAX_ENABLED 那道「限数即限内存」的闸只剩「限数」。
package plugin

// 权限模型。声明制:插件在 manifest.permissions 里声明,用户启用前必须同意;
// 运行时每次 ctx.* 调用做检查,未授权 -> JS 异常。`log` 隐式授予、无需声明。

// Permission 单个权限定义。
type Permission struct {
	ID          string `json:"id"`
	Title       string `json:"title"`
	Description string `json:"description"`
	// Dangerous 涉及网络/隐私的权限,UI 上需强调。
	Dangerous bool `json:"dangerous"`
}

// All 全部内置可申请权限。**顺序即 UI 展示顺序。**
var All = []Permission{
	{ID: "player.read", Title: "读取播放状态", Dangerous: false,
		Description: "获取当前播放的媒体信息、播放进度,并监听播放事件(如播放结束)。"},
	{ID: "player.control", Title: "控制播放器", Dangerous: true,
		Description: "可以播放、暂停、跳转当前视频。"},
	{ID: "http", Title: "网络访问", Dangerous: true,
		Description: "通过 HTTPS 访问外部网络(受域名白名单限制)。"},
	{ID: "storage", Title: "本地存储", Dangerous: false,
		Description: "在本地保存插件自己的数据(每个插件独立,上限 5MB)。"},
	{ID: "ui", Title: "界面交互", Dangerous: false,
		Description: "弹出提示、对话框,或打开插件页面。"},
	{ID: "emby.read", Title: "读取 Emby 信息", Dangerous: false,
		Description: "读取当前登录用户和服务器地址。"},
	{ID: "emby.api", Title: "调用 Emby 接口", Dangerous: true,
		Description: "以当前登录身份向 Emby 服务器发起任意 API 请求。"},
	{ID: "sources", Title: "提供数据源", Dangerous: true,
		Description: "向应用注册可浏览、搜索、播放的媒体源,出现在你的服务器列表里。"},
	{ID: "extensions", Title: "扩展界面", Dangerous: false,
		Description: "向应用注册侧边栏入口、操作按钮、设置页等界面模块。"},
	{ID: "sandbox", Title: "自定义界面", Dangerous: true,
		Description: "在隔离沙箱里渲染插件自带的网页界面(拿不到应用本身的任何接口)。"},
	{ID: "log", Title: "写日志", Dangerous: false,
		Description: "输出调试日志(始终允许)。"},
}

// Removed v1 有、v2 已删除的权限。
//
// ★ **单独列出来是为了给用户一句人话**,而不是让老插件撞上「未知权限: cfproxy」
// 这种看起来像 App 出了 bug 的报错。
var Removed = [][2]string{
	{"emby.credentials", "宿主不再保存登录密码;请改为在插件自己的设置页里让用户填写"},
	{"cfproxy", "CF 优选反代已改为应用内置功能,不再经由插件"},
}

// RemovedReason 这个权限是不是 v2 里被删掉的。是的话返回给用户看的原因。
func RemovedReason(id string) string {
	for _, r := range Removed {
		if r[0] == id {
			return r[1]
		}
	}
	return ""
}

// ImplicitlyGranted 始终授予、无需声明的权限。
var ImplicitlyGranted = []string{"log"}

// IsKnownPermission 是不是已知权限。
func IsKnownPermission(id string) bool {
	for _, p := range All {
		if p.ID == id {
			return true
		}
	}
	return false
}

// Granted 一组已授予权限。
type Granted struct{ ids map[string]bool }

// NewGranted 造一组已授权集合(自动补上隐式授予的)。
func NewGranted(ids []string) Granted {
	set := map[string]bool{}
	for _, id := range ids {
		set[id] = true
	}
	for _, g := range ImplicitlyGranted {
		set[g] = true
	}
	return Granted{ids: set}
}

// Has 有没有这个权限。
func (g Granted) Has(id string) bool { return g.ids[id] }

// PermissionError 权限被拒 -> 变成插件内 JS 异常的错误文案。
func PermissionError(pluginID, permissionID string) string {
	return "插件 " + pluginID + " 缺少权限「" + permissionID + "」"
}
