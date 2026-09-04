package player

// 真正的起播链:取流 → 应用播放偏好 → loadfile → 挂外挂字幕 → 上报 start。
//
// ★ 这里**只做已经移植好的那几段**。还没移植的子系统在下面各有一条 `ponytail:`
// 说明「缺什么、缺了会怎样」—— 写「待接」而不说清后果,下一个人只会照着继续拖。

import (
	"context"
	"fmt"
	"strconv"
	"sync"
	"time"

	"linplayer/core/bus"
	"linplayer/core/config"
	"linplayer/core/emby"
	"linplayer/core/history"
)

// current 当前这次播放的目标。上报三件套要靠它拿 PlaySessionId。
var (
	currentMu sync.Mutex
	current   *emby.PlaybackTarget
	// pendingSubs 等 FILE_LOADED 之后才挂的外挂字幕。
	//
	// ★★ **loadfile 只是排队就返回**。紧跟着调 sub-add 必定拿到 -12(MPV_ERROR_COMMAND),
	// 而 Rust 版当年那句 `let _ =` 把它吞了 —— 表现就是「外挂字幕挂了等于没挂」。
	// 挂载必须等 FILE_LOADED,而且只能在事件线程上做。
	pendingSubs []emby.ExternalSub
)

// Current 当前播放目标(供上报三件套)。没在播返回 nil。
func Current() *emby.PlaybackTarget {
	currentMu.Lock()
	defer currentMu.Unlock()
	return current
}

// onFileLoaded 由事件线程调用。
func onFileLoaded() {
	currentMu.Lock()
	subs := pendingSubs
	pendingSubs = nil
	currentMu.Unlock()
	for _, s := range subs {
		// flags=auto:挂上但**不自动切** —— 选哪条仍由用户/语言偏好决定
		if err := command("sub-add", s.URL, "auto", s.Title); err != nil {
			bus.Logf("warn", "挂外挂字幕失败 %s: %v", s.Title, err)
		}
	}
	if len(subs) > 0 {
		bus.Logf("info", "挂载外挂字幕 %d 条", len(subs))
	}
	bus.Emit("player.fileLoaded", map[string]any{"subs": len(subs)}, "")
}

// applyPlaybackDefaults 起播前应用播放偏好。
//
// ★ **每次起播都要应用一次**,不是只在启动时设一遍:mpv 的这些属性会跨文件粘连,
// 而用户可能在上一部片里临时调过倍速/解码。
func applyPlaybackDefaults(p config.Prefs, isDolbyVision bool) {
	hwdec := p.Hwdec
	if isDolbyVision && p.DolbyAutoSW {
		// ★ 杜比视界走硬解在多数 Windows 显卡上**出色偏移**(发绿/发紫),
		//   软解画面才是对的。判据用 VideoRangeType,不是 VideoRange ——
		//   只看 HDR 会把 HDR10 一起误判成 DV,白白掉进软解。
		hwdec = "no"
		bus.Logf("info", "杜比视界:自动切软解(hwdec=no)")
	}
	setProp("hwdec", hwdec)
	setProp("speed", strconv.FormatFloat(p.DefaultSpeed, 'f', -1, 64))
}

