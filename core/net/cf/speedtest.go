package cf

//
// CF 优选测速引擎。
// 流程对标 XIU2/CloudflareSpeedTest:
//  1. 随机抽样 CF 边缘 IP
//  2. TCP 握手延迟 + 丢包筛选排序
//  3. HTTP 校验(cdn-cgi/trace)—— 剔掉「TCP 通但 HTTP 死」的边缘
//  4. 对延迟最优的若干做 HTTPS 下载测速(钉 IP + SNI = 测速域名)

import (
	"context"
	"crypto/tls"
	"fmt"
	"io"
	"net"
	"net/http"
	"net/url"
	"os"
	"sort"
	"strings"
	"sync"
	"time"
)

// defaultTestURL 默认测速文件。
//
// ★★ 由 `-ldflags -X` 注入(见 core/cmd/sealsecrets):它是一个具体的域名,
// 按仓库红线不进提交。没注入时下载测速这一阶段直接跳过 ——
// 结果里 download_kbps 为空,排序退化成纯按延迟,功能仍然可用。
var defaultTestURL string

// TestURL 这个构建用哪个测速文件。空 = 没配。
func TestURL() string {
	if v := strings.TrimSpace(os.Getenv("LP_CF_TEST_URL")); v != "" {
		return v
	}
	return strings.TrimSpace(defaultTestURL)
}

// TestResult 一个候选边缘的测速结果。
type TestResult struct {
	IP        string   `json:"ip"`
	LatencyMs int64    `json:"latency_ms"`
	LossRate  float64  `json:"loss_rate"`
	KBps      *float64 `json:"download_kbps"`
}

// Options 测速参数。零值不可用,拿 DefaultOptions() 起手。
type Options struct {
	SampleCount        int
	LatencyConcurrency int
	PingSamples        int
	PingTimeout        time.Duration
	MaxLossRate        float64
	MaxLatencyMs       int64
	LatencyKeepTop     int
	DownloadWanted     int
	DownloadDuration   time.Duration
	MinDownloadKBps    float64
	TestURL            string
	IPMode             string // auto / v4 / v6 / dual
	// ValidateHost HTTP 校验域名(通常是 Emby 域名);空 = 跳过校验。
	ValidateHost string
}

func DefaultOptions() Options {
	return Options{
		SampleCount: 256, LatencyConcurrency: 64,
		PingSamples: 4, PingTimeout: time.Second,
		MaxLossRate: 0.5, MaxLatencyMs: 500, LatencyKeepTop: 24,
		// 用户 2026-07-16:带宽要真正参与。多测几个 IP 的带宽(4→8),
		// 否则只有最低延迟的那几个被测带宽,高带宽的中延迟 IP 根本没机会;
		// 单次时长 6→4s 抵消额外 IP 的总耗时。
		DownloadWanted: 8, DownloadDuration: 4 * time.Second,
		// 带宽下限 2Mbps:有更好的就不选近乎零带宽的 IP(都达不到才回退)。
		MinDownloadKBps: 2000, TestURL: TestURL(), IPMode: "auto",
	}
}

// score 排名综合分。**分越低越靠前。**
//
// ★★ 用户 2026-07-16:「别光看延迟,带宽也很重要 —— 延迟极低的一般带宽也极低」。
// 旧版是硬分档(50ms 一档),同档才比带宽 → 一个延迟低但带宽差的 IP 仍能排在
// 延迟略高、带宽高得多的 IP 前面。
//
// 改成综合分:`分 = 延迟(ms) − 带宽奖励`。每 Mbps 抵约 3ms,带宽封顶 100Mbps
// (≈300ms 奖励)—— 既让带宽真正参与排序,又不至于让一个 480ms 的远端高带宽 IP
// 通吃(它 300ms 奖励也追不平延迟差)。
func score(r TestResult) float64 {
	mbps := 0.0
	if r.KBps != nil {
		mbps = *r.KBps / 1000
	}
	if mbps > 100 {
		mbps = 100
	}
	return float64(r.LatencyMs) - mbps*3
}

func addrOf(ip string) string {
	if strings.Contains(ip, ":") {
		return "[" + ip + "]:443"
	}
	return ip + ":443"
}

// hasIPv6 探本机有没有可用 IPv6(连 CF 公共 DNS v6)。
func hasIPv6(ctx context.Context) bool {
	for _, ip := range []string{"2606:4700:4700::1111", "2606:4700:4700::1001"} {
		c, cancel := context.WithTimeout(ctx, 800*time.Millisecond)
		conn, err := (&net.Dialer{}).DialContext(c, "tcp", addrOf(ip))
		cancel()
		if err == nil {
			_ = conn.Close()
			return true
		}
	}
	return false
}

