package bus

// 事件队列背压(SPEC §5.11)。
//
// ★★ 这个文件存在的理由写在 TODO.md T10 里:实现全在,**判据一条没验**。
// 「别把『代码写了』当成『验过了』」—— 队列这种东西错了不会崩,
// 只会表现成「UI 上一个转不完的圈」或者「有时候收得到有时候收不到」。

import (
	"encoding/json"
	"testing"
	"time"
)

// 分级表照 SPEC §5.11 那张表逐条钉住。改了分级就等于改了故障形态。
func Test事件分级(t *testing.T) {
	for _, c := range []struct {
		e    Event
		want evClass
		why  string
	}{
		{Event{T: "result"}, clNeverDrop, "丢一条 = 某个 seq 永远没有回音"},
		{Event{T: "partial"}, clNeverDrop, "流式中间结果同 result"},
		{Event{T: "eof"}, clNeverDrop, "消费者靠它退出循环"},
		{Event{T: "event", Name: "log"}, clDroppable, "日志不值得为它阻塞播放"},
		{Event{T: "event", Name: "player.status"}, clMerge, "只有最新值有意义"},
		{Event{T: "event", Name: "prefetch.stats"}, clMerge, "同上"},
		{Event{T: "event", Name: "download.progress"}, clMerge, "同上"},
		{Event{T: "event", Name: "config.changed"}, clNeverDrop, "丢了界面显示过期数据且永不自愈"},
		{Event{T: "event", Name: "data.invalidate"}, clNeverDrop, "同上"},
		{Event{T: "event", Name: "plugin.ui"}, clNeverDrop, "丢了插件的弹窗永远不出现"},
	} {
		if got := classOf(&c.e); got != c.want {
			t.Errorf("%s/%s 分到了 %v,应为 %v —— %s", c.e.T, c.e.Name, got, c.want, c.why)
		}
	}
}

// result 永不丢:队列满了要**阻塞产生方**,不许悄悄丢掉。
func Test队列_result满了要阻塞而不是丢(t *testing.T) {
	q := newQueue()
	defer q.close()
	for i := 0; i < queueCap; i++ {
		q.push(&Event{T: "result", Seq: int64(i + 1)})
	}
	if n := q.stats()["len"].(int); n != queueCap {
		t.Fatalf("装了 %d 条,实得 %d", queueCap, n)
	}

	done := make(chan struct{})
	go func() { q.push(&Event{T: "result", Seq: 9999}); close(done) }()
	select {
	case <-done:
		t.Fatal("队列满了 push 却立刻返回 —— 这条 result 被丢了,对应的 seq 永远等不到回音(UI 上一个转不完的圈)")
	case <-time.After(150 * time.Millisecond):
	}

	// 消费一条腾出位置,阻塞的那条必须被唤醒 —— 否则是生产方永久卡死,更糟。
	if e := q.pop(200); e == nil || e.Seq != 1 {
		t.Fatalf("先进先出坏了: %+v", e)
	}
	select {
	case <-done:
	case <-time.After(2 * time.Second):
		t.Fatal("腾出位置后阻塞的 push 没被唤醒 —— 生产方永久卡死")
	}
}

// 高频状态事件原地合并,而且留下的必须是**最新**那条。
func Test队列_高频状态事件合并且留最新(t *testing.T) {
	q := newQueue()
	defer q.close()
	for i := 1; i <= 10; i++ {
		d, _ := json.Marshal(map[string]int{"position": i})
		q.push(&Event{T: "event", Name: "player.status", Data: d, mergeKey: "player.status"})
	}
	if n := q.stats()["len"].(int); n != 1 {
		t.Fatalf("10 条同键状态事件应合并成 1 条,实得 %d —— UI 卡一下就会收到一串陈旧的播放位置", n)
	}
	e := q.pop(200)
	if e == nil || string(e.Data) != `{"position":10}` {
		t.Fatalf("合并后要留最新值,实得 %s", e.Data)
	}
}

// 不同 id 的状态事件不许互相吃掉(两个下载各自的进度)。
func Test队列_不同mergeKey互不影响(t *testing.T) {
	q := newQueue()
	defer q.close()
	q.push(&Event{T: "event", Name: "download.progress", mergeKey: "download.progress/A"})
	q.push(&Event{T: "event", Name: "download.progress", mergeKey: "download.progress/B"})
	if n := q.stats()["len"].(int); n != 2 {
		t.Fatalf("两个不同 id 的进度被合成了 %d 条 —— 会有一个下载的进度条永远不动", n)
	}
}

