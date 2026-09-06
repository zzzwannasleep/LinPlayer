package aggregate

import (
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"os"
	"strings"
	"testing"
	"time"

	"linplayer/core/bus"
	"linplayer/core/config"
	"linplayer/core/paths"
)

func TestMain(m *testing.M) {
	bus.Init()
	RegisterCommands("test")
	os.Exit(m.Run())
}

func call(t *testing.T, seq int64, cmd string, args map[string]any, out any) {
	t.Helper()
	b, _ := json.Marshal(args)
	if err := bus.Call(seq, cmd, string(b)); err != nil {
		t.Fatalf("发命令失败: %v", err)
	}
	deadline := time.Now().Add(10 * time.Second)
	for time.Now().Before(deadline) {
		ev := bus.NextEvent(200)
		if len(ev) == 0 {
			continue
		}
		var e struct {
			T    string          `json:"t"`
			Seq  int64           `json:"seq"`
			Data json.RawMessage `json:"data"`
			Err  *struct {
				Code, Msg string
			} `json:"err"`
		}
		if json.Unmarshal(ev, &e) != nil || e.T != "result" || e.Seq != seq {
			continue
		}
		if e.Err != nil {
			t.Fatalf("%s 报错: %s %s", cmd, e.Err.Code, e.Err.Msg)
		}
		if err := json.Unmarshal(e.Data, out); err != nil {
			t.Fatalf("解不动返回体: %v\n%s", err, e.Data)
		}
		return
	}
	t.Fatalf("等不到 %s 的 result", cmd)
}

// embyServer 起一台假 Emby。searchHits 是搜索要回的条目名。
func embyServer(t *testing.T, name string, searchHits []string, brokenCounts bool) *httptest.Server {
	t.Helper()
	s := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		switch {
		case strings.Contains(r.URL.Path, "/Items/Counts"):
			if brokenCounts {
				w.WriteHeader(404) // 某些 fork 上这个端点就是没有的
				return
			}
			_, _ = w.Write([]byte(`{"MovieCount":3,"SeriesCount":2,"EpisodeCount":9,"BoxSetCount":1}`))
		case strings.Contains(r.URL.Path, "/Items/Resume"):
			_, _ = w.Write([]byte(`{"Items":[{"Id":"r1","Name":"继续看的","Type":"Episode"}],"TotalRecordCount":1}`))
		default: // 搜索
			items := make([]string, 0, len(searchHits))
			for i, n := range searchHits {
				items = append(items, `{"Id":"`+name+`-`+string(rune('a'+i))+`","Name":"`+n+`","Type":"Movie"}`)
			}
			_, _ = w.Write([]byte(`{"Items":[` + strings.Join(items, ",") + `],"TotalRecordCount":` +
				string(rune('0'+len(items))) + `}`))
		}
	}))
	t.Cleanup(s.Close)
	return s
}

func setup(t *testing.T) *config.AppConfig {
	t.Helper()
	paths.SetRoot(t.TempDir())
	c, err := config.Load()
	if err != nil {
		t.Fatal(err)
	}
	return c
}

// ★★ 必须走**生效线路**,不能用账号主键。
//
// 用户切到备用线正是因为主线不通 —— 打主线的结果是那台服务器静默变成
// 「零条目」,从聚合里消失,查都没处查。
//
// 这条测试的形状:主线指向一个**根本起不来**的地址,备用线指向真服务器。
// 用主键的实现会拿不到任何结果,用生效线路的能拿到。
func TestAggregate必须走生效线路(t *testing.T) {
	c := setup(t)
	up := embyServer(t, "s1", []string{"某片"}, false)

	acc := config.Account{Server: "http://127.0.0.1:1", Token: "t", UserID: "u"} // 主键:连不上
	acc.Lines = []config.ServerLine{
		{ID: "main", Name: "主线", URL: "http://127.0.0.1:1"},
		{ID: "alt", Name: "备线", URL: up.URL},
	}
	acc.ActiveLine = 1 // 用户切到了备用线
	c.Upsert(acc)
	if err := c.Save(); err != nil {
		t.Fatal(err)
	}

	var groups []ServerGroup
	call(t, 101, "emby.aggregateSearch", map[string]any{"query": "某"}, &groups)
	if len(groups) != 1 || len(groups[0].Items) != 1 {
		t.Fatalf("该走备用线拿到结果,实得 %+v —— 用主键的话这台服会从聚合里静默消失", groups)
	}
	// ★ 名字只放服务器名,不许拼「账户名 @ 地址」
	if strings.ContainsAny(groups[0].ServerName, "@") {
		t.Fatalf("server_name 里不该有账户名/地址:%q —— 调用方拆不开", groups[0].ServerName)
	}
}

