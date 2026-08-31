package danmaku

// 标题相似度与季号判定 —— 智能匹配的评分核心。
//
// 移植自 `crates/core/src/danmaku/mod.rs` 的标题相似度那一段。
//
// ★★ 口径是 **归一化折叠 + Levenshtein 比率 + 长度加权的包含下限**,
// 一条代码路径吃所有语种,**不写任何按语言分支的规则**。
//
// 为什么不是「字符二元组 Jaccard」(它被换掉了):
//
//  1. 它给不出 0.6 以上的分。凡是没有完全相等、也没有包含关系的标题,上限就是 0.6,
//     而自动加载阈值是 0.5 —— 差一个字的标题(「葬送的芙莉莲」vs「葬送之芙莉莲」)
//     和毫不相干的标题挤在同一个窄区间里,**阈值根本分不开**。
//     Levenshtein 比率给的是 0.86 对 0.1,这才叫可判。
//  2. 它不做任何字形折叠。全角(ＦＡＴＥ)、片假名 / 平假名(フリーレン vs ふりーれん)、
//     大小写、标点差异,在二元组集合上全是「不同的字符」,直接把分打到 0。
//  3. 包含关系一律记 0.7,不看长度。于是「刀」落在「刀剑神域」里 = 0.7,
//     「赛马娘」落在「赛马娘 Pretty Derby」里也 = 0.7 —— 后者显然更该信。

import (
	"regexp"
	"strconv"
	"strings"
	"unicode"
)

// MinAutoScore 自动加载可信度阈值:低于此分不该自动上屏。
const MinAutoScore = 0.5

// maxTitleChars 标题长于这个就截断。
//
// ★ 超长标题的尾巴对匹配没有贡献,却让 Levenshtein 变成 O(n²) 的负担。
const maxTitleChars = 128

var (
	digitsRe = regexp.MustCompile(`\d+`)
	seasonRe = regexp.MustCompile(
		`(?i)第\s*[一二三四五六七八九十两0-9]+\s*[季期部]|season\s*[0-9]+|[0-9]+(?:st|nd|rd|th)\s+season`)
	// subtitleRe 副标题:-xx- / ～xx～ /(xx)/ [xx] / :xx
	subtitleRe = regexp.MustCompile(
		`\s*[-–—]\s*[^-–—]*[-–—]\s*$|\s*[～~][^～~]*[～~]\s*$|\s*[（(\[][^）)\]]*[）)\]]\s*|\s*[:：].*$`)
)

// fold 把一个字符折叠到可比较的表面;返回 (0, false) 表示整个丢掉。
//
// 做的是 NFKC + casefold 里「对标题真正有用」的那个子集:全角→半角、大写→小写、
// 片假名→平假名、所有分隔符 / 标点丢弃。
//
// ★ 完整 NFKC 和繁→简要拖进大张 Unicode 表,**不做** ——
// 下面的 Levenshtein 比率吃得下繁体带来的那几个字的漂移。
func fold(c rune) (rune, bool) {
	u := uint32(c)
	switch {
	case u == 0x20 || u == 0x09 || u == 0x0A || u == 0x0D || u == 0x3000:
		return 0, false // 各种空白 + 表意空格
	case (u >= 0x21 && u <= 0x2F) || (u >= 0x3A && u <= 0x40) ||
		(u >= 0x5B && u <= 0x60) || (u >= 0x7B && u <= 0x7E):
		return 0, false // ASCII 标点
	case u >= 0x3001 && u <= 0x303F:
		return 0, false // CJK 标点:、。〈〉「」【】〜…
	case u == 0x30FB:
		return 0, false // 片假名中点「・」(不在下面的片假名区间里,得单独丢)
	case u >= 0xFF01 && u <= 0xFF5E:
		// 全角 ASCII → 半角,然后**再走一遍**(大写还要转小写、标点还要丢)
		return fold(rune(u - 0xFEE0))
	case u >= 0x30A1 && u <= 0x30F6:
		return rune(u - 0x60), true // 片假名 → 平假名(把假名的宽窄统一掉)
	default:
		return unicode.ToLower(c), true
	}
}

// normChars 归一化成可比较的字符序列。
//
// ★ 季号在这一步**剥掉** —— 它不是标题相似度该管的事,而是一路独立且更硬的信号
// (见 seasonTerm)。
func normChars(s string) []rune {
	stripped := seasonRe.ReplaceAllString(s, "")
	out := make([]rune, 0, len(stripped))
	for _, c := range stripped {
		if f, ok := fold(c); ok {
			out = append(out, f)
			if len(out) >= maxTitleChars {
				break
			}
		}
	}
	return out
}

