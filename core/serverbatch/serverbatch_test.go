package serverbatch

// 整套用例照搬黄金实现 `crates/core/src/server_batch.rs` 的回归集。
//
// ⚠️ 夹具里的域名 / 用户名 / 密码**全部是编造的占位符**。仓库红线:
// 真实值不许进版本控制,包括「只是个测试夹具」。改的时候保持**结构**不变即可。

import (
	"reflect"
	"testing"
)

func pairs(v []Line) [][2]string {
	out := [][2]string{}
	for _, l := range v {
		out = append(out, [2]string{l.Name, l.URL})
	}
	return out
}

func deref(p *string) string {
	if p == nil {
		return "<nil>"
	}
	return *p
}

// ★★ 这段真实形状的机场分享文本**是这个模块存在的理由**,必须一字不差解对。
func TestParseShareText_真实分享文本(t *testing.T) {
	text := "▎创建用户成功🎉\n" +
		"· 用户名称 | 示例用户\n" +
		"· 用户密码 | Ab3xKp9Q\n" +
		"· 安全密码 | 1234（仅发送一次）\n" +
		"· 到期时间 | 2026-06-30 23:34:28\n" +
		"主线路（可尝试直连）\n" +
		"https://line1.example.com:443\n" +
		"海外备用（国际优化 CDN）\n" +
		"https://cdn.example.net:443\n" +
		"弹幕 API\n" +
		"https://danmu.example.org/api-danmu\n"
	bs := ParseShareText(text)
	if len(bs) != 1 {
		t.Fatalf("整段是一个账号块,解出了 %d 个", len(bs))
	}
	b := bs[0]
	if deref(b.Username) != "示例用户" {
		t.Fatalf("用户名 = %q", deref(b.Username))
	}
	// ★★ 「安全密码」排在「用户密码」后面。它被当成密码的话,登录用的会是一串
	//   一次性验证码 —— 永远登不进去,而分享文本看起来毫无问题。
	if deref(b.Password) != "Ab3xKp9Q" {
		t.Fatalf("密码 = %q —— 安全密码/到期时间不能被当成登录凭据", deref(b.Password))
	}
	want := [][2]string{
		{"主线路", "https://line1.example.com:443"},
		{"海外备用", "https://cdn.example.net:443"},
	}
	if !reflect.DeepEqual(pairs(b.Lines), want) {
		t.Fatalf("线路 = %v,想要 %v(括号备注要剥掉,顺序=登录尝试顺序)", pairs(b.Lines), want)
	}
	if got := pairs(b.DanmakuLines); !reflect.DeepEqual(got, [][2]string{{"弹幕 API", "https://danmu.example.org/api-danmu"}}) {
		t.Fatalf("弹幕线路 = %v —— 带 danmu 的地址要分到弹幕那一栏", got)
	}
}

// ★★ 「安全密码」「到期时间」这类键**不是登录凭据**,必须显式忽略。
//
// ★ 夹具要让忽略名单**真的承重**:上面那条真实文本里「安全密码」排在「用户密码」
// 后面,而密码只认第一个 —— 忽略名单去掉也照样绿(第一版就是这么假绿的)。
// 这里把「安全密码」放到**前面**,再让「到期时间」紧挨着一条 URL:
// 前者不忽略就会顶掉真密码,后者不忽略就会变成那条线路的名字。
func TestParseShareText_忽略名单要承重(t *testing.T) {
	text := "安全密码 | 9999\n用户密码 | RealPw1\n到期时间 | 2026-06-30\nhttps://a.com\n"
	bs := ParseShareText(text)
	if len(bs) != 1 {
		t.Fatalf("解出了 %d 个块", len(bs))
	}
	if deref(bs[0].Password) != "RealPw1" {
		t.Fatalf("密码 = %q —— 安全密码顶掉了真密码,表现是永远登不进去", deref(bs[0].Password))
	}
	if !reflect.DeepEqual(pairs(bs[0].Lines), [][2]string{{"a.com", "https://a.com"}}) {
		t.Fatalf("线路 = %v —— 「到期时间」被当成了线路名", pairs(bs[0].Lines))
	}
}

