package prefetch

import (
	"context"
	"fmt"
	"io"
	"net"
	"net/http"
	"net/http/httptest"
	"os"
	"strconv"
	"strings"
	"sync"
	"sync/atomic"
	"testing"
	"time"

	"linplayer/core/paths"
)

// ★ 测试语料是**真实尺寸**的:8 段 × 4MB。
//
// **禁止靠调小 ChunkSize 让测试变绿**(TODO C26 明写)——
// 调小之后「等整段」的代价跟着变小,几条本该红的用例会假绿,
// 而真实链路上的问题一点没修。
const testTotal = 8 * ChunkSize

// body 生成可校验的内容:第 i 个字节 = i 的低 8 位。
// 错位 / 串数据一读就现形,而全 0 或全 'x' 的语料看不出来。
func bodyAt(off int64, n int) []byte {
	b := make([]byte, n)
	for i := range b {
		b[i] = byte((off + int64(i)) & 0xff)
	}
	return b
}

type upstream struct {
	*httptest.Server
	requests atomic.Int64
	// slow 每写一块之间停多久(模拟慢链路)
	slow time.Duration
	// stall 收到请求后**只连不回**(验空闲超时)
	stall atomic.Bool
	// truncate 只回一半字节(验「短了必须重试」)
	truncate atomic.Bool
	// lastRangeStart 最后一次被要求的 Range 起点(验「seek 不回退边界」)
	lastRangeStart atomic.Int64
	// release 收尾时放行被 stall 卡住的 handler。
	//
	// ★ 不能直接 `select {}` 干等:httptest 的 Close 会**等所有在途请求结束**,
	//   一个永远不返回的 handler 就把整包测试卡到超时(180s)——
	//   而失败信息只有一堆 goroutine dump,看起来像死锁 bug 而不是测试写法问题。
	release chan struct{}
}

func osStat(p string) (any, error) { return os.Stat(p) }

func newUpstream(t *testing.T) *upstream {
	t.Helper()
	u := &upstream{release: make(chan struct{})}
	u.Server = httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		u.requests.Add(1)
		if u.stall.Load() {
			<-u.release // 只连不回,直到收尾放行
			return
		}
		start, end := int64(0), testTotal-1
		if v := r.Header.Get("Range"); v != "" {
			if s, e, ok := parseRange(v); ok {
				start = s
				u.lastRangeStart.Store(s)
				if e >= 0 && e < end {
					end = e
				}
			}
		}
		n := int(end - start + 1)
		if u.truncate.Load() && n > 1024 {
			n /= 2 // 「格式合法但短」的响应
		}
		w.Header().Set("Content-Type", "video/x-matroska")
		w.Header().Set("Content-Range", fmt.Sprintf("bytes %d-%d/%d", start, end, testTotal))
		w.Header().Set("Content-Length", strconv.Itoa(n))
		w.WriteHeader(http.StatusPartialContent)
		data := bodyAt(start, n)
		step := 64 * 1024
		for i := 0; i < len(data); i += step {
			j := i + step
			if j > len(data) {
				j = len(data)
			}
			if _, err := w.Write(data[i:j]); err != nil {
				return
			}
			if f, ok := w.(http.Flusher); ok {
				f.Flush()
			}
			if u.slow > 0 {
				time.Sleep(u.slow)
			}
		}
	}))
	t.Cleanup(u.Close)                     // 后跑
	t.Cleanup(func() { close(u.release) }) // 先跑:放行卡住的 handler
	return u
}

func startProxy(t *testing.T, up *upstream, threads int, cacheLimit int64) *Handle {
	t.Helper()
	paths.SetRoot(t.TempDir())
	h, err := Start(context.Background(), up.URL+"/video.mkv", threads, cacheLimit, nil)
	if err != nil {
		t.Fatalf("起代理失败: %v", err)
	}
	t.Cleanup(h.Close)
	return h
}

