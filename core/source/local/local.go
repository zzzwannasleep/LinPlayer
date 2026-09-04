// Package local 本机文件夹源。用户点「本地播放」→ 系统文件夹选择器挑一个目录 →
// 当成一个源接进来,之后就和网盘 / 局域网源走**完全一样**的浏览页和播放链路。
//
// ## 为什么做成「源」而不是另开一套页面
//
// 一个能列目录、能把条目解析成可播地址的东西,正好就是 `source.Backend`。
// 做成源就白拿:文件浏览页、面包屑、搜索、播放、服务器列表里的一条、重启免登。
// 另开一套「本地播放页」等于把这些**再实现一遍**,还得再维护一遍。
//
// ## 交给 mpv 的是**裸路径**,不是 file:// URL
//
// 播放链路最后一句是把 URL 喂给 mpv,而 mpv 吃裸路径。自己拼 file:// 反而要处理
// 盘符、反斜杠、百分号编码三件事,每件都能拼错。
package local

import (
	"context"
	"net/http"
	"os"
	"path/filepath"
	"strings"

	"linplayer/core/source"
)

// Backend 本机文件夹。
type Backend struct{}

// New 造一个。
func New() *Backend { return &Backend{} }

// Kind 源类型。
func (*Backend) Kind() source.Kind { return source.KindLocal }

// confine 把要访问的路径**关进用户选的那个根目录里**。
//
// ★★ entry.ID 是绝对路径,而前端可以把任意 id 传回来(浏览页的面包屑、历史记录、
// 将来某个手滑拼出来的路径)。不做这道闸,一个 `..` 就能从用户挑的「电影」目录
// 跑到整块硬盘上去 —— 这不是「反正是他自己的电脑」能糊弄过去的:
// **用户挑一个目录的动作本身就是在划范围。**
//
// ★ 用 EvalSymlinks + Abs 而不是纯字符串比较:符号链接、`..`、大小写、
// Windows 的 `\\?\` 前缀都得先归一,不然「看着在里面、实际在外面」照样能过。
func confine(root string, target string) (string, error) {
	rootReal, err := realPath(strings.TrimSpace(root))
	if err != nil {
		return "", source.Msg("文件夹打不开(%s): %v", root, err)
	}
	targetReal, err := realPath(target)
	if err != nil {
		return "", source.Msg("路径打不开(%s): %v", target, err)
	}
	if !under(targetReal, rootReal) {
		return "", source.Msg("这个路径不在你选的文件夹里")
	}
	return targetReal, nil
}

func realPath(p string) (string, error) {
	abs, err := filepath.Abs(p)
	if err != nil {
		return "", err
	}
	// EvalSymlinks 顺带做了「存在性」检查,和 Rust 的 canonicalize 口径一致
	real, err := filepath.EvalSymlinks(abs)
	if err != nil {
		return "", err
	}
	return real, nil
}

// under 判断 child 是不是在 parent 里面(或就是它)。
//
// ★ 不能用 strings.HasPrefix 直接判:`/data/movies-private` 会被判成
// 在 `/data/movies` 里面。必须按**路径分隔符**对齐。
func under(child, parent string) bool {
	rel, err := filepath.Rel(parent, child)
	if err != nil {
		return false
	}
	if rel == "." {
		return true
	}
	return rel != ".." && !strings.HasPrefix(rel, ".."+string(filepath.Separator))
}

// ListDir 列目录。dirID 为空 = 根目录。
func (b *Backend) ListDir(ctx context.Context, _ *http.Client, s *source.Server, dirID string) ([]source.Entry, error) {
	root := strings.TrimSpace(s.BaseURL)
	if root == "" {
		return nil, source.Msg("这个本地源没有记住文件夹路径")
	}
	want := dirID
	if want == "" {
		want = root
	}
	dir, err := confine(root, want)
	if err != nil {
		return nil, err
	}
	return read(dir)
}

// read 读一个目录。
//
// ★ **单条读失败只跳过这一条**,不让整个目录列不出来 ——
// 一个权限不足的子目录不该把旁边二十部片子一起拖下水。
func read(dir string) ([]source.Entry, error) {
	des, err := os.ReadDir(dir)
	if err != nil {
		return nil, source.Msg("读不了这个文件夹: %v", err)
	}
	out := make([]source.Entry, 0, len(des))
	for _, de := range des {
		name := de.Name()
		// 隐藏文件 / 系统目录:列出来只是噪声
		// (macOS 的 .DS_Store、Windows 的 System Volume Information)
		if strings.HasPrefix(name, ".") {
			continue
		}
		full := filepath.Join(dir, name)
		isDir := de.IsDir()
		// 符号链接按它**指向的东西**算(指向目录就当目录)。
		// confine 那道闸会挡住指到外面去的。
		if de.Type()&os.ModeSymlink != 0 {
			st, err := os.Stat(full)
			if err != nil {
				continue
			}
			isDir = st.IsDir()
		}
		e := source.Entry{ID: full, Name: name, IsDir: isDir}
		if !isDir {
			e.IsVideo = source.IsVideoFileName(name)
			if info, err := de.Info(); err == nil && info.Size() > 0 {
				sz := info.Size()
				e.Size = &sz
			}
		}
		out = append(out, e)
	}
	source.SortEntries(out)
	return out, nil
}

// ResolvePlay 交给播放器:裸路径。
func (b *Backend) ResolvePlay(ctx context.Context, _ *http.Client, s *source.Server,
	e *source.Entry, _ string) (*source.ResolvedPlay, error) {
	path, err := confine(s.BaseURL, e.ID)
	if err != nil {
		return nil, err
	}
	st, err := os.Stat(path)
	if err != nil || st.IsDir() {
		// 索引里有不代表文件还在(用户可能删了 / 挪走了 / U 盘拔了)
		return nil, source.Msg("文件已不存在:%s", path)
	}
	r := source.Simple(path, e.Name, nil)
	return &r, nil
}
