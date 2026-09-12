//go:build !windows

package system

import "os/exec"

// hideConsole 非 Windows 上没有控制台窗口这回事。
func hideConsole(*exec.Cmd) {}
