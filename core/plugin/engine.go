package plugin

// 每插件一个 goja 引擎,钉在一条专用 goroutine 上。
//
// ★★ **goja 的 Runtime 不是并发安全的**,而插件的宿主调用天然是并发的
// (UI 点一下、播放事件、数据源浏览可能同时进来)。所以所有对 VM 的触碰
// 都投进 jobs 通道,由 loop 这一条 goroutine 串行执行 —— 这也顺带给了
// Promise 微任务一个确定的执行位置。
//
// 与 Rust(rquickjs)版的差异,写清楚免得下次有人以为是漏了:
//   · **没有内存上限**。QuickJS 有 set_memory_limit(64MB),goja 没有对应能力。
//     所以 MaxEnabled 那道「限数即限内存」的闸,在 Go 版只剩「限数」。
//   · 看门狗同样是「无宿主交互超过 30 秒判失控」,靠 vm.Interrupt 落地。

import (
	"fmt"
	"sync"
	"sync/atomic"
	"time"

	"github.com/dop251/goja"
)

// WatchdogMS 单次进入 JS 的空转墙钟上限(无任何宿主交互超过此值 = 判失控)。
const WatchdogMS = 30_000

// prelude 统一把插件回调包成 Promise(无论 handler 是同步还是 async)。
// 唯一残留的 JS 胶水,1 行。
const prelude = "globalThis.__lp_call=function(f,a){return Promise.resolve(f.apply(null,a||[]))};"

// UnsupportedMarker `ctx.errors.unsupported()` 抛出的异常文案前缀。
//
// 数据源桥按这个前缀把 JS 异常还原成「该源不支持」(UI 退回本地过滤),
// 而不是当成一次真失败弹红字。
const UnsupportedMarker = "__LP_UNSUPPORTED__"

// Engine 一个插件的运行时。
type Engine struct {
	pluginID string
	vm       *goja.Runtime
	jobs     chan func()
	stop     chan struct{}
	stopOnce sync.Once
	state    *ctxState

	// deadline 看门狗:JS 应在此毫秒(UNIX ms)前有宿主交互;0 = 关闭。
	deadline atomic.Int64
	// lastPanic 最近一次在 VM goroutine 上被接住的 panic。
	// 留着是为了把「插件把自己搞崩了」这件事说清楚,而不是让调用方看到一个空结果。
	lastPanic atomic.Value
}

func nowMS() int64 { return time.Now().UnixMilli() }

// StartEngine 建引擎、装配 ctx、跑一遍插件入口。
func StartEngine(m *Manifest, mainJS string, granted Granted, st *Storage,
	host Host, reg *Registry, grants *GrantsSlot) (*Engine, error) {

	e := &Engine{
		pluginID: m.ID,
		vm:       goja.New(),
		jobs:     make(chan func(), 64),
		stop:     make(chan struct{}),
	}
	e.state = &ctxState{
		pluginID:     m.ID,
		permissions:  granted,
		allowedHosts: m.HTTPAllowedHosts,
		grants:       grants,
		storage:      st,
		host:         host,
		registry:     reg,
		handlers:     map[string]goja.Value{},
		events:       map[string][]goja.Value{},
		lifecycle:    map[string]goja.Value{},
		engine:       e,
	}

	go e.loop()
	go e.watchdog()

	meta := map[string]any{"id": m.ID, "name": m.Name, "version": m.Version}
	e.bumpDeadline()

	var startErr error
	e.run(func() {
		if err := installCtx(e, meta); err != nil {
			startErr = fmt.Errorf("装配 ctx 失败: %w", err)
			return
		}
		if _, err := e.vm.RunString(prelude); err != nil {
			startErr = jsErr(err)
			return
		}
		if _, err := e.vm.RunString(mainJS); err != nil {
			startErr = jsErr(err)
			return
		}
	})
	e.clearDeadline()
	if startErr != nil {
		e.Dispose()
		return nil, startErr
	}
	return e, nil
}

// loop 是唯一碰 VM 的 goroutine。
func (e *Engine) loop() {
	for {
		select {
		case fn := <-e.jobs:
			fn()
		case <-e.stop:
			return
		}
	}
}

