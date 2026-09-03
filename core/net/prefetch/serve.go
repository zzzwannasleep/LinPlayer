package prefetch

// 每连接的顺序取数窗口 + HTTP 供给。
//
// 移植自 `crates/core/src/net/prefetch.rs` 的 Stream / handle。

import (
	"bufio"
	"context"
	"fmt"
	"net"
	"strconv"
	"strings"
	"sync"
	"time"
)

// stream 每连接的顺序取数窗口。连接结束即 done,它的 worker 随之退出。
// **不持有分段数据**(数据在 diskCache 里,全连接共享)。
type stream struct {
	o          *origin
	firstChunk int64
	lastChunk  int64
	// headWithin 请求起点在首段内的偏移。0 = 正好对齐。
	headWithin int

	// headLive 首段的**残段**载体(只覆盖 [headWithin, 段尾))。
	//
	// ★ 为什么它不进共享登记处也不落盘:它是**残的**。写进环形缓存会把
	// [0, headWithin) 那截垃圾一起标成就绪,别的连接读同一段就拿到脏数据 ——
	// 那是不报错、只坏画面的一类。挂在本连接上、随连接消亡,最省事也最安全。
	// 代价是这一小段不进缓存(seek 回来要重下),换来每次 seek 少等平均 2MB。
	headMu   sync.Mutex
	headLive *live

	mu sync.Mutex
	// failed 永久失败(供给端遇到即断流)
	failed map[int64]bool
	// serveChunk 下一个要供给的分段;fetchCursor 下一个要分配给 worker 的分段
	serveChunk  int64
	fetchCursor int64
	// inFlight 已被 worker 认领、还没落盘的分段。
	//
	// ★ 必须有它才能把「在飞」和「被环形缓存挤掉」分开:两者的 has() 都是 false,
	// 但前者只需等,后者必须重拉。分不开就会把在飞的段又拉一遍(重复下载 = 烧用户流量)。
	inFlight map[int64]bool

	dataNotify   notifier // worker -> serve:某段就绪/失败
	windowNotify notifier // serve -> worker:窗口推进
	done         chan struct{}
	doneOnce     sync.Once
}

func (s *stream) over() bool {
	select {
	case <-s.done:
		return true
	default:
		return s.o.over()
	}
}

func (s *stream) finish() {
	s.doneOnce.Do(func() { close(s.done) })
	s.windowNotify.notifyAll()
	s.dataNotify.notifyAll()
}

// worker 在窗口内顺序认领分段并拉取。
func (s *stream) worker(ctx context.Context) {
	for !s.over() {
		// 认领:窗口未满且未到本次请求末段才取下一段
		s.mu.Lock()
		var c int64 = -1
		if s.fetchCursor <= s.lastChunk && s.fetchCursor <= s.serveChunk+s.o.readAheadChunks-1 {
			c = s.fetchCursor
			s.fetchCursor++
		}
		s.mu.Unlock()

		if c < 0 {
			// 窗口满(mpv 读得慢 = 背压)或已取到末段:等推进,250ms 兜底防丢唤醒
			select {
			case <-s.windowNotify.wait():
			case <-time.After(250 * time.Millisecond):
			case <-s.done:
				return
			}
			continue
		}
		// 已在盘上就别再下一遍(seek 回看 / 两条连接区间重叠时命中)
		if s.o.disk.has(c) {
			continue
		}
		s.mu.Lock()
		s.inFlight[c] = true
		s.mu.Unlock()

		/* 首段若不对齐,只拉播放器真正要的那截(残段),挂在本连接上不进共享登记处。

		   ☠☠ **但钉住的那几段例外 —— 它们必须整段拉、必须落盘。**

		   播放器打开一个 moov 在末尾的 mp4 时,发的正是
		   `Range: bytes=<文件尾附近>-` —— 从块中间开始,于是走这条残段路径,
		   于是**索引那一段永远进不了环形缓存**。后果:任何人想重新打开这条流
		   (进度条缩略图就是)都会失败,而现象只有一句「打不开」。
		   2026-09-03 为此查了四轮:头明明缓存着,spans 也报着 75%,就是开不了。

		   ★ 代价是这一次读要多拉不到 4MB,而且只发生在文件头/尾那两三段上 ——
		     换掉的是「这个功能在半数片子上根本不工作」。 */
		partial := c == s.firstChunk && s.headWithin > 0 && !s.o.disk.pinned(c)
		var l *live
		registered := false
		if partial {
			l = newLiveBased(s.headWithin, s.o.chunkLen(c)-s.headWithin)
			s.headMu.Lock()
			s.headLive = l
			s.headMu.Unlock()
		} else {
			l, registered = s.o.liveBegin(c)
		}

		/* ★ 在飞的请求也要能取消。只靠循环顶部的 over() 判断,是「这一段拉完了才发现
		   连接早没了」—— 播放器跳一次进度条,每条被丢下的连接还要把 threads 段(12MB)
		   拉完才罢休,纯烧用户流量。 */
		fetchCtx, cancel := context.WithCancel(ctx)
		go func() {
			select {
			case <-s.done:
				cancel()
			case <-fetchCtx.Done():
			}
		}()
		data := s.o.fetchChunk(fetchCtx, c, l)
		cancel()

		// 落盘成功才算就绪;写盘失败(磁盘满/被删)等同取数失败。
		// 残段**不落盘**,取到即算成功,供给端从载体里读。
		ok := false
		switch {
		case data != nil && partial:
			ok = true
		case data != nil:
			ok = s.o.disk.put(c, data)
		}
		s.o.liveEnd(c, l, registered) // ★ 必须在落盘之后,别留查不到的空档

		s.mu.Lock()
		delete(s.inFlight, c)
		if !ok {
			s.failed[c] = true
		}
		s.mu.Unlock()
		s.dataNotify.notifyAll()
	}
}

