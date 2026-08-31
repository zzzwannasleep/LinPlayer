package emby

// 登录时顺带取服务器名(用户 2026-08-31 要求)。
//
// 之前首次登录后侧栏显示的是地址(`192.168.x.x:8096`),要手动去服务器页改名。
// 现在登录流程里并一跳 `/System/Info/Public`,把 ServerName 落成账号显示名。
//
// ★★ 三条边界,每条都能单独把这个功能变成 bug:
//
//	① **只在新账号时带名字**。Upsert 对非空 Name 是**覆盖**语义,
//	   无条件传的话「重新登录一次,用户改过的服务器名就被冲回原名」。
//	② **探不到名字不能挡住登录**。有的 fork 没有这个端点 —— 名字是锦上添花,
//	   登录是刚需,不能因为锦上添花失败就登不进去。
//	③ **探名字要有独立的短超时**。共用 60 秒的客户端超时的话,
//	   这个端点一挂,登录就卡 60 秒 —— 用户只会觉得「这播放器登录巨慢」。

import (
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"testing"
	"time"

	"linplayer/core/bus"
	"linplayer/core/config"
)

// embyWithName 一台会回服务器名的假 Emby。probeDelay > 0 时让 /System/Info/Public 卡住。
func embyWithName(t *testing.T, name string, probeDelay time.Duration, probeCode int) *httptest.Server {
	t.Helper()
	/* ★ 卡住的 handler 必须能被**提前释放**。
	   直接 time.Sleep(30s) 的话,httptest.Server.Close() 会等这个请求跑完 ——
	   测试逻辑明明 5 秒就判完了,整条测试却要挂满 30 秒。
	   (同一个坑在 prefetch 那边踩过:handler 里 select{} 把整个包卡到超时。) */
	release := make(chan struct{})
	t.Cleanup(func() { close(release) })

	s := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		switch r.URL.Path {
		case "/System/Info/Public":
			if probeDelay > 0 {
				select {
				case <-time.After(probeDelay):
				case <-release: // 测试结束,别再吊着
					return
				case <-r.Context().Done(): // 客户端超时主动断了
					return
				}
			}
			if probeCode != 0 && probeCode != 200 {
				w.WriteHeader(probeCode)
				return
			}
			w.Header().Set("Content-Type", "application/json")
			_, _ = w.Write([]byte(`{"ServerName":"` + name + `","Version":"4.9.0","Id":"srv-1"}`))
		case "/Users/AuthenticateByName":
			w.Header().Set("Content-Type", "application/json")
			_, _ = w.Write([]byte(`{"AccessToken":"tok-1","User":{"Id":"u1","Name":"某用户"}}`))
		default:
			w.WriteHeader(404)
		}
	}))
	t.Cleanup(s.Close)
	return s
}

// ★★ 首次登录要把服务器名落下来。
func TestLogin_首次登录自动取服务器名(t *testing.T) {
	freshConfig(t)
	up := embyWithName(t, "我家的影院", 0, 200)

	doLogin(t, 40, up.URL, "u", "p")

	a := config.Current().Find(up.URL)
	if a == nil {
		t.Fatal("账号没落库")
	}
	if a.Name != "我家的影院" {
		t.Fatalf("服务器名没落下来,实得 %q —— 侧栏会显示成一串地址", a.Name)
	}
}

// ★★ 重登**不能**把用户改过的名字冲掉。
//
// Upsert 对非空 Name 是覆盖语义,所以只能在新账号时带名字。
// 这条错了的表现是「我每次重新登录,改好的服务器名就被打回原形」。
func TestLogin_重登不冲掉用户改过的服务器名(t *testing.T) {
	freshConfig(t)
	up := embyWithName(t, "服务器原名", 0, 200)

	doLogin(t, 41, up.URL, "u", "p")

	c := config.Current()
	c.Find(up.URL).Name = "我自己起的名"
	if err := c.Save(); err != nil {
		t.Fatal(err)
	}

	doLogin(t, 42, up.URL, "u", "p") // 再登一次

	if got := config.Current().Find(up.URL); got.Name != "我自己起的名" {
		t.Fatalf("重登把用户改过的名字冲成了 %q", got.Name)
	}
}

// ★ 探不到名字**不能挡住登录**。名字是锦上添花,登录是刚需。
func TestLogin_探不到服务器名也要能登进去(t *testing.T) {
	freshConfig(t)
	up := embyWithName(t, "", 0, 404) // 这个端点直接 404

	doLogin(t, 43, up.URL, "u", "p") // 不报错才算过

	a := config.Current().Find(up.URL)
	if a == nil {
		t.Fatal("探不到服务器名居然把登录也搞挂了 —— 名字是锦上添花,登录是刚需")
	}
	if a.Name != "" {
		t.Fatalf("探不到名字时应当留空(由前端回落 host),实得 %q", a.Name)
	}
}

// ★★ 探名字要有**独立的短超时**。
//
// 共用 60 秒的客户端超时的话,这个端点一卡,登录就跟着卡 60 秒 ——
// 用户只会觉得「这播放器登录巨慢」,而根本想不到是在取一个可有可无的名字。
func TestLogin_探服务器名不能拖慢登录(t *testing.T) {
	freshConfig(t)
	up := embyWithName(t, "慢服务器", 30*time.Second, 200) // 这个端点吊死

	t0 := time.Now()
	args, _ := json.Marshal(map[string]string{
		"server": up.URL, "username": "u", "password": "p", "device_id": "dev-1",
	})
	if err := bus.Call(44, "emby.login", string(args)); err != nil {
		t.Fatalf("发命令失败: %v", err)
	}
	waitResult(t, 44)
	elapsed := time.Since(t0)

	// ★ 判据卡在 8 秒:5 秒超时 + 余量。放到 10 秒以上就分不出
	//   「短超时生效」和「刚好比 60 秒快一点」了。
	if elapsed > 8*time.Second {
		t.Fatalf("取服务器名的端点吊死时,登录用了 %v —— 名字探测必须有自己的短超时", elapsed)
	}
	if config.Current().Find(up.URL) == nil {
		t.Fatal("登录没落库")
	}
}