// watchdog 空转看门狗。纯 JS 死循环不碰宿主 -> 不刷新死线 -> 到点被中断。
func (e *Engine) watchdog() {
	t := time.NewTicker(500 * time.Millisecond)
	defer t.Stop()
	for {
		select {
		case <-e.stop:
			return
		case <-t.C:
			dl := e.deadline.Load()
			if dl != 0 && nowMS() > dl {
				// 只中断一次:Interrupt 之后 deadline 清零,
				// 否则每 500ms 再中断一次会把后续正常调用一起打死。
				e.deadline.Store(0)
				e.vm.Interrupt(fmt.Sprintf("插件 %s 空转超过 %d 秒,已中断", e.pluginID, WatchdogMS/1000))
			}
		}
	}
}

func (e *Engine) bumpDeadline()  { e.deadline.Store(nowMS() + WatchdogMS) }
func (e *Engine) clearDeadline() { e.deadline.Store(0); e.vm.ClearInterrupt() }

// post 把一段活儿投给 VM goroutine,不等它做完。
func (e *Engine) post(fn func()) {
	select {
	case e.jobs <- fn:
	case <-e.stop:
	}
}

// run 把一段活儿投给 VM goroutine 并等它做完。
func (e *Engine) run(fn func()) {
	done := make(chan struct{})
	wrapped := func() {
		defer close(done)
		defer func() {
			// 插件里的 panic(goja 的 InterruptedError / StackOverflow)只毁自己,
			// 不能把宿主带走。
			if r := recover(); r != nil {
				e.lastPanic.Store(fmt.Sprintf("%v", r))
			}
		}()
		fn()
	}
	select {
	case e.jobs <- wrapped:
		<-done
	case <-e.stop:
	}
}

// LastPanic 最近一次被接住的插件 panic(没有则空串)。
func (e *Engine) LastPanic() string {
	s, _ := e.lastPanic.Load().(string)
	return s
}

// Dispose 停引擎。幂等。
func (e *Engine) Dispose() {
	e.stopOnce.Do(func() {
		close(e.stop)
		// 清三张回调表:留着它们等于留着对 VM 的引用。
		e.state.mu.Lock()
		e.state.handlers = map[string]goja.Value{}
		e.state.events = map[string][]goja.Value{}
		e.state.lifecycle = map[string]goja.Value{}
		e.state.mu.Unlock()
	})
}

// jsErr 把 goja 的错误尽量变成人类可读的一句话。
func jsErr(err error) error {
	if err == nil {
		return nil
	}
	if ex, ok := err.(*goja.Exception); ok {
		if v := ex.Value(); v != nil {
			// Error 对象优先取 message,拿不到就整体 String()。
			if obj, ok := v.(*goja.Object); ok {
				if msg := obj.Get("message"); msg != nil && !goja.IsUndefined(msg) {
					return fmt.Errorf("%s", msg.String())
				}
			}
			return fmt.Errorf("%s", v.String())
		}
	}
	if ie, ok := err.(*goja.InterruptedError); ok {
		return fmt.Errorf("%v", ie.Value())
	}
	return err
}

