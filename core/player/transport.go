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
		out, err := Play(ctx, s, id, resume, msid)
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

	bus.Register("player.setAspectRatio", func(ctx context.Context, seq int64, a map[string]any) (any, error) {
		r, _ := a["ratio"].(string)
		setProp("video-aspect-override", r)
		return map[string]any{"ratio": r}, nil
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
		}
		if t != nil {
			out["item_id"] = t.ItemID
			out["play_session_id"] = t.PlaySessionID
			out["media_source_id"] = t.MediaSourceID
		}
		return out, nil
	})

	registerApplyPrefs()
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
	}
	if err := json.Unmarshal([]byte(raw), &list); err != nil {
		bus.Logf("warn", "track-list 解不动: %v", err)
		return out
	}
	for _, t := range list {
		kind := t.Type
		if kind == "sub" || kind == "audio" || kind == "video" {
			out = append(out, Track{
				ID: strconv.FormatInt(t.ID, 10), Kind: kind,
				Title: strDeref(t.Title), Lang: strDeref(t.Lang),
				Default: t.Default, Selected: t.Selected, External: t.External,
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
