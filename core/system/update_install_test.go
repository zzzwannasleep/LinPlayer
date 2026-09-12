package system

// 一条龙更新里编译全绿却会真出事的那几段:压缩包里的 `../` 带不带得出安装目录、
// 会不会忘了钻进 `LinPlayer/` 那一层、覆盖脚本会不会顺手把 userdata/ 一起清掉,
// 以及下载那条**异步**链路(命令立刻返回,活儿在后台)有没有正确收尾。
// 只有「起覆盖脚本」那一步不测:它要真的杀掉本进程。

import (
	"archive/zip"
	"bytes"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"os"
	"os/exec"
	"path/filepath"
	"runtime"
	"strings"
	"testing"
	"time"

	"linplayer/core/paths"
)

// makeZip 造一个 zip,names 是「压缩包内路径」。
func makeZip(t *testing.T, names ...string) string {
	t.Helper()
	p := filepath.Join(t.TempDir(), "u.zip")
	f, err := os.Create(p)
	if err != nil {
		t.Fatal(err)
	}
	w := zip.NewWriter(f)
	for _, n := range names {
		e, err := w.Create(n)
		if err != nil {
			t.Fatal(err)
		}
		if _, err := e.Write([]byte("x")); err != nil {
			t.Fatal(err)
		}
	}
	if err := w.Close(); err != nil {
		t.Fatal(err)
	}
	_ = f.Close()
	return p
}

func TestStageZip挡住越界路径(t *testing.T) {
	z := makeZip(t, "LinPlayer/LinPlayer.exe", "../坏东西.txt")
	dest := filepath.Join(t.TempDir(), "staged")
	_, err := stageZip(z, dest, "LinPlayer.exe")
	if err == nil {
		t.Fatal("压缩包里的 ../ 被放过了 —— 这条链路的下游是以本机权限覆盖文件")
	}
	if !strings.Contains(err.Error(), "越界") {
		t.Fatalf("报错没说清是越界: %v", err)
	}
}

func TestStageZip钻进单层顶层目录(t *testing.T) {
	// pack-win.sh 用 Compress-Archive 打整个文件夹,所以真东西在 LinPlayer/ 下面
	z := makeZip(t, "LinPlayer/LinPlayer.exe", "LinPlayer/lpcore.dll", "LinPlayer/Theme/a.axaml")
	dest := filepath.Join(t.TempDir(), "staged")
	root, err := stageZip(z, dest, "LinPlayer.exe")
	if err != nil {
		t.Fatal(err)
	}
	if root == dest {
		t.Fatal("没钻进 LinPlayer/ 那一层 —— 覆盖过去会变成 安装目录/LinPlayer/LinPlayer.exe,旧 exe 原地不动")
	}
	if _, err := os.Stat(filepath.Join(root, "lpcore.dll")); err != nil {
		t.Fatalf("负载根不对,里面没有 lpcore.dll: %v", err)
	}
}

func TestStageZip缺可执行文件就不覆盖(t *testing.T) {
	// 下到一半、或者下成了别的平台的包:必须在动安装目录之前挡掉
	z := makeZip(t, "LinPlayer/README.txt")
	dest := filepath.Join(t.TempDir(), "staged")
	if _, err := stageZip(z, dest, "LinPlayer.exe"); err == nil {
		t.Fatal("包里没有主程序也放行了 —— 覆盖完用户手上是个起不来的目录")
	}
}

// 覆盖脚本跑的时候程序已经退出了,炸了没人看得见。这条钉死两件事:
// **绝不清空安装目录**(userdata/ 在里面),以及确实等到本进程退出才动手。
func TestApply脚本绝不清空安装目录(t *testing.T) {
	p := applyPlan{
		Pid: 4242, Staged: `C:\tmp\staged\LinPlayer`,
		Dir: `C:\程序\LinPlayer`, Exe: `C:\程序\LinPlayer\LinPlayer.exe`,
		Log: `C:\程序\LinPlayer\userdata\logs\update.log`,
	}
	for _, goos := range []string{"windows", "linux"} {
		_, body := applyScript(goos, p)
		if !strings.Contains(body, "4242") {
			t.Fatalf("[%s] 脚本没等本进程退出 —— exe 正被自己锁着,这时候覆盖必然失败", goos)
		}
		if !strings.Contains(body, p.Exe) {
			t.Fatalf("[%s] 覆盖完不重启,用户看到的是程序直接消失", goos)
		}
		if strings.Contains(body, "/MIR") || strings.Contains(body, "--delete") {
			t.Fatalf("[%s] 用了镜像模式 —— userdata/ 会被当成「源里没有的多余文件」删掉:\n%s", goos, body)
		}
		// 唯一允许删的是暂存目录,安装目录一个字都不许出现在删除动作里
		for _, del := range []string{"Remove-Item -LiteralPath " + psq(p.Dir), "rm -rf " + shq(p.Dir)} {
			if strings.Contains(body, del) {
				t.Fatalf("[%s] 脚本在删安装目录:\n%s", goos, body)
			}
		}
	}
}

