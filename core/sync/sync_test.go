package sync

import (
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"

	"linplayer/core/paths"
)

// ★★ 闰年与世纪非闰年是这个算法最容易写错的地方,而写错的表现是
// 「日历里某几天的条目跑到隔壁去了」—— 不报错,只是日期偏一天。
func TestCivilFromDays_已知日期(t *testing.T) {
	cases := []struct {
		days int64
		y    int64
		m, d int
	}{
		{0, 1970, 1, 1},  // unix 纪元
		{59, 1970, 3, 1}, // 平年 2 月只有 28 天
		{365, 1971, 1, 1},
		{730, 1972, 1, 1},
		{789, 1972, 2, 29},   // 1972 是闰年
		{11016, 2000, 2, 29}, // 2000 闰(整 400)
		{-1, 1969, 12, 31},   // 纪元前一天
		{18262, 2020, 1, 1},
	}
	for _, c := range cases {
		y, m, d := CivilFromDays(c.days)
		if y != c.y || m != c.m || d != c.d {
			t.Fatalf("CivilFromDays(%d) = %d-%02d-%02d,想要 %d-%02d-%02d", c.days, y, m, d, c.y, c.m, c.d)
		}
	}
}

// ★ 往返一致:civil → days → civil。
func TestDaysFromCivil_往返(t *testing.T) {
	for _, c := range [][3]int64{{1970, 1, 1}, {2020, 1, 1}, {2024, 2, 29}, {1999, 12, 31}, {1900, 3, 1}} {
		days := DaysFromCivil(c[0], c[1], c[2])
		y, m, d := CivilFromDays(days)
		if y != c[0] || int64(m) != c[1] || int64(d) != c[2] {
			t.Fatalf("往返变形:%v → %d → %d-%02d-%02d", c, days, y, m, d)
		}
	}
}

// ★ 三种日期串形状都要吃得下:Trakt 给带时刻带毫秒的,Bangumi 给纯日期,还有带空格的。
func TestParseDateToDays_三种形状(t *testing.T) {
	a, ok := ParseDateToDays("2020-01-01")
	if !ok {
		t.Fatal("纯日期解不出来")
	}
	b, ok := ParseDateToDays("2020-01-11T00:00:00.000Z")
	if !ok {
		t.Fatal("带时刻带毫秒的解不出来 —— Trakt 给的就是这种")
	}
	c, ok := ParseDateToDays("2020-01-11 12:30")
	if !ok {
		t.Fatal("带空格的解不出来")
	}
	if b != c {
		t.Fatalf("同一天解出两个值:%d != %d", b, c)
	}
	if b-a != 10 {
		t.Fatalf("日期差算错:%d,应当 10", b-a)
	}
	for _, bad := range []string{"garbage", "", "2020", "2020-13-01", "2020-01-99", "x-y-z"} {
		if _, ok := ParseDateToDays(bad); ok {
			t.Fatalf("%q 不该解得出来", bad)
		}
	}
}

// ★ 过期判断带 60 秒余量:正好卡在过期那一刻发出去的请求,到服务端就已经过期了。
func TestAccount_过期带余量(t *testing.T) {
	exp := int64(100_000)
	a := &Account{Service: "trakt", AccessToken: "x", ExpiresAt: &exp}
	if a.IsExpired(0) {
		t.Fatal("还早得很却说过期了")
	}
	if !a.IsExpired(100_000) {
		t.Fatal("到点前 60 秒余量内应当视为过期")
	}
	if !a.IsExpired(40_001) {
		t.Fatal("余量边界算错了")
	}
	never := &Account{Service: "trakt", AccessToken: "x"}
	if never.IsExpired(1 << 62) {
		t.Fatal("没有过期时刻的账号不该被判过期")
	}
}

