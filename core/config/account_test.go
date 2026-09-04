package config

import (
	"encoding/json"
	"os"
	"path/filepath"
	"strings"
	"testing"

	"linplayer/core/net/cf"
)

func acc(server string) Account { return Account{Server: server, Token: "t", UserID: "u"} }

// 重登**保留用户侧编辑**。
//
// ★ 用户改过的服务器名 / 备注 / 图标 / 线路表 / TLS 开关,不该被一次登录冲掉。
// 冲掉的表现是「说不上哪里不对但就是不对」—— 重新登录一次,自己起的名字变回默认。
func TestUpsert保留用户侧编辑(t *testing.T) {
	remark, icon := "我的备注", "https://example.invalid/i.png"
	c := defaults()
	old := acc("https://s")
	old.Name = "客厅那台"
	old.Remark = &remark
	old.IconURL = &icon
	old.Lines = []ServerLine{{ID: "a", URL: "https://s"}, {ID: "b", URL: "https://s2"}}
	old.ActiveLine = 1
	old.AllowInsecureTLS = true
	c.Upsert(old)

	// 重新登录:只带回 token/user,别的都是空的
	fresh := Account{Server: "https://s", Token: "新token", UserID: "u", UserName: "n"}
	c.Upsert(fresh)

	got := c.Find("https://s")
	if got.Token != "新token" {
		t.Fatalf("token 该刷新,实得 %q", got.Token)
	}
	if got.Name != "客厅那台" {
		t.Fatalf("用户起的名字被冲掉了:%q", got.Name)
	}
	if got.Remark == nil || *got.Remark != remark {
		t.Fatal("备注被冲掉了")
	}
	if got.IconURL == nil || *got.IconURL != icon {
		t.Fatal("图标被冲掉了")
	}
	if len(got.Lines) != 2 || got.ActiveLine != 1 {
		t.Fatalf("线路表/生效线路被冲掉了:%d 条 active=%d", len(got.Lines), got.ActiveLine)
	}
	if !got.AllowInsecureTLS {
		t.Fatal("自签名开关被冲掉了 —— 用户下次连不上,而且看不出为什么")
	}
}

// 排序之后活跃账号要**跟着走**,不是指向别人。
func TestReorder活跃账号跟着走(t *testing.T) {
	c := defaults()
	c.Upsert(acc("https://a"))
	c.Upsert(acc("https://b"))
	c.Upsert(acc("https://c")) // 最后 upsert 的是活跃的
	if c.ActiveAccount().Server != "https://c" {
		t.Fatal("前提不成立")
	}
	if err := c.Reorder(2, 0); err != nil {
		t.Fatal(err)
	}
	if c.AccountList[0].Server != "https://c" {
		t.Fatalf("顺序不对: %v", serversOf(c))
	}
	if c.ActiveAccount().Server != "https://c" {
		t.Fatalf("活跃账号该跟着走,实得 %s", c.ActiveAccount().Server)
	}
	if err := c.Reorder(0, 9); err == nil {
		t.Fatal("越界下标必须报错,不能默默改错顺序")
	}
}

// 删掉**别人**的时候,活跃账号靠 server 重新定位 —— 别让下标漂移串台。
func TestRemove不串台(t *testing.T) {
	c := defaults()
	c.Upsert(acc("https://a"))
	c.Upsert(acc("https://b"))
	c.Upsert(acc("https://c"))
	i := 2
	c.Active = &i // 活跃 = c

	if !c.Remove("https://a") {
		t.Fatal("该删得掉")
	}
	if c.ActiveAccount().Server != "https://c" {
		t.Fatalf("删别人不该换活跃账号,实得 %s —— 下标漂移会串台", c.ActiveAccount().Server)
	}
	// 删活跃的:回落第一个
	c.Remove("https://c")
	if c.ActiveAccount() == nil || c.ActiveAccount().Server != "https://b" {
		t.Fatalf("删掉活跃账号应回落第一个,实得 %v", c.ActiveAccount())
	}
	// 删光:活跃清空,不是留一个越界下标
	c.Remove("https://b")
	if c.ActiveAccount() != nil {
		t.Fatal("账号删光后活跃必须是空 —— 留个越界下标会在每个读活跃账号的地方炸")
	}
}