func gatherIPs(ctx context.Context, o Options) []string {
	mode := o.IPMode
	if mode == "auto" || mode == "" {
		if hasIPv6(ctx) {
			mode = "dual"
		} else {
			mode = "v4"
		}
	}
	switch mode {
	case "v4":
		return SampleV4(o.SampleCount)
	case "v6":
		return SampleV6(o.SampleCount)
	default:
		half := (o.SampleCount + 1) / 2
		return append(SampleV4(half), SampleV6(half)...)
	}
}

// measureLatency TCP 握手延迟 + 丢包。多次握手取均值;一次都没成返回 false。
func measureLatency(ctx context.Context, ip string, o Options) (TestResult, bool) {
	addr := addrOf(ip)
	var success, totalMs int64
	for i := 0; i < o.PingSamples; i++ {
		t0 := time.Now()
		c, cancel := context.WithTimeout(ctx, o.PingTimeout)
		conn, err := (&net.Dialer{}).DialContext(c, "tcp", addr)
		cancel()
		if err == nil {
			_ = conn.Close()
			success++
			totalMs += time.Since(t0).Milliseconds()
		}
	}
	if success == 0 {
		return TestResult{}, false
	}
	return TestResult{
		IP:        ip,
		LatencyMs: int64(float64(totalMs)/float64(success) + 0.5),
		LossRate:  float64(o.PingSamples-int(success)) / float64(o.PingSamples),
	}, true
}

// pinnedClient 把 host 的 DNS 钉到 ip:443,**TLS SNI / Host 仍是 host**。
//
// ★ 这就是 CF 优选能成立的全部机制:边缘按 SNI 调度回源,钉 IP 只是换了个入口。
// 钉错了 SNI 就回不了源 —— 表现是 403 或者一个陌生站点的页面。
func pinnedClient(host, ip string) *http.Client {
	addr := addrOf(ip)
	return &http.Client{
		Timeout: 10 * time.Second,
		// ★ 不跟随重定向:测速文件直返 200,跟随只会把测速跑到别的域名上去。
		CheckRedirect: func(*http.Request, []*http.Request) error { return http.ErrUseLastResponse },
		Transport: &http.Transport{
			DialContext: func(ctx context.Context, network, _ string) (net.Conn, error) {
				return (&net.Dialer{}).DialContext(ctx, network, addr)
			},
			// ★ 测速阶段**不校验证书**:候选 IP 里混着不为该域名服务的边缘,
			//   证书对不上是常态而不是攻击信号。真正取数据的连接走的是别的客户端。
			TLSClientConfig: &tls.Config{InsecureSkipVerify: true, ServerName: host},
		},
	}
}

// httpValidate 用 https://<host>/cdn-cgi/trace 校验这个 IP 能否为该域名服务。
//
// ★ 2xx/3xx = 边缘确实在为该域名服务(trace 由 CF 边缘直接应答,**不回源**)。
// 少了这一步会挑到「TCP 通但 HTTP 死」的边缘 —— 测速一片绿,一用就全 502。
func httpValidate(ctx context.Context, ip, host string) bool {
	c, cancel := context.WithTimeout(ctx, 4*time.Second)
	defer cancel()
	req, err := http.NewRequestWithContext(c, http.MethodGet, "https://"+host+"/cdn-cgi/trace", nil)
	if err != nil {
		return false
	}
	resp, err := pinnedClient(host, ip).Do(req)
	if err != nil {
		return false
	}
	defer resp.Body.Close()
	_, _ = io.Copy(io.Discard, io.LimitReader(resp.Body, 4096))
	return resp.StatusCode >= 200 && resp.StatusCode < 400
}

// measureDownload HTTPS 下载测速。返回 KB/s;失败返回 nil。
func measureDownload(ctx context.Context, ip string, o Options) *float64 {
	if strings.TrimSpace(o.TestURL) == "" {
		return nil
	}
	u, err := url.Parse(o.TestURL)
	if err != nil || u.Hostname() == "" {
		return nil
	}
	c, cancel := context.WithTimeout(ctx, o.DownloadDuration+8*time.Second)
	defer cancel()
	req, err := http.NewRequestWithContext(c, http.MethodGet, o.TestURL, nil)
	if err != nil {
		return nil
	}
	resp, err := pinnedClient(u.Hostname(), ip).Do(req)
	if err != nil {
		return nil
	}
	defer resp.Body.Close()
	if resp.StatusCode != 200 {
		return nil
	}
	var bytes int64
	buf := make([]byte, 64*1024)
	t0 := time.Now()
	for time.Since(t0) < o.DownloadDuration {
		n, err := resp.Body.Read(buf)
		bytes += int64(n)
		if err != nil {
			break
		}
	}
	secs := time.Since(t0).Seconds()
	// ★ 太短或太少都不算数:一个 0.01 秒下了 1KB 的样本会算出一个荒唐的高速度,
	//   然后它会排到第一名。
	if secs <= 0.05 || bytes < 65536 {
		return nil
	}
	kbps := (float64(bytes) / 1024) / secs
	return &kbps
}

