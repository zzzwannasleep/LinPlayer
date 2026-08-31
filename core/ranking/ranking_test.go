package ranking

// 这个包的判据几乎全是**「失败的时候说不说得清」**。
//
// 2026-07-21 用户报「榜单没数据」:当时 5 种成因(缺凭据 / 请求失败 / 非 JSON /
// success=false / 缺字段)全部 `return vec![]`,长得一模一样。查了很久才发现是
// 安卓 CI 压根没传 DANDANPLAY_*。所以下面每一条都在钉「错误信息里有没有那句关键词」。

import (
	"context"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"

	"linplayer/core/paths"
)

func fresh(t *testing.T) {
	t.Helper()
	paths.SetRoot(t.TempDir()) // 缓存目录隔离,别让上一条用例的缓存喂给下一条
}

// ★ 分类表本身要自洽:每条恰有对应源的路径,id 不重复。
func TestCategories自洽(t *testing.T) {
	seen := map[string]bool{}
	for _, c := range Categories {
		switch c.Source {
		case SourceDandan:
			if c.DandanPath == nil || c.TMDBPath != nil {
				t.Fatalf("%s 是弹弹源,却没有弹弹路径或多了 TMDB 路径", c.ID)
			}
		case SourceTMDB:
			if c.TMDBPath == nil || c.DandanPath != nil {
				t.Fatalf("%s 是 TMDB 源,却没有 TMDB 路径或多了弹弹路径", c.ID)
			}
		default:
			t.Fatalf("%s 的来源不认识: %q", c.ID, c.Source)
		}
		if seen[c.ID] {
			t.Fatalf("分类 id 重复: %s", c.ID)
		}
		seen[c.ID] = true
	}
}

// ★★ 未知分类必须**点名那个 id**。
//
// 只说「没找到」的话,拼错一个字母和「这个榜下线了」看起来一模一样。
func TestFetch未知分类要点名(t *testing.T) {
	fresh(t)
	_, err := Fetch(context.Background(), "no-such-category", true)
	if err == nil {
		t.Fatal("未知分类居然成功了")
	}
	if !strings.Contains(err.Error(), "no-such-category") {
		t.Fatalf("错误信息没点名分类: %v", err)
	}
}

// ★★ 没凭据必须**明说缺哪个环境变量**。
//
// 这条是当年那次事故的正解:根因是 CI 没传 DANDANPLAY_*,而现象只有「空榜」。
// 把变量名写进错误里,看一眼就知道去 CI 里补哪个。
func TestFetch没凭据要说缺哪个变量(t *testing.T) {
	fresh(t)
	if !AnimeConfigured() {
		_, err := Fetch(context.Background(), "anime_hot_week", true)
		if err == nil {
			t.Fatal("没有弹弹凭据却成功了")
		}
		if !strings.Contains(err.Error(), "DANDANPLAY_APP_ID") {
			t.Fatalf("没指明缺哪个变量: %v", err)
		}
	}
	if !VideoConfigured() {
		_, err := Fetch(context.Background(), "movie_popular", true)
		if err == nil {
			t.Fatal("没有 TMDB 密钥却成功了")
		}
		if !strings.Contains(err.Error(), "TMDB_API_KEY") {
			t.Fatalf("没指明缺哪个变量: %v", err)
		}
	}
}

// ★ 没凭据 → 不亮那一族分类。亮出来点进去必然是空的,用户只会以为播放器坏了。
func TestAvailable没凭据就不亮(t *testing.T) {
	got := Available()
	if got == nil {
		t.Fatal("返回了 nil —— 序列化成 JSON 是 null,前端 .map() 直接抛,透明窗口下就是一片黑")
	}
	if !AnimeConfigured() && !VideoConfigured() && len(got) != 0 {
		t.Fatalf("两源都没凭据,却亮了 %d 个分类", len(got))
	}
	for _, c := range got {
		if c.Source == SourceDandan && !AnimeConfigured() {
			t.Fatalf("没有弹弹凭据却亮了 %s", c.ID)
		}
		if c.Source == SourceTMDB && !VideoConfigured() {
			t.Fatalf("没有 TMDB 密钥却亮了 %s", c.ID)
		}
	}
}

// ---- 下面几条要绕过「没凭据」那一关,直接验**服务端拒绝**时的表现 ----

func fakeUpstream(t *testing.T, status int, body string) *httptest.Server {
	t.Helper()
	s := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "application/json")
		w.WriteHeader(status)
		_, _ = w.Write([]byte(body))
	}))
	t.Cleanup(s.Close)
	return s
}

