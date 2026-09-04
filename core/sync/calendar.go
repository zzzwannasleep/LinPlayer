package sync

import (
	"fmt"
	"strconv"
	"strings"
)

// 追剧日历条目(Trakt / Bangumi 归一化)+ 免依赖的日期算术。
//
// ★ **归组是 UI 逻辑**,核心层只出数据 —— 按周几归、按日期归、跨时区怎么算,
// 是各端自己的事。核心层替它们决定了,三端就都得跟着改。

// CalendarEntry 一条放送。
type CalendarEntry struct {
	Title    string  `json:"title"`
	Subtitle *string `json:"subtitle"`
	// AirDate 精确放送时刻 ISO8601(Trakt 有);为空时前端用 weekday 归组。
	AirDate *string `json:"air_date"`
	// Weekday 每周放送日 1=周一…7=周日(Bangumi 用)。
	Weekday *int `json:"weekday"`
	// BroadcastAt 每周固定放送时刻(ISO8601 UTC 的**首播时刻**,周期重复 → 时分即每周更新时间)。
	//
	// ★ Bangumi 官方 API **不给时刻**,靠 bangumi-data 数据集补;取不到就是 nil,
	// 不编一个时间出来。前端拿它换算成本地 HH:MM;Trakt 那边 AirDate 已含时刻,用不上它。
	BroadcastAt *string `json:"broadcast_at"`
	ImageURL    *string `json:"image_url"`
	TMDBID      *int64  `json:"tmdb_id"`
	// Rating 评分(10 分制,两源同口径)。
	//
	// ★★ **0 分 = 没人评过**,不是「这片 0 分」—— 取不到就 nil,别让前端画出诽谤。
	// 以前 Bangumi 把评分硬塞进 subtitle 当文字(「评分 8.2」),那是拿文案位当数据位。
	Rating *float64 `json:"rating"`
	// Summary 简介。
	//
	//   - Trakt:TMDB 的 overview —— 取海报那次请求**顺手就有**,零额外开销,直接内联。
	//   - Bangumi:**恒为 nil**。实测 /calendar 的 summary 整周 111 条全是空串
	//     (字段在、值不给),真简介只在 /v0/subjects/{id}。一周 111 部要 111 次请求,
	//     不能在拉放送表时同步做 → 走 sync.bangumiSummary 按需拉。
	Summary *string `json:"summary"`
	// BangumiID Bangumi subject id。前端拿它按需拉简介(见上)。Trakt 侧为 nil。
	BangumiID *int64 `json:"bangumi_id"`
	Source    string `json:"source"` // trakt | bangumi
}

// CivilFromDays epoch 天数 → (年,月,日)。Howard Hinnant civil_from_days,免依赖。
func CivilFromDays(z int64) (int64, int, int) {
	z += 719468
	era := z / 146097
	if z < 0 {
		era = (z - 146096) / 146097
	}
	doe := z - era*146097                                  // [0, 146096]
	yoe := (doe - doe/1460 + doe/36524 - doe/146096) / 365 // [0, 399]
	y := yoe + era*400
	doy := doe - (365*yoe + yoe/4 - yoe/100) // [0, 365]
	mp := (5*doy + 2) / 153                  // [0, 11]
	d := doy - (153*mp+2)/5 + 1              // [1, 31]
	m := mp + 3
	if mp >= 10 {
		m = mp - 9
	}
	if m <= 2 {
		y++
	}
	return y, int(m), int(d)
}

// DaysFromCivil (年,月,日) → epoch 天数。CivilFromDays 的逆。
func DaysFromCivil(y, m, d int64) int64 {
	if m <= 2 {
		y--
	}
	era := y / 400
	if y < 0 {
		era = (y - 399) / 400
	}
	yoe := y - era*400 // [0, 399]
	mm := m + 9
	if m > 2 {
		mm = m - 3
	}
	doy := (153*mm+2)/5 + d - 1            // [0, 365]
	doe := yoe*365 + yoe/4 - yoe/100 + doy // [0, 146096]
	return era*146097 + doe - 719468
}

// ParseDateToDays 解析日期串(取首个 YYYY-MM-DD)→ epoch 天数。失败返回 (0, false)。
//
// ★ 宽松解析:Trakt 给的是 `2024-05-01T12:00:00.000Z`,Bangumi 给的是 `2024-05-01`,
// 还有的源给 `2024-05-01 12:00`。三种都得吃得下。
func ParseDateToDays(s string) (int64, bool) {
	datePart := s
	if i := strings.IndexAny(s, "T "); i >= 0 {
		datePart = s[:i]
	}
	seg := strings.SplitN(datePart, "-", 3)
	if len(seg) < 3 {
		return 0, false
	}
	y, err1 := strconv.ParseInt(strings.TrimSpace(seg[0]), 10, 64)
	m, err2 := strconv.ParseInt(strings.TrimSpace(seg[1]), 10, 64)
	d, err3 := strconv.ParseInt(strings.TrimSpace(seg[2]), 10, 64)
	if err1 != nil || err2 != nil || err3 != nil {
		return 0, false
	}
	if m < 1 || m > 12 || d < 1 || d > 31 {
		return 0, false
	}
	return DaysFromCivil(y, m, d), true
}

// DateStrDaysAgo 从当前时间偏移若干天,格式化成 YYYY-MM-DD(Trakt 日历起点用)。
func DateStrDaysAgo(offsetDays int64) string {
	days := NowMs()/1000/86400 - offsetDays
	y, m, d := CivilFromDays(days)
	return fmt.Sprintf("%04d-%02d-%02d", y, m, d)
}
