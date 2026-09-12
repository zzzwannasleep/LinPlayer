package player

// 外部播放器 + 播放窗中转。

import (
	"context"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"strconv"
	"strings"
	"sync"

	"linplayer/core/bus"
	"linplayer/core/config"
	"linplayer/core/emby"
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
		queue := []extEntry{{URL: target.URL}}
		if isMpvLike(exe) {
			queue = externalQueue(ctx, s, id, target.URL)
		}
		args := externalArgs(isMpvLike(exe), resume, queue)
		if err := exec.Command(exe, args...).Start(); err != nil {
			return nil, bus.NewErr(bus.EInternal, "启动外部播放器失败: %v", err)
		}
		bus.Logf("info", "外部播放器 %s <- %d 条,首条 %s", exe, len(queue), queue[0].Title)
		return map[string]any{"url": target.URL, "count": len(queue)}, nil
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

// ---------------------------------------------------------------- 交给外部播放器的队列

// ExternalQueueMax 最多往外部播放器塞几集。
//
// ★ 每一集都要单独问一次 PlaybackInfo(一次 POST,服务端还会为它开一个会话),
// 整季一百集就是一百次 —— 点一下按钮等半分钟,服务端凭空多出一百个会话。
const ExternalQueueMax = 12

// extEntry 队列里的一条:一个地址配一个人看得懂的标题。
type extEntry struct {
	URL   string
	Title string
}

// externalArgs 拼命令行。
//
// ★ **标题必须传。** 不传的话外部播放器看到的是一串 Emby 直传 URL,
// uosc_danmaku 这类靠标题搜弹幕的脚本什么都搜不到
// (用户 2026-09-12:「并不能传递视频标题、多个视频地址」)。
//
// ★ 逐条用 `--{ … --}` 包起来,标题才**跟着各自那一条**走。写成一个全局
// `--force-media-title` 的话,第二集起显示的还是第一集的名字 —— 弹幕会跟着搜错。
// 本机 mpv 实测:两条分别报出 `标题甲` / `标题乙`。
//
// ★ `--start=` 只给**第一条**。放全局的话后面每一集都会跳到同一个续播点。
func externalArgs(mpvLike bool, resume float64, q []extEntry) []string {
	if !mpvLike {
		// 不是 mpv 的播放器会忽略未知参数**或者直接报错**,后者连片都打不开。
		// 所以只递一个地址,一个参数都不加。
		return []string{q[0].URL}
	}
	args := []string{}
	for i, e := range q {
		args = append(args, "--{")
		if i == 0 && resume > 1 {
			args = append(args, "--start="+strconv.FormatFloat(resume, 'f', 3, 64))
		}
		if e.Title != "" {
			args = append(args, "--force-media-title="+e.Title)
		}
		args = append(args, e.URL, "--}")
	}
	return args
}

// externalQueue 这一条,加上它后面还没看的那几集。
//
// ★ 一路都是**拿不到就算了**:队列是锦上添花,为了它把「打开外部播放器」
// 整个弄失败是本末倒置。最差的结果就是回到只有一条地址的老样子。
func externalQueue(ctx context.Context, s *emby.Session, id, url string) []extEntry {
	head := extEntry{URL: url}
	d, err := prefsClient.Detail(ctx, s, id, false)
	if err != nil {
		return []extEntry{head}
	}
	head.Title = itemTitle(d.SeriesName, d.SeasonNo, d.EpisodeNo, d.Name)
	if d.Type != "Episode" || d.SeasonID == nil {
		return []extEntry{head}
	}
	page, err := prefsClient.SeasonEpisodes(ctx, s, *d.SeasonID, 0, emby.ServerPageCap)
	if err != nil {
		return []extEntry{head}
	}
	out := []extEntry{head}
	after := false
	for i := range page.Items {
		it := &page.Items[i]
		if it.ID == id {
			after = true
			continue
		}
		if !after || len(out) >= ExternalQueueMax {
			continue
		}
		t, err := prefsClient.ResolveStream(ctx, s, it.ID, "", config.Current().PrefsOf().VersionRegex)
		if err != nil {
			// 这一集取不到就到此为止:跳过它接着往下排,会让「下一集」变成隔一集
			break
		}
		out = append(out, extEntry{
			URL:   t.URL,
			Title: itemTitle(it.SeriesName, it.SeasonNo, it.EpisodeNo, it.Name),
		})
	}
	return out
}

// itemTitle 人看得懂的标题:`剧名 S01E05 集名`。分集的 Name 只是「第 5 集」,
// 单看无意义 —— 弹幕脚本拿它去搜,搜出来的会是另一部片。
func itemTitle(series *string, season, episode *int64, name string) string {
	parts := []string{}
	if series != nil && *series != "" {
		parts = append(parts, *series)
	}
	if season != nil && episode != nil {
		parts = append(parts, fmt.Sprintf("S%02dE%02d", *season, *episode))
	}
	if name != "" && (len(parts) == 0 || name != parts[0]) {
		parts = append(parts, name)
	}
	return strings.Join(parts, " ")
}
