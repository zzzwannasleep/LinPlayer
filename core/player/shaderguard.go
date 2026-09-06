package player

// 着色器编译失败的自愈闸。
//
// ## 为什么需要它
//
// 2026-09-02 真机撞到:开 `ak_sharp` 之后**整屏变纯蓝**,而
//
//   · `mpv_set_option_string("glsl-shaders", …)` 返回 0(收下了)
//   · `player.setShaderLevel` 返回 `count=2, will_run=true`(尺寸判断也过了)
//   · 没有任何属性、任何返回码显示出错
//
// 唯一的线索在 mpv 的 **error 级日志**里:
//
//	ERROR: 0:58: 'linearize' : no matching overloaded function found
//
// 根因:黄金实现(Rust)用 `vo=gpu-next`,那是 **libplacebo**;新栈是
// `vo=libmpv` + OpenGL render API,走的是 mpv 旧的 `gl_video`,而且 Avalonia
// 在 Windows 上的 GL 后端是 **ANGLE**,着色器按 `#version 300 es` 编译。
// `linearize()` 是 libplacebo 提供的,这条路上没有 —— 于是那一趟 pass 编译失败,
// mpv 继续渲染,输出一片纯色。
//
// **「档位表照抄过来了」不等于「档位能用」。** 换渲染后端 = 换着色器方言。
//
// ## 这个闸做什么
//
// 挂上档位之后等一会儿(要等真的渲染一帧才会去编译),看有没有编译错误;
// 有就**自己退回关闭**,并把原文交给 UI。宁可告诉用户「这档在你机器上用不了」,
// 也不能给他一屏纯蓝还说「已启用」。

import (
	"strings"
	"sync"
	"time"
)

var (
	shaderErrMu sync.Mutex
	shaderErr   string // 最近一条着色器编译错误;取走即清
)

// isShaderCompileError 认一条 mpv 日志是不是着色器编译/链接失败。
//
// ★ 只认这几种:mpv 的 error 级日志里还有网络、解码、字幕的错,
// 把它们也当成「着色器坏了」会让好好的档位被无故关掉。
func isShaderCompileError(text string) bool {
	t := strings.ToLower(text)
	switch {
	case strings.Contains(t, "shader compile log"),
		strings.Contains(t, "fragment shader source"),
		strings.Contains(t, "vertex shader source"),
		strings.Contains(t, "no matching overloaded function"),
		strings.Contains(t, "shader link log"):
		return true
	}
	return false
}

// noteMpvLog 由事件线程调用。一次失败会刷出几十行(整份着色器源码都会打出来),
// 全存下来只会让用户看到一堵墙,所以**只留一条**。
//
// ★ 但留哪一条有讲究:mpv 先打表头(`fragment shader source:`),
// 真正有用的 `ERROR: 0:58: 'linearize' : no matching overloaded function found`
// 在几十行之后。只留第一条的话,交给用户的是一句什么都没说的话
// —— 2026-09-02 第一版就是这样,截图上写着「mpv 的原话:fragment shader source:」。
// 所以:先到先得,但**遇到第一条真正的 ERROR 行时升级一次**。
func noteMpvLog(text string) {
	if !isShaderCompileError(text) {
		return
	}
	t := strings.TrimSpace(text)
	shaderErrMu.Lock()
	defer shaderErrMu.Unlock()
	switch {
	case shaderErr == "":
		shaderErr = t
	case !isDiagnosticLine(shaderErr) && isDiagnosticLine(t):
		shaderErr = t
	}
}

// isDiagnosticLine 认「这一行真的说了哪里错了」,而不是表头。
func isDiagnosticLine(s string) bool {
	u := strings.ToUpper(s)
	return strings.Contains(u, "ERROR:") || strings.Contains(u, "WARNING:")
}

// clearShaderErr 挂档位之前清一次,免得读到上一次的。
func clearShaderErr() {
	shaderErrMu.Lock()
	shaderErr = ""
	shaderErrMu.Unlock()
}

// takeShaderErr 取走并清空。
func takeShaderErr() string {
	shaderErrMu.Lock()
	defer shaderErrMu.Unlock()
	e := shaderErr
	shaderErr = ""
	return e
}

// shaderWaitWindow 等编译错误冒出来的窗口。
//
// ★ 着色器是**渲染第一帧时**才编译的,不是设选项那一刻。24 fps 下 600ms ≈ 14 帧,
// 足够。是 var 不是 const:测试要把它压到毫秒级。
var shaderWaitWindow = 600 * time.Millisecond

// waitShaderCompileError 挂上档位之后等一小会儿,返回编译错误(没有就是空串)。
//
// 分片轮询而不是睡满:绝大多数情况下没有错误,不该让 UI 白等 600ms。
func waitShaderCompileError() string {
	deadline := time.Now().Add(shaderWaitWindow)
	for time.Now().Before(deadline) {
		if e := takeShaderErr(); e != "" {
			return e
		}
		time.Sleep(20 * time.Millisecond)
	}
	return takeShaderErr()
}

