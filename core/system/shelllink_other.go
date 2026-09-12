//go:build !windows

package system

import (
	"errors"
	"os"
	"path/filepath"
)

// .lnk 是 Windows 的东西。这里只为让安卓 / Linux 那份核心编得过。
var errNoLnk = errors.New("只有 Windows 有桌面快捷方式")

func shellLinkReady() error          { return errNoLnk }
func writeLnk(lnk, exe string) error { return errNoLnk }
func lnkTarget(lnk string) string    { return "" }
func programsDir() string            { return "" }

func desktopDir() string {
	home, _ := os.UserHomeDir()
	return filepath.Join(home, "Desktop")
}
