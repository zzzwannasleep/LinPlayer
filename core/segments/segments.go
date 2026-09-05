// Package segments 片头片尾时间戳的外部数据源。
//
// 为什么要有它:片头片尾本来只认 Emby 的章节,而**章节是服务端刮削出来的** ——
// 没刮过章节的库返回空表,「自动跳过」就整个不工作。用户 2026-09-06:
// 「很多 Emby 服务器没有数据,增加三个片头片尾数据源提高成功率」。
//
// 三个源按顺序问,**取到什么留什么**:片头从 A 来、片尾从 B 来是允许的 ——
// 目标是提高命中率,不是让某一个源赢。
package segments

import (
	"context"
	"strings"
	"sync"
	"time"
)

// Range 一个可跳过的区间(秒)。
type Range struct {
	Start float64 `json:"start"`
	End   float64 `json:"end"`
}

// Meta 查询依据。字段缺得越多能问的源越少,但**不缺就一定要传** ——
// 三个源用的是三种 id,少传一个就等于少一个源。
type Meta struct {
	IMDb        string // tt 开头,IntroDB 唯一认的 id
	TMDb        string // TheIntroDB 的首选 id
	TVDb        string // TheIntroDB 的备选
	MAL         string // MyAnimeList id,AniSkip 唯一认的 id
	Season      int
	Episode     int
	RuntimeSecs float64
	IsMovie     bool
}

// Result 查到的东西。Intro / Outro 为 nil 表示这个源没有。
type Result struct {
	Intro *Range `json:"intro"`
	Outro *Range `json:"outro"`
	// From 片头和片尾各自来自哪个源,用于界面上说清楚数据的出处。
	From string `json:"from"`
}

// source 一个数据源。查不到返回 (nil, nil) —— **查不到不是错误**,
// 这三个源本来就都是「有就用、没有就算」。
type source struct {
	name string
	get  func(ctx context.Context, m Meta) (*Result, error)
}

func sources() []source {
	return []source{
		{"IntroDB", introDB},
		{"TheIntroDB", theIntroDB},
		{"AniSkip", aniSkip},
	}
}

/* ponytail: 只有内存缓存,不落盘。
   一次起播最多三个小 JSON,连播时命中的就是这份内存表;
   重启后重查的代价是三次几百字节的请求。真要落盘,照 danmaku/cache.go 那套加。 */
var (
	cacheMu  sync.Mutex
	cache    = map[string]cached{}
	negative = 12 * time.Hour
)

type cached struct {
	res *Result
	at  time.Time
	// 空结果的有效期短一些:这三个源都是众投的,今天没有的明天可能就有了
	empty bool
}

func keyOf(m Meta) string {
	return strings.Join([]string{
		m.IMDb, m.TMDb, m.TVDb, m.MAL,
		itoa(m.Season), itoa(m.Episode),
	}, "|")
}

// Lookup 依次问三个源,把拿到的片头片尾拼起来。
//
// ★ 两段都拿到就**不再问后面的源** —— 剩下的问了也用不上,而每一次都是一趟网络。
// ★ 某个源报错不中断:它挂了不该让另外两个也查不成。
func Lookup(ctx context.Context, m Meta) *Result {
	if m.IMDb == "" && m.TMDb == "" && m.TVDb == "" && m.MAL == "" {
		return nil
	}
	k := keyOf(m)
	cacheMu.Lock()
	if c, ok := cache[k]; ok && (!c.empty || time.Since(c.at) < negative) {
		cacheMu.Unlock()
		return c.res
	}
	cacheMu.Unlock()

	out := &Result{}
	var from []string
	for _, s := range sources() {
		if out.Intro != nil && out.Outro != nil {
			break
		}
		r, err := s.get(ctx, m)
		if err != nil {
			logSourceErr(s.name, err)
			continue
		}
		if r == nil {
			continue
		}
		hit := false
		if out.Intro == nil && r.Intro != nil {
			out.Intro, hit = r.Intro, true
		}
		if out.Outro == nil && r.Outro != nil {
			out.Outro, hit = r.Outro, true
		}
		if hit {
			from = append(from, s.name)
		}
	}
	out.From = strings.Join(from, " + ")

	res := out
	if out.Intro == nil && out.Outro == nil {
		res = nil
	}
	cacheMu.Lock()
	cache[k] = cached{res: res, at: time.Now(), empty: res == nil}
	cacheMu.Unlock()
	return res
}

// Clear 清掉缓存。设置页换了开关之后要用,不然改完还是上一轮的结果。
func Clear() {
	cacheMu.Lock()
	cache = map[string]cached{}
	cacheMu.Unlock()
}

// sane 挡掉明显不合理的区间。
//
// ★ 众投数据里出现过 start>end、负数、比片长还长的条目 ——
// 照单全收的结果是「点跳过之后跳到片尾」或者直接跳出片长,而那不报错。
func sane(r *Range, runtimeSecs float64) *Range {
	if r == nil || r.End <= r.Start || r.Start < 0 {
		return nil
	}
	if runtimeSecs > 0 && r.End > runtimeSecs+1 {
		return nil
	}
	// 短于 3 秒的段跳不跳都一样,而按钮弹一下反而打扰
	if r.End-r.Start < 3 {
		return nil
	}
	return r
}

func itoa(n int) string {
	if n == 0 {
		return ""
	}
	neg := n < 0
	if neg {
		n = -n
	}
	var b []byte
	for n > 0 {
		b = append([]byte{byte('0' + n%10)}, b...)
		n /= 10
	}
	if neg {
		return "-" + string(b)
	}
	return string(b)
}

// SetEndpointsForTest 把三个源指到假服务器上,返回还原函数。**只给测试用。**
//
// ★ 没有这个钩子的话,跨包(core/player)的三层优先级就只能靠打真外网来测,
// 而那种测试要么慢要么假绿 —— 于是那段代码等于没有测试。
func SetEndpointsForTest(introDB, theIntroDB, aniSkip string) func() {
	old := [3]string{introDBBase, theIntroDBBase, aniSkipBase}
	introDBBase, theIntroDBBase, aniSkipBase = introDB, theIntroDB, aniSkip
	Clear()
	return func() {
		introDBBase, theIntroDBBase, aniSkipBase = old[0], old[1], old[2]
		Clear()
	}
}
