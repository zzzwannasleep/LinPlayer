package plugin

// 插件管理器:扫描/安装/启用/禁用/卸载/触发扩展/派发事件。
// 引擎执行委托给各插件自己的 Engine;本层只管元数据、启用态持久化、贡献点编排。

import (
	"fmt"
	"os"
	"path/filepath"
	"sort"
	"sync"

	"linplayer/core/paths"
)

// MaxEnabled 同时启用插件数上限。
//
// ★ 黄金实现里这条的理由是「每引擎 ~64MB,限数即限内存」。goja 没有内存上限,
// 所以在 Go 版它只是**限数**;真要限内存得换引擎或加进程隔离。
const MaxEnabled = 16

// Status 插件状态。
type Status string

// 三种状态。
const (
	StatusDisabled Status = "disabled"
	StatusEnabled  Status = "enabled"
	StatusError    Status = "error"
)

type record struct {
	manifest  *Manifest
	dir       string
	entryPath string
	status    Status
	errMsg    string
	// dev 开发模式:直接挂本地目录,不复制文件,改完存盘即重载。
	dev bool
	// entryMtime 入口文件 mtime(毫秒),开发模式热重载靠它判变化。
	entryMtime int64
}

// mtimeOf 入口文件的修改时间(毫秒)。取不到就 0 —— 取不到时一律不判「变了」,
// 免得每轮都无脑重载。
func mtimeOf(path string) int64 {
	st, err := os.Stat(path)
	if err != nil {
		return 0
	}
	return st.ModTime().UnixMilli()
}

// Manager 插件管理器。
type Manager struct {
	pluginsRoot string
	dataRoot    string
	stateFile   string
	registry    *Registry
	host        Host

	mu       sync.Mutex
	records  map[string]*record
	enabled  map[string]bool
	approved map[string]map[string]bool
	engines  map[string]*Engine
	grants   map[string]*GrantsSlot
}

// NewManager 用数据根下的标准目录建管理器(生产路径)。
func NewManager(host Host) *Manager {
	return NewManagerAt(paths.PluginsDir(), paths.PluginStorage(), paths.PluginStateFile(), host)
}

// NewManagerAt 显式给三个位置(测试用)。host = 平台能力实现。
func NewManagerAt(pluginsRoot, dataRoot, stateFile string, host Host) *Manager {
	m := &Manager{
		pluginsRoot: pluginsRoot,
		dataRoot:    dataRoot,
		stateFile:   stateFile,
		registry:    NewRegistry(),
		host:        host,
		records:     map[string]*record{},
		engines:     map[string]*Engine{},
		grants:      map[string]*GrantsSlot{},
	}
	_ = os.MkdirAll(m.pluginsRoot, 0o755)
	_ = os.MkdirAll(m.dataRoot, 0o755)
	m.enabled, m.approved = loadPluginState(m.stateFile)
	return m
}

// Registry 贡献点注册表。
func (m *Manager) Registry() *Registry { return m.registry }

// Init 扫描插件目录,并激活「已启用且权限未提权」的插件。
func (m *Manager) Init() {
	m.Scan()
	m.mu.Lock()
	var toEnable []string
	for id := range m.records {
		if m.enabled[id] && m.permsApprovedLocked(id) {
			toEnable = append(toEnable, id)
		}
	}
	m.mu.Unlock()
	sort.Strings(toEnable) // 顺序稳定:超过上限时被砍掉的永远是同一批
	activated := 0
	for _, id := range toEnable {
		if activated >= MaxEnabled {
			break
		}
		if err := m.activate(id); err == nil {
			activated++
		}
	}
}

