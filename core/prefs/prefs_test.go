package prefs

import (
	"encoding/json"
	"os"
	"testing"
	"time"

	"linplayer/core/bus"
	"linplayer/core/config"
	"linplayer/core/paths"
)

func TestMain(m *testing.M) {
	bus.Init()
	RegisterCommands("9.9.9")
	os.Exit(m.Run())
}

type result struct {
	OK   bool
	Data map[string]any
	Code string
	Msg  string
}

// call 走**真的命令总线**发一条命令。失败不 Fatal —— 有几条测试要的正是失败。
func call(t *testing.T, seq int64, cmd string, args map[string]any) result {
	t.Helper()
	b, _ := json.Marshal(args)
	if err := bus.Call(seq, cmd, string(b)); err != nil {
		t.Fatalf("发命令失败: %v", err)
	}
	deadline := time.Now().Add(5 * time.Second)
	for time.Now().Before(deadline) {
		ev := bus.NextEvent(200)
		if len(ev) == 0 {
			continue
		}
		var e struct {
			T    string          `json:"t"`
			Seq  int64           `json:"seq"`
			OK   bool            `json:"ok"`
			Data json.RawMessage `json:"data"`
			Err  *struct {
				Code string `json:"code"`
				Msg  string `json:"msg"`
			} `json:"err"`
		}
		if json.Unmarshal(ev, &e) != nil || e.T != "result" || e.Seq != seq {
			continue
		}
		r := result{OK: e.OK}
		if e.Err != nil {
			r.Code, r.Msg = e.Err.Code, e.Err.Msg
		}
		_ = json.Unmarshal(e.Data, &r.Data)
		return r
	}
	t.Fatalf("等不到 %s 的 result", cmd)
	return result{}
}

func setup(t *testing.T) {
	t.Helper()
	paths.SetRoot(t.TempDir())
	if _, err := config.Load(); err != nil {
		t.Fatal(err)
	}
}

// ★★ 这一层最贵的一条:**写的时候拒,不要悄悄钳**。
//
// 悄悄钳的表现是「用户设了 8 线程 / 8GB,界面显示成功,实际生效 4 线程 / 4GB」——
// 毫无反馈,而且他下次还会再设一遍。
func TestSetters拒绝越界而不是悄悄钳(t *testing.T) {
	setup(t)
	for _, c := range []struct {
		name string
		seq  int64
		cmd  string
		args map[string]any
	}{
		{"线程数 8", 101, "prefs.setPrefetchSettings",
			map[string]any{"settings": map[string]any{"threads": float64(8), "cache_bytes": float64(config.PrefetchCacheMin)}}},
		{"线程数 1", 102, "prefs.setPrefetchSettings",
			map[string]any{"settings": map[string]any{"threads": float64(1), "cache_bytes": float64(config.PrefetchCacheMin)}}},
		{"缓存 8GB", 103, "prefs.setPrefetchSettings",
			map[string]any{"settings": map[string]any{"threads": float64(3), "cache_bytes": float64(8 << 30)}}},
		{"缓存 1MB", 104, "prefs.setPrefetchSettings",
			map[string]any{"settings": map[string]any{"threads": float64(3), "cache_bytes": float64(1 << 20)}}},
		{"预热 9999MB", 105, "prefs.setPreloadSettings",
			map[string]any{"settings": map[string]any{"head_mb": float64(9999)}}},
		{"回传范围乱写", 106, "prefs.setWritebackSettings",
			map[string]any{"settings": map[string]any{"range": "乱写的"}}},
		{"更新渠道乱写", 107, "prefs.setUpdateSettings", map[string]any{"channel": "nightly"}},
		{"模糊强度 500", 108, "prefs.setDetailBlur", map[string]any{"value": float64(500)}},
	} {
		t.Run(c.name, func(t *testing.T) {
			r := call(t, c.seq, c.cmd, c.args)
			if r.OK {
				t.Fatal("越界必须报错 —— 悄悄钳的话用户以为设成功了,实际生效的是别的值")
			}
			if r.Code != bus.EInvalid {
				t.Fatalf("错误码该是 %s,实得 %s(%s)", bus.EInvalid, r.Code, r.Msg)
			}
		})
	}
}

// 读的时候相反:老配置里存着离谱值也要能打开设置页。
//
// ★ 不钳的话,设置页拿到一个越界值,用户什么都没改点一下保存就被上面那条规矩拒掉,
// 而他根本不知道哪儿不对。
func TestGetters对老配置里的离谱值要钳(t *testing.T) {
	setup(t)
	c := config.Current()
	c.Prefs = json.RawMessage(`{"prefetch_cache_bytes": 1099511627776, "prefetch_threads": 64}`)
	if err := c.Save(); err != nil {
		t.Fatal(err)
	}
	if _, err := config.Load(); err != nil {
		t.Fatal(err)
	}

	r := call(t, 201, "prefs.getPrefetchSettings", nil)
	if !r.OK {
		t.Fatalf("读设置不该失败: %s", r.Msg)
	}
	if got := int64(r.Data["cache_bytes"].(float64)); got != config.PrefetchCacheMax {
		t.Fatalf("读出来要钳到上限,实得 %d —— 不钳的话设置页一保存就被自己拒掉", got)
	}
	if got := int(r.Data["threads"].(float64)); got != 4 {
		t.Fatalf("线程数要钳到 4,实得 %d", got)
	}
}

