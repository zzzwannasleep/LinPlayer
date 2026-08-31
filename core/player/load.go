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

	args := []string{"loadfile", url, "replace"}
	if startSec > 1 {
		args = append(args, "start="+strconv.FormatFloat(startSec, 'f', 3, 64))
	}
	if err := command(args...); err != nil {
		return fmt.Errorf("loadfile 失败: %w", err)
	}
	setProp("pause", "no")
	return nil
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
