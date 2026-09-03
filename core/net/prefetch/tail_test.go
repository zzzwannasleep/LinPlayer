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
//
//	而所有既有用例全绿。夹具不真实,测的就是另一个程序。
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

// 播放器**从块中间**读文件尾(mp4 的 moov 就在那儿)时,那一段必须进环形缓存。
//
// ☠☠ 原来走的是「残段」那条路:只拉播放器要的那一小截,**不落盘**。
// 于是 moov 在末尾的 mp4(没跑过 faststart 的,很常见)每次打开都得重下索引,
// 更要命的是——**别人再也打不开这条流了**。进度条缩略图正是这样:
// 它用第二个 mpv 从只读缓存端点开同一条流,拿不到 moov 就整个失败,
// 而唯一的现象是一句「打不开」。2026-09-03 真机自检四轮才定位到这里。
//
// ★ 断言必须**同时**验「只读端点能吐出这一段」——「has() 为真」只证明落盘了,
// 而缩略图那条路真正依赖的是只读端点吐得出来。
func TestC27_从块中间读文件尾也要落盘(t *testing.T) {
	const total = 9*ChunkSize + 12345
	body := make([]byte, total)
	for i := range body {
		body[i] = byte((i*11 + 5) & 0xff)
	}
	up := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		http.ServeContent(w, r, "video.mp4", time.Time{}, bytes.NewReader(body))
	}))
	t.Cleanup(up.Close)

	paths.SetRoot(t.TempDir())
	// 环钉在下限:装不下整片,于是「有没有落盘」这件事才有意义
	h, err := Start(context.Background(), up.URL+"/video.mp4", 2, 64*1024*1024, nil)
	if err != nil {
		t.Fatalf("起代理失败: %v", err)
	}
	t.Cleanup(h.Close)

	/* 学播放器读 moov:`Range: bytes=<末尾附近>-`,起点落在最后一段的**中间**。
	   ★ 不能用整段对齐的起点 —— 那条路本来就落盘,测了等于没测。 */
	off := int64(total) - 3000
	req, _ := http.NewRequest(http.MethodGet, h.URL, nil)
	req.Header.Set("Range", fmt.Sprintf("bytes=%d-", off))
	resp, err := http.DefaultClient.Do(req)
	if err != nil {
		t.Fatalf("读文件尾失败: %v", err)
	}
	got, _ := io.ReadAll(resp.Body)
	_ = resp.Body.Close()
	if !bytes.Equal(got, body[off:]) {
		t.Fatalf("文件尾内容对不上:得 %d 字节,期望 %d", len(got), int64(total)-off)
	}

	last := (int64(total)+ChunkSize-1)/ChunkSize - 1
	if !h.origin.disk.has(last) {
		t.Fatal("从块中间读过文件尾之后,那一段没进环形缓存 —— " +
			"moov 在末尾的 mp4 从此没人能重新打开(缩略图会静默失效)")
	}

	// 只读端点吐得出来才算数:缩略图那条路走的是它,不是 has()
	req2, _ := http.NewRequest(http.MethodGet, h.CachedURL, nil)
	req2.Header.Set("Range", fmt.Sprintf("bytes=%d-", off))
	r2, err := http.DefaultClient.Do(req2)
	if err != nil {
		t.Fatalf("只读端点读不到: %v", err)
	}
	defer r2.Body.Close()
	if r2.StatusCode == http.StatusRequestedRangeNotSatisfiable {
		t.Fatal("只读端点对文件尾回 416 —— 第二个 mpv 打不开这条流")
	}
	b2, _ := io.ReadAll(r2.Body)
	if !bytes.Equal(b2, body[off:]) {
		t.Fatalf("只读端点吐的文件尾对不上:得 %d 字节,期望 %d", len(b2), int64(total)-off)
	}
}
