// fakeemby 是一台**假 Emby**,给 Windows 端做真机自检用。
//
// 为什么要它:真机自检不能依赖真服务器 ——
//
//	· 真服务器的地址和账号是红线,不能进仓库
//	· 网络一抖自检就红,那种门禁没人信
//	· 有些形状(空库 / 404 的统计端点 / 慢链路)在真服务器上根本造不出来
//
// 它只实现 UI 主链路真正会打的那几个端点,回的字段名与真 Emby 一致。
//
//	go run ./tools/fakeemby -addr 127.0.0.1:8096
package main

import (
	"compress/gzip"
	"crypto/rand"
	"crypto/rsa"
	"crypto/x509"
	"crypto/x509/pkix"
	"encoding/json"
	"encoding/pem"
	"flag"
	"fmt"
	"image"
	"image/color"
	"image/draw"
	"image/png"
	"log"
	"math/big"
	"net"
	"net/http"
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"sync"
	"time"
)

// clip 起播时真正吐出去的文件。空 = 播放自检跳过。
var clip *string

// reject 登录一律回 401。
var reject *bool

// useTLS 用自签名证书起 https。
var useTLS *bool

// useGzip JSON 响应压缩。
var useGzip *bool

func main() {
	addr := flag.String("addr", "127.0.0.1:8096", "监听地址")
	clip = flag.String("clip", "", "起播时回放的本地视频文件")
	reject = flag.Bool("reject", false, "登录一律回 401(验错误提示用)")
	useTLS = flag.Bool("tls", false, "用自签名证书起 https")
	useGzip = flag.Bool("gzip", false, "JSON 响应用 gzip 压缩(真 Emby 默认就是压的)")
	flag.Parse()

	mux := http.NewServeMux()

	/* ---- 排行榜的两个上游(弹弹Play / TMDB)----

	   ★★ 为什么假 Emby 要管排行榜:排行榜**有凭据时长什么样**,单测验不到 ——
	   凭据是编译期注入的,而页面渲染只有真 exe 跑起来才现形。
	   本仓库已经栽过两次「预置形状 ≠ 真实形状」(自检永远灌配置没走过真登录 /
	   假服务器不开 gzip 让 Go 不解压那个洞本地全绿),所以这条路要能端到端走一遍。

	   核心层那边靠 LP_RANKING_BASE_DANDAN / LP_RANKING_BASE_TMDB 指过来。 */
	mux.HandleFunc("/api/v2/trending/", func(w http.ResponseWriter, r *http.Request) {
		// ★ 顺带把签名头验了:三个头缺一个都说明命令层漏了东西
		for _, h := range []string{"X-AppId", "X-Timestamp", "X-Signature"} {
			if r.Header.Get(h) == "" {
				writeJSON(w, map[string]any{"success": false, "errorCode": 400,
					"errorMessage": "缺少签名头 " + h})
				return
			}
		}
		list := []map[string]any{}
		for i := 1; i <= 12; i++ {
			list = append(list, map[string]any{
				"animeId": i, "animeTitle": fmt.Sprintf("假榜番剧 %d", i),
				"imageUrl":        fmt.Sprintf("http://%s/rankimg/anime-%d.png", r.Host, i),
				"rating":          9.5 - float64(i)/10,
				"typeDescription": "TV 动画", "isFavorited": i%3 == 0,
			})
		}
		writeJSON(w, map[string]any{"success": true, "bangumiList": list})
	})
	/* 假的图标聚合源(自检用)。核心层靠 LP_ICON_LIBRARY_SOURCES 指过来。
	   ★ 夹具里要带上**会出事的那两种条目**:空 url 和非 http 的 url ——
	     不带的话「丢掉坏条目」那条判据在真渲染里根本走不到。 */
	mux.HandleFunc("/icons.json", func(w http.ResponseWriter, r *http.Request) {
		icons := []any{
			map[string]any{"name": "", "url": ""},              // 空的:要被丢掉
			map[string]any{"name": "坏协议", "url": "ftp://x/y.png"}, // 非 http:要被丢掉
		}
		for i := 1; i <= 24; i++ {
			icons = append(icons, map[string]any{
				"name": fmt.Sprintf("假图标 %02d", i),
				"url":  fmt.Sprintf("http://%s/rankimg/icon-%d.png", r.Host, i),
			})
		}
		writeJSON(w, map[string]any{"name": "自检图标库", "description": "", "icons": icons})
	})

	/* 假的插件源 registry(自检用)。核心层靠 LP_PLUGIN_OFFICIAL_REGISTRY 指过来。
	   ★ 夹具要带上**会出事的那几种条目**,不然对应的 UI 判据在真渲染里走不到:
	     · 一条 v1 schema(author 是对象)—— 它必须被跳过,而且「跳了几条」要报出来
	     · 版本数组**故意乱序且 1.10 在 1.9 前面** —— 卡片必须显示 1.10.0
	       (照数组第一个取的话显示 1.2.0,而装下去是另一版)
	     · 一条 apiVersion=3 的高版本 —— 宿主装不了,要回退到能装的那版
	     · 权限里带危险权限 —— 授权弹窗的 ⚠ 那一支才有东西可画 */
	mux.HandleFunc("/plugins/registry.json", func(w http.ResponseWriter, r *http.Request) {
		ver := func(v string, api int) map[string]any {
			return map[string]any{
				"version": v, "api_version": api,
				"package_url": fmt.Sprintf("http://%s/plugins/pkg-%s.ipk", r.Host, v),
			}
		}
		writeJSON(w, map[string]any{"plugins": []any{
			map[string]any{
				"id": "com.fake.source", "name": "假网盘源", "author": "自检",
				"description": "贡献一个数据源,用来验「添加服务器」里能不能看到插件源。",
				"category":    "source",
				"permissions": []string{"sources", "http", "storage"},
				"versions":    []any{ver("1.2.0", 2), ver("1.10.0", 2), ver("1.9.0", 2), ver("2.0.0", 3)},
			},
			map[string]any{
				"id": "com.fake.tools", "name": "假工具", "author": "自检",
				"description": "只申请了界面权限的插件。", "category": "tools",
				"permissions": []string{"ui", "extensions"},
				"versions":    []any{ver("0.1.0", 2)},
			},
			// v1 schema:author 是对象。**必须被跳过**,而且跳过数要能报出来
			map[string]any{
				"id": "com.fake.v1", "name": "老插件",
				"author":   map[string]any{"name": "谁"},
				"versions": []any{ver("1.0.0", 2)},
			},
		}})
	})

	/* 假的 Bangumi 放送表(自检用)。核心层靠 LP_BANGUMI_API 指过来。
	   ★ 夹具要带上**真实形状里那些会出事的东西**:0 分的条目、只有原名的条目、
	     协议相对的图片地址 —— 缺一样,对应那条 UI 判据就验不到。 */
	mux.HandleFunc("/calendar", func(w http.ResponseWriter, r *http.Request) {
		groups := []any{}
		names := []string{"假番一号", "假番二号", "假番三号", "假番四号", "假番五号", "假番六号", "假番七号"}
		for wd := 1; wd <= 7; wd++ {
			items := []any{}
			for i := 0; i <= wd%3; i++ {
				it := map[string]any{
					"id":       wd*10 + i,
					"name":     fmt.Sprintf("Fake Anime %d-%d", wd, i),
					"name_cn":  fmt.Sprintf("%s · 第%d部", names[wd-1], i+1),
					"air_date": "2026-07-06",
					"images": map[string]any{
						"large": fmt.Sprintf("http://%s/rankimg/bgm-%d-%d.png", r.Host, wd, i),
					},
				}
				// 一半有评分、一半 0 分(0 分不许画出来)
				if i == 0 {
					it["rating"] = map[string]any{"score": 8.0 + float64(wd)/10}
				} else {
					it["rating"] = map[string]any{"score": 0}
				}
				items = append(items, it)
			}
			groups = append(groups, map[string]any{
				"weekday": map[string]any{"id": wd},
				"items":   items,
			})
		}
		writeJSON(w, groups)
	})

	mux.HandleFunc("/trending/", tmdbList)
	mux.HandleFunc("/movie/", tmdbList)
	mux.HandleFunc("/tv/", tmdbList)
	// 榜单封面:和 Emby 的封面不同源,走的是**静态白名单**那条路
	mux.HandleFunc("/rankimg/", func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "image/png")
		_ = png.Encode(w, solid(strings.TrimPrefix(r.URL.Path, "/rankimg/")))
	})

	// 探测(登录前,「测试连接」用)
	mux.HandleFunc("/System/Info/Public", func(w http.ResponseWriter, r *http.Request) {
		writeJSON(w, map[string]any{"ServerName": "自检用假服务器", "Version": "4.9.5", "Id": "fake-1"})
	})

	// 登录。★ -reject 让它回 401,用来验「密码不对」显示成什么 ——
	// 这条路曾经显示成「网络不通,可以重试」,用户明明有网。
	mux.HandleFunc("/Users/AuthenticateByName", func(w http.ResponseWriter, r *http.Request) {
		if *reject {
			w.WriteHeader(http.StatusUnauthorized)
			return
		}
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
		// 剧的分集:/Users/{uid}/Items?ParentId=s1&IncludeItemTypes=Episode
		case strings.Contains(p, "/Items") && r.URL.Query().Get("IncludeItemTypes") == "Episode":
			eps := []map[string]any{}
			for i := 1; i <= 12; i++ {
				e := item(fmt.Sprintf("s1e%d", i), fmt.Sprintf("第 %d 集", i), "Episode")
				e["SeriesName"] = "某部剧"
				e["SeriesId"] = "s1"
				e["IndexNumber"] = i
				e["ParentIndexNumber"] = 1
				e["RunTimeTicks"] = 14000000000
				eps = append(eps, e)
			}
			writeJSON(w, page(eps...))

		// 详情:/Users/{uid}/Items/{itemId}(尾段是具体 id,不是 Resume/Latest/Counts)
		case detailID(p) != "":
			id := detailID(p)
			/* p* 是人物。★ 故意让 p1 有生平和出生地、p2 **什么都没有** ——
			   「生卒 / 出生地空是常态」是真实形状,人物页不许因此留一片空白。 */
			if strings.HasPrefix(id, "p") {
				d := item(id, "某演员", "Person")
				if id == "p1" {
					d["Overview"] = "自检用的人物生平。"
					d["PremiereDate"] = "1980-03-15T00:00:00.0000000Z"
					d["ProductionLocations"] = []string{"某地"}
				} else {
					d["Name"] = "某导演"
					// ★ 空数组元素:有的刮削器就这么写,出生地要被滤掉而不是显示成空
					d["ProductionLocations"] = []string{""}
				}
				writeJSON(w, d)
				return
			}
			// s1 是剧,其余当电影 —— 详情页对这两种是**两张不同的版式**
			if id == "s1" {
				d := item("s1", "某部剧", "Series")
				d["Overview"] = "自检用剧集简介。"
				d["ProductionYear"] = 2023
				d["Status"] = "Continuing"
				d["ChildCount"] = 12
				d["UserData"] = map[string]any{"IsFavorite": true}
				writeJSON(w, d)
				return
			}
			d := item(id, "某部电影", "Movie")
			d["Overview"] = "自检用简介。这一段是拿来验「有值就画、没值不留空位」的。"
			d["ProductionYear"] = 2024
			d["Genres"] = []string{"剧情", "科幻"}
			d["CommunityRating"] = 8.4
			d["RunTimeTicks"] = 72000000000
			d["OfficialRating"] = "PG-13"
			d["Taglines"] = []string{"一句自检用的标语"}
			d["UserData"] = map[string]any{"PlaybackPositionTicks": 12000000000, "IsFavorite": false}
			d["People"] = []any{
				map[string]any{"Id": "p1", "Name": "某演员", "Role": "主角", "Type": "Actor",
					"PrimaryImageTag": "tag-p1"},
				map[string]any{"Id": "p2", "Name": "某导演", "Type": "Director"},
			}
			writeJSON(w, d)

		case strings.Contains(p, "/Items"):
			// ★ 给 140 条,超过一页(60)—— 只给两条的话「滚到底翻页」永远没被跑过
			q := r.URL.Query()
			start := atoi(q.Get("StartIndex"))
			limit := atoi(q.Get("Limit"))
			if limit <= 0 {
				limit = 60
			}
			const total = 140
			items := []map[string]any{}
			for i := start; i < start+limit && i < total; i++ {
				it := item(fmt.Sprintf("m%d", i+1), fmt.Sprintf("库里的第 %d 部", i+1), "Movie")
				it["ProductionYear"] = 2000 + i%25
				it["Genres"] = []string{[]string{"剧情", "科幻", "喜剧"}[i%3]}
				items = append(items, it)
			}
			writeJSONRaw(w, map[string]any{"Items": items, "TotalRecordCount": total})
		default:
			// /Users/{id} —— 管理员位
			writeJSON(w, map[string]any{"Id": "u1", "Name": "自检用户",
				"Policy": map[string]any{"IsAdministrator": true}})
		}
	})

	// 图片:/Items/{id}/Images/{kind}
	//
	// ★ 生成的是**每个 id 一种颜色**的纯色图 —— 截图里一眼就能分辨
	//   「封面加载出来了」和「三张卡都是同一个占位」。
	mux.HandleFunc("/Items/", func(w http.ResponseWriter, r *http.Request) {
		parts := strings.Split(strings.Trim(r.URL.Path, "/"), "/")
		switch {
		case len(parts) >= 3 && parts[2] == "Images":
			w.Header().Set("Content-Type", "image/png")
			_ = png.Encode(w, solid(parts[1]))

		// 起播:PlaybackInfo → DirectStreamUrl。
		//
		// ★ DirectStreamUrl 故意给**相对路径** —— 真 Emby 就是这么回的,
		//   而「把相对路径拼在服务器根上」正是 Range 前缀那个坑的源头。
		case len(parts) >= 3 && parts[2] == "PlaybackInfo":
			id := parts[1]
			writeJSON(w, map[string]any{
				"PlaySessionId": "ps-selfcheck",
				"MediaSources": []any{map[string]any{
					"Id": "ms-1", "Name": "1080p", "Container": "mp4",
					"SupportsDirectStream": true,
					"DirectStreamUrl":      "/Videos/" + id + "/stream.mp4?static=true&mediaSourceId=ms-1",
					"MediaStreams": []any{
						map[string]any{"Type": "Video", "Codec": "h264", "Height": 1080, "Index": 0},
						map[string]any{"Type": "Audio", "Codec": "aac", "Language": "jpn", "Index": 1},
					},
				}},
			})

		/* 下载:/Items/{id}/Download。支持 Range,回可预测内容(第 i 字节 = i%251)。
		   ★ 真 Emby 这条路由由**服务端按下载权限**放行,客户端不预判。
		     所以假服务器也照放 —— 要验「没权限」那条,用 -reject。 */
		case len(parts) >= 3 && parts[2] == "Download":
			const size = 3 * 1024 * 1024
			if *reject {
				w.WriteHeader(http.StatusForbidden)
				return
			}
			start, end := int64(0), int64(size-1)
			w.Header().Set("Accept-Ranges", "bytes")
			if rg := r.Header.Get("Range"); strings.HasPrefix(rg, "bytes=") {
				p := strings.SplitN(strings.TrimPrefix(rg, "bytes="), "-", 2)
				start, _ = strconv.ParseInt(p[0], 10, 64)
				if len(p) > 1 && p[1] != "" {
					end, _ = strconv.ParseInt(p[1], 10, 64)
				}
				if end > size-1 {
					end = size - 1
				}
				w.Header().Set("Content-Range", fmt.Sprintf("bytes %d-%d/%d", start, end, size))
				w.Header().Set("Content-Length", strconv.FormatInt(end-start+1, 10))
				w.WriteHeader(http.StatusPartialContent)
			} else {
				w.Header().Set("Content-Length", strconv.FormatInt(size, 10))
			}
			buf := make([]byte, end-start+1)
			for i := range buf {
				buf[i] = byte((start + int64(i)) % 251)
			}
			_, _ = w.Write(buf)

		// 详情:/Items/{id} 直接位(不带 /Users/ 前缀的那条 UI 不走,留着兜底)
		default:
			http.NotFound(w, r)
		}
	})

	// 分面(筛选面板)。★ 真 Emby 是 /Genres /Tags /Studios /OfficialRatings 四个独立端点。
	for _, ep := range []string{"/Genres", "/Tags", "/Studios", "/OfficialRatings"} {
		names := map[string][]string{
			"/Genres":  {"剧情", "科幻", "喜剧"},
			"/Tags":    {"自检"},
			"/Studios": {},
			// ★ 故意给空:「某个分面一个取值都没有」是真实形状,前端不许因此报错
			"/OfficialRatings": {},
		}[ep]
		mux.HandleFunc(ep, func(w http.ResponseWriter, r *http.Request) {
			out := []any{}
			for _, n := range names {
				out = append(out, map[string]any{"Name": n})
			}
			writeJSON(w, map[string]any{"Items": out})
		})
	}

	// 全库规模。★ 真 Emby 是 **/Items/Counts**(根路径),不在 /Users/{id} 下 ——
	// 聚合视界打的就是这条。挂错地方的表现是「这台服务器没有提供规模统计」,
	// 而那恰好和某些 fork 真的没有这个端点长得一模一样。
	mux.HandleFunc("/Items/Counts", func(w http.ResponseWriter, r *http.Request) {
		writeJSON(w, map[string]any{
			"MovieCount": 128, "SeriesCount": 42, "EpisodeCount": 1580, "BoxSetCount": 6,
		})
	})

	// 接着看下一集。★ 真 Emby 挂在 /Shows/NextUp,不在 /Users/{id} 下面。
	mux.HandleFunc("/Shows/NextUp", func(w http.ResponseWriter, r *http.Request) {
		ep := item("ep-2", "第 4 集", "Episode")
		ep["SeriesName"] = "某部剧"
		ep["SeriesId"] = "s1"
		ep["IndexNumber"] = 4
		ep["RunTimeTicks"] = 14000000000
		writeJSON(w, page(ep))
	})

	// 视频流。★ 必须支持 Range —— http.ServeFile 自带。
	// 不支持的话核心层的 `bytes=0-0` 探测会选错前缀,而表现是「跳到没缓冲的位置就卡死」。
	mux.HandleFunc("/Videos/", func(w http.ResponseWriter, r *http.Request) {
		if *clip == "" {
			http.Error(w, "自检没带 -clip,没有可播的文件", http.StatusNotFound)
			return
		}
		http.ServeFile(w, r, *clip)
	})

	// 播放上报。★ 三件套都得回 2xx:回错的话核心层会当成上报失败,
	// 而「看一半退出续播不落地」正是这条链断掉的表现。
	mux.HandleFunc("/Sessions/", func(w http.ResponseWriter, r *http.Request) {
		w.WriteHeader(http.StatusNoContent)
	})

	// -tls:用自签名证书起 https。验「允许自签名」那条开关用 ——
	// 自建 Emby 用自签名证书很常见,而这条路以前报的是一句看不懂的 x509 英文。
	if *useTLS {
		log.Printf("假 Emby(自签名 https)起在 https://%s", *addr)
		if err := http.ListenAndServeTLS(*addr, certFile(), keyFile(), logged(mux)); err != nil {
			log.Fatal(err)
		}
		return
	}
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

