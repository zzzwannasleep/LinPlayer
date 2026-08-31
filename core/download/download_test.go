package download

// 下载这块的判据分两类:
//   ① 分段算术(切分 / 断点 / 拼接)—— 错了的表现是「下完了,播放器说文件损坏」
//   ② 状态机(暂停 / 删除 / 清除)—— 错了的表现是「点了没反应」或「文件莫名其妙没了」
//
// 两类都不会报错,所以每条都得有测试。

import (
	"fmt"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"sync/atomic"
	"testing"
	"time"
)

// rangeServer 一台支持 Range 的假服务器,回可预测的内容(第 i 字节 = i%251)。
//
// ★ 内容**必须可预测**:拼接错位是这个模块最容易出的 bug,而拼错的文件
// 长度往往是对的 —— 只有逐字节比对才抓得到。
func rangeServer(t *testing.T, size int64) (*httptest.Server, *atomic.Int64) {
	t.Helper()
	var hits atomic.Int64
	s := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		hits.Add(1)
		w.Header().Set("Accept-Ranges", "bytes")
		start, end := int64(0), size-1
		if rg := r.Header.Get("Range"); strings.HasPrefix(rg, "bytes=") {
			parts := strings.SplitN(strings.TrimPrefix(rg, "bytes="), "-", 2)
			start, _ = strconv.ParseInt(parts[0], 10, 64)
			if len(parts) > 1 && parts[1] != "" {
				end, _ = strconv.ParseInt(parts[1], 10, 64)
			}
			if end > size-1 {
				end = size - 1
			}
			w.Header().Set("Content-Range", fmt.Sprintf("bytes %d-%d/%d", start, end, size))
			w.Header().Set("Content-Length", strconv.FormatInt(end-start+1, 10))
			w.WriteHeader(http.StatusPartialContent)
		} else {
			w.Header().Set("Content-Length", strconv.FormatInt(size, 10))
		}
		buf := make([]byte, end-start+1)
		for i := range buf {
			buf[i] = byte((start + int64(i)) % 251)
		}
		_, _ = w.Write(buf)
	}))
	t.Cleanup(s.Close)
	return s, &hits
}

func mgr(t *testing.T) *Manager {
	t.Helper()
	m, err := New(t.TempDir(), http.DefaultClient)
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(m.Close)
	return m
}

func waitDone(t *testing.T, m *Manager, id string, d time.Duration) Item {
	t.Helper()
	deadline := time.Now().Add(d)
	for time.Now().Before(deadline) {
		for _, it := range m.List() {
			if it.ID != id {
				continue
			}
			if it.Status == StatusCompleted || it.Status == StatusFailed {
				return it
			}
		}
		time.Sleep(20 * time.Millisecond)
	}
	t.Fatalf("等不到任务 %s 结束", id)
	return Item{}
}

// ★★ 端到端:多段并发下完之后,**逐字节**和源文件一致。
//
// 拼接错位的文件长度往往是对的,只有逐字节比对才抓得到 ——
// 而它的表现是「下完了,播放器说文件损坏」。
func TestDownload_多段拼接逐字节一致(t *testing.T) {
	const size = 5 * 1024 * 1024
	up, _ := rangeServer(t, size)
	m := mgr(t)
	m.SetThreads(4)

	id := m.Enqueue(&Item{ItemID: "i1", Title: "某部电影", Container: "mkv", URL: up.URL})
	it := waitDone(t, m, id, 30*time.Second)
	if it.Status != StatusCompleted {
		t.Fatalf("状态 %s,错误 %v", it.Status, deref(it.Error))
	}

	b, err := os.ReadFile(it.FilePath)
	if err != nil {
		t.Fatal(err)
	}
	if len(b) != size {
		t.Fatalf("长度 %d,应当 %d", len(b), size)
	}
	for i := range b {
		if b[i] != byte(i%251) {
			t.Fatalf("第 %d 字节对不上:%d != %d —— 分段拼接错位了", i, b[i], byte(i%251))
		}
	}
	// part 文件要清干净,不然下载目录里全是垃圾
	for i := 0; i < 8; i++ {
		if _, err := os.Stat(it.FilePath + ".part" + strconv.Itoa(i)); err == nil {
			t.Fatalf("part%d 没删掉", i)
		}
	}
}

