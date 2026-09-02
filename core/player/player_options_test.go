package player

import "testing"

// N1(CVE-2026-8461):magicyuv 解码器必须被拉黑。
//
// ★★ 这条测试存在的**唯一**理由:这条防护已经在一次重构里静默丢过一回
// (TODO.md N1)。丢了之后编译绿、单测绿、运行时也不报错 —— 只是防护没了。
// 「靠文档提醒防不住重构,只有测试能。」
func Test基础选项_magicyuv必须被拉黑(t *testing.T) {
	want := [2]string{"vd", "-magicyuv"}
	for _, kv := range baseOptions("auto", "") {
		if kv == want {
			return
		}
	}
	t.Fatalf("mpv 起手选项里没有 %v —— CVE-2026-8461 的防护没了", want)
}

// 着色器缓存:给了目录就必须两项都设上。
//
// libmpv 没有配置目录,少给 `gpu-shader-cache-dir` 它就不落盘,
// 表现是每次起播重编整条 Anime4K 链(开着超分时第一秒卡一下)。
func Test基础选项_给了目录就要开着色器缓存(t *testing.T) {
	got := map[string]string{}
	for _, kv := range baseOptions("auto", "D:/x/cache/shaders") {
		got[kv[0]] = kv[1]
	}
	if got["gpu-shader-cache"] != "yes" {
		t.Errorf("gpu-shader-cache 应为 yes,实得 %q", got["gpu-shader-cache"])
	}
	if got["gpu-shader-cache-dir"] != "D:/x/cache/shaders" {
		t.Errorf("gpu-shader-cache-dir 没传对,实得 %q", got["gpu-shader-cache-dir"])
	}

	// 目录为空(建不出来)时不许把这两项设上 —— 给 mpv 一个空路径比不给更糟。
	for _, kv := range baseOptions("auto", "") {
		if kv[0] == "gpu-shader-cache-dir" {
			t.Errorf("没有可用目录时不该设 gpu-shader-cache-dir")
		}
	}
}

// hwdec 要原样透传(LP_HWDEC 是自检台切软硬解的唯一开关)。
func Test基础选项_hwdec原样透传(t *testing.T) {
	for _, kv := range baseOptions("no", "") {
		if kv[0] == "hwdec" {
			if kv[1] != "no" {
				t.Fatalf("hwdec 应为 no,实得 %q", kv[1])
			}
			return
		}
	}
	t.Fatal("选项表里根本没有 hwdec")
}

// ★★ 上面三条只钉住「表里写了」。这条钉住「**libmpv 真的认**」——
// 两者不是一回事:选项名写错、或者 libmpv 升级把它改名,
// mpv_set_option_string 只返回 -5 就完事,没有任何人会知道(N13)。
//
// 实测:不存在的选项名返回 -5(option not found)。
func Test基础选项_每个选项名libmpv都认(t *testing.T) {
	if bad := checkOptionNames(baseOptions("auto", "D:/x/cache/shaders")); len(bad) > 0 {
		t.Fatalf("libmpv 不认这些选项(功能等于关着,而且不会报错):%v", bad)
	}
}

// 反向断言:确认上面那条测试**有能力**发现问题,不是恒绿。
// 没有这一条的话,checkOptionNames 哪天变成永远返回空,上面那条会一直绿。
func Test选项名探测_对不存在的选项必须报出来(t *testing.T) {
	bad := checkOptionNames([][2]string{{"lp-绝不存在的选项", "1"}})
	if len(bad) != 1 {
		t.Fatalf("探测器没能识别出不存在的选项 —— 它现在是恒绿的,不可信;实得 %v", bad)
	}
}
