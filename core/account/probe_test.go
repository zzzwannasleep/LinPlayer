package account

import (
	"context"
	"net/http"
	"net/http/httptest"
	"testing"
	"time"

	"linplayer/core/config"
	"linplayer/core/emby"
)

// ★★ 没配备用线路时,线路表必须回落成「server 本身算一条」。
//
// 回落成空表的表现是:点「测线路」什么都不显示 —— 用户以为按钮坏了,
// 而实际上大多数服务器就是没配备用线路,也就是**大多数人看到的都是坏的那一版**。
func TestLineURLs_没有备用线路时回落成主地址(t *testing.T) {
	c := &config.AppConfig{AccountList: []config.Account{{Server: "http://a.invalid"}}}
	urls, err := lineURLs(c, "http://a.invalid")
	if err != nil {
		t.Fatal(err)
	}
	if len(urls) != 1 || urls[0] != "http://a.invalid" {
		t.Fatalf("应当回落成主地址一条,实得 %v", urls)
	}
}

// ★ 不通必须是 **null**,不是 0。写成 0 的话「秒回」和「不通」在界面上长得一模一样。
func TestProbeOne_不通给nil而不是零(t *testing.T) {
	down := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.WriteHeader(http.StatusInternalServerError)
	}))
	defer down.Close()

	if got := probeOne(context.Background(), down.Client(), down.URL); got != nil {
		t.Fatalf("500 的线路应当是 nil(不通),实得 %v 毫秒", *got)
	}
}

// ★★ 并发不是优化,是必需:串行的话 6s × N。
//
// 这条测的判据是**墙钟**:三条各睡 300ms 的线路,并发跑总时长必须显著小于串行的 900ms。
func TestProbeAll_并发而不是串行(t *testing.T) {
	slow := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		time.Sleep(300 * time.Millisecond)
	}))
	defer slow.Close()

	urls := []string{slow.URL, slow.URL, slow.URL}
	t0 := time.Now()
	got := probeAll(context.Background(), slow.Client(), urls)
	elapsed := time.Since(t0)

	if len(got) != 3 {
		t.Fatalf("应当回 3 条,实得 %d", len(got))
	}
	for i, p := range got {
		if p.Index != i {
			t.Fatalf("第 %d 条的 index 是 %d —— 并发写回时下标串了", i, p.Index)
		}
		if p.MS == nil {
			t.Fatalf("第 %d 条应当是通的", i)
		}
	}
	if elapsed > 700*time.Millisecond {
		t.Fatalf("三条各 300ms 并发跑用了 %v —— 这是串行的时长", elapsed)
	}
}

func TestProbeOne_通了给毫秒(t *testing.T) {
	up := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.URL.Path != "/System/Info/Public" {
			t.Errorf("探的路径应当是 /System/Info/Public,实得 %s", r.URL.Path)
		}
	}))
	defer up.Close()

	if got := probeOne(context.Background(), up.Client(), up.URL+"/"); got == nil {
		t.Fatal("通的线路不该是 nil")
	}
	_ = emby.NewClient
}