// ★★ 断点续传:按 **part 文件的实际大小**恢复,不信索引里记的数。
//
// 索引是异步落盘的,进程被杀时它必然落后于磁盘。信索引 = 重下一段已经下过的,
// 而且因为是 append 写入,重下的那截会**追加**在后面 → 文件超长 → 拼接错位。
func TestDownload_断点按文件实际大小恢复(t *testing.T) {
	const size = 4 * 1024 * 1024
	up, _ := rangeServer(t, size)
	dir := t.TempDir()
	m, err := New(dir, http.DefaultClient)
	if err != nil {
		t.Fatal(err)
	}
	m.SetThreads(1)

	// 先造一个「下到一半」的现场:part0 里已经有前 1MB,而索引里记的是 0
	const half = 1024 * 1024
	fp := filepath.Join(dir, "半截片.mkv")
	pre := make([]byte, half)
	for i := range pre {
		pre[i] = byte(i % 251)
	}
	if err := os.WriteFile(fp+".part0", pre, 0o644); err != nil {
		t.Fatal(err)
	}

	id := m.Enqueue(&Item{ItemID: "i2", Title: "半截片", Container: "mkv", URL: up.URL})
	it := waitDone(t, m, id, 30*time.Second)
	if it.Status != StatusCompleted {
		t.Fatalf("状态 %s,错误 %v", it.Status, deref(it.Error))
	}
	b, err := os.ReadFile(it.FilePath)
	if err != nil {
		t.Fatal(err)
	}
	if len(b) != size {
		t.Fatalf("长度 %d,应当 %d —— 续传把已下过的又追加了一遍", len(b), size)
	}
	for i := range b {
		if b[i] != byte(i%251) {
			t.Fatalf("第 %d 字节对不上 —— 续传的起点算错了", i)
		}
	}
	m.Close()
}

// ★ 僵尸 part(比区间还长)要**截断**,否则拼接整条错位。
func TestSyncSegments_超长的part要截断(t *testing.T) {
	dir := t.TempDir()
	it := &Item{
		FilePath: filepath.Join(dir, "a.mkv"),
		Segments: []Segment{{Start: 0, End: 99}, {Start: 100, End: 199}},
	}
	// part0 写了 150 字节,而它的区间只有 100
	if err := os.WriteFile(it.partPath(0), make([]byte, 150), 0o644); err != nil {
		t.Fatal(err)
	}
	syncSegmentsFromDisk(it)

	st, err := os.Stat(it.partPath(0))
	if err != nil {
		t.Fatal(err)
	}
	if st.Size() != 100 {
		t.Fatalf("part0 是 %d 字节,应当被截到 100 —— 不截的话拼接整条错位,"+
			"表现是「下完了,播放器说文件损坏」", st.Size())
	}
	if it.Segments[0].Downloaded != 100 {
		t.Fatalf("进度记成了 %d", it.Segments[0].Downloaded)
	}
}

// ★★ 不支持 Range → 单段整流,照样要能下完。
//
// ★ 语料**必须 ≥ 2MB**。第一版用了 300KB —— 而小于 2MB 本来就不分段,
//
//	于是注入「不看 SupportsRange」时段数照样是 1,测试全程绿。
//	夹具选错让断言变空,是假绿的一类。
func TestDownload_不支持Range退回单段(t *testing.T) {
	const size = 3 * 1024 * 1024
	up := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		// 故意**不给** Accept-Ranges,而且无视 Range 头
		buf := make([]byte, size)
		for i := range buf {
			buf[i] = byte(i % 251)
		}
		w.Header().Set("Content-Length", strconv.Itoa(size))
		_, _ = w.Write(buf)
	}))
	defer up.Close()

	m := mgr(t)
	m.SetThreads(4)
	id := m.Enqueue(&Item{ItemID: "i3", Title: "不支持range", Container: "mp4", URL: up.URL})
	it := waitDone(t, m, id, 20*time.Second)
	if it.Status != StatusCompleted {
		t.Fatalf("状态 %s,错误 %v", it.Status, deref(it.Error))
	}
	if len(it.Segments) != 1 {
		t.Fatalf("切成了 %d 段 —— 服务端不支持 Range 时必须退回单段,"+
			"否则每段都从头下,拼出来是四份开头", len(it.Segments))
	}
	b, _ := os.ReadFile(it.FilePath)
	if len(b) != size {
		t.Fatalf("长度 %d,应当 %d", len(b), size)
	}
}

