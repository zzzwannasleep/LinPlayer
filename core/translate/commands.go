package translate

// `translate.*` 9 条 + `prefs.get/setTranslationSettings` 2 条。

import (
	"context"
	"encoding/json"
	"fmt"
	"strings"
	"sync"
	"sync/atomic"
	"time"

	"linplayer/core/bus"
	"linplayer/core/config"
	"linplayer/core/player"
)

// RegisterCommands 由 core/commands 调用。
func RegisterCommands() {
	bus.Register("translate.subtitle", cmdSubtitle)
	bus.Register("translate.liveStart", cmdLiveStart)
	bus.Register("translate.liveStop", cmdLiveStop)
	bus.Register("translate.translationEngineStatus", cmdEngineStatus)
	bus.Register("translate.whisperModels", cmdWhisperModels)
	bus.Register("translate.whisperDownload", cmdWhisperDownload)
	bus.Register("translate.whisperDelete", cmdWhisperDelete)
	bus.Register("translate.whisperDeps", cmdWhisperDeps)
	bus.Register("translate.whisperDownloadFfmpeg", cmdWhisperDownloadFFmpeg)

	bus.Register("prefs.getTranslationSettings", cmdGetSettings)
	bus.Register("prefs.setTranslationSettings", cmdSetSettings)
}

func str(a map[string]any, k string) string {
	if v, ok := a[k].(string); ok {
		return v
	}
	return ""
}

// ---------------------------------------------------------------------------
// 设置
// ---------------------------------------------------------------------------

func cmdGetSettings(ctx context.Context, seq int64, a map[string]any) (any, error) {
	return LoadSettings(), nil
}

func cmdSetSettings(ctx context.Context, seq int64, a map[string]any) (any, error) {
	raw, ok := a["settings"]
	if !ok {
		return nil, bus.NewErr(bus.EInvalid, "缺少 settings")
	}
	b, err := json.Marshal(raw)
	if err != nil {
		return nil, bus.NewErr(bus.EInvalid, "settings 不是对象")
	}
	/* ★★ **在当前设置之上反序列化**,不是从零值开始。
	   从零值开始的话,前端只传了一个 targetLang 过来,别的字段全被清成空 ——
	   用户填的 API Key 就这么没了,而界面上什么都不会说。 */
	s := LoadSettings()
	if err := json.Unmarshal(b, &s); err != nil {
		return nil, bus.NewErr(bus.EInvalid, "settings 解析失败: %v", err)
	}
	// 引擎/排版是开放字符串,认不出的值要归到默认档,不能原样落盘。
	s.Engine = EngineKindFromKey(string(s.Engine))
	s.Layout = LayoutFromKey(string(s.Layout))
	if _, err := WhisperModelOf(s.WhisperModel); err != nil {
		s.WhisperModel = string(WhisperBase)
	}
	if err := s.SaveSettings(); err != nil {
		return nil, bus.NewErr(bus.EInternal, "%v", err)
	}
	return s, nil
}

// cmdEngineStatus 各引擎是否已配好(设置页的状态点)。key = 引擎存盘键。
func cmdEngineStatus(ctx context.Context, seq int64, a map[string]any) (any, error) {
	s := LoadSettings()
	out := map[string]bool{}
	for _, k := range AllEngineKinds {
		out[string(k)] = BuildEngine(k, s) != nil
	}
	return out, nil
}

func activeEngineOrErr() (Engine, Settings, error) {
	s := LoadSettings()
	e := ActiveEngine(s)
	if e == nil {
		return nil, s, bus.NewErr(bus.EInvalid,
			"当前翻译引擎还没配好(缺 API Key 或地址),先去设置里填")
	}
	return e, s, nil
}

// ---------------------------------------------------------------------------
// 整轨翻译
// ---------------------------------------------------------------------------

