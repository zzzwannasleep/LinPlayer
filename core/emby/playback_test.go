package emby

import (
	"context"
	"encoding/json"
	"io"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
)

// ★★ SubtitleProfiles **绝不能是空表**。
//
// 空表 = 告诉服务器「本客户端一种字幕都不支持」,服务器于是把 DeliveryMethod
// 判成 Encode/Drop 且**不发 DeliveryUrl** —— 外挂字幕从源头就被掐死。
// 这是「外挂字幕不加载」的第一层根因,而且**在响应里看不出来**:
// 服务器一切正常,只是没给取字幕地址。所以这条只能在**请求体**上断言。
func TestDeviceProfile必须声明外挂字幕支持(t *testing.T) {
	var gotBody []byte
	up := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		gotBody, _ = io.ReadAll(r.Body)
		_, _ = w.Write([]byte(`{"MediaSources":[{"Id":"ms","Container":"mkv"}]}`))
	}))
	defer up.Close()
	ResetRangePrefixCache()

	c := NewClient("test")
	s := &Session{Server: up.URL, Token: "t", UserID: "u", DeviceID: "d"}
	if _, err := c.ResolveStream(context.Background(), s, "it1", "", ""); err != nil {
		t.Fatal(err)
	}

	var body map[string]any
	if err := json.Unmarshal(gotBody, &body); err != nil {
		t.Fatalf("请求体不是 JSON: %s", gotBody)
	}
	prof, _ := body["DeviceProfile"].(map[string]any)
	subs, _ := prof["SubtitleProfiles"].([]any)
	if len(subs) == 0 {
		t.Fatal("SubtitleProfiles 是空表 —— 服务器会判成「这客户端不支持字幕」,从此不发 DeliveryUrl")
	}
	// 至少要有 srt / ass 两种走 External,否则最常见的两类外挂字幕仍然拿不到地址
	want := map[string]bool{"srt": false, "ass": false}
	for _, it := range subs {
		m, _ := it.(map[string]any)
		if m["Method"] == "External" {
			if _, ok := want[m["Format"].(string)]; ok {
				want[m["Format"].(string)] = true
			}
		}
	}
	for f, ok := range want {
		if !ok {
			t.Errorf("%s 没有声明成 External —— 这类外挂字幕拿不到取字幕地址", f)
		}
	}
}

// 指定了版本却找不到,**必须报错,不静默回落第一条**。
//
// ★ 静默回落 = 用户以为在看 4K,实际放的是 1080p,而且毫无提示。
func TestResolveStream指定版本找不到要报错(t *testing.T) {
	up := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		_, _ = w.Write([]byte(`{"MediaSources":[{"Id":"ms-1080","Container":"mkv"}]}`))
	}))
	defer up.Close()
	ResetRangePrefixCache()

	c := NewClient("test")
	s := &Session{Server: up.URL, Token: "t", UserID: "u", DeviceID: "d"}
	got, err := c.ResolveStream(context.Background(), s, "it1", "ms-4k-不存在", "")
	if err == nil {
		t.Fatalf("找不到指定版本必须报错,实得 %+v —— 静默回落会让用户以为在看 4K", got)
	}
	if !strings.Contains(err.Error(), "ms-4k-不存在") {
		t.Fatalf("错误里要说清是哪个版本没有: %v", err)
	}
}

// 手动指定的版本**永远优先于版本正则**。
func TestResolveStream手动选版本优先于正则(t *testing.T) {
	up := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		_, _ = w.Write([]byte(`{"MediaSources":[
			{"Id":"ms-1080","Container":"mkv","MediaStreams":[{"Type":"Video","Height":1080,"Index":0}]},
			{"Id":"ms-4k","Container":"mkv","MediaStreams":[{"Type":"Video","Height":2160,"Index":0}]}]}`))
	}))
	defer up.Close()
	ResetRangePrefixCache()

	c := NewClient("test")
	s := &Session{Server: up.URL, Token: "t", UserID: "u", DeviceID: "d"}
	// 正则指着 4K,但用户手动选了 1080 —— 必须听用户的
	got, err := c.ResolveStream(context.Background(), s, "it1", "ms-1080", "4K")
	if err != nil {
		t.Fatal(err)
	}
	if got.MediaSourceID != "ms-1080" {
		t.Fatalf("手动选的版本必须优先,实得 %s", got.MediaSourceID)
	}
}

// 服务器没给 PlaySessionId 时本地兜底,但**同一次播放内保持一致**。
//
// ★ 这个 id 要贯穿 start/progress/stopped 三次上报 —— 不贯穿的表现是
// 「看一半退出,续播进度不落地」。
func TestResolveStream缺PlaySessionId时本地兜底(t *testing.T) {
	up := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		_, _ = w.Write([]byte(`{"MediaSources":[{"Id":"ms","Container":"mkv"}]}`))
	}))
	defer up.Close()
	ResetRangePrefixCache()

	c := NewClient("test")
	s := &Session{Server: up.URL, Token: "t", UserID: "u", DeviceID: "dev-9"}
	a, err := c.ResolveStream(context.Background(), s, "it1", "", "")
	if err != nil {
		t.Fatal(err)
	}
	if a.PlaySessionID != "dev-9-it1" {
		t.Fatalf("兜底 id 形状不对: %q", a.PlaySessionID)
	}
	b, _ := c.ResolveStream(context.Background(), s, "it1", "", "")
	if b.PlaySessionID != a.PlaySessionID {
		t.Fatal("同一条片子两次取流的兜底 id 必须一样 —— 变了就等于上报三件套对不上")
	}
}