// Scan 重扫插件目录。
func (m *Manager) Scan() {
	records := map[string]*record{}
	entries, err := os.ReadDir(m.pluginsRoot)
	if err == nil {
		for _, ent := range entries {
			if !ent.IsDir() {
				continue
			}
			path := filepath.Join(m.pluginsRoot, ent.Name())
			p, err := LoadFromDir(path)
			if err != nil {
				// 坏目录跳过但要留痕:静默跳过会让「我明明装了」变成无头案。
				m.host.Log("", "warn", fmt.Sprintf("跳过无效插件目录 %s: %v", path, err))
				continue
			}
			records[p.Manifest.ID] = &record{
				manifest: p.Manifest, dir: p.Dir, entryPath: p.EntryPath,
				status: StatusDisabled,
			}
		}
	}
	m.mu.Lock()
	// 开发模式的记录不在 plugins/ 下,重扫不能把它们冲掉。
	for id, r := range m.records {
		if r.dev {
			records[id] = r
		}
	}
	m.records = records
	m.mu.Unlock()
}

// List 全部已装插件的展示 JSON。
func (m *Manager) List() []map[string]any {
	m.mu.Lock()
	defer m.mu.Unlock()
	ids := make([]string, 0, len(m.records))
	for id := range m.records {
		ids = append(ids, id)
	}
	sort.Strings(ids) // 顺序稳定:否则插件页每次刷新卡片都在跳
	out := make([]map[string]any, 0, len(ids))
	for _, id := range ids {
		r := m.records[id]
		out = append(out, map[string]any{
			"id":               r.manifest.ID,
			"name":             r.manifest.Name,
			"version":          r.manifest.Version,
			"author":           r.manifest.Author,
			"description":      r.manifest.Description,
			"permissions":      r.manifest.Permissions,
			"httpAllowedHosts": r.manifest.HTTPAllowedHosts,
			"icon":             r.manifest.Icon,
			"homepage":         r.manifest.Homepage,
			"status":           string(r.status),
			"enabled":          m.enabled[id],
			"error":            r.errMsg,
			"dev":              r.dev,
			"category":         r.manifest.Category,
			"apiVersion":       r.manifest.APIVersion,
			"contributes":      contributesSummary(r.manifest),
		})
	}
	return out
}

// contributesSummary 卡片上的能力徽章:「提供 1 个数据源、2 个面板」。
// 市场不下载包就能展示。
func contributesSummary(m *Manifest) map[string]any {
	count := func(k Kind) int {
		n := 0
		for _, c := range m.Contributions {
			if c.Kind == k {
				n++
			}
		}
		return n
	}
	return map[string]any{
		"dataSources":  count(KindDataSources),
		"panels":       count(KindPanels),
		"actions":      count(KindActions),
		"sandboxViews": count(KindSandboxViews),
	}
}

// InstallIPK 安装 .ipk(安装后默认禁用,待授权启用)。
func (m *Manager) InstallIPK(ipkPath string) (map[string]any, error) {
	p, err := InstallIPKFile(ipkPath, m.pluginsRoot)
	if err != nil {
		return nil, err
	}
	id := p.Manifest.ID
	m.mu.Lock()
	// ★ 重装:清旧启用态与已同意权限,**强制重新授权** —— 防新清单悄悄提权。
	delete(m.enabled, id)
	delete(m.approved, id)
	m.records[id] = &record{
		manifest: p.Manifest, dir: p.Dir, entryPath: p.EntryPath, status: StatusDisabled,
	}
	m.mu.Unlock()
	m.persist()
	return map[string]any{"id": id, "name": p.Manifest.Name, "version": p.Manifest.Version}, nil
}

// InstallDevDir 把一个**本地目录**直接当插件装上(不复制文件)。
//
// 跟 InstallIPK 的区别就是不搬文件 —— 这样「自己写插件自己用」的循环
// 从「改代码→打包→安装→启用」缩成「改代码→存盘」。
func (m *Manager) InstallDevDir(dir string) (map[string]any, error) {
	p, err := LoadFromDir(dir)
	if err != nil {
		return nil, err
	}
	id := p.Manifest.ID
	m.mu.Lock()
	// 同 InstallIPK:换了源就强制重新授权,防新清单悄悄提权。
	delete(m.enabled, id)
	delete(m.approved, id)
	m.records[id] = &record{
		manifest: p.Manifest, dir: p.Dir, entryPath: p.EntryPath,
		status: StatusDisabled, dev: true, entryMtime: mtimeOf(p.EntryPath),
	}
	m.mu.Unlock()
	m.persist()
	return map[string]any{
		"id": id, "name": p.Manifest.Name, "version": p.Manifest.Version, "dev": true,
	}, nil
}

