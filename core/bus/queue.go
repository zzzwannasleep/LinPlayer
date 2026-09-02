// Package bus 是命令分派与事件队列 —— 核心层与 UI 之间的全部往来都经过这里。
//
// ★ 本包**不许**出现 //export、C. 或 unsafe.Pointer(SPEC §4.1)。
//
//	那些只能待在 core/ffi 里。违反这条 = 业务逻辑跟 FFI 焊死,以后没法单独测。
package bus

// 事件队列 —— 核心层与 UI 之间**唯一的下行通路**(SPEC §5.11)。
//
// 容量策略不能一刀切,一刀切会造出两类故障:
//   无界    -> UI 事件线程一卡就 OOM
//   无脑丢  -> 命令结果丢了,调用方永远挂着(UI 上是一个转不完的圈)
// 所以按事件类分级,见 classOf()。

import (
	"container/list"
	"encoding/json"
	"sync"
	"time"
)

// 队列容量。**这个数不是拍的**:4 Hz 的 player.status + 1 Hz 的 prefetch.stats + 日志,
// 正常态稳态占用是个位数;1024 意味着 UI 得卡住几十秒才碰得到底。
const queueCap = 1024

// 消费停滞阈值:队列非空且这么久没被取过,就写一条 warn。
// 这是「UI 事件线程被谁堵住了」的唯一线索。
//
// ★ 是 var 不是 const:测试要把它压到毫秒级,否则这条判据得跑 5 秒 —— 而
// 「跑得慢的测试等于没人跑的测试」。谁再加一条动这两个值的测试,
// **必须和现有那条串行**(护栏测试共用全局覆盖值的老坑)。
var (
	stallAfter = 5 * time.Second
	stallTick  = time.Second
)

// ErrObj 是错误对象(SPEC §5.4)。错误是对象不是字符串 ——
// 字符串到了 UI 层只能原样弹 toast,分不清「该重试」「该重登」「该报 bug」。
type ErrObj struct {
	Code      string `json:"code"`
	Msg       string `json:"msg"`
	Retryable bool   `json:"retryable"`
	Detail    string `json:"detail,omitempty"`
}

// Event 是事件信封(SPEC §5.2)。外层固定 {t, seq, ts, ...}。
type Event struct {
	T    string          `json:"t"` // result | partial | event | eof
	Seq  int64           `json:"seq"`
	Ts   int64           `json:"ts"`             // 单调毫秒,不是墙钟(SPEC §5.2)
	Name string          `json:"name,omitempty"` // t=event 时的事件名
	OK   *bool           `json:"ok,omitempty"`
	Data json.RawMessage `json:"data,omitempty"`
	Err  *ErrObj         `json:"err,omitempty"`
	// 丢弃计数:只出现在 log 事件上。**丢了必须说** —— 静默丢弃会让人
	// 误判「这段时间没事发生」。
	Dropped int `json:"dropped,omitempty"`

	mergeKey string // 不序列化。高频状态事件靠它原地替换
}

type evClass int

const (
	clNeverDrop evClass = iota // result / partial / config.changed / plugin.ui …
	clMerge                    // 高频状态事件:队列里已有同键的未消费事件就原地替换
	clDroppable                // log
)

// 高频状态事件表。这类事件**只有最新值有意义** ——
// UI 卡 2 秒后收到 8 条陈旧的播放位置,还不如收到 1 条最新的。
var mergeable = map[string]bool{
	"player.status":     true,
	"prefetch.stats":    true,
	"download.progress": true,
}

func classOf(e *Event) evClass {
	if e.T != "event" {
		return clNeverDrop // result / partial / eof
	}
	if e.Name == "log" {
		return clDroppable
	}
	if mergeable[e.Name] {
		return clMerge
	}
	return clNeverDrop
}

type queue struct {
	mu       sync.Mutex
	notEmpty *sync.Cond
	notFull  *sync.Cond
	l        *list.List
	closed   bool
	// 已丢弃但还没被上报出去的 log 条数
	droppedLogs int
	lastPop     time.Time
	stalled     bool
}

func newQueue() *queue {
	q := &queue{l: list.New(), lastPop: time.Now()}
	q.notEmpty = sync.NewCond(&q.mu)
	q.notFull = sync.NewCond(&q.mu)
	go q.watchStall()
	return q
}

