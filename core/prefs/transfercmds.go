package prefs

// 配置搬迁:出码 / 扫码导入(UI_PC §7.15「备份 / 搬迁」)。
//
// ★ 出码的载荷是**文本**,由 UI 自己编成二维码;核心层不画图 ——
// 画图要带一整个二维码库,而三端各自的 UI 框架都有现成的。

import (
	"context"
	"os"
	"path/filepath"
	"strings"
	"time"

	"linplayer/core/bus"
	"linplayer/core/config"
)

// BackupExported 一次备份导出的结果。
//
// 具名而不是裸 map:UI 靠 Warning 决定要不要弹「别公开分享」那句话,
// 键名拼错了这句警示就静默消失 —— 而文件里带着所有服务器的凭据。
type BackupExported struct {
	// Content 给了 path 就已经落盘,这里空着,不再跨 FFI 回吐一份大字符串。
	Content  string `json:"content,omitempty"`
	Path     string `json:"path,omitempty"`
	Bytes    int    `json:"bytes"`
	Filename string `json:"filename"`
	// Accounts / Warning 只在这份备份真的带账号时才发。
	Accounts *int   `json:"accounts,omitempty"`
	Warning  string `json:"warning,omitempty"`
}

// BackupImported 一次还原的结果。
type BackupImported struct {
	Imported         int  `json:"imported"`
	Total            int  `json:"total"`
	SettingsRestored bool `json:"settings_restored"`
}

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

	/* ---- 备份与还原(用户 2026-09-08)----

	   核心层只管**内容**,文件对话框归 UI:三端各有各的挑文件方式(SAF / 系统对话框),
	   而「备份里装什么」必须只有一份实现,否则 PC 导出的手机读不了 —— 那正是
	   这个功能唯一的验收点。 */
	bus.Register("prefs.backupExport", func(ctx context.Context, seq int64, a map[string]any) (any, error) {
		withAccounts := boolArg(a, "accounts", true)
		withSettings := boolArg(a, "settings", true)
		if !withAccounts && !withSettings {
			return nil, bus.NewErr(bus.EInvalid, "两样都不导出的话,导出来的是一个空文件")
		}
		c := config.Current()
		b, err := config.EncodeBackup(c, time.Now().Unix(), withAccounts, withSettings)
		if err != nil {
			return nil, bus.NewErr(bus.EInternal, "备份编码失败: %v", err)
		}
		out := BackupExported{
			Content:  string(b),
			Bytes:    len(b),
			Filename: "LinPlayer-备份-" + time.Now().Format("20060102-150405") + ".lpbak",
		}
		if withAccounts {
			n := len(c.AccountList)
			out.Accounts = &n
			// ★★ 文件里**带着 token 和密码**,而加密是混淆级(密钥随文件走)。
			//   这句话必须交到 UI 手上 —— 用户会把备份发到群里。
			out.Warning = "这份备份里包含你所有服务器的登录凭据,别公开分享。"
		}
		// UI 可以直接落盘;给了 path 就核心层写,省掉一次大字符串跨 FFI
		if p, ok := a["path"].(string); ok && strings.TrimSpace(p) != "" {
			if err := os.MkdirAll(filepath.Dir(p), 0o755); err != nil {
				return nil, bus.NewErr(bus.EInvalid, "这个目录建不出来: %v", err)
			}
			if err := os.WriteFile(p, b, 0o600); err != nil {
				return nil, bus.NewErr(bus.EInvalid, "写不进去: %v", err)
			}
			out.Path = p
			out.Content = "" // 已经落盘了,再回吐一份是白花
		}
		return out, nil
	})

	// backupPreview 只读不写 —— 导入前让用户看清楚要还原什么再点确认。
	bus.Register("prefs.backupPreview", func(ctx context.Context, seq int64, a map[string]any) (any, error) {
		raw, err := backupBytes(strArg(a, "content"), strArg(a, "path"))
		if err != nil {
			return nil, err
		}
		container, e := config.DecodeBackup(raw)
		if e != nil {
			return nil, bus.NewErr(bus.EInvalid, "%v", e)
		}
		return config.PreviewBackup(container), nil
	})

	bus.Register("prefs.backupImport", func(ctx context.Context, seq int64, a map[string]any) (any, error) {
		raw, err := backupBytes(strArg(a, "content"), strArg(a, "path"))
		if err != nil {
			return nil, err
		}
		container, e := config.DecodeBackup(raw)
		if e != nil {
			return nil, bus.NewErr(bus.EInvalid, "%v", e)
		}
		c := config.Current()
		n, restored := config.ApplyBackup(c, container,
			boolArg(a, "accounts", true), boolArg(a, "settings", true))
		if err := c.Save(); err != nil {
			return nil, bus.NewErr(bus.EInternal, "配置保存失败: %v", err)
		}
		return BackupImported{
			Imported: n, Total: len(c.AccountList), SettingsRestored: restored,
		}, nil
	})
}

// backupBytes 备份内容从哪来:直接给 content,或者给一个 path 让核心层读。
//
// ★ 两个参数**在调用点读**,不在这里读 a[...] —— `check-android-args.py`
// 跟不进助手函数,那样会报一条「传了 content,核心层从不读它」的假红。
// 而假红比没有门禁更坏:它会训练人无视这个门禁。
func backupBytes(content, path string) ([]byte, error) {
	if strings.TrimSpace(content) != "" {
		return []byte(content), nil
	}
	if strings.TrimSpace(path) == "" {
		return nil, bus.NewErr(bus.EInvalid, "要么给 content,要么给 path")
	}
	b, err := os.ReadFile(path)
	if err != nil {
		return nil, bus.NewErr(bus.EInvalid, "读不出这个文件: %v", err)
	}
	return b, nil
}

// strArg 取一个字符串参数。没传 = 空串。
func strArg(a map[string]any, k string) string {
	v, _ := a[k].(string)
	return v
}

// boolArg 没传就用默认值。**不能默认 false** —— 那会让「不传 = 什么都不导」,
// 而调用方以为不传是「全都要」。
func boolArg(a map[string]any, k string, def bool) bool {
	if v, ok := a[k].(bool); ok {
		return v
	}
	return def
}
