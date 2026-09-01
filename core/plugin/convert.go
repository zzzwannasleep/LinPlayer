package plugin

// JS 值 <-> Go 值(JSON 形状)互转。
//
// ★ 不用 goja 的 Export():它把 JS 函数导出成 Go 闭包、把数组导出成 []interface{}
// 但对 undefined / Date / TypedArray 的形状我们都不想要。这里只认 JSON 的六种形状,
// 多余的一律变成 nil —— 越过这条线的值最终要走 encoding/json 出核心层,
// 在这里就规整掉比在序列化时炸掉好。

import (
	"github.com/dop251/goja"
)

// exportJSON 把一个 JS 值转成 JSON 形状的 Go 值。
//
// onFunc 非 nil 时,遇到函数就调它登记并原位换成 `{"__handler__": id}` ——
// 贡献点描述里的回调就是这么存下来的。onFunc 为 nil 时函数直接丢掉。
func exportJSON(vm *goja.Runtime, v goja.Value, onFunc func(goja.Value) string) any {
	if v == nil || goja.IsUndefined(v) || goja.IsNull(v) {
		return nil
	}
	obj, isObj := v.(*goja.Object)
	if !isObj {
		// 原始值:布尔 / 数字 / 字符串。
		// ★ 整数统一升成 float64:JSON 里没有整数类型,不统一的话同一个字段
		//   在两次调用里会一次是 int64 一次是 float64,断言处处要写两遍。
		switch raw := v.Export().(type) {
		case bool:
			return raw
		case int64:
			return float64(raw)
		case float64:
			return raw
		case string:
			return raw
		default:
			return nil
		}
	}
	// 函数
	if _, ok := goja.AssertFunction(obj); ok {
		if onFunc == nil {
			return nil
		}
		return map[string]any{"__handler__": onFunc(v)}
	}
	switch obj.ClassName() {
	case "Array":
		n := obj.Get("length")
		length := 0
		if n != nil {
			length = int(n.ToInteger())
		}
		out := make([]any, 0, length)
		for i := 0; i < length; i++ {
			out = append(out, exportJSON(vm, obj.Get(itoa(i)), onFunc))
		}
		return out
	default:
		out := map[string]any{}
		for _, k := range obj.Keys() {
			out[k] = exportJSON(vm, obj.Get(k), onFunc)
		}
		return out
	}
}

func itoa(i int) string {
	if i == 0 {
		return "0"
	}
	var buf [20]byte
	p := len(buf)
	for i > 0 {
		p--
		buf[p] = byte('0' + i%10)
		i /= 10
	}
	return string(buf[p:])
}