// cmdSubtitle 取当前播放条目的某条字幕流 → 翻译 → 落 SRT → 挂给 mpv,返回 SRT 路径。
func cmdSubtitle(ctx context.Context, seq int64, a map[string]any) (any, error) {
	engine, s, err := activeEngineOrErr()
	if err != nil {
		return nil, err
	}
	itemID, msID := str(a, "item_id"), str(a, "media_source_id")
	if itemID == "" {
		return nil, bus.NewErr(bus.EInvalid, "缺少 item_id")
	}
	var index int64
	if f, ok := a["index"].(float64); ok {
		index = int64(f)
	}

	// 走**当前生效线路** —— 用户切了线路,字幕也得跟着走。
	acc := config.Current().ActiveAccount()
	if acc == nil || acc.IsFileBrowse() {
		return nil, bus.NewErr(bus.EAuth, "当前没有已登录的 Emby 服务器")
	}
	base, token := acc.ActiveLineURL(), acc.Token

	candidates := SubtitleURLCandidates(base, token, itemID, msID, index,
		str(a, "delivery_url"), "")

	sourceLang := str(a, "source_lang")
	if sourceLang == "" {
		sourceLang = LangAuto
	}
	seed := fmt.Sprintf("%s:%s:%s:%d", base, itemID, msID, index)

	// 进度推给前端:整轨翻译动辄几分钟,不报进度用户会以为卡死。
	progress := func(done, total int, phase string) {
		bus.Emit("translate.progress", map[string]any{
			"done": done, "total": total, "phase": phase,
		}, "translate.progress")
	}

	path, err := TranslateSubtitleURL(ctx, candidates, engine, sourceLang, s.TargetLang,
		s.Layout, token, seed, progress)
	if err != nil {
		return nil, bus.NewErr(bus.EUpstream, "%v", err)
	}

	/* ★★ 翻完**直接挂上** —— 只返回路径不挂载,那就是「摆了个按钮不接线」:
	   用户点了「翻译字幕」,进度跑完,然后什么都没发生。 */
	secondary, _ := a["secondary"].(bool)
	if err := player.AddTranslatedSubtitle(path, secondary); err != nil {
		return nil, bus.NewErr(bus.EInternal, "%v", err)
	}
	return path, nil
}

// ---------------------------------------------------------------------------
// 实时预读翻译
// ---------------------------------------------------------------------------
//
// 「字幕 cue 观测」听着像要新建一套观测机制,其实 mpv 的 `sub-text` 就是普通属性,
// 读属性就拿得到 —— 播放器侧没有任何前置缺口。

var (
	liveMu   sync.Mutex
	liveStop chan struct{}
	liveGen  atomic.Int64
)

func cmdLiveStart(ctx context.Context, seq int64, a map[string]any) (any, error) {
	engine, s, err := activeEngineOrErr()
	if err != nil {
		return nil, err
	}
	sourceLang := str(a, "source_lang")
	tr := NewStreamingTranslator(engine, sourceLang, s.TargetLang, s.Layout)

	// ★ 先停旧的:不停的话切换引擎/语言会留下两个轮询,两句译文交替闪。
	stopLive()

	stop := make(chan struct{})
	gen := liveGen.Add(1)
	liveMu.Lock()
	liveStop = stop
	liveMu.Unlock()

	go func() {
		last := ""
		t := time.NewTicker(200 * time.Millisecond)
		defer t.Stop()
		for {
			select {
			case <-stop:
				return
			case <-t.C:
			}
			// 每轮重新读:播放器可能中途被换掉(换片)。
			cur := player.Prop("sub-text")
			if cur == last {
				continue
			}
			last = cur
			if strings.TrimSpace(cur) == "" {
				// 空 cue = 这句结束了,清掉叠加层,否则上一句会一直挂着。
				bus.Emit("translate.cue", map[string]any{"text": ""}, "translate.cue")
				continue
			}
			if hit, ok := tr.CachedDisplay(cur); ok {
				// 命中缓存就直接推,不必等一个网络往返(重复台词/回看很常见)。
				bus.Emit("translate.cue", map[string]any{"text": hit}, "translate.cue")
				continue
			}
			text, err := tr.OnCue(context.Background(), cur)
			// 这一轮跑完时可能已经被 stop 了(或者又 start 了一次),那就别再推。
			if liveGen.Load() != gen {
				return
			}
			if err != nil {
				/* ★ 单句失败**不停掉整个轮询**(限流/抖动很常见),但要让前端知道
				   这句没译出来 —— 静默显示原文会让用户以为翻译在正常工作。 */
				bus.Emit("translate.cueError", map[string]any{"error": err.Error()}, "")
				continue
			}
			bus.Emit("translate.cue", map[string]any{"text": text}, "translate.cue")
		}
	}()
	return map[string]any{"ok": true}, nil
}

