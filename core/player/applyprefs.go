package player

// prefs.applyPrefs —— 把选轨偏好应用到**当前正在播的这个文件**。
//
// 移植自 `apps/desktop/src/lib.rs` 的 apply_prefs。
//
// ★★ 它和 `prefs.setPrefs` 是两件事:后者只是把偏好存起来,而这条是「现在就按偏好
// 重选一遍音轨字幕」。用户在播放中改了字幕语言,不调这条的话要退出重进才生效。
//
// ★★ 判据是 **mpv 真的切了轨**,不是「我们算出了一个 id」——
// 「设了没反应」那一族 bug 全长在这中间:算对了但没设下去,或者设下去了但 mpv 拒了。

import (
	"context"
	"strconv"
	"strings"

	"linplayer/core/bus"
	"linplayer/core/config"
	"linplayer/core/media"
)

// registerApplyPrefs 注册 prefs.applyPrefs。
//
// ★ 放在 player 包而不是 prefs 包:它要读 mpv 的 track-list 并下 sid/aid ——
// 而 prefs 包不该知道 mpv 的存在。
func registerApplyPrefs() {
	bus.Register("prefs.applyPrefs", func(ctx context.Context, seq int64, a map[string]any) (any, error) {
		tracks := parseTracks(Prop("track-list"))
		if len(tracks) == 0 {
			return nil, bus.NewErr(bus.EInvalid, "现在没有正在播放的文件")
		}
		p := config.Current().PrefsOf()

		aid := pickTrack(tracks, "audio", p.AudioLang, p.AudioRegex)
		sid := ""
		if p.SubEnabled {
			sid = pickTrack(tracks, "sub", p.SubLang, p.SubRegex)
		}

		// ★ 字幕关掉时要显式设 `no`,不是「不管它」——
		//   不管的话上一片选中的字幕轨会一路留着(mpv 的属性是实例级的)。
		if p.SubEnabled {
			if sid != "" {
				setProp("sid", sid)
			}
		} else {
			setProp("sid", "no")
		}
		if aid != "" {
			setProp("aid", aid)
		}

		// ★★ 回读 mpv 真正生效的值,而不是回我们刚算的那个。
		//   两者不一致正是「设了没反应」的现场 —— 不回读就永远看不见。
		return map[string]any{
			"audio": Prop("aid"),
			"sub":   Prop("sid"),
		}, nil
	})
}

// pickTrack 按语言 + 正则挑一条轨。返回 mpv 的轨道 id;挑不出返回空串。
//
// ★ 顺序是**正则优先于语言**:正则是用户明确写下的规则,语言只是个粗筛。
// 反过来的话用户写的正则永远轮不到生效 —— 那正是「设了正则没反应」的一种。
func pickTrack(tracks []Track, kind string, lang *string, pattern string) string {
	var (
		texts []string
		ids   []string
	)
	for _, t := range tracks {
		if t.Kind != kind {
			continue
		}
		// ★ 正则匹配的是「标题 + 语言」拼起来的串:用户写 `简体|中文` 时,
		//   有的源把它放在标题里,有的放在 lang 里
		texts = append(texts, strings.TrimSpace(t.Title+" "+t.Lang))
		ids = append(ids, t.ID)
	}
	if len(ids) == 0 {
		return ""
	}
	if strings.TrimSpace(pattern) != "" {
		if i := media.PickIndex(texts, pattern); i >= 0 {
			return ids[i]
		}
	}
	if lang != nil && strings.TrimSpace(*lang) != "" {
		want := strings.ToLower(strings.TrimSpace(*lang))
		for i, t := range tracks {
			_ = i
			if t.Kind == kind && strings.ToLower(t.Lang) == want {
				return t.ID
			}
		}
	}
	return ""
}

// PlayLocal 播放一个**已经下载好**的条目。
//
// ★ 索引说完成了不代表文件还在(用户可能手动删了 / 挪走了)——
// 放给 mpv 之前先确认,否则表现是「点了播放,黑屏,什么都不说」。
func PlayLocal(path string, resumeSecs float64) (map[string]any, error) {
	if err := loadWith(path, resumeSecs, nil, ""); err != nil {
		return nil, err
	}
	// ★ 本地文件**不走 Emby 上报**,也没有观看记录上下文 —— 清掉,
	//   否则会把本地文件的进度记到上一部 Emby 片上。
	currentMu.Lock()
	current = nil
	currentCtx = nil
	pendingSubs = nil
	currentMu.Unlock()
	return map[string]any{"resume_secs": resumeSecs}, nil
}

var _ = strconv.Itoa
