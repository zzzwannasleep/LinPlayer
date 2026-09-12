package emby

import (
	"context"
	"net/http"
	"net/http/httptest"
	"testing"
)

// 真服实测(Emby 4.9.5,2026-09-12):
//   Studios = [{"Name":"天津佐伊影业有限公司","Id":49567}]  ← Id 是**数字**
//   Tags    = null(这台全库一条都没有)
// Jellyfin 那边 Id 是 GUID 字符串。声明成任何一种都会在另一家上解析失败,
// 而失败的表现是**整个条目解析报错**,不是少一个字段。
func Test工作室与标签的解析(t *testing.T) {
	body := `{"Items":[
      {"Id":"a","Name":"数字id","Type":"Movie","Studios":[{"Name":"天津佐伊","Id":49567}],"Tags":null},
      {"Id":"b","Name":"GUID","Type":"Movie","Studios":[{"Name":"某社","Id":"7f3e-guid"}],"Tags":["国语","4K"]},
      {"Id":"c","Name":"空名字要丢掉","Type":"Movie","Studios":[{"Name":"","Id":1}]}
    ],"TotalRecordCount":3}`
	up := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		_, _ = w.Write([]byte(body))
	}))
	defer up.Close()

	c := NewClient("test")
	s := &Session{Server: up.URL, Token: "t", UserID: "u", DeviceID: "d"}
	page, err := c.Items(context.Background(), s, "lib", &ItemQuery{})
	if err != nil {
		t.Fatal(err)
	}
	got := page.Items
	if len(got) != 3 {
		t.Fatalf("要 3 条,得到 %d", len(got))
	}
	if len(got[0].Studios) != 1 || got[0].Studios[0].ID != "49567" || got[0].Studios[0].Name != "天津佐伊" {
		t.Fatalf("数字 id 没拉成字符串: %+v", got[0].Studios)
	}
	if len(got[1].Studios) != 1 || got[1].Studios[0].ID != "7f3e-guid" {
		t.Fatalf("GUID id 解析错了: %+v", got[1].Studios)
	}
	// null 和 [] 对前端是两件事:null 会让 `.length` 那一行整个炸掉
	if got[0].Tags == nil {
		t.Fatal("Tags 是 null 时没折成空数组")
	}
	if len(got[1].Tags) != 2 {
		t.Fatalf("标签没解出来: %+v", got[1].Tags)
	}
	// 没名字的画出来是个空 chip,点了还搜不出东西
	if len(got[2].Studios) != 0 {
		t.Fatalf("空名字的工作室没丢掉: %+v", got[2].Studios)
	}
}

// ☠ 标签和工作室原来**只发出去、不复筛**,而 needsLocalFilter 又把它们算作要复筛。
// 于是在无视这两个参数的服务器上,复筛一遍什么都没滤掉,整页不匹配的条目照样铺出来。
// 实测 2026-09-12:`Studios=<名字>` 在真 Emby 4.9.5 上返回全库 1673 条,
// 头几条的工作室完全对不上 —— 和 Genres 那条老账一模一样。
func Test服务端无视标签与工作室时要复筛(t *testing.T) {
	body := `{"Items":[
      {"Id":"命中","Type":"Movie","Studios":[{"Name":"甲社","Id":1}],"Tags":["国语"]},
      {"Id":"不该出现","Type":"Movie","Studios":[{"Name":"乙社","Id":2}],"Tags":["粤语"]}
    ],"TotalRecordCount":2}`
	up := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		_, _ = w.Write([]byte(body)) // 上游把筛选参数当空气,原样回两条
	}))
	defer up.Close()
	c := NewClient("test")
	s := &Session{Server: up.URL, Token: "t", UserID: "u", DeviceID: "d"}

	for _, q := range []*ItemQuery{{Studios: []string{"甲社"}}, {Tags: []string{"国语"}}} {
		page, err := c.Items(context.Background(), s, "lib", q)
		if err != nil {
			t.Fatal(err)
		}
		if len(page.Items) != 1 || page.Items[0].ID != "命中" {
			t.Fatalf("%+v:复筛没滤掉不匹配的条目,得到 %d 条", q, len(page.Items))
		}
		// total 也得跟着改,否则界面上「共 2 条」而只画得出 1 条
		if page.Total != 1 {
			t.Fatalf("%+v:total 没跟着复筛改(=%d)", q, page.Total)
		}
	}
}

// 工作室**只有按 id 才筛得动**:实测 `Studios=<名字>` 被无视、`StudioIds=49567` 命中 1 条。
func Test按工作室id筛要发StudioIds(t *testing.T) {
	seen := ""
	up := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		seen = r.URL.RawQuery
		_, _ = w.Write([]byte(`{"Items":[],"TotalRecordCount":0}`))
	}))
	defer up.Close()
	c := NewClient("test")
	s := &Session{Server: up.URL, Token: "t", UserID: "u", DeviceID: "d"}
	if _, err := c.Items(context.Background(), s, "lib",
		&ItemQuery{StudioIds: []string{"49567", "66089"}}); err != nil {
		t.Fatal(err)
	}
	if !contains2(seen, "StudioIds=49567%2C66089") && !contains2(seen, "StudioIds=49567,66089") {
		t.Fatalf("没发 StudioIds,实际 query: %s", seen)
	}
}

func contains2(s, sub string) bool {
	for i := 0; i+len(sub) <= len(s); i++ {
		if s[i:i+len(sub)] == sub {
			return true
		}
	}
	return false
}
