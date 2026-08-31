package emby

// 本包自己注册 `emby.*`。命令归属跟着实现走(理由见 core/player/commands.go)。

import (
	"context"

	"linplayer/core/bus"
)

var defaultClient *Client

// RegisterCommands 由 lp_init 调用。
func RegisterCommands(version string) {
	defaultClient = NewClient(version)

	bus.Register("emby.views", func(ctx context.Context, seq int64, args map[string]any) (any, error) {
		s, err := sessionFrom(args)
		if err != nil {
			return nil, err
		}
		items, err := defaultClient.Views(ctx, s)
		if err != nil {
			// 网络错误是**可重试**的 —— UI 据此显示「重试」而不是「重新登录」(SPEC §5.4)
			return nil, &bus.Err{Code: bus.ENetwork, Msg: err.Error(), Retryable: true}
		}
		return items, nil
	})
}

// sessionFrom 从命令参数里取会话。
//
// ponytail: 迁移期先由调用方显式传。等 core/config 把 accounts 接进来之后,
// 改成「传 account 下标,会话由核心层自己组装」—— 那才是 §5.6 命令表里的形状。
func sessionFrom(args map[string]any) (*Session, error) {
	get := func(k string) string {
		v, _ := args[k].(string)
		return v
	}
	s := &Session{
		Server:   get("server"),
		Token:    get("token"),
		UserID:   get("user_id"),
		DeviceID: get("device_id"),
	}
	if s.Server == "" || s.UserID == "" {
		return nil, bus.NewErr(bus.EInvalid, "缺少 server 或 user_id")
	}
	return s, nil
}