// advanceServe 供给推进:腾出窗口、清除已消费分段。
func (s *stream) advanceServe(next int64) {
	s.mu.Lock()
	if next <= s.serveChunk {
		s.mu.Unlock()
		return
	}
	for c := s.serveChunk; c < next; c++ {
		delete(s.failed, c) // 分段数据留在盘上,seek 回看可直接命中
	}
	s.serveChunk = next
	s.mu.Unlock()

	if next > s.firstChunk {
		// 首段已消费完,残段载体没人再读了,别让那几 MB 挂到连接结束
		s.headMu.Lock()
		s.headLive = nil
		s.headMu.Unlock()
	}
	s.windowNotify.notifyAll()
}

// nextBytes 取分段 c 内、从段内偏移 within 起**当前拿得到**的字节(至少 1 字节)。
// 返回 nil = 失败 / 停服,供给端据此断流。
//
// ★★ 「有多少给多少」,不是「等整段就绪」。整段就绪是**预取**该有的粒度,
// 不是**供给**该有的粒度 —— 见 live 头部那笔 56~143KB/s 的账。
func (s *stream) nextBytes(c int64, within int) []byte {
	for {
		if s.over() {
			return nil
		}
		if s.o.disk.has(c) {
			// get 返回 nil = 刚好被别的连接挤出槽位(**不是**取数失败),
			// 落到下面的自愈分支重拉 —— 当失败断流就是给播放器一个 early eof
			if b := s.o.disk.get(c, s.o.chunkLen(c)); b != nil && within < len(b) {
				out := make([]byte, len(b)-within)
				copy(out, b[within:])
				return out
			}
		}

		/* 整段还没落盘,但它可能**正在飞** —— 已经到货的那部分立刻给播放器。
		   起播只需要头几百 KB,等满 4MB 是纯粹的白等。
		   先看本连接首段的残段载体,再看共享登记处。 */
		var l *live
		if c == s.firstChunk {
			s.headMu.Lock()
			l = s.headLive
			s.headMu.Unlock()
		}
		if l == nil {
			l = s.o.liveGet(c)
		}
		if l != nil {
			if part := l.sliceFrom(within); part != nil {
				return part
			}
			if !l.isDone() {
				select {
				case <-l.n.wait():
				case <-time.After(250 * time.Millisecond):
				case <-s.done:
					return nil
				}
				continue
			}
		}

		s.mu.Lock()
		if s.failed[c] {
			s.mu.Unlock()
			return nil
		}
		/* ★★ 自愈:我要的这段**曾经拉过、但被挤掉了**,得重拉,不能干等。

		   环形缓存是**全连接共享**的,槽位 = chunk % ring。两条连接的分段号只要
		   模 ring 同余就落同一个槽,后写的直接盖掉先写的。
		   而 worker 认领时游标已经自增越过 c,**再没有人会去重拉它** ——
		   于是这里无限空转:has() 永远 false,又不在 failed 里。
		   表现就是那条连接彻底饿死(播放器侧 = 有流量、黑屏/永远缓冲)。

		   把游标倒回 c 让 worker 重新认领即可。倒回是幂等的:已经 <= c 就不动,
		   所以不会和正在飞的那次打架;重拉一次的代价远小于饿死。 */
		if s.fetchCursor > c && !s.inFlight[c] {
			s.fetchCursor = c
			s.mu.Unlock()
			s.windowNotify.notifyAll()
		} else {
			s.mu.Unlock()
		}
		select {
		case <-s.dataNotify.wait():
		case <-time.After(250 * time.Millisecond):
		case <-s.done:
			return nil
		}
	}
}

