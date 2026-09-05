package emby

// 本包自己注册 `emby.*`。命令归属跟着实现走(理由见 core/player/commands.go)。

import (
	"context"
	"crypto/x509"
	"encoding/json"
	"errors"
	"net/http"
	"strings"
	"time"

	"linplayer/core/blocklist"
	"linplayer/core/bus"
	"linplayer/core/config"
	"linplayer/core/net/localserve"
	"linplayer/core/net/tlspolicy"
	"linplayer/core/serverbatch"
)

var defaultClient *Client

// Default 给同仓别的包用的那份客户端(批量添加服务器要逐线路试登录)。
//
// ★ 不另建一个:另建的那份不带同一套 UA / 代理 / TLS 白名单,
// 表现是「单独加服务器能连,批量加就连不上」。
func Default() *Client { return defaultClient }

// ProbeName 探服务器名。**探失败不算错**,返回空串由调用方回落 ——
// 有的 fork 根本没有这个端点,名字是锦上添花,加服务器是刚需。
func ProbeName(ctx context.Context, server string) string {
	if defaultClient == nil {
		return ""
	}
	pctx, cancel := context.WithTimeout(ctx, serverNameTimeout)
	defer cancel()
	info, err := defaultClient.ProbeServer(pctx, server)
	if err != nil || info == nil {
		return ""
	}
	return strings.TrimSpace(info.Name)
}

// OnPlayedChanged 手动标记「已看 / 未看」成功之后的回调。
//
// ★ 存在的理由只有一个:**打破包依赖环**。`core/history` import 了本包
// (它要 emby.Item 才折得出观看记录候选),所以本包不能反过来 import 它。
// 由 history.RegisterCommands 在启动时填上。
var OnPlayedChanged func(ctx context.Context, s *Session, itemID string, played bool)

