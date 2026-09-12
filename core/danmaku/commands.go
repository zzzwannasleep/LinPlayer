package danmaku

// `danmaku.*` 十四条命令。

import (
	"context"
	"encoding/json"
	"fmt"
	"os"
	"strings"
	"sync"

	"linplayer/core/bus"
	"linplayer/core/secrets"
)

// Blocklist 落库的屏蔽表:按词屏蔽 + 按发送者屏蔽。
type Blocklist struct {
	Words []string `json:"words"`
	Users []string `json:"users"`
}

// BlocklistImported 导入一份弹弹Play 屏蔽表 XML 之后的回执。
//
// TotalWords / TotalUsers 是**合并去重之后**的总数,不是这次导进来的条数 ——
// UI 拿它给「现在一共屏蔽了多少」,两者混用会越导数字越离谱。
type BlocklistImported struct {
	TextWords    []string `json:"text_words"`
	UserIDs      []string `json:"user_ids"`
	SkippedCount int      `json:"skipped_count"`
	TotalWords   int      `json:"total_words"`
	TotalUsers   int      `json:"total_users"`
}

// OfficialSourceID 官方源的固定 id。
const OfficialSourceID = "official"

// OfficialSource 官方弹弹Play 源。
//
// ★★ 凭据是**编译期注入**的(见 core/secrets)。没注入时 Enabled=false ——
// 这不是「缺功能」,是**本地构建本来就没有**。假装它可用的话,
// 每次匹配都会往官方接口打一轮空请求,而用户只看到「搜不到」。
func OfficialSource() (SourceConfig, bool) {
	id, secret, ok := secrets.DandanCreds()
	return SourceConfig{
		ID: OfficialSourceID, Name: "弹弹Play(官方)",
		APIURL: OfficialBase, Official: true,
		AppID: id, AppSecret: secret,
	}, ok
}

// allSources 官方源(如果可用)+ 用户自建源。
//
// allowOfficial=false 时**只留自建源**(见 AllowOfficialFor)。
func allSources(allowOfficial bool) []SourceConfig {
	out := []SourceConfig{}
	if allowOfficial {
		if o, ok := OfficialSource(); ok {
			out = append(out, o)
		}
	}
	return append(out, LoadSources()...)
}

// hasOfficial 这批源里有没有官方源(决定要不要过搜索闸门)。
func hasOfficial(cfgs []SourceConfig) bool {
	for _, c := range cfgs {
		if c.Official {
			return true
		}
	}
	return false
}