// serve 顺序把 [start,end] 喂给播放器。
func (s *stream) serve(conn net.Conn, start, end int64) error {
	pos := start
	for pos <= end && !s.over() {
		c := pos / ChunkSize
		within := int(pos - c*ChunkSize)
		piece := s.nextBytes(c, within)
		if len(piece) == 0 {
			break // 失败 / 停服 -> 断流,播放器回退直连
		}
		need := int(end - pos + 1)
		n := len(piece)
		if n > need {
			n = need
		}
		// write 在 mpv 读慢时自然阻塞 → 端到端背压,预取停在窗口内
		if _, err := conn.Write(piece[:n]); err != nil {
			return err // 播放器跳走了
		}
		pos += int64(n)
		// 整段消费完才推进窗口(拿到的可能只是这一段的一部分)
		if within+n >= s.o.chunkLen(c) {
			s.advanceServe(c + 1)
		}
	}
	return nil
}

// handle 处理播放器的一次 HTTP 请求(GET/HEAD,可带 Range)。
// mpv 是唯一受控客户端,手写最小 HTTP/1.1。
func (o *origin) handle(conn *net.TCPConn) error {
	method, path, rangeStart, rangeEnd, hasRange, err := readRequest(conn)
	if err != nil {
		return err
	}
	// 只读缓存端点(见 serveCached)。路径是普通端点和它唯一的区别。
	cachedOnly := path == cachedPath

	/* ★ 越界判定必须在**钳位之前**用原始 start:原来先 min 再判,那个分支就永远
	   进不去(死代码),越界请求会被悄悄挪回最后一字节回一个 206 ——
	   播放器拿到的是「有效但错位」的数据。 */
	if hasRange && rangeStart >= o.totalSize {
		_, _ = conn.Write([]byte("HTTP/1.1 416 Range Not Satisfiable\r\nContent-Length: 0\r\nConnection: close\r\n\r\n"))
		return nil
	}

	start, end := int64(0), o.totalSize-1
	if hasRange {
		start = rangeStart
		if rangeEnd >= 0 && rangeEnd < end {
			end = rangeEnd
		}
		if end < start {
			end = start
		}
	}

	/* 只读端点:能给多少**在这儿就定死**,给不出就 416。

	   ★ 必须算在写响应头之前 —— Content-Length 说了多少就得吐多少;
	     边吐边发现没了只能断流,而 ffmpeg 把提前断流当成**文件损坏**,
	     不是「读到尾」。那会让缩略图这条路从「这个位置没有图」变成「这个文件坏了」。 */
	if cachedOnly {
		run := o.cachedRun(start, end)
		if run <= 0 {
			_, _ = conn.Write([]byte(status416))
			return nil
		}
		end = start + run - 1
	}

	var head strings.Builder
	if hasRange {
		head.WriteString("HTTP/1.1 206 Partial Content\r\n")
		fmt.Fprintf(&head, "Content-Range: bytes %d-%d/%d\r\n", start, end, o.totalSize)
	} else {
		head.WriteString("HTTP/1.1 200 OK\r\n")
	}
	head.WriteString("Accept-Ranges: bytes\r\n")
	/* ★★ 必须显式 `Connection: close`。这就是「有流量、没画面没声音」的根因之一。

	   我们每条 TCP 只读**一个**请求,然后把 body 一直喂到结束。可 HTTP/1.1 默认是
	   **长连接**,不写这个头就是在对播放器承诺「这条连接还能再发请求」。
	   ffmpeg 一 seek(MKV 索引在末尾,起播必 seek;续播还要再跳一次)就把
	   `Range: bytes=<末尾>-` **管线化发在同一条 socket 上** —— 那个请求没人读,
	   响应永远不来。实测 ffprobe:`1 connection, 1 request, 0 seeks`,
	   seek 静默失败后退化成**从头线性读完整个文件**(289MB 全下),而播放器在干等。

	   声明 close 后 ffmpeg 每次 seek 老老实实新开一条连接,
	   正好落进「每连接独立窗口」的设计。 */
	head.WriteString("Connection: close\r\n")
	fmt.Fprintf(&head, "Content-Type: %s\r\n", o.contentType)
	fmt.Fprintf(&head, "Content-Length: %d\r\n\r\n", end-start+1)
	if _, err := conn.Write([]byte(head.String())); err != nil {
		return err
	}
	if method == "HEAD" {
		return nil
	}
	if cachedOnly {
		return o.serveCached(conn, start, end)
	}

	first := start / ChunkSize
	s := &stream{
		o: o, firstChunk: first, lastChunk: end / ChunkSize,
		headWithin:  int(start - first*ChunkSize),
		failed:      map[int64]bool{},
		serveChunk:  first,
		fetchCursor: first,
		inFlight:    map[int64]bool{},
		done:        make(chan struct{}),
	}
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	for i := 0; i < o.threads; i++ {
		go s.worker(ctx)
	}
	err = s.serve(conn, start, end)
	s.finish() // 供给结束 -> 本连接 worker 退出、取消在飞的 fetch
	return err
}

