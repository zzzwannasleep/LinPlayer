package history

import "testing"

func sp(s string) *string { return &s }
func ip(i int64) *int64   { return &i }

// 标题归一化:同一部片在不同服务器上的标题几乎不会完全一样。
func TestNormalizeText(t *testing.T) {
	for _, c := range []struct{ in, want string }{
		{"[星尘字幕组] 某剧 (2024)", "某剧"},
		{"The Movie (2019) [1080p]", "the movie"},
		{"  某·剧_名  ", "某 剧 名"},
		{"", ""},
		{"!!!", ""},
	} {
		if got := NormalizeText(c.in); got != c.want {
			t.Errorf("NormalizeText(%q) = %q,期望 %q", c.in, got, c.want)
		}
	}
}

// 路径归一化:记录里存的是**服务器端**路径,两种分隔符都要认。
func TestNormalizePathStem(t *testing.T) {
	for _, c := range []struct {
		in   *string
		want string
	}{
		{sp("/media/movies/Some Movie (2019).mkv"), "some movie"},
		{sp(`D:\media\Some Movie.mkv`), "some movie"},
		{sp("Some Movie.mkv"), "some movie"},
		{sp(".hidden"), "hidden"}, // 点在首位不算扩展名
	} {
		got := NormalizePathStem(c.in)
		if got == nil || *got != c.want {
			t.Errorf("NormalizePathStem(%v) = %v,期望 %q", *c.in, got, c.want)
		}
	}
	if NormalizePathStem(nil) != nil || NormalizePathStem(sp("  ")) != nil {
		t.Error("空路径该返回 nil")
	}
}

// ★ ProviderIds 的键名**大小写不敏感** —— 不同刮削器写 Tmdb / TMDB / tmdb 都有。
func TestExtractProviderID(t *testing.T) {
	for _, key := range []string{"Tmdb", "TMDB", "tmdb"} {
		got := ExtractProviderID(map[string]string{key: " 550 "}, "Tmdb")
		if got == nil || *got != "550" {
			t.Errorf("键 %q 没取到(要去空白): %v", key, got)
		}
	}
	if ExtractProviderID(map[string]string{"Tmdb": "  "}, "Tmdb") != nil {
		t.Error("空串当没有")
	}
	if ExtractProviderID(map[string]string{"Imdb": "tt1"}, "Tmdb") != nil {
		t.Error("别的键不该被当成 Tmdb")
	}
}

// ScopeKey / ServerFromScope:server 是 URL,自带冒号。
//
// ★ 按**第一个**冒号切的话 `https://x:8096:user` 会被切成 `https`,
// 于是回传时往一个叫 "https" 的服务器写 —— 静默失败。
func TestScopeKey(t *testing.T) {
	k := ScopeKey("https://x.invalid:8096", "user-1")
	if got := ServerFromScope(k); got != "https://x.invalid:8096" {
		t.Fatalf("要按最后一个冒号切,实得 %q", got)
	}
	if got := ServerFromScope("没有冒号"); got != "没有冒号" {
		t.Fatalf("没有冒号时原样返回,实得 %q", got)
	}
}