// getRange 从代理拉一段,返回 (状态码, 响应头, body)。
func getRange(t *testing.T, h *Handle, start, end int64) (int, http.Header, []byte) {
	t.Helper()
	req, _ := http.NewRequest(http.MethodGet, h.URL, nil)
	if start >= 0 {
		if end >= 0 {
			req.Header.Set("Range", fmt.Sprintf("bytes=%d-%d", start, end))
		} else {
			req.Header.Set("Range", fmt.Sprintf("bytes=%d-", start))
		}
	}
	resp, err := http.DefaultClient.Do(req)
	if err != nil {
		t.Fatalf("拉代理失败: %v", err)
	}
	defer resp.Body.Close()
	b, _ := io.ReadAll(resp.Body)
	return resp.StatusCode, resp.Header, b
}

// rawRequest 手写一次 HTTP 请求,把**原始响应字节**读回来。
//
// ★ 线上格式类的判据只能这么验:Go 的 http 客户端会吃掉逐跳头,
// 拿它做断言等于在验「客户端怎么解析」,不是在验「我们发了什么」。
func rawRequest(t *testing.T, url, extraHeader string) string {
	t.Helper()
	addr := strings.TrimPrefix(url, "http://")
	addr, _, _ = strings.Cut(addr, "/")
	conn, err := net.Dial("tcp", addr)
	if err != nil {
		t.Fatal(err)
	}
	defer conn.Close()
	fmt.Fprintf(conn, "GET /stream HTTP/1.1\r\nHost: %s\r\n%s\r\n\r\n", addr, extraHeader)
	_ = conn.SetReadDeadline(time.Now().Add(10 * time.Second))
	b, _ := io.ReadAll(conn)
	return string(b)
}

func assertBytes(t *testing.T, off int64, got []byte) {
	t.Helper()
	want := bodyAt(off, len(got))
	for i := range got {
		if got[i] != want[i] {
			t.Fatalf("第 %d 字节(绝对位置 %d)对不上:得 %d 期望 %d —— 串数据/错位",
				i, off+int64(i), got[i], want[i])
		}
	}
}

// 判据 1:**边收边吐** —— 慢链路上不等整段收完就能拿到头几百 KB。
//
// ★ 这是「开了多线程加载就没画面没声音」的正解。分段粒度是给**预取**用的,
// 不该成为**供给**的粒度:mpv 起播只要文件头 ~200KB,等满 4MB 是纯粹的白等。
// 实测用户那条链 56~143KB/s,一段 4MB 合法地要 29~62 秒。
func TestC26_边收边吐(t *testing.T) {
	up := newUpstream(t)
	// 每 64KB 停 20ms → 一整段 4MB 要 ~1.3 秒。断言首字节远早于此。
	up.slow = 20 * time.Millisecond
	h := startProxy(t, up, 2, 64*1024*1024)

	req, _ := http.NewRequest(http.MethodGet, h.URL, nil)
	req.Header.Set("Range", "bytes=0-")
	t0 := time.Now()
	resp, err := http.DefaultClient.Do(req)
	if err != nil {
		t.Fatal(err)
	}
	defer resp.Body.Close()

	buf := make([]byte, 200*1024)
	if _, err := io.ReadFull(resp.Body, buf); err != nil {
		t.Fatalf("读头 200KB 失败: %v", err)
	}
	took := time.Since(t0)
	assertBytes(t, 0, buf)

	// 整段要 ~1.3s;边收边吐的话头 200KB 该在几百毫秒内到手
	if took > 900*time.Millisecond {
		t.Fatalf("头 200KB 等了 %v —— 说明在等整段落盘(那正是「开了就播不出来」的形态)", took)
	}
}

