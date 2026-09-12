package system

//
// 应用内一条龙更新:下载 → 验包 → 就位 → 等本进程退出 → 覆盖 → 重启。
//
// ☠ 覆盖**只加不删**。绿色包的全部用户数据就在 exe 同级的 userdata/ 里,
//   给覆盖脚本加一个 /MIR 或者先清空目标目录,等于把账号历史一起删掉 ——
//   而那一步跑的时候程序已经退出了,炸了连日志都没人写。
// ☠ 下载地址**不收 UI 传进来的 URL**:要装的东西只能由核心层自己从发布接口解析。
//   收 URL 的话这条命令就是一个「下载任意文件并以本机权限执行」的入口。
//

import (
	"archive/zip"
	"context"
	"fmt"
	"io"
	"net/http"
	"os"
	"os/exec"
	"path/filepath"
	"runtime"
	"strconv"
	"strings"
	"sync"

	"linplayer/core/bus"
	"linplayer/core/config"
	"linplayer/core/httpx"
	"linplayer/core/paths"
)

// updateDir 更新包落点。放 cache/ 下:丢了能重下。
func updateDir() string { return filepath.Join(paths.CacheDir(), "update") }

func installDir() (string, error) {
	exe, err := os.Executable()
	if err != nil {
		return "", err
	}
	return filepath.Dir(exe), nil
}

// CanSelfUpdate 安装目录写得进去吗。
//
// **先问再做**:绿色包被解压到 Program Files 之类的地方时覆盖会中途失败,
// 用户手上就是一个装不上也回不去的半吊子。探针写一个文件再删掉 ——
// 光看权限位在 Windows 上判不准(ACL 和只读属性是两回事)。
func CanSelfUpdate() bool {
	if runtime.GOOS == "android" {
		return false // 安卓交给系统装包器,不走覆盖这条路
	}
	dir, err := installDir()
	if err != nil {
		return false
	}
	p := filepath.Join(dir, ".lp-write-probe")
	f, err := os.OpenFile(p, os.O_CREATE|os.O_WRONLY|os.O_TRUNC, 0o644)
	if err != nil {
		return false
	}
	_ = f.Close()
	_ = os.Remove(p)
	return true
}

// ---------------------------------------------------------------- 下载状态

// updState 下载进度。**不主动推事件**,UI 轮询 system.updateProgress ——
// 和下载管理器同一个口径:一个活跃任务不值得为它开一条事件流。
type updState struct {
	mu     sync.Mutex
	phase  string // idle / downloading / ready / failed
	tag    string
	name   string
	file   string
	errMsg string
	got    int64
	total  int64
	cancel context.CancelFunc
}

var upd = &updState{phase: "idle"}

// UpdateProgress 下载进度。做成 struct 不是 map:字段名是**跨语言契约**,
// check-android-fields.py 只认得 struct 上的 json 标签(账号那条上一轮已经栽过)。
type UpdateProgress struct {
	// Phase idle / downloading / ready / failed
	Phase      string `json:"phase"`
	Tag        string `json:"tag"`
	AssetName  string `json:"asset_name"`
	File       string `json:"file"`
	Error      string `json:"error"`
	Downloaded int64  `json:"downloaded"`
	Total      int64  `json:"total"`
}

func (s *updState) snap() UpdateProgress {
	s.mu.Lock()
	defer s.mu.Unlock()
	return UpdateProgress{
		Phase: s.phase, Tag: s.tag, AssetName: s.name,
		File: s.file, Error: s.errMsg,
		Downloaded: s.got, Total: s.total,
	}
}

func (s *updState) progress(n int64) {
	s.mu.Lock()
	s.got = n
	s.mu.Unlock()
}

// start 开下载。已经在下就什么都不做 —— 按钮连点不该叠出两条。
func (s *updState) start(info *Info) {
	s.mu.Lock()
	if s.phase == "downloading" {
		s.mu.Unlock()
		return
	}
	ctx, cancel := context.WithCancel(context.Background())
	s.phase, s.tag, s.name = "downloading", info.Tag, info.AssetName
	s.file, s.errMsg, s.got, s.total, s.cancel = "", "", 0, info.AssetSize, cancel
	s.mu.Unlock()

	/* 脱离命令的 ctx 单开一条。命令一返回它的 ctx 就取消了,挂在上面的话
	   下载会在第一次读响应体时当场断,而界面上看到的是「刚开始就失败」。 */
	go func() {
		f, err := fetchAsset(ctx, info, s.progress)
		s.mu.Lock()
		defer s.mu.Unlock()
		s.cancel = nil
		if err != nil {
			s.phase, s.errMsg = "failed", err.Error()
			return
		}
		s.phase, s.file, s.got = "ready", f, s.total
	}()
}

