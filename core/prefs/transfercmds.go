package prefs

// 配置搬迁:出码 / 扫码导入(UI_PC §7.15「备份 / 搬迁」)。
//
// ★ 出码的载荷是**文本**,由 UI 自己编成二维码;核心层不画图 ——
// 画图要带一整个二维码库,而三端各自的 UI 框架都有现成的。

import (
	"context"
	"time"

	"linplayer/core/bus"
	"linplayer/core/config"
)

func registerTransferCommands() {
	bus.Register("prefs.configExportQr", func(ctx context.Context, seq int64, a map[string]any) (any, error) {
		c := config.Current()
		payload := config.EncodeTransfer(c.AccountList, time.Now().Unix())
		/* ★★ 载荷里**带着 token 和密码**(只是混淆级加密,密钥随载荷走)。
		   把这句话交给 UI,让它必须显示警示 —— 用户会把这张码截图发到群里。 */
		return map[string]any{
			"payload": payload, "count": len(c.AccountList),
			"warning": "这张码里包含你所有服务器的登录凭据,别公开分享。",
		}, nil
	})

	bus.Register("prefs.configImportQr", func(ctx context.Context, seq int64, a map[string]any) (any, error) {
		payload, _ := a["payload"].(string)
		incoming, err := config.DecodeTransfer(payload)
		if err != nil {
			return nil, bus.NewErr(bus.EInvalid, "%v", err)
		}
		c := config.Current()
		// ★★ **合并不是覆盖**:覆盖的话用户在新机器上已经加好的服务器会被抹掉,
		//   而他以为只是「把老机器上的搬过来」。
		c.AccountList = config.MergeAccounts(c.AccountList, incoming)
		if c.Active == nil && len(c.AccountList) > 0 {
			zero := 0
			c.Active = &zero
		}
		if err := c.Save(); err != nil {
			return nil, bus.NewErr(bus.EInternal, "配置保存失败: %v", err)
		}
		return map[string]any{"imported": len(incoming), "total": len(c.AccountList)}, nil
	})
}
