//go:build windows

package system

/*
.lnk 的读写直接走 IShellLinkW(COM),不经过 PowerShell / WScript.Shell。

☠ WScript.Shell **只认系统 ANSI 代码页**。路径里有代码页编不出的字,
`TargetPath = ...` 当场抛「值不在预期的范围内」:简体中文机器(CP936)上
韩文目录就能复现,en-US 的 CI 上连中文目录都不行 —— CI 为此红了六个提交,
中间一度以为是环境变量传坏了、改成 Base64 递值,毫无作用。
IShellLinkW 是 W 版接口,全程 UTF-16,没有代码页这一层。

顺带省掉的:起 powershell.exe 的黑框、每个 .lnk 一个进程的几百毫秒、
没有控制台时 [Console]::OutputEncoding 会抛的那条坑。
*/

import (
	"fmt"
	"os"
	"path/filepath"
	"runtime"
	"syscall"
	"unsafe"
)

var (
	ole32                    = syscall.NewLazyDLL("ole32.dll")
	shell32                  = syscall.NewLazyDLL("shell32.dll")
	procCoInitializeEx       = ole32.NewProc("CoInitializeEx")
	procCoUninitialize       = ole32.NewProc("CoUninitialize")
	procCoCreateInstance     = ole32.NewProc("CoCreateInstance")
	procCoTaskMemFree        = ole32.NewProc("CoTaskMemFree")
	procSHGetKnownFolderPath = shell32.NewProc("SHGetKnownFolderPath")
)

type guid struct {
	d1     uint32
	d2, d3 uint16
	d4     [8]byte
}

var (
	clsidShellLink = guid{0x00021401, 0, 0, [8]byte{0xC0, 0, 0, 0, 0, 0, 0, 0x46}}
	iidShellLinkW  = guid{0x000214F9, 0, 0, [8]byte{0xC0, 0, 0, 0, 0, 0, 0, 0x46}}
	iidPersistFile = guid{0x0000010B, 0, 0, [8]byte{0xC0, 0, 0, 0, 0, 0, 0, 0x46}}
	folderDesktop  = guid{0xB4BFCC3A, 0xDB2C, 0x424C, [8]byte{0xB0, 0x29, 0x7F, 0xE9, 0x9A, 0x87, 0xC6, 0x41}}
	folderPrograms = guid{0xA77F5D77, 0x2E2B, 0x44C3, [8]byte{0xA6, 0xA2, 0xAB, 0xA6, 0x01, 0x05, 0x4A, 0x51}}
)

// comObj 一个 COM 接口指针。第一个字段就是虚表,方法按下标取。
type comObj struct{ vtbl *[32]uintptr }

// 虚表下标。IUnknown 占 0~2。
const (
	vRelease         = 2
	vGetPath         = 3 // IShellLinkW
	vSetDescription  = 7
	vSetWorkingDir   = 9
	vSetIconLocation = 17
	vSetPath         = 20
	vLoad            = 5 // IPersistFile
	vSave            = 6
)

func failed(hr uintptr) bool { return int32(hr) < 0 }

func hrErr(what string, hr uintptr) error {
	return fmt.Errorf("%s 失败:0x%08X", what, uint32(hr))
}

func comRelease(o *comObj) {
	syscall.SyscallN(o.vtbl[vRelease], uintptr(unsafe.Pointer(o)))
}

// withCOM COM 调用必须在**同一条**已初始化的系统线程上,Go 的调度会把 goroutine 挪线程。
func withCOM(f func() error) error {
	runtime.LockOSThread()
	defer runtime.UnlockOSThread()
	hr, _, _ := procCoInitializeEx.Call(0, 2) // COINIT_APARTMENTTHREADED
	switch uint32(hr) {
	case 0, 1: // S_OK / S_FALSE(这条线程早初始化过)
		defer procCoUninitialize.Call()
	case 0x80010106: // RPC_E_CHANGED_MODE:别人按另一种模式初始化过,照用即可,但轮不到我们反初始化
	default:
		return hrErr("CoInitializeEx", hr)
	}
	return f()
}

// openLink 造一个 ShellLink,连同它的 IPersistFile 一起给出。两个都要 release。
func openLink() (sl, pf *comObj, err error) {
	hr, _, _ := procCoCreateInstance.Call(uintptr(unsafe.Pointer(&clsidShellLink)), 0,
		1, // CLSCTX_INPROC_SERVER
		uintptr(unsafe.Pointer(&iidShellLinkW)), uintptr(unsafe.Pointer(&sl)))
	if failed(hr) {
		return nil, nil, hrErr("CoCreateInstance(ShellLink)", hr)
	}
	hr, _, _ = syscall.SyscallN(sl.vtbl[0], uintptr(unsafe.Pointer(sl)),
		uintptr(unsafe.Pointer(&iidPersistFile)), uintptr(unsafe.Pointer(&pf)))
	if failed(hr) {
		comRelease(sl)
		return nil, nil, hrErr("QueryInterface(IPersistFile)", hr)
	}
	return sl, pf, nil
}

