package plugin

import (
	"strings"
	"testing"
)

// ★★ 贡献点 id 是**写在用户 manifest 里的字面量**,也是前端查询用的键。
// 改一个字母,所有已发布插件的那一类贡献静默消失(不报错,只是不出现)。
func TestKindID是稳定线上串(t *testing.T) {
	for _, pair := range [][2]string{
		{string(KindDataSources), "dataSources"},
		{string(KindPanels), "panels"},
		{string(KindActions), "actions"},
		{string(KindSandboxViews), "sandboxViews"},
	} {
		if pair[0] != pair[1] {
			t.Fatalf("贡献点 id 变了:%s != %s", pair[0], pair[1])
		}
		if k, ok := KindFromID(pair[1]); !ok || string(k) != pair[1] {
			t.Fatalf("%s 认不出来了", pair[1])
		}
	}
	// v1 的老扩展点名一律不再认 —— 认了会让 v1 插件半死不活地跑起来
	for _, old := range []string{"sidebarItems", "mediaSources", "eventListeners",
		"settingsPages", "homeStats", "playerOverlays", "contextMenus"} {
		if _, ok := KindFromID(old); ok {
			t.Fatalf("v1 扩展点名 %s 不该还被认", old)
		}
	}
}

// ★★ 每类贡献都必须绑一个权限。漏绑 = 用户在授权弹窗里看不见、却被挂上了东西。
//
// 另外 panels/actions 绑的必须是 `extensions` 而不是 `ui`:黄金实现第一版绑错,
// 结果是只声明 `ui` 的插件**静态校验过、运行时被拒**,而拒的异常在 onEnable 里
// 被吞掉 —— 表现为「插件显示已启用、面板永远是空的」。
func TestEveryKind都绑了已知权限(t *testing.T) {
	for _, k := range AllKinds {
		p := k.RequiredPermission()
		if p == "" {
			t.Fatalf("%s 没绑权限", k)
		}
		if !IsKnownPermission(p) {
			t.Fatalf("%s 绑了一个不存在的权限 %s", k, p)
		}
	}
	if KindPanels.RequiredPermission() != "extensions" {
		t.Fatal("panels 必须绑 extensions;绑 ui 会让静态校验和运行时两把尺子对不上")
	}
	if KindActions.RequiredPermission() != "extensions" {
		t.Fatal("actions 必须绑 extensions")
	}
}

func TestGranted_log隐式授予(t *testing.T) {
	g := NewGranted([]string{"ui"})
	if !g.Has("ui") || !g.Has("log") || g.Has("http") {
		t.Fatal("隐式授予或权限判定不对")
	}
}

// ★★ v2 删掉的权限必须**同时**满足:不再是已知权限(manifest 校验会拒),
// 且能给出一句人话原因。只删一半 —— 从 All 里删了却忘了进 Removed ——
// 老插件会撞上「未知权限: cfproxy」,看起来像 bug 而不是设计。
func TestRemoved权限要有人话原因(t *testing.T) {
	for _, r := range Removed {
		if IsKnownPermission(r[0]) {
			t.Fatalf("%s 已宣布删除,却还在 All 里 —— 会被继续放行", r[0])
		}
		if RemovedReason(r[0]) == "" {
			t.Fatalf("%s 被删了却没给原因", r[0])
		}
	}
	if RemovedReason("http") != "" {
		t.Fatal("在用的权限不该被当成已删除")
	}
}

func mustFail(t *testing.T, raw, wantSubstr string) {
	t.Helper()
	_, err := ParseManifest(raw)
	if err == nil {
		t.Fatalf("应当被拒却过了:%s", raw)
	}
	if wantSubstr != "" && !strings.Contains(err.Error(), wantSubstr) {
		t.Fatalf("报错里没有 %q:%v", wantSubstr, err)
	}
}

