package emby

import "strings"

import "testing"

// 搜索 URL 的形状。**这几条都对应真实故障**,不是凑的:
//
//	· SearchTerm 写成小写 searchTerm 被服务端**静默忽略** —— 搜索一直在吐全库前 N 条
//	  冒充结果(实测 TotalRecordCount=25596)。
//	· parent_id 传空串时不能拼上去,否则变成「在 id 为空的库里搜」= 零结果。
//	· Limit 超过服务端硬上限时被夹,自己先夹掉才知道拿到的是不是全部。
func TestSearchURL(t *testing.T) {
	s := &Session{Server: "http://x", UserID: "u"}

	u := searchURL(s, "关键词", nil, 0, "")
	if !strings.Contains(u, "SearchTerm=") {
		t.Fatalf("必须是大写 S 的 SearchTerm,实得:%s", u)
	}
	if strings.Contains(u, "searchTerm=") {
		t.Fatalf("小写 searchTerm 会被服务端静默忽略:%s", u)
	}
	if !strings.Contains(u, "IncludeItemTypes=Movie,Series,Episode") {
		t.Fatalf("没点名类型时默认三种:%s", u)
	}
	if strings.Contains(u, "ParentId=") {
		t.Fatalf("parent_id 为空串时不该拼 ParentId:%s", u)
	}
	if !strings.Contains(u, "Limit=50") {
		t.Fatalf("limit<=0 时默认 50:%s", u)
	}
	if !strings.Contains(u, "Recursive=true") {
		t.Fatalf("必须 Recursive,否则只搜库根那一层:%s", u)
	}
	// 跨服续播的强匹配判据必须要,缺了会静默降级到「剧名+季集号」猜
	for _, f := range []string{"ProviderIds", "PresentationUniqueKey", "Path", "SeriesId"} {
		if !strings.Contains(u, f) {
			t.Fatalf("缺 Fields %s:%s", f, u)
		}
	}

	u = searchURL(s, "x", []string{"Movie"}, 9999, "  lib-1  ")
	if !strings.Contains(u, "Limit=200") {
		t.Fatalf("limit 要夹到服务端硬上限 200:%s", u)
	}
	if !strings.Contains(u, "ParentId=lib-1") {
		t.Fatalf("parent_id 要去空白后拼上:%s", u)
	}
	if !strings.Contains(u, "IncludeItemTypes=Movie&") {
		t.Fatalf("点名了就只发点名的:%s", u)
	}
}

// filterTypes 的两个边界:没点名 = 全要(不是一个都不要)。
func TestFilterTypesEmptyMeansAll(t *testing.T) {
	in := []Item{{ID: "a", Type: "Movie"}, {ID: "b", Type: "Episode"}}
	if got := filterTypes(append([]Item(nil), in...), nil); len(got) != 2 {
		t.Fatalf("没点名类型时应原样返回,实得 %d 条", len(got))
	}
	if got := filterTypes(append([]Item(nil), in...), []string{"Movie"}); len(got) != 1 || got[0].ID != "a" {
		t.Fatalf("点名 Movie 应只剩 a,实得 %+v", got)
	}
}
