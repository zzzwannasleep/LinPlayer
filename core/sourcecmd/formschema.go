package sourcecmd

// source.formSchema —— 源类型与它们各自的登录表单,由核心层声明,三端各写一个渲染器。
//
// ☠ 这条命令 `SPEC.md` §8.1 和 `UI_PC.md` §7.6 写了很久,但**一直不存在**;
// PC 和安卓各自硬编了一张源类型表。两处不同步的表现是「某个入口加不了这种源」——
// 而不是报错。表在这里之后,新增源类型只改这一个文件。

import (
	"context"

	"linplayer/core/bus"
)

// FormField 表单里的一个字段。
type FormField struct {
	Key   string `json:"key"`
	Label string `json:"label"`
	// Type: text | password | url | dir —— 渲染器按它决定用哪个控件。
	// dir 是目录选择器:安卓上没有可用的目录选择器时,整个源类型不该出现在表里。
	Type        string `json:"type"`
	Placeholder string `json:"placeholder"`
	Required    bool   `json:"required"`
}

// SourceForm 一种源类型。
type SourceForm struct {
	Kind  string `json:"kind"`
	Label string `json:"label"`
	// Hint 选中这一类时显示的一句话。**不是字段说明**,是「这一类是什么」。
	Hint string `json:"hint"`
	// CanTest 有没有「测试连接」按钮。本机目录没有可测的东西。
	CanTest bool        `json:"can_test"`
	Fields  []FormField `json:"fields"`
}

// forms 全部源类型。**这是唯一一份**。
func forms() []SourceForm {
	return []SourceForm{
		{
			Kind: "emby", Label: "Emby", CanTest: true,
			Hint: "填服务器地址和账号即可。先点「测试连接」可以确认地址对不对。",
			Fields: []FormField{
				{Key: "server", Label: "服务器地址", Type: "url",
					Placeholder: "https://你的服务器地址", Required: true},
				{Key: "username", Label: "用户名", Type: "text", Required: true},
				{Key: "password", Label: "密码", Type: "password"},
			},
		},
		{
			Kind: "local", Label: "本机文件夹", CanTest: false,
			Hint: "选一个本机目录当作源。没有地址也没有账号密码。",
			Fields: []FormField{
				{Key: "path", Label: "本机目录", Type: "dir", Required: true},
			},
		},
	}
}

func registerFormSchema() {
	bus.Register("source.formSchema", func(ctx context.Context, seq int64, a map[string]any) (any, error) {
		return forms(), nil
	})
}
