// Package preload 是详情页预热。
//
// **Rust 版是黄金实现。**
// 进详情页就对**即将要播的那个流**发 Range 请求,预热「头 32MB + 尾 2MB」,
// fire-and-forget。两件事同时在办:
//
//  1. **把字节留下来**(头部)。调用方把头部的 URL 指向本地预取代理,字节流经代理时
//     顺手进它的环形缓存;起播时 mpv 连同一个代理,**预热了多少就当场吐多少**,
//     没热完的部分接着拉(边收边吐)。这是用户 2026-08-02 定的口径 ——
//     光把路跑热、把字节丢掉,在慢链路上等于白烧几分钟带宽,起播还得从头再下一遍。
//  2. **把路跑热**(头尾都算):TCP + TLS 握手已建好(远程 Emby 一次往返 100~300ms);
//     服务端把文件页缓存拉进内存(机械盘 / NAS 上这项最值钱);
//     中间有 CDN 时边缘节点把这两段收进缓存。
//     尾部 2MB 是**为 MKV 准备的**:cues 索引在文件末尾,ffmpeg 打开容器的第一件事
//     就是 seek 到尾巴读索引;不预热尾巴,起播必然多一次冷 seek。
//
// ★ 这和「多线程加载(net/prefetch)」是**两个功能,别合并**:
//
//	prefetch = 播放**中**超前拉 Range 喂给 mpv,管「喂得满」
//	preload  = 播放**前**在详情页把头段搬到本地 + 把路跑热,管「起得快」
//
// 它们**共用**同一个本地代理和同一份环形缓存 —— 那正是预热能被起播直接吃到的原因。
//
// 同一时刻只预热一个条目:进了新详情页就把上一个掐掉(用户已经走了,再拉就是白费流量)。
// **起播时也要掐** —— 那时候带宽该全给播放器。
package preload

import (
	"linplayer/core/net/tlspolicy"

	"context"
	"io"
	"net/http"
	"sync"
	"sync/atomic"
)

// DefaultHeadBytes 默认头部预热量。32MB ≈ 1080p 直传流的头一两分钟,
// 够盖住起播 + 前几秒的解码。
//
// ★ 别随手改小:太小盖不住起播后头几秒的解码,预热就白做了。
const DefaultHeadBytes int64 = 32 * 1024 * 1024

// DefaultTailBytes 默认尾部预热量。MKV 的 cues 索引在末尾,2MB 足够覆盖绝大多数
// 片子的索引块。
const DefaultTailBytes int64 = 2 * 1024 * 1024

// Stats 一轮预热的结果(纯统计,失败也不是错误 —— 预热本来就是尽力而为)。
type Stats struct {
	HeadBytes int64 `json:"head_bytes"`
	TailBytes int64 `json:"tail_bytes"`
	Canceled  bool  `json:"canceled"`
}

type job struct {
	cancel *atomic.Bool
	got    *atomic.Int64
	item   string
}

// Preloader 预加载器。调用方持一个,详情页进出各调一次。
type Preloader struct {
	mu     sync.Mutex
	cur    job
	Client *http.Client
}

// New 造一个。
func New() *Preloader {
	return &Preloader{
		cur:    job{cancel: &atomic.Bool{}, got: &atomic.Int64{}},
		// ★ 走 tlspolicy:不走的话自签名服务器上预热永远失败(而且是静默的)
		Client: &http.Client{Transport: tlspolicy.Transport()},
	}
}

// Cancel 掐掉当前这一轮(换条目 / 离开详情页 / **起播时**调)。
func (p *Preloader) Cancel() {
	p.mu.Lock()
	defer p.mu.Unlock()
	p.cur.cancel.Store(true)
}

// Current 当前正在预热的条目 id(空串 = 没在预热)。
func (p *Preloader) Current() string {
	p.mu.Lock()
	defer p.mu.Unlock()
	return p.cur.item
}

// Bytes 已经预热到的字节数(供设置页 / 日志展示)。
func (p *Preloader) Bytes() int64 {
	p.mu.Lock()
	defer p.mu.Unlock()
	return p.cur.got.Load()
}

// begin 开一轮。**会先掐掉上一轮。**
//
// ★ 不掐的话用户在列表里快速点几下,后台会挂着好几轮预热同时抢带宽,
// 而他真正要看的那部反而更慢了。
func (p *Preloader) begin(item string) (*atomic.Bool, *atomic.Int64) {
	p.mu.Lock()
	defer p.mu.Unlock()
	p.cur.cancel.Store(true) // 上一轮:走人
	cancel, got := &atomic.Bool{}, &atomic.Int64{}
	p.cur = job{cancel: cancel, got: got, item: item}
	return cancel, got
}

