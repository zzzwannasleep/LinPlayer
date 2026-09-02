package pluginsrc

import (
	"context"
	"os"
	"path/filepath"
	"testing"

	"linplayer/core/plugin"
	"linplayer/core/source"
)

// mountPlugin 在临时目录里造一个插件、挂上、启用,返回管理器。
func mountPlugin(t *testing.T, manifest, mainJS string) *plugin.Manager {
	t.Helper()
	dir := t.TempDir()
	if err := os.WriteFile(filepath.Join(dir, "manifest.json"), []byte(manifest), 0o644); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(dir, "main.js"), []byte(mainJS), 0o644); err != nil {
		t.Fatal(err)
	}
	base := t.TempDir()
	m := plugin.NewManagerAt(filepath.Join(base, "installed"), filepath.Join(base, "storage"),
		filepath.Join(base, "state.json"), plugin.NoopHost{})
	info, err := m.InstallDevDir(dir)
	if err != nil {
		t.Fatalf("装不上: %v", err)
	}
	id, _ := info["id"].(string)
	if err := m.Enable(id); err != nil {
		t.Fatalf("启用失败: %v", err)
	}
	return m
}

const catalogManifest = `{
  "id": "com.test.vod", "name": "资源站", "version": "1.0.0", "apiVersion": 2,
  "category": "source", "permissions": ["sources"],
  "contributes": { "dataSources": [{ "id": "vod", "name": "测试资源站" }] }
}`

// ★★★ 影视目录三件套的端到端:JS 里写三个函数 → 宿主拿到的是结构化的
// MediaCategory / MediaPage / MediaDetail。
//
// 这条链是「资源站不是文件树」那个决定的落点:JS 侧一条 badge 字段,
// 到这里必须还是**独立字段**,而不是被拼进标题。
func TestCataloger端到端(t *testing.T) {
	m := mountPlugin(t, catalogManifest, `
		ctx.sources.register("vod", {
			async categories() {
				return [{ id: "movie", name: "电影", children: [{ id: "m.action", name: "动作" }] }];
			},
			async catalog(req) {
				return {
					items: [
						{ id: "v1", title: "片一", badge: "更新至17集", year: 2026, score: 9.1, isSeries: true },
						{ title: "缺 id 的一条" },
					],
					hasMore: req.page < 2,
					total: 20,
				};
			},
			async mediaDetail(id) {
				return {
					id, title: "片一详情",
					lines: [{ id: "l1", name: "线路一", episodes: [
						{ id: "e1", name: "第01集", raw: { url: "http://127.0.0.1:1/a.mp4" } },
						{ name: "缺 id 的一集" },
					]}],
				};
			},
			async resolvePlay(entry) { return { url: (entry.raw || {}).url || "" }; },
		});
	`)
	Sync(m)

	b, ok := source.Get(source.PluginKind("com.test.vod", "vod"))
	if !ok {
		t.Fatal("插件源没进分派表 —— 播放链路会查不到这个源")
	}
	cat, ok := b.(source.Cataloger)
	if !ok {
		t.Fatal("插件源没实现影视目录能力")
	}
	ctx := context.Background()
	srv := &source.Server{ID: "s", BaseURL: "http://127.0.0.1:1"}

	cats, err := cat.Categories(ctx, nil, srv)
	if err != nil {
		t.Fatalf("categories: %v", err)
	}
	if len(cats) != 1 || cats[0].ID != "movie" || len(cats[0].Children) != 1 {
		t.Fatalf("分类树没接上:%#v", cats)
	}

	page, err := cat.Catalog(ctx, nil, srv, "movie", "", 1)
	if err != nil {
		t.Fatalf("catalog: %v", err)
	}
	// ★ 缺 id 的那条要被跳过,不能让一条坏数据把整页打不开
	if len(page.Items) != 1 {
		t.Fatalf("应当只剩 1 条(缺 id 的被跳过),实得 %d", len(page.Items))
	}
	c := page.Items[0]
	if c.Badge == nil || *c.Badge != "更新至17集" {
		t.Fatalf("badge 必须是独立字段:%#v", c)
	}
	// ★ 数字也要收下:资源站的 year/score 一会儿是字符串一会儿是数字
	if c.Year == nil || *c.Year != "2026" || c.Score == nil || *c.Score != "9.1" {
		t.Fatalf("数字型 year/score 没接住:%#v", c)
	}
	if !c.IsSeries || !page.HasMore || page.Total == nil || *page.Total != 20 {
		t.Fatalf("分页信息不对:%#v", page)
	}

	d, err := cat.MediaDetailOf(ctx, nil, srv, "v1")
	if err != nil {
		t.Fatalf("mediaDetail: %v", err)
	}
	if len(d.Lines) != 1 || len(d.Lines[0].Episodes) != 1 {
		t.Fatalf("线路/分集没接上(缺 id 的一集该被跳过):%#v", d.Lines)
	}
	// ★★ raw 必须原样带回来 —— 资源站的可播地址就藏在里面,
	//    丢了的表现是「点了集数没反应」。
	ep := d.Lines[0].Episodes[0]
	if len(ep.Raw) == 0 {
		t.Fatal("分集的 raw 丢了 —— 解析不出流,点集数没反应")
	}
	play, err := b.ResolvePlay(ctx, nil, srv, &source.Entry{ID: ep.ID, Name: ep.Name, Raw: ep.Raw}, "")
	if err != nil || play.URL != "http://127.0.0.1:1/a.mp4" {
		t.Fatalf("raw 没走通到 resolvePlay:%v / %#v", err, play)
	}
}

