// Package pluginsrc 是插件数据源桥:把插件的几个 JS 函数转发成 source.Backend。
//
// 这是整个插件系统 v2 的承重梁。`source.Backend` 只有两个必需方法,却什么都塞得进去:
// 网盘用它扛「目录树 → 直链」,局域网源用它扛 SMB/WebDAV,资源站插件用它扛
// 「分类 → 详情 → 分集」——**接口够用是实测过的,不是推断的**。
// 把它原样开放给 JS,插件作者写三个函数就白拿:浏览页 / 搜索 / 播放 / 外挂字幕 /
// 多清晰度 / 跨服聚合,零新页面零新命令。
//
// 插件侧:
//
//	ctx.sources.register("mysrc", {
//	  async listDir(dirId, server)                { return [entry, ...] },
//	  async search(query, server)                 { throw ctx.errors.unsupported() },
//	  async resolvePlay(entry, qualityId, server) { return { url, title, ... } },
//	})
//
// **网络走插件自己的 ctx.http**(受域名白名单 + $sourceServer 约束),
// 不把宿主的 http.Client 借给它 —— 借了等于绕过整套白名单。
package pluginsrc

import (
	"context"
	"encoding/json"
	"fmt"
	"net/http"
	"strings"

	"linplayer/core/plugin"
	"linplayer/core/source"
)

// Backend 一个插件贡献的数据源。
type Backend struct {
	pluginID string
	srcID    string
	mgr      *plugin.Manager
}

// New 造一个桥。
func New(pluginID, srcID string, mgr *plugin.Manager) *Backend {
	return &Backend{pluginID: pluginID, srcID: srcID, mgr: mgr}
}

// Kind 源类型:`plugin:<插件id>/<源id>`。
func (b *Backend) Kind() source.Kind { return source.PluginKind(b.pluginID, b.srcID) }

func (b *Backend) call(method string, args []any) (any, error) {
	if b.mgr == nil {
		return nil, source.Msg("插件系统未初始化")
	}
	out, err := b.mgr.CallSource(b.pluginID, b.srcID, method, args)
	if err != nil {
		return nil, jsErrorToSourceError(err.Error())
	}
	return out, nil
}

// jsErrorToSourceError 把插件抛出的 JS 异常还原成 source.Error。
//
// ★★ ctx.errors.unsupported() 带特征前缀 —— 它表示「这个源没有这个能力」,
// UI 该退回本地过滤,而不是弹一条红色报错。两者混为一谈的话,每个不支持搜索的
// 插件源都会在用户每次搜索时糊一脸错误。
func jsErrorToSourceError(msg string) error {
	if i := strings.Index(msg, plugin.UnsupportedMarker); i >= 0 {
		detail := strings.TrimSpace(msg[i+len(plugin.UnsupportedMarker):])
		if detail == "" {
			return source.Unsupported()
		}
		return &source.Error{Message: detail, Unsupported: true}
	}
	// 鉴权失效要能被 UI 认出来并引导重登。插件用文案表达,这里做关键词识别。
	lowered := strings.ToLower(msg)
	if strings.Contains(lowered, "401") || strings.Contains(lowered, "unauthorized") ||
		strings.Contains(msg, "登录") {
		return source.Auth("%s", msg)
	}
	return source.Msg("%s", msg)
}

// serverForJS 下发给插件的服务器信息。
//
// ★ **只给连接必需的字段**,不整包丢过去 —— source.Server 将来加字段时,
// 不该自动流进所有插件。
func serverForJS(s *source.Server) any {
	if s == nil {
		return nil
	}
	deref := func(p *string) any {
		if p == nil {
			return nil
		}
		return *p
	}
	extra := map[string]any{}
	for k, v := range s.Extra {
		extra[k] = v
	}
	return map[string]any{
		"id": s.ID, "baseUrl": s.BaseURL,
		"username": deref(s.Username), "password": deref(s.Password),
		"token": deref(s.Token), "extra": extra,
	}
}

func s(v map[string]any, k string) *string {
	raw, has := v[k]
	if !has {
		return nil
	}
	var out string
	switch t := raw.(type) {
	case string:
		out = t
	case float64:
		out = fmt.Sprintf("%g", t)
	default:
		return nil
	}
	if strings.TrimSpace(out) == "" {
		return nil
	}
	return &out
}

