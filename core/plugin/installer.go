package plugin

// 插件安装/加载:.ipk(就是 zip,含 manifest.json + main.js[+图标])解压落盘;
// 从目录加载清单。安装目录扁平化为 `<plugins_root>/<id>/`(一插件一版本,重装即覆盖)。

import (
	"archive/zip"
	"bytes"
	"fmt"
	"io"
	"os"
	"path/filepath"
	"strings"
)

// Installed 一个已装好的插件在磁盘上的位置。
type Installed struct {
	Manifest  *Manifest
	Dir       string
	EntryPath string // main.js 绝对路径
}

// LoadFromDir 从已解压目录加载(扫描用)。
func LoadFromDir(dir string) (*Installed, error) {
	raw, err := os.ReadFile(filepath.Join(dir, "manifest.json"))
	if err != nil {
		return nil, fmt.Errorf("读 manifest 失败: %w", err)
	}
	m, err := ParseManifest(string(raw))
	if err != nil {
		return nil, err
	}
	entry := filepath.Join(dir, filepath.FromSlash(m.Main))
	if _, err := os.Stat(entry); err != nil {
		return nil, fmt.Errorf("入口不存在: %s", m.Main)
	}
	return &Installed{Manifest: m, Dir: dir, EntryPath: entry}, nil
}

// safeJoin 防 zip-slip:解出来的路径必须仍在 dest 之内。
//
// ★ Go 的 archive/zip **不做**这件事(Rust 的 zip crate 有 enclosed_name),
// 所以这一层必须自己写:一个 `../../` 的条目就能往用户任意目录写文件。
func safeJoin(dest, name string) (string, bool) {
	clean := filepath.Clean(strings.ReplaceAll(name, "\\", "/"))
	if clean == "." || filepath.IsAbs(clean) || strings.HasPrefix(clean, "..") {
		return "", false
	}
	// 盘符形式的绝对路径(C:foo)在 Linux 上 IsAbs 为假,单独挡掉。
	if len(clean) >= 2 && clean[1] == ':' {
		return "", false
	}
	out := filepath.Join(dest, clean)
	if out != dest && !strings.HasPrefix(out, dest+string(filepath.Separator)) {
		return "", false
	}
	return out, true
}

// InstallIPKBytes 从 .ipk 字节安装到 plugins_root/<id>/。
func InstallIPKBytes(data []byte, pluginsRoot string) (*Installed, error) {
	zr, err := zip.NewReader(bytes.NewReader(data), int64(len(data)))
	if err != nil {
		return nil, fmt.Errorf("打开 .ipk 失败: %w", err)
	}

	// 先取 manifest 校验 + 拿 id。
	var manifest *Manifest
	for _, f := range zr.File {
		if f.Name != "manifest.json" {
			continue
		}
		rc, err := f.Open()
		if err != nil {
			return nil, fmt.Errorf("读 manifest 失败: %w", err)
		}
		raw, err := io.ReadAll(rc)
		rc.Close()
		if err != nil {
			return nil, fmt.Errorf("读 manifest 失败: %w", err)
		}
		manifest, err = ParseManifest(string(raw))
		if err != nil {
			return nil, err
		}
		break
	}
	if manifest == nil {
		return nil, fmt.Errorf("包内缺少 manifest.json")
	}

	dest := filepath.Join(pluginsRoot, manifest.ID)
	if _, err := os.Stat(dest); err == nil {
		if err := os.RemoveAll(dest); err != nil {
			return nil, fmt.Errorf("清理旧版本失败: %w", err)
		}
	}
	if err := os.MkdirAll(dest, 0o755); err != nil {
		return nil, fmt.Errorf("建插件目录失败: %w", err)
	}

	for _, f := range zr.File {
		out, ok := safeJoin(dest, f.Name)
		if !ok {
			return nil, fmt.Errorf("包内含非法路径,已拒绝安装: %s", f.Name)
		}
		if f.FileInfo().IsDir() {
			if err := os.MkdirAll(out, 0o755); err != nil {
				return nil, fmt.Errorf("建目录失败: %w", err)
			}
			continue
		}
		if err := os.MkdirAll(filepath.Dir(out), 0o755); err != nil {
			return nil, fmt.Errorf("建目录失败: %w", err)
		}
		rc, err := f.Open()
		if err != nil {
			return nil, fmt.Errorf("读包条目失败: %w", err)
		}
		buf, err := io.ReadAll(rc)
		rc.Close()
		if err != nil {
			return nil, fmt.Errorf("解压失败: %w", err)
		}
		if err := os.WriteFile(out, buf, 0o644); err != nil {
			return nil, fmt.Errorf("写文件失败: %w", err)
		}
	}
	return LoadFromDir(dest)
}

// InstallIPKFile 从磁盘上的 .ipk 安装。
func InstallIPKFile(ipkPath, pluginsRoot string) (*Installed, error) {
	data, err := os.ReadFile(ipkPath)
	if err != nil {
		return nil, fmt.Errorf("读 .ipk 失败: %w", err)
	}
	return InstallIPKBytes(data, pluginsRoot)
}

// UninstallDir 删掉一个插件目录。
func UninstallDir(dir string) error {
	if _, err := os.Stat(dir); err != nil {
		return nil
	}
	if err := os.RemoveAll(dir); err != nil {
		return fmt.Errorf("删除插件目录失败: %w", err)
	}
	return nil
}
