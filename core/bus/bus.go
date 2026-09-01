package bus

// 命令注册表 + 分派 + panic 边界(SPEC §5.4 / §5.7 / §5.10)。

import (
	"context"
	"encoding/json"
	"fmt"
	"runtime/debug"
	"sync"
	"sync/atomic"
)

// 错误码(SPEC §5.4)。错误是对象不是字符串。
const (
	EAuth        = "E_AUTH"
	ENetwork     = "E_NETWORK"
	EUpstream    = "E_UPSTREAM"
	EUnsupported = "E_UNSUPPORTED"
	ENotFound    = "E_NOTFOUND"
	EPermission  = "E_PERMISSION"
	EInvalid     = "E_INVALID"
	EShutdown    = "E_SHUTDOWN"
	EInternal    = "E_INTERNAL"
)

// Handler 是一条命令的实现。
//
// 约定:
//   - 返回值会被序列化进 {"t":"result","ok":true,"data":…}
//   - 返回 error 会被转成 {"ok":false,"err":{…}};想指定 code 就返回 *Err
//   - 想发流式中间结果,用 Partial(seq, …)
type Handler func(ctx context.Context, seq int64, args map[string]any) (any, error)

// Err 是带 code 的错误。不带 code 的普通 error 一律归到 E_INTERNAL。
type Err struct {
	Code      string
	Msg       string
	Detail    string
	Retryable bool
}

func (e *Err) Error() string { return e.Code + ": " + e.Msg }

// NewErr 造一个带 code 的错误。
func NewErr(code, msg string, args ...any) *Err {
	e := &Err{Code: code, Msg: msg}
	if len(args) > 0 {
		if d, ok := args[0].(string); ok {
			e.Detail = d
		}
	}
	return e
}

// ---------------------------------------------------------------- 注册表

var (
	regMu    sync.RWMutex
	registry = map[string]Handler{}
)

// Register 注册一条命令。重复注册会 panic —— 那是编码错误,不该等到运行时才发现。
func Register(name string, h Handler) {
	regMu.Lock()
	defer regMu.Unlock()
	if _, dup := registry[name]; dup {
		panic("命令重复注册: " + name)
	}
	registry[name] = h
}

// Commands 返回已注册的命令名,给契约测试和 system.capabilities 用。
func Commands() []string {
	regMu.RLock()
	defer regMu.RUnlock()
	out := make([]string, 0, len(registry))
	for k := range registry {
		out = append(out, k)
	}
	return out
}

func lookup(name string) (Handler, bool) {
	regMu.RLock()
	defer regMu.RUnlock()
	h, ok := registry[name]
	return h, ok
}

// ---------------------------------------------------------------- 状态

var (
	q *queue

	inflightMu sync.Mutex
	inflight   = map[int64]context.CancelFunc{}

	panicCount   atomic.Int64
	started      atomic.Bool
	shuttingDown atomic.Bool
)

// Started 报告 lp_init 是否已经跑过。
func Started() bool { return started.Load() }

// ShuttingDown 报告是否已经关停。
func ShuttingDown() bool { return shuttingDown.Load() }

// PanicCount 累计 panic 次数,给诊断包用。
func PanicCount() int64 { return panicCount.Load() }

// ---------------------------------------------------------------- 事件出口

// Logf 把日志打进事件队列。log 是**可丢**类 —— 日志重要,但不值得为它阻塞播放。
func Logf(level, format string, a ...any) {
	if q == nil {
		return
	}
	d, _ := json.Marshal(map[string]string{"level": level, "msg": fmt.Sprintf(format, a...)})
	q.push(&Event{T: "event", Name: "log", Data: d})
}

// Emit 推一条主动事件(seq 恒为 0)。mergeKey 非空时走「原地替换」那一档(SPEC §5.11)。
func Emit(name string, data any, mergeKey string) {
	if q == nil {
		return
	}
	d, err := json.Marshal(data)
	if err != nil {
		Logf("error", "事件 %s 序列化失败: %v", name, err)
		return
	}
	q.push(&Event{T: "event", Name: name, Data: d, mergeKey: mergeKey})
}

