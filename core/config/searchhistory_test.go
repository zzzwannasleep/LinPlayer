package config

import (
	"fmt"
	"strings"
	"testing"
)

/*
搜索历史的规矩(草稿 09 页第 34 条的空态用它)。

☠ 去重和封顶<b>必须在核心层</b>。三端各写一遍的话,「同一个词搜两次会不会出两条」
「记多少条」这两件事迟早说不一样的话,而这份表是跨端共用同一份配置的。
*/
func TestClampSearchHistory(t *testing.T) {
	got := ClampSearchHistory([]string{"三体", "  ", "三体", "沙丘", "", " 三体 ", "流浪地球"})
	want := []string{"三体", "沙丘", "流浪地球"}
	if strings.Join(got, "|") != strings.Join(want, "|") {
		t.Fatalf("去空去重之后该是 %v,实得 %v", want, got)
	}
}

// 封顶:超出的从**尾巴**丢,不是从头 —— 新的在前,丢掉的该是最久没搜的那些。
func TestClampSearchHistory_封顶从尾巴丢(t *testing.T) {
	in := make([]string, 0, SearchHistoryMax+5)
	for i := 0; i < SearchHistoryMax+5; i++ {
		in = append(in, fmt.Sprintf("第%d个", i))
	}
	got := ClampSearchHistory(in)
	if len(got) != SearchHistoryMax {
		t.Fatalf("该封在 %d 条,实得 %d", SearchHistoryMax, len(got))
	}
	if got[0] != "第0个" {
		t.Fatalf("最新的那条被丢了:头是 %q", got[0])
	}
	if got[len(got)-1] != fmt.Sprintf("第%d个", SearchHistoryMax-1) {
		t.Fatalf("丢的不是尾巴:尾是 %q", got[len(got)-1])
	}
}
