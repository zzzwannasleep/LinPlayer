package system

import (
	"os"
	"path/filepath"
	"runtime"
	"strings"
	"testing"
)

/*
「自动更新完之后,用户自己创建的快捷方式不能使用了」(用户 2026-09-12)。

☠ 这条判据两边都要守住:
  - 松了 → 把**别人的**快捷方式改成指向 LinPlayer,那是在用户桌面上乱改文件;
  - 紧了 → 用户桌面上那个坏链接照样是坏的,报的这个症状一点没变。
*/
func TestShouldRepair(t *testing.T) {
	const exe = "LinPlayer.exe"
	cases := []struct {
		why    string
		target string
		exists bool
		want   bool
	}{
		{"指着我们的 exe 而且已经不在了 —— 就是它", `D:\旧位置\LinPlayer.exe`, false, true},
		{"大小写不同也算我们的(Windows 文件名不区分大小写)", `D:\旧\linplayer.EXE`, false, true},
		{"还指得到就别动:用户可能故意指向另一份安装", `D:\在的\LinPlayer.exe`, true, false},
		{"指着别的程序,坏了也不归我们修", `C:\别人\Foobar.exe`, false, false},
		{"读不出目标(坏文件 / 没权限)", "", false, false},
		{"名字里带 LinPlayer 但不是那个 exe", `D:\x\LinPlayer.Updater.exe`, false, false},
	}
	for _, c := range cases {
		if got := shouldRepair(c.target, exe, c.exists); got != c.want {
			t.Errorf("%s:shouldRepair(%q, exists=%v) = %v,期望 %v",
				c.why, c.target, c.exists, got, c.want)
		}
	}
}

// 判据用的是**文件名**不是整条路径 —— 整条路径比的话,挪过窝的那些一条都修不到
// (它们的旧路径按定义就和现在的不一样)。
func TestShouldRepair_按文件名不按路径(t *testing.T) {
	old := filepath.Join(`D:\一年前解压的地方`, "LinPlayer.exe")
	if !shouldRepair(old, "LinPlayer.exe", false) {
		t.Fatal("旧路径下的同名 exe 没被认出来 —— 挪过窝的快捷方式一个都修不到")
	}
}

/*
真写一个 .lnk、真读回来、再把它指坏了修一遍。

☠ 上面那条钉的是判据,而「.lnk 到底写出来没有」只有真调一次 COM 才知道:
虚表下标错一位、GUID 抄错一个字节 —— 编译期全是绿的。
*/
func Test快捷方式真写真读真修(t *testing.T) {
	if runtime.GOOS != "windows" {
		t.Skip(".lnk 是 Windows 的东西")
	}
	/* ★ COM 起不来就跳过,**而且把原因打出来**。
	   这不是给失败找台阶:起不来的机器上「建快捷方式」本来就没有这回事,
	   而调用写错时 writeLnk 照样会红(它走的是同一条 openLink)。
	   跳过和绿是两件事 —— 日志里看得见跳过的理由。 */
	if err := shellLinkReady(); err != nil {
		t.Skipf("这台机器上造不出 ShellLink:%v —— .lnk 只有真桌面上验得了", err)
	}
	/* 三组路径分开跑,**不是为了多测一遍**:
	   纯 ASCII 钉「链路本身通不通」;中文钉 en-US 机器(CI)上的代码页;
	   **韩文钉简体中文机器上的代码页** —— CP936 编不出它,
	   所以只有这一组能在本机复现 WScript.Shell 那个坑(实测抛「值不在预期的范围内」)。
	   合成一组的话,红了分不清是链路坏了还是编码坏了。 */
	for _, c := range []struct{ why, sub, moved string }{
		{"纯 ASCII 路径", "plain dir", "moved dir"},
		{"中文 + 空格路径", "我的 程序", "挪过去 的地方"},
		{"系统代码页之外的字", "한국 폴더", "옮긴 폴더"},
	} {
		t.Run(c.why, func(t *testing.T) { roundTripLnk(t, c.sub, c.moved) })
	}
}

func roundTripLnk(t *testing.T, sub, movedDir string) {
	t.Helper()
	/* ☠ 不用 t.TempDir():它把**测试名**拼进目录名,而测试名是中文 ——
	   「纯 ASCII」那组其实一点都不纯,CI 上它和中文那组一起红,什么都区分不了。 */
	dir, err := os.MkdirTemp("", "lnk")
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { os.RemoveAll(dir) })
	exeDir := filepath.Join(dir, sub)
	if err := os.MkdirAll(exeDir, 0o755); err != nil {
		t.Fatal(err)
	}
	exe := filepath.Join(exeDir, "LinPlayer.exe")
	if err := os.WriteFile(exe, []byte("假的"), 0o644); err != nil {
		t.Fatal(err)
	}
	lnk := filepath.Join(dir, "LinPlayer.lnk")

	if err := writeLnk(lnk, exe); err != nil {
		t.Fatalf("写不出快捷方式: %v", err)
	}
	if _, err := os.Stat(lnk); err != nil {
		t.Fatalf(".lnk 没落盘: %v", err)
	}
	if got := lnkTarget(lnk); !strings.EqualFold(got, exe) {
		t.Fatalf("读回来的目标不对:%q,期望 %q", got, exe)
	}

	// 把程序挪窝:旧目标不在了,这正是用户报的「找不到项目」
	moved := filepath.Join(dir, movedDir)
	if err := os.MkdirAll(moved, 0o755); err != nil {
		t.Fatal(err)
	}
	newExe := filepath.Join(moved, "LinPlayer.exe")
	if err := os.Rename(exe, newExe); err != nil {
		t.Fatal(err)
	}
	if _, err := os.Stat(lnkTarget(lnk)); err == nil {
		t.Fatal("挪完之后旧目标居然还在 —— 这条测试的前提没成立")
	}
	if err := writeLnk(lnk, newExe); err != nil {
		t.Fatalf("修不回来: %v", err)
	}
	if got := lnkTarget(lnk); !strings.EqualFold(got, newExe) {
		t.Fatalf("修完还是指着 %q,期望 %q", got, newExe)
	}
}
