// Package download 多线程(分段)下载管理器。
//
// 移植自 `crates/core/src/download.rs`。**Rust 版是黄金实现。**
//
//   - 同一时刻只下**一个文件**,单文件内部 1–4 分段(线程)并发,用 HTTP Range 分块。
//   - 每段写独立 `${file}.partN` 临时文件,全完成后按序拼接;
//     天然断点续传(重启按 part 大小恢复)。
//   - 探测大小 + Range 支持;不支持 Range / 未知大小 → 退回单段整流。
//
// 进度**不主动推送**,前端轮询 List()。一个活跃下载,不值得为它开一条事件流。
//
// ★ Go 这边不存在黄金实现里那条「裸 tokio::spawn 没有运行时上下文就 panic」的坑
// (goroutine 在哪儿都能开)。但**等价的坑换了个样子**:命令一返回,下载还在跑,
// 而进程可能正在关停 —— 所以 Close() 要能把在跑的那条掐掉并落盘,见本文件末尾。
package download

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net/http"
	"os"
	"path/filepath"
	"sort"
	"strconv"
	"strings"
	"sync"
	"time"
)

// Status 任务状态。线上是小写字符串。
type Status string

const (
	StatusQueued      Status = "queued"
	StatusDownloading Status = "downloading"
	StatusPaused      Status = "paused"
	StatusCompleted   Status = "completed"
	StatusFailed      Status = "failed"
	StatusCanceled    Status = "canceled"
)

// Segment 一个分段。End = -1 表示未知大小(单段整流)。
type Segment struct {
	Start      int64 `json:"start"`
	End        int64 `json:"end"`
	Downloaded int64 `json:"downloaded"`
}

func (s Segment) length() int64 { return s.End - s.Start + 1 }

// Item 一条下载任务。
type Item struct {
	ID            string    `json:"id"`
	ItemID        string    `json:"item_id"`
	MediaSourceID *string   `json:"media_source_id"`
	Type          string    `json:"type"`
	Title         string    `json:"title"`
	SeriesID      *string   `json:"series_id"`
	SeriesName    *string   `json:"series_name"`
	SeasonNumber  *int64    `json:"season_number"`
	EpisodeNumber *int64    `json:"episode_number"`
	PosterURL     *string   `json:"poster_url"`
	Container     string    `json:"container"`
	URL           string    `json:"url"`
	FilePath      string    `json:"file_path"`
	TotalBytes    int64     `json:"total_bytes"`
	Status        Status    `json:"status"`
	Error         *string   `json:"error"`
	AddedAt       int64     `json:"added_at"`
	SupportsRange bool      `json:"supports_range"`
	Segments      []Segment `json:"segments"`

	// 派生字段:已收字节 + 进度。序列化出去,前端直接读。
	ReceivedBytes int64   `json:"received_bytes"`
	Progress      float64 `json:"progress"`
}

func (it *Item) recompute() {
	var got int64
	for _, s := range it.Segments {
		got += s.Downloaded
	}
	it.ReceivedBytes = got
	if it.TotalBytes > 0 {
		p := float64(got) / float64(it.TotalBytes)
		if p > 1 {
			p = 1
		}
		it.Progress = p
	} else {
		it.Progress = 0
	}
}

func (it *Item) partPath(i int) string { return it.FilePath + ".part" + strconv.Itoa(i) }

// state 管理器的内部状态。**所有字段都由 mu 保护。**
type state struct {
	items          map[string]*Item
	dir            string
	indexPath      string
	activeID       string
	cancel         chan struct{} // 关掉它 = 让当前任务的所有分段停下来
	pendingRemoval map[string]bool
	threads        int
}

// Manager 下载管理器。
type Manager struct {
	mu     sync.Mutex
	st     state
	client *http.Client
	closed bool
	wg     sync.WaitGroup // 在跑的下载 goroutine,关停时等它们
}

