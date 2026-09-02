package translate

import (
	"context"
	"errors"
	"strings"
	"testing"
)

// ★★ 分块规则:条数超限或累计字符超限即断批;**单条超限也自成一批,不能丢**。
func TestChunkRanges(t *testing.T) {
	mk := func(texts ...string) []Cue {
		out := make([]Cue, 0, len(texts))
		for _, t := range texts {
			out = append(out, Cue{Text: t})
		}
		return out
	}
	// 按条数断批
	got := chunkRanges(mk("a", "b", "c", "d", "e"), 2, 0)
	if len(got) != 3 || got[0] != [2]int{0, 2} || got[2] != [2]int{4, 5} {
		t.Fatalf("按条数断批不对:%v", got)
	}
	// 按字符断批
	got = chunkRanges(mk("aaaa", "bbbb", "cc"), 100, 6)
	if len(got) != 2 || got[0] != [2]int{0, 1} {
		t.Fatalf("按字符断批不对:%v", got)
	}
	// ★ 单条就超限:必须自成一批,**不能被丢掉**
	long := strings.Repeat("x", 5000)
	got = chunkRanges(mk(long, "b"), 100, 100)
	total := 0
	for _, r := range got {
		total += r[1] - r[0]
	}
	if total != 2 {
		t.Fatalf("超长条目被丢了:%v", got)
	}
	// 字符数按**字符**算不是字节:一个汉字算一个
	got = chunkRanges(mk("中文中文", "中文中文"), 100, 5)
	if len(got) != 2 {
		t.Fatalf("字符数应当按 rune 算:%v", got)
	}
	if len(chunkRanges(nil, 10, 10)) != 0 {
		t.Fatal("空输入该是空批次")
	}
}

// fakeEngine 按脚本失败的假引擎:记录每次收到的批大小。
type fakeEngine struct {
	// failIfLargerThan 批大小超过它就报错(模拟「回包条数不齐」)。
	failIfLargerThan int
	// alwaysFail 单条也失败。
	alwaysFail bool
	sizes      []int
}

func (f *fakeEngine) ID() string          { return "fake" }
func (f *fakeEngine) MaxBatchSize() int   { return 100 }
func (f *fakeEngine) MaxBatchChars() int  { return 0 }
func (f *fakeEngine) MaxConcurrency() int { return 1 }
func (f *fakeEngine) Translate(_ context.Context, texts []string, _, _ string) ([]string, error) {
	f.sizes = append(f.sizes, len(texts))
	if f.alwaysFail || len(texts) > f.failIfLargerThan {
		return nil, errors.New("回包条数不一致")
	}
	out := make([]string, 0, len(texts))
	for _, t := range texts {
		out = append(out, "译:"+t)
	}
	return out, nil
}

// ★★ 引擎报错要**二分重试**,而不是整批放弃。
//
// 百度那家会在偶发合并空行时回包行数对不齐 —— 不二分的话一次抖动就毁掉
// 整批 50 条字幕(它们会被回退成原文)。
func TestTranslateChunk_二分重试(t *testing.T) {
	f := &fakeEngine{failIfLargerThan: 1}
	out := translateChunk(context.Background(), f, []string{"a", "b", "c", "d"}, "auto", "zh")
	if out.failed != 0 {
		t.Fatalf("二分到单条就该成功,实得 failed=%d", out.failed)
	}
	if len(out.texts) != 4 || out.texts[0] != "译:a" || out.texts[3] != "译:d" {
		t.Fatalf("二分后顺序/内容不对:%v", out.texts)
	}
	// 4 -> 2+2 -> 1+1+1+1:每一层都试过
	if len(f.sizes) < 5 {
		t.Fatalf("没有真的二分:%v", f.sizes)
	}
}

// ★ 单条也失败时**回退原文**并记账,不是把整个流程中断 ——
// 一句译不出来不该让另外 900 句也没有。
func TestTranslateChunk_单条失败回退原文(t *testing.T) {
	f := &fakeEngine{alwaysFail: true}
	out := translateChunk(context.Background(), f, []string{"a", "b"}, "auto", "zh")
	if out.failed != 2 {
		t.Fatalf("失败条数应当是 2,实得 %d", out.failed)
	}
	if len(out.texts) != 2 || out.texts[0] != "a" {
		t.Fatalf("没回退原文:%v", out.texts)
	}
	if out.err == nil {
		t.Fatal("要把最后一条错误带出去,上层靠它判断引擎是否整体不可用")
	}
}

