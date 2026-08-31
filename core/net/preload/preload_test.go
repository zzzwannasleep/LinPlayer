package preload

import (
	"context"
	"net/http"
	"net/http/httptest"
	"strings"
	"sync"
	"testing"
	"time"
)

// rangeEcho 记录收到的 Range 头,并回 bodyLen 个零字节。
func rangeEcho(t *testing.T, bodyLen int) (*httptest.Server, func() []string) {
	t.Helper()
	var mu sync.Mutex
	var seen []string
	s := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		mu.Lock()
		seen = append(seen, r.Header.Get("Range"))
		mu.Unlock()
		w.Header().Set("Content-Length", itoa(int64(bodyLen)))
		w.WriteHeader(http.StatusPartialContent)
		_, _ = w.Write(make([]byte, bodyLen))
	}))
	t.Cleanup(s.Close)
	return s, func() []string {
		mu.Lock()
		defer mu.Unlock()
		out := make([]string, len(seen))
		copy(out, seen)
		return out
	}
}

// ★★ 预热必须打**两段**:头一段正向 Range,尾一段**后缀** Range。
//
// 只热头部的话 MKV 起播仍要冷 seek 去文件末尾读 cues 索引 ——
// 那正是起播最慢的一跳,预热了个寂寞。
func TestC27_头尾都要热而且尾部用后缀Range(t *testing.T) {
	srv, seen := rangeEcho(t, 64)
	p := New()
	st := p.Warm(context.Background(), "it1", srv.URL+"/x.mkv", 64, srv.URL+"/x.mkv", 32)

	rs := seen()
	if len(rs) != 2 {
		t.Fatalf("该打两段(头 + 尾),实得 %d 段:%v", len(rs), rs)
	}
	if rs[0] != "bytes=0-63" {
		t.Fatalf("头段该是正向 Range,实得 %q", rs[0])
	}
	if !strings.HasPrefix(rs[1], "bytes=-") {
		t.Fatalf("尾段必须是**后缀** Range(MKV 索引在末尾),实得 %q", rs[1])
	}
	if st.HeadBytes <= 0 || st.TailBytes <= 0 {
		t.Fatalf("两段都该热到字节: %+v", st)
	}
}

// ★★ 头尾**可以是两个地址**,而且尾部必须走直连。
//
// 代理的环形缓存按 `chunk % ring` 定位,尾部段号和头部段号模 ring 有约一半的概率
// 同槽 —— 那样预热完尾巴正好把头顶掉。而且我们自家的预取代理**不认后缀 Range**。
func TestC27_尾部走另一个地址(t *testing.T) {
	proxy, proxySeen := rangeEcho(t, 64)   // 假装是本地预取代理
	direct, directSeen := rangeEcho(t, 32) // 直连地址

	p := New()
	p.Warm(context.Background(), "it1", proxy.URL+"/x.mkv", 64, direct.URL+"/x.mkv", 32)

	ph, dh := proxySeen(), directSeen()
	if len(ph) != 1 || ph[0] != "bytes=0-63" {
		t.Fatalf("头部该只打代理,实得 %v", ph)
	}
	if len(dh) != 1 || !strings.HasPrefix(dh[0], "bytes=-") {
		t.Fatalf("尾部该只打直连且用后缀 Range,实得 %v —— 打代理会把刚热好的头顶掉", dh)
	}
}

// ★★ 服务端**无视 Range 回整片**是真发生过的事。
//
// 预热必须自己封顶,否则「热一下」会变成把整部片子偷偷下下来 ——
// 在计费网络上那是直接烧用户的钱。
func TestC27_服务端无视Range时也要封顶(t *testing.T) {
	// 不管你要多少,一律回 4MB
	const whole = 4 * 1024 * 1024
	srv, _ := rangeEcho(t, whole)
	p := New()
	st := p.Warm(context.Background(), "it2", srv.URL+"/x.mkv", 128, srv.URL+"/x.mkv", 0)

	if st.HeadBytes < 128 {
		t.Fatalf("该至少读到要的量,实读 %d", st.HeadBytes)
	}
	// 允许多读到一整个读缓冲(64KB),但绝不能把 4MB 整片拉完
	if st.HeadBytes > 128+64*1024 {
		t.Fatalf("没封顶:服务端无视 Range 时预热把整片拉了下来,实读 %d 字节", st.HeadBytes)
	}
}