// ★★ 网盘型插件源点开「影视目录」时必须报**不支持**,而不是一条普通错误 ——
// 前端靠它静默换路退回文件浏览页。报成普通错误的话,每个网盘用户点进去
// 都会看到一句读不懂的红字。
func TestCataloger没实现要报不支持(t *testing.T) {
	m := mountPlugin(t, catalogManifest,
		`ctx.sources.register("vod", { async listDir() { return []; } });`)
	Sync(m)

	b, _ := source.Get(source.PluginKind("com.test.vod", "vod"))
	cat := b.(source.Cataloger)
	ctx := context.Background()
	srv := &source.Server{ID: "s"}

	_, err := cat.Categories(ctx, nil, srv)
	if !source.IsUnsupported(err) {
		t.Fatalf("没实现 categories 应当判成「不支持」,实得 %v", err)
	}
	_, err = cat.Catalog(ctx, nil, srv, "", "", 1)
	if !source.IsUnsupported(err) {
		t.Fatalf("没实现 catalog 应当判成「不支持」,实得 %v", err)
	}
	_, err = cat.MediaDetailOf(ctx, nil, srv, "x")
	if !source.IsUnsupported(err) {
		t.Fatalf("没实现 mediaDetail 应当判成「不支持」,实得 %v", err)
	}
}

// ★★ 禁用插件后它的源必须**从分派表里消失**。
//
// 只加不减的话,分派表里会留下一个背后没有引擎的后端 —— 播放链路查得到它,
// 调过去却永远返回空,而界面上那个源看着还是好的。
func TestSync禁用后要摘掉源(t *testing.T) {
	m := mountPlugin(t, catalogManifest,
		`ctx.sources.register("vod", { async listDir() { return []; } });`)
	Sync(m)
	k := source.PluginKind("com.test.vod", "vod")
	if _, ok := source.Get(k); !ok {
		t.Fatal("启用后源没进分派表")
	}
	m.Disable("com.test.vod")
	Sync(m)
	if _, ok := source.Get(k); ok {
		t.Fatal("禁用后源还留在分派表里 —— 背后已经没有引擎了")
	}
}

// ★ 鉴权失效要能被 UI 认出来并引导重登;「不支持」不能被误判成失败。
func TestJS异常还原(t *testing.T) {
	if e := jsErrorToSourceError(plugin.UnsupportedMarker); !source.IsUnsupported(e) {
		t.Fatalf("裸标记没还原成 unsupported:%v", e)
	}
	if e := jsErrorToSourceError("Error: " + plugin.UnsupportedMarker + "这个源只能浏览"); e.Error() != "这个源只能浏览" {
		t.Fatalf("带说明的标记没剥干净:%v", e)
	}
	for _, msg := range []string{"HTTP 401", "Unauthorized", "登录已过期"} {
		if !source.IsAuthErr(jsErrorToSourceError(msg)) {
			t.Fatalf("%s 应判为鉴权失效", msg)
		}
	}
	if source.IsAuthErr(jsErrorToSourceError("连接被拒绝")) {
		t.Fatal("普通网络错误不该被判成鉴权失效")
	}
	if source.IsUnsupported(jsErrorToSourceError("网络超时")) {
		t.Fatal("普通错误不该被误判成 unsupported")
	}
}