func sv(v map[string]any, k string) string {
	if p := s(v, k); p != nil {
		return *p
	}
	return ""
}

func rawOf(v map[string]any, k string) json.RawMessage {
	x, has := v[k]
	if !has || x == nil {
		return nil
	}
	b, err := json.Marshal(x)
	if err != nil {
		return nil
	}
	return b
}

// entryFromJS JS 返回的一行 -> source.Entry。
//
// ★ isVideo 允许插件不填 —— 缺省按宿主那份扩展名表自动判定。插件各自维护一份
// 必然漂移,漂移的后果是「某种格式在内置源能播、在插件源里根本不显示」。
func entryFromJS(v map[string]any) (source.Entry, bool) {
	id := sv(v, "id")
	if id == "" {
		return source.Entry{}, false
	}
	name := sv(v, "name")
	if name == "" {
		name = id
	}
	isDir, _ := v["isDir"].(bool)
	isVideo, hasIsVideo := v["isVideo"].(bool)
	if !hasIsVideo {
		isVideo = !isDir && source.IsVideoFileName(name)
	}
	e := source.Entry{ID: id, Name: name, IsDir: isDir, IsVideo: isVideo, Raw: rawOf(v, "raw")}
	if f, ok := v["size"].(float64); ok {
		n := int64(f)
		e.Size = &n
	}
	if t := s(v, "thumb"); t != nil {
		e.ThumbURL = t
	} else if t := s(v, "thumbUrl"); t != nil {
		e.ThumbURL = t
	}
	return e, true
}

// entriesFromJS 逐条跳过畸形项而不是整页失败 —— 一条缺 id 的记录不该让整个目录打不开。
func entriesFromJS(out any) ([]source.Entry, error) {
	arr, ok := out.([]any)
	if !ok {
		return nil, source.Msg("插件数据源必须返回数组")
	}
	list := []source.Entry{}
	for _, it := range arr {
		m, ok := it.(map[string]any)
		if !ok {
			continue
		}
		if e, ok := entryFromJS(m); ok {
			list = append(list, e)
		}
	}
	return list, nil
}

func headersFromJS(v any) map[string]string {
	out := map[string]string{}
	m, ok := v.(map[string]any)
	if !ok {
		return out
	}
	for k, val := range m {
		switch t := val.(type) {
		case string:
			out[k] = t
		default:
			b, _ := json.Marshal(t)
			out[k] = string(b)
		}
	}
	return out
}

// ListDir 列目录。
func (b *Backend) ListDir(ctx context.Context, _ *http.Client, srv *source.Server, dirID string) ([]source.Entry, error) {
	var arg any
	if dirID != "" {
		arg = dirID
	}
	out, err := b.call("listDir", []any{arg, serverForJS(srv)})
	if err != nil {
		return nil, err
	}
	return entriesFromJS(out)
}

// Search 源内搜索。
//
// ★ 插件没实现 search 这个字段时,handler 派发返回 nil(不是报错)。
// 那等同于「不支持」,让 UI 退回本地过滤 —— 而不是当成一次空结果,
// 否则用户会以为搜到了 0 条。
func (b *Backend) Search(ctx context.Context, _ *http.Client, srv *source.Server, query string) ([]source.Entry, error) {
	out, err := b.call("search", []any{query, serverForJS(srv)})
	if err != nil {
		return nil, err
	}
	if out == nil {
		return nil, source.Unsupported()
	}
	return entriesFromJS(out)
}

// ResolvePlay 把文件解析成可播单元(含取流所需 headers)。
func (b *Backend) ResolvePlay(ctx context.Context, _ *http.Client, srv *source.Server,
	e *source.Entry, qualityID string) (*source.ResolvedPlay, error) {

	entryJS := map[string]any{
		"id": e.ID, "name": e.Name, "isDir": e.IsDir, "isVideo": e.IsVideo,
	}
	if e.Size != nil {
		entryJS["size"] = float64(*e.Size)
	}
	if len(e.Raw) > 0 {
		var raw any
		if json.Unmarshal(e.Raw, &raw) == nil {
			entryJS["raw"] = raw
		}
	}
	var q any
	if qualityID != "" {
		q = qualityID
	}
	out, err := b.call("resolvePlay", []any{entryJS, q, serverForJS(srv)})
	if err != nil {
		return nil, err
	}
	m, ok := out.(map[string]any)
	if !ok {
		return nil, source.Msg("插件未实现 resolvePlay")
	}
	return resolvedFromJS(m, e.Name)
}

