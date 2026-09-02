package translate

// Whisper 本地转写(桌面独占)。
//
// 不预置任何模型,用户在设置里开启功能后按需下载。模型为 whisper.cpp 的 GGML
// 量化权重,下载源默认 Hugging Face 官方仓库。

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
	"strings"
	"sync"

	"linplayer/core/httpx"
	"linplayer/core/paths"
)

// WhisperModel 模型规格。
type WhisperModel string

// 四档模型。**这些字面量是存盘键**。
const (
	WhisperTiny   WhisperModel = "tiny"
	WhisperBase   WhisperModel = "base"
	WhisperMedium WhisperModel = "medium"
	WhisperLarge  WhisperModel = "large"
)

// AllWhisperModels 顺序即 UI 展示顺序。
var AllWhisperModels = []WhisperModel{WhisperTiny, WhisperBase, WhisperMedium, WhisperLarge}

// WhisperModelOf 按 key 取模型。
//
// ★★ **认不出必须报错,不能静默回落默认档** —— 黄金实现的 from_key 会悄悄回落,
// 于是前端传错一个字,用户点「下载 medium」实际下的是 base(1.5GB vs 142MB),
// 而界面上什么都不说。
func WhisperModelOf(key string) (WhisperModel, error) {
	for _, m := range AllWhisperModels {
		if string(m) == key {
			return m, nil
		}
	}
	return "", fmt.Errorf("未知的 Whisper 模型:%s", key)
}

// DisplayName 人话名字。
func (m WhisperModel) DisplayName() string {
	switch m {
	case WhisperTiny:
		return "Tiny(最快,精度最低)"
	case WhisperMedium:
		return "Medium(较慢,精度好)"
	case WhisperLarge:
		return "Large(最慢,精度最高)"
	}
	return "Base(快速,日常够用)"
}

// FileName 权重文件名(whisper.cpp GGML 格式)。
func (m WhisperModel) FileName() string {
	switch m {
	case WhisperTiny:
		return "ggml-tiny.bin"
	case WhisperMedium:
		return "ggml-medium.bin"
	case WhisperLarge:
		return "ggml-large-v3.bin"
	}
	return "ggml-base.bin"
}

// SizeLabel 大致体积(UI 提示用)。
func (m WhisperModel) SizeLabel() string {
	switch m {
	case WhisperTiny:
		return "约 75 MB"
	case WhisperMedium:
		return "约 1.5 GB"
	case WhisperLarge:
		return "约 2.9 GB"
	}
	return "约 142 MB"
}

// whisperOfficialBase 官方权重仓库。设置里可填镜像覆盖。
const whisperOfficialBase = "https://huggingface.co/ggerganov/whisper.cpp/resolve/main"

// DownloadURL 默认下载地址。
func (m WhisperModel) DownloadURL(mirrorBase string) string {
	base := whisperOfficialBase
	if strings.TrimSpace(mirrorBase) != "" {
		base = strings.TrimRight(strings.TrimSpace(mirrorBase), "/")
	}
	return base + "/" + m.FileName()
}

// DownloadProgress 下载进度:(已收字节, 总字节, 0..1)。总字节未知时为 0。
type DownloadProgress func(done, total int64, pct float64)

// ModelsDir 模型目录。
//
// ★★ **必须在 data/ 而不是 cache/** —— 一个模型几百 MB 到几 GB,
// 被「清理缓存」顺手删掉等于让用户重下一晚上。
func ModelsDir() string { return paths.ModelsDir() }

// ModelFile 某个模型的权重文件路径。
func ModelFile(m WhisperModel) string { return filepath.Join(ModelsDir(), m.FileName()) }

// DownloadedSize 已下载模型的体积(字节),未下载返回 0。
func DownloadedSize(m WhisperModel) int64 {
	st, err := os.Stat(ModelFile(m))
	if err != nil {
		return 0
	}
	return st.Size()
}

// IsDownloaded 已下载**且非半截文件**(> 1MB)。
func IsDownloaded(m WhisperModel) bool { return DownloadedSize(m) > 1024*1024 }

// DeleteModel 删掉一个模型。
func DeleteModel(m WhisperModel) error {
	f := ModelFile(m)
	if _, err := os.Stat(f); err != nil {
		return nil
	}
	if err := os.Remove(f); err != nil {
		return fmt.Errorf("删除模型失败: %w", err)
	}
	return nil
}

