package player

// player.playLocal —— 播放已下载到本地的条目。

import (
	"context"
	"os"

	"linplayer/core/bus"
	"linplayer/core/download"
)

func registerLocalCommands() {
	bus.Register("player.playLocal", func(ctx context.Context, seq int64, a map[string]any) (any, error) {
		id, _ := a["id"].(string)
		if id == "" {
			return nil, bus.NewErr(bus.EInvalid, "缺少 id")
		}
		m := download.Shared()
		if m == nil {
			return nil, bus.NewErr(bus.EInternal, "下载模块没起来")
		}
		/* ☠☠ <b>id 两种都收</b>:下载**任务**的 id,或者 Emby 的**条目** id。
		   CompletedPath 只按 ItemID 找 —— 而下载页手里天然拿着的是任务 id
		   (列表里每条的主键就是它)。只按 ItemID 找的话,下载页照着列表传下来
		   一个任务 id,这里一句「还没下载完成」,而那条明明是已完成的。
		   这条命令从注册那天起就没有调用方,所以这个错配一直没人撞上。 */
		path := ""
		for _, it := range m.List() {
			if it.Status != download.StatusCompleted {
				continue
			}
			if it.ID == id || it.ItemID == id {
				path = it.FilePath
				break
			}
		}
		if path == "" {
			return nil, bus.NewErr(bus.ENotFound, "这个条目还没下载完成")
		}
		// ★ 再确认一次文件真的在:索引说完成了不代表文件还在
		//   (用户可能手动删了 / 挪走了 / U 盘拔了)
		if st, err := os.Stat(path); err != nil || st.IsDir() {
			return nil, bus.NewErr(bus.ENotFound, "文件已不存在:%s", path)
		}
		resume, _ := a["resume_secs"].(float64)
		return PlayLocal(path, resume)
	})
}