// solid 按 id 摊出一种颜色,同 id 必得同色。
func solid(id string) image.Image {
	var h uint32 = 2166136261
	for _, c := range []byte(id) {
		h = (h ^ uint32(c)) * 16777619
	}
	img := image.NewRGBA(image.Rect(0, 0, 64, 96))
	c := color.RGBA{uint8(h>>16)/2 + 60, uint8(h>>8)/2 + 60, uint8(h)/2 + 60, 255}
	draw.Draw(img, img.Bounds(), &image.Uniform{c}, image.Point{}, draw.Src)
	return img
}

func item(id, name, typ string) map[string]any {
	return map[string]any{
		"Id": id, "Name": name, "Type": typ,
		"IsFolder":  typ == "CollectionFolder" || typ == "Series",
		"ImageTags": map[string]any{"Primary": "tag-" + id},
	}
}

// detailID 从 /Users/{uid}/Items/{itemId} 里取条目 id。
// 尾段是列表名(Resume / Latest / Counts)或路径不是这个形状时返回空串。
func detailID(path string) string {
	parts := strings.Split(strings.Trim(path, "/"), "/")
	if len(parts) != 4 || parts[0] != "Users" || parts[2] != "Items" {
		return ""
	}
	switch parts[3] {
	case "Resume", "Latest", "Counts", "":
		return ""
	}
	return parts[3]
}