// ★ 混淆解出来的应当是**可打印 ASCII**(OAuth 的公开标识符),且非空。
//
// 解错了的表现是登录时服务端回「client_id 无效」—— 而 keystream 一改就静默解错。
func TestReveal_解出可打印标识符(t *testing.T) {
	for name, got := range map[string]string{"trakt": TraktClientID(), "bangumi": BangumiAppID()} {
		if got == "" {
			t.Fatalf("%s 的 client_id 解出来是空的", name)
		}
		for _, r := range got {
			if r < 0x21 || r > 0x7e {
				t.Fatalf("%s 的 client_id 解出了非可打印字符 %q(完整值 %q)—— keystream 对不上", name, r, got)
			}
		}
	}
}

// ★★ 没配同步代理时要**明说**,不是一句语焉不详的失败。
//
// 这条和排行榜「没凭据」是同一套:自己构建的人得知道去补哪个环境变量。
func TestPostProxy_没配代理要说清楚(t *testing.T) {
	if UseProxy() {
		t.Skip("这个构建配了代理,跳过")
	}
	_, _, err := postProxy(t.Context(), "/trakt/device", nil)
	if err == nil {
		t.Fatal("没配代理却成功了")
	}
	if !strings.Contains(err.Error(), "LP_SYNC_PROXY_BASE") {
		t.Fatalf("没指明缺哪个环境变量: %v", err)
	}
}

// ★ 图片改写:协议相对的要补 https,官方域要换成反代。
//
// 不补 https 的表现是「一张封面都没有」—— `//lain.bgm.tv/…` 交给图片加载器
// 会被当成相对路径。
func TestMirrorImage(t *testing.T) {
	got := mirrorImage("//lain.bgm.tv/pic/cover/l/a.jpg")
	if got == nil || !strings.HasPrefix(*got, "https://") {
		t.Fatalf("协议相对的地址没补 https: %v", got)
	}
	if strings.Contains(*got, "lain.bgm.tv") {
		t.Fatalf("没改写到反代: %s", *got)
	}
	if mirrorImage("  ") != nil {
		t.Fatal("空地址应当返回 nil,不是一个空串 URL")
	}
}

// ★ broadcast 只认 `R/<起始>/<周期>` 这一种形状,别的一律不猜。
func TestBroadcastStart(t *testing.T) {
	if got := broadcastStart("R/2026-07-06T14:30:00.000Z/P7D"); got != "2026-07-06T14:30:00.000Z" {
		t.Fatalf("取起始时刻不对: %q", got)
	}
	for _, bad := range []string{"", "P7D", "2026-07-06", "X/2026-07-06/P7D"} {
		if got := broadcastStart(bad); got != "" {
			t.Fatalf("%q 不该解出 %q —— 编一个时间出来比没有更糟", bad, got)
		}
	}
}

// ---- 放送表解析:拿真形状的响应验,不是拿真上游 ----

// ★ 夹具里**必须带 air_date** —— 真实响应里它就在。
//
//	第一版没带,于是注入「把 air_date 传出去」时代码取不到值、什么都没设,
//	那条 ★★ 断言全程是空的。夹具缺字段让断言变空,是假绿的一类。
const calendarFixture = `[
 {"weekday":{"id":1},"items":[
   {"id":100,"name":"Original Name","name_cn":"中文名","rating":{"score":8.2},
    "air_date":"2026-07-06","air_weekday":1,
    "images":{"large":"//lain.bgm.tv/pic/cover/l/a.jpg","common":"//lain.bgm.tv/pic/cover/c/a.jpg"}},
   {"id":101,"name":"只有原名","rating":{"score":0},"air_date":"2026-07-06",
    "images":{"common":"//lain.bgm.tv/pic/cover/c/b.jpg"}}
 ]},
 {"weekday":{"id":7},"items":[{"id":102,"name_cn":"周日那部","air_date":"2026-07-12"}]}
]`

func calendarServer(t *testing.T, body string) func() {
	t.Helper()
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "application/json")
		_, _ = w.Write([]byte(body))
	}))
	restore := setBangumiBaseForTest(srv.URL)
	return func() { restore(); srv.Close() }
}

