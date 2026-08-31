package main

// SPIKE-3 · quickjs-go 能不能跑现有插件。
//
// 判据(TODO S3.1~S3.4),全部是数字/表格,退出码 = 不通过条数:
//   S3.1 ctx.* 最小子集(http / log / storage / ui / sources / extensions / emby)
//   S3.2 拿**现存全部插件**当语料,逐个加载 + 调主要入口 -> 逐插件通过/失败表
//   S3.3 内存上限拦得住 128MB 分配;死循环 30s 被中断且**宿主进程不受影响**
//   S3.4 交互式流程(await 一个等很久的 UI)**不被看门狗误杀**
//
// 用法:
//   go run . --plugins <插件目录> [--slow-seconds 12] [--watchdog-ms 2000]

import (
	"encoding/json"
	"flag"
	"fmt"
	"net/http"
	"net/http/httptest"
	"os"
	"os/exec"
	"path/filepath"
	"runtime"
	"sort"
	"strings"
	"time"

	"github.com/buke/quickjs-go"
)

var fail int

func check(ok bool, what string, detail ...string) {
	d := ""
	if len(detail) > 0 {
		d = "  — " + strings.Join(detail, " ")
	}
	mark := "通过"
	if !ok {
		mark = "不通过"
		fail++
	}
	fmt.Printf("  [%s] %s%s\n", mark, what, d)
}

type manifest struct {
	ID          string   `json:"id"`
	Name        string   `json:"name"`
	Version     string   `json:"version"`
	Permissions []string `json:"permissions"`
}

// engine 一个插件一套 runtime/context —— 一个坏插件不许带走别的插件,更不许带走宿主。
type engine struct {
	rt   *quickjs.Runtime
	ctx  *quickjs.Context
	h    *hostState
	dead chan struct{}

	// 看门狗:中断处理器只在 **JS 正在执行** 时被调用。
	// 所以 await 期间它压根不会触发 —— 这正是 S3.4 能通过的机制。
	deadline time.Time
	limit    time.Duration
	aborted  bool

	// jsQueue 是「回到 JS 线程执行」的投递队列。所有异步 API 的结果都从这里回来。
	jsQueue chan jsTask
}

func newEngine(m manifest, memLimit uint64, watchdog time.Duration, slowUI time.Duration) *engine {
	rt := quickjs.NewRuntime()
	rt.SetMemoryLimit(memLimit)
	rt.SetMaxStackSize(1 << 20)
	c := rt.NewContext()

	e := &engine{rt: rt, ctx: c, h: newHostState(slowUI), limit: watchdog,
		dead: make(chan struct{}), jsQueue: make(chan jsTask, 256)}
	e.h.post = func(t jsTask) {
		select {
		case e.jsQueue <- t:
		default: // 队列满就丢 —— SPIKE 里够用;生产环境要按 SPEC §5.11 分级
		}
	}
	e.resetDeadline()
	rt.SetInterruptHandler(func() int {
		if time.Now().After(e.deadline) {
			e.aborted = true
			return 1 // 中断
		}
		return 0
	})

	granted := map[string]bool{}
	for _, p := range m.Permissions {
		granted[p] = true
	}
	installCtx(c, e.h, m.ID, m.Name, m.Version, granted)
	return e
}

// resetDeadline 必须在每次「让 JS 重新开始跑」之前调 ——
// 否则一个 await 了 60 秒的插件在恢复执行时会被立刻误杀。
func (e *engine) resetDeadline() { e.deadline = time.Now().Add(e.limit) }

// close 关引擎。
//
// ★ 先等一小会儿再关:ctx.sleep / ctx.http 那些 Promise 是在 goroutine 里 resolve 的,
//   context 先被释放掉的话,那些 goroutine 一落地就是 use-after-free —— 表现是
//   JS_FreeRuntime 里的段错误,和插件本身没关系。
func (e *engine) close() {
	e.drainPending(500 * time.Millisecond)
	e.ctx.Close()
	e.rt.Close()
}

func (e *engine) drainPending(d time.Duration) {
	deadline := time.Now().Add(d)
	for time.Now().Before(deadline) {
		e.resetDeadline()
		e.drainJS()
		if e.ctx.LoopOnce() == 0 && len(e.jsQueue) == 0 {
			return
		}
		time.Sleep(2 * time.Millisecond)
	}
}

// drainJS 把投递队列里的工作在**当前(JS)线程**上跑掉。
func (e *engine) drainJS() {
	for {
		select {
		case t := <-e.jsQueue:
			t(e.ctx)
		default:
			return
		}
	}
}

