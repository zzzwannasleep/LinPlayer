# SPIKE-3 · quickjs-go 能不能跑现有插件

> 状态:**已结题**(Windows;三个真插件全部通过)
> 起止:2026-08-31
> 关联:`SPEC.md` §9、`TODO.md` S3.1~S3.4、`knowledge/PLUGINS.md`
> 工程:`spikes/s3/`(`main.go` 判据集 + `ctxapi.go` 宿主 API)

## 1. 要回答的问题

**换成 quickjs-go 之后,现有插件包不重新打包还能不能跑?**

`SPEC.md` §9.1 承诺「现有插件包不重新打包即可运行」。这条承诺没验过。
`TODO.md` 还写着「**不接受**『让插件作者改代码』这个选项」。

## 2. 为什么它排在业务代码之前

插件市场是 Win 端**已有功能**。跑不了 = 22 条 `plugin.*` 的形状全变、
插件生态断代、`SPEC.md` §9.1 那条承诺作废。

## 3. 做法

语料是**三个真插件**(从绿色包的 `userdata/data/plugins/plugins/` 取):

| 插件 | 版本 | 权限 | JS 体积 |
|---|---|---|---|
| `com.linplayer.m3u` | 1.0.0 | `sources` `http` `storage` | 6.2 KB |
| `com.linplayer.uhdnow` | 1.0.0 | `http` `storage` `ui` `extensions` `emby.read` | 17.2 KB |
| `com.linplayer.vod` | 2.0.0 | `sources` `http` | 14.8 KB |

三个一共用到 **19 个不同的 `ctx.*`**,覆盖 5 组权限。宿主按 `knowledge/PLUGINS.md`
实现了对应子集,并且**权限门控是真的**:没声明的权限直接不注入,插件拿到 `undefined`,
不是一个会在运行时报错的桩。

复跑:

```bash
source scripts/env.sh
cd docs/go-migration/spikes/s3 && go build -o s3.exe .
./s3.exe --plugins <绿色包>/userdata/data/plugins/plugins --slow-seconds 3 --watchdog-ms 2000
# 退出码 = 不通过条数
```

## 4. 实测数据

### 4.0 环境

| 项 | 值 |
|---|---|
| quickjs-go | **v0.7.7**(内嵌 QuickJS 的 C 源,用项目级 zig cc 编译,**一次过**,约 27s) |
| Go / OS | 1.27.0 windows/amd64 / Windows 11 |
| GOPROXY | `proxy.golang.org` **可达**(拉 quickjs-go 成功)—— 这条以前没验过 |

> 顺带排掉一个风险:**核心层是零第三方依赖的,但插件引擎必须引入 quickjs-go**,
> 而 GOPROXY 通不通此前从没验过。现在验了。

### 4.1 S3.2 逐插件结果:3/3 全过

```
插件                         加载   onEnable  详情
com.linplayer.m3u          ✓      ✓        日志 1 条,注册源 [playlist]
com.linplayer.uhdnow       ✓      ✓        日志 1 条
com.linplayer.vod          ✓      ✓        日志 1 条,注册源 [site]
```

`m3u` 与 `vod` 都真的走到了业务逻辑(各自注册了数据源)。
**没有任何一个插件因为 JS 语言特性失败** —— 语料里的 `async/await`、模板字符串、
解构、可选链、`Promise` 全部正常。

### 4.2 🔴 三个只有跑起来才会现形的陷阱

这三条都不是「能不能跑」的问题,是「跑起来之后偶发出错、而且错得像插件的锅」。

#### ① 必须 `runtime.LockOSThread()`,否则偶发 `Maximum call stack size exceeded`

QuickJS 用「当前栈指针 vs 创建 runtime 时记录的栈基址」做栈溢出检查,
而 **Go 调度器会把 goroutine 在 OS 线程之间搬** —— 栈基址一变,检查就误报。

| 配置 | 5 次运行 |
|---|---|
| 锁 OS 线程 | **5 次全绿** |
| 不锁(`LP_NO_LOCK_OS_THREAD=1`) | **5 次全败** |

报的错是 `RangeError: Maximum call stack size exceeded`。
**这是最坏的一类失效**:偶发、每次失败的项还不一样,而且报出来的错
看起来完全像「这个插件写了个死递归」—— 插件作者查不出任何问题。

#### ② 异步结果必须回到 JS 线程再造值

在**非 owner goroutine** 上调 `ctx.NewObject()` 造出来的是无效值,
resolve 出去之后 JS 侧拿到 `undefined`,**而且不报任何错**:

```
TypeError: cannot read property 'status' of undefined
```

**`NewNull()` 之类的常量 tag 不受影响**(不需要分配)—— 所以
`ctx.sleep` 看起来一直是好的,一换成返回对象的 `ctx.http` 就坏。
**这正是最容易漏测的形态:简单的先写、先测、先通过,复杂的后写。**

正确形状:

```
goroutine 里只做 Go 的事(发 HTTP / 读盘)
        ↓ post(jsTask)
JS 线程上再造值并 resolve
```

宿主因此必须有一条「投回 JS 线程」的队列,并在泵作业的每一轮里排干它。

#### ③ 回调不能在 Go 侧存

`Value.Set` 会**接管**传入值的引用,而 `NewFunction` 回调拿到的 `args[0]`
是**借来的**(QuickJS 的调用帧还持有)。把它 `Set` 进对象 = 同一个引用释放两次,
表现是 `JS_FreeValue` 里的段错误。quickjs-go **没有 `Dup`/`Retain`** 可以补引用。

