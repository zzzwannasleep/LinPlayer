package plugin

// 插件市场:多源 registry 订阅 → 聚合 → 下载校验 → 安装。
//
// 纯逻辑(版本挑选/聚合/sha256)在 registryindex.go;这一层管 **HTTP + 配置持久化
// + 落盘安装**。

import (
	"context"
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"net/url"
	"os"
	"path/filepath"
	"strings"
	"sync"

	"linplayer/core/config"
	"linplayer/core/httpx"
	"linplayer/core/paths"
)

// 官方源。id 是稳定常量,配置里只落一个开关(AppConfig.PluginOfficialEnabled)。
//
// ★ 地址是本仓库自己的公开插件仓库,和 httpx.RepoURL 同一性质(项目自身的
// 公开地址,不是任何人的服务器/线路地址),所以照黄金实现写在源码里。
const (
	OfficialSourceID   = "official"
	officialSourceName = "LinPlayer 官方源"
	officialSourceURL  = "https://raw.githubusercontent.com/zzzwannasleep/LinplayerPluginsRepository/main/registry.json"
)

// marketCache 聚合结果的进程内缓存。
//
// 市场页每次进出都重新拉一遍网络既慢又白费流量,而插件源的内容一天也不会变几次
// —— 想要最新的用户会点刷新(refresh=true)。
//
// ★★ **错误也要一起缓存**。黄金实现第一版只存插件列表,于是「某个源挂了」的提示
// 只在真正联网那一次出现,切走再切回来(命中缓存)警告条就消失了,剩下一个光秃秃
// 的「没有找到插件」—— 用户第二次看到的是一个**更没线索**的页面。
type marketCache struct {
	plugins []RegistryPlugin
	errors  []map[string]any
	valid   bool
}

var (
	cacheMu sync.Mutex
	cache   marketCache
)

// InvalidateMarketCache 让市场缓存作废(改了源订阅时调)。
func InvalidateMarketCache() {
	cacheMu.Lock()
	cache = marketCache{}
	cacheMu.Unlock()
}

func officialSource() Source {
	return Source{
		ID: OfficialSourceID, Name: officialSourceName, URL: officialSourceURL,
		Enabled: true, Builtin: true,
	}
}

// userSources 读用户自定义源订阅。
func userSources() []Source {
	c := config.Current()
	out := []Source{}
	if len(c.PluginSources) == 0 {
		return out
	}
	if json.Unmarshal(c.PluginSources, &out) != nil {
		return []Source{}
	}
	return out
}

func saveUserSources(list []Source) error {
	c := config.Current()
	raw, err := json.Marshal(list)
	if err != nil {
		return err
	}
	c.PluginSources = raw
	InvalidateMarketCache()
	return c.Save()
}

// AllSources 官方源 + 用户源。
//
// 官方**永远排第一** —— 聚合时先到的赢重名,顺序即优先级。
func AllSources() []Source {
	c := config.Current()
	off := officialSource()
	off.Enabled = c.PluginOfficialEnabled
	return append([]Source{off}, userSources()...)
}

// sourceIDFor 源 id 由 URL 派生:同一个 URL 加两次不会变成两条。
//
// ★ 归一化交给 url.Parse(它只把 scheme/host 转小写,**路径保持原样**)——
// 手写 ToLower 会让 /R.json 和 /r.json 撞成同一个 id,而在大小写敏感的
// 服务器上那是两份不同的 registry。
func sourceIDFor(raw string) string {
	norm := strings.TrimSpace(raw)
	if u, err := url.Parse(norm); err == nil && u.Host != "" {
		u.Scheme = strings.ToLower(u.Scheme)
		u.Host = strings.ToLower(u.Host)
		norm = u.String()
	}
	return SHA256Hex([]byte(norm))[:12]
}

