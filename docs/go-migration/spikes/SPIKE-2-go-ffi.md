# SPIKE-2 · Go 的 C ABI 能不能被宿主稳定调用(Windows / C# 侧)

> 状态:**Windows + C# 已结题**;Kotlin(S2.3)与 Swift(S2.4)未做
> 起止:2026-08-31
> 关联:`SPEC.md` §5(整章)、`TODO.md` S2.1 / S2.2
> 工程:`spikes/s2/`(`lpcore/` Go 核心 + `CsHost/` C# 宿主 + `probe_py.py` 判别器)

## 1. 要回答的问题

**SPEC §5 那套 FFI 契约,原样实现出来能不能在 .NET 宿主上稳定跑?**

不是「调得通吗」—— 调通是最低要求。要验的是契约里那些**只有跑起来才会现形**的条款:
panic 边界、内存所有权、事件队列的分级背压、关停时的 eof。

## 2. 为什么它排在业务代码之前

整个架构的地基。它塌了,三端 UI 全部无处可接。
而且 §5 标着【一次做对】—— 一旦三端绑定写完再改,代价是三份重写。

## 3. 做法

```
spikes/s2/
  lpcore/          Go c-shared,零第三方依赖(全标准库)
    abi.go         LP_ABI 常量(唯一真值)
    main.go        SPEC §5.1 的 13 个导出 + 每个导出的 panic 兜底
    queue.go       事件队列:分级背压 / 合并 / 停滞检测 / eof
    dispatch.go    命令分发 + worker 池 + panic 边界
    glchan.go      视频通道 B(阶段 A 是桩,阶段 B 已换成真 libmpv)
    util.go
  CsHost/          C# 控制台宿主,用 LibraryImport(不是 DllImport)
  probe_py.py      ★ 判别器:同一个 DLL 换 Python 宿主
```

**刻意的两条切分:**

1. **阶段 A 不接 libmpv。** 把「契约通不通」和「cgo 能不能链上 libmpv」拆成两个变量,
   一次只动一个。视频通道那 5 个导出先用桩,阶段 B 再换真实现。
2. **零第三方依赖。** GOPROXY 在本地网络能不能通没验过,不该让拉模块失败挡住这个 SPIKE。

复跑:

```bash
source scripts/env.sh
(cd docs/go-migration/spikes/s2/lpcore && go build -buildmode=c-shared -o ../out/lpcore.dll .)
(cd docs/go-migration/spikes/s2/CsHost && dotnet build -c Release)
LP_DEBUG_CMDS=1 ./CsHost/bin/Release/net10.0/CsHost.exe out/lpcore.dll   # 退出码 = 不通过条数
```

## 4. 实测数据

### 4.0 环境

| 项 | 值 |
|---|---|
| OS | Windows 11 Home China 10.0.26200 |
| Go | 1.27.0 windows/amd64(项目级工具链 `.toolchain/`) |
| cgo 的 C 编译器 | zig 0.16.0 (`zig cc`) |
| .NET | SDK 10.0.301,`net10.0`,`LibraryImport` 源生成 P/Invoke |
| 产物 | `lpcore.dll` 5.5 MB,**导出 13 个,与 SPEC §5.1 一字不差**(PE 导出表核准,非字符串搜索) |

### 4.1 判据:35 条全绿

| 段 | 覆盖的 SPEC 条款 | 结果 |
|---|---|:--:|
| 1 ABI 协商 | §5.0 | ✅ 2/2 |
| 2 启动与事件泵 | §5.1 §5.11 | ✅ 2/2 |
| 3 调用协议 | §5.2(信封 / seq / **必需的 ts** / UTF-8 往返) | ✅ 6/6 |
| 4 `system.capabilities` | §5.6 | ✅ 3/3 |
| 5 流式结果与取消 | §5.7 | ✅ 4/4 |
| 6 错误模型 | §5.4(`E_UNSUPPORTED` / `E_NOTFOUND` / `E_INVALID`) | ✅ 5/5 |
| 7 panic 边界 | §5.10 的三件事 | ✅ 3/3 |
| 8 两组视频通道导出 | §5.1 第 2、3 组 | ✅ 5/5 |
| 9 内存所有权 | §5.3 | ✅ 2/2 |
| 10 关停与 eof | §5.11 | ✅ 3/3 |

```
== 9. 内存所有权:2 万次 call/free ==
       lp_next_event 分配 20020 次,lp_free 释放 20020 次,未释放 0
== 10. 关停:必须发 eof,否则事件线程永远退不出来 ==
  [通过] 事件线程 3 秒内退出
  [通过] 收到了 {"t":"eof"}
全部通过。
```

### 4.2 🔴 最重要的发现:panic 边界只对**一半**的 panic 有效

SPEC §5.10 写的是「每个导出函数体顶层 `defer recover()`」。实测下来这句话**不完整**。

同一个 `lpcore.dll`,同一条命令,只改「故障是哪一类」和「goroutine 在哪儿创建」:

| 故障 | 在哪条 goroutine 上 | .NET 宿主 | Python 宿主 |
|---|---|:--:|:--:|
| 显式 `panic("…")` | cgo 调用里现开的 | ✅ recover 住,`E_INTERNAL` | ✅ |
| **空指针解引用** | **cgo 调用里现开的** | ❌ **进程被 `0xC0000409` 硬杀** | ✅ |
| 空指针解引用 | `lp_init` 时就存在的后台 goroutine | ✅ recover 住 | ✅ |

三条读法:

1. **不是 Go 的 recover 不行** —— 换 Python 宿主,两类故障都 recover 得住。
2. **也不是进程级的异常处理被谁抢了** —— 同一个进程里,后台 goroutine 上的同款故障
   recover 得住,只有「在 cgo 调用里现开的」那条会死。
3. 死的时候**什么都不打印**:`GOTRACEBACK=system` 也一个字没有,stderr 全空,
   只有退出码 `0xC0000409`(fastfail)。**这是最难查的一种崩溃。**

试过但**无效**的缓解:`DOTNET_LegacyExceptionHandling=1`、
`runtime/debug.SetPanicOnFault(true)`、`GOTRACEBACK=system`。

**有效的做法:worker 池。**

```
lp_call  ──(投 job)──►  jobs chan  ──►  lp_init 时就建好的 8 条 worker goroutine
                                          └─ 每条 worker 顶层 defer recover()
```

先绿后红的对照(`LP_INLINE_GOROUTINE=1` 是反向注入开关,退回「现开 goroutine」):

| 执行方式 | 显式 `panic()` | 空指针解引用 |
|---|:--:|:--:|
| **worker 池**(默认) | 退出码 0 | **退出码 0** |
| 现开 goroutine【注入】 | 退出码 0 | **`-1073740791`** |

**推断的机制**(标为推断,没有进一步验证到运行时内部):在 cgo 调用里现开的 goroutine
可能被调度到「被 Go 临时收编的宿主线程」上,而那条线程的异常处理归宿主运行时管。
worker 池让命令永远跑在 Go 自己创建的线程上。

> **这条要写进契约,不能只写进注释。** 它的失效模式是「偶发、无日志、无栈、
> 只有一个退出码」—— 靠 code review 拦不住,靠注释提醒也拦不住,
> 只有把「命令必须投给 worker 池」做成唯一的入口才拦得住。

### 4.3 第二个教训:内存判据的第一版是错的,反向注入把它抓了出来

第一版用「进程私有内存增长」当判据,阈值 24 MB。跑出来 26.2 MB,红了。
但接上 `--leak` 反向注入(故意不调 `lp_free`)之后:

| | 进程私有内存增长 |
|---|---|
| 正常(每条都 free) | 23.7 MB |
| **故意不 free** | **24.5 MB** |

**几乎一样。** 说明这条判据根本没在测它声称的东西 ——
2 万次往返里漏掉的 C 字符串只有约 2 MB,完全被 .NET 运行时自己的分配淹没。

换成**直接数 `alloc` / `free`**(计数在 Go 侧,`system.exportDiagnostics` 透出):

| | 分配 | 释放 | 未释放 |
|---|---:|---:|---:|
| 正常 | 20020 | 20020 | **0** |
| 故意不 free | 20020 | 0 | **20020** |

判据干净,反向注入干净地变红。**这是「先红」纪律的价值:如果不注入,
第一版那条判据会以「红了但看起来只是阈值偏紧」的样子被调松,然后永远测不出真泄漏。**

> 顺带:第一版的红有一半是**测试自己漏** —— 事件泵给 2 万个 seq 每个都攒了一个
> partial 桶。已改成只对显式关心的 seq 跟踪。

### 4.4 阶段 B:接上真 libmpv,端到端跑通 Avalonia

**cgo 怎么链 libmpv:实测 `zig cc` 能直接吃仓库自带的 MSVC 格式导入库 `mpv.lib`。**

```go
#cgo LDFLAGS: -L${SRCDIR}/../../../../../crates/mpv/libmpv -lmpv
```

不需要 mingw 格式的 `.dll.a`,也不需要退回运行时 `LoadLibrary`。
运行时把 `libmpv-2.dll` 放在 DLL 搜索路径上即可(宿主用 `NativeLibrary.Load` 绝对路径预载)。

**`AvaloniaProbe` 改成只用 13 个契约导出。** 原来它用的是 S1.2 那套 `lp_spike_*` 专用口子;
现在换成 `lp_init` / `lp_call` / `lp_next_event` / `lp_free` / `lp_shutdown` + 5 个 `lp_gl_*`,
属性读取走 `player.prop` 命令、起播走 `player.play`。
**UI 侧不再有任何 mpv 类型,也没有任何非契约导出** —— 这才是真实架构,
比原计划的「一行不改」更有价值。

用 Go 核心跑 S1.2 的四条判据(WGL,1080p60,输出 1920×1080):

```
FBO(末次)       : fb=1 1920x1080      hwdec-current : d3d11va-copy
lp_gl_render     : 624 次 -> 59.9 fps  lp_gl_swapped : 624 次
播放推进         : 10.40s / 10.41s = 0.999  跟得上   frame-drop-count : +0

  A 窗口里出画面        : 视频区逐像素帧间差 3.05  -> 通过
  B 半透明控件可见      : 最小品红偏移 324.5       -> 通过
  C 控件确实是半透明    : 叠加区逐像素帧间差 1.84  -> 通过(视频透上来了)
  D 不闪(每帧都在)    : 通过
```

干净口径(`--shots 0 --no-anim --gl wgl`)与 S1.2 记录的 Rust 桩对比:

| 核心 | 片源 | 渲染 fps | 丢帧 | CPU 单核 |
|---|---|---:|---:|---:|
| Rust 桩(S1.2 记录) | 1080p60 | 60.0 | 0 | 18~24% |
| **Go 核心** | 1080p60 | **59.9** | **0** | **25%** |
| Rust 桩(S1.2 记录) | 4K24 | 24.0 | 0 | 13~26% |
| **Go 核心** | 4K24 | **24.0** | **0** | **20%** |

**同量级。** Go 侧 1080p60 的 25% 略高于 Rust 桩那一批的上界,
候选原因是核心层里 4 Hz 的 `player.status` 每次读 6 个 mpv 属性(每次都要加锁 + 一次
`mpv_get_property_string` + 一次 `mpv_free`)—— **这条是猜测,没有量过**,列进遗留问题。

顺带在核心层就带上了 **N1(CVE-2026-8461)** 的防护:mpv 初始化选项里 `vd = -magicyuv`。
迁移必带清单的第一条,在地基里就带上,别等以后补。

## 5. 结论

> **SPEC §5 的契约在 Windows + C# 上成立,35 条判据全绿;
> 接上真 libmpv 之后,Avalonia 端到端跑通 S1.2 的四条判据,性能与 Rust 桩同量级。**
> 但 §5.10 的表述必须补一条:**光有 `defer recover()` 不够,
> 命令还必须跑在 `lp_init` 时就建好的 worker 池上** ——
> 否则运行时故障(不是显式 panic)会直接 fastfail 掉整个进程,而且没有任何日志。

## 6. 若失败:备选方案

本次没失败。若将来在某个宿主上 worker 池也挡不住:

| 触发条件 | 走哪条 |
|---|---|
| 某宿主上仍会 fastfail | 把核心层拆成**独立进程**,用本地 socket 通信。代价是每次调用多一次 IPC,以及 §6 那条数据通道要重做 |
| 只有个别命令危险 | 那些命令单独起 worker,并接受它们崩了只影响自己 |

## 7. 对 SPEC 的影响

- [x] `SPEC.md` §5.10 —— 新增「命令必须由 `lp_init` 建立的 worker 池执行」,并写清失效模式
- [x] `SPEC.md` §5.10 —— 测试要求补上「两类 panic 分开测」(显式 panic / 运行时故障)
- [x] `SPEC.md` §5.3 —— 内存判据改成 `alloc`/`free` 计数,并写明「用进程内存当判据测不出来」
- [x] `TODO.md` S2.1 / S2.2 打勾;S2.1 的「八个函数」订正为 13 个

## 8. 遗留问题

1. **Kotlin(S2.3)与 Swift(S2.4)没做。** worker 池那条结论是在 .NET 上得到的,
   JVM 的 JNI 也有自己的信号处理(而且历史上和 Go 冲突过),**必须单独验**。
2. ~~阶段 B~~ ✅ 已完成,见 §4.4。
3. ~~cgo 链 libmpv 的方式~~ ✅ 已定:`zig cc` 直接链 `mpv.lib`,见 §4.4。
3b. **Go 核心比 Rust 桩多用约 4 个百分点 CPU(1080p60)的原因没查。**
   候选是 4 Hz 的 `player.status` 每次读 6 个 mpv 属性。**这是猜测,没量过。**
4. **worker 数量 8 是拍的**,没有压测依据。长任务(下载 / 预取)会不会把池占满、
   要不要分池,没验。
5. **队列的合并与背压没有专门测。** 现在只跑了正常路径;
   「队列满了 result 阻塞而 log 被丢」这条要单独造压力验。
6. **fastfail 的机制只到「推断」。** 没有进一步验证到 Go 运行时 / CoreCLR 内部。
   结论(worker 池有效)是实测的,机制解释不是。