// Enable 启用(调用方须已过授权弹窗)。记录用户同意的权限集,启动引擎并跑 onEnable。
func (m *Manager) Enable(id string) error {
	m.mu.Lock()
	r, ok := m.records[id]
	if !ok {
		m.mu.Unlock()
		return fmt.Errorf("插件不存在: %s", id)
	}
	if !m.enabled[id] && len(m.enabled) >= MaxEnabled {
		m.mu.Unlock()
		return fmt.Errorf("已达同时启用上限(%d 个),请先禁用其它插件", MaxEnabled)
	}
	perms := map[string]bool{}
	for _, p := range r.manifest.Permissions {
		perms[p] = true
	}
	m.enabled[id] = true
	m.approved[id] = perms
	m.mu.Unlock()
	m.persist()
	return m.activate(id)
}

func (m *Manager) activate(id string) error {
	m.mu.Lock()
	r, ok := m.records[id]
	if !ok {
		m.mu.Unlock()
		return fmt.Errorf("插件不存在: %s", id)
	}
	manifest, entryPath := r.manifest, r.entryPath
	slot := m.grantsSlotLocked(id)
	m.mu.Unlock()

	mainJS, err := os.ReadFile(entryPath)
	if err != nil {
		m.setStatus(id, StatusError, fmt.Sprintf("读入口失败: %v", err))
		return fmt.Errorf("读入口失败: %w", err)
	}

	// 先注册 manifest 静态声明的贡献点(handler 为具名全局函数)。
	for _, decl := range manifest.Contributions {
		cid := str(decl.Data, "id")
		if cid == "" {
			cid = "static_" + string(decl.Kind)
		}
		m.registry.Register(Contribution{
			PluginID: manifest.ID, Kind: decl.Kind, ID: cid,
			Data: decl.Data, FromManifest: true,
		})
	}

	storage := NewStorage(manifest.ID, filepath.Join(m.dataRoot, manifest.ID))
	eng, err := StartEngine(manifest, string(mainJS), NewGranted(manifest.Permissions),
		storage, m.host, m.registry, slot)
	if err != nil {
		m.registry.RemoveAllForPlugin(id)
		m.setStatus(id, StatusError, err.Error())
		return err
	}

	m.mu.Lock()
	if old := m.engines[id]; old != nil {
		old.Dispose()
	}
	m.engines[id] = eng
	m.mu.Unlock()

	/* ★★ onEnable 抛出的错**必须留下来**。黄金实现第一版是丢掉:
	   插件在 onEnable 里踩到权限拒绝/写错一行,注册到一半就中断,
	   而界面上它是「已启用、无错误」—— 面板永远空白、数据源少一半,
	   没有任何线索。现在照旧保持启用(已经注册上的那部分是能用的),
	   但把错误挂到记录上让用户看得见。 */
	if err := eng.RunLifecycle("onEnable"); err != nil {
		m.setStatus(id, StatusError, fmt.Sprintf("插件初始化(onEnable)出错,功能可能不完整:%v", err))
	} else {
		m.setStatus(id, StatusEnabled, "")
	}
	m.host.ExtensionsChanged()
	m.host.SourcesChanged(id)
	return nil
}

// Disable 禁用。
func (m *Manager) Disable(id string) {
	m.mu.Lock()
	eng := m.engines[id]
	delete(m.engines, id)
	m.mu.Unlock()

	if eng != nil {
		_ = eng.RunLifecycle("onDisable")
		eng.Dispose()
	}
	m.registry.RemoveAllForPlugin(id)

	m.mu.Lock()
	delete(m.enabled, id)
	if r := m.records[id]; r != nil {
		r.status = StatusDisabled
		r.errMsg = ""
	}
	m.mu.Unlock()
	m.persist()
	m.host.ExtensionsChanged()
	m.host.SourcesChanged(id)
}

