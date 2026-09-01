package plugin

// manifest.json 解析 + 严格校验(**apiVersion: 2**)。
//
// **不做 v1 兼容层**:官方仓库总共 8 个插件,全部重写比养两套概念便宜,
// 而且 `emby.credentials` 这个刚删掉的攻击面会被兼容层拖回来。

import (
	"encoding/json"
	"fmt"
	"strings"
)

// APIVersion 当前宿主支持的插件 API 版本。
const APIVersion = 2

// TokenSourceServer `httpAllowedHosts` 里的运行时令牌:展开成**用户在「添加服务器」
// 里亲手填的**那个 base_url 的 origin。
//
// 没有它,数据源插件是废的 —— 白名单是发布期固定的,而通用数据源插件
// (OpenList / 飞牛 / 任意自建)发布时不可能知道用户自建服务器的域名,
// 裸 `*` 又被明确堵死(见 hostAllowed)。
const TokenSourceServer = "$sourceServer"

// Categories 市场分类。
var Categories = []string{"source", "ui", "player", "notify", "tools"}

// Targets 适配端。
var Targets = []string{"pc", "mobile", "tv"}

// ContributionDecl manifest 里 contributes 的一条静态贡献声明。
type ContributionDecl struct {
	Kind Kind
	Data map[string]any
}

// Manifest 一份已校验的插件清单。
type Manifest struct {
	ID          string
	Version     string
	APIVersion  int
	Name        string
	Author      string
	Description string
	Category    string
	Targets     []string
	// Main 入口 JS 文件名(相对插件目录),默认 main.js。
	Main          string
	Permissions   []string
	Contributions []ContributionDecl
	// HTTPAllowedHosts HTTPS 白名单(空 = 拒绝所有出网,fail-closed)。可含 $sourceServer。
	HTTPAllowedHosts []string
	Icon             string
	Homepage         string
	License          string
	MinAppVersion    string
	// Raw 原始 JSON(展示/备份用)。
	Raw map[string]any
}

