// fakeemby 是一台**假 Emby**,给 Windows 端做真机自检用。
//
// 为什么要它:真机自检不能依赖真服务器 ——
//   · 真服务器的地址和账号是红线,不能进仓库
//   · 网络一抖自检就红,那种门禁没人信
//   · 有些形状(空库 / 404 的统计端点 / 慢链路)在真服务器上根本造不出来
//
// 它只实现 UI 主链路真正会打的那几个端点,回的字段名与真 Emby 一致。
//
//	go run ./tools/fakeemby -addr 127.0.0.1:8096
package main

import (
	"encoding/json"
	"flag"
	"fmt"
	"log"
	"net/http"
	"strings"
)

func main() {
	addr := flag.String("addr", "127.0.0.1:8096", "监听地址")
	flag.Parse()

	mux := http.NewServeMux()

	// 探测(登录前,「测试连接」用)
	mux.HandleFunc("/System/Info/Public", func(w http.ResponseWriter, r *http.Request) {
		writeJSON(w, map[string]any{"ServerName": "自检用假服务器", "Version": "4.9.5", "Id": "fake-1"})
	})

	// 登录
	mux.HandleFunc("/Users/AuthenticateByName", func(w http.ResponseWriter, r *http.Request) {
		writeJSON(w, map[string]any{
			"AccessToken": "fake-token",
			"User":        map[string]any{"Id": "u1", "Name": "自检用户"},
		})
	})

	// 媒体库 / 继续观看 / 最新 / 列表 —— 都挂在 /Users/{id}/... 下
	mux.HandleFunc("/Users/", func(w http.ResponseWriter, r *http.Request) {
		p := r.URL.Path
		switch {
		case strings.HasSuffix(p, "/Views"):
			writeJSON(w, page(
				item("lib-movie", "电影", "CollectionFolder"),
				item("lib-tv", "剧集", "CollectionFolder"),
				item("lib-anime", "番剧", "CollectionFolder"),
			))
		case strings.HasSuffix(p, "/Items/Resume"):
			ep := item("ep-1", "第 3 集", "Episode")
			ep["SeriesName"] = "某部剧"
			ep["SeriesId"] = "s1"
			ep["IndexNumber"] = 3
			ep["ParentIndexNumber"] = 1
			ep["RunTimeTicks"] = 14000000000
			ep["UserData"] = map[string]any{"PlaybackPositionTicks": 5000000000}
			mv := item("mv-1", "某部电影", "Movie")
			mv["RunTimeTicks"] = 72000000000
			mv["UserData"] = map[string]any{"PlaybackPositionTicks": 12000000000}
			writeJSON(w, page(ep, mv))
		case strings.HasSuffix(p, "/Items/Latest"):
			// ★ Latest 是**裸数组**,不是 {Items:[]} —— 真 Emby 就是这么回的
			writeJSONRaw(w, []any{
				item("new-1", "刚入库的电影", "Movie"),
				item("new-2", "刚入库的剧", "Series"),
				item("new-3", "另一部新片", "Movie"),
			})
		case strings.HasSuffix(p, "/Items/Counts"):
			writeJSON(w, map[string]any{
				"MovieCount": 128, "SeriesCount": 42, "EpisodeCount": 1580, "BoxSetCount": 6,
			})
		case strings.Contains(p, "/Items"):
			writeJSON(w, page(
				item("m1", "库里的第一部", "Movie"),
				item("m2", "库里的第二部", "Movie"),
			))
		default:
			// /Users/{id} —— 管理员位
			writeJSON(w, map[string]any{"Id": "u1", "Name": "自检用户",
				"Policy": map[string]any{"IsAdministrator": true}})
		}
	})

	log.Printf("假 Emby 起在 http://%s", *addr)
	if err := http.ListenAndServe(*addr, logged(mux)); err != nil {
		log.Fatal(err)
	}
}

func logged(h http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		fmt.Printf("  <- %s %s\n", r.Method, r.URL.RequestURI())
		h.ServeHTTP(w, r)
	})
}

func item(id, name, typ string) map[string]any {
	return map[string]any{
		"Id": id, "Name": name, "Type": typ,
		"IsFolder":  typ == "CollectionFolder" || typ == "Series",
		"ImageTags": map[string]any{"Primary": "tag-" + id},
	}
}

func page(items ...map[string]any) map[string]any {
	return map[string]any{"Items": items, "TotalRecordCount": len(items)}
}

func writeJSON(w http.ResponseWriter, v any) { writeJSONRaw(w, v) }

func writeJSONRaw(w http.ResponseWriter, v any) {
	w.Header().Set("Content-Type", "application/json")
	_ = json.NewEncoder(w).Encode(v)
}