// Play 起播一个 Emby 条目。返回真正用的续播位置(秒)。
func Play(ctx context.Context, s *emby.Session, itemID string, resumeSecs float64, mediaSourceID string) (map[string]any, error) {
	c := config.Current()
	prefs := c.PrefsOf()

	/* ★★ 观看记录判据和取流地址<b>并发打</b>。
	   两者互不依赖,而串起来是**起播路径上白白多出的一到两次网络往返**:
	     取流地址(PlaybackInfo) → 取条目判据 → 查剧的 TMDB id → 这才轮到 loadfile
	   本机上看不出来,150ms 延迟的服务器上就是黑屏多停将近半秒。
	   ★ 能并发的前提是这两条路上**没有跨网络调用持有的锁**:
	     history 的写锁在 Capture 内部(停播/进度上报时才走),buildHistoryContext
	     只读不写。真要再往里塞东西,先确认这一条还成立 ——
	     不成立的话就是两个 goroutine 抢同一把锁,症状是起播直接吊死且不报错。
	   ★ 通道要**带缓冲**:取流地址失败时这里直接 return,没人收这个值,
	     无缓冲的话那个 goroutine 会永远卡在发送上(每失败一次泄漏一个)。 */
	histCh := make(chan *historyContext, 1)
	go func() { histCh <- buildHistoryContext(ctx, s, itemID) }()

	target, err := prefsClient.ResolveStream(ctx, s, itemID, mediaSourceID, prefs.VersionRegex)
	if err != nil {
		return nil, err
	}

	/* ponytail: 下面这几段等对应子系统移植后接上,**缺了各自的后果**:
	   · 预加载取消        —— 起播那一刻预热还在拉,和播放器抢带宽,反倒更慢
	   · Trakt/Bangumi     —— 播放期同步不发 start
	   · 插件 onPlay 事件  —— 插件收不到「开始播放」
	   这些**都不影响本次能不能播出来**,所以先把主链路打通;
	   但它们各自都是「功能静默不工作」,别当成可选项忘掉。 */

	/* ★ **预热到此为止**:起播那一刻带宽该全给播放器。
	   它自己跨过这一刻继续拉,就成了和播放器抢带宽 —— 反倒把起播拖慢。 */
	preloader.Cancel()

	playURL := startPrefetch(ctx, s, target, prefs)

	whCtx := <-histCh
	if whCtx != nil {
		// ★ 调用方传进来的 resumeSecs 只是**这一台** Emby 的进度;
		//   跨服续播开着时,本地记录里别的服务器上更靠后的进度会覆盖它(取最大)。
		remote := int64(resumeSecs * float64(history.TicksPerSec))
		if t := history.Shared().ResolveResumeTicks(whCtx.scope, whCtx.candidate,
			whCtx.seriesTmdbID, &remote, whCtx.candidate.Played, prefs.CrossServerResume); t != nil {
			resumeSecs = float64(*t) / float64(history.TicksPerSec)
		}
		/* ☆☆ **看完了的片再点播放,从头开始**(用户 2026-09-03)。

		   不做这一步的表现很难归因:服务器把进度停在 99%,卸载时又没清,
		   于是 `loadfile ... start=<几乎片长>` —— mpv 当场 EOF。
		   播放页判「播完了」直接退出去,看起来像「点了播放没反应」,
		   而且全程一条错不报。上一轮自检就是被它卡了六轮。

		   ★ 判据用的是用户那条阈值,不是「等于片长」。
		     它得和「算不算已观看」完全一致:两处分开写就会出现
		     「标了已看完却仍从 97% 续播」这种自相矛盾的状态。 */
		if rt := whCtx.candidate.RunTimeTicks; rt != nil && *rt > 0 {
			runtime := float64(*rt) / float64(history.TicksPerSec)
			if prefs.WatchedAt(resumeSecs, runtime) {
				bus.Logf("info", "这一集已经看到 %.0f%%(阈值 %d%%),从头放",
					resumeSecs/runtime*100, prefs.WatchedThresholdPercent)
				resumeSecs = 0
			}
		}
	}
	currentMu.Lock()
	currentCtx = whCtx
	currentMu.Unlock()

	bus.Logf("info", "PLAY item=%s resume=%.1f psid=%s method=%s",
		itemID, resumeSecs, target.PlaySessionID, target.PlayMethod)

	if r := ensureMpv(); r != 0 {
		return nil, fmt.Errorf("mpv 起不来")
	}
	if !waitRenderCtx(5 * time.Second) {
		return nil, fmt.Errorf("视频通道未就绪:UI 还没调 lp_gl_init。起播必须排在它之后(SPEC §7.2 约束 6)")
	}

	applyPlaybackDefaults(prefs, target.IsDolbyVision)

	// ★ 外挂字幕**先记下来,等 FILE_LOADED 再挂**。
	//   在 loadfile 之前挂会被 loadfile 冲掉;紧跟着挂拿到的是 -12。
	currentMu.Lock()
	pendingSubs = target.ExternalSubs
	current = target
	currentMu.Unlock()

	/* 起播走 loadWith 这个**唯一入口**(见 load.go)。
	   ★ Emby 这条路不需要额外的逐流头,但**仍然要走它** ——
	     loadWith 会无条件把 http-header-fields 清空、把 UA 设回 LinPlayer/{版本}。
	     不清的话,上一次放网盘源留下的 Authorization / Cookie 会**发给 Emby 服务器**,
	     而且画面照放,只有服务端日志里看得出来。 */
	if err := loadWith(playURL, resumeSecs, nil, ""); err != nil {
		return nil, err
	}

	// 上报 start。★ 失败**不阻断播放** —— 上报是记账,播放是主线。
	if err := prefsClient.ReportStart(ctx, s, target, resumeSecs); err != nil {
		bus.Logf("warn", "report_start 失败(不影响播放): %v", err)
	}

	return map[string]any{
		"resume_secs":     resumeSecs,
		"play_session_id": target.PlaySessionID,
		"media_source_id": target.MediaSourceID,
		"play_method":     target.PlayMethod,
		"is_dolby_vision": target.IsDolbyVision,
		"external_subs":   len(target.ExternalSubs),
	}, nil
}

