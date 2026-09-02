//go:build !windows

package translate

import "os/exec"

// hideWindow 非 Windows 上无事可做。
func hideWindow(*exec.Cmd) {}
