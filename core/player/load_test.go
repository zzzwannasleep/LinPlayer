package player

import (
	"strings"
	"testing"
)

// ☠ 「继续观看里的片子一点就 loadfile 失败」的门禁。
//
// mpv 的 loadfile 签名是 `loadfile <url> [<flags> [<index> [<options>]]]` ——
// **第 3 个位置是 index,不是选项**。把 `start=…` 直接拼在 `replace` 后面,
// 真 mpv 回 -4(invalid parameter),而这条路**只有带续播进度的条目才会走到**。
//
// 所以这条测试钉的不是「有没有 start=」,是**它排在第几段**。
// 只断言「参数里含 start=」的话,那个 bug 照样绿。
func Test续播的loadfile参数里start不能占掉index那一格(t *testing.T) {
	// 从头看:三段,不带 start=
	if got := loadArgs("http://h/a.mkv", 0); len(got) != 3 {
		t.Fatalf("从头看应当是三段,实得 %d 段: %q", len(got), got)
	}

	got := loadArgs("http://h/a.mkv", 123.5)
	if len(got) != 5 {
		t.Fatalf("带续播位置时应当是五段(多一格 index),实得 %d 段: %q", len(got), got)
	}
	// ★ 关键的一格:第 3 位必须是 index,不能是 start=
	if strings.HasPrefix(got[3], "start=") {
		t.Fatalf("start= 落在了 index 那一格 —— 真 mpv 会回 -4 invalid parameter: %q", got)
	}
	if got[3] != "-1" {
		t.Fatalf("index 那一格应当是 -1(追加到末尾),实得 %q: %q", got[3], got)
	}
	if got[4] != "start=123.500" {
		t.Fatalf("选项那一格不对: %q", got[4])
	}
}
