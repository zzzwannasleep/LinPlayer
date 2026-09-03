package player

import "testing"

// 判据:mpv 事件 id 必须和 client.h 对得上。
//
// ☠☠ 这是一条**钉子**,不是行为测试 —— 因为这里栽过一次而且栽得很静:
// evFileLoaded 写成了 6,可 6 是 START_FILE(8 才是 FILE_LOADED)。
// 于是 onFileLoaded 里的 sub-add 在文件还没打开时就发,mpv 回 -12,
// 错误只进日志 —— 用户看到的是「外挂字幕挂了等于没挂」,一句报错都没有。
//
// ★ 期望值是**实测**出来的,不是抄文档:ctypes 直打 build/core/libmpv-2.dll,
//   loadfile 之后事件依次是 6 → 8 → 17 → 21。
func Test事件id和clienth对得上(t *testing.T) {
	for _, c := range []struct {
		name      string
		got, want int
	}{
		{"MPV_EVENT_LOG_MESSAGE", evLogMessage, 2},
		{"MPV_EVENT_START_FILE", evStartFile, 6},
		{"MPV_EVENT_END_FILE", evEndFile, 7},
		{"MPV_EVENT_FILE_LOADED", evFileLoaded, 8},
		{"MPV_EVENT_PLAYBACK_RESTART", evPlaybackRestart, 21},
	} {
		if c.got != c.want {
			t.Errorf("%s 应当是 %d,实得 %d", c.name, c.want, c.got)
		}
	}
}
