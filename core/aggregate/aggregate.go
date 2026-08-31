// Package aggregate 是跨所有已登录服务器的聚合视图(`emby.aggregate*`)。
//
// 移植自 `apps/*/src/lib.rs` 的 aggregate_search / aggregate_overview。
//
// ★★ 这个域只有两条命令,但两条都踩着同一个坑:**必须走生效线路
// (ActiveLineURL),不能用账号主键**。用户切到备用线正是因为主线不通 ——
// 打主线的结果是那台服务器 `unwrap_or_default()` 成空结果,
// **从聚合里静默消失,查都没处查**。
package aggregate

import (
	"context"
	"strings"
	"sync"

	"linplayer/core/bus"
	"linplayer/core/config"
	"linplayer/core/emby"
)

var client *emby.Client

// ServerGroup 聚合搜索里的一组结果。
type ServerGroup struct {
	ServerID string `json:"server_id"`
	// ServerName **只放服务器名**。
	//
	// ★ 这里曾拼成「账户名 @ 地址」。用户 2026-07-15:「聚合搜索的时候只显示
	// 服务器名称,不显示账户名字和地址」—— 而且拼串这个做法本身就错:
	// 调用方**拆不开**,想只显示一部分都做不到。要加回去请**加字段**,
	// 别再往一个串里塞三样东西。
	ServerName string      `json:"server_name"`
	Items      []emby.Item `json:"items"`
}

// SourceOverview 聚合视界里的一张服务器卡。
type SourceOverview struct {
	ServerID     string      `json:"server_id"`
	ServerName   string      `json:"server_name"`
	SourceKind   string      `json:"source_kind"`
	IsFileBrowse bool        `json:"is_file_browse"`
	Active       bool        `json:"active"`
	Counts       emby.Counts `json:"counts"`
	Resume       []emby.Item `json:"resume"`
}

// RegisterCommands 由 lp_init 调用。
func RegisterCommands(version string) {
	client = emby.NewClient(version)

	// aggregateSearch 跨所有已登录 Emby 服务器并行搜索,按服分组。
	//
	// ★ **单台失败隔离**:一台连不上不该让整个搜索报错 —— 那台没结果就是没结果,
	//   其余照出。所以每台的错误都被吞掉,只是不出现在结果里。
	bus.Register("emby.aggregateSearch", func(ctx context.Context, seq int64, a map[string]any) (any, error) {
		query, _ := a["query"].(string)
		c := config.Current()
		if strings.TrimSpace(query) == "" || len(c.AccountList) == 0 {
			return []ServerGroup{}, nil
		}
		/* 用户 2026-07-16:「跨服查找剧/电影、聚合搜索,都只出剧/电影的条目,
		   不要出『集』这种条目 —— 这是不一样的」。
		   emby.Search 不点名类型时默认 Movie,Series,Episode → 分集混进结果。
		   这里显式收敛成 Movie,Series。
		   ★ **不传 include_episodes = 关**:跨服选源那条路不传这个参数,
		     它的行为因此一字未变。 */
		types := []string{"Movie", "Series"}
		if inc, _ := a["include_episodes"].(bool); inc {
			types = append(types, "Episode")
		}

		type slot struct {
			g  ServerGroup
			ok bool
		}
		slots := make([]slot, len(c.AccountList))
		var wg sync.WaitGroup
		for i := range c.AccountList {
			acc := c.AccountList[i]
			if acc.IsFileBrowse() {
				continue // 浏览型源没有 Emby 搜索接口
			}
			wg.Add(1)
			go func(i int, acc config.Account) {
				defer wg.Done()
				s := sessionOf(c, acc)
				items, err := client.Search(ctx, s, query, types, 0, "")
				if err != nil || len(items) == 0 {
					return // 单台失败隔离:这台没结果,其余照出
				}
				slots[i] = slot{ServerGroup{ServerID: acc.Server, ServerName: acc.DisplayName(), Items: items}, true}
			}(i, acc)
		}
		wg.Wait()

		// ★ 按账号表顺序拼回去,不按谁先返回 —— 否则每次搜索服务器顺序都在跳
		out := []ServerGroup{}
		for _, s := range slots {
			if s.ok {
				out = append(out, s.g)
			}
		}
		return out, nil
	})

	// aggregateOverview 聚合视界:每台服务器一张卡(规模统计 + 继续观看)。
	bus.Register("emby.aggregateOverview", func(ctx context.Context, seq int64, a map[string]any) (any, error) {
		c := config.Current()
		activeServer := ""
		if act := c.ActiveAccount(); act != nil {
			activeServer = act.Server
		}
		out := make([]SourceOverview, len(c.AccountList))
		var wg sync.WaitGroup
		for i := range c.AccountList {
			acc := c.AccountList[i]
			out[i] = SourceOverview{
				ServerID: acc.Server, ServerName: acc.DisplayName(),
				SourceKind: acc.SourceKind(), IsFileBrowse: acc.IsFileBrowse(),
				Active: acc.Server == activeServer,
				// 空切片不是 nil:调用方直接 .map() 拿到 null 会抛错
				Resume: []emby.Item{},
			}
			if acc.IsFileBrowse() {
				continue // 浏览型源没有 counts / resume
			}
			wg.Add(1)
			go func(i int, acc config.Account) {
				defer wg.Done()
				s := sessionOf(c, acc)
				/* ★ counts 和 resume **各自吞错**,不是一起失败。
				   合成一条命令而不是「counts 一条、resume 一条」,是因为手机端首页顶栏
				   和聚合视界都要这两样;但**某台服的统计端点 404 不能让整页报错** ——
				   /Items/Counts 在某些 fork 上就是没有的。 */
				var wg2 sync.WaitGroup
				wg2.Add(2)
				go func() {
					defer wg2.Done()
					if cnt, err := client.CountsOf(ctx, s); err == nil && cnt != nil {
						out[i].Counts = *cnt
					}
				}()
				go func() {
					defer wg2.Done()
					if items, err := client.Resume(ctx, s, 12); err == nil {
						out[i].Resume = items
					}
				}()
				wg2.Wait()
			}(i, acc)
		}
		wg.Wait()
		return out, nil
	})
}

// sessionOf 造会话。
//
// ★★ **必须走生效线路**(ActiveLineURL),不能用账号主键 acc.Server ——
// 用户切到备用线正是因为主线不通,打主线的结果是这台服静默变成「零条目」,
// 从聚合里消失,查都没处查。
func sessionOf(c *config.AppConfig, acc config.Account) *emby.Session {
	return &emby.Session{
		Server: acc.ActiveLineURL(), Token: acc.Token,
		UserID: acc.UserID, DeviceID: c.DeviceID,
	}
}
