package player

import (
	"strings"
	"testing"
)

func s2(v string) *string { return &v }
func n2(v int64) *int64   { return &v }

// 标题不传,靠标题搜弹幕的脚本(uosc_danmaku 一类)什么都搜不到 ——
// 它看到的只是一串 Emby 直传 URL。
func Test外部播放器标题(t *testing.T) {
	for _, c := range []struct{ want string; series *string; sn, en *int64; name string }{
		{"某剧 S01E05 出发", s2("某剧"), n2(1), n2(5), "出发"},
		{"某剧 出发", s2("某剧"), nil, nil, "出发"},
		{"某部电影", nil, nil, nil, "某部电影"},
		{"某剧 S02E10", s2("某剧"), n2(2), n2(10), "某剧"}, // 名字和剧名一样就不重复一遍
	} {
		if got := itemTitle(c.series, c.sn, c.en, c.name); got != c.want {
			t.Fatalf("标题:得到 %q,要 %q", got, c.want)
		}
	}
}

// ☠ 标题必须**跟着各自那一条**走(mpv 的 `--{ … --}`)。写成一个全局
// --force-media-title 的话第二集起显示第一集的名字,弹幕会跟着搜错。
// ☠ --start= 只给第一条,否则后面每一集都跳到同一个续播点。
func Test外部播放器命令行(t *testing.T) {
	q := []extEntry{{URL: "u1", Title: "甲"}, {URL: "u2", Title: "乙"}}
	got := strings.Join(externalArgs(true, 63.5, q), " ")
	want := "--{ --start=63.500 --force-media-title=甲 u1 --} --{ --force-media-title=乙 u2 --}"
	if got != want {
		t.Fatalf("命令行:\n得到 %s\n要   %s", got, want)
	}

	// 每一条都得有自己的 --force-media-title,一条都不能少
	if n := strings.Count(got, "--force-media-title="); n != len(q) {
		t.Fatalf("%d 条却只有 %d 个标题参数", len(q), n)
	}
	// --start= 只能出现一次,而且必须在第一条那一组里
	if strings.Count(got, "--start=") != 1 || strings.Index(got, "--start=") > strings.Index(got, "u1") {
		t.Fatalf("--start= 位置不对: %s", got)
	}

	// 不是 mpv 的播放器:一个参数都不给。给错参数导致压根打不开,比不续播糟得多
	if got := externalArgs(false, 63.5, q); len(got) != 1 || got[0] != "u1" {
		t.Fatalf("非 mpv 只能递一个地址,实得 %v", got)
	}
}
