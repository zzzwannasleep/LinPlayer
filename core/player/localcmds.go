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
		path := m.CompletedPath(id)
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