// ★★ 一段文本里多个账号必须拆开。糊成一坨的话第二个账号的线路会挂到第一个账号上,
// 用户加完发现少了一台服务器,而多出来的那几条线路怎么点都连不上。
func TestParseShareText_多账号拆块(t *testing.T) {
	text := "用户名 | u1\n密码 | p1\n线路 | https://a.com:8096\n" +
		"用户名 | u2\n密码 | p2\n线路 | https://b.com\n"
	bs := ParseShareText(text)
	if len(bs) != 2 {
		t.Fatalf("第二个用户名必须开新块,解出了 %d 个", len(bs))
	}
	if deref(bs[0].Username) != "u1" || deref(bs[0].Password) != "p1" {
		t.Fatalf("第一块 = %q/%q", deref(bs[0].Username), deref(bs[0].Password))
	}
	if !reflect.DeepEqual(pairs(bs[0].Lines), [][2]string{{"线路", "https://a.com:8096"}}) {
		t.Fatalf("第一块线路 = %v", pairs(bs[0].Lines))
	}
	if deref(bs[1].Username) != "u2" || deref(bs[1].Password) != "p2" {
		t.Fatalf("第二块 = %q/%q", deref(bs[1].Username), deref(bs[1].Password))
	}
}

func TestParseShareText_块头也能拆(t *testing.T) {
	text := "创建用户成功\n主线路\nhttps://a.com\n创建用户成功\n主线路\nhttps://b.com\n"
	bs := ParseShareText(text)
	if len(bs) != 2 {
		t.Fatalf("解出了 %d 个块", len(bs))
	}
	if !reflect.DeepEqual(pairs(bs[0].Lines), [][2]string{{"主线路", "https://a.com"}}) ||
		!reflect.DeepEqual(pairs(bs[1].Lines), [][2]string{{"主线路", "https://b.com"}}) {
		t.Fatalf("%v / %v", pairs(bs[0].Lines), pairs(bs[1].Lines))
	}
}

// ★ 没用户名**不能整块丢掉**:很多分享只给线路,用户名要用户自己在界面上补。
func TestParseShareText_没用户名也要留下线路(t *testing.T) {
	text := "主线路\nhttps://a.com:443\n弹幕\nhttps://d.com/danmu\n"
	bs := ParseShareText(text)
	if len(bs) != 1 {
		t.Fatalf("没用户名不能整块丢掉,解出了 %d 个", len(bs))
	}
	if bs[0].Username != nil || bs[0].Password != nil {
		t.Fatalf("凭据应当是空的:%v/%v", bs[0].Username, bs[0].Password)
	}
	if !reflect.DeepEqual(pairs(bs[0].Lines), [][2]string{{"主线路", "https://a.com:443"}}) {
		t.Fatalf("线路 = %v", pairs(bs[0].Lines))
	}
	if !reflect.DeepEqual(pairs(bs[0].DanmakuLines), [][2]string{{"弹幕", "https://d.com/danmu"}}) {
		t.Fatalf("弹幕 = %v", pairs(bs[0].DanmakuLines))
	}
}

// ★ 全角冒号:中文输入法下的默认分隔符。不认的话整段分享文本一条都解不出来。
func TestParseShareText_全角冒号(t *testing.T) {
	text := "用户名：alice\n密码：secret123\n主线路：https://a.com\n"
	bs := ParseShareText(text)
	if len(bs) != 1 || deref(bs[0].Username) != "alice" || deref(bs[0].Password) != "secret123" {
		t.Fatalf("解出 %d 块,%q/%q", len(bs), deref(bs[0].Username), deref(bs[0].Password))
	}
	if !reflect.DeepEqual(pairs(bs[0].Lines), [][2]string{{"主线路", "https://a.com"}}) {
		t.Fatalf("线路 = %v", pairs(bs[0].Lines))
	}
}