// Partial 发一条流式中间结果(SPEC §5.7)。
func Partial(seq int64, data any) {
	if q == nil {
		return
	}
	d, _ := json.Marshal(data)
	q.push(&Event{T: "partial", Seq: seq, Data: d})
}

func okResult(seq int64, v any) {
	d, err := json.Marshal(v)
	if err != nil {
		failResult(seq, &Err{Code: EInternal, Msg: "结果序列化失败", Detail: err.Error()})
		return
	}
	t := true
	q.push(&Event{T: "result", Seq: seq, OK: &t, Data: d})
}

func failResult(seq int64, e *Err) {
	f := false
	q.push(&Event{T: "result", Seq: seq, OK: &f,
		Err: &ErrObj{Code: e.Code, Msg: e.Msg, Retryable: e.Retryable, Detail: e.Detail}})
}

// ---------------------------------------------------------------- worker 池
//
// ★★ 命令**不在 cgo 调用里现开 goroutine**,而是投给 Init 时就建好的 worker。
//
// 这不是性能优化,是**正确性**(SPIKE-2 实测,2026-08-31,.NET 10 宿主):
//   · 在 cgo 调用里 `go func(){…}()` 现开的 goroutine 上做空指针解引用
//     -> 进程被 0xC0000409(fastfail)硬杀,recover 完全没机会,
//        连 GOTRACEBACK=system 都不打印任何东西
//   · 同一个故障放在 Init 时就存在的后台 goroutine 上 -> recover 正常接住
//   · 同一个库换成 Python 宿主,两种情况都 recover 得住
//
// 推断:现开的 goroutine 可能被调度到「被 Go 临时收编的宿主线程」上,
// 而那条线程的异常处理归宿主运行时管。worker 池让命令永远跑在 Go 自己的线程上。
//
// 报告:docs/go-migration/spikes/SPIKE-2-go-ffi.md §4.2

type job struct {
	seq  int64
	cmd  string
	args string
	ctx  context.Context
}

var jobs chan job

// WorkerCount 是 worker 数量。
//
// ponytail: 8 是拍的,没有压测依据。长任务(下载 / 预取)会不会把池占满、
// 要不要分池,还没验(SPIKE-2 §8 遗留问题 4)。
const WorkerCount = 8

// Init 起事件队列与 worker 池。幂等。
func Init() {
	if !started.CompareAndSwap(false, true) {
		return
	}
	q = newQueue()
	jobs = make(chan job, 256)
	for i := 0; i < WorkerCount; i++ {
		go func() {
			for j := range jobs {
				runGuarded(j)
			}
		}()
	}
}

// Call 受理一条命令。立即返回,不阻塞。
func Call(seq int64, cmd, argsJSON string) error {
	if !started.Load() {
		return NewErr(EInvalid, "核心层还没 init")
	}
	if shuttingDown.Load() {
		return NewErr(EShutdown, "核心层已关停")
	}
	if seq == 0 {
		// seq 由宿主分配,必须单调递增且非 0
		return NewErr(EInvalid, "seq 不能为 0")
	}
	ctx, cancel := context.WithCancel(context.Background())
	inflightMu.Lock()
	inflight[seq] = cancel
	inflightMu.Unlock()
	jobs <- job{seq: seq, cmd: cmd, args: argsJSON, ctx: ctx}
	return nil
}

// Invoke 在**当前 goroutine 上**同步跑一条已注册命令,结果直接返回,不进事件队列。
//
// 只给核心层内部的跨模块转发用(插件的 ctx.player / ctx.emby 就是靠它落到
// 已有的 player.* / emby.* 实现上)。**不要**拿它当宿主入口 —— 宿主必须走
// Call,那条路才有 seq / 取消 / worker 池那套保障。
//
// ★ 复用已注册的 handler 而不是另写一份:另写一份的后果是同一个能力在
// 命令层和插件层慢慢长成两个行为,而差异只有用户会撞见。
func Invoke(ctx context.Context, cmd string, args map[string]any) (out any, err error) {
	h, ok := lookup(cmd)
	if !ok {
		return nil, NewErr(ENotFound, "没有这条命令: %s", cmd)
	}
	defer func() {
		// 同 runGuarded:panic 跨不过 cgo,这里也得兜住。
		if r := recover(); r != nil {
			panicCount.Add(1)
			err = NewErr(EInternal, "命令 %s 内部错误: %v", cmd, r)
			out = nil
		}
	}()
	if args == nil {
		args = map[string]any{}
	}
	return h(ctx, 0, args)
}