// 换条目 / 离开详情页要能**立刻掐掉上一轮**。
//
// ★ 不掐的话用户在列表里快速点几下,后台会挂着好几轮预热同时抢带宽,
// 而他真正要看的那部反而更慢了。
func TestC27_开新一轮掐掉上一轮(t *testing.T) {
	p := New()
	c1, _ := p.begin("a")
	if c1.Load() {
		t.Fatal("刚开的这一轮不该是已取消")
	}
	c2, _ := p.begin("b")
	if !c1.Load() {
		t.Fatal("开新一轮没掐掉上一轮 —— 几轮预热会同时抢带宽")
	}
	if c2.Load() {
		t.Fatal("新一轮不该一开始就被取消")
	}
	if p.Current() != "b" {
		t.Fatalf("当前条目该是 b,实得 %q", p.Current())
	}
	p.Cancel()
	if !c2.Load() {
		t.Fatal("Cancel 没生效 —— 起播时掐不掉预热就会和播放器抢带宽")
	}
}

// 取消之后**尾部那段压根不该发出去**。
func TestC27_取消后不再打尾部(t *testing.T) {
	// ★ 上游必须**慢**:用秒回的假服务器的话,头部那段在 Cancel 之前就读完了,
	//   Warm 早已返回,断言测的是「谁先跑完」而不是「取消管不管用」。
	//   第一版就是这么假绿……不,是这么**假红**的 —— 但同样说明用例的形状不对。
	var seenMu sync.Mutex
	var got []string
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		seenMu.Lock()
		got = append(got, r.Header.Get("Range"))
		seenMu.Unlock()
		w.WriteHeader(http.StatusPartialContent)
		for i := 0; i < 200; i++ {
			if _, err := w.Write(make([]byte, 64*1024)); err != nil {
				return
			}
			if f, ok := w.(http.Flusher); ok {
				f.Flush()
			}
			time.Sleep(20 * time.Millisecond)
		}
	}))
	defer srv.Close()
	seen := func() []string {
		seenMu.Lock()
		defer seenMu.Unlock()
		out := make([]string, len(got))
		copy(out, got)
		return out
	}

	p := New()
	done := make(chan Stats, 1)
	go func() {
		done <- p.Warm(context.Background(), "it1", srv.URL+"/x", 32*1024*1024, srv.URL+"/x", 1024)
	}()
	time.Sleep(80 * time.Millisecond)
	p.Cancel()

	select {
	case st := <-done:
		if !st.Canceled {
			t.Fatal("取消旗标该反映在结果里")
		}
		if st.TailBytes != 0 {
			t.Fatalf("取消之后不该再热尾部,实得 %d 字节", st.TailBytes)
		}
		if n := len(seen()); n != 1 {
			t.Fatalf("取消之后只该打过头部那一次,实得 %d 次", n)
		}
	case <-time.After(10 * time.Second):
		t.Fatal("取消之后 Warm 没能收场")
	}
}

// 任何失败都只是「没热成」,**绝不能把详情页拦下来**。
func TestC27_失败一律当没热成(t *testing.T) {
	p := New()
	// 连不上
	st := p.Warm(context.Background(), "it1", "http://127.0.0.1:1/x", 1024, "http://127.0.0.1:1/x", 1024)
	if st.HeadBytes != 0 || st.TailBytes != 0 {
		t.Fatalf("连不上时该是 0 字节,实得 %+v", st)
	}
	/* 403(条目没权限)。
	   ★ 错误响应**带 body**才测得出来:空 body 的 403 就算不看状态码也读到 0 字节,
	     用例分不开「查了状态码」和「没查但正好没内容」。
	     而真实服务器的 403/404 往往回一整页 HTML —— 不看状态码就等于
	     把错误页当成「预热好的视频头」记进统计,还白读一遍。 */
	deny := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.WriteHeader(403)
		_, _ = w.Write([]byte(strings.Repeat("错误页", 500)))
	}))
	defer deny.Close()
	if st := p.Warm(context.Background(), "it2", deny.URL, 1024, deny.URL, 1024); st.HeadBytes != 0 || st.TailBytes != 0 {
		t.Fatalf("403 时该是 0 字节(别把错误页当成预热好的视频头),实得 %+v", st)
	}
}

// head=0 / tail=0 时那一段压根不发请求(用户把预热量调成 0 就是要它别拉)。
func TestC27_量为零时不发请求(t *testing.T) {
	srv, seen := rangeEcho(t, 64)
	p := New()
	p.Warm(context.Background(), "it1", srv.URL, 0, srv.URL, 0)
	if n := len(seen()); n != 0 {
		t.Fatalf("头尾都是 0 时不该发任何请求,实得 %d 次", n)
	}
	p.Warm(context.Background(), "it1", srv.URL, 0, srv.URL, 32)
	if rs := seen(); len(rs) != 1 || !strings.HasPrefix(rs[0], "bytes=-") {
		t.Fatalf("只热尾部时该只打后缀 Range,实得 %v", rs)
	}
}