func TestManifest_基本校验(t *testing.T) {
	ok := `{"id":"com.a.b","name":"x","version":"1.0.0","apiVersion":2}`
	m, err := ParseManifest(ok)
	if err != nil {
		t.Fatal(err)
	}
	if m.Main != "main.js" || m.Category != "tools" || m.Author != "未知作者" {
		t.Fatalf("缺省值不对:%#v", m)
	}

	mustFail(t, `{"id":"noDot","name":"x","version":"1.0.0","apiVersion":2}`, "反向域名")
	mustFail(t, `{"id":"com.a.b","name":"x","version":"1.0","apiVersion":2}`, "语义化版本")
	mustFail(t, `{"id":"com.a.b","name":"x","version":"1.0.0"}`, "旧版本")
	mustFail(t, `{"id":"com.a.b","name":"x","version":"1.0.0","apiVersion":9}`, "更新的应用版本")
	// v1 遗留字段要给人话,不能让用户去查 JSON 语法
	mustFail(t, `{"id":"com.a.b","name":"x","version":"1.0.0","apiVersion":2,"runtime":"js"}`, "runtime")
	mustFail(t, `{"id":"com.a.b","name":"x","version":"1.0.0","apiVersion":2,"extends":{}}`, "extends")
	mustFail(t, `{"id":"com.a.b","name":"x","version":"1.0.0","apiVersion":2,
		"permissions":["cfproxy"]}`, "已移除")
}

// ★★ 没声明对应权限就不许贡献 —— 否则用户在授权弹窗里看不到、却被悄悄挂上了东西。
func TestManifest_贡献点必须先声明权限(t *testing.T) {
	mustFail(t, `{"id":"com.a.b","name":"x","version":"1.0.0","apiVersion":2,
		"permissions":["ui"],
		"contributes":{"panels":[{"id":"p","slot":"sidebar"}]}}`, "extensions")

	if _, err := ParseManifest(`{"id":"com.a.b","name":"x","version":"1.0.0","apiVersion":2,
		"permissions":["extensions"],
		"contributes":{"panels":[{"id":"p","slot":"sidebar"}]}}`); err != nil {
		t.Fatalf("声明了 extensions 就该过:%v", err)
	}
}

func TestManifest_贡献点字段校验(t *testing.T) {
	base := `{"id":"com.a.b","name":"x","version":"1.0.0","apiVersion":2,
		"permissions":["extensions","sandbox"],"contributes":{%s}}`
	mustFail(t, strings.Replace(base, "%s", `"panels":[{"id":"p","slot":"不存在"}]`, 1), "slot 非法")
	mustFail(t, strings.Replace(base, "%s", `"panels":[{"slot":"sidebar"}]`, 1), "非空 id")
	mustFail(t, strings.Replace(base, "%s", `"actions":[{"id":"a","context":"乱写"}]`, 1), "context 非法")
	// 逃生舱的 entry 会拼进 lpplugin:// 路径,穿越要在这一层就挡掉
	mustFail(t, strings.Replace(base, "%s", `"sandboxViews":[{"id":"v","entry":"../../etc/passwd"}]`, 1), "相对路径")
	mustFail(t, strings.Replace(base, "%s", `"sandboxViews":[{"id":"v","entry":"/abs.html"}]`, 1), "相对路径")
	// 认不出来的贡献点名要报错 —— 静默忽略的表现是「功能没出现」
	mustFail(t, strings.Replace(base, "%s", `"sidebarItems":[{"id":"s"}]`, 1), "未知贡献点类型")
}

// ★ `$` 开头的一律当令牌:拼错的令牌不能被当成一个普通(且永远匹配不上的)域名
// 静默放过 —— 那样插件作者会对着一句「域名不在白名单内」查半天域名。
func TestManifest_未知令牌要报错(t *testing.T) {
	mustFail(t, `{"id":"com.a.b","name":"x","version":"1.0.0","apiVersion":2,
		"httpAllowedHosts":["$sourceServr"]}`, "未知令牌")

	m, err := ParseManifest(`{"id":"com.a.b","name":"x","version":"1.0.0","apiVersion":2,
		"httpAllowedHosts":["$sourceServer","api.example.com"]}`)
	if err != nil {
		t.Fatal(err)
	}
	if !m.WantsSourceServerHost() {
		t.Fatal("声明了 $sourceServer 却没认出来 —— 添加服务器页就不会提示用户")
	}
}