// push 按事件类做背压。**produce 方是 goroutine,阻塞是安全的** ——
// 这正是 result 敢用「队列满则阻塞」的前提。
func (q *queue) push(e *Event) {
	q.mu.Lock()
	defer q.mu.Unlock()
	if q.closed {
		return
	}
	e.Ts = MonoMillis()

	switch classOf(e) {
	case clMerge:
		// 原地替换,不追加。找不到同键的才入队
		if e.mergeKey != "" {
			for el := q.l.Front(); el != nil; el = el.Next() {
				if old := el.Value.(*Event); old.mergeKey == e.mergeKey {
					el.Value = e
					return
				}
			}
		}
	case clDroppable:
		if q.l.Len() >= queueCap {
			q.droppedLogs++
			return
		}
		// 把攒下的丢弃计数挂在这一条上带出去
		if q.droppedLogs > 0 {
			e.Dropped = q.droppedLogs
			q.droppedLogs = 0
		}
	case clNeverDrop:
		// 队列满则阻塞产生方。丢一条 = 某个 seq 永远没有回音
		for q.l.Len() >= queueCap && !q.closed {
			q.notFull.Wait()
		}
		if q.closed {
			return
		}
	}

	q.l.PushBack(e)
	q.notEmpty.Signal()
}

// pop 取一条事件。timeoutMs < 0 表示无限等;超时返回 nil。
//
// ★ 有且仅有**一个**消费者线程可以调它。两个线程同时调不是竞态崩溃,
//
//	是事件被随机分给两个线程 —— 表现为「有时候收得到有时候收不到」。
func (q *queue) pop(timeoutMs int32) *Event {
	q.mu.Lock()
	defer q.mu.Unlock()

	if timeoutMs >= 0 {
		// Cond 没有带超时的 Wait,用一个定时器唤醒。
		// ponytail: 每次 pop 起一个 timer。超时路径只在 UI 空闲时走,不是热路。
		t := time.AfterFunc(time.Duration(timeoutMs)*time.Millisecond, func() {
			q.mu.Lock()
			q.notEmpty.Broadcast()
			q.mu.Unlock()
		})
		defer t.Stop()
		deadline := time.Now().Add(time.Duration(timeoutMs) * time.Millisecond)
		for q.l.Len() == 0 && !q.closed && time.Now().Before(deadline) {
			q.notEmpty.Wait()
		}
	} else {
		for q.l.Len() == 0 && !q.closed {
			q.notEmpty.Wait()
		}
	}

	el := q.l.Front()
	if el == nil {
		return nil
	}
	q.l.Remove(el)
	q.lastPop = time.Now()
	q.stalled = false
	q.notFull.Signal()
	return el.Value.(*Event)
}

// close 关停:发一条 eof 让消费者退出循环。
//
// ★ 不发 eof,消费者会永远阻塞在 lp_next_event(-1) 上,进程退不干净。
//
//	本项目在 Rust 版栽过同款(播放窗藏起来不销毁,窗口系统永远等不到
//	「最后一个窗口关闭」,关掉程序还有残留进程)。
func (q *queue) close() {
	q.mu.Lock()
	defer q.mu.Unlock()
	if q.closed {
		return
	}
	q.closed = true
	q.l.PushBack(&Event{T: "eof", Ts: MonoMillis()})
	q.notEmpty.Broadcast()
	q.notFull.Broadcast()
}

func (q *queue) watchStall() {
	tick := time.NewTicker(stallTick)
	defer tick.Stop()
	for range tick.C {
		q.mu.Lock()
		if q.closed {
			q.mu.Unlock()
			return
		}
		stall := q.l.Len() > 0 && time.Since(q.lastPop) > stallAfter && !q.stalled
		if stall {
			q.stalled = true
		}
		n := q.l.Len()
		q.mu.Unlock()
		if stall {
			// 不走 q.push(否则可能自己把自己堵住),直接打到宿主日志通道
			Logf("warn", "事件队列停滞:%d 条积压,已 %.0fs 没有被取过 —— UI 的事件线程被堵住了", n, stallAfter.Seconds())
		}
	}
}

// stats 给 system.exportDiagnostics 用
func (q *queue) stats() map[string]any {
	q.mu.Lock()
	defer q.mu.Unlock()
	return map[string]any{
		"len":          q.l.Len(),
		"cap":          queueCap,
		"droppedLogs":  q.droppedLogs,
		"stalled":      q.stalled,
		"sinceLastPop": time.Since(q.lastPop).Milliseconds(),
	}
}

var startMono = time.Now()

// MonoMillis 是**进程内单调时钟**,不是墙钟(SPEC §5.2)。
// 理由:出问题时要把「UI 什么时候收到」和「核心层什么时候发出」并排看。
func MonoMillis() int64 { return time.Since(startMono).Milliseconds() }

// MarshalEvent 把事件序列化成宿主要吃的 JSON。
// 外层信封固定为 {"t","seq","ts",...}(SPEC §5.2),`ts` 是必需字段。
func MarshalEvent(e *Event) ([]byte, error) { return json.Marshal(e) }
