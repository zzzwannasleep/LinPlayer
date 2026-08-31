package main

// 命令分发 + panic 边界(SPEC §5.4 / §5.7 / §5.10)。

import (
	"context"
	"encoding/json"
	"fmt"
	"os"
	"runtime"
	"runtime/debug"
	"sync"
	"sync/atomic"
	"time"
)

var (
	q *queue

	inflightMu sync.Mutex
	inflight   = map[int64]context.CancelFunc{}

	panicCount atomic.Int64
	started    atomic.Bool
	shutdown   atomic.Bool
)

// logf 把日志打进事件队列。log 是**可丢**类 —— 日志重要,但不值得为它阻塞播放。
func logf(level, format string, a ...any) {
	if q == nil {
		return
	}
	d, _ := json.Marshal(map[string]string{"level": level, "msg": fmt.Sprintf(format, a...)})
	q.push(&event{T: "event", Name: "log", Data: d})
}

func okResult(seq int64, v any) {
	d, err := json.Marshal(v)
	if err != nil {
		failResult(seq, "E_INTERNAL", "结果序列化失败", err.Error(), false)
		return
	}
	t := true
	q.push(&event{T: "result", Seq: seq, OK: &t, Data: d})
}

func failResult(seq int64, code, msg, detail string, retryable bool) {
	f := false
	q.push(&event{T: "result", Seq: seq, OK: &f,
		Err: &errObj{Code: code, Msg: msg, Retryable: retryable, Detail: detail}})
}

func partial(seq int64, v any) {
	d, _ := json.Marshal(v)
	q.push(&event{T: "partial", Seq: seq, Data: d})
}

// ---------------------------------------------------------------- worker 池
//
// ★★ 命令**不在 cgo 调用里现开 goroutine**,而是投给 lp_init 时就建好的 worker。
//
// 这不是性能优化,是**正确性**。SPIKE-2 实测(2026-08-31,.NET 10 宿主 / Go 1.27 / Windows):
//
//	· 在 cgo 调用里 `go func(){…}()` 现开的 goroutine 上做空指针解引用
//	  -> 进程被 0xC0000409(fastfail)硬杀,recover 完全没机会,
//	     连 GOTRACEBACK=system 都不打印任何东西
//	· 同一个故障放在 lp_init 时就存在的后台 goroutine 上 -> recover 正常接住
//	· 同一个 DLL 换成 Python 宿主,两种情况都 recover 得住
//
// 推断:在 cgo 调用里现开的 goroutine 可能被调度到「被 Go 临时收编的宿主线程」上,
// 而那条线程的异常处理归宿主运行时管。worker 池让命令永远跑在 Go 自己的线程上。
//
// LP_INLINE_GOROUTINE=1 退回「现开 goroutine」—— 这是本结论的反向注入开关。
type job struct {
	seq  int64
	cmd  string
	args string
	ctx  context.Context
}

var jobs chan job

const workerCount = 8

func startWorkers() {
	jobs = make(chan job, 256)
	for i := 0; i < workerCount; i++ {
		go func() {
			for j := range jobs {
				runGuarded(j)
			}
		}()
	}
}

func dispatch(seq int64, cmd string, argsJSON string) {
	ctx, cancel := context.WithCancel(context.Background())
	inflightMu.Lock()
	inflight[seq] = cancel
	inflightMu.Unlock()

	j := job{seq: seq, cmd: cmd, args: argsJSON, ctx: ctx}
	if os.Getenv("LP_INLINE_GOROUTINE") == "1" {
		go runGuarded(j) // 反向注入:退回在 cgo 调用里现开
		return
	}
	jobs <- j
}

