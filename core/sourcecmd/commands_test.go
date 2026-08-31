package sourcecmd

// 这一层的判据集中在**状态从哪来**和**错误怎么分类**上。
//
// ★ 「活跃源从配置现算」是本包的一条设计决定,不是实现细节 ——
// 黄金实现那边活跃源另存了一份内存状态,和账号表并存。两份状态就有两份真相:
// 切服务器改了账号表而没改那个互斥量,表现是「切过去了,浏览的还是上一个源」。

import (
	"context"
	"encoding/json"
	"os"
	"path/filepath"
	"testing"

	"linplayer/core/bus"
	"linplayer/core/config"
	"linplayer/core/paths"
	"linplayer/core/source"
)

func fresh(t *testing.T) string {
	t.Helper()
	root := t.TempDir()
	paths.SetRoot(root)
	if _, err := config.Load(); err != nil {
		t.Fatal(err)
	}
	registerBackends()
	return root
}

// dir 造一个可以当本地源根的目录。
func dir(t *testing.T) string {
	t.Helper()
	d := t.TempDir()
	if err := os.WriteFile(filepath.Join(d, "a.mkv"), []byte("x"), 0o644); err != nil {
		t.Fatal(err)
	}
	if err := os.MkdirAll(filepath.Join(d, "子目录"), 0o755); err != nil {
		t.Fatal(err)
	}
	return d
}

func login(t *testing.T, kind, baseURL string) error {
	t.Helper()
	_, err := cmdLogin(context.Background(), 1, map[string]any{
		"kind": kind, "base_url": baseURL, "username": "", "password": "",
	})
	return err
}

// ★★ 登录成功必须**落进同一张账号表**。
//
// 源和 Emby 共用一张表 —— 重启免登 + 多源并存全靠这一步。
// 不落的话:重启回到「没有源」,而登录那一刻明明是成功的。
func TestLogin_成功要落进账号表(t *testing.T) {
	fresh(t)
	root := dir(t)
	if err := login(t, "local", root); err != nil {
		t.Fatalf("登录失败: %v", err)
	}
	c := config.Current()
	if len(c.AccountList) != 1 {
		t.Fatalf("账号表应当有 1 条,实得 %d —— 重启后会变回「没有源」", len(c.AccountList))
	}
	a := c.AccountList[0]
	if a.SourceKind() != "local" {
		t.Fatalf("source_kind 落错了: %q(线上必须是小写)", a.SourceKind())
	}
	if len(a.RestValue("source")) == 0 {
		t.Fatal("source 连接信息没落库 —— 下次启动列不出目录")
	}
}

// ★ 登录要成为**活跃账号**,否则 currentSource 恒空,前端当你没登录。
func TestLogin_要成为活跃账号(t *testing.T) {
	fresh(t)
	if err := login(t, "local", dir(t)); err != nil {
		t.Fatal(err)
	}
	got, err := cmdCurrentSource(context.Background(), 2, nil)
	if err != nil {
		t.Fatal(err)
	}
	if got == nil {
		t.Fatal("currentSource 是空的 —— 前端会当你没登录")
	}
	m := got.(map[string]any)
	if m["source_kind"] != "local" || m["is_file_browse"] != true {
		t.Fatalf("currentSource 字段不对: %+v", m)
	}
}

// ★★ 探测不通就**不许落库**。
//
// 落了的话:用户填错一次路径,一个打不开的源就永久赖在服务器列表里,
// 而且会被 Upsert 设成活跃账号 —— 下次启动直接进一个列不出目录的源。
func TestLogin_探测不通不许落库(t *testing.T) {
	fresh(t)
	err := login(t, "local", filepath.Join(t.TempDir(), "根本不存在"))
	if err == nil {
		t.Fatal("路径不存在却登录成功了")
	}
	if n := len(config.Current().AccountList); n != 0 {
		t.Fatalf("探测失败却落了 %d 条账号 —— 填错一次路径就永久多一个打不开的源", n)
	}
}

// ★ 还没移植的源要说「这个版本还不支持」,不是一句莫名其妙的失败。
func TestLogin_没移植的源要说清楚(t *testing.T) {
	fresh(t)
	err := login(t, "quark", "")
	if err == nil {
		t.Fatal("没有后端却登录成功了")
	}
	var be *bus.Err
	if !asBusErr(err, &be) || be.Code != bus.EUnsupported {
		t.Fatalf("错误码应当是 E_UNSUPPORTED,实得 %v", err)
	}
}

