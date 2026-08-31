package main

// 插件宿主 API `ctx.*` 的最小实现(SPIKE-3 · S3.1)。
//
// 形状照 `knowledge/PLUGINS.md`:四类贡献点 + 权限门控。
// **权限门控不是装饰**:没声明权限的 API 直接不注入 —— 插件拿到的是
// `undefined`,而不是一个会在运行时报错的桩。这和现有 Rust 宿主一致。

import (
	"fmt"
	"io"
	"net/http"
	"strings"
	"sync"
	"time"

	"github.com/buke/quickjs-go"
)

// hookGlobal 是宿主藏回调的全局名。带下划线前缀,插件不该碰它。
const hookGlobal = "__lp_hooks"

// jsTask 是「回到 JS 线程上执行」的一段工作。
//
// ★★ 为什么必须有它(SPIKE-3 实测,2026-08-31):
//   在**非 owner goroutine** 上调 `ctx.NewObject()` 造出来的是无效值,
//   resolve 出去之后 JS 侧拿到的是 `undefined` —— 表现是
//   `TypeError: cannot read property 'status' of undefined`,**而且不报任何错**。
//   `NewNull()` 之类的常量 tag 不受影响(不需要分配),所以 ctx.sleep 看起来是好的,
//   一换成返回对象的 ctx.http 就坏 —— 这正是最容易漏测的形态。
//
// 所以异步 API 的正确形状是:**goroutine 里只做 Go 的事,回到 JS 线程再造值。**
type jsTask func(*quickjs.Context)

// hostState 记录插件干了什么,判据要看它
type hostState struct {
	mu          sync.Mutex
	logs        []string
	storage     map[string]string
	sources     []string
	extensions  []string
	uiCalls     []string
	httpCalls   int
	slowUIDelay time.Duration // ctx.ui.showList 故意等这么久(S3.4 用)

	// post 把一段工作投回 JS 线程。由 engine 注入。
	post func(jsTask)
}

func newHostState(slow time.Duration) *hostState {
	return &hostState{storage: map[string]string{}, slowUIDelay: slow}
}

func (h *hostState) note(f string, a ...any) {
	h.mu.Lock()
	h.logs = append(h.logs, fmt.Sprintf(f, a...))
	h.mu.Unlock()
}

