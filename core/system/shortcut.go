package system

/*
桌面快捷方式:创建、体检、修好。

☠ 用户 2026-09-12:「自动更新完之后,用户自己创建的快捷方式不能使用了」。
覆盖脚本是**原地换文件**(update_install_test.go 真跑过一遍钉住了),路径没变,
所以那条链路解释不了「找不到项目」。剩下的解释只有一个:**exe 整个换了地方** ——
绿色包本来就是「解压到哪算哪」,用户挪一次文件夹、或者把新包解到另一个目录,
桌面上那个 .lnk 指的就是一个已经不存在的文件了。

所以这里做两件事:
① 给一条**自己的**命令建 / 修桌面快捷方式,不让用户去手搓;
② 启动时发现 exe 换了位置,就把桌面和开始菜单里**已经指坏了的**我们这个 exe 的
   .lnk 修回来。只动「本来就已经坏掉、而且本来就指着 LinPlayer.exe」的那些 ——
   修一个坏链接不会丢任何东西,而放着不管就是用户报的那个症状。
*/

import (
	"context"
	"encoding/base64"
	"errors"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"runtime"
	"strings"

	"linplayer/core/bus"
	"linplayer/core/config"
)

// ShortcutStatus 桌面快捷方式现在什么样。
type ShortcutStatus struct {
	// Supported 只有 Windows 有 .lnk 这回事。其它平台一律 false,界面据此整块不画。
	Supported bool   `json:"supported"`
	Path      string `json:"path"`
	Exists    bool   `json:"exists"`
	// Target 快捷方式现在指向哪。指坏了也照实回,用户要看的就是这个。
	Target string `json:"target"`
	// Ok 指的那个文件真的在,而且就是当前这个 exe。
	Ok  bool   `json:"ok"`
	Exe string `json:"exe"`
}

// psRun 跑一小段 PowerShell,值全走**环境变量**递进去。
//
// ☠ 不把路径拼进脚本文本里:中文、空格、引号、`$` 任意一个都能把拼出来的那行
// 弄成另一个意思,而 PowerShell 只会照着错的那行执行,一声不吭。
//
// ☠ **输出编码必须自己钉成 UTF-8**。默认走控制台代码页(简体中文机器上是 GBK),
// 于是「读回来的快捷方式指向哪」在中文路径上是一串乱码 —— 而它照样是个字符串,
// 后面 os.Stat 必然失败,程序会以为每个快捷方式都坏了。
// 集成测试当场抓到过:期望「我的 程序」,实得「ÎҵÄ ³ÌÐò」。
func psRun(script string, env map[string]string) (string, error) {
	c := exec.Command("powershell", "-NoProfile", "-NonInteractive",
		"-ExecutionPolicy", "Bypass", "-Command", script)
	hideConsole(c)
	c.Env = os.Environ()
	for k, v := range env {
		c.Env = append(c.Env, k+"="+v)
	}
	out, err := c.Output()
	/* 把 PowerShell 自己那句话带出来。 只回「exit status 1」的话,
	   出了问题谁也不知道是脚本写错、还是这台机器上根本起不了那个 COM ——
	   CI 上红了一整天就是卡在这一句上。 */
	var ee *exec.ExitError
	if errors.As(err, &ee) && len(ee.Stderr) > 0 {
		err = fmt.Errorf("%w:%s", err, strings.TrimSpace(string(ee.Stderr)))
	}
	return strings.TrimSpace(string(out)), err
}

/*
psValue 跑一段 PowerShell 并把它的值取回来。

☠ 值走 **Base64**,不走裸文本。PowerShell 写到重定向管道里用的是控制台代码页
(简体中文机器上是 GBK),中文路径取回来是一串乱码 —— 而它照样是个字符串,
后面 os.Stat 必然失败,程序会以为每个快捷方式都坏了。
上一版靠 `[Console]::OutputEncoding = UTF8` 钉编码,但**没有控制台的时候那一句会抛**
(GUI 进程 + HideWindow 起的子进程就没有控制台),整条命令当场 exit 1。
Base64 全是 ASCII,哪个代码页都改不动它,而且不需要控制台。
*/
func psValue(script string, env map[string]string) (string, error) {
	/* 脚本裹进 & { } 里:前面几行是解 Base64 的赋值,不出值,取的是最后那个表达式。
	   直接写 `$v = <脚本>` 的话,多行脚本只有第一行会被当成赋值的右边,
	   剩下几行照跑但没人接 —— 回来是空串,而且不报错。 */
	out, err := psRun("$v = & {\n"+script+"\n}\n"+
		"[Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes([string]$v))", env)
	if err != nil {
		return "", err
	}
	b, err := base64.StdEncoding.DecodeString(out)
	if err != nil {
		return "", fmt.Errorf("PowerShell 回的不是 Base64(%q):%w", out, err)
	}
	return strings.TrimSpace(string(b)), nil
}

