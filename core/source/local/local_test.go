package local

import (
	"context"
	"os"
	"path/filepath"
	"strings"
	"testing"

	"linplayer/core/source"
)

// tree 造一棵临时目录树。
//
// ★ 每个测试**各用各的目录**(t.TempDir 天然如此)。Rust 那版曾经四条测试
// 共用一棵树,而测试是并行跑的 —— 「删掉 movie.mkv 看报错」那条一动手,
// 正在列目录的那条当场少一个文件。红的是测试自己打架,不是被测代码有问题。
func tree(t *testing.T) string {
	t.Helper()
	root := t.TempDir()
	must(t, os.MkdirAll(filepath.Join(root, "剧集", "S01"), 0o755))
	must(t, os.WriteFile(filepath.Join(root, "movie.mkv"), []byte("x"), 0o644))
	must(t, os.WriteFile(filepath.Join(root, "cover.jpg"), []byte("x"), 0o644))
	must(t, os.WriteFile(filepath.Join(root, ".hidden"), []byte("x"), 0o644))
	must(t, os.WriteFile(filepath.Join(root, "剧集", "S01", "ep1.mp4"), []byte("xx"), 0o644))
	return root
}

func must(t *testing.T, err error) {
	t.Helper()
	if err != nil {
		t.Fatal(err)
	}
}

func srv(root string) *source.Server { return &source.Server{BaseURL: root} }

func TestListDir_目录在前且认得视频(t *testing.T) {
	root := tree(t)
	got, err := New().ListDir(context.Background(), nil, srv(root), "")
	if err != nil {
		t.Fatal(err)
	}
	var names []string
	for _, e := range got {
		names = append(names, e.Name)
	}
	want := []string{"剧集", "cover.jpg", "movie.mkv"}
	if strings.Join(names, ",") != strings.Join(want, ",") {
		t.Fatalf("排序不对:实得 %v,想要 %v(目录必须排最前)", names, want)
	}
	for _, e := range got {
		switch e.Name {
		case "movie.mkv":
			if !e.IsVideo || e.IsDir || e.Size == nil || *e.Size != 1 {
				t.Fatalf("movie.mkv 的字段不对: %+v", e)
			}
		case "cover.jpg":
			if e.IsVideo {
				t.Fatal("cover.jpg 被当成视频了")
			}
		}
	}
}

func TestListDir_隐藏文件不列(t *testing.T) {
	root := tree(t)
	got, _ := New().ListDir(context.Background(), nil, srv(root), "")
	for _, e := range got {
		if strings.HasPrefix(e.Name, ".") {
			t.Fatalf("隐藏文件 %q 被列出来了 —— 那只是噪声", e.Name)
		}
	}
}

// ★ 点进子目录:拿上一层给的 id 直接回传,必须能列出来。
func TestListDir_能逐层点进去(t *testing.T) {
	root := tree(t)
	b := New()
	top, err := b.ListDir(context.Background(), nil, srv(root), "")
	must(t, err)
	var subID string
	for _, e := range top {
		if e.Name == "剧集" {
			subID = e.ID
		}
	}
	if subID == "" {
		t.Fatal("根目录里没有「剧集」")
	}
	lvl2, err := b.ListDir(context.Background(), nil, srv(root), subID)
	must(t, err)
	if len(lvl2) != 1 || lvl2[0].Name != "S01" {
		t.Fatalf("第二层不对: %+v", lvl2)
	}
	lvl3, err := b.ListDir(context.Background(), nil, srv(root), lvl2[0].ID)
	must(t, err)
	if len(lvl3) != 1 || lvl3[0].Name != "ep1.mp4" || !lvl3[0].IsVideo {
		t.Fatalf("第三层不对: %+v", lvl3)
	}
}

