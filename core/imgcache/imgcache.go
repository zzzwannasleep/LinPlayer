// Package imgcache 是封面 / 剧照的两层缓存(内存 L1 + 磁盘 L2)。
//
// **Rust 版是黄金实现。**
// # 为什么要两层
//
// 磁盘层解决「重启后不用回源」,内存层解决「翻回来这一下要快」。
// 只有磁盘 = 每次重挂图都是一次 open+read+解码;只有内存 = 关了程序全没。
//
// # 上限是用户 2026-07-15 亲自定的
//
//	磁盘 2 GB —— 旧栈是 6 GB,他选了更省盘的一档
//	内存 128 MB —— 他原话:「也得给一点去内存 128MB内存去缓存各种各样的图片」
//
// **别照 SPEC 早期那版写的 512 MB。**
package imgcache

import (
	"crypto/sha256"
	"encoding/hex"
	"os"
	"path/filepath"
	"sort"
	"sync"
	"sync/atomic"
	"time"

	"linplayer/core/paths"
)

const (
	// MaxBytes 磁盘层总容量上限。
	MaxBytes int64 = 2 * 1024 * 1024 * 1024
	// MemMaxBytes 内存层上限。
	MemMaxBytes int64 = 128 * 1024 * 1024
	// TTL 过期时间。超过就当没有,重新回源。
	TTL = 30 * 24 * time.Hour
	// maxOne 单张上限。防「图片地址被填成一部电影的直链」把盘吃穿。
	maxOne int64 = 32 * 1024 * 1024
	// sweepEvery 攒够这么多新字节才做一次淘汰扫描。
	// ★ 每次写入都扫 = 每存一张封面就 readdir 几万个文件,**比不缓存还慢**。
	sweepEvery int64 = 64 * 1024 * 1024
	// touchAfter 命中且比这还旧才顶 mtime。
	// ★ 不 touch 的话淘汰就退化成「按存入时间先进先出」,常看的封面照样被淘汰,等于白缓存;
	//   每次命中都 touch 又是拿磁盘 IO 换空气。
	touchAfter = 24 * time.Hour
)

var addedSinceSweep atomic.Int64

// Dir 缓存目录。**唯一出口是 paths**,别的包不许自己拼路径(SPEC §10.1)。
func Dir() string { return paths.ImageCache() }

// fileOf 缓存键 → 文件名。
//
// ★ 键里有 `/` `:` 等字符,Windows 上直接当文件名建不出来;而且键可能很长(URL 拼的),
// 超过文件名上限也会失败。故一律哈希成定长十六进制。
func fileOf(key string) string {
	sum := sha256.Sum256([]byte(key))
	return filepath.Join(Dir(), hex.EncodeToString(sum[:]))
}

/* ================= 内存层(L1) =================

   淘汰用「最久未用」,数据结构就是 map + 一个自增计数当时间戳:
   条目数 = 128MB / 单张约 100KB ≈ 1300,淘汰时线性扫一遍是几十微秒 ——
   为这点规模引一个 LRU 库不值当(而且它还得进依赖树、进安卓交叉编译)。 */

type memEntry struct {
	bytes []byte
	used  uint64 // 最后使用序号
}

var (
	memMu    sync.Mutex
	memMap   = map[string]memEntry{}
	memTotal int64
	memTick  uint64
)

// MemGet 只查内存层。命中就完全不碰磁盘。
func MemGet(key string) []byte {
	memMu.Lock()
	defer memMu.Unlock()
	e, ok := memMap[key]
	if !ok {
		return nil
	}
	memTick++
	e.used = memTick
	memMap[key] = e
	return e.bytes
}

// MemPut 塞进内存层,必要时按最久未用淘汰到 90%。
//
// ★ 留 10% 余量而不是卡着上限:卡满了会变成「每存一张就得淘汰一张」,
// 每次都线性扫一遍,扫描成本摊到每一次写入上。
func MemPut(key string, b []byte) {
	// ★ 单张就超过内存上限 1/8 的(超大 backdrop)不进内存 —— 它会把整个缓存挤空,
	//   换来的只是它自己一张命中。磁盘层照存。
	if len(b) == 0 || int64(len(b)) > MemMaxBytes/8 {
		return
	}
	memMu.Lock()
	defer memMu.Unlock()
	memTick++
	if old, ok := memMap[key]; ok {
		// 覆盖同一个键:先把旧的字节数减掉,否则计数只增不减
		memTotal -= int64(len(old.bytes))
	}
	memMap[key] = memEntry{bytes: b, used: memTick}
	memTotal += int64(len(b))
	if memTotal <= MemMaxBytes {
		return
	}
	target := MemMaxBytes / 10 * 9
	type ku struct {
		k string
		u uint64
	}
	all := make([]ku, 0, len(memMap))
	for k, e := range memMap {
		all = append(all, ku{k, e.used})
	}
	sort.Slice(all, func(i, j int) bool { return all[i].u < all[j].u })
	for _, x := range all {
		if memTotal <= target {
			break
		}
		if e, ok := memMap[x.k]; ok {
			memTotal -= int64(len(e.bytes))
			delete(memMap, x.k)
		}
	}
}

// MemBytes 内存层当前占用。设置页和测试用。
func MemBytes() int64 {
	memMu.Lock()
	defer memMu.Unlock()
	return memTotal
}

