package segments

import (
	"context"
	"net/http"
	"net/http/httptest"
	"testing"
)

// 三个源的假服务器。每个只回一份写死的 body,路径和 query 由各用例自己断言。
func fake(t *testing.T, h http.HandlerFunc) *httptest.Server {
	t.Helper()
	s := httptest.NewServer(h)
	t.Cleanup(s.Close)
	return s
}

func reset() { Clear() }

func TestIntroDB读秒字段(t *testing.T) {
	reset()
	var gotQuery string
	s := fake(t, func(w http.ResponseWriter, r *http.Request) {
		gotQuery = r.URL.RawQuery
		_, _ = w.Write([]byte(`{"imdb_id":"tt1","season":1,"episode":2,
			"intro":{"start_ms":30000,"end_ms":90000,"start_sec":30,"end_sec":90},
			"recap":null,"outro":null}`))
	})
	introDBBase = s.URL
	r, err := introDB(context.Background(), Meta{IMDb: "tt1", Season: 1, Episode: 2, RuntimeSecs: 1400})
	if err != nil {
		t.Fatal(err)
	}
	if r == nil || r.Intro == nil || r.Intro.Start != 30 || r.Intro.End != 90 {
		t.Fatalf("片头没解出来: %+v", r)
	}
	if r.Outro != nil {
		t.Fatal("outro 是 null,不该造出一个区间")
	}
	for _, want := range []string{"imdb_id=tt1", "season=1", "episode=2"} {
		if !contains(gotQuery, want) {
			t.Fatalf("请求少了 %s,实际 %s", want, gotQuery)
		}
	}
}

// 电影和缺季集号时**根本不该发请求** —— IntroDB 只有电视剧,发了也是白发一趟。
func TestIntroDB电影不发请求(t *testing.T) {
	reset()
	hit := false
	s := fake(t, func(w http.ResponseWriter, r *http.Request) { hit = true })
	introDBBase = s.URL
	if _, err := introDB(context.Background(), Meta{IMDb: "tt1", IsMovie: true}); err != nil {
		t.Fatal(err)
	}
	if hit {
		t.Fatal("电影也去问 IntroDB 了")
	}
}

func TestTheIntroDB片尾叫credits且null结束等于片尾(t *testing.T) {
	reset()
	s := fake(t, func(w http.ResponseWriter, r *http.Request) {
		_, _ = w.Write([]byte(`{"tmdb_id":1,"type":"tv","season":1,"episode":1,
			"intro":[{"start_ms":30000,"end_ms":90000}],
			"credits":[{"start_ms":5801777,"end_ms":null}]}`))
	})
	theIntroDBBase = s.URL
	r, err := theIntroDB(context.Background(), Meta{TMDb: "1", Season: 1, Episode: 1, RuntimeSecs: 6000})
	if err != nil {
		t.Fatal(err)
	}
	if r.Intro == nil || r.Intro.End != 90 {
		t.Fatalf("intro 解错: %+v", r.Intro)
	}
	// end_ms 是 null 表示「一直到片尾」。当成 0 的话区间反过来,sane 会把它整个丢掉
	if r.Outro == nil || r.Outro.End != 6000 {
		t.Fatalf("credits 的 null 结束没落到片长上: %+v", r.Outro)
	}
}

func TestAniSkip必带episodeLength且认found(t *testing.T) {
	reset()
	var gotQuery, gotPath string
	s := fake(t, func(w http.ResponseWriter, r *http.Request) {
		gotQuery, gotPath = r.URL.RawQuery, r.URL.Path
		_, _ = w.Write([]byte(`{"statusCode":200,"message":"ok","found":true,"results":[
			{"interval":{"startTime":60,"endTime":150},"skipType":"op","skipId":"x","episodeLength":1440},
			{"interval":{"startTime":1380,"endTime":1440},"skipType":"ed","skipId":"y","episodeLength":1440}]}`))
	})
	aniSkipBase = s.URL
	r, err := aniSkip(context.Background(), Meta{MAL: "20", Episode: 3, RuntimeSecs: 1440})
	if err != nil {
		t.Fatal(err)
	}
	if !contains(gotQuery, "episodeLength=") {
		t.Fatalf("episodeLength 是必填,漏了整条请求会 400。实际 query: %s", gotQuery)
	}
	if gotPath != "/skip-times/20/3" {
		t.Fatalf("路径不对: %s", gotPath)
	}
	if r.Intro == nil || r.Intro.Start != 60 || r.Outro == nil || r.Outro.Start != 1380 {
		t.Fatalf("op/ed 没映射到片头片尾: %+v", r)
	}
}

