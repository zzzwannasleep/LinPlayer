package player

// 外部播放器 + 播放窗中转。

import (
	"context"
	"os"
	"os/exec"
	"path/filepath"
	"strconv"
	"strings"
	"sync"

	"linplayer/core/bus"
	"linplayer/core/config"
)

// pendingPlay 待播条目。主窗点「播放」时塞进来,播放窗起来后自取。
//
// ★★ 为什么走核心层而不是命令行参数 / 本地存储:条目是个结构体,塞进参数要编码、
// 长度还有上限;两个窗口之间共享的本地存储倒是有,但那是**隐式**耦合,
// 读写时序全靠猜。核心层是两个窗口本来就共有的那份状态,最省事也最实在。
var (
	pendingMu   sync.Mutex
	pendingItem any
)

// takePending 取走待播条目并清空。**取完即清** —— 它只该被消费一次。
func takePending() any {
	pendingMu.Lock()
	defer pendingMu.Unlock()
	v := pendingItem
	pendingItem = nil
	return v
}

// isMpvLike 可执行文件名看起来像不像 mpv。
//
// ★ mpv 系通吃 `--start=`;不是 mpv 的播放器会忽略未知参数**或者直接报错**,
// 所以续播参数只在名字像 mpv 时才给 —— 给错参数导致压根打不开,比不续播糟得多。
func isMpvLike(exe string) bool {
	name := strings.ToLower(filepath.Base(exe))
	name = strings.TrimSuffix(name, filepath.Ext(name))
	return strings.Contains(name, "mpv")
}

func registerExternalCommands() {
	// player.playExternal —— 把取到的流地址交给用户自己配的播放器。
	bus.Register("player.playExternal", func(ctx context.Context, seq int64, a map[string]any) (any, error) {
		exe := strings.TrimSpace(config.Current().PrefsOf().ExternalPlayer)
		if exe == "" {
			return nil, bus.NewErr(bus.EInvalid, "未设置外部播放器")
		}
		// ★ 先确认文件在,再去取流:反过来的话用户要等一次网络往返才看到
		//   「外部播放器不存在」,而那句话第一秒就该说得出来。
		if fi, err := os.Stat(exe); err != nil || fi.IsDir() {
			return nil, bus.NewErr(bus.EInvalid, "外部播放器不存在: %s", exe)
		}
		id, _ := a["item_id"].(string)
		if id == "" {
			return nil, bus.NewErr(bus.EInvalid, "缺少 item_id")
		}
		s, err := sessionFrom(a)
		if err != nil {
			return nil, err
		}
		resume, _ := a["resume_secs"].(float64)
		msid, _ := a["media_source_id"].(string)
		target, err := prefsClient.ResolveStream(ctx, s, id, msid, config.Current().PrefsOf().VersionRegex)
		if err != nil {
			return nil, &bus.Err{Code: bus.ENetwork, Msg: err.Error(), Retryable: true}
		}
		args := []string{}
		if isMpvLike(exe) && resume > 1 {
			args = append(args, "--start="+strconv.FormatFloat(resume, 'f', 3, 64))
		}
		args = append(args, target.URL)
		if err := exec.Command(exe, args...).Start(); err != nil {
			return nil, bus.NewErr(bus.EInternal, "启动外部播放器失败: %v", err)
		}
		bus.Logf("info", "外部播放器 %s <- %s", exe, target.URL)
		return map[string]any{"url": target.URL}, nil
	})

	// player.windowOpen —— 存下待播条目,叫壳把播放窗开起来 / 叫醒。
	//
	// ★ 核心层**不解析这个信封**,它只是个中转:UI 塞什么,播放窗原样取回去自己分派。
	//   解析它等于让核心层认识每一种起播来源(Emby / 网盘 / 本地 / 影视目录),
	//   而那正是各端 UI 自己最清楚的事。
	bus.Register("player.windowOpen", func(ctx context.Context, seq int64, a map[string]any) (any, error) {
		pendingMu.Lock()
		pendingItem = a["payload"]
		pendingMu.Unlock()
		bus.Emit("player.windowOpen", map[string]any{}, "")
		return map[string]any{"ok": true}, nil
	})

	// player.takePending —— 播放窗起来后自取待播条目。
	//
	// ★ **取完即清**:它只该被消费一次。不清的话播放窗第二次起来会把上一部片
	//   重新放一遍,而用户以为自己点的是新的那部。
	bus.Register("player.takePending", func(ctx context.Context, seq int64, a map[string]any) (any, error) {
		return takePending(), nil
	})

	// player.windowClose —— 叫壳把播放窗收起来。
	//
	// ★★ 「收起来」不是「销毁」,而且**必须先停播**:窗口没了而 mpv 还在放
	//   = 有声音没画面的孤儿播放器(见 [[desktop-double-audio-orphan-player]]),
	//   这一段观看进度也会直接丢。所以这里先 stop,再让壳去藏窗。
	bus.Register("player.windowClose", func(ctx context.Context, seq int64, a map[string]any) (any, error) {
		_ = command("stop")
		bus.Emit("player.windowClose", map[string]any{}, "")
		return map[string]any{"ok": true}, nil
	})
}