// startPrefetch 按需起多线程加载代理,返回真正交给 mpv 的地址。
//
// ★ 开关按**服务器**查(账号主键),不是全局:它是**优化**不是功能 ——
// 能不能加速取决于对端(远程 Emby 有收益;局域网/NAS 本就跑满,多开几条 Range
// 只是白白多占连接)。所以只能由用户按服务器主动开,不给全开的入口。
//
// ★ **只代理直传流**:转码 URL 是分段流,套一层字节代理没有意义。
// ★ 起服失败一律回退直连 —— 代理是加速手段,它挂了不该让片子播不了。
func startPrefetch(ctx context.Context, s *emby.Session, target *emby.PlaybackTarget, p config.Prefs) string {
	if target.PlayMethod != "DirectStream" {
		closeSharedProxy() // 转码流:停掉旧代理走直连
		return target.URL
	}
	acc := config.Current().ActiveAccount()
	// ★ 认**账号主键**而不是 session.Server:后者是当前生效线路,还可能被反代改写。
	//   线路只是同一台服的入口,开关不该跟着线路走。
	on := acc != nil && p.PrefetchEnabledFor(acc.Server)

	/* ★★ 预热已经把这条流的头部灌进某个代理的环形缓存里了 —— 那就**必须走那个代理**,
	   否则预热白做。判据是**上游地址一致**(同一条流),和「这台服开没开多线程加载」
	   **无关**:开关管的是播放中并发拉多凶,而不是「已经在本地的字节要不要用」。 */
	warmHit := false
	proxyMu.Lock()
	if sharedProxy != nil && sharedProxy.Upstream() == target.URL {
		warmHit = true
	}
	proxyMu.Unlock()

	if !on && !warmHit {
		closeSharedProxy()
		return target.URL
	}
	h := proxyFor(ctx, target.URL, p)
	if h == nil {
		return target.URL
	}
	if warmHit {
		bus.Logf("info", "复用预热好的本地代理(缓存已就位)")
	} else {
		bus.Logf("info", "多线程加载已开(%d 线程,缓存上限 %d MB)", p.PrefetchThreads, p.PrefetchCacheBytes>>20)
	}
	return h.URL
}

// historyContext 这次播放在观看记录里的上下文。
type historyContext struct {
	scope        string
	candidate    history.Candidate
	seriesTmdbID *string
}

var currentCtx *historyContext

