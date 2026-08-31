// Package commands 是**唯一**的命令注册入口。
//
// ★★ 这个包存在的全部理由是防一类静默漂移。
//
// 之前 `lp_init`(core/ffi)和 `listcommands`(四方比对门禁用的)**各自列一遍**
// 要注册哪些模块。两边都是手写的清单,于是:
//
//	新模块只加进 lp_init  → 门禁少数一批,「Go 112/271」这个数字长期偏低,
//	                        看起来像还没做,实际做了
//	新模块只加进 listcommands → **更糟**:门禁说绿,而真正的应用里根本没有那条命令,
//	                        UI 调过去拿到 E_NOTFOUND
//
// 两种都不报错。收成一处之后,两边调的是同一个函数,漂移无处可生。
package commands

import (
	"linplayer/core/account"
	"linplayer/core/aggregate"
	"linplayer/core/download"
	"linplayer/core/emby"
	"linplayer/core/history"
	"linplayer/core/player"
	"linplayer/core/prefs"
	"linplayer/core/ranking"
	"linplayer/core/sourcecmd"
	"linplayer/core/system"
)

// RegisterAll 注册全部命令。version 进 UA 与 system.info。
//
// ★ 只注册,不 bus.Init() —— 注册表和工作池是两件事。
// listcommands 那个小程序不需要后者。
func RegisterAll(version string) {
	system.RegisterCommands()
	player.RegisterCommands(version)
	emby.RegisterCommands(version)
	account.RegisterCommands(version)
	prefs.RegisterCommands(version)
	history.RegisterCommands()
	aggregate.RegisterCommands(version)
	ranking.RegisterCommands()
	sourcecmd.RegisterCommands()
	download.RegisterCommands()
}
