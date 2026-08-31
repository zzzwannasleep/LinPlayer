package player

// 源播放(网盘 / 局域网 / 资源站)的起播入口。
//
// 和 Emby 那条路的区别只有三点,别的一律共用:
//
//	① 地址和逐流头由源后端解析出来,不走 Emby 的 PlaybackInfo
//	② **没有 MediaStreams**,判不出杜比视界 → 按用户设的默认解码方式走
//	③ 上报走源自己的 ReportProgress(有服务端观看记录的源才有),不是 Emby 三件套

import (
	"time"

	"linplayer/core/bus"
	"linplayer/core/config"
	"linplayer/core/emby"
)

// PlaySource 起播一条已经解析好的源地址。
//
//	url        可播地址(本地源给的是**裸路径**,不是 file://)
//	title      片名,只用于日志与 OSD
//	resumeSecs 续播位置
//	headers    逐流请求头(WebDAV 的 Basic、网盘的 Cookie…)
//	ua         整条流的 UA 覆盖,空 = 默认口径
//	subs       外挂字幕(URL 自鉴权的源,如 ani-rss 的 ?s=token)
//
// ★ 返回实际起播的续播位置,和 Emby 那条对齐。
func PlaySource(url, title string, resumeSecs float64,
	headers map[string]string, ua string, subs []emby.ExternalSub) (map[string]any, error) {

	if r := ensureMpv(); r != 0 {
		return nil, bus.NewErr(bus.EInternal, "mpv 起不来")
	}
	if !waitRenderCtx(5 * time.Second) {
		return nil, bus.NewErr(bus.EInternal,
			"视频通道未就绪:UI 还没调 lp_gl_init。起播必须排在它之后(SPEC §7.2 约束 6)")
	}

	prefs := config.Current().PrefsOf()
	// ★ 源播放没有 Emby 的 MediaStreams,**判不出 DV** → 按用户设的默认解码方式走。
	//   硬塞一个 isDolbyVision=true 会让所有网盘片都跑软解,白白卡顿。
	applyPlaybackDefaults(prefs, false)

	/* ★★ 换片时 pending 字幕和当前目标**必须在 loadfile 之前复位**。
	   排在后面的话,上一片的外挂字幕会挂到这一片上,而且旧的 current 还会被
	   状态轮询拍回来 —— 表现是「第二个片子露出上一片的信息」。 */
	currentMu.Lock()
	current = nil
	pendingSubs = nil
	currentCtx = nil // 源播放不是 Emby,清掉观看记录上下文,别把网盘进度记到上一部 Emby 片上
	for _, s := range subs {
		pendingSubs = append(pendingSubs, s)
	}
	currentMu.Unlock()

	bus.Logf("info", "SOURCE PLAY %s resume=%.1f headers=%d subs=%d", title, resumeSecs, len(headers), len(subs))

	if err := loadWith(url, resumeSecs, headers, ua); err != nil {
		return nil, bus.NewErr(bus.EInternal, "%v", err)
	}

	return map[string]any{
		"resume_secs":   resumeSecs,
		"external_subs": len(subs),
	}, nil
}
