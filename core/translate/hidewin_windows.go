//go:build windows

package translate

import (
	"os/exec"
	"syscall"
)

// hideWindow 别让探测子进程闪出一个黑框。
//
// ★ 探测 ffmpeg/whisper 要真的 spawn 一次;不加这一句的话,Windows 上
// 每次打开翻译设置页都会闪几个控制台窗口 —— 看起来像中了什么东西。
func hideWindow(cmd *exec.Cmd) {
	cmd.SysProcAttr = &syscall.SysProcAttr{HideWindow: true}
}