// 判据 2:**seek 不回退边界** —— 首段不对齐时只拉播放器真正要的那一截。
//
// ★ 每次 seek 都是一条新连接。从段边界拉就等于在播放器要的第一个字节前面
// 先白拉平均 2MB —— 150KB/s 下 = 拖一次进度条画面 13 秒不动。
func TestC26_seek不回退边界(t *testing.T) {
	up := newUpstream(t)
	h := startProxy(t, up, 2, 64*1024*1024)

	// 从第 3 段中间开始要 1KB
	start := 3*ChunkSize + ChunkSize/2
	_, _, b := getRange(t, h, start, start+1023)
	if len(b) != 1024 {
		t.Fatalf("该拿到 1024 字节,实得 %d", len(b))
	}
	assertBytes(t, start, b)

	// 上游收到的第一个 Range 必须**从请求点开始**,不是从段边界
	// (校验方式:再拉一次同样的区间,若第一次是从边界拉的,这段早在缓存里了 ——
	//  所以直接看上游收到的 Range 更直接)
	if got := up.lastRangeStart.Load(); got < start {
		t.Fatalf("上游被要求从 %d 开始拉,而播放器只要 %d 之后的 —— 白拉了 %d 字节",
			got, start, start-got)
	}
}

// 判据 4:响应必须带 **Connection: close**。
//
// ★ 这是「有流量、没画面没声音」的根因之一:HTTP/1.1 默认长连接,
// 不写这个头就是在对播放器承诺「这条连接还能再发请求」。ffmpeg 一 seek
// 就把下一个 Range **管线化发在同一条 socket 上** —— 那个请求没人读,
// 响应永远不来,seek 静默失败后退化成从头线性读完整个文件。
func TestC26_必须带Connection_close(t *testing.T) {
	up := newUpstream(t)
	h := startProxy(t, up, 2, 64*1024*1024)
	/* ★ 这一条必须在**原始字节**上验,不能用 Go 的 http 客户端读 Header ——
	   它把 Connection 当逐跳头吃掉了(只在 resp.Close 上反映)。
	   而这个判据说的正是「线上到底发了什么」:ffmpeg 看的是原始头。
	   用客户端读的话断言恒空,看起来像我们没发,实际是被库吃了 —— 两种都不该猜。 */
	raw := rawRequest(t, h.URL, "Range: bytes=0-1023")
	head, _, _ := strings.Cut(raw, "\r\n\r\n")
	if !strings.HasPrefix(head, "HTTP/1.1 206 Partial Content") {
		t.Fatalf("带 Range 该回 206,实得:\n%s", head)
	}
	if !strings.Contains(strings.ToLower(head), "connection: close") {
		t.Fatalf("必须带 Connection: close,实得:\n%s\n—— ffmpeg 会把 seek 管线化到同一条 socket 上", head)
	}
	for _, k := range []string{"Content-Range: bytes 0-1023/", "Accept-Ranges: bytes", "Content-Length: 1024"} {
		if !strings.Contains(head, k) {
			t.Fatalf("206 的头缺 %q:\n%s", k, head)
		}
	}
	// 不带 Range 时回 200 全量
	code2, hdr2, _ := getRange(t, h, -1, -1)
	if code2 != http.StatusOK || hdr2.Get("Content-Length") != strconv.FormatInt(testTotal, 10) {
		t.Fatalf("不带 Range 该回 200 + 全长,实得 %d %v", code2, hdr2.Get("Content-Length"))
	}
}

// 判据 6:**环形缓存占用恒 = 上限**。
//
// ★ 整片直存看着简单,但随手就有 29.6GB 的片子 —— 顺序看完一遍就把用户硬盘
// 吃掉 29.6GB。这和「内存爆掉」是同一个错误换了个介质。
func TestC26_环形缓存占用恒等于上限(t *testing.T) {
	up := newUpstream(t)
	limit := int64(8 * 1024 * 1024) // 2 段
	h := startProxy(t, up, 2, limit)

	// 顺序读完整片(8 段)
	_, _, b := getRange(t, h, 0, testTotal-1)
	if int64(len(b)) != testTotal {
		t.Fatalf("该读完整片,实得 %d/%d", len(b), testTotal)
	}
	assertBytes(t, 0, b)

	// ring = max(limit/ChunkSize, threads*2) = max(2,4) = 4 段
	wantMax := int64(4) * ChunkSize
	if got := h.origin.disk.sizeOnDisk(); got > wantMax {
		t.Fatalf("缓存文件涨到 %d 字节,上限该是 %d —— 整片直存会把用户硬盘吃光", got, wantMax)
	}
}

