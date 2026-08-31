package system

import (
	"encoding/json"
	"os"
	"path/filepath"
	"testing"
	"time"

	"linplayer/core/bus"
	"linplayer/core/imgcache"
	"linplayer/core/paths"
)

func TestMain(m *testing.M) {
	bus.Init()
	RegisterCommands()
	os.Exit(m.Run())
}

type result struct {
	OK   bool
	Data map[string]any
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

// ★★ 清缓存**只动 cache/**,config / data / downloads 一根汗毛都不碰。
//
// 观看记录、账号、已下载的片子都在后者里 —— 清缓存把它们带走的话,
// 用户是找不回来的。
func TestClearCache只动缓存目录(t *testing.T) {
	root := t.TempDir()
	paths.SetRoot(root)
	if err := paths.EnsureDirs(); err != nil {
		t.Fatal(err)
	}

	mk := func(p string, n int) {
		t.Helper()
		if err := os.MkdirAll(filepath.Dir(p), 0o755); err != nil {
			t.Fatal(err)
		}
		if err := os.WriteFile(p, make([]byte, n), 0o644); err != nil {
			t.Fatal(err)
		}
	}
	// 缓存里的:该没
	mk(filepath.Join(paths.ImageCache(), "cover.jpg"), 1000)
	mk(filepath.Join(paths.PrefetchCache(), "seg-0"), 2000)
	// 不该动的:配置 / 观看记录 / 下载 / 插件
	mustKeep := []string{
		paths.ConfigFile(), paths.HistoryFile(),
		filepath.Join(paths.DownloadsDir(), "某片.mkv"),
		filepath.Join(paths.PluginsDir(), "p1", "manifest.json"),
	}
	for _, p := range mustKeep {
		mk(p, 10)
	}

	r := call(t, 101, "system.cacheSize", nil)
	if !r.OK {
		t.Fatal(r.Msg)
	}
	if got := int64(r.Data["bytes"].(float64)); got != 3000 {
		t.Fatalf("缓存统计该是 3000 字节,实得 %d —— 统计和清除必须说同一件事", got)
	}

	if r := call(t, 102, "system.clearCache", nil); !r.OK {
		t.Fatal(r.Msg)
	}
	if got := call(t, 103, "system.cacheSize", nil); int64(got.Data["bytes"].(float64)) != 0 {
		t.Fatalf("清完该是 0,实得 %v", got.Data["bytes"])
	}
	for _, p := range mustKeep {
		if _, err := os.Stat(p); err != nil {
			t.Fatalf("清缓存把 %s 带走了 —— 用户找不回来", p)
		}
	}
	// 目录树要留着:删光之后下一次写入会因为父目录不存在而失败
	if _, err := os.Stat(paths.ImageCache()); err != nil {
		t.Fatal("缓存目录本身该留着")
	}
}

// ★ 清缓存必须**连内存层一起清**。
//
// 只删磁盘的话内存里那份还在继续供图,用户看着占用变 0、封面却还是旧的
// —— 那不叫清理,叫骗人。
func TestClearCache连内存层一起清(t *testing.T) {
	paths.SetRoot(t.TempDir())
	if err := paths.EnsureDirs(); err != nil {
		t.Fatal(err)
	}
	imgcache.MemPut("某张封面", []byte("旧的字节"))
	if imgcache.MemGet("某张封面") == nil {
		t.Fatal("前提不成立:该塞进去了")
	}
	if r := call(t, 201, "system.clearCache", nil); !r.OK {
		t.Fatal(r.Msg)
	}
	if imgcache.MemGet("某张封面") != nil {
		t.Fatal("内存层没清 —— 占用显示 0 却还在供旧封面")
	}
}

// dataPaths 要把该给的都给全:UI 靠它解释「为什么数据在这个位置」。
func TestDataPaths(t *testing.T) {
	root := t.TempDir()
	paths.SetRoot(root)
	r := call(t, 301, "system.dataPaths", nil)
	if !r.OK {
		t.Fatal(r.Msg)
	}
	for _, k := range []string{"root", "config", "history", "cache", "logs", "downloads", "plugins", "models", "exe_dir", "kind"} {
		v, ok := r.Data[k].(string)
		if !ok || v == "" {
			t.Errorf("dataPaths 缺 %q", k)
		}
	}
	if r.Data["root"] != root {
		t.Fatalf("root 该是当前数据根: %v", r.Data["root"])
	}
}

// 本平台做不了的那几条要报 E_UNSUPPORTED,**而不是从命令表里消失**。
//
// ★ 两份不同的命令表 = 两份不同的契约测试,而漏的那份就是「点了没反应」。
func TestPickers报不支持而不是消失(t *testing.T) {
	names := []string{"system.pickFile", "system.pickDirectory", "system.pickLocalFolder"}
	registered := map[string]bool{}
	for _, c := range bus.Commands() {
		registered[c] = true
	}
	for i, n := range names {
		if !registered[n] {
			t.Fatalf("%s 该在命令表里(只是返回 E_UNSUPPORTED)", n)
		}
		r := call(t, int64(400+i), n, nil)
		if r.OK {
			t.Fatalf("%s 不该成功", n)
		}
		if r.Code != bus.EUnsupported {
			t.Fatalf("%s 的错误码该是 %s,实得 %s", n, bus.EUnsupported, r.Code)
		}
	}
}
