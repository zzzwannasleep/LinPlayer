package prefetch

import (
	"fmt"
	"net"
	"net/url"
	"testing"
	"time"
)

/*
☠☠☠ 「已缓存的位置取不到图」剩下的那一半根因(2026-09-04)。

	ffmpeg 打开一个 mp4 时先发 `Range: bytes=0-` 读文件头,**只读几百 KB**
	认出 moov 的位置就把这条连接关了,另开一条从 moov 处读。
	而代理这边正在为它拉整个 4MB 的分段 0 —— 连接一关,fetchCtx 当场取消,
	**分段 0 半途而废、不落盘**。

	后果:环形缓存里从此没有文件头。正片照放(它自己那条连接边拉边吐),
	但任何人想**重新打开**这条流都失败 —— 进度条缩略图那个 mpv 实例
	拿到的就是一句「打不开」,而 spans 显示 30% 已缓存,看着完全正常。
	端到端实测复现过:spans = 0.70-1.00,整条时间轴没有头。

	★ 这条用例专门造「读一点就断」这个形状。上一条相关用例(首段不对齐 →
	  只拉残段)已经被 pinned() 挡住了,但它挡不到**连接活得比这一段短**。
	★ 反向注入:把 serve.go 里 pin 那个分支去掉(让 s.done 照样取消),这条当场红。
*/
func TestC30_钉住的段连接断了也要拉完落盘(t *testing.T) {
	up := newUpstream(t)
	// ★ 慢一点,好让「读几百 KB 就断」真的发生在这一段拉完之前。
	//   不慢的话本地环回一瞬间就拉完了,这个形状根本造不出来 —— 假绿。
	up.slow = 8 * time.Millisecond
	h := startProxy(t, up, 2, 64*ChunkSize)

	// 手写请求:从 0 开始要,只读几百 KB 就把 socket 关掉 —— ffmpeg 探头就是这么干的。
	u, _ := url.Parse(h.URL)
	conn, err := net.Dial("tcp", u.Host)
	if err != nil {
		t.Fatalf("连不上代理: %v", err)
	}
	fmt.Fprintf(conn, "GET %s HTTP/1.1\r\nHost: %s\r\nRange: bytes=0-\r\n\r\n", u.Path, u.Host)
	buf := make([]byte, 256*1024)
	read := 0
	_ = conn.SetReadDeadline(time.Now().Add(10 * time.Second))
	for read < 200*1024 {
		n, err := conn.Read(buf)
		if n > 0 {
			read += n
		}
		if err != nil {
			break
		}
	}
	_ = conn.Close() // ★ 这一下就是 bug 的触发点
	if read < 1024 {
		t.Fatalf("只读到 %d 字节,这个形状没造出来", read)
	}

	/* 判据:分段 0 **最终**落盘。
	   ★ 要轮询等,不能读完就断言 —— 这条修复的意思正是「连接没了它还在拉」,
	     所以它必然在断开之后一小会儿才就绪。 */
	deadline := time.Now().Add(20 * time.Second)
	for time.Now().Before(deadline) {
		if h.origin.disk.has(0) {
			return
		}
		time.Sleep(100 * time.Millisecond)
	}
	t.Fatalf("连接断了之后分段 0 没落盘 —— 环形缓存里没有文件头,"+
		"任何人重新打开这条流都会失败(缩略图那条路就是这么哑掉的)。"+
		"当前 spans=%v", h.CachedSpans())
}

/*
不钉住的段**该取消就取消**。

	这一条是上面那条的护栏:只写上面那条的话,一个「所有段都不许取消」的实现
	也照样绿 —— 而那种实现下,用户跳一次进度条,每条被丢下的连接都要
	把 threads 段(12MB)拉完才罢休,纯烧流量。
*/
func TestC30b_没钉住的段连接断了要停(t *testing.T) {
	up := newUpstream(t)
	up.slow = 12 * time.Millisecond
	h := startProxy(t, up, 2, 64*ChunkSize)

	// 从第 3 段中间开始要(避开 0 / last-1 / last 那三段钉住位)
	start := 3*ChunkSize + 1024
	u, _ := url.Parse(h.URL)
	conn, err := net.Dial("tcp", u.Host)
	if err != nil {
		t.Fatalf("连不上代理: %v", err)
	}
	fmt.Fprintf(conn, "GET %s HTTP/1.1\r\nHost: %s\r\nRange: bytes=%d-\r\n\r\n", u.Path, u.Host, start)
	buf := make([]byte, 64*1024)
	_ = conn.SetReadDeadline(time.Now().Add(10 * time.Second))
	read := 0
	for read < 64*1024 {
		n, err := conn.Read(buf)
		if n > 0 {
			read += n
		}
		if err != nil {
			break
		}
	}
	_ = conn.Close()

	// 断开后再等一会儿:第 4 段(纯预取、没钉住)不该继续拉到落盘
	time.Sleep(2 * time.Second)
	if h.origin.disk.has(4) {
		t.Fatalf("连接早断了,第 4 段还是被拉完落了盘 —— 被丢下的连接在烧用户流量")
	}
}