func atoi(s string) int {
	n, _ := strconv.Atoi(s)
	return n
}

func page(items ...map[string]any) map[string]any {
	return map[string]any{"Items": items, "TotalRecordCount": len(items)}
}

func writeJSON(w http.ResponseWriter, v any) { writeJSONRaw(w, v) }

// writeJSONRaw 回 JSON。★ -gzip 时**压缩后再回**。
//
// 真 Emby 默认开压缩,而假 Emby 一开始不压 —— 于是
// 「手动设了 Accept-Encoding 导致 Go 不再自动解压」这个洞本地全绿,
// 只有拿真服务器打才现形(2026-08-31 用户实测)。
// 把这个形状造进来:**假服务器只能造出你想到的形状,想到了就得造**。
func writeJSONRaw(w http.ResponseWriter, v any) {
	w.Header().Set("Content-Type", "application/json")
	if !*useGzip {
		_ = json.NewEncoder(w).Encode(v)
		return
	}
	w.Header().Set("Content-Encoding", "gzip")
	zw := gzip.NewWriter(w)
	defer zw.Close()
	_ = json.NewEncoder(zw).Encode(v)
}

// certFile / keyFile 现生成一张自签名证书,落到临时目录。
//
// ★ 证书**不进仓库**:仓库里放私钥是红线,而且每次现生成也省得管过期。
func certFile() string { ensureCert(); return certPath }
func keyFile() string  { ensureCert(); return keyPath }

