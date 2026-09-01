package cf

import (
	"net"
	"strings"
	"testing"
)

func kbps(v float64) *float64 { return &v }

// ★★ 排序必须**同时看延迟和带宽**。
//
// 用户 2026-07-16:「别光看延迟,带宽也很重要 —— 延迟极低的一般带宽也极低」。
// 旧版硬分档(50ms 一档、同档才比带宽)的后果是:一个 20ms/2Mbps 的 IP
// 永远压着 90ms/40Mbps 的那个 —— 而后者才是能把片放流畅的那个。
func TestScore_延迟与带宽一起排(t *testing.T) {
	lower := func(a, b TestResult) bool { return score(a) < score(b) }

	// 延迟差太大时带宽追不平:60ms 仍优于 480ms(哪怕后者快很多)
	a := TestResult{IP: "a", LatencyMs: 60, KBps: kbps(1000)}
	b := TestResult{IP: "b", LatencyMs: 480, KBps: kbps(9000)}
	if !lower(a, b) {
		t.Fatalf("480ms 的高带宽 IP 不该通吃:score(a)=%.1f score(b)=%.1f", score(a), score(b))
	}

	// 相近延迟比带宽:更快的排前
	c := TestResult{IP: "c", LatencyMs: 70, KBps: kbps(5000)}
	d := TestResult{IP: "d", LatencyMs: 60, KBps: kbps(1000)}
	if !lower(c, d) {
		t.Fatalf("延迟相近时带宽应当说话:%.1f vs %.1f", score(c), score(d))
	}

	// ★ 用户场景:20ms/2Mbps(20-6=14)vs 90ms/40Mbps(90-120=-30)→ 后者胜出
	low := TestResult{IP: "low", LatencyMs: 20, KBps: kbps(2000)}
	high := TestResult{IP: "high", LatencyMs: 90, KBps: kbps(40000)}
	if !lower(high, low) {
		t.Fatalf("高带宽的中延迟 IP 应当胜出:%.1f vs %.1f", score(high), score(low))
	}
}

// ★ 带宽封顶 100Mbps:不封顶的话一个千兆边缘的奖励会大到把任何延迟都吃掉。
func TestScore_带宽奖励封顶(t *testing.T) {
	near := TestResult{IP: "near", LatencyMs: 10, KBps: kbps(1000)}
	farHuge := TestResult{IP: "far", LatencyMs: 400, KBps: kbps(1_000_000)} // 1Gbps
	if score(farHuge) < score(near) {
		t.Fatalf("千兆远端不该通吃:%.1f vs %.1f", score(farHuge), score(near))
	}
}

// ★★ 抽样必须是**段内随机主机位**,不是段首。
//
// 全抽段首等于每次都测同样十几个 IP,优选就成了摆设 —— 而且段首往往是
// 网络地址,握手必然失败。
func TestSampleV4_段内随机且落在CF段里(t *testing.T) {
	ips := SampleV4(200)
	if len(ips) != 200 {
		t.Fatalf("抽了 %d 个", len(ips))
	}
	var nets []*net.IPNet
	for _, c := range cfIPv4CIDRs {
		_, nw, err := net.ParseCIDR(c)
		if err != nil {
			t.Fatalf("段写错了:%q", c)
		}
		nets = append(nets, nw)
	}
	uniq := map[string]bool{}
	for _, s := range ips {
		ip := net.ParseIP(s)
		if ip == nil || ip.To4() == nil {
			t.Fatalf("不是合法 IPv4: %q", s)
		}
		in := false
		for _, nw := range nets {
			if nw.Contains(ip) {
				in = true
				break
			}
		}
		if !in {
			t.Fatalf("%s 不在任何 CF 段里 —— 测了也白测", s)
		}
		// 末字节 0 / 255 是网络地址和广播地址,握手必然失败,白吃一次超时
		if last := ip.To4()[3]; last == 0 || last == 255 {
			t.Fatalf("抽到了 %s(网络/广播地址)", s)
		}
		uniq[s] = true
	}
	// 200 个里几乎不可能只有几个不同值 —— 少于 100 就说明随机化没生效
	if len(uniq) < 100 {
		t.Fatalf("200 个样本只有 %d 个不同 —— 每次都测同样几个 IP,优选是摆设", len(uniq))
	}
}

// ★ v6 只随机化低位:整段随机的命中率低到测不出东西。
func TestSampleV6_落在前缀内且形状对(t *testing.T) {
	ips := SampleV6(50)
	if len(ips) != 50 {
		t.Fatalf("抽了 %d 个", len(ips))
	}
	uniq := map[string]bool{}
	for _, s := range ips {
		ip := net.ParseIP(s)
		if ip == nil || ip.To4() != nil {
			t.Fatalf("不是合法 IPv6: %q", s)
		}
		hit := false
		for _, p := range cfIPv6Prefixes {
			if _, nw, err := net.ParseCIDR(strings.TrimSuffix(p, "::") + "::/48"); err == nil && nw.Contains(ip) {
				hit = true
				break
			}
		}
		if !hit {
			t.Fatalf("%s 不在任何 CF v6 前缀里", s)
		}
		uniq[s] = true
	}
	if len(uniq) < 25 {
		t.Fatalf("50 个样本只有 %d 个不同", len(uniq))
	}
}

// ★★ 测速地址**不许硬编在源码里**(仓库红线:域名不进提交)。
// 黄金实现把它写死在 speedtest.rs 里 —— 这条钉住别人「顺手加回来」。
func TestTestURL_默认为空(t *testing.T) {
	if strings.TrimSpace(defaultTestURL) != "" {
		t.Fatalf("源码里出现了硬编的测速地址:%q —— 它必须走 -ldflags 注入", defaultTestURL)
	}
}