// setPrefs **只改选轨三项**,别整体覆盖。
//
// ★ 整体覆盖的表现是:用户改个字幕语言,跨服续播 / 跳过片头 / 多线程加载全被重置。
func TestSetPrefs不碰别的字段(t *testing.T) {
	setup(t)
	c := config.Current()
	p := config.DefaultPrefs()
	p.CrossServerResume = true
	p.SkipIntro = true
	p.DetailBlur = 7
	p.VersionRegex = "4K"
	if err := c.SetPrefs(p); err != nil {
		t.Fatal(err)
	}
	if err := c.Save(); err != nil {
		t.Fatal(err)
	}
	if _, err := config.Load(); err != nil {
		t.Fatal(err)
	}

	if r := call(t, 301, "prefs.setPrefs", map[string]any{
		"audio_lang": "jpn", "sub_lang": "chi", "sub_enabled": true,
	}); !r.OK {
		t.Fatalf("改选轨不该失败: %s", r.Msg)
	}
	got := config.Current().PrefsOf()
	if got.AudioLang == nil || *got.AudioLang != "jpn" {
		t.Fatal("选轨没改上")
	}
	for _, x := range []struct {
		name string
		ok   bool
	}{
		{"cross_server_resume", got.CrossServerResume},
		{"skip_intro", got.SkipIntro},
		{"detail_blur=7", got.DetailBlur == 7},
		{"version_regex=4K", got.VersionRegex == "4K"},
	} {
		if !x.ok {
			t.Errorf("改个字幕语言把 %s 一起重置了 —— 别整体覆盖", x.name)
		}
	}
}

// 每条 setter 都必须落盘。漏了的表现是「改完看着对了,重启回到改之前」。
func TestSetters都落盘(t *testing.T) {
	setup(t)
	call(t, 401, "prefs.setDetailBlur", map[string]any{"value": float64(88)})
	call(t, 402, "prefs.setUpdateSettings", map[string]any{"channel": "prerelease", "auto_check": false})
	call(t, 403, "prefs.setWritebackSettings",
		map[string]any{"settings": map[string]any{"enabled": true, "range": "latest"}})
	call(t, 404, "prefs.setPreloadSettings",
		map[string]any{"settings": map[string]any{"enabled": false, "head_mb": float64(8)}})

	// ★ 从磁盘重新读 —— 只看内存的话,忘了 Save 的命令照样绿
	reloaded, err := config.Load()
	if err != nil {
		t.Fatal(err)
	}
	p := reloaded.PrefsOf()
	if p.DetailBlur != 88 {
		t.Errorf("detail_blur 没落盘: %d", p.DetailBlur)
	}
	if p.UpdateChannel != "prerelease" || p.UpdateAutoCheck {
		t.Errorf("更新设置没落盘: %s %v", p.UpdateChannel, p.UpdateAutoCheck)
	}
	if !p.CrossServerWriteback || p.CrossServerWritebackRange != "latest" {
		t.Errorf("回传设置没落盘: %v %s", p.CrossServerWriteback, p.CrossServerWritebackRange)
	}
	if p.PreloadEnabled || p.PreloadHeadMB != 8 {
		t.Errorf("预加载设置没落盘: %v %d", p.PreloadEnabled, p.PreloadHeadMB)
	}
}

// 多线程加载的服务器表**只留真实存在的账号**。
//
// ★ 服务器删了它的 id 还赖在表里的话,重新加同一地址的服会「自己就开着」——
// 用户没开过,它却是开的,而且没有任何地方解释为什么。
func TestPrefetchServers只留真实账号(t *testing.T) {
	setup(t)
	c := config.Current()
	c.Upsert(config.Account{Server: "https://a", Token: "t", UserID: "u"})
	if err := c.Save(); err != nil {
		t.Fatal(err)
	}

	r := call(t, 501, "prefs.setPrefetchSettings", map[string]any{"settings": map[string]any{
		"servers":     []any{"https://a", "https://早就删了的"},
		"threads":     float64(3),
		"cache_bytes": float64(config.PrefetchCacheMin),
	}})
	if !r.OK {
		t.Fatalf("不该失败: %s", r.Msg)
	}
	p := config.Current().PrefsOf()
	if len(p.PrefetchServers) != 1 || p.PrefetchServers[0] != "https://a" {
		t.Fatalf("不存在的服务器不该留在表里: %v", p.PrefetchServers)
	}
}

// 删账号时,按服务器存的开关要跟着走。
func TestRemoveAccount清掉预取开关(t *testing.T) {
	setup(t)
	c := config.Current()
	c.Upsert(config.Account{Server: "https://a", Token: "t", UserID: "u"})
	p := c.PrefsOf()
	p.PrefetchServers = []string{"https://a"}
	if err := c.SetPrefs(p); err != nil {
		t.Fatal(err)
	}
	if !c.Remove("https://a") {
		t.Fatal("该删得掉")
	}
	if got := c.PrefsOf().PrefetchServers; len(got) != 0 {
		t.Fatalf("删了账号开关还留着: %v —— 重新加同一地址的服会「自己就开着」", got)
	}
}

// settings 既能嵌套传也能摊平传 —— 少收一种就是「某个端上设置页点了没反应」。
func TestSettings嵌套与摊平都收(t *testing.T) {
	setup(t)
	if r := call(t, 601, "prefs.setPreloadSettings",
		map[string]any{"enabled": false, "head_mb": float64(4)}); !r.OK {
		t.Fatalf("摊平传应当也收: %s", r.Msg)
	}
	if p := config.Current().PrefsOf(); p.PreloadEnabled || p.PreloadHeadMB != 4 {
		t.Fatalf("摊平传的值没生效: %v %d", p.PreloadEnabled, p.PreloadHeadMB)
	}
}