// New 建一个管理器并恢复既有索引。
//
// ★ index.json 跟着 dir 走 —— 换 dir 等于换一份索引,
// 旧目录里的文件不会自动出现在列表里。
func New(dir string, c *http.Client) (*Manager, error) {
	if err := os.MkdirAll(dir, 0o755); err != nil {
		return nil, err
	}
	m := &Manager{
		client: c,
		st: state{
			items:          map[string]*Item{},
			dir:            dir,
			indexPath:      filepath.Join(dir, "index.json"),
			cancel:         make(chan struct{}),
			pendingRemoval: map[string]bool{},
			threads:        2,
		},
	}
	if raw, err := os.ReadFile(m.st.indexPath); err == nil {
		list, threads := decodeIndex(raw)
		if threads > 0 {
			m.st.threads = clamp(threads, 1, 4)
		}
		if list != nil {
			for _, it := range list {
				// ★ 被中断的「下载中」改成暂停,并按 part 文件的**实际大小**恢复。
				//   不改的话列表里永远挂着一条谁也不在跑的「下载中」。
				if it.Status == StatusDownloading {
					it.Status = StatusPaused
				}
				syncSegmentsFromDisk(it)
				it.recompute()
				m.st.items[it.ID] = it
			}
		}
	}
	m.processQueue()
	return m, nil
}

// SetThreads 分段数。**钳在 1~4**:再多对同一个文件只是给服务端添堵。
func (m *Manager) SetThreads(n int) {
	m.mu.Lock()
	m.st.threads = clamp(n, 1, 4)
	m.mu.Unlock()
	// ★ 立刻落盘。黄金实现里这个值只活在内存里,每次启动都回到 2 ——
	//   而 UI_PC §7.9 要的是「归核心层持久化,UI 只读不灌」。
	m.persist()
}

// Threads 当前分段数。
func (m *Manager) Threads() int {
	m.mu.Lock()
	defer m.mu.Unlock()
	return m.st.threads
}

// List 所有任务,按加入时间**倒序**(新的在上面)。
func (m *Manager) List() []Item {
	m.mu.Lock()
	defer m.mu.Unlock()
	out := make([]Item, 0, len(m.st.items))
	for _, it := range m.st.items {
		out = append(out, *it)
	}
	sort.Slice(out, func(i, j int) bool { return out[i].AddedAt > out[j].AddedAt })
	return out
}

// CompletedPath 某个媒体条目已下好的本地文件路径。没下完返回空串。
//
// ★ 起播时要拿它优先本地播放(SPEC §7.6)。判据是**状态 completed 且文件还在** ——
// 只判状态的话,用户手动删了文件之后会拿着一个不存在的路径去起播。
func (m *Manager) CompletedPath(itemID string) string {
	m.mu.Lock()
	defer m.mu.Unlock()
	for _, it := range m.st.items {
		if it.ItemID == itemID && it.Status == StatusCompleted {
			if st, err := os.Stat(it.FilePath); err == nil && !st.IsDir() {
				return it.FilePath
			}
		}
	}
	return ""
}

// Enqueue 入队。返回任务 id。
func (m *Manager) Enqueue(it *Item) string {
	m.mu.Lock()
	if it.ID == "" {
		it.ID = strconv.FormatInt(time.Now().UnixNano(), 36)
	}
	it.AddedAt = time.Now().UnixMilli()
	it.Status = StatusQueued
	if it.Container == "" {
		it.Container = "mkv"
	}
	it.FilePath = filepath.Join(m.st.dir, SafeName(it.Title)+"."+it.Container)
	if it.Segments == nil {
		it.Segments = []Segment{}
	}
	m.st.items[it.ID] = it
	id := it.ID
	m.mu.Unlock()

	m.persist()
	m.processQueue()
	return id
}

// Pause 暂停。当前正在下的那条会被掐断(分段各自看 cancel)。
func (m *Manager) Pause(id string) {
	m.mu.Lock()
	it, ok := m.st.items[id]
	if !ok {
		m.mu.Unlock()
		return
	}
	it.Status = StatusPaused
	if m.st.activeID == id {
		m.closeCancelLocked()
	}
	m.mu.Unlock()
	m.persist()
}

// Resume 继续。断点由 part 文件的实际大小决定,不信索引里记的数。
func (m *Manager) Resume(id string) {
	m.mu.Lock()
	it, ok := m.st.items[id]
	if !ok {
		m.mu.Unlock()
		return
	}
	if it.Status == StatusPaused || it.Status == StatusFailed {
		it.Status = StatusQueued
		it.Error = nil
	}
	m.mu.Unlock()
	m.persist()
	m.processQueue()
}