// Warm 预热头 head 字节 + 尾 tail 字节。本函数自己**读完即丢**;
// 字节留不留得下来,取决于调用方把 headURL 指到哪儿。
//
// # 头尾为什么可以是两个地址
//
// 用户定的口径:**预加载了多少就吐多少出来,不需要等加载完才放**。
// 所以调用方把 headURL 指向**本地预取代理**:字节流经代理时顺手进它的环形缓存,
// 起播时 mpv 连同一个代理,已经预热的部分**当场就吐**。
//
// ★★ 尾部仍然打**直连地址**,两个理由:
//  1. 代理的环形缓存按 `chunk % ring` 定位,尾部段号和头部段号模 ring
//     **有约一半的概率同槽** —— 那样预热完尾巴正好把头顶掉。
//     尾巴只有 2MB,重拉便宜;把路跑热就够本了。
//  2. 尾部用**后缀 Range**(`bytes=-N`),而我们自家的预取代理**不认**后缀 Range。
//
// 任何失败都只是「没热成」,不是错误 —— 服务器不支持 Range、网络抖、条目没权限,
// 统统按 0 字节收场,**绝不能把详情页拦下来**。
func (p *Preloader) Warm(ctx context.Context, itemID, headURL string, head int64, tailURL string, tail int64) Stats {
	cancel, got := p.begin(itemID)

	var st Stats
	if head > 0 {
		st.HeadBytes = p.pull(ctx, headURL, rangeHeader(0, head-1), head, cancel, got)
	}
	/* 尾部用**后缀 Range**,不用先 HEAD 探总长度:少一次往返,而且对
	   「不给 Content-Length 的分块响应」也成立。服务端不认后缀 Range 就拿不到数据 ——
	   那正好,它多半也不支持 Range,预热本来就无从谈起。 */
	if tail > 0 && !cancel.Load() {
		st.TailBytes = p.pull(ctx, tailURL, suffixRange(tail), tail, cancel, got)
	}
	st.Canceled = cancel.Load()
	return st
}

func rangeHeader(start, end int64) string { return "bytes=" + itoa(start) + "-" + itoa(end) }
func suffixRange(n int64) string          { return "bytes=-" + itoa(n) }

// pull 拉一段并**丢弃**。
//
// ★★ limit 是**硬上限**:服务端无视 Range 回整片时(这事真发生过)
// 不能把整部片子拉下来 —— 「热一下」会变成把整部片子偷偷下下来,
// 在计费网络上那是直接烧用户的钱。
func (p *Preloader) pull(ctx context.Context, url, rng string, limit int64, cancel *atomic.Bool, got *atomic.Int64) int64 {
	req, err := http.NewRequestWithContext(ctx, http.MethodGet, url, nil)
	if err != nil {
		return 0
	}
	req.Header.Set("Range", rng)
	// ★ 预取拉上游用 LinPlayerPreload 这条 UA 道(SPEC §14.1):
	//   服主要能把「替 mpv 提前拉的旁路请求」和「用户正在看的那一路」在日志里分开。
	req.Header.Set("User-Agent", "LinPlayerPreload/dev")
	resp, err := p.Client.Do(req)
	if err != nil {
		return 0
	}
	defer resp.Body.Close()
	if resp.StatusCode < 200 || resp.StatusCode >= 300 {
		return 0
	}

	var n int64
	buf := make([]byte, 64*1024)
	for n < limit {
		if cancel.Load() {
			break
		}
		r, err := resp.Body.Read(buf)
		if r > 0 {
			n += int64(r)
			got.Add(int64(r))
			// 读到的字节在这里就丢了 —— **预热不留数据**,这是它和 prefetch 的根本区别
		}
		if err != nil {
			break
		}
	}
	_, _ = io.Copy(io.Discard, io.LimitReader(resp.Body, 0))
	return n
}

func itoa(v int64) string {
	if v == 0 {
		return "0"
	}
	neg := v < 0
	if neg {
		v = -v
	}
	var b [24]byte
	i := len(b)
	for v > 0 {
		i--
		b[i] = byte('0' + v%10)
		v /= 10
	}
	if neg {
		i--
		b[i] = '-'
	}
	return string(b[i:])
}