// runGuarded 是 panic 边界。
//
// ★ Go 的 panic 跨不过 cgo,一个没 recover 的 panic **直接终止整个进程**,
// 宿主的 try/catch 一个都拦不住,用户看到的是「程序突然没了」且没有任何线索。
// 所以这里的 recover 不是编码习惯,是契约(SPEC §5.10)。
func runGuarded(j job) {
	seq, cmd := j.seq, j.cmd
	defer func() {
		inflightMu.Lock()
		delete(inflight, seq)
		inflightMu.Unlock()

		// ★ 反向注入开关(SPEC §5.10 的「先红」要求):
		//   LP_NO_RECOVER=1 时不 recover,panic 直接带走整个进程。
		//   不做这一步,就不知道 panic 边界的测试是不是在测「没 panic」。
		if os.Getenv("LP_NO_RECOVER") == "1" {
			return
		}
		if r := recover(); r != nil {
			panicCount.Add(1)
			// recover 之后必须做三件事,少一件这条契约就白写:
			// ① 把栈写进日志(否则 recover 等于把 bug 藏起来)
			logf("error", "命令 %s 发生 panic: %v | %s", cmd, r, string(debug.Stack()))
			// ② 回一个 E_INTERNAL 给等待的 seq(否则调用方永远等不到 result,
			//    UI 上表现为「点了没反应」,比崩溃更难查)
			failResult(seq, "E_INTERNAL", "核心层内部错误", fmt.Sprint(r), false)
			// ③ 计数并透出,让诊断包看得到「这个版本 panic 了多少次」
			logf("warn", "累计 panic 次数 = %d", panicCount.Load())
		}
	}()
	run(j.ctx, seq, cmd, j.args)
}

