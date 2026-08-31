package account

import (
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"os"
	"strings"
	"testing"
	"time"

	"linplayer/core/bus"
	"linplayer/core/config"
	"linplayer/core/net/localserve"
	"linplayer/core/paths"
)

// TestMain 统一起总线并注册一次命令(bus.Register 重复注册会 panic)。
func TestMain(m *testing.M) {
	bus.Init()
	RegisterCommands("test")
	os.Exit(m.Run())
}

// call 走**真的命令总线**发一条命令,返回 data。
//
// ★ 直接调函数证明不了「命令层做没做这件事」,而这一层的 bug 恰恰全在接线上。
func call(t *testing.T, seq int64, cmd string, args map[string]any) map[string]any {
	t.Helper()
	b, _ := json.Marshal(args)
	if err := bus.Call(seq, cmd, string(b)); err != nil {
		t.Fatalf("发命令失败: %v", err)
	}
	deadline := time.Now().Add(5 * time.Second)
	for time.Now().Before(deadline) {
		ev := bus.NextEvent(200)
		if len(ev) == 0 {
			continue
		}
		var e struct {
			T    string          `json:"t"`
			Seq  int64           `json:"seq"`
			OK   bool            `json:"ok"`
			Data json.RawMessage `json:"data"`
			Err  *struct {
				Code string `json:"code"`
				Msg  string `json:"msg"`
			} `json:"err"`
		}
		if json.Unmarshal(ev, &e) != nil || e.T != "result" || e.Seq != seq {
			continue
		}
		if e.Err != nil {
			t.Fatalf("%s 报错: %s %s", cmd, e.Err.Code, e.Err.Msg)
		}
		var out map[string]any
		_ = json.Unmarshal(e.Data, &out)
		if out == nil {
			// 返回的是数组时包一层,方便调用方统一取
			var arr []any
			_ = json.Unmarshal(e.Data, &arr)
			return map[string]any{"list": arr}
		}
		return out
	}
	t.Fatalf("等不到 %s 的 result", cmd)
	return nil
}

func callList(t *testing.T, seq int64, cmd string, args map[string]any) []any {
	t.Helper()
	v := call(t, seq, cmd, args)
	if l, ok := v["list"].([]any); ok {
		return l
	}
	if l, ok := v["accounts"].([]any); ok {
		return l
	}
	t.Fatalf("%s 没返回账号表: %+v", cmd, v)
	return nil
}

func setup(t *testing.T) {
	t.Helper()
	paths.SetRoot(t.TempDir())
	if _, err := config.Load(); err != nil {
		t.Fatal(err)
	}
}

func addAccount(t *testing.T, server, token string) {
	t.Helper()
	c := config.Current()
	c.Upsert(config.Account{Server: server, Token: token, UserID: "u", UserName: "n"})
	if err := c.Save(); err != nil {
		t.Fatal(err)
	}
}

// 每条改账号的命令都必须**落盘** —— 漏了的表现是「改完看着对了,重启回到改之前」。
//
// 这条测试把 5 条命令挨个跑一遍,每跑一条就从磁盘重新读一次,
// 而不是只测其中一条:漏落盘是**逐条**发生的,测一条盖不住其余四条。
func TestEveryMutationPersists(t *testing.T) {
	setup(t)
	addAccount(t, "https://a", "t1")
	addAccount(t, "https://b", "t2")

	steps := []struct {
		name string
		seq  int64
		cmd  string
		args map[string]any
		want func(t *testing.T, c *config.AppConfig)
	}{
		{"改名", 101, "account.updateAccount",
			map[string]any{"server_id": "https://a", "name": "客厅那台"},
			func(t *testing.T, c *config.AppConfig) {
				if c.Find("https://a").Name != "客厅那台" {
					t.Fatal("改名没落盘")
				}
			}},
		{"切活跃", 102, "account.setActiveServer",
			map[string]any{"server_id": "https://a"},
			func(t *testing.T, c *config.AppConfig) {
				if c.ActiveAccount().Server != "https://a" {
					t.Fatal("切活跃没落盘")
				}
			}},
		{"排序", 103, "account.reorderAccounts",
			map[string]any{"from": float64(1), "to": float64(0)},
			func(t *testing.T, c *config.AppConfig) {
				if c.AccountList[0].Server != "https://b" {
					t.Fatal("排序没落盘")
				}
				if c.ActiveAccount().Server != "https://a" {
					t.Fatal("排序后活跃账号该跟着走")
				}
			}},
		{"设线路", 104, "account.setLines",
			map[string]any{"server_id": "https://a", "lines": []any{
				map[string]any{"name": "主线", "url": "https://a"},
				map[string]any{"name": "备线", "url": "https://a2"},
			}},
			func(t *testing.T, c *config.AppConfig) {
				if len(c.Find("https://a").Lines) != 2 {
					t.Fatal("线路表没落盘")
				}
			}},
		{"删账号", 105, "account.removeAccount",
			map[string]any{"server_id": "https://b"},
			func(t *testing.T, c *config.AppConfig) {
				if c.Find("https://b") != nil {
					t.Fatal("删账号没落盘")
				}
			}},
	}
	for _, s := range steps {
		t.Run(s.name, func(t *testing.T) {
			call(t, s.seq, s.cmd, s.args)
			// ★ 从磁盘重新读 —— 只看内存里的 config.Current() 的话,
			//   忘了 Save 的命令照样绿,而用户重启后什么都没变。
			c, err := config.Load()
			if err != nil {
				t.Fatal(err)
			}
			s.want(t, c)
		})
	}
}

