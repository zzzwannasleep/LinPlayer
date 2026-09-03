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

// noAvatar 用户头像回 404 —— 验「图标回退到官方那条」。
var noAvatar *bool

// eps1 第 1 季的集数。验「上千集不卡死」时调大。
var eps1 *int

/*
★★ 「这台服务器一个合集都没有」。**没有这个开关的话,合集栏那条

	「没有就整条不画」的规则永远走不到** —— 假服务器只造得出「有 4 个合集」
	一种形状,而 bug 恰恰藏在另一种形状里。
*/
var noBoxset *bool

/*
★★ 「服务器只肯给转码地址」。用户 2026-09-03 定了不做转码流,

	而这条路上真正会坏的是**后果**:落到转码流上就没有本地字节,
	预热 / 多线程加载 / 缩略图一起哑掉,还一条错都不报。
	造得出这个形状,才验得了「就算服务器只给转码地址,我们照样直连、照样有缩略图」。
*/
var transcodeOnly *bool

/*
☠☠ **片长必须和 -clip 那个文件一致**。

	夹具原来给电影写死 7200 秒,而真正吐出去的片子是 1800 秒 ——
	于是**一切按百分比算的功能都在对着一个假数验**:
	观看阈值(1200s 到底是 16.7% 还是 66.7%?)、进度条、片头片尾跳过。
	2026-09-03 就是这么白跑了一轮:阈值设 60% 明明该越线,自检说没越。
	假服务器可以造假东西,但**同一件事不能造两个互相矛盾的数**。
*/
var clipSecs *float64

// clipKBps 视频流限速(KB/s)。0 = 不限。理由见 throttled。
var clipKBps *int