// ★★ **全部失败要报错**,不能静默产出一份未翻译的文件。
//
// 静默产出的表现是「翻译完成了,但字幕还是英文」—— 用户完全看不出是
// API Key 没配对还是服务没开通。
func TestTranslateDocument_全失败要报错(t *testing.T) {
	doc := &Document{Cues: []Cue{{Text: "a"}, {Text: "b"}}}
	err := TranslateDocument(context.Background(), doc, &fakeEngine{alwaysFail: true}, "auto", "zh", nil)
	if err == nil {
		t.Fatal("全部条目失败却没报错 —— 用户会拿到一份没翻译的字幕并以为翻译坏了")
	}
	if !strings.Contains(err.Error(), "引擎不可用") {
		t.Fatalf("报错要说清是引擎不可用:%v", err)
	}
}

// ★ 译文要贴回**对应的那一条**。贴错的表现是字幕整体错位,而且没有任何报错。
func TestTranslateDocument_译文贴回原位(t *testing.T) {
	doc := &Document{Cues: []Cue{{Text: "a"}, {Text: "b"}, {Text: "c"}}}
	f := &fakeEngine{failIfLargerThan: 100}
	if err := TranslateDocument(context.Background(), doc, f, "auto", "zh", nil); err != nil {
		t.Fatal(err)
	}
	for _, c := range doc.Cues {
		if c.Translated != "译:"+c.Text {
			t.Fatalf("译文贴错位:%#v", doc.Cues)
		}
	}
}

// ---------------------------------------------------------------------------

func TestNormLang(t *testing.T) {
	cases := map[string]string{
		"en-GB": "en", "zh-TW": "zh-hant", "cht": "zh-hant", "big5": "zh-hant",
		"zh": "zh-hans", "chs": "zh-hans", "zh-CN": "zh-hans",
		"jpn": "ja", "fre": "fr", "ita": "it", "": "auto", "und": "auto", "AUTO": "auto",
	}
	for in, want := range cases {
		if got := NormLang(in); got != want {
			t.Fatalf("NormLang(%q)=%q 想要 %q", in, got, want)
		}
	}
}

// ★ 各家的语言码互不相同,而且**日语最容易错**:百度是 jp,腾讯是 ja。
// 写反的表现是「翻译出来还是日文」或者直接报参数错。
func TestLangCodeMapping(t *testing.T) {
	if ToBaidu("ja") != "jp" {
		t.Fatalf("百度的日语是 jp,实得 %s", ToBaidu("ja"))
	}
	if ToTencent("ja") != "ja" {
		t.Fatalf("腾讯的日语是 ja,实得 %s", ToTencent("ja"))
	}
	if ToBaidu("zh-TW") != "cht" || ToTencent("zh-TW") != "zh-TW" {
		t.Fatal("繁体中文的两家码不对")
	}
	// 不认识的一律 auto,不能原样透传(会被服务端拒)
	if ToBaidu("klingon") != "auto" || ToTencent("klingon") != "auto" {
		t.Fatal("未知语言码要回退 auto")
	}
}

// ★ 未知码要**原样喂给模型**(不是归一码)—— 归一剥掉的地区后缀对模型有意义。
func TestHumanLangName(t *testing.T) {
	if HumanLangName("zh-TW") != "Traditional Chinese" {
		t.Fatal("zh-TW")
	}
	if HumanLangName("auto") != "the source language" {
		t.Fatal("auto")
	}
	if HumanLangName("xx-YY") != "xx-YY" {
		t.Fatalf("未知码该原样返回,实得 %q", HumanLangName("xx-YY"))
	}
}

// ★ 模型爱在 JSON 前后加解释文字,所以要从第一个 [ 到最后一个 ] 抠;
// **长度对不上一律判失败**,交给二分重试 —— 硬凑会让字幕整体错位。
func TestParseJSONArray(t *testing.T) {
	got, ok := parseJSONArray("好的,结果是:[\"a\",\"b\"] 以上。", 2)
	if !ok || got[0] != "a" || got[1] != "b" {
		t.Fatalf("%v %v", got, ok)
	}
	if _, ok := parseJSONArray(`["a"]`, 2); ok {
		t.Fatal("长度对不上必须判失败")
	}
	if _, ok := parseJSONArray("没有数组", 1); ok {
		t.Fatal("没有数组该判失败")
	}
	// null 要变空串,不是 "null"
	got, ok = parseJSONArray(`["a",null]`, 2)
	if !ok || got[1] != "" {
		t.Fatalf("null 该折成空串:%v", got)
	}
}