// 同步线路:只增不删,且**生效线路跟着 url 走不跟着下标走**。
func TestMergeLines(t *testing.T) {
	a := acc("https://origin")
	// 用户手填的一条内网线,服主表里没有
	a.Lines = []ServerLine{
		{ID: "origin", Name: "主线", URL: "https://origin"},
		{ID: "lan", Name: "内网", URL: "http://10.0.0.2:8096"},
	}
	a.ActiveLine = 1 // 正在用内网那条

	added := MergeLines(&a, []RemoteLine{
		{Name: "CDN", URL: "https://cdn.example.invalid/"}, // 尾斜杠
		{Name: "", URL: "https://origin"},                  // 已有,跳过
		{Name: "空的", URL: "   "},                           // 空,跳过
	})
	if added != 1 {
		t.Fatalf("只该新增 1 条,实得 %d", added)
	}
	if len(a.Lines) != 3 {
		t.Fatalf("只增不删:该是 3 条,实得 %d", len(a.Lines))
	}
	if a.DirectLineURL() != "http://10.0.0.2:8096" {
		t.Fatalf("生效线路被同步换掉了:%s —— 用户点个同步,线路被悄悄改了", a.DirectLineURL())
	}

	// 归一化去重:再同步一次不带尾斜杠的同一条,不该重复加
	if n := MergeLines(&a, []RemoteLine{{Name: "CDN", URL: "https://cdn.example.invalid"}}); n != 0 {
		t.Fatalf("尾斜杠不同的同一条不该重复加,实得新增 %d 条 —— 每点一次同步表就长一截", n)
	}
}

// 线路表原本为空时,必须先把 server 落成第一条,再并入服主的线路。
func TestMergeLines空表先落主线(t *testing.T) {
	a := acc("https://origin")
	MergeLines(&a, []RemoteLine{{Name: "CDN", URL: "https://cdn.example.invalid"}})
	if len(a.Lines) != 2 || a.Lines[0].URL != "https://origin" {
		t.Fatalf("空表要先把 server 落成第一条,实得 %+v", a.Lines)
	}
	if a.DirectLineURL() != "https://origin" {
		t.Fatalf("同步后生效线路应仍是原来那个地址,实得 %s", a.DirectLineURL())
	}
}

// 越界下标钳回合法区间,不 panic。
func TestDirectLineURL越界(t *testing.T) {
	a := acc("https://s")
	a.Lines = []ServerLine{{URL: "https://l1"}}
	a.ActiveLine = 7
	if got := a.DirectLineURL(); got != "https://l1" {
		t.Fatalf("越界应钳回,实得 %s", got)
	}
	a.Lines = nil
	if got := a.DirectLineURL(); got != "https://s" {
		t.Fatalf("空表应回落 server,实得 %s", got)
	}
}

// source_kind **线上是小写**,且缺省就是 emby。
//
// ★ 前端曾整套写成首字母大写:每处比较恒 false、登录送错值,**两边都不报错**。
func TestSourceKind线上小写(t *testing.T) {
	var a Account
	if err := json.Unmarshal([]byte(`{"server":"https://s"}`), &a); err != nil {
		t.Fatal(err)
	}
	if a.SourceKind() != "emby" || a.IsFileBrowse() {
		t.Fatalf("没有 source_kind 键时应是 emby,实得 %q", a.SourceKind())
	}
	if err := json.Unmarshal([]byte(`{"server":"https://s","source_kind":"local"}`), &a); err != nil {
		t.Fatal(err)
	}
	if a.SourceKind() != "local" || !a.IsFileBrowse() {
		t.Fatalf("local 应判成浏览型源,实得 %q", a.SourceKind())
	}
}

// 账号里**还没移植的键**必须原样留住。
//
// ★ 丢了的表现是「升级之后我配的网盘源没了」,而且不报错。
func TestAccount未接的键不丢(t *testing.T) {
	dir := withTempRoot(t)
	raw := `{
  "device_id": "PLACEHOLDER-DEVICE-ID",
  "active": 0,
  "accounts": [
    {
      "server": "https://s",
      "token": "PLACEHOLDER-TOKEN",
      "user_id": "PLACEHOLDER-USER",
      "user_name": "someone",
      "source_kind": "local",
      "source": {"cookie": "PLACEHOLDER-COOKIE", "root": "/"}
    }
  ]
}`
	if err := os.WriteFile(filepath.Join(dir, "config.json"), []byte(raw), 0o644); err != nil {
		t.Fatal(err)
	}
	c, err := Load()
	if err != nil {
		t.Fatal(err)
	}
	if len(c.AccountList) != 1 || c.AccountList[0].UserName != "someone" {
		t.Fatalf("强类型字段没读对: %+v", c.AccountList)
	}
	// 动一下别的字段再存
	c.Theme = "light"
	if err := c.Save(); err != nil {
		t.Fatal(err)
	}
	out, _ := os.ReadFile(filepath.Join(dir, "config.json"))
	for _, k := range []string{"source_kind", "PLACEHOLDER-COOKIE", `"source"`} {
		if !strings.Contains(string(out), k) {
			t.Fatalf("保存后 %s 没了 —— 用户会看到「升级之后我配的网盘源没了」\n%s", k, out)
		}
	}
}