// Remove 删任务 **并删文件**。
//
// ★ 正在下的那条不能直接从表里摘掉:分段还在往 part 文件里写。
// 先标记 pendingRemoval + 掐断,等收尾那一步再真删 —— 否则删完的下一秒
// 又被写回来一个半截文件。
func (m *Manager) Remove(id string) {
	m.mu.Lock()
	it, ok := m.st.items[id]
	if !ok {
		m.mu.Unlock()
		return
	}
	if m.st.activeID == id {
		it.Status = StatusCanceled
		m.st.pendingRemoval[id] = true
		m.closeCancelLocked()
		m.mu.Unlock()
		return // 收尾那一步会删
	}
	delete(m.st.items, id)
	snapshot := *it
	m.mu.Unlock()

	deleteFiles(&snapshot)
	m.persist()
}

// ClearCompleted 清掉已完成的**记录**。返回清掉的条数。
//
// ★★ **只清记录,不删文件。** 用户点「清除已完成」是想收拾列表,不是想丢文件。
func (m *Manager) ClearCompleted() int {
	m.mu.Lock()
	n := 0
	for id, it := range m.st.items {
		if it.Status == StatusCompleted {
			delete(m.st.items, id)
			n++
		}
	}
	m.mu.Unlock()
	if n > 0 {
		m.persist()
	}
	return n
}

// Close 关停:掐断在跑的任务,等它退出,落盘。
//
// ★ 不等的话,进程退出时正在写的 part 文件会停在一个**没记进索引**的长度上。
// 下次启动按文件实际大小恢复,所以不会坏 —— 但索引里的进度会明显偏小,
// 用户看到的是「上次明明下了一半,怎么回到 10% 了」。
func (m *Manager) Close() {
	m.mu.Lock()
	if m.closed {
		m.mu.Unlock()
		return
	}
	m.closed = true
	m.closeCancelLocked()
	m.mu.Unlock()

	m.wg.Wait()
	m.persist()
}

// closeCancelLocked 关掉当前的 cancel 通道并换一个新的。**调用方必须持锁。**
//
// ★ 用「关通道」而不是布尔量:所有分段都在 select 上等它,关一次全部立刻醒。
// 布尔量要靠轮询,而分段大多数时间阻塞在网络读上,轮询不到。
func (m *Manager) closeCancelLocked() {
	select {
	case <-m.st.cancel: // 已经关过了
	default:
		close(m.st.cancel)
	}
}

// ---------------------------------------------------------------------------
// 下载核心
// ---------------------------------------------------------------------------

func (m *Manager) processQueue() {
	m.mu.Lock()
	if m.closed || m.st.activeID != "" {
		m.mu.Unlock()
		return
	}
	// 队列里加入时间最早的那条
	var next *Item
	for _, it := range m.st.items {
		if it.Status != StatusQueued {
			continue
		}
		if next == nil || it.AddedAt < next.AddedAt {
			next = it
		}
	}
	if next == nil {
		m.mu.Unlock()
		return
	}
	id := next.ID
	m.st.activeID = id
	m.st.cancel = make(chan struct{})
	cancel := m.st.cancel
	next.Status = StatusDownloading
	next.Error = nil
	m.wg.Add(1)
	m.mu.Unlock()

	go func() {
		defer m.wg.Done()
		m.runOne(id, cancel)
	}()
}

func (m *Manager) runOne(id string, cancel chan struct{}) {
	err := m.downloadItem(id, cancel)

	m.mu.Lock()
	if it, ok := m.st.items[id]; ok {
		if err == nil {
			if it.TotalBytes <= 0 {
				var sum int64
				for _, s := range it.Segments {
					sum += s.Downloaded
				}
				it.TotalBytes = sum
			}
			it.Status = StatusCompleted
			it.recompute()
		} else if it.Status == StatusDownloading {
			// pause / remove 已经把状态改掉了;只有还挂着「下载中」的才算失败
			it.Status = StatusFailed
			msg := err.Error()
			it.Error = &msg
		}
	}
	m.st.activeID = ""
	removing := m.st.pendingRemoval[id]
	delete(m.st.pendingRemoval, id)
	var snapshot *Item
	if removing {
		if it, ok := m.st.items[id]; ok {
			cp := *it
			snapshot = &cp
			delete(m.st.items, id)
		}
	}
	m.mu.Unlock()

	if snapshot != nil {
		deleteFiles(snapshot)
	}
	m.persist()
	m.processQueue()
}

