package history

import (
	"os"
	"path/filepath"
	"testing"
)

func newStore(t *testing.T) *Store {
	t.Helper()
	return New(filepath.Join(t.TempDir(), "watch_history.json"))
}

func epCandidate(id string) Candidate {
	rt := int64(1400) * TicksPerSec
	return Candidate{
		ID: id, Type: "Episode", Name: "第 3 集", SeriesName: sp("某剧"),
		SeasonNo: ip(1), EpisodeNo: ip(3), RunTimeTicks: &rt,
	}
}

// 损坏 / 缺失的观看记录**一律当空文档**,不能挡住播放。
//
// ★ 和 config 相反:配置坏了必须报错(那会覆盖用户的账号);
// 观看记录坏了最多丢一些进度,而挡住播放的代价大得多。
func TestLoadDocument坏了当空(t *testing.T) {
	s := newStore(t)
	if got := s.LoadDocument(); len(got.Records) != 0 {
		t.Fatal("文件不存在时该是空文档")
	}
	if err := os.WriteFile(s.path, []byte("{这不是 JSON"), 0o644); err != nil {
		t.Fatal(err)
	}
	if got := s.LoadDocument(); len(got.Records) != 0 {
		t.Fatal("解析失败时该当空文档,不能报错挡住播放")
	}
	// 空列表要是 [] 不是 null:调用方直接遍历 null 会抛错
	if s.LoadAll() == nil || s.LoadScope("x") == nil {
		t.Fatal("空结果要给空切片不是 nil")
	}
}

// 落一条记录再读回来。
func TestCapture往返(t *testing.T) {
	s := newStore(t)
	scope := ScopeKey("https://a", "u")
	rec := s.Capture(CaptureOpts{
		ScopeKey: scope, Candidate: epCandidate("it1"), SeriesTmdbID: sp("s1"),
		PositionTicks: 300 * TicksPerSec, WatchedThresholdPercent: 90,
	})
	if rec == nil {
		t.Fatal("该落得下")
	}
	if rec.CanonicalKey != "series:tmdb:s1:s01:e03" {
		t.Fatalf("canonicalKey 不对: %q", rec.CanonicalKey)
	}
	if rec.Played {
		t.Fatal("看了 300/1400 不该算看完")
	}
	if rec.PlayCount != 1 {
		t.Fatalf("首次记录 play_count 该是 1,实得 %d", rec.PlayCount)
	}
	got := s.LoadScope(scope)
	if len(got) != 1 || got[0].RecordID != rec.RecordID {
		t.Fatalf("读回来不对: %+v", got)
	}
	// 别的 scope 读不到
	if len(s.LoadScope(ScopeKey("https://b", "u"))) != 0 {
		t.Fatal("别的服务器不该读到这条")
	}
}

// ★ 节流:同一条记录 10 秒内重复调用不落盘。
//
// 不节流的话一部两小时的片子会往盘上写 7200 次「读-改-写整份文档」。
// 但 Force 要能穿透 —— 停播那一下必须落,否则最后几秒的进度丢了。
func TestCapture节流与Force(t *testing.T) {
	s := newStore(t)
	scope := ScopeKey("https://a", "u")
	base := CaptureOpts{ScopeKey: scope, Candidate: epCandidate("it1"), SeriesTmdbID: sp("s1"),
		WatchedThresholdPercent: 90}

	b1 := base
	b1.PositionTicks = 100 * TicksPerSec
	s.Capture(b1)

	b2 := base
	b2.PositionTicks = 200 * TicksPerSec
	s.Capture(b2) // 10 秒内,该被节流

	if got := s.LoadScope(scope)[0].LastPositionTicks; got != 100*TicksPerSec {
		t.Fatalf("10 秒内的第二次该被节流掉,实得 %d", got/TicksPerSec)
	}

	b3 := base
	b3.PositionTicks = 300 * TicksPerSec
	b3.Force = true
	s.Capture(b3)
	if got := s.LoadScope(scope)[0].LastPositionTicks; got != 300*TicksPerSec {
		t.Fatalf("Force 必须穿透节流,实得 %d —— 否则停播时最后几秒的进度丢了", got/TicksPerSec)
	}
}

