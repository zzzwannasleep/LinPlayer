package emby

// 播放上报三件套(start / progress / stopped)。
//
// ★★ 三次上报**必须带同一个 PlaySessionId**,而且要和取流那次是同一个。
// 不贯穿的表现是「看一半退出,续播进度不落地」—— 服务器把它们当成三次
// 互不相干的播放,最后一次 Stopped 找不到对应的会话,进度就丢了。
//

import (
	"bytes"
	"context"
	"encoding/json"
	"fmt"
	"net/http"
)

// secsToTicks 秒 → Emby 的 100 纳秒 tick。负数钳到 0。
func secsToTicks(secs float64) int64 {
	if secs < 0 {
		secs = 0
	}
	return int64(secs * 1e7)
}

func (c *Client) postReport(ctx context.Context, s *Session, endpoint string, body map[string]any) error {
	u := s.Server + "/Sessions/Playing" + endpoint
	b, _ := json.Marshal(body)
	req, err := http.NewRequestWithContext(ctx, http.MethodPost, u, bytes.NewReader(b))
	if err != nil {
		return fmt.Errorf("请求构造失败: %w", err)
	}
	req.Header.Set("X-Emby-Token", s.Token)
	req.Header.Set("X-Emby-Authorization", c.authHeader(s.DeviceID))
	req.Header.Set("Content-Type", "application/json")
	req.Header.Set("User-Agent", c.UA)
	resp, err := c.HTTP.Do(req)
	if err != nil {
		return fmt.Errorf("上报网络错误: %w", err)
	}
	defer resp.Body.Close()
	if resp.StatusCode < 200 || resp.StatusCode >= 300 {
		return fmt.Errorf("上报失败: HTTP %d", resp.StatusCode)
	}
	return nil
}

// ReportStart 起播上报。
func (c *Client) ReportStart(ctx context.Context, s *Session, t *PlaybackTarget, positionSecs float64) error {
	return c.postReport(ctx, s, "", map[string]any{
		"ItemId":        t.ItemID,
		"MediaSourceId": t.MediaSourceID,
		"PlaySessionId": t.PlaySessionID,
		"PlayMethod":    t.PlayMethod,
		"PositionTicks": secsToTicks(positionSecs),
		"CanSeek":       true,
		"IsPaused":      false,
	})
}

// ReportProgress 播放中上报。
func (c *Client) ReportProgress(ctx context.Context, s *Session, t *PlaybackTarget, positionSecs float64, paused bool) error {
	return c.postReport(ctx, s, "/Progress", map[string]any{
		"ItemId":        t.ItemID,
		"MediaSourceId": t.MediaSourceID,
		"PlaySessionId": t.PlaySessionID,
		"PlayMethod":    t.PlayMethod,
		"PositionTicks": secsToTicks(positionSecs),
		"IsPaused":      paused,
		"EventName":     "timeupdate",
	})
}

// ReportStopped 停播上报。
//
// ★ 这条**不带 PlayMethod** —— 照 Rust 版原样。别「统一一下」:
// 上报体的字段集是服务器认的契约,多给一个字段不见得无害。
func (c *Client) ReportStopped(ctx context.Context, s *Session, t *PlaybackTarget, positionSecs float64) error {
	return c.postReport(ctx, s, "/Stopped", map[string]any{
		"ItemId":        t.ItemID,
		"MediaSourceId": t.MediaSourceID,
		"PlaySessionId": t.PlaySessionID,
		"PositionTicks": secsToTicks(positionSecs),
	})
}