// AddSource 添加一个用户源。
func AddSource(name, rawURL string) ([]Source, error) {
	rawURL = strings.TrimSpace(rawURL)
	if err := CheckFetchURL(rawURL); err != nil {
		return nil, err
	}
	id := sourceIDFor(rawURL)
	if id == OfficialSourceID || rawURL == officialSourceURL {
		return nil, fmt.Errorf("这已经是官方源了")
	}
	list := userSources()
	for _, s := range list {
		if s.ID == id {
			return nil, fmt.Errorf("这个源已经添加过了")
		}
	}
	if strings.TrimSpace(name) == "" {
		name = rawURL
	}
	list = append(list, Source{ID: id, Name: strings.TrimSpace(name), URL: rawURL, Enabled: true})
	if err := saveUserSources(list); err != nil {
		return nil, err
	}
	return AllSources(), nil
}

// RemoveSource 删一个用户源。官方源不能删,只能停用。
func RemoveSource(id string) ([]Source, error) {
	if id == OfficialSourceID {
		return nil, fmt.Errorf("官方源不能删除,只能停用")
	}
	list := userSources()
	out := make([]Source, 0, len(list))
	for _, s := range list {
		if s.ID != id {
			out = append(out, s)
		}
	}
	if err := saveUserSources(out); err != nil {
		return nil, err
	}
	return AllSources(), nil
}

// ToggleSource 启用/停用一个源。
func ToggleSource(id string, enabled bool) ([]Source, error) {
	if id == OfficialSourceID {
		c := config.Current()
		c.PluginOfficialEnabled = enabled
		InvalidateMarketCache()
		if err := c.Save(); err != nil {
			return nil, err
		}
		return AllSources(), nil
	}
	list := userSources()
	found := false
	for i := range list {
		if list[i].ID == id {
			list[i].Enabled = enabled
			found = true
		}
	}
	if !found {
		return nil, fmt.Errorf("没有这个插件源")
	}
	if err := saveUserSources(list); err != nil {
		return nil, err
	}
	return AllSources(), nil
}

// MarketList 拉取并聚合全部启用的源。
//
// **单个源失败不影响其它源**:错误按源收集后一并回给前端展示,
// 而不是让一个挂掉的第三方源把整个市场变成一张报错页。
func MarketList(ctx context.Context, refresh bool) (map[string]any, error) {
	if !refresh {
		cacheMu.Lock()
		c := cache
		cacheMu.Unlock()
		if c.valid {
			return map[string]any{
				"plugins": c.plugins, "errors": c.errors,
				"apiVersion": APIVersion, "cached": true,
			}, nil
		}
	}

	var perSource [][]RegistryPlugin
	errors := []map[string]any{}
	for _, s := range AllSources() {
		if !s.Enabled {
			continue
		}
		list, err := fetchOneSource(ctx, s)
		if err != nil {
			errors = append(errors, map[string]any{"source": s.Name, "error": err.Error()})
			continue
		}
		perSource = append(perSource, list)
	}
	merged := MergeSources(perSource)

	cacheMu.Lock()
	cache = marketCache{plugins: merged, errors: errors, valid: true}
	cacheMu.Unlock()

	return map[string]any{
		"plugins": merged, "errors": errors, "apiVersion": APIVersion, "cached": false,
	}, nil
}