func run(ctx context.Context, seq int64, cmd, argsJSON string) {
	var args map[string]any
	if argsJSON != "" {
		if err := json.Unmarshal([]byte(argsJSON), &args); err != nil {
			failResult(seq, "E_INVALID", "参数不是合法 JSON", err.Error(), false)
			return
		}
	}

	switch cmd {
	case "system.capabilities":
		okResult(seq, capabilities())

	case "system.exportDiagnostics":
		// 带上 Go 侧的堆统计 —— 内存判据必须能分清是宿主漏还是核心漏,
		// 只看进程私有内存分不出来
		var ms runtime.MemStats
		runtime.ReadMemStats(&ms)
		okResult(seq, map[string]any{
			"abi":        LP_ABI,
			"queue":      q.stats(),
			"panicCount": panicCount.Load(),
			"uptimeMs":   monoMillis(),
			"goHeapMB":   float64(ms.HeapAlloc) / 1048576.0,
			"goSysMB":    float64(ms.Sys) / 1048576.0,
			"goroutines": runtime.NumGoroutine(),
			// SPEC §5.3 的直接判据:漏一次就是永久泄漏
			"cstrAlloc":       cstrAlloc.Load(),
			"cstrFree":        cstrFree.Load(),
			"cstrOutstanding": cstrAlloc.Load() - cstrFree.Load(),
		})

	// ---- 播放(视频通道 B)----
	case "player.play":
		path, _ := args["path"].(string)
		if path == "" {
			failResult(seq, "E_INVALID", "缺少 path", "", false)
			return
		}
		if err := playFile(path); err != nil {
			failResult(seq, "E_INTERNAL", err.Error(), "", false)
			return
		}
		okResult(seq, map[string]any{"playing": path})

	case "player.prop":
		name, _ := args["name"].(string)
		if name == "" {
			failResult(seq, "E_INVALID", "缺少 name", "", false)
			return
		}
		v := prop(name)
		if v == "" {
			// 属性不可用不是错误 —— UI 探测时收到的是信息
			failResult(seq, "E_NOTFOUND", "属性不可用", name, false)
			return
		}
		okResult(seq, map[string]any{"name": name, "value": v})

	// ---- 弹幕(SPIKE-5)----
	case "danmaku.load":
		n := 500
		if v, ok := args["count"].(float64); ok {
			n = int(v)
		}
		span := 60.0
		if v, ok := args["span"].(float64); ok {
			span = v
		}
		danmakuLoad(n, span)
		okResult(seq, map[string]any{"loaded": n})

	case "danmaku.start":
		hz := 60
		if v, ok := args["hz"].(float64); ok {
			hz = int(v)
		}
		if v, ok := args["fpsFilter"].(float64); ok && v > 0 {
			applyFpsFilter(int(v))
		}
		danmakuStart(hz)
		okResult(seq, map[string]any{"hz": hz})

	case "danmaku.stop":
		danmakuStop()
		okResult(seq, map[string]any{"stopped": true})

	case "danmaku.stats":
		okResult(seq, danmakuStats())

	case "player.counters":
		okResult(seq, map[string]any{
			"renderCalls": renderCalls.Load(),
			"swapCalls":   swapCalls.Load(),
		})

	case "debug.echo":
		okResult(seq, map[string]any{"cmd": cmd, "args": args})

	// 长任务 + 流式中间结果(SPEC §5.7),顺带验 lp_cancel
	case "debug.slow":
		n := 5
		if v, ok := args["steps"].(float64); ok {
			n = int(v)
		}
		for i := 1; i <= n; i++ {
			select {
			case <-ctx.Done():
				failResult(seq, "E_SHUTDOWN", "已取消", "", false)
				return
			case <-time.After(80 * time.Millisecond):
			}
			partial(seq, map[string]any{"step": i, "of": n})
		}
		okResult(seq, map[string]any{"done": n})

	// 下面三条只在 LP_DEBUG_CMDS=1 时存在(SPEC §5.10 的先红要求)。
	//
	// ★ 故意分成三条,因为它们在 .NET 宿主下的行为**不一样**:
	//   debug.panic        显式 panic(),纯 Go 控制流,不产生 OS 异常
	//   debug.panicnil     空指针解引用,由**硬件异常**转成 panic
	//   debug.panicnil.bg  同上,但发生在脱离 cgo 调用链的后台 goroutine 上
	// 混成一条就分不清 recover 到底挡住了哪一类 —— 而实测它们的结果不同。
	case "debug.panic":
		if !debugCmds() {
			failResult(seq, "E_NOTFOUND", "未知命令", cmd, false)
			return
		}
		panic("故意的显式 panic:验证 SPEC §5.10 的 recover 边界")

	case "debug.panicnil":
		if !debugCmds() {
			failResult(seq, "E_NOTFOUND", "未知命令", cmd, false)
			return
		}
		var p *int
		_ = *p

	case "debug.panicnil.bg":
		if !debugCmds() {
			failResult(seq, "E_NOTFOUND", "未知命令", cmd, false)
			return
		}
		okResult(seq, map[string]any{"scheduled": true})
		time.AfterFunc(300*time.Millisecond, func() {
			defer func() {
				if r := recover(); r != nil {
					logf("error", "后台 goroutine recover 住了: %v", r)
				}
			}()
			var p *int
			_ = *p
		})

	case "debug.unsupported":
		// E_UNSUPPORTED 单列的意义:UI 探测能力时收到的不是错误,是信息 ——
		// 混在一起的表现是「进网盘就弹一个红色报错」
		failResult(seq, "E_UNSUPPORTED", "该源不支持这个能力", "", false)

	default:
		failResult(seq, "E_NOTFOUND", "未知命令", cmd, false)
	}
}

func debugCmds() bool { return os.Getenv("LP_DEBUG_CMDS") == "1" }

// capabilities 让 UI 探测平台差异,而不是靠三份拷贝各自维护(SPEC §5.6)。
func capabilities() map[string]any {
	return map[string]any{
		"abi":        LP_ABI,
		"platform":   platformName(),
		"videoChan":  videoChannel(), // "gl" = 通道 B;"surface" = 通道 A
		"translate":  platformName() == "windows" || platformName() == "linux",
		"pluginUI":   true,
		"webviewEsc": platformName() == "windows",
	}
}
