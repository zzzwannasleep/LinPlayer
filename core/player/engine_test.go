package player

import (
	"encoding/json"
	"fmt"
	"net/http"
	"net/http/httptest"
	"strings"
	"sync"
	"testing"

	"linplayer/core/config"
	"linplayer/core/paths"
)

/*
两个播放内核(用户 2026-09-06 点名:mpv / ExoPlayer 可切)。

★★ 判据只有一条:**`engine=exo` 那条路不许碰 mpv,而且必须把地址交出来。**

  为什么这条值得钉:安卓上 ExoPlayer 是「mpv 出不了画面」时的退路。
  如果 exo 那条也走 `ensureMpv` / `waitRenderCtx`,那么 mpv 起不来的那台机器上
  **换内核照样播不了** —— 而错误信息会是「视频通道未就绪」,指向一条
  跟 ExoPlayer 毫无关系的路,查起来极远。

  反向注入:把 playback.go 里 `if useMpv {` 那两处守卫去掉,这条当场红
  (headless 测试进程里没有 Surface,waitRenderCtx 必然超时)。
*/
// TestMain 故意只注册了偏好那批(player.play 那条在 mpv 内核下要真 libmpv)。
// 这条测试要的正是**不要 libmpv 的那一半**,所以在这里补注册一次。
var regTransportOnce sync.Once

func TestPlay_Exo内核不碰mpv且交出地址(t *testing.T) {
	regTransportOnce.Do(registerTransport)
	paths.SetRoot(t.TempDir())
	if _, err := config.Load(); err != nil {
		t.Fatal(err)
	}

	up := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		switch {
		case strings.Contains(r.URL.Path, "/PlaybackInfo"):
			w.Header().Set("Content-Type", "application/json")
			fmt.Fprintf(w, `{"PlaySessionId":"psid-1","MediaSources":[{
				"Id":"ms-1080","Name":"1080p","Container":"mkv",
				"SupportsDirectStream":true,
				"DirectStreamUrl":"/emby/videos/e1/stream.mkv?api_key=tk",
				"MediaStreams":[{"Type":"Video","Index":0,"Height":1080,"Codec":"h264"}]}]}`)
		case strings.Contains(r.URL.Path, "stream.mkv"):
			// 预取代理会来探一次总长度
			const total = 8 * 1024 * 1024
			w.Header().Set("Content-Range", fmt.Sprintf("bytes 0-0/%d", total))
			w.WriteHeader(http.StatusPartialContent)
			_, _ = w.Write(make([]byte, 1))
		default:
			// 观看记录判据 / start 上报:回什么都行,失败也不该阻断起播
			w.Header().Set("Content-Type", "application/json")
			_, _ = w.Write([]byte(`{"Id":"e1","Name":"第 1 集","Type":"Episode","RunTimeTicks":14000000000}`))
		}
	}))
	defer up.Close()
	defer closeSharedProxy()

	r := call(t, 9101, "player.play", map[string]any{
		"server": up.URL, "token": "tk", "user_id": "u1", "device_id": "d1",
		"item_id": "e1", "engine": "exo",
	})
	if !r.OK {
		t.Fatalf("engine=exo 起播失败: %s %s —— 它不该需要视频通道", r.Code, r.Msg)
	}
	var out map[string]any
	if err := json.Unmarshal(r.Data, &out); err != nil {
		t.Fatal(err)
	}
	// ☠ 地址必须由核心层给。让 UI 自己拼的下场见 docs/lessons:
	//    反代只在 /emby/ 前缀下处理 Range,拼错了「跳到没缓冲的位置就卡死」。
	if u, _ := out["play_url"].(string); u == "" {
		t.Fatalf("engine=exo 必须回 play_url,实得 %+v —— 没有它 ExoPlayer 无米下锅", out)
	}
	if ms, _ := out["media_source_id"].(string); ms != "ms-1080" {
		t.Fatalf("换内核不该换选中的版本,实得 %q", ms)
	}
	// PlaySessionId 要贯穿:少了它「看一半退出进度不落地」,而且不报错
	if ps, _ := out["play_session_id"].(string); ps != "psid-1" {
		t.Fatalf("PlaySessionId 没贯穿: %q", ps)
	}
}
