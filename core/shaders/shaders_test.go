package shaders

import (
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"testing"
	"time"
)

// 档位表里引用的每个文件都必须真的嵌进来了 —— 否则**运行时才炸**(超分点了没反应)。
func TestEveryPresetFileIsEmbedded(t *testing.T) {
	for _, lv := range Levels() {
		p, ok := PresetOf(lv.ID)
		if !ok {
			continue
		}
		for _, f := range p.Files {
			if bodyOf(f) == "" {
				t.Errorf("档位 %s 引用了未嵌入的 shader: %s", lv.ID, f)
			}
		}
	}
}

// ★★ 本档 opts 里写的每个参数名,都必须真的存在于**本档挂载的 shader** 里。
//
// 这是「强度烧进档位」这个设计唯一会静默失效的地方:
// **mpv 遇到不认识的参数名会把整条 glsl-shader-opts 拒掉** ——
// 于是锐化悄悄回到 shader 自带默认(CAS STR=0.5,只开一半),
// 正是用户「看不太出来」的那个状态,**而且不报错**。
//
// 典型踩法:给只挂 CAS 的档位写上 `SHARP=0`(RCAS 根本没加载)。
func TestEveryPresetOptNamesAParamThisPresetLoads(t *testing.T) {
	for _, lv := range Levels() {
		p, ok := PresetOf(lv.ID)
		if !ok {
			continue
		}
		var available []string
		for _, f := range p.Files {
			available = append(available, ParamsOf(f)...)
		}
		for _, kv := range splitOpts(p.Opts) {
			key, _, _ := strings.Cut(kv, "=")
			key = strings.TrimSpace(key)
			if !contains(available, key) {
				t.Errorf("档位 %s(%s)的参数 %q 不属于它挂载的任何 shader —— "+
					"mpv 会把整条 opts 拒掉,强度静默回到默认,而且不报错。可用的:%v",
					lv.ID, lv.Name, key, available)
			}
		}
	}
}

// 每个 opts 的值都要落在 shader 声明的区间里。
//
// ★ 越界值 mpv 同样是静默处理 —— 要么钳、要么整条拒,两种都让「强 档」变成「默认档」。
func TestEveryPresetOptValueIsInRange(t *testing.T) {
	for _, lv := range Levels() {
		p, ok := PresetOf(lv.ID)
		if !ok {
			continue
		}
		for _, kv := range splitOpts(p.Opts) {
			key, val, _ := strings.Cut(kv, "=")
			key, val = strings.TrimSpace(key), strings.TrimSpace(val)
			v, err := strconv.ParseFloat(val, 64)
			if err != nil {
				t.Errorf("%s 的 %s 不是数字", lv.ID, kv)
				continue
			}
			owner := ""
			for _, f := range p.Files {
				if contains(ParamsOf(f), key) {
					owner = f
					break
				}
			}
			if owner == "" {
				continue // 上一条测试已经报过了
			}
			min, max, ok := paramRange(owner, key)
			if !ok {
				continue // 这个 shader 没声明区间,放行
			}
			if v < min || v > max {
				t.Errorf("档位 %s 的 %s=%v 超出 %s 声明的区间 [%v, %v]", lv.ID, key, v, owner, min, max)
			}
		}
	}
}

