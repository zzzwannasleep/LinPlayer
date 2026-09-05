package segments

import (
	"context"
	"encoding/json"
	"fmt"
	"net/http"
	"net/url"
	"strconv"

	"linplayer/core/bus"
	"linplayer/core/httpx"
)

/* 三个源的端点都是照**权威 spec** 抄的,不是照第三方文章:
     IntroDB    api-1.json(官方 OpenAPI)
     TheIntroDB https://theintrodb.org/openapi.yaml(v3;api 根的 JSON 指过去的)
     AniSkip    https://api.aniskip.com/api-docs-json(/api-docs.json 是 404)
   改端点前先重新拉一次 spec —— 这三家都在活跃改版。
   写成 var 是为了让测试指向 httptest:不指的话这三个客户端一条都测不了,
   而「测不了」的代码就是**永远没跑过**的代码。 */
var (
	introDBBase    = "https://api.introdb.app"
	theIntroDBBase = "https://api.theintrodb.org/v3"
	aniSkipBase    = "https://api.aniskip.com/v2"
)

// errRateLimited 被限流。**必须和「没有数据」分开** ——
// 本仓踩过:弹弹 Play 整天回 429,界面上一直显示「未找到」,查了几个月。
var errRateLimited = fmt.Errorf("对方在限流(429)")

func logSourceErr(name string, err error) {
	bus.Logf("debug", "[片头源] %s: %v", name, err)
}

// get 打一个 JSON 接口。404 当「这一集没有数据」,回 (nil, nil)。
func get(ctx context.Context, u string) ([]byte, error) {
	b, code, err := httpx.GetJSON(ctx, httpx.Client(), u, http.Header{})
	if err != nil {
		return nil, err
	}
	switch {
	case code == http.StatusNotFound:
		return nil, nil
	case code == http.StatusTooManyRequests:
		return nil, errRateLimited
	case code < 200 || code >= 300:
		return nil, fmt.Errorf("HTTP %d", code)
	}
	return b, nil
}

// ---------------------------------------------------------------- IntroDB

// introDB 用 IMDb id + 季集号查。只有电视剧,电影它没有。
func introDB(ctx context.Context, m Meta) (*Result, error) {
	if m.IMDb == "" || m.IsMovie || m.Season <= 0 || m.Episode <= 0 {
		return nil, nil
	}
	q := url.Values{
		"imdb_id": {m.IMDb},
		"season":  {strconv.Itoa(m.Season)},
		"episode": {strconv.Itoa(m.Episode)},
	}
	b, err := get(ctx, introDBBase+"/segments?"+q.Encode())
	if b == nil || err != nil {
		return nil, err
	}
	var raw struct {
		Intro *struct {
			StartSec *float64 `json:"start_sec"`
			EndSec   *float64 `json:"end_sec"`
		} `json:"intro"`
		Outro *struct {
			StartSec *float64 `json:"start_sec"`
			EndSec   *float64 `json:"end_sec"`
		} `json:"outro"`
	}
	if err := json.Unmarshal(b, &raw); err != nil {
		return nil, err
	}
	out := &Result{}
	if raw.Intro != nil && raw.Intro.StartSec != nil && raw.Intro.EndSec != nil {
		out.Intro = sane(&Range{*raw.Intro.StartSec, *raw.Intro.EndSec}, m.RuntimeSecs)
	}
	if raw.Outro != nil && raw.Outro.StartSec != nil && raw.Outro.EndSec != nil {
		out.Outro = sane(&Range{*raw.Outro.StartSec, *raw.Outro.EndSec}, m.RuntimeSecs)
	}
	return out, nil
}

// ---------------------------------------------------------------- TheIntroDB