var (
	certPath, keyPath string
	certOnce          sync.Once
)

func ensureCert() {
	certOnce.Do(func() {
		key, err := rsa.GenerateKey(rand.Reader, 2048)
		if err != nil {
			log.Fatal(err)
		}
		tpl := x509.Certificate{
			SerialNumber: big.NewInt(1),
			Subject:      pkix.Name{CommonName: "linplayer-selfcheck"},
			NotBefore:    time.Now().Add(-time.Hour),
			NotAfter:     time.Now().Add(24 * time.Hour),
			IPAddresses:  []net.IP{net.ParseIP("127.0.0.1")},
			DNSNames:     []string{"localhost"},
			KeyUsage:     x509.KeyUsageKeyEncipherment | x509.KeyUsageDigitalSignature,
			ExtKeyUsage:  []x509.ExtKeyUsage{x509.ExtKeyUsageServerAuth},
		}
		der, err := x509.CreateCertificate(rand.Reader, &tpl, &tpl, &key.PublicKey, key)
		if err != nil {
			log.Fatal(err)
		}
		dir, err := os.MkdirTemp("", "fakeemby-cert")
		if err != nil {
			log.Fatal(err)
		}
		certPath = filepath.Join(dir, "cert.pem")
		keyPath = filepath.Join(dir, "key.pem")
		writePem(certPath, "CERTIFICATE", der)
		writePem(keyPath, "RSA PRIVATE KEY", x509.MarshalPKCS1PrivateKey(key))
	})
}