// ★★ 锐化专精那一族:每档**只能挂一个锐化器**。
//
// Adaptive / aWarpSharp2 / BCAS 都叫 `STR`,而 `glsl-shader-opts` 是**全局**的 ——
// 叠在同一档里会共用一个值、量纲还不同(0~2 / -20~20 / 0~1),
// **必然串味且不报错**:用户选「自适应锐化 · 强」,拿到的却是 aWarpSharp2 的 1.9
// (它的区间是 -20~20,1.9 约等于没开)。
func TestSharpenPresetsLoadOnlyOneSharpener(t *testing.T) {
	sharpeners := map[string]bool{
		"Adaptive_sharpen_lite_luma_RT.glsl": true,
		"aWarpSharp2_RT.glsl":                true,
		"AMD_BCAS_RT.glsl":                   true,
		"AMD_CAS_luma_RT.glsl":               true,
	}
	for _, lv := range Levels() {
		p, ok := PresetOf(lv.ID)
		if !ok {
			continue
		}
		n := 0
		var got []string
		for _, f := range p.Files {
			if sharpeners[f] {
				n++
				got = append(got, f)
			}
		}
		if n > 1 {
			t.Errorf("档位 %s 挂了 %d 个共用 STR 的锐化器 %v —— glsl-shader-opts 是全局的,"+
				"它们会共用一个值而量纲不同,必然串味且不报错", lv.ID, n, got)
		}
	}
}

// ★★ 「窗口也生效」的判断必须**从 shader 源里现算**,不能手工维护名单。
//
// 语义是「**有效果**」,不是「全部 pass 都跑」:FSR 档在窗口下 EASU 放大那半会被跳过、
// RCAS 锐化那半照跑 → 判 true(退化成只锐化)。
// Rust 侧第一版照直觉把 FSR 档标成 false,是测试红了才发现 RCAS 的门槛
// (`//!WHEN SHARP 4.0 <`)是**参数**不是尺寸。
func TestWorksAtAnySize(t *testing.T) {
	// 锐化专精那一族:**全部**该是「窗口也生效」—— 它是日常首选,标错就等于把它藏了
	for _, id := range []string{"sh_ada_l", "sh_ada_m", "sh_ada_h", "sh_fine_m", "sh_fine_h", "sh_warp", "sh_bcas"} {
		if !WorksAtAnySize(id) {
			t.Errorf("%s 该是窗口也生效的 —— 这一族全是参数门槛,不挑尺寸", id)
		}
	}
	// 去噪族也不挑尺寸
	for _, id := range []string{"ak_denoise_l", "ak_denoise_h", "ak_sharp"} {
		if !WorksAtAnySize(id) {
			t.Errorf("%s 该是窗口也生效的", id)
		}
	}
	// FSR 放大档:窗口下退化成只锐化,仍算「有效果」
	for _, id := range []string{"fsr_up", "fsr_up_h", "fsr_up_dn"} {
		if !WorksAtAnySize(id) {
			t.Errorf("%s 在窗口下会退化成只锐化,仍该判 true —— "+
				"RCAS 的门槛是参数不是尺寸(这是照直觉最容易写错的一条)", id)
		}
	}
	// 纯 CNN 放大档:窗口下**一帧都不跑**
	for _, id := range []string{"ak_up_m", "ak_up_vl", "ak_up_artcnn", "nv_up", "nv_up_h"} {
		if WorksAtAnySize(id) {
			t.Errorf("%s 是纯放大档,窗口下一帧都不跑,不该判 true —— "+
				"标错就是「UI 说生效了,画面一点没变」", id)
		}
	}
	// off / 未知
	if WorksAtAnySize("off") || WorksAtAnySize("根本没这档") {
		t.Error("off / 未知档位不该判 true")
	}
}