// 判据 7 / 8 的地基:**先失效再写**,以及「被挤掉要能重拉」。
//
// ★ 先写盘再更新槽表的话,读者可以:查表命中 → 开始读 → 另一条流正把别的段
// 覆盖进同一个槽 → 读到半新半旧的**脏数据**。表现是播放器拿到错帧,
// **比饿死更隐蔽 —— 它不报错,只是画面坏掉**。
func TestC26_环形槽位的先失效再写(t *testing.T) {
	paths.SetRoot(t.TempDir())
	d, err := newDiskCache(testTotal, 8*1024*1024, 2)
	if err != nil {
		t.Fatal(err)
	}
	defer d.close()

	// ★ chunk 0 的坑:map 取不到返回零值,写成 `slots[slot] == c` 的话
	//   槽位空着时 chunk 0 会被判成「就绪」,读回一整块稀疏零当有效数据发出去。
	//   而文件头恰恰是每次起播必读的第一段。
	if d.has(0) {
		t.Fatal("空槽位不该把 chunk 0 判成就绪 —— 会读回一整块稀疏零")
	}

	seg := bodyAt(0, int(ChunkSize))
	if !d.put(0, seg) {
		t.Fatal("写不进去")
	}
	if !d.has(0) || d.get(0, int(ChunkSize)) == nil {
		t.Fatal("写完该命中")
	}
	// 同槽的另一段覆盖进来(ring=4,chunk 4 与 chunk 0 同槽)
	if !d.put(4, bodyAt(4*ChunkSize, int(ChunkSize))) {
		t.Fatal("写不进去")
	}
	if d.has(0) {
		t.Fatal("chunk 0 已被 chunk 4 挤出槽位,不该再命中")
	}
	if d.get(0, int(ChunkSize)) != nil {
		t.Fatal("被挤掉的段必须返回 nil(让调用方重拉),不能把别人的字节当成它的")
	}
	if got := d.get(4, int(ChunkSize)); got == nil || got[0] != seg[0] && got[0] != byte(4*ChunkSize&0xff) {
		t.Fatalf("chunk 4 该读得回来")
	}
}

// 判据:并发多连接互不饿死,且**每条连接读到的都是自己那段的正确字节**。
//
// ★ 环形缓存是全连接共享的(槽位 = chunk % ring),两条连接的段号模 ring 同余就同槽。
// 后写的直接盖掉先写的,而 worker 的游标已经越过那一段 —— **再没有人会去重拉它**,
// 于是那条连接彻底饿死(播放器侧 = 有流量、黑屏 / 永远缓冲)。
// 自愈的做法是把游标倒回去让 worker 重新认领。
func TestC26_并发连接互不饿死(t *testing.T) {
	up := newUpstream(t)
	// 缓存只有 2 段 → ring 很小 → 两条连接必然抢同一批槽位
	h := startProxy(t, up, 2, 8*1024*1024)

	type want struct{ start, end int64 }
	cases := []want{
		{0, 2*ChunkSize - 1},
		{4 * ChunkSize, 6*ChunkSize - 1},
		{2 * ChunkSize, 4*ChunkSize - 1},
	}
	var wg sync.WaitGroup
	errs := make([]error, len(cases))
	for i, c := range cases {
		wg.Add(1)
		go func(i int, c want) {
			defer wg.Done()
			req, _ := http.NewRequest(http.MethodGet, h.URL, nil)
			req.Header.Set("Range", fmt.Sprintf("bytes=%d-%d", c.start, c.end))
			resp, err := http.DefaultClient.Do(req)
			if err != nil {
				errs[i] = err
				return
			}
			defer resp.Body.Close()
			b, err := io.ReadAll(resp.Body)
			if err != nil {
				errs[i] = err
				return
			}
			if int64(len(b)) != c.end-c.start+1 {
				errs[i] = fmt.Errorf("连接 %d 少了字节: %d/%d(饿死或 early eof)", i, len(b), c.end-c.start+1)
				return
			}
			for j := range b {
				if b[j] != byte((c.start+int64(j))&0xff) {
					errs[i] = fmt.Errorf("连接 %d 第 %d 字节串了数据", i, j)
					return
				}
			}
		}(i, c)
	}
	wg.Wait()
	for _, e := range errs {
		if e != nil {
			t.Fatal(e)
		}
	}
}

