package config

import (
	"encoding/json"
	"errors"
	"os"
	"path/filepath"
	"strings"
	"testing"

	"linplayer/core/paths"
)

// realShapeFixture 是现有 config.json 的**形状**,值全部是占位符。
//
// ★ 红线:真配置里有服务器地址、账号、token。**夹具里一个真值都不许有**
// (AGENTS.md §3.1)。这份夹具只保证「键的形状一致」——
// 而 B1.6 要验的正是「少一个键不会把整份配置读没」。
const realShapeFixture = `{
  "device_id": "PLACEHOLDER-DEVICE-ID",
  "accounts": [
    {"name": "占位服务器", "base_url": "SERVER_URL_PLACEHOLDER", "token": "TOKEN_PLACEHOLDER",
     "user_id": "USER_PLACEHOLDER", "kind": "emby", "lines": [], "ext_domains": []}
  ],
  "active": 0,
  "prefs": {"audio_lang": null, "sub_lang": "chi", "sub_enabled": true,
            "version_regex": "", "sub_regex": "", "audio_regex": ""},
  "danmaku_sources": [],
  "proxy": {"type": "none", "host": "", "port": 0, "username": "", "password": "", "proxy_media": false},
  "sync_trakt": null,
  "sync_bangumi": null,
  "companion_enabled": true,
  "theme": "dark",
  "plugin_sources": [],
  "plugin_official_enabled": true
}`

func withTempRoot(t *testing.T) string {
	t.Helper()
	dir := t.TempDir()
	paths.SetRoot(dir)
	return dir
}

func TestLoad_文件不存在时返回空配置且不报错(t *testing.T) {
	withTempRoot(t)
	c, err := Load()
	if err != nil {
		t.Fatalf("新装应当无错,得到 %v", err)
	}
	if !c.CompanionEnabled || !c.PluginOfficialEnabled {
		t.Fatalf("两个默认开的开关应当是 true")
	}
}

// ★★ 这条是本包存在的**全部理由**。
//
// Rust 版栽过:配置文件少一个字段 → 整份反序列化失败 → .ok() 吞掉 →
// unwrap_or_default() 退回空配置 → **用户所有账号一次性消失且不报错**。
// Go 侧缺字段不会失败,但「解析失败时退回空配置」这个错误一模一样致命:
// 下一次保存就把用户的配置覆盖没了。
func TestLoad_文件坏了必须报错而不是返回空配置(t *testing.T) {
	dir := withTempRoot(t)
	if err := os.WriteFile(filepath.Join(dir, "config.json"), []byte(`{"accounts": [`), 0o644); err != nil {
		t.Fatal(err)
	}
	c, err := Load()
	if err == nil {
		t.Fatal("坏文件必须报错")
	}
	if !errors.Is(err, ErrCorrupt) {
		t.Fatalf("应当是 ErrCorrupt,得到 %v", err)
	}
	if c != nil {
		t.Fatal("★ 绝不能返回一个可用的空配置 —— 那会在下次保存时覆盖掉用户的账号")
	}
}

func TestLoad_读得出现有形状的配置(t *testing.T) {
	dir := withTempRoot(t)
	if err := os.WriteFile(filepath.Join(dir, "config.json"), []byte(realShapeFixture), 0o644); err != nil {
		t.Fatal(err)
	}
	c, err := Load()
	if err != nil {
		t.Fatalf("读现有形状的配置不该出错: %v", err)
	}
	if c.DeviceID != "PLACEHOLDER-DEVICE-ID" {
		t.Fatalf("device_id 读错了: %q", c.DeviceID)
	}
	if c.Active == nil || *c.Active != 0 {
		t.Fatalf("active 读错了: %v", c.Active)
	}
	if c.Theme != "dark" {
		t.Fatalf("theme 读错了: %q", c.Theme)
	}
	if len(c.Accounts) == 0 {
		t.Fatal("accounts 应当被原样透传住,而不是丢掉")
	}
}

// 缺字段不许让整份配置作废 —— 这正是 Rust 版那条注释在讲的事。
func TestLoad_缺字段只丢那一个字段(t *testing.T) {
	dir := withTempRoot(t)
	if err := os.WriteFile(filepath.Join(dir, "config.json"),
		[]byte(`{"theme":"light"}`), 0o644); err != nil {
		t.Fatal(err)
	}
	c, err := Load()
	if err != nil {
		t.Fatalf("缺字段不该报错: %v", err)
	}
	if c.Theme != "light" {
		t.Fatalf("在的那个字段要读到: %q", c.Theme)
	}
}

// ★ 保存不许把「还没移植的功能」的配置抹掉。
// 否则用户看到的是「升级之后我的 XX 设置没了」。
func TestSave_未接的字段原样保留(t *testing.T) {
	dir := withTempRoot(t)
	p := filepath.Join(dir, "config.json")
	if err := os.WriteFile(p, []byte(realShapeFixture), 0o644); err != nil {
		t.Fatal(err)
	}
	c, err := Load()
	if err != nil {
		t.Fatal(err)
	}
	c.Theme = "light"
	if err := c.Save(); err != nil {
		t.Fatal(err)
	}

	b, _ := os.ReadFile(p)
	var m map[string]json.RawMessage
	if err := json.Unmarshal(b, &m); err != nil {
		t.Fatalf("保存后的文件必须是合法 JSON: %v", err)
	}
	for _, k := range []string{"accounts", "prefs", "proxy", "danmaku_sources",
		"plugin_sources", "sync_trakt", "sync_bangumi"} {
		if _, ok := m[k]; !ok {
			t.Fatalf("★ 保存把还没移植的键 %q 抹掉了", k)
		}
	}
	if !strings.Contains(string(b), "TOKEN_PLACEHOLDER") {
		t.Fatal("★ accounts 里的内容被吃掉了")
	}
	var got AppConfig
	_ = json.Unmarshal(b, &got)
	if got.Theme != "light" {
		t.Fatalf("改动没落盘: %q", got.Theme)
	}
}

// 原子写:保存过程中不许出现「文件已被截断但还没写完」的窗口。
// 这里只能验最终状态 + 没有残留临时文件。
func TestSave_原子写不留临时文件(t *testing.T) {
	dir := withTempRoot(t)
	c, _ := Load()
	c.Theme = "dark"
	if err := c.Save(); err != nil {
		t.Fatal(err)
	}
	ents, _ := os.ReadDir(dir)
	for _, e := range ents {
		if strings.HasPrefix(e.Name(), ".config-") {
			t.Fatalf("留下了临时文件 %s", e.Name())
		}
	}
}