// boundedLatency 分波并发:每波跑 LatencyConcurrency 个,等齐再下一波。
func boundedLatency(ctx context.Context, ips []string, o Options) []TestResult {
	n := o.LatencyConcurrency
	if n < 1 {
		n = 1
	}
	var (
		mu  sync.Mutex
		out []TestResult
	)
	for i := 0; i < len(ips); i += n {
		end := min(i+n, len(ips))
		var wg sync.WaitGroup
		for _, ip := range ips[i:end] {
			wg.Add(1)
			go func(ip string) {
				defer wg.Done()
				r, ok := measureLatency(ctx, ip, o)
				if !ok || r.LossRate > o.MaxLossRate || r.LatencyMs > o.MaxLatencyMs {
					return
				}
				mu.Lock()
				out = append(out, r)
				mu.Unlock()
			}(ip)
		}
		wg.Wait()
	}
	return out
}

// SpeedTest 跑一轮优选,返回排好序的结果(最优在前)。空 = 没有可用 IP。
func SpeedTest(ctx context.Context, o Options) []TestResult {
	ips := gatherIPs(ctx, o)
	if len(ips) == 0 {
		return []TestResult{}
	}

	// 阶段一:握手延迟 + 丢包筛选
	latency := boundedLatency(ctx, ips, o)
	if len(latency) == 0 {
		return []TestResult{}
	}
	sort.SliceStable(latency, func(i, j int) bool {
		if latency[i].LatencyMs != latency[j].LatencyMs {
			return latency[i].LatencyMs < latency[j].LatencyMs
		}
		return latency[i].LossRate < latency[j].LossRate
	})
	candidates := latency[:min(o.LatencyKeepTop, len(latency))]

	// 阶段二:HTTP 校验(并发 16)
	if host := strings.TrimSpace(o.ValidateHost); host != "" {
		var (
			mu        sync.Mutex
			validated []TestResult
		)
		for i := 0; i < len(candidates); i += 16 {
			end := min(i+16, len(candidates))
			var wg sync.WaitGroup
			for _, c := range candidates[i:end] {
				wg.Add(1)
				go func(c TestResult) {
					defer wg.Done()
					if httpValidate(ctx, c.IP, host) {
						mu.Lock()
						validated = append(validated, c)
						mu.Unlock()
					}
				}(c)
			}
			wg.Wait()
		}
		// ★ 一个都没过 = 这个域名多半根本不走 CF。返回空,让界面如实说 ——
		//   退回未校验的 IP 会让用户选中一个必然 502 的边缘。
		if len(validated) == 0 {
			return []TestResult{}
		}
		sort.SliceStable(validated, func(i, j int) bool {
			return validated[i].LatencyMs < validated[j].LatencyMs
		})
		candidates = validated
	}

	// 阶段三:下载测速(顺序,命中 DownloadWanted 个即停)
	var downloaded []TestResult
	for _, c := range candidates {
		if len(downloaded) >= o.DownloadWanted {
			break
		}
		if kbps := measureDownload(ctx, c.IP, o); kbps != nil && *kbps > 0 {
			r := c
			r.KBps = kbps
			downloaded = append(downloaded, r)
		}
	}
	if len(downloaded) == 0 {
		// ★ 下载全失败(测速文件被墙 / 这个构建没配测速文件):
		//   退回已过 HTTP 校验的 IP,按延迟排 —— 有排序总比没有强。
		return candidates
	}
	sort.SliceStable(downloaded, func(i, j int) bool { return score(downloaded[i]) < score(downloaded[j]) })
	// 满足带宽阈值的优先;都不满足就按综合分给全部。
	if o.MinDownloadKBps > 0 {
		var qualified []TestResult
		for _, r := range downloaded {
			if r.KBps != nil && *r.KBps >= o.MinDownloadKBps {
				qualified = append(qualified, r)
			}
		}
		if len(qualified) > 0 {
			return qualified
		}
	}
	return downloaded
}

var _ = fmt.Sprint
