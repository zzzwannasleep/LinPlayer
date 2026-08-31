package emby

// HTTP 错误的分类。
//
// ★★ 为什么要它:命令层原来把 Login / getBytes 的**任何**错误都标成
// `E_NETWORK`,而 UI 对 E_NETWORK 显示的是「网络不通,可以重试」——
// 于是密码错、token 过期、地址打错、证书不认、JSON 解析失败,
// 用户看到的全是同一句「没网」。**用户明明有网,却只能看到这句话**,
// 既不知道真因,也不知道下一步该干什么。
//
// 2026-08-31 用户实测撞上:「我登陆了 Emby 服务器一直提示没网了,实际上有网络」。

import (
	"errors"
	"fmt"
	"net/http"
)

// StatusError 服务器回了非 2xx。带上状态码,好让命令层分出「认证问题」和「网络问题」。
type StatusError struct {
	Status int
	// What 这一步在干什么(「登录」「取列表」),拼进给用户看的话里
	What string
}

func (e *StatusError) Error() string {
	switch e.Status {
	case http.StatusUnauthorized:
		return e.What + "失败:服务器说凭据不对(HTTP 401)"
	case http.StatusForbidden:
		return e.What + "失败:服务器拒绝了这个请求(HTTP 403)"
	case http.StatusNotFound:
		// ★ 404 在登录这一步几乎总是**地址填错**,不是「服务器没这个用户」。
		//   写成「找不到」会把人往查账号的方向带。
		return e.What + "失败:这个地址上没有 Emby 接口(HTTP 404),检查一下服务器地址"
	}
	return fmt.Sprintf("%s失败:服务器返回 HTTP %d", e.What, e.Status)
}

// StatusOf 取出 HTTP 状态码;不是 StatusError 就返回 0。
func StatusOf(err error) int {
	var se *StatusError
	if errors.As(err, &se) {
		return se.Status
	}
	return 0
}
