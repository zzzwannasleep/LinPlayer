//go:build windows

package system

import (
	"os/exec"
	"syscall"
)

// hideConsole 不让子进程弹控制台窗口。
//
// ☠ GUI 进程起 powershell.exe **会闪一个黑框**。设置页一进去闪一下、开机再闪一下
// —— 用户看到的是「这软件有毛病」。而且它是个真窗口:自检截图当场拍到了它
// (2026-09-12,拍出来一张 237×39 的图)。
func hideConsole(c *exec.Cmd) {
	c.SysProcAttr = &syscall.SysProcAttr{HideWindow: true}
}
