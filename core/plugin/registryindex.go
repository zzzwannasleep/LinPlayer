package plugin

// 插件市场索引:多源订阅 + 聚合 + sha256 校验。
//
// 分发模型:**官方源 + 用户自定义源订阅 + 本地安装**。官方源不可删只可禁;
// 第三方源的插件在 UI 上打「第三方源」徽章,安装前弹权限确认。
//
// 通道口径:**registry 和 .ipk 都走 GitHub raw,不要「优化」到 Cloudflare**
// (用户实测:国内 CF 有地方会被阻断,GitHub 反而更稳)。
// 图标在构建期压成 data URI 内联进 registry.json,所以卡片永远不碎图、零额外请求。

import (
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"fmt"
	"sort"
	"strconv"
	"strings"
)

// Source 用户订阅的一个插件源。
type Source struct {
	ID      string `json:"id"`
	Name    string `json:"name"`
	URL     string `json:"url"`
	Enabled bool   `json:"enabled"`
	// Builtin 官方源。**可禁不可删** —— 删掉之后新用户开箱即空,
	// 再想找回来只能手打 URL。
	Builtin bool `json:"builtin"`
}

// RegistryVersion registry.json 里的一个版本条目。
type RegistryVersion struct {
	Version    string `json:"version"`
	APIVersion int    `json:"api_version"`
	MinAppVer  string `json:"min_app_version,omitempty"`
	PackageURL string `json:"package_url"`
	// SHA256 包的 sha256(小写十六进制)。**v2 新增** —— v1 既无签名也无校验和。
	SHA256      string `json:"sha256,omitempty"`
	PublishedAt string `json:"published_at,omitempty"`
	Changelog   string `json:"changelog,omitempty"`
}

// RegistryPlugin registry.json 里的一个插件。
type RegistryPlugin struct {
	ID          string   `json:"id"`
	Name        string   `json:"name"`
	Description string   `json:"description"`
	Author      string   `json:"author"`
	Icon        string   `json:"icon,omitempty"`
	Category    string   `json:"category,omitempty"`
	Tags        []string `json:"tags"`
	Targets     []string `json:"targets"`
	// Permissions 权限摘要:上移到 registry,**市场不下载包就能展示权限**。
	Permissions []string          `json:"permissions"`
	Contributes map[string]any    `json:"contributes,omitempty"`
	Versions    []RegistryVersion `json:"versions"`
	// 聚合时填:这条来自哪个源。第三方源要在卡片上打徽章。
	SourceID    string `json:"source_id"`
	SourceName  string `json:"source_name"`
	FromBuiltin bool   `json:"from_builtin"`
}

// BestVersion 当前宿主能装的最新版本。
//
// ★★ **必须自己按版本号取最大,不能信数组顺序** —— 本仓库在 GitHub Releases 上
// 栽过一模一样的跟头(id/created/published 三个键的返回顺序全是反的)。
func (p *RegistryPlugin) BestVersion(hostAPIVersion int) *RegistryVersion {
	var best *RegistryVersion
	for i := range p.Versions {
		v := &p.Versions[i]
		if v.APIVersion != 0 && v.APIVersion > hostAPIVersion {
			continue
		}
		if best == nil || CompareSemver(v.Version, best.Version) > 0 {
			best = v
		}
	}
	return best
}

// CompareSemver 语义化版本比较。
//
// 缺段按 0 补,非数字段按 0(宽松:registry 是外部数据,一条写歪的版本号
// 不该让整个市场炸掉)。
func CompareSemver(a, b string) int {
	parse := func(s string) []uint64 {
		head := strings.FieldsFunc(s, func(r rune) bool { return r == '-' || r == '+' })
		if len(head) == 0 {
			return nil
		}
		var out []uint64
		for _, p := range strings.Split(head[0], ".") {
			n, _ := strconv.ParseUint(p, 10, 64)
			out = append(out, n)
		}
		return out
	}
	va, vb := parse(a), parse(b)
	n := len(va)
	if len(vb) > n {
		n = len(vb)
	}
	for i := 0; i < n; i++ {
		var x, y uint64
		if i < len(va) {
			x = va[i]
		}
		if i < len(vb) {
			y = vb[i]
		}
		if x != y {
			if x > y {
				return 1
			}
			return -1
		}
	}
	return 0
}

// ParsedRegistry 一次解析的结果。**跳过数必须带出去。**
type ParsedRegistry struct {
	Plugins []RegistryPlugin
	// Skipped 认不出来、被跳过的条目数。
	Skipped int
}

// ParseRegistry 解析一份 registry.json。
//
// 单条坏了跳过,不让一个写歪的条目废掉整个源 —— 但**跳了多少必须报出来**。
// 2026-07-23 实测:官方源还是 v1 schema(author 是对象不是字符串),
// 于是 8 条**全部**被静默跳过,前端拿到的是「0 个插件、0 个错误」——
// 和「这个源本来就是空的」一模一样,没有任何线索指向「格式不对」。
func ParseRegistry(raw string) (*ParsedRegistry, error) {
	var top struct {
		Plugins []json.RawMessage `json:"plugins"`
	}
	if err := json.Unmarshal([]byte(raw), &top); err != nil {
		return nil, fmt.Errorf("registry JSON 非法: %w", err)
	}
	if top.Plugins == nil {
		return nil, fmt.Errorf("registry 缺少 plugins 数组")
	}
	out := &ParsedRegistry{Plugins: []RegistryPlugin{}}
	for _, item := range top.Plugins {
		var p RegistryPlugin
		if err := json.Unmarshal(item, &p); err != nil || p.ID == "" || len(p.Versions) == 0 {
			out.Skipped++
			continue
		}
		out.Plugins = append(out.Plugins, p)
	}
	return out, nil
}

// MergeSources 把多个源的插件聚合成一张列表。
//
// ★★ **按 id 去重,官方源优先** —— 第三方源不能靠重名覆盖掉官方插件,
// 那是最直接的一条投毒路径。同为第三方时先到先得(源的顺序即用户排的优先级)。
func MergeSources(perSource [][]RegistryPlugin) []RegistryPlugin {
	out := []RegistryPlugin{}
	for _, list := range perSource {
		for _, p := range list {
			found := -1
			for i := range out {
				if out[i].ID == p.ID {
					found = i
					break
				}
			}
			if found < 0 {
				out = append(out, p)
				continue
			}
			// 已有的是官方源 -> 保留;已有的是第三方而新的是官方 -> 换成官方。
			if !out[found].FromBuiltin && p.FromBuiltin {
				out[found] = p
			}
		}
	}
	sort.SliceStable(out, func(i, j int) bool {
		return strings.ToLower(out[i].Name) < strings.ToLower(out[j].Name)
	})
	return out
}

// VerifyPackage 校验下载下来的包。registry 里声明了 sha256 就必须对上。
//
// **声明了却对不上一律拒装**。没声明的只能放行(老源没这个字段),
// 但 UI 要能看出来「这个包没有校验和」。
func VerifyPackage(expectedSHA256 string, data []byte) error {
	expected := strings.ToLower(strings.TrimSpace(expectedSHA256))
	if expected == "" {
		return nil
	}
	actual := SHA256Hex(data)
	if actual == expected {
		return nil
	}
	return fmt.Errorf("插件包校验失败(可能已损坏或被篡改)\n期望 %s\n实际 %s", expected, actual)
}

// SHA256Hex 小写十六进制 SHA-256。
func SHA256Hex(data []byte) string {
	sum := sha256.Sum256(data)
	return hex.EncodeToString(sum[:])
}
