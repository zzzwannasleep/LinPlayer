// Package sourcecmd 是 `source.*` 命令层:文件浏览型源的登录 / 浏览 / 搜索 / 播放。
//
// ★ 为什么不放在 core/source 里:那个包被每个后端(local / webdav / …)导入,
// 而命令层要导入**所有后端**去注册 —— 放一起就是导入环。
//
// ★★ 活跃源**从配置里现算**,不另存一份内存状态。
// 黄金实现那边是 `state.source` 一个互斥量,和账号表并存 —— 两份状态就有两份真相:
// 切服务器改了账号表而没改那个互斥量,表现是「切过去了,浏览的还是上一个源」。
package sourcecmd

import (
	"context"
	"encoding/json"
	"fmt"
	"net/http"
	"strings"

	"linplayer/core/bus"
	"linplayer/core/config"
	"linplayer/core/httpx"
	"linplayer/core/player"
	"linplayer/core/source"
	"linplayer/core/source/local"
)

// RegisterCommands 由 core/commands 调用。
func RegisterCommands() {
	registerBackends()

	registerFormSchema()
	bus.Register("source.currentSource", cmdCurrentSource)
	bus.Register("source.login", cmdLogin)
	bus.Register("source.listDir", cmdListDir)
	bus.Register("source.search", cmdSearch)
	bus.Register("source.play", cmdPlay)
	bus.Register("source.watchdog", cmdWatchdog)

	// 影视目录三条:只有资源站那类源实现,别的源一律「没这个能力」。
	bus.Register("source.categories", cmdCategories)
	bus.Register("source.catalog", cmdCatalog)
	bus.Register("source.mediaDetail", cmdMediaDetail)

}

// registerBackends 登记已移植的后端。
//
// ★ 还没移植的源(网盘系、SMB、FTP、资源站)**不在这里**。
// 它们对应的账号在配置里照样留着(config 那边 rest 原样透传),
// 只是暂时点不开 —— 而不是「升级之后账号没了」。
func registerBackends() {
	source.Register(local.New())
}

// ---------------------------------------------------------------------------
// 活跃源
// ---------------------------------------------------------------------------

// activeSource 当前活跃的浏览型源。
//
// ★ 从**账号表**现算:活跃账号是浏览型源时才算数。
func activeSource() (source.Kind, *source.Server, error) {
	a := config.Current().ActiveAccount()
	if a == nil || !a.IsFileBrowse() {
		return "", nil, bus.NewErr(bus.EAuth, "当前没有已登录的文件源")
	}
	kind := source.Kind(a.SourceKind())
	srv := sourceServerOf(*a)
	if srv == nil {
		// 账号在、但 source 那段没了(手改配置 / 老版本写的)
		return "", nil, bus.NewErr(bus.EAuth, "这个源的连接信息不完整,请重新登录一次")
	}
	return kind, srv, nil
}

// backendFor 取后端。没有就说清楚是「还没支持」而不是一句「失败」。
func backendFor(k source.Kind) (source.Backend, error) {
	b, ok := source.Get(k)
	if !ok {
		return nil, bus.NewErr(bus.EUnsupported, "这个版本还不支持 %s 这种源", k)
	}
	return b, nil
}

// sourceServerOf 从账号里取出源的连接信息(存在 `source` 这个键里)。
func sourceServerOf(a config.Account) *source.Server {
	raw := a.RestValue("source")
	if len(raw) == 0 {
		return nil
	}
	var s source.Server
	if json.Unmarshal(raw, &s) != nil {
		return nil
	}
	if s.ID == "" {
		s.ID = a.Server
	}
	return &s
}

// client 源请求用的 HTTP 客户端。
//
// ★ 走**第三方那条道**的 UA,不是 Emby 那条:网盘和 NAS 不是 Emby,
// 拿 LinPlayer/{版本} 去打它们只会让服务端日志分不清来路。
func client() *http.Client { return httpx.Client() }

// ---------------------------------------------------------------------------
// 命令
// ---------------------------------------------------------------------------

func cmdCurrentSource(ctx context.Context, seq int64, a map[string]any) (any, error) {
	acc := config.Current().ActiveAccount()
	if acc == nil || !acc.IsFileBrowse() {
		return nil, nil // 不是错误:当前就是没有源
	}
	return map[string]any{
		"server_id":      acc.Server,
		"server_name":    acc.DisplayName(),
		"user_name":      acc.UserName,
		"source_kind":    acc.SourceKind(),
		"is_file_browse": true,
		"active":         true,
	}, nil
}