// Cancel 取消一条在途命令。对已完成的 seq 是空操作。
func Cancel(seq int64) {
	inflightMu.Lock()
	c, ok := inflight[seq]
	inflightMu.Unlock()
	if ok {
		c()
	}
}

// NextEvent 阻塞取下一个事件。timeoutMs < 0 表示无限等;超时返回 nil。
//
// ★ 有且仅有**一个**消费者线程可以调它(SPEC §5.11)。
func NextEvent(timeoutMs int32) []byte {
	if q == nil {
		return nil
	}
	e := q.pop(timeoutMs)
	if e == nil {
		return nil
	}
	b, err := MarshalEvent(e)
	if err != nil {
		return nil
	}
	return b
}

// Shutdown 关停。发 eof 让消费者退出循环。
func Shutdown() {
	if !shuttingDown.CompareAndSwap(false, true) {
		return
	}
	inflightMu.Lock()
	for _, c := range inflight {
		c()
	}
	inflightMu.Unlock()
	if q != nil {
		q.close()
	}
}

// QueueStats 给 system.exportDiagnostics 用。
func QueueStats() map[string]any {
	if q == nil {
		return map[string]any{}
	}
	return q.stats()
}

// runGuarded 是 panic 边界。
//
// ★ Go 的 panic 跨不过 cgo,一个没 recover 的 panic **直接终止整个进程**,
// 宿主的 try/catch 一个都拦不住 —— 用户看到的是「程序突然没了」且没有任何线索。
// 所以这里的 recover 不是编码习惯,是契约(SPEC §5.10)。
func runGuarded(j job) {
	defer func() {
		inflightMu.Lock()
		delete(inflight, j.seq)
		inflightMu.Unlock()

		if r := recover(); r != nil {
			panicCount.Add(1)
			// recover 之后必须做三件事,少一件这条契约就白写:
			// ① 把栈写进日志(否则 recover 等于把 bug 藏起来)
			Logf("error", "命令 %s 发生 panic: %v | %s", j.cmd, r, string(debug.Stack()))
			// ② 回一个 E_INTERNAL 给等待的 seq(否则调用方永远等不到 result,
			//    UI 上表现为「点了没反应」,比崩溃更难查)
			failResult(j.seq, &Err{Code: EInternal, Msg: "核心层内部错误", Detail: fmt.Sprint(r)})
			// ③ 计数并透出,让诊断包看得到「这个版本 panic 了多少次」
			Logf("warn", "累计 panic 次数 = %d", panicCount.Load())
		}
	}()

	h, ok := lookup(j.cmd)
	if !ok {
		// 未注册的命令是**调用方的 bug**,不是「条目不存在」——
		// 所以是 E_INVALID(记日志)而不是 E_NOTFOUND(空态)。
		failResult(j.seq, &Err{Code: EInvalid, Msg: "未注册的命令", Detail: j.cmd})
		return
	}

	var args map[string]any
	if j.args != "" {
		if err := json.Unmarshal([]byte(j.args), &args); err != nil {
			failResult(j.seq, &Err{Code: EInvalid, Msg: "参数不是合法 JSON", Detail: err.Error()})
			return
		}
	}

	out, err := h(j.ctx, j.seq, args)
	if err != nil {
		if e, ok := err.(*Err); ok {
			failResult(j.seq, e)
		} else {
			failResult(j.seq, &Err{Code: EInternal, Msg: err.Error()})
		}
		return
	}
	if out == nil {
		out = map[string]any{}
	}
	okResult(j.seq, out)
}
