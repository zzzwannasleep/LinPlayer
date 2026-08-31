package danmaku

// 评分算法的测试。这一块的判据全是**「分数拉不拉得开」** ——
// 自动加载阈值是 0.5,而阈值只有在「像的明显高、不像的明显低」时才有意义。

import (
	"testing"
)

func mi(title string, alts ...string) *MatchInput {
	return &MatchInput{Title: title, AltTitles: alts}
}

// ★★ 差一个字的标题必须**明显高于**阈值,毫不相干的必须**明显低于**。
//
// 旧口径(字符二元组 Jaccard ×0.6)给不出 0.6 以上的分:凡是没有完全相等、
// 也没有包含关系的标题上限就是 0.6,而阈值是 0.5 ——
// 「葬送的芙莉莲」和「葬送之芙莉莲」跟毫不相干的标题挤在同一个窄区间里,
// **阈值根本分不开**。
func TestSimilarity_差一个字要明显高于毫不相干(t *testing.T) {
	near := similarity("葬送的芙莉莲", "葬送之芙莉莲")
	far := similarity("葬送的芙莉莲", "间谍过家家")
	if near < 0.75 {
		t.Fatalf("差一个字只给了 %.2f —— 阈值 %.1f 分不开", near, MinAutoScore)
	}
	if far > 0.3 {
		t.Fatalf("毫不相干却给了 %.2f", far)
	}
	if near-far < 0.4 {
		t.Fatalf("两者只差 %.2f,拉不开", near-far)
	}
}

// ★★ 字形折叠:全角 / 片假名平假名 / 大小写 / 标点差异**不该把分打到 0**。
//
// 二元组集合上它们全是「不同的字符」,而它们指的是同一部作品。
func TestSimilarity_字形折叠(t *testing.T) {
	cases := []struct{ a, b string }{
		{"ＦＡＴＥ／ＺＥＲＯ", "fate/zero"}, // 全角 → 半角 + 大小写
		{"フリーレン", "ふりーれん"},         // 片假名 → 平假名
		{"孤独摇滚!", "孤独摇滚"},          // 标点
		{"Re:从零开始", "Re 从零开始"},     // 分隔符
		{"进击的巨人 第二季", "进击的巨人"},     // 季号剥掉
	}
	for _, c := range cases {
		if s := similarity(c.a, c.b); s < 0.9 {
			t.Fatalf("%q vs %q 只给了 %.2f —— 折叠没生效(归一化后:%q / %q)",
				c.a, c.b, s, normalize(c.a), normalize(c.b))
		}
	}
}

// ★★ 包含关系要**按长度占比**给分,不是一律 0.7。
//
// 一律 0.7 的话,「刀」落在「刀剑神域」里和「刀剑神域」落在「刀剑神域Ⅱ」里
// 拿同一个分 —— 后者显然更该信,而前者会把正确候选挤下去。
//
// ★ 用例里的两个例子**占比要真的不同**。第一版拿「赛马娘 / 赛马娘 Pretty Derby」
//
//	(3/16 = 0.19)去比「刀 / 刀剑神域」(1/4 = 0.25),方向正好反了 ——
//	前者占比更低,分低是**对的**。挑例子之前得先把占比算出来。
func TestSimilarity_包含按长度占比(t *testing.T) {
	// ★ 两个例子落在**同一个长串**上,只有占比不同 —— 这样固定 0.7 时两者会相等,
	//   注入立刻现形。第一版挑的两组长串不同,分差正好卡在判据边界(恰好 0.10)上,
	//   注入照样绿。夹具卡在边界上,等于断言没有余量。
	high := similarity("刀剑神域外", "刀剑神域外传") // 占比 5/6
	low := similarity("刀", "刀剑神域外传")      // 占比 1/6
	if high <= low {
		t.Fatalf("占比高的(%.2f)没有比占比低的(%.2f)高 —— "+
			"包含关系给固定分的话,一个字的子串会把正确候选挤下去", high, low)
	}
	if low > 0.68 {
		t.Fatalf("一个字落在六个字里只占 1/6,却给了 %.2f —— 太高了", low)
	}
	if high < 0.85 {
		t.Fatalf("占了 5/6 却只给 %.2f —— 长度占比这一路没说话", high)
	}
}