func stopLive() {
	liveMu.Lock()
	if liveStop != nil {
		close(liveStop)
		liveStop = nil
	}
	liveMu.Unlock()
	liveGen.Add(1)
}

func cmdLiveStop(ctx context.Context, seq int64, a map[string]any) (any, error) {
	stopLive()
	return map[string]any{"ok": true}, nil
}

// ---------------------------------------------------------------------------
// Whisper
// ---------------------------------------------------------------------------

func cmdWhisperModels(ctx context.Context, seq int64, a map[string]any) (any, error) {
	out := []map[string]any{}
	for _, m := range AllWhisperModels {
		out = append(out, map[string]any{
			"key":              string(m),
			"display_name":     m.DisplayName(),
			"size_label":       m.SizeLabel(),
			"downloaded":       IsDownloaded(m),
			"downloaded_bytes": DownloadedSize(m),
		})
	}
	return out, nil
}

func cmdWhisperDownload(ctx context.Context, seq int64, a map[string]any) (any, error) {
	m, err := WhisperModelOf(str(a, "model"))
	if err != nil {
		return nil, bus.NewErr(bus.EInvalid, "%v", err)
	}
	mirror := LoadSettings().WhisperMirror
	// 模型 1~3GB,不报进度用户会以为卡死。
	last := time.Now()
	progress := func(done, total int64, pct float64) {
		// 限流:每 200ms 一条,不然几 GB 的下载会把事件队列刷爆。
		if time.Since(last) < 200*time.Millisecond && done != total {
			return
		}
		last = time.Now()
		bus.Emit("translate.whisperDownload", map[string]any{
			"model": string(m), "done": done, "total": total, "pct": pct,
		}, "translate.whisperDownload")
	}
	path, err := DownloadModel(ctx, m, mirror, progress)
	if err != nil {
		return nil, bus.NewErr(bus.ENetwork, "%v", err)
	}
	return path, nil
}

func cmdWhisperDelete(ctx context.Context, seq int64, a map[string]any) (any, error) {
	m, err := WhisperModelOf(str(a, "model"))
	if err != nil {
		return nil, bus.NewErr(bus.EInvalid, "%v", err)
	}
	if err := DeleteModel(m); err != nil {
		return nil, bus.NewErr(bus.EInternal, "%v", err)
	}
	return map[string]any{"ok": true}, nil
}

// cmdWhisperDeps whisper/ffmpeg 可执行文件是否就位(设置页据此决定能不能开转录)。
//
// ★ 探测会 spawn 子进程,所以 runsOk 内部按 exe 名缓存(见那边的论证)。
// 命令层跑在 worker 池上,不会冻界面。
func cmdWhisperDeps(ctx context.Context, seq int64, a map[string]any) (any, error) {
	s := LoadSettings()
	whisper := ResolveWhisper(s.WhisperBinary)
	ffmpeg := ResolveFFmpeg(s.FFmpegPath)
	return map[string]any{
		"whisper": nilIfEmpty(whisper),
		"ffmpeg":  nilIfEmpty(ffmpeg),
	}, nil
}

// nilIfEmpty 空串要变成 null:前端拿 `whisper == null` 判「没找到」,
// 空串在 JS 里是 falsy 但在类型上是 string,两边判据会漂。
func nilIfEmpty(s string) any {
	if s == "" {
		return nil
	}
	return s
}

func cmdWhisperDownloadFFmpeg(ctx context.Context, seq int64, a map[string]any) (any, error) {
	last := time.Now()
	progress := func(done, total int64, pct float64) {
		if time.Since(last) < 200*time.Millisecond && done != total {
			return
		}
		last = time.Now()
		bus.Emit("translate.ffmpegDownload", map[string]any{
			"done": done, "total": total, "pct": pct,
		}, "translate.ffmpegDownload")
	}
	path, err := DownloadFFmpeg(ctx, progress)
	if err != nil {
		return nil, bus.NewErr(bus.ENetwork, "%v", err)
	}
	return path, nil
}