// DownloadModel 下载模型。mirrorBase 为空用官方源。
//
// ★ 流式写临时文件,完成后原子改名 —— 中断不会留下半截损坏文件被当成「已下载」。
func DownloadModel(ctx context.Context, m WhisperModel, mirrorBase string, onProgress DownloadProgress) (string, error) {
	u := m.DownloadURL(mirrorBase)
	/* ★★ 强制 https:自定义镜像可能填 http://,而明文下载会被中间人替换成篡改过的
	   GGML 权重,再交给原生 whisper 二进制去解析 —— 那是内存破坏级的攻击面。 */
	if !strings.HasPrefix(strings.ToLower(u), "https://") {
		return "", fmt.Errorf("模型下载地址必须为 https:%s", u)
	}
	dir := ModelsDir()
	if err := os.MkdirAll(dir, 0o755); err != nil {
		return "", fmt.Errorf("建模型目录失败: %w", err)
	}
	target := ModelFile(m)
	tmp := target + ".part"

	if err := downloadTo(ctx, u, tmp, onProgress); err != nil {
		_ = os.Remove(tmp)
		return "", err
	}
	_ = os.Remove(target)
	if err := os.Rename(tmp, target); err != nil {
		return "", fmt.Errorf("改名失败: %w", err)
	}
	return target, nil
}

// downloadTo 流式下载到文件(带进度)。
func downloadTo(ctx context.Context, u, out string, onProgress DownloadProgress) error {
	req, err := http.NewRequestWithContext(ctx, http.MethodGet, u, nil)
	if err != nil {
		return fmt.Errorf("下载请求失败: %w", err)
	}
	resp, err := httpx.Client().Do(req)
	if err != nil {
		return fmt.Errorf("下载请求失败: %w", err)
	}
	defer resp.Body.Close()
	if resp.StatusCode < 200 || resp.StatusCode >= 300 {
		return fmt.Errorf("下载失败: HTTP %d", resp.StatusCode)
	}
	total := resp.ContentLength
	if total < 0 {
		total = 0
	}
	f, err := os.Create(out)
	if err != nil {
		return fmt.Errorf("建文件失败: %w", err)
	}
	defer f.Close()

	buf := make([]byte, 256*1024)
	var got int64
	for {
		if ctx.Err() != nil {
			return fmt.Errorf("下载已取消")
		}
		n, rerr := resp.Body.Read(buf)
		if n > 0 {
			if _, werr := f.Write(buf[:n]); werr != nil {
				return fmt.Errorf("写入失败: %w", werr)
			}
			got += int64(n)
			if onProgress != nil {
				pct := 0.0
				if total > 0 {
					pct = float64(got) / float64(total)
				}
				onProgress(got, total, pct)
			}
		}
		if rerr == io.EOF {
			break
		}
		if rerr != nil {
			return fmt.Errorf("下载中断: %w", rerr)
		}
	}
	return nil
}

// ---------------------------------------------------------------------------
// 外部二进制定位
// ---------------------------------------------------------------------------

func exeName(stem string) string {
	if runtime.GOOS == "windows" {
		return stem + ".exe"
	}
	return stem
}

// binDir 下载来的 whisper/ffmpeg 可执行文件。同 ModelsDir:重下代价高,放 data/ 不放 cache/。
func binDir() string { return filepath.Join(paths.Root(), "bin") }

func exeDir() string {
	p, err := os.Executable()
	if err != nil {
		return "."
	}
	return filepath.Dir(p)
}

func isFile(p string) bool {
	st, err := os.Stat(p)
	return err == nil && !st.IsDir()
}

var (
	runsOKMu   sync.Mutex
	runsOKMemo = map[string]bool{}
)

// runsOk 这个名字在 PATH 上跑得起来吗。
//
// ★★ 结果**按 exe 名缓存**。这是「每次打开字幕翻译都卡」的元凶那一半:
// 探测要真的 spawn 一次子进程,最多 4 次;不缓存的话每次打开设置页都重来一遍。
// 缓存是正确的:一次会话内 PATH 不会变,而用户装了 ffmpeg 之后重开一次应用即可。
func runsOk(exe string) bool {
	runsOKMu.Lock()
	if v, ok := runsOKMemo[exe]; ok {
		runsOKMu.Unlock()
		return v
	}
	runsOKMu.Unlock()

	cmd := exec.Command(exe, "-version")
	hideWindow(cmd)
	ok := cmd.Run() == nil

	runsOKMu.Lock()
	runsOKMemo[exe] = ok
	runsOKMu.Unlock()
	return ok
}

func commonFFmpegLocations() []string {
	switch runtime.GOOS {
	case "windows":
		return []string{`C:\ffmpeg\bin\ffmpeg.exe`, `C:\Program Files\ffmpeg\bin\ffmpeg.exe`}
	case "darwin":
		return []string{"/opt/homebrew/bin/ffmpeg", "/usr/local/bin/ffmpeg"}
	}
	return []string{"/usr/bin/ffmpeg", "/usr/local/bin/ffmpeg", "/snap/bin/ffmpeg"}
}

