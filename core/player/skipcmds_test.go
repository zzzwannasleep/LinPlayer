package player

import (
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"strings"
	"sync/atomic"
	"testing"

	"linplayer/core/config"
	"linplayer/core/paths"
	"linplayer/core/segments"
)

/*
片头片尾三层来源的优先级:手动设定 > 服务端章节 > 第三方库。

★ 这三层**只有端到端才验得出来**:每一层单独看都对,错的是它们的先后 ——
  而先后错了的表现是「我明明手动量过了,它还是按网上那份跳」,不报错。
*/

// fakeEmby 一台只回答两种问题的假服务器:要章节的、要条目元数据的。
func fakeEmby(t *testing.T, hits *atomic.Int64) *httptest.Server {
	t.Helper()
	s := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if hits != nil {
			hits.Add(1)
		}
		id := r.URL.Path[strings.LastIndex(r.URL.Path, "/")+1:]
		w.Header().Set("Content-Type", "application/json")
		// Chapters() 只要 Fields=Chapters,这里给空表 = 这个库没刮过章节
		if r.URL.Query().Get("Fields") == "Chapters" {
			_, _ = w.Write([]byte(`{"Id":"` + id + `","Chapters":[]}`))
			return
		}
		if id == "s1" {
			// 剧级条目才带外部 id —— 分集上往往只有一个分集号
			_, _ = w.Write([]byte(`{"Id":"s1","Name":"某剧","Type":"Series",
				"ProviderIds":{"Imdb":"tt0903747","Tmdb":"1396"}}`))
			return
		}
		_, _ = w.Write([]byte(`{"Id":"` + id + `","Name":"第 1 集","Type":"Episode",
			"SeriesId":"s1","IndexNumber":1,"ParentIndexNumber":1,
			"RunTimeTicks":14000000000,"ProviderIds":{}}`))
	}))
	t.Cleanup(s.Close)
	return s
}

func fakeIntroDB(t *testing.T, hits *atomic.Int64) *httptest.Server {
	t.Helper()
	s := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if hits != nil {
			hits.Add(1)
		}
		_, _ = w.Write([]byte(`{"imdb_id":"tt0903747","season":1,"episode":1,
			"intro":{"start_ms":30000,"end_ms":90000,"start_sec":30,"end_sec":90},
			"recap":null,"outro":null}`))
	}))
	t.Cleanup(s.Close)
	return s
}

func setSkipPrefs(t *testing.T, intro, outro, auto, online bool) {
	t.Helper()
	c := config.Current()
	p := c.PrefsOf()
	p.SkipIntro, p.SkipOutro, p.SkipAuto, p.SkipUseOnline = intro, outro, auto, online
	if err := c.SetPrefs(p); err != nil {
		t.Fatal(err)
	}
}

func chapterInfoOf(t *testing.T, seq int64, server string) map[string]any {
	t.Helper()
	r := call(t, seq, "player.chapterInfo", map[string]any{
		"server": server, "token": "tk", "user_id": "u1", "device_id": "d1",
		"item_id": "e1", "runtime_secs": 1400.0,
	})
	if !r.OK {
		t.Fatalf("chapterInfo 失败: %s %s", r.Code, r.Msg)
	}
	var out map[string]any
	if err := json.Unmarshal(r.Data, &out); err != nil {
		t.Fatal(err)
	}
	return out
}

func introOf(m map[string]any) (float64, float64, bool) {
	v, ok := m["intro"].(map[string]any)
	if !ok {
		return 0, 0, false
	}
	a, _ := v["start"].(float64)
	b, _ := v["end"].(float64)
	return a, b, true
}

// 服务端没刮章节时,第三方库要能把片头补上 —— 这正是加这三个源的理由。
func TestChapterInfo没章节时用第三方库补(t *testing.T) {
	paths.SetRoot(t.TempDir())
	if _, err := config.Load(); err != nil {
		t.Fatal(err)
	}
	emby := fakeEmby(t, nil)
	idb := fakeIntroDB(t, nil)
	defer segments.SetEndpointsForTest(idb.URL, idb.URL, idb.URL)()
	setSkipPrefs(t, true, true, false, true)

	got := chapterInfoOf(t, 9001, emby.URL)
	a, b, ok := introOf(got)
	if !ok || a != 30 || b != 90 {
		t.Fatalf("第三方库那一层没接上: %+v", got)
	}
	if src, _ := got["skip_source"].(string); src != "IntroDB" {
		t.Fatalf("出处该说清楚是谁给的,实得 %q", src)
	}
}

