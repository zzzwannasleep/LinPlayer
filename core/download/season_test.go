package download

import (
	"fmt"
	"testing"

	"linplayer/core/emby"
)

// 整季下载必须翻到底。服务端把任何 Limit 都夹到 ServerPageCap(200),
// 只拿一页的写法在长季上是**静默少拿**:界面报「已加入 200 集」,
// 而用户以为整季都在里面了。
func TestAllEpisodes_超过一页要翻到底(t *testing.T) {
	const total = 443
	calls := 0
	got, err := allEpisodes(func(start int) (*emby.Page, error) {
		calls++
		n := total - start
		if n > emby.ServerPageCap {
			n = emby.ServerPageCap
		}
		items := make([]emby.Item, 0, n)
		for i := 0; i < n; i++ {
			items = append(items, emby.Item{ID: fmt.Sprint(start + i)})
		}
		return &emby.Page{Items: items, Total: total}, nil
	})
	if err != nil {
		t.Fatal(err)
	}
	if len(got) != total {
		t.Fatalf("该拿到 %d 集,实得 %d —— 服务端夹在 %d,少拿了不报错",
			total, len(got), emby.ServerPageCap)
	}
	if calls != 3 {
		t.Fatalf("443 集该翻 3 页,实得 %d 页", calls)
	}
	if got[0].ID != "0" || got[total-1].ID != fmt.Sprint(total-1) {
		t.Fatalf("翻页拼接错位:头 %q 尾 %q", got[0].ID, got[total-1].ID)
	}
}

/*
☠ Total 不可信。实测过的 fork 里它要么恒为 0,要么比真实条数大
(屏蔽过滤在服务端发完 Total 之后才做)。只拿 Total 当终止条件的话,
后一种会让这个循环**永远拉空页** —— 点一下「下载整季」就挂在那儿。
*/
func TestAllEpisodes_Total比真实条数大也要停(t *testing.T) {
	calls := 0
	got, err := allEpisodes(func(start int) (*emby.Page, error) {
		calls++
		if calls > 5 {
			t.Fatal("停不下来 —— Total 虚报时必须靠「这一页没拿满」出循环")
		}
		if start > 0 {
			// 服务端实际只有 200 条,却一直报 Total=1000
			return &emby.Page{Items: nil, Total: 1000}, nil
		}
		return &emby.Page{Items: make([]emby.Item, emby.ServerPageCap), Total: 1000}, nil
	})
	if err != nil {
		t.Fatal(err)
	}
	if len(got) != emby.ServerPageCap {
		t.Fatalf("该拿到 %d 集,实得 %d", emby.ServerPageCap, len(got))
	}
}

/*
落盘文件名要认得出是哪部剧的第几集。

☠ Emby 的 Episode.Name 常常只有「第 12 集」—— 两部剧各下一集就撞成
同一个文件,后一个把前一个覆盖掉且不报错。
*/
func TestFileBase(t *testing.T) {
	name := "凡人修仙传"
	s2, e35 := int64(2), int64(35)
	cases := []struct {
		in   Item
		want string
	}{
		{Item{Title: "第 35 集", SeriesName: &name, SeasonNumber: &s2, EpisodeNumber: &e35},
			"凡人修仙传 S02E35 第 35 集"},
		{Item{Title: "特别篇", SeriesName: &name}, "凡人修仙传 特别篇"},
		// 电影没有剧名,标题本身就是它 —— 不能被拼成空串
		{Item{Title: "阿凡达"}, "阿凡达"},
	}
	for _, c := range cases {
		got := fileBase(&c.in)
		if got != c.want {
			t.Errorf("实得 %q,期望 %q", got, c.want)
		}
	}
	// 两部剧的同号集**不能**落成同一个文件名
	other := "斗破苍穹"
	a := fileBase(&Item{Title: "第 35 集", SeriesName: &name, SeasonNumber: &s2, EpisodeNumber: &e35})
	b := fileBase(&Item{Title: "第 35 集", SeriesName: &other, SeasonNumber: &s2, EpisodeNumber: &e35})
	if a == b {
		t.Fatalf("两部剧的 S02E35 撞成了同一个文件名 %q —— 后一个会把前一个覆盖掉", a)
	}
}
