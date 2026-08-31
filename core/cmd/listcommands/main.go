// listcommands 把 Go 侧**已注册**的命令名打出来,一行一条。
//
// 给四方比对用(COMMANDS.md ↔ Go 注册表 ↔ 三端绑定,SPEC §5.6)。
// 单独一个小程序而不是让契约测试顺带打:比对脚本不该依赖 .dll 出得来。
package main

import (
	"fmt"
	"sort"

	"linplayer/core/bus"
	"linplayer/core/emby"
	"linplayer/core/player"
	"linplayer/core/system"
)

func main() {
	// 只注册,不 bus.Init() —— 注册表和工作池是两件事,这里不需要后者。
	system.RegisterCommands()
	player.RegisterCommands()
	emby.RegisterCommands("listcommands")

	cmds := bus.Commands()
	sort.Strings(cmds)
	for _, c := range cmds {
		fmt.Println(c)
	}
}