// Range 前缀选择的四种组合。
//
// ★ 「原地址能 Range 就别动」是最少惊讶原则:写死 /emby 会在 Jellyfin
// (没有这个前缀)和带 base path 的部署上**把好地址改坏**。
// ★ 「两个都不行也保持原样」—— 那时换前缀只是换一种坏法。
func TestChoosePrefix(t *testing.T) {
	for _, c := range []struct {
		plain, emby bool
		want        string
	}{
		{true, true, ""},       // 原地址就行,别动
		{true, false, ""},      // 原地址就行
		{false, true, "/emby"}, // 只有 /emby 行 —— 这就是那两台反代服务器
		{false, false, ""},     // 都不行,保持原样
	} {
		if got := choosePrefix(c.plain, c.emby); got != c.want {
			t.Errorf("choosePrefix(%v,%v) = %q,期望 %q", c.plain, c.emby, got, c.want)
		}
	}
}

// 已经带 /emby 的、以及绝对地址,没有第二个候选(别拼成 /emby/emby/…)。
func TestEmbyPrefixed(t *testing.T) {
	for _, p := range []string{"http://h/x.mkv", "https://h/x.mkv", "/emby/videos/x", "/emby"} {
		if _, ok := embyPrefixed(p); ok {
			t.Errorf("%q 不该有第二个候选", p)
		}
	}
	if got, ok := embyPrefixed("/videos/x"); !ok || got != "/emby/videos/x" {
		t.Errorf("相对路径要拼成 /emby/videos/x,实得 %q", got)
	}
	if got, ok := embyPrefixed("videos/x"); !ok || got != "/emby/videos/x" {
		t.Errorf("不带前导斜杠的也要拼对,实得 %q", got)
	}
}

// 探测**绝不能挡住起播**:上游把探测请求直接掐掉时,仍要给出一条能用的地址。
//
// ★ 网络抖一下就播不了,比跳转慢严重得多。
func TestSeekablePath探测失败不挡起播(t *testing.T) {
	up := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.Header.Get("Range") != "" {
			// 探测请求:装作服务器炸了
			hj, ok := w.(http.Hijacker)
			if ok {
				conn, _, _ := hj.Hijack()
				_ = conn.Close()
				return
			}
			w.WriteHeader(500)
			return
		}
		_, _ = w.Write([]byte(`{"MediaSources":[{"Id":"ms","Container":"mkv","DirectStreamUrl":"/videos/it1/original.mkv"}]}`))
	}))
	defer up.Close()
	ResetRangePrefixCache()

	c := NewClient("test")
	s := &Session{Server: up.URL, Token: "t", UserID: "u", DeviceID: "d"}
	got, err := c.ResolveStream(context.Background(), s, "it1", "", "")
	if err != nil {
		t.Fatalf("探测失败不该挡住起播: %v", err)
	}
	if !strings.HasSuffix(got.URL, "/videos/it1/original.mkv?api_key=t") {
		t.Fatalf("探测失败应回原地址,实得 %s", got.URL)
	}
}

// 每台服务器只探一次,结果缓存。
func TestSeekablePath每台服只探一次(t *testing.T) {
	probes := 0
	up := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.Header.Get("Range") != "" {
			probes++
			w.WriteHeader(http.StatusPartialContent)
			return
		}
		_, _ = w.Write([]byte(`{"MediaSources":[{"Id":"ms","Container":"mkv","DirectStreamUrl":"/videos/it1/original.mkv"}]}`))
	}))
	defer up.Close()
	ResetRangePrefixCache()

	c := NewClient("test")
	s := &Session{Server: up.URL, Token: "t", UserID: "u", DeviceID: "d"}
	for i := 0; i < 3; i++ {
		if _, err := c.ResolveStream(context.Background(), s, "it1", "", ""); err != nil {
			t.Fatal(err)
		}
	}
	if probes != 1 {
		t.Fatalf("每台服务器只该探一次,实得 %d 次 —— 每次起播多两个往返", probes)
	}
}

// absURL:相对路径补 server,任何地址都补 api_key,已经有的不重复补。
func TestAbsURL(t *testing.T) {
	s := &Session{Server: "https://h", Token: "tok"}
	if got := absURL(s, "/a/b"); got != "https://h/a/b?api_key=tok" {
		t.Errorf("相对路径: %s", got)
	}
	if got := absURL(s, "/a/b?x=1"); got != "https://h/a/b?x=1&api_key=tok" {
		t.Errorf("已有 query 要用 &: %s", got)
	}
	if got := absURL(s, "https://other/a?api_key=已有"); got != "https://other/a?api_key=已有" {
		t.Errorf("已有 api_key 不该重复补: %s", got)
	}
}
