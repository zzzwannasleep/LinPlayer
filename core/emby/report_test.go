package emby

import (
	"context"
	"encoding/json"
	"io"
	"net/http"
	"net/http/httptest"
	"testing"
)

// ★★ 三次上报**必须带同一个 PlaySessionId**,而且要和取流那次是同一个。
//
// 不贯穿的表现是「看一半退出,续播进度不落地」—— 服务器把它们当成三次
// 互不相干的播放,最后那次 Stopped 找不到对应会话,进度就丢了。
// 这条只能在**请求体**上断言:三次响应都是 204,从外面看不出任何异常。
func TestReport三次共用同一个PlaySessionId(t *testing.T) {
	type hit struct {
		path string
		body map[string]any
	}
	var hits []hit
	up := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.URL.Path == "/Items/it1/PlaybackInfo" {
			_, _ = w.Write([]byte(`{"PlaySessionId":"PSID-1","MediaSources":[{"Id":"ms","Container":"mkv"}]}`))
			return
		}
		b, _ := io.ReadAll(r.Body)
		var m map[string]any
		_ = json.Unmarshal(b, &m)
		hits = append(hits, hit{r.URL.Path, m})
		w.WriteHeader(204)
	}))
	defer up.Close()
	ResetRangePrefixCache()

	c := NewClient("test")
	s := &Session{Server: up.URL, Token: "t", UserID: "u", DeviceID: "d"}
	target, err := c.ResolveStream(context.Background(), s, "it1", "", "")
	if err != nil {
		t.Fatal(err)
	}
	ctx := context.Background()
	if err := c.ReportStart(ctx, s, target, 12); err != nil {
		t.Fatal(err)
	}
	if err := c.ReportProgress(ctx, s, target, 34, true); err != nil {
		t.Fatal(err)
	}
	if err := c.ReportStopped(ctx, s, target, 56); err != nil {
		t.Fatal(err)
	}

	if len(hits) != 3 {
		t.Fatalf("该有三次上报,实得 %d", len(hits))
	}
	for i, h := range hits {
		if h.body["PlaySessionId"] != "PSID-1" {
			t.Fatalf("第 %d 次上报的 PlaySessionId 不是取流那次的: %v —— 进度会落不了地", i+1, h.body["PlaySessionId"])
		}
		if h.body["ItemId"] != "it1" || h.body["MediaSourceId"] != "ms" {
			t.Fatalf("第 %d 次上报的条目/版本不对: %+v", i+1, h.body)
		}
	}
	// 端点
	for i, want := range []string{"/Sessions/Playing", "/Sessions/Playing/Progress", "/Sessions/Playing/Stopped"} {
		if hits[i].path != want {
			t.Errorf("第 %d 次上报打错端点:%s(期望 %s)", i+1, hits[i].path, want)
		}
	}
	// 位置换算:秒 → 100 纳秒 tick
	if got := hits[0].body["PositionTicks"].(float64); got != 12*1e7 {
		t.Errorf("start 的位置换算不对: %v", got)
	}
	if got := hits[2].body["PositionTicks"].(float64); got != 56*1e7 {
		t.Errorf("stopped 的位置换算不对: %v", got)
	}
	// progress 要带暂停状态和 EventName
	if hits[1].body["IsPaused"] != true || hits[1].body["EventName"] != "timeupdate" {
		t.Errorf("progress 的字段不对: %+v", hits[1].body)
	}
	// ★ Stopped **不带 PlayMethod** —— 照黄金实现原样,别「统一一下」
	if _, has := hits[2].body["PlayMethod"]; has {
		t.Error("Stopped 不该带 PlayMethod:上报体的字段集是服务器认的契约")
	}
}

// 负数位置钳到 0 —— 播放器在 seek 边界上偶尔会给出 -0.001 这种值,
// 原样送上去服务器会把它当成一个非法 tick。
func TestSecsToTicks(t *testing.T) {
	if got := secsToTicks(-1); got != 0 {
		t.Errorf("负数该钳到 0,实得 %d", got)
	}
	if got := secsToTicks(1.5); got != 15000000 {
		t.Errorf("1.5 秒该是 15000000 tick,实得 %d", got)
	}
}