func (m *Manager) downloadItem(id string, cancel chan struct{}) error {
	it := m.snapshot(id)
	if it == nil {
		return errors.New("任务不存在")
	}

	if it.TotalBytes <= 0 && len(it.Segments) == 0 {
		total, supports := probe(m.client, it.URL, cancel)
		m.mu.Lock()
		if cur, ok := m.st.items[id]; ok {
			if total > 0 {
				cur.TotalBytes = total
			}
			cur.SupportsRange = supports
			buildSegments(cur, m.st.threads)
		}
		m.mu.Unlock()
	} else {
		m.mu.Lock()
		if cur, ok := m.st.items[id]; ok && len(cur.Segments) == 0 {
			buildSegments(cur, m.st.threads)
		}
		m.mu.Unlock()
		// 续传:按 part 文件的**实际大小**恢复,不信索引里记的数
		if cur := m.snapshot(id); cur != nil {
			syncSegmentsFromDisk(cur)
			m.writeSegments(id, cur)
		}
	}

	it = m.snapshot(id)
	if it == nil {
		return errors.New("任务不存在")
	}
	n := len(it.Segments)
	if n == 0 {
		return errors.New("分不出可下载的区间")
	}

	// 并发跑所有分段。一段出错 → 立刻掐掉其余(别让另外三条继续白下)。
	var (
		wg      sync.WaitGroup
		errMu   sync.Mutex
		firstEr error
	)
	segCancel := make(chan struct{})
	var once sync.Once
	stopAll := func() { once.Do(func() { close(segCancel) }) }

	for i := 0; i < n; i++ {
		wg.Add(1)
		go func(idx int) {
			defer wg.Done()
			if err := m.runSegment(id, idx, cancel, segCancel); err != nil {
				errMu.Lock()
				if firstEr == nil {
					firstEr = err
				}
				errMu.Unlock()
				stopAll()
			}
		}(i)
	}
	wg.Wait()
	stopAll()

	if firstEr != nil {
		return firstEr
	}

	it = m.snapshot(id)
	if it == nil {
		return errors.New("任务不存在")
	}
	return assemble(it)
}

func (m *Manager) runSegment(id string, index int, cancel, segCancel chan struct{}) error {
	it := m.snapshot(id)
	if it == nil {
		return errors.New("任务不存在")
	}
	if index >= len(it.Segments) {
		return errors.New("分段越界")
	}
	seg := it.Segments[index]
	part := it.partPath(index)

	// 已经下了多少 —— 看**文件**,不看索引
	var existing int64
	if st, err := os.Stat(part); err == nil {
		existing = st.Size()
	}
	if seg.End >= 0 && existing > seg.length() {
		existing = seg.length()
	}
	m.updateDownloaded(id, index, existing)
	if seg.End >= 0 && existing >= seg.length() {
		return nil // 这一段早就完了
	}

	ctx, stop := context.WithCancel(context.Background())
	defer stop()
	go func() {
		select {
		case <-cancel:
		case <-segCancel:
		case <-ctx.Done():
			return
		}
		stop() // 掐断正在进行的读
	}()

	req, err := http.NewRequestWithContext(ctx, http.MethodGet, it.URL, nil)
	if err != nil {
		return err
	}
	if it.SupportsRange {
		if seg.End >= 0 {
			req.Header.Set("Range", fmt.Sprintf("bytes=%d-%d", seg.Start+existing, seg.End))
		} else if existing > 0 {
			req.Header.Set("Range", fmt.Sprintf("bytes=%d-", existing))
		}
	}
	resp, err := m.client.Do(req)
	if err != nil {
		return friendlyErr(err, cancel, segCancel)
	}
	defer resp.Body.Close()
	if resp.StatusCode >= 400 {
		return statusErr(resp.StatusCode)
	}

	f, err := os.OpenFile(part, os.O_CREATE|os.O_WRONLY|os.O_APPEND, 0o644)
	if err != nil {
		return err
	}
	defer f.Close()

	buf := make([]byte, 256*1024)
	downloaded := existing
	for {
		select {
		case <-cancel:
			return errors.New("已暂停")
		case <-segCancel:
			return errors.New("已取消")
		default:
		}
		nr, err := resp.Body.Read(buf)
		if nr > 0 {
			if _, werr := f.Write(buf[:nr]); werr != nil {
				return werr
			}
			downloaded += int64(nr)
			m.updateDownloaded(id, index, downloaded)
		}
		if err == io.EOF {
			return nil
		}
		if err != nil {
			return friendlyErr(err, cancel, segCancel)
		}
	}
}

