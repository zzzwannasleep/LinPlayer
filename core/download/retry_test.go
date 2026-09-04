package download

// 分段下载的**自动重试**判据。
//
// ★ 这一整块的由来:前后端分离的 Emby(115 / 123 那类网盘后端)发的是带时效签名的
//   直链(115 默认 30 分钟),而一部原盘要下几小时 —— 签名**必然**在中途失效。
//   老代码一段出错就整条任务死,用户看到的是「下到 37% 就失败了,重下又从 37% 失败」。

import (
	"fmt"
	"net/http"
	"net/http/httptest"
	"os"
	"strconv"
	"strings"
	"sync/atomic"
	"testing"
	"time"
)

// flakyServer 一台会「中途掐连接」的服务器。
//
//	failFirst 前多少次取数请求写到一半就断(模拟鉴权直链过期 / CDN 掐长连接)
//
// 探测请求(`Range: bytes=0-0`)不算在 dataHits 里,也从不掐 —— 它和重试无关。
type flakyServer struct {
	*httptest.Server
	dataHits atomic.Int64
}

func newFlakyServer(t *testing.T, size int64, failFirst int64) *flakyServer {
	t.Helper()
	fs := &flakyServer{}
	fs.Server = httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		rg := r.Header.Get("Range")
		if rg == "bytes=0-0" { // 探测
			w.Header().Set("Accept-Ranges", "bytes")
			w.Header().Set("Content-Range", fmt.Sprintf("bytes 0-0/%d", size))
			w.Header().Set("Content-Length", "1")
			w.WriteHeader(http.StatusPartialContent)
			_, _ = w.Write([]byte{0})
			return
		}
		n := fs.dataHits.Add(1)
		start, end := parseTestRange(rg, size)
		body := testBytes(start, end)

		w.Header().Set("Accept-Ranges", "bytes")
		w.Header().Set("Content-Range", fmt.Sprintf("bytes %d-%d/%d", start, end, size))
		w.Header().Set("Content-Length", strconv.Itoa(len(body)))
		w.WriteHeader(http.StatusPartialContent)

		if n <= failFirst {
			// 写一半,然后**掐掉连接** —— 声明的长度没写够,客户端读到的是意外断流
			_, _ = w.Write(body[:len(body)/2])
			if f, ok := w.(http.Flusher); ok {
				f.Flush()
			}
			panic(http.ErrAbortHandler)
		}
		_, _ = w.Write(body)
	}))
	t.Cleanup(fs.Close)
	return fs
}

func parseTestRange(rg string, size int64) (int64, int64) {
	start, end := int64(0), size-1
	if strings.HasPrefix(rg, "bytes=") {
		parts := strings.SplitN(strings.TrimPrefix(rg, "bytes="), "-", 2)
		start, _ = strconv.ParseInt(parts[0], 10, 64)
		if len(parts) > 1 && parts[1] != "" {
			end, _ = strconv.ParseInt(parts[1], 10, 64)
		}
	}
	if end > size-1 {
		end = size - 1
	}
	return start, end
}

func testBytes(start, end int64) []byte {
	b := make([]byte, end-start+1)
	for i := range b {
		b[i] = byte((start + int64(i)) % 251)
	}
	return b
}

func assertWholeFile(t *testing.T, path string, size int) {
	t.Helper()
	b, err := os.ReadFile(path)
	if err != nil {
		t.Fatal(err)
	}
	if len(b) != size {
		t.Fatalf("长度 %d,应当 %d —— 续传接错位置或短了没人发现", len(b), size)
	}
	for i := range b {
		if b[i] != byte(i%251) {
			t.Fatalf("第 %d 字节对不上:%d != %d —— 重试那一轮接错了位置", i, b[i], byte(i%251))
		}
	}
}

// ★★ 判据 1:上游中途掐两次连接,下载必须**自己续上并下完**,文件逐字节一致。
//
// 反向注入:把 runSegment 的重试循环拆掉(fetchSegment 出错就 return),
// 任务当场变 failed —— 本用例红。
func TestDL_中途断流要自己重试续上(t *testing.T) {
	const size = 512 * 1024
	up := newFlakyServer(t, size, 2)
	m := mgr(t)
	m.SetThreads(1)

	id := m.Enqueue(&Item{ItemID: "i1", Title: "某部电影", Container: "mkv", URL: up.URL})
	it := waitDone(t, m, id, 30*time.Second)
	if it.Status != StatusCompleted {
		t.Fatalf("断了两次就该重试下完,实得状态 %s,错误 %v", it.Status, deref(it.Error))
	}
	assertWholeFile(t, it.FilePath, size)
	if got := up.dataHits.Load(); got < 3 {
		t.Fatalf("掐了两次至少要打三次才可能下完,实得 %d 次 —— 没在重试", got)
	}
}