// RegisterCommands 由 core/commands 调用。
func RegisterCommands() {
	// ---- 源配置 ----
	bus.Register("danmaku.getDanmakuConfig", func(ctx context.Context, seq int64, a map[string]any) (any, error) {
		return LoadSources(), nil
	})

	bus.Register("danmaku.setDanmakuConfig", func(ctx context.Context, seq int64, a map[string]any) (any, error) {
		raw, ok := a["sources"]
		if !ok {
			return nil, bus.NewErr(bus.EInvalid, "缺少 sources")
		}
		b, err := json.Marshal(raw)
		if err != nil {
			return nil, bus.NewErr(bus.EInvalid, "sources 解析失败: %v", err)
		}
		var list []SourceConfig
		if json.Unmarshal(b, &list) != nil {
			return nil, bus.NewErr(bus.EInvalid, "sources 不是源列表")
		}
		// ★ 从用户粘的地址里**推导**鉴权方式,不让他选(他也不知道啥是鉴权方式)
		for i := range list {
			if list[i].Official {
				continue
			}
			u, auth, tok := DeriveAuth(list[i].APIURL)
			list[i].APIURL = u
			if list[i].AuthType == "" || list[i].AuthType == AuthNone {
				list[i].AuthType = auth
				if tok != "" {
					list[i].Token = tok
				}
			}
		}
		if list == nil {
			list = []SourceConfig{}
		}
		return nil, SaveSources(list)
	})

	bus.Register("danmaku.getOfficialDanmaku", func(ctx context.Context, seq int64, a map[string]any) (any, error) {
		o, ok := OfficialSource()
		return map[string]any{
			"enabled": ok,
			"name":    o.Name,
			// ★ 如实说明为什么不可用 —— 「没有」和「坏了」是两件事
			"reason": map[bool]string{
				true:  "",
				false: "这个构建没有注入弹弹Play 官方凭据(DANDANPLAY_APP_ID / DANDANPLAY_APP_SECRET)",
			}[ok],
		}, nil
	})

	bus.Register("danmaku.minAutoScore", func(ctx context.Context, seq int64, a map[string]any) (any, error) {
		return MinAutoScore, nil
	})

	// ---- 搜索 / 集表 ----
	bus.Register("danmaku.search", func(ctx context.Context, seq int64, a map[string]any) (any, error) {
		kw := strings.TrimSpace(str(a, "keyword"))
		if kw == "" {
			return nil, bus.NewErr(bus.EInvalid, "请输入搜索词")
		}
		/* ★ 粘一条 Bangumi 条目链接(或 `bgm:253`)就当片名用 —— 换成条目的官方原名再搜。
		   媒体库刮到的中文名和弹幕源收录的日文名对不上时,直接搜中文名是 0 条。
		   ☠ 换不出名字要**明说**:拿 `bgm:253` 这串去搜必然 0 条,
		     而用户看到的会是「都没搜到」,以为源坏了。 */
		if id := BgmSubjectID(kw); id > 0 {
			names := BgmTitles(ctx, id)
			if len(names) == 0 {
				return nil, bus.NewErr(bus.EUpstream, "查不到 Bangumi 条目 %d 的名字,直接输片名试试", id)
			}
			kw = names[0]
		}
		// ★ 手动搜索**不**过 AllowOfficialFor 那一关:那是用户明确要求的
		cfgs := allSources(true)
		if len(cfgs) == 0 {
			return nil, bus.NewErr(bus.EUnsupported, "还没有可用的弹幕源(去设置里添加一个)")
		}
		if hasOfficial(cfgs) {
			if err := SearchGate(); err != nil {
				return nil, &bus.Err{Code: bus.EInvalid, Msg: err.Error()}
			}
		}
		return searchAllGrouped(ctx, cfgs, kw), nil
	})

	bus.Register("danmaku.episodes", func(ctx context.Context, seq int64, a map[string]any) (any, error) {
		cfg := findSource(str(a, "source_id"))
		if cfg == nil {
			return nil, bus.NewErr(bus.ENotFound, "没有这个弹幕源")
		}
		eps, err := cfg.BangumiEpisodes(ctx, str(a, "anime_id"))
		if err != nil {
			return nil, upstream(err)
		}
		if eps == nil {
			eps = []Episode{}
		}
		return eps, nil
	})

	// ---- 匹配 ----
	bus.Register("danmaku.match", func(ctx context.Context, seq int64, a map[string]any) (any, error) {
		in, err := matchInputOf(a)
		if err != nil {
			return nil, err
		}
		cfgs := allSources(AllowOfficialFor(in.Genres))
		if len(cfgs) == 0 {
			return nil, bus.NewErr(bus.EUnsupported, "还没有可用的弹幕源")
		}
		out, err := MatchAll(ctx, cfgs, withBgmTitles(ctx, in))
		if err != nil {
			return nil, upstream(err)
		}
		return out, nil
	})

	// danmaku.autoLoad —— 起播时自动匹配 + 加载 + 过滤,一条命令走完。
	//
	// ★★ 返回 null 表示「**没有够可信的候选**」,不是失败。
	//   前端据此决定要不要提示用户手动搜 —— 抛错的话它得靠解析错误文案来分辨。
	bus.Register("danmaku.autoLoad", func(ctx context.Context, seq int64, a map[string]any) (any, error) {
		in, err := matchInputOf(a)
		if err != nil {
			return nil, err
		}
		cfgs := allSources(AllowOfficialFor(in.Genres))
		if len(cfgs) == 0 {
			return nil, nil // 没源 = 没弹幕,不是错误
		}
		// ★ 连看下一集先走接力:上一集的 id 加一,一次上游请求解决(见 relay.go)
		if items, ok := relayLoad(ctx, cfgs, in, chConvertOf(a)); ok {
			return ApplyFilterAndDedup(items, filterOptionsOf(a)), nil
		}
		cands, err := MatchAll(ctx, cfgs, withBgmTitles(ctx, in))
		if err != nil {
			return nil, upstream(err)
		}
		if len(cands) == 0 || cands[0].Score < MinAutoScore {
			// ★ 分不够就**不上屏**。硬上的话观众看到的是另一部片的弹幕,
			//   那比没有弹幕糟得多 —— 而且他不会想到是匹配错了。
			return nil, nil
		}
		best := cands[0]
		cfg := findSourceIn(cfgs, best.SourceID)
		if cfg == nil {
			return nil, nil
		}
		items, err := getCommentsCached(ctx, cfg, best.EpisodeID, chConvertOf(a))
		if err != nil {
			return nil, upstream(err)
		}
		// 取到东西才记接力点 —— 记一个空集会让下一集跟着一路错下去
		if len(items) > 0 {
			relayRemember(in, &best)
		}
		return ApplyFilterAndDedup(items, filterOptionsOf(a)), nil
	})

	// ---- 取弹幕 ----
	bus.Register("danmaku.load", func(ctx context.Context, seq int64, a map[string]any) (any, error) {
		epID := str(a, "episode_id")
		if epID == "" {
			return nil, bus.NewErr(bus.EInvalid, "缺少 episode_id")
		}
		cfg := findSource(str(a, "source_id"))
		if cfg == nil {
			return nil, bus.NewErr(bus.ENotFound, "没有这个弹幕源")
		}
		items, err := getCommentsCached(ctx, cfg, epID, chConvertOf(a))
		if err != nil {
			return nil, upstream(err)
		}
		return items, nil
	})

	bus.Register("danmaku.loadLocal", func(ctx context.Context, seq int64, a map[string]any) (any, error) {
		p := str(a, "path")
		if p == "" {
			return nil, bus.NewErr(bus.EInvalid, "缺少 path")
		}
		raw, err := os.ReadFile(p)
		if err != nil {
			return nil, bus.NewErr(bus.ENotFound, "读不了这个文件: %v", err)
		}
		items, err := ParseLocal(string(raw))
		if err != nil {
			return nil, &bus.Err{Code: bus.EInvalid, Msg: err.Error()}
		}
		return items, nil
	})

	// ---- 后处理 ----
	bus.Register("danmaku.filter", func(ctx context.Context, seq int64, a map[string]any) (any, error) {
		var items []Comment
		if raw, ok := a["comments"]; ok {
			if b, err := json.Marshal(raw); err == nil {
				_ = json.Unmarshal(b, &items)
			}
		}
		return ApplyFilterAndDedup(items, filterOptionsOf(a)), nil
	})

	// danmaku.importBlocklist 解析弹弹Play 的 XML 屏蔽表并**并进落库的那一份**。
	//
	// ☠ 上一版只解析、不落库,由调用方自己合并再存 —— 而调用方有两个(PC / 安卓),
	//   两边各写一份合并逻辑,漏掉「去重」的那一边会越导越长且不报错。
	//   合并放这里,两端各自只要发一条命令。
	bus.Register("danmaku.importBlocklist", func(ctx context.Context, seq int64, a map[string]any) (any, error) {
		r := ImportDandanplayBlocklistXML(str(a, "xml"))
		words, users := LoadBlocklist()
		words = mergeUnique(words, r.TextWords)
		users = mergeUnique(users, r.UserIDs)
		if err := SaveBlocklist(words, users); err != nil {
			return nil, bus.NewErr(bus.EInternal, "屏蔽表保存失败: %v", err)
		}
		return BlocklistImported{
			TextWords: r.TextWords, UserIDs: r.UserIDs,
			SkippedCount: r.SkippedCount,
			TotalWords:   len(words), TotalUsers: len(users),
		}, nil
	})

	// ---- 屏蔽词(落库,自动加载和手动搜索都用它)----
	bus.Register("danmaku.getBlockwords", func(ctx context.Context, seq int64, a map[string]any) (any, error) {
		words, users := LoadBlocklist()
		return Blocklist{Words: words, Users: users}, nil
	})

	bus.Register("danmaku.setBlockwords", func(ctx context.Context, seq int64, a map[string]any) (any, error) {
		words, users := LoadBlocklist()
		if v, ok := a["words"]; ok {
			words = strList(v)
		}
		if v, ok := a["users"]; ok {
			users = strList(v)
		}
		if err := SaveBlocklist(words, users); err != nil {
			return nil, bus.NewErr(bus.EInternal, "屏蔽表保存失败: %v", err)
		}
		return Blocklist{Words: words, Users: users}, nil
	})

	// ---- 缓存 ----
	bus.Register("danmaku.cacheClear", func(ctx context.Context, seq int64, a map[string]any) (any, error) {
		return CacheClear(), nil
	})
	bus.Register("danmaku.cacheSize", func(ctx context.Context, seq int64, a map[string]any) (any, error) {
		return CacheDiskSize(), nil
	})
}