// ☠ 没有 BOM 的 .ps1 会被按本地代码页读。路径里有一个中文字符,后面就全错位,
// 而 PowerShell 不报错 —— pack-portable.ps1 整个打不出包、CI 却全绿,就是这么来的。
func TestWriteScript的ps1必须带BOM(t *testing.T) {
	dir := t.TempDir()
	p, err := writeScript(dir, "apply-update.ps1", "Write-Output '中文路径'\r\n")
	if err != nil {
		t.Fatal(err)
	}
	b, err := os.ReadFile(p)
	if err != nil {
		t.Fatal(err)
	}
	if len(b) < 3 || b[0] != 0xEF || b[1] != 0xBB || b[2] != 0xBF {
		t.Fatalf("ps1 没写 BOM,头三个字节是 % X", b[:min(3, len(b))])
	}
	// sh 不吃 BOM:开头多三个字节,`#!/bin/sh` 就不再是 shebang
	p2, err := writeScript(dir, "apply-update.sh", "#!/bin/sh\n")
	if err != nil {
		t.Fatal(err)
	}
	b2, _ := os.ReadFile(p2)
	if len(b2) > 0 && b2[0] == 0xEF {
		t.Fatal("给 sh 脚本也加了 BOM,shebang 就废了")
	}
}

func TestPickAsset安卓认的是APK(t *testing.T) {
	names := []string{"SHA256SUMS", "LinPlayer-Windows-v1.2.0.zip", "app-arm64-v8a-release.apk"}
	// 安卓原先吃的是 "linux" 这个关键词,APK 名里没有 —— 于是永远挑不出资产
	i := pickAsset(names, [][]string{{".apk", "arm64"}, {".apk"}})
	if i < 0 || names[i] != "app-arm64-v8a-release.apk" {
		t.Fatalf("安卓挑到了 %d(%v)", i, names)
	}
	// 只有别的 ABI 时退回任意 APK,总好过把用户丢去网页
	only := []string{"app-x86_64-release.apk"}
	if pickAsset(only, [][]string{{".apk", "arm64"}, {".apk"}}) != 0 {
		t.Fatal("没有本机 ABI 时没退回任意 APK")
	}
	// 一个都不认就必须是 -1,让界面引导去网页,而不是随手拿第一个
	if pickAsset([]string{"SHA256SUMS"}, [][]string{{".apk"}}) != -1 {
		t.Fatal("挑不到时没返回 -1")
	}
}

// ---------------------------------------------------------------- 整条下载链路

// fakeRelease 一台假 GitHub:发布信息 + 真的能下的资产。
// body 短于 size 时模拟「下到一半断了」。
func fakeRelease(t *testing.T, body []byte, size int64) *httptest.Server {
	t.Helper()
	var base string
	mux := http.NewServeMux()
	mux.HandleFunc("/asset", func(w http.ResponseWriter, r *http.Request) {
		_, _ = w.Write(body)
	})
	mux.HandleFunc("/", func(w http.ResponseWriter, r *http.Request) {
		rel := map[string]any{
			"tag_name": "v99.0.0", "name": "v99", "body": "新版本",
			"html_url": "https://example.invalid/rel",
			// 两个平台各放一个,跑在哪台机器上都挑得中
			"assets": []map[string]any{
				{"name": "LinPlayer-Windows-v99.0.0.zip", "browser_download_url": base + "/asset", "size": size},
				{"name": "LinPlayer-linux-v99.0.0.tar.gz", "browser_download_url": base + "/asset", "size": size},
			},
		}
		w.Header().Set("Content-Type", "application/json")
		_ = json.NewEncoder(w).Encode(rel)
	})
	srv := httptest.NewServer(mux)
	base = srv.URL
	t.Cleanup(srv.Close)
	return srv
}