// idValid 反向域名:至少一个点,仅字母数字/点/连字符/下划线,每段非空。
func idValid(id string) bool {
	segs := strings.Split(id, ".")
	if len(segs) < 2 {
		return false
	}
	for _, s := range segs {
		if s == "" {
			return false
		}
		for _, c := range s {
			ok := (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') ||
				(c >= '0' && c <= '9') || c == '-' || c == '_'
			if !ok {
				return false
			}
		}
	}
	return true
}

// versionValid 宽松语义化:major.minor.patch,允许 -/+ 后缀。
func versionValid(v string) bool {
	core := strings.FieldsFunc(v, func(r rune) bool { return r == '-' || r == '+' })
	if len(core) == 0 {
		return false
	}
	parts := strings.Split(core[0], ".")
	if len(parts) != 3 {
		return false
	}
	for _, p := range parts {
		if p == "" {
			return false
		}
		for _, c := range p {
			if c < '0' || c > '9' {
				return false
			}
		}
	}
	return true
}

func str(m map[string]any, field string) string {
	s, _ := m[field].(string)
	return strings.TrimSpace(s)
}

// ParseManifest 解析并严格校验一份 manifest.json。
func ParseManifest(raw string) (*Manifest, error) {
	var v map[string]any
	if err := json.Unmarshal([]byte(raw), &v); err != nil {
		return nil, fmt.Errorf("manifest JSON 非法: %w", err)
	}
	return ManifestFromValue(v)
}

// ManifestFromValue 从已解析的 JSON 对象构造。
func ManifestFromValue(v map[string]any) (*Manifest, error) {
	req := func(field string) (string, error) {
		s := str(v, field)
		if s == "" {
			return "", fmt.Errorf("缺少或非法字段: %s", field)
		}
		return s, nil
	}

	id, err := req("id")
	if err != nil {
		return nil, err
	}
	if !idValid(id) {
		return nil, fmt.Errorf("id 必须为反向域名格式(如 com.example.foo),当前: %s", id)
	}
	version, err := req("version")
	if err != nil {
		return nil, err
	}
	if !versionValid(version) {
		return nil, fmt.Errorf("version 必须为语义化版本(如 1.0.0),当前: %s", version)
	}
	name, err := req("name")
	if err != nil {
		return nil, err
	}

	// apiVersion 门禁。缺省视为 1(v1 插件没这个字段),直接拒。
	apiVersion := 1
	if f, ok := v["apiVersion"].(float64); ok {
		apiVersion = int(f)
	}
	if apiVersion < APIVersion {
		return nil, fmt.Errorf(
			"该插件是旧版本(apiVersion %d),本应用需要 %d;请到插件市场获取新版",
			apiVersion, APIVersion)
	}
	if apiVersion > APIVersion {
		return nil, fmt.Errorf(
			"该插件需要更新的应用版本(apiVersion %d > %d);请先升级 LinPlayer",
			apiVersion, APIVersion)
	}

	// v1 的字段撞上就明确告诉用户这是老插件,别让他去查 JSON 语法。
	if _, has := v["runtime"]; has {
		return nil, fmt.Errorf("manifest 含已废弃的 runtime 字段(v1 遗留,曾用于 iOS 合规);请使用 v2 规范重新打包")
	}
	if _, has := v["extends"]; has {
		return nil, fmt.Errorf("manifest 含已废弃的 extends 字段;v2 改用 contributes,见插件开发文档")
	}

	permissions, err := parsePermissions(v)
	if err != nil {
		return nil, err
	}

	category := str(v, "category")
	if category == "" {
		category = "tools"
	}
	if !inList(Categories, category) {
		return nil, fmt.Errorf("未知分类: %s(可选 %s)", category, strings.Join(Categories, " / "))
	}

	targets, err := parseTargets(v)
	if err != nil {
		return nil, err
	}

	contributions, err := parseContributions(v, permissions)
	if err != nil {
		return nil, err
	}

	hosts, err := parseAllowedHosts(v)
	if err != nil {
		return nil, err
	}

	author := str(v, "author")
	if author == "" {
		author = "未知作者"
	}
	main := str(v, "main")
	if main == "" {
		main = "main.js"
	}

	return &Manifest{
		ID: id, Version: version, APIVersion: apiVersion, Name: name,
		Author: author, Description: str(v, "description"),
		Category: category, Targets: targets, Main: main,
		Permissions: permissions, Contributions: contributions,
		HTTPAllowedHosts: hosts,
		Icon:             str(v, "icon"), Homepage: str(v, "homepage"),
		License: str(v, "license"), MinAppVersion: str(v, "minAppVersion"),
		Raw: v,
	}, nil
}

func parsePermissions(v map[string]any) ([]string, error) {
	out := []string{}
	pv, has := v["permissions"]
	if !has {
		return out, nil
	}
	arr, ok := pv.([]any)
	if !ok {
		return nil, fmt.Errorf("permissions 必须是数组")
	}
	for _, p := range arr {
		s, ok := p.(string)
		if !ok {
			return nil, fmt.Errorf("permissions 数组元素必须是字符串")
		}
		if why := RemovedReason(s); why != "" {
			return nil, fmt.Errorf("权限「%s」在新版本已移除:%s", s, why)
		}
		if !IsKnownPermission(s) {
			return nil, fmt.Errorf("未知权限: %s", s)
		}
		if !inList(out, s) {
			out = append(out, s)
		}
	}
	return out, nil
}

func parseTargets(v map[string]any) ([]string, error) {
	out := []string{}
	tv, has := v["targets"]
	if !has {
		return out, nil
	}
	arr, ok := tv.([]any)
	if !ok {
		return nil, fmt.Errorf("targets 必须是数组")
	}
	for _, t := range arr {
		s, ok := t.(string)
		if !ok {
			return nil, fmt.Errorf("targets 数组元素必须是字符串")
		}
		s = strings.TrimSpace(s)
		if !inList(Targets, s) {
			return nil, fmt.Errorf("未知目标端: %s(可选 %s)", s, strings.Join(Targets, " / "))
		}
		if !inList(out, s) {
			out = append(out, s)
		}
	}
	return out, nil
}

func parseContributions(v map[string]any, permissions []string) ([]ContributionDecl, error) {
	out := []ContributionDecl{}
	cv, has := v["contributes"]
	if !has {
		return out, nil
	}
	obj, ok := cv.(map[string]any)
	if !ok {
		return nil, fmt.Errorf("contributes 必须是对象")
	}
	// 认不出来的键要报错,不能静默忽略 —— 拼错的贡献点名字会表现成「功能没出现」。
	for key := range obj {
		if _, ok := KindFromID(key); !ok {
			return nil, fmt.Errorf("未知贡献点类型: %s", key)
		}
	}
	// ★ 按 AllKinds 的固定顺序遍历:Go 的 map 迭代顺序是随机的,
	//   直接 range 会让同一份 manifest 每次解析出不同的贡献顺序,
	//   进而让「先撞上哪条错误」在两次运行之间跳来跳去。
	for _, kind := range AllKinds {
		val, has := obj[string(kind)]
		if !has {
			continue
		}
		// 没声明对应权限就不许贡献 —— 否则用户在授权弹窗里看不到、却被悄悄挂上了东西。
		need := kind.RequiredPermission()
		if !inList(permissions, need) {
			return nil, fmt.Errorf("contributes.%s 需要声明权限「%s」,但 permissions 里没有", kind, need)
		}
		var items []any
		if arr, ok := val.([]any); ok {
			items = arr
		} else {
			items = []any{val}
		}
		for _, item := range items {
			m, ok := item.(map[string]any)
			if !ok {
				return nil, fmt.Errorf("contributes.%s 的描述必须是对象", kind)
			}
			if err := validateContribution(kind, m); err != nil {
				return nil, err
			}
			out = append(out, ContributionDecl{Kind: kind, Data: m})
		}
	}
	return out, nil
}

func validateContribution(kind Kind, item map[string]any) error {
	id := str(item, "id")
	if id == "" {
		return fmt.Errorf("contributes.%s 的每一条都必须有非空 id", kind)
	}
	switch kind {
	case KindPanels:
		slot := str(item, "slot")
		if !inList(PanelSlots, slot) {
			return fmt.Errorf("panels[%s] 的 slot 非法: %q(可选 %s)", id, slot, strings.Join(PanelSlots, " / "))
		}
	case KindActions:
		cx := str(item, "context")
		if cx == "" {
			cx = "global" // context 缺省为 global
		}
		if !inList(ActionContexts, cx) {
			return fmt.Errorf("actions[%s] 的 context 非法: %q(可选 %s)", id, cx, strings.Join(ActionContexts, " / "))
		}
	case KindSandboxViews:
		entry := str(item, "entry")
		if entry == "" {
			return fmt.Errorf("sandboxViews[%s] 必须指定 entry(插件内的 html 文件)", id)
		}
		// 逃生舱的 entry 是要拼进 lpplugin:// 路径的,先在这一层挡掉穿越。
		if strings.Contains(entry, "..") || strings.HasPrefix(entry, "/") || strings.HasPrefix(entry, "\\") {
			return fmt.Errorf("sandboxViews[%s] 的 entry 必须是插件目录内的相对路径", id)
		}
	case KindDataSources:
		auth, has := item["auth"]
		if !has {
			return nil
		}
		authObj, _ := auth.(map[string]any)
		fields, ok := authObj["fields"].([]any)
		if !ok {
			return fmt.Errorf("dataSources[%s] 的 auth.fields 必须是数组", id)
		}
		for _, f := range fields {
			fm, _ := f.(map[string]any)
			if str(fm, "id") == "" {
				return fmt.Errorf("dataSources[%s] 的 auth.fields 每项都要有 id", id)
			}
		}
	}
	return nil
}

func parseAllowedHosts(v map[string]any) ([]string, error) {
	out := []string{}
	arr, ok := v["httpAllowedHosts"].([]any)
	if !ok {
		return out, nil
	}
	for _, e := range arr {
		s, ok := e.(string)
		if !ok {
			return nil, fmt.Errorf("httpAllowedHosts 数组元素必须是字符串")
		}
		s = strings.TrimSpace(s)
		if s == "" {
			continue
		}
		// $ 开头的一律当令牌:拼错的令牌不能被当成一个普通(且永远匹配不上的)域名
		// 静默放过 —— 那样插件作者会对着一个「域名不在白名单内」的报错查半天域名。
		if strings.HasPrefix(s, "$") && s != TokenSourceServer {
			return nil, fmt.Errorf("httpAllowedHosts 含未知令牌: %s(目前只支持 %s)", s, TokenSourceServer)
		}
		if !inList(out, s) {
			out = append(out, s)
		}
	}
	return out, nil
}

// DataSources 这个插件贡献的全部数据源 (源id, 展示名)。
func (m *Manifest) DataSources() [][2]string {
	out := [][2]string{}
	for _, c := range m.Contributions {
		if c.Kind != KindDataSources {
			continue
		}
		sid := str(c.Data, "id")
		if sid == "" {
			continue
		}
		name := str(c.Data, "name")
		if name == "" {
			name = sid
		}
		out = append(out, [2]string{sid, name})
	}
	return out
}

// WantsSourceServerHost 白名单里是否含 $sourceServer 令牌 —— 有就说明它要访问
// 用户自己填的服务器地址,「添加服务器」页要据此提示用户。
func (m *Manifest) WantsSourceServerHost() bool {
	return inList(m.HTTPAllowedHosts, TokenSourceServer)
}