// canonicalKey 变了(终于查到 TMDB id)→ 旧记录要删掉,不然一份内容两条。
func TestCapture换键时删旧记录(t *testing.T) {
	s := newStore(t)
	scope := ScopeKey("https://a", "u")
	// 第一次:没有剧 TMDB,键退到「剧名 + 季集号」
	first := s.Capture(CaptureOpts{ScopeKey: scope, Candidate: epCandidate("it1"),
		PositionTicks: 100 * TicksPerSec, WatchedThresholdPercent: 90, Force: true})
	if first.CanonicalKey != "episode:title:某剧:s01:e03" {
		t.Fatalf("前提不成立: %q", first.CanonicalKey)
	}
	// 第二次:查到了剧 TMDB,键变成 series:tmdb:...
	second := s.Capture(CaptureOpts{ScopeKey: scope, Candidate: epCandidate("it1"),
		SeriesTmdbID: sp("s1"), PositionTicks: 200 * TicksPerSec,
		WatchedThresholdPercent: 90, Force: true})
	if second.CanonicalKey == first.CanonicalKey {
		t.Fatal("前提不成立:键该变了")
	}
	got := s.LoadScope(scope)
	if len(got) != 1 {
		t.Fatalf("换键之后该只剩一条,实得 %d 条 —— 「继续观看」里同一集会出现两次:%+v", len(got), got)
	}
	// play_count 要继承,不是从头再来
	if got[0].PlayCount != 1 {
		t.Fatalf("换键不该重置 play_count,实得 %d", got[0].PlayCount)
	}
	// 首次观看时间也要继承
	if got[0].EffectiveFirstPlayedAt() != first.EffectiveFirstPlayedAt() {
		t.Fatal("换键不该重置首次观看时间")
	}
}

// ★★ 续播位置取**最大值**:远端 ∪ 本服本地 ∪(可选)其它服务器。
func TestResolveResumeTicks取最大(t *testing.T) {
	s := newStore(t)
	scopeA := ScopeKey("https://a", "u")
	scopeB := ScopeKey("https://b", "u")
	cand := epCandidate("it-on-a")

	// A 服本地记录:500 秒
	s.Capture(CaptureOpts{ScopeKey: scopeA, Candidate: cand, SeriesTmdbID: sp("s1"),
		PositionTicks: 500 * TicksPerSec, WatchedThresholdPercent: 90, Force: true})
	// B 服(另一台)记录同一集:900 秒
	candB := epCandidate("it-on-b")
	s.Capture(CaptureOpts{ScopeKey: scopeB, Candidate: candB, SeriesTmdbID: sp("s1"),
		PositionTicks: 900 * TicksPerSec, WatchedThresholdPercent: 99, Force: true})

	remote := int64(100) * TicksPerSec

	// 关掉跨服:只在远端 100 和本服 500 里取最大
	got := s.ResolveResumeTicks(scopeA, cand, sp("s1"), &remote, false, false)
	if got == nil || *got != 500*TicksPerSec {
		t.Fatalf("关掉跨服时该取本服的 500,实得 %v", ticks(got))
	}
	// 打开跨服:B 服的 900 要参与
	got = s.ResolveResumeTicks(scopeA, cand, sp("s1"), &remote, false, true)
	if got == nil || *got != 900*TicksPerSec {
		t.Fatalf("打开跨服时该取 B 服的 900,实得 %v —— 跨服续播的全部意义就在这一句", ticks(got))
	}
}

// 远端已看完 → 不续播。
func TestResolveResumeTicks远端看完不续播(t *testing.T) {
	s := newStore(t)
	scope := ScopeKey("https://a", "u")
	cand := epCandidate("it1")
	s.Capture(CaptureOpts{ScopeKey: scope, Candidate: cand, SeriesTmdbID: sp("s1"),
		PositionTicks: 500 * TicksPerSec, WatchedThresholdPercent: 90, Force: true})
	remote := int64(0)
	if got := s.ResolveResumeTicks(scope, cand, sp("s1"), &remote, true, true); got != nil {
		t.Fatalf("远端标了已看完就不该续播,实得 %v —— 用户会以为「怎么又从中间开始」", ticks(got))
	}
}

// 本服记录已看完 → **只信远端**,别让跨服记录把「已看完」盖回去。
func TestResolveResumeTicks本服看完只信远端(t *testing.T) {
	s := newStore(t)
	scopeA := ScopeKey("https://a", "u")
	scopeB := ScopeKey("https://b", "u")
	cand := epCandidate("it-on-a")

	// A 服:看完了
	s.Capture(CaptureOpts{ScopeKey: scopeA, Candidate: cand, SeriesTmdbID: sp("s1"),
		PositionTicks: 1400 * TicksPerSec, WatchedThresholdPercent: 90, Force: true})
	if !s.LoadScope(scopeA)[0].Played {
		t.Fatal("前提不成立:A 服该是看完状态")
	}
	// B 服:看到 900 秒
	s.Capture(CaptureOpts{ScopeKey: scopeB, Candidate: epCandidate("it-on-b"), SeriesTmdbID: sp("s1"),
		PositionTicks: 900 * TicksPerSec, WatchedThresholdPercent: 99, Force: true})

	remote := int64(50) * TicksPerSec
	got := s.ResolveResumeTicks(scopeA, cand, sp("s1"), &remote, false, true)
	if got == nil || *got != 50*TicksPerSec {
		t.Fatalf("本服已看完时只该信远端的 50,实得 %v —— 否则用户在本服标的「看完」被跨服记录顶掉",
			ticks(got))
	}
}

