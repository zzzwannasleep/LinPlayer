package history

import (
	"testing"
)

// 手动标「已看」之后,本地观看记录也得跟着改。
//
// ☠☠ 原来 `emby.setPlayed` **只写服务器**,本地记录纹丝不动。两条静默的错路:
//
//	· 跨服续播:换一台服务器接着看,会从那条旧记录的位置起播
//	· 跨服回传:把那个旧进度写回**别人的服务器**
//
// 两条都不报错,用户只会觉得「标了没用」。
//
// ★ 断言必须**同时**验「记录里的 Played 变了」和「续播解析不再给位置」——
// 只验前者的话,一个改了标志位却没清进度的实现照样绿,
// 而用户看到的正是「写着已看完,点进去从 8 分钟开始放」。
func Test手动标已看要落到本地记录(t *testing.T) {
	s := newStore(t)
	scope := ScopeKey("https://a", "u")
	cand := epCandidate("it1")

	// 先看了一半
	s.Capture(CaptureOpts{ScopeKey: scope, Candidate: cand, SeriesTmdbID: sp("s1"),
		PositionTicks: 500 * TicksPerSec, WatchedThresholdPercent: 90, Force: true})
	remote := int64(0)
	if got := s.ResolveResumeTicks(scope, cand, sp("s1"), &remote, false, false); got == nil || *got != 500*TicksPerSec {
		t.Fatalf("前置条件不成立:该续播 500 秒,实得 %v", ticks(got))
	}

	// 用户手动标「已看」
	yes := true
	rec := s.Capture(CaptureOpts{ScopeKey: scope, Candidate: cand, SeriesTmdbID: sp("s1"),
		Source: SourceInternal, ForcePlayed: &yes, Force: true})
	if rec == nil || !rec.Played {
		t.Fatal("手动标已看之后,记录里的 Played 应当是 true")
	}
	if got := s.ResolveResumeTicks(scope, cand, sp("s1"), &remote, false, false); got != nil {
		t.Fatalf("标了已看还给续播位置 %v —— 用户会看到「写着已看完,点进去从中间开始放」", ticks(got))
	}

	// 再手动标「未看」:标志位和进度都要回到干净状态
	no := false
	rec = s.Capture(CaptureOpts{ScopeKey: scope, Candidate: cand, SeriesTmdbID: sp("s1"),
		Source: SourceInternal, ForcePlayed: &no, Force: true})
	if rec == nil || rec.Played {
		t.Fatal("手动标未看之后,记录里的 Played 应当是 false")
	}
	// 进度也要被覆盖掉:留着旧进度 = 「标了未看还是从中间放」
	if rec.LastPositionTicks != 0 {
		t.Fatalf("标未看之后进度该归零,实得 %d", rec.LastPositionTicks)
	}
}

// 片长未知时也要标得上。
//
// ☠ 这正是**不能**拿「位置 = 片长 + 阈值 100%」去凑 ForcePlayed 的理由:
// RunTimeTicks 为 nil 时 isPlayed 恒为 false,于是「标记为已看」会静默地什么都没标上,
// 而服务器那边已经标上了 —— 两边从此对不上,且无人报错。
func Test片长未知也标得上已看(t *testing.T) {
	s := newStore(t)
	scope := ScopeKey("https://a", "u")
	cand := epCandidate("it-noruntime")
	cand.RunTimeTicks = nil

	yes := true
	rec := s.Capture(CaptureOpts{ScopeKey: scope, Candidate: cand, SeriesTmdbID: sp("s1"),
		Source: SourceInternal, ForcePlayed: &yes, Force: true})
	if rec == nil || !rec.Played {
		t.Fatal("片长未知时手动标已看也必须标上 —— 服务器那边已经标了,本地不能掉队")
	}
}

// 阈值字段没填(零值)时,**不许把所有记录都判成已看完**。
//
// ☠☠ 0 的字面含义是「位置 ≥ 0 就算看完」—— 每一条落进来的记录都是已看完。
// 而 0 从来不是谁的本意,它是「调用方忘了填这个字段」的样子(Go 的缺省是零值)。
// 把「忘了填」翻译成「全都看完了」是这一层最贵的一种沉默:
// 用户的库会在某次重构之后一夜之间全变成已看,而没有任何东西报错。
func Test阈值忘了填不许判成已看完(t *testing.T) {
	s := newStore(t)
	scope := ScopeKey("https://a", "u")
	cand := epCandidate("it-zero")
	// 注意:**没有** WatchedThresholdPercent 这个字段
	rec := s.Capture(CaptureOpts{ScopeKey: scope, Candidate: cand, SeriesTmdbID: sp("s1"),
		PositionTicks: 1 * TicksPerSec, Source: SourceInternal, Force: true})
	if rec == nil {
		t.Fatal("记录没落下来")
	}
	if rec.Played {
		t.Fatal("阈值字段没填时把记录判成了已看完 —— 才放了 1 秒")
	}
}
