// listcommands 把 Go 侧**已注册**的命令名打出来,一行一条。
//
// 给四方比对用(COMMANDS.md ↔ Go 注册表 ↔ 三端绑定,SPEC §5.6)。
// 单独一个小程序而不是让契约测试顺带打:比对脚本不该依赖 .dll 出得来。
//
// ★★ 注册走 core/commands 这个**唯一入口** —— 这里再手抄一份清单的话,
// 漏一个模块就是「门禁说绿、应用里没有那条命令」,而且两边都不报错。
package main

import (
	"fmt"
	"sort"

	"linplayer/core/bus"
	"linplayer/core/commands"
)

func main() {
	commands.RegisterAll("listcommands")
	cmds := bus.Commands()
	sort.Strings(cmds)
	for _, c := range cmds {
		fmt.Println(c)
	}
}