// 跨服只采用可信匹配。
func TestResolveResumeTicks跨服只信可信匹配(t *testing.T) {
	s := newStore(t)
	scopeA := ScopeKey("https://a", "u")
	scopeB := ScopeKey("https://b", "u")

	// B 服上是**另一部剧**的同季同集号,只有季集号一样
	other := Candidate{ID: "x", Type: "Episode", Name: "第 3 集", SeriesName: sp("另一部剧"),
		SeasonNo: ip(1), EpisodeNo: ip(3)}
	s.Capture(CaptureOpts{ScopeKey: scopeB, Candidate: other,
		PositionTicks: 900 * TicksPerSec, WatchedThresholdPercent: 99, Force: true})

	cand := epCandidate("it-on-a")
	remote := int64(10) * TicksPerSec
	got := s.ResolveResumeTicks(scopeA, cand, sp("s1"), &remote, false, true)
	if got == nil || *got != 10*TicksPerSec {
		t.Fatalf("不同剧不该被跨服采用,实得 %v —— 会从别的片子的进度开始播", ticks(got))
	}
}

// 进度归一化:超过时长要夹回去(服务器偶尔给出超长的 tick)。
func TestNormalizeTicks(t *testing.T) {
	rt := int64(100)
	if got := normalizeTicks(ip(150), &rt); got == nil || *got != 100 {
		t.Errorf("超过时长要夹回去: %v", ticks(got))
	}
	if got := normalizeTicks(ip(0), &rt); got != nil {
		t.Errorf("0 视为没有进度: %v", ticks(got))
	}
	if got := normalizeTicks(ip(-5), &rt); got != nil {
		t.Errorf("负数视为没有进度: %v", ticks(got))
	}
	if got := normalizeTicks(ip(150), nil); got == nil || *got != 150 {
		t.Errorf("没有时长就不夹: %v", ticks(got))
	}
}

// 已看判定:**无时长时判不了,不算看完**。
//
// ★ 猜错的方向是「把没看完的标成看完」—— 那更糟:用户回头找不到没看完的那一集。
func TestIsPlayed(t *testing.T) {
	rt := int64(100)
	if !isPlayed(95, &rt, 90) {
		t.Error("95/100 该算看完")
	}
	if isPlayed(50, &rt, 90) {
		t.Error("50/100 不该算看完")
	}
	if isPlayed(999, nil, 90) {
		t.Error("没有时长时不能算看完")
	}
	zero := int64(0)
	if isPlayed(999, &zero, 90) {
		t.Error("时长为 0 时不能算看完")
	}
}

// 删除与清空。
func TestDeleteAndClear(t *testing.T) {
	s := newStore(t)
	scope := ScopeKey("https://a", "u")
	rec := s.Capture(CaptureOpts{ScopeKey: scope, Candidate: epCandidate("it1"),
		PositionTicks: 100 * TicksPerSec, WatchedThresholdPercent: 90, Force: true})
	if err := s.DeleteRecord(rec.RecordID); err != nil {
		t.Fatal(err)
	}
	if len(s.LoadAll()) != 0 {
		t.Fatal("该删掉了")
	}
	s.Capture(CaptureOpts{ScopeKey: scope, Candidate: epCandidate("it2"),
		PositionTicks: 100 * TicksPerSec, WatchedThresholdPercent: 90, Force: true})
	if err := s.ClearAll(); err != nil {
		t.Fatal(err)
	}
	if len(s.LoadAll()) != 0 {
		t.Fatal("该清空了")
	}
}

// 非 Movie/Episode 不记录。
func TestCapture不记录整部剧(t *testing.T) {
	s := newStore(t)
	c := Candidate{ID: "s1", Type: "Series", Name: "某剧"}
	if rec := s.Capture(CaptureOpts{ScopeKey: "x", Candidate: c, PositionTicks: 100}); rec != nil {
		t.Fatal("整部剧不该进观看记录 —— 记了会在「继续观看」里冒出一整部剧")
	}
}

func ticks(p *int64) any {
	if p == nil {
		return nil
	}
	return *p / TicksPerSec
}
