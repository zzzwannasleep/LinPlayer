package emby

import (
	"context"
	"fmt"
	"net/http"
	"net/http/httptest"
	"net/url"
	"strings"
	"testing"
)

// Hero 只能放**有艺术字**的条目【用户定 2026-09-06】。
//
// 轮播五张里两张是 TMDB 艺术字、三张回落成排版标题,看着就像没做完 ——
// 用户原话:「不然视觉上不统一,很丑」。
//
// ☠ 服务端只保证「有剧照」:`ImageTypes` 多值在各 fork 上是 AND 还是 OR 不一致,
// 所以判据必须落在**拿回来之后**,不能指望查询参数。

// heroServer 造一台假 Emby:前 n 条只有剧照,后面几条剧照 + 艺术字都有。
func heroServer(t *testing.T, noLogo, withLogo int) (*httptest.Server, *int) {
	t.Helper()
	askedLimit := new(int)
	return httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if v := r.URL.Query().Get("Limit"); v != "" {
			_, _ = fmt.Sscanf(v, "%d", askedLimit)
		}
		var b strings.Builder
		b.WriteString(`{"Items":[`)
		first := true
		add := func(id string, logo bool) {
			if !first {
				b.WriteString(",")
			}
			first = false
			tags := `{"Primary":"p-` + id + `"}`
			if logo {
				tags = `{"Primary":"p-` + id + `","Logo":"lg-` + id + `"}`
			}
			fmt.Fprintf(&b, `{"Id":%q,"Name":%q,"Type":"Movie","ImageTags":%s,`+
				`"BackdropImageTags":["bd-%s"]}`, id, id, tags, id)
		}
		for i := 0; i < noLogo; i++ {
			add(fmt.Sprintf("plain-%d", i), false)
		}
		for i := 0; i < withLogo; i++ {
			add(fmt.Sprintf("art-%d", i), true)
		}
		b.WriteString(`],"TotalRecordCount":1}`)
		_, _ = w.Write([]byte(b.String()))
	})), askedLimit
}

func TestRandomPicks只挑有艺术字的(t *testing.T) {
	// 20 条没艺术字排在前面 —— 不过取的话一条都挑不到
	up, askedLimit := heroServer(t, 20, 5)
	defer up.Close()

	got, err := NewClient("test").RandomPicks(context.Background(),
		&Session{Server: up.URL, Token: "t", UserID: "u"}, 5)
	if err != nil {
		t.Fatal(err)
	}
	if len(got) != 5 {
		t.Fatalf("要 5 条有艺术字的,实得 %d 条", len(got))
	}
	for _, it := range got {
		if !strings.HasPrefix(it.ID, "art-") {
			t.Fatalf("挑进 Hero 的 %s 没有艺术字 —— 轮播会一半艺术字一半宋体标题", it.ID)
		}
	}
	// 过取必须真的发出去:limit 原样发的话前 20 条全没 Logo,这一页就挑空了
	if *askedLimit <= 5 {
		t.Fatalf("只向服务端要了 %d 条 —— 没有过取,有艺术字的条目排在后面就永远挑不到", *askedLimit)
	}
	if *askedLimit > heroMaxFetch {
		t.Fatalf("过取 %d 条超过上限 %d", *askedLimit, heroMaxFetch)
	}
}

// 一张 Logo 都没刮的库:**退回按剧照挑**,不能给空表。
// 给空表的话首页顶上是一块什么都没有的洞 —— 比风格不统一更糟。
func TestRandomPicks全库没艺术字时退回剧照(t *testing.T) {
	up, _ := heroServer(t, 8, 0)
	defer up.Close()

	got, err := NewClient("test").RandomPicks(context.Background(),
		&Session{Server: up.URL, Token: "t", UserID: "u"}, 5)
	if err != nil {
		t.Fatal(err)
	}
	if len(got) != 5 {
		t.Fatalf("退回路径要给满 5 条,实得 %d", len(got))
	}
}

// 服务端不认 ImageTypes 时(某些 fork)把没剧照的也发回来 —— 自己要再判一次,
// 否则 Hero 背景是一片空白。
func TestRandomPicks滤掉没剧照的(t *testing.T) {
	up := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		_, _ = w.Write([]byte(`{"Items":[
			{"Id":"no-bd","Name":"没剧照","Type":"Movie","ImageTags":{"Logo":"lg"}},
			{"Id":"ok","Name":"有剧照","Type":"Movie","ImageTags":{"Logo":"lg"},
			 "BackdropImageTags":["bd"]}
		]}`))
	}))
	defer up.Close()

	got, err := NewClient("test").RandomPicks(context.Background(),
		&Session{Server: up.URL, Token: "t", UserID: "u"}, 5)
	if err != nil {
		t.Fatal(err)
	}
	if len(got) != 1 || got[0].ID != "ok" {
		t.Fatalf("没有 BackdropImageTags 的条目不该进 Hero,实得 %v", ids(got))
	}
}

func ids(items []Item) []string {
	out := make([]string, 0, len(items))
	for _, it := range items {
		out = append(out, it.ID)
	}
	return out
}

// 请求本身别退化:Hero 拉的仍然是随机 + 只要有剧照的那一批。
func TestRandomPicks查询参数没退化(t *testing.T) {
	var got string
	up := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		got = r.URL.RawQuery
		_, _ = w.Write([]byte(`{"Items":[]}`))
	}))
	defer up.Close()
	_, _ = NewClient("test").RandomPicks(context.Background(),
		&Session{Server: up.URL, Token: "t", UserID: "u"}, 5)
	q, _ := url.ParseQuery(got)
	for k, want := range map[string]string{
		"SortBy": "Random", "ImageTypes": "Backdrop", "Recursive": "true",
	} {
		if q.Get(k) != want {
			t.Fatalf("%s 应为 %q,实得 %q(整串:%s)", k, want, q.Get(k), got)
		}
	}
}
