package prefetch

// 直链落点的**有效期**:跟着 302 自己声明的 `Cache-Control: max-age` 走。
//
// # 为什么需要它
//
// 前后端分离的 Emby(115 / 123 这类网盘后端)取流是 302 跳一条**带时效签名**的直链,
// 而那个 302 会用 `Cache-Control: max-age=<秒>` 把签名的剩余寿命告诉客户端 ——
// 115 默认 30 分钟,123 短得多。
//
// 我们原来把落点(origin.resolved)缓存成**永不过期**,只在请求真的失败时才丢掉它。
// 也就是说签名过期这件事,我们是**靠撞墙才知道**的:
//
//	2~4 个 worker 在同一瞬间全部拿着已经死掉的落点去请求
//	  → 每个各自重试 3 次(fetchChunk 那三轮)
//	  → 每次失败都清一次 resolved、回头再打一遍 Emby 直链
//	  = 一次签名到期,后端瞬间挨上十几次直链解析
//
// 服务端那边看到的就是「这个客户端每隔半小时抽一次风」,而源站(网盘)要为每一次
// 解析付出一次真实请求。读懂 max-age 之后,过期变成**预定事件**:提前一点主动换,
// 一次换一个新落点,失败重试那条路只留给真正的意外。
//
// ★ 上游**没给** max-age 时行为一个字不变(落点永不过期,失败再换)——
//   没有这条兜底的话,不吐这个头的服务器会从「永不重解析」变成「每段都重解析」,
//   那是把减压做成了加压。

import (
	"context"
	"errors"
	"net/http"
	"strconv"
	"strings"
	"sync/atomic"
	"time"
)

// resolveMargin 提前多久就当落点过期。
//
// ★ 必须 ≥ 单段取数的空闲上限(chunkTimeout,20s):在余量里发起的那一段,
//   要能在签名真正失效**之前**读完。留 0 的话边界上必然有一段撞在过期那一刻,
//   表现是每隔 max-age 卡一下 —— 修了失败风暴,换来一个准点的小卡顿。
const resolveMargin = 30 * time.Second

// maxRedirects 跟随上限。Go 默认也是 10,这里自己写是因为装了 CheckRedirect 就得自己管。
const maxRedirects = 10

// ttlSlot 一次请求里从 302 上读到的 max-age。
//
// ★ 为什么挂在**请求上下文**里而不是 origin 上:CheckRedirect 是在别人的 goroutine
//   里被调用的,而同一时刻有 2~4 个 worker 各自在跟自己的跳转。写到共享字段上就是
//   竞态 —— 而且是「偶尔把 A 请求的有效期安到 B 的落点上」这种不报错只出错的类型。
type ttlSlot struct{ ns atomic.Int64 }

type ttlKey struct{}

// withTTLSlot 给 ctx 挂一个收集槽。
func withTTLSlot(ctx context.Context) (context.Context, *ttlSlot) {
	s := &ttlSlot{}
	return context.WithValue(ctx, ttlKey{}, s), s
}

// ttl 这次跳转链里声明的有效期。0 = 没人声明。
func (s *ttlSlot) ttl() time.Duration { return time.Duration(s.ns.Load()) }

// note 记一跳。多跳时取**最小**的那个 —— 链路上最短的那条命决定整条链的命。
func (s *ttlSlot) note(d time.Duration) {
	if d <= 0 {
		return
	}
	for {
		old := s.ns.Load()
		if old > 0 && old <= int64(d) {
			return
		}
		if s.ns.CompareAndSwap(old, int64(d)) {
			return
		}
	}
}

// captureRedirectTTL 装在 http.Client.CheckRedirect 上:跟跳转的同时把 302 自己的
// Cache-Control 收下来。
//
// ★ 这里能拿到 302 的响应头,靠的是 req.Response —— Go 只在客户端跟跳转时填它。
//   不走这条路的话就得自己手动跟一跳(ErrUseLastResponse),那要把 probe 和 fetchOnce
//   两处都改成两段式,平白多一份会走偏的代码。
func captureRedirectTTL(req *http.Request, via []*http.Request) error {
	if len(via) >= maxRedirects {
		return errors.New("重定向超过 10 跳")
	}
	if s, _ := req.Context().Value(ttlKey{}).(*ttlSlot); s != nil && req.Response != nil {
		s.note(maxAgeOf(req.Response.Header))
	}
	return nil
}

// maxAgeOf 从 Cache-Control 里取 max-age。取不到 / 明说别缓存 = 0。
func maxAgeOf(h http.Header) time.Duration {
	for _, v := range h.Values("Cache-Control") {
		for _, part := range strings.Split(v, ",") {
			part = strings.TrimSpace(part)
			// no-store / no-cache = 服务端明说这条落点别留 —— 当成没声明,走旧行为
			if strings.EqualFold(part, "no-store") || strings.EqualFold(part, "no-cache") {
				return 0
			}
			k, val, ok := strings.Cut(part, "=")
			if !ok || !strings.EqualFold(strings.TrimSpace(k), "max-age") {
				continue
			}
			n, err := strconv.Atoi(strings.Trim(strings.TrimSpace(val), `"`))
			if err != nil || n <= 0 {
				return 0
			}
			return time.Duration(n) * time.Second
		}
	}
	return 0
}

// upstreamURL 这一次该打哪个地址。返回 (地址, 用的是不是已解析的落点)。
//
// ★ 过期判定放在**取地址**这一步,不放在定时器上:没有后台 goroutine 要收,
//   也不会在没人播的时候还去刷接口。
func (o *origin) upstreamURL() (string, bool) {
	o.upMu.Lock()
	defer o.upMu.Unlock()
	if o.resolved == "" {
		return o.url, false
	}
	if !o.resolvedExp.IsZero() && !time.Now().Before(o.resolvedExp) {
		o.resolved, o.resolvedExp = "", time.Time{}
		return o.url, false // 签名到期:回头打 Emby 直链,让它给个新落点
	}
	return o.resolved, true
}

// noteResolved 记下跟完跳转的落点和它的有效期。requested == final = 压根没跳转,不记。
func (o *origin) noteResolved(requested, final string, ttl time.Duration) {
	if final == "" || final == requested {
		return
	}
	o.upMu.Lock()
	defer o.upMu.Unlock()
	o.resolved = final
	switch {
	case ttl > resolveMargin:
		o.resolvedExp = time.Now().Add(ttl - resolveMargin)
	case ttl > 0:
		// 声明的寿命比余量还短:余量再减就成负数了,按原值用,过期照旧靠失败兜底
		o.resolvedExp = time.Now().Add(ttl)
	default:
		o.resolvedExp = time.Time{} // 没声明 = 不过期(旧行为)
	}
}

// dropResolved 落点不灵了,丢掉。
func (o *origin) dropResolved() {
	o.upMu.Lock()
	defer o.upMu.Unlock()
	o.resolved, o.resolvedExp = "", time.Time{}
}
