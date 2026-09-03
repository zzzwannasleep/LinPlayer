package prefetch

import (
	"bytes"
	"context"
	"crypto/md5"
	"fmt"
	"io"
	"net/http"
	"net/http/httptest"
	"testing"
	"time"

	"linplayer/core/paths"
)

// 判据:**总长不是整段倍数**时,整条流吐出来的字节要和上游一模一样。
//
// ☠☠ 别的用例里 `testTotal = 8 * ChunkSize` —— 永远整除,
// 于是「最后一段是残段」这条路**一次都没被走过**。真实视频文件几乎不可能整除。
//
// ★ 这条用例是从真机上倒推出来的:接上预热之后起播即 EOF(位置直接跳到片尾),
//   而所有既有用例全绿。夹具不真实,测的就是另一个程序。
func TestC26_总长不是整段倍数也要一字不差(t *testing.T) {
	// 9 段零一点:最后一段只有 12345 字节
	const total = 9*ChunkSize + 12345
	body := make([]byte, total)
	for i := range body {
		body[i] = byte((i*7 + 3) & 0xff)
	}
	up := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		http.ServeContent(w, r, "video.mkv", time.Time{}, bytes.NewReader(body))
	}))
	t.Cleanup(up.Close)

	paths.SetRoot(t.TempDir())
	h, err := Start(context.Background(), up.URL+"/video.mkv", 2, 64*1024*1024, nil)
	if err != nil {
		t.Fatalf("起代理失败: %v", err)
	}
	t.Cleanup(h.Close)

	resp, err := http.Get(h.URL)
	if err != nil {
		t.Fatalf("拉代理失败: %v", err)
	}
	defer resp.Body.Close()
	got, _ := io.ReadAll(resp.Body)
	if int64(len(got)) != total {
		t.Fatalf("长度对不上:得 %d 字节,期望 %d(差 %d)", len(got), total, total-int64(len(got)))
	}
	if fmt.Sprintf("%x", md5.Sum(got)) != fmt.Sprintf("%x", md5.Sum(body)) {
		t.Fatal("内容对不上 —— 有错位或串段")
	}

	// 尾部那一小截单独再要一次(播放器读 MKV 索引就是这么干的)
	req, _ := http.NewRequest(http.MethodGet, h.URL, nil)
	req.Header.Set("Range", fmt.Sprintf("bytes=%d-%d", total-5000, total-1))
	r2, err := http.DefaultClient.Do(req)
	if err != nil {
		t.Fatalf("拉尾部失败: %v", err)
	}
	defer r2.Body.Close()
	tail, _ := io.ReadAll(r2.Body)
	if len(tail) != 5000 {
		t.Fatalf("尾部长度对不上:得 %d,期望 5000", len(tail))
	}
	for i := range tail {
		if tail[i] != body[int(total)-5000+i] {
			t.Fatalf("尾部第 %d 字节对不上", i)
		}
	}
}