func fetchOneSource(ctx context.Context, src Source) ([]RegistryPlugin, error) {
	if err := CheckFetchURL(src.URL); err != nil {
		return nil, err
	}
	req, err := http.NewRequestWithContext(ctx, http.MethodGet, src.URL, nil)
	if err != nil {
		return nil, fmt.Errorf("地址非法: %w", err)
	}
	resp, err := httpx.Client().Do(req)
	if err != nil {
		return nil, fmt.Errorf("连不上: %w", err)
	}
	defer resp.Body.Close()
	if resp.StatusCode < 200 || resp.StatusCode >= 300 {
		return nil, fmt.Errorf("HTTP %d", resp.StatusCode)
	}
	raw, err := io.ReadAll(resp.Body)
	if err != nil {
		return nil, fmt.Errorf("读取失败: %w", err)
	}
	parsed, err := ParseRegistry(string(raw))
	if err != nil {
		return nil, err
	}
	// ★ 一条都没认出来 ≠ 这个源是空的。不说清楚的话前端只会显示「没有找到插件」,
	//   用户完全看不出真实原因是 schema 对不上(2026-07-23 官方源正是这个状态)。
	if len(parsed.Plugins) == 0 && parsed.Skipped > 0 {
		return nil, fmt.Errorf(
			"这个源里的 %d 条插件全都认不出来 —— 多半是旧版(v1)registry,需要源那边升级到 v2",
			parsed.Skipped)
	}
	list := parsed.Plugins
	// 卡片上要标「来自哪个源」,第三方源必须能一眼看出来。
	for i := range list {
		list[i].SourceID = src.ID
		list[i].SourceName = src.Name
		list[i].FromBuiltin = src.Builtin
	}
	return list, nil
}

// MarketInstall 从市场安装(或升级)一个插件。
//
// 顺序是**先校验再落盘**:sha256 对不上的包连临时文件都不留。
func MarketInstall(ctx context.Context, mgr *Manager, id, version string) (map[string]any, error) {
	cacheMu.Lock()
	var found *RegistryPlugin
	for i := range cache.plugins {
		if cache.plugins[i].ID == id {
			p := cache.plugins[i]
			found = &p
			break
		}
	}
	cacheMu.Unlock()
	if found == nil {
		return nil, fmt.Errorf("插件列表已过期,请刷新市场后重试")
	}

	var ver *RegistryVersion
	if version != "" {
		for i := range found.Versions {
			if found.Versions[i].Version == version {
				ver = &found.Versions[i]
				break
			}
		}
		if ver == nil {
			return nil, fmt.Errorf("没有 %s 这个版本", version)
		}
	} else {
		ver = found.BestVersion(APIVersion)
		if ver == nil {
			return nil, fmt.Errorf("这个插件没有当前版本能装的版本,请先升级 LinPlayer")
		}
	}

	pkgURL := strings.TrimSpace(ver.PackageURL)
	if pkgURL == "" {
		return nil, fmt.Errorf("这个版本没有提供下载地址")
	}
	// 和 registry 同一把尺子:https,本机除外(插件作者要能在本地试自己的源)。
	if err := CheckFetchURL(pkgURL); err != nil {
		return nil, err
	}

	req, err := http.NewRequestWithContext(ctx, http.MethodGet, pkgURL, nil)
	if err != nil {
		return nil, fmt.Errorf("下载失败: %w", err)
	}
	resp, err := httpx.Client().Do(req)
	if err != nil {
		return nil, fmt.Errorf("下载失败: %w", err)
	}
	defer resp.Body.Close()
	if resp.StatusCode < 200 || resp.StatusCode >= 300 {
		return nil, fmt.Errorf("下载失败: HTTP %d", resp.StatusCode)
	}
	data, err := io.ReadAll(resp.Body)
	if err != nil {
		return nil, fmt.Errorf("下载失败: %w", err)
	}

	if err := VerifyPackage(ver.SHA256, data); err != nil {
		return nil, err
	}

	// 临时文件落在自家 temp 根下(不是系统 %TEMP%),遵守「数据全在 userdata/」。
	dir := paths.TempDir()
	if err := os.MkdirAll(dir, 0o755); err != nil {
		return nil, fmt.Errorf("建临时目录失败: %w", err)
	}
	tmp := filepath.Join(dir, fmt.Sprintf("%s-%s.ipk", id, ver.Version))
	if err := os.WriteFile(tmp, data, 0o644); err != nil {
		return nil, fmt.Errorf("写临时文件失败: %w", err)
	}
	info, err := mgr.InstallIPK(tmp)
	_ = os.Remove(tmp)
	if err != nil {
		return nil, err
	}
	return map[string]any{
		"info": info, "version": ver.Version,
		"verified": strings.TrimSpace(ver.SHA256) != "",
	}, nil
}