// buildHistoryContext 取「带全部匹配判据的条目」+ 剧的 TMDB id。
//
// ★ 取不到判据(网络抖 / 权限)**不该拦住播放** —— 返回 nil,
// 这次播放就不进本地记录,但片子照放。
func buildHistoryContext(ctx context.Context, s *emby.Session, itemID string) *historyContext {
	it, err := prefsClient.ItemForHistory(ctx, s, itemID)
	if err != nil || it == nil {
		bus.Logf("warn", "取观看记录判据失败(本次播放不进本地记录): %v", err)
		return nil
	}
	cand := history.CandidateFromItem(*it)
	var seriesTmdb *string
	if cand.SeriesID != nil && *cand.SeriesID != "" {
		// ponytail: 这里每次起播都打一次。Rust 侧按 seriesId 缓存(含「查过但没有」的
		// 负缓存)—— 没有缓存的表现是对没刮削的剧反复打服务器。接 net 层时补上。
		seriesTmdb = prefsClient.SeriesTmdbID(ctx, s, *cand.SeriesID)
	}
	return &historyContext{
		scope:        history.ScopeKey(s.Server, s.UserID),
		candidate:    cand,
		seriesTmdbID: seriesTmdb,
	}
}

// captureHistory 落一次观看记录。force=true 用于停播那一下。
func captureHistory(posSecs float64, force bool) {
	currentMu.Lock()
	c := currentCtx
	currentMu.Unlock()
	if c == nil {
		return
	}
	history.Shared().Capture(history.CaptureOpts{
		ScopeKey: c.scope, Candidate: c.candidate, SeriesTmdbID: c.seriesTmdbID,
		PositionTicks: int64(posSecs * float64(history.TicksPerSec)),
		Source:        history.SourceInternal,
		// ★ 阈值由用户定(设置页「看完多少算已观看」)。
		//   它和「下次从头放」用的是**同一个**值 —— 见 config.Prefs.WatchedAt。
		WatchedThresholdPercent: config.Current().PrefsOf().WatchedThresholdPercent,
		Force:                   force,
	})
}

// watchedNow 停在 pos 秒算不算「已经看完」。**调用方必须已经持有 currentMu**。
//
// ★ 片长从当前这次播放的观看记录判据里取,不问 mpv ——
// stop 之后 mpv 的 duration 立刻变 0,在那儿读到的是「片长未知」,
// 于是永远判不出看完(而且不报错)。
func watchedNow(pos float64) bool {
	if currentCtx == nil || currentCtx.candidate.RunTimeTicks == nil {
		return false
	}
	runtime := float64(*currentCtx.candidate.RunTimeTicks) / float64(history.TicksPerSec)
	return config.Current().PrefsOf().WatchedAt(pos, runtime)
}

// Stop 停播并上报。pos 是停在哪一秒。
func Stop(ctx context.Context, s *emby.Session, pos float64) error {
	t := Current()
	currentMu.Lock()
	current = nil
	pendingSubs = nil
	currentMu.Unlock()
	_ = command("stop")
	closeSharedProxy() // 停播就把代理停掉:端口、goroutine、缓存文件一起收
	thumbs.close()     // 缩略图那个实例也收掉:它装的是这一片
	// ★ 停播这一下**必须落盘**(force):不 force 的话会被 10 秒节流吃掉,
	//   最后那段进度就丢了 —— 而用户下次进来看到的正是那个旧位置。
	captureHistory(pos, true)
	currentMu.Lock()
	watched := watchedNow(pos)
	currentCtx = nil
	currentMu.Unlock()
	if t == nil {
		return nil
	}
	/* ★★ 越过用户那条阈值就**明着告诉服务器已看完**。

	   不能只靠 ReportStopped:服务器按**它自己**的阈值判(Emby 默认 90,
	   fork 各改各的),于是设置页里那个数字对用户看到的「已观看」标记
	   毫无影响 —— 一个设了没反应的开关。
	   ★ 只往「已看完」一个方向写,不写 false:没到阈值不代表用户想取消已看标记。 */
	if watched {
		if err := prefsClient.SetPlayed(ctx, s, t.ItemID, true); err != nil {
			bus.Logf("warn", "标记已观看失败(不影响播放): %v", err)
		} else {
			bus.Logf("info", "看到 %.0fs 越过阈值,已标记为看完 item=%s", pos, t.ItemID)
		}
	}
	// ★ 上报失败不该让「停止播放」这个动作看起来失败了
	if err := prefsClient.ReportStopped(ctx, s, t, pos); err != nil {
		bus.Logf("warn", "report_stopped 失败: %v", err)
	}
	return nil
}