// RegisterCommands 由 lp_init 调用。
func RegisterCommands(version string) {
	defaultClient = NewClient(version)

	// list 把「取会话 → 调实现 → 网络错误归到可重试」这段样板收成一处。
	// 网络错误是**可重试**的 —— UI 据此显示「重试」而不是「重新登录」(SPEC §5.4)
	list := func(name string, fn func(context.Context, *Session, map[string]any) (any, error)) {
		bus.Register(name, func(ctx context.Context, seq int64, args map[string]any) (any, error) {
			s, err := sessionFrom(args)
			if err != nil {
				return nil, err
			}
			out, err := fn(ctx, s, args)
			if err != nil {
				return nil, classify(err)
			}
			return out, nil
		})
	}

	list("emby.views", func(ctx context.Context, s *Session, a map[string]any) (any, error) {
		v, err := defaultClient.Views(ctx, s)
		if err != nil {
			return nil, err
		}
		/* 屏蔽掉的媒体库不出现在**列表里**(首页的媒体库轨、各库「最新」行、侧栏)。
		   ★ 缺省过滤,`include_blocked=true` 才给全量 —— 只有媒体库页那份列表要全量:
		     它是唯一能把库找回来解除屏蔽的地方,滤掉就成了单向门。
		   ★ 这里**不走**条目那条屏蔽判定(它按 series_id / 名字比):
		     库没有 series_id,而「名字对得上」在库上是错的判据 —— 两台服务器上都叫
		     「电影」的库是两个不同的库,按名字判会一屏两台一起屏蔽。 */
		inc, _ := a["include_blocked"].(bool)
		return FilterBlockedLibraries(v, inc), nil
	})
	list("emby.listLatest", func(ctx context.Context, s *Session, a map[string]any) (any, error) {
		return defaultClient.Latest(ctx, s, str(a, "parent_id"), intArg(a, "limit", 16))
	})
	list("emby.listResume", func(ctx context.Context, s *Session, a map[string]any) (any, error) {
		return defaultClient.Resume(ctx, s, intArg(a, "limit", 12))
	})
	list("emby.listNextUp", func(ctx context.Context, s *Session, a map[string]any) (any, error) {
		return defaultClient.NextUp(ctx, s, intArg(a, "limit", 12))
	})
	list("emby.listFavorites", func(ctx context.Context, s *Session, a map[string]any) (any, error) {
		return defaultClient.Favorites(ctx, s)
	})
	list("emby.listCollections", func(ctx context.Context, s *Session, a map[string]any) (any, error) {
		return defaultClient.Collections(ctx, s)
	})
	list("emby.listItemsPage", func(ctx context.Context, s *Session, a map[string]any) (any, error) {
		q := &ItemQuery{}
		if raw, ok := a["query"]; ok {
			b, _ := json.Marshal(raw)
			_ = json.Unmarshal(b, q)
		}
		return defaultClient.Items(ctx, s, str(a, "parent_id"), q)
	})

	// ---- 详情页那条链 ----
	list("emby.itemDetail", func(ctx context.Context, s *Session, a map[string]any) (any, error) {
		id := str(a, "item_id")
		if id == "" {
			return nil, bus.NewErr(bus.EInvalid, "缺少 item_id")
		}
		// ★ 桌面/TV 传 true(一屏铺完所有集),**手机端传 false**(按季分页拉)。
		//   实测最长的剧全量拉 1.8MB/1841ms,分页 30 条 20KB/435ms。
		wc, _ := a["with_children"].(bool)
		return defaultClient.Detail(ctx, s, id, wc)
	})
	list("emby.seriesSeasons", func(ctx context.Context, s *Session, a map[string]any) (any, error) {
		return defaultClient.Seasons(ctx, s, str(a, "series_id"))
	})
	list("emby.seasonEpisodes", func(ctx context.Context, s *Session, a map[string]any) (any, error) {
		return defaultClient.SeasonEpisodes(ctx, s, str(a, "parent_id"),
			intArg(a, "start_index", 0), intArg(a, "limit", 30))
	})

	list("emby.listItems", func(ctx context.Context, s *Session, a map[string]any) (any, error) {
		// ★ 保持返回**数组**而不是 {items,total}:要总数/翻页/筛选走 listItemsPage。
		//   这两条的返回形状不同是故意的,前端各有各的调用点。
		p, err := defaultClient.Items(ctx, s, str(a, "parent_id"), &ItemQuery{})
		if err != nil {
			return nil, err
		}
		return p.Items, nil
	})
	list("emby.listRandom", func(ctx context.Context, s *Session, a map[string]any) (any, error) {
		return defaultClient.RandomPicks(ctx, s, intArg(a, "limit", 8))
	})
	list("emby.getFilters", func(ctx context.Context, s *Session, a map[string]any) (any, error) {
		return defaultClient.FiltersOf(ctx, s, str(a, "parent_id"))
	})
	list("emby.itemMedia", func(ctx context.Context, s *Session, a map[string]any) (any, error) {
		// ★ version_regex 只用来标 preferred,不影响返回哪些版本。
		//   ponytail: 迁移期由调用方传;接进 core/config 之后从设置里读。
		return defaultClient.MediaVersions(ctx, s, str(a, "item_id"), str(a, "version_regex"))
	})

	// ---- 搜索 / 相似 / 演职员 ----
	list("emby.search", func(ctx context.Context, s *Session, a map[string]any) (any, error) {
		// ★ types 缺省 = 全要(不是一个都不要);「包括集」开关关着时前端显式传 Movie,Series
		return defaultClient.Search(ctx, s, str(a, "query"), strList(a, "types"),
			intArg(a, "limit", 50), str(a, "parent_id"))
	})
	list("emby.similarItems", func(ctx context.Context, s *Session, a map[string]any) (any, error) {
		return defaultClient.Similar(ctx, s, str(a, "item_id"), intArg(a, "limit", 12))
	})
	list("emby.personDetail", func(ctx context.Context, s *Session, a map[string]any) (any, error) {
		return defaultClient.Person(ctx, s, str(a, "person_id"))
	})
	list("emby.personItems", func(ctx context.Context, s *Session, a map[string]any) (any, error) {
		return defaultClient.PersonItems(ctx, s, str(a, "person_id"), intArg(a, "limit", 60))
	})

	// ---- 收藏 / 已看 ----
	// ★ 返回体带上刚设成什么:前端拿它对账自己的乐观更新,而不是各自记一份状态
	list("emby.setFavorite", func(ctx context.Context, s *Session, a map[string]any) (any, error) {
		fav, _ := a["fav"].(bool)
		if err := defaultClient.SetFavorite(ctx, s, str(a, "item_id"), fav); err != nil {
			return nil, err
		}
		return map[string]any{"item_id": str(a, "item_id"), "fav": fav}, nil
	})
	list("emby.setPlayed", func(ctx context.Context, s *Session, a map[string]any) (any, error) {
		played, _ := a["played"].(bool)
		itemID := str(a, "item_id")
		if err := defaultClient.SetPlayed(ctx, s, itemID, played); err != nil {
			return nil, err
		}
		/* ★★ **本地观看记录也要跟着改。**

		   不改的话,用户手动标了「已看」而本地记录还停在旧进度上 ——
		   跨服续播会从那个旧位置起播、跨服回传会把旧进度写回**别人的服务器**。
		   两条路都不报错,用户只会觉得「标了没用」。

		   ★ 走回调而不是直接调:`core/history` 反过来 import 了 `core/emby`
		     (candidate.go 要 emby.Item),这边再 import 它就成环了。
		     槽由 history.RegisterCommands 填上;没填(比如只跑 emby 包的测试)就跳过。 */
		if OnPlayedChanged != nil {
			OnPlayedChanged(ctx, s, itemID, played)
		}
		return map[string]any{"item_id": itemID, "played": played}, nil
	})

	// ---- 管理员动作 ----
	list("emby.isAdmin", func(ctx context.Context, s *Session, a map[string]any) (any, error) {
		return defaultClient.IsAdmin(ctx, s)
	})
	list("emby.permissions", func(ctx context.Context, s *Session, a map[string]any) (any, error) {
		return defaultClient.Permissions(ctx, s)
	})
	list("emby.refreshItem", func(ctx context.Context, s *Session, a map[string]any) (any, error) {
		full, _ := a["full"].(bool)
		return nil, defaultClient.RefreshItem(ctx, s, str(a, "item_id"), full)
	})
	list("emby.scanLibraries", func(ctx context.Context, s *Session, a map[string]any) (any, error) {
		return nil, defaultClient.ScanAllLibraries(ctx, s)
	})

	// ★ login 单列:它**没有会话**(会话就是它产出的),走不了 list() 的取会话那步。
	//   密码只在这一处出现,**不进日志、不进事件、不进错误串** —— 错误只说 HTTP 码。
	bus.Register("emby.login", func(ctx context.Context, seq int64, args map[string]any) (any, error) {
		server, user := str(args, "server"), str(args, "username")
		if server == "" || user == "" {
			return nil, bus.NewErr(bus.EInvalid, "缺少 server 或 username")
		}
		dev := str(args, "device_id")
		if dev == "" {
			// 设备 ID 必须**持久**:每次换一个会把服务器的设备列表刷满,续播会话也对不上。
			// ponytail: 迁移期先由调用方传;接进 core/config 之后改成核心层自己存一个。
			return nil, bus.NewErr(bus.EInvalid, "缺少 device_id")
		}
		_, res, err := defaultClient.Login(ctx, server, user, str(args, "password"), dev)
		if err != nil {
			return nil, classify(err)
		}
		/* ★★ 持久化账号 → 重启免登。**这一步漏了的表现极其阴**:
		   认证成功、token 拿到了、白名单也登记了,但账号表是空的 ——
		     account.listAccounts → 空;emby.currentSession → null(没有活跃账号);
		     侧栏 → 还是「未连接」;按 server_id 找账号的命令 → 「没有这个服务器: 」
		   也就是「登录成功了,但整个应用当作你没登录」,而且一步都不报错。
		   用户 2026-08-31 实测撞上,原话:「进去了但是还是不行,提示缺少 server-id」。

		   ★ 用 Upsert 不是 append:它保住用户编辑过的名称 / 备注 / 图标 / 线路 /
		     active_line / 自签名开关,重登不会把这些冲掉;同时它自带 setActive,
		     所以新登录的账号会成为活跃账号(currentSession 靠的就是这个)。 */
		c := config.Current()
		acc := config.Account{
			Server:   res.Server,
			Token:    res.Token,
			UserID:   res.UserID,
			UserName: res.UserName,
		}
		/* 顺带取服务器名当显示名(用户 2026-08-31 要求)——
		   不取的话侧栏首次登录后显示的是一串地址。

		   ★★ **只在新账号时带**:Upsert 对非空 Name 是**覆盖**语义,
		     无条件传的话「重新登录一次,用户改过的服务器名就被冲回原名」。
		   ★★ 用**独立的短超时**:和登录共用 60 秒客户端超时的话,
		     这个端点一卡登录就跟着卡 60 秒,用户只会觉得「登录巨慢」,
		     根本想不到是在取一个可有可无的名字。
		   ★ 探失败**不挡登录**:有的 fork 没有这个端点。名字是锦上添花,
		     登录是刚需 —— 取不到就留空,由前端回落 host。 */
		if c.Find(res.Server) == nil {
			pctx, cancel := context.WithTimeout(ctx, serverNameTimeout)
			if info, e := defaultClient.ProbeServer(pctx, res.Server); e == nil && info != nil {
				acc.Name = info.Name
			}
			cancel()
		}
		// ★ 空密码**不存成空串** —— 那会让「有密码」和「没设过密码」分不清。
		//   存它是给重新登录和插件的 emby.credentials 权限用的。
		if pw := str(args, "password"); pw != "" {
			acc.Password = &pw
		}
		/* 服务器图标默认取**登录用户的 Emby 头像**:很多 Emby 服把品牌 logo
		   直接设成用户头像,而用户头像在 Emby 是免鉴权的公开资源。
		   该用户没头像时退回 /web/touchicon.png,两者都取不到由 UI 回落内置图标。

		   ★ 和 Name 同理**只在新账号时带**:Upsert 对非空值是覆盖语义,
		     无条件写的话用户自己传上去的那张图标每次重登都被冲掉。 */
		if c.Find(res.Server) == nil {
			tag := ""
			if res.PrimaryImageTag != nil {
				tag = *res.PrimaryImageTag
			}
			icon := serverbatch.BuildIconURL(res.Server, res.UserID, tag)
			acc.IconURL = &icon
		}
		c.Upsert(acc)
		if err := c.Save(); err != nil {
			return nil, bus.NewErr(bus.EInternal, "配置保存失败: %v", err)
		}

		// ★ 登录成功才把这台服务器放进图片通道的白名单(SPEC §6)。
		//   漏了这一步的表现是**登录进去一张封面都没有**,而命令全都正常 ——
		//   很容易被误判成「图片接口坏了」。
		localserve.AllowDefault(res.Server, http.Header{"X-Emby-Token": {res.Token}})
		// ★ 自签名白名单也要跟着刷:新账号默认不放行,但这里和 account.commit
		//   保持同一套动作,免得以后加了「登录时勾自签名」又漏一处。
		tlspolicy.Set(c.InsecureHosts())
		return res, nil
	})

	// currentSession 已登录的 Emby 账号(启动时跳过登录页直接进库);无则 null。
	//
	// ★ 活跃的是**浏览型源**(网盘 / 局域网 / 资源站)时返回 null ——
	//   它没有 Emby token,吐个空 token 的会话会让调用方拿去打 401。
	// ★ 但**前端判断「要不要进登录页」不能只看这一条** —— 只判它的话
	//   网盘用户永远进不了门(他有账号,只是不是 Emby 的)。要连 account.listAccounts
	//   一起看。这条已经害过一次,见 docs/lessons。
	bus.Register("emby.currentSession", func(ctx context.Context, seq int64, args map[string]any) (any, error) {
		a := config.Current().ActiveAccount()
		if a == nil || a.IsFileBrowse() {
			return nil, nil
		}
		return map[string]any{
			// ★ 调用方拿这个 server 直接拼封面 / 背景图地址,所以必须是**当前生效线路**,
			//   不能是账号主键 —— 否则用户切到备用线路后 API 走新线、封面还打老线,
			//   表现为「封面全白但不报错」。
			"server":    a.ActiveLineURL(),
			"token":     a.Token,
			"user_id":   a.UserID,
			"user_name": a.UserName,
			// 头像 tag 只在登录那一刻有意义(用来建服务器图标,已存进 icon_url);
			// 恢复会话时没有也不需要重新取。
			"primary_image_tag": nil,
		}, nil
	})

	// relogin 定点换凭据。
	//
	// ★ **不能直接调 login 那条路** —— 那条走 Upsert,会把账号当成「新登录的」处理。
	//   这里要的是:只换 token/user/password,**不动 server/name/remark/icon/lines/active_line**
	//   (那些是用户的编辑)。
	// ★ 打的是**当前生效线路**不是账号主键:用户多半正是因为主线连不上才来重新登录的。
	bus.Register("emby.relogin", func(ctx context.Context, seq int64, args map[string]any) (any, error) {
		c := config.Current()
		id, user, pw := str(args, "server_id"), str(args, "username"), str(args, "password")
		acc := c.Find(id)
		if acc == nil {
			return nil, bus.NewErr(bus.ENotFound, "找不到该服务器: %s", id)
		}
		_, res, err := defaultClient.Login(ctx, acc.DirectLineURL(), user, pw, c.DeviceID)
		if err != nil {
			return nil, &bus.Err{Code: bus.EAuth, Msg: err.Error()}
		}
		acc.Token = res.Token
		acc.UserID = res.UserID
		acc.UserName = res.UserName
		if pw != "" {
			acc.Password = &pw
		}
		if err := c.Save(); err != nil {
			return nil, bus.NewErr(bus.EInternal, "配置保存失败: %v", err)
		}
		// 新 token 要立刻进图片白名单,否则重新登录之后封面还在用旧 token 打 401
		localserve.AllowDefault(acc.Server, http.Header{"X-Emby-Token": {acc.Token}})
		return map[string]any{"server_id": id, "user_name": res.UserName}, nil
	})

	// ★ logout **尽力而为**:实测某 fork 该端点 404 且 token 登出后仍可用,
	//   所以它的失败**不能**挡住本地删账号 —— 这里永远返回成功,只把结果写进返回体。
	list("emby.logout", func(ctx context.Context, s *Session, a map[string]any) (any, error) {
		err := defaultClient.Logout(ctx, s)
		// ★ 无论服务端登出成不成,本地都要撤销白名单 ——
		//   留着的话那个 origin 就是一个永久的 SSRF 出口。
		localserve.RevokeDefault(s.Server)
		return map[string]any{"server_ok": err == nil}, nil
	})

	// ★ counts 单列不走 list():这个端点在某些 fork 上是 404,
	//   调用方**必须容忍它失败** —— 统计条是锦上添花,不该让首页整个报错。
	//   所以它的错误码是 E_UNSUPPORTED(信息,UI 静默降级)而不是 E_NETWORK(红字 + 重试)。
	bus.Register("emby.counts", func(ctx context.Context, seq int64, args map[string]any) (any, error) {
		s, err := sessionFrom(args)
		if err != nil {
			return nil, err
		}
		c, err := defaultClient.CountsOf(ctx, s)
		if err != nil {
			return nil, bus.NewErr(bus.EUnsupported, "这台服务器没有 /Items/Counts", err.Error())
		}
		return c, nil
	})

	// ---- 屏蔽名单 ----
	bus.Register("emby.blockedList", func(ctx context.Context, seq int64, args map[string]any) (any, error) {
		return blocklist.List(), nil
	})
	bus.Register("emby.setBlocked", func(ctx context.Context, seq int64, args map[string]any) (any, error) {
		id := str(args, "id")
		if id == "" {
			return nil, bus.NewErr(bus.EInvalid, "缺少 id")
		}
		on, _ := args["blocked"].(bool)
		// ★ id 和名字**都要存**:分集靠 series_id 认,跨服的同一部剧 id 不同、只有名字对得上
		blocklist.Set(id, str(args, "name"), on)
		return map[string]any{"id": id, "blocked": on}, nil
	})
}

