package aggregate

import (
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"

	"linplayer/core/config"
)

// verServer 起一台假 Emby,只回聚合版本这条路上要用的几个端点。
//
// epID 为空表示「这台上没有这一集」—— 搜得到剧、但那一季里没有那个集号。
type verSpec struct {
	seriesID   string
	seriesName string
	tmdb       string
	season     int64
	episode    int64
	epID       string
	verName    string
}

func verServer(t *testing.T, sp verSpec) *httptest.Server {
	t.Helper()
	item := func(id, name, typ string) string {
		s := `{"Id":"` + id + `","Name":"` + name + `","Type":"` + typ + `"`
		if typ == "Episode" {
			s += `,"SeriesId":"` + sp.seriesID + `","SeriesName":"` + sp.seriesName + `"` +
				`,"ParentIndexNumber":` + itoa(sp.season) + `,"IndexNumber":` + itoa(sp.episode)
		}
		if typ == "Series" {
			s += `,"ProviderIds":{"Tmdb":"` + sp.tmdb + `"}`
		}
		return s + `}`
	}
	s := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		q := r.URL.Query()
		switch {
		case strings.HasSuffix(r.URL.Path, "/PlaybackInfo"):
			_, _ = w.Write([]byte(`{"MediaSources":[{"Id":"ms-` + sp.verName +
				`","Name":"` + sp.verName + `","Size":100,"MediaStreams":[]}]}`))
		case q.Get("IncludeItemTypes") == "Season":
			_, _ = w.Write([]byte(`{"Items":[{"Id":"sn","Name":"第 1 季","IndexNumber":` +
				itoa(sp.season) + `}],"TotalRecordCount":1}`))
		case q.Get("IncludeItemTypes") == "Episode":
			if sp.epID == "" {
				_, _ = w.Write([]byte(`{"Items":[],"TotalRecordCount":0}`))
				return
			}
			_, _ = w.Write([]byte(`{"Items":[` + item(sp.epID, "第 3 集", "Episode") + `],"TotalRecordCount":1}`))
		case q.Get("SearchTerm") != "":
			_, _ = w.Write([]byte(`{"Items":[` + item(sp.seriesID, sp.seriesName, "Series") + `],"TotalRecordCount":1}`))
		default: // 单条 Item(ItemForHistory)
			id := r.URL.Path[strings.LastIndex(r.URL.Path, "/")+1:]
			if id == sp.seriesID {
				_, _ = w.Write([]byte(item(sp.seriesID, sp.seriesName, "Series")))
				return
			}
			_, _ = w.Write([]byte(item(id, "第 3 集", "Episode")))
		}
	}))
	t.Cleanup(s.Close)
	return s
}

func itoa(v int64) string {
	if v < 10 {
		return string(rune('0' + v))
	}
	return string(rune('0'+v/10)) + string(rune('0'+v%10))
}

// 两台服上是同一集 → 两组都出,而且**每组带的是自己那台的 item_id**。
//
// ★ item_id 拿错是这个功能最凶的失败形态:用户选了 B 台的 4K,起播却拿 A 台的 id
// 去打 B ——404 或者放出另一部片,两边都不报错。
func TestAggregateVersions两台服的同一集要合成两组(t *testing.T) {
	c := setup(t)
	a := verServer(t, verSpec{"sa", "某剧", "9001", 1, 3, "ep-A", "1080p"})
	b := verServer(t, verSpec{"sb", "某剧", "9001", 1, 3, "ep-B", "2160p"})
	c.Upsert(config.Account{Server: a.URL, Token: "t", UserID: "u", Name: "甲"})
	c.Upsert(config.Account{Server: b.URL, Token: "t", UserID: "u", Name: "乙"})
	if err := c.Save(); err != nil {
		t.Fatal(err)
	}

	var groups []VersionGroup
	call(t, 901, "emby.aggregateVersions",
		map[string]any{"item_id": "ep-A", "server_id": a.URL}, &groups)

	if len(groups) != 2 {
		t.Fatalf("该出两台服的版本,实得 %d 组:%+v", len(groups), groups)
	}
	if !groups[0].Current || groups[0].ItemID != "ep-A" {
		t.Fatalf("本服那组该排头且是自己的 item_id,实得 %+v", groups[0])
	}
	if groups[1].Current || groups[1].ItemID != "ep-B" {
		t.Fatalf("别台那组必须带**那台**的 item_id,实得 %+v —— 拿错就是起播打到别处", groups[1])
	}
	if len(groups[1].Versions) != 1 || groups[1].Versions[0].Name != "2160p" {
		t.Fatalf("别台的版本表该是它自己的,实得 %+v", groups[1].Versions)
	}
	if groups[1].Reason == "" {
		t.Fatalf("跨服那组必须说清凭什么认为是同一部")
	}
}

// 另一台搜回来的是**别的剧** → 那台整组不出现,不许拿它的版本表冒充。
//
// ★ 这不是假想的:某 fork **带 SearchTerm 时忽略所有筛选参数**,吐回来的头几条
// 和关键词无关(2026-08-17 curl 实测)。照单全收的后果是「选了 2160p,
// 放出来是另一部片」,而从头到尾没有一个报错。
// ★ 候选池**非空**才测得到「宁可不给」那条规则 —— 用「这台上没有这一集」
// 当负例是测不到的:那条路在挑之前就返回了(2026-09-05 反向注入时发现)。
func TestAggregateVersions匹配不上就不给(t *testing.T) {
	c := setup(t)
	a := verServer(t, verSpec{"sc", "另一剧", "9002", 1, 3, "ep-A2", "1080p"})
	b := verServer(t, verSpec{"sd", "毫不相干的剧", "7777", 1, 3, "ep-B2", "2160p"})
	c.Upsert(config.Account{Server: a.URL, Token: "t", UserID: "u", Name: "甲"})
	c.Upsert(config.Account{Server: b.URL, Token: "t", UserID: "u", Name: "乙"})
	if err := c.Save(); err != nil {
		t.Fatal(err)
	}

	var groups []VersionGroup
	call(t, 902, "emby.aggregateVersions",
		map[string]any{"item_id": "ep-A2", "server_id": a.URL}, &groups)

	if len(groups) != 1 || !groups[0].Current {
		t.Fatalf("匹配不上的那台不该出现,实得 %+v", groups)
	}
}

// UI 报回来的 server_id 是**生效线路地址**(emby.currentSession 就是这么吐的),
// 不是账号主键。只按主键找的话,切了备用线的用户跨服选版本一台都出不来 ——
// 而他切备用线正是因为主线不通。
func TestAggregateVersions认线路地址不只认主键(t *testing.T) {
	c := setup(t)
	a := verServer(t, verSpec{"se", "第三剧", "9003", 1, 3, "ep-A3", "1080p"})
	acc := config.Account{Server: "http://127.0.0.1:1", Token: "t", UserID: "u", Name: "甲"}
	acc.Lines = []config.ServerLine{
		{ID: "main", Name: "主线", URL: "http://127.0.0.1:1"},
		{ID: "alt", Name: "备线", URL: a.URL},
	}
	acc.ActiveLine = 1
	c.Upsert(acc)
	if err := c.Save(); err != nil {
		t.Fatal(err)
	}

	var groups []VersionGroup
	// UI 手上的 server 就是这个 —— 备用线地址,不是账号主键
	call(t, 903, "emby.aggregateVersions",
		map[string]any{"item_id": "ep-A3", "server_id": a.URL}, &groups)

	if len(groups) != 1 || !groups[0].Current {
		t.Fatalf("按线路地址也该认得出这个账号,实得 %+v", groups)
	}
}