// ★ 小文件不分段:分段的开销比省下的时间还多。
func TestBuildSegments_小文件不分段(t *testing.T) {
	it := &Item{TotalBytes: 1024 * 1024, SupportsRange: true} // 1MB < 2MB
	buildSegments(it, 4)
	if len(it.Segments) != 1 {
		t.Fatalf("1MB 切成了 %d 段", len(it.Segments))
	}
	it2 := &Item{TotalBytes: 10 * 1024 * 1024, SupportsRange: true}
	buildSegments(it2, 4)
	if len(it2.Segments) != 4 {
		t.Fatalf("10MB 切成了 %d 段,应当 4", len(it2.Segments))
	}
}

// ★★ 分段必须**恰好铺满**整个文件,不重不漏。
//
// 差一个字节的表现是「下完了,最后一帧花屏」或者干脆播不了 —— 而长度看着是对的。
func TestBuildSegments_不重不漏(t *testing.T) {
	for _, total := range []int64{2 * 1024 * 1024, 3*1024*1024 + 1, 100 * 1024 * 1024, 7} {
		for _, threads := range []int{1, 2, 3, 4} {
			it := &Item{TotalBytes: total, SupportsRange: true}
			buildSegments(it, threads)
			var covered int64
			prevEnd := int64(-1)
			for _, s := range it.Segments {
				if s.Start != prevEnd+1 {
					t.Fatalf("total=%d threads=%d:区间不连续,%d 之后是 %d", total, threads, prevEnd, s.Start)
				}
				covered += s.length()
				prevEnd = s.End
			}
			if covered != total {
				t.Fatalf("total=%d threads=%d:只铺了 %d 字节", total, threads, covered)
			}
			if prevEnd != total-1 {
				t.Fatalf("total=%d threads=%d:最后一段结束在 %d,应当 %d", total, threads, prevEnd, total-1)
			}
		}
	}
}

// ★★ 「清除已完成」**只清记录,不删文件**。
//
// 用户点它是想收拾列表,不是想丢文件。删了的话,那是不可逆的。
func TestClearCompleted_不删文件(t *testing.T) {
	const size = 200 * 1024
	up, _ := rangeServer(t, size)
	m := mgr(t)
	id := m.Enqueue(&Item{ItemID: "i4", Title: "下好的片", Container: "mkv", URL: up.URL})
	it := waitDone(t, m, id, 20*time.Second)
	if it.Status != StatusCompleted {
		t.Fatalf("状态 %s", it.Status)
	}

	if n := m.ClearCompleted(); n != 1 {
		t.Fatalf("清了 %d 条,应当 1", n)
	}
	if len(m.List()) != 0 {
		t.Fatal("记录没清掉")
	}
	if _, err := os.Stat(it.FilePath); err != nil {
		t.Fatalf("文件被删了 —— 「清除已完成」是收拾列表,不是丢文件:%v", err)
	}
}

// ★ 删任务**要**删文件(和上一条是相反的语义,别搞混)。
func TestRemove_要删文件(t *testing.T) {
	const size = 200 * 1024
	up, _ := rangeServer(t, size)
	m := mgr(t)
	id := m.Enqueue(&Item{ItemID: "i5", Title: "要删的片", Container: "mkv", URL: up.URL})
	it := waitDone(t, m, id, 20*time.Second)

	m.Remove(id)
	if len(m.List()) != 0 {
		t.Fatal("记录没删")
	}
	if _, err := os.Stat(it.FilePath); err == nil {
		t.Fatal("文件还在 —— 删任务就该连文件一起删")
	}
}

// ★ 文件名净化:Windows 上冒号非法,而片名里冒号极常见。
//
// 不净化的话文件建不出来,而报错发生在下载**结束**时 —— 用户等了半小时才看到失败。
func TestSafeName(t *testing.T) {
	cases := map[string]string{
		`某某:第二部`:      "某某_第二部",
		`a/b\c:d*e?f`: "a_b_c_d_e_f",
		`  空白  `:      "空白",
		``:            "video",
		`   `:         "video",
	}
	for in, want := range cases {
		if got := SafeName(in); got != want {
			t.Fatalf("SafeName(%q) = %q,想要 %q", in, got, want)
		}
	}
	// ★ 按**字符**截断不是按字节:按字节会把一个汉字劈成两半,落盘就是乱码文件名
	long := strings.Repeat("中", 100)
	got := SafeName(long)
	if len([]rune(got)) != 60 {
		t.Fatalf("截成了 %d 个字符,应当 60", len([]rune(got)))
	}
	if strings.Contains(got, "�") {
		t.Fatal("截断把汉字劈成了两半")
	}
}

