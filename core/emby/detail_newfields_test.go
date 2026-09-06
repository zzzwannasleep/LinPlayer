package emby

import (
	"context"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"testing"
)

// played / season_id 是 2026-09-06 补的两个字段,黄金实现里**没有**它们。
//
// ☠ 缺 played:详情页的「已看」恒 false —— 点一下变已看,重进又变回未看。
// ☠ 缺 season_id:播放器的「选集」面板拿不到季主键,整个面板恒空。
//
// 差分对账语料钉不住它们(那份夹具里两项都没给,恒为 false / null),
// 所以真值映射只能在这里钉。
func TestItemDetail补的两个字段(t *testing.T) {
	up := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		_, _ = w.Write([]byte(`{
			"Id": "ep-9", "Name": "第 9 集", "Type": "Episode",
			"SeasonId": "se-2", "SeriesId": "sr-1",
			"UserData": {"Played": true, "PlaybackPositionTicks": 0}
		}`))
	}))
	defer up.Close()

	c := NewClient("test")
	d, err := c.Detail(context.Background(),
		&Session{Server: up.URL, Token: "t", UserID: "u"}, "ep-9", false)
	if err != nil {
		t.Fatal(err)
	}
	if !d.Played {
		t.Fatal("UserData.Played=true 时 played 必须是 true —— 否则详情页的「已看」永远点不亮")
	}
	if d.SeasonID == nil || *d.SeasonID != "se-2" {
		t.Fatalf("season_id 要取 SeasonId,实得 %v —— 取不到的话「选集」面板恒空", d.SeasonID)
	}

	// 反过来:没有这两项时不能凭空造出值
	b, _ := json.Marshal(d)
	if !json.Valid(b) {
		t.Fatal("序列化坏了")
	}
}

// 缺字段时的口径:false / null,不是「猜一个」。
func TestItemDetail缺这两个字段时不编值(t *testing.T) {
	up := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		_, _ = w.Write([]byte(`{"Id": "m-1", "Name": "某片", "Type": "Movie"}`))
	}))
	defer up.Close()

	d, err := NewClient("test").Detail(context.Background(),
		&Session{Server: up.URL, Token: "t", UserID: "u"}, "m-1", false)
	if err != nil {
		t.Fatal(err)
	}
	if d.Played {
		t.Fatal("没有 UserData 时 played 必须是 false")
	}
	if d.SeasonID != nil {
		t.Fatalf("电影没有季,season_id 必须是 null,实得 %v", *d.SeasonID)
	}
}