// countWriter 数过去多少字节。
type countWriter struct {
	n  int64
	on func(int64)
}

func (w *countWriter) Write(p []byte) (int, error) {
	w.n += int64(len(p))
	w.on(w.n)
	return len(p), nil
}

// fetchAsset 把发行资产拉到 cache/update/ 下,返回落盘路径。
//
// 先写 `.part` 再改名:中途断网留下的半个文件不能被下一次当成「已经下好了」。
func fetchAsset(ctx context.Context, info *Info, on func(int64)) (string, error) {
	if info.AssetURL == "" {
		return "", fmt.Errorf("这个版本没有适合本平台的安装包")
	}
	dir := updateDir()
	if err := os.MkdirAll(dir, 0o755); err != nil {
		return "", err
	}
	dst := filepath.Join(dir, filepath.Base(info.AssetName))
	// 已经下过一份**大小对得上**的:直接用。重下 100MB 只为拿到同一份文件没有意义
	if fi, err := os.Stat(dst); err == nil && info.AssetSize > 0 && fi.Size() == info.AssetSize {
		on(fi.Size())
		return dst, nil
	}

	// 下载也要走代理:只代理「查版本」的话,墙内查得到新版却下不动
	req, err := http.NewRequestWithContext(ctx, http.MethodGet, proxied(info.AssetURL), nil)
	if err != nil {
		return "", err
	}
	resp, err := httpx.Client().Do(req)
	if err != nil {
		return "", fmt.Errorf("下载更新失败: %w", err)
	}
	defer resp.Body.Close()
	if resp.StatusCode < 200 || resp.StatusCode >= 300 {
		return "", fmt.Errorf("下载更新失败: 服务器返回 %d", resp.StatusCode)
	}

	part := dst + ".part"
	f, err := os.Create(part)
	if err != nil {
		return "", err
	}
	n, err := io.Copy(io.MultiWriter(f, &countWriter{on: on}), resp.Body)
	if cerr := f.Close(); err == nil {
		err = cerr
	}
	if err != nil {
		_ = os.Remove(part)
		return "", fmt.Errorf("下载更新失败: %w", err)
	}
	/* 大小对不上就是没下全。放行的话下一步会拿半个 zip 去覆盖安装目录 ——
	   zip 解压器多半还能解出前半截文件,那才是最糟的形态。 */
	if info.AssetSize > 0 && n != info.AssetSize {
		_ = os.Remove(part)
		return "", fmt.Errorf("下载不完整(%d/%d 字节),没装", n, info.AssetSize)
	}
	_ = os.Remove(dst)
	if err := os.Rename(part, dst); err != nil {
		return "", err
	}
	return dst, nil
}

// ---------------------------------------------------------------- 解包就位

// stageZip 把更新包解到 destDir,返回真正的**负载根**。
//
// wantExe 是解出来必须找得到的可执行文件名。找不到就说明这个包不是给本平台的、
// 或者结构变了 —— **在覆盖安装目录之前**挡掉,不然用户手上是一个起不来的目录。
func stageZip(zipPath, destDir, wantExe string) (string, error) {
	r, err := zip.OpenReader(zipPath)
	if err != nil {
		return "", fmt.Errorf("更新包打不开(可能没下全): %w", err)
	}
	defer r.Close()
	if err := os.MkdirAll(destDir, 0o755); err != nil {
		return "", err
	}
	sep := string(filepath.Separator)
	for _, f := range r.File {
		name := filepath.Clean(filepath.FromSlash(f.Name))
		/* ☠ zip slip:压缩包里的路径是**外来输入**,`../` 一路能写到安装目录外面去。
		   这一步不是洁癖 —— 这条链路的下游是「以本机权限覆盖文件」。 */
		if name == "." || name == sep || filepath.IsAbs(name) ||
			name == ".." || strings.HasPrefix(name, ".."+sep) {
			return "", fmt.Errorf("更新包里有越界路径: %s", f.Name)
		}
		dst := filepath.Join(destDir, name)
		if f.FileInfo().IsDir() {
			if err := os.MkdirAll(dst, 0o755); err != nil {
				return "", err
			}
			continue
		}
		if err := os.MkdirAll(filepath.Dir(dst), 0o755); err != nil {
			return "", err
		}
		if err := copyZipEntry(f, dst); err != nil {
			return "", err
		}
	}
	root, err := payloadRoot(destDir)
	if err != nil {
		return "", err
	}
	if _, err := os.Stat(filepath.Join(root, wantExe)); err != nil {
		return "", fmt.Errorf("更新包里没有 %s,不敢往安装目录上覆盖", wantExe)
	}
	return root, nil
}

