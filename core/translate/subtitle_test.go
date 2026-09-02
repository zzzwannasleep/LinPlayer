package translate

import (
	"strings"
	"testing"
)

// ★★ 毫秒位数不足要**右补零**:`,5` 是 500ms 不是 5ms。
//
// 写错的表现是整轨字幕**越往后越对不上**(每条早半秒),而文件本身看着是好的。
func TestParseSRT_毫秒补零(t *testing.T) {
	cues := parseSRT("1\n00:00:01,5 --> 00:00:02,50\n你好\n")
	if len(cues) != 1 {
		t.Fatalf("应当解出 1 条,实得 %d", len(cues))
	}
	if cues[0].StartMS != 1500 {
		t.Fatalf(",5 应当是 500ms(共 1500),实得 %d", cues[0].StartMS)
	}
	if cues[0].EndMS != 2500 {
		t.Fatalf(",50 应当是 500ms(共 2500),实得 %d", cues[0].EndMS)
	}
}

func TestParseSRT_基本(t *testing.T) {
	src := "1\n00:00:01,000 --> 00:00:02,000\nHello\nWorld\n\n" +
		"2\n00:01:00,000 --> 00:01:02,500\n第二句\n"
	cues := parseSRT(src)
	if len(cues) != 2 {
		t.Fatalf("%#v", cues)
	}
	if cues[0].Text != "Hello\nWorld" {
		t.Fatalf("多行没接上: %q", cues[0].Text)
	}
	if cues[1].StartMS != 60000 || cues[1].EndMS != 62500 {
		t.Fatalf("%#v", cues[1])
	}
}

// ★ VTT 块可能带 cue 标识行,时间轴**不限定在前两行** —— 限定了会整块丢掉。
func TestParseVTT_标识行与内联标签(t *testing.T) {
	src := "WEBVTT\n\ncue-7\nSTYLE-ish\n00:00:03.000 --> 00:00:04.000\n<v Bob>Hi <c>there</c>\n"
	cues := parseVTT(src)
	if len(cues) != 1 {
		t.Fatalf("带标识行的块被丢了:%#v", cues)
	}
	if cues[0].Text != "Bob>Hi there" && cues[0].Text != "Hi there" {
		t.Fatalf("内联标签没剥干净: %q", cues[0].Text)
	}
	if cues[0].StartMS != 3000 {
		t.Fatalf("点号小数分隔符没吃下: %d", cues[0].StartMS)
	}
}

// ★★ ASS 的 Text 字段里**有逗号**。按逗号全切会把台词切碎,
// 表现是「字幕只显示前半句」。
func TestParseASS_Text里的逗号不能被切碎(t *testing.T) {
	src := `[Script Info]
[Events]
Format: Layer, Start, End, Style, Name, MarginL, MarginR, MarginV, Effect, Text
Dialogue: 0,0:00:01.00,0:00:02.50,Default,,0,0,0,,{\an8}你好,世界,再见
`
	cues := parseASS(src)
	if len(cues) != 1 {
		t.Fatalf("%#v", cues)
	}
	if cues[0].Text != "你好,世界,再见" {
		t.Fatalf("台词被逗号切碎了 / 覆盖标签没剥掉: %q", cues[0].Text)
	}
	// ASS 时间是**百分秒**:0:00:02.50 = 2500ms,不是 2050ms
	if cues[0].StartMS != 1000 || cues[0].EndMS != 2500 {
		t.Fatalf("ASS 时间(百分秒)算错了: %d -> %d", cues[0].StartMS, cues[0].EndMS)
	}
}

// ★ 自定义 Format 行里 Text 不在最后一列时也要认对。
func TestParseASS_跟随Format行(t *testing.T) {
	src := "[Events]\nFormat: Start, End, Text\nDialogue: 0:00:05.00,0:00:06.00,一句话\n"
	cues := parseASS(src)
	if len(cues) != 1 || cues[0].Text != "一句话" || cues[0].StartMS != 5000 {
		t.Fatalf("%#v", cues)
	}
}

func TestParseString_内容嗅探(t *testing.T) {
	if d := ParseString("[Script Info]\n[Events]\nFormat: Start, End, Text\nDialogue: 0:00:01.00,0:00:02.00,x\n", ""); len(d.Cues) != 1 {
		t.Fatal("ASS 没被嗅探出来")
	}
	if d := ParseString("WEBVTT\n\n00:00:01.000 --> 00:00:02.000\nx\n", ""); len(d.Cues) != 1 {
		t.Fatal("VTT 没被嗅探出来")
	}
	if d := ParseString("1\n00:00:01,000 --> 00:00:02,000\nx\n", ""); len(d.Cues) != 1 {
		t.Fatal("SRT 兜底没生效")
	}
}

// ★ 三种排版都要验:漏一种的表现是「双语字幕只显示一半」。
func TestToSRT_三种排版(t *testing.T) {
	doc := &Document{Cues: []Cue{{StartMS: 1000, EndMS: 2000, Text: "Hello", Translated: "你好"}}}
	cases := map[Layout]string{
		LayoutTranslatedOnly:  "你好",
		LayoutTranslatedFirst: "你好\nHello",
		LayoutOriginalFirst:   "Hello\n你好",
	}
	for layout, want := range cases {
		got := doc.ToSRT(layout)
		if !strings.Contains(got, want) {
			t.Fatalf("排版 %s 的正文不对:\n%s", layout, got)
		}
		if !strings.Contains(got, "00:00:01,000 --> 00:00:02,000") {
			t.Fatalf("时间轴格式不对:\n%s", got)
		}
	}
	// 没译文时只出原文,而且不能是空块
	untranslated := &Document{Cues: []Cue{{StartMS: 0, EndMS: 1000, Text: "Only"}}}
	if !strings.Contains(untranslated.ToSRT(LayoutTranslatedFirst), "Only") {
		t.Fatal("没译文时该回退原文")
	}
	// ★ 正文全空的条目要**整条跳过**,否则 SRT 里会出现空块,有的播放器直接罢工
	empty := &Document{Cues: []Cue{{StartMS: 0, EndMS: 1000, Text: "  "}}}
	if strings.TrimSpace(empty.ToSRT(LayoutTranslatedFirst)) != "" {
		t.Fatalf("空条目没被跳过:%q", empty.ToSRT(LayoutTranslatedFirst))
	}
}

// ★ SRT 序号必须**连续重编**。照搬原序号的话,跳过空条目会留下断号,
// 一部分播放器会在断号处停止解析。
func TestToSRT_序号连续(t *testing.T) {
	doc := &Document{Cues: []Cue{
		{StartMS: 0, EndMS: 1000, Text: "a"},
		{StartMS: 1000, EndMS: 2000, Text: "  "}, // 被跳过
		{StartMS: 2000, EndMS: 3000, Text: "b"},
	}}
	out := doc.ToSRT(LayoutTranslatedOnly)
	if !strings.HasPrefix(out, "1\n") || !strings.Contains(out, "\n2\n") {
		t.Fatalf("序号不连续:\n%s", out)
	}
	if strings.Contains(out, "\n3\n") {
		t.Fatalf("跳过的条目还占了号:\n%s", out)
	}
}
