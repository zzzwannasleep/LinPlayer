package emby

import (
	"testing"

	"linplayer/core/blocklist"
)

// 媒体库屏蔽的两条**反向**要求。都对应真故障:
//
//  1. include_blocked=true 时一条都不能滤 —— 媒体库页是唯一能解除屏蔽的地方,
//     滤了就是单向门(用户屏蔽完来问「那我怎么恢复呢」)。
//  2. **只按 id 判,绝不按名字判** —— 两台服务器上都叫「电影」的库是两个不同的库,
//     按名字会一屏两台一起屏蔽。
func TestFilterBlockedLibraries(t *testing.T) {
	blocklist.Replace([]blocklist.Entry{{ID: "lib-a", Name: "电影"}})
	defer blocklist.Replace(nil)

	libs := []Item{{ID: "lib-a", Name: "电影"}, {ID: "lib-b", Name: "电影"}, {ID: "lib-c", Name: "剧集"}}

	got := FilterBlockedLibraries(append([]Item(nil), libs...), false)
	if len(got) != 2 || got[0].ID != "lib-b" {
		t.Fatalf("缺省应只滤掉 lib-a(按 id),实得 %+v", got)
	}
	// lib-b 同名不同 id:被滤掉了就是「按名字判」,那会一屏两台服务器
	for _, it := range got {
		if it.ID == "lib-a" {
			t.Fatal("lib-a 应被滤掉")
		}
	}

	all := FilterBlockedLibraries(append([]Item(nil), libs...), true)
	if len(all) != 3 {
		t.Fatalf("include_blocked=true 时一条都不能滤,实得 %d 条 —— 这是单向门", len(all))
	}
}
