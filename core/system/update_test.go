package system

// 更新检查的测试。这一块的判据全是**「会不会把用户送到更旧的包上」** ——
// 更新链路错了不报错,表现是「点更新装完还是老版本」或者更糟:装回旧代码。

import (
	"context"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"testing"
)

// ★★ 预览版渠道必须能比出 `-buildN` 的大小。
//
// 标准 semver 会把 `1.2.0-build88` 和 `1.2.0-build91` 的核心部分都规约成 1.2.0
// 判等 —— 于是**预览版渠道永远检测不到新版本**,而且一声不吭。
func TestCompareVersions_构建号要参与比较(t *testing.T) {
	if CompareVersions("v1.2.0-build91-pre", "v1.2.0-build88-pre") <= 0 {
		t.Fatal("build91 没比 build88 新 —— 预览版渠道会永远检测不到新版本")
	}
	if CompareVersions("v1.2.0-build88-pre", "v1.2.0-build91-pre") >= 0 {
		t.Fatal("反过来也要成立")
	}
}

// ★★ 同号同构建时**稳定版 > 预览版**:表达「预览版晋升为正式版」这层关系。
// 反过来的话,装了正式版的人会被劝回同号的 -pre。
func TestCompareVersions_稳定版压过同号预览版(t *testing.T) {
	if CompareVersions("v1.2.0-build91", "v1.2.0-build91-pre") <= 0 {
		t.Fatal("同号同构建下稳定版应当更新")
	}
	// 逐级比:大号压过一切
	if CompareVersions("v2.0.0-build1", "v1.9.9-build999") <= 0 {
		t.Fatal("major 必须先比")
	}
}

// ★ `-preview-x` 不是预览版标记。`\b` 就是为这个加的。
func TestCompareVersions_preview不算预览版(t *testing.T) {
	// 两边都不是 -pre,除了这个后缀完全一样 → 应当判等
	if CompareVersions("v1.0.0-preview-x", "v1.0.0-preview-x") != 0 {
		t.Fatal("同一个串应当判等")
	}
	// 「-preview-x」被误判成预览版的话,它会输给同号的裸版本
	if CompareVersions("v1.0.0-preview-x", "v1.0.0") != 0 {
		t.Fatal("-preview- 不是 -pre 标记,不该被当成预览版降一级")
	}
}

// ★★★ **不许照抄 GitHub 返回的列表顺序。**
//
// 2026-07-19 实测反证:v1.0.0-build557-pre(id 356263112,created 05:05)
// 排在 v0.1.0-build566-pre(id 356398423,created 17:35)**前面** ——
// id / created_at / published_at 三个键都是后者更大更晚。这个顺序不可依赖。
//
// 照抄的后果是「降级伪装成升级」:把代码更旧、版本号更大的包当最新版推给用户。
func TestPickNewestRelease_不照抄列表顺序(t *testing.T) {
	list := []release{
		{TagName: "v1.0.0-build557-pre"}, // 列表第一个,但版本号更小
		{TagName: "v1.0.0-build566-pre"}, // 真正最新的
		{TagName: "v1.0.0-build560-pre"},
	}
	got := PickNewestRelease(list)
	if got == nil || got.TagName != "v1.0.0-build566-pre" {
		t.Fatalf("挑成了 %v —— 照抄列表顺序会把更旧的包当成最新版推给用户", got)
	}
}

// ★ 草稿发布对用户不可见,挑中它等于给出一个 404 的下载地址。
func TestPickNewestRelease_跳过草稿(t *testing.T) {
	list := []release{
		{TagName: "v9.9.9-build999", Draft: true},
		{TagName: "v1.0.0-build2"},
	}
	got := PickNewestRelease(list)
	if got == nil || got.TagName != "v1.0.0-build2" {
		t.Fatalf("挑成了 %v —— 草稿发布用户下不到", got)
	}
	if PickNewestRelease([]release{{TagName: "x", Draft: true}}) != nil {
		t.Fatal("全是草稿时应当返回 nil(= 没有更新),不是随便挑一个")
	}
}