// theIntroDB 电影和剧都有。
//
// ★ id 优先级 tmdb > tvdb > imdb 是**它自己文档定的**:用后两个时服务端要现查一次映射,
// 更慢而且它明说「可能不准」。
// ★ 片尾在这儿叫 credits,不叫 outro。
// ★ 每种段是**数组**(同一集可能有多段),而且没有数据时该字段整个不出现。
func theIntroDB(ctx context.Context, m Meta) (*Result, error) {
	q := url.Values{}
	switch {
	case m.TMDb != "":
		q.Set("tmdb_id", m.TMDb)
	case m.TVDb != "":
		q.Set("tvdb_id", m.TVDb)
	case m.IMDb != "":
		q.Set("imdb_id", m.IMDb)
	default:
		return nil, nil
	}
	if !m.IsMovie && m.Season > 0 && m.Episode > 0 {
		q.Set("season", strconv.Itoa(m.Season))
		q.Set("episode", strconv.Itoa(m.Episode))
	}
	if m.RuntimeSecs > 0 {
		q.Set("duration_ms", strconv.FormatInt(int64(m.RuntimeSecs*1000), 10))
	}
	b, err := get(ctx, theIntroDBBase+"/media?"+q.Encode())
	if b == nil || err != nil {
		return nil, err
	}
	var raw struct {
		Intro   []msRange `json:"intro"`
		Credits []msRange `json:"credits"`
	}
	if err := json.Unmarshal(b, &raw); err != nil {
		return nil, err
	}
	return &Result{
		Intro: sane(firstRange(raw.Intro, m.RuntimeSecs), m.RuntimeSecs),
		Outro: sane(firstRange(raw.Credits, m.RuntimeSecs), m.RuntimeSecs),
	}, nil
}

type msRange struct {
	StartMs *int64 `json:"start_ms"`
	EndMs   *int64 `json:"end_ms"`
}

// firstRange 取第一段。
//
// ★ null 有含义:开始为 null = 从 0 起,结束为 null = 一直到片尾 ——
// 当成 0 处理的话「片尾从 95 分钟到 0 分钟」,区间当场作废。
func firstRange(list []msRange, runtimeSecs float64) *Range {
	if len(list) == 0 {
		return nil
	}
	r := list[0]
	start := 0.0
	if r.StartMs != nil {
		start = float64(*r.StartMs) / 1000
	}
	end := runtimeSecs
	if r.EndMs != nil {
		end = float64(*r.EndMs) / 1000
	}
	if end <= 0 {
		return nil
	}
	return &Range{start, end}
}

// ---------------------------------------------------------------- AniSkip

// aniSkip 只有动画,而且只认 MyAnimeList id。
//
// ★ episodeLength 是**必填**参数(spec 里 required),不是可选的 ——
// 漏了它整条请求 400,而 400 长得跟「这一集没有数据」很像。
// ★ 判有没有看 found 字段,不是看 HTTP 码。
func aniSkip(ctx context.Context, m Meta) (*Result, error) {
	if m.MAL == "" || m.Episode <= 0 {
		return nil, nil
	}
	q := url.Values{}
	for _, t := range []string{"op", "ed", "mixed-op", "mixed-ed"} {
		q.Add("types", t)
	}
	q.Set("episodeLength", strconv.FormatFloat(m.RuntimeSecs, 'f', 3, 64))
	u := fmt.Sprintf("%s/skip-times/%s/%d?%s",
		aniSkipBase, url.PathEscape(m.MAL), m.Episode, q.Encode())
	b, err := get(ctx, u)
	if b == nil || err != nil {
		return nil, err
	}
	var raw struct {
		Found   bool `json:"found"`
		Results []struct {
			Interval struct {
				StartTime float64 `json:"startTime"`
				EndTime   float64 `json:"endTime"`
			} `json:"interval"`
			SkipType string `json:"skipType"`
		} `json:"results"`
	}
	if err := json.Unmarshal(b, &raw); err != nil {
		return nil, err
	}
	if !raw.Found {
		return nil, nil
	}
	out := &Result{}
	for _, r := range raw.Results {
		seg := &Range{r.Interval.StartTime, r.Interval.EndTime}
		switch r.SkipType {
		case "op", "mixed-op":
			if out.Intro == nil {
				out.Intro = sane(seg, m.RuntimeSecs)
			}
		case "ed", "mixed-ed":
			if out.Outro == nil {
				out.Outro = sane(seg, m.RuntimeSecs)
			}
		}
	}
	return out, nil
}