// ★★ **0 分 = 没人评过**,不是「这片 0 分」。
//
// 不滤的话前端会在新番卡片上画一个大大的 0 分 —— 那是诽谤。
func TestBangumiCalendar_零分要滤掉(t *testing.T) {
	paths.SetRoot(t.TempDir())
	defer calendarServer(t, calendarFixture)()

	got := BangumiCalendar(t.Context(), nil, false)
	if len(got) != 3 {
		t.Fatalf("解出 %d 条,想要 3", len(got))
	}
	for _, e := range got {
		if e.Rating != nil && *e.Rating == 0 {
			t.Fatalf("%q 的评分是 0 却给了出去 —— 那不是「0 分」,是「没人评过」", e.Title)
		}
	}
	if got[0].Rating == nil || *got[0].Rating != 8.2 {
		t.Fatalf("真有评分的那条丢了: %v", got[0].Rating)
	}
	if got[1].Rating != nil {
		t.Fatalf("0 分那条应当是 nil,实得 %v", *got[1].Rating)
	}
}

// ★ 中文名优先,没有才用原名。
func TestBangumiCalendar_中文名优先(t *testing.T) {
	paths.SetRoot(t.TempDir())
	defer calendarServer(t, calendarFixture)()

	got := BangumiCalendar(t.Context(), nil, false)
	if got[0].Title != "中文名" {
		t.Fatalf("有 name_cn 却用了 %q", got[0].Title)
	}
	if got[1].Title != "只有原名" {
		t.Fatalf("没有 name_cn 时应当回落原名,实得 %q", got[1].Title)
	}
}

// ★★ AirDate 必须留空。
//
// Bangumi 的 air_date 是**首播日**,不是本周这一集的日期。传上去前端会拿它
// 和本周日期比对,比不上就整条丢掉 —— 放送表直接空。用 weekday 归组才对。
func TestBangumiCalendar_不给AirDate只给Weekday(t *testing.T) {
	paths.SetRoot(t.TempDir())
	defer calendarServer(t, calendarFixture)()

	got := BangumiCalendar(t.Context(), nil, false)
	for _, e := range got {
		if e.AirDate != nil {
			t.Fatalf("%q 给了 air_date(%q)—— 那是首播日不是本周日期,前端会把整条丢掉", e.Title, *e.AirDate)
		}
		if e.Weekday == nil {
			t.Fatalf("%q 没有 weekday,前端没法归组", e.Title)
		}
	}
	if *got[2].Weekday != 7 {
		t.Fatalf("周日那条的 weekday 是 %d", *got[2].Weekday)
	}
}

// ★ 海报优先 large:common 是小缩略图,放大到卡片上发虚。
func TestBangumiCalendar_海报优先large(t *testing.T) {
	paths.SetRoot(t.TempDir())
	defer calendarServer(t, calendarFixture)()

	got := BangumiCalendar(t.Context(), nil, false)
	if got[0].ImageURL == nil || !strings.Contains(*got[0].ImageURL, "/cover/l/") {
		t.Fatalf("没优先取 large: %v", got[0].ImageURL)
	}
	// 只有 common 时也要能出图,不能因为没有 large 就一张不给
	if got[1].ImageURL == nil {
		t.Fatal("只有 common 的那条一张图都没给")
	}
}

// ★ 上游挂了要返回**空切片不是 nil** —— nil 序列化成 null,前端 .map() 直接抛。
func TestBangumiCalendar_上游挂了也给空数组(t *testing.T) {
	paths.SetRoot(t.TempDir())
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.WriteHeader(500)
	}))
	defer srv.Close()
	defer setBangumiBaseForTest(srv.URL)()

	got := BangumiCalendar(t.Context(), nil, false)
	if got == nil {
		t.Fatal("返回了 nil —— 序列化成 null,前端 .map() 直接抛,透明窗口下就是一片黑")
	}
	if len(got) != 0 {
		t.Fatalf("上游 500 却解出了 %d 条", len(got))
	}
}