// shellLinkReady 这台机器上造不造得出 ShellLink。造不出就没有 .lnk 这回事。
func shellLinkReady() error {
	return withCOM(func() error {
		sl, pf, err := openLink()
		if err != nil {
			return err
		}
		comRelease(pf)
		comRelease(sl)
		return nil
	})
}

// writeLnk 建 / 改一个快捷方式,指向 exe。
func writeLnk(lnk, exe string) error {
	return withCOM(func() error {
		sl, pf, err := openLink()
		if err != nil {
			return err
		}
		defer comRelease(sl)
		defer comRelease(pf)
		for _, s := range []struct {
			slot int
			val  string
			what string
		}{
			{vSetPath, exe, "SetPath"},
			{vSetWorkingDir, filepath.Dir(exe), "SetWorkingDirectory"},
			{vSetDescription, "LinPlayer", "SetDescription"},
		} {
			p, err := syscall.UTF16PtrFromString(s.val)
			if err != nil {
				return err
			}
			if hr, _, _ := syscall.SyscallN(sl.vtbl[s.slot], uintptr(unsafe.Pointer(sl)),
				uintptr(unsafe.Pointer(p))); failed(hr) {
				return hrErr(s.what, hr)
			}
		}
		icon, err := syscall.UTF16PtrFromString(exe)
		if err != nil {
			return err
		}
		if hr, _, _ := syscall.SyscallN(sl.vtbl[vSetIconLocation], uintptr(unsafe.Pointer(sl)),
			uintptr(unsafe.Pointer(icon)), 0); failed(hr) {
			return hrErr("SetIconLocation", hr)
		}
		dst, err := syscall.UTF16PtrFromString(lnk)
		if err != nil {
			return err
		}
		if hr, _, _ := syscall.SyscallN(pf.vtbl[vSave], uintptr(unsafe.Pointer(pf)),
			uintptr(unsafe.Pointer(dst)), 1); failed(hr) {
			return hrErr("IPersistFile.Save", hr)
		}
		return nil
	})
}

// lnkTarget 读一个 .lnk 指向哪。读不出来返回空串(坏文件、不是 .lnk、没权限)。
func lnkTarget(lnk string) string {
	var out string
	_ = withCOM(func() error {
		sl, pf, err := openLink()
		if err != nil {
			return err
		}
		defer comRelease(sl)
		defer comRelease(pf)
		src, err := syscall.UTF16PtrFromString(lnk)
		if err != nil {
			return err
		}
		if hr, _, _ := syscall.SyscallN(pf.vtbl[vLoad], uintptr(unsafe.Pointer(pf)),
			uintptr(unsafe.Pointer(src)), 0); failed(hr) { // STGM_READ
			return hrErr("IPersistFile.Load", hr)
		}
		buf := make([]uint16, 32768)
		if hr, _, _ := syscall.SyscallN(sl.vtbl[vGetPath], uintptr(unsafe.Pointer(sl)),
			uintptr(unsafe.Pointer(&buf[0])), uintptr(len(buf)), 0, 0); failed(hr) {
			return hrErr("GetPath", hr)
		}
		out = syscall.UTF16ToString(buf)
		return nil
	})
	return out
}

// knownFolder 问系统某个特殊目录在哪。
func knownFolder(id *guid) (string, error) {
	var p *uint16
	hr, _, _ := procSHGetKnownFolderPath.Call(uintptr(unsafe.Pointer(id)), 0, 0,
		uintptr(unsafe.Pointer(&p)))
	if p != nil {
		defer procCoTaskMemFree.Call(uintptr(unsafe.Pointer(p)))
	}
	if failed(hr) {
		return "", hrErr("SHGetKnownFolderPath", hr)
	}
	n := 0
	for q := unsafe.Pointer(p); *(*uint16)(q) != 0; q = unsafe.Add(q, 2) {
		n++
	}
	return syscall.UTF16ToString(unsafe.Slice(p, n)), nil
}

// desktopDir 桌面目录。**必须问系统**:OneDrive 接管之后它不在 %USERPROFILE%\Desktop。
func desktopDir() string {
	if s, err := knownFolder(&folderDesktop); err == nil && s != "" {
		return s
	}
	home, _ := os.UserHomeDir()
	return filepath.Join(home, "Desktop")
}

// programsDir 开始菜单「程序」(当前用户那一份)。问不到就是空串,调用方跳过。
func programsDir() string {
	s, _ := knownFolder(&folderPrograms)
	return s
}

// longPath 把 8.3 短名展开成长名(RUNNER~1 → runneradmin)。
// 文件不在就展开不了,原样返回 —— 指坏了的快捷方式正是这种。
func longPath(p string) string {
	u, err := syscall.UTF16PtrFromString(p)
	if err != nil {
		return p
	}
	buf := make([]uint16, 32768)
	n, err := syscall.GetLongPathName(u, &buf[0], uint32(len(buf)))
	if err != nil || n == 0 || int(n) > len(buf) {
		return p
	}
	return syscall.UTF16ToString(buf[:n])
}