// Uninstall 卸载(先禁用,再删目录)。
func (m *Manager) Uninstall(id string) {
	m.Disable(id)
	m.mu.Lock()
	delete(m.approved, id)
	var dir string
	if r := m.records[id]; r != nil {
		dir = r.dir
		// 开发模式挂的是用户自己的源码目录,**不能删** ——
		// 「卸载」在那里的意思是「不要再挂了」,不是「删掉我的工程」。
		if r.dev {
			dir = ""
		}
	}
	delete(m.records, id)
	m.mu.Unlock()
	if dir != "" {
		_ = UninstallDir(dir)
	}
	m.persist()
}

// Reload 重载一个插件(禁用 -> 重读 manifest -> 重新启用)。开发模式热重载走这里。
func (m *Manager) Reload(id string) error {
	m.mu.Lock()
	wasEnabled := m.enabled[id]
	r := m.records[id]
	m.mu.Unlock()
	if r == nil {
		return fmt.Errorf("插件不存在: %s", id)
	}
	if wasEnabled {
		m.Disable(id)
	}
	// manifest 可能也改了,重新读一遍。
	p, err := LoadFromDir(r.dir)
	if err != nil {
		return err
	}
	m.mu.Lock()
	if rec := m.records[id]; rec != nil {
		rec.manifest = p.Manifest
		rec.entryPath = p.EntryPath
		rec.entryMtime = mtimeOf(p.EntryPath)
		rec.errMsg = ""
	}
	m.mu.Unlock()
	if wasEnabled {
		return m.Enable(id)
	}
	return nil
}

// DevPluginsChanged 开发模式插件的入口文件是否变了(mtime)。变了就该重载。
//
// ponytail: 轮询 mtime 而不是上文件监听库 —— 零新依赖,而开发模式插件通常就一两个。
func (m *Manager) DevPluginsChanged() []string {
	type snap struct {
		id    string
		path  string
		known int64
	}
	m.mu.Lock()
	var snaps []snap
	for id, r := range m.records {
		if r.dev {
			snaps = append(snaps, snap{id, r.entryPath, r.entryMtime})
		}
	}
	m.mu.Unlock()

	changed := []string{}
	for _, s := range snaps {
		now := mtimeOf(s.path)
		if now == 0 || now == s.known {
			continue
		}
		m.mu.Lock()
		if r := m.records[s.id]; r != nil {
			r.entryMtime = now
		}
		m.mu.Unlock()
		changed = append(changed, s.id)
	}
	sort.Strings(changed)
	return changed
}

// ---- 触发 ----

// TriggerExtension 触发某扩展的 handler(actions / 设置页的入口按钮等)。
func (m *Manager) TriggerExtension(pluginID, typeID, extID string, args []any) (any, error) {
	return m.InvokeExtensionField(pluginID, typeID, extID, "handler", args)
}

// InvokeExtensionField 触发扩展 data 里某具名字段的 handler(如设置页的 load/submit)。
func (m *Manager) InvokeExtensionField(pluginID, typeID, extID, field string, args []any) (any, error) {
	kind, ok := KindFromID(typeID)
	if !ok {
		return nil, fmt.Errorf("未知贡献点类型: %s", typeID)
	}
	ext, ok := m.registry.Find(pluginID, kind, extID)
	if !ok {
		return nil, fmt.Errorf("贡献点不存在: %s/%s/%s", pluginID, typeID, extID)
	}
	ref := HandlerRefOf(ext.Data[field])
	if ref.None() {
		return nil, nil
	}
	m.mu.Lock()
	eng := m.engines[pluginID]
	m.mu.Unlock()
	if eng == nil {
		return nil, nil
	}
	if ref.Dynamic != "" {
		return eng.CallHandler(ref.Dynamic, args)
	}
	return eng.CallNamed(ref.Named, args)
}