// 改账号必须同步刷新图片白名单,而且是**整表重建**。
//
// ★ 只加不删的话,删掉的账号 / 换掉的线路会永久留在白名单里 ——
// 一个长期存在、谁也不会再想起来的 SSRF 出口。
func TestMutationRebuildsImageAllowlist(t *testing.T) {
	setup(t)
	up := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		_, _ = w.Write([]byte{0x89, 'P', 'N', 'G', 0, 0, 0, 0})
	}))
	defer up.Close()

	srv, err := localserve.Start()
	if err != nil {
		t.Fatal(err)
	}
	defer srv.Close()
	localserve.SetDefault(srv)
	defer localserve.SetDefault(nil)

	// ★ 备用线路要用**真起得来的**第二台假服务器,不能随手写个不可路由的地址:
	//   白名单放行之后请求会真的发出去,不可路由的地址要卡满 20 秒回源超时才回 502。
	//   断言写的是「不是 404」,所以照样绿 —— 但整条测试从 0.1 秒变成 20 秒。
	up2 := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		_, _ = w.Write([]byte{0x89, 'P', 'N', 'G', 0, 0, 0, 0})
	}))
	defer up2.Close()

	addAccount(t, up.URL, "tok")
	// 先设一条线路,让「线路也要进白名单」这件事有东西可测
	call(t, 201, "account.setLines", map[string]any{
		"server_id": up.URL,
		"lines": []any{
			map[string]any{"name": "主线", "url": up.URL},
			map[string]any{"name": "备线", "url": up2.URL},
		},
	})

	img := func(origin string) int {
		req, _ := http.NewRequest(http.MethodGet, srv.BaseURL()+"/img?src="+origin+"/x.jpg", nil)
		req.Header.Set("X-LP-Token", srv.Token)
		resp, err := http.DefaultClient.Do(req)
		if err != nil {
			t.Fatal(err)
		}
		defer resp.Body.Close()
		return resp.StatusCode
	}
	if got := img(up.URL); got == http.StatusNotFound {
		t.Fatal("改完线路后主线不在白名单里 —— 表现是这台服的封面全空")
	}
	if got := img(up2.URL); got == http.StatusNotFound {
		t.Fatal("备用线路不在白名单里 —— 用户切条线看封面就全空了")
	}

	// 删掉账号:白名单必须跟着没
	call(t, 202, "account.removeAccount", map[string]any{"server_id": up.URL})
	if got := img(up.URL); got != http.StatusNotFound {
		t.Fatalf("删了账号白名单还留着(实得 %d)—— 那是个永久的 SSRF 出口", got)
	}
}

// 账号视图**不许**带 token / password。
//
// ★ 它会进事件队列、进日志、进诊断包 —— 用户把诊断包发到 issue 里,凭据就跟着走了。
func TestListAccountsNeverLeaksCredentials(t *testing.T) {
	setup(t)
	c := config.Current()
	pw := "PLACEHOLDER-PASSWORD"
	c.Upsert(config.Account{Server: "https://a", Token: "PLACEHOLDER-TOKEN", UserID: "u", Password: &pw})
	if err := c.Save(); err != nil {
		t.Fatal(err)
	}

	b, _ := json.Marshal(listOf(config.Current()))
	for _, secret := range []string{"PLACEHOLDER-TOKEN", "PLACEHOLDER-PASSWORD"} {
		if strings.Contains(string(b), secret) {
			t.Fatalf("账号视图里出现了凭据(%s):%s", secret, b)
		}
	}
	// 对照组:没有这条的话,上面那两个断言在「视图整个是空的」时也会绿
	if !strings.Contains(string(b), "https://a") {
		t.Fatalf("视图里连服务器地址都没有,这条测试证明不了任何事:%s", b)
	}
}

