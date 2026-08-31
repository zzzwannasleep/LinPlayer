package player

import (
	"context"
	"fmt"
	"net/http"
	"net/http/httptest"
	"os"
	"testing"

	"linplayer/core/config"
	"linplayer/core/paths"
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
	first := proxyFor(context.Background(), up.URL+"/v.mkv", p)
	if first == nil {
		t.Fatal("该起得来")
	}
	again := proxyFor(context.Background(), up.URL+"/v.mkv", p)
	if again != first {
		t.Fatal("同一条上游地址必须复用同一个句柄 —— 新起一个会把预热好的缓存删掉")
	}
	if again.URL != first.URL {
		t.Fatalf("复用的话本地地址也该一样:%s vs %s", first.URL, again.URL)
	}

	// 换一条流:必须换句柄(旧的连缓存一起收掉,否则端口和文件都留着)
	other := proxyFor(context.Background(), up.URL+"/other.mkv", p)
	if other == first {
		t.Fatal("换了流还复用旧句柄 = 播 A 的字节喂给 B")
	}
	if _, err := os.Stat(first.CachePathForTest()); err == nil {
		t.Fatal("旧句柄的缓存文件没删掉")
	}
}
