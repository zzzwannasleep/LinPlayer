package danmaku

// 弹幕缓存:内存 LRU + 磁盘 JSON。
//
// ★ 为什么两层:同一集反复起播(拖进度、换轨、退出再进)很常见,
// 而一集弹幕动辄几千条、一次往返要好几秒。内存那层挡住同一次会话内的重复,
// 磁盘那层挡住跨会话的。

import (
	"encoding/json"
	"os"
	"path/filepath"
	"sync"

	"linplayer/core/paths"
)

// memCap 内存里最多留几集。
//
// ★ 一集几千条,按 32 集算峰值也就几 MB —— 而它挡掉的是几秒的往返。
const memCap = 32

var (
	memMu    sync.Mutex
	memOrder []string // 最近用过的在后面
	memData  = map[string][]Comment{}
)

func cacheDir() string { return filepath.Join(paths.CacheDir(), "danmaku") }

func cacheKey(sourceID, episodeID string) string { return sourceID + "__" + episodeID }

// cachePath 磁盘缓存文件路径。
//
// ★ 文件名要**净化**:episodeId 在自建源上可能是任意字符串,
// 里面一个斜杠就会把文件写到别的目录去(或者干脆写不出来)。
func cachePath(sourceID, episodeID string) string {
	return filepath.Join(cacheDir(), SafeKey(cacheKey(sourceID, episodeID))+".json")
}

// SafeKey 把任意 id 净化成能当文件名的形状。
func SafeKey(s string) string {
	const bad = `\/:*?"<>|`
	out := make([]rune, 0, len(s))
	for _, r := range s {
		if r < 0x20 || containsRune(bad, r) {
			out = append(out, '_')
		} else {
			out = append(out, r)
		}
	}
	if len(out) > 120 {
		out = out[:120]
	}
	if len(out) == 0 {
		return "x"
	}
	return string(out)
}

func containsRune(s string, r rune) bool {
	for _, c := range s {
		if c == r {
			return true
		}
	}
	return false
}

// CacheGet 取缓存。内存没有就读盘;都没有返回 nil。
func CacheGet(sourceID, episodeID string) []Comment {
	k := cacheKey(sourceID, episodeID)

	memMu.Lock()
	if v, ok := memData[k]; ok {
		touchLocked(k)
		memMu.Unlock()
		return v
	}
	memMu.Unlock()

	raw, err := os.ReadFile(cachePath(sourceID, episodeID))
	if err != nil {
		return nil
	}
	var out []Comment
	if json.Unmarshal(raw, &out) != nil || out == nil {
		return nil
	}
	// ★ 读盘命中也要进内存:不然拖一次进度条就读一次盘
	memMu.Lock()
	memData[k] = out
	touchLocked(k)
	evictLocked()
	memMu.Unlock()
	return out
}

// CachePut 写缓存。
//
// ★ 空表**不写**:那多半是这次没取到,写进去等于把「取不到」缓存了下来,
// 下次连试都不试。
func CachePut(sourceID, episodeID string, items []Comment) {
	if len(items) == 0 {
		return
	}
	k := cacheKey(sourceID, episodeID)
	memMu.Lock()
	memData[k] = items
	touchLocked(k)
	evictLocked()
	memMu.Unlock()

	if os.MkdirAll(cacheDir(), 0o755) != nil {
		return
	}
	if b, err := json.Marshal(items); err == nil {
		_ = os.WriteFile(cachePath(sourceID, episodeID), b, 0o644)
	}
}

func touchLocked(k string) {
	for i, v := range memOrder {
		if v == k {
			memOrder = append(memOrder[:i], memOrder[i+1:]...)
			break
		}
	}
	memOrder = append(memOrder, k)
}

func evictLocked() {
	for len(memOrder) > memCap {
		oldest := memOrder[0]
		memOrder = memOrder[1:]
		delete(memData, oldest)
	}
}

// CacheClear 清空缓存(内存 + 磁盘)。返回删掉的文件数。
func CacheClear() int {
	memMu.Lock()
	memData = map[string][]Comment{}
	memOrder = nil
	memMu.Unlock()

	entries, err := os.ReadDir(cacheDir())
	if err != nil {
		return 0
	}
	n := 0
	for _, e := range entries {
		if e.IsDir() {
			continue
		}
		if os.Remove(filepath.Join(cacheDir(), e.Name())) == nil {
			n++
		}
	}
	return n
}

// CacheDiskSize 磁盘缓存占用(字节)。
func CacheDiskSize() int64 {
	entries, err := os.ReadDir(cacheDir())
	if err != nil {
		return 0
	}
	var total int64
	for _, e := range entries {
		if info, err := e.Info(); err == nil && !e.IsDir() {
			total += info.Size()
		}
	}
	return total
}
