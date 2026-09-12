package player

import (
	"os"
	"path/filepath"
	"strings"
	"testing"
)

// N1(CVE-2026-8461):magicyuv 解码器必须被拉黑。
//
// ★★ 这条测试存在的**唯一**理由:这条防护已经在一次重构里静默丢过一回
// (TODO.md N1)。丢了之后编译绿、单测绿、运行时也不报错 —— 只是防护没了。
// 「靠文档提醒防不住重构,只有测试能。」
func Test基础选项_magicyuv必须被拉黑(t *testing.T) {
	want := [2]string{"vd", "-magicyuv"}
	for _, kv := range baseOptions("auto", "", "") {
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
	for _, kv := range baseOptions("auto", "D:/x/cache/shaders", "") {
		got[kv[0]] = kv[1]
	}
	if got["gpu-shader-cache"] != "yes" {
		t.Errorf("gpu-shader-cache 应为 yes,实得 %q", got["gpu-shader-cache"])
	}
	if got["gpu-shader-cache-dir"] != "D:/x/cache/shaders" {
		t.Errorf("gpu-shader-cache-dir 没传对,实得 %q", got["gpu-shader-cache-dir"])
	}

	// 目录为空(建不出来)时不许把这两项设上 —— 给 mpv 一个空路径比不给更糟。
	for _, kv := range baseOptions("auto", "", "") {
		if kv[0] == "gpu-shader-cache-dir" {
			t.Errorf("没有可用目录时不该设 gpu-shader-cache-dir")
		}
	}
}

// hwdec 要原样透传(LP_HWDEC 是自检台切软硬解的唯一开关)。
func Test基础选项_hwdec原样透传(t *testing.T) {
	for _, kv := range baseOptions("no", "", "") {
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
	if bad := checkOptionNames(baseOptions("auto", "D:/x/cache/shaders", "")); len(bad) > 0 {
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


// ---- 用户的 mpv.conf ----

// 不给 config-dir 时**一个 config 相关的选项都不许出现**:
// libmpv 默认 config=no,给一半(开了 config 却没给目录)会去读 mpv 自己那套默认位置。
func Test基础选项_没有用户配置时不开config(t *testing.T) {
	for _, kv := range baseOptions("auto", "", "") {
		if kv[0] == "config" || kv[0] == "config-dir" {
			t.Fatalf("没有用户 mpv.conf 时不该设 %s", kv[0])
		}
	}
}

// 给了目录就必须两项都设上。
//
// ☠ 只设 config-dir 不设 config=yes 的表现是:文件在、路径对、mpv 就是不读 ——
// 设置页里那个「导入 mpv.conf」变成一个装成功能的入口。
func Test基础选项_给了配置目录就要开config(t *testing.T) {
	got := map[string]string{}
	for _, kv := range baseOptions("auto", "", "D:/x/userdata/mpv") {
		got[kv[0]] = kv[1]
	}
	if got["config"] != "yes" {
		t.Errorf("config 应为 yes,实得 %q —— 这样 mpv 根本不会读那份 mpv.conf", got["config"])
	}
	if got["config-dir"] != "D:/x/userdata/mpv" {
		t.Errorf("config-dir 没传对,实得 %q", got["config-dir"])
	}
	/* ☠ 壳会把自己没用掉的键 keypress 给 mpv(input.conf 生效的唯一通路)。
	   默认键位不关的话 `q` 当场退播放器、`s` 悄悄截图 —— 而这些键在转发之前
	   一个都到不了 mpv,所以关掉是维持原样,不是减功能。 */
	if got["input-default-bindings"] != "no" {
		t.Errorf("默认键位没关(实得 %q)—— 转发按键之后 q 会把播放器退掉",
			got["input-default-bindings"])
	}
}

// ★★ **实测**:用户的 mpv.conf **顶得掉**我们在 mpv_initialize 之前设的选项。
//
// 这条测试记的是一个事实,不是一个期望 —— 它是 sanitizeMpvConf 存在的全部理由。
// 哪天 mpv 改了这个行为(config 文件不再赢),这条会红,那时才可以谈「过滤能不能撤」。
// 拿 keep-open 当探针:它 init 之后读得回来,而且和画面无关。
func Test用户配置_会顶掉我们设的选项_所以必须过滤(t *testing.T) {
	dir := confDirWith(t, "keep-open=yes"+NL)
	// 先确认这份 conf 真的被读进去了(我们什么都不设,值只能来自 conf)——
	// 读不进去的话下面那条断言是恒绿的
	switch probeConfDirPrecedence(dir, "keep-open", "") {
	case "":
		t.Skip("这台机器上起不了 mpv 探针,跳过")
	case "yes": // 探针有效
	default:
		t.Fatal("探针没读到 mpv.conf —— 下面那条断言恒绿,不可信")
	}
	if got := probeConfDirPrecedence(dir, "keep-open", "no"); got != "yes" {
		t.Fatalf("mpv.conf 不再顶掉我们设的值(实得 %q)。"+
			"如果这是 mpv 的新行为,sanitizeMpvConf 的理由要重新评估", got)
	}
}

// 过滤器:会砸掉画面的那几行必须被摘掉,别的一行不动。
//
// ☠ `vo` 这一行放过去就是**全程黑屏且一条错都不报** —— vo=libmpv 是 render context
// 的前提。这条是整个「导入 mpv.conf」功能的安全底线。
func Test过滤mpv配置_砸画面的行被摘掉别的不动(t *testing.T) {
	src := "# 我的配置" + NL +
		"profile=gpu-hq" + NL +
		"vo=gpu" + NL +
		"--wid=123" + NL +
		"  Config-Dir = /tmp  " + NL +
		"scale=ewa_lanczossharp" + NL +
		"[hq]" + NL +
		"include=/etc/other.conf" + NL
	clean, dropped := sanitizeMpvConf(src)
	if len(dropped) != 4 {
		t.Fatalf("该摘 4 行(vo/wid/config-dir/include),实得 %d:%v", len(dropped), dropped)
	}
	for _, keep := range []string{"profile=gpu-hq", "scale=ewa_lanczossharp", "[hq]"} {
		if !strings.Contains(clean, NL+keep) && !strings.HasPrefix(clean, keep) {
			t.Errorf("这一行不该动:%s", keep)
		}
	}
	for _, gone := range []string{"vo=gpu", "wid=123", "include=/etc/other.conf"} {
		for _, ln := range strings.Split(clean, NL) {
			if strings.TrimSpace(ln) == gone {
				t.Errorf("这一行必须被注释掉:%s", gone)
			}
		}
	}
	// 行号要对得上 —— 用户拿日志找自己那一行时靠的是行号
	if got, want := len(strings.Split(clean, NL)), len(strings.Split(src, NL)); got != want {
		t.Errorf("过滤后行数变了(%d → %d),日志里的行号就对不上了", want, got)
	}
}

const NL = "\n"

func confDirWith(t *testing.T, body string) string {
	t.Helper()
	dir := t.TempDir()
	if err := os.WriteFile(filepath.Join(dir, "mpv.conf"), []byte(body), 0o644); err != nil {
		t.Fatal(err)
	}
	return dir
}
