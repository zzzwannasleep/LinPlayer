package player

import (
	"context"
	"fmt"
	"net/http"
	"net/http/httptest"
	"os"
	"testing"

	"linplayer/core/config"
	"linplayer/core/emby"
	"linplayer/core/paths"
	"strings"
)

// ★★ C27 判据:预热之后起播必须**复用同一个句柄**,不能新起。
//
// 新起一个的表现:旧句柄一关,它的环形缓存文件就被删了 —— 详情页预热的那几十 MB
// 全部作废,起播还得从头再下一遍。慢链路上那是几分钟的白等,
// 而用户什么都看不出来(只觉得「预加载好像没用」)。
func TestC27_预热之后起播复用同一句柄(t *testing.T) {
	paths.SetRoot(t.TempDir())
	up := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		const total = 8 * 1024 * 1024
		w.Header().Set("Content-Range", fmt.Sprintf("bytes 0-0/%d", total))
		w.WriteHeader(http.StatusPartialContent)
		_, _ = w.Write(make([]byte, 1))
	}))
	defer up.Close()
	defer closeSharedProxy()

	p := config.DefaultPrefs()
	first := proxyFor(context.Background(), up.URL+"/v.mkv", p, true)
	if first == nil {
		t.Fatal("该起得来")
	}
	again := proxyFor(context.Background(), up.URL+"/v.mkv", p, true)
	if again != first {
		t.Fatal("同一条上游地址必须复用同一个句柄 —— 新起一个会把预热好的缓存删掉")
	}
	if again.URL != first.URL {
		t.Fatalf("复用的话本地地址也该一样:%s vs %s", first.URL, again.URL)
	}

	// 换一条流:必须换句柄(旧的连缓存一起收掉,否则端口和文件都留着)
	other := proxyFor(context.Background(), up.URL+"/other.mkv", p, true)
	if other == first {
		t.Fatal("换了流还复用旧句柄 = 播 A 的字节喂给 B")
	}
	if _, err := os.Stat(first.CachePathForTest()); err == nil {
		t.Fatal("旧句柄的缓存文件没删掉")
	}
}

// 关掉「多线程加载」**也要走本地代理** —— 只是不超前拉。
//
// ★★ 从前这里是 `if !on && !warmHit { return target.URL }`:开关关着连代理都不起,
// 而缩略图和进度条上「哪一段有图」唯一的字节来源就是代理的环形缓存 ——
// 于是「不开多线程加载就没有缩略图」。两个功能挂在一个开关上,用户 2026-09-06 点名。
func TestStartPrefetch关了多线程也要有本地代理(t *testing.T) {
	paths.SetRoot(t.TempDir())
	if _, err := config.Load(); err != nil {
		t.Fatal(err)
	}
	up := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		const total = 8 * 1024 * 1024
		w.Header().Set("Content-Range", fmt.Sprintf("bytes 0-0/%d", total))
		w.WriteHeader(http.StatusPartialContent)
		_, _ = w.Write(make([]byte, 1))
	}))
	defer up.Close()
	defer closeSharedProxy()

	p := config.DefaultPrefs()
	if len(p.PrefetchServers) != 0 {
		t.Fatal("前提不成立:多线程加载默认该是**按服务器手动开**的")
	}
	target := &emby.PlaybackTarget{URL: up.URL + "/v.mkv", PlayMethod: "DirectStream"}
	got := startPrefetch(context.Background(), nil, target, p)
	if got == target.URL {
		t.Fatal("关了多线程加载就直连了 —— 那样本地没有任何字节,缩略图整个不存在")
	}
	if !strings.HasPrefix(got, "http://127.0.0.1:") {
		t.Fatalf("该交给本地代理,实得 %s", got)
	}
}

// 转码流仍然直连:分段流套一层字节代理没有意义(这条别被上面那条顺手改坏)。
func TestStartPrefetch转码流仍然直连(t *testing.T) {
	paths.SetRoot(t.TempDir())
	if _, err := config.Load(); err != nil {
		t.Fatal(err)
	}
	defer closeSharedProxy()
	target := &emby.PlaybackTarget{URL: "http://example.invalid/hls.m3u8", PlayMethod: "Transcode"}
	if got := startPrefetch(context.Background(), nil, target, config.DefaultPrefs()); got != target.URL {
		t.Fatalf("转码流该直连,实得 %s", got)
	}
}