// ★★ 「没有更新」和「没查成」必须**分开**。
//
// 混成一个的话「查不动」会被说成「已是最新」—— 那是最坏的一种沉默失败:
// 用户永远等不到更新,还以为自己是最新的。
func TestCheckUpdate_查不动不能说成已是最新(t *testing.T) {
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.WriteHeader(403) // GitHub 未认证限流:60 次/小时/IP
		_, _ = w.Write([]byte(`{"message":"rate limit"}`))
	}))
	defer srv.Close()
	old := githubAPI
	githubAPI = srv.URL
	defer func() { githubAPI = old }()

	info, err := CheckUpdate(context.Background(), "stable", "v1.0.0")
	if err == nil {
		t.Fatalf("限流(403)被当成了「没有更新」(info=%v)—— 用户永远等不到更新", info)
	}
	// 状态码要带出去,否则用户以为是自己网的问题
	if want := "403"; !contains(err.Error(), want) {
		t.Fatalf("错误里没带状态码:%v", err)
	}
}

// ★ 已经是最新时返回 (nil, nil),**不是**错误。
func TestCheckUpdate_已是最新(t *testing.T) {
	srv := fakeReleases(t, release{TagName: "v1.0.0-build10"})
	defer srv.Close()
	old := githubAPI
	githubAPI = srv.URL
	defer func() { githubAPI = old }()

	info, err := CheckUpdate(context.Background(), "stable", "v1.0.0-build10")
	if err != nil {
		t.Fatalf("同版本不该报错:%v", err)
	}
	if info != nil {
		t.Fatalf("同版本不该有更新:%+v", info)
	}
}

// ★★ 资产要挑**本平台**那个。挑错了用户下到的是另一个系统的包,
// 而这一步没有任何提示 —— 下完双击才发现。
func TestCheckUpdate_挑本平台资产并清洗说明(t *testing.T) {
	rel := release{
		TagName: "v2.0.0-build5",
		Name:    "2.0.0",
		Body:    "## 更新内容\n- 修了[某个问题](https://example.invalid/x)\n- **重要**改动\n",
		HTMLURL: "https://example.invalid/release",
	}
	rel.Assets = []struct {
		Name string `json:"name"`
		URL  string `json:"browser_download_url"`
		Size int64  `json:"size"`
	}{
		{Name: "LinPlayer-linux-x64.tar.gz", URL: "u-linux", Size: 11},
		{Name: "LinPlayer-windows-x64.zip", URL: "u-win", Size: 22},
	}
	srv := fakeReleases(t, rel)
	defer srv.Close()
	old := githubAPI
	githubAPI = srv.URL
	defer func() { githubAPI = old }()

	info, err := CheckUpdate(context.Background(), "stable", "v1.0.0")
	if err != nil || info == nil {
		t.Fatalf("应当查到更新:info=%v err=%v", info, err)
	}
	want := "LinPlayer-windows-x64.zip" // 测试在 Windows 上跑
	if runtimeIsWindows() && info.AssetName != want {
		t.Fatalf("挑成了 %q,想要 %q —— 挑错平台的话用户下完双击才发现", info.AssetName, want)
	}
	// 说明要清洗:对话框不跑 Markdown 渲染器,原样贴过去满屏 ## 和 **
	for _, bad := range []string{"##", "**", "]("} {
		if contains(info.Notes, bad) {
			t.Fatalf("说明里还留着 %q:\n%s", bad, info.Notes)
		}
	}
	if !contains(info.Notes, "• ") {
		t.Fatalf("列表项没折成圆点:\n%s", info.Notes)
	}
	// 显示版本规约成 x.y.z,但比较用的 tag 要原样留着
	if info.Version != "2.0.0" || info.Tag != "v2.0.0-build5" {
		t.Fatalf("version=%q tag=%q —— tag 丢了就没法再比较", info.Version, info.Tag)
	}
}

func runtimeIsWindows() bool { return assetKeywords()[0] == "windows" }

func contains(s, sub string) bool {
	for i := 0; i+len(sub) <= len(s); i++ {
		if s[i:i+len(sub)] == sub {
			return true
		}
	}
	return false
}

// fakeReleases 假 GitHub:/releases/latest 给单个,/releases 给列表。
func fakeReleases(t *testing.T, rels ...release) *httptest.Server {
	t.Helper()
	return httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "application/json")
		if len(r.URL.Path) >= len("/releases/latest") &&
			r.URL.Path[len(r.URL.Path)-len("latest"):] == "latest" {
			_ = json.NewEncoder(w).Encode(rels[0])
			return
		}
		_ = json.NewEncoder(w).Encode(rels)
	}))
}