// firstLine 只取第一行:一次编译失败会刷出几十行着色器源码,
// 整坨塞进 UI 只会变成一堵墙。
func firstLine(s string) string {
	if i := strings.IndexByte(s, '\n'); i >= 0 {
		s = s[:i]
	}
	if len(s) > 200 {
		s = s[:200] + "…"
	}
	return strings.TrimSpace(s)
}

// ---------------------------------------------------------------- 坏文件记忆
//
// ## 为什么需要
//
// **mpv 每个着色器程序在一个进程里只报一次编译错误。** 2026-09-02 实测:
// 全表扫描里 `ak_sharp` 报了 BAD,而后面同样挂 `AMD_CAS_luma_RT.glsl` 的
// `fsr_sharp_l/m/h` 全报 ok —— 单独起一个进程跑 `fsr_sharp_m`,照样炸(10 行错误)。
//
// 也就是说:**光靠"等错误冒出来"这一招,同一个坏文件只挡得住第一档。**
// 用户切到第二档就会拿到一屏纯色,而我们还告诉他"已启用"。
//
// ## 归罪必须精确
//
// 一档失败时**不能把它挂的文件全打成坏的** —— `ak_sharp` 是
// 去噪 + 锐化两个 pass,坏的只是后者。把去噪也拉黑,`ak_denoise_h` 就被冤枉了,
// 而那是好档。**误判比漏报更糟**:漏报只是少挡一次,误判是无故关掉用户能用的功能。
//
// 所以规则是:**只有能唯一定位时才归罪** —— 失败档的文件里,除掉已经被
// 证明能编译的(在别的成功档里出现过),剩下**恰好一个**时才把它拉黑。
// 定位不了就只记住"这一档坏",不牵连别人。

var (
	badMu     sync.Mutex
	badFiles  = map[string]string{} // 坏文件 → 错误原文
	goodFiles = map[string]bool{}   // 已证明能编译的文件
	badLevels = map[string]string{} // 坏档位 → 错误原文(定位不到文件时的兜底)
)

// markShaderOK 一档挂上去没出错,它的文件就都算证明过了。
func markShaderOK(level string, files []string) {
	badMu.Lock()
	defer badMu.Unlock()
	for _, f := range files {
		goodFiles[f] = true
	}
	delete(badLevels, level)
}

// markShaderBad 一档编译失败。能唯一定位到某个文件就拉黑那个文件,否则只记这一档。
func markShaderBad(level string, files []string, reason string) {
	badMu.Lock()
	defer badMu.Unlock()
	badLevels[level] = reason
	var suspects []string
	for _, f := range files {
		if !goodFiles[f] && badFiles[f] == "" {
			suspects = append(suspects, f)
		}
	}
	if len(suspects) == 1 {
		badFiles[suspects[0]] = reason
	}
}

// knownBadReason 这一档是不是已经知道会坏。空串 = 不知道,该照常试。
func knownBadReason(level string, files []string) string {
	badMu.Lock()
	defer badMu.Unlock()
	if r := badLevels[level]; r != "" {
		return r
	}
	for _, f := range files {
		if r := badFiles[f]; r != "" {
			return r
		}
	}
	return ""
}

// resetShaderMemory 只给测试用。
func resetShaderMemory() {
	badMu.Lock()
	defer badMu.Unlock()
	badFiles = map[string]string{}
	goodFiles = map[string]bool{}
	badLevels = map[string]string{}
}

// revertedResult 「这档用不了,已退回关闭」的统一返回体。
//
// ★ 三个字段缺一不可:`count=0` 和 `will_run=false` 让老调用方也不会误判成成功,
// `reverted` 让 UI 知道要把下拉框拨回「关闭」—— 显示某档而实际是关的,
// 是同一类谎换个地方说。
func revertedResult(level, reason string) map[string]any {
	return map[string]any{
		"level":    level,
		"count":    0,
		"will_run": false,
		"reverted": true,
		"note": "这档在你这台机器的渲染后端上编译不过,已自动退回「关闭」" +
			"(画面不会被弄坏)。mpv 的原话:" + firstLine(reason),
	}
}

// ---------------------------------------------------------------- 最后一条 mpv 错误

// ☠☠ 「起播失败」在界面上只有一句「这一片没能播起来」,而 mpv **明明报了原因**。
// 上一版把原因只写进日志,于是每一次这类报告都要先让用户去导诊断包 ——
// 「有声音没画面」这一类实测靠这个白烧过好几轮。
//
// 只留**最后一条**:mpv 的 error 级一次失败可能刷十几行,全存下来是一堵墙,
// 而最后一条通常就是结论(前面那些是过程)。
var (
	lastErrMu  sync.Mutex
	lastMpvErr string
)

func noteLastError(text string) {
	t := strings.TrimSpace(text)
	if t == "" {
		return
	}
	lastErrMu.Lock()
	lastMpvErr = t
	lastErrMu.Unlock()
}

// LastMpvError 最后一条 mpv error 级日志。空 = 这次没报过错。
func LastMpvError() string {
	lastErrMu.Lock()
	defer lastErrMu.Unlock()
	return lastMpvErr
}

// ClearMpvError 起播前清一次。不清的话上一部片的错会被当成这一部的原因。
func ClearMpvError() {
	lastErrMu.Lock()
	lastMpvErr = ""
	lastErrMu.Unlock()
}