// normalize 归一化后的字符串。给测试读值用。
func normalize(s string) string { return string(normChars(s)) }

// levenshtein 两行 DP 的编辑距离。
func levenshtein(a, b []rune) int {
	if len(a) == 0 {
		return len(b)
	}
	prev := make([]int, len(b)+1)
	cur := make([]int, len(b)+1)
	for j := range prev {
		prev[j] = j
	}
	for i, ca := range a {
		cur[0] = i + 1
		for j, cb := range b {
			sub := prev[j]
			if ca != cb {
				sub++
			}
			cur[j+1] = min3(prev[j+1]+1, cur[j]+1, sub)
		}
		prev, cur = cur, prev
	}
	return prev[len(b)]
}

func min3(a, b, c int) int {
	if b < a {
		a = b
	}
	if c < a {
		a = c
	}
	return a
}

// containsSeq small 是否作为**连续子序列**出现在 big 里。
func containsSeq(big, small []rune) bool {
	if len(small) == 0 || len(small) > len(big) {
		return false
	}
	for i := 0; i+len(small) <= len(big); i++ {
		same := true
		for j := range small {
			if big[i+j] != small[j] {
				same = false
				break
			}
		}
		if same {
			return true
		}
	}
	return false
}

// similarity 单个「查询串 × 候选标题」的相似度,0~1。**与脚本无关**。
func similarity(query, title string) float64 {
	q, t := normChars(query), normChars(title)
	if len(q) == 0 || len(t) == 0 {
		return 0
	}
	if string(q) == string(t) {
		return 1
	}
	maxl := len(q)
	if len(t) > maxl {
		maxl = len(t)
	}
	ratio := 1 - float64(levenshtein(q, t))/float64(maxl)

	/* 包含:短串整个落在长串里。按**长度占比**给下限 —— 占比越高越可信。
	   「赛马娘」在「赛马娘 Pretty Derby」里(3/16)和「刀」在「刀剑神域」里(1/4)
	   不该拿同一个分。等长时趋近 1.0,极短子串只到 0.6 出头。 */
	short, long := q, t
	if len(t) < len(q) {
		short, long = t, q
	}
	if containsSeq(long, short) {
		floor := 0.6 + 0.4*(float64(len(short))/float64(len(long)))
		if floor > ratio {
			ratio = floor
		}
	}
	if ratio < 0 {
		return 0
	}
	if ratio > 1 {
		return 1
	}
	return ratio
}

// seasonOf 从标题里读出季号。读不出来返回 (0, false) —— 调用方按第一季看待。
//
// ★★ 这是**独立于标题相似度**的一路信号,而且比相似度硬:
// 「孤独摇滚」和「孤独摇滚 第二季」剥掉季号后是同一个串,相似度分不开;
// 但季号一对,谁是谁立刻清楚。
//
// 以前没有这一路 —— 第二季的片配上第一季的弹幕,从头到尾对不上,
// **而且不报错**,看起来就像「弹幕匹配得不准」。
func seasonOf(title string) (int64, bool) {
	m := seasonRe.FindString(title)
	if m == "" {
		return 0, false
	}
	if d := digitsRe.FindString(m); d != "" {
		if n, err := strconv.ParseInt(d, 10, 64); err == nil {
			return n, true
		}
	}
	return cjkNumber(m)
}

// cjkNumber 「二」「十」「十二」「二十一」→ 2 / 10 / 12 / 21。
func cjkNumber(s string) (int64, bool) {
	digits := map[rune]int64{
		'零': 0, '一': 1, '两': 2, '二': 2, '三': 3, '四': 4,
		'五': 5, '六': 6, '七': 7, '八': 8, '九': 9,
	}
	var chars []rune
	for _, c := range s {
		if _, ok := digits[c]; ok || c == '十' {
			chars = append(chars, c)
		}
	}
	if len(chars) == 0 {
		return 0, false
	}
	// 「十」「十N」「N十」「N十M」四种写法,别的(百 / 千)动漫季号里不存在
	ten := -1
	for i, c := range chars {
		if c == '十' {
			ten = i
			break
		}
	}
	if ten < 0 {
		return digits[chars[0]], true
	}
	tens := int64(1)
	if ten > 0 {
		tens = digits[chars[ten-1]]
	}
	var ones int64
	if ten+1 < len(chars) {
		ones = digits[chars[ten+1]]
	}
	return tens*10 + ones, true
}