// MemClear 清空内存层。
//
// ★ **清理缓存必须连它一起清** —— 只删磁盘的话,内存里那份还在继续供图,
// 用户看着占用变 0 却还是旧封面,那就是在骗他。
func MemClear() {
	memMu.Lock()
	defer memMu.Unlock()
	memMap = map[string]memEntry{}
	memTotal = 0
}

/* ================= 磁盘层(L2) ================= */

// Get2L 读缓存(内存 → 磁盘)。未命中 / 已过期 → nil。
func Get2L(key string) []byte {
	if b := MemGet(key); b != nil {
		return b
	}
	b := Get(key)
	if b != nil {
		MemPut(key, b)
	}
	return b
}

// Put2L 写两层。
func Put2L(key string, b []byte) {
	MemPut(key, b)
	Put(key, b)
}

// Get 只读磁盘层。未命中 / 已过期 → nil。
func Get(key string) []byte {
	p := fileOf(key)
	st, err := os.Stat(p)
	if err != nil {
		return nil
	}
	age := time.Since(st.ModTime())
	if age > TTL {
		_ = os.Remove(p) // 过期就顺手删掉,别等淘汰扫描
		return nil
	}
	b, err := os.ReadFile(p)
	if err != nil {
		return nil
	}
	if len(b) == 0 {
		_ = os.Remove(p) // 空文件 = 上次写到一半崩了
		return nil
	}
	if age > touchAfter {
		now := time.Now()
		_ = os.Chtimes(p, now, now)
	}
	return b
}

// Put 写磁盘层。
//
// ★ 失败(磁盘满 / 无权限)**不算错误** —— 缓存是优化,它挂了图片照样该显示出来。
func Put(key string, b []byte) {
	if len(b) == 0 || int64(len(b)) > maxOne {
		return
	}
	if err := os.MkdirAll(Dir(), 0o755); err != nil {
		return
	}
	p := fileOf(key)
	/* ★ 先写临时文件再 rename:直接写目标文件的话,写到一半进程被杀,
	   留下的半张图会被后续 Get 当成有效缓存读出来 —— 表现为「封面永远是坏的,
	   删缓存才好」。rename 在同一分区上是原子的。 */
	tmp := p + ".tmp"
	f, err := os.Create(tmp)
	if err != nil {
		return
	}
	_, werr := f.Write(b)
	serr := f.Sync()
	cerr := f.Close()
	if werr != nil || serr != nil || cerr != nil || os.Rename(tmp, p) != nil {
		_ = os.Remove(tmp)
		return
	}
	if addedSinceSweep.Add(int64(len(b))) >= sweepEvery {
		addedSinceSweep.Store(0)
		Sweep()
	}
}

// Sweep 淘汰:先删过期的,再在超出 MaxBytes 时按 mtime 从旧到新删到 90% 以下。
//
// ★ 删到 90% 而不是刚好卡在 100%:卡着上限会导致「每存一张就得再扫一次删一张」,
// 扫描成本被摊到每一次写入上。留 10% 余量让下一次扫描离得远一点。
func Sweep() {
	ents, err := os.ReadDir(Dir())
	if err != nil {
		return
	}
	type f struct {
		mt   time.Time
		size int64
		path string
	}
	var files []f
	var total int64
	for _, e := range ents {
		if e.IsDir() {
			continue
		}
		info, err := e.Info()
		if err != nil {
			continue
		}
		p := filepath.Join(Dir(), e.Name())
		// 过期的直接删,不参与容量计算
		if time.Since(info.ModTime()) > TTL {
			_ = os.Remove(p)
			continue
		}
		total += info.Size()
		files = append(files, f{info.ModTime(), info.Size(), p})
	}
	if total <= MaxBytes {
		return
	}
	sort.Slice(files, func(i, j int) bool { return files[i].mt.Before(files[j].mt) }) // 最久未用的排前面
	target := MaxBytes / 10 * 9
	for _, x := range files {
		if total <= target {
			break
		}
		if os.Remove(x.path) == nil {
			total -= x.size
		}
	}
}

// SizeBytes 磁盘层当前占用(设置页「已用 xx MB」用)。
func SizeBytes() int64 {
	ents, err := os.ReadDir(Dir())
	if err != nil {
		return 0
	}
	var total int64
	for _, e := range ents {
		if e.IsDir() {
			continue
		}
		if info, err := e.Info(); err == nil {
			total += info.Size()
		}
	}
	return total
}

// Clear 清空两层。
func Clear() {
	if ents, err := os.ReadDir(Dir()); err == nil {
		for _, e := range ents {
			_ = os.Remove(filepath.Join(Dir(), e.Name()))
		}
	}
	addedSinceSweep.Store(0)
	MemClear()
}

// Sniff 按魔数嗅 MIME。
//
// ★ **不能信上游的 Content-Type**:反代经常把它抹成 application/octet-stream,
// 那样浏览器/图片解码器不认,图就是不显示且不报错。
func Sniff(b []byte) string {
	switch {
	case len(b) >= 3 && b[0] == 0xFF && b[1] == 0xD8 && b[2] == 0xFF:
		return "image/jpeg"
	case len(b) >= 4 && b[0] == 0x89 && b[1] == 'P' && b[2] == 'N' && b[3] == 'G':
		return "image/png"
	case len(b) >= 4 && string(b[:4]) == "GIF8":
		return "image/gif"
	case len(b) >= 12 && string(b[:4]) == "RIFF" && string(b[8:12]) == "WEBP":
		return "image/webp"
	default:
		return "application/octet-stream"
	}
}