// 「格式合法但短」的响应必须重试,不能收下。
//
// ★ 分段是按 pos/ChunkSize 定位的,收下短包会让供给端写完这几字节后把窗口推到
// 下一段,而 pos 仍落在本段内 → 下一轮又来要这一段,可游标早过了它,
// **永远没人重拉 → 永远缓冲**。
func TestC26_短包必须重试(t *testing.T) {
	up := newUpstream(t)
	up.truncate.Store(true)
	h := startProxy(t, up, 2, 64*1024*1024)

	// 三次尝试都短 → 这一段拉不到 → 断流(而不是把半段当成完整段收下)
	done := make(chan int, 1)
	go func() {
		_, _, b := getRange(t, h, 0, ChunkSize-1)
		done <- len(b)
	}()
	select {
	case n := <-done:
		if int64(n) == ChunkSize {
			t.Fatal("上游一直只给一半,不该拿到完整一段 —— 说明短包被收下了")
		}
	case <-time.After(20 * time.Second):
		t.Fatal("短包路径吊死了 —— 三次重试之后必须放弃并断流")
	}
}

// 上游只连不回时**不能吊死**:空闲超时到了就作废这个地址。
//
// ★ 在这之前是无限期等待:上游只要不回,worker 就永远吊在那儿 ——
// 不重试、不重签、不报错、连一行日志都没有。供给端于是也永远等,
// mpv 那边表现成:206 头收到了、然后 duration=0 / 一帧不出。
func TestC26_上游只连不回不吊死(t *testing.T) {
	SetChunkTimeoutForTest(300 * time.Millisecond)
	defer SetChunkTimeoutForTest(0)

	up := newUpstream(t)
	h := startProxy(t, up, 2, 64*1024*1024) // 探测阶段正常
	up.stall.Store(true)                    // 之后的取数全部只连不回

	done := make(chan struct{})
	go func() {
		getRange(t, h, 0, ChunkSize-1)
		close(done)
	}()
	select {
	case <-done:
	case <-time.After(15 * time.Second):
		t.Fatal("上游只连不回时吊死了 —— 必须靠空闲超时作废地址")
	}
}

// 越界 Range 回 416,**不能**悄悄挪回最后一字节回 206。
//
// ★ 原来先钳位再判越界,那个分支永远进不去(死代码),越界请求被悄悄挪回
// 最后一字节回一个 206 —— 播放器拿到的是「有效但错位」的数据。
func TestC26_越界Range回416(t *testing.T) {
	up := newUpstream(t)
	h := startProxy(t, up, 2, 64*1024*1024)
	code, _, _ := getRange(t, h, testTotal+1024, -1)
	if code != http.StatusRequestedRangeNotSatisfiable {
		t.Fatalf("越界该回 416,实得 %d —— 挪回最后一字节回 206 是「有效但错位」的数据", code)
	}
}

// 预取窗口 = min(缓存上限, 64MB),且**至少每 worker 一段**。
//
// ★ 这两件事以前共用一个值,是个真雷:缓存上限放开到 GB 级后,预取窗口跟着变成
// GB 级,一条连接会一路狂拉几个 G;而被播放器丢下的连接**正是照着这个窗口把量
// 拉满才停** —— 跳一次进度条的代价从白拉 32MB 升级成白拉几 GB。
func TestC26_预取窗口与缓存上限是两件事(t *testing.T) {
	if got := readAheadBytes(3, 4*1024*1024*1024); got != MaxReadAhead {
		t.Errorf("缓存上限是**天花板**不是下限:4GB 时窗口该被钳到 %d,实得 %d", MaxReadAhead, got)
	}
	if got := readAheadBytes(3, 1024); got != 3*ChunkSize {
		t.Errorf("缓存上限很小时窗口至少每 worker 一段,实得 %d", got)
	}
	if got := readAheadBytes(2, 32*1024*1024); got != 32*1024*1024 {
		t.Errorf("区间内原样,实得 %d", got)
	}
}