func copyZipEntry(f *zip.File, dst string) error {
	rc, err := f.Open()
	if err != nil {
		return err
	}
	defer rc.Close()
	// 保留可执行位:Linux 上丢了它,解出来的程序跑不起来
	out, err := os.OpenFile(dst, os.O_CREATE|os.O_WRONLY|os.O_TRUNC, f.Mode().Perm()|0o200)
	if err != nil {
		return err
	}
	_, err = io.Copy(out, rc)
	if cerr := out.Close(); err == nil {
		err = cerr
	}
	return err
}

// payloadRoot 顺着「里面只有一个子目录」一路往下钻。
//
// ☠ pack-win.sh 用 Compress-Archive 打**整个文件夹**,所以真东西在 zip 里的
// `LinPlayer/` 这一层下面。照解压目录直接覆盖的话,安装目录会多出一个
// `LinPlayer/LinPlayer.exe`,而旧 exe 原地不动 —— 更新看着成功,其实一次都没换。
func payloadRoot(dir string) (string, error) {
	for range 4 {
		ents, err := os.ReadDir(dir)
		if err != nil {
			return "", err
		}
		if len(ents) != 1 || !ents[0].IsDir() {
			return dir, nil
		}
		dir = filepath.Join(dir, ents[0].Name())
	}
	return dir, nil
}

// ---------------------------------------------------------------- 覆盖脚本

// applyPlan 交给覆盖脚本的四个路径。
type applyPlan struct {
	Pid    int    // 等谁退出 —— 就是本进程,exe 正被自己锁着
	Staged string // 新版文件的负载根
	Dir    string // 安装目录
	Exe    string // 覆盖完重启谁
	Log    string // 脚本自己的日志。这一步跑的时候没人盯着,不写日志就是纯黑盒
}

func psq(s string) string { return "'" + strings.ReplaceAll(s, "'", "''") + "'" }

func shq(s string) string { return "'" + strings.ReplaceAll(s, "'", `'"'"'`) + "'" }

// applyScript 生成「等我退出 → 覆盖 → 重启」的脚本。
// goos 是参数不是 runtime 常量,为的是两个平台的脚本在任何一台机器上都能被自检读一遍。
func applyScript(goos string, p applyPlan) (name, body string) {
	pid := strconv.Itoa(p.Pid)
	if goos == "windows" {
		/* robocopy **不带 /MIR**:它只补齐和覆盖,从不删目标里多出来的东西。
		   userdata/ 就在这个目标目录里 —— 加一个 /MIR 等于删掉用户的全部账号。 */
		lines := []string{
			"$ErrorActionPreference = 'Continue'",
			"Start-Transcript -Path " + psq(p.Log) + " -Force | Out-Null",
			"Wait-Process -Id " + pid + " -Timeout 120 -ErrorAction SilentlyContinue",
			"Start-Sleep -Milliseconds 800",
			"& robocopy " + psq(p.Staged) + " " + psq(p.Dir) + " /E /R:2 /W:1 /NFL /NDL /NJH /NJS | Out-Null",
			"if ($LASTEXITCODE -ge 8) { Write-Output \"robocopy failed: $LASTEXITCODE\" }",
			"Remove-Item -LiteralPath " + psq(p.Staged) + " -Recurse -Force -ErrorAction SilentlyContinue",
			"Start-Process -FilePath " + psq(p.Exe) + " -WorkingDirectory " + psq(p.Dir),
			"Stop-Transcript | Out-Null",
		}
		return "apply-update.ps1", strings.Join(lines, "\r\n") + "\r\n"
	}
	lines := []string{
		"#!/bin/sh",
		"exec >>" + shq(p.Log) + " 2>&1",
		"while kill -0 " + pid + " 2>/dev/null; do sleep 1; done",
		"sleep 1",
		"cp -a " + shq(p.Staged+"/.") + " " + shq(p.Dir+"/"),
		"rm -rf " + shq(p.Staged),
		"cd " + shq(p.Dir) + " && " + shq(p.Exe) + " &",
	}
	return "apply-update.sh", strings.Join(lines, "\n") + "\n"
}

// writeScript 落盘。
//
// ☠ Windows 上必须写 **UTF-8 BOM**:没有 BOM 的 .ps1 会被按本地代码页(GBK)读,
// 路径里只要有一个中文字符后面的字节就错位,轻则路径不对重则吞掉下一行 ——
// 而 PowerShell 不会说自己读错了。pack-portable.ps1 栽过同一个坑。
func writeScript(dir, name, body string) (string, error) {
	p := filepath.Join(dir, name)
	data := []byte(body)
	mode := os.FileMode(0o755)
	if strings.HasSuffix(name, ".ps1") {
		data = append([]byte{0xEF, 0xBB, 0xBF}, data...)
		mode = 0o644
	}
	return p, os.WriteFile(p, data, mode)
}