func cmdLogin(ctx context.Context, seq int64, a map[string]any) (any, error) {
	kind := source.Kind(str(a, "kind"))
	if kind == "" {
		return nil, bus.NewErr(bus.EInvalid, "缺少 kind")
	}
	baseURL := strings.TrimSpace(str(a, "base_url"))
	username, password := str(a, "username"), str(a, "password")
	cookie := str(a, "cookie")

	// ★ 夸克 Cookie 模式**没有 base_url**(固定云端 API),用 kind 名做稳定 id。
	//   这个字符串的形状不能改:老账号已经拿它当主键存在用户配置里了。
	id := baseURL
	if id == "" {
		id = kind.LegacyDebugLabel()
	}

	srv := &source.Server{ID: id, BaseURL: baseURL, Extra: map[string]string{}}
	if username != "" {
		srv.Username = &username
	}
	if password != "" {
		srv.Password = &password
	}
	if cookie != "" {
		srv.Token = &cookie
	}
	if ex, ok := a["extra"].(map[string]any); ok {
		for k, v := range ex {
			if s, ok := v.(string); ok {
				srv.Extra[k] = s
			}
		}
	}

	b, err := backendFor(kind)
	if err != nil {
		return nil, err
	}
	// 验证这个源确实能用。探测口径(为什么不能只试 ListDir)见 source.ProbeBackend。
	if err := source.ProbeBackend(ctx, b, client(), srv); err != nil {
		return nil, classify(err)
	}

	// 落盘:源和 Emby **共用同一张账号表** —— 重启免登 + 多源并存全靠这一步。
	c := config.Current()
	acc := config.Account{Server: srv.ID, UserName: username}
	if acc.UserName == "" {
		acc.UserName = kind.LegacyDebugLabel()
	}
	acc.SetRestValue("source_kind", string(kind))
	acc.SetRestValue("source", srv)
	c.Upsert(acc)
	if err := c.Save(); err != nil {
		return nil, bus.NewErr(bus.EInternal, "配置保存失败: %v", err)
	}
	return nil, nil
}

func cmdListDir(ctx context.Context, seq int64, a map[string]any) (any, error) {
	kind, srv, err := activeSource()
	if err != nil {
		return nil, err
	}
	b, err := backendFor(kind)
	if err != nil {
		return nil, err
	}
	out, err := b.ListDir(ctx, client(), srv, str(a, "dir_id"))
	persistRotated(b, srv)
	if err != nil {
		return nil, classify(err)
	}
	if out == nil {
		out = []source.Entry{} // 空目录是 [] 不是 null(前端 .map() 会抛)
	}
	return out, nil
}

func cmdSearch(ctx context.Context, seq int64, a map[string]any) (any, error) {
	kind, srv, err := activeSource()
	if err != nil {
		return nil, err
	}
	b, err := backendFor(kind)
	if err != nil {
		return nil, err
	}
	s, ok := b.(source.Searcher)
	if !ok {
		// ★ 「这个源没有源端搜索」不是故障。前端据此**退回当前目录本地过滤**,
		//   所以这里必须是一条能被认出来的错误,不能是空数组
		//   —— 回空数组的话前端会以为「搜过了,没搜到」。
		return nil, classify(source.Unsupported())
	}
	out, err := s.Search(ctx, client(), srv, str(a, "query"))
	persistRotated(b, srv)
	if err != nil {
		return nil, classify(err)
	}
	if out == nil {
		out = []source.Entry{}
	}
	return out, nil
}

func cmdPlay(ctx context.Context, seq int64, a map[string]any) (any, error) {
	kind, srv, err := activeSource()
	if err != nil {
		return nil, err
	}
	b, err := backendFor(kind)
	if err != nil {
		return nil, err
	}
	entryID := str(a, "entry_id")
	if entryID == "" {
		return nil, bus.NewErr(bus.EInvalid, "缺少 entry_id")
	}
	e := &source.Entry{ID: entryID, Name: str(a, "entry_name"), IsVideo: true}
	// raw 透传源原始数据(ani-rss 的外挂字幕等靠它)
	if raw, ok := a["raw"]; ok && raw != nil {
		if bs, err := json.Marshal(raw); err == nil {
			e.Raw = bs
		}
	}
	resolved, err := b.ResolvePlay(ctx, client(), srv, e, "")
	persistRotated(b, srv)
	if err != nil {
		return nil, classify(err)
	}

	ua := ""
	if resolved.UserAgentOverride != nil {
		ua = *resolved.UserAgentOverride
	}
	subs := make([]embySub, 0, len(resolved.Subtitles))
	for _, s := range resolved.Subtitles {
		t := "字幕"
		if s.Title != nil && *s.Title != "" {
			t = *s.Title
		}
		subs = append(subs, embySub{URL: s.URL, Title: t})
	}
	return player.PlaySource(resolved.URL, e.Name, num(a, "resume_secs"),
		resolved.HTTPHeaders, ua, toEmbySubs(subs))
}