// ★★ 「挂上了」和「会跑」是两件事。
//
// 2026-07-15 真机:窗口 1770×1080 播 1920×1080,六个 CNN pass 全被 //!WHEN 跳过,
// 而 UI 还在报「超分已生效 · 挂载 6 个 shader」。**那是在撒谎**,
// 正是本项目最贵的那类 bug。
func TestWillRun(t *testing.T) {
	// 放大档:输出没比源大 1.2 倍就不跑
	if run, ok := WillRun("ak_up_m", 1920, 1080, 1770, 1080); !ok || run {
		t.Errorf("窗口 1770×1080 播 1920×1080 时放大档不该跑,实得 run=%v ok=%v", run, ok)
	}
	if run, ok := WillRun("ak_up_m", 1920, 1080, 3840, 2160); !ok || !run {
		t.Errorf("全屏 4K 播 1080p 时放大档该跑,实得 run=%v ok=%v", run, ok)
	}
	// 恰好 1.2 倍:不算(源里写的是**严格大于**)
	if run, _ := WillRun("ak_up_m", 1000, 1000, 1200, 1200); run {
		t.Error("恰好 1.2 倍不该跑 —— shader 里写的是严格大于")
	}
	// 锐化档:任何尺寸都跑,连尺寸都不用问
	if run, ok := WillRun("sh_ada_m", 0, 0, 0, 0); !ok || !run {
		t.Errorf("锐化档不挑尺寸,尺寸未知也该判 true,实得 run=%v ok=%v", run, ok)
	}
	// 尺寸未知(没在播)时**不下结论**
	if _, ok := WillRun("ak_up_m", 0, 0, 0, 0); ok {
		t.Error("尺寸未知时不该下结论 —— 猜一个就是在撒谎")
	}
	// off / 未知
	if _, ok := WillRun("off", 1920, 1080, 3840, 2160); ok {
		t.Error("off 不该有结论")
	}
}

// WhenRatio 这个常量必须和 shader 源里写死的门槛一致。
//
// ★ 从**嵌入的源**里抠出来比对,而不是相信注释 —— 换 shader 文件时这条会红。
func TestWhenRatioMatchesShaderSource(t *testing.T) {
	body := bodyOf("Anime4K_Upscale_CNN_x2_M.glsl")
	if body == "" {
		t.Fatal("拿不到 shader 源")
	}
	found := false
	for _, l := range strings.Split(body, "\n") {
		if !strings.HasPrefix(l, "//!WHEN") || !strings.Contains(l, "OUTPUT.") {
			continue
		}
		found = true
		want := strconv.FormatFloat(WhenRatio, 'f', 3, 64) // "1.200"
		if !strings.Contains(l, want) {
			t.Errorf("WhenRatio=%v 与 shader 源里的门槛对不上:%s", WhenRatio, strings.TrimSpace(l))
		}
	}
	if !found {
		t.Error("这个 shader 里没找到尺寸门槛那一行 —— 是不是换文件了?")
	}
}

// ★ Restore CNN **不许加回来**。
//
// 用户 2026-07-11 明确否掉:动态画面边缘振铃 / 拖影,且最吃显卡。
// 2026-07-15 他又问了一遍「为什么要用还原」。这条测试就是那个「别再走回头路」的钉子。
func TestRestoreCNNStaysGone(t *testing.T) {
	for _, lv := range Levels() {
		p, ok := PresetOf(lv.ID)
		if !ok {
			continue
		}
		for _, f := range p.Files {
			if strings.Contains(strings.ToLower(f), "restore") {
				t.Errorf("档位 %s 又把 Restore CNN 加回来了(%s)—— "+
					"用户两次明确否掉:边缘振铃/拖影,且最吃显卡", lv.ID, f)
			}
		}
	}
}

// 落盘:内容一致时**不重写**(免得每次起播写 520KB),路径能直接喂给 mpv。
func TestEnsureFilesIsIdempotent(t *testing.T) {
	dir := t.TempDir()
	m1, err := EnsureFiles(dir)
	if err != nil {
		t.Fatal(err)
	}
	if len(m1) == 0 {
		t.Fatal("一个都没落下来")
	}
	target := m1["AMD_CAS_luma_RT.glsl"]
	st1, err := os.Stat(target)
	if err != nil {
		t.Fatal(err)
	}
	// 把 mtime 拨旧,再跑一次:内容一致就不该被重写
	old := st1.ModTime().Add(-time.Hour)
	if err := os.Chtimes(target, old, old); err != nil {
		t.Fatal(err)
	}
	if _, err := EnsureFiles(dir); err != nil {
		t.Fatal(err)
	}
	st2, _ := os.Stat(target)
	if !st2.ModTime().Equal(old) {
		t.Error("内容没变却重写了 —— 每次起播白写 520KB")
	}

	// 文件被改坏(长度不同)时要重新落
	if err := os.WriteFile(target, []byte("坏了"), 0o644); err != nil {
		t.Fatal(err)
	}
	if _, err := EnsureFiles(dir); err != nil {
		t.Fatal(err)
	}
	if b, _ := os.ReadFile(target); string(b) == "坏了" {
		t.Error("文件长度对不上时该重新落盘")
	}
}