// ---------------------------------------------------------------------------
// 小工具
// ---------------------------------------------------------------------------

func (m *Manager) snapshot(id string) *Item {
	m.mu.Lock()
	defer m.mu.Unlock()
	it, ok := m.st.items[id]
	if !ok {
		return nil
	}
	cp := *it
	cp.Segments = append([]Segment(nil), it.Segments...)
	return &cp
}

func (m *Manager) writeSegments(id string, src *Item) {
	m.mu.Lock()
	defer m.mu.Unlock()
	if it, ok := m.st.items[id]; ok {
		it.Segments = append([]Segment(nil), src.Segments...)
		it.recompute()
	}
}

func (m *Manager) updateDownloaded(id string, index int, v int64) {
	m.mu.Lock()
	defer m.mu.Unlock()
	if it, ok := m.st.items[id]; ok && index < len(it.Segments) {
		it.Segments[index].Downloaded = v
		it.recompute()
	}
}

func (m *Manager) persist() {
	m.mu.Lock()
	list := make([]*Item, 0, len(m.st.items))
	for _, it := range m.st.items {
		list = append(list, it)
	}
	path := m.st.indexPath
	b, err := json.Marshal(indexFile{Threads: m.st.threads, Items: list})
	m.mu.Unlock()
	if err != nil {
		return
	}
	// ★ 临时文件 + rename:写到一半断电的话,就地重写会留下一份**半截的 JSON**,
	//   下次启动整个下载列表读不出来(而文件其实都还在)。
	tmp := path + ".tmp"
	if os.WriteFile(tmp, b, 0o644) == nil {
		_ = os.Rename(tmp, path)
	}
}

// syncSegmentsFromDisk 按 part 文件的实际大小校正各段进度。
func syncSegmentsFromDisk(it *Item) {
	for i := range it.Segments {
		part := it.partPath(i)
		st, err := os.Stat(part)
		if err != nil {
			continue
		}
		l := st.Size()
		seg := it.Segments[i]
		// ★ 分段文件超出区间长度(僵尸写入):**截断**,否则拼接时整条错位,
		//   而错位的表现是「下完了,播放器说文件损坏」。
		if seg.End >= 0 && l > seg.length() {
			if f, err := os.OpenFile(part, os.O_WRONLY, 0o644); err == nil {
				_ = f.Truncate(seg.length())
				_ = f.Close()
			}
			l = seg.length()
		}
		if seg.End >= 0 {
			it.Segments[i].Downloaded = clamp64(l, 0, seg.length())
		} else {
			it.Segments[i].Downloaded = l
		}
	}
}

// probe 探测文件大小与 Range 支持。
//
// ★ 用 `Range: bytes=0-0` 而不是 HEAD:有的服务端 HEAD 不给 Content-Length,
// 有的干脆不支持 HEAD。一个字节的 GET 两样都能问出来。
func probe(c *http.Client, url string, cancel chan struct{}) (int64, bool) {
	ctx, stop := context.WithCancel(context.Background())
	defer stop()
	go func() {
		select {
		case <-cancel:
			stop()
		case <-ctx.Done():
		}
	}()
	req, err := http.NewRequestWithContext(ctx, http.MethodGet, url, nil)
	if err != nil {
		return 0, false
	}
	req.Header.Set("Range", "bytes=0-0")
	resp, err := c.Do(req)
	if err != nil {
		return 0, false // 探测失败:退回单线程未知大小
	}
	defer resp.Body.Close()
	_, _ = io.Copy(io.Discard, io.LimitReader(resp.Body, 8))

	if resp.StatusCode == http.StatusPartialContent {
		// Content-Range: bytes 0-0/123456 —— 斜杠后面那截才是总长
		if cr := resp.Header.Get("Content-Range"); cr != "" {
			if i := strings.LastIndex(cr, "/"); i >= 0 {
				if n, err := strconv.ParseInt(strings.TrimSpace(cr[i+1:]), 10, 64); err == nil {
					return n, true
				}
			}
		}
	}
	total, _ := strconv.ParseInt(resp.Header.Get("Content-Length"), 10, 64)
	supports := strings.Contains(strings.ToLower(resp.Header.Get("Accept-Ranges")), "bytes")
	return total, supports
}