// serverNameTimeout 登录时取服务器名的上限。**独立于登录本身的超时** ——
// 它只是个显示名,不值得让用户多等哪怕一秒。
const serverNameTimeout = 5 * time.Second

// classify 把出网错误分到正确的错误码上。
//
// ★★ 原来这里**一律** E_NETWORK,而 UI 对 E_NETWORK 只显示「网络不通,可以重试」——
// 密码错、token 过期、地址打错、证书不认,用户看到的全是「没网」。
// 用户 2026-08-31 实测撞上:「我登陆了 Emby 服务器一直提示没网了,实际上有网络」。
//
// ★ 三条判据:
//   - 401/403 是**认证**问题,不是网络问题,而且**不该标 Retryable** ——
//     密码不对时重试一百次也还是不对。
//   - 其余非 2xx 是服务器在说话,说明**网络是通的**,标成 E_NETWORK 是误导。
//   - 只有连不上(DNS / 拒绝连接 / 超时 / TLS 握手失败)才是 E_NETWORK。
//
// 无论哪一类,`Msg` 都带上真实原因 —— UI 那边负责把它显示出来。
func classify(err error) error {
	// ★★ 证书问题要**指路**,不能只把 x509 那句英文丢给用户。
	//   自建 Emby 用自签名证书极常见,而用户看到
	//   「x509: certificate signed by unknown authority」是不知道该干什么的 ——
	//   表现就是「有网,但就是进不去」。
	if hint := certHint(err); hint != "" {
		return &bus.Err{Code: bus.ENetwork, Msg: hint, Detail: err.Error()}
	}
	switch code := StatusOf(err); {
	case code == 401 || code == 403:
		return &bus.Err{Code: bus.EAuth, Msg: err.Error()}
	case code == 404:
		return &bus.Err{Code: bus.ENotFound, Msg: err.Error()}
	case code != 0:
		// 服务器回了话(5xx 之类)—— 网络是通的,可以重试
		return &bus.Err{Code: bus.EInternal, Msg: err.Error(), Retryable: true}
	}
	return &bus.Err{Code: bus.ENetwork, Msg: err.Error(), Retryable: true}
}