func main() {
	addr := flag.String("addr", "127.0.0.1:8096", "监听地址")
	clip = flag.String("clip", "", "起播时回放的本地视频文件")
	reject = flag.Bool("reject", false, "登录一律回 401(验错误提示用)")
	useTLS = flag.Bool("tls", false, "用自签名证书起 https")
	useGzip = flag.Bool("gzip", false, "JSON 响应用 gzip 压缩(真 Emby 默认就是压的)")
	// ★ 验「头像被删了要退回官方图标」那条路。不给开关的话它永远走不到。
	noAvatar = flag.Bool("no-avatar", false, "用户头像回 404(验图标回退官方那条)")
	/* ★★ 第 1 季有多少集。默认 12,自检验「上千集不卡死」时调到 1200。
	   用户 2026-09-03:「遇到那些上千集的不一下子卡死了」——
	   而假服务器只造得出 12 集的话,虚拟化有没有生效**根本量不出来**:
	   12 张卡不虚拟化也照样流畅。假服务器只能造出你想到的形状,想到了就得造。 */
	eps1 = flag.Int("eps", 12, "第 1 季的集数(验虚拟化时调大)")
	noBoxset = flag.Bool("no-boxset", false, "一个合集都没有(验首页合集栏整条不画)")
	transcodeOnly = flag.Bool("transcode-only", false, "只给 TranscodingUrl(验我们照样不走转码)")
	clipSecs = flag.Float64("clip-secs", 0, "-clip 那个文件的真实时长(秒)。0 = 用写死的假片长")
	clipKBps = flag.Int("clip-kbps", 0, "视频流限速 KB/s(0=不限)。环回不限速会让「已缓存/没缓存」这个对比组造不出来")
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
			map[string]any{"name": "", "url": ""},                 // 空的:要被丢掉
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
		_ = png.Encode(w, solid(strings.TrimPrefix(r.URL.Path, "/rankimg/"), false))
	})

	/* 服务器图标的两条路(用户 2026-09-03 点名的那两种)。
	   ★★ 两条都得有,而且**颜色要不一样** ——
	     只有颜色不同,截图上才分得清 UI 到底走的是哪一条;
	     两条画成一样的话,「头像挂了自动退官方图标」这件事永远验不了。 */
	mux.HandleFunc("/Users/u1/Images/Primary", func(w http.ResponseWriter, r *http.Request) {
		if *noAvatar {
			// -no-avatar:模拟「用户把头像删了」,验核心层会不会接着试官方那条
			w.WriteHeader(http.StatusNotFound)
			return
		}
		w.Header().Set("Content-Type", "image/png")
		_ = png.Encode(w, solid("avatar", false))
	})
	mux.HandleFunc("/web/touchicon.png", func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "image/png")
		_ = png.Encode(w, solid("touchicon", false))
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
			// ★ PrimaryImageTag 必须给:核心层拿它拼服务器图标地址
			//   (serverbatch.BuildIconURL)。不给的话直接退官方图标那条,
			//   于是「从用户头像取图标」这条路在自检里一次都跑不到。
			"User": map[string]any{"Id": "u1", "Name": "自检用户", "PrimaryImageTag": "tag1"},
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
			ep["RunTimeTicks"] = runtimeTicks(14000000000)
			ep["UserData"] = map[string]any{"PlaybackPositionTicks": 5000000000}
			mv := item("mv-1", "某部电影", "Movie")
			mv["RunTimeTicks"] = runtimeTicks(72000000000)
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
		/* 收藏:/Users/{uid}/Items?Filters=IsFavorite
		   ★★ 必须是**混着的**:电影 + 剧 + 分集。原来这条请求掉进通用列表分支,
		     回来清一色的电影 —— 于是「分集单独一栏横版」这条在自检里
		     <b>永远走不到</b>,而它绿不绿全看夹具有没有分集。假绿五类里的「夹具不真实」。 */
		case r.URL.Query().Get("Filters") == "IsFavorite":
			favs := []map[string]any{
				item("mv-1", "某部电影", "Movie"),
				item("mv-2", "另一部电影", "Movie"),
				item("s1", "某部剧", "Series"),
			}
			for i := 1; i <= 3; i++ {
				e := item(fmt.Sprintf("s1e%d", i), fmt.Sprintf("第 %d 集", i), "Episode")
				e["SeriesName"] = "某部剧"
				e["SeriesId"] = "s1"
				e["IndexNumber"] = i
				e["ParentIndexNumber"] = 1
				e["RunTimeTicks"] = runtimeTicks(14000000000)
				favs = append(favs, e)
			}
			writeJSON(w, page(favs...))

		/* 合集:/Users/{uid}/Items?IncludeItemTypes=BoxSet
		   ★★ 夹具原来没有这个形状,请求打过来会掉进下面某个兜底分支 ——
		     于是「合集」这条轨道**永远是空的**,而空态和「这台服务器没有合集」
		     长得一模一样。核心层的 emby.listCollections 早就在,
		     UI 一次没调过(第五次撞上「后端领先前端」)。 */
		case strings.Contains(p, "/Items") && r.URL.Query().Get("IncludeItemTypes") == "BoxSet":
			sets := []map[string]any{}
			n := 4
			if *noBoxset {
				n = 0 // ★ 空表,不是 404 —— 真 Emby 上「没有合集」就是回一个空 Items
			}
			for i := 1; i <= n; i++ {
				b := item(fmt.Sprintf("bs-%d", i), fmt.Sprintf("自检合集 %d", i), "BoxSet")
				b["ChildCount"] = i * 3
				sets = append(sets, b)
			}
			writeJSON(w, page(sets...))

		// 剧的分集:/Users/{uid}/Items?ParentId=s1&IncludeItemTypes=Episode
		case strings.Contains(p, "/Items") && r.URL.Query().Get("IncludeItemTypes") == "Episode":
			/* ★★ **两季**,不是一季。
			   只造一季的话「按季分组」这个功能在自检里永远看不出对错 ——
			   分组代码就算把季号写死成 1 也照样绿。假服务器只能造出你想到的形状,
			   想到了就得造(2026-09-02 做季分组时补的)。 */
			eps := []map[string]any{}
			for _, sea := range []struct{ No, Count int }{{1, *eps1}, {2, 8}} {
				for i := 1; i <= sea.Count; i++ {
					e := item(fmt.Sprintf("s%de%d", sea.No, i),
						fmt.Sprintf("第 %d 集", i), "Episode")
					e["SeriesName"] = "某部剧"
					e["SeriesId"] = "s1"
					e["IndexNumber"] = i
					e["ParentIndexNumber"] = sea.No
					e["RunTimeTicks"] = runtimeTicks(14000000000)
					// 第 1 季前两集已看,第 3 集看了一半 —— 「继续观看 · 第 3 集」
					// 挑集顺序要有真实数据才验得到。
					switch {
					case sea.No == 1 && i <= 2:
						e["UserData"] = map[string]any{"Played": true}
					case sea.No == 1 && i == 3:
						e["UserData"] = map[string]any{"PlaybackPositionTicks": 5000000000}
					}
					eps = append(eps, e)
				}
			}
			writeJSON(w, page(eps...))

		/* 搜索:/Users/{uid}/Items?SearchTerm=…
		   ★★ **真的按词过滤**,不是回一把固定结果。
		     不过滤的话「搜不到」那半永远出不来 —— 而空结果页恰恰是最容易
		     做成一片黑的那一页。想验它,假服务器就得有能搜不到的输入。 */
		case r.URL.Query().Get("SearchTerm") != "":
			term := r.URL.Query().Get("SearchTerm")
			catalog := []struct{ ID, Name, Type string }{
				{"mv-1", "某部电影", "Movie"},
				{"s1", "某部剧", "Series"},
				{"mv-2", "另一部电影", "Movie"},
				{"s1e3", "某部剧 第 3 集", "Episode"},
			}
			hits := []map[string]any{}
			for _, e := range catalog {
				if !strings.Contains(e.Name, term) {
					continue
				}
				// ★ 关着「包括分集」时前端会传 IncludeItemTypes=Movie,Series —— 要认。
				if it := r.URL.Query().Get("IncludeItemTypes"); it != "" &&
					!strings.Contains(it, e.Type) {
					continue
				}
				hits = append(hits, item(e.ID, e.Name, e.Type))
			}
			writeJSON(w, page(hits...))

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
				d["ChildCount"] = 2 // Series 的 ChildCount 是**季数**,不是集数
				d["Genres"] = []string{"剧情", "悬疑"}
				d["CommunityRating"] = 8.9
				d["BackdropImageTags"] = []string{"tag-s1-bd"}
				d["UserData"] = map[string]any{"IsFavorite": true}
				writeJSON(w, d)
				return
			}
			/* ★★ <b>分集详情是一张不同的页</b>(用户 2026-09-03:
			   「集封面和海报封面/季封面是不一样的,集封面是横着的」)。
			   夹具里所有 id 一律回 Movie 的话,详情页的分集版式**一次都跑不到** ——
			   而那正是这一条要验的东西。假绿五类里的「夹具不真实」。 */
			if strings.HasPrefix(id, "s") && strings.Contains(id, "e") {
				d := item(id, "第 1 集", "Episode")
				d["SeriesName"] = "某部剧"
				d["SeriesId"] = "s1"
				d["IndexNumber"] = 1
				d["ParentIndexNumber"] = 1
				d["Overview"] = "自检用分集简介。"
				d["ProductionYear"] = 2023
				d["RunTimeTicks"] = runtimeTicks(14000000000)
				d["PremiereDate"] = "2023-04-02T00:00:00.0000000Z"
				d["UserData"] = map[string]any{"PlaybackPositionTicks": 5000000000}
				writeJSON(w, d)
				return
			}
			d := item(id, "某部电影", "Movie")
			d["Overview"] = "自检用简介。这一段是拿来验「有值就画、没值不留空位」的。"
			d["ProductionYear"] = 2024
			d["Genres"] = []string{"剧情", "科幻"}
			d["CommunityRating"] = 8.4
			d["RunTimeTicks"] = runtimeTicks(72000000000)
			d["OfficialRating"] = "PG-13"
			d["Taglines"] = []string{"一句自检用的标语"}
			// ★ 背景图挂在 **BackdropImageTags 数组**里,不在 ImageTags 里。
			//   假服务器不造这个形状,详情页的大图就永远验不到。
			d["BackdropImageTags"] = []string{"tag-bd"}
			d["UserData"] = map[string]any{"PlaybackPositionTicks": 12000000000, "IsFavorite": false}
			/* 章节 + 片头片尾。
			   ★★ 不造这个形状的话,播放页的「章节」下拉和「跳过片头」条**一次都不会出现** ——
			     而它们不出现和「这一版没做」长得一模一样。
			   ★ 名字要能被 emby.isIntroName / isOutroName 认出来(片头 / 片尾),
			     而且片头必须落在 runtime 的前 40%、片尾在后 25% —— 否则核心层会判成
			     「误判的正片章节」直接不给区间。这里 runtime 是 7200 秒。 */
			d["Chapters"] = []any{
				map[string]any{"Name": "片头", "StartPositionTicks": int64(0)},
				map[string]any{"Name": "第一章", "StartPositionTicks": int64(90 * 1e7)},
				map[string]any{"Name": "第二章", "StartPositionTicks": int64(2400 * 1e7)},
				map[string]any{"Name": "片尾", "StartPositionTicks": int64(6900 * 1e7)},
				map[string]any{"Name": "预告", "StartPositionTicks": int64(7100 * 1e7)},
			}
			d["People"] = []any{
				map[string]any{"Id": "p1", "Name": "某演员", "Role": "主角", "Type": "Actor",
					"PrimaryImageTag": "tag-p1"},
				map[string]any{"Id": "p2", "Name": "某导演", "Type": "Director"},
			}
			writeJSON(w, d)

		/* 随机推荐(首页 Hero + 「随便看看」共用这一条)。
		   ★★ 必须**单独造**,不能让它落进下面那条 140 部的通用列表 ——
		     通用列表全是 Movie、全都没有评分、名字长度也一样,
		     于是 Hero 上「年份 / 类型 / 评分 / 类型标签」这一行永远长一个样,
		     版式排错了也看不出来。
		   ★ 名字**故意有长有短**:艺术字取不到时要回落成文字标题,
		     一个 30 字的片名会不会撑破两行、会不会顶掉标签行,只有长名字才验得到。 */
		case r.URL.Query().Get("SortBy") == "Random":
			picks := []struct {
				ID, Name, Type string
				Year           int
				Rating         float64
				Genres         []string
			}{
				{"hero-1", "很短的名字", "Movie", 2024, 8.7, []string{"科幻", "冒险"}},
				{"hero-2", "一部名字长得能占满两行还要再多出一截的自检用剧集", "Series", 2021, 9.2, []string{"剧情", "悬疑", "犯罪"}},
				{"hero-3", "没有评分的那一部", "Movie", 1998, 0, []string{"动画"}},
				{"hero-4", "连年份都没有的那一部", "Movie", 0, 7.1, nil},
				{"hero-5", "第五部", "Series", 2019, 6.4, []string{"喜剧"}},
			}
			randItems := []map[string]any{}
			for _, e := range picks {
				it := item(e.ID, e.Name, e.Type)
				if e.Year > 0 {
					it["ProductionYear"] = e.Year
				}
				if e.Rating > 0 {
					it["CommunityRating"] = e.Rating
				}
				if e.Genres != nil {
					it["Genres"] = e.Genres
				}
				it["BackdropImageTags"] = []string{"tag-" + e.ID + "-bd"}
				randItems = append(randItems, it)
			}
			// 剩下的补成普通条目 —— Hero 拿前 5 张,后面的进「随便看看」
			for i := len(randItems); i < atoi(r.URL.Query().Get("Limit")); i++ {
				randItems = append(randItems,
					item(fmt.Sprintf("rnd%d", i), fmt.Sprintf("随便看看第 %d 部", i-4), "Movie"))
			}
			writeJSON(w, page(randItems...))

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
		/* 标记已看 / 取消已看:POST|DELETE /Users/{uid}/PlayedItems/{id}
		   ★★ 必须**单独一条 case**,不能靠下面那个 default 兜。
		     default 对任何路径都回 200 —— 于是「客户端把这条路径拼错了」
		     和「标记成功了」在日志和返回码上完全一样,自检永远绿。
		     形状对不上就该 404,那才是真服务器的行为。 */
		case strings.Contains(p, "/PlayedItems/"):
			writeJSON(w, map[string]any{"Played": r.Method != http.MethodDelete})
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
			kind := ""
			if len(parts) >= 4 {
				kind = parts[3]
			}
			/* ★★ 艺术字(Logo)<b>必须有取不到的那一半</b>。
			   真实的库里大多数剧集根本没刮 Logo,客户端要回落成文字标题 ——
			   而假服务器如果每个 id 都给图,那条回落路径<b>一次都不会被渲染</b>。
			   这里让 id 末位是偶数的条目 404(hero-2 / hero-4 就是),
			   于是一轮轮播里两种版式都会出现。 */
			if strings.HasPrefix(kind, "Logo") {
				if n := parts[1]; len(n) > 0 && (n[len(n)-1]-'0')%2 == 0 {
					http.NotFound(w, r)
					return
				}
				w.Header().Set("Content-Type", "image/png")
				_ = png.Encode(w, wordmark(parts[1]))
				return
			}
			w.Header().Set("Content-Type", "image/png")
			// ★ Backdrop 要出**宽图**(16:9)。都出 2:3 的话详情页的大图
			//   会被 UniformToFill 裁得只剩中间一条,看不出比例对不对。
			_ = png.Encode(w, solid(parts[1], strings.HasPrefix(kind, "Backdrop")))

		// 起播:PlaybackInfo → DirectStreamUrl。
		//
		// ★ DirectStreamUrl 故意给**相对路径** —— 真 Emby 就是这么回的,
		//   而「把相对路径拼在服务器根上」正是 Range 前缀那个坑的源头。
		case len(parts) >= 3 && parts[2] == "PlaybackInfo":
			id := parts[1]
			/* ★★ **两个版本**,不是一个。
			   只造一个的话「多版本选择」这个功能在自检里永远看不出对错 ——
			   代码就算把版本写死成第一条也照样绿(2026-07-30 那次
			   「界面在撒谎:当前版本」就是这么活了几个月的)。
			   ★ 流也要造全:视频 / 音频 / **字幕** / 第二条音轨。
			     只有一条音轨的话「几条音轨」这行永远是 1,数错了也看不出来。 */
			src := func(msid, name, codec string, h int64, size, bitrate int64, extra []any) map[string]any {
				streams := append([]any{
					map[string]any{"Type": "Video", "Codec": codec, "Height": h, "Index": 0,
						"VideoRangeType": map[bool]string{true: "HDR10", false: "SDR"}[h > 1080]},
				}, extra...)
				ms := map[string]any{
					"Id": msid, "Name": name, "Container": "mkv",
					"Size": size, "Bitrate": bitrate,
					"SupportsDirectStream": true,
					"DirectStreamUrl": "/Videos/" + id +
						"/stream.mp4?static=true&mediaSourceId=" + msid,
					"MediaStreams": streams,
				}
				if *transcodeOnly {
					// ★ 连 SupportsDirectStream 一起撤掉 —— 半吊子的形状会让
					//   「我们到底为什么直连」这件事说不清:是真的不理转码,
					//   还是碰巧 DirectStreamUrl 还在?
					delete(ms, "DirectStreamUrl")
					ms["SupportsDirectStream"] = false
					ms["TranscodingUrl"] = "/videos/" + id +
						"/master.m3u8?VideoCodec=h264&AudioCodec=aac&mediaSourceId=" + msid
				}
				return ms
			}
			writeJSON(w, map[string]any{
				"PlaySessionId": "ps-selfcheck",
				"MediaSources": []any{
					src("ms-1", "1080p", "h264", 1080, 4_800_000_000, 6_500_000, []any{
						map[string]any{"Type": "Audio", "Codec": "aac", "Language": "jpn",
							"Index": 1, "Channels": 2, "DisplayTitle": "日语 AAC 2.0"},
						map[string]any{"Type": "Subtitle", "Codec": "ass", "Language": "chi",
							"Index": 2, "DisplayTitle": "简体中文"},
					}),
					src("ms-2", "2160p HDR", "hevc", 2160, 21_300_000_000, 28_000_000, []any{
						map[string]any{"Type": "Audio", "Codec": "truehd", "Language": "eng",
							"Index": 1, "Channels": 8, "DisplayTitle": "英语 TrueHD 7.1"},
						map[string]any{"Type": "Audio", "Codec": "flac", "Language": "jpn",
							"Index": 2, "Channels": 2, "DisplayTitle": "日语 FLAC 2.0"},
						map[string]any{"Type": "Subtitle", "Codec": "ass", "Language": "chi",
							"Index": 3, "DisplayTitle": "简体中文"},
					}),
				},
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
		ep["RunTimeTicks"] = runtimeTicks(14000000000)
		writeJSON(w, page(ep))
	})

	// 视频流。★ 必须支持 Range —— http.ServeFile 自带。
	// 不支持的话核心层的 `bytes=0-0` 探测会选错前缀,而表现是「跳到没缓冲的位置就卡死」。
	mux.HandleFunc("/Videos/", func(w http.ResponseWriter, r *http.Request) {
		if *clip == "" {
			http.Error(w, "自检没带 -clip,没有可播的文件", http.StatusNotFound)
			return
		}
		http.ServeFile(throttled(w), r, *clip)
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

// bootAt 进程启动时刻。日志里的毫秒数以它为准。
// runtimeTicks 一个条目该报多长。给了 -clip-secs 就一律用它 ——
// 界面上所有百分比都得和真正放出来的那个文件对得上。
/* throttled 给视频流限速。

   ☠☠ **不限速的假服务器是一台无限快的服务器**,而那会让一整类断言变成假的:
   预取代理在环回上几秒钟就能把整片拉下来 —— 于是「已缓存 / 没缓存」这个
   对比组根本造不出来,「取缩略图有没有替用户下载」也永远量不出增量
   (本来就已经 100% 了)。2026-09-03 当场撞上:同一份代码,
   自检等 12 秒是绿的、等 22 秒变红,而代码一行没改。

   ★ 限的是**吐字节的速度**,不是延迟 —— 延迟慢的服务器和带宽小的服务器
     暴露的是两类 bug,这里要的是后者。 */
func throttled(w http.ResponseWriter) http.ResponseWriter {
	if clipKBps == nil || *clipKBps <= 0 {
		return w
	}
	return &slowWriter{ResponseWriter: w, bps: *clipKBps * 1024}
}

type slowWriter struct {
	http.ResponseWriter
	bps int
}

func (s *slowWriter) Write(b []byte) (int, error) {
	n, err := s.ResponseWriter.Write(b)
	if n > 0 {
		time.Sleep(time.Duration(float64(n) / float64(s.bps) * float64(time.Second)))
	}
	return n, err
}

func runtimeTicks(fallback int64) int64 {
	if clipSecs != nil && *clipSecs > 0 {
		return int64(*clipSecs * 1e7)
	}
	return fallback
}

var bootAt = time.Now()

// logged 请求日志。
//
// ★★ 带**毫秒时间戳和 UA**。只打路径的话,「同一条路径出现 30 次」看不出是
// 启动时一次性打的还是每秒都在打,也分不清是哪一路发的
// (Emby 用 LinPlayer/x,预取用 LinPlayerPreload/x,探活不带凭据)——
// 而这两件事恰恰是排查「响应慢」时唯一要问的问题。
func logged(h http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		ua := r.Header.Get("User-Agent")
		if ua == "" {
			ua = "-"
		}
		fmt.Printf("  <- %6d ms %s %s  [%s]\n",
			time.Since(bootAt).Milliseconds(), r.Method, r.URL.RequestURI(), ua)
		h.ServeHTTP(w, r)
	})
}