// waitPhase 轮询到不再是 downloading 为止。
func waitPhase(t *testing.T) map[string]any {
	t.Helper()
	deadline := time.Now().Add(8 * time.Second)
	for time.Now().Before(deadline) {
		r := call(t, 9002, "system.updateProgress", nil)
		if !r.OK {
			t.Fatalf("问进度失败: %s", r.Msg)
		}
		if r.Data["phase"] != "downloading" {
			return r.Data
		}
		time.Sleep(50 * time.Millisecond)
	}
	t.Fatal("下载一直停在 downloading")
	return nil
}

// 整条链路只有这一段是异步的:命令立刻返回、活儿在后台 goroutine 里。
// 挂错 ctx、状态机少一个分支,编译全绿而界面永远停在「正在下载」。
func TestDownloadUpdate下完了状态要变成就绪(t *testing.T) {
	paths.SetRoot(t.TempDir())
	upd = &updState{phase: "idle"}
	payload := bytes.Repeat([]byte("LP"), 5000)
	srv := fakeRelease(t, payload, int64(len(payload)))
	old := githubAPI
	githubAPI = srv.URL
	defer func() { githubAPI = old }()

	if r := call(t, 9001, "system.downloadUpdate", nil); !r.OK {
		t.Fatalf("开下载失败: %s", r.Msg)
	}
	d := waitPhase(t)
	if d["phase"] != "ready" {
		t.Fatalf("下完了却不是 ready:%v", d)
	}
	f, _ := d["file"].(string)
	fi, err := os.Stat(f)
	if err != nil {
		t.Fatalf("说下好了,文件却不在: %v", err)
	}
	if fi.Size() != int64(len(payload)) {
		t.Fatalf("落盘 %d 字节,应该是 %d", fi.Size(), len(payload))
	}
	/* ☆ 下面两条**不能跟着实现给的路径走**:那样的话「.part 根本没改名」
	   也是绿的(实测过)—— 按目录里的事实判:最终名字必须是资产名,
	   而且一个 .part 都不许剩。剩着的话下一次会把半个包当成下好了的。 */
	if filepath.Base(f) != "LinPlayer-Windows-v99.0.0.zip" &&
		filepath.Base(f) != "LinPlayer-linux-v99.0.0.tar.gz" {
		t.Fatalf("落盘名字不是资产名,是 %q", filepath.Base(f))
	}
	ents, err := os.ReadDir(filepath.Dir(f))
	if err != nil {
		t.Fatal(err)
	}
	for _, e := range ents {
		if strings.HasSuffix(e.Name(), ".part") {
			t.Fatalf("临时文件没清掉: %s", e.Name())
		}
	}
}

// ☠ 下到一半的包**绝不能**进入安装那一步:zip 解压器多半还能解出前半截文件,
// 于是安装目录被半份新版覆盖,而这一步跑完程序已经退出了。
func TestDownloadUpdate下不全就得判失败(t *testing.T) {
	paths.SetRoot(t.TempDir())
	upd = &updState{phase: "idle"}
	srv := fakeRelease(t, []byte("只有这么点"), 999999)
	old := githubAPI
	githubAPI = srv.URL
	defer func() { githubAPI = old }()

	if r := call(t, 9003, "system.downloadUpdate", nil); !r.OK {
		t.Fatalf("开下载失败: %s", r.Msg)
	}
	d := waitPhase(t)
	if d["phase"] != "failed" {
		t.Fatalf("只下到一小半却报 %v —— 下一步就会拿半个包去覆盖安装目录", d["phase"])
	}
	// 装这一步必须挡住
	if r := call(t, 9004, "system.installUpdate", nil); r.OK {
		t.Fatal("没下好也让装了")
	}
}

