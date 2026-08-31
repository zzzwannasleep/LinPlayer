package account

// 线路测速。移植自 `apps/desktop/src/lib.rs` 的 probe_one / probe_lines / probe_line。

import (
	"context"
	"net/http"
	"strings"
	"sync"
	"time"

	"linplayer/core/bus"
	"linplayer/core/config"
)

// probeTimeout 单条线路的上限。6 秒是现有实现的值,别顺手改 —— 改了差分对账会不一致。
const probeTimeout = 6 * time.Second

// LineProbe 一条线路的测速结果。
type LineProbe struct {
	Index int    `json:"index"`
	URL   string `json:"url"`
	// MS 毫秒;**null 表示这条不通**(不是 0)。写成 0 的话「秒回」和「不通」长得一样。
	MS *int64 `json:"ms"`
}

// lineURLs 线路地址表。
//
// ★ 空 lines **回落成「server 本身算一条线」** —— 前端渲染的行数必须与此一致。
// 回落成空表的话,没配备用线路的服务器点「测线路」什么都不显示,像是坏了。
func lineURLs(c *config.AppConfig, serverID string) ([]string, error) {
	a := c.Find(serverID)
	if a == nil {
		return nil, bus.NewErr(bus.ENotFound, "找不到该服务器: %s", serverID)
	}
	if len(a.Lines) == 0 {
		return []string{a.Server}, nil
	}
	out := make([]string, 0, len(a.Lines))
	for _, l := range a.Lines {
		out = append(out, l.URL)
	}
	return out, nil
}

// probeOne 单条线路测速。通 = 毫秒数,不通 / 超时 = nil。
func probeOne(ctx context.Context, hc *http.Client, url string) *int64 {
	ctx, cancel := context.WithTimeout(ctx, probeTimeout)
	defer cancel()

	u := strings.TrimRight(url, "/") + "/System/Info/Public"
	t0 := time.Now()
	req, err := http.NewRequestWithContext(ctx, http.MethodGet, u, nil)
	if err != nil {
		return nil
	}
	resp, err := hc.Do(req)
	if err != nil {
		return nil
	}
	defer resp.Body.Close()
	if resp.StatusCode < 200 || resp.StatusCode >= 300 {
		return nil
	}
	ms := time.Since(t0).Milliseconds()
	return &ms
}

// probeAll 并发测全部线路。
//
// ★ 并发不是优化,是必需:串行的话 6s × N,线路一多用户就以为卡死了。
func probeAll(ctx context.Context, hc *http.Client, urls []string) []LineProbe {
	out := make([]LineProbe, len(urls))
	var wg sync.WaitGroup
	for i, u := range urls {
		wg.Add(1)
		go func(i int, u string) {
			defer wg.Done()
			out[i] = LineProbe{Index: i, URL: u, MS: probeOne(ctx, hc, u)}
		}(i, u)
	}
	wg.Wait()
	return out
}

func registerProbeCommands() {
	bus.Register("account.probeLines", func(ctx context.Context, seq int64, a map[string]any) (any, error) {
		urls, err := lineURLs(config.Current(), str(a, "server_id"))
		if err != nil {
			return nil, err
		}
		return probeAll(ctx, client.HTTP, urls), nil
	})

	// ★ 逐条探是**另一条命令**,不是 probeLines 的内部细节。
	//   整表要等最慢那条(最坏 6s)才返回 —— 一条死线就把整个面板扣住,
	//   用户连切到能用的线路都做不到。用户 2026-07-16 明确要求过:
	//   「先显示线路再去探测,不然一条探得久就一直卡在那」。
	bus.Register("account.probeLine", func(ctx context.Context, seq int64, a map[string]any) (any, error) {
		urls, err := lineURLs(config.Current(), str(a, "server_id"))
		if err != nil {
			return nil, err
		}
		i := intArg(a, "index", -1)
		if i < 0 || i >= len(urls) {
			return nil, bus.NewErr(bus.EInvalid, "线路下标越界: %d(共 %d 条)", i, len(urls))
		}
		return LineProbe{Index: i, URL: urls[i], MS: probeOne(ctx, client.HTTP, urls[i])}, nil
	})
}