// SearchGroupCap 一个源最多回多少部作品。
//
// ★ 用户 2026-09-10:「每个源最多 8 个,方便换源」。搜索面板是**用来换源的**,
// 一个源刷出四十条相似作品时,第二个源已经被顶到屏幕外面去了。
const SearchGroupCap = 8

// searchAllGrouped 并行搜所有源,**按源分组**返回。
//
// ★★ 一个源挂了**不影响别的** —— 它自己那组带 error,其余照出。
// 合成一个大列表的话,一个源 429 就把整页拖成空白。
//
// ★ 组的顺序**就是设置里的顺序**,不按结果条数重排 —— 重排的话用户在设置里
//   把常用源拖到第一位这件事等于没做。
func searchAllGrouped(ctx context.Context, cfgs []SourceConfig, keyword string) []SourceGroup {
	out := make([]SourceGroup, len(cfgs))
	var wg sync.WaitGroup
	for i := range cfgs {
		wg.Add(1)
		go func(i int) {
			defer wg.Done()
			cfg := cfgs[i]
			g := SourceGroup{SourceID: cfg.ID, SourceName: cfg.Name, Animes: []Anime{}}
			if animes, err := cfg.SearchAnime(ctx, keyword); err != nil {
				msg := err.Error()
				g.Error = &msg
			} else {
				if len(animes) > SearchGroupCap {
					animes = animes[:SearchGroupCap]
				}
				g.Animes = animes
			}
			out[i] = g
		}(i)
	}
	wg.Wait()
	return out
}

