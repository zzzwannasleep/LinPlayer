package player

// 播放控制命令(play / seek / pause / speed / volume / 轨道 / 上报…)。
//
// 这一层只做「参数校验 + 转成 mpv 属性或命令」。真正的坑都在 player.go
// (事件线程、渲染通道)和 emby/playback.go(取流)里。

import (
	"context"
	"encoding/json"
	"strconv"
	"strings"

	"linplayer/core/bus"
	"linplayer/core/config"
)

// registerTransport 由 RegisterCommands 调用。
func registerTransport() {
	// ---- 起播 / 停播 ----
	bus.Register("player.play", func(ctx context.Context, seq int64, a map[string]any) (any, error) {
		id, _ := a["item_id"].(string)
		if id == "" {
			// ★ 迁移期兼容:探针用 path 直接放本地文件。产品路径一律走 item_id。
			if p, _ := a["path"].(string); p != "" {
				if err := playFile(p); err != nil {
					return nil, bus.NewErr(bus.EInternal, "%v", err)
				}
				return map[string]any{"path": p}, nil
			}
			return nil, bus.NewErr(bus.EInvalid, "缺少 item_id")
		}
		s, err := sessionFrom(a)
		if err != nil {
			return nil, err
		}
		resume, _ := a["resume_secs"].(float64)
		msid, _ := a["media_source_id"].(string)
		/* engine:交给谁去解码渲染。空 / "mpv" = 核心层里的 libmpv(所有平台的默认);
		   "exo" = **调用方自己播**(安卓的 ExoPlayer),核心层只把地址和续播位置算好。
		   ★ 不认识的值一律当 mpv,不报错:内核名是 UI 传上来的字符串,
		     拼错了该退回默认能播,而不是让用户点了播放什么都没有。 */
		engine, _ := a["engine"].(string)
		var out map[string]any
		if engine == "exo" {
			out, err = PlayResolve(ctx, s, id, resume, msid)
		} else {
			out, err = Play(ctx, s, id, resume, msid)
		}
		if err != nil {
			return nil, &bus.Err{Code: bus.ENetwork, Msg: err.Error(), Retryable: true}
		}
		return out, nil
	})

	bus.Register("player.stopPlayback", func(ctx context.Context, seq int64, a map[string]any) (any, error) {
		pos, _ := a["pos"].(float64)
		s, err := sessionFrom(a)
		if err != nil {
			// 没有会话也要能停 —— 停播是本地动作,上报才需要会话
			_ = command("stop")
			return map[string]any{"stopped": true, "reported": false}, nil
		}
		if err := Stop(ctx, s, pos); err != nil {
			return nil, err
		}
		return map[string]any{"stopped": true, "reported": true}, nil
	})

	// reportProgress 播放中定时上报。
	//
	// ★ 三次上报共用同一个 PlaySessionId —— 这里从当前播放目标取,
	//   **不让调用方传**:传错一次就是「看一半退出进度不落地」,而且查不出来。
	bus.Register("emby.reportProgress", func(ctx context.Context, seq int64, a map[string]any) (any, error) {
		t := Current()
		if t == nil {
			// 没在播就上报 = 调用方状态错了,但这不该报错打扰用户
			return map[string]any{"reported": false, "why": "没有正在进行的播放"}, nil
		}
		s, err := sessionFrom(a)
		if err != nil {
			return nil, err
		}
		pos, _ := a["pos"].(float64)
		paused, _ := a["paused"].(bool)
		// ★ 顺手落一次本地观看记录(内部有 10 秒节流)。
		//   放在这里而不是另开一条定时器:上报本来就是「每几秒一次」的节奏,
		//   再开一条只会多一份状态要对齐。
		captureHistory(pos, false)
		if err := prefsClient.ReportProgress(ctx, s, t, pos, paused); err != nil {
			// ★ 上报失败不该冒到用户面前:它每几秒一次,弹一次红字就是刷屏
			bus.Logf("warn", "report_progress 失败: %v", err)
			return map[string]any{"reported": false}, nil
		}
		return map[string]any{"reported": true}, nil
	})

	// ---- 传输控制 ----
	bus.Register("player.seek", func(ctx context.Context, seq int64, a map[string]any) (any, error) {
		pos, ok := a["pos"].(float64)
		if !ok {
			return nil, bus.NewErr(bus.EInvalid, "缺少 pos")
		}
		// absolute+exact:按秒绝对定位。默认的 relative 会把「跳到 300 秒」
		// 变成「往后跳 300 秒」,而且不报错。
		if err := command("seek", strconv.FormatFloat(pos, 'f', 3, 64), "absolute+exact"); err != nil {
			return nil, bus.NewErr(bus.EInternal, "%v", err)
		}
		return map[string]any{"pos": pos}, nil
	})

	bus.Register("player.setPause", func(ctx context.Context, seq int64, a map[string]any) (any, error) {
		paused, _ := a["paused"].(bool)
		setProp("pause", boolStr(paused))
		return map[string]any{"paused": paused}, nil
	})

	bus.Register("player.setSpeed", func(ctx context.Context, seq int64, a map[string]any) (any, error) {
		v, ok := a["speed"].(float64)
		if !ok || v < config.SpeedMin || v > config.SpeedMax {
			return nil, bus.NewErr(bus.EInvalid, "倍速只支持 %.2f~%.2f×", config.SpeedMin, config.SpeedMax)
		}
		// ★ 播放中调倍速**不回写偏好** —— 那是临时调整,回写会让下一部片也变速
		setProp("speed", strconv.FormatFloat(v, 'f', -1, 64))
		return map[string]any{"speed": v}, nil
	})

	bus.Register("player.setVolume", func(ctx context.Context, seq int64, a map[string]any) (any, error) {
		v, ok := a["volume"].(float64)
		if !ok || v < 0 || v > 130 {
			// mpv 支持超过 100 的软增益,上限给 130;再高就是失真了
			return nil, bus.NewErr(bus.EInvalid, "音量只支持 0~130")
		}
		setProp("volume", strconv.FormatFloat(v, 'f', -1, 64))
		return map[string]any{"volume": v}, nil
	})

	bus.Register("player.setMute", func(ctx context.Context, seq int64, a map[string]any) (any, error) {
		m, _ := a["mute"].(bool)
		setProp("mute", boolStr(m))
		return map[string]any{"mute": m}, nil
	})

	bus.Register("player.setHwdec", func(ctx context.Context, seq int64, a map[string]any) (any, error) {
		mode, _ := a["mode"].(string)
		if mode != "auto-safe" && mode != "no" {
			return nil, bus.NewErr(bus.EInvalid, "未知的解码方式: %s", mode)
		}
		setProp("hwdec", mode)
		// ★ 回读确认。「设上了」和「生效了」是两回事:显卡不支持时 mpv 会静默回落,
		//   不回读的话 UI 会显示成硬解而实际在软解。
		return map[string]any{"mode": mode, "current": Prop("hwdec-current")}, nil
	})

	/* 画面比例。
	   ☠☠ 「拉伸填满」<b>不是一个宽高比</b>,是「别保持宽高比」这件事(mpv 的 keepaspect)。
	     原来这一档把 "-2" 当成比例塞给 video-aspect-override —— mpv 认不出这个值,
	     **静默无视**,于是这一档点了永远没反应,而且返回值还是成功的。
	     (用户 2026-09-04:「播放页的控制面板 字幕 超分 比例 这些全都不生效」——
	      面板被自动收走是主因,而这一档是它自己另外坏的。)
	   ★ 切回别的档要把 keepaspect 放回 yes,不然拉伸过一次之后就再也回不去了。 */
	bus.Register("player.setAspectRatio", func(ctx context.Context, seq int64, a map[string]any) (any, error) {
		r, _ := a["ratio"].(string)
		if r == "-2" {
			setProp("keepaspect", "no")
			return map[string]any{"ratio": r, "keepaspect": "no"}, nil
		}
		setProp("keepaspect", "yes")
		setProp("video-aspect-override", r)
		return map[string]any{"ratio": r, "keepaspect": "yes"}, nil
	})

	bus.Register("player.setSubDelay", func(ctx context.Context, seq int64, a map[string]any) (any, error) {
		v, _ := a["secs"].(float64)
		setProp("sub-delay", strconv.FormatFloat(v, 'f', 3, 64))
		return map[string]any{"secs": v}, nil
	})
	bus.Register("player.setAudioDelay", func(ctx context.Context, seq int64, a map[string]any) (any, error) {
		v, _ := a["secs"].(float64)
		setProp("audio-delay", strconv.FormatFloat(v, 'f', 3, 64))
		return map[string]any{"secs": v}, nil
	})

	// setTrack 切轨。kind = "audio" | "sub" | "video"。
	bus.Register("player.setTrack", func(ctx context.Context, seq int64, a map[string]any) (any, error) {
		kind, _ := a["kind"].(string)
		id, _ := a["id"].(string)
		prop := map[string]string{"audio": "aid", "sub": "sid", "video": "vid"}[kind]
		if prop == "" {
			return nil, bus.NewErr(bus.EInvalid, "未知的轨道类型: %s", kind)
		}
		if id == "" {
			id = "no" // 空 = 关掉这一路(关字幕就是 sid=no)
		}
		setProp(prop, id)
		return map[string]any{"kind": kind, "id": id}, nil
	})

	// addSubtitle 手动挂一条外挂字幕。
	//
	// ★ 和起播时那批不同:这条是用户主动加的,**要自动切过去**(flags=select),
	//   否则用户加完发现什么都没变。
	bus.Register("player.addSubtitle", func(ctx context.Context, seq int64, a map[string]any) (any, error) {
		u, _ := a["url"].(string)
		if u == "" {
			return nil, bus.NewErr(bus.EInvalid, "缺少 url")
		}
		title, _ := a["title"].(string)
		if title == "" {
			title = "外挂字幕"
		}
		if err := command("sub-add", u, "select", title); err != nil {
			return nil, bus.NewErr(bus.EInternal, "%v", err)
		}
		return map[string]any{"url": u, "title": title}, nil
	})

	// ---- 直通 mpv(设置页的高级项 / 自检用)----
	bus.Register("player.mpvCommand", func(ctx context.Context, seq int64, a map[string]any) (any, error) {
		raw, _ := a["args"].([]any)
		args := make([]string, 0, len(raw))
		for _, v := range raw {
			if s, ok := v.(string); ok {
				args = append(args, s)
			}
		}
		if len(args) == 0 {
			return nil, bus.NewErr(bus.EInvalid, "args 是空的")
		}
		if err := command(args...); err != nil {
			return nil, bus.NewErr(bus.EInternal, "%v", err)
		}
		return map[string]any{"ok": true}, nil
	})
	bus.Register("player.mpvGet", func(ctx context.Context, seq int64, a map[string]any) (any, error) {
		name, _ := a["name"].(string)
		if name == "" {
			return nil, bus.NewErr(bus.EInvalid, "缺少 name")
		}
		v := Prop(name)
		if v == "" {
			return map[string]any{"name": name, "value": nil}, nil
		}
		return map[string]any{"name": name, "value": v}, nil
	})
	bus.Register("player.mpvSet", func(ctx context.Context, seq int64, a map[string]any) (any, error) {
		name, _ := a["name"].(string)
		value, _ := a["value"].(string)
		if name == "" {
			return nil, bus.NewErr(bus.EInvalid, "缺少 name")
		}
		setProp(name, value)
		return map[string]any{"name": name, "value": value}, nil
	})

	// status 当前播放状态。
	//
	// ★ 判「播完」必须读 **eof-reached 属性**,不能等 END_FILE 事件 ——
	//   keep-open=yes 时文件不卸载,END_FILE **永远不发**。
	//   这是「播完不同步 Trakt/Bangumi」的根因。
	bus.Register("player.status", func(ctx context.Context, seq int64, a map[string]any) (any, error) {
		t := Current()
		out := map[string]any{
			"position": propF("time-pos"),
			"duration": propF("duration"),
			"paused":   Prop("pause") == "yes",
			"eof":      Prop("eof-reached") == "yes",
			"speed":    propF("speed"),
			"volume":   propF("volume"),
			"mute":     Prop("mute") == "yes",
			"hwdec":    Prop("hwdec-current"),
			// buffered 已缓冲到哪一秒(绝对位置,不是「还剩多少」)。
			//
			// ★★ demuxer-cache-time 给的是**缓冲前沿的绝对时间**,而不是长度 ——
			//   写成 position + 它 会算出双倍。进度条上那条浅色的「已缓冲」段
			//   直接用这个值当右端。
			// ★ 没有缓存(本地文件 / 属性拿不到)时是 0,UI 就当没有这一段,不画。
			"buffered": propF("demuxer-cache-time"),
			// cached 「哪几段的字节已经在本地」,占全片的比例。
			//
			// ★★ 和 buffered **不是一回事**:buffered 是 mpv 解复用缓存的前沿(一个数),
			//   cached 是本地环形缓存里真实躺着的区间(可能好几段,而且能在播放头**后面**)。
			//   进度条上「这段能看缩略图」画的是它 —— 因为缩略图正是从这些字节里解出来的。
			"cached": cachedSpans(),
			// cached_kind:proxy / file / none。见 localSource 的注释。
			"cached_kind": cachedKind(),
			/* avsync 音画差(秒)。**给自检当判据用的**,UI 不显示。

			   ★★ 它是「画面抽不抽搐」唯一量得出来的东西。用户说的「抽搐」
			   在截图上一个像素都看不出来,而 mpv 自己一直在算这个数:
			   授时正常时它贴着 0 抖(±0.01),关掉 block_for_target_time 之后
			   帧按解码完成时刻上屏,它就会越漂越远。见 GLRender 的注释。
			   ★ 没在播 / 拿不到时 propF 给 -1,自检按「没数」处理。 */
			"avsync": propF("avsync"),
			// drops 解码器丢帧数。抽搐的另一种成因(机器扛不住),和授时分得开。
			"drops": propF("frame-drop-count"),
			/* ★★ vo_delayed 是**画面稳不稳的最终判据**,比 frame_jitter_ms 硬:
			   它是 mpv 自己数的「上屏晚于目标时刻的帧数」,而它的输入是我们
			   report_swap 报上去的真实上屏时刻 —— 和授时到底由谁做无关。

			   frame_jitter_ms 量的是**我们发起 render 的时刻**。block_for_target_time=1
			   的时候那一刻就是呈现时刻(mpv 在里面等到点才放行),所以它当判据成立;
			   授时挪出合成线程之后,发起 render 的时刻被合成心跳量化了,那个数会变大
			   而画面并没有变差 —— 拿它继续当判据会得出反的结论。 */
			// aspect_override 自检对账用:控件显示 16:9 而 mpv 没收到,两者长得一样。
			"aspect_override": propF("video-aspect-override"),
			"vo_delayed": propF("vo-delayed-frame-count"),
			"vsync_jitter": propF("vsync-jitter"),
		}
		/* ★★ 出帧节奏:相邻两次上屏的**间隔抖动**。见 player.go 的 noteCadence。
		   这是「画面抽搐」唯一量得出来的东西 —— avsync 量不出来(实测关掉授时
		   它照样 0.0ms),截图更量不出来。 */
		if mean, jit, n := Cadence(); n >= 2 {
			out["frame_gap_ms"] = mean
			out["frame_jitter_ms"] = jit
			out["frame_samples"] = n
		}
		/* render 调用**本身**堵了多久。它跑在宿主合成线程上,堵多久界面就多久不动。
		   render_calls = 合成帧数(每个合成帧都渲),advance_calls = 其中推进了一帧的次数。 */
		/* 累计量,不是区间量 —— 自检要哪一段的数就自己前后各读一次做差。
		   为此专门加一条命令的话,三端绑定表都得跟着改,而它只有自检会调。 */
		if sum, mx, slow, n := RenderCost(); n >= 2 {
			out["render_ms_sum"] = sum
			out["render_ms_max"] = mx
			out["render_slow16"] = slow
			out["render_calls"] = n
			out["advance_calls"] = AdvanceCalls()
		}
		// 画面比 mpv 给的呈现时刻早多少 = 画面比声音早多少。见 player.go 的 noteLead。
		if mean, n := Lead(); n >= 2 {
			out["lead_ms"] = mean
			out["lead_samples"] = n
		}
		if t != nil {
			out["item_id"] = t.ItemID
			out["play_session_id"] = t.PlaySessionID
			out["media_source_id"] = t.MediaSourceID
		}
		return out, nil
	})

	registerApplyPrefs()
	registerExternalCommands()
	registerLocalCommands()

	// tracks 当前文件的轨道表。
	bus.Register("player.tracks", func(ctx context.Context, seq int64, a map[string]any) (any, error) {
		return parseTracks(Prop("track-list")), nil
	})
}

