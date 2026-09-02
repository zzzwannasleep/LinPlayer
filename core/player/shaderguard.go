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