// certHint 认出 TLS 证书类的错,给一句能照着做的话。认不出就返回空串。
func certHint(err error) string {
	var unknownCA x509.UnknownAuthorityError
	var badHost x509.HostnameError
	var invalid x509.CertificateInvalidError
	switch {
	case errors.As(err, &unknownCA):
		return "这台服务器用的是自签名证书。要连它,请在「服务器」页面勾上「允许这台服务器的自签名证书」"
	case errors.As(err, &badHost):
		return "证书上的域名和你填的地址对不上(证书签给的是别的域名)。" +
			"要么改用证书上的那个域名,要么在「服务器」页面勾上「允许这台服务器的自签名证书」"
	case errors.As(err, &invalid):
		// 过期是这一类里最常见的
		return "服务器的证书不被信任(常见原因是证书过期)。" +
			"确认服务器证书没问题;自建服务器可以在「服务器」页面勾上「允许这台服务器的自签名证书」"
	}
	return ""
}

func str(a map[string]any, k string) string {
	v, _ := a[k].(string)
	return v
}

// strList 取一个字符串数组参数。**空 / 缺省一律返回 nil** ——
// 下游把 nil 当「没点名 = 全要」,把空数组当同一件事,别在这里造出区别。
func strList(a map[string]any, k string) []string {
	raw, _ := a[k].([]any)
	var out []string
	for _, v := range raw {
		if s, ok := v.(string); ok {
			out = append(out, s)
		}
	}
	return out
}