// Track 一条轨道。
type Track struct {
	ID       string `json:"id"`
	Kind     string `json:"kind"` // audio | sub | video
	Title    string `json:"title"`
	Lang     string `json:"lang"`
	Default  bool   `json:"default"`
	Selected bool   `json:"selected"`
	External bool   `json:"external"`
	// FFIndex 这条轨在**容器里的流序号**(mpv 的 `ff-index`)。
	//
	// ★★ 详情页「播放前先选好音轨/字幕」靠它对号入座:详情页手里只有 Emby 的
	// `MediaStream.Index`(也是容器流序号),而那会儿 mpv 还没起、没有 track-list。
	// 用 `id` 对不上 —— mpv 的 id 是**按类型各自从 1 开始重编**的,
	// 和容器流序号是两套编号,混用的表现是「选了第 2 条日语,放出来是英语」。
	// ★ 外挂字幕没有 ff-index,mpv 给 -1;调用方按 -1 判「对不上号」。
	FFIndex int64 `json:"ff_index"`
}

// parseTracks 解析 mpv 的 track-list。
//
// ★ mpv 给的是 JSON,但 `mpv_get_property_string("track-list")` 返回的就是一坨 JSON 串。
// 解不动时返回**空表不是 nil** —— 调用方拿到 null 直接遍历会抛错。
func parseTracks(raw string) []Track {
	out := []Track{}
	if strings.TrimSpace(raw) == "" {
		return out
	}
	var list []struct {
		ID       int64   `json:"id"`
		Type     string  `json:"type"`
		Title    *string `json:"title"`
		Lang     *string `json:"lang"`
		Default  bool    `json:"default"`
		Selected bool    `json:"selected"`
		External bool    `json:"external"`
		FFIndex  *int64  `json:"ff-index"`
	}
	if err := json.Unmarshal([]byte(raw), &list); err != nil {
		bus.Logf("warn", "track-list 解不动: %v", err)
		return out
	}
	for _, t := range list {
		kind := t.Type
		if kind == "sub" || kind == "audio" || kind == "video" {
			ff := int64(-1)
			if t.FFIndex != nil {
				ff = *t.FFIndex
			}
			out = append(out, Track{
				ID: strconv.FormatInt(t.ID, 10), Kind: kind,
				Title: strDeref(t.Title), Lang: strDeref(t.Lang),
				Default: t.Default, Selected: t.Selected, External: t.External,
				FFIndex: ff,
			})
		}
	}
	return out
}

func strDeref(p *string) string {
	if p == nil {
		return ""
	}
	return *p
}

func boolStr(b bool) string {
	if b {
		return "yes"
	}
	return "no"
}
