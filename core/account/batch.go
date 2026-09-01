package account

// 批量解析添加服务器 + `linplayer://` 深链。
//
// 移植自 `apps/desktop/src/lib.rs` 的 batch_parse / parse_deep_link /
// batch_add_servers / startup_deep_link。解析本身在 core/serverbatch(纯逻辑),
// 这里只负责**编排**:逐块逐线路试登录、落盘、并弹幕源。

import (
	"context"
	"encoding/json"
	"os"
	"strings"
	"sync"

	"linplayer/core/bus"
	"linplayer/core/config"
	"linplayer/core/danmaku"
	"linplayer/core/emby"
	"linplayer/core/serverbatch"
)

// blocksArg 把命令参数里的 blocks 还原成结构体。
//
// ★ 走一遍 JSON 而不是手撕 map:Block 里 Username/Password 是**指针**,
// 手撕的话「键不存在」和「键是空串」这层区别会被抹平 ——
// 而深链里 `?user=` 显式给空串正是靠这层区别被拒绝登录的。
// startupDeepLink 启动深链只能被取走一次。
var (
	startupMu    sync.Mutex
	startupTaken bool
)

func blocksArg(a map[string]any) ([]serverbatch.Block, error) {
	raw, err := json.Marshal(a["blocks"])
	if err != nil {
		return nil, bus.NewErr(bus.EInvalid, "blocks 不合法: %v", err)
	}
	var out []serverbatch.Block
	if err := json.Unmarshal(raw, &out); err != nil {
		return nil, bus.NewErr(bus.EInvalid, "blocks 不合法: %v", err)
	}
	return out, nil
}

// serverLines 块里的服务器线路 → 登录候选(按顺序试)。
//
// ★ id 用**归一化后的 URL**,不是随机 uuid:URL 做 id 更稳,
// 同一份分享文本重复导入不会产生重影。
func serverLines(b *serverbatch.Block) []config.ServerLine {
	out := make([]config.ServerLine, 0, len(b.Lines))
	for _, l := range b.Lines {
		u := serverbatch.NormalizeURL(l.URL)
		out = append(out, config.ServerLine{
			ID: strings.TrimRight(u, "/"), Name: l.Name, URL: u,
		})
	}
	return out
}

// mergeDanmakuLines 把块里的弹幕线路并进全局弹幕源,追加在现有源之后。
//
// ★ 按 id 去重:id 是削掉尾斜杠的地址 —— 同一份分享文本重复导入不产生重影。
func mergeDanmakuLines(b *serverbatch.Block) {
	if len(b.DanmakuLines) == 0 {
		return
	}
	list := danmaku.LoadSources()
	changed := false
	for _, l := range b.DanmakuLines {
		api := serverbatch.NormalizeURL(l.URL)
		id := strings.TrimRight(api, "/")
		dup := false
		for _, x := range list {
			if x.ID == id {
				dup = true
				break
			}
		}
		if dup {
			continue
		}
		// ★ 鉴权方式默认「无」,用户可以在弹幕设置里改。
		//   **表里的顺序就是优先级** —— 追加在最后,不抢现有源的位置。
		list = append(list, danmaku.SourceConfig{
			ID: id, Name: l.Name, APIURL: api, AuthType: danmaku.AuthNone,
		})
		changed = true
	}
	if changed {
		_ = danmaku.SaveSources(list)
	}
}

