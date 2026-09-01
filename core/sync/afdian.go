package sync

// 爱发电付费校验。移植自 `crates/core/src/sync/mod.rs` 的 afdian_verify。
//
// ★ 订单号发给自建代理(代理持 afdian token 调 query-order),**客户端不接触 token**。
//   软锁 —— 只抬高门槛,别指望防破解。

import (
	"context"
	"encoding/json"
	"fmt"
	"strings"

	"linplayer/core/bus"
)

// AfdianVerifyResult 校验结果。
//
// ★ 失败不抛错,而是**带着 reason 返回**:这条命令的每一种失败(没填、没配、
//   网络断、服务抽风、订单不对)都要在同一个输入框下面显示成一句人话,
//   抛错的话界面只能笼统显示「失败」,用户不知道下一步该干什么。
type AfdianVerifyResult struct {
	Valid     bool   `json:"valid"`
	PlanTitle string `json:"plan_title"`
	Amount    string `json:"amount"`
	Reason    string `json:"reason,omitempty"`
}

// v2s 把 JSON 里的值折成字符串。金额在不同接口里有时是数字有时是字符串。
func v2s(v any) string {
	switch x := v.(type) {
	case string:
		return x
	case float64:
		return strings.TrimSuffix(strings.TrimRight(fmt.Sprintf("%.2f", x), "0"), ".")
	}
	return ""
}

// AfdianVerify 校验一个订单号。
func AfdianVerify(ctx context.Context, orderNo string) AfdianVerifyResult {
	trimmed := strings.TrimSpace(orderNo)
	if trimmed == "" {
		return AfdianVerifyResult{Reason: "请输入订单号"}
	}
	if !UseProxy() {
		return AfdianVerifyResult{Reason: "未配置校验服务"}
	}
	code, b, err := postProxy(ctx, "/afdian/verify", map[string]any{"out_trade_no": trimmed})
	if err != nil {
		return AfdianVerifyResult{Reason: "网络错误:" + err.Error()}
	}
	var j map[string]any
	if json.Unmarshal(b, &j) != nil {
		return AfdianVerifyResult{Reason: fmt.Sprintf("服务返回异常:HTTP %d", code)}
	}
	r := AfdianVerifyResult{PlanTitle: v2s(j["planTitle"]), Amount: v2s(j["amount"]), Reason: v2s(j["reason"])}
	if v, ok := j["valid"].(bool); ok {
		r.Valid = v
	}
	return r
}

func registerAfdian() {
	// ★ 命令名在 `system.*` 下(契约如此),但实现留在 sync 包 ——
	//   代理地址、共享密钥、postProxy 全在这儿。为了对齐命名把这些搬去 system
	//   等于把注入的密钥再多铺一个包。
	bus.Register("system.afdianVerify", func(ctx context.Context, seq int64, a map[string]any) (any, error) {
		s, _ := a["order_no"].(string)
		return AfdianVerify(ctx, s), nil
	})
}