// setActiveLine 越界要报错,不能默默钳一下 —— 钳完用户以为切了线路,其实没切。
func TestSetActiveLineRejectsOutOfRange(t *testing.T) {
	setup(t)
	addAccount(t, "https://a", "t")
	call(t, 301, "account.setLines", map[string]any{
		"server_id": "https://a",
		"lines":     []any{map[string]any{"url": "https://a"}},
	})
	b, _ := json.Marshal(map[string]any{"server_id": "https://a", "index": 5})
	if err := bus.Call(302, "account.setActiveLine", string(b)); err != nil {
		t.Fatal(err)
	}
	deadline := time.Now().Add(5 * time.Second)
	for time.Now().Before(deadline) {
		ev := bus.NextEvent(200)
		if len(ev) == 0 {
			continue
		}
		var e struct {
			T   string `json:"t"`
			Seq int64  `json:"seq"`
			OK  bool   `json:"ok"`
		}
		if json.Unmarshal(ev, &e) != nil || e.T != "result" || e.Seq != 302 {
			continue
		}
		if e.OK {
			t.Fatal("越界下标必须报错 —— 默默钳一下的话用户以为切了线路,其实没切")
		}
		return
	}
	t.Fatal("等不到 result")
}

// setLines 整表替换后,**生效线路按 url 找回**。
//
// ★ 按下标的话,用户删掉列表中间一条,正在用的线路会静默地换成另一条。
func TestSetLinesKeepsActiveByURL(t *testing.T) {
	setup(t)
	addAccount(t, "https://a", "t")
	call(t, 401, "account.setLines", map[string]any{
		"server_id": "https://a",
		"lines": []any{
			map[string]any{"name": "1", "url": "https://l1"},
			map[string]any{"name": "2", "url": "https://l2"},
			map[string]any{"name": "3", "url": "https://l3"},
		},
	})
	call(t, 402, "account.setActiveLine", map[string]any{"server_id": "https://a", "index": float64(2)})
	if got := config.Current().Find("https://a").DirectLineURL(); got != "https://l3" {
		t.Fatalf("前提不成立: %s", got)
	}
	// 删掉中间那条
	call(t, 403, "account.setLines", map[string]any{
		"server_id": "https://a",
		"lines": []any{
			map[string]any{"name": "1", "url": "https://l1"},
			map[string]any{"name": "3", "url": "https://l3"},
		},
	})
	if got := config.Current().Find("https://a").DirectLineURL(); got != "https://l3" {
		t.Fatalf("生效线路被静默换掉了:%s", got)
	}
}

// syncLines:服务器没部署那个端点是**常态**,必须返回 added=0 而不是报错。
func TestSyncLinesTreatsMissingEndpointAsNormal(t *testing.T) {
	setup(t)
	up := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.WriteHeader(404) // 绝大多数 Emby 服务器就是这样
	}))
	defer up.Close()
	addAccount(t, up.URL, "tok")

	got := call(t, 501, "account.syncLines", map[string]any{"server_id": up.URL})
	if n, _ := got["added"].(float64); n != 0 {
		t.Fatalf("没部署时应新增 0 条,实得 %v", got["added"])
	}
}

// syncLines 只收 http(s) 的线路。
//
// ★ 信任边界:那个 url 是**服主在自己配置里自填的裸字符串,上游零校验**。
// 它会被我们直接拿去当 baseUrl 拼 API + 带上 token 请求 ——
// 配错或被投毒就等于把 token 发到任意地址。
func TestSyncLinesRejectsNonHTTPURLs(t *testing.T) {
	setup(t)
	up := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "application/json")
		_, _ = w.Write([]byte(`{"ok":true,"data":[
			{"name":"好的","url":"https://good.example.invalid"},
			{"name":"坏的","url":"file:///etc/passwd"},
			{"name":"也坏","url":"not a url at all"}
		]}`))
	}))
	defer up.Close()
	addAccount(t, up.URL, "tok")

	got := call(t, 601, "account.syncLines", map[string]any{"server_id": up.URL})
	if n, _ := got["added"].(float64); n != 1 {
		t.Fatalf("只有 1 条合法线路,实得新增 %v 条", got["added"])
	}
	for _, l := range config.Current().Find(up.URL).Lines {
		if strings.HasPrefix(l.URL, "file:") || l.URL == "not a url at all" {
			t.Fatalf("非 http 的线路进了表:%s —— 切过去就是把 token 发到任意地址", l.URL)
		}
	}
}

// testConnection 是登录**前**用的,不该要求已有账号。
func TestTestConnectionNeedsNoAccount(t *testing.T) {
	setup(t)
	up := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.URL.Path != "/System/Info/Public" {
			w.WriteHeader(599)
			return
		}
		_, _ = w.Write([]byte(`{"ServerName":"某服务器","Version":"4.9.5","Id":"abc"}`))
	}))
	defer up.Close()

	got := call(t, 701, "account.testConnection", map[string]any{"server": up.URL + "/"})
	if got["name"] != "某服务器" || got["version"] != "4.9.5" {
		t.Fatalf("探测结果不对: %+v", got)
	}
	if len(callList(t, 702, "account.listAccounts", nil)) != 0 {
		t.Fatal("测试连接不该往账号表里加东西")
	}
}