// awaitValue 等一个 Promise 落定,期间不停泵作业队列。
// 每泵一轮就重置看门狗 —— JS 没在跑的时间不该算进「执行超时」。
func (e *engine) awaitValue(v *quickjs.Value, timeout time.Duration) (*quickjs.Value, error) {
	deadline := time.Now().Add(timeout)
	for time.Now().Before(deadline) {
		e.resetDeadline()
		e.drainJS()
		e.ctx.LoopOnce()
		if e.aborted {
			return nil, fmt.Errorf("被看门狗中断")
		}
		st := v.PromiseState()
		if st == quickjs.PromiseFulfilled {
			return v.Await(), nil
		}
		if st == quickjs.PromiseRejected {
			// ★ 光报「被拒绝」会把真相盖住 —— 必须把 reason 带出来
			// Await 对被拒绝的 promise 返回的是**异常值**,String() 是空的 ——
			// 真正的 reason 要从 ctx.Exception() 取
			reason := v.Await()
			txt := ""
			if reason != nil {
				txt = reason.String()
				reason.Free()
			}
			if txt == "" {
				txt = errText(e.ctx)
			}
			return nil, fmt.Errorf("Promise 被拒绝: %s", txt)
		}
		time.Sleep(2 * time.Millisecond)
	}
	return nil, fmt.Errorf("等待超时")
}

// awaitValueNoReset 是 awaitValue 的**反向注入版**:泵作业时不重置看门狗。
// 用来证明 awaitValue 里那行 resetDeadline 不是多余的。
func (e *engine) awaitValueNoReset(v *quickjs.Value, timeout time.Duration) (*quickjs.Value, error) {
	deadline := time.Now().Add(timeout)
	for time.Now().Before(deadline) {
		e.drainJS()
		e.ctx.LoopOnce()
		if e.aborted {
			return nil, fmt.Errorf("被看门狗中断")
		}
		switch v.PromiseState() {
		case quickjs.PromiseFulfilled:
			return v.Await(), nil
		case quickjs.PromiseRejected:
			return nil, fmt.Errorf("Promise 被拒绝")
		}
		time.Sleep(2 * time.Millisecond)
	}
	return nil, fmt.Errorf("等待超时")
}

// ---------------------------------------------------------------- S3.2

type result struct {
	id      string
	loaded  bool
	enabled bool
	err     string
	detail  string
}

func runPlugin(dir string, watchdog, slowUI time.Duration) result {
	r := result{id: filepath.Base(dir)}
	mb, err := os.ReadFile(filepath.Join(dir, "manifest.json"))
	if err != nil {
		r.err = "读不到 manifest: " + err.Error()
		return r
	}
	var m manifest
	if err := json.Unmarshal(mb, &m); err != nil {
		r.err = "manifest 不是合法 JSON: " + err.Error()
		return r
	}
	if m.ID != "" {
		r.id = m.ID
	}
	src, err := os.ReadFile(filepath.Join(dir, "main.js"))
	if err != nil {
		r.err = "读不到 main.js: " + err.Error()
		return r
	}

	e := newEngine(m, 64<<20, watchdog, slowUI)
	defer e.close()

	e.resetDeadline()
	v := e.ctx.Eval(string(src))
	if v.IsException() {
		r.err = "加载失败: " + errText(e.ctx)
		v.Free()
		return r
	}
	v.Free()
	r.loaded = true

	hooks := e.ctx.Globals().Get(hookGlobal)
	fn := hooks.Get("onEnable")
	if !fn.IsFunction() {
		fn.Free()
		hooks.Free()
		r.detail = "没注册 onEnable"
		r.enabled = true // 不算失败:不是每个插件都必须注册
		return r
	}
	e.resetDeadline()
	ret := fn.Execute(e.ctx.NewUndefined())
	fn.Free()
	hooks.Free()
	if ret.IsException() {
		r.err = "onEnable 抛异常: " + errText(e.ctx)
		fmt.Println("      >>", r.err)
		ret.Free()
		return r
	}
	// onEnable 是 async function,返回的是 Promise
	if ret.IsPromise() {
		if _, err := e.awaitValue(ret, 20*time.Second); err != nil {
			r.err = "onEnable 的 Promise 没落定: " + err.Error()
			ret.Free()
			return r
		}
	}
	ret.Free()
	r.enabled = true

	e.h.mu.Lock()
	r.detail = fmt.Sprintf("日志 %d 条,注册源 %v,贡献点 %v,UI %v,HTTP %d 次",
		len(e.h.logs), e.h.sources, e.h.extensions, e.h.uiCalls, e.h.httpCalls)
	e.h.mu.Unlock()
	return r
}