// ★ 项目符号要剥干净,否则用户名会变成「· 用户名」那一串。
func TestParseShareText_剥项目符号(t *testing.T) {
	text := "· 用户名|bob\n▍密码|pw\n► 主线路\nhttps://a.com\n"
	bs := ParseShareText(text)
	if len(bs) != 1 || deref(bs[0].Username) != "bob" || deref(bs[0].Password) != "pw" {
		t.Fatalf("%d 块,%q/%q", len(bs), deref(bs[0].Username), deref(bs[0].Password))
	}
	if !reflect.DeepEqual(pairs(bs[0].Lines), [][2]string{{"主线路", "https://a.com"}}) {
		t.Fatalf("▍/► 没剥干净:%v", pairs(bs[0].Lines))
	}
}

// ★ 同一个地址出现两次只留一条;没有标签时用 host 顶名字。
func TestParseShareText_去重与host兜底(t *testing.T) {
	bs := ParseShareText("https://a.com\nhttps://a.com\n")
	if !reflect.DeepEqual(pairs(bs[0].Lines), [][2]string{{"a.com", "https://a.com"}}) {
		t.Fatalf("%v", pairs(bs[0].Lines))
	}
}

// ★★ 「标签: URL」这一行的 URL 必须在标点处收口。
//
// 用 `\S+` 整段吞的话,"https://a.com,备注" 会把 ",备注" 也吞进地址 ——
// 而**换成分行写法就没这个问题**,同一段文本两种写法解出两个不同的 URL,
// 那是最难查的一类不一致。
func TestParseShareText_同行URL在标点处收口(t *testing.T) {
	bs := ParseShareText("主线路: https://a.com,这是备注\n")
	if !reflect.DeepEqual(pairs(bs[0].Lines), [][2]string{{"主线路", "https://a.com"}}) {
		t.Fatalf("%v —— 逗号后面的备注被吞进 URL 了", pairs(bs[0].Lines))
	}
}

func TestParseShareText_没线路的块要丢掉(t *testing.T) {
	if len(ParseShareText("")) != 0 {
		t.Fatal("空文本")
	}
	if got := ParseShareText("这里啥也没有\n随便几行字\n"); len(got) != 0 {
		t.Fatalf("没线路的块必须丢掉,却留下了 %v", got)
	}
}

// ★★ 明文 http **不能被偷偷改成 https**:有的自建服就是只开了 80,
// 悄悄改协议的表现是「填对了地址却连不上」。
func TestNormalizeURL(t *testing.T) {
	cases := map[string]string{
		"a.com":         "https://a.com",
		"  a.com:8096 ": "https://a.com:8096",
		"http://a.com":  "http://a.com",
		"HTTPS://a.com": "HTTPS://a.com",
		"   ":           "",
	}
	for in, want := range cases {
		if got := NormalizeURL(in); got != want {
			t.Fatalf("NormalizeURL(%q) = %q,想要 %q", in, got, want)
		}
	}
}

// ★ 图标优先用登录用户的头像:很多 Emby 服把品牌 logo 设成了用户头像,
// 而用户头像是免鉴权的公开资源。
func TestBuildIconURL(t *testing.T) {
	if got := BuildIconURL("https://a.com/", "u1", "tag1"); got != "https://a.com/Users/u1/Images/Primary?tag=tag1" {
		t.Fatalf("%q", got)
	}
	for _, c := range [][3]string{{"https://a.com", "u1", ""}, {"https://a.com", "", "tag"}, {"https://a.com/", "", ""}} {
		if got := BuildIconURL(c[0], c[1], c[2]); got != "https://a.com/web/touchicon.png" {
			t.Fatalf("缺 user_id 或 tag 时应当退回 touchicon,实得 %q", got)
		}
	}
}

// ---------- 深链 ----------