// ★ 百度按「一行一条」对齐回包,所以条目内部的换行必须先压成空格。
func TestFlattenLines(t *testing.T) {
	got := flattenLines([]string{"a\nb", "  c  "})
	if got[0] != "a b" || got[1] != "c" {
		t.Fatalf("%q", got)
	}
}

func TestParseBaiduResponse(t *testing.T) {
	ok := map[string]any{"trans_result": []any{
		map[string]any{"dst": "一"}, map[string]any{"dst": "二"},
	}}
	got, err := parseBaiduResponse("baidu", ok, 2)
	if err != nil || got[1] != "二" {
		t.Fatalf("%v %v", got, err)
	}
	// error_code 要变成错误,不能当成空结果
	bad := map[string]any{"error_code": "54001", "error_msg": "Invalid Sign"}
	if _, err := parseBaiduResponse("baidu", bad, 1); err == nil ||
		!strings.Contains(err.Error(), "54001") {
		t.Fatalf("error_code 被吞了:%v", err)
	}
	// 行数不齐要报错(交给二分重试),不是截断
	short := map[string]any{"trans_result": []any{map[string]any{"dst": "一"}}}
	if _, err := parseBaiduResponse("baidu", short, 2); err == nil {
		t.Fatal("行数不齐必须报错")
	}
}

// ★★ 腾讯 TC3 签名链的**回归钉**。
//
// 这条不是「和腾讯对得上」的证明(那只有打真接口才验得了),而是防止
// 签名链被顺手改动:改了 canonical request 的任何一段、改了 scope、
// 改了派生顺序,签名都会变 —— 而线上表现只是一句 AuthFailure,查起来很贵。
func TestTencentSignature_回归钉(t *testing.T) {
	e := &TencentEngine{Config: TencentConfig{
		SecretID: "AKIDEXAMPLE", SecretKey: "SECRETEXAMPLE", Region: "ap-beijing",
	}}
	got := e.buildAuthorization("TextTranslateBatch", `{"a":1}`, 1700000000, "2023-11-14")
	// 值是 2026-09-02 从这份实现算出来钉下的。
	const want = "TC3-HMAC-SHA256 Credential=AKIDEXAMPLE/2023-11-14/tmt/tc3_request, " +
		"SignedHeaders=content-type;host;x-tc-action, " +
		"Signature=59d19be9269f4c8db4b03f342cf4fa29648bd83e4b869ce954aa3def5c7117c7"
	if got != want {
		t.Fatalf("签名链变了。这不一定是错的,但**必须是有意的**:\n 得到 %s\n 想要 %s", got, want)
	}
	// 载荷变了签名必须变(否则说明 payload 根本没进签名)
	other := e.buildAuthorization("TextTranslateBatch", `{"a":2}`, 1700000000, "2023-11-14")
	if other == got {
		t.Fatal("改了载荷签名却没变 —— payload 没参与签名")
	}
	// action 变了签名也必须变(它在 canonical headers 里)
	if e.buildAuthorization("TextTranslate", `{"a":1}`, 1700000000, "2023-11-14") == got {
		t.Fatal("改了 action 签名却没变")
	}
}

// ★ 未配置的引擎必须返回 nil —— UI 据此禁用「翻译」入口。
// 返回一个「配置为空的引擎」的话,用户点了翻译才发现打不通。
func TestBuildEngine_没配全返回nil(t *testing.T) {
	s := DefaultSettings()
	for _, k := range AllEngineKinds {
		if BuildEngine(k, s) != nil {
			t.Fatalf("%s 默认没填 key,不该造出引擎", k)
		}
	}
	s.OpenAI.APIKey = "sk-x"
	if BuildEngine(EngineOpenAI, s) == nil {
		t.Fatal("填了 key 就该造得出来")
	}
	// 百度:两种鉴权任意一种齐了就算
	s.BaiduGeneral.AppID = "1"
	if BuildEngine(EngineBaiduGeneral, s) != nil {
		t.Fatal("只有 appId 不算配好")
	}
	s.BaiduGeneral.SecretKey = "k"
	if BuildEngine(EngineBaiduGeneral, s) == nil {
		t.Fatal("appId+secretKey 该算配好")
	}
}