// canonicalKey 的优先级:TMDB > PUK > 标题(+年份/季集号)> itemId。
//
// ★ 这个键**与服务器无关**,跨服匹配全靠它。优先级搞反的话,
// 同一部片在两台服上会算出不同的键 —— 跨服续播直接失效,而且不报错。
func TestBuildCanonicalKey优先级(t *testing.T) {
	// 电影
	if got := BuildCanonicalKey(KindMovie, "it1", sp("550"), nil, sp("PUK-1"), "fight club", "", nil, nil, ip(1999)); got != "movie:tmdb:550" {
		t.Errorf("有 TMDB 时优先用它: %q", got)
	}
	if got := BuildCanonicalKey(KindMovie, "it1", nil, nil, sp("PUK-1"), "fight club", "", nil, nil, ip(1999)); got != "movie:puk:puk-1" {
		t.Errorf("没 TMDB 用 PUK(且要小写): %q", got)
	}
	if got := BuildCanonicalKey(KindMovie, "it1", nil, nil, nil, "fight club", "", nil, nil, ip(1999)); got != "movie:title:fight club:year:1999" {
		t.Errorf("再退标题+年份: %q", got)
	}
	if got := BuildCanonicalKey(KindMovie, "it1", nil, nil, nil, "fight club", "", nil, nil, nil); got != "movie:title:fight club:year:unknown" {
		t.Errorf("没年份写 unknown(不是空): %q", got)
	}
	if got := BuildCanonicalKey(KindMovie, "it1", nil, nil, nil, "", "", nil, nil, nil); got != "movie:item:it1" {
		t.Errorf("信息全无才退 itemId: %q", got)
	}

	// 剧集:季集号要补零 —— 不补的话 s1:e10 和 s1:e1 的前缀会撞
	if got := BuildCanonicalKey(KindEpisode, "it1", sp("t1"), sp("s1"), nil, "第 3 集", "某剧", ip(1), ip(3), nil); got != "series:tmdb:s1:s01:e03" {
		t.Errorf("剧 TMDB 优先且季集号补零: %q", got)
	}
	if got := BuildCanonicalKey(KindEpisode, "it1", sp("t1"), nil, nil, "", "某剧", ip(1), ip(3), nil); got != "episode:tmdb:t1:s01:e03" {
		t.Errorf("没有剧 TMDB 时退单集 TMDB: %q", got)
	}
	if got := BuildCanonicalKey(KindEpisode, "it1", nil, nil, sp("PUK"), "", "某剧", ip(1), ip(3), nil); got != "episode:puk:puk" {
		t.Errorf("再退 PUK: %q", got)
	}
	if got := BuildCanonicalKey(KindEpisode, "it1", nil, nil, nil, "", "某剧", ip(1), ip(3), nil); got != "episode:title:某剧:s01:e03" {
		t.Errorf("再退剧名+季集号: %q", got)
	}
	if got := BuildCanonicalKey(KindEpisode, "it1", nil, nil, nil, "", "", nil, nil, nil); got != "episode:item:it1" {
		t.Errorf("信息全无才退 itemId: %q", got)
	}
}

// 只有 Movie / Episode 记录。
func TestMediaKindFromItemType(t *testing.T) {
	for _, ok := range []string{"Movie", "movie", "Episode", "EPISODE"} {
		if _, got := MediaKindFromItemType(ok); !got {
			t.Errorf("%q 该能记录", ok)
		}
	}
	for _, no := range []string{"Series", "Season", "BoxSet", "Folder", ""} {
		if _, got := MediaKindFromItemType(no); got {
			t.Errorf("%q 不该记录 —— 记了会在「继续观看」里冒出一整部剧", no)
		}
	}
}

func movieRecord() Record {
	return Record{
		MediaKind: KindMovie, Title: "Fight Club", TmdbID: sp("550"), Year: ip(1999),
		MediaPath: sp("/media/Fight Club (1999).mkv"),
	}
}
func movieCandidate() Candidate {
	return Candidate{Type: "Movie", Name: "Fight Club", TmdbID: sp("550"), Year: ip(1999),
		Path: sp("/other/Fight Club (1999).mkv")}
}

// PUK 一致 = 同一台服务器上的同一条目,最强证据,压过一切。
func TestMatchPUK最强(t *testing.T) {
	r, c := movieRecord(), movieCandidate()
	r.PresentationKey, c.PresentationKey = sp("PUK-1"), sp("puk-1") // 大小写不同也要认
	r.TmdbID, c.TmdbID = sp("550"), sp("999")                       // TMDB 故意对不上
	r.Title, c.Name = "完全不同的名字", "另一个名字"
	got := MatchRecordToCandidate(r, c, nil, false)
	if got.Confidence != ConfStrong {
		t.Fatalf("PUK 一致该是 strong,实得 %+v", got)
	}
}

// 两条都没有 TMDB id,**不能因此判成同一部**。
func TestMatch两边都没有TMDB不算匹配(t *testing.T) {
	r, c := movieRecord(), movieCandidate()
	r.TmdbID, c.TmdbID = nil, nil
	r.Year, c.Year = nil, nil
	r.Title, c.Name = "甲片", "乙片"
	r.MediaPath, c.Path = nil, nil
	got := MatchRecordToCandidate(r, c, nil, false)
	if got.Confidence != ConfNone {
		t.Fatalf("信息全无该判 none,实得 %+v —— 否则会从别的片子的进度开始播", got)
	}
}