func intArg(a map[string]any, k string, def int) int {
	if v, ok := a[k].(float64); ok {
		return int(v)
	}
	return def
}

// sessionFrom 从命令参数里取会话。
//
// ponytail: 迁移期先由调用方显式传。等 core/config 把 accounts 接进来之后,
// 改成「传 account 下标,会话由核心层自己组装」—— 那才是 §5.6 命令表里的形状。
func sessionFrom(args map[string]any) (*Session, error) {
	get := func(k string) string {
		v, _ := args[k].(string)
		return v
	}
	/* server_id 指名道姓要哪一台。跨服选版本 / 跨服起播走的就是这一条 ——
	   UI 手上只有 server id,没有那台的 token(见 config.SessionOf 的注释)。
	   ★ 它**压过**同时传来的 server/token:两者不一致时,拿着 A 的 token
	     去打 B 的条目会得到 401 或者另一条片,而两边都不报错。 */
	if id := get("server_id"); id != "" {
		srv, tok, uid, dev, ok := config.Current().SessionOf(id)
		if !ok {
			return nil, bus.NewErr(bus.ENotFound, "没有这个服务器:"+id)
		}
		return &Session{Server: srv, Token: tok, UserID: uid, DeviceID: dev}, nil
	}
	s := &Session{
		Server:   get("server"),
		Token:    get("token"),
		UserID:   get("user_id"),
		DeviceID: get("device_id"),
	}
	if s.Server == "" || s.UserID == "" {
		return nil, bus.NewErr(bus.EInvalid, "缺少 server 或 user_id")
	}
	return s, nil
}