// CallSource 调某数据源的一个方法(listDir / search / resolvePlay / 影视目录三件套)。
//
// 走 InvokeExtensionField:这些方法就是 dataSources 贡献描述里的字段,
// 复用既有的 handler 派发,不新开一条通路。
func (m *Manager) CallSource(pluginID, srcID, method string, args []any) (any, error) {
	return m.InvokeExtensionField(pluginID, string(KindDataSources), srcID, method, args)
}

// FirePlayerEvent 派发播放事件给所有插件的监听者。
func (m *Manager) FirePlayerEvent(event string, data any) {
	m.mu.Lock()
	engines := make([]*Engine, 0, len(m.engines))
	for _, e := range m.engines {
		engines = append(engines, e)
	}
	m.mu.Unlock()
	for _, e := range engines {
		e.FireEvent(event, data)
	}
}

// ExtensionsByType 取某类贡献的展示 JSON。
func (m *Manager) ExtensionsByType(typeID string) []Contribution {
	kind, ok := KindFromID(typeID)
	if !ok {
		return []Contribution{}
	}
	return m.registry.ByKind(kind)
}

// PanelsInSlot 取挂在某个 slot 的全部 panels。
func (m *Manager) PanelsInSlot(slot string) []Contribution {
	return m.registry.PanelsInSlot(slot)
}

// DataSources 当前所有已注册的数据源:(插件id, 源id, 展示名)。
func (m *Manager) DataSources() [][3]string {
	out := [][3]string{}
	for _, c := range m.registry.ByKind(KindDataSources) {
		name, _ := c.Data["name"].(string)
		if name == "" {
			name = c.ID
		}
		out = append(out, [3]string{c.PluginID, c.ID, name})
	}
	return out
}

// AssetPath 解析 `lpplugin://<插件id>/<rel>` 到磁盘文件。
//
// ★ **只有已启用的插件可读** —— 装了没启用的插件不该能被一个 iframe 拉起来,
// 否则「禁用」这个动作就没有实际约束力。
func (m *Manager) AssetPath(pluginID, rel string) (string, error) {
	m.mu.Lock()
	if !m.enabled[pluginID] {
		m.mu.Unlock()
		return "", ErrAssetNotEnabled
	}
	r := m.records[pluginID]
	m.mu.Unlock()
	if r == nil {
		return "", ErrAssetNotEnabled
	}
	return ResolveAsset(r.dir, rel)
}

// SetSourceGrants 用「用户已为该插件配置的全部源地址」整体替换它的
// `$sourceServer` 展开表。
func (m *Manager) SetSourceGrants(pluginID string, baseURLs []string) {
	m.mu.Lock()
	slot := m.grantsSlotLocked(pluginID)
	m.mu.Unlock()
	slot.Set(baseURLs)
}

// ManifestOf 取一个插件的清单(没有则 nil)。
func (m *Manager) ManifestOf(id string) *Manifest {
	m.mu.Lock()
	defer m.mu.Unlock()
	if r := m.records[id]; r != nil {
		return r.manifest
	}
	return nil
}

// ---- 内部 ----

func (m *Manager) grantsSlotLocked(pluginID string) *GrantsSlot {
	s := m.grants[pluginID]
	if s == nil {
		s = &GrantsSlot{}
		m.grants[pluginID] = s
	}
	return s
}

func (m *Manager) permsApprovedLocked(id string) bool {
	r := m.records[id]
	approved := m.approved[id]
	if r == nil || approved == nil {
		return false
	}
	for _, p := range r.manifest.Permissions {
		if !approved[p] {
			return false
		}
	}
	return true
}

func (m *Manager) setStatus(id string, status Status, errMsg string) {
	m.mu.Lock()
	defer m.mu.Unlock()
	if r := m.records[id]; r != nil {
		r.status = status
		r.errMsg = errMsg
	}
}
