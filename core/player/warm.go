package player

// 详情页预热(`prefs.preloadItem` / `prefs.preloadCancel`)+ 代理句柄的复用。
//
// ★★ 预热和多线程加载**共用同一个本地代理和同一份环形缓存** ——
// 那正是「预热了多少就吐多少出来」能成立的原因(用户 2026-08-02 定的口径)。
// 所以代理句柄必须**复用**:起播时新起一个的话,旧句柄一关缓存文件就被删了,
// 预热白做,而且用户在慢链路上白烧了几十 MB 流量。

import (
	"context"
	"strings"
	"sync"

	"linplayer/core/bus"
	"linplayer/core/config"
	"linplayer/core/net/prefetch"
	"linplayer/core/net/preload"
)

var (
	warmMu      sync.Mutex
	preloader   = preload.New()
	proxyMu     sync.Mutex
	sharedProxy *prefetch.Handle
)

// proxyFor 取一个代理到 upstreamURL 的句柄。
//
// ★★ **上游地址一致就复用同一个句柄**,不新起。
// 判据是「同一条流」,和「这台服开没开多线程加载」无关 ——
// 开关管的是播放中并发拉多凶,而不是「已经在本地的字节要不要用」。
//
// 新起一个的表现:旧句柄一关,它的环形缓存文件就被删了 —— 详情页预热的那几十 MB
// 全部作废,起播还得从头再下一遍。慢链路上那是几分钟的白等。
func proxyFor(ctx context.Context, upstreamURL string, p config.Prefs) *prefetch.Handle {
	proxyMu.Lock()
	defer proxyMu.Unlock()
	if sharedProxy != nil {
		if sharedProxy.Upstream() == upstreamURL {
			return sharedProxy // ★ 命中预热:连同它已经装好的缓存一起拿回来
		}
		sharedProxy.Close() // 换片了:端口、goroutine、缓存文件一起收
		sharedProxy = nil
	}
	h, err := prefetch.Start(ctx, upstreamURL, p.PrefetchThreads, p.PrefetchCacheBytes, nil)
	if err != nil {
		bus.Logf("warn", "本地代理起不来,回退直连: %v", err)
		return nil
	}
	sharedProxy = h
	return h
}

// currentProxy 当前那个共享代理句柄(可能为 nil)。缩略图和进度条都要问它。
func currentProxy() *prefetch.Handle {
	proxyMu.Lock()
	defer proxyMu.Unlock()
	return sharedProxy
}

var (
	playURLMu sync.Mutex
	playURL   string
)

// setPlayURL 记下这次交给 mpv 的地址。由 loadWith 唯一调用。
func setPlayURL(u string) {
	playURLMu.Lock()
	playURL = u
	playURLMu.Unlock()
}

// localSource 这条流的**本地字节**从哪儿读、覆盖哪几段。
//
// ★★ 一处判定,两个调用方共用(缩略图取数 / 进度条画带子)。
// 分两处写的下场是「带子说这儿有,点下去没有」—— 本仓的经验里这类不一致
// 全都不报错,只是功能看起来时灵时不灵。
//
//	src   给第二个 mpv 的地址;空串 = 没有本地字节,缩略图整个不可用
//	spans 已在本地的区间(占全片比例)
//	kind  本地字节的来源:proxy(环形缓存)/ file(本地文件)/ none
//
// ★ kind 不是给用户看的措辞,是**判据**:「整片都已缓存」在本地文件上是常态,
// 在代理流上却意味着有人把整部片子下下来了 —— 两者只有 kind 分得开。
func localSource() (src string, spans [][2]float64, kind string) {
	playURLMu.Lock()
	p := playURL
	playURLMu.Unlock()
	if p == "" {
		return "", nil, "none"
	}
	// 直传流走本地代理:只读缓存端点 + 环形缓存里真实躺着的区间
	if h := currentProxy(); h != nil && p == h.URL {
		return h.CachedURL, h.CachedSpans(), "proxy"
	}
	// 本地文件 / 下载好的文件:整条时间轴都能截
	if !strings.Contains(p, "://") {
		return p, [][2]float64{{0, 1}}, "file"
	}
	// 转码流、代理没起来:没有本地字节
	return "", nil, "none"
}

// cachedSpans 进度条画「哪一段有缩略图」用的区间。
func cachedSpans() [][2]float64 {
	_, spans, _ := localSource()
	return spans
}

// cachedKind 本地字节的来源。见 localSource。
func cachedKind() string {
	_, _, k := localSource()
	return k
}

func closeSharedProxy() {
	proxyMu.Lock()
	defer proxyMu.Unlock()
	if sharedProxy != nil {
		sharedProxy.Close()
		sharedProxy = nil
	}
}

// registerWarmCommands 由 RegisterCommands 调用。
func registerWarmCommands() {
	// preloadItem 详情页预热。**fire-and-forget**:立刻返回,后台慢慢热。
	//
	// ★ 不能同步等:详情页要的是「秒开」,而预热本身要几十秒。
	//   等它 = 把一个纯优化做成了一个卡顿。
	bus.Register("prefs.preloadItem", func(ctx context.Context, seq int64, a map[string]any) (any, error) {
		itemID, _ := a["item_id"].(string)
		if itemID == "" {
			return nil, bus.NewErr(bus.EInvalid, "缺少 item_id")
		}
		p := config.Current().PrefsOf()
		if !p.PreloadEnabled {
			return map[string]any{"skipped": "预加载已关闭"}, nil
		}
		s, err := sessionFrom(a)
		if err != nil {
			return nil, err
		}
		msID, _ := a["media_source_id"].(string)

		go func() {
			// ★ 这个 goroutine 有自己的生命周期,别用请求的 ctx —— 那个一返回就取消了,
			//   预热会当场被掐掉,看起来像「预热根本没工作」。
			ctx := context.Background()
			warmMu.Lock()
			defer warmMu.Unlock()
			target, err := prefsClient.ResolveStream(ctx, s, itemID, msID, p.VersionRegex)
			if err != nil {
				bus.Logf("info", "预热取流失败(不影响详情页): %v", err)
				return
			}
			headURL := target.URL
			// ★ 头部指向**本地代理**:字节流经代理时顺手进环形缓存,
			//   起播时 mpv 连同一个代理,预热了多少当场吐多少。
			//   只对直传流做 —— 转码 URL 是分段流,套代理没有意义。
			if target.PlayMethod == "DirectStream" {
				if h := proxyFor(ctx, target.URL, p); h != nil {
					headURL = h.URL
				}
			}
			// ★★ 尾部走**直连**,两个理由都在 core/net/preload 的注释里:
			//   环形缓存同槽会把刚热好的头顶掉;而且代理不认后缀 Range。
			st := preloader.Warm(ctx, itemID, headURL, p.PreloadHeadMB<<20, target.URL, preload.DefaultTailBytes)
			bus.Logf("info", "预热完成 item=%s 头 %d KB 尾 %d KB 取消=%v",
				itemID, st.HeadBytes>>10, st.TailBytes>>10, st.Canceled)
			bus.Emit("preload.done", map[string]any{
				"item_id": itemID, "head_bytes": st.HeadBytes,
				"tail_bytes": st.TailBytes, "canceled": st.Canceled,
			}, "")
		}()
		return map[string]any{"started": itemID}, nil
	})

	bus.Register("prefs.preloadCancel", func(ctx context.Context, seq int64, a map[string]any) (any, error) {
		preloader.Cancel()
		return map[string]any{"canceled": true}, nil
	})
}