// buildSegments 切分段。
func buildSegments(it *Item, threads int) {
	total := it.TotalBytes
	if total <= 0 || !it.SupportsRange {
		it.Segments = []Segment{{Start: 0, End: -1}}
		return
	}
	// ★ 小文件(< 2MB)不分段:分段的开销(多开几条连接 + 拼接)比省下的时间还多。
	n := 1
	if total >= 2*1024*1024 {
		n = clamp(threads, 1, 4)
	}
	chunk := (total + int64(n) - 1) / int64(n)
	segs := make([]Segment, 0, n)
	for i := 0; i < n; i++ {
		start := int64(i) * chunk
		if start >= total {
			break
		}
		end := start + chunk - 1
		if i == n-1 || end > total-1 {
			end = total - 1
		}
		segs = append(segs, Segment{Start: start, End: end})
	}
	it.Segments = segs
	it.recompute()
}

// assemble 按序拼接各段,然后删掉 part 文件。
func assemble(it *Item) error {
	_ = os.Remove(it.FilePath)
	out, err := os.Create(it.FilePath)
	if err != nil {
		return err
	}
	for i := range it.Segments {
		f, err := os.Open(it.partPath(i))
		if err != nil {
			continue
		}
		_, cerr := io.Copy(out, f)
		_ = f.Close()
		if cerr != nil {
			_ = out.Close()
			return cerr
		}
	}
	if err := out.Close(); err != nil {
		return err
	}
	for i := range it.Segments {
		_ = os.Remove(it.partPath(i))
	}
	return nil
}

func deleteFiles(it *Item) {
	_ = os.Remove(it.FilePath)
	for i := range it.Segments {
		_ = os.Remove(it.partPath(i))
	}
}

// friendlyErr 把网络错误翻成人话。
//
// ★ 先看是不是**我们自己掐的** —— context canceled 的原文是英文的
// "context canceled",直接显示给用户等于什么都没说。
func friendlyErr(err error, cancel, segCancel chan struct{}) error {
	select {
	case <-cancel:
		return errors.New("已暂停")
	default:
	}
	select {
	case <-segCancel:
		return errors.New("已取消")
	default:
	}
	if errors.Is(err, context.DeadlineExceeded) {
		return errors.New("连接超时")
	}
	if errors.Is(err, context.Canceled) {
		return errors.New("已取消")
	}
	return errors.New("下载出错")
}

func statusErr(code int) error {
	if code == 401 || code == 403 {
		return errors.New("无下载权限")
	}
	return fmt.Errorf("服务器错误(%d)", code)
}

// SafeName 文件名净化。
//
// ★ Windows 上 `\ / : * ? " < > |` 都是非法字符,而片名里冒号极常见
// (「某某:第二部」)。不净化的话文件建不出来,而报错发生在下载**结束**时 ——
// 用户等了半小时才看到失败。
func SafeName(name string) string {
	const bad = `\/:*?"<>|`
	var b strings.Builder
	for _, r := range name {
		if strings.ContainsRune(bad, r) {
			b.WriteRune('_')
		} else {
			b.WriteRune(r)
		}
	}
	s := strings.TrimSpace(b.String())
	// ★ 按**字符**截断不是按字节:按字节会把一个汉字劈成两半,
	//   落在磁盘上就是一个乱码文件名。
	rs := []rune(s)
	if len(rs) > 60 {
		s = string(rs[:60])
	}
	if s == "" {
		return "video"
	}
	return s
}

func clamp(v, lo, hi int) int {
	if v < lo {
		return lo
	}
	if v > hi {
		return hi
	}
	return v
}

func clamp64(v, lo, hi int64) int64 {
	if v < lo {
		return lo
	}
	if v > hi {
		return hi
	}
	return v
}

// indexFile 索引文件的形状。
//
// ★★ 老格式是**裸数组**(黄金实现就这么写的)。加 threads 只能换成对象,
// 而换格式必须**两种都读得回来** —— 否则升级一次,用户的下载列表整个消失
// (文件其实都还在,只是列表空了,看起来像被清空了)。
type indexFile struct {
	Threads int     `json:"threads"`
	Items   []*Item `json:"items"`
}

// decodeIndex 两种格式都吃:新的对象格式,和老的裸数组。
func decodeIndex(raw []byte) ([]*Item, int) {
	var f indexFile
	if json.Unmarshal(raw, &f) == nil && f.Items != nil {
		return f.Items, f.Threads
	}
	var list []*Item
	if json.Unmarshal(raw, &list) == nil {
		return list, 0 // 老格式没有 threads,用默认值
	}
	return nil, 0
}