// 日志可丢,但**丢了必须说**:静默丢弃会让人误判「这段时间没事发生」。
func Test队列_日志可丢且丢了必须带计数(t *testing.T) {
	q := newQueue()
	defer q.close()
	for i := 0; i < queueCap; i++ {
		q.push(&Event{T: "result", Seq: int64(i + 1)})
	}
	const dropped = 7
	for i := 0; i < dropped; i++ {
		q.push(&Event{T: "event", Name: "log"})
	}
	if n := q.stats()["len"].(int); n != queueCap {
		t.Fatalf("日志把队列撑过了上限(%d)—— 可丢类没在丢", n)
	}
	if d := q.stats()["droppedLogs"].(int); d != dropped {
		t.Fatalf("丢弃计数应为 %d,实得 %d", dropped, d)
	}

	q.pop(200) // 腾一个位置
	q.push(&Event{T: "event", Name: "log"})

	var carried int = -1
	for i := 0; i < queueCap+2; i++ {
		e := q.pop(200)
		if e == nil {
			break
		}
		if e.Name == "log" {
			carried = e.Dropped
			break
		}
	}
	if carried != dropped {
		t.Fatalf("下一条 log 应带 dropped=%d,实得 %d —— 丢了不说等于骗人", dropped, carried)
	}
	if d := q.stats()["droppedLogs"].(int); d != 0 {
		t.Fatalf("计数带出去之后要清零,实得 %d(会重复上报)", d)
	}
}

// 消费停滞检测。TODO T10 原话:「『停止消费 10 s』这条压根没跑过」。
//
// ★ 本条覆盖 stallAfter / stallTick 两个包级变量,**不许和别的测试并行**。
func Test队列_停止消费要标停滞(t *testing.T) {
	oldAfter, oldTick := stallAfter, stallTick
	stallAfter, stallTick = 60*time.Millisecond, 20*time.Millisecond
	defer func() { stallAfter, stallTick = oldAfter, oldTick }()

	q := newQueue()
	defer q.close()
	q.push(&Event{T: "event", Name: "data.invalidate"})

	deadline := time.Now().Add(3 * time.Second)
	for time.Now().Before(deadline) {
		if q.stats()["stalled"].(bool) {
			return
		}
		time.Sleep(10 * time.Millisecond)
	}
	t.Fatal("积压且长时间没人取,stalled 没被标起来 —— 「UI 事件线程被谁堵住了」将没有任何线索")
}

// 消费恢复之后停滞标记要落下去,否则诊断包会一直显示「卡着」。
func Test队列_恢复消费要清停滞(t *testing.T) {
	oldAfter, oldTick := stallAfter, stallTick
	stallAfter, stallTick = 60*time.Millisecond, 20*time.Millisecond
	defer func() { stallAfter, stallTick = oldAfter, oldTick }()

	q := newQueue()
	defer q.close()
	q.push(&Event{T: "event", Name: "data.invalidate"})
	for i := 0; i < 300 && !q.stats()["stalled"].(bool); i++ {
		time.Sleep(10 * time.Millisecond)
	}
	q.pop(200)
	if q.stats()["stalled"].(bool) {
		t.Fatal("取过之后 stalled 还挂着 —— 诊断包会一直误报卡顿")
	}
}

// 关停必须发 eof。不发的话消费者永远阻塞在 lp_next_event(-1) 上,进程退不干净
// —— Rust 版栽过同款(关掉程序还有残留进程)。
func Test队列_关停必须发eof(t *testing.T) {
	q := newQueue()
	q.close()
	e := q.pop(200)
	if e == nil || e.T != "eof" {
		t.Fatalf("关停要发 eof,实得 %+v", e)
	}
}

// 关停之后再 push 不许把事件塞进去(也不许 panic)。
func Test队列_关停后push是空操作(t *testing.T) {
	q := newQueue()
	q.close()
	q.pop(200) // 取走 eof
	q.push(&Event{T: "result", Seq: 1})
	if n := q.stats()["len"].(int); n != 0 {
		t.Fatalf("关停后还能入队 %d 条", n)
	}
}

// pop 超时要返回 nil,不能一直吊着 —— 宿主的事件线程靠这个超时做心跳。
func Test队列_pop超时返回nil(t *testing.T) {
	q := newQueue()
	defer q.close()
	t0 := time.Now()
	if e := q.pop(80); e != nil {
		t.Fatalf("空队列超时应返回 nil,实得 %+v", e)
	}
	if d := time.Since(t0); d < 60*time.Millisecond {
		t.Fatalf("超时 80ms 却只等了 %v —— 会把宿主的事件线程变成忙轮询", d)
	}
}
