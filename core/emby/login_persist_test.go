package emby

// 登录成功必须把账号**落库**。
//
// ★★ 用户 2026-08-31 实测撞上:「进去了但是还是不行,提示缺少 server-id」。
// 根因就是这条:`emby.login` 认证成功、返回了 token、图片白名单也登记了,
// **唯独没把账号写进配置**。于是:
//
//	account.listAccounts   → 空数组
//	emby.currentSession    → null(ActiveAccount 是 nil)
//	侧栏                    → 还是「未连接」
//	任何按 server_id 找账号的命令 → 「没有这个服务器: 」
//
// 「登录成功了,但整个应用当作你没登录」—— 而且一步都不报错。
//
// ★ 为什么之前没抓到:同目录的 login_allowlist_test.go 只钉住了「白名单」那一半。
// 我做对了想到的那一半,漏掉的那一半自然也没有测试。**测试只能钉住你想到的东西**,
// 所以端到端那条路必须真的走一遍(见 scripts/selfcheck-win.sh 的真登录用例)。

import (
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"testing"

	"linplayer/core/bus"
	"linplayer/core/config"
	"linplayer/core/paths"
)

// freshConfig 一个空的数据根 + **加载一次配置**。
//
// ★ 必须 Load:config.Current() 在没加载过时返回的是一个**临时的默认对象**,
// 改它不影响全局 —— 而真机上 lp_init 一定先 Load 过。
// 少这一步的话测试测的是「往一个临时对象里写」,和真实行为对不上(我第一版就这么写的)。
func freshConfig(t *testing.T) {
	t.Helper()
	paths.SetRoot(t.TempDir())
	if _, err := config.Load(); err != nil {
		t.Fatal(err)
	}
}

// loginServer 一台只认一组凭据的假 Emby。
func loginServer(t *testing.T, ok bool) *httptest.Server {
	t.Helper()
	s := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if !ok {
			w.WriteHeader(http.StatusUnauthorized)
			return
		}
		w.Header().Set("Content-Type", "application/json")
		_, _ = w.Write([]byte(`{"AccessToken":"tok-1","User":{"Id":"u1","Name":"某用户"}}`))
	}))
	t.Cleanup(s.Close)
	return s
}

func doLogin(t *testing.T, seq int64, server, user, pw string) {
	t.Helper()
	args, _ := json.Marshal(map[string]string{
		"server": server, "username": user, "password": pw, "device_id": "dev-1",
	})
	if err := bus.Call(seq, "emby.login", string(args)); err != nil {
		t.Fatalf("发命令失败: %v", err)
	}
	waitResult(t, seq)
}

// ★★ 这条是本文件存在的全部理由。
func TestLogin_成功之后账号必须落库(t *testing.T) {
	freshConfig(t)
	up := loginServer(t, true)

	doLogin(t, 20, up.URL, "u", "p")

	c := config.Current()
	if len(c.AccountList) != 1 {
		t.Fatalf("登录成功后账号表应当有 1 条,实得 %d ——"+
			"表现是「登录进去了,但整个应用当作你没登录」", len(c.AccountList))
	}
	got := c.AccountList[0]
	if got.Server != up.URL || got.Token != "tok-1" || got.UserID != "u1" {
		t.Fatalf("落库的账号字段不对: %+v", got)
	}
	if got.UserName != "某用户" {
		t.Fatalf("用户名没落库,实得 %q —— 同一台服务器上两个账号会分不清", got.UserName)
	}
}

// ★★ 落库还不够,还得是**活跃账号**。
//
// emby.currentSession 读的是 ActiveAccount();不设活跃的话它照样返回 null,
// 症状和「压根没落库」一模一样。
func TestLogin_落库的账号必须成为活跃账号(t *testing.T) {
	freshConfig(t)
	up := loginServer(t, true)

	doLogin(t, 21, up.URL, "u", "p")

	if a := config.Current().ActiveAccount(); a == nil {
		t.Fatal("登录后没有活跃账号 —— emby.currentSession 会返回 null,前端当你没登录")
	} else if a.Server != up.URL {
		t.Fatalf("活跃账号不是刚登录的那台: %s", a.Server)
	}
}

// ★ 密码要存下来:重新登录和插件的 emby.credentials 权限都要用它。
//
// ★ 但**空密码不能存成空串** —— 那会让「有密码」和「没设过密码」分不清。
func TestLogin_密码落库而空密码不落(t *testing.T) {
	freshConfig(t)
	up := loginServer(t, true)

	doLogin(t, 22, up.URL, "u", "p")
	if a := config.Current().Find(up.URL); a == nil || a.Password == nil || *a.Password != "p" {
		t.Fatal("密码没落库 —— 重新登录和插件凭据权限都要用它")
	}

	freshConfig(t)
	up2 := loginServer(t, true)
	doLogin(t, 23, up2.URL, "u", "")
	if a := config.Current().Find(up2.URL); a == nil {
		t.Fatal("账号没落库")
	} else if a.Password != nil {
		t.Fatalf("空密码不该存成空串(会和「没设过密码」混淆),实得 %q", *a.Password)
	}
}

// ★★ 登录**失败**时绝不能落库。
//
// 落了的话:用户打错一次密码,一个连不上的账号就永久赖在服务器列表里,
// 而且会被 Upsert 设成活跃账号 —— 下次启动直接进一个 401 的服务器。
func TestLogin_失败时不许落库(t *testing.T) {
	freshConfig(t)
	up := loginServer(t, false) // 一律 401

	args, _ := json.Marshal(map[string]string{
		"server": up.URL, "username": "u", "password": "错的", "device_id": "dev-1",
	})
	if err := bus.Call(24, "emby.login", string(args)); err != nil {
		t.Fatalf("发命令失败: %v", err)
	}
	waitErr(t, 24) // 预期报错

	if n := len(config.Current().AccountList); n != 0 {
		t.Fatalf("登录失败却落了 %d 条账号 —— 打错一次密码就永久多一台连不上的服务器", n)
	}
}

// ★ 重登不能把用户改过的名称冲掉(Upsert 的语义,这里从命令层串起来验一遍)。
func TestLogin_重登保住用户改过的名称(t *testing.T) {
	freshConfig(t)
	up := loginServer(t, true)

	doLogin(t, 25, up.URL, "u", "p")

	c := config.Current()
	c.Find(up.URL).Name = "我家的服务器"
	if err := c.Save(); err != nil {
		t.Fatal(err)
	}

	doLogin(t, 26, up.URL, "u", "p") // 再登一次

	if got := config.Current().Find(up.URL); got == nil {
		t.Fatal("重登之后账号没了")
	} else if got.Name != "我家的服务器" {
		t.Fatalf("重登把用户改过的名称冲掉了,实得 %q", got.Name)
	}
	if n := len(config.Current().AccountList); n != 1 {
		t.Fatalf("重登应当是更新不是新增,实得 %d 条", n)
	}
}

// waitErr 等这条 seq 的 result,并要求它是**失败**。
func waitErr(t *testing.T, seq int64) {
	t.Helper()
	for i := 0; i < 50; i++ {
		b := bus.NextEvent(200)
		if len(b) == 0 {
			continue
		}
		var e struct {
			T   string `json:"t"`
			Seq int64  `json:"seq"`
			OK  bool   `json:"ok"`
		}
		if json.Unmarshal(b, &e) != nil || e.T != "result" || e.Seq != seq {
			continue
		}
		if e.OK {
			t.Fatal("这条命令应当失败,却成功了")
		}
		return
	}
	t.Fatal("等不到 result")
}
