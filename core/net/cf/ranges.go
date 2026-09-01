package cf

// Cloudflare 边缘 IP 段随机抽样。移植自 `crates/core/src/net/cf/ranges.rs`。
//
// CF 优选的原理:CF anycast **按 SNI + Host 调度回源** —— 连到哪个 CF 边缘 IP
// 都能正确回到你的源站,只要 TLS SNI / HTTP Host 仍是你的域名。
// 于是从这些段里随机抽样、就近测速,挑一个最快的边缘。
//
// ★ 下面两张表是 **Cloudflare 官方公布的地址段**(cloudflare.com/ips),
// 不是任何人的服务器地址 —— 和端口号、协议常量一个性质。

import (
	"crypto/rand"
	"encoding/binary"
	"fmt"
	"math/big"
	"net"
	"strings"
)

// cfIPv4CIDRs Cloudflare 官方 IPv4 段。
var cfIPv4CIDRs = []string{
	"173.245.48.0/20", "103.21.244.0/22", "103.22.200.0/22", "103.31.4.0/22",
	"141.101.64.0/18", "108.162.192.0/18", "190.93.240.0/20", "188.114.96.0/20",
	"197.234.240.0/22", "198.41.128.0/17", "162.158.0.0/15", "104.16.0.0/13",
	"104.24.0.0/14", "172.64.0.0/13", "131.0.72.0/22",
}

// cfIPv6Prefixes CF 优选 IPv6 的 /48 前缀。
//
// ★ 只列前缀、只随机化低 32 位:真实可用的 CF 优选 v6 地址形如
// `<前缀>::xxxx:xxxx`,整段随机的命中率低到测不出东西。
var cfIPv6Prefixes = []string{
	"2400:cb00:2049::", "2400:cb00:f00e::", "2606:4700::",
	"2606:4700:10::", "2606:4700:130::",
	"2606:4700:a::", "2606:4700:a0::", "2606:4700:a1::", "2606:4700:a8::", "2606:4700:a9::",
	"2606:4700:b::", "2606:4700:c::", "2606:4700:d::", "2606:4700:d0::", "2606:4700:d1::",
	"2606:4700:e::", "2606:4700:e0::", "2606:4700:e1::", "2606:4700:e2::", "2606:4700:e3::",
	"2606:4700:e4::", "2606:4700:e5::", "2606:4700:e6::", "2606:4700:e7::",
	"2606:4700:f::", "2606:4700:f1::", "2606:4700:f2::", "2606:4700:f3::",
	"2606:4700:f4::", "2606:4700:f5::",
	"2803:f800:50::", "2803:f800:51::",
	"2a06:98c1:3100::", "2a06:98c1:3101::", "2a06:98c1:3102::", "2a06:98c1:3103::",
	"2a06:98c1:3104::", "2a06:98c1:3105::", "2a06:98c1:3106::", "2a06:98c1:3107::",
	"2a06:98c1:3108::", "2a06:98c1:3109::", "2a06:98c1:310a::", "2a06:98c1:310b::",
}

func randUint32() uint32 {
	var b [4]byte
	if _, err := rand.Read(b[:]); err != nil {
		return 0
	}
	return binary.BigEndian.Uint32(b[:])
}

func randBelow(n int) int {
	if n <= 0 {
		return 0
	}
	v, err := rand.Int(rand.Reader, big.NewInt(int64(n)))
	if err != nil {
		return 0
	}
	return int(v.Int64())
}

// SampleV4 从 CF 的 IPv4 段里随机抽 n 个地址。
//
// ★ 抽的是**段内随机主机位**,不是段的第一个地址:段首往往是网络地址 / 保留,
// 全抽段首等于每次都测同样 15 个 IP,优选就成了摆设。
func SampleV4(n int) []string {
	out := make([]string, 0, n)
	nets := make([]*net.IPNet, 0, len(cfIPv4CIDRs))
	for _, c := range cfIPv4CIDRs {
		if _, nw, err := net.ParseCIDR(c); err == nil {
			nets = append(nets, nw)
		}
	}
	if len(nets) == 0 {
		return out
	}
	for i := 0; i < n; i++ {
		nw := nets[randBelow(len(nets))]
		base := binary.BigEndian.Uint32(nw.IP.To4())
		ones, bits := nw.Mask.Size()
		hostBits := bits - ones
		var host uint32
		if hostBits > 0 && hostBits < 32 {
			host = randUint32() & (1<<uint(hostBits) - 1)
		}
		// ★ 跳过 .0 和 .255:网络地址和广播地址握手必然失败,
		//   白白吃掉一次超时(每个 1 秒 × 4 次采样)。
		if host&0xFF == 0 || host&0xFF == 0xFF {
			host |= 1
			host &^= 0xFF
			host |= 1
		}
		ip := make(net.IP, 4)
		binary.BigEndian.PutUint32(ip, base|host)
		out = append(out, ip.String())
	}
	return out
}

// SampleV6 从 CF 的 /48 前缀里随机抽 n 个地址(只随机化低 32 位)。
func SampleV6(n int) []string {
	out := make([]string, 0, n)
	if len(cfIPv6Prefixes) == 0 {
		return out
	}
	for i := 0; i < n; i++ {
		p := strings.TrimSuffix(cfIPv6Prefixes[randBelow(len(cfIPv6Prefixes))], "::")
		out = append(out, fmt.Sprintf("%s::%x:%x", p, randUint32()>>16, randUint32()&0xFFFF))
	}
	return out
}