// 线程数钳进 2~4。
func TestC26_线程数钳位(t *testing.T) {
	up := newUpstream(t)
	for _, c := range []struct{ in, want int }{{1, 2}, {2, 2}, {4, 4}, {99, 4}} {
		paths.SetRoot(t.TempDir())
		h, err := Start(context.Background(), up.URL+"/v.mkv", c.in, 64*1024*1024, nil)
		if err != nil {
			t.Fatal(err)
		}
		if h.origin.threads != c.want {
			t.Errorf("threads=%d 该钳到 %d,实得 %d", c.in, c.want, h.origin.threads)
		}
		h.Close()
	}
}

// 上游给不出文件大小时**不能代理**,要让调用方回退直连。
//
// ★ 没有 total 就发不出正确的 Content-Length,播放器算不出进度条也没法 seek。
func TestC26_没有文件大小就不代理(t *testing.T) {
	bad := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.WriteHeader(200) // 没有 Content-Range
	}))
	defer bad.Close()
	paths.SetRoot(t.TempDir())
	if h, err := Start(context.Background(), bad.URL+"/v.mkv", 2, 64*1024*1024, nil); err == nil {
		h.Close()
		t.Fatal("拿不到文件大小时必须失败,让调用方回退直连")
	}
}

// 缓存文件在句柄关闭后要删掉,不留垃圾。
func TestC26_关闭即清缓存文件(t *testing.T) {
	up := newUpstream(t)
	h := startProxy(t, up, 2, 64*1024*1024)
	getRange(t, h, 0, 1023)
	path := h.origin.disk.path
	h.Close()
	if _, err := osStat(path); err == nil {
		t.Fatalf("缓存文件没删掉: %s —— 实测用户机器上躺着一周前的残留", path)
	}
}

// ★★ 判据 8:段被别的连接挤出槽位后**必须能被重拉**,不能饿死。
//
// 环形缓存是全连接共享的(槽位 = chunk % ring),两条连接的段号模 ring 同余就同槽,
// 后写的直接盖掉先写的。而 worker 认领时游标已经自增越过那一段 ——
// **再没有人会去重拉它**,于是供给端无限空转:has() 永远 false,又不在 failed 里。
// 表现就是那条连接彻底饿死(播放器侧 = 有流量、黑屏 / 永远缓冲)。
//
// ★ 为什么不用「两条并发连接」来测:那样能不能撞上取决于时序,
// Rust 侧那条同款用例正是**偶发**红的 —— 偶发红的门禁等于没有门禁。
// 这里直接把「游标已越过 + 段不在盘上 + 不在飞」这个状态摆出来,确定性地验它。
func TestC26_段被挤掉后能重拉不饿死(t *testing.T) {
	up := newUpstream(t)
	h := startProxy(t, up, 2, 64*1024*1024)

	const c = int64(2)
	s := &stream{
		o: h.origin, firstChunk: 0, lastChunk: 7, headWithin: 0,
		failed: map[int64]bool{}, inFlight: map[int64]bool{},
		serveChunk: c,
		// ★ 游标**已经越过** c —— 正常路径下再没有人会去认领它
		fetchCursor: c + 3,
		done:        make(chan struct{}),
	}
	defer s.finish()
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	go s.worker(ctx)

	got := make(chan []byte, 1)
	go func() { got <- s.nextBytes(c, 0) }()
	select {
	case b := <-got:
		if len(b) == 0 {
			t.Fatal("重拉之后该拿到字节")
		}
		assertBytes(t, c*ChunkSize, b)
	case <-time.After(15 * time.Second):
		t.Fatal("段被挤掉之后没人重拉 —— 那条连接饿死了(播放器侧 = 有流量、黑屏/永远缓冲)")
	}
}
