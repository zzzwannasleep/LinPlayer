package plugin

// 每插件独立 KV 存储,持久化为 `<data>/<pluginId>/storage.json`。
// 序列化后总大小上限 5MB,超限 set 报错不写入。

import (
	"encoding/json"
	"fmt"
	"os"
	"path/filepath"
	"sort"
	"sync"
)

// MaxStorageBytes 单插件存储上限。
const MaxStorageBytes = 5 * 1024 * 1024

// Storage 一个插件的 KV 存储。
type Storage struct {
	pluginID string
	file     string

	mu     sync.Mutex
	data   map[string]any
	loaded bool
}

// NewStorage 建一个存储句柄(不碰磁盘,首次读写时才加载)。
func NewStorage(pluginID, dataDir string) *Storage {
	return &Storage{
		pluginID: pluginID,
		file:     filepath.Join(dataDir, "storage.json"),
		data:     map[string]any{},
	}
}

func (s *Storage) ensureLoaded() {
	if s.loaded {
		return
	}
	s.loaded = true
	raw, err := os.ReadFile(s.file)
	if err != nil {
		return
	}
	var m map[string]any
	if json.Unmarshal(raw, &m) == nil && m != nil {
		s.data = m
	}
}

func (s *Storage) persist() error {
	if dir := filepath.Dir(s.file); dir != "" {
		if err := os.MkdirAll(dir, 0o755); err != nil {
			return fmt.Errorf("建存储目录失败: %w", err)
		}
	}
	enc, err := json.Marshal(s.data)
	if err != nil {
		return fmt.Errorf("序列化存储失败: %w", err)
	}
	if err := os.WriteFile(s.file, enc, 0o644); err != nil {
		return fmt.Errorf("写存储失败: %w", err)
	}
	return nil
}

// Get 取一个键。没有就是 nil(JS 侧看到 null)。
func (s *Storage) Get(key string) any {
	s.mu.Lock()
	defer s.mu.Unlock()
	s.ensureLoaded()
	return s.data[key]
}

// Keys 全部键,按字典序(顺序稳定,否则插件每次拿到的顺序都不一样)。
func (s *Storage) Keys() []string {
	s.mu.Lock()
	defer s.mu.Unlock()
	s.ensureLoaded()
	out := make([]string, 0, len(s.data))
	for k := range s.data {
		out = append(out, k)
	}
	sort.Strings(out)
	return out
}

// Set 写一个键。
//
// ★ **先算加入后的大小,超限则拒绝且不改内存** —— 先写后查会让超限那一次
// 把数据留在内存里,下一次任何写入都跟着一起失败。
func (s *Storage) Set(key string, value any) error {
	s.mu.Lock()
	defer s.mu.Unlock()
	s.ensureLoaded()

	probe := make(map[string]any, len(s.data)+1)
	for k, v := range s.data {
		probe[k] = v
	}
	probe[key] = value
	enc, err := json.Marshal(probe)
	if err != nil {
		return fmt.Errorf("序列化存储失败: %w", err)
	}
	if len(enc) > MaxStorageBytes {
		return fmt.Errorf("插件 %s 存储超出 5MB 上限(尝试写入 %d 字节)", s.pluginID, len(enc))
	}
	s.data[key] = value
	return s.persist()
}

// Delete 删一个键。删不存在的键不算错,也不写盘。
func (s *Storage) Delete(key string) error {
	s.mu.Lock()
	defer s.mu.Unlock()
	s.ensureLoaded()
	if _, has := s.data[key]; !has {
		return nil
	}
	delete(s.data, key)
	return s.persist()
}

// Clear 清空。
func (s *Storage) Clear() error {
	s.mu.Lock()
	defer s.mu.Unlock()
	s.data = map[string]any{}
	s.loaded = true
	return s.persist()
}