// readRequest 读 HTTP 请求头至 \r\n\r\n。
// mpv 客户端行为可控,只解析所需(method + Range)。
func readRequest(conn net.Conn) (method, path string, start, end int64, hasRange bool, err error) {
	br := bufio.NewReader(conn)
	method, path, start, end = "GET", "/", 0, -1
	first := true
	for {
		line, e := br.ReadString('\n')
		if e != nil {
			return method, path, start, end, hasRange, e
		}
		line = strings.TrimRight(line, "\r\n")
		if first {
			// "GET /cached HTTP/1.1"
			if f := strings.Fields(line); len(f) >= 2 {
				method, path = f[0], f[1]
			} else if i := strings.Index(line, " "); i > 0 {
				method = line[:i]
			}
			first = false
			continue
		}
		if line == "" {
			return method, path, start, end, hasRange, nil
		}
		if k, v, ok := strings.Cut(line, ":"); ok && strings.EqualFold(strings.TrimSpace(k), "range") {
			if s, e2, ok := parseRange(strings.TrimSpace(v)); ok {
				start, end, hasRange = s, e2, true
			}
		}
	}
}

// parseRange 解析 `bytes=start-end` / `bytes=start-`。
//
// ★ 后缀范围(`bytes=-N`)**不支持**:总长度在这一层已知,本可以算,
// 但代理这条路上 mpv 从不发后缀范围,而支持它就要多一条分支和一份测试。
// 不支持时返回 ok=false,调用方按「没带 Range」处理 —— 那是**安全**的降级
// (给全量),不会给出错位数据。
func parseRange(v string) (start, end int64, ok bool) {
	spec, found := strings.CutPrefix(v, "bytes=")
	if !found {
		return 0, -1, false
	}
	spec, _, _ = strings.Cut(spec, ",")
	s, e, found := strings.Cut(strings.TrimSpace(spec), "-")
	if !found || strings.TrimSpace(s) == "" {
		return 0, -1, false
	}
	start, err := strconv.ParseInt(strings.TrimSpace(s), 10, 64)
	if err != nil {
		return 0, -1, false
	}
	end = -1
	if t := strings.TrimSpace(e); t != "" {
		if v, err := strconv.ParseInt(t, 10, 64); err == nil {
			end = v
		}
	}
	return start, end, true
}

// cachedRun 从 start 起、**已经躺在盘上**的连续字节数(截到 end 为止)。
func (o *origin) cachedRun(start, end int64) int64 {
	var n int64
	for pos := start; pos <= end; {
		c := pos / ChunkSize
		if !o.disk.has(c) {
			break
		}
		segEnd := c*ChunkSize + int64(o.chunkLen(c)) - 1
		if segEnd > end {
			segEnd = end
		}
		n += segEnd - pos + 1
		pos = segEnd + 1
	}
	return n
}

// serveCached 只读端点的供给:**只吐盘上已有的,一个字节都不去上游取**。
//
// ★★ 它存在的理由是缩略图那条路。取缩略图的那个 mpv 如果走普通端点,
// 它会自己开一条 stream + 一组 worker 顺序拉数据,于是:
//
//	① 用户明明说了「没缓存的不能用」,它却会**替用户下**;
//	② 更糟的是环形缓存**全连接共享**,它拉进来的段会把正在播的段挤掉 ——
//	   表现是「拖一下进度条看预览,正片开始卡」,而且不报错。
//
// 所以这不是「普通端点加个开关」,而是一条**没有 worker 的**路。
// 「没缓存的不能用」这条规矩因此落在了传输层:缩略图那边不需要先判断能不能用,
// 它只是取数失败而已。判断和事实分成两处写,迟早会对不上。
func (o *origin) serveCached(conn net.Conn, start, end int64) error {
	for pos := start; pos <= end; {
		c := pos / ChunkSize
		b := o.disk.get(c, o.chunkLen(c))
		// 刚才还在、这会儿被别的连接挤掉了(TOCTOU)。断流即可 ——
		// 缩略图那边失败一次就是「这个位置没有图」,正是要的语义。
		if b == nil {
			return nil
		}
		within := int(pos - c*ChunkSize)
		if within >= len(b) {
			return nil
		}
		piece := b[within:]
		if need := int(end - pos + 1); len(piece) > need {
			piece = piece[:need]
		}
		if _, err := conn.Write(piece); err != nil {
			return err
		}
		pos += int64(len(piece))
	}
	return nil
}
