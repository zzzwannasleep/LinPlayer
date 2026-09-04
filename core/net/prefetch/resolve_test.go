package prefetch

// 直链落点有效期(302 的 Cache-Control: max-age)的门禁。
//
// ★ 服主 2026-09-04 提的:前后端分离的 Emby(115 / 123 那类网盘后端)会在 302 上用
//   max-age 声明鉴权直链还能活多久 —— 115 默认 30 分钟,123 更短。我们跟着这个数
//   换落点,就等于「请求直链的间隔」和签名寿命对齐,源站不用为撞墙重试白挨请求。

import (
	"context"
	"fmt"
	"net/http"
	"net/http/httptest"
	"strconv"
	"sync/atomic"
	"testing"
	"time"

	"linplayer/core/paths"
)

// splitUpstream 模拟前后端分离:backend 只发 302 + Cache-Control,真字节在 cdn 上。
type splitUpstream struct {
	backend, cdn *httptest.Server
	backendHits  atomic.Int64
	cdnHits      atomic.Int64
}

// newSplitUpstream maxAge <= 0 = 302 上**不发** Cache-Control(旧行为那一路)。
func newSplitUpstream(t *testing.T, maxAge time.Duration) *splitUpstream {
	t.Helper()
	s := &splitUpstream{}

	s.cdn = httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		s.cdnHits.Add(1)
		start, end := int64(0), testTotal-1
		if v := r.Header.Get("Range"); v != "" {
			if a, b, ok := parseRange(v); ok {
				start = a
				if b >= 0 && b < end {
					end = b
				}
			}
		}
		n := int(end - start + 1)
		w.Header().Set("Content-Type", "video/x-matroska")
		w.Header().Set("Content-Range", fmt.Sprintf("bytes %d-%d/%d", start, end, testTotal))
		w.Header().Set("Content-Length", strconv.Itoa(n))
		w.WriteHeader(http.StatusPartialContent)
		_, _ = w.Write(bodyAt(start, n))
	}))
	t.Cleanup(s.cdn.Close)

	s.backend = httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		s.backendHits.Add(1)
		if maxAge > 0 {
			w.Header().Set("Cache-Control", "max-age="+strconv.Itoa(int(maxAge.Seconds())))
		}
		http.Redirect(w, r, s.cdn.URL+"/signed.mkv", http.StatusFound)
	}))
	t.Cleanup(s.backend.Close)
	return s
}

func (s *splitUpstream) start(t *testing.T) *Handle {
	t.Helper()
	paths.SetRoot(t.TempDir())
	h, err := Start(context.Background(), s.backend.URL+"/video.mkv", 2, 64*1024*1024, nil)
	if err != nil {
		t.Fatalf("起代理失败: %v", err)
	}
	t.Cleanup(h.Close)
	return h
}

// 判据 1:302 声明的 max-age 到点后,**必须回头再打一次后端**换新落点。
//
// ★ 反向注入:把 upstreamURL 里的过期分支删掉(退回「落点永不过期」),
//   后端命中数会一直停在探测那一次 —— 本用例当场红。
func TestNL_落点按max_age到期后重解析(t *testing.T) {
	up := newSplitUpstream(t, time.Second)
	h := up.start(t)

	// 探测阶段:后端被打一次,拿到落点
	if got := up.backendHits.Load(); got != 1 {
		t.Fatalf("探测该正好打一次后端,实得 %d", got)
	}
	_, _, b := getRange(t, h, 0, 64*1024-1)
	assertBytes(t, 0, b)
	if got := up.backendHits.Load(); got != 1 {
		t.Fatalf("没到期就不该重打后端(落点还有效),实得 %d 次", got)
	}

	// 等签名过期
	time.Sleep(1300 * time.Millisecond)

	_, _, b2 := getRange(t, h, 5*ChunkSize, 5*ChunkSize+64*1024-1)
	assertBytes(t, 5*ChunkSize, b2)
	if got := up.backendHits.Load(); got < 2 {
		t.Fatalf("max-age 到点后该重打后端换落点,后端仍只被打了 %d 次 —— 我们在拿一条已过期的鉴权直链硬撑", got)
	}
}

// 判据 2:上游**没声明** max-age 时,行为一个字不能变 —— 落点永不过期。
//
// ★ 这条是防「减压做成加压」:没有它,把过期判定写成无条件生效也能让判据 1 绿,
//   而不吐这个头的服务器会从「永不重解析」变成「每段都重解析」。
func TestNL_没有max_age就不过期(t *testing.T) {
	up := newSplitUpstream(t, 0)
	h := up.start(t)

	for i := int64(0); i < 4; i++ {
		_, _, b := getRange(t, h, i*ChunkSize, i*ChunkSize+64*1024-1)
		assertBytes(t, i*ChunkSize, b)
		time.Sleep(120 * time.Millisecond)
	}
	if got := up.backendHits.Load(); got != 1 {
		t.Fatalf("上游没给 max-age 就该沿用旧行为(落点永不过期),后端却被打了 %d 次", got)
	}
	if up.cdnHits.Load() == 0 {
		t.Fatal("一次都没落到 CDN —— 落点根本没被用上,判据 1 会假绿")
	}
}

func TestNL_maxAgeOf解析(t *testing.T) {
	cases := []struct {
		name string
		vals []string
		want time.Duration
	}{
		{"单值", []string{"max-age=1800"}, 30 * time.Minute},
		{"带别的指令", []string{"public, max-age=900, must-revalidate"}, 15 * time.Minute},
		{"带引号", []string{`max-age="60"`}, time.Minute},
		{"大小写混写", []string{"Max-Age=30"}, 30 * time.Second},
		{"no-store 优先", []string{"no-store, max-age=1800"}, 0},
		{"no-cache 优先", []string{"no-cache"}, 0},
		{"没有这个头", nil, 0},
		{"值不是数", []string{"max-age=soon"}, 0},
		{"零和负数当没声明", []string{"max-age=0"}, 0},
		{"两个头取先出现的", []string{"public", "max-age=120"}, 2 * time.Minute},
	}
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			h := http.Header{}
			for _, v := range c.vals {
				h.Add("Cache-Control", v)
			}
			if got := maxAgeOf(h); got != c.want {
				t.Fatalf("%v: 得 %v 期望 %v", c.vals, got, c.want)
			}
		})
	}
}

// 判据 3:多跳时取**最短**的那条命 —— 链路上任何一跳先过期,整条落点就不能再用。
func TestNL_多跳取最短的max_age(t *testing.T) {
	s := &ttlSlot{}
	s.note(30 * time.Minute)
	s.note(90 * time.Second)
	s.note(0) // 没声明的那跳不参与
	if got := s.ttl(); got != 90*time.Second {
		t.Fatalf("多跳该取最小值,得 %v 期望 90s", got)
	}
}
