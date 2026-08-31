package prefetch

// 边收边吐的载体(Live)+ 落盘的环形分段缓存(diskCache)。
//
// 移植自 `crates/core/src/net/prefetch.rs`。**这两块是「开了多线程加载就播不出来」
// 那几次故障的正中心**,注释是从 Rust 侧逐字搬来的。

import (
	"fmt"
	"os"
	"path/filepath"
	"strings"
	"sync"

	"linplayer/core/paths"
)

// ChunkSize 每段 4MB。
//
// ★ **禁止靠调小它让测试变绿**(TODO C26 明写)—— 调小之后「等整段」的代价跟着变小,
// 几条本该红的用例会假绿,而真实链路上的问题一点没修。
const ChunkSize int64 = 4 * 1024 * 1024

// notifier 是 tokio `Notify::notify_waiters()` 的等价物:**广播,不排队**。
//
// ★ 不能用带缓冲的 channel 冒充:那是「攒一个唤醒」的语义,
// 多个等待者时只会叫醒一个,剩下的等到 250ms 兜底才动 —— 表现是断断续续的卡顿。
type notifier struct {
	mu sync.Mutex
	ch chan struct{}
}

func (n *notifier) wait() <-chan struct{} {
	n.mu.Lock()
	defer n.mu.Unlock()
	if n.ch == nil {
		n.ch = make(chan struct{})
	}
	return n.ch
}

func (n *notifier) notifyAll() {
	n.mu.Lock()
	defer n.mu.Unlock()
	if n.ch != nil {
		close(n.ch)
		n.ch = nil
	}
}

// live 正在拉取中的一个分段 —— **边收边吐**的载体。
//
// # 为什么非要有它
//
// 在这之前,供给端必须等**整段 4MB 落盘**才吐第一个字节。
// 而 mpv 起播只要文件头 ~200KB + 尾部 cues 索引(MKV,ffmpeg 开容器第一跳就 seek 到尾)。
// 实测用户那条链(2026-08-01)吞吐只有 56~143KB/s → 一段 4MB **合法地要 29~62 秒**,
// 头/尾各一次,于是「开了多线程加载就没画面没声音」。直连反而能播,正是因为
// mpv 只拉它真正要的那几百 KB。
//
// **分段粒度是给「预取」用的,不该成为「供给」的粒度。**
type live struct {
	mu   sync.Mutex
	data []byte
	n    notifier
	// done 喂食结束(成功/失败/被取消)。置位后供给端不再干等,回落到磁盘/重拉路径。
	done chan struct{}
	once sync.Once
	// base 本载体覆盖的是段内 [base, base+cap)。base > 0 只出现在**连接首段**。
	base int
	cap  int
}

func newLive(cap int) *live { return newLiveBased(0, cap) }

func newLiveBased(base, cap int) *live {
	return &live{data: make([]byte, 0, cap), done: make(chan struct{}), base: base, cap: cap}
}

func (l *live) len() int {
	l.mu.Lock()
	defer l.mu.Unlock()
	return len(l.data)
}

// feed 并进新到的一块。
//
// ★ skip 是**重试**用的:第 2 次尝试打的是同一个 Range,前面那几 MB 上一轮已经收下、
// 而且很可能**已经吐给播放器了**,不能再追加一遍。
// 「同 URL 同 Range 返回同样的字节」是这份缓存从一开始就依赖的前提。
func (l *live) feed(skip *int, b []byte) {
	if *skip >= len(b) {
		*skip -= len(b)
		return
	}
	b = b[*skip:]
	*skip = 0
	l.mu.Lock()
	room := l.cap - len(l.data)
	if room > 0 {
		if room > len(b) {
			room = len(b)
		}
		l.data = append(l.data, b[:room]...)
	}
	l.mu.Unlock()
	l.n.notifyAll()
}

