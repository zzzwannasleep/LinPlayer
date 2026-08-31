// Package blocklist 是媒体屏蔽名单。
//
// 移植自 `crates/core/src/blocklist.rs`。**Rust 版是黄金实现**,
// 这里的判定逻辑一条都不许简化 —— 每条都对应过一次「用户一眼就看得见的漏网」。
package blocklist

import (
	"strings"
	"sync"
)

// Item 是被判定对象需要提供的最小信息。
// 用接口而不是直接依赖 emby.Item:屏蔽名单也要给观看记录、插件源用。
type Item interface {
	BlockID() string
	BlockName() string
	BlockSeriesID() string
	BlockSeriesName() string // 空字符串表示没有
	HasSeriesName() bool
}

// Entry 一条屏蔽记录。
//
// ★ **id 和名字都要存**:分集靠 series_id 认,跨服的同一部剧 id 不同、只有名字对得上。
type Entry struct {
	ID   string `json:"id"`
	Name string `json:"name"`
	At   int64  `json:"at"`
}

var (
	mu   sync.RWMutex
	list []Entry
)

// List 返回当前名单的快照。
func List() []Entry {
	mu.RLock()
	defer mu.RUnlock()
	out := make([]Entry, len(list))
	copy(out, list)
	return out
}

// Set 加入或移除一条。
func Set(id, name string, blocked bool) {
	mu.Lock()
	defer mu.Unlock()
	for i := range list {
		if list[i].ID == id {
			if !blocked {
				list = append(list[:i], list[i+1:]...)
			} else {
				list[i].Name = name
			}
			return
		}
	}
	if blocked {
		list = append(list, Entry{ID: id, Name: name})
	}
}

// Replace 整体替换(加载配置时用)。
func Replace(v []Entry) {
	mu.Lock()
	defer mu.Unlock()
	list = append(list[:0], v...)
}

// nameHit 名字命中。
//
// ★ **空名字永不命中** —— 否则一条脏数据能把整个库屏蔽掉。
func nameHit(blockedName, candidate string) bool {
	return blockedName != "" && candidate != "" &&
		strings.EqualFold(candidate, blockedName)
}

// IsBlocked 这个条目被屏蔽了吗。
//
// ★ 三条判据缺一不可:
//  1. 条目自己被屏蔽(在媒体库网格上右键屏蔽的那张卡)
//  2. 它所属的剧被屏蔽(series_id)—— 屏蔽一部剧却在「继续观看」里看见它的分集,
//     是用户第一眼就会发现的漏网
//  3. 剧名对上(series_name / name)—— 跨服的同一部剧 id 不同,只有名字对得上
func IsBlocked(it Item) bool {
	l := List()
	if len(l) == 0 {
		return false
	}
	series := it.BlockSeriesID()
	for _, b := range l {
		switch {
		case b.ID == it.BlockID():
			return true
		case series != "" && b.ID == series:
			return true
		case nameHit(b.Name, it.BlockSeriesName()):
			return true
		case !it.HasSeriesName() && nameHit(b.Name, it.BlockName()):
			return true
		}
	}
	return false
}

// IsBlockedID 这个 id 在名单里吗。
//
// ★ **给媒体库用** —— 库(CollectionFolder)没有 series_id 也不参与跨服名字比对,
// 只按 id 判就够。而且**不能按名字判**:两台服务器上都叫「电影」的库是两个不同的库,
// 按名字会一屏两台一起屏蔽。
func IsBlockedID(id string) bool {
	if id == "" {
		return false
	}
	for _, b := range List() {
		if b.ID == id {
			return true
		}
	}
	return false
}

// IsBlockedTitle 观看记录用:按标题判。记录是跨服的,没有可靠的 item id 可比。
func IsBlockedTitle(title, seriesTitle string) bool {
	for _, b := range List() {
		if nameHit(b.Name, seriesTitle) || nameHit(b.Name, title) {
			return true
		}
	}
	return false
}
