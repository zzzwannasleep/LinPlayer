package sourcecmd

// 源给的外挂字幕 → 播放器认的形状。
//
// ★ 单独一个文件是为了把 emby 这个 import 关在一处:
// 外挂字幕的挂载结构定义在 core/emby(它是先长出来的那一边),
// 而源播放要复用同一套挂载逻辑 —— 复制一份形状出来只会有两份要同步。

import "linplayer/core/emby"

type embySub struct {
	URL   string
	Title string
}

func toEmbySubs(in []embySub) []emby.ExternalSub {
	out := make([]emby.ExternalSub, 0, len(in))
	for _, s := range in {
		out = append(out, emby.ExternalSub{URL: s.URL, Title: s.Title})
	}
	return out
}
