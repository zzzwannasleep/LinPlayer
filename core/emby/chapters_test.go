package emby

import "testing"

func chs(pairs ...any) []Chapter {
	out := []Chapter{}
	for i := 0; i+1 < len(pairs); i += 2 {
		out = append(out, Chapter{Index: len(out), StartSecs: pairs[i].(float64), Name: pairs[i+1].(string)})
	}
	return out
}

// ★★ 短词必须**整词**匹配。
//
// 用 contains 的话 "Opera"、"Stop"、"Wedding" 都会被当成片头 ——
// 把正片开头切掉,而且用户只会觉得「怎么跳掉一段」。
func TestIsIntroName短词要整词匹配(t *testing.T) {
	for _, n := range []string{"OP", "op", "Intro", "Avant", "Opening Theme", "片头曲", "主题曲", "オープニング"} {
		if !isIntroName(n) {
			t.Errorf("%q 该判成片头", n)
		}
	}
	// ★ 这几个是**反例**,一个都不能命中
	for _, n := range []string{"Opera", "Stop", "Chapter 1", "Prologue", "Top Gun", "Shop"} {
		if isIntroName(n) {
			t.Errorf("%q 不该判成片头 —— 会把正片开头切掉", n)
		}
	}
}

func TestIsOutroName短词要整词匹配(t *testing.T) {
	for _, n := range []string{"ED", "ed", "Outro", "Credits", "Ending", "片尾", "下集预告", "End Credits"} {
		if !isOutroName(n) {
			t.Errorf("%q 该判成片尾", n)
		}
	}
	for _, n := range []string{"Wedding", "Red", "Bed", "Speed", "Chapter 9"} {
		if isOutroName(n) {
			t.Errorf("%q 不该判成片尾 —— 会把正片结尾切掉", n)
		}
	}
}

// 片头只在**前 40%** 里找。
//
// ★ 有些剧集把片尾曲也叫 "OP"(插入曲/同名主题曲),不设这道闸会在快看完时
// 把人一脚踹到片尾。
func TestIntroRange只在前四成里找(t *testing.T) {
	runtime := 1400.0
	// 正常:片头在 30s,下一章 120s
	if a, b, ok := IntroRange(chs(0.0, "Prologue", 30.0, "OP", 120.0, "Part A"), runtime); !ok || a != 30 || b != 120 {
		t.Fatalf("正常片头没识别: %v %v %v", a, b, ok)
	}
	// 一首叫 OP 的插入曲落在 80% 处 —— 不能跳
	if _, _, ok := IntroRange(chs(0.0, "Part A", 1200.0, "OP"), runtime); ok {
		t.Fatal("后段的 OP 不该被当成片头 —— 会把人一脚踹到片尾")
	}
}

// 「片头」超过 5 分钟多半是误判的正片章节,不跳。
func TestIntroRange太长不跳(t *testing.T) {
	if _, _, ok := IntroRange(chs(0.0, "OP", 600.0, "Part A"), 3000); ok {
		t.Fatal("10 分钟的「片头」多半是误判,不该跳")
	}
	// 边界:整 5 分钟允许,5 分 1 秒不允许
	if _, _, ok := IntroRange(chs(0.0, "OP", 300.0, "Part A"), 3000); !ok {
		t.Fatal("整 5 分钟应当允许")
	}
	if _, _, ok := IntroRange(chs(0.0, "OP", 301.0, "Part A"), 3000); ok {
		t.Fatal("超过 5 分钟不该跳")
	}
}

// ★★ 片尾是**最后一个章节**时不跳。
//
// 跳过去就等于把这一集直接结束掉 —— 用户要的是「跳过片尾」,不是「提前结束」,
// 这两件事差得远。
func TestOutroRange最后一章不跳(t *testing.T) {
	runtime := 1400.0
	// 片尾后面还有「下集预告」——可以跳
	if a, b, ok := OutroRange(chs(0.0, "Part A", 1200.0, "ED", 1300.0, "Next Episode"), runtime); !ok || a != 1200 || b != 1300 {
		t.Fatalf("有后续内容时应当可跳: %v %v %v", a, b, ok)
	}
	// 片尾是最后一章 —— 不跳
	if _, _, ok := OutroRange(chs(0.0, "Part A", 1200.0, "ED"), runtime); ok {
		t.Fatal("片尾是最后一章时不该跳 —— 那等于把这一集直接结束掉")
	}
	// 落点贴着结尾(<5s)也当没内容
	if _, _, ok := OutroRange(chs(0.0, "Part A", 1200.0, "ED", 1396.0, "彩蛋"), runtime); ok {
		t.Fatal("落点贴着结尾时不该跳 —— 跳过去只看到一秒黑屏")
	}
}

// 片尾只在**后 25%** 里找。
func TestOutroRange只在后四分之一里找(t *testing.T) {
	// "ED" 落在 10% 处(比如某个叫 "Ed" 的角色章节)—— 不跳
	if _, _, ok := OutroRange(chs(0.0, "Part A", 140.0, "ED", 400.0, "Part B"), 1400); ok {
		t.Fatal("前段的 ED 不该被当成片尾")
	}
}

// 总时长未知(0)时:片头照常找(没有比例闸),片尾**一律不跳**。
//
// ★ 片尾判定完全依赖总时长(后 25% + 落点离结尾的距离),没有它就只能不跳。
func TestRange总时长未知(t *testing.T) {
	if _, _, ok := IntroRange(chs(0.0, "OP", 90.0, "Part A"), 0); !ok {
		t.Fatal("总时长未知时片头仍该能识别")
	}
	if _, _, ok := OutroRange(chs(0.0, "Part A", 1200.0, "ED", 1300.0, "预告"), 0); ok {
		t.Fatal("总时长未知时片尾必须不跳 —— 判据全靠它")
	}
}

// 没有章节 = 两个功能都静默不工作,不能报错也不能瞎猜。
func TestRange无章节(t *testing.T) {
	if _, _, ok := IntroRange(nil, 1400); ok {
		t.Fatal("没章节就不该跳片头")
	}
	if _, _, ok := OutroRange(nil, 1400); ok {
		t.Fatal("没章节就不该跳片尾")
	}
}
