package player

import (
	"testing"

	"linplayer/core/config"

	"linplayer/core/emby"
)

// track-list 解析。
//
// ★ 解不动时返回**空表不是 nil** —— 调用方拿到 null 直接遍历会抛错,
// 在透明窗口下就是一片黑且不报错。
func TestParseTracks(t *testing.T) {
	for _, bad := range []string{"", "   ", "不是 JSON", "{}"} {
		got := parseTracks(bad)
		if got == nil {
			t.Fatalf("%q 应返回空表而不是 nil", bad)
		}
		if len(got) != 0 {
			t.Fatalf("%q 不该解出轨道: %+v", bad, got)
		}
	}

	raw := `[
		{"id":1,"type":"video","selected":true},
		{"id":2,"type":"audio","lang":"jpn","title":"日语","default":true,"selected":true},
		{"id":3,"type":"sub","lang":"chi","external":true},
		{"id":4,"type":"其它没见过的类型"}
	]`
	got := parseTracks(raw)
	if len(got) != 3 {
		t.Fatalf("不认识的轨道类型要丢掉,实得 %d 条: %+v", len(got), got)
	}
	if got[1].Kind != "audio" || got[1].Lang != "jpn" || got[1].Title != "日语" ||
		!got[1].Default || !got[1].Selected {
		t.Fatalf("音轨字段不对: %+v", got[1])
	}
	if got[2].Kind != "sub" || !got[2].External {
		t.Fatalf("外挂字幕轨没标出来: %+v —— UI 分不出内封和外挂", got[2])
	}
	// id 要是字符串:切轨时直接喂 mpv 的 aid/sid,而那两个属性认 "no" 这种非数字值
	if got[0].ID != "1" {
		t.Fatalf("轨道 id 该是字符串: %q", got[0].ID)
	}
}

// ★★ 外挂字幕**必须等 FILE_LOADED 才挂**。
//
// loadfile 只是排队就返回,紧跟着调 sub-add 必定拿到 -12(MPV_ERROR_COMMAND),
// 而当年那句 `let _ =` 把它吞了 —— 表现就是「外挂字幕挂了等于没挂」。
//
// 这条测试只钉**排队与取用**这一半(挂载本身要真 mpv):
// 记进 pendingSubs 之后,onFileLoaded 必须把它们取走且只取一次。
func TestPendingSubs等FileLoaded才取走(t *testing.T) {
	currentMu.Lock()
	pendingSubs = []emby.ExternalSub{{URL: "http://h/a.ass", Title: "简体"}, {URL: "http://h/b.srt", Title: "英文"}}
	currentMu.Unlock()

	onFileLoaded() // mpv 没起来,sub-add 会失败并记日志 —— 这里只看队列有没有被取走

	currentMu.Lock()
	left := pendingSubs
	currentMu.Unlock()
	if len(left) != 0 {
		t.Fatalf("FILE_LOADED 之后待挂队列该清空,实得 %d 条", len(left))
	}

	// 再来一次不该重复挂(换片时上一片的字幕不能跟过来)
	onFileLoaded()
	currentMu.Lock()
	left = pendingSubs
	currentMu.Unlock()
	if len(left) != 0 {
		t.Fatalf("重复的 FILE_LOADED 不该凭空冒出待挂字幕: %+v", left)
	}
}

// 杜比视界 + 「自动软解」开着时,hwdec 要被压成 no。
//
// ★ 判据用 VideoRangeType 不是 VideoRange —— 只看 HDR 会把 HDR10 一起误判成 DV,
// 白白掉进软解、白白卡顿。那部分在 emby.hasDolbyVision 里测,这里只测「压不压」。
func TestApplyPlaybackDefaults(t *testing.T) {
	// 这条不碰 mpv(没起来时 setProp 是空操作),只验它不 panic 且分支走对。
	// 真正的「hwdec 有没有生效」要回读 mpv 的 hwdec-current,那是真机自检的事。
	defer func() {
		if r := recover(); r != nil {
			t.Fatalf("不该 panic: %v", r)
		}
	}()
	p := config.DefaultPrefs()
	applyPlaybackDefaults(p, false)
	applyPlaybackDefaults(p, true)
	p.DolbyAutoSW = false
	applyPlaybackDefaults(p, true)
}
