package prefs

// 网络图标库:拉聚合源 → 解析成(名字, 链接)→ **落盘缓存 + TTL**,不每次拉。
//
// 用户 2026-07-15:「我提供四个聚合图标链接 你解析出来名字和链接 然后下载到本地
// 持久化缓存 不要每次都拉取」。源统一格式 `{name, description, icons:[{name, url, category?}]}`,
// 共约 1468 个图标。
//
// ★★ **源地址走编译期注入,不写进源码。**
// 黄金实现把四条地址硬编在 icon_library.rs 里,那违反仓库红线(域名不许进提交)。
// 这里改成 `-ldflags -X` 注入一串逗号分隔的地址(见 core/cmd/sealsecrets),
// 没注入时图标库为空 —— 界面据此说「这个构建没有配图标源」,而不是「没有图标」。
//
// ## 缓存策略(照 core/ranking)
// 拉全源 → 合并 → 落 cache/icon_library.json + 时间戳,TTL 内直接读盘。
// **拉取失败时回退到旧缓存(哪怕过期)** —— 网断了也别让图标库空着,旧的总比没有强。
// 用户点「刷新」传 force 绕过 TTL。

import (
	"context"
	"encoding/json"
	"io"
	"net/http"
	"os"
	"path/filepath"
	"strings"
	"time"

	"linplayer/core/bus"
	"linplayer/core/httpx"
	"linplayer/core/paths"
)

// iconSources 由 -ldflags -X 注入,逗号分隔。
var iconSources string

// cacheTTL 图标库不常变,一天拉一次够了。
const cacheTTL = 24 * time.Hour

// IconSources 这个构建配了哪些图标源。
func IconSources() []string {
	var out []string
	for _, s := range strings.Split(iconSources, ",") {
		if s = strings.TrimSpace(s); strings.HasPrefix(s, "http") {
			out = append(out, s)
		}
	}
	// 测试 / 自检用:指到假上游。
	if v := strings.TrimSpace(os.Getenv("LP_ICON_LIBRARY_SOURCES")); v != "" {
		out = nil
		for _, s := range strings.Split(v, ",") {
			if s = strings.TrimSpace(s); s != "" {
				out = append(out, s)
			}
		}
	}
	return out
}

// IconEntry 库里的一个图标条目。UI 拿它渲染网格,点选后当 icon_url。
type IconEntry struct {
	Name string `json:"name"`
	URL  string `json:"url"`
	// Source 来自哪个源(源的 name 字段,如「某图标库」),UI 可分组;空则未知。
	Source string `json:"source"`
}

type sourceDoc struct {
	Name  string `json:"name"`
	Icons []struct {
		Name string `json:"name"`
		URL  string `json:"url"`
	} `json:"icons"`
}

type iconCache struct {
	At      int64       `json:"at"`
	Entries []IconEntry `json:"entries"`
}

func iconCachePath() string { return filepath.Join(paths.CacheDir(), "icon_library.json") }

// parseSource 解析一个源的 JSON。
//
// ★ 坏 JSON / 空 url **静默跳过**,不因为一个源坏了整库空 ——
// fetch 那层的隔离就靠这个。
func parseSource(body string) []IconEntry {
	var doc sourceDoc
	if json.Unmarshal([]byte(body), &doc) != nil {
		return nil
	}
	var out []IconEntry
	for _, i := range doc.Icons {
		// ★ 空 url / 非 http 的条目必须丢掉 —— 前端拿去当图片地址是坏图,
		//   被选中当服务器图标更糟(存进配置里,以后每次都是坏图)。
		if !strings.HasPrefix(strings.TrimSpace(i.URL), "http") {
			continue
		}
		name := i.Name
		// ★ 名字缺失回落成 url:空名字的格子搜不到、也看不出是什么。
		if strings.TrimSpace(name) == "" {
			name = i.URL
		}
		out = append(out, IconEntry{Name: name, URL: i.URL, Source: doc.Name})
	}
	return out
}

func fetchAll(ctx context.Context) []IconEntry {
	var out []IconEntry
	seen := map[string]bool{}
	for _, u := range IconSources() {
		req, err := http.NewRequestWithContext(ctx, http.MethodGet, u, nil)
		if err != nil {
			continue
		}
		// ★ 单源失败不影响其它源。
		resp, err := httpx.Client().Do(req)
		if err != nil {
			continue
		}
		body, err := io.ReadAll(resp.Body)
		code := resp.StatusCode
		resp.Body.Close()
		if err != nil || code < 200 || code >= 300 {
			continue
		}
		// 不同源可能收录同一张图,按 url 去重。
		for _, e := range parseSource(string(body)) {
			if !seen[e.URL] {
				seen[e.URL] = true
				out = append(out, e)
			}
		}
	}
	return out
}

func iconCacheGet(allowStale bool) []IconEntry {
	raw, err := os.ReadFile(iconCachePath())
	if err != nil {
		return nil
	}
	var c iconCache
	if json.Unmarshal(raw, &c) != nil {
		return nil
	}
	if allowStale || time.Since(time.Unix(c.At, 0)) <= cacheTTL {
		return c.Entries
	}
	return nil
}

func iconCachePut(entries []IconEntry) {
	if os.MkdirAll(paths.CacheDir(), 0o755) != nil {
		return
	}
	if b, err := json.Marshal(iconCache{At: time.Now().Unix(), Entries: entries}); err == nil {
		_ = os.WriteFile(iconCachePath(), b, 0o644)
	}
}

// IconLibrary 图标库。默认命中 24h 缓存;force 绕过并重新拉全源。
func IconLibrary(ctx context.Context, force bool) []IconEntry {
	if !force {
		if c := iconCacheGet(false); c != nil {
			return c
		}
	}
	if fresh := fetchAll(ctx); len(fresh) > 0 {
		iconCachePut(fresh)
		return fresh
	}
	// ★ 全拉失败 → 回退旧缓存(**哪怕过期**)。网断了也别让图标库空着。
	return iconCacheGet(true)
}

func registerIconLibrary() {
	bus.Register("prefs.iconLibrary", func(ctx context.Context, seq int64, a map[string]any) (any, error) {
		force, _ := a["force"].(bool)
		items := IconLibrary(ctx, force)
		if items == nil {
			items = []IconEntry{}
		}
		/* ★★ 「这个构建没配源」和「拉取失败」要分开说。
		   合成一句「没有图标」的话,前者是永远修不好的(界面在等一件不会发生的事),
		   后者点一下刷新就好了 —— 而用户看到的是同一句话。 */
		return map[string]any{
			"items": items, "configured": len(IconSources()) > 0,
		}, nil
	})
}
