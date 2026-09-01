package history

import "testing"

func i64(v int64) *int64 { return &v }

// ★★ 服务器上已经有同等或更靠后的进度时,**不要回写** —— 只更新本地的匹配信息。
//
// 无脑回写的后果是把用户在这台服务器上看到的更靠后的进度**倒回去**。
// 那是恢复功能能造成的最严重的伤害:它本来是来救进度的。
func TestRestoreAction_服务器更靠后时不回写(t *testing.T) {
	rec := Record{Played: false, LastPositionTicks: 100 * TicksPerSec}
	// 服务器已经播到 500 秒 —— 比本地靠后
	ahead := Candidate{ID: "x", PositionTicks: 500 * TicksPerSec}
	if got := RestoreAction(rec, ahead, ConfStrong); got != ActionUpdateOnly {
		t.Fatalf("服务器更靠后却判成 %v —— 会把用户的进度倒回去", got)
	}
	// 服务器什么都没有 —— 该恢复
	behind := Candidate{ID: "x"}
	if got := RestoreAction(rec, behind, ConfStrong); got != ActionAuto {
		t.Fatalf("强匹配 + 服务器没进度,应当自动恢复,实得 %v", got)
	}
}

// ★★ 只有**强匹配**才自动写。
//
// 可能匹配交给用户确认,弱匹配 / 不匹配直接放过 —— 自动写弱匹配的后果是
// 把进度写到另一部片上,而且看起来一切正常。
func TestRestoreAction_按置信度分流(t *testing.T) {
	rec := Record{Played: true}
	item := Candidate{ID: "x"}
	cases := map[Confidence]Action{
		ConfStrong:   ActionAuto,
		ConfPossible: ActionPrompt,
		ConfWeak:     ActionIgnore,
		ConfNone:     ActionIgnore,
	}
	for conf, want := range cases {
		if got := RestoreAction(rec, item, conf); got != want {
			t.Fatalf("置信度 %v 应当 %v,实得 %v", conf, want, got)
		}
	}
}

// ★ 已看完 → 标记已看;有进度 → 上报三连;都没有 → 无可写(**不是失败**)。
func TestRestoreWrite(t *testing.T) {
	if k, _ := RestoreWrite(Record{Played: true, LastPositionTicks: 5}); k != WriteMarkPlayed {
		t.Fatalf("已看完应当标记已看,实得 %v", k)
	}
	k, ticks := RestoreWrite(Record{LastPositionTicks: 123})
	if k != WriteProgress || ticks != 123 {
		t.Fatalf("有进度应当上报进度,实得 %v/%d", k, ticks)
	}
	if k, _ := RestoreWrite(Record{}); k != WriteNothing {
		t.Fatalf("没看完也没进度,应当无可写,实得 %v", k)
	}
}

// ★★ 兜底只对「本地已看完」成立,而且必须有时长。
//
// 兜底的做法是「定位到片尾再 stopped,让服务器自己判已看」——
// 对一条只看了一半的记录这么干,等于把它标成看完了。
func TestRestoreFallbackTicks(t *testing.T) {
	item := Candidate{RunTimeTicks: i64(9000)}
	if got, ok := RestoreFallbackTicks(Record{Played: true}, item); !ok || got != 9000 {
		t.Fatalf("已看完 + 条目带时长,应当拿条目的时长,实得 %d/%v", got, ok)
	}
	// 条目没时长时退回记录自己记的
	if got, ok := RestoreFallbackTicks(Record{Played: true, RunTimeTicks: i64(7000)}, Candidate{}); !ok || got != 7000 {
		t.Fatalf("应当退回记录里的时长,实得 %d/%v", got, ok)
	}
	// ★ 没看完的**绝不能**兜底 —— 那会把它标成看完
	if _, ok := RestoreFallbackTicks(Record{Played: false, RunTimeTicks: i64(7000)}, item); ok {
		t.Fatal("没看完的记录不该走兜底 —— 会被标成看完了")
	}
	// 两边都没有时长 → 没法兜底
	if _, ok := RestoreFallbackTicks(Record{Played: true}, Candidate{}); ok {
		t.Fatal("拿不到时长时没法兜底")
	}
}
