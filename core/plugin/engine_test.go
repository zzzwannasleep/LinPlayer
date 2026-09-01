package plugin

import (
	"os"
	"path/filepath"
	"strings"
	"testing"
)

// devPlugin 在临时目录里造一个插件,返回目录。
func devPlugin(t *testing.T, manifest, mainJS string) string {
	t.Helper()
	dir := t.TempDir()
	if err := os.WriteFile(filepath.Join(dir, "manifest.json"), []byte(manifest), 0o644); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(dir, "main.js"), []byte(mainJS), 0o644); err != nil {
		t.Fatal(err)
	}
	return dir
}

// newTestManager 建一个只在临时目录里活动的管理器。
func newTestManager(t *testing.T, host Host) *Manager {
	t.Helper()
	base := t.TempDir()
	return NewManagerAt(filepath.Join(base, "installed"), filepath.Join(base, "storage"),
		filepath.Join(base, "state.json"), host)
}

const srcManifest = `{
  "id": "com.test.demo", "name": "演示源", "version": "1.0.0", "apiVersion": 2,
  "category": "source",
  "permissions": ["sources", "storage"],
  "contributes": { "dataSources": [{ "id": "demo", "name": "演示网盘" }] }
}`

// ★★★ 承重梁:插件写三个函数就是一个完整数据源。
//
// 这条测试要同时钉住四件只有真跑 JS 才验得了的事:
//  1. async 函数能跑通(宿主等得到它的返回值);
//  2. manifest 静态声明的 name 在插件运行时注册回调后**还在**
//     —— 合并语义坏掉的表现是「添加服务器」页拿到一个没有名字、没有表单的源;
//  3. ctx.storage 真落盘、真读得回来;
//  4. ctx.errors.unsupported() 的标记能穿过 JS 异常传回来。
func TestPluginDataSource端到端(t *testing.T) {
	dir := devPlugin(t, srcManifest, `
		ctx.sources.register("demo", {
			async listDir(dirId, server) {
				await ctx.storage.set("last", dirId || "root");
				return [
					{ id: "a", name: "第01话.mkv" },
					{ id: "b", name: "子目录", isDir: true },
				];
			},
			async search(q) { throw ctx.errors.unsupported(); },
			async lastDir() { return await ctx.storage.get("last"); },
		});
	`)

	m := newTestManager(t, NoopHost{})
	if _, err := m.InstallDevDir(dir); err != nil {
		t.Fatalf("装不上: %v", err)
	}
	if err := m.Enable("com.test.demo"); err != nil {
		t.Fatalf("启用失败: %v", err)
	}

	// 1 + 3:async 跑通,storage 真写进去了
	out, err := m.CallSource("com.test.demo", "demo", "listDir", []any{"/movies", nil})
	if err != nil {
		t.Fatalf("listDir 失败: %v", err)
	}
	list, ok := out.([]any)
	if !ok || len(list) != 2 {
		t.Fatalf("listDir 应当返回 2 行,实得 %#v", out)
	}
	first, _ := list[0].(map[string]any)
	if first["name"] != "第01话.mkv" {
		t.Fatalf("第一行不对: %#v", first)
	}

	last, err := m.CallSource("com.test.demo", "demo", "lastDir", nil)
	if err != nil || last != "/movies" {
		t.Fatalf("storage 没落地:%v / %#v", err, last)
	}

	// 2:manifest 里的 name 不能被运行时注册顶掉
	c, ok := m.Registry().Find("com.test.demo", KindDataSources, "demo")
	if !ok {
		t.Fatal("贡献点没注册上")
	}
	if c.Data["name"] != "演示网盘" {
		t.Fatalf("manifest 里的 name 被运行时注册冲掉了:%#v —— "+
			"表现是「添加服务器」页拿到一个没名字没表单的插件源", c.Data)
	}
	if HandlerRefOf(c.Data["listDir"]).None() {
		t.Fatal("运行时注册的 listDir 回调没接上")
	}

	// 4:unsupported 标记要能穿过 JS 异常
	if _, err := m.CallSource("com.test.demo", "demo", "search", []any{"x", nil}); err == nil ||
		!strings.Contains(err.Error(), UnsupportedMarker) {
		t.Fatalf("unsupported 标记丢了:%v —— 丢了的话每个不支持搜索的插件源都会糊用户一脸红字", err)
	}
}

