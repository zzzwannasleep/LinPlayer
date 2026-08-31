package player

// 真正的起播链:取流 → 应用播放偏好 → loadfile → 挂外挂字幕 → 上报 start。
//
// 移植自 `apps/desktop/src/lib.rs` 的 `play()` 与 `apply_playback_defaults()`。
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

	target, err := prefsClient.ResolveStream(ctx, s, itemID, mediaSourceID, prefs.VersionRegex)
	if err != nil {
		return nil, err
	}

	/* ponytail: 下面这几段等对应子系统移植后接上,**缺了各自的后果**:
	   · 预加载取消        —— 起播那一刻预热还在拉,和播放器抢带宽,反倒更慢
	   · 多线程加载代理    —— 慢链路上起播仍是冷握手 + 冷 seek
	   · Trakt/Bangumi     —— 播放期同步不发 start
	   · 插件 onPlay 事件  —— 插件收不到「开始播放」
	   这些**都不影响本次能不能播出来**,所以先把主链路打通;
	   但它们各自都是「功能静默不工作」,别当成可选项忘掉。 */

	/* 观看记录上下文 与 取流地址本可以**并发**打 —— 两者互不依赖。
	   ★ 能并发的前提是这两条路上**没有跨 await 持有的锁**。Go 这边暂时串着:
	     history 的写锁在 Capture 内部,不跨网络调用;真要并发时先确认这一点,
	     否则就是同一线程上两个 future 抢同一把锁 = 自我死锁(症状是起播直接吊死,不报错)。 */
	whCtx := buildHistoryContext(ctx, s, itemID)
	if whCtx != nil {
		// ★ 调用方传进来的 resumeSecs 只是**这一台** Emby 的进度;
		//   跨服续播开着时,本地记录里别的服务器上更靠后的进度会覆盖它(取最大)。
		remote := int64(resumeSecs * float64(history.TicksPerSec))
		if t := history.Shared().ResolveResumeTicks(whCtx.scope, whCtx.candidate,
			whCtx.seriesTmdbID, &remote, whCtx.candidate.Played, prefs.CrossServerResume); t != nil {
			resumeSecs = float64(*t) / float64(history.TicksPerSec)
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

	// loadfile 的 start= 选项把续播位置交给 mpv 自己处理 ——
	// ★ 别在 FILE_LOADED 之后自己 seek:那时画面已经从 0 开始解了,
	//   用户会看到「先闪一下开头再跳过去」。
	opts := "replace"
	if resumeSecs > 1 {
		opts = "replace"
	}
	args := []string{"loadfile", target.URL, opts}
	if resumeSecs > 1 {
		args = append(args, "start="+strconv.FormatFloat(resumeSecs, 'f', 3, 64))
	}
	if err := command(args...); err != nil {
		return nil, fmt.Errorf("loadfile 失败: %w", err)
	}
	setProp("pause", "no")

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
	cand := candidateOf(*it)
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

// candidateOf 把 Emby 条目折成观看记录的候选。
//
// ★ ProviderIds / PresentationUniqueKey / Path 三样**必须是带 HistoryFields 取回来的**,
// 否则这里全是空,匹配自动降级到「剧名+季集号」—— 跨服续播最容易假装能用的失败形态。
func candidateOf(it emby.Item) history.Candidate {
	rt := int64(it.RuntimeSecs * float64(history.TicksPerSec))
	return history.Candidate{
		ID: it.ID, Name: it.Name, Type: it.Type,
		TmdbID:          history.ExtractProviderID(it.ProviderIDs, "Tmdb"),
		SeriesID:        it.SeriesID,
		SeriesName:      it.SeriesName,
		PresentationKey: it.PresentationUniqueKey,
		Path:            it.Path,
		SeasonNo:        it.SeasonNo,
		EpisodeNo:       it.EpisodeNo,
		Year:            it.Year,
		RunTimeTicks:    &rt,
		Played:          it.Played,
		PositionTicks:   int64(it.ResumeSecs * float64(history.TicksPerSec)),
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
		// ponytail: 阈值应当来自服务器的用户配置(Emby 默认 90%)。
		// 先写死 90 —— 与 Rust 版调用点一致。
		WatchedThresholdPercent: 90,
		Force:                   force,
	})
}

// Stop 停播并上报。pos 是停在哪一秒。
func Stop(ctx context.Context, s *emby.Session, pos float64) error {
	t := Current()
	currentMu.Lock()
	current = nil
	pendingSubs = nil
	currentMu.Unlock()
	_ = command("stop")
	// ★ 停播这一下**必须落盘**(force):不 force 的话会被 10 秒节流吃掉,
	//   最后那段进度就丢了 —— 而用户下次进来看到的正是那个旧位置。
	captureHistory(pos, true)
	currentMu.Lock()
	currentCtx = nil
	currentMu.Unlock()
	if t == nil {
		return nil
	}
	// ★ 上报失败不该让「停止播放」这个动作看起来失败了
	if err := prefsClient.ReportStopped(ctx, s, t, pos); err != nil {
		bus.Logf("warn", "report_stopped 失败: %v", err)
	}
	return nil
}