// cmdWatchdog 直链过期看门狗:播放层每隔一阵问一次「这条流还活着吗」。
//
// ★ 返回 true = 重新解析并换了地址。**必须带上 entry**:
// 黄金实现在安卓侧就是因为起播时没把 (entry_id, entry_name) 记下来,
// 这条看门狗**永远是死的** —— 直链一过期就卡住,而且不报错。
func cmdWatchdog(ctx context.Context, seq int64, a map[string]any) (any, error) {
	// 目前已移植的两个后端(本地 / WebDAV)都是**长效地址**:
	// 本地是裸路径,WebDAV 是固定 URL + 每次带 Basic。都不会过期,所以恒 false。
	// 等短效签名链的网盘后端落地时,这里按 kind 分派。
	return false, nil
}

func cmdCategories(ctx context.Context, seq int64, a map[string]any) (any, error) {
	cat, _, srv, err := activeCataloger()
	if err != nil {
		return nil, err
	}
	out, err := cat.Categories(ctx, client(), srv)
	if err != nil {
		return nil, classify(err)
	}
	if out == nil {
		out = []source.MediaCategory{}
	}
	return out, nil
}

func cmdCatalog(ctx context.Context, seq int64, a map[string]any) (any, error) {
	cat, _, srv, err := activeCataloger()
	if err != nil {
		return nil, err
	}
	page := uint32(num(a, "page"))
	if page == 0 {
		page = 1
	}
	out, err := cat.Catalog(ctx, client(), srv, str(a, "category_id"), str(a, "keyword"), page)
	if err != nil {
		return nil, classify(err)
	}
	return out, nil
}

func cmdMediaDetail(ctx context.Context, seq int64, a map[string]any) (any, error) {
	cat, _, srv, err := activeCataloger()
	if err != nil {
		return nil, err
	}
	id := str(a, "id")
	if id == "" {
		return nil, bus.NewErr(bus.EInvalid, "缺少 id")
	}
	out, err := cat.MediaDetailOf(ctx, client(), srv, id)
	if err != nil {
		return nil, classify(err)
	}
	return out, nil
}

func activeCataloger() (source.Cataloger, source.Kind, *source.Server, error) {
	kind, srv, err := activeSource()
	if err != nil {
		return nil, "", nil, err
	}
	b, err := backendFor(kind)
	if err != nil {
		return nil, "", nil, err
	}
	cat, ok := b.(source.Cataloger)
	if !ok {
		return nil, "", nil, classify(source.UnsupportedFeature("影视目录"))
	}
	return cat, kind, srv, nil
}

// ---------------------------------------------------------------------------
// 辅助
// ---------------------------------------------------------------------------

// persistRotated 后端轮换出的新凭据**落盘**。
//
// ★★ 不做这件事的后果:阿里云盘 / 天翼189 的 refresh_token 是**一次性的**,
// 刷新一次旧值当场作废。会话内因为有内存缓存看不出问题,一重启就拿着死 token 去刷
// —— 表现为「用得好好的,重开就要重新授权」,而且不会报任何错。
func persistRotated(b source.Backend, srv *source.Server) {
	r, ok := b.(source.CredentialRotator)
	if !ok {
		return
	}
	updates := r.TakeRotatedCredentials(srv.ID)
	if len(updates) == 0 {
		return
	}
	if srv.Extra == nil {
		srv.Extra = map[string]string{}
	}
	for k, v := range updates {
		srv.Extra[k] = v
	}
	c := config.Current()
	if acc := c.Find(srv.ID); acc != nil {
		acc.SetRestValue("source", srv)
		if err := c.Save(); err != nil {
			bus.Logf("warn", "轮换凭据落盘失败(重启后可能要重新授权): %v", err)
		}
	}
}

// classify 把源错误翻成总线错误码。
//
// ★ 鉴权失效要走 E_AUTH:UI 据此引导**重新登录**,而不是提示「检查网络」。
// ★ 「没这个能力」保留原文(带 __LP_UNSUPPORTED__ 前缀),前端据此静默退回另一条路。
func classify(err error) error {
	if err == nil {
		return nil
	}
	if source.IsAuthErr(err) {
		return &bus.Err{Code: bus.EAuth, Msg: err.Error()}
	}
	if source.IsUnsupported(err) {
		return &bus.Err{Code: bus.EUnsupported, Msg: err.Error()}
	}
	return &bus.Err{Code: bus.EUpstream, Msg: err.Error(), Retryable: true}
}

func str(a map[string]any, k string) string {
	if v, ok := a[k].(string); ok {
		return v
	}
	return ""
}

func num(a map[string]any, k string) float64 {
	switch v := a[k].(type) {
	case float64:
		return v
	case int64:
		return float64(v)
	}
	return 0
}

var _ = fmt.Sprintf
