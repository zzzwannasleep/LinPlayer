package emby

import (
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"os"
	"strings"
	"testing"
	"time"

	"linplayer/core/bus"
	"linplayer/core/net/localserve"
	"linplayer/core/paths"
)

// TestMain 统一起总线并注册一次命令。
//
// ★ bus.Register **重复注册会 panic**(那是编码错误,不该等到运行时才发现),
// 所以每条测试各自 RegisterCommands 是跑不起来的;bus.Shutdown 之后总线也不再收命令。
// 一次注册、全程共用 —— 代价是这几条测试共享事件队列,所以每条用**不同的 seq**。
func TestMain(m *testing.M) {
	bus.Init()
	RegisterCommands("test")
	os.Exit(m.Run())
}

// 登录成功必须把这台服务器登记进图片通道的白名单。
//
// ★ 漏了这一步的表现是**登录进去一张封面都没有,而命令全都正常** ——
// 很容易被误判成「图片接口坏了」,然后去查 localserve、查缓存、查上游,
// 唯独不会去看登录那条路。这类「A 处漏了在 B 处发作」的接线,
// 只有端到端跑一遍才抓得到:两边各自的单测都是绿的。
//
// 这条测试**走真的命令总线**(bus.Call → 工作池 → 事件队列),不是直接调函数 ——
// 直接调 Client.Login 的话,连「命令层有没有做这件事」都证明不了。
func TestLoginRegistersImageAllowlist(t *testing.T) {
	paths.SetRoot(t.TempDir())

	up := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.URL.Path != "/Users/AuthenticateByName" {
			w.WriteHeader(599)
			return
		}
		w.Header().Set("Content-Type", "application/json")
		_, _ = w.Write([]byte(`{"AccessToken":"tok-1","User":{"Id":"u1","Name":"某用户"}}`))
	}))
	defer up.Close()

	srv, err := localserve.Start()
	if err != nil {
		t.Fatalf("起本地服务失败: %v", err)
	}
	defer srv.Close()
	localserve.SetDefault(srv)
	defer localserve.SetDefault(nil)

	args, _ := json.Marshal(map[string]string{
		"server": up.URL, "username": "u", "password": "p", "device_id": "dev-1",
	})
	if err := bus.Call(1, "emby.login", string(args)); err != nil {
		t.Fatalf("发命令失败: %v", err)
	}
	waitResult(t, 1)

	// 登记进去了吗 —— 用「这张图取不取得到」来判,而不是去读白名单的内部结构:
	// 读内部结构的话,把 handleImg 改坏了这条测试照样绿。
	req, _ := http.NewRequest(http.MethodGet,
		srv.BaseURL()+"/img?src="+up.URL+"/Items/x/Images/Primary", nil)
	req.Header.Set("X-LP-Token", srv.Token)
	resp, err := http.DefaultClient.Do(req)
	if err != nil {
		t.Fatalf("取图请求失败: %v", err)
	}
	defer resp.Body.Close()
	// 上游那个 mock 对图片路径回 599,所以这里不该是 200;
	// 关键是**不能是 404**（404 = 没进白名单，请求根本没发出去）。
	if resp.StatusCode == http.StatusNotFound {
		t.Fatal("登录后这台服务器仍不在图片白名单里 —— 表现是登录进去一张封面都没有")
	}
}

// waitResult 从事件队列里等这条 seq 的 result。
func waitResult(t *testing.T, seq int64) {
	t.Helper()
	deadline := time.Now().Add(5 * time.Second)
	for time.Now().Before(deadline) {
		b := bus.NextEvent(200)
		if len(b) == 0 {
			continue
		}
		var e struct {
			T   string `json:"t"`
			Seq int64  `json:"seq"`
			Err *struct {
				Code string `json:"code"`
				Msg  string `json:"msg"`
			} `json:"error"`
		}
		if json.Unmarshal(b, &e) != nil {
			continue
		}
		if e.T != "result" || e.Seq != seq {
			continue
		}
		if e.Err != nil {
			t.Fatalf("命令报错: %s %s", e.Err.Code, e.Err.Msg)
		}
		return
	}
	t.Fatal("等不到 result —— 命令没被执行,或者事件队列没吐出来")
}

// 登出必须撤销白名单。留着的话那个 origin 就是一个永久的 SSRF 出口。
func TestLogoutRevokesImageAllowlist(t *testing.T) {
	paths.SetRoot(t.TempDir())

	up := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.WriteHeader(200)
	}))
	defer up.Close()

	srv, err := localserve.Start()
	if err != nil {
		t.Fatal(err)
	}
	defer srv.Close()
	localserve.SetDefault(srv)
	defer localserve.SetDefault(nil)
	srv.Allow(up.URL, http.Header{"X-Emby-Token": {"tok"}})

	args, _ := json.Marshal(map[string]string{
		"server": up.URL, "token": "tok", "user_id": "u1", "device_id": "dev-1",
	})
	if err := bus.Call(2, "emby.logout", string(args)); err != nil {
		t.Fatal(err)
	}
	waitResult(t, 2)

	req, _ := http.NewRequest(http.MethodGet, srv.BaseURL()+"/img?src="+up.URL+"/a.jpg", nil)
	req.Header.Set("X-LP-Token", srv.Token)
	resp, err := http.DefaultClient.Do(req)
	if err != nil {
		t.Fatal(err)
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusNotFound {
		t.Fatalf("登出后应撤销白名单(404),实得 %d", resp.StatusCode)
	}
}

// 密码**不许**出现在任何返回体或错误串里。
//
// ★ 这条是仓库红线的一部分:错误串会进日志、进事件队列、进
// system.exportDiagnostics 导出的诊断包 —— 用户把诊断包发到 issue 里,
// 密码就跟着走了。所以登录失败只说 HTTP 码。
func TestLoginNeverLeaksPassword(t *testing.T) {
	paths.SetRoot(t.TempDir())
	const secret = "这是密码不许出现"

	up := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.WriteHeader(401)
		_, _ = w.Write([]byte(`{"error":"bad"}`))
	}))
	defer up.Close()

	args, _ := json.Marshal(map[string]string{
		"server": up.URL, "username": "u", "password": secret, "device_id": "dev-1",
	})
	if err := bus.Call(3, "emby.login", string(args)); err != nil {
		t.Fatal(err)
	}
	deadline := time.Now().Add(5 * time.Second)
	got := false
	for time.Now().Before(deadline) && !got {
		b := bus.NextEvent(200)
		if len(b) == 0 {
			continue
		}
		if strings.Contains(string(b), secret) {
			t.Fatalf("密码出现在事件里了:%s", b)
		}
		var e struct {
			T   string `json:"t"`
			Seq int64  `json:"seq"`
		}
		if json.Unmarshal(b, &e) == nil && e.T == "result" && e.Seq == 3 {
			got = true
		}
	}
	if !got {
		t.Fatal("等不到 result")
	}
}