// ★★ 判据 2:**没权限不许重试**。
//
// 401/403 重试十遍只有两个后果:用户等一分钟才看到「无下载权限」,服务器白挨十次。
// 反向注入:把 statusErr 里的 permanent() 摘掉 —— 任务要退避重试到超时,
// 本用例等不到结束当场红。
func TestDL_没权限不重试(t *testing.T) {
	var hits atomic.Int64
	up := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		hits.Add(1)
		w.WriteHeader(http.StatusUnauthorized)
	}))
	t.Cleanup(up.Close)

	m := mgr(t)
	m.SetThreads(1)
	id := m.Enqueue(&Item{ItemID: "i1", Title: "某部电影", Container: "mkv", URL: up.URL})
	it := waitDone(t, m, id, 5*time.Second)
	if it.Status != StatusFailed {
		t.Fatalf("401 该直接失败,实得 %s", it.Status)
	}
	if msg := deref(it.Error); !strings.Contains(msg, "无下载权限") {
		t.Fatalf("错误该说人话,实得 %q", msg)
	}
	// 探测 1 次 + 取数 1 次 = 2。多出来的就是在重试一个不可能变对的错。
	if got := hits.Load(); got > 2 {
		t.Fatalf("401 被打了 %d 次 —— 在重试一个重试也不会变对的错", got)
	}
}

// ★★ 判据 3:**干净的 EOF 不等于下完了**。
//
// 反代无视 Range 回一个更短的 Content-Length、CDN 提前收尾,都会产出「读到头了
// 但字节不够」的响应。老代码在这里直接算成功,而 assemble 只拼接**不校验长度** ——
// 出来的是一个短了却报「已完成」的文件,播到一半就没了,一句错都不报。
//
// 反向注入:删掉 fetchSegment 里那条 `downloaded < seg.length()` 判断,
// 文件会短一半而状态是 completed —— 本用例红在长度断言上。
func TestDL_短读不能报成功(t *testing.T) {
	const size = 512 * 1024
	var dataHits atomic.Int64
	up := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		rg := r.Header.Get("Range")
		if rg == "bytes=0-0" {
			w.Header().Set("Accept-Ranges", "bytes")
			w.Header().Set("Content-Range", fmt.Sprintf("bytes 0-0/%d", size))
			w.Header().Set("Content-Length", "1")
			w.WriteHeader(http.StatusPartialContent)
			_, _ = w.Write([]byte{0})
			return
		}
		n := dataHits.Add(1)
		start, end := parseTestRange(rg, size)
		body := testBytes(start, end)
		if n == 1 {
			body = body[:len(body)/2] // 第一次:**长度也报短的**,读到的是干净 EOF
		}
		w.Header().Set("Accept-Ranges", "bytes")
		w.Header().Set("Content-Range", fmt.Sprintf("bytes %d-%d/%d", start, start+int64(len(body))-1, size))
		w.Header().Set("Content-Length", strconv.Itoa(len(body)))
		w.WriteHeader(http.StatusPartialContent)
		_, _ = w.Write(body)
	}))
	t.Cleanup(up.Close)

	m := mgr(t)
	m.SetThreads(1)
	id := m.Enqueue(&Item{ItemID: "i1", Title: "某部电影", Container: "mkv", URL: up.URL})
	it := waitDone(t, m, id, 30*time.Second)
	if it.Status != StatusCompleted {
		t.Fatalf("短读该重试补齐,实得 %s,错误 %v", it.Status, deref(it.Error))
	}
	assertWholeFile(t, it.FilePath, size)
}

// 判据 4:退避要封顶 —— 太密是给源站加压,而我们做这块正是为了给它减压。
func TestDL_退避封顶(t *testing.T) {
	if got := retryBackoff(0); got != time.Second {
		t.Fatalf("第一次该等 1s,实得 %v", got)
	}
	if got := retryBackoff(3); got != 8*time.Second {
		t.Fatalf("第四次该等 8s,实得 %v", got)
	}
	for _, n := range []int{5, 10, 60, 1000} {
		if got := retryBackoff(n); got != 30*time.Second {
			t.Fatalf("第 %d 次该封顶 30s,实得 %v —— 没封顶就是移位溢出", n, got)
		}
	}
	if got := retryBackoff(-1); got != time.Second {
		t.Fatalf("负数该当 0 处理,实得 %v", got)
	}
}
