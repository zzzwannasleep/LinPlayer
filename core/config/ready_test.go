package config

import (
	"os"
	"path/filepath"
	"testing"

	"linplayer/core/paths"
)

/*
☠ 2026-09-12 真机自检当场撞到的:自检账号被清空了。

根因是 `lp_init` 里 `commands.RegisterAll` 排在 `config.Load` **之前**,
而注册期起的一个后台活往配置里记了一句话。那一刻 `Current()` 回的是 `defaults()`
—— 保存它就是把盘上的账号覆盖成空,而且一声不吭。

所以这条钉两件事:① 没加载过时 `Ready()` 必须说没准备好;
② 那一刻 `Current()` 确实是空的(危险是真的,不是我多虑)。
启动早期要写配置的代码,先问 `Ready()`。
*/
func TestReady_没加载过时不许写配置(t *testing.T) {
	root := t.TempDir()
	paths.SetRoot(root)
	if err := os.MkdirAll(filepath.Dir(paths.ConfigFile()), 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(paths.ConfigFile(),
		[]byte(`{"accounts":[{"server":"http://x","name":"我的服务器"}]}`), 0o644); err != nil {
		t.Fatal(err)
	}

	mu.Lock()
	current = nil // lp_init 里 config.Load 之前的那一刻
	mu.Unlock()

	if Ready() {
		t.Fatal("还没加载就说准备好了 —— 调用方会拿空配置去 Save,账号当场清空")
	}
	if n := len(Current().AccountList); n != 0 {
		t.Fatalf("没加载时 Current() 竟然有 %d 个账号 —— 这条测试的前提变了,重写它", n)
	}

	if _, err := Load(); err != nil {
		t.Fatal(err)
	}
	if !Ready() {
		t.Fatal("加载完了还说没准备好")
	}
	if len(Current().AccountList) != 1 {
		t.Fatalf("加载完账号没回来:%+v", Current().AccountList)
	}
}