// 唯一候选下 weak 提升成 possible。
//
// ★ 这条是「跨服续播能不能用得起来」的关键:多数服务器上元数据都不全,
// 全靠严格证据的话跨服基本用不了;但提升只在**候选唯一**时才做。
func TestMatch唯一候选提升置信度(t *testing.T) {
	r, c := movieRecord(), movieCandidate()
	r.TmdbID, c.TmdbID = nil, nil // 只剩标题 + 年份
	if got := MatchRecordToCandidate(r, c, nil, false); got.Confidence != ConfWeak {
		t.Fatalf("非唯一候选下该是 weak,实得 %+v", got)
	}
	if got := MatchRecordToCandidate(r, c, nil, true); got.Confidence != ConfPossible {
		t.Fatalf("唯一候选下该提升成 possible,实得 %+v", got)
	}
	// weak 不可信,possible 可信 —— 这条决定了会不会真去续播
	if ConfWeak.IsTrusted() {
		t.Fatal("weak 不该被信任 —— 信了就会「从别的片子的进度开始播」")
	}
	if !ConfPossible.IsTrusted() || !ConfStrong.IsTrusted() {
		t.Fatal("possible / strong 该被信任")
	}
}

// 剧集:剧 TMDB + 季集号 = strong。
func TestMatchEpisode(t *testing.T) {
	r := Record{MediaKind: KindEpisode, Title: "第 3 集", SeriesTitle: sp("某剧"),
		SeriesTmdbID: sp("s1"), SeasonNumber: ip(1), EpisodeNo: ip(3)}
	c := Candidate{Type: "Episode", Name: "第 3 集", SeriesName: sp("某剧"),
		SeasonNo: ip(1), EpisodeNo: ip(3)}
	if got := MatchRecordToCandidate(r, c, sp("s1"), false); got.Confidence != ConfStrong {
		t.Fatalf("剧 TMDB + 季集号该 strong,实得 %+v", got)
	}
	// 剧 TMDB 对不上,只剩剧名 + 季集号 → 非唯一候选下只有 weak
	if got := MatchRecordToCandidate(r, c, sp("别的剧"), false); got.Confidence != ConfWeak {
		t.Fatalf("只剩剧名+季集号该 weak,实得 %+v", got)
	}
	// 季集号不同 = 不是同一集,再像也不行
	c2 := c
	c2.EpisodeNo = ip(4)
	if got := MatchRecordToCandidate(r, c2, sp("s1"), true); got.Confidence != ConfNone {
		t.Fatalf("季集号不同必须 none,实得 %+v —— 否则会跳到别的一集", got)
	}
}

// 电影记录不该匹配到剧集条目(反之亦然)。
func TestMatch类型必须一致(t *testing.T) {
	r := movieRecord()
	c := Candidate{Type: "Episode", Name: "Fight Club", TmdbID: sp("550")}
	if got := MatchRecordToCandidate(r, c, nil, true); got.Confidence != ConfNone {
		t.Fatalf("类型不同必须 none,实得 %+v", got)
	}
	// 非 Movie/Episode 的候选(比如整部剧)也不该匹配
	c2 := Candidate{Type: "Series", Name: "Fight Club", TmdbID: sp("550")}
	if got := MatchRecordToCandidate(r, c2, nil, true); got.Confidence != ConfNone {
		t.Fatalf("Series 类型不该匹配,实得 %+v", got)
	}
}

// 取最大进度 —— 跨服续播的核心就是这一句。
func TestMaxPositionTicks(t *testing.T) {
	if got := MaxPositionTicks(nil, ip(5)); got == nil || *got != 5 {
		t.Errorf("一边为 nil 时返回另一边: %v", got)
	}
	if got := MaxPositionTicks(ip(5), nil); got == nil || *got != 5 {
		t.Errorf("一边为 nil 时返回另一边: %v", got)
	}
	if got := MaxPositionTicks(ip(3), ip(9)); got == nil || *got != 9 {
		t.Errorf("取大的那个: %v", got)
	}
	if MaxPositionTicks(nil, nil) != nil {
		t.Error("都没有时返回 nil")
	}
}

