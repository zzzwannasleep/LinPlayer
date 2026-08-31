package ranking

// 排行榜的两条命令。
//
// ★ 命令名沿用 `emby.*` 前缀 —— 这是**契约里定死的**(COMMANDS.md 第 77/78 行),
// 不是笔误。排行榜其实和 Emby 服务器无关,但改名要动三端绑定,
// 迁移期不动契约(冻结在 B3)。

import (
	"context"

	"linplayer/core/bus"
	"linplayer/core/net/localserve"
)

// ImageOrigins 排行榜封面所在的图床。
//
// ★ 必须登记进图片通道的白名单,否则**一张榜单封面都出不来**,
// 而命令本身全都成功 —— 最难查的那种(「数据有、图没有」)。
func ImageOrigins() []string {
	out := []string{
		"https://image.tmdb.org", // TMDB 海报
		"https://img.dandanplay.net",
		"https://image.dandanplay.net",
	}
	// 自检把上游指向了本机假服务器时,那台的图床也要放行(见 endpoints.go)
	return append(out, selfCheckOrigins...)
}

// RegisterCommands 由 lp_init 调用。
func RegisterCommands() {
	localserve.AllowStatic(ImageOrigins()...)

	// emby.rankingCategories —— 当前构建**可用**的分类。
	//
	// ★ 返回的是 Available() 不是 Categories:没凭据的那一族不亮。
	//   亮出来点进去必然是空的,用户只会以为「这个播放器的排行榜坏了」。
	bus.Register("emby.rankingCategories", func(ctx context.Context, seq int64, args map[string]any) (any, error) {
		return Available(), nil
	})

	// emby.rankingFetch —— 拉某一榜。
	//
	// ★★ 错误一律以 **E_UPSTREAM** 上抛,不吞成空数组(TODO C10 的判据)。
	//   分成 E_UPSTREAM 而不是 E_NETWORK:这类失败是**上游说了话**
	//   (429 / 密钥无效 / 分类下线),UI 该原样显示那句话,而不是提示「检查网络」。
	bus.Register("emby.rankingFetch", func(ctx context.Context, seq int64, args map[string]any) (any, error) {
		id, _ := args["category_id"].(string)
		if id == "" {
			return nil, bus.NewErr(bus.EInvalid, "缺少 category_id")
		}
		force, _ := args["force_refresh"].(bool)
		list, err := Fetch(ctx, id, force)
		if err != nil {
			return nil, &bus.Err{Code: bus.EUpstream, Msg: err.Error(), Retryable: true}
		}
		if list == nil {
			list = []Entry{} // 空榜是 [] 不是 null(前端 .map() 会抛)
		}
		return list, nil
	})
}