// ★ 重启恢复:被中断的「下载中」要变成暂停,不能永远挂着一条谁也不在跑的任务。
func TestNew_重启把下载中改成暂停(t *testing.T) {
	dir := t.TempDir()
	idx := filepath.Join(dir, "index.json")
	raw := `[{"id":"x","item_id":"i","title":"t","container":"mkv","url":"http://x",
	  "file_path":"` + strings.ReplaceAll(filepath.Join(dir, "t.mkv"), `\`, `\\`) + `",
	  "status":"downloading","added_at":1,"segments":[]}]`
	if err := os.WriteFile(idx, []byte(raw), 0o644); err != nil {
		t.Fatal(err)
	}
	m, err := New(dir, http.DefaultClient)
	if err != nil {
		t.Fatal(err)
	}
	defer m.Close()
	list := m.List()
	if len(list) != 1 {
		t.Fatalf("恢复出 %d 条", len(list))
	}
	if list[0].Status != StatusPaused {
		t.Fatalf("状态是 %s,应当是 paused —— "+
			"不改的话列表里永远挂着一条谁也不在跑的「下载中」", list[0].Status)
	}
}

// ★ CompletedPath:状态是 completed **且文件还在**才算数。
func TestCompletedPath_文件被手删了就不算(t *testing.T) {
	const size = 100 * 1024
	up, _ := rangeServer(t, size)
	m := mgr(t)
	id := m.Enqueue(&Item{ItemID: "movie-1", Title: "本地有的片", Container: "mkv", URL: up.URL})
	it := waitDone(t, m, id, 20*time.Second)
	if it.Status != StatusCompleted {
		t.Fatalf("状态 %s", it.Status)
	}
	if p := m.CompletedPath("movie-1"); p == "" {
		t.Fatal("下好了却拿不到本地路径")
	}
	_ = os.Remove(it.FilePath)
	if p := m.CompletedPath("movie-1"); p != "" {
		t.Fatalf("文件已被手动删掉,却还给出了路径 %q —— 起播会拿着一个不存在的文件", p)
	}
}

func deref(p *string) string {
	if p == nil {
		return ""
	}
	return *p
}

// ★★ 索引换了格式(裸数组 → 带 threads 的对象),**两种都要读得回来**。
//
// 只读新格式的话,升级一次用户的下载列表整个消失 —— 文件其实都还在,
// 只是列表空了,看起来像被清空了。
func TestDecodeIndex_新老格式都吃(t *testing.T) {
	old := []byte(`[{"id":"a","item_id":"i","title":"t","status":"paused","added_at":1}]`)
	list, threads := decodeIndex(old)
	if len(list) != 1 || list[0].ID != "a" {
		t.Fatalf("老的裸数组格式读不回来: %+v —— 升级一次下载列表就空了", list)
	}
	if threads != 0 {
		t.Fatalf("老格式没有 threads,应当返回 0 让调用方用默认值,实得 %d", threads)
	}

	nw := []byte(`{"threads":4,"items":[{"id":"b","item_id":"i","title":"t","status":"paused","added_at":1}]}`)
	list2, threads2 := decodeIndex(nw)
	if len(list2) != 1 || list2[0].ID != "b" {
		t.Fatalf("新格式读不回来: %+v", list2)
	}
	if threads2 != 4 {
		t.Fatalf("threads 没读出来: %d", threads2)
	}

	if l, _ := decodeIndex([]byte("不是JSON")); l != nil {
		t.Fatal("坏文件应当返回 nil,不能崩")
	}
}

// ★ 线程数要**跨重启活着**。黄金实现里它只在内存里,每次启动回到 2 ——
// 而 UI_PC §7.9 要的是「归核心层持久化,UI 只读不灌」。
func TestSetThreads_重启后还在(t *testing.T) {
	dir := t.TempDir()
	m, err := New(dir, http.DefaultClient)
	if err != nil {
		t.Fatal(err)
	}
	m.SetThreads(4)
	m.Close()

	m2, err := New(dir, http.DefaultClient)
	if err != nil {
		t.Fatal(err)
	}
	defer m2.Close()
	if got := m2.Threads(); got != 4 {
		t.Fatalf("重启后线程数变回 %d —— 用户每次开机都要重设一遍", got)
	}
}

// ★ 越界值要**钳**,不是照收。设成 99 的话会对同一个文件开 99 条连接。
func TestSetThreads_钳在1到4(t *testing.T) {
	m := mgr(t)
	for in, want := range map[int]int{0: 1, -5: 1, 1: 1, 4: 4, 99: 4} {
		m.SetThreads(in)
		if got := m.Threads(); got != want {
			t.Fatalf("SetThreads(%d) 之后是 %d,应当 %d", in, got, want)
		}
	}
}