func resolvedFromJS(v map[string]any, fallbackTitle string) (*source.ResolvedPlay, error) {
	url := sv(v, "url")
	if url == "" {
		return nil, source.Msg("插件未返回可播放地址(url)")
	}
	title := sv(v, "title")
	if title == "" {
		title = fallbackTitle
	}
	out := source.ResolvedPlay{
		URL: url, Title: title, HTTPHeaders: headersFromJS(v["httpHeaders"]),
		Subtitles: []source.Subtitle{}, Qualities: []source.PlayQuality{},
	}
	out.UserAgentOverride = s(v, "userAgent")
	if arr, ok := v["subtitles"].([]any); ok {
		for _, it := range arr {
			m, ok := it.(map[string]any)
			if !ok {
				continue
			}
			u := sv(m, "url")
			if u == "" {
				continue
			}
			out.Subtitles = append(out.Subtitles, source.Subtitle{
				URL: u, Title: s(m, "title"), Language: s(m, "language"),
				HTTPHeaders: headersFromJS(m["httpHeaders"]),
			})
		}
	}
	if arr, ok := v["qualities"].([]any); ok {
		for _, it := range arr {
			m, ok := it.(map[string]any)
			if !ok {
				continue
			}
			id := sv(m, "id")
			if id == "" {
				continue
			}
			label := sv(m, "label")
			if label == "" {
				label = id
			}
			rank := 0
			if f, ok := m["rank"].(float64); ok {
				rank = int(f)
			}
			out.Qualities = append(out.Qualities, source.PlayQuality{ID: id, Label: label, Rank: rank})
		}
	}
	if q := s(v, "quality"); q != nil {
		out.SelectedQualityID = q
	} else if q := s(v, "selectedQualityId"); q != nil {
		out.SelectedQualityID = q
	}
	return &out, nil
}

// ── 影视目录能力 ─────────────────────────────────────────────────────────
//
// 插件没实现对应字段时 handler 派发返回 nil(不是抛错),那等同于「不支持」——
// 必须还原成 unsupported,否则前端会把「这个源是网盘」当成「这个源坏了」。
//
// 一律「缺字段就留空」而不是报错:插件少填一个 year 不该让整页打不开。

// Categories 分类树。
func (b *Backend) Categories(ctx context.Context, _ *http.Client, srv *source.Server) ([]source.MediaCategory, error) {
	out, err := b.call("categories", []any{serverForJS(srv)})
	if err != nil {
		return nil, err
	}
	if out == nil {
		return nil, source.UnsupportedFeature("影视目录")
	}
	arr, ok := out.([]any)
	if !ok {
		return nil, source.Msg("categories 必须返回数组")
	}
	return categoriesFromJS(arr), nil
}

func categoriesFromJS(arr []any) []source.MediaCategory {
	out := []source.MediaCategory{}
	for _, it := range arr {
		m, ok := it.(map[string]any)
		if !ok {
			continue
		}
		id := sv(m, "id")
		if id == "" {
			continue
		}
		name := sv(m, "name")
		if name == "" {
			name = id
		}
		children := []source.MediaCategory{}
		if kids, ok := m["children"].([]any); ok {
			children = categoriesFromJS(kids)
		}
		out = append(out, source.MediaCategory{ID: id, Name: name, Children: children})
	}
	return out
}

func cardFromJS(m map[string]any) (source.MediaCard, bool) {
	id := sv(m, "id")
	if id == "" {
		return source.MediaCard{}, false
	}
	title := sv(m, "title")
	if title == "" {
		title = id
	}
	isSeries, _ := m["isSeries"].(bool)
	return source.MediaCard{
		ID: id, Title: title, Poster: s(m, "poster"), Badge: s(m, "badge"),
		Year: s(m, "year"), Score: s(m, "score"), IsSeries: isSeries,
	}, true
}