// ★★ 权限门必须在**运行时**也拦得住,不只是 manifest 静态校验。
//
// 只靠静态校验的话,一个没声明 http 的插件照样能在代码里调 ctx.http.get ——
// 而它是整套沙箱唯一的出网口。
func TestCtx权限门运行时也要拦(t *testing.T) {
	dir := devPlugin(t, `{
	  "id": "com.test.noperm", "name": "无权限", "version": "1.0.0", "apiVersion": 2,
	  "permissions": ["extensions"],
	  "contributes": { "actions": [{ "id": "go", "title": "试试", "handler": "tryFetch" }] }
	}`, `
		globalThis.tryFetch = async function () {
			try { await ctx.http.get("https://example.com/"); return "居然通了"; }
			catch (e) { return "被拒:" + e.message; }
		};
	`)

	m := newTestManager(t, NoopHost{})
	if _, err := m.InstallDevDir(dir); err != nil {
		t.Fatal(err)
	}
	if err := m.Enable("com.test.noperm"); err != nil {
		t.Fatal(err)
	}
	out, err := m.TriggerExtension("com.test.noperm", "actions", "go", nil)
	if err != nil {
		t.Fatalf("触发失败: %v", err)
	}
	s, _ := out.(string)
	if !strings.Contains(s, "缺少权限") {
		t.Fatalf("没声明 http 却出网成功了:%q —— 白名单是这套沙箱唯一的出网闸", s)
	}
}

// ★ 生命周期:onEnable 抛错时插件仍算装上了,但**错误必须留下来**。
//
// 黄金实现第一版把它吞了:插件在 onEnable 里写错一行,界面上却是
// 「已启用、无错误」,面板永远空白且没有任何线索。
func TestOnEnable出错要留痕(t *testing.T) {
	dir := devPlugin(t, `{
	  "id": "com.test.boom", "name": "会炸", "version": "1.0.0", "apiVersion": 2,
	  "permissions": []
	}`, `ctx.onEnable(function () { throw new Error("我坏了"); });`)

	m := newTestManager(t, NoopHost{})
	if _, err := m.InstallDevDir(dir); err != nil {
		t.Fatal(err)
	}
	if err := m.Enable("com.test.boom"); err != nil {
		t.Fatalf("onEnable 出错不该让启用整体失败: %v", err)
	}
	var got map[string]any
	for _, p := range m.List() {
		if p["id"] == "com.test.boom" {
			got = p
		}
	}
	if got == nil {
		t.Fatal("插件不在列表里")
	}
	if got["status"] != string(StatusError) {
		t.Fatalf("状态应当是 error,实得 %v", got["status"])
	}
	if !strings.Contains(got["error"].(string), "我坏了") {
		t.Fatalf("onEnable 的错误被吞了:%v", got["error"])
	}
}

// ★ 禁用要真的把引擎停掉:停不掉的表现是「关了还在跑」,而且卸载后回调还在。
func TestDisable停引擎(t *testing.T) {
	dir := devPlugin(t, srcManifest, `ctx.sources.register("demo", { async listDir() { return []; } });`)
	m := newTestManager(t, NoopHost{})
	if _, err := m.InstallDevDir(dir); err != nil {
		t.Fatal(err)
	}
	if err := m.Enable("com.test.demo"); err != nil {
		t.Fatal(err)
	}
	m.Disable("com.test.demo")
	if _, ok := m.Registry().Find("com.test.demo", KindDataSources, "demo"); ok {
		t.Fatal("禁用后贡献点还挂着")
	}
	// 禁用后再调不能卡住,也不能 panic
	if _, err := m.CallSource("com.test.demo", "demo", "listDir", nil); err == nil {
		t.Log("禁用后调用返回 nil 错误(贡献点已摘,等同于没这个源)")
	}
}