// ☠ 上面那几条钉的都是**脚本的字符串**,一次都没真跑过。而用户报的两件事
// (2026-09-12:「自动更新完之后,用户自己创建的快捷方式不能使用了」、
// 「处于最新版但是依然提示更新,更新完启动再次提示更新」)如果成立,
// 病灶只可能在「脚本真跑起来之后落到了哪儿」—— 那正是字符串断言照不到的地方。
// 所以这条真造一个安装目录、真跑一遍 PowerShell、再回来数文件。
func Test覆盖脚本真跑一遍就地换文件(t *testing.T) {
	if runtime.GOOS != "windows" {
		t.Skip("覆盖脚本是 PowerShell,只在 Windows 上跑得起来")
	}
	base := t.TempDir()
	dir := filepath.Join(base, "程序", "LinPlayer") // 中文路径:BOM 那条坑的现场
	/* ★ 暂存目录**必须摆在安装目录里面** —— 真实布局就是
	   `<安装目录>/userdata/cache/update/staged/LinPlayer`(绿色包的数据根在 exe 同级)。
	   摆到外面去测的话,「源在目标里面」这个几何根本没被测到。 */
	staged := filepath.Join(dir, "userdata", "cache", "update", "staged", "LinPlayer")
	write := func(p, s string) {
		if err := os.MkdirAll(filepath.Dir(p), 0o755); err != nil {
			t.Fatal(err)
		}
		if err := os.WriteFile(p, []byte(s), 0o644); err != nil {
			t.Fatal(err)
		}
	}
	exe := filepath.Join(dir, "LinPlayer.exe")
	write(exe, "旧")
	write(filepath.Join(dir, "Theme", "x.axaml"), "旧")
	write(filepath.Join(dir, "userdata", "accounts.json"), "我的账号")
	write(filepath.Join(staged, "LinPlayer.exe"), "新")
	write(filepath.Join(staged, "Theme", "x.axaml"), "新")
	write(filepath.Join(staged, "lpcore.dll"), "新")

	// 脚本第一句是「等这个 pid 退出」。起一个当场就死的进程,拿它的 pid ——
	// 随手编一个数字的话,万一撞上真在跑的进程就要干等 120 秒
	dead := exec.Command("cmd", "/c", "exit")
	if err := dead.Run(); err != nil {
		t.Fatal(err)
	}
	log := filepath.Join(dir, "userdata", "logs", "update.log")
	_, body := applyScript("windows", applyPlan{
		Pid: dead.Process.Pid, Staged: staged, Dir: dir, Exe: exe, Log: log,
	})
	script, err := writeScript(filepath.Join(dir, "userdata", "cache", "update"), "apply-update.ps1", body)
	if err != nil {
		t.Fatal(err)
	}
	out, err := exec.Command("powershell", "-NoProfile", "-ExecutionPolicy", "Bypass",
		"-File", script).CombinedOutput()
	if err != nil {
		t.Fatalf("脚本没跑完: %v\n%s", err, out)
	}

	read := func(p string) string {
		b, err := os.ReadFile(p)
		if err != nil {
			t.Fatalf("读不到 %s: %v", p, err)
		}
		return string(b)
	}
	// ①「快捷方式失效」如果成立,只可能是 exe 换了地方。这里钉死:**同一个路径**换了内容
	if got := read(exe); got != "新" {
		t.Fatalf("exe 原地没换成新的(现在是 %q)—— 版本号也就永远不变,更新完还提示更新", got)
	}
	// ② 多出一层 LinPlayer/ = 「更新看着成功其实一次都没换」的那个形状
	if _, err := os.Stat(filepath.Join(dir, "LinPlayer")); err == nil {
		t.Fatal("安装目录里多出了一层 LinPlayer/,旧 exe 原地不动")
	}
	if got := read(filepath.Join(dir, "Theme", "x.axaml")); got != "新" {
		t.Fatalf("子目录里的文件没换(现在是 %q)", got)
	}
	if _, err := os.Stat(filepath.Join(dir, "lpcore.dll")); err != nil {
		t.Fatalf("新增的文件没带过来: %v", err)
	}
	// ③ userdata/ 必须原样活着 —— 这就是 robocopy 不许带 /MIR 的全部理由
	if got := read(filepath.Join(dir, "userdata", "accounts.json")); got != "我的账号" {
		t.Fatalf("用户数据被动了(现在是 %q)", got)
	}
	if _, err := os.Stat(staged); err == nil {
		t.Fatal("暂存目录没清掉,下次更新会拿它当负载根")
	}
	// 源在目标里面,一不小心就会把暂存树自己复制成 <安装目录>/userdata/... 的一份拷贝
	if _, err := os.Stat(filepath.Join(dir, "userdata", "cache", "update", "staged", "LinPlayer.exe")); err == nil {
		t.Fatal("暂存目录里被塞进了一份拷贝 —— 源在目标里面时 robocopy 递归到自己身上了")
	}
}