// 回写判定。
func TestNeedsRestore(t *testing.T) {
	rec := Record{LastPositionTicks: 100 * TicksPerSec}
	// 服务器上还没进度 → 回写
	if !NeedsRestore(rec, Candidate{}) {
		t.Error("服务器没进度时该回写")
	}
	// 服务器上差不到 30 秒 → 别折腾
	if NeedsRestore(rec, Candidate{PositionTicks: 80 * TicksPerSec}) {
		t.Error("差不到 30 秒不该回写")
	}
	// 差超过 30 秒 → 回写
	if !NeedsRestore(rec, Candidate{PositionTicks: 60 * TicksPerSec}) {
		t.Error("差超过 30 秒该回写")
	}
	// 服务器上已看完 → 不要把它退回「看了一半」
	if NeedsRestore(rec, Candidate{Played: true}) {
		t.Error("服务器上已看完时不该回写进度")
	}
	// 本地看完、服务器没看完 → 回写「已看完」
	done := Record{Played: true}
	if !NeedsRestore(done, Candidate{}) {
		t.Error("本地看完该回写")
	}
	if NeedsRestore(done, Candidate{Played: true}) {
		t.Error("两边都看完就没事可做")
	}
	// 本地没进度也没看完 → 没什么可回写的
	if NeedsRestore(Record{}, Candidate{}) {
		t.Error("本地什么都没有时不该回写")
	}
}

// 恢复搜什么:电影用片名,剧集用剧名。
func TestRestoreSearchQuery(t *testing.T) {
	if q, ok := RestoreSearchQuery(Record{MediaKind: KindMovie, Title: "某片"}); !ok || q != "某片" {
		t.Errorf("电影用片名: %q %v", q, ok)
	}
	if q, ok := RestoreSearchQuery(Record{MediaKind: KindEpisode, Title: "第 3 集", SeriesTitle: sp("某剧")}); !ok || q != "某剧" {
		t.Errorf("剧集用剧名 —— 拿「第 3 集」去搜是搜不到的: %q %v", q, ok)
	}
	if q, ok := RestoreSearchQuery(Record{MediaKind: KindEpisode, Title: "第 3 集"}); !ok || q != "第 3 集" {
		t.Errorf("没有剧名时退回片名: %q %v", q, ok)
	}
	if _, ok := RestoreSearchQuery(Record{MediaKind: KindMovie, Title: "   "}); ok {
		t.Error("全空时搜不了")
	}
}

// ★★ 两边**都没有** TMDB 时,绝不能因为「都没有」就判成同一部。
//
// 上面那条(标题也不同)其实盖不到这个:标题不同时结论本来就是 none,
// 把 `None == None` 改成算匹配也照样绿。真正会炸的是**标题相同但都没有 TMDB**
// 的那种 —— 那时 sameTmdb 变成 true,和 sameTitle 一凑就成了「标题 + TMDB 匹配」= strong,
// 于是两部同名的不同片子被判成同一部,直接从别人的进度开始播。
//
// 剧集侧同理:两边都没有剧 TMDB + 季集号相同 → 会被判成「剧集 TMDB + 季集号匹配」。
func TestMatch都没有TMDB时同名也不能算强匹配(t *testing.T) {
	r, c := movieRecord(), movieCandidate()
	r.TmdbID, c.TmdbID = nil, nil // 两边都没有
	r.Title, c.Name = "同名的片子", "同名的片子"
	r.Year, c.Year = nil, nil
	r.MediaPath, c.Path = nil, nil
	if got := MatchRecordToCandidate(r, c, nil, false); got.Confidence == ConfStrong {
		t.Fatalf("都没有 TMDB 时不该判成 strong,实得 %+v —— 两部同名的不同片子会被当成同一部", got)
	}

	re := Record{MediaKind: KindEpisode, Title: "第 3 集", SeriesTitle: sp("某剧"),
		SeasonNumber: ip(1), EpisodeNo: ip(3)}
	ce := Candidate{Type: "Episode", Name: "第 3 集", SeriesName: sp("另一部剧"),
		SeasonNo: ip(1), EpisodeNo: ip(3)}
	// 两边都没有剧 TMDB,剧名还不同 —— 只有季集号一样,不该算匹配上
	if got := MatchRecordToCandidate(re, ce, nil, false); got.Confidence != ConfNone {
		t.Fatalf("只有季集号相同不该算匹配,实得 %+v —— 不同剧的第 1 季第 3 集会串台", got)
	}
}