// installCtx 把 ctx 对象装进全局。granted 是 manifest 里声明的权限集合。
func installCtx(c *quickjs.Context, h *hostState, pluginID, name, version string, granted map[string]bool) {
	ctxObj := c.NewObject()

	// ---- 1.1 无需权限:log / util / errors / sleep / plugin / onEnable / onDisable ----
	logObj := c.NewObject()
	for _, lv := range []string{"info", "warn", "error", "debug"} {
		level := lv
		logObj.Set(level, c.NewFunction(func(c *quickjs.Context, this *quickjs.Value, args []*quickjs.Value) *quickjs.Value {
			var parts []string
			for _, a := range args {
				parts = append(parts, a.String())
			}
			h.note("[%s] %s", level, strings.Join(parts, " "))
			return c.NewUndefined()
		}))
	}
	ctxObj.Set("log", logObj)

	utilObj := c.NewObject()
	utilObj.Set("isVideoName", c.NewFunction(func(c *quickjs.Context, this *quickjs.Value, args []*quickjs.Value) *quickjs.Value {
		if len(args) == 0 {
			return c.NewBool(false)
		}
		n := strings.ToLower(args[0].String())
		for _, e := range []string{".mp4", ".mkv", ".ts", ".avi", ".mov", ".flv", ".m4v", ".webm"} {
			if strings.HasSuffix(n, e) {
				return c.NewBool(true)
			}
		}
		return c.NewBool(false)
	}))
	ctxObj.Set("util", utilObj)

	errObj := c.NewObject()
	errObj.Set("unsupported", c.NewFunction(func(c *quickjs.Context, this *quickjs.Value, args []*quickjs.Value) *quickjs.Value {
		msg := "unsupported"
		if len(args) > 0 {
			msg = args[0].String()
		}
		// 前缀是契约:数据源桥据此还原成 SourceError::unsupported(),UI 静默降级
		return c.ThrowError(fmt.Errorf("__LP_UNSUPPORTED__%s", msg))
	}))
	ctxObj.Set("errors", errObj)

	// sleep:**clamp 到 0..10000ms,越界不报错**(照现有实现)
	ctxObj.Set("sleep", c.NewFunction(func(c *quickjs.Context, this *quickjs.Value, args []*quickjs.Value) *quickjs.Value {
		ms := 0.0
		if len(args) > 0 {
			ms = args[0].ToFloat64()
		}
		if ms < 0 {
			ms = 0
		}
		if ms > 10000 {
			ms = 10000
		}
		d := time.Duration(ms) * time.Millisecond
		return c.NewPromise(func(resolve, reject func(*quickjs.Value)) {
			go func() {
				time.Sleep(d)
				resolve(c.NewNull())
			}()
		})
	}))

	pl := c.NewObject()
	pl.Set("id", c.NewString(pluginID))
	pl.Set("name", c.NewString(name))
	pl.Set("version", c.NewString(version))
	ctxObj.Set("plugin", pl)

	// ★ onEnable / onDisable 的注册**故意在 JS 里做,不在 Go 里做**。
	//
	// 原因是所有权:`Value.Set` 会**接管**传入值的引用,而 `NewFunction` 回调拿到的
	// `args[0]` 是**借来的**(QuickJS 的调用帧还持有它)。把它 Set 进对象 =
	// 同一个引用被释放两次 —— 实测表现是 `JS_FreeValue` 里的段错误,
	// 而 quickjs-go 又没有 `Dup`/`Retain` 可以补一次引用。
	// 让这两行发生在 JS 侧,所有权全归 QuickJS 自己管,一行 Go 都不用写。

	// ---- 1.2 网络(权限 http)。★ 真发请求,真跨 goroutine 延后 resolve ----
	if granted["http"] {
		httpObj := c.NewObject()
		mk := func(method string) *quickjs.Value {
			return c.NewFunction(func(c *quickjs.Context, this *quickjs.Value, args []*quickjs.Value) *quickjs.Value {
				url := ""
				if len(args) > 0 {
					url = args[0].String()
				}
				h.mu.Lock()
				h.httpCalls++
				h.mu.Unlock()
				return c.NewPromise(func(resolve, reject func(*quickjs.Value)) {
					go func() {
						resp := doHTTP(method, url) // goroutine 里只做 Go 的事
						h.post(func(c *quickjs.Context) {
							// ★ 回到 JS 线程再造值 —— 见 jsTask 上面那段
							o := c.NewObject()
							o.Set("status", c.NewInt32(int32(resp.status)))
							o.Set("body", c.NewString(resp.body))
							o.Set("ok", c.NewBool(resp.status >= 200 && resp.status < 300))
							resolve(o)
						})
					}()
				})
			})
		}
		httpObj.Set("get", mk("GET"))
		httpObj.Set("post", mk("POST"))
		httpObj.Set("delete", mk("DELETE"))
		ctxObj.Set("http", httpObj)
	}

	// ---- 1.3 存储(权限 storage)----
	if granted["storage"] {
		st := c.NewObject()
		st.Set("get", c.NewFunction(func(c *quickjs.Context, this *quickjs.Value, args []*quickjs.Value) *quickjs.Value {
			k := ""
			if len(args) > 0 {
				k = args[0].String()
			}
			h.mu.Lock()
			v, ok := h.storage[k]
			h.mu.Unlock()
			return c.NewPromise(func(resolve, reject func(*quickjs.Value)) {
				if !ok {
					resolve(c.NewNull())
					return
				}
				resolve(c.NewString(v))
			})
		}))
		st.Set("set", c.NewFunction(func(c *quickjs.Context, this *quickjs.Value, args []*quickjs.Value) *quickjs.Value {
			if len(args) >= 2 {
				h.mu.Lock()
				h.storage[args[0].String()] = args[1].String()
				h.mu.Unlock()
			}
			return c.NewPromise(func(resolve, reject func(*quickjs.Value)) { resolve(c.NewNull()) })
		}))
		st.Set("delete", c.NewFunction(func(c *quickjs.Context, this *quickjs.Value, args []*quickjs.Value) *quickjs.Value {
			if len(args) > 0 {
				h.mu.Lock()
				delete(h.storage, args[0].String())
				h.mu.Unlock()
			}
			return c.NewPromise(func(resolve, reject func(*quickjs.Value)) { resolve(c.NewNull()) })
		}))
		ctxObj.Set("storage", st)
	}

	// ---- 1.5 界面(权限 ui)----
	if granted["ui"] {
		ui := c.NewObject()
		// showList 故意慢 —— S3.4 要验「等用户的交互流程不被看门狗误杀」
		ui.Set("showList", c.NewFunction(func(c *quickjs.Context, this *quickjs.Value, args []*quickjs.Value) *quickjs.Value {
			h.mu.Lock()
			h.uiCalls = append(h.uiCalls, "showList")
			d := h.slowUIDelay
			h.mu.Unlock()
			return c.NewPromise(func(resolve, reject func(*quickjs.Value)) {
				go func() {
					time.Sleep(d)
					resolve(c.NewNull()) // 模拟用户没选,直接关掉
				}()
			})
		}))
		for _, n := range []string{"showToast", "showProgress", "closeProgress"} {
			name := n
			ui.Set(name, c.NewFunction(func(c *quickjs.Context, this *quickjs.Value, args []*quickjs.Value) *quickjs.Value {
				h.mu.Lock()
				h.uiCalls = append(h.uiCalls, name)
				h.mu.Unlock()
				return c.NewUndefined()
			}))
		}
		ctxObj.Set("ui", ui)
	}

	// ---- 1.6 Emby(权限 emby.read)----
	if granted["emby.read"] {
		em := c.NewObject()
		em.Set("getServerInfo", c.NewFunction(func(c *quickjs.Context, this *quickjs.Value, args []*quickjs.Value) *quickjs.Value {
			return c.NewPromise(func(resolve, reject func(*quickjs.Value)) {
				o := c.NewObject()
				o.Set("id", c.NewString("srv-spike"))
				o.Set("name", c.NewString("SPIKE 假服务器"))
				resolve(o)
			})
		}))
		ctxObj.Set("emby", em)
	}

	// ---- 1.7 贡献点(权限 extensions)----
	if granted["extensions"] {
		ex := c.NewObject()
		for _, n := range []string{"register", "unregister"} {
			name := n
			ex.Set(name, c.NewFunction(func(c *quickjs.Context, this *quickjs.Value, args []*quickjs.Value) *quickjs.Value {
				id := ""
				if len(args) > 0 {
					id = args[0].String()
				}
				h.mu.Lock()
				h.extensions = append(h.extensions, name+":"+id)
				h.mu.Unlock()
				return c.NewPromise(func(resolve, reject func(*quickjs.Value)) { resolve(c.NewNull()) })
			}))
		}
		ctxObj.Set("extensions", ex)
	}

	// ---- 1.8 数据源(权限 sources)----
	if granted["sources"] {
		sc := c.NewObject()
		sc.Set("register", c.NewFunction(func(c *quickjs.Context, this *quickjs.Value, args []*quickjs.Value) *quickjs.Value {
			id := ""
			if len(args) > 0 {
				id = args[0].String()
			}
			h.mu.Lock()
			h.sources = append(h.sources, id)
			h.mu.Unlock()
			return c.NewPromise(func(resolve, reject func(*quickjs.Value)) { resolve(c.NewNull()) })
		}))
		sc.Set("unregister", c.NewFunction(func(c *quickjs.Context, this *quickjs.Value, args []*quickjs.Value) *quickjs.Value {
			return c.NewPromise(func(resolve, reject func(*quickjs.Value)) { resolve(c.NewNull()) })
		}))
		ctxObj.Set("sources", sc)
	}

	c.Globals().Set("ctx", ctxObj)

	// JS 侧的补齐:钩子注册 + 一个空的 console(有插件会顺手用)
	prelude := c.Eval(`
		globalThis.` + hookGlobal + ` = {};
		ctx.onEnable  = function (fn) { ` + hookGlobal + `.onEnable  = fn; };
		ctx.onDisable = function (fn) { ` + hookGlobal + `.onDisable = fn; };
		globalThis.console = globalThis.console || {
			log: function () { ctx.log.info.apply(null, arguments); },
			warn: function () { ctx.log.warn.apply(null, arguments); },
			error: function () { ctx.log.error.apply(null, arguments); },
		};
	`)
	prelude.Free()
}

type httpResp struct {
	status int
	body   string
}

var httpClient = &http.Client{Timeout: 10 * time.Second}

func doHTTP(method, url string) httpResp {
	if !strings.HasPrefix(url, "http://") && !strings.HasPrefix(url, "https://") {
		return httpResp{status: 0, body: "非法 URL"}
	}
	req, err := http.NewRequest(method, url, nil)
	if err != nil {
		return httpResp{status: 0, body: err.Error()}
	}
	// UA 三分口径里的「其它默认」道(SPEC §14.1)
	req.Header.Set("User-Agent", "LinPlayer/spike3")
	resp, err := httpClient.Do(req)
	if err != nil {
		return httpResp{status: 0, body: err.Error()}
	}
	defer resp.Body.Close()
	b, _ := io.ReadAll(io.LimitReader(resp.Body, 1<<20))
	return httpResp{status: resp.StatusCode, body: string(b)}
}