// found=false 时 results 可能仍是空数组,HTTP 也是 200 —— 只看 HTTP 码会把它当成有数据
func TestAniSkipFound为假当没有(t *testing.T) {
	reset()
	s := fake(t, func(w http.ResponseWriter, r *http.Request) {
		_, _ = w.Write([]byte(`{"statusCode":404,"message":"not found","found":false,"results":[]}`))
	})
	aniSkipBase = s.URL
	r, err := aniSkip(context.Background(), Meta{MAL: "20", Episode: 3, RuntimeSecs: 1440})
	if err != nil || r != nil {
		t.Fatalf("found=false 该当成没有数据,实得 r=%+v err=%v", r, err)
	}
}

// 限流必须是**错误**,不能被吞成「没有数据」——
// 吞掉的后果是整天被限流而界面上一直显示「这一集没有片头数据」。
func TestGet限流不当成没有数据(t *testing.T) {
	reset()
	s := fake(t, func(w http.ResponseWriter, r *http.Request) {
		w.WriteHeader(http.StatusTooManyRequests)
	})
	b, err := get(context.Background(), s.URL)
	if err == nil {
		t.Fatal("429 必须报错")
	}
	if b != nil {
		t.Fatal("429 不该带回 body")
	}
}

func TestGet404是没有数据不是错误(t *testing.T) {
	reset()
	s := fake(t, func(w http.ResponseWriter, r *http.Request) {
		w.WriteHeader(http.StatusNotFound)
	})
	b, err := get(context.Background(), s.URL)
	if err != nil || b != nil {
		t.Fatalf("404 该是「查过,没有」,实得 b=%v err=%v", b, err)
	}
}

// 片头从一个源来、片尾从另一个源来 —— 这正是「三个源提高成功率」的意义
func TestLookup跨源拼接(t *testing.T) {
	reset()
	a := fake(t, func(w http.ResponseWriter, r *http.Request) {
		_, _ = w.Write([]byte(`{"intro":{"start_sec":10,"end_sec":100},"outro":null}`))
	})
	b := fake(t, func(w http.ResponseWriter, r *http.Request) {
		_, _ = w.Write([]byte(`{"credits":[{"start_ms":1000000,"end_ms":1200000}]}`))
	})
	introDBBase, theIntroDBBase = a.URL, b.URL
	got := Lookup(context.Background(), Meta{
		IMDb: "tt1", TMDb: "9", Season: 1, Episode: 1, RuntimeSecs: 1400,
	})
	if got == nil || got.Intro == nil || got.Outro == nil {
		t.Fatalf("两段没拼齐: %+v", got)
	}
	if got.From != "IntroDB + TheIntroDB" {
		t.Fatalf("出处该记两个源,实得 %q", got.From)
	}
}

func TestLookup全空回nil(t *testing.T) {
	reset()
	empty := fake(t, func(w http.ResponseWriter, r *http.Request) {
		w.WriteHeader(http.StatusNotFound)
	})
	introDBBase, theIntroDBBase, aniSkipBase = empty.URL, empty.URL, empty.URL
	if got := Lookup(context.Background(), Meta{IMDb: "tt1", Season: 1, Episode: 1}); got != nil {
		t.Fatalf("一个源都没数据时该回 nil,实得 %+v", got)
	}
}

// 一集查过就别再查:连播时同一集会被起播路径问好几次
func TestLookup走缓存(t *testing.T) {
	reset()
	n := 0
	s := fake(t, func(w http.ResponseWriter, r *http.Request) {
		n++
		_, _ = w.Write([]byte(`{"intro":{"start_sec":10,"end_sec":100},"outro":{"start_sec":1300,"end_sec":1400}}`))
	})
	introDBBase = s.URL
	m := Meta{IMDb: "tt7", Season: 2, Episode: 5, RuntimeSecs: 1400}
	_ = Lookup(context.Background(), m)
	_ = Lookup(context.Background(), m)
	if n != 1 {
		t.Fatalf("同一集问了 %d 次,缓存没生效", n)
	}
}

func TestSane挡掉不合理区间(t *testing.T) {
	cases := []struct {
		name string
		r    *Range
		rt   float64
	}{
		{"倒着的", &Range{100, 30}, 1400},
		{"负的", &Range{-5, 100}, 1400},
		{"超出片长", &Range{100, 9999}, 1400},
		{"短于三秒", &Range{100, 102}, 1400},
	}
	for _, c := range cases {
		if got := sane(c.r, c.rt); got != nil {
			t.Fatalf("%s 该被挡掉,实得 %+v", c.name, got)
		}
	}
	if sane(&Range{30, 90}, 1400) == nil {
		t.Fatal("正常区间被误挡")
	}
}

func contains(s, sub string) bool {
	for i := 0; i+len(sub) <= len(s); i++ {
		if s[i:i+len(sub)] == sub {
			return true
		}
	}
	return false
}
