// Package config 读写 AppConfig。
//
// ★★ 这个包存在的**全部理由**是一条真故障(见 crates/core/src/config.rs:458 的注释):
//
//	Rust 版有三个字段没标 serde(default) —— 配置文件里少任意一个,整份 JSON
//	反序列化失败 → load() 的 .ok() 把错误吞掉 → unwrap_or_default() 退回空配置
//	→ **用户所有服务器账号一次性消失,而且不报错。**
//
// Go 的 encoding/json 在「缺字段」这件事上天然宽松(缺了就是零值),
// 所以那个具体的坑不存在。**但反过来的坑存在,而且一模一样致命:**
// 解析失败时如果我们也「退回默认值继续跑」,下一次保存就把用户的配置覆盖没了。
//
// 所以本包的硬规矩:
//  1. 文件不存在 = 新装,返回空配置,**这是唯一允许返回空配置的情形**
//  2. 文件存在但解析失败 = **返回错误,绝不返回空配置**;调用方必须让它冒到用户面前
//  3. 保存必须是原子的(SPEC §14.2):写临时文件 + rename,不许就地截断重写
package config

import (
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"sync"

	"linplayer/core/paths"
)

// AppConfig 与现有 config.json 的顶层结构对齐(12 个键)。
//
// ★ 移植期的策略:**已接的字段用强类型,没接的原样透传**。
// 用 json.RawMessage 兜住没接的部分 —— 否则每次保存都会把还没移植的功能的
// 配置抹掉,而用户只会看到「升级之后我的 XX 设置没了」。
type AppConfig struct {
	DeviceID string `json:"device_id"`
	Active   *int   `json:"active"`
	Theme    string `json:"theme"`

	CompanionEnabled      bool `json:"companion_enabled"`
	PluginOfficialEnabled bool `json:"plugin_official_enabled"`

	// AccountList 服务器账号表。**已接强类型**,但每条账号内部没接的键仍原样透传
	// (见 account.go 的 Account.rest)。
	AccountList []Account `json:"accounts"`

	// 下面这些迁移期还没接,**原样透传**,别丢
	Prefs          json.RawMessage `json:"prefs,omitempty"`
	DanmakuSources json.RawMessage `json:"danmaku_sources,omitempty"`
	Proxy          json.RawMessage `json:"proxy,omitempty"`
	SyncTrakt      json.RawMessage `json:"sync_trakt,omitempty"`
	SyncBangumi    json.RawMessage `json:"sync_bangumi,omitempty"`
	PluginSources  json.RawMessage `json:"plugin_sources,omitempty"`

	// 未知字段的兜底。加载时把整份 JSON 也存一份,保存时合并回去 ——
	// 这样即使上面漏了某个键,也不会在保存时把它抹掉。
	unknown map[string]json.RawMessage
}

// ErrCorrupt 表示配置文件存在但读不出来。
// **调用方绝不能把它当成「没有配置」处理**,见包注释。
var ErrCorrupt = errors.New("配置文件存在但解析失败")

var (
	mu      sync.RWMutex
	current *AppConfig
)

func defaults() *AppConfig {
	return &AppConfig{
		CompanionEnabled:      true, // 默认开:关着的话「遥控器」每次要先在电视上打开,等于没有
		PluginOfficialEnabled: true, // 可禁不可删:删掉之后新用户开箱即空
		unknown:               map[string]json.RawMessage{},
	}
}

// Load 读配置。返回的错误必须冒到用户面前,不许吞。
func Load() (*AppConfig, error) {
	p := paths.ConfigFile()
	b, err := os.ReadFile(p)
	if errors.Is(err, os.ErrNotExist) {
		c := defaults()
		mu.Lock()
		current = c
		mu.Unlock()
		return c, nil // 新装。**这是唯一允许返回空配置的情形**
	}
	if err != nil {
		return nil, fmt.Errorf("读配置失败 %s: %w", p, err)
	}

	// 先按 map 解一遍,把所有键都留住(包括我们还没接的)
	raw := map[string]json.RawMessage{}
	if err := json.Unmarshal(b, &raw); err != nil {
		// ★ 不返回空配置。返回空配置 = 下次保存把用户的账号全覆盖掉
		return nil, fmt.Errorf("%w: %s: %v", ErrCorrupt, p, err)
	}
	c := defaults()
	if err := json.Unmarshal(b, c); err != nil {
		return nil, fmt.Errorf("%w: %s: %v", ErrCorrupt, p, err)
	}
	c.unknown = raw

	mu.Lock()
	current = c
	mu.Unlock()
	return c, nil
}

// Save 原子写(SPEC §14.2):临时文件 + rename。
//
// ★ 不许就地截断重写。断电 / 进程被杀在截断之后写入之前,配置文件就是 0 字节,
// 而 0 字节的 JSON 解析失败 —— 按本包的规矩会变成 ErrCorrupt,用户进不去。
func (c *AppConfig) Save() error {
	// 把强类型字段序列化回去,再合并进原始 map —— 没接的键因此不会丢
	typed, err := json.Marshal(c)
	if err != nil {
		return err
	}
	merged := map[string]json.RawMessage{}
	for k, v := range c.unknown {
		merged[k] = v
	}
	var overlay map[string]json.RawMessage
	if err := json.Unmarshal(typed, &overlay); err != nil {
		return err
	}
	for k, v := range overlay {
		merged[k] = v
	}

	out, err := json.MarshalIndent(merged, "", "  ")
	if err != nil {
		return err
	}

	p := paths.ConfigFile()
	if err := os.MkdirAll(filepath.Dir(p), 0o755); err != nil {
		return err
	}
	tmp, err := os.CreateTemp(filepath.Dir(p), ".config-*.tmp")
	if err != nil {
		return err
	}
	tmpName := tmp.Name()
	defer os.Remove(tmpName) // rename 成功后这句是空操作
	if _, err := tmp.Write(out); err != nil {
		tmp.Close()
		return err
	}
	if err := tmp.Sync(); err != nil { // 落盘再 rename,否则「原子」只是名义上的
		tmp.Close()
		return err
	}
	if err := tmp.Close(); err != nil {
		return err
	}
	return os.Rename(tmpName, p)
}

// Current 返回已加载的配置。没加载过返回默认值。
func Current() *AppConfig {
	mu.RLock()
	c := current
	mu.RUnlock()
	if c == nil {
		return defaults()
	}
	return c
}
