package player

import (
	"encoding/json"
	"os"
	"path/filepath"
	"testing"
	"time"

	"linplayer/core/bus"
	"linplayer/core/config"
	"linplayer/core/paths"
)

func TestMain(m *testing.M) {
	bus.Init()
	// ★ 只注册偏好那批。整包 RegisterCommands 会一起注册 player.play,
	//   而那条要真 libmpv —— 测试进程里没有 DLL 就起不来。
	registerPrefsCommands("test")
	os.Exit(m.Run())
}

type result struct {
	OK   bool
	Data json.RawMessage
	Code string
	Msg  string
}

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
		r := result{OK: e.OK, Data: e.Data}
		if e.Err != nil {
			r.Code, r.Msg = e.Err.Code, e.Err.Msg
		}
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

// 三条正则**都要先校验完再落盘**。
//
// ★ 边校验边写的话,第三条不合法时前两条已经存进去了 ——
// 用户看到报错,却发现设置被改了一半。
func TestSetTrackRegexes全部合法才落盘(t *testing.T) {
	setup(t)
	r := call(t, 101, "player.setTrackRegexes", map[string]any{
		"version_regex": "4K", "sub_regex": "简", "audio_regex": "[",
	})
	if r.OK {
		t.Fatal("有一条非法就该整体拒掉")
	}
	if r.Code != bus.EInvalid {
		t.Fatalf("错误码该是 %s,实得 %s", bus.EInvalid, r.Code)
	}
	p := config.Current().PrefsOf()
	if p.VersionRegex != "" || p.SubRegex != "" {
		t.Fatalf("拒掉的这次不该写进去任何一条:version=%q sub=%q —— 用户会看到设置被改了一半",
			p.VersionRegex, p.SubRegex)
	}

	// 全合法时三条都要生效,而且**不碰别的偏好**
	c := config.Current()
	pf := c.PrefsOf()
	pf.SkipIntro = true
	pf.DetailBlur = 7
	if err := c.SetPrefs(pf); err != nil {
		t.Fatal(err)
	}
	if r := call(t, 102, "player.setTrackRegexes", map[string]any{
		"version_regex": "4K", "sub_regex": "简", "audio_regex": "jpn",
	}); !r.OK {
		t.Fatalf("全合法不该失败: %s", r.Msg)
	}
	got := config.Current().PrefsOf()
	if got.VersionRegex != "4K" || got.SubRegex != "简" || got.AudioRegex != "jpn" {
		t.Fatalf("三条正则没都写进去: %+v", got)
	}
	if !got.SkipIntro || got.DetailBlur != 7 {
		t.Fatal("设正则把别的偏好一起重置了 —— 别整体覆盖")
	}
}

// 正则校验必须用**核心层这套引擎**,不能只看长得像不像。
func TestValidateTrackRegex(t *testing.T) {
	setup(t)
	if r := call(t, 201, "player.validateTrackRegex", map[string]any{"pattern": ""}); !r.OK {
		t.Fatal("空串算合法(= 关闭该筛选)")
	}
	if r := call(t, 202, "player.validateTrackRegex", map[string]any{"pattern": "简|繁"}); !r.OK {
		t.Fatal("中文正则该放行")
	}
	if r := call(t, 203, "player.validateTrackRegex", map[string]any{"pattern": "["}); r.OK {
		t.Fatal("非法正则必须拒 —— 放行的话用户在设置页看到「合法」,实际一条都匹配不上")
	}
}

// setPlaybackPrefs 拒而不是夹。
func TestSetPlaybackPrefs拒绝非法值(t *testing.T) {
	setup(t)
	for _, c := range []struct {
		name string
		seq  int64
		args map[string]any
	}{
		{"未知解码方式", 301, map[string]any{"hwdec": "vaapi-copy"}},
		{"倍速 99", 302, map[string]any{"default_speed": float64(99)}},
		{"倍速 0", 303, map[string]any{"default_speed": float64(0)}},
		{"外部播放器不存在", 304, map[string]any{"external_player": "C:/根本没有这个文件.exe"}},
	} {
		t.Run(c.name, func(t *testing.T) {
			r := call(t, c.seq, "player.setPlaybackPrefs", c.args)
			if r.OK {
				t.Fatal("必须拒 —— 静默夹紧/放行会让用户以为设上了,等起播才炸")
			}
		})
	}
}

// 外部播放器指向一个**真实存在**的文件时要收下。
//
// ★ 对照组:没有这条的话,上面那条「不存在要拒」在「永远拒」时也会绿。
func TestSetPlaybackPrefs收下真实路径(t *testing.T) {
	setup(t)
	f := filepath.Join(t.TempDir(), "player.exe")
	if err := os.WriteFile(f, []byte("x"), 0o755); err != nil {
		t.Fatal(err)
	}
	if r := call(t, 401, "player.setPlaybackPrefs", map[string]any{"external_player": f}); !r.OK {
		t.Fatalf("真实存在的路径该收下: %s", r.Msg)
	}
	if got := config.Current().PrefsOf().ExternalPlayer; got != f {
		t.Fatalf("没写进去: %q", got)
	}
	// 目录不算 —— 起播时同样打不开
	if r := call(t, 402, "player.setPlaybackPrefs", map[string]any{"external_player": filepath.Dir(f)}); r.OK {
		t.Fatal("目录不该被当成可执行文件")
	}
}

// 档位表:顺序就是 UI 顺序,且「锐化专精」那一族必须在。
func TestShaderLevels(t *testing.T) {
	setup(t)
	r := call(t, 501, "player.shaderLevels", nil)
	if !r.OK {
		t.Fatal(r.Msg)
	}
	var levels []shaderLevel
	if err := json.Unmarshal(r.Data, &levels); err != nil {
		t.Fatal(err)
	}
	if len(levels) == 0 || levels[0].ID != "off" {
		t.Fatalf("第一档必须是 off: %+v", levels)
	}
	groups := map[string]bool{}
	for _, l := range levels {
		groups[l.Group] = true
	}
	// ★ Sharpen 那一族是「窗口也生效」的那批,用户点名最有用 —— 少了等于日常首选没了
	for _, g := range []string{"Anime4K", "FSR", "NVIDIA", "Sharpen"} {
		if !groups[g] {
			t.Errorf("缺了 %s 这一族", g)
		}
	}
}
