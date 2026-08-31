package emby

// 服务器回 gzip 时必须能正常解析。
//
// ★★ 用户 2026-08-31 拿真 Emby 实测撞上:首页每一条轨道都是
// 「解析失败: invalid character '\x1f' looking for beginning of value」。
// `\x1f` 就是 **gzip 魔数的第一个字节**(gzip 头是 1f 8b)——
// 也就是拿着压缩后的字节去 json.Unmarshal。
//
// ★ 根因是 Go net/http 的一个反直觉规则:
//
//	Transport 自己加 Accept-Encoding: gzip 时,响应**自动解压**;
//	但只要调用方**手动**设了这个头,Go 就认为「你要自己处理压缩」,
//	于是不再解压,把原始 gzip 字节交给你。
//
//	我们之前正是手动设了它(照着 Rust 版抄了「要发压缩头」这件事,
//	但 reqwest 的 gzip feature 是**连解压一起**做的,Go 这边只抄了一半)。
//
// ★ 为什么本地全绿:假 Emby 不开压缩。**预置形状 ≠ 真实形状** ——
// 这是同一个教训的第二次(第一次是「自检永远灌配置,没走过真登录」)。
// 所以 fakeemby 加了 -gzip 开关,把这个形状也造进去。

import (
	"compress/gzip"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"testing"
)

// gzipServer 一台**永远回 gzip** 的服务器。
func gzipServer(t *testing.T, body string) *httptest.Server {
	t.Helper()
	s := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "application/json")
		w.Header().Set("Content-Encoding", "gzip")
		zw := gzip.NewWriter(w)
		defer zw.Close()
		_, _ = zw.Write([]byte(body))
	}))
	t.Cleanup(s.Close)
	return s
}

// ★★ 这条是本文件存在的全部理由。
func TestGetBytes_服务器回gzip时要能解析(t *testing.T) {
	const body = `{"Items":[{"Id":"a","Name":"某部片","Type":"Movie"}],"TotalRecordCount":1}`
	up := gzipServer(t, body)

	c := NewClient("test")
	s := &Session{Server: up.URL, Token: "t", UserID: "u", DeviceID: "d"}
	got, err := c.getBytes(t.Context(), s, up.URL+"/whatever")
	if err != nil {
		t.Fatalf("取数失败: %v", err)
	}
	/* ★ 判据是「**能不能真的解析成 JSON**」,不是「字节里有没有出现某个词」。
	   第一版写的是 strings.Contains(got, "某部片") —— 那条**对注入不敏感**:
	   语料太短时 deflate 会用 stored(未压缩)块,原文原样留在压缩流里,
	   Contains 照样匹配得上,测试就成了空跑。夹具/语料选错是假绿的一类。 */
	var j struct {
		Items []struct{ Name string } `json:"Items"`
	}
	if err := json.Unmarshal(got, &j); err != nil {
		t.Fatalf("拿到的不是解压后的 JSON:%v(前 4 字节 % x;"+
			"1f 8b 开头就是没解压)", err, got[:min(4, len(got))])
	}
	if len(j.Items) != 1 || j.Items[0].Name != "某部片" {
		t.Fatalf("解出来的内容不对: %+v", j)
	}
}

// ★ 列表那条链要端到端能用,不只是 getBytes 能解压。
func TestFetchPage_gzip响应下能拿到条目(t *testing.T) {
	const body = `{"Items":[{"Id":"a","Name":"某部片","Type":"Movie"}],"TotalRecordCount":1}`
	up := gzipServer(t, body)

	c := NewClient("test")
	s := &Session{Server: up.URL, Token: "t", UserID: "u", DeviceID: "d"}
	page, err := c.fetchPage(t.Context(), s, up.URL+"/Items")
	if err != nil {
		t.Fatalf("取列表失败: %v", err)
	}
	if len(page.Items) != 1 || page.Items[0].Name != "某部片" {
		t.Fatalf("条目没解出来: %+v", page.Items)
	}
}

// ★ 不压缩的响应当然也要照常能用 —— 别修好一边坏另一边。
func TestGetBytes_不压缩的响应照常可用(t *testing.T) {
	up := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "application/json")
		_, _ = w.Write([]byte(`{"Items":[],"TotalRecordCount":0}`))
	}))
	defer up.Close()

	c := NewClient("test")
	s := &Session{Server: up.URL, Token: "t", UserID: "u", DeviceID: "d"}
	got, err := c.getBytes(t.Context(), s, up.URL+"/x")
	if err != nil {
		t.Fatalf("取数失败: %v", err)
	}
	var j map[string]any
	if err := json.Unmarshal(got, &j); err != nil {
		t.Fatalf("明文响应解析失败: %v", err)
	}
	if _, ok := j["TotalRecordCount"]; !ok {
		t.Fatalf("明文响应拿错了: %v", j)
	}
}

func min(a, b int) int {
	if a < b {
		return a
	}
	return b
}
