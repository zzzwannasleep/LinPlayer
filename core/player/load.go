package player

// 起播的**唯一**入口:loadfile + 逐流 headers + UA。
//
// ★★ 这个文件存在的全部理由是一句话:**mpv 的 user-agent 和 http-header-fields
// 是实例级属性,设了就一直在**。
//
// 黄金实现栽过一次:只有网盘那条路会设、谁都不复位,于是放过一次网盘源之后再放 Emby:
//
//	① 还顶着网盘的 UA,并把网盘的 Authorization / Cookie **发给 Emby 服务器**;
//	② Emby 直连取流从来没带过 LinPlayer/{版本},用的是 mpv 自带默认 UA。
//
// 两个都是**静默**的 —— 画面照放,只有服务端日志里看得出来。
//
// 所以:两条起播路(Emby / 源)都必须走 loadWith,而它**无条件重设**这两个属性,
// 不是「有才设」。

import (
	"fmt"
	"sort"
	"strconv"
	"strings"

	"linplayer/core/httpx"
)

// loadWith 起播一个地址。
//
//	headers  逐流请求头。空表示这条路不需要额外头。
//	ua       整条流的 User-Agent 覆盖。空表示用默认口径(httpx.UA())。
//	startSec 续播位置,<= 1 视为从头。
//
// ★ 续播位置走 loadfile 的 `start=` 选项交给 mpv 自己处理。
// 别在 FILE_LOADED 之后自己 seek:那时画面已经从 0 开始解了,
// 用户会看到「先闪一下开头再跳过去」。
func loadWith(url string, startSec float64, headers map[string]string, ua string) error {
	// ★★ 无条件重设,顺序无所谓但**一个都不能省**。
	//    省掉哪一个,那一个就会带着上一片的值继续用。
	setProp("http-header-fields", joinHeaders(headers))
	if ua == "" {
		ua = httpx.UA()
	}
	setProp("user-agent", ua)

	if err := command(loadArgs(url, startSec)...); err != nil {
		return fmt.Errorf("loadfile 失败: %w", err)
	}
	/* ★★ 把交给 mpv 的地址**自己记一份**,别回头去问 mpv 的 `path` 属性。
	   实测它不可靠:同一次播放里,状态轮询读到的是完整地址(29 字符的代理 URL),
	   而几百毫秒后另一条命令里读到的是**空串** —— 于是「这条流有没有本地缓存」
	   一会儿说有一会儿说没有,进度条画着带子、点下去却没有图。
	   我们本来就知道给出去的是什么,没有理由去问别人。 */
	setPlayURL(url)
	setProp("pause", "no")
	ResetCadence() // 换片:出帧节奏重新开始统计(上一片的样本和这一片没关系)
	/* ★ 换片了,缩略图那个实例装的还是上一片 —— 收掉它。
	   它是**用到才开**的(见 thumb.go),这里不需要提前开;
	   不收的话下一次取图会先花一趟 loadfile 去换文件,而那趟是在鼠标底下发生的。 */
	thumbs.close()
	return nil
}

// loadArgs 拼 loadfile 的参数表。
//
// ☠☠ **`replace` 后面那个位置是 `index`,不是选项**(mpv 0.38 起插进来的一个参数)。
// 这里原来直接把 `start=…` 拼在 `replace` 后面,mpv 当场回 -4(invalid parameter),
// 而调用方把它包成「loadfile 失败」抛给 UI。
//
// ★★ 它的表现极具迷惑性:**从头看的片子好好的,只有「继续观看」里的点不动** ——
// 因为只有带进度的条目才会拼出第 4 段。用户 2026-09-03 的原话就是
// 「继续观看里面的影片看不了,点击就是 loadfile 失败」。
//
// 实测(本仓 build/core 里的 libmpv,client api 2.5):
//
//	loadfile x.mkv replace                    → 0  success
//	loadfile x.mkv replace start=123.000      → -4 invalid parameter
//	loadfile x.mkv replace -1 start=123.000   → 0  success
//
// -1 = 追加到播放列表末尾。replace 模式下这个位置具体填什么不影响结果,
// 但**必须占住** —— 空着的话选项就滑到 index 那一格上去了。
func loadArgs(url string, startSec float64) []string {
	args := []string{"loadfile", url, "replace"}
	if startSec > 1 {
		args = append(args, "-1", "start="+strconv.FormatFloat(startSec, 'f', 3, 64))
	}
	return args
}

// joinHeaders 把头表拼成 mpv 认的 `K: V,K: V` 形式。
//
// ★ 排序输出:map 遍历顺序在 Go 里是随机的,不排的话同一组头每次拼出来的字符串
// 都不一样 —— 单测会随机红,而真正的 bug 反而藏在噪声里。
func joinHeaders(h map[string]string) string {
	if len(h) == 0 {
		return ""
	}
	keys := make([]string, 0, len(h))
	for k := range h {
		keys = append(keys, k)
	}
	sort.Strings(keys)
	parts := make([]string, 0, len(keys))
	for _, k := range keys {
		parts = append(parts, k+": "+h[k])
	}
	return strings.Join(parts, ",")
}