/*
psArg 把一个值递进 PowerShell:环境变量里放 Base64,脚本头上解回来。

☠ 直接放原文**在别的机器上会烂**。CI(en-US)实测:路径里那十个汉字到了
PowerShell 手上是十个 `?` —— 简体中文机器的 ANSI 代码页(CP936)编得出它们,
所以本地怎么跑都是绿的。Base64 全是 ASCII,中间隔着几层代码页都改不动它。
*/
func psArg(name, value string) (string, string, string) {
	env := "LP_" + name + "_B64"
	line := "$" + name + " = [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($env:" +
		env + "))\n"
	return line, env, base64.StdEncoding.EncodeToString([]byte(value))
}

// comReady 这台机器上起不起得来 WScript.Shell。起不来就没有 .lnk 这回事
// (CI 的容器里就没有)—— 调用方据此跳过,而不是把它当成我们的脚本写错了。
func comReady() error {
	_, err := psRun("$null = New-Object -ComObject WScript.Shell", nil)
	return err
}

// desktopDir 桌面目录。**必须问系统**:OneDrive 接管之后它不在 %USERPROFILE%\Desktop。
func desktopDir() string {
	s, err := psValue("[Environment]::GetFolderPath('Desktop')", nil)
	if err != nil || s == "" {
		home, _ := os.UserHomeDir()
		return filepath.Join(home, "Desktop")
	}
	return s
}

// lnkTarget 读一个 .lnk 指向哪。读不出来返回空串(坏文件、不是 .lnk、没权限)。
func lnkTarget(lnk string) string {
	decl, env, val := psArg("lnk", lnk)
	s, err := psValue(decl+"(New-Object -ComObject WScript.Shell).CreateShortcut($lnk).TargetPath",
		map[string]string{env: val})
	if err != nil {
		return ""
	}
	return s
}

// writeLnk 建 / 改一个快捷方式,指向 exe。
func writeLnk(lnk, exe string) error {
	dl, el, lv := psArg("lnk", lnk)
	de, ee, ev := psArg("exe", exe)
	_, err := psRun(dl+de+`$s = (New-Object -ComObject WScript.Shell).CreateShortcut($lnk)
$s.TargetPath = $exe
$s.WorkingDirectory = Split-Path -Parent $exe
$s.IconLocation = $exe + ',0'
$s.Description = 'LinPlayer'
$s.Save()`, map[string]string{el: lv, ee: ev})
	return err
}

func shortcutStatus() ShortcutStatus {
	exe, _ := os.Executable()
	if runtime.GOOS != "windows" {
		return ShortcutStatus{Exe: exe}
	}
	p := filepath.Join(desktopDir(), "LinPlayer.lnk")
	st := ShortcutStatus{Supported: true, Path: p, Exe: exe}
	if _, err := os.Stat(p); err != nil {
		return st
	}
	st.Exists = true
	st.Target = lnkTarget(p)
	if st.Target == "" {
		return st
	}
	if _, err := os.Stat(st.Target); err != nil {
		return st
	}
	st.Ok = strings.EqualFold(st.Target, exe)
	return st
}

// lnkDirs 会去看的地方:桌面 + 开始菜单(当前用户那一份)。
//
// ★ 不扫全盘。这两处是用户真的会放快捷方式的地方,再多扫就是在别人硬盘上乱翻。
func lnkDirs() []string {
	dirs := []string{desktopDir()}
	if s, err := psRun("[Environment]::GetFolderPath('Programs')", nil); err == nil && s != "" {
		dirs = append(dirs, s)
	}
	return dirs
}

