package download

// 分段下载的重试策略。
//
// # 为什么非要有
//
// 老代码一段出错就整条任务失败,没有任何重试。日常观影链路上这三件事都会踩到:
//
//   - **鉴权直链过期**。前后端分离的 Emby(115 / 123 那类网盘后端)给的是带时效
//     签名的直链,115 默认 30 分钟。一部 40GB 的原盘在慢链路上要下几小时 ——
//     签名**必然**在中途失效,而下载是一段一条长连接,失效那一刻整条任务就死了。
//   - 反代 / CDN 掐长连接。
//   - 家里的网抖一下。
//
// 这些全都是**重试就能过去**的,而且 part 文件天然可续:重新按盘上的实际大小
// 发一次 Range 就接上了。重试打的是 `it.URL`(Emby 直链)而不是上一轮那条落点,
// 所以前后端分离的服会在这里重新发一次 302,换回一条**新签名**的直链。
//
// # 判据是「有没有前进」,不是「失败了几次」
//
// 见 runSegment 里那段注释:只要这一轮真写下了字节,重试预算就清零。
// 按次数硬扣的话,一部下几小时的片会在第 10 次换签名时把预算烧光 ——
// 而它每一次其实都下成了。

import (
	"errors"
	"time"
)

// maxSegmentRetries 一段**连续毫无进展**多少次才放弃。
const maxSegmentRetries = 10

// maxSegmentRounds 一段总共最多重来多少轮。
//
// ★ 只为一件事存在:防住「每轮吐一点点字节就断」的病态上游 —— 那种上游能让
// 「有进展就清零」这条规则永远转下去,而每一轮都是一次打在源站上的真实请求。
// 正常链路够不着这个数(每轮至少退避 1 秒,200 轮 ≈ 用户早就去点取消了)。
const maxSegmentRounds = 200

// retryBackoff 第 n 次连续失败之后等多久再来。1s 起翻倍,封顶 30s。
//
// ★ 封顶不能太小:签名过期那一类问题,重试太密只是在给源站加压 ——
// 而我们做这一整块的初衷正是**给源站减压**。
func retryBackoff(n int) time.Duration {
	if n < 0 {
		n = 0
	}
	if n > 5 {
		n = 5
	}
	d := time.Second << n
	if d > 30*time.Second {
		d = 30 * time.Second
	}
	return d
}

// permanentErr 重试也不会变对的错:用户叫停、没权限、请求本身不合法、盘写不进去。
//
// ★ 不分这一类的下场是**把 401 重试十遍**:用户等 10 × 退避 ≈ 一分钟才看到
// 「无下载权限」,而服务器白挨十次。
type permanentErr struct{ err error }

func (e permanentErr) Error() string { return e.err.Error() }
func (e permanentErr) Unwrap() error { return e.err }

func permanent(err error) error {
	if err == nil {
		return nil
	}
	return permanentErr{err: err}
}

func isPermanent(err error) bool {
	var p permanentErr
	return errors.As(err, &p)
}