// ★★ 活跃源**从配置现算**:切了账号,浏览的就必须是新的那个。
func TestActiveSource_跟着活跃账号走(t *testing.T) {
	fresh(t)
	d1, d2 := dir(t), dir(t)
	if err := login(t, "local", d1); err != nil {
		t.Fatal(err)
	}
	if err := login(t, "local", d2); err != nil {
		t.Fatal(err)
	}
	_, srv, err := activeSource()
	if err != nil {
		t.Fatal(err)
	}
	if srv.BaseURL != d2 {
		t.Fatalf("活跃源还是上一个: %q,应当是 %q —— "+
			"「切过去了,浏览的还是上一个源」就是这么来的", srv.BaseURL, d2)
	}
}

// ★ 没登录任何源时,浏览要报**鉴权**类错误(UI 据此引导去添加服务器),
//   不是一句网络错误。
func TestListDir_没登录源要报鉴权(t *testing.T) {
	fresh(t)
	_, err := cmdListDir(context.Background(), 3, map[string]any{})
	if err == nil {
		t.Fatal("没登录却列出来了")
	}
	var be *bus.Err
	if !asBusErr(err, &be) || be.Code != bus.EAuth {
		t.Fatalf("应当是 E_AUTH,实得 %v", err)
	}
}

// ★ 列目录端到端:登录 → 列根目录 → 拿到条目。
func TestListDir_端到端(t *testing.T) {
	fresh(t)
	root := dir(t)
	if err := login(t, "local", root); err != nil {
		t.Fatal(err)
	}
	got, err := cmdListDir(context.Background(), 4, map[string]any{})
	if err != nil {
		t.Fatal(err)
	}
	entries := got.([]source.Entry)
	if len(entries) != 2 {
		t.Fatalf("应当 2 条,实得 %d: %+v", len(entries), entries)
	}
	if !entries[0].IsDir {
		t.Fatal("目录没排在最前")
	}
	// ★ 空目录也要是 [] 不是 null(前端 .map() 会抛)
	sub, err := cmdListDir(context.Background(), 5, map[string]any{"dir_id": entries[0].ID})
	if err != nil {
		t.Fatal(err)
	}
	b, _ := json.Marshal(sub)
	if string(b) != "[]" {
		t.Fatalf("空目录序列化成了 %s —— null 会让前端 .map() 直接抛", b)
	}
}

// ★★ 「这个源没有源端搜索」不是故障:前端据此**退回当前目录本地过滤**。
//
// 所以必须是一条能被认出来的错误,**不能回空数组** —— 回空数组的话
// 前端会以为「搜过了,没搜到」,而用户明明看得见那个文件就在眼前。
func TestSearch_不支持要能被认出来(t *testing.T) {
	fresh(t)
	if err := login(t, "local", dir(t)); err != nil {
		t.Fatal(err)
	}
	got, err := cmdSearch(context.Background(), 6, map[string]any{"query": "a"})
	if err == nil {
		t.Fatalf("本地源没有源端搜索,却返回了 %v —— 前端会以为「搜过了,没搜到」", got)
	}
	var be *bus.Err
	if !asBusErr(err, &be) || be.Code != bus.EUnsupported {
		t.Fatalf("应当是 E_UNSUPPORTED,实得 %v", err)
	}
}

// ★ 影视目录三条:不是资源站的源要回「没这个能力」,前端据此走文件浏览页。
func TestCategories_文件树源要回没这个能力(t *testing.T) {
	fresh(t)
	if err := login(t, "local", dir(t)); err != nil {
		t.Fatal(err)
	}
	_, err := cmdCategories(context.Background(), 7, nil)
	if err == nil {
		t.Fatal("本地源不是资源站,却给出了分类")
	}
	if !containsUnsupportedMark(err.Error()) {
		t.Fatalf("错误里没有可机读的标记: %v —— "+
			"靠中文提示语判断会在改文案时静默失效", err)
	}
}

func containsUnsupportedMark(s string) bool {
	return len(s) > 0 && source.IsUnsupported(errString(s))
}

type errString string

func (e errString) Error() string { return string(e) }

func asBusErr(err error, out **bus.Err) bool {
	e, ok := err.(*bus.Err)
	if ok {
		*out = e
	}
	return ok
}