// applyJS 调一个 JS 函数(经 __lp_call 包成 Promise),等它 settle。
//
// ★ 结果必须靠 `.then` 回调取,不能轮询 Promise 状态:goja 的微任务只在
// VM goroutine 上跑,轮询会把这条 goroutine 占住,微任务永远排不上。
func (e *Engine) applyJS(f goja.Value, args []any) (any, error) {
	type outcome struct {
		val any
		err error
	}
	ch := make(chan outcome, 1)
	settle := func(o outcome) {
		select {
		case ch <- o:
		default:
		}
	}

	e.bumpDeadline()
	e.run(func() {
		callFn, ok := goja.AssertFunction(e.vm.GlobalObject().Get("__lp_call"))
		if !ok {
			settle(outcome{err: fmt.Errorf("插件运行时未初始化(__lp_call 丢失)")})
			return
		}
		/* ★★ 两个都踩过,而且都**不报错**:
		   · 参数必须是**真 JS 数组**。ToValue 一个 Go 切片拿到的是 Go 支撑的对象,
		     `f.apply(null, it)` 认不出它是 array-like —— 参数全丢。
		   · 函数必须原样传**当初那个 JS 值**,不能把 goja.Callable 再 ToValue 回去。
		     goja.Callable 的签名是 `func(this, args...)`,当成原生函数包回 JS 之后,
		     JS 的第一个实参会被吃掉当 this —— 表现是**所有参数整体左移一位**,
		     第一个形参变 undefined。2026-09-02 在 listDir(dirId) 上现场抓到。 */
		res, err := callFn(goja.Undefined(), f, e.vm.NewArray(args...))
		if err != nil {
			settle(outcome{err: jsErr(err)})
			return
		}
		obj, ok := res.(*goja.Object)
		if !ok {
			settle(outcome{val: exportJSON(e.vm, res, nil)})
			return
		}
		thenFn, ok := goja.AssertFunction(obj.Get("then"))
		if !ok {
			settle(outcome{val: exportJSON(e.vm, res, nil)})
			return
		}
		onOK := e.vm.ToValue(func(call goja.FunctionCall) goja.Value {
			settle(outcome{val: exportJSON(e.vm, call.Argument(0), nil)})
			return goja.Undefined()
		})
		onErr := e.vm.ToValue(func(call goja.FunctionCall) goja.Value {
			settle(outcome{err: fmt.Errorf("%s", errText(e.vm, call.Argument(0)))})
			return goja.Undefined()
		})
		if _, err := thenFn(obj, onOK, onErr); err != nil {
			settle(outcome{err: jsErr(err)})
		}
	})

	// e.run 返回时同步部分已跑完;异步的 resolve 会在后续 job 里落地,
	// 所以这里等通道,不等 run。
	select {
	case o := <-ch:
		e.clearDeadline()
		return o.val, o.err
	case <-e.stop:
		return nil, fmt.Errorf("插件已停止")
	}
}

// errText 从 JS 抛出来的值里取文案(Error 对象取 message,其它 String())。
func errText(vm *goja.Runtime, v goja.Value) string {
	if v == nil || goja.IsUndefined(v) || goja.IsNull(v) {
		return "插件抛出了空错误"
	}
	if obj, ok := v.(*goja.Object); ok {
		if msg := obj.Get("message"); msg != nil && !goja.IsUndefined(msg) && msg.String() != "" {
			return msg.String()
		}
	}
	return v.String()
}

// CallHandler 触发动态注册的 handler(按 id)。
func (e *Engine) CallHandler(handlerID string, args []any) (any, error) {
	e.state.mu.Lock()
	f, ok := e.state.handlers[handlerID]
	e.state.mu.Unlock()
	if !ok {
		return nil, nil
	}
	return e.applyJS(f, args)
}

// CallNamed 触发 manifest 声明的具名全局函数 handler。
//
// 函数不存在时返回 nil(不是报错)—— 那等同于「插件没实现这个字段」,
// 调用方据此退回默认行为。
func (e *Engine) CallNamed(name string, args []any) (any, error) {
	var f goja.Value
	var ok bool
	e.run(func() {
		v := e.vm.GlobalObject().Get(name)
		if _, isFn := goja.AssertFunction(v); isFn {
			f, ok = v, true
		}
	})
	if !ok {
		return nil, nil
	}
	return e.applyJS(f, args)
}

// FireEvent 派发播放事件给所有监听者。
func (e *Engine) FireEvent(event string, data any) {
	e.state.mu.Lock()
	listeners := append([]goja.Value(nil), e.state.events[event]...)
	e.state.mu.Unlock()
	for _, f := range listeners {
		_, _ = e.applyJS(f, []any{data})
	}
}

// RunLifecycle 跑生命周期回调 onEnable / onDisable(若插件注册了)。
func (e *Engine) RunLifecycle(name string) error {
	e.state.mu.Lock()
	f, ok := e.state.lifecycle[name]
	e.state.mu.Unlock()
	if !ok {
		return nil
	}
	_, err := e.applyJS(f, nil)
	return err
}