// ResolveFFmpeg 定位 ffmpeg,找不到返回空串。
//
// 顺序:用户指定 → 已下载缓存 → 随应用打包 → 系统 PATH → 常见安装位置。
func ResolveFFmpeg(configured string) string {
	name := exeName("ffmpeg")
	if configured != "" && isFile(configured) {
		return configured
	}
	if cached := filepath.Join(binDir(), name); isFile(cached) {
		return cached
	}
	d := exeDir()
	for _, c := range []string{
		filepath.Join(d, name),
		filepath.Join(d, "ffmpeg", name),
		filepath.Join(d, "bin", name),
	} {
		if isFile(c) {
			return c
		}
	}
	if runsOk(name) {
		return name // PATH
	}
	for _, c := range commonFFmpegLocations() {
		if isFile(c) {
			return c
		}
	}
	return ""
}

// ResolveWhisper 定位 whisper-cli(用户指定/缓存/内置/PATH/旧名 main|whisper),
// 找不到返回空串。
func ResolveWhisper(configured string) string {
	name := exeName("whisper-cli")
	if configured != "" && isFile(configured) {
		return configured
	}
	if cached := filepath.Join(binDir(), name); isFile(cached) {
		return cached
	}
	d := exeDir()
	for _, c := range []string{
		filepath.Join(d, name),
		filepath.Join(d, "whisper", name),
		filepath.Join(d, "bin", name),
		filepath.Join(d, "..", "Resources", "whisper", name),
	} {
		if isFile(c) {
			return c
		}
	}
	if runsOk(name) {
		return name // PATH
	}
	// 兼容旧名 main / whisper。
	for _, alt := range []string{"main", "whisper"} {
		if c := filepath.Join(d, exeName(alt)); isFile(c) {
			return c
		}
	}
	return ""
}

// ffmpeg 静态构建下载地址。
//
// ★ 这两个是 ffmpeg 官网 Download 页给各平台指的源,属于**公开的官方分发地址**,
// 和 API 基址一个性质;而且用户随时可以在设置里手填自己的 ffmpeg 路径绕开它。
const (
	ffmpegWinURL = "https://www.gyan.dev/ffmpeg/builds/ffmpeg-release-essentials.zip"
	ffmpegMacURL = "https://evermeet.cx/ffmpeg/getrelease/ffmpeg/zip"
)

// DownloadFFmpeg 下载并安装 ffmpeg 到应用 bin 目录,返回可执行文件路径。
//
// ★ Linux 上游是 .tar.xz,Go 标准库解不了 —— **明确报错让用户走包管理器**,
// 而不是下完 30MB 再失败。
func DownloadFFmpeg(ctx context.Context, onProgress DownloadProgress) (string, error) {
	var u string
	switch runtime.GOOS {
	case "windows":
		u = ffmpegWinURL
	case "darwin":
		u = ffmpegMacURL
	default:
		return "", fmt.Errorf(
			"Linux 上请用发行版包管理器安装 ffmpeg(如 apt install ffmpeg),或在设置里手填路径 —— " +
				"上游只提供 .tar.xz,应用内解不了")
	}

	dir := binDir()
	if err := os.MkdirAll(dir, 0o755); err != nil {
		return "", fmt.Errorf("建 bin 目录失败: %w", err)
	}
	tmp := filepath.Join(dir, "ffmpeg_dl.zip")
	if err := downloadTo(ctx, u, tmp, onProgress); err != nil {
		_ = os.Remove(tmp)
		return "", err
	}
	defer os.Remove(tmp)

	out := filepath.Join(dir, exeName("ffmpeg"))
	if err := extractFFmpegFromZip(tmp, out); err != nil {
		return "", err
	}
	setExecutable(out)
	return out, nil
}

// extractFFmpegFromZip 从 zip 里挑出 ffmpeg 可执行文件。
//
// ★ **按文件名找,不按路径找**:包内路径含版本号(ffmpeg-7.x-essentials_build/bin/ffmpeg.exe),
// 写死路径会在上游发版时静默失效。
func extractFFmpegFromZip(zipPath, out string) error {
	zr, err := zip.OpenReader(zipPath)
	if err != nil {
		return fmt.Errorf("解包失败: %w", err)
	}
	defer zr.Close()
	want := exeName("ffmpeg")
	for _, f := range zr.File {
		if filepath.Base(strings.ReplaceAll(f.Name, "\\", "/")) != want {
			continue
		}
		rc, err := f.Open()
		if err != nil {
			return fmt.Errorf("解包失败: %w", err)
		}
		defer rc.Close()
		dst, err := os.Create(out)
		if err != nil {
			return fmt.Errorf("写 ffmpeg 失败: %w", err)
		}
		defer dst.Close()
		if _, err := io.Copy(dst, rc); err != nil {
			return fmt.Errorf("写 ffmpeg 失败: %w", err)
		}
		return nil
	}
	return fmt.Errorf("包内未找到 %s", want)
}

func setExecutable(p string) {
	if runtime.GOOS != "windows" {
		_ = os.Chmod(p, 0o755)
	}
}