func TestPaths(t *testing.T) {
	dir := t.TempDir()
	got, err := Paths(dir, "ak_sharp")
	if err != nil {
		t.Fatal(err)
	}
	if len(got) != 2 {
		t.Fatalf("ak_sharp 该有两个 pass,实得 %v", got)
	}
	// ★ 顺序就是 pipeline:先去噪(在源分辨率上最干净)再锐化,反了效果就不一样
	if !strings.Contains(got[0], "Denoise") || !strings.Contains(got[1], "CAS") {
		t.Fatalf("顺序不对(该是先去噪再锐化): %v", got)
	}
	for _, p := range got {
		if !filepath.IsAbs(p) {
			t.Errorf("mpv 的 glsl-shaders 只收绝对路径: %s", p)
		}
	}
	// off / 未知 = 空列表(把上一档关掉)
	for _, id := range []string{"off", "根本没这档"} {
		if g, err := Paths(dir, id); err != nil || len(g) != 0 {
			t.Errorf("%s 该给空列表,实得 %v %v", id, g, err)
		}
	}
}

// off 的 opts 是空串 —— 切到 off 时要**顺带把上一档的参数清掉**
// (glsl-shader-opts 是全局的,不清的话下一档会吃到上一档留下的值)。
func TestOptsForOff(t *testing.T) {
	if Opts("off") != "" || Opts("根本没这档") != "" {
		t.Error("off / 未知档位的 opts 该是空串")
	}
	if Opts("sh_ada_h") != "STR=1.90" {
		t.Errorf("档位参数没取对: %q", Opts("sh_ada_h"))
	}
}

// ---------------------------------------------------------------- 小工具

func splitOpts(s string) []string {
	var out []string
	for _, kv := range strings.Split(s, ",") {
		if strings.TrimSpace(kv) != "" {
			out = append(out, kv)
		}
	}
	return out
}

func contains(all []string, v string) bool {
	for _, x := range all {
		if x == v {
			return true
		}
	}
	return false
}

// paramRange 从 shader 源里抠出某个 //!PARAM 的 //!MINIMUM / //!MAXIMUM。
func paramRange(file, param string) (min, max float64, ok bool) {
	lines := strings.Split(bodyOf(file), "\n")
	i := -1
	for n, l := range lines {
		if strings.TrimSpace(l) == "//!PARAM "+param {
			i = n
			break
		}
	}
	if i < 0 {
		return 0, 0, false
	}
	gotMin, gotMax := false, false
	for _, l := range lines[i+1:] {
		t := strings.TrimSpace(l)
		switch {
		case strings.HasPrefix(t, "//!MINIMUM"):
			if v, err := strconv.ParseFloat(strings.TrimSpace(strings.TrimPrefix(t, "//!MINIMUM")), 64); err == nil {
				min, gotMin = v, true
			}
		case strings.HasPrefix(t, "//!MAXIMUM"):
			if v, err := strconv.ParseFloat(strings.TrimSpace(strings.TrimPrefix(t, "//!MAXIMUM")), 64); err == nil {
				max, gotMax = v, true
			}
		case strings.HasPrefix(t, "//!PARAM"), strings.HasPrefix(t, "//!HOOK"):
			return min, max, gotMin && gotMax // 到下一个声明为止
		}
	}
	return min, max, gotMin && gotMax
}