func errText(c *quickjs.Context) string {
	if err := c.Exception(); err != nil {
		return strings.ReplaceAll(err.Error(), "\n", " | ")
	}
	return "(无异常信息)"
}

// ---------------------------------------------------------------- main

func main() {
	// ★★ 必须锁 OS 线程(SPIKE-3 实测,2026-08-31)。
	//
	// QuickJS 靠「当前栈指针 vs 创建 runtime 时记录的栈基址」做栈溢出检查,
	// 而 Go 调度器会把 goroutine 在 OS 线程之间搬 —— 栈基址一变,检查就误报
	// **`RangeError: Maximum call stack size exceeded`**,而且是**偶发**的
	// (实测 5 次里错 4 次,每次错的项还不一样)。
	//
	// 这种「偶发 + 报的是一个看起来像插件写错了的错」是最坏的一类:
	// 不锁线程的话,现象会是「某些插件有时候用不了」,而插件作者查不出任何问题。
	// LP_NO_LOCK_OS_THREAD=1 是这条结论的反向注入开关。
	if os.Getenv("LP_NO_LOCK_OS_THREAD") != "1" {
		runtime.LockOSThread()
		defer runtime.UnlockOSThread()
	}

	pluginsDir := flag.String("plugins", "", "插件目录(每个子目录一个插件)")
	slowSec := flag.Int("slow-seconds", 12, "S3.4 里 ctx.ui.showList 等多久")
	watchdogMs := flag.Int("watchdog-ms", 2000, "看门狗:JS 连续执行超过这么久就中断")
	childNoLoop := flag.Bool("child-noloop", false, "内部用:子进程模式,不装中断处理器跑死循环")
	skipInject := flag.Bool("skip-inject", false, "跳过反向注入段(用来隔离它有没有污染后面的测试)")
	flag.Parse()

	// 子进程模式:不装中断处理器,跑一个死循环。父进程靠「它会不会自己停」判定。
	if *childNoLoop {
		rt := quickjs.NewRuntime()
		c := rt.NewContext()
		v := c.Eval(`var n=0; while(true){n++;}`)
		v.Free()
		c.Close()
		rt.Close()
		return
	}

	watchdog := time.Duration(*watchdogMs) * time.Millisecond
	slowUI := time.Duration(*slowSec) * time.Second

	fmt.Println("======== SPIKE-3 · quickjs-go 跑现有插件 ========")
	fmt.Printf("看门狗 %v,S3.4 的等待时长 %v\n", watchdog, slowUI)

	// ---- S3.2 ----
	fmt.Println("== S3.2 现存全部插件逐个加载 + 调 onEnable ==")
	if *pluginsDir == "" {
		check(false, "必须给 --plugins")
	} else {
		ents, _ := os.ReadDir(*pluginsDir)
		var dirs []string
		for _, en := range ents {
			if en.IsDir() {
				if _, err := os.Stat(filepath.Join(*pluginsDir, en.Name(), "main.js")); err == nil {
					dirs = append(dirs, filepath.Join(*pluginsDir, en.Name()))
				}
			}
		}
		sort.Strings(dirs)
		check(len(dirs) > 0, fmt.Sprintf("找到 %d 个插件当语料", len(dirs)))
		fmt.Printf("  %-26s %-6s %-8s %s\n", "插件", "加载", "onEnable", "详情 / 失败原因")
		for _, d := range dirs {
			r := runPlugin(d, watchdog, slowUI)
			ld, en := "✗", "✗"
			if r.loaded {
				ld = "✓"
			}
			if r.enabled {
				en = "✓"
			}
			info := r.detail
			if r.err != "" {
				info = r.err
			}
			fmt.Printf("  %-26s %-6s %-8s %s\n", r.id, ld, en, info)
			check(r.loaded && r.enabled, "插件 "+r.id+" 加载并启用")
		}
	}

	// ---- S3.1 异步链路:三个插件的 onEnable 里 HTTP 调用数都是 0,
	//      也就是说 ctx.http / ctx.sleep 这条**跨 goroutine 延后 resolve** 的链路
	//      没被语料走到。不单独测,「实现了 http」就是没验的。----
	fmt.Println("== S3.1 异步链路:真发 HTTP + sleep,验跨 goroutine 的 resolve 回得来 ==")
	{
		srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
			time.Sleep(120 * time.Millisecond) // 确保不是同步就绪
			w.WriteHeader(200)
			fmt.Fprint(w, `{"pong":true,"ua":"`+r.Header.Get("User-Agent")+`"}`)
		}))
		defer srv.Close()

		m := manifest{ID: "async", Permissions: []string{"http", "storage"}}
		e := newEngine(m, 64<<20, watchdog, slowUI)
		e.resetDeadline()
		// 分步 try/catch:一整段 await 链里任何一步拒绝都只报「Promise 被拒绝」,
		// 分不出是哪一步。逐步捕获才定位得到。
		v := e.ctx.Eval(`
			(async function () {
				const out = {};
				try { const t0 = Date.now(); await ctx.sleep(150); out.slept = (Date.now()-t0) >= 140; }
				catch (e) { out.sleepErr = String(e); }
				try { const r = await ctx.http.get(` + "`" + srv.URL + "`" + `);
				      out.status = r.status; out.ok = r.ok;
				      out.pong = JSON.parse(r.body).pong; out.ua = JSON.parse(r.body).ua; }
				catch (e) { out.httpErr = String(e); }
				try { await ctx.storage.set('k','v'); out.storage = await ctx.storage.get('k'); }
				catch (e) { out.storageErr = String(e); }
				return JSON.stringify(out);
			})().catch(function (e) { return JSON.stringify({fatal: String(e), stack: String(e && e.stack)}); })`)
		fmt.Println("      诊断: IsPromise=", v.IsPromise(), " state=", v.PromiseState(), " str=", trunc(v.String(), 120))
		if v.IsException() {
			check(false, "异步链路脚本能跑", errText(e.ctx))
		} else {
			res, err := e.awaitValue(v, 15*time.Second)
			if err != nil {
				check(false, "异步链路的 Promise 落定", err.Error())
			} else {
				got := res.String()
				res.Free()
				check(strings.Contains(got, `"status":200`), "ctx.http.get 真发出去并拿到 200", got)
				check(strings.Contains(got, `"pong":true`), "响应体解析正确")
				check(strings.Contains(got, `"slept":true`), "ctx.sleep 真的等够了(跨 goroutine resolve 回得来)")
				check(strings.Contains(got, `"storage":"v"`), "ctx.storage 存取往返正确")
				check(strings.Contains(got, "LinPlayer/"), "出网带了我们的 UA(SPEC §14.1 三条 UA 道)")
			}
		}
		v.Free()
		e.close()
	}

	// ---- 反向注入:三条判据各注入一次,不注入就不知道它们在不在测东西 ----
	fmt.Println("== 反向注入:把三条护栏各拆一次,断言它们真的变红 ==")
	if *skipInject {
		fmt.Println("  (--skip-inject:本段跳过)")
	}
	if !*skipInject {
		// ① 内存上限调大 -> 128MB 分配应当**成功**
		e := newEngine(manifest{ID: "mem-big"}, 512<<20, watchdog, slowUI)
		e.resetDeadline()
		v := e.ctx.Eval(`var c=[];for(var i=0;i<128;i++){c.push(new Uint8Array(1048576));}c.length`)
		ok := !v.IsException() && v.ToInt32() == 128
		v.Free()
		e.close()
		check(ok, "① 上限放到 512MB 时同样的分配应当成功(证明拦截来自上限,不是别的)")
	}
	if !*skipInject {
		// ② 不装中断处理器 -> 死循环没人拦。
		//
		// ★ 必须在**子进程**里做:第一版把它放在另一个 goroutine 上 Eval,
		//   那违反了 quickjs-go 的 owner-goroutine 约束,不但没测到东西,
		//   还把后面所有测试污染了(S3.4 从通过变成失败)。
		//   「注入本身有 bug」比「没有注入」更糟 —— 它会让你以为护栏坏了。
		exe, _ := os.Executable()
		cmd := exec.Command(exe, "--child-noloop")
		if err := cmd.Start(); err != nil {
			check(false, "② 起子进程失败", err.Error())
		} else {
			done := make(chan error, 1)
			go func() { done <- cmd.Wait() }()
			var escaped bool
			select {
			case <-done:
				escaped = false // 自己停了 = 有别的东西在拦
			case <-time.After(4 * time.Second):
				escaped = true
				_ = cmd.Process.Kill()
				<-done
			}
			check(escaped, "② 不装中断处理器时死循环不会自己停(证明 S3.3b 是看门狗的功劳)",
				"看门狗阈值 2s,子进程跑满 4s 仍未结束")
		}
	}

	if !*skipInject {
		// ③ awaitValue 里去掉 resetDeadline -> 长等待应当被误杀
		m := manifest{ID: "no-reset", Permissions: []string{"ui"}}
		e := newEngine(m, 64<<20, watchdog, slowUI)
		e.resetDeadline()
		// ★ await 之后**接着干活** —— 真实插件就是这个形状(等用户选完再处理)。
		//   第一版注入里 await 完就 return,那段代码短到 QuickJS 的中断检查根本没触发,
		//   于是「不重置也没事」,把一条真约束测成了不存在。
		v := e.ctx.Eval(`(async function(){
			await ctx.ui.showList(['a']);
			var n = 0; var t0 = Date.now();
			while (Date.now() - t0 < 300) { n++; }   // 等完之后接着干 300ms 的活
			return 'survived:' + (n > 0);
		})()`)
		_, err := e.awaitValueNoReset(v, slowUI+10*time.Second)
		check(err != nil, "③ 泵作业时不重置看门狗 -> 长等待被误杀(证明那行 resetDeadline 是必需的)",
			fmt.Sprintf("实际: %v", err))
		v.Free()
		e.close()
	}

	// ---- S3.3 内存上限 ----
	fmt.Println("== S3.3a 内存上限:故意分配 128MB 的插件必须被拦 ==")
	{
		e := newEngine(manifest{ID: "mem"}, 32<<20, watchdog, slowUI)
		e.resetDeadline()
		v := e.ctx.Eval(`
			var chunks = [];
			for (var i = 0; i < 128; i++) { chunks.push(new Uint8Array(1024*1024)); }
			chunks.length`)
		blocked := v.IsException()
		msg := ""
		if blocked {
			msg = errText(e.ctx)
		}
		v.Free()
		check(blocked, "128MB 分配被 32MB 上限拦住", trunc(msg, 60))
		e.close()
		check(true, "拦住之后宿主进程还活着")
	}

	// ---- S3.3 死循环看门狗 ----
	fmt.Println("== S3.3b 死循环:必须被中断,且宿主不受影响 ==")
	{
		e := newEngine(manifest{ID: "loop"}, 64<<20, watchdog, slowUI)
		e.resetDeadline()
		t0 := time.Now()
		v := e.ctx.Eval(`while (true) {}`)
		el := time.Since(t0)
		killed := v.IsException() || e.aborted
		v.Free()
		check(killed, "死循环被中断", fmt.Sprintf("耗时 %.1fs(看门狗 %.1fs)", el.Seconds(), watchdog.Seconds()))
		check(el < watchdog*3, "中断发生在看门狗阈值附近,不是失控", fmt.Sprintf("%.1fs", el.Seconds()))
		e.close()
		check(true, "中断之后宿主进程还活着")
	}

	// ---- S3.4 交互式流程不被误杀 ----
	fmt.Printf("== S3.4 交互式流程:await 一个等 %v 的 UI,不许被 %v 的看门狗杀掉 ==\n", slowUI, watchdog)
	{
		m := manifest{ID: "interactive", Permissions: []string{"ui"}}
		e := newEngine(m, 64<<20, watchdog, slowUI)
		e.resetDeadline()
		v := e.ctx.Eval(`
			(async function () {
				await ctx.ui.showList(['a','b']);
				var n = 0; var t0 = Date.now();
				while (Date.now() - t0 < 300) { n++; }   // 等完之后接着干活,这才是真实形状
				return 'survived';
			})()`)
		ok := !v.IsException()
		var got string
		if ok {
			t0 := time.Now()
			res, err := e.awaitValue(v, slowUI+15*time.Second)
			el := time.Since(t0)
			if err != nil {
				check(false, "长等待的交互流程活了下来", err.Error())
			} else {
				got = res.String()
				res.Free()
				check(got == "survived", "长等待的交互流程活了下来", fmt.Sprintf("返回 %q,等了 %.1fs", got, el.Seconds()))
				check(el >= slowUI, "确实等满了,不是提前返回", fmt.Sprintf("%.1fs >= %.1fs", el.Seconds(), slowUI.Seconds()))
			}
		} else {
			check(false, "长等待的交互流程活了下来", errText(e.ctx))
		}
		v.Free()
		e.close()
	}

	fmt.Println("================================================")
	if fail == 0 {
		fmt.Println("全部通过。")
	} else {
		fmt.Printf("有 %d 条不通过。\n", fail)
	}
	os.Exit(fail)
}

func trunc(s string, n int) string {
	if len(s) <= n {
		return s
	}
	return s[:n] + "…"
}