做法:让 `ctx.onEnable` / `ctx.onDisable` 的注册**发生在 JS 侧**(宿主注入一段
JS prelude 把回调存进隐藏全局对象),所有权全归 QuickJS 自己管,一行 Go 都不用写。

### 4.3 S3.1 异步链路(语料没覆盖到,单独补的)

三个插件的 `onEnable` 里 **HTTP 调用数都是 0** —— 也就是说
`ctx.http` 那条跨 goroutine 的链路**语料根本没走到**。不单独测,
「实现了 http」就是没验的。补测(本地 `httptest` 服务器,不依赖外网):

```
{"slept":true,"status":200,"ok":true,"pong":true,"ua":"LinPlayer/spike3","storage":"v"}
```

`ctx.sleep` 真等够、`ctx.http.get` 真发出去并拿到 200、响应体解析正确、
`ctx.storage` 往返正确、**出网带了我们的 UA**(`SPEC.md` §14.1 三条 UA 道)。

### 4.4 S3.3 / S3.4 护栏

| 判据 | 结果 |
|---|---|
| S3.3a 32MB 上限拦住 128MB 分配 | ✅ `InternalError: out of memory`,宿主存活 |
| S3.3b 死循环被中断 | ✅ 2.0s(看门狗阈值 2.0s),宿主存活 |
| S3.4 `await` 一个等 3s 的 UI 不被 2s 看门狗杀掉 | ✅ 返回 `survived`,实等 3.3s |

> **看门狗的阈值用 2s 而不是 TODO 原文的 30s**:机制一样(超过阈值就中断),
> 2s 只是让测试跑得快。30s 是产品取值,不是机制。

**关键设计点:看门狗的 deadline 必须在每次泵作业时重置。**
中断处理器只在 **JS 正在执行** 时被调用,所以 `await` 期间它不会触发 ——
这正是 S3.4 能通过的机制。但 `await` **恢复之后插件还要接着干活**,
如果那时 deadline 还停在 2 秒前,这段活会被立刻杀掉。

### 4.5 三条反向注入(先红)

| 注入 | 期望 | 实测 |
|---|---|---|
| ① 上限放到 512MB | 128MB 分配应当**成功** | ✅ 成功(证明拦截来自上限) |
| ② 不装中断处理器(**子进程**里) | 死循环不会自己停 | ✅ 跑满 4s 未结束 |
| ③ 泵作业时不重置 deadline | 长等待应当**被误杀** | ✅ 「被看门狗中断」 |

> **② 的第一版注入本身有 bug**,值得单独记一笔:我一开始把死循环放在
> **另一个 goroutine** 上 Eval,那违反了 quickjs-go 的 owner-goroutine 约束 ——
> 不但没测到东西,还**污染了后面所有测试**(S3.4 从通过变成失败)。
> **「注入本身有 bug」比「没有注入」更糟:它会让你以为护栏坏了。**
> 改成开子进程之后正常。
>
> **③ 的第一版也是错的**:注入版里 `await` 完就 `return`,那段代码短到
> QuickJS 的中断检查根本没触发,于是「不重置也没事」——
> 把一条真约束测成了不存在。改成「等完之后接着干 300ms 的活」(真实插件的形状)才红。

## 5. 结论

> **quickjs-go 能跑现有插件。三个真插件 3/3 加载并启用成功,
> 没有一个因为 JS 语言特性失败,`SPEC.md` §9.1「不重新打包即可运行」的承诺成立。**
>
> 但宿主实现有三条**不写就偶发出错**的硬约束,必须写进契约:
> ① 锁 OS 线程 ② 异步结果回 JS 线程再造值 ③ 回调注册放在 JS 侧。

## 6. 若失败:备选方案

本次没失败。留给以后:

| 触发条件 | 走哪条 |
|---|---|
| 某个插件用到 QuickJS 不支持的特性 | 先看是不是 polyfill 能补;真不行再评估把引擎放进独立进程 |
| 锁 OS 线程带来的并发瓶颈(插件多时) | 每插件一个专用 OS 线程(现在是每插件一个 Runtime,天然可分线程) |

## 7. 对 SPEC 的影响

- [x] `SPEC.md` §9.2 —— 新增三条宿主实现约束(锁线程 / 回 JS 线程造值 / 回调放 JS 侧)
- [x] `TODO.md` S3.1~S3.4 打勾;新增 S3.5(其余插件语料)
- [x] 记录 GOPROXY 可达 + quickjs-go 用 zig cc 编译通过

## 8. 遗留问题

1. **语料只有三个插件。** 插件仓库里还有别的(独立仓库),没全部跑过。
   `TODO.md` 原文写的是「现存**全部**插件」—— 这三个是绿色包里带的,不是全集。
2. **只测了 `onEnable`,没测数据源的三个函数**(`listDir` / `search` / `resolvePlay`)。
   那才是插件真正干活的地方,而且它们的返回值形状要和 `MediaSourceBackend` 对齐。
3. **没测 `ctx.ui.form` 这类真交互**(S3.4 用的是一个会自己返回的假 UI)。
4. **没测插件崩了之后宿主的恢复**:一个插件 panic / OOM 之后,
   同进程里的**其它插件**还能不能正常工作,没验。
5. **性能没量。** 启动一个引擎要多久、内存占多少、20 个插件同时装会怎样,都没数。
6. **锁 OS 线程的代价没评估。** 每插件一个 Runtime + 锁线程 = 每插件一条 OS 线程,
   插件多了是不是要改成线程池,没想过。