// SeasonTerm 季号一致性的加减分。
//
// ★★ 想要的季号优先取**标题自己带的**。媒体库有两种摆法:
//
//	A. 一部剧一个条目、季在里面 → seriesName="孤独摇滚",seasonNo=2
//	B. 每季各一个条目          → seriesName="孤独摇滚 第二季",seasonNo=1
//
// 只认 seasonNo 的话,B 这种摆法会把**正确的**「第二季」候选判成错季直接压死。
func SeasonTerm(in *MatchInput, candidateTitle string) float64 {
	want, ok := seasonOf(in.Title)
	if !ok {
		if in.SeasonNo == nil {
			return 0 // 不知道要第几季 → 这一路不表态
		}
		want = *in.SeasonNo
	}
	got, ok2 := seasonOf(candidateTitle)
	if !ok2 {
		got = 1
	}
	if want == got {
		return 0.15
	}
	return -0.35
}

// CoreName 剥掉季号与副标题,留下「主名」。
//
// ★ **只用于扩大召回**,不参与算分 —— 所以它宽一点也不会造成错配,
// 最多是多捞几个候选回来让评分去筛。
//
// ★ 长标题会把弹弹Play 的全文检索呛住:带季号、带破折号副标题的整串搜出来常常是 0 条,
// 而只搜主名就有。
func CoreName(title string) string {
	noSeason := seasonRe.ReplaceAllString(title, " ")
	return strings.TrimSpace(subtitleRe.ReplaceAllString(strings.TrimSpace(noSeason), ""))
}

// TitleScore 标题相似度 0~1:拿**所有已知的查询写法**去比候选的标题,取最好的那个。
//
// ★★ 「所有写法」= 主标题 + AltTitles(原名 / 真实文件名 / 条目名,由宿主装)。
//
// 弹弹Play 的条目只有一个标题、**没有别名表**,所以平行语料只能由我们这边提供:
// 媒体库同时握着中文名、原名和发布文件名 —— 谁都可能是能对上的那一个,所以全试。
// 媒体库标题是中文而弹弹Play 收录的是日文名(或反过来)时,单靠 Title 一路分数恒为 0,
// 候选明明已经捞回来了,却被自己的评分扔掉。
func TitleScore(in *MatchInput, candidate string) float64 {
	best := 0.0
	for _, q := range append([]string{in.Title}, in.AltTitles...) {
		if strings.TrimSpace(q) == "" {
			continue
		}
		if s := similarity(q, candidate); s > best {
			best = s
		}
	}
	return best
}

// IsAnime 是否动漫。
//
// ★ 决定要不要放行官方弹弹Play:那是**动漫专库**,给电视剧 / 电影匹配会出
// 乱七八糟的弹幕,而且纯烧配额。
func IsAnime(genresAndTags []string) bool {
	kw := []string{"动画", "动漫", "動畫", "動漫", "番剧", "番劇", "二次元", "卡通", "anime", "アニメ", "animation"}
	for _, g := range genresAndTags {
		l := strings.ToLower(g)
		for _, k := range kw {
			if strings.Contains(l, k) {
				return true
			}
		}
	}
	return false
}

// AllowOfficialFor 这次**自动**匹配该不该带上官方弹弹Play 源。
//
// ★★ 背景(用户报「配额老是被刷完」):`is_anime` 从落地起就**没有任何宿主调用过**
// —— 三处调用点全是写死的 true。后果是播好莱坞电影、国产剧、综艺、纪录片……
// 一样往官方接口打一整轮(/match + 最多 4 次 /search/episodes),
// 而这些内容弹弹Play 根本不收录,一条候选都不可能有。**纯烧配额,零收益**,
// 而且是每次起播都烧。
//
// ★★ 判据是「**确信不是番**才排除」,不是「确信是番才放行」:
// genres 为空 = 元数据没刮到 / 网盘源没有分类信息 = **不知道** → 照常允许。
// 反过来写(空表就排除)会让所有没刮削的库弹幕直接死掉,而且是静默的
// —— 用户只会看见「弹幕突然不出来了」,查都没处查。
//
// ★ 手动搜索和手动挑源**不**过这一关:那是用户明确要求的,他说这是番就是番。
func AllowOfficialFor(genresAndTags []string) bool {
	return len(genresAndTags) == 0 || IsAnime(genresAndTags)
}