// ★★ 季号是**独立且更硬**的一路信号。
//
// 「孤独摇滚」和「孤独摇滚 第二季」剥掉季号后是同一个串,相似度分不开;
// 但季号一对,谁是谁立刻清楚。以前没有这一路 —— 第二季的片配上第一季的弹幕,
// 从头到尾对不上,**而且不报错**。
func TestSeasonTerm_对上加分对不上重罚(t *testing.T) {
	two := int64(2)
	in := &MatchInput{Title: "孤独摇滚", SeasonNo: &two}
	if got := SeasonTerm(in, "孤独摇滚 第二季"); got != 0.15 {
		t.Fatalf("季号对上应当 +0.15,实得 %v", got)
	}
	if got := SeasonTerm(in, "孤独摇滚"); got != -0.35 {
		t.Fatalf("候选没写季号 = 第一季,对不上应当 -0.35,实得 %v", got)
	}
	// ★ 不知道要第几季 → 这一路**不表态**,不能白送分也不能乱罚
	if got := SeasonTerm(&MatchInput{Title: "孤独摇滚"}, "孤独摇滚 第二季"); got != 0 {
		t.Fatalf("不知道季号时应当 0,实得 %v", got)
	}
}

// ★★ 想要的季号优先取**标题自己带的**。
//
// 媒体库有两种摆法:一部剧一个条目(季在 seasonNo 里),或每季各一个条目
// (季在标题里、seasonNo 恒为 1)。只认 seasonNo 的话,后者会把**正确的**
// 「第二季」候选判成错季直接压死。
func TestSeasonTerm_标题里的季号优先于seasonNo(t *testing.T) {
	one := int64(1)
	in := &MatchInput{Title: "孤独摇滚 第二季", SeasonNo: &one}
	if got := SeasonTerm(in, "孤独摇滚 第二季"); got != 0.15 {
		t.Fatalf("标题自带第二季,候选也是第二季,应当 +0.15,实得 %v —— "+
			"只认 season_no 的话正确候选会被压死", got)
	}
}

func TestSeasonOf_中文数字与英文(t *testing.T) {
	cases := map[string]int64{
		"孤独摇滚 第二季":             2,
		"某某 第10季":              10,
		"某某 第十二季":              12,
		"某某 第二十一期":             21,
		"Some Show Season 3":   3,
		"Some Show 2nd Season": 2,
	}
	for title, want := range cases {
		got, ok := seasonOf(title)
		if !ok || got != want {
			t.Fatalf("seasonOf(%q) = (%d,%v),想要 %d", title, got, ok, want)
		}
	}
	if _, ok := seasonOf("孤独摇滚"); ok {
		t.Fatal("没有季号标记时应当读不出来(调用方按第一季看待)")
	}
}

// ★★ 平行语料:媒体库标题是中文而弹弹Play 收录的是日文名(或反过来)时,
// 单靠 Title 一路分数恒为 0 —— 候选明明已经捞回来了,却被自己的评分扔掉。
func TestTitleScore_别名要参与(t *testing.T) {
	in := mi("葬送的芙莉莲", "Sousou no Frieren", "葬送のフリーレン")
	got := TitleScore(in, "葬送のフリーレン")
	if got < 0.95 {
		t.Fatalf("日文原名在 alt_titles 里却只给了 %.2f —— 候选会被自己的评分扔掉", got)
	}
	// 没有别名时确实对不上,这正是需要平行语料的理由
	if s := TitleScore(mi("葬送的芙莉莲"), "葬送のフリーレン"); s > 0.4 {
		t.Fatalf("夹具不成立:不给别名也能对上(%.2f),那这条测不到别名的作用", s)
	}
}

// ★ 主名召回:长标题会把全文检索呛住,整串搜出来常常是 0 条。
func TestCoreName(t *testing.T) {
	cases := map[string]string{
		"孤独摇滚 第二季":                  "孤独摇滚",
		"进击的巨人 - 最终季 -":             "进击的巨人",
		"某某作品(剧场版)":                 "某某作品",
		"Re:从零开始的异世界生活":             "Re",
		"赛马娘 Pretty Derby Season 2": "赛马娘 Pretty Derby",
	}
	for in, want := range cases {
		if got := CoreName(in); got != want {
			t.Fatalf("CoreName(%q) = %q,想要 %q", in, got, want)
		}
	}
}

// ★★ 官方源参不参与自动匹配。
//
// 「不知道」必须**放行** —— 反过来写(genres 空就排除)会让所有没刮削元数据的库
// 弹幕静默死掉,那是比烧配额严重得多的回归。
func TestAllowOfficialFor(t *testing.T) {
	if !AllowOfficialFor([]string{"动画", "奇幻"}) {
		t.Fatal("是番却不带官方源")
	}
	if !AllowOfficialFor([]string{"Animation"}) {
		t.Fatal("英文分类也要认")
	}
	if AllowOfficialFor([]string{"动作", "科幻"}) {
		t.Fatal("确信不是番,不该烧官方配额")
	}
	if AllowOfficialFor([]string{"Drama", "Crime"}) {
		t.Fatal("欧美剧同理")
	}
	if !AllowOfficialFor(nil) {
		t.Fatal("★ 没刮到元数据 = 不知道,**必须放行** —— 否则弹幕静默死掉,查都没处查")
	}
}