func writePem(path, typ string, der []byte) {
	f, err := os.Create(path)
	if err != nil {
		log.Fatal(err)
	}
	defer f.Close()
	if err := pem.Encode(f, &pem.Block{Type: typ, Bytes: der}); err != nil {
		log.Fatal(err)
	}
}

// tmdbList 假的 TMDB 榜。★ 故意让 id 一半是数字一半是字符串 ——
// 真 TMDB 给数字,但我们的解析要两种都吃得下(移植时这里错过一次)。
func tmdbList(w http.ResponseWriter, r *http.Request) {
	kind := "movie"
	if strings.Contains(r.URL.Path, "/tv") {
		kind = "tv"
	}
	out := []map[string]any{}
	for i := 1; i <= 12; i++ {
		m := map[string]any{
			"poster_path":  fmt.Sprintf("/rankimg/%s-%d.png", kind, i),
			"vote_average": 8.8 - float64(i)/10,
		}
		if i%2 == 0 {
			m["id"] = i
		} else {
			m["id"] = fmt.Sprintf("%d", i)
		}
		if kind == "tv" {
			m["name"] = fmt.Sprintf("假榜剧集 %d", i)
			m["first_air_date"] = "2023-09-01"
		} else {
			m["title"] = fmt.Sprintf("假榜电影 %d", i)
			m["release_date"] = "2024-05-01"
		}
		out = append(out, m)
	}
	writeJSON(w, map[string]any{"page": 1, "results": out})
}