func getCommentsCached(ctx context.Context, cfg *SourceConfig, episodeID string, chConvert int) ([]Comment, error) {
	if c := CacheGet(cfg.ID, episodeID); c != nil {
		return c, nil
	}
	items, err := cfg.GetComments(ctx, episodeID, chConvert)
	if err != nil {
		return nil, err
	}
	CachePut(cfg.ID, episodeID, items)
	if items == nil {
		items = []Comment{}
	}
	return items, nil
}

func findSource(id string) *SourceConfig { return findSourceIn(allSources(true), id) }

func findSourceIn(cfgs []SourceConfig, id string) *SourceConfig {
	for i := range cfgs {
		if cfgs[i].ID == id {
			return &cfgs[i]
		}
	}
	return nil
}

func matchInputOf(a map[string]any) (*MatchInput, error) {
	raw, ok := a["input"]
	if !ok {
		return nil, bus.NewErr(bus.EInvalid, "缺少 input")
	}
	b, err := json.Marshal(raw)
	if err != nil {
		return nil, bus.NewErr(bus.EInvalid, "input 解析失败: %v", err)
	}
	in := &MatchInput{}
	if json.Unmarshal(b, in) != nil {
		return nil, bus.NewErr(bus.EInvalid, "input 形状不对")
	}
	if strings.TrimSpace(in.Title) == "" {
		return nil, bus.NewErr(bus.EInvalid, "input.title 不能为空")
	}
	return in, nil
}

// filterOptionsOf 从命令参数里取后处理选项。
//
// ★ **先造默认再往上盖**:直接解进零值结构体的话去重窗口会变成 0,
// 开了去重跟没开一样(本仓最常见的移植坑,见 config/prefs.go 的包注释)。
//
// ☠ **落库的屏蔽词无条件并进来**,不管调用方传没传 options。
//   靠调用方传的话,漏传的那条路径不报错、只是屏蔽词没生效 ——
//   而用户会以为是词写错了,然后去改一个本来就对的词。
func filterOptionsOf(a map[string]any) FilterOptions {
	opts := DefaultFilterOptions()
	if raw, ok := a["options"]; ok {
		if b, err := json.Marshal(raw); err == nil {
			_ = json.Unmarshal(b, &opts)
		}
	}
	if opts.DedupWindow <= 0 {
		opts.DedupWindow = 10.0
	}
	words, users := LoadBlocklist()
	opts.Blockwords = mergeUnique(opts.Blockwords, words)
	opts.UserBlocklist = mergeUnique(opts.UserBlocklist, users)
	return opts
}

// mergeUnique 并集,保持 a 的顺序。
func mergeUnique(a, b []string) []string {
	seen := map[string]bool{}
	out := []string{}
	for _, s := range append(append([]string{}, a...), b...) {
		if s == "" || seen[s] {
			continue
		}
		seen[s] = true
		out = append(out, s)
	}
	return out
}

// strList 把命令参数里的一个数组读成字符串表。非字符串项丢掉。
func strList(v any) []string {
	arr, ok := v.([]any)
	if !ok {
		return []string{}
	}
	out := make([]string, 0, len(arr))
	for _, it := range arr {
		if s, ok := it.(string); ok && s != "" {
			out = append(out, s)
		}
	}
	return out
}

func chConvertOf(a map[string]any) int {
	if v, ok := a["ch_convert"].(float64); ok {
		return int(v)
	}
	return 0
}

func upstream(err error) error {
	return &bus.Err{Code: bus.EUpstream, Msg: err.Error(), Retryable: true}
}

func str(a map[string]any, k string) string {
	if v, ok := a[k].(string); ok {
		return v
	}
	return ""
}

var _ = fmt.Sprintf
