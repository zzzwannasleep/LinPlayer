//go:build windows

package system

import (
	"os"
	"path/filepath"
	"strings"
	"syscall"
	"testing"
)

/*
8.3 短名和长名是同一个文件。

CI 的临时目录是 `C:\Users\RUNNER~1\...`,外壳读回 .lnk 时展开成 `runneradmin` ——
本机用户目录没有短名,所以这条只能**自己造一个短名**才能在本机复现。
*/
func Test短文件名和长文件名是同一个文件(t *testing.T) {
	dir, err := os.MkdirTemp("", "lnk")
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { os.RemoveAll(dir) })
	long := filepath.Join(dir, "a directory name longer than eight", "LinPlayer.exe")
	if err := os.MkdirAll(filepath.Dir(long), 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(long, []byte("假的"), 0o644); err != nil {
		t.Fatal(err)
	}
	u, _ := syscall.UTF16PtrFromString(long)
	buf := make([]uint16, 32768)
	n, err := syscall.GetShortPathName(u, &buf[0], uint32(len(buf)))
	if err != nil || n == 0 {
		t.Skipf("拿不到短名:%v", err)
	}
	short := syscall.UTF16ToString(buf[:n])
	if strings.EqualFold(short, long) {
		t.Skip("这个卷关掉了 8.3 短名,造不出这个场景")
	}

	if !samePath(short, long) {
		t.Fatalf("短名 %q 和长名 %q 是同一个文件,却判成了不同", short, long)
	}
	if samePath(short, filepath.Join(dir, "别的.exe")) {
		t.Fatal("两个不同的文件被判成同一个 —— 判据松过头了")
	}

	if err := shellLinkReady(); err != nil {
		t.Skipf("这台机器上造不出 ShellLink:%v", err)
	}
	lnk := filepath.Join(dir, "LinPlayer.lnk")
	if err := writeLnk(lnk, short); err != nil {
		t.Fatalf("写不出快捷方式: %v", err)
	}
	if got := lnkTarget(lnk); !samePath(got, short) {
		t.Fatalf("按短名写进去、读回来 %q,认不出是同一个 %q", got, short)
	}
}