// ★★ 重复的 `line=` 必须**全收**。只收第一个 = 悄悄丢线路,
// 而用户看到的是「加进来的服务器少了几条备用线」。
func TestParseDeepLink_结构化参数(t *testing.T) {
	d := ParseDeepLink("linplayer://add-server?name=MyServer&user=bob&pwd=p%40ss" +
		"&line=https%3A%2F%2Fa.com%3A8096&line=https%3A%2F%2Fb.com&danmaku=https%3A%2F%2Fd.com%2Fapi")
	if d == nil {
		t.Fatal("合法 add-server 链接必须解出来")
	}
	if deref(d.Name) != "MyServer" || deref(d.Block.Username) != "bob" || deref(d.Block.Password) != "p@ss" {
		t.Fatalf("name=%q user=%q pwd=%q", deref(d.Name), deref(d.Block.Username), deref(d.Block.Password))
	}
	want := [][2]string{{"a.com", "https://a.com:8096"}, {"b.com", "https://b.com"}}
	if !reflect.DeepEqual(pairs(d.Block.Lines), want) {
		t.Fatalf("线路 = %v,想要 %v", pairs(d.Block.Lines), want)
	}
	if !reflect.DeepEqual(pairs(d.Block.DanmakuLines), [][2]string{{"弹幕", "https://d.com/api"}}) {
		t.Fatalf("弹幕 = %v", pairs(d.Block.DanmakuLines))
	}
}

func TestParseDeepLink_text参数与凭据覆盖(t *testing.T) {
	d := ParseDeepLink("linplayer://add-server?text=%E4%B8%BB%E7%BA%BF%E8%B7%AF%0Ahttps%3A%2F%2Fa.com%3A443&user=bob&pwd=pw")
	if d == nil {
		t.Fatal("text= 整段文本必须能解")
	}
	if !reflect.DeepEqual(pairs(d.Block.Lines), [][2]string{{"主线路", "https://a.com:443"}}) {
		t.Fatalf("%v", pairs(d.Block.Lines))
	}
	if deref(d.Block.Username) != "bob" || deref(d.Block.Password) != "pw" {
		t.Fatalf("?user=/?pwd= 要覆盖文本里解出的凭据:%q/%q", deref(d.Block.Username), deref(d.Block.Password))
	}
	if d.Name != nil {
		t.Fatalf("没给 name 时应当是 nil,实得 %q", *d.Name)
	}
}

// ★★ 深链来自任何网页或聊天窗口 —— 认链必须严。
func TestParseDeepLink_垃圾链接一律不接(t *testing.T) {
	for _, u := range []string{
		"https://evil.example/add-server?line=https://a.com", // 别的 scheme
		"linplayer://sync-bangumi?code=x",                    // 别的 host
		"linplayer://add-server",                             // 没线路 = 没用
		"linplayer://add-server?line=%20",                    // 空白不算线路
		"not a url",
	} {
		if d := ParseDeepLink(u); d != nil {
			t.Fatalf("%q 不该被接受,却解出了 %+v", u, d)
		}
	}
	// ★★ `?user=` 显式给空串 → Username 是**空串而不是 nil**:
	//   「链接里写了但是空的」和「链接里根本没写」是两件事,
	//   前者调用方要据此拒绝登录,回落到文本里的用户名等于替用户做主。
	d := ParseDeepLink("linplayer://add-server?user=&line=https%3A%2F%2Fa.com")
	if d == nil || d.Block.Username == nil || *d.Block.Username != "" {
		t.Fatalf("显式空 user 应当是空串:%v", d)
	}
}

func TestParseBangumiCode(t *testing.T) {
	if got := ParseBangumiCode("linplayer://sync-bangumi?code=%20abc%20"); got != "abc" {
		t.Fatalf("%q", got)
	}
	for _, u := range []string{
		"linplayer://sync-bangumi?code=", // 空授权码不能拿去换令牌
		"linplayer://sync-bangumi",
		"linplayer://add-server?code=x",
	} {
		if got := ParseBangumiCode(u); got != "" {
			t.Fatalf("%q 不该解出授权码,实得 %q", u, got)
		}
	}
}