func registerBatchCommands() {
	// account.batchParse —— **纯解析,不登录、不落盘**。
	//
	// ★ 分两步是故意的:调用方拿去展示让用户核对 / 补用户名,确认后再调
	//   batchAddServers。一步到底的话,一段贴错的文本会直接往配置里塞几台服务器。
	bus.Register("account.batchParse", func(ctx context.Context, seq int64, a map[string]any) (any, error) {
		return serverbatch.ParseShareText(str(a, "text")), nil
	})

	// account.parseDeepLink —— 解析 `linplayer://add-server?...`。
	//
	// ★★ 返回非 null **不等于**可以直接加。深链可能来自任何网页或聊天窗口,
	//   调用方必须先弹确认框(展示地址 / 用户名 / 弹幕源数量 + 明文 HTTP 警告),
	//   用户点了头才调 batchAddServers。
	bus.Register("account.parseDeepLink", func(ctx context.Context, seq int64, a map[string]any) (any, error) {
		return serverbatch.ParseDeepLink(str(a, "url")), nil
	})

	// account.startupDeepLink —— 进程启动参数里带的那条深链(点链接冷启动时)。
	//
	// ★ 只**取一次就没了**:重复取的话用户在应用里点了「取消」,下次进设置页
	//   又会被同一条链接问一遍。
	bus.Register("account.startupDeepLink", func(ctx context.Context, seq int64, a map[string]any) (any, error) {
		startupMu.Lock()
		defer startupMu.Unlock()
		if startupTaken {
			return nil, nil
		}
		startupTaken = true
		for _, arg := range os.Args[1:] {
			if strings.HasPrefix(arg, "linplayer://") {
				return arg, nil
			}
		}
		return nil, nil
	})

	// account.batchAddServers —— 逐块逐线路试登录,第一条通的即设为生效线路。
	//
	// ★★ **为什么要逐线路试**:分享文本里的「主线路」经常是最不通的那条
	//   (被墙 / 限速)。直接钉死第 0 条会让用户加完就连不上,
	//   还得自己去线路列表里一条条点 —— 而他根本不知道能去哪儿点。
	bus.Register("account.batchAddServers", func(ctx context.Context, seq int64, a map[string]any) (any, error) {
		blocks, err := blocksArg(a)
		if err != nil {
			return nil, err
		}
		fbUser := strings.TrimSpace(str(a, "fallback_username"))
		fbPass := str(a, "fallback_password")
		fbName := strings.TrimSpace(str(a, "fallback_name"))
		deviceID := config.Current().DeviceID

		out := []map[string]any{}
		for i := range blocks {
			b := &blocks[i]
			lines := serverLines(b)
			if len(lines) == 0 {
				continue
			}
			display := lines[0].Name

			/* ★★ 空串要当「缺用户名」处理,**不能**当成「用户名就是空的」闷头去登。
			   深链里 `?user=` 显式给空串正是这种情况 —— 闷头登的结果是一次必然
			   失败的认证请求,而报出来的错是服务器给的「用户名或密码错误」,
			   用户会以为是自己密码记错了。 */
			username := ""
			if b.Username != nil {
				username = strings.TrimSpace(*b.Username)
			}
			if username == "" {
				username = fbUser
			}
			if username == "" {
				out = append(out, map[string]any{
					"server_id": nil, "name": display, "error": "缺用户名",
				})
				continue
			}
			password := fbPass
			if b.Password != nil {
				password = *b.Password
			}

			added, lastErr := "", ""
			for idx, line := range lines {
				_, res, err := emby.Default().Login(ctx, line.URL, username, password, deviceID)
				if err != nil {
					lastErr = err.Error()
					continue
				}
				c := config.Current()
				// ★ 服务器名优先用服务器自己报的,取不到才用链接里带的 `?name=`。
				name := fbName
				if probed := emby.ProbeName(ctx, line.URL); probed != "" {
					name = probed
				}
				icon := serverbatch.BuildIconURL(line.URL, res.UserID, ptrStr(res.PrimaryImageTag))
				acc := config.Account{
					Server: res.Server, Token: res.Token,
					UserID: res.UserID, UserName: res.UserName,
					Name: name, IconURL: &icon,
					Lines: lines, ActiveLine: idx, // 试通的那条即生效线路
				}
				if password != "" {
					pw := password
					acc.Password = &pw
				}
				c.Upsert(acc)
				mergeDanmakuLines(b)
				if err := commit(c); err != nil {
					return nil, err
				}
				added = res.Server
				break
			}
			if added != "" {
				out = append(out, map[string]any{"server_id": added, "name": display, "error": nil})
				continue
			}
			// ★ **所有线路都没通**才算失败,报最后一条的错。
			//   报第一条的话用户看到的永远是「主线路超时」,而真正的原因
			//   (密码错)在后面几条上。
			if lastErr == "" {
				lastErr = "所有线路均无法连接"
			}
			out = append(out, map[string]any{"server_id": nil, "name": display, "error": lastErr})
		}
		return out, nil
	})
}

func ptrStr(p *string) string {
	if p == nil {
		return ""
	}
	return *p
}