// sliceFrom 从**段内**偏移 at 起、当前已到货的部分。
// 还没到(或压根不在本载体覆盖范围内)返回 nil。
func (l *live) sliceFrom(at int) []byte {
	i := at - l.base
	if i < 0 {
		return nil
	}
	l.mu.Lock()
	defer l.mu.Unlock()
	if len(l.data) <= i {
		return nil
	}
	out := make([]byte, len(l.data)-i)
	copy(out, l.data[i:])
	return out
}

func (l *live) snapshot() []byte {
	l.mu.Lock()
	defer l.mu.Unlock()
	out := make([]byte, len(l.data))
	copy(out, l.data)
	return out
}

func (l *live) finish() {
	l.once.Do(func() { close(l.done) })
	l.n.notifyAll()
}

func (l *live) isDone() bool {
	select {
	case <-l.done:
		return true
	default:
		return false
	}
}

// ---------------------------------------------------------------- 环形磁盘缓存

// diskCache 落盘的分段缓存 —— **全会话共享**(所有连接共用一份),不是每连接一份。
//
// # 为什么必须落盘
//
// 原来分段全存在内存里,峰值 = 单连接窗口 × 存活连接数。播放器一 seek 就丢下旧连接
// 新开一条,而被丢下的连接**还会把整个窗口填满才罢休** —— 快速拖 N 次进度条就是
// 32MB × N 瞬时占用,内存不足直接闪退。因为不敢放大,用户的「视频缓存上限」
// 设置项被硬钳在 16~32MB,形同虚设。
// 落盘后内存只剩**正在传输的那几段**,窗口上限才敢跟着用户设置走。
//
// # 为什么共享而不是每连接一份
//
// 共享才有「缓存」的意义:seek 回看过的区域直接命中磁盘,不重新下载。
// 每连接一份的话,拖回去一次就得重下一次 —— 那只是「缓冲」不是「缓存」。
//
// # 为什么是环形
//
// 磁盘占用**恒定 = 用户设的缓存上限**。整片直存看着简单,但随手就有 29.6GB 的片子
// —— 顺序看完一遍就把用户硬盘吃掉 29.6GB,这和「内存爆掉」是同一个错误换了个介质。
type diskCache struct {
	mu sync.Mutex // 同时保护 slots 与文件读写
	f  *os.File
	// slots 槽位 -> 当前存的分段号。slots[c%ring] == c 才算命中。
	slots map[int64]int64
	ring  int64
	path  string
	total int64
}

// sweepOrphans 清掉**别的进程**留下的分段缓存文件。
//
// ★ 缓存文件靠句柄关闭时删除,而进程被杀 / 崩溃时那段代码根本不跑 ——
// 实测用户机器上躺着一周前的 33MB 残留。预加载改成在**详情页**就起代理之后,
// 逛一圈详情页就能攒一堆,必须堵。
//
// 只删文件名前缀不是本进程 pid 的 —— 本进程自己那些正在用。删不掉一律忽略:
// 这是打扫,不是关键路径。
func sweepOrphans(dir string) {
	me := fmt.Sprintf("s%d_", os.Getpid())
	ents, err := os.ReadDir(dir)
	if err != nil {
		return
	}
	for _, e := range ents {
		n := e.Name()
		if strings.HasSuffix(n, ".part") && !strings.HasPrefix(n, me) {
			_ = os.Remove(filepath.Join(dir, n))
		}
	}
}

var cacheSeq struct {
	mu sync.Mutex
	n  int64
}