// ★★ TMDB 拒绝时必须把 status_message 带出来。
//
// 密钥过期 / 超配额都走这条,而它们的处置办法完全不同 —— 吞成空榜就分不出来。
func TestFetchTMDB拒绝时要带出服务端的话(t *testing.T) {
	fresh(t)
	up := fakeUpstream(t, 401, `{"status_message":"Invalid API key: You must be granted a valid key."}`)
	defer setBasesForTest("", up.URL)()

	cat := byID("movie_popular")
	_, err := fetchTMDBWithKey(context.Background(), cat, "deadbeef")
	if err == nil {
		t.Fatal("服务端 401 却当成功了")
	}
	if !strings.Contains(err.Error(), "Invalid API key") {
		t.Fatalf("没把服务端说的话带出来: %v", err)
	}
	if !strings.Contains(err.Error(), "401") {
		t.Fatalf("没带 HTTP 状态码: %v", err)
	}
}

// ★★ TMDB 回了合法 JSON 但**没有 results** 时,不能当成「空榜」。
func TestFetchTMDB缺results不算空榜(t *testing.T) {
	fresh(t)
	up := fakeUpstream(t, 200, `{"page":1}`)
	defer setBasesForTest("", up.URL)()

	_, err := fetchTMDBWithKey(context.Background(), byID("movie_popular"), "deadbeef")
	if err == nil {
		t.Fatal("缺 results 却当成功了 —— 这正是「整页空白查不出原因」的来源")
	}
	if !strings.Contains(err.Error(), "results") {
		t.Fatalf("没说清缺什么: %v", err)
	}
}

// ★ 正常返回要解得出来,而且 rank 从 1 连续排。
func TestFetchTMDB正常解析(t *testing.T) {
	fresh(t)
	up := fakeUpstream(t, 200, `{"results":[
		{"id":1,"title":"某部电影","poster_path":"/a.jpg","vote_average":8.1,"release_date":"2024-05-01"},
		{"id":"2","title":"","name":"只有 name 的那种"},
		{"id":3,"title":"   "}
	]}`)
	defer setBasesForTest("", up.URL)()

	got, err := fetchTMDBWithKey(context.Background(), byID("movie_popular"), "deadbeef")
	if err != nil {
		t.Fatal(err)
	}
	if len(got) != 2 {
		t.Fatalf("应当解出 2 条(空标题那条丢掉),实得 %d", len(got))
	}
	if got[0].Rank != 1 || got[1].Rank != 2 {
		t.Fatalf("rank 不是从 1 连续排: %d %d —— 丢掉的那条不能在名次上留空", got[0].Rank, got[1].Rank)
	}
	if got[0].ImageURL == nil || !strings.HasSuffix(*got[0].ImageURL, "/a.jpg") {
		t.Fatalf("海报没拼全: %v", got[0].ImageURL)
	}
	if got[0].Subtitle == nil || *got[0].Subtitle != "2024" {
		t.Fatalf("年份没截出来: %v", got[0].Subtitle)
	}
	// ★ id 可能是数字也可能是字符串,两种都要吃得下
	if got[0].ID != "1" || got[1].ID != "2" {
		t.Fatalf("id 解析不对: %q %q", got[0].ID, got[1].ID)
	}
}

// ★★ 弹弹 success=false 时必须带出 errorCode + errorMessage。
//
// 实测整天 429 却显示「未找到」—— 那次的根因就是 errorCode 从来没人看。
func TestFetchDandan拒绝时要带出errorCode(t *testing.T) {
	fresh(t)
	up := fakeUpstream(t, 200, `{"success":false,"errorCode":429,"errorMessage":"请求过于频繁"}`)
	defer setBasesForTest(up.URL, "")()

	_, err := fetchDandanWithCreds(context.Background(), byID("anime_hot_week"), "id", "sec")
	if err == nil {
		t.Fatal("success=false 却当成功了")
	}
	if !strings.Contains(err.Error(), "429") || !strings.Contains(err.Error(), "请求过于频繁") {
		t.Fatalf("没带出 errorCode/errorMessage: %v —— 「整天 429 却显示未找到」就是这么来的", err)
	}
}

// ★ 缓存:同一分类第二次不该再打上游。
func TestFetch命中缓存不再打上游(t *testing.T) {
	fresh(t)
	hits := 0
	up := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		hits++
		w.Header().Set("Content-Type", "application/json")
		_, _ = w.Write([]byte(`{"results":[{"id":1,"title":"某部电影"}]}`))
	}))
	defer up.Close()
	defer setBasesForTest("", up.URL)()

	for i := 0; i < 3; i++ {
		if _, err := fetchWith(context.Background(), "movie_popular", i == 0, "", "", "deadbeef"); err != nil {
			t.Fatal(err)
		}
	}
	if hits != 1 {
		t.Fatalf("打了上游 %d 次,应当只有 1 次 —— 6 小时缓存没生效", hits)
	}
}