// ★★ 越狱闸:这是本文件最要紧的一条。
//
// 前端可以把**任意** id 传回来。不做这道闸,一个 `..` 就能从用户挑的目录
// 跑到整块硬盘上去。用户挑一个目录的动作本身就是在划范围。
func TestConfine_跳不出用户选的目录(t *testing.T) {
	root := tree(t)
	parent := filepath.Dir(root)

	for _, bad := range []string{
		filepath.Join(root, ".."),
		filepath.Join(root, "..", ".."),
		parent,
		filepath.Join(root, "剧集", "..", ".."),
	} {
		if _, err := New().ListDir(context.Background(), nil, srv(root), bad); err == nil {
			t.Fatalf("%q 居然列出来了 —— 一个 .. 就跑到用户选的目录外面去了", bad)
		}
	}
}

// ★★ 前缀相同但**不在里面**的目录不能放行。
//
// `/data/movies-private` 不在 `/data/movies` 里面 —— 用 strings.HasPrefix
// 判断的话它会被放行,而这正是最容易写错的一处。
func TestConfine_同前缀的兄弟目录不算在里面(t *testing.T) {
	base := t.TempDir()
	root := filepath.Join(base, "movies")
	sibling := filepath.Join(base, "movies-private")
	must(t, os.MkdirAll(root, 0o755))
	must(t, os.MkdirAll(sibling, 0o755))
	must(t, os.WriteFile(filepath.Join(sibling, "secret.mkv"), []byte("x"), 0o644))

	if _, err := New().ListDir(context.Background(), nil, srv(root), sibling); err == nil {
		t.Fatal("movies-private 被当成 movies 的子目录放行了 —— " +
			"这是 strings.HasPrefix 判断路径的经典错法")
	}
}

// ★ 播放:给的是**裸路径**,不是 file:// URL(mpv 吃裸路径)。
func TestResolvePlay_给裸路径(t *testing.T) {
	root := tree(t)
	e := &source.Entry{ID: filepath.Join(root, "movie.mkv"), Name: "movie.mkv"}
	got, err := New().ResolvePlay(context.Background(), nil, srv(root), e, "")
	must(t, err)
	if strings.HasPrefix(got.URL, "file://") {
		t.Fatalf("拼成了 file:// URL: %q —— mpv 吃裸路径,自己拼要处理盘符/反斜杠/编码三件事", got.URL)
	}
	if !strings.HasSuffix(got.URL, "movie.mkv") {
		t.Fatalf("路径不对: %q", got.URL)
	}
	if got.Subtitles == nil || got.Qualities == nil {
		t.Fatal("列表字段是 nil —— 序列化成 null 会让前端 .map() 抛,透明窗口下就是一片黑")
	}
}

// ★ 文件没了要**说清楚**:索引里有不代表文件还在(删了 / 挪走了 / U 盘拔了)。
func TestResolvePlay_文件不在了要报清楚(t *testing.T) {
	root := tree(t)
	e := &source.Entry{ID: filepath.Join(root, "不存在.mkv"), Name: "不存在.mkv"}
	_, err := New().ResolvePlay(context.Background(), nil, srv(root), e, "")
	if err == nil {
		t.Fatal("文件不在了却成功了")
	}
	if !strings.Contains(err.Error(), "打不开") && !strings.Contains(err.Error(), "不存在") {
		t.Fatalf("错误信息看不出是文件没了: %v", err)
	}
}

// ★ 播放也要过越狱闸 —— 只在列目录那边拦是不够的,前端可以直接调播放。
func TestResolvePlay_也要过越狱闸(t *testing.T) {
	root := tree(t)
	outside := filepath.Join(filepath.Dir(root), "外面.mkv")
	must(t, os.WriteFile(outside, []byte("x"), 0o644))
	defer os.Remove(outside)

	e := &source.Entry{ID: outside, Name: "外面.mkv"}
	if _, err := New().ResolvePlay(context.Background(), nil, srv(root), e, ""); err == nil {
		t.Fatal("播放路径没过越狱闸 —— 只拦列目录的话,前端直接调播放就绕过去了")
	}
}

// ★ 没记住路径的源要说人话,不是拿空路径去读根目录。
func TestListDir_空根目录要报错(t *testing.T) {
	if _, err := New().ListDir(context.Background(), nil, srv("  "), ""); err == nil {
		t.Fatal("空的 base_url 居然成功了")
	}
}