// 关掉联网就**一个请求都不该发**。发了才是问题:那是用户明确关掉的外网访问。
func TestChapterInfo关了联网就不发请求(t *testing.T) {
	paths.SetRoot(t.TempDir())
	if _, err := config.Load(); err != nil {
		t.Fatal(err)
	}
	emby := fakeEmby(t, nil)
	var idbHits atomic.Int64
	idb := fakeIntroDB(t, &idbHits)
	defer segments.SetEndpointsForTest(idb.URL, idb.URL, idb.URL)()
	setSkipPrefs(t, true, true, false, false)

	got := chapterInfoOf(t, 9002, emby.URL)
	if _, _, ok := introOf(got); ok {
		t.Fatalf("关了联网还查到了片头: %+v", got)
	}
	if n := idbHits.Load(); n != 0 {
		t.Fatalf("关了联网仍然打了 %d 次第三方接口", n)
	}
}

// 手动设定压过第三方库,而且**压过之后就不必再联网** ——
// 用户量都量过了,再去问一次网上那份是白发一趟。
func TestChapterInfo手动设定压过第三方(t *testing.T) {
	paths.SetRoot(t.TempDir())
	if _, err := config.Load(); err != nil {
		t.Fatal(err)
	}
	emby := fakeEmby(t, nil)
	var idbHits atomic.Int64
	idb := fakeIntroDB(t, &idbHits)
	defer segments.SetEndpointsForTest(idb.URL, idb.URL, idb.URL)()
	setSkipPrefs(t, true, false, false, true)

	r := call(t, 9003, "player.setSkipRange", map[string]any{
		"server": emby.URL, "token": "tk", "user_id": "u1", "device_id": "d1",
		"item_id": "e1", "intro_start": 5.0, "intro_end": 25.0,
		"outro_start": 0.0, "outro_end": 0.0,
	})
	if !r.OK {
		t.Fatalf("设不上: %s %s", r.Code, r.Msg)
	}

	got := chapterInfoOf(t, 9004, emby.URL)
	a, b, ok := introOf(got)
	if !ok || a != 5 || b != 25 {
		t.Fatalf("手动设定没压过第三方: %+v", got)
	}
	if src, _ := got["skip_source"].(string); src != "手动设定" {
		t.Fatalf("出处该是手动设定,实得 %q", src)
	}
	if n := idbHits.Load(); n != 0 {
		t.Fatalf("手动设过了还去问了 %d 次第三方", n)
	}
}

// 存的键按**剧**算:同一部剧的第二集不用再设一遍。
func TestSetSkipRange按剧存(t *testing.T) {
	paths.SetRoot(t.TempDir())
	if _, err := config.Load(); err != nil {
		t.Fatal(err)
	}
	emby := fakeEmby(t, nil)
	r := call(t, 9005, "player.setSkipRange", map[string]any{
		"server": emby.URL, "token": "tk", "user_id": "u1", "device_id": "d1",
		"item_id": "e1", "intro_start": 0.0, "intro_end": 60.0,
		"outro_start": 0.0, "outro_end": 0.0,
	})
	if !r.OK {
		t.Fatalf("设不上: %s %s", r.Code, r.Msg)
	}
	var out struct {
		Key string `json:"key"`
	}
	if err := json.Unmarshal(r.Data, &out); err != nil {
		t.Fatal(err)
	}
	if !strings.HasSuffix(out.Key, "|s1") {
		t.Fatalf("键该落在剧上(|s1),实得 %q —— 按集存的话用户得为每一集设一遍", out.Key)
	}
	// 第二集查出来应当是同一条
	r2 := call(t, 9006, "player.getSkipRange", map[string]any{
		"server": emby.URL, "token": "tk", "user_id": "u1", "device_id": "d1",
		"item_id": "e2",
	})
	if !r2.OK {
		t.Fatalf("查不到: %s %s", r2.Code, r2.Msg)
	}
	if !strings.Contains(string(r2.Data), `"intro_end":60`) {
		t.Fatalf("同一部剧的第二集没继承设定: %s", r2.Data)
	}
}

// 结束早于开始要**拒**,不能悄悄夹紧:夹紧之后用户看到「已保存」,存的却是别的值。
func TestSetSkipRange倒着的区间要拒(t *testing.T) {
	paths.SetRoot(t.TempDir())
	if _, err := config.Load(); err != nil {
		t.Fatal(err)
	}
	emby := fakeEmby(t, nil)
	r := call(t, 9007, "player.setSkipRange", map[string]any{
		"server": emby.URL, "token": "tk", "user_id": "u1", "device_id": "d1",
		"item_id": "e1", "intro_start": 90.0, "intro_end": 30.0,
		"outro_start": 0.0, "outro_end": 0.0,
	})
	if r.OK {
		t.Fatal("结束早于开始还存下来了")
	}
}
