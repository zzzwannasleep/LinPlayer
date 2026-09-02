package player

import (
	"strings"
	"testing"
	"time"
)

// 分类器:该认的要认,不该认的一条都不许认。
//
// ★ 「不该认的」比「该认的」更要紧:mpv 的 error 级日志里还有网络、解码、字幕的错。
// 误判成着色器坏了,会把用户好好的画质档位无故关掉 —— 而且他找不到原因。
func Test着色器错误分类(t *testing.T) {
	// 真机 2026-09-02 抓到的原文
	yes := []string{
		"fragment shader compile log (status=0):",
		"ERROR: 0:58: 'linearize' : no matching overloaded function found",
		"fragment shader source:",
		"vertex shader source:",
		"shader link log (status=0):",
	}
	for _, s := range yes {
		if !isShaderCompileError(s) {
			t.Errorf("应当认出是着色器编译失败:%q", s)
		}
	}
	no := []string{
		"Failed to open http://example.invalid/x.mkv",
		"Could not open codec.",
		"Error parsing subtitle file",
		"cu->cuGLGetDevices(...) failed -> CUDA_ERROR_OPERATING_SYSTEM",
		"Failed sending hook command auto_profiles/on_load. Removing hook.",
		"Loading failed.",
	}
	for _, s := range no {
		if isShaderCompileError(s) {
			t.Errorf("**误判**:这不是着色器编译失败,认成了就会无故关掉用户的档位:%q", s)
		}
	}
}

// 只留一条、取走即清、不相关的日志不许覆盖。
func Test着色器错误_只留一条且取走即清(t *testing.T) {
	clearShaderErr()
	noteMpvLog("ERROR: 0:58: 'linearize' : no matching overloaded function found")
	noteMpvLog("Could not open codec.") // 不相关的,不许覆盖
	noteMpvLog("ERROR: 0:59: 'x' : field selection requires structure")

	got := takeShaderErr()
	if !strings.Contains(got, "0:58") {
		t.Fatalf("第一条诊断行就该定下来,实得 %q", got)
	}
	if again := takeShaderErr(); again != "" {
		t.Fatalf("取走之后要清空,实得 %q —— 不清的话下一次挂档位会被上一次的错误误伤", again)
	}
}

// 没有错误时不许假报,而且不许把 UI 白晾满一个窗口。
func Test着色器等待_无错时快速返回空(t *testing.T) {
	old := shaderWaitWindow
	shaderWaitWindow = 120 * time.Millisecond
	defer func() { shaderWaitWindow = old }()

	clearShaderErr()
	t0 := time.Now()
	if e := waitShaderCompileError(); e != "" {
		t.Fatalf("没有错误却报了 %q", e)
	}
	if d := time.Since(t0); d > 600*time.Millisecond {
		t.Fatalf("等了 %v,远超窗口 —— UI 会明显卡一下", d)
	}
}

// 错误在窗口内冒出来要接得住(着色器是渲染第一帧时才编译的,不是设选项那一刻)。
func Test着色器等待_窗口内冒出来要接住(t *testing.T) {
	old := shaderWaitWindow
	shaderWaitWindow = 500 * time.Millisecond
	defer func() { shaderWaitWindow = old }()

	clearShaderErr()
	go func() {
		time.Sleep(60 * time.Millisecond)
		noteMpvLog("fragment shader compile log (status=0):")
	}()
	if e := waitShaderCompileError(); e == "" {
		t.Fatal("窗口内冒出来的编译错误没接住 —— 用户会拿到一屏纯色还被告知「已启用」")
	}
}

// 给 UI 的文本只取第一行并截断。
func TestFirstLine截断(t *testing.T) {
	if got := firstLine("第一行\n第二行\n第三行"); got != "第一行" {
		t.Errorf("只该留第一行,实得 %q", got)
	}
	long := strings.Repeat("x", 500)
	if got := firstLine(long); len([]rune(got)) > 205 {
		t.Errorf("没截断,长度 %d", len([]rune(got)))
	}
}


// 留下的那一条**必须是说清楚哪里错了的那行**,不是表头。
//
// ★ 真机 2026-09-02:第一版只留第一条,于是截图上写着
// 「mpv 的原话:fragment shader source:」—— 等于什么都没说。
func Test着色器错误_要升级到真正的诊断行(t *testing.T) {
	clearShaderErr()
	noteMpvLog("fragment shader source:")                                        // 表头,先到
	noteMpvLog("ERROR: 0:58: 'linearize' : no matching overloaded function found") // 真话,后到
	noteMpvLog("ERROR: 0:59: 'x' : field selection requires structure")            // 再后到的不许覆盖

	got := takeShaderErr()
	if !strings.Contains(got, "linearize") {
		t.Fatalf("应当升级到第一条真正的诊断行,实得 %q —— 交给用户的是一句没用的表头", got)
	}
	if strings.Contains(got, "0:59") {
		t.Fatalf("升级只该发生一次,实得 %q", got)
	}
}