// 单台失败隔离:一台连不上不该让整个搜索报错 —— 但**要说出来**。
//
// ☠ 这条判据 2026-09-06 改过:以前失败的那台**整条被丢掉**,
// 于是「这台没有这部片」和「这台压根没搜成」在调用方看来一模一样,
// 半失败(一路 429 一路回空)被吞成「没搜到」。现在失败的那台照样出一条,
// Items 空 + Error 非空。
func TestAggregateSearch单台失败隔离(t *testing.T) {
	c := setup(t)
	good := embyServer(t, "good", []string{"某片"}, false)
	c.Upsert(config.Account{Server: good.URL, Token: "t", UserID: "u"})
	c.Upsert(config.Account{Server: "http://127.0.0.1:1", Token: "t", UserID: "u"}) // 连不上
	if err := c.Save(); err != nil {
		t.Fatal(err)
	}

	var groups []ServerGroup
	call(t, 201, "emby.aggregateSearch", map[string]any{"query": "某"}, &groups)
	if len(groups) != 2 {
		t.Fatalf("好的那台出结果、坏的那台出错误,共两条,实得 %+v", groups)
	}
	ok, bad := groups[0], groups[1]
	if ok.ServerID != good.URL || len(ok.Items) == 0 || ok.Error != nil {
		t.Fatalf("能连的那台该照出结果且无错误,实得 %+v", ok)
	}
	if bad.Error == nil || *bad.Error == "" {
		t.Fatalf("连不上的那台必须带出错原因,否则调用方分不清「没有」和「没搜成」,实得 %+v", bad)
	}
	if len(bad.Items) != 0 {
		t.Fatalf("带 Error 时 Items 必须为空,实得 %+v", bad)
	}
}

// 空关键词 / 没有账号 → 空表,不报错也不打服务器。
func TestAggregateSearch空关键词(t *testing.T) {
	c := setup(t)
	hit := false
	up := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		hit = true
		_, _ = w.Write([]byte(`{"Items":[]}`))
	}))
	defer up.Close()
	c.Upsert(config.Account{Server: up.URL, Token: "t", UserID: "u"})
	if err := c.Save(); err != nil {
		t.Fatal(err)
	}

	var groups []ServerGroup
	call(t, 301, "emby.aggregateSearch", map[string]any{"query": "   "}, &groups)
	if len(groups) != 0 {
		t.Fatalf("空关键词该给空表,实得 %+v", groups)
	}
	if hit {
		t.Fatal("空关键词不该打服务器")
	}
}

// 聚合视界:统计端点 404 时**这张卡照出**,只是数字为 0。
//
// ★ /Items/Counts 在某些 fork 上就是没有的。让它拖垮整页 = 那台服的用户
// 连聚合视界都打不开。
func TestAggregateOverview统计挂了卡还在(t *testing.T) {
	c := setup(t)
	broken := embyServer(t, "broken", nil, true)
	c.Upsert(config.Account{Server: broken.URL, Token: "t", UserID: "u"})
	if err := c.Save(); err != nil {
		t.Fatal(err)
	}

	var cards []SourceOverview
	call(t, 401, "emby.aggregateOverview", nil, &cards)
	if len(cards) != 1 {
		t.Fatalf("该有一张卡,实得 %+v", cards)
	}
	if cards[0].Counts.Movie != 0 {
		t.Fatalf("统计端点 404 时数字该是 0,实得 %+v", cards[0].Counts)
	}
	// 但「继续观看」照拉到 —— 两者各自吞错
	if len(cards[0].Resume) != 1 {
		t.Fatalf("统计挂了不该连继续观看一起没了,实得 %+v", cards[0].Resume)
	}
	if !cards[0].Active {
		t.Fatal("唯一的账号该标成 active")
	}
}

// 浏览型源(网盘 / 局域网)不打 Emby 接口,但卡要在。
func TestAggregateOverview浏览型源(t *testing.T) {
	c := setup(t)
	hit := false
	up := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		hit = true
	}))
	defer up.Close()

	var acc config.Account
	if err := json.Unmarshal([]byte(`{"server":"`+up.URL+`","source_kind":"local","user_id":"u"}`), &acc); err != nil {
		t.Fatal(err)
	}
	c.Upsert(acc)
	if err := c.Save(); err != nil {
		t.Fatal(err)
	}

	var cards []SourceOverview
	call(t, 501, "emby.aggregateOverview", nil, &cards)
	if len(cards) != 1 || !cards[0].IsFileBrowse || cards[0].SourceKind != "local" {
		t.Fatalf("浏览型源的卡不对: %+v", cards)
	}
	if hit {
		t.Fatal("浏览型源不该去打 Emby 接口")
	}
	// 空切片不是 null:调用方直接 .map() 拿到 null 会抛错
	if cards[0].Resume == nil {
		t.Fatal("resume 要给空数组不是 null")
	}
}

// 结果按**账号表顺序**排,不按谁先返回 —— 否则每次搜索服务器顺序都在跳。
func TestAggregateSearch顺序稳定(t *testing.T) {
	c := setup(t)
	// 第一台故意慢一点
	slow := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		time.Sleep(150 * time.Millisecond)
		_, _ = w.Write([]byte(`{"Items":[{"Id":"a","Name":"某片","Type":"Movie"}],"TotalRecordCount":1}`))
	}))
	defer slow.Close()
	fast := embyServer(t, "fast", []string{"某片"}, false)

	c.Upsert(config.Account{Server: slow.URL, Token: "t", UserID: "u"})
	c.Upsert(config.Account{Server: fast.URL, Token: "t", UserID: "u"})
	if err := c.Save(); err != nil {
		t.Fatal(err)
	}

	for i := 0; i < 3; i++ {
		var groups []ServerGroup
		call(t, int64(600+i), "emby.aggregateSearch", map[string]any{"query": "某"}, &groups)
		if len(groups) != 2 || groups[0].ServerID != slow.URL {
			t.Fatalf("第 %d 次:顺序该跟账号表,实得 %v", i, []string{groups[0].ServerID})
		}
	}
}