// Catalog 目录的一页。
func (b *Backend) Catalog(ctx context.Context, _ *http.Client, srv *source.Server,
	categoryID, keyword string, page uint32) (*source.MediaPage, error) {

	req := map[string]any{"page": float64(page)}
	if categoryID != "" {
		req["categoryId"] = categoryID
	}
	if keyword != "" {
		req["keyword"] = keyword
	}
	out, err := b.call("catalog", []any{req, serverForJS(srv)})
	if err != nil {
		return nil, err
	}
	if out == nil {
		return nil, source.UnsupportedFeature("影视目录")
	}
	m, ok := out.(map[string]any)
	if !ok {
		return nil, source.Msg("catalog 必须返回 { items: [...] }")
	}
	arr, ok := m["items"].([]any)
	if !ok {
		return nil, source.Msg("catalog 必须返回 { items: [...] }")
	}
	items := []source.MediaCard{}
	for _, it := range arr {
		cm, ok := it.(map[string]any)
		if !ok {
			continue
		}
		if c, ok := cardFromJS(cm); ok {
			items = append(items, c)
		}
	}
	// ★ 插件没明说就按「还有」处理会让前端无限拉空页;默认 false 更安全。
	hasMore, _ := m["hasMore"].(bool)
	pg := &source.MediaPage{Items: items, Page: page, HasMore: hasMore}
	if f, ok := m["total"].(float64); ok && f >= 0 {
		t := uint32(f)
		pg.Total = &t
	}
	return pg, nil
}

// MediaDetailOf 一部片的详情。
func (b *Backend) MediaDetailOf(ctx context.Context, _ *http.Client, srv *source.Server, id string) (*source.MediaDetail, error) {
	out, err := b.call("mediaDetail", []any{id, serverForJS(srv)})
	if err != nil {
		return nil, err
	}
	if out == nil {
		return nil, source.UnsupportedFeature("影视目录")
	}
	m, ok := out.(map[string]any)
	if !ok {
		return nil, source.Msg("mediaDetail 必须返回对象")
	}
	return detailFromJS(m, id), nil
}

func detailFromJS(v map[string]any, fallbackID string) *source.MediaDetail {
	id := sv(v, "id")
	if id == "" {
		id = fallbackID
	}
	d := &source.MediaDetail{
		ID: id, Title: sv(v, "title"),
		Poster: s(v, "poster"), Badge: s(v, "badge"), Year: s(v, "year"),
		Area: s(v, "area"), Lang: s(v, "lang"), Genre: s(v, "genre"),
		Score: s(v, "score"), Overview: s(v, "overview"),
		Actors: s(v, "actors"), Director: s(v, "director"),
		Lines: []source.MediaLine{},
	}
	arr, _ := v["lines"].([]any)
	for _, it := range arr {
		lm, ok := it.(map[string]any)
		if !ok {
			continue
		}
		lid := sv(lm, "id")
		if lid == "" {
			continue
		}
		lname := sv(lm, "name")
		if lname == "" {
			lname = lid
		}
		line := source.MediaLine{ID: lid, Name: lname, Episodes: []source.MediaEpisode{}}
		eps, _ := lm["episodes"].([]any)
		for _, e := range eps {
			em, ok := e.(map[string]any)
			if !ok {
				continue
			}
			eid := sv(em, "id")
			if eid == "" {
				continue
			}
			ename := sv(em, "name")
			if ename == "" {
				ename = eid
			}
			line.Episodes = append(line.Episodes, source.MediaEpisode{
				ID: eid, Name: ename, Raw: rawOf(em, "raw"),
			})
		}
		d.Lines = append(d.Lines, line)
	}
	return d
}

// Sync 把管理器当前注册的插件数据源同步进 source 分派表。
//
// ★ **整体同步而不是只加不减**:插件禁用/卸载后它的源必须立刻从分派表消失,
// 否则播放链路还能查到一个背后没有引擎的后端。
func Sync(mgr *plugin.Manager) {
	if mgr == nil {
		return
	}
	want := map[source.Kind]bool{}
	for _, t := range mgr.DataSources() {
		k := source.PluginKind(t[0], t[1])
		want[k] = true
		source.Register(New(t[0], t[1], mgr))
	}
	for _, k := range source.Kinds() {
		if k.IsPlugin() && !want[k] {
			source.Unregister(k)
		}
	}
}