// solid 按 id 摊出一种颜色,同 id 必得同色。
func solid(id string, wide bool) image.Image {
	var h uint32 = 2166136261
	for _, c := range []byte(id) {
		h = (h ^ uint32(c)) * 16777619
	}
	iw, ih := 64, 96
	if wide {
		// ★ 横版给 480×270(16:9)。原来是 192×108 —— 首页 Hero 按 720 高解码,
		//   等于把它放大将近七倍,糊到看不出裁没裁。
		iw, ih = 480, 270
	}
	img := image.NewRGBA(image.Rect(0, 0, iw, ih))
	c := color.RGBA{uint8(h>>16)/2 + 60, uint8(h>>8)/2 + 60, uint8(h)/2 + 60, 255}
	/* ★★ 画成**斜向渐变**,不是一整块纯色。
	   纯色图在界面上判不出任何东西:铺满了没有、拉伸比例对不对、
	   淡出遮罩从哪儿开始 —— 全看不出来,因为哪一块都长一样。
	   自检截图里「背景大图」这一项一直等于没验过。
	   有了渐变,拉歪了、只铺了一半、遮罩方向反了,一眼就能看见。 */
	for y := 0; y < ih; y++ {
		for x := 0; x < iw; x++ {
			t := float64(x)/float64(iw)*0.6 + float64(y)/float64(ih)*0.4
			f := func(v uint8) uint8 { return uint8(float64(v)*(1.15-0.7*t) + 10) }
			img.Set(x, y, color.RGBA{f(c.R), f(c.G), f(c.B), 255})
		}
	}
	if wide {
		/* ★★ 四角画角标 + 正中画一个十字。
		   这是「**这张图有没有被裁掉**」唯一看得见的判据 ——
		   用户 2026-09-02 报的第一条就是首页 Hero「封面不全」,
		   而在一张渐变图上,裁掉上下各四分之一是**看不出来**的:
		   剩下的那条照样是一片渐变。四个角都在 = 一个像素都没裁。 */
		mark := color.RGBA{255, 255, 255, 255}
		const arm, thick, inset = 40, 4, 6
		put := func(x, y int) {
			if x >= 0 && x < iw && y >= 0 && y < ih {
				img.Set(x, y, mark)
			}
		}
		for _, cn := range [][2]int{{inset, inset}, {iw - inset - 1, inset},
			{inset, ih - inset - 1}, {iw - inset - 1, ih - inset - 1}} {
			dx, dy := 1, 1
			if cn[0] > iw/2 {
				dx = -1
			}
			if cn[1] > ih/2 {
				dy = -1
			}
			for i := 0; i < arm; i++ {
				for t := 0; t < thick; t++ {
					put(cn[0]+dx*i, cn[1]+dy*t)
					put(cn[0]+dx*t, cn[1]+dy*i)
				}
			}
		}
		for i := -arm / 2; i < arm/2; i++ {
			for t := 0; t < thick; t++ {
				put(iw/2+i, ih/2+t)
				put(iw/2+t, ih/2+i)
			}
		}
	}
	return img
}

func wordmark(id string) image.Image {
	var h uint32 = 2166136261
	for _, c := range []byte(id) {
		h = (h ^ uint32(c)) * 16777619
	}
	const iw, ih = 360, 100
	img := image.NewRGBA(image.Rect(0, 0, iw, ih))
	// 三段字块,宽度按 id 抖一抖 —— 每部片的艺术字宽度不同才验得到左对齐
	x := 10
	for i := 0; i < 3; i++ {
		w := 60 + int((h>>(uint(i)*5))%70)
		for yy := 26; yy < 74; yy++ {
			for xx := x; xx < x+w && xx < iw; xx++ {
				img.Set(xx, yy, color.RGBA{245, 246, 250, 255})
			}
		}
		x += w + 14
	}
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