// spawnDetached 起覆盖脚本并**立刻撒手**。它要活过本进程的死亡。
func spawnDetached(script string) error {
	var c *exec.Cmd
	if runtime.GOOS == "windows" {
		c = exec.Command("powershell", "-NoProfile", "-ExecutionPolicy", "Bypass",
			"-WindowStyle", "Hidden", "-File", script)
	} else {
		c = exec.Command("sh", script)
	}
	if err := c.Start(); err != nil {
		return err
	}
	// 不 Wait:等它就等于等自己退出。子进程不在作业对象里,父进程死了它照跑
	go func() { _ = c.Wait() }()
	return nil
}

// ---------------------------------------------------------------- 命令

func registerInstallCommands() {
	// system.downloadUpdate —— 开下载,**立刻返回**,进度轮询 system.updateProgress。
	bus.Register("system.downloadUpdate", func(ctx context.Context, seq int64, a map[string]any) (any, error) {
		ch := config.Current().PrefsOf().UpdateChannel
		info, err := CheckUpdate(ctx, ch, Version)
		if err != nil {
			return nil, bus.NewErr(bus.ENetwork, "%v", err)
		}
		if info == nil {
			return nil, bus.NewErr(bus.EInvalid, "已经是最新版本了")
		}
		if info.AssetURL == "" {
			return nil, bus.NewErr(bus.ENotFound, "这个版本没有适合本平台的安装包,去发布页手动下吧")
		}
		upd.start(info)
		return upd.snap(), nil
	})

	bus.Register("system.updateProgress", func(ctx context.Context, seq int64, a map[string]any) (any, error) {
		return upd.snap(), nil
	})

	bus.Register("system.cancelUpdate", func(ctx context.Context, seq int64, a map[string]any) (any, error) {
		upd.mu.Lock()
		if upd.cancel != nil {
			upd.cancel()
		}
		upd.phase, upd.errMsg, upd.cancel = "idle", "", nil
		upd.mu.Unlock()
		return upd.snap(), nil
	})

	// system.installUpdate —— 装上。
	//
	// 桌面端:解包 → 生成覆盖脚本 → 起脚本 → 返回 restart,宿主随即退出,
	// 脚本等到进程没了才动手。安卓端不走这条路,把 APK 交给系统装包器。
	bus.Register("system.installUpdate", func(ctx context.Context, seq int64, a map[string]any) (any, error) {
		upd.mu.Lock()
		phase, file := upd.phase, upd.file
		upd.mu.Unlock()
		if phase != "ready" || file == "" {
			return nil, bus.NewErr(bus.EInvalid, "安装包还没下好")
		}
		if runtime.GOOS == "android" {
			return InstallResult{Action: "apk", File: file}, nil
		}
		if !CanSelfUpdate() {
			return nil, bus.NewErr(bus.EInternal,
				"程序所在的文件夹写不进去,没法自动覆盖。把整个文件夹挪到个人目录下再试。")
		}
		exe, err := os.Executable()
		if err != nil {
			return nil, bus.NewErr(bus.EInternal, "找不到程序自己的位置: %v", err)
		}
		dir := filepath.Dir(exe)
		staged := filepath.Join(updateDir(), "staged")
		_ = os.RemoveAll(staged)
		root, err := stageZip(file, staged, filepath.Base(exe))
		if err != nil {
			_ = os.RemoveAll(staged)
			return nil, bus.NewErr(bus.EInternal, "%v", err)
		}
		name, body := applyScript(runtime.GOOS, applyPlan{
			Pid: os.Getpid(), Staged: root, Dir: dir, Exe: exe,
			Log: filepath.Join(paths.LogsDir(), "update.log"),
		})
		_ = os.MkdirAll(paths.LogsDir(), 0o755)
		script, err := writeScript(updateDir(), name, body)
		if err != nil {
			return nil, bus.NewErr(bus.EInternal, "写不出覆盖脚本: %v", err)
		}
		if err := spawnDetached(script); err != nil {
			return nil, bus.NewErr(bus.EInternal, "覆盖脚本起不来: %v", err)
		}
		bus.Logf("info", "更新就位,等本进程退出后覆盖: %s", root)
		return InstallResult{Action: "restart"}, nil
	})
}

// InstallResult 装这一步之后宿主该干什么。
//
// `restart` = 覆盖脚本已经在等本进程退出,宿主自己关掉即可;
// `apk` = 安卓,把 File 交给系统装包器。
type InstallResult struct {
	Action string `json:"action"`
	File   string `json:"file"`
}