// 一次 Emby 重登不该把同一条账号里网盘源那部分的凭据冲掉。
func TestUpsert不冲掉未接的键(t *testing.T) {
	c := defaults()
	var old Account
	if err := json.Unmarshal([]byte(`{"server":"https://s","source_kind":"local","source":{"cookie":"PLACEHOLDER"}}`), &old); err != nil {
		t.Fatal(err)
	}
	c.Upsert(old)
	c.Upsert(Account{Server: "https://s", Token: "新token", UserID: "u"})

	b, err := json.Marshal(c.Find("https://s"))
	if err != nil {
		t.Fatal(err)
	}
	if !strings.Contains(string(b), "PLACEHOLDER") {
		t.Fatalf("重登把网盘凭据冲掉了:%s", b)
	}
}

// 允许自签名的账号,**每条线路的 host 都要进白名单**。
func TestInsecureHosts含每条线路(t *testing.T) {
	c := defaults()
	a := acc("https://s")
	a.AllowInsecureTLS = true
	a.Lines = []ServerLine{{URL: "https://s"}, {URL: "https://s2"}}
	c.Upsert(a)
	c.Upsert(acc("https://plain")) // 没勾的不进

	hosts := c.InsecureHosts()
	want := map[string]bool{"https://s": true, "https://s2": true}
	for _, h := range hosts {
		if !want[h] {
			t.Fatalf("没勾自签名的也进了白名单: %s", h)
		}
	}
	if len(hosts) != 3 { // server + 两条线路(server 与 lines[0] 同址,按 Rust 版原样都放)
		t.Fatalf("每条线路都要进白名单,实得 %v", hosts)
	}
}

func serversOf(c *AppConfig) []string {
	var out []string
	for _, a := range c.AccountList {
		out = append(out, a.Server)
	}
	return out
}

// ★★ ActiveLineURL 是线路优选的**唯一 choke point**,而且查表用的是
// **当前那条线**而不是账号主键。
//
// 按服务器查等于把这台服的每条线都劫持到同一个反代上,而反代的上游 host 是开启时
// 那条线定死的 —— 切到没走优选的线路后,请求会被送去「A 线的域名 + 钉死的 IP」,
// **连得上但拿不到数据,且不报错**。
func TestActiveLineURL只改写当前那条线(t *testing.T) {
	cf.Clear()
	defer cf.Clear()

	a := acc("https://主键")
	a.Lines = []ServerLine{
		{ID: "1", URL: "https://线路甲"},
		{ID: "2", URL: "https://线路乙"},
	}
	a.ActiveLine = 0

	// 只给「线路甲」开优选。
	// ★ 同时也给**账号主键**登记一条 —— 这是能把「按线路查」和「按服务器查」
	//   分开的唯一形状:只登记线路的话,按服务器查的实现在切到乙时同样查不到,
	//   用例就分不出对错(我第一版就是这么写的,注入按服务器查完全不红)。
	cf.Bind("https://线路甲", "http://127.0.0.1:5001")
	cf.Bind("https://主键", "http://127.0.0.1:5999")

	if got := a.ActiveLineURL(); got != "http://127.0.0.1:5001" {
		t.Fatalf("生效线路是甲,该走优选,实得 %q", got)
	}
	// 切到乙:必须走原线,**不能**被甲的反代劫持
	a.ActiveLine = 1
	if got := a.ActiveLineURL(); got != "https://线路乙" {
		t.Fatalf("切到没开优选的线路后该走原线,实得 %q —— "+
			"按服务器查的话每条线都被劫持到同一个反代上,"+
			"请求会送到「甲的域名 + 钉死的 IP」,连得上但拿不到数据且不报错", got)
	}
	// DirectLineURL 永远是原始地址(起反代自身的上游、编辑线路、展示给用户看都要它)
	a.ActiveLine = 0
	if got := a.DirectLineURL(); got != "https://线路甲" {
		t.Fatalf("DirectLineURL 不该被改写: %q", got)
	}
}
