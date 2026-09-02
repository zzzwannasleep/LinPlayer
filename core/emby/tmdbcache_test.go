package emby

import (
	"context"
	"encoding/json"
	"fmt"
	"net/http"
	"net/http/httptest"
	"sync/atomic"
	"testing"
)

// SeriesTmdbID 的缓存。
//
// ★★ 为什么值得一条测试:这一次网络往返在**起播路径上**,而追剧就是同一部剧
// 一集接一集地放 —— 不缓存的话每集都要重打一次,答案却永远一样。
//
// 三条都对应真实的错法:
//
//  1. 查到了要缓存 —— 否则等于没写。
//  2. **查过但没有也要缓存**。这条最容易漏:没刮削 TMDB 的库返回 nil,
//     只缓存非空的话整库都不命中,而那正是最需要缓存的场景。
//  3. 键要带 server。同一个 seriesID 在两台服务器上不是同一部剧,
//     混用的结果是跨服匹配到别的剧上去 —— 而且不报错。
func TestSeriesTmdbIDCaches(t *testing.T) {
	tmdbMu.Lock()
	tmdbCache = map[string]*string{}
	tmdbMu.Unlock()

	var hits atomic.Int64
	mk := func() *httptest.Server {
		return httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
			hits.Add(1)
			id := r.URL.Path[len(r.URL.Path)-4:]
			body := map[string]any{"Id": id, "Name": "某剧", "Type": "Series"}
			if id == "有的" || id == "s001" {
				body["ProviderIds"] = map[string]string{"Tmdb": "12345"}
			}
			w.Header().Set("Content-Type", "application/json")
			_ = json.NewEncoder(w).Encode(body)
		}))
	}
	up1, up2 := mk(), mk()
	defer up1.Close()
	defer up2.Close()

	c := NewClient("test")
	s1 := &Session{Server: up1.URL, Token: "t", UserID: "u", DeviceID: "d"}
	s2 := &Session{Server: up2.URL, Token: "t", UserID: "u", DeviceID: "d"}
	ctx := context.Background()

	// 1) 有 TMDB id:第二次不该再打服务器
	if got := c.SeriesTmdbID(ctx, s1, "s001"); got == nil || *got != "12345" {
		t.Fatalf("第一次应取到 12345,实得 %v", got)
	}
	before := hits.Load()
	if got := c.SeriesTmdbID(ctx, s1, "s001"); got == nil || *got != "12345" {
		t.Fatalf("第二次应取到 12345,实得 %v", got)
	}
	if n := hits.Load() - before; n != 0 {
		t.Fatalf("第二次又打了 %d 次服务器 —— 缓存没生效", n)
	}

	// 2) 没有 TMDB id(没刮削):负结果同样要缓存
	if got := c.SeriesTmdbID(ctx, s1, "s002"); got != nil {
		t.Fatalf("没刮削的剧应返回 nil,实得 %v", *got)
	}
	before = hits.Load()
	_ = c.SeriesTmdbID(ctx, s1, "s002")
	if n := hits.Load() - before; n != 0 {
		t.Fatalf("「查过但没有」重复打了 %d 次 —— 没记负结果等于整个没刮削的库都不命中", n)
	}

	// 3) 换一台服务器,同一个 seriesID:必须重新打
	before = hits.Load()
	_ = c.SeriesTmdbID(ctx, s2, "s001")
	if n := hits.Load() - before; n != 1 {
		t.Fatalf("换服务器后应重新打一次,实得 %d 次 —— 缓存键漏了 server,会跨服串剧", n)
	}
	_ = fmt.Sprint()
}