// newDiskCache 建缓存文件。cacheBytes = 用户设的缓存上限,决定环形槽位数。
//
// ★ 槽位至少要比并发 worker 多,否则 worker 之间会互相覆盖对方刚写的段。
// ★ 文件名必须**每个实例唯一**:两个会话完全可能并存(孤儿播放器还没关、新播放器已起来),
// 同一部片 total 当然相同。一旦重名,后来者把文件截断清零,而前者的 slots 表在内存里
// 仍然认为那些段「就绪」→ 前者读回一整块**稀疏零**并当作有效数据发给播放器。
func newDiskCache(total, cacheBytes int64, threads int) (*diskCache, error) {
	dir := paths.PrefetchCache()
	if err := os.MkdirAll(dir, 0o755); err != nil {
		return nil, err
	}
	sweepOrphans(dir)
	cacheSeq.mu.Lock()
	seq := cacheSeq.n
	cacheSeq.n++
	cacheSeq.mu.Unlock()

	path := filepath.Join(dir, fmt.Sprintf("s%d_%d_%d.part", os.Getpid(), total, seq))
	f, err := os.OpenFile(path, os.O_CREATE|os.O_RDWR|os.O_TRUNC, 0o644)
	if err != nil {
		return nil, err
	}
	want := cacheBytes / ChunkSize
	if min := int64(threads) * 2; want < min {
		want = min
	}
	if all := (total + ChunkSize - 1) / ChunkSize; want > all {
		want = all // 比整片还大就没必要
	}
	if want < 1 {
		want = 1
	}
	return &diskCache{f: f, slots: map[int64]int64{}, ring: want, path: path, total: total}, nil
}

func (d *diskCache) off(c int64) int64 { return (c % d.ring) * ChunkSize }

// has 该段是否就绪(槽位没被别的段覆盖掉)。
//
// ★ **必须用两值形式取 map**:Go 的 map 取不到返回零值,而分段号 0 是合法的 ——
// 写成 `d.slots[slot] == c` 的话,槽位空着时 chunk 0 会被判成「就绪」,
// 读回一整块**稀疏零**当成有效数据发给播放器。这个坑只在文件头那一段出现,
// 而文件头恰恰是每次起播必读的第一段。
func (d *diskCache) has(c int64) bool {
	d.mu.Lock()
	defer d.mu.Unlock()
	v, ok := d.slots[c%d.ring]
	return ok && v == c
}

// put 写入一段并标记就绪。
//
// ★★ 全程持锁,且**先把槽标失效再写**。
// 原来是「写完盘再更新 slots」,于是读者可以:查 slots 命中 → 开始读 →
// 另一条流正把**别的段**覆盖进同一个槽 → 读到半新半旧的脏数据。
// 表现是播放器拿到错帧(实测:B 连接在自己的起始位置读到 A 的字节),
// **比饿死更隐蔽 —— 它不报错,只是画面坏掉**。
//
// 环形缓存是全连接共享的(槽位 = chunk % ring),两条连接的段号模 ring 同余就同槽,
// 所以这个竞态在多连接下是**必然会撞上**的,不是理论风险。
func (d *diskCache) put(c int64, data []byte) bool {
	d.mu.Lock()
	defer d.mu.Unlock()
	slot := c % d.ring
	delete(d.slots, slot) // 写到一半被读走 = 脏数据,先失效
	if _, err := d.f.WriteAt(data, d.off(c)); err != nil {
		return false
	}
	d.slots[slot] = c
	return true
}

// get 读回一段。
//
// ★ 返回 nil = **这一段已经被别的连接挤出槽位**,调用方要重拉而不是当失败。
// ★ 槽位校验必须和读盘在**同一把锁**里完成:先 has() 再 get() 的两段式有 TOCTOU,
// 中间那一瞬别人把槽覆盖了就会读到别人的数据。
func (d *diskCache) get(c int64, length int) []byte {
	d.mu.Lock()
	defer d.mu.Unlock()
	if v, ok := d.slots[c%d.ring]; !ok || v != c {
		return nil // 已被挤掉
	}
	buf := make([]byte, length)
	if _, err := d.f.ReadAt(buf, d.off(c)); err != nil {
		return nil
	}
	return buf
}

// close 关文件并删掉它。**会话内缓存,退出即清,不留垃圾。**
func (d *diskCache) close() {
	d.mu.Lock()
	defer d.mu.Unlock()
	_ = d.f.Close()
	_ = os.Remove(d.path)
}

// sizeOnDisk 当前文件实际长度。测试用:验「占用恒 = 上限」。
func (d *diskCache) sizeOnDisk() int64 {
	d.mu.Lock()
	defer d.mu.Unlock()
	st, err := d.f.Stat()
	if err != nil {
		return 0
	}
	return st.Size()
}
