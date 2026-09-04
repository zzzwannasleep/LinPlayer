// Package danmaku 弹幕。本文件先只放**签名** —— 排行榜和弹幕搜索共用它。
//
package danmaku

import (
	"crypto/sha256"
	"encoding/base64"
	"strconv"
)

// Signature 弹弹Play 官方签名:base64(sha256(AppId + Timestamp + Path + AppSecret))。
//
// ★ 拼接顺序是**契约**,错一个位置就是 403,而服务端只会说「签名无效」。
// ★ path 是**不带域名的路径**(如 /api/v2/trending/all/hot/week),不能带 query。
func Signature(appID, path string, ts int64, secret string) string {
	h := sha256.New()
	h.Write([]byte(appID + strconv.FormatInt(ts, 10) + path + secret))
	return base64.StdEncoding.EncodeToString(h.Sum(nil))
}