/*
shouldRepair 这一个 .lnk 该不该改回来。<b>两条判据缺一不可</b>:

① 它指着的文件**已经不在了**;② 它指着的文件名**就是我们这个 exe 的文件名**。

少了②会去改别人的快捷方式;少了①会把用户故意指向另一份安装的链接抢过来。
拆成纯函数只为可测 —— 真跑一遍要有桌面、有 .lnk、有 PowerShell。
*/
func shouldRepair(target, exeName string, targetExists bool) bool {
	if target == "" || targetExists {
		return false
	}
	return strings.EqualFold(filepath.Base(target), exeName)
}

// repairBroken 把**已经指坏了的**、原本指着我们这个 exe 的快捷方式改回来。
//
// ☠ 判据两条缺一不可:① 目标文件不存在 ② 目标的文件名就是我们这个 exe 的文件名。
// 少了②就会去改别人的快捷方式;少了①就会把用户故意指向另一份安装的链接抢过来。
// 返回修好了几个。
func repairBroken(exe string) int {
	name := filepath.Base(exe)
	n := 0
	for _, dir := range lnkDirs() {
		entries, err := os.ReadDir(dir)
		if err != nil {
			continue
		}
		for _, e := range entries {
			if e.IsDir() || !strings.EqualFold(filepath.Ext(e.Name()), ".lnk") {
				continue
			}
			p := filepath.Join(dir, e.Name())
			t := lnkTarget(p)
			_, statErr := os.Stat(t)
			if !shouldRepair(t, name, t != "" && statErr == nil) {
				continue
			}
			if writeLnk(p, exe) == nil {
				bus.Logf("info", "快捷方式修回来了:%s(原来指着 %s)", p, t)
				n++
			}
		}
	}
	return n
}

/*
RepairShortcutsIfMoved exe 换了地方才去看快捷方式,没换就一个字都不做。

★ 这个「才」很重要:扫一遍目录 + 每个 .lnk 起一次 PowerShell,放在每次启动上
是白烧几百毫秒。而快捷方式只会因为**exe 挪窝**而失效 —— 覆盖更新是原地换文件。

由 lp_init 在后台调。
*/
func RepairShortcutsIfMoved() {
	if runtime.GOOS != "windows" {
		return
	}
	exe, err := os.Executable()
	if err != nil {
		return
	}
	// ☠ 配置还没从盘上加载过时 Current() 回的是空配置,拿它 Save() = 把账号清空
	if !config.Ready() {
		return
	}
	c := config.Current()
	if strings.EqualFold(c.LastExePath, exe) {
		return
	}
	first := c.LastExePath == ""
	c.LastExePath = exe
	if err := c.Save(); err != nil {
		bus.Logf("warn", "记不下 exe 位置,下次启动还会再扫一遍: %v", err)
	}
	// 头一次运行没有「上一次在哪」,谈不上挪窝 —— 记下来就完了,别扫
	if first {
		return
	}
	if n := repairBroken(exe); n > 0 {
		bus.Logf("info", "程序换了位置(现在在 %s),顺手修好了 %d 个快捷方式", exe, n)
	}
}

func registerShortcutCommands() {
	bus.Register("system.shortcutStatus", func(ctx context.Context, seq int64, a map[string]any) (any, error) {
		return shortcutStatus(), nil
	})

	// system.makeShortcut —— 建桌面快捷方式;已经有了就把它指回当前 exe。
	bus.Register("system.makeShortcut", func(ctx context.Context, seq int64, a map[string]any) (any, error) {
		if runtime.GOOS != "windows" {
			return nil, bus.NewErr(bus.EUnsupported, "只有 Windows 有桌面快捷方式")
		}
		exe, err := os.Executable()
		if err != nil {
			return nil, bus.NewErr(bus.EInternal, "找不到程序自己的位置: %v", err)
		}
		p := filepath.Join(desktopDir(), "LinPlayer.lnk")
		if err := writeLnk(p, exe); err != nil {
			return nil, bus.NewErr(bus.EInternal, "写不出快捷方式: %v", err)
		}
		// 顺手把别处指坏的也修了 —— 用户点这颗按钮的意思就是「让它能用」
		repairBroken(exe)
		return shortcutStatus(), nil
	})
}
