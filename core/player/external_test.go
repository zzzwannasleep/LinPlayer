package player

import "testing"

// ★★ 续播参数只能给 mpv 系。别的播放器拿到未知参数会**直接打不开** ——
// 而「点了没反应」比「没续播」糟得多。
func TestIsMpvLike(t *testing.T) {
	yes := []string{
		`C:\tools\mpv.exe`, `/usr/bin/mpv`, `D:\mpv.net\mpvnet.exe`, `/opt/MPV/MPV.EXE`,
	}
	no := []string{
		`C:\Program Files\VideoLAN\VLC\vlc.exe`, `/usr/bin/ffplay`,
		// ★ 目录名里带 mpv 不算 —— 判据是**可执行文件名**。
		//   按整条路径判的话,把播放器装在 D:\mpv\ 下的人会拿到 --start=,
		//   而那个播放器根本不认。
		`D:\mpv\vlc.exe`,
	}
	for _, p := range yes {
		if !isMpvLike(p) {
			t.Fatalf("%q 应当认成 mpv 系", p)
		}
	}
	for _, p := range no {
		if isMpvLike(p) {
			t.Fatalf("%q 不是 mpv,给了 --start= 会打不开", p)
		}
	}
}

// ★★ 待播条目**取完即清**。
//
// 不清的话播放窗第二次起来会把上一部片重新放一遍 —— 而用户以为自己点的是新的那部,
// 且没有任何报错。
func TestPendingItem_只能被消费一次(t *testing.T) {
	pendingMu.Lock()
	pendingItem = map[string]any{"item_id": "x1"}
	pendingMu.Unlock()

	// ★ 调**本尊** takePending(),不许在测试里抄一份同样的逻辑 ——
	//   抄的那份永远是绿的,本仓栽过两次。
	if takePending() == nil {
		t.Fatal("第一次应当取得到")
	}
	if v := takePending(); v != nil {
		t.Fatalf("第二次还取得到 %v —— 播放窗会把上一部片重放一遍", v)
	}
}
