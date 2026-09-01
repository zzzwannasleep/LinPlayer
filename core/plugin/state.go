package plugin

// 启用态 / 已同意权限的落盘。

import (
	"encoding/json"
	"os"
	"sort"
)

type persistedState struct {
	Enabled  []string            `json:"enabled"`
	Approved map[string][]string `json:"approved"`
}

func loadPluginState(file string) (map[string]bool, map[string]map[string]bool) {
	enabled := map[string]bool{}
	approved := map[string]map[string]bool{}
	raw, err := os.ReadFile(file)
	if err != nil {
		return enabled, approved
	}
	var p persistedState
	if json.Unmarshal(raw, &p) != nil {
		return enabled, approved
	}
	for _, id := range p.Enabled {
		enabled[id] = true
	}
	for id, perms := range p.Approved {
		set := map[string]bool{}
		for _, x := range perms {
			set[x] = true
		}
		approved[id] = set
	}
	return enabled, approved
}

// persist 落盘启用态与已同意权限。
//
// ★ 两张表都排序后再写:map 的迭代顺序是随机的,不排序的话每次保存
// 文件内容都不一样 —— 备份/同步会看到一堆无意义的差异。
func (m *Manager) persist() {
	m.mu.Lock()
	p := persistedState{Enabled: []string{}, Approved: map[string][]string{}}
	for id := range m.enabled {
		p.Enabled = append(p.Enabled, id)
	}
	for id, perms := range m.approved {
		list := make([]string, 0, len(perms))
		for x := range perms {
			list = append(list, x)
		}
		sort.Strings(list)
		p.Approved[id] = list
	}
	file := m.stateFile
	m.mu.Unlock()

	sort.Strings(p.Enabled)
	raw, err := json.Marshal(p)
	if err != nil {
		return
	}
	_ = os.WriteFile(file, raw, 0o644)
}
