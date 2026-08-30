# LinPlayer 架构规格 · Go 核心 + 各端原生 UI

> 状态:草案 v0.1 · 2026-08-30
> 这份文档描述**目标架构**,不描述现状。迁移路径见 `MIGRATION.md`,任务清单见 `TODO.md`。

---

## 0. 这份文档的地位

本规格是**唯一契约来源**。三端 UI 与核心层之间的任何争议,以本文为准。

标了 `【一次做对】` 的地方,一旦落地就极难改(要同时改三端),而且**改错的表现都不是报错**:

| 节 | 内容 | 事后才改的代价 |
|---|---|---|
| §5.0 | ABI 版本协商 | 崩溃或静默乱码,没有任何一层会喊 |
| §5.1–5.3 | 导出函数签名、调用协议、内存所有权 | 「偶发崩溃、复现不了」 |
| §5.10 | panic 边界 | 进程整个消失,三端的 catch 都拦不住 |
| §5.11 | 事件队列与背压 | 要么 OOM,要么某个命令永远没有回音 |
| §7.2 | 视频通道的 surface 交接 | use-after-free |

其余部分都可以边做边改。

**PC 端(Windows / Linux)的 UI 规格另有一份:[`UI_PC.md`](UI_PC.md)。**
本文定的是跨端契约,`UI_PC.md` 定的是 PC 端的设计系统、动效、组件、交互与逐页规格 ——
两份合起来才够直接开工。

---

## 1. 目标与非目标

### 目标

| # | 目标 | 判据 |
|---|---|---|
| G1 | 业务逻辑写一次,五端共用 | 三端 UI 代码里 0 行 Emby / 网盘 / 弹幕 / 插件协议代码 |
| G2 | 每个平台的 UI 都是该平台的最优解 | Android 用 Compose,Apple 用 SwiftUI,Windows 用 XAML 生态 |
| G3 | 视频与 UI 在**同一个顶层窗口内**合成 | 不存在"两个顶层窗口手动对齐几何"这种东西 |
| G4 | Android TV 遥控器焦点由框架提供 | 不再自己实现空间导航算法 |
| G5 | 插件生态零改动存活 | 现有插件包不重新打包即可运行 |

### 非目标

- **不追求单一 UI 框架**。刻意接受 3 套 UI 代码库。
- **不做 Web 端。**
- **不保证 iOS 上架**。iOS 目标是"技术上能装",分发渠道另议(见 §11.4)。
- **不做实时转码。** 转码是服务端的事。

---

## 2. 总体分层:三通道模型

```
┌──────────────────────────────────────────────────────────────────────┐
│  UI 层(每平台一份)                                                    │
│  Android: Kotlin+Compose   Win/Linux: C#+Avalonia   Apple: SwiftUI    │
└──────┬───────────────────────┬───────────────────────┬───────────────┘
       │ ① 控制通道             │ ② 数据通道             │ ③ 视频通道
       │   C ABI / JSON        │   HTTP 127.0.0.1      │   surface 句柄
       │   异步 + 事件队列       │   图片/资源/字幕/流     │   (一个 int64)
┌──────▼───────────────────────▼───────────────────────▼───────────────┐
│  核心层(Go,一份,编译成 .so / .dll / .a)                             │
│  ┌────────┬────────┬─────────┬─────────┬────────┬──────────────────┐ │
│  │ emby   │ source │ danmaku │ plugins │ net    │ sync / download  │ │
│  └────────┴────────┴─────────┴─────────┴────────┴──────────────────┘ │
│  ┌──────────────────────────────────────────────────────────────────┐│
│  │ player:mpv 控制(cgo → libmpv)   ← 视频通道的另一端                ││
│  └──────────────────────────────────────────────────────────────────┘│
└──────────────────────────────────────────────────────────────────────┘
```

### 为什么是三条通道而不是一条

一条通道(全走 FFI)会逼你把图片字节、字幕文本、视频帧全塞进 JSON 或手工 marshal。
三条通道各自用最合适的搬运方式:

| 通道 | 搬什么 | 为什么用这个方式 |
|---|---|---|
| ① 控制 | 结构化的小数据(条目列表、配置、状态) | JSON,三种宿主语言都能零成本反序列化 |
| ② 数据 | 图片、插件资源、字幕文件、预取流 | HTTP,三端都有成熟的图片加载器和流式客户端,不用写一行 marshal |
| ③ 视频 | 一个 surface 句柄 | 只有一个整数过 FFI,剩下的 libmpv 自己干 |

**这条分工是整个架构最重要的一次简化。** 通道 ② 让"取一张海报"变成
`AsyncImage("http://127.0.0.1:PORT/img?...")` —— Coil / Avalonia Bitmap / SwiftUI AsyncImage
各自的缓存、解码、复用全部白送,核心层一行图片 marshal 代码都不用写。

---

## 3. 选型

### 3.1 决策

| 层 | 选择 | 版本下限 |
|---|---|---|
| 核心 | **Go** | 1.22+ |
| Android 手机 / TV | **Kotlin + Jetpack Compose** + `androidx.tv` | Compose BOM 2024.09+ |
| Windows / Linux | **C# + Avalonia** | .NET 8 / Avalonia 11.1+ |
| Apple(后置) | **Swift + SwiftUI** | iOS 16 / macOS 13+ |
| 播放引擎 | **libmpv**(所有平台) | 0.37+ |
| 插件引擎 | **QuickJS**(经 cgo) | 与现有插件 ABI 一致 |

### 3.2 核心层为什么必须是 Go / Rust / C++ 三选一

核心层要被 Kotlin(JNI)、Swift(bridging header)、C#(P/Invoke)**同时**加载,
所以它必须能编译成 **C ABI 的共享库 / 静态库**。这一条把候选集砍到只剩三个。

| 语言 | C ABI | 结论 |
|---|---|---|
| Go | `-buildmode=c-shared` / `c-archive` | ✅ 选它 |
| Rust | `crate-type=["cdylib","staticlib"]` | 技术可行,团队不选 |
| C / C++ | 天生 | 团队不选 |
| C# | NativeAOT 能出库,但 .NET on Android 是**应用模型**不是可嵌入库 | ❌ |
| Kotlin | Kotlin/Native 只对 Apple 友好,Windows 侧要拖 JVM | ❌ |
| Dart / TS | 无 | ❌ |

### 3.3 Go 对本项目负载的适配度

| 核心层在干的事 | Go 侧方案 |
|---|---|
| 本地预取代理(HTTP server + Range + 环形磁盘缓存 + 并发拉流) | `net/http` + goroutine + `os.File`。Go 的主场 |
| ~10 个 HTTP 源客户端 | stdlib `net/http`,不需要挑第三方库、不需要管 feature flag |
| 逆向登录的签名(RSA / secp256k1 / MD5 拼接) | `crypto/rsa`、`math/big`、`decred/dcrd/dcrec/secp256k1` |
| 插件 JS 引擎 | `buke/quickjs-go`(cgo 绑定 QuickJS,与现有插件同一个引擎) |
| SMB / WebDAV / FTP | `cloudsoda/go-smb2`、`studio-b12/gowebdav`、`jlaffaye/ftp` |
| libmpv | cgo。调用频率是 UI 级别(≤60/s),cgo 开销可忽略 |
| 弹幕 ASS 生成 | 纯字符串处理 |

### 3.4 被明确否掉的

| 方案 | 否掉的理由 |
|---|---|
| .NET MAUI | Windows 端(WinUI3 封装)质量最差,而 Windows 是主力平台 |
| Flutter | 本仓库已删除过一次;且 Dart 当不了 C ABI 核心 |
| Qt + Go | Qt 只与 C++ 配套,Go 的 Qt 绑定已停止维护 |
| 核心层写 C# | `.NET on Android` 不是可嵌入库,会连带吃掉 UI 层选择权 |
| 单一 UI 框架(Compose MP / Avalonia 全端) | 牺牲 Android TV 焦点与 Apple 原生观感,而本项目不赶工期 |

---

## 4. 核心层(Go)规格

### 4.1 包结构

```
core/
├── ffi/            # C ABI 导出层。唯一带 //export 的包。不含业务逻辑
├── bus/            # 命令分派 + 事件队列
├── config/         # AppConfig / Account / Prefs 的读写与迁移
├── paths/          # 唯一的路径出口(见 §10.1)
├── emby/           # Emby 客户端
├── source/         # 媒体源抽象 + 各后端实现
│   ├── backend.go      # MediaSourceBackend 接口
│   ├── aliyun/ baidu/ pan115/ pan139/ pan189/ quark/ openlist/
│   ├── smb/ webdav/ ftp/ local/
│   ├── feiniu/ anirss/
│   └── pluginsrc/      # 插件提供的源
├── player/         # libmpv 控制(cgo)。见 §7
├── danmaku/        # 弹幕拉取、匹配、ASS 生成
├── plugins/        # QuickJS 宿主、权限、市场、贡献点
├── net/
│   ├── prefetch/       # 预取代理(环形磁盘缓存)
│   ├── preload/        # 详情页预热
│   ├── cf/             # 线路优选
│   └── localserve/     # 数据通道 HTTP 服务(§6)
├── sync/           # Trakt / Bangumi / 日历
├── download/       # 多线程下载
├── history/        # 本地观看记录 + 跨服续播
├── update/         # 自更新
├── companion/      # 电视端手机控制台
└── secrets/        # 编译期凭据(-ldflags -X)
```

**规则:** `ffi/` 之外的任何包都不许出现 `//export`、`C.` 或 `unsafe.Pointer`。
违反这条 = 业务逻辑跟 FFI 焊死,以后没法单独测。唯一例外是 `player/`(它必须 cgo 调 libmpv)。

### 4.2 生命周期

```
lp_init(config_json) ──► 建 App 实例(单例) ──► 起 localserve ──► 起插件管理器
                                                     │
                          ┌──────────────────────────┘
                          ▼
        宿主起一个专用线程死循环:lp_next_event(timeout) ──► 分发给 UI
                          │
        宿主任意线程:lp_call(seq, cmd, args) ──► 立即返回 ──► 结果走事件队列
                          │
lp_shutdown() ──► 停播放 ──► 落盘 ──► 停 localserve ──► 停插件 ──► 事件队列发 EOF
```

- **单例。** 一个进程只有一个 Go 运行时,也只有一个 App 实例。主窗口与播放窗口共用同一个实例
  (这正是现在 `pending_play` 走核层而不走 URL / localStorage 的原因)。
- `lp_init` 幂等:重复调用返回同一实例,不重复初始化。
- `lp_shutdown` 之后所有 `lp_call` 返回 `E_SHUTDOWN`,不 panic。

### 4.3 并发模型

- 每条 `lp_call` 起一个 goroutine,**不排队**。命令之间不保证顺序。
- 需要顺序的地方(播放器控制)由 `player` 包内部串行化:一个 goroutine 持有 mpv handle,
  外部通过 channel 投递。这对应现有约束"挂载字幕必须在事件线程"。
- 共享状态一律 `sync.RWMutex` 或 channel,**禁止**跨 goroutine 传裸指针。
- 取消:每条 `lp_call` 的 `seq` 可用 `lp_cancel(seq)` 取消,内部走 `context.Context`。
  聚合搜索、跨服请求必须尊重取消(对应现有的"离页杀请求")。

---

## 5. 【一次做对】FFI 契约

### 5.0 ABI 版本协商

**核心库与 UI 是两个可以被分别替换的文件。** 绿色包升级、增量更新、用户手动覆盖某个
`.dll` —— 任何一种都能造出「新 exe + 旧 lpcore.dll」的组合。

FFI 版本错配的表现**不是报错,是崩溃或静默乱码**:结构变了、字段少了、事件名改了,
P/Invoke 照样调得进去,只是读到的内存不是它以为的那个东西。这类故障没有任何一层会喊。

```
UI 启动 --> lp_abi_version()
              |
              +- 符号不存在(EntryPointNotFound / dlsym NULL)-> 核心库过旧 -> 明确报错退出
              +- 返回值 != UI 编译时的 LP_ABI -> 版本错配 -> 明确报错退出
              +- 相等 -> lp_init(...)
```

| 规则 | 内容 |
|---|---|
| `LP_ABI` 是什么 | 一个整数,**只在破坏性变更时 +1**:导出函数签名、事件外层信封、错误对象形状、surface 交接语义 |
| 什么不算破坏性 | 新增命令、新增事件 `name`、给已有 JSON 加字段 —— 这些靠 `system.capabilities` 探测,不动 `LP_ABI` |
| 谁持有真值 | 核心层 `ffi/abi.go` 一处常量;三端绑定由生成器写入,**不许手抄** |
| 门禁 | 契约测试断言「三端绑定里的 `LP_ABI` == 核心层常量」,不等即红 |

> **为什么值得多一个导出。** 本节开头写着「少即是对」,这条是例外,必须说清理由:
> 没有它,错配的代价是「偶发崩溃、复现不了」(与 §5.3 同款);有了它,代价是一行明确的
> 错误提示。**用一个导出换掉一整类不可诊断的故障,是这份契约里性价比最高的一次交易。**
> 而且它天然向后兼容 —— 旧库里没有这个符号,这件事本身就是信号。

### 5.1 导出函数表

**全部导出函数只有 8 个。** 少即是对 —— 每多一个导出,三端就多一份绑定要写、要测、要对齐。

```c
// ABI 版本。**必须在 lp_init 之前调**,不匹配就不要 init。见 §5.0。
int32_t  lp_abi_version(void);

// 初始化。config_json 传宿主已知的平台信息(数据目录、平台名、版本号)。
// 返回 0 成功,非 0 为错误码。幂等。
int32_t  lp_init(const char* config_json);

// 发起一条命令。立即返回(不阻塞)。结果通过事件队列以 {"t":"result","seq":N,...} 送回。
// seq 由宿主分配,必须单调递增且非 0。
// 返回 0 表示已受理;非 0 表示连受理都失败(如未 init)。
int32_t  lp_call(int64_t seq, const char* cmd, const char* args_json);

// 取消一条在途命令。对已完成的 seq 是空操作。
void     lp_cancel(int64_t seq);

// 阻塞取下一个事件。timeout_ms < 0 表示无限等。
// 返回 UTF-8 JSON 的 C 字符串;超时返回 NULL。**调用方必须用 lp_free 释放。**
char*    lp_next_event(int32_t timeout_ms);

// 释放 lp_next_event 返回的指针。
void     lp_free(char* ptr);

// 把一个平台 surface 句柄交给播放器。见 §7.2。
// kind: 0=none(解绑) 1=ANativeWindow* 2=HWND 3=X11 Window 4=CAMetalLayer*
int32_t  lp_set_surface(int32_t kind, int64_t handle, int32_t width, int32_t height);

// 关停。之后所有调用返回 E_SHUTDOWN。阻塞直到落盘完成。
void     lp_shutdown(void);
```

**没有 `lp_call_sync`。** 同步与异步两套路径 = 两倍的错误模式。全异步,一条路。
宿主想要同步语义,自己在调用侧包一个"等这个 seq 的 result"的 helper —— 那是 15 行的事,
而且各语言都有更自然的写法(Kotlin `suspendCancellableCoroutine`、
C# `TaskCompletionSource`、Swift `withCheckedContinuation`)。

### 5.2 调用协议

```
宿主                                       Go 核心
 │                                           │
 │── lp_call(42, "emby.listItems", {...}) ──►│  起 goroutine
 │◄─ 0(已受理) ──────────────────────────────│
 │                                           │
 │  [事件线程] lp_next_event(-1) ────────────►│  阻塞
 │◄─ {"t":"result","seq":42,"ok":true,        │
 │    "data":{...}} ──────────────────────────│
 │                                           │
 │  lp_free(ptr)                             │
```

**事件 JSON 统一外层:**

```jsonc
// 命令结果
{"t":"result","seq":42,"ts":1724990400123,"ok":true,"data": <任意> }
{"t":"result","seq":42,"ts":1724990400123,"ok":false,
 "err":{"code":"E_AUTH","msg":"未登录","retryable":false}}

// 流式中间结果(见 §5.7)
{"t":"partial","seq":42,"ts":1724990400090,"data":{...}}

// 主动推送(seq 恒为 0)
{"t":"event","seq":0,"ts":1724990400200,"name":"player.status","data":{...}}
```

**`ts` 是必需字段**,单调毫秒(核心层进程内单调时钟,不是墙钟)。
理由:出问题时要把「UI 什么时候收到」和「核心层什么时候发出」并排看 ——
只有一个时间点的日志对不出「是核心层慢了还是 UI 的事件线程堵了」,
而这两者的修法完全不同。§5.11 的队列积压诊断也依赖它。

### 5.3 内存所有权

**唯一规则:Go 分配,宿主释放。**

- `lp_next_event` 返回的指针,宿主必须 `lp_free`。**漏一次就是永久泄漏。**
- 传进 Go 的 `const char*`(cmd / args_json / config_json)在调用返回后即失效,
  Go 侧必须在 `lp_call` 内**立刻**拷贝成 Go string,不许把指针带进 goroutine。
- **禁止**任何方向传结构体指针、回调函数指针、Go 指针。

> 违反这三条中任何一条,表现都是"偶发崩溃、复现不了"。
> 这是本文档里唯一必须写进三端 code review checklist 的一节。

### 5.4 错误模型

错误是 JSON 对象,不是字符串。现有代码返回 `Result<T, String>` —— 那个 String
到了 UI 层只能原样弹 toast,分不清"该重试"、"该重登"、"该报 bug"。

```jsonc
{"code":"E_AUTH", "msg":"令牌已过期", "retryable":false, "detail":"..."}
```

| code | 含义 | UI 该做什么 |
|---|---|---|
| `E_AUTH` | 凭据失效 | 引导重新登录 |
| `E_NETWORK` | 连不上 / 超时 | 提示 + 允许重试 |
| `E_UPSTREAM` | 服务端返回了错误 | 展示 `msg`,记日志 |
| `E_UNSUPPORTED` | 该源不支持这个能力 | 静默降级,**不弹错** |
| `E_NOTFOUND` | 条目不存在 | 空态 |
| `E_PERMISSION` | 插件权限未授予 | 弹权限对话框 |
| `E_INVALID` | 参数非法 | 这是 bug,记日志 |
| `E_SHUTDOWN` | 核心已关停 | 忽略 |
| `E_INTERNAL` | 兜底 | 记日志 + 上报 |

`E_UNSUPPORTED` 单列的理由:现有 `MediaSourceBackend` 有一批"默认返回不支持"的可选能力
(源内搜索、影视目录、进度上报)。UI 探测这些能力时收到的不是错误,是信息。
混在一起的表现是"进网盘就弹一个红色报错"。

### 5.5 事件类型表

| name | 触发时机 | 载荷要点 |
|---|---|---|
| `player.status` | 播放中 4 Hz | position / duration / paused / buffering / eof / ready |
| `player.tracks` | 文件加载完成 | 音轨、字幕轨列表 |
| `player.ended` | 播完或出错停止 | reason |
| `download.progress` | 下载任务变化 | id / bytes / speed / state |
| `prefetch.stats` | 预取代理 1 Hz | cached / upstream / threads |
| `source.qr` | 扫码登录轮询状态变化 | state / qr_png_url |
| `plugin.ui` | 插件请求宿主弹 UI | id / kind / descriptor(需 `plugin.uiRespond` 回) |
| `plugin.toast` | 插件请求提示 | level / msg |
| `config.changed` | 配置被任意路径改动 | 改了哪个域 |
| `account.status` | 服务器连通性探测结果 | server_id / state |
| `update.available` | 检查到新版本 | version / notes |
| `log` | 核心层日志 | level / msg |

**`config.changed` 是必需的。** 现在 PC 前端"零 store,各持副本",靠在调用层广播来同步。
原生 UI 同样会有多个页面持有同一份配置的副本 —— 把广播做成核心层的**主动事件**,
比让每个调用点自觉更可靠。

### 5.6 命令表

**266 条命令(桌面口径)。** 完整列表见 `COMMANDS.md`(从现有注册表生成)。

| 域 | 约条数 | 说明 |
|---|---|---|
| Emby(登录 / 浏览 / 详情 / 收藏 / 搜索) | ~45 | |
| 账号与线路 | ~20 | 含批量添加、深链、线路探测 |
| 播放器控制 | ~40 | 见 §7 |
| 媒体源(浏览型) | ~25 | 登录 / 扫码 / 列目录 / 解析播放 |
| 影视目录(VOD) | ~8 | 资源站型源 |
| 弹幕 | ~15 | |
| 插件 | ~35 | 市场 / 安装 / 权限 / 贡献点 / UI 回调 |
| 下载 | ~12 | |
| 设置与偏好 | ~30 | |
| 同步(Trakt / Bangumi / 日历) | ~18 | |
| 观看记录 | ~8 | |
| 系统(更新 / 日志 / 路径 / 诊断) | ~10 | |

#### 命名规范(迁移时统一)

现有命令名有历史包袱(`list_items` 与 `list_items_page` 并存,`views` 无前缀)。
新契约统一为 `<域>.<动作>`,camelCase 动作:

```
emby.login        emby.listItems      emby.itemDetail
source.login      source.listDir      source.resolvePlay
player.play       player.seek         player.setTrack
plugin.install    plugin.grant        plugin.uiRespond
```

> 这不是洁癖。三端各写一遍绑定时,`views` 这种名字会被三个人理解成三件事。

#### 平台差异

现有 29 条命令桌面有、安卓没有(文件选择器、mpv.conf、翻译 / Whisper、预加载设置、播放窗控制)。

**新契约的规则:命令表全平台一致**,平台不支持的返回 `E_UNSUPPORTED`。
UI 启动时调一次 `system.capabilities` 拿到本平台支持集,据此隐藏入口。

> 理由:两份不同的命令表意味着两份不同的契约测试,而漏的那份就是"安卓上点了没反应"。

#### `system.capabilities` 的返回

```jsonc
{
  "platform": "windows | linux | android | android_tv | macos | ios",
  "version":  "1.4.2",
  "dataRoot": "D:/LinPlayer/userdata",
  "serve":    { "port": 51873, "token": "…" },   // 数据通道(§6)
  "unsupported": ["translate.subtitle", "system.pickFile", "…"],
  "features": {
    "filePicker":     false,   // 有没有系统文件选择器
    "externalPlayer": false,   // 能不能交给外部播放器
    "mpvConf":        false,   // 有没有用户可编辑的 mpv.conf
    "plugins":        true,    // 装不装插件(TV 为 false)
    "backgroundPlay": true,    // 支不支持后台播放
    "pip":            true
  }
}
```

- `unsupported` 是**命令名列表**,UI 据此禁用入口 —— 比一个个试更省事,也不会漏。
- `features` 是**语义开关**,给"这个平台压根没有这个概念"的场合用
  (TV 没有文件选择器这件事,不能只靠"某条命令不支持"来表达)。
- 两者必须自洽:`features.filePicker == false` ⟺ `system.pickFile ∈ unsupported`。
  **有一条契约测试钉住这个自洽性**,否则两处会各说各话。

### 5.7 长任务与流式结果

**一条命令可以在最终 `result` 之前先发若干条 `partial`。**

```jsonc
{"t":"partial","seq":42,"data":{"server":"A","items":[...]}}
{"t":"partial","seq":42,"data":{"server":"B","items":[...]}}
{"t":"result", "seq":42,"ok":true,"data":{"servers":2,"failed":["C"]}}
```

规则:

- `partial` 与 `result` 的 `seq` 相同。收到 `result` 后**不会**再有该 seq 的 `partial`。
- UI 收到 `partial` 就可以先渲染。**不许**攒齐了再画。
- `result` 携带的是汇总(成功几个、失败哪些),不是数据的重复。

必须用流式的命令:

| 命令 | 为什么 |
|---|---|
| `emby.aggregateSearch` / `aggregateOverview` | 跨 N 台服务器,最慢的那台不该拖住最快的那台 |
| `source.listDir`(慢协议:SMB / FTP) | 大目录要边列边出 |
| `plugin.installAll` / 市场刷新 | 逐个反馈进度 |
| `account.probeAccounts` | 逐台出连通状态 |

> **这条影响被冻结的契约,所以必须现在定。** 现有实现是"`Promise.all` 屏障 + 串行 await",
> 实测比并发慢 5.5 倍,而用户描述成"不秒加载"。当时的正解是"骨架先出 + 各块各自渲染",
> 流式结果就是把这个正解写进契约,而不是指望三个端各自想到。

### 5.8 载荷约定

#### 上限

| 项 | 上限 | 超了怎么办 |
|---|---|---|
| 单条事件 JSON | 4 MB | 核心层拆成多条 `partial` |
| 单页条目数 | 200 | 核心层强制截断并在响应里标 `truncated: true` |
| 图片 / 二进制 | **不走 FFI** | 一律走数据通道(§6) |

一个 5000 条的媒体库塞进一个 JSON 是可以做到的,但它会在最差的机器上卡住 UI 线程。
**分页是契约的一部分,不是优化。**

#### 分页

- 请求带 `offset` + `limit`;响应带 `total`(服务端给不出就 `null`,UI 显示"加载更多"而非进度)。
- **分页大小由核心层决定,不由 UI 传。** 有的上游每页返回的条数与请求的不一致
  (实测某接口每页 46~51,不是文档说的 100)。写死在 UI 里 = 永远只看得到第一页,还不报错。
- 核心层必须**从响应学**实际页大小,据此算下一页的 offset。

#### 缓存失效

UI 会缓存列表。核心层通过事件告诉它什么时候该丢:

```jsonc
{"t":"event","name":"data.invalidate","data":{"scope":"library","id":"…"}}
```

| scope | 什么时候发 | UI 该做什么 |
|---|---|---|
| `library` | 看完一集、标记已看 / 未看、收藏变化 | 该库的网格重取(未看数角标 -1 就靠它) |
| `item` | 单条目详情变化 | 该条目的详情页重取 |
| `accounts` | 账号 / 线路增删改 | 服务器列表重取 |
| `plugins` | 插件装 / 卸 / 启停 | 插件页重取 |
| `all` | 导入配置、切换用户 | 全丢 |

> 不定义这个的后果是三端各写各的失效时机,而"看完一集角标不减"这类 bug
> 会在其中一到两端存在很久 —— 它不报错,只是数字不对。

### 5.9 各宿主绑定

| 宿主 | 绑定方式 | 产物 |
|---|---|---|
| Android | `go build -buildmode=c-shared` + 手写 JNI 薄层 | `liblpcore.so` × 4 ABI |
| Windows | `-buildmode=c-shared` + C# `[LibraryImport]` | `lpcore.dll` |
| Linux | 同上 | `liblpcore.so` |
| macOS / iOS | `-buildmode=c-archive` + Swift bridging header | `lpcore.a` → xcframework |

**每端的绑定层必须是生成的,不是手写的。** 从 `COMMANDS.md` 生成三份类型化包装
(Kotlin data class / C# record / Swift Codable)。手写 = 266 × 3 = 798 次抄写机会,
其中会错的那几次全是运行时才发现。

---

### 5.10 【一次做对】panic 边界

**Go 的 panic 跨不过 cgo 边界。** 一个没被 recover 的 panic 不是抛给宿主的异常 ——
它直接终止整个进程。C# 的 `try/catch`、Kotlin 的 `runCatching`、Swift 的 `do/catch`
**一个都拦不住**,用户看到的是「程序突然没了」,而且没有任何一端的日志里有线索。

Rust 版靠 `Result<T,E>` 把这类错误逼到类型系统里,Go 没有这个保护。
**所以 panic 边界必须是显式契约,不是编码习惯。**

| 位置 | 要求 |
|---|---|
| `ffi` 的每个导出函数体 | 顶层 `defer recover()`。参数解析本身就可能 panic(空指针、非法 UTF-8) |
| 每条 `lp_call` 起的 goroutine | 顶层 `defer recover()` → 转成 `{"ok":false,"err":{"code":"E_INTERNAL"}}` 正常回给该 `seq` |
| mpv 事件线程的回调 | 同上。这条线程死了 = 播放状态永远不再更新,而画面还在动,最难查 |
| `localserve` 的每个 handler | `net/http` 自带 per-connection recover,**但它只保护连接不保护你的清理逻辑** —— 仍要自己 recover 并回 500 |
| 插件宿主 goroutine | 同上。一个坏插件不许带走宿主 |
| 下载 / 预取 / 同步的后台 goroutine | 同上,recover 后写日志并让该任务转 `failed`,不重启整条流水线 |

**唯一允许崩的地方:`lp_init` 之前的包级初始化。** 那时候还没有可以回报错误的通道,
崩了至少是个能被崩溃转储抓到的现场。

recover 之后必须做三件事,少一件这条契约就白写:

1. **把栈写进日志**(`runtime/debug.Stack()`),否则 recover 等于把 bug 藏起来
2. **回一个 `E_INTERNAL` 给等待的 `seq`** —— 否则调用方永远等不到 `result`,UI 上表现为
   「点了没反应」,比崩溃更难查
3. **计数并通过 `log` 事件透出**,让诊断包能看到「这个版本 panic 了多少次」

> **测试要求(必须先红):** 注册一条只在测试构建里存在的 `debug.panic` 命令,
> 断言 ① 宿主进程存活 ② 该 `seq` 收到 `E_INTERNAL` ③ 日志里有栈。
> 先把 recover 注释掉确认这条测试会红 —— 否则它测的是「没 panic」。

### 5.11 【一次做对】事件队列与背压

事件队列是**核心层与 UI 之间唯一的下行通路**,它的容量策略决定了两类故障:
无界 → UI 事件线程一卡就 OOM;无脑丢 → 命令结果丢了,调用方永远挂着。

**所以不能一刀切,必须分级。**

| 事件类 | 满了怎么办 | 理由 |
|---|---|---|
| `result` / `partial` | **永不丢**。队列满则阻塞产生方 | 丢一条 = 某个 `seq` 永远没有回音 = UI 上一个转不完的圈。产生方是 goroutine,阻塞是安全的 |
| 高频状态事件(`player.status`、`prefetch.stats`、`download.progress`) | **合并**:队列里已有同 `name`(+同 id)的未消费事件就**原地替换**,不追加 | 这类事件只有最新值有意义。UI 卡 2 秒之后收到 8 条陈旧的播放位置,还不如收到 1 条最新的 |
| `log` | **可丢**。丢弃计数累加,在下一条 `log` 里带 `dropped:N` | 日志重要但不值得为它阻塞播放。**丢了必须说**,静默丢弃会让人误判"这段时间没事发生" |
| 其余(`config.changed`、`data.invalidate`、`plugin.ui`…) | 同 `result`,不丢 | 丢 `data.invalidate` = 界面显示过期数据且永不自愈 |

其余硬性规定:

- **队列容量 1024 条。** 这个数不是拍的:4 Hz 的 `player.status` + 1 Hz 的
  `prefetch.stats` + 日志,正常态稳态占用是个位数;1024 意味着 UI 得卡住几十秒才碰得到底。
- **有且仅有一个消费者线程调 `lp_next_event`。** 两个线程同时调是未定义行为
  —— 不是竞态崩溃,是事件被**随机分给两个线程**,表现为「有时候收得到有时候收不到」。
  这条要写进三端的绑定层注释,并由绑定生成器把 `lp_next_event` 封成私有。
- **消费停滞检测:** 队列非空且 5 秒没有被取过,核心层写一条 warn 日志并在
  `system.exportDiagnostics` 里标记。这是「UI 事件线程被谁堵住了」的唯一线索。
- **`lp_shutdown` 时队列发 EOF**(一个 `{"t":"eof"}`),消费者据此退出循环。
  不发 EOF 的话消费者会永远阻塞在 `lp_next_event(-1)` 上,进程退不干净 ——
  本项目在 Rust 版栽过同款(播放窗藏起来不销毁,窗口系统永远等不到"最后一个窗口关闭")。

## 6. 数据通道:本地 HTTP

核心层启动时在 `127.0.0.1` 绑一个**随机端口**,通过 `lp_init` 后的首个事件告知宿主。

| 路由 | 用途 | 消费者 |
|---|---|---|
| `/img?src=<url>&w=<px>` | 图片代理 + 磁盘缓存 + 尺寸参数 | 三端图片加载器 |
| `/icon/<id>` | 服务器图标 / 本地图标库 | 同上 |
| `/plugin/<id>/*` | 插件静态资源(逃生舱 WebView 的内容) | 各端 WebView |
| `/sub/<id>.ass` | 生成的弹幕 ASS / 外挂字幕 | libmpv 直接吃 |
| `/stream/*` | 预取代理 | libmpv 直接吃 |
| `/companion/*` | 电视端手机控制台 | 局域网浏览器 |

### 安全约束

- 只绑 `127.0.0.1`;**唯独** `/companion/*` 绑 `0.0.0.0`(仅电视端启用,且开关默认关)。
- 除 `/companion/*` 外,所有路由都要鉴权,**但鉴权方式分两种**(见下)。
- `/img` 的 `src` 必须命中白名单(已登录服务器 + 已授权插件源),否则 404。
  没有这一条,它就是一个开放的 SSRF 代理。

### 【坑】给 mpv 吃的路由,token 必须在 URL 里,不能在请求头

| 消费者 | 路由 | 鉴权方式 |
|---|---|---|
| 三端图片加载器、WebView | `/img` `/icon` `/plugin/*` | 请求头 `X-LP-Token` |
| **libmpv** | `/stream/*` `/sub/*` | **URL 路径段**:`/stream/<token>/...` |

理由:给 mpv 加请求头只能改 `http-header-fields`,而那是一个**全局粘连属性** ——
现有教训是它把网盘的 Cookie 发给了 Emby。为了本地代理去动全局请求头,
等于用一个必现的跨源污染换一个本可以放进 URL 的 token。

URL 里的 token 会进 mpv 日志。因此:token **每次启动重新随机生成**,不落盘,
且日志打印 URL 时对 token 段做掩码。

---

## 7. 视频通道

### 7.1 【决策】mpv 归核心层管

UI 层**不直接调用 libmpv**。UI 只做两件事:

1. 提供一个 surface 句柄(§7.2)
2. 发 `player.*` 命令、收 `player.status` 事件

**理由:** 播放器控制是本项目积累最深、坑最多的一块 —— 外挂字幕必须等 `FILE_LOADED`
且只能在事件线程挂载;`keep-open` 下 `END_FILE` 永远不发,判播完必须读 `eof-reached`;
ASS 字幕的字号要用 `sub-scale` 而不是 `sub-font-size`;seek 闩不能拿粘性值和目标比;
双显卡要靠导出符号钉独显;302 跳转流要删 `multiple_requests=1`……
这些知识写一遍就够了。放到 UI 层 = 写三遍 = 错三遍。

### 7.2 【一次做对】surface 交接

```
UI 层                                 核心层
  │                                     │
  │ 创建 surface(见下表)                 │
  │── lp_set_surface(kind,handle,w,h) ──►│ 绑定到 mpv
  │                                     │
  │ surface 尺寸变了                      │
  │── lp_set_surface(kind,handle,w',h')─►│ 重设尺寸
  │                                     │
  │ surface 即将销毁                      │
  │── lp_set_surface(0,0,0,0) ──────────►│ 解绑(**必须在销毁前**,阻塞返回)
  │◄─ 返回后才可以销毁 ───────────────────│
```

| 平台 | kind | 句柄来源 | mpv 侧 |
|---|:---:|---|---|
| Android | 1 | `SurfaceView.holder.surface` → `ANativeWindow_fromSurface` | `--wid` = ANativeWindow |
| Windows | 2 | Avalonia `NativeControlHost` 的子 HWND(v1)/ 共享纹理(v2) | `--wid` / render API |
| Linux (X11) | 3 | 同上,XID | 同上 |
| Linux (Wayland) | 5 | `wl_surface`(**待定,见 §15.2**) | render API |
| Apple | 4 | `CAMetalLayer` | render API |

**解绑必须是同步阻塞的。** Android 的 `surfaceDestroyed` 回调返回后 Surface 立即失效,
mpv 还在往里画就是 use-after-free。这是安卓端最容易漏的一条。

### 7.3 【P0 风险】Windows / Linux 的合成方案

这是**整个计划里唯一可能推翻选型的技术风险**,必须先打通再谈别的。

问题:Windows / Linux 上要让 **libmpv 的画面成为 UI 场景里的一层**,
且 OSD / 弹幕 / 进度条画在它上面。Android(SurfaceView)和 Apple(CAMetalLayer)
天生就行,Windows / Linux 不行。

三条候选路径,`TODO.md` 的 SPIKE-1 要求**实测三条并给出数据**:

| 路径 | 做法 | 预期问题 | 判据 |
|---|---|---|---|
| **A. 子窗口 `--wid`** | mpv 画进 Avalonia `NativeControlHost` 的子 HWND | 原生子窗口永远画在 Avalonia 内容之上(airspace),**OSD 盖不上去** | 除非接受 OSD 由 mpv 自己画,否则 A 不可用 |
| **B. render API + 纹理互操作** | mpv render API(OpenGL / ANGLE)→ 纹理 → Avalonia 合成面导入 | ANGLE 与 D3D11 共享句柄的同步(keyed mutex);Linux 走原生 GL 更简单 | 1080p60 / 4K60 各测 10 分钟,掉帧率 < 1%,CPU 占用与现状同量级 |
| **C. render API 软件回读** | `MPV_RENDER_API_TYPE_SW` 回读到 CPU,交 Avalonia 位图 | 每帧全画面 CPU 拷贝,4K60 ≈ 1.5 GB/s 内存带宽 | 只在 A / B 都失败时作为 1080p 兜底 |

**默认赌 B。** A 只作为"先跑起来"的临时脚手架,且必须在代码里标注天花板与升级路径。

#### 【已实测】图形字幕(PGS/SUP)不构成对 B 的否决 ✅

曾有一条来自真实经历的反对意见:**「Flutter 时代就是因为用纹理,libmpv 一直显示不了
PGS/SUP 图形字幕」**。这条如果成立,B 直接出局 —— 图形字幕是蓝光原盘 / WEB-DL 的常态。

**2026-08-30 实测,结论:归因不成立,B 未被排除。**
完整报告见 [`spikes/SPIKE-1a-PGS-render-api.md`](spikes/SPIKE-1a-PGS-render-api.md)。

| 用例(全部渲进**自建纹理 FBO**) | hwdec-current | 噪声基线 | 字幕信号 |
|---|---|---:|---:|
| 真 H.264 + 软解 | `no` | **0** | 25827 px |
| 真 H.264 + `hwdec=auto` | `d3d11va-copy` | **0** | 25827 px |
| 真 H.264 + 显式 `d3d11va` | `no` | **0** | 25827 px |

语料是真实 `.sup`(1359 条,1920×1080 画布);差异区域聚成 677×68 一块、位于画面底部;
截图肉眼可辨认中英双行字幕。mpv 报的字幕起止与自写 PGS 解析器算出的**逐位对上**。

> 当年 Flutter 那份实现建的是 **GLES 2.0** 上下文(`EGL_CONTEXT_CLIENT_VERSION, 2`),
> 而 mpv 的 GPU 渲染器面向 GLES 3.0+ 设计。这是**未证实的最可能原因**,不当结论用。

#### 【新增风险】B 在桌面 GL 上拿不到 d3d11va 零拷贝 🔴

同一轮实测顺带发现:显式要 `hwdec=d3d11va`(零拷贝)时 **起不来,回落软解**;
`auto` 最好只到 **`d3d11va-copy`** —— 每帧一次显存→内存→显存的拷贝。

原因是我们的 GL 上下文是 WGL 桌面 OpenGL,和 mpv 想用的 D3D11 设备不共享。
**要拿回零拷贝,GL 上下文必须换成 ANGLE(EGL over D3D11)** —— 也就是上表 B 那行
"ANGLE 与 D3D11 共享句柄的同步(keyed mutex)"背后的真实工作量。

**这条改变了 B 的成本估计,SPIKE-1 必须把它列为实测项**(见 `TODO.md` S1.2b)。

> 如果 B 在 Windows 上被证伪,备选是把 Windows 的 UI 换成 **WinUI 3 + `SwapChainPanel`**
> (它天生就是给外部渲染器准备的挂载点),代价是 Linux 需要另找 GTK4 / Qt。
> 这个备选**不影响核心层一行代码** —— 这正是三通道分层的价值。

### 7.4 播放器行为规格

以下是**规格**,不是实现细节,三端 UI 可以依赖:

- `player.play` 是异步的,返回只代表"已受理"。真正可播的信号是 `player.status` 里 `duration > 0`。
- **`duration == 0` 时进度条必须禁用。** 量程塌成 1 秒时点中间会跳到 0.5 秒,表现为"画面不动"。
- `player.seek` 在 `FILE_LOADED` 之前会被核心层排队,不会丢。
- 缓冲进度与播放进度是两条独立的值。UI **不许**把缓冲条从 0 画起(会压在播放头上,
  用户会描述成"进度跟着缓存走")。
- 换片时 `status.ready` 必须在**发出 play 命令之前**复位,不能在之后 ——
  上一片的轮询会在两次 await 之间把旧值拍回来,表现为"第二个视频先露出上一片的画面"。
- 拖动进度条:`onPointerUp` 必须挂在**窗口**上,不能挂在滑块自己身上(拖出边界会钉死)。

### 7.5 【决策】弹幕渲染走 `osd-overlay`,不走字幕轨

> **本节 v0.1 写错了,v0.2 已重写。** 详细论证与实测见
> [`knowledge/DANMAKU_CARRIER.md`](knowledge/DANMAKU_CARRIER.md)。

#### 事实(先纠正 v0.1 的错误前提)

v0.1 写的是"现有实现有两条渲染路径,主路是 ASS 交 `secondary-sid`,新架构删掉网页层 fallback"。
**这个前提是错的。**

- ASS 那条路**已于 2026-07-27 整条删除**(commit `108965f6`,`danmaku/ass.rs` 360 行连同 mod 入口一起拔掉)
- 删除理由是用户拍板:**次字幕位只有一个,弹幕占了就开不了双语字幕**。用户原话「删掉就行了 那个没必要留」
- **现在唯一的渲染路径是前端 Canvas**(`ui/shared/Danmaku.tsx`)
- `crates/core/src/danmaku/local.rs` 里剩下的 `parse_ass` / `parse_ass_time` 是**解析器**
  —— 读 `.ass` 文件当弹幕导入源,不是渲染用的生成器
- `crates/mpv/src/lib.rs` 里的 `secondary-sid` 现在服务于**外挂字幕 / 双语字幕**,
  正是当初被弹幕挤掉的那个功能

所以 v0.1 的"删掉 fallback"实际含义是**把用户否决过的方案重建回来**,而且没有回应当初否决它的理由。

#### 新架构的真问题

Canvas 路径依赖 WebView,而三端原生 UI 下没有 WebView 覆盖在视频上(逃生舱除外)。
**弹幕渲染必须重建。** 三个选项:

| 方案 | 占字幕轨? | 双语字幕 | 结论 |
|---|:--:|:--:|---|
| `sub-add` + `secondary-sid` | ✅ 占 | ❌ 冲突 | **否**。这正是 2026-07-27 被否决的方案 |
| **`osd-overlay` + `format=ass-events`** | ❌ 不占 | ✅ 保住 | **选它** |
| 三端各写一个 Canvas 等价物 | — | ✅ | 否。三份新代码,且是三份新 bug |

`osd-overlay` 是 mpv 的 OSD 层接口,吃 ASS event 文本但**不走字幕轨** ——
双语字幕保住,弹幕也有 libass 的排版能力。社区方案(uosc_danmaku)用的就是这条路。

#### 代价必须说清

mpv 手册对 `osd-overlay` 明确写着 **`Timing is unused`** —— **mpv 不管时间轴**。
滚动位置要宿主每拍自己算并重发。

也就是说 v0.1 里"交给 libass 就零 IPC"这个收益论述**只对 `sub-add` 成立,对 `osd-overlay` 不成立**。

净收益仍然存在,但换了内容:

- 弹幕布局计算从三份(三端各一份)收敛成一份,放在核心层
- 核心层进程内直读 `time-pos`,不再像现在的 Canvas 那样靠 IPC 轮询 + 墙钟外推
  (现在的实现必须自己乘倍速因子来补外推误差,否则 2x 播放时弹幕按 1x 爬)

#### 未验证的风险

**`osd-overlay` 的刷新率够不够支撑平滑滚动,没有实测。** 这是整个方案唯一的观感风险点。
`TODO.md` 立了 SPIKE-5,**先测再定**。

#### 载体格式(XML)另说

"弹幕用 XML" 是**存储 / 交换**格式的问题,与渲染无关 —— 见 §7.5.1。

### 7.5.1 弹幕载体:XML

**结论:XML 只作导入 / 导出 / 本地文件,不升格为内部唯一表示。**

- mpv 与 ffmpeg **都不能直接播弹幕 XML**(实测 `ffprobe` 报 `Invalid data found`;
  `ffmpeg -decoders` 里连 TTML 这个唯一的 XML 系字幕标准都没有 decoder)。
  所以"用 XML 播放"技术上不成立,成立的是"用 XML 存,播放时转 ASS event"
- **"支持 XML"已经做了一半**:`crates/core/src/danmaku/local.rs:123 parse_xml` 已能读 B 站弹幕 XML,
  `local.rs:16` 也已把 `xml` 列在支持格式首位
- **不升格为内部表示**的理由:弹弹Play 只给 4 个字段,写进 9 字段的 XML 要编造 5 个值,
  而这些 XML 会被导出给外部工具当真数据读 —— 编出来的字段会被当真
- 体积不是理由:实测 5000 条弹幕,XML 414 KB / 弹弹Play JSON 395 KB /
  **我们现在往磁盘写的缓存 JSON 761 KB**。XML 比现状小 45%

Go 侧用 `encoding/xml` 标准库,零新依赖,但有两条硬要求:

1. **必须显式 `Strict = false`** —— 野生弹幕文件常有未转义的裸 `&`,严格模式会整份解析失败
2. **必须挂 `CharsetReader`** —— 顺带修一个现存的真 bug:Rust 版收 `&str`,GBK 编码的弹幕文件现在就是坏的

### 7.6 播放来源的统一

不管片子从哪来,UI 只调 `player.play(itemRef)`。**解析归核心层。**

| 来源 | 核心层怎么解析 | 进度上报去哪 |
|---|---|---|
| Emby 直传 / 转码 | `emby.getPlaybackInfo` → 直链或转码 URL | 原服务器(带 `PlaySessionId`) |
| Emby + 预取代理 | 同上,再包一层 `/stream/*` | 同上 |
| 网盘 / 局域网源 | `source.resolvePlay` → 直链 + 逐流 headers | 该源(有服务端记录的才发) |
| SMB | 本地 Range 桥 | 无 |
| 本地文件 | 裸路径 | 本地观看记录 |
| **已下载的条目** | 本地路径 | **原服务器 + 本地记录两处** |

最后一行是唯一需要额外说明的:下载下来的片子播的是本地文件,
但**进度必须回传给它原本所属的那台服务器** —— 否则在别的设备上续播会丢。
`itemRef` 因此必须同时携带"本地路径"和"来源标识",不能只留一个。

> 这一条现在没有对应的实现,是这次迁移要补上的功能缺口,不是移植。
> 单独在 `TODO.md` 立了一条(C46 的子项)。

### 7.7 可以顺手删掉的命令

新架构下这些命令失去了存在理由,移植时**直接不做**:

| 命令 | 为什么不需要了 |
|---|---|
| `player_take_pending` | 主窗与播放窗现在是同一个 .NET / JVM 进程里的两个窗口,直接共享对象。原先走核层是因为两个 WebView2 窗口之间只有 localStorage 这种隐式耦合 |
| `player_window_open` / `player_window_close` | 窗口生命周期归 UI 层 |
| 视频窗几何 / z 序相关的一切 | 见 §8.3 |

**但 `COMMANDS.md` 里仍要保留这几行并标注"已废弃 + 原因"** ——
否则三个月后有人看到 UI 里没这个功能,会以为是漏了。

---

## 8. 各端 UI 规格

### 8.0 启动时序

三端必须按同一个顺序启动,否则会各自长出不同的竞态。

```
1. UI 进程起来,画一个不依赖任何数据的骨架(不是转圈,是页面轮廓)
2. lp_init(config_json)              ← 传数据根、平台名、版本号
3. 起事件线程,开始 lp_next_event 循环
4. system.capabilities               ← 拿端口 / token / 支持集,据此隐藏入口
5. emby.currentSession + source.currentSource   ← 判断是否已登录
      │
      ├─ 都空 → 首登闸口(它是「添加服务器」页的另一种版式,共用同一份表单)
      └─ 有一个 → 首页
6. 首页各区块**各自并发拉取,各自渲染**,不设屏障
```

两条硬约束:

- **第 5 步必须同时看 `currentSession` 和 `currentSource`。**
  只判 Emby 会话的话,纯网盘用户永远进不了门 —— 这是有过的真实故障。
- **第 6 步不许有 `Promise.all` 式的屏障。** 骨架先出、各块各自渲染是契约,不是优化。
  实测串行 await 比并发慢 5.5 倍,而用户会把它描述成"不秒加载"、归咎于动画。

### 8.1 共同的 UI 契约

三端页面集合(不是像素级一致,是**功能集合**一致):

| 页面 | 桌面 | 手机 | TV | 备注 |
|---|:---:|:---:|:---:|---|
| 首登闸口 / 添加服务器 | ✅ | ✅ | ✅ | 与"添加服务器"页共用同一份表单定义 |
| 首页 | ✅ | ✅ | ✅ | |
| 媒体库(网格 + 筛选) | ✅ | ✅ | ✅ | |
| 详情(剧 / 影 / 季 / 集 四种版式) | ✅ | ✅ | ✅ | |
| 播放页 | 独立窗口 | ✅ | ✅ | |
| 搜索(全局 / 库内 / 包括集) | ✅ | ✅ | ✅ | |
| 聚合视界(跨服) | ✅ | ✅ | ✅ | |
| 收藏 | ✅ | ✅ | ✅ | |
| 服务器管理 / 线路 | ✅ | ✅ | ✅ | |
| 文件浏览(网盘 / SMB / WebDAV / FTP / 本地) | ✅ | ✅ | ✅ | |
| 影视目录(VOD 资源站) | ✅ | ✅ | ✅ | 与文件浏览是**两套页面**,不复用 |
| 下载 | ✅ | ✅ | ✅ | |
| 插件市场 / 已装 / 设置 | ✅ | ✅ | ❌ | TV 不做插件 |
| 排行榜 | ✅ | ✅ | ✅ | |
| 追剧日历 | ✅ | ✅ | ❌ | |
| Ani-RSS 管理 | ✅ | ✅ | ❌ | |
| 设置 | ✅ | ✅ | ✅ | 桌面 4 组 14 项(见 `UI_PC.md` §7.15) |
| 人物详情 | ✅ | ✅ | ❌ | |
| 图标库 | ✅ | ✅ | ❌ | |

**表单定义下沉核心层。** 现在 PC 的 `sourceForms.tsx` 是"新增一个源只改一处"的关键。
新架构把源表单的**字段定义**下沉到核心层(`source.formSchema` 返回声明式描述),
三端各写一个渲染器。新增源类型 = 核心层改一处,三端零改动。

### 8.2 Android(手机 + TV)

- **单 APK 双形态**。现在靠 UA 分流;新架构靠
  `UiModeManager.currentModeType == UI_MODE_TYPE_TELEVISION`。
- 手机形态:Material 3 + Compose,底栏三个 Tab(首页 / 聚合视界 / 服务器)。
- TV 形态:`androidx.tv.material3` + Compose 焦点系统。
  - **不再自己写空间导航。** `Modifier.focusRestorer` / `focusProperties` / `TvLazyRow` 处理。
  - "输入即焦点框"的既有约定保留。
- 视频:`SurfaceView`(不是 `TextureView` —— SurfaceView 走独立合成层,零 overdraw)。
  Compose 内容画在其上,**天然无缝**。
- 开屏:`androidx.core.splashscreen`,图标边距留在 drawable 内部(否则 Android 12 会放大满幅)。
- 资源限定符:按 API 分主题时必须同时建 `values-vXX` 与 `values-night-vXX`
  —— `-night` 压过 `-vXX`,只建一份的表现是"浅色修好了深色没修"。

### 8.3 Windows / Linux

> **完整的 PC 端 UI 规格在 [`UI_PC.md`](UI_PC.md)** —— 设计系统(色 / 字 / 间距 / 图标)、
> 动效 token 与三条禁令、布局与窗口行为、组件状态矩阵、快捷键全表、反馈层、
> 19 页逐页规格、播放页 OSD、无障碍、性能预算、验收清单。
> 本节只留跨端契约里必须提到的那几条。

- Avalonia 11,单一 `MainWindow` + 独立播放窗口。
  播放页保持独立窗口(用户明确要求"单开的播放页要有标题栏,不然拖不动")。
  两个窗口各自持有自己的 surface,核心层同时只绑一个。
- 自绘标题栏由 `ExtendClientAreaToDecorationsHint` 处理。
  **现有"给视频窗让出 36px"的整套逻辑删除** —— 视频在窗口内合成,不存在让位问题。
- Linux 的显示服务器(X11 / Wayland)**是一个被新架构重新打开的问题,不是既定结论** ——
  强制 X11 的两条理由都随架构失效了。**决策规则与待验证清单见 §15.2**,
  SPIKE-1 必须在 Linux 上同时跑两条。
- 绿色包:.NET 8 self-contained,数据仍全在 exe 同级 `userdata/`。

### 8.4 Apple(后置)

- SwiftUI + `CAMetalLayer` + mpv render API。
- macOS 优先,iOS 后置(分发问题见 §11.4)。
- 与其它两端共用同一份 `lpcore.a`。

### 8.5 【必读】平台职责分工

"什么归核心层、什么归 UI 层"是三端最容易各做各的地方。这张表是分工的唯一依据。

#### 归 UI 层(核心层不碰,也碰不到)

| 事项 | Android | Windows / Linux | Apple |
|---|---|---|---|
| 系统媒体控制 / 通知栏 | `MediaSession` + 前台服务 | 🔴 Win: SMTC / **Linux: MPRIS**(两端都未实现,§15.5) | `MPNowPlayingInfoCenter` |
| 后台播放存活 | 前台服务 + `WAKE_LOCK` | 无需 | 后台音频能力 |
| 音频焦点(来电 / 别的 App 抢) | `AudioFocusRequest` | 无需 | `AVAudioSession` |
| 屏幕常亮 | `FLAG_KEEP_SCREEN_ON` | 🟠 Win: 系统 API / Linux: D-Bus 抑制。**别依赖 mpv 的 `stop-screensaver`**(§15.5) | `isIdleTimerDisabled` |
| 画中画 | `PictureInPictureParams` | 迷你窗(自己做) | PiP |
| 深链注册(`linplayer://`) | intent-filter | 注册表 / .desktop | URL scheme |
| 系统文件选择器 | SAF | 原生对话框 | `NSOpenPanel` |
| 运行时权限请求 | 存储 / 通知 / 网络 | 无 | 相册等 |
| 跟随系统深浅色 | `isSystemInDarkTheme` | Avalonia 主题 | `colorScheme` |
| 遥控器 / 键盘 / 手势输入 | 各端各自 | | |
| 窗口生命周期、多窗口 | — | Avalonia | AppKit |

> **核心层收到的只有结果。** 例如深链:UI 层负责被系统唤起并拿到 URL,
> 然后调 `account.parseDeepLink`。核心层不知道也不关心 URL 从哪来。

#### 归核心层(UI 层不许自己实现)

| 事项 | 说明 |
|---|---|
| 一切网络请求 | UI 层**零**出网。唯一例外是数据通道那几个本地 URL |
| 一切凭据与签名 | 包括扫码轮询、token 轮换、RSA/secp256k1 |
| 一切持久化 | 配置、历史、缓存、插件存储 |
| mpv 的全部控制 | 见 §7.1 |
| 版本 / 音轨 / 字幕的选择算法 | UI 只展示 `preferred` 标记,**不许自己回落 `versions[0]`** |
| 源能力探测 | UI 调 `source.capabilities` 决定走文件浏览页还是影视目录页 |
| 表单字段定义 | `source.formSchema`(§8.1) |
| 排序、筛选、去重 | 服务端能做的交服务端,做不了的核心层做,**不在 UI 层做** |

> 最后一条有真实教训:某台 fork 服务器在收藏页忽略 `SortBy`,当时是在 UI 层做的本地排序。
> 新架构里这类补偿一律下沉 —— 否则三端要各补一次,而漏的那端就是"排序在手机上不生效"。

#### 灰色地带的裁决

| 场景 | 归谁 | 理由 |
|---|---|---|
| Toast / 提示文案 | 核心层给 `code` + `msg`,UI 决定怎么显示 | 文案是产品的,位置是平台的 |
| 空态 / 骨架屏 | UI | 纯呈现 |
| 分页触发时机 | UI | 与滚动强相关 |
| 分页大小 | 核心层 | **必须从响应学**,不能写死(实测某接口每页 46~51,不是文档说的 100) |
| 重试策略 | 核心层 | UI 重试会把核心层的退避打乱 |
| 图片尺寸参数 | UI 传期望宽度,核心层决定实际取多大 | 有的服务端完全忽略 `maxWidth` |

---

## 9. 插件系统

### 9.1 兼容性承诺

**现有插件包不重新打包即可运行。** 插件 ABI 是 JS,与宿主语言无关。

| 组成 | 迁移影响 |
|---|---|
| 插件 JS 代码 | **零改动** |
| `manifest.json` 格式 | **零改动** |
| registry 索引格式 | **零改动**(snake_case 键、author 为字符串是硬契约) |
| `ctx.*` 宿主 API | 语义零改动,实现从 rquickjs 换成 quickjs-go |
| 声明式 UI 贡献点 | 语义零改动,三端各写一个渲染器 |
| 逃生舱 WebView | 需要各端提供一个 WebView(见下) |

### 9.2 引擎

`buke/quickjs-go`。每插件一个 Runtime + Context,内存上限 64 MB,空转看门狗 30 s。
与现有 `plugins/engine.rs` 的约束**逐条对齐**。

> 备选 `dop251/goja`(纯 Go,免 cgo)。**否掉**:插件大量使用 async/await 与 Promise,
> goja 的支持面与 QuickJS 有差异,而差异会表现为"某个插件在新版本上莫名其妙不工作"。
> 既然已经因为 libmpv 用了 cgo,再多一个 cgo 依赖不增加边际成本。

### 9.3 逃生舱

插件的自定义 UI 走**独立 origin** 的 WebView(不能是宿主 UI 的一部分,否则权限模型是摆设)。

| 平台 | 组件 |
|---|---|
| Android | `android.webkit.WebView` |
| Windows | WebView2(Avalonia 社区控件,或 `NativeControlHost` 直接挂) |
| Linux | WebKitGTK |
| Apple | `WKWebView` |

内容由数据通道 `/plugin/<id>/*` 提供。

---

## 10. 数据与存储

### 10.1 路径

**唯一出口 `core/paths`。** 任何包不许自己拼数据目录。

| 平台 | 数据根 |
|---|---|
| Windows(绿色包) | exe 同级 `userdata/` —— **但有三种落点,判据必须是探针,见 §16.1** |
| Linux | `$XDG_DATA_HOME/linplayer` |
| Android | `context.filesDir`(由 `lp_init` 传入) |
| Apple | `~/Library/Application Support/LinPlayer` |

Android / Apple 的数据根由宿主通过 `lp_init(config_json)` 传入 —— **核心层不猜**。

```
userdata/
├── config.json          # AppConfig
├── history.json         # 本地观看记录
├── logs/
├── cache/
│   ├── img/             # 图片缓存
│   └── prefetch/        # 预取环形缓存(占用恒 = 上限)
├── plugins/
│   ├── installed/
│   └── storage/         # 每插件的 KV
└── shaders/
```

### 10.2 配置迁移

Rust 版的 `config.json` 必须能被 Go 版**直接读**。
字段名与 serde 的输出保持一致(现有是 snake_case + 全字段 `default`)。

**测试要求:** 拿一份真实的旧 `config.json`(脱敏后)作为夹具,
断言 Go 版读进来再写出去,语义等价。**这条测试必须先红过**(故意改一个字段名看它失败)。

已知的跨语言陷阱:

- `SourceKind` 线上是**小写字符串**。三端不许写成首字母大写 —— 现有教训是每处比较恒 false、
  登录送错值,而**两边都不报错**。
- `active_line` 是下标,跟着 `lines` 数组走,不是 id。
- 密码字段存在,但**不得出现在任何日志、诊断包、上报里**。

### 10.3 日志与诊断

**一份日志,不是四份。**

- 核心层写 `userdata/logs/app.log`(按天滚动,保留 7 天)。
- UI 层**不自己开日志文件**,通过 `system.log(level, tag, msg)` 写进同一份
  —— 三端各写各的日志文件,出问题时对不上时间线。
- 核心层的日志同时以 `log` 事件推给 UI,供调试面板实时显示。
- mpv 的日志**默认关**,由环境变量门控。理由:`log-file` 会把 mpv 与 ffmpeg
  一起钉在 debug 级,发行版里这是白白的性能与磁盘开销。
- 诊断包导出(`system.exportDiagnostics`):日志 + 配置(**脱敏**)+ 版本 + 平台信息。
  **脱敏是核心层的责任**,不是让用户自己删。token / 密码 / Cookie / 服务器地址
  一律替换,替换后仍保持可读的结构。

### 10.4 编译期凭据

`secrets` 包,值由 `-ldflags "-X core/secrets.XXX=..."` 注入。
CI 必须传全 —— 漏传的表现是"功能静默残废而构建全绿"。
`TODO.md` 有一条专门给这个加门禁。

---

## 11. 构建与分发

### 11.1 核心库

```bash
# Windows
GOOS=windows GOARCH=amd64 CGO_ENABLED=1 \
  go build -buildmode=c-shared -ldflags "-s -w" -o lpcore.dll ./ffi

# Linux
GOOS=linux GOARCH=amd64 CGO_ENABLED=1 \
  go build -buildmode=c-shared -ldflags "-s -w" -o liblpcore.so ./ffi

# Android(4 ABI,需 NDK toolchain)
CC=$NDK/toolchains/llvm/prebuilt/*/bin/aarch64-linux-android24-clang \
CGO_ENABLED=1 GOOS=android GOARCH=arm64 \
  go build -buildmode=c-shared -o jniLibs/arm64-v8a/liblpcore.so ./ffi

# Apple
CGO_ENABLED=1 GOOS=darwin GOARCH=arm64 \
  go build -buildmode=c-archive -o lpcore.a ./ffi
```

### 11.2 libmpv

保持现状:Android 走 Git LFS 的 `libmpv.so`(CI 必须 `lfs: true`,并校验 ELF 魔数,
否则 APK 里是 LFS 指针文本,运行时 `UnsatisfiedLinkError`);
桌面走 `dlopen` + soname 分裂兜底(Linux 上 libmpv soname 不统一)。
**完整规格与三条 CI 断言见 §15.4** —— 那一节是这句话的展开,不要只读这一句就动手。

### 11.3 产物

| 平台 | 产物 | 备注 |
|---|---|---|
| Windows | 绿色 zip(self-contained .NET + lpcore.dll + libmpv) | 数据全在 `userdata/` |
| Linux | **绿色 zip**(不是 AppImage / tar.gz —— 理由见 §15.6) | **不含 libmpv**,依赖系统安装(§15.4) |
| Android | 单 APK(手机 + TV 双形态) | 必须签名 —— `keystore.properties` 写了 ≠ 用了 |
| macOS | .app / .dmg | |
| iOS | 见 §11.4 | |

版本号唯一权威放在一处,并加**单调性门禁** —— 仓库重组曾把它静默顶退,
表现为"老用户永远收不到更新"。

### 11.4 iOS 分发的现实

本 App 带第三方媒体服务器客户端、网盘、资源站聚合 —— App Store 审核通过的概率低。
可行渠道:TestFlight(有效期与审核)、企业签名、侧载、欧盟第三方商店。

**结论:iOS 是"技术上支持",不承诺分发。选型时不为 iOS 付溢价。**

---

## 12. 测试与验收

### 12.1 差分对账(主验收手段)

Rust 版是**黄金实现**。Go 版每个模块完成后,用同一份输入喂给两边,diff JSON 输出。

```
                ┌─► crates/core (Rust) ─┐
录制的请求 / 响应 ┤                        ├─► diff
                └─► core (Go) ──────────┘
```

- 录制层:在 Rust 版加 `LP_RECORD=<dir>` 模式,把每次 HTTP 请求 / 响应
  与命令入参 / 出参落盘。
- 回放层:Go 版跑同一份录制,断言输出一致。
- **这是防"看起来对了"的唯一手段。** 单元测试只能证明 Go 版自洽,
  证明不了它和 Rust 版一致。

### 12.2 契约测试

- 命令表一致性:`COMMANDS.md` ↔ Go 注册表 ↔ 三端生成的绑定,四方比对。任何一方缺一条即红。
- 跨语言枚举:`SourceKind` 等线上值的大小写。
- 配置往返:§10.2。

### 12.3 各端真机自检

代码编译绿 + 单测绿**照不到**的那一类 bug(布局、焦点、可见性、时序)必须真渲染才现形。

| 平台 | 手段 |
|---|---|
| Android | Compose UI Test,焦点断言用语义树 |
| Windows / Linux | Avalonia.Headless + 真实窗口截图对账 |
| Apple | XCUITest |
| 播放可见性 | 各端各自的"视频层确实在画"的探针(不能只看命令返回值) |

### 12.4 测试纪律

**新测试必须先红。** 反向注入一个真 bug,确认它变红,再修好。
假绿的五种形态:注入不忠实 / 环境不同 / 夹具不真实 / 语料选错 /
断言的时序让 bug 没机会发生(清理类断言最易测成空集)。

另:**长期红的门禁 = 没有门禁**,真信号会淹在噪音里。

---

## 13. 风险登记册

| # | 风险 | 影响 | 缓解 | 状态 |
|---|---|---|---|---|
| R1 | Windows / Linux 纹理互操作走不通 | 推翻 Avalonia 选型 | SPIKE-1 先做;备选 WinUI3 + SwapChainPanel | 🔴 未验证 |
| R2 | cgo + NDK 交叉编译链路复杂 | 拖慢一切 | SPIKE-2 先跑通并固化进 CI | 🔴 未验证 |
| R3 | quickjs-go 跑不了现有插件 | 插件生态断代 | SPIKE-3 拿现存全部插件当验收语料 | 🔴 未验证 |
| R4 | Compose TV 焦点不如预期 | TV 端要自己写空间导航 | SPIKE-4 用最复杂的页面(EpisodePage)验证 | 🔴 未验证 |
| R5 | Go 二进制体积 / 启动时间 | APK 变大、冷启动变慢 | 测量;`-ldflags "-s -w"`;可接受上限写死进门禁 | 🟡 待测 |
| R6 | 三端 UI 行为漂移 | 同一功能三种表现 | 功能集合表(§8.1)+ 逐端验收清单 | 🟡 持续 |
| R7 | 迁移期两套核心并存,修 bug 要修两遍 | 双倍工作量 | 冻结 Rust 版功能,只修 P0 | 🟡 待定 |
| R8 | 编译期凭据在 CI 漏传 | 功能静默残废而 CI 全绿 | 门禁脚本(现有 `check-workflows.sh` 有先例) | 🟢 有方案 |
| R9 | **Linux 只能跑 X11**(Wayland 走不通) | Wayland 会话下靠 XWayland,分数缩放可能糊;长期看是死路 | SPIKE-1 必须同时跑两条(§15.2);走不通则明确写进发行说明,不静默降级 | 🔴 未验证 |
| R10 | **Linux 双显卡跑核显** | 超分卡顿,而且**不报错** | 按 §15.3 做 PRIME 环境变量 + 回读 GPU 名字;`system.gpuInfo` 暴露给用户 | 🔴 未实现 |
| R11 | Linux 用户没装 libmpv | 起不来 | §15.4:不打包 + 首启检测 + 给各发行版的安装命令 | 🟡 有方案 |
| R12 | **Windows 未签名** | SmartScreen 常驻 + 杀软误报,而且更新后信誉从零开始 | §16.3 给了三个选项与代价,需负责人裁决;无论签不签,首次运行指引现在就要写 | 🔴 待裁决 |
| R14 | **路径 B 拿不到 d3d11va 零拷贝** | 4K HDR 下每帧多一次显存↔内存往返,CPU 与带宽开销上升 | 已实测(桌面 WGL 下确认);SPIKE-1 要测 ANGLE 能否拿回零拷贝,并量 `d3d11va-copy` 在 4K60 的实际代价 | 🔴 已确认存在 |
| R13 | **长路径 / 文件锁** | 下载静默失败;预取环形缓存删不掉分段 → "占用恒等于上限"这条承诺破掉 | §16.6:清单声明 + 落盘前校验 + 删除失败要计数不许静默跳过 | 🔴 未实现 |

---

## 14. 核心层横切规格

§4–§11 按模块划分,但有几件事**每个模块都会碰**。它们不写进契约的后果不是"某个功能不好用",
而是"每个模块各写一遍,其中几遍是错的"。

### 14.1 出网规格

**UI 层零出网**(§8.5),所以整个 App 的出网行为由核心层一处定义。

#### 三条 UA 道(照搬,不要合并)

| 用途 | UA | 压缩 |
|---|---|:--:|
| 访问 Emby(含 mpv 直连取流) | `LinPlayer/{版本}` | 开 |
| 多线程加载 / 预取代理拉上游 | `LinPlayerPreload/{版本}` | **关** |
| 第三方公开 API(Bangumi / Trakt / 弹弹Play / 翻译 / 排行) | `LinPlayer/{版本} (+<项目地址>)` | 开 |

- **分开的理由是服务端视角:** 预取代理是我们替 mpv 提前拉流的旁路请求,和用户真正在看的
  那一路在服主的日志与风控里必须分得开。糊成一个 UA,服主看到的是"一个客户端同时开了
  四五路并发",最容易被当成盗刷限速。
- **第三方那条不能"不设 UA"。** Go 的 `net/http` 至少会发 `Go-http-client/...`,
  比 Rust 的 reqwest(不设 = 一个 UA 头都不发)好一点,但一样会被 WAF 判成脚本流量。
  实测同一个 Access Token 打 Bangumi:带 UA → 200,不带 → **403(Cloudflare)**,
  而错误信息长得像"Token 无效",会把人带去查凭据。
- **UA 绝不能通过 mpv 的属性设置。** mpv 的 `http-header-fields` 是全局粘连属性,
  设一次影响后续所有流 —— 本项目栽过:网盘的 Cookie 被发给了 Emby。
  给 mpv 的 URL 一律由核心层构造(§6),头由核心层的代理层加。
- **契约测试按行为验,不按常量验。** 现有测试的做法值得照搬:发一个请求到本地测试服务器,
  断言收到的 `User-Agent` 头 —— 比对常量只能证明拼接没写错,证明不了那个 client
  真的用上了它。反向验证(把 preload client 换成普通 UA)必须让测试变红。

#### 超时:是**空闲超时**,不是整体超时

这条是本项目付过学费的一条,而且**第一版修法是错的**:

- 症状:上游变黑洞时请求永远吊着,且零日志。现状是主要的几个 client **一个超时都没设**。
- 错误的修法:给整体请求设 30s 超时。**慢链路上拉一个 4 MB 分段合法地要 29~62 秒** ——
  这样改会把正常播放判成失败。
- 正确的口径:

| 项 | 值 | 说明 |
|---|---|---|
| 连接超时 | 15 s | 建连本身不该慢 |
| **响应头超时** | 30 s | 发出请求到收到响应头。上游黑洞在这里被抓住 |
| **读空闲超时** | 30 s | **两次收到字节之间**的间隔。只要还在出字节就不判死 |
| 整体超时 | **不设**(流式路由) | 大文件流没有合理的整体上限 |
| 整体超时 | 60 s(非流式 API) | 元数据类请求 |

Go 侧落法:`http.Transport{ResponseHeaderTimeout, DialContext:{Timeout}}` 管前两项;
读空闲用一个包住 `resp.Body` 的 `idleTimeoutReader`,每次 `Read` 返回时重置定时器。

> **测试要求:** 这类护栏测试如果共用全局配置(比如覆盖超时值),**必须加锁串行** ——
> Go 的测试默认包内串行但 `t.Parallel()` 一开就不是了,而超时是全局状态。

#### 其余

| 项 | 规定 |
|---|---|
| 重定向 | **只跟随一次**。多跳会把预取代理的分段逻辑和 302 签名过期搅在一起 |
| 重试 | 归核心层。指数退避 + 抖动,`E_NETWORK` 才重试,`E_AUTH` / `E_UPSTREAM` 不重试。**UI 不许自己重试**,会打乱退避 |
| 取消 | 每条 `lp_call` 的 `context` 必须一路传到 `http.Request`。离页杀请求靠这个 |
| 压缩 | 显式设 `Accept-Encoding`。流式路由**不压缩**(压了就没法按 Range 切) |
| 代理 | 用户可配 + 跟随系统。**预取代理与 mpv 走的本地回环必须绕过代理**,否则自己打自己 |
| 连接池 | 按 host 复用。跨服聚合会同时打多台,**不设并发上限**(元数据请求本轻),但每台有连接数上限 |
| TLS | 默认校验。自签证书由用户逐台显式信任,**不提供全局关闭开关** |

### 14.2 存储与持久化

#### 写配置必须是原子的

现状是 `fs::write` 直接覆盖 —— 断电或崩溃发生在写一半时,`config.json` 会变成截断的半个
JSON 或 0 字节,**表现是"重开 App 账号全没了"**。

规定:所有 JSON 状态文件(`config.json` / `history.json` / 插件 KV)一律
**写临时文件 → `fsync` → `rename` 覆盖**。`rename` 在同一文件系统内是原子的。

再加一条兜底:启动时读到损坏的 `config.json`,**不要静默重置** ——
把坏文件改名成 `config.json.broken-<时间戳>` 保留,再用默认值起来,并通过事件告诉 UI。
静默重置和"账号全没了"在用户眼里是同一件事,但前者还销毁了取证材料。

#### 磁盘配额总账

现在只有预取缓存有上限。其余几处都能无限长:

| 目录 | 上限 | 淘汰策略 |
|---|---|---|
| `cache/prefetch/` | 用户可设(默认 32 MB,区间 16 MB ~ 4 GB) | 环形,占用恒 = 上限 |
| `cache/img/` | **默认 512 MB** | LRU,按访问时间 |
| `logs/` | 7 天 **且** 总量 ≤ 64 MB | 按天滚动,先按量再按天 |
| 下载目录 | 不限(用户的资产) | 不淘汰,但要在设置页显示占用 |
| `plugins/storage/` | 每插件 ≤ 16 MB | 超了让插件的写操作失败,**不静默丢** |

`system.storageUsage` 返回逐项占用,设置页据此显示。**没有这条,"清理缓存"这个按钮
就只能是个安慰剂。**

#### 并发

- 每个状态文件一把写锁,读写都走 `core/config` 一处,**不许别的包自己开文件**。
- 高频写(播放进度)**不落每一拍**:内存记账 + 5 秒或状态跃迁时落盘,`lp_shutdown` 强制落。

### 14.3 凭据的静态保护

`config.json` 里存着服务器密码、网盘 token、Cookie。现状是**明文**。

这不是纯粹的技术问题,需要一次明确裁决,所以把选项和代价摆在这里:

| 方案 | 代价 | 保护了什么 |
|---|---|---|
| **A. 维持明文** | 零 | 什么都没保护。但绿色包本来就是"整个目录可拷走"的形态 |
| **B. 系统钥匙串**(DPAPI / libsecret / Keystore) | 破坏绿色包的可移植性:换机器就解不开 | 防止别的用户 / 别的程序读到 |
| **C. 本机绑定的对称加密** | 同 B,且要自己管密钥轮换 | 同 B |

**建议 A + 边界防护**,理由:绿色包的核心卖点是"拷走就能用",B / C 会直接毁掉它;
而真正的威胁模型里,能读到 `userdata/` 的攻击者通常也能读到钥匙串。

所以把力气花在**不让凭据漏出这个目录**:

1. **诊断包必须脱敏**(§10.3),而且脱敏是核心层的责任,不是让用户自己删
2. **日志里任何位置不许出现凭据**,包括请求 URL 的 query(网盘直链常把 token 放 query)
3. **`system.exportDiagnostics` 有一条契约测试**:构造一份含已知假凭据的配置,
   导出后断言那些字符串一个都不出现。**这条必须先红过**
4. UI 上任何地方不展示线路地址(用户明确要求),线路只显示名称 + 延迟

### 14.4 本地化、时间与格式化

**这一节现在完全没有主,但它会同时影响契约的两端。**

#### 谁负责翻译

`err.msg` 是给人看的字符串,由核心层产生。**那它是什么语言?**

规定:

- **`err.code` 是契约,`err.msg` 是呈现。** UI 优先按 `code` 查自己的文案表;
  查不到才显示 `msg`。这样新增错误码时旧 UI 不会显示空白。
- 核心层按 `lp_init` 传入的 `locale` 产生 `msg`,并提供 `system.setLocale` 供运行时切换
  (设置页的"外观与语言"要能立刻生效,不能要求重启)。
- **上游返回的错误原文不翻译**,原样放进 `err.detail`。翻译它等于伪造服务端的话。

#### 语言范围

跟随现有仓库已有的三份 README:**简体中文(默认)/ English / 日本語**。
UI 层各自用平台的资源机制(Android `strings.xml`、Avalonia `.resx`、SwiftUI
`Localizable.strings`);核心层用一份 `core/i18n` 的 key → 多语言表。

**三端的文案 key 必须同名**,并与核心层共用一份 key 清单 —— 否则同一个提示在三端
被写成三种说法,而 QA 只会在其中一端发现。

#### 时间与时区

| 项 | 规定 |
|---|---|
| 传输 | 一律 UTC 的 RFC3339 字符串。**核心层不发本地时间** |
| 展示 | UI 按系统时区格式化 |
| **放送日历** | 上游是 JST(日本时间)。**必须按上游时区判"今天是周几"**,直接用本地时区会让时区偏东/偏西的用户看到错位一天的番表 |
| 时长 | 核心层给秒(整数),UI 决定显示成 `1:23:45` 还是 `83 分钟` |
| 相对时间 | UI 算(「3 天前」),核心层不算 —— 它不知道 UI 什么时候渲染 |

#### 数字与文本口径(三端统一,不许各写一份)

这一组来自现有实现,每一条背后都有过真实故障:

| 口径 | 规则 |
|---|---|
| 列表卡标题 | 剧集**恒带剧名**:「剧名 · S1E5」;缺季号回落到集名。只写集名认不出是哪部 |
| 季名称 | 用**服务端返回的名字**,不要自己拼「第 N 季」(真实值有「全 1 季」「怪奇物语 4」这种) |
| 评分 | `null` = 没人评过,**不是 0 分**,不许画成 0.0 |
| 未看角标 | 只有剧集 / 季 > 0;已看 = true 时必为 0。**有勾优先,否则显数字** |
| 缓冲速度 | 0 或负数 → **什么都不画**(本地文件本来就是 0,画个「0 KB/s」像卡住了) |
| 影视目录角标 | 「更新至 17 集」「HD」是**独立字段**,不许拼进标题 |
| 线路 | 只显示**名称 + 延迟**;没起名的回落成「线路 N」,**不是**回落成 URL |

### 14.5 单实例与深链

**现状是已知缺口**:App 已经开着时再点一次 `linplayer://` 深链,系统会拉起第二个进程,
而深链只在冷启动时被读取。第二个进程会:抢同一个 `userdata/`、绑另一个端口、开第二个 mpv。

新架构必须做单实例,而且**归 UI 层**(它是平台机制:Windows 命名互斥体 /
Linux abstract socket 或 XDG / Android 的 `launchMode`):

```
第二个实例启动
  ├─ 抢锁失败 → 把 argv 里的深链发给第一个实例 → 自己退出(退出码 0,不弹任何东西)
  └─ 抢锁成功 → 正常启动
第一个实例收到 → 窗口置前 + 调 account.parseDeepLink
```

两条容易漏的:

- **锁必须和数据根绑定**,不是和可执行文件绑定 —— 绿色包允许同机跑两份不同目录的实例,
  那是合法用法,不该被单实例挡住。
- **崩溃留下的陈旧锁要能自愈**(带 pid 校验),否则一次崩溃之后再也起不来。

### 14.6 离线与降级

服务器连不上不等于 App 不能用。**这条现在没有明确规格,三端很容易各写各的。**

| 能力 | 服务器不可达时 |
|---|---|
| 已下载的条目 | **可播**。这是下载功能存在的理由 |
| 本地观看记录 | 可读可写,恢复连接后补传 |
| 本地播放 / SMB / WebDAV / FTP | 与 Emby 无关,照常 |
| 媒体库浏览 | 展示上次缓存 + 明确的"离线"标识,**不是空白页也不是红色报错** |
| 进度上报 | **进队列,不丢**。恢复连接后按序补传,冲突时以时间戳新的为准 |

规定:核心层维护每台服务器的 `reachable` 状态,通过 `account.status` 事件推。
**UI 不许自己探测连通性** —— 三端各探一遍就是三种退避策略。

### 14.7 资源预算

不写数字的"性能要求"等于没要求。以下是**门禁值**,越线即红:

| 指标 | 预算 | 怎么量 |
|---|---|---|
| 冷启动到首屏骨架 | ≤ 400 ms | UI 进程起来到第一帧非空 |
| 冷启动到首页有内容 | ≤ 1.5 s(局域网服务器) | 到第一个区块渲染完 |
| `lp_init` 本身 | ≤ 150 ms | 不许在里面做网络 I/O |
| 单条 `lp_call` 的分派开销 | ≤ 1 ms | 不含业务耗时 |
| 空闲内存占用(核心层) | ≤ 120 MB | 不含预取缓存与 mpv |
| 播放中 CPU(1080p,硬解) | 与 Rust 版同量级(± 20%) | 差分对账时一并量 |
| `lpcore` 二进制体积 | ≤ 25 MB / ABI | `-ldflags "-s -w"` 后 |
| APK 总体积 | ≤ 60 MB | 含 4 ABI 的 libmpv |

> **`lp_init` 不许做网络 I/O** 这条要单独强调:它是同步阻塞的,而 UI 在等它返回才能起
> 事件线程。在里面探测服务器连通性 = 断网时启动界面卡死几十秒,
> 而用户会说"打不开"。连通性探测一律是 `lp_init` 之后的异步事件。

### 14.8 遥测与崩溃上报

**现有实现有这一层,而且它是"黑屏"这类故障的唯一证据来源** —— 迁移时容易整块丢掉。

现状是 Rust 侧接 panic、前端侧接 JS 异常,**同一个 DSN、同一个 release 名**,
所以一次崩溃两边的证据落在同一处。

新架构里对应关系变成:

| 层 | 接什么 |
|---|---|
| 核心层(Go) | 被 recover 的 panic(§5.10)+ 未捕获的致命错误 |
| UI 层(C#) | 未处理异常 + `TaskScheduler.UnobservedTaskException` |

**两层必须共用同一个 release 标识**,否则同一次崩溃的两半对不上。

#### 隐私底线(四条,一条都不许松)

1. **不采 PII。** 不采 IP、账号、服务器地址。
2. **不开性能追踪、不开会话回放。** 不录屏。
3. **绝不给用户自己的出站请求塞遥测头。**
   追踪头传播目标列表必须是**空**的 —— Emby / 网盘 / CDN 是**用户的**服务器,
   我们没资格往它的请求里加东西。
4. **发送前抹掉 URL 里的凭据类 query**(`api_key` / `token` / `access_token` /
   `password` / `sign` / `authorization` 等)。
   报错消息里常年带着请求 URL,而本项目的 Emby 请求 URL 就带 token。

> 第 4 条要有一条**先红过**的测试:构造一条含假 token 的错误消息,
> 断言脱敏后那个值不出现。和 §14.3 的诊断包脱敏是同一类护栏,但**是两条路径**,
> 不能只测一条。

#### 开关

- 遥测必须**可关**,且开关在设置页显眼处。
- 关掉之后**一个字节都不发**(不是"只发匿名的")。

### 14.9 自更新、备份与配置搬迁

#### 自更新(PC 绿色包)

绿色包的难点在 Windows:**正在运行的 exe 不能被覆盖。**

现有实现的做法值得照搬(它已经解决了这个问题):

```
检查 → 下载 zip(先写 .part 再 rename)→ 解包到临时目录
  → 把自己复制一份到 userdata/temp/ 作为 "applier"
  → 以 applier 身份重新启动自己 → 主进程退出
  → applier 覆盖主目录 → 拉起新版主程序 → applier 退出
  → 下次启动时清理上一轮残留的 applier(它删不掉运行中的自己)
```

**两个必须写进契约的雷:**

1. **「以 applier 身份跑」的判断必须是进程入口的第一行。**
   排在数据根重定向之后的话,applier 会按自己的位置(临时目录)推出**错误的数据根**。
2. **解包时越界条目直接丢弃,不是报错。** 报错会让一个坏条目挡住整包。
   (同时这也是路径穿越防护 —— 两个目的一条实现。)

其余:

| 项 | 规定 |
|---|---|
| 版本比较 | **必须自己按语义版本取最大**。上游发布列表的返回顺序**不可依赖** —— 【实测】某次真实数据里 `id` / 创建时间 / 发布时间三个键的顺序全是反的,`.find(第一个)` 会把更旧的包当成更新推给用户,**降级伪装成升级** |
| 版本唯一权威 | 一处。加**单调性门禁** —— 仓库重组曾把它静默顶退,表现是"老用户永远收不到更新" |
| 校验 | 下载完必须校验(大小 + 哈希)再解包 |
| 失败 | 任何一步失败都**回到旧版正常启动**,不许留下半个装好的状态 |

#### 备份与配置搬迁

这是一个**独立于自更新**的功能,现有实现里也有,但 SPEC 之前没提:

| 能力 | 规定 |
|---|---|
| 导出 | 账号 / 线路 / 偏好编码成一份可搬运的载荷,带导出时间 |
| 导入 | **合并,不是覆盖**。同一台服务器以导入的为准,本地独有的保留 |
| 载体 | 文件 + **二维码**(手机扫码搬迁)|
| 密码 | 导出里含凭据 ⇒ 导出动作要有明确警示,且**导出文件不进日志、不进诊断包** |

> **二维码有一个跨入口的坑:** 同一份载荷在两个入口出码时,
> **纠错级必须一致** —— 不一致的表现是"设置页能出图、添加页报容量超限"。

## 15. Windows / Linux 双端差异

> 前面各节把两端合写成「Windows / Linux」。**那是简写,不是事实。**
> 本节把每一处真实分叉摊开 —— 现有实现里有 **9 处 `cfg` 硬分叉**,
> 其中 6 处的注释明写「只有真跑 Linux 才现形」。

### 15.0 总纲

**分叉点必须收敛在少数几个有名字的地方,不许散落。**

现有实现的分叉散在 5 个文件里(窗口句柄、深链注册、overlay、更新器、外部进程),
新架构要求:

| 层 | 允许分叉吗 | 收敛在哪 |
|---|---|---|
| 业务逻辑(emby / source / danmaku / plugins) | **不许** | 一行 `runtime.GOOS` 都不该有 |
| `core/player` | 允许 | libmpv 的加载与 GPU 选择(§15.3、§15.4) |
| `core/paths` | 允许 | 数据根(§10.1) |
| `core/update` | 允许 | 自替换机制(§15.7) |
| UI 层 | 允许 | 窗口 / 系统集成(§15.5) |

> 判据:`grep -r 'GOOS' core/` 的结果应当**可以逐条念出理由**。
> 念不出来的那条,说明业务逻辑漏进平台层了。

### 15.1 分叉点全表

| # | 事项 | Windows | Linux | 现状 |
|---|---|---|---|---|
| 1 | 窗口句柄 | `HWND` | X11 `Window`(XID) | 两端都有 |
| 2 | **Wayland** | — | **当前明确拒绝**,报「视频窗口无法定位」 | 见 §15.2 |
| 3 | 双显卡钉独显 | 两个导出符号(NVIDIA / AMD 各一) | **零实现** | 🔴 Linux 缺 |
| 4 | 硬解 | `d3d11va`(零拷贝) | `vaapi` / `nvdec` | `auto-safe` 两端通吃 |
| 5 | libmpv 加载 | 链接期 `libmpv-2.dll` | **运行时 `dlopen`**,三个候选名 | 见 §15.4 |
| 6 | 深链注册 | 写注册表,**每次启动都跑一遍** | `~/.local/share/applications/` 下的 desktop 条目,**必须落在包外** | 两端都有 |
| 7 | 外部进程窗口 | 必须建进程时压掉控制台窗口,否则每次闪一下 cmd 窗 | 无需 | 两端都有 |
| 8 | 自更新替换 | 等锁 + applier | **先 `unlink` 再 copy**(Unix 上替换运行中程序的标准做法) | 两端都有 |
| 9 | 可执行文件名 | `LinPlayer.exe` | `LinPlayer`(**ELF 无扩展名**) | 两端都有 |
| 10 | 解包后的权限位 | 无所谓 | **必须补 `0755`** | 见 §15.7 |
| 11 | 文件选择器过滤 | 按后缀过滤正常 | **后缀过滤会把列表滤空**(Linux 可执行文件没有后缀) | 见 §15.5 |
| 12 | 路径穿越语义 | 反斜杠与盘符是路径语义 | 反斜杠只是个普通文件名字符 | 测试要分平台 |
| 13 | 符号链接测试 | 需管理员 / 开发者模式,CI 不可靠 | 正常可跑 | 只在 Linux CI 跑 |
| 14 | 屏幕常亮 | 系统 API | D-Bus 抑制 | 🟠 我们零实现;**mpv 自带 `stop-screensaver` 默认开**,但嵌入模式下是否生效未确认 |
| 15 | 托盘 | 通知区 | `StatusNotifierItem`(桌面环境可能没有) | 🔴 两端都零实现 |
| 16 | 系统媒体控制 | SMTC | **MPRIS**(D-Bus) | 🔴 两端都零实现 |
| 17 | 字幕字体回退 | 系统字体 | **fontconfig** | 靠 libmpv |
| 18 | 打包 | 绿色 zip | zip(**不是 tar.gz**,见 §15.6) | 两端都有 |
| 19 | 系统下限 | Windows 10+ | **由 `DT_NEEDED` 决定** | 见 §15.6 |
| 20 | 调试符号 | 独立 `.pdb`,主程序体积不变 | **调试段在 ELF 里**,不 strip 实测 191 MB | 见 §15.6 |

🔴 = 新架构要新做的,不是移植。

### 15.2 【P0】Linux 的显示服务器:X11 还是 Wayland

**这是本节最重要的一条,而且是一个被新架构重新打开的问题。**

现状是**强制 X11**:进程入口把 `GDK_BACKEND` 钉成 `x11`(已显式指定的用户不覆盖)。
理由有两条,都写在代码注释里:

1. 要自己摆放两个顶层窗口并对齐几何 —— Wayland 上**客户端拿不到也定不了自己的绝对位置**
2. `mpv --wid` 在 Wayland 上不受支持

**新架构下这两条理由都不成立了:**

- 视频改成**窗口内合成**(§7.3),不再有"两个顶层窗口对齐"这件事
- 不再走 `--wid`,走 render API

所以 Wayland 从"必然不行"变成了"**没人验过**"。这不是可以顺手假设的事:

| 问题 | 状态 |
|---|---|
| Avalonia 11 在 Wayland 下的成熟度 | 【待验证】 |
| mpv render API + Wayland(EGL)能否拿到可用的 GL 上下文 | 【待验证】 |
| 分数缩放(fractional scaling)下画面是否糊 | 【待验证】 |
| 全屏 / 多显示器行为 | 【待验证】 |
| 无边框窗口 + 自绘标题栏(CSD)在各 WM 下是否一致 | 【待验证】 |

**决策规则(现在就定,免得到时候拍脑袋):**

```
SPIKE-1 在 Linux 上必须同时跑 X11 与 Wayland 两条:
  +- 两条都通过     -> 默认跟随会话,不强制任何 backend
  +- 只有 X11 通过  -> 保留强制 X11,但**必须在设置页与发行说明里写明**
  |                    (老版本是静默降级的,用户不知道自己在跑 XWayland)
  +- 两条都不通过   -> 触发 §7.3 的备选(Linux 改 GTK4 / Qt),核心层零改动
```

> **不许沿用"反正老版本就是 X11"这个理由。** 那个理由已经随架构一起失效了 ——
> 把一条失效的结论继续执行下去,和没做过调研是一样的。

另一条同源约束:**设置显示后端 / GPU 相关的环境变量必须在图形栈初始化之前**,
也就是进程入口的头几行。Go 里 `os.Setenv` 没有 Rust 那条"多线程下是 UB"的问题,
但**时机约束一样存在** —— 晚一步就不生效,而且不报错。

### 15.3 视频与 GPU

#### 硬解

| 平台 | 默认 | 说明 |
|---|---|---|
| Windows | `d3d11va` | 零拷贝,是 Win 上的最佳档。`dxva2-egl` 的 EGL 报错是**无害红鲱鱼**(渲染器名正常),别为它改配置 |

> ⚠️ **「零拷贝」这条结论属于路径 A(mpv 自己拥有窗口、自己建 D3D11 设备)。**
> 实测:走路径 B 且 GL 上下文是桌面 WGL 时,显式 `d3d11va` **起不来**,`auto` 只到 `d3d11va-copy`。
> 换 ANGLE 才有机会拿回零拷贝 —— 见 §7.3 与 `spikes/SPIKE-1a-PGS-render-api.md` §5.3。
| Linux | `auto-safe` | 由 mpv 在 `vaapi` / `nvdec` 里挑,挑不到就软解 |

`auto-safe` 两端通吃,**所以默认值可以统一**;只有 Windows 显式钉 `d3d11va` 这一处例外。

#### 【🔴 Linux 缺口】双显卡必须钉独显

Windows 侧靠导出两个符号(NVIDIA / AMD 各一)让驱动把进程调度到独显。
**两个都要,而且必须防止链接器把没人读的静态量优化掉** ——
少了它们不会报错,只是**继续跑在核显上**,表现是"超分非常卡、独显全程没参与"。

**Linux 侧现在什么都没有。** 对应机制是环境变量(PRIME 那一组),但它们:

- 必须在**图形栈初始化之前**设置(同 §15.2 末尾那条)
- 不同发行版 / 驱动组合取值不同
- 设错了的表现同样是**静默跑核显**,不报错

**规定:**

1. 新架构必须在 Linux 上也做这件事,不能只做 Windows
2. **判据是回读 mpv 日志里的 GPU 名字**,不是"设置了环境变量"
   —— 本项目在 Windows 上就是靠回读才确认修好的
3. 提供可见的诊断出口:`system.gpuInfo` 返回 mpv 实际用的设备名,设置页显示。
   **让用户能自己看见跑在哪块卡上**,比我们猜强

### 15.4 libmpv 的加载与分发

#### soname 分裂 —— Linux 必须运行时 `dlopen`

发行版之间 libmpv 的 soname 是**分裂**的:

| 发行版 | soname |
|---|---|
| Ubuntu 22.04 | `libmpv.so.1`(mpv 0.34) |
| Ubuntu 24.04 / Fedora / Arch | `libmpv.so.2`(mpv 0.36+) |

**链接期绑哪个都是错的:** 绑 `.so.1`,新系统上一启动就是"找不到 libmpv.so.1";
绑 `.so.2` 就得换更新的构建机,glibc 随之抬高,又反过来砍掉一批老系统。

**所以:运行时 `dlopen`,按序试三个候选名。**

```
候选顺序:libmpv.so.2  ->  libmpv.so.1  ->  libmpv.so
```

程序目录优先(`$ORIGIN` rpath),所以用户往解压目录丢一个 `libmpv.so.2` 依然会优先生效。

#### 三条必须进 CI 的断言

这三条是**反向门禁**,防的是"CI 全绿、本机也照跑、发出去起不来":

| # | 断言 | 防什么 |
|---|:--|---|
| 1 | **`libmpv` 绝不能出现在 `DT_NEEDED` 里** | 有人把它变回链接期依赖 → 某个具体 soname 被钉死进 ELF → 在只有另一个 soname 的系统上一启动就死 |
| 2 | 二进制里能 `grep` 到候选名 `libmpv.so.2` | dlopen 那条路被误删,退化成"永远找不到 libmpv" |
| 3 | **构建机上故意不装 libmpv 开发包** | 装了反而有害:一旦有人加回链接期依赖,构建机上有 `.so` 就会"碰巧编过" |

> 第 3 条最容易被"优化"掉 —— 它看起来像是漏装依赖。
> **它是故意的**,注释必须写清楚,否则下一个人会好心地把它装上。

#### Windows 侧:完整版 vs 精简版

Windows 用链接期的 `libmpv-2.dll`,但有一个**静默陷阱**:

**精简版 libmpv 能编译、能播放,只有蓝光 PGS 字幕一片空白。**
所以打包要有**体积门禁**(实测完整版 60 MB 以上),小于阈值即构建失败。

同时 `.dll` 必须真的进包 —— 少了它的表现是**用户双击才发现"找不到 libmpv-2.dll"**,
而 CI 一路绿。

#### 【决策】Linux 发行包不打包 libmpv

理由不是省体积,是**自带的那份反而更坏**:

`$ORIGIN` rpath 会让自带的永远优先于系统的。构建机那份连带一串特定版本的
ffmpeg / libass 依赖,到了别的发行版上就从"用系统上好好的库"变成
"用一个依赖对不上的库"。

**所以:Linux 发行包不含 libmpv,依赖系统安装;想自带的用户把 `libmpv.so.2`
丢进解压目录即可 —— rpath 已经给他留好了这条路。**

> 代价要说清:这意味着 Linux 用户**必须自己装 mpv**。
> 首次启动检测不到 libmpv 时,错误提示要给出各发行版的安装命令,
> **不能只说"加载失败"**。

### 15.5 系统集成

全部归 UI 层(§8.5),但**两端的做法不同,且有几处是新做的**。

#### 深链注册

| | Windows | Linux |
|---|---|---|
| 载体 | 注册表 | `~/.local/share/applications/` 下的 desktop 条目 + MIME 关联 |
| 时机 | **每次启动都重注册一遍** | 同左 |
| 位置 | — | **必须落在包外** |

两条理由要写进代码注释,否则一定会被"优化":

1. **每次启动重注册** —— 绿色包分发,用户挪个文件夹可执行文件路径就变了。
   注册表 / desktop 条目里还钉着老路径的话,深链点了会启动失败或**启动到旧副本**,
   而且不报错。
2. **Linux 的 desktop 条目必须落在包外** —— 它和注册表键同理,删文件夹带不走。
   写死路径比依赖某个会被环境变量左右的抽象更稳。
   > 本项目栽过:早期为了把数据关进包里而劫持 `XDG_*`,险些把 desktop 条目也写进包内。

#### 单实例(§14.5 的平台落法)

| | Windows | Linux |
|---|---|---|
| 锁 | 命名互斥体 | abstract socket 或数据根下的 `flock` |
| 传参 | 命名管道 / 窗口消息 | 同一条 socket |

**锁必须和数据根绑定,不是和可执行文件绑定** —— 绿色包允许同机跑两份不同目录的实例,
那是合法用法。

#### 🟠 屏幕常亮

**先把事实说准:** 我们自己的代码**一次都没设过** `stop-screensaver`(全仓 grep 零命中),
但 **mpv 自带这个选项且默认是开的** —— 所以老版本上"播放时不息屏"可能一直是 mpv 在管。

**问题在于:mpv 靠它自己的窗口去抑制。** 新架构走 render API,
**mpv 不再拥有窗口** —— 那条路大概率断掉,而且断掉的表现是"看片看到一半黑屏",
没有任何报错。

| Windows | Linux |
|---|---|
| 系统 API 声明"正在播放,别息屏" | D-Bus 抑制(桌面环境接口 + systemd 兜底) |

**规定:**

1. **不要依赖 mpv 的 `stop-screensaver`。** SPIKE-1 里顺手验一次它在 render API 模式下
   还灵不灵;**不论结论如何,UI 层都要自己做一遍** —— 多做一层的代价是零,
   赌错的代价是"看片黑屏"。
2. **播放中生效,暂停 / 退出必须撤销。** 不撤销的表现是"看完片之后电脑再也不息屏了",
   用户不会把这件事和播放器联系起来。
3. Linux 上抑制接口**可能不存在**(极简 WM)。取不到就**静默降级**,不弹错。

#### 🔴 系统媒体控制(两端都要新做)

| Windows | Linux |
|---|---|
| SMTC | **MPRIS**(D-Bus) |

MPRIS 在 Linux 上的价值比 Windows 那半大得多 —— 它是桌面环境**统一的**媒体控制协议,
接上之后系统托盘、锁屏、媒体键、GNOME 通知中心全部白送。

**优先级:Linux 的 MPRIS > Windows 的 SMTC。**

#### 🔴 托盘

两端都零实现。Linux 上要注意:**`StatusNotifierItem` 在某些桌面环境根本不存在**
(GNOME 默认就没有)。所以:

- 托盘是**增强,不是必需路径**。任何功能都不许只能从托盘触达
- 取不到托盘时静默降级,**不弹错也不写警告 toast**

#### 【坑】文件选择器的后缀过滤

**`*.exe` 这类后缀过滤在 Linux 上会把列表滤空。** Linux 的可执行文件没有后缀
(`/usr/bin/mpv`),挂一条 `*.exe` 过滤 = **列不出任何东西,看着就是选择器坏了**。

这是**只有真跑 Linux 才现形**的一类:Windows 上开发、Windows 上自测,永远复现不出来,
编译检查也一声不吭。

**规定:后缀过滤必须按平台给。** Linux 上选可执行文件时**不加后缀过滤**
(或只按"可执行位"过滤)。

> 这条要泛化:**任何"按扩展名做的事"都要问一遍在 Linux 上成不成立。**
> 插件包(`.ipk` / `.zip`)、视频文件、字幕文件这些**有**扩展名,不受影响;
> 受影响的是"程序"这一类。

#### 字幕字体

Linux 靠 **fontconfig** 做字体回退,libmpv 直接用,**不需要我们指定字体目录**。
(对照:Android 没有 fontconfig,必须显式指字体目录,否则**静默不画字幕**。)

### 15.6 打包与系统下限

#### glibc:向后兼容,不向前兼容

**构建机必须钉老发行版,不能用 `latest`。**

在新系统(高 glibc)上链出来的二进制,拿到老系统上就是 `GLIBC_2.xx not found`,
**起都起不来**。用老的构建 = 覆盖面更广。

现有口径:钉 **Ubuntu 22.04**。新架构沿用,并且**在 CI 里写明理由**,
否则某次"顺手升级 runner"就会静默砍掉一批用户。

> Go + cgo 同样受这条约束 —— `CGO_ENABLED=1` 就意味着链 glibc。
> 若哪天核心层能做到 `CGO_ENABLED=0`,这条约束才消失,但 libmpv 决定了做不到。

#### 系统下限由 `DT_NEEDED` 决定

**发行包的"最低支持系统"不是拍出来的,是二进制的硬依赖清单算出来的。**

规定:打包步骤必须**把 `DT_NEEDED` 清单打进构建日志**。
谁哪天引入了一个新的硬依赖,这里一眼可见,不用等用户报"装了却起不来"。

> 老版本的下限被 WebKitGTK 钉在 Ubuntu 22.04 / Debian 12。
> **新架构(Avalonia)不再需要 WebKitGTK 做主 UI**,下限有机会往下走 ——
> 但插件逃生舱(§9.3)仍要一个 WebView。
> **【待验证 + 决策】** 逃生舱的 WebView 能否做成**可选依赖**(用到才加载,
> 没有就禁用插件自定义 UI 并说明原因)。能的话,基础发行包的下限会显著放宽。

#### 打包格式:两端都是 zip

**Linux 也打 zip,不是更习惯的 tar.gz。**

理由是**和更新链路一致** —— 应用内更新器解的是 zip,喂它 tar.gz 会当场失败。
格式统一比"符合平台习惯"重要。

同理:**发布资产名必须含小写子串 `linux` / `windows`**,更新器就按这个挑。

#### strip 与调试符号

| | Windows | Linux |
|---|---|---|
| 调试信息在哪 | 独立 `.pdb` | **ELF 二进制本身** |
| 不处理的代价 | 主程序体积不变 | **实测 191 MB** |

顺序是硬的:

```
① 上传调试符号到崩溃收集服务   ② strip --strip-debug   ③ 打包
```

**②必须在①之后。** 符号化靠 build-id 匹配,和本地这份二进制还留不留调试段无关 ——
但顺序反了就没得传了。

另:符号要传到**崩溃上报所指的那个项目**。传到别的项目**两边都不报错**,
只是符号化永远不发生。

#### 产物名

产物名跟构建配置里的**主程序名**走,不是模块名。
> 本项目栽过:改主程序名时只同步了 Windows 的打包步骤,Linux 那半还在找旧名字 ——
> **Windows 绿、Linux 在打包步骤炸**。要有一条测试钉住两边一致。

### 15.7 自更新的平台差异

机制总纲见 §14.9。两端的差异集中在"怎么替换正在运行的程序":

| | Windows | Linux |
|---|---|---|
| 能否直接覆盖运行中的程序 | **不能** | **能**(先 `unlink` 再写新文件是标准做法) |
| 所以需要 applier 吗 | 需要(等主进程退出 + 等锁) | 仍走同一条流程,但**不需要等锁** |
| 可执行文件名 | `LinPlayer.exe` | `LinPlayer` |
| 解包后权限 | 无所谓 | **必须补 `0755`** |

三条会让 Linux 侧 100% 失败的坑,每条都在现有代码里留着注释:

1. **可执行文件名写死 `.exe`** → applier 一路走到"更新包里没有 LinPlayer.exe,
   不敢安装",**应用内更新在 Linux 上 100% 失败**。
2. **zip 不还原 Unix 权限位** → 解出来的主程序是 `0644`。覆盖上去之后用户点了"更新",
   下次启动就是 `Permission denied` —— **更新看着成功了,App 再也起不来**。
   这是 Linux 端最容易漏、后果最严重的一处。
3. **`$ORIGIN` rpath 写不进 ELF 不会报错**,只是"用户自带 libmpv"那条路静默失效。
   打包时要**回读确认**。

> 三条的共性:**都是"看起来成功了"的失败**。所以三条都必须是 CI 断言,不是人工检查。

### 15.8 测试与 CI 矩阵

#### 哪些测试必须在哪个平台跑

| 测试 | Windows | Linux | 理由 |
|---|:--:|:--:|---|
| 业务逻辑(emby / source / danmaku / plugins) | ✅ | ✅ | 两端都跑,发现平台假设 |
| 路径穿越:反斜杠 / 盘符 | ✅ | ❌ | 那些在 Linux 上只是普通文件名,**断言了就是错的** |
| 路径穿越:符号链接逃逸 | ❌ | ✅ | Windows 建符号链接要管理员 / 开发者模式,CI 不可靠 |
| libmpv 的三条 ELF 断言(§15.4) | ❌ | ✅ | 只有 ELF 有 |
| 二进制体积门禁 | ✅ | ✅ | 各有各的阈值 |
| 主程序名一致性 | ✅ | ✅ | 防"一边绿一边炸" |
| 更新器可执行位 | ❌ | ✅ | 见 §15.7 |
| 窗口几何 / DPI | ✅ | ✅ | 真窗口,headless 量不到 |

> **"这条测试在另一个平台上是错的"是合法理由,"跑不了所以不写"不是。**
> 现有实现里符号链接那条测试的注释写得很清楚:
> **它只在 Linux CI 跑,所以它不是没人测的死代码。**

#### CI 矩阵

| Job | Runner | 产出 |
|---|---|---|
| `core-test` | ubuntu-22.04 | Go 核心层单测 + 差分对账 |
| `build-windows` | windows-latest | `lpcore.dll` + 绿色 zip |
| `build-linux` | **ubuntu-22.04**(钉死) | `liblpcore.so` + zip |
| `ui-test-win` | windows-latest | Avalonia headless + 真窗口探针 |
| `ui-test-linux` | ubuntu-22.04(带 X11 虚拟屏) | 同上 |

**两端的构建都必须出真产物并跑一次启动冒烟**,不能只 `build` 就算过 ——
本节列的坑有一半是"编译绿、打包绿、双击才死"。

## 16. Windows 端规格

> §15 回答「两端哪里不同」,本节回答「**Windows 上有哪些只有 Windows 才有的坑**」。
> 这两件事不一样 —— 差异表列不出「UAC 虚拟化会让写入静默重定向」这种单边问题。
>
> 本节 11 项在补写之前**在 SPEC 与 `UI_PC.md` 里命中为 0**。

### 16.1 数据根:三种落点,而且判据必须是探针

§10.1 写的「Windows(绿色包)= exe 同级 `userdata/`」是**理想情况,不是全部**。
现有实现有三种落点,而且**必须如实告诉用户落在哪**:

| 落点 | 何时 | UI 该做什么 |
|---|---|---|
| `Portable` | exe 同级 `userdata/` **且可写** | 正常,不提示 |
| `Overridden` | 环境变量 `LP_DATA_DIR` 指定 | 设置页显示实际路径 |
| **`SystemFallback`** | **exe 目录写不进去**(Program Files / 只读盘 / 网络盘) | **显眼提示** —— 用户以为数据在包里,其实不在 |

#### 【坑】UAC 虚拟化让"建目录成功"变成谎话

**不能只看建目录成不成。** Windows 的 Program Files 有 UAC 虚拟化:
目录"建成功"了,写进去的东西却被悄悄重定向到 `VirtualStore` ——
**用户在包里死活找不到自己的数据,而且一点错都不报。**

**规定:可写性判据必须是「真的写一个探针文件再删掉」。**

```
is_writable(dir):
  建目录            -> 失败即不可写
  写 .write-probe   -> 失败即不可写      ← 这一步是关键,少了它 UAC 虚拟化就骗过去了
  删 .write-probe
```

#### 兜底落点用 `%LOCALAPPDATA%`,**故意不用 Roaming**

回落时用**本地**应用数据目录,不用漫游目录 ——
后者在域环境里会把**几 GB 的缓存跟着域账户漫游**,登录一次拖十分钟。

这条要写进注释,否则"用标准配置目录"看起来更正确,一定会被人改回去。

#### 迁移钉在路径解析上,不是钉在启动流程上

旧数据迁移必须挂在**数据根首次被解析**这个动作上,而不是启动序列里的一句显式调用。

理由是本项目栽过的一次真实故障:迁移写成显式调用时,配置加载**恰好排在它前面** ——
配置读不到就生成设备 id 并立刻保存,在新根落下一个空配置;
迁移随后看见目标已存在就跳过(它绝不覆盖新数据),**旧根里的账号 / token 永远搬不过来**。

**顺序错了不报错,只是用户升级后"服务器全没了"。**
靠注释提醒"要第一个调"是纸糊的;把迁移钉在唯一入口上才是真的关不掉。

> 配套:迁移在测试构建下要有守卫。本项目的 `cargo test` 曾经真的搬走过开发机上的账号。

### 16.2 逃出数据根的暗道

绿色包的承诺是"数据全在这个文件夹里"。**有几条路会绕过它,每条都要单独按住:**

| 暗道 | 现状 | 规定 |
|---|---|---|
| 进程临时目录 | 已按住:启动时把 `TEMP` / `TMP` / `TMPDIR` 指进数据根 | 保留 |
| **WebView2 profile** | 已按住:显式给 `data_directory`。不给它就自己在 `%LOCALAPPDATA%` 下建,**实测 126 MB,而且含 localStorage** | 保留,见 §16.4 |
| **.NET 运行时自己的落点** | 【待确认】 | 新架构必须查一遍:崩溃转储、日志、临时程序集 |
| 崩溃上报缓存 | 【待确认】 | 同上 |

两条硬约束:

1. **重定向临时目录必须排在数据根首次解析之后。**
   顺序反了,迁移就会去一个我们刚刚伪造出来的空目录里找旧数据 ——
   结果同样是"升级后账号全没了"且不报错。
2. **不许劫持系统的用户目录语义**(`%APPDATA%` / XDG 那一组)。
   本项目试过,代价是真的:整个进程的目录查询跟着说谎,
   Linux 侧要写的桌面条目差点因此落进包内、桌面环境永远扫不到。
   **只按住自家数据根,不改系统语义** —— 两端同一个口径。

> 另:"清理缓存"算占用时**不含 WebView2 profile** —— 那里有 localStorage,不归"缓存"管。
> 清理动作对 `config` / `data` / `downloads` / WebView2 profile **一根汗毛都不许动**。

### 16.3 🔴 分发信任:代码签名与 SmartScreen

**现状:未签名。** CI 里没有任何签名步骤(`signtool` / 证书 零命中)。

这不是"锦上添花",它是 Windows 端**第一印象**的决定因素:

| 后果 | 表现 |
|---|---|
| SmartScreen | 首次运行弹"Windows 已保护你的电脑",默认按钮是**不运行**,要点"更多信息"才能跑 |
| 部分杀软 | 未签名 + 自解压 + 会写同目录 + 起本地 HTTP 服务 + 拉起子进程 —— 这组特征很容易被启发式引擎直接隔离 |
| **应用内更新** | 更新器替换 exe 后,新 exe 又是一个未知签名的新文件,**信誉从零开始** |

三个选项:

| 方案 | 代价 | 效果 |
|---|---|---|
| A. 维持不签 | 零 | SmartScreen 常驻。用户量越大,误报越多 |
| B. OV 代码签名证书 | 年费 + 需要主体资质 | 仍要**积累信誉**才不弹,但会随下载量收敛 |
| C. EV 代码签名证书 | 更贵 + 硬件令牌(CI 签名麻烦) | **立刻**通过 SmartScreen |

**建议:先 A,把决定权留给项目负责人;但无论签不签,下面这条现在就要做。**

- **下载页与首次运行指引必须写清楚会遇到什么、为什么。**
  用户看到"Windows 已保护你的电脑"时,如果我们一个字都没提,他的第一反应是"这是病毒"。
- 发布产物提供**校验和**,让愿意核对的人能核对。
- 签名一旦引入,**签的是 zip 里的每个可执行文件**(主程序 + 核心库),不是只签外层压缩包
  —— 只签压缩包对 SmartScreen 没有帮助。

### 16.4 WebView2:从「必需」降级为「可选」

**现状是致命依赖:** 主 UI 本身就跑在 WebView2 里,而**代码里没有任何运行时缺失检测**。
用户机器上没有 WebView2 运行时 = 整个 App 起不来,而且不会有任何有用的提示。

**新架构改变了这件事**:主 UI 是 Avalonia,WebView2 **只服务插件逃生舱**(§9.3)。
所以它从"必需"降成"可选",这是新架构白送的一个稳健性提升 —— **但必须显式做,不会自动发生**:

| 规定 | 内容 |
|---|---|
| 启动时**不**加载 WebView2 | 主 UI 一行都不依赖它。启动路径上碰它 = 又变回必需依赖 |
| 用到时才检测 | 打开插件自定义 UI 之前检测运行时是否存在 |
| **缺失时禁用该功能并说明原因** | 不是崩,也不是空白页。给一句人话 + 一个"怎么装"的去处 |
| profile 必须显式指定 | 指到数据根下的 WebView2 目录。不指定它就自己去 `%LOCALAPPDATA%` 建(实测 126 MB) |
| `system.capabilities` 要如实反映 | 检测不到运行时 ⇒ 对应的插件 UI 能力标成不支持,UI 据此隐藏入口(§5.6) |

> 这条也解释了为什么**主 UI 不能顺手用 WebView 做**:那等于把一个可选依赖重新变成必需依赖,
> 而且是在一个已经把它降级了的架构上。

### 16.5 DPI 与窗口几何

窗口的**视觉**规格在 [`UI_PC.md`](UI_PC.md) §3;本节只写 Windows 上**量出来才知道**的那几条。
四条全部是挂真 exe 实测的,没有一条能靠读代码或跑单测发现。

#### ① 逻辑像素与物理像素混用

**设置位置的接口吃逻辑像素,读取位置 / 尺寸的接口返回物理像素。**

把读到的物理值直接喂回去,**150% 缩放的机器上位置整体偏 1.5 倍**
(实测:播放窗被顶到 `0,0`)。

**规定:窗口几何计算全程用物理像素**,只在最后交给接口时转换 —— 并且**把单位写进变量名**。

#### ② 无边框窗的外框比可见区域每边宽出一圈

Windows 上无边框窗口的外框比可见区域每边宽一圈(**实测 150% 缩放下 11 px**),
而且系统的取矩形接口把它算在内。

**这一圈在窗口建出来之前量不到。** 所以:按内容尺寸算出来的位置**必然偏一个边框宽**。

**规定:先建窗(隐身)→ 拿真实外框尺寸 → 再摆位置 → 才 show。**
两个窗口都用外框尺寸做减法时,两边的边框会自动抵消。

#### ③ 最小化窗口的位置是哨兵值

窗口最小化时,系统返回的位置是 `(-32000, -32000)`。
照它算(比如"把播放窗居中到主窗")会**把新窗口扔到屏幕外**,用户看不见也找不回来。

**规定:任何基于另一个窗口位置的计算,都要先滤掉哨兵值。**

#### ④ 【契约】进全屏之前必须先退出最大化

用户报过两次:「窗口最大化之后,点全屏按钮无效,依旧还是最大化」。

挂真 exe 量出来的根因:**最大化态下直接切全屏,标志位会翻成 true,而窗口客户区一个像素都不动**
(实测 2560×1599 原样)。标志位说全屏了,几何还是最大化 —— 于是标题栏还在、
画面还让着标题栏那一条,用户看到的就是"按钮没用"。

**规定:**

```
进全屏:  记住"进来之前是不是最大化" -> 先退最大化 -> 再进全屏
退全屏:  退出全屏 -> 若之前是最大化,还原成最大化
```

**这条要有契约测试钉住**,而且要钉三件事:① 全屏调用只有一处出口
② 那个出口里有"先退最大化 / 退出后还原"这一对动作 ③ 窗口操作的权限已放行。
> 第三条是本项目的老账:**写了不放行 = 运行时静默失败**,ACL 挡掉调用而且不报错。

#### ⑤ 最大化溢出 8 px —— 状态未确认,必须实测

无边框窗最大化时系统会把窗口四周各外扩约 8 px,**自绘的窗口控制按钮被顶出屏幕**,
表现是"最大化后控制栏没了"。

**必须说清现状,别照抄旧结论:**

- 根治方案(在系统的"取最大化尺寸"消息里把尺寸钉到显示器**工作区**;
  只钉最大尺寸与位置,**不要钉最大跟踪尺寸** —— 钉了会卡住原生全屏铺满整屏)
  **写在已经被删除的旧运行时里**,当前仓库中不存在
- 当前 Rust 版**没有任何补偿代码**,播放窗那边是绕开的:**几何照抄主窗、不真的 maximize**
- 所以「Avalonia / 新架构下这个问题还在不在」——**未确认**

**规定:SPIKE 里实测一次,最大化后量右上角按钮是否完整可见。**
问题仍在就实现上面那个根治方案;不在就把这条记成"已由框架处理",两种结论都要写下来。

#### ⑥ 自检工具本身也有 DPI 陷阱

用截图做几何自检时,**截图进程默认是 DPI 不感知的**,屏幕坐标会被虚拟化 ——
截出来内容偏移、按钮"消失"**是假象**,不是 bug。

**规定:自检工具必须先声明 per-monitor DPI 感知再截图**,否则你在追一个不存在的 bug。

#### ⑦ 应用清单

per-monitor v2 的 DPI 感知、长路径支持(§16.6)都要在应用清单里声明。
**规定:清单内容进版本控制并有测试断言**,不靠"默认应该是对的"。

### 16.6 文件系统的 Windows 语义

#### 非法字符与文件名净化(已有,照搬)

Windows 禁止文件名里出现 `\ / : * ? " < > |`。
**剧名里带冒号是常态**,所以这是必现问题,不是边界情况。

现有净化规则(照搬):

```
把非法字符逐个换成下划线  ->  去首尾空白  ->  截断到 60 字符  ->  空了就回落成一个默认名
最终文件名 = <净化后的标题>_<条目 id>.<容器后缀>
```

> **那个条目 id 后缀是承重的,不是装饰。** 它顺带解决了另外两类 Windows 专属问题:
> ① **保留设备名**(`CON` / `PRN` / `AUX` / `NUL` / `COM1`-`COM9` / `LPT1`-`LPT9`)——
> 这些名字在 Windows 上**根本创建不了文件**,而它们都是合法的剧名;
> ② **结尾的点**(剧名 `Mr.`)—— Windows 会静默吃掉结尾的点。
> 加了 id 后缀之后两者都构不成完整文件名。**谁要动这个命名格式,先读这一段。**

#### 🔴 长路径(MAX_PATH)—— 零处理

**现状:仓库里没有任何长路径处理。**

风险点:下载目录由用户指定(可能已经很深)+ 剧名 60 字符 + 季集目录 + 容器后缀。
默认 260 字符上限不难撞到,而**撞到时的表现是"下载失败",不会说是路径太长**。

**规定:**

1. 应用清单里声明长路径支持(§16.5 ⑦),并且**在最低支持的系统版本上验证它真的生效**
2. 落盘前**校验最终路径长度**,超限时给出**明确的**错误("路径太长",带上实际长度)
3. 净化函数的截断上限要**按剩余预算算**,不是固定 60 ——
   固定值在浅目录下浪费,在深目录下不够

#### 🔴 文件锁定语义

**Windows 锁定正在被打开的文件,Unix 不锁。** 影响三处:

| 场景 | Windows 上会怎样 |
|---|---|
| 预取环形缓存淘汰分段 | 播放器正在读的那一段**删不掉**,淘汰静默失败 |
| 删除下载中的任务 | 同上 |
| 自更新替换 | 已知,已有 applier 机制处理(§15.7) |

**规定:所有"删除/改名一个可能正在被读的文件"的路径,都必须能容忍失败并重试**,
而不是假设删除一定成功。删不掉时**不许静默跳过** —— 至少要计数,
否则环形缓存会因为删不掉而无限增长,而"占用恒等于上限"这条承诺就破了。

#### 路径大小写不敏感

Windows 路径不区分大小写,Linux 区分。影响:缓存键、插件 id、字幕外挂文件匹配。

**规定:凡是用路径当键的地方,一律先规范化成小写再比较** ——
两端用同一套规则,否则同一份缓存在 Windows 上命中、Linux 上不命中(反过来也一样),
而且**两边都不报错**,只是白下一遍。

### 16.7 系统下限与运行时依赖

**照 Linux 那条纪律办:下限是算出来的,不是拍出来的。**

Linux 侧靠二进制的硬依赖清单确定下限(§15.6)。Windows 侧的下限由四个来源共同决定:

| 来源 | 下限 | 状态 |
|---|---|---|
| .NET 运行时(self-contained) | 由所选版本决定 | 【待确认】 |
| Avalonia | 同上 | 【待确认】 |
| WebView2 运行时 | **不再影响下限**(已降为可选,§16.4) | ✅ |
| libmpv / 其依赖 | 由所用的构建决定 | 【待确认】 |

**规定:**

1. 三个"待确认"必须在 SPIKE 阶段查实并写进发行说明,**不许写"应该支持 Win10 及以上"**
2. 打包步骤把**实际的导入表**打进构建日志 —— 与 Linux 侧的做法对齐,
   谁哪天引入了一个新的系统依赖,这里一眼可见
3. **在最低支持版本的干净虚拟机上跑一次启动冒烟**,作为发版门禁。
   "开发机上能跑"和"最低版本上能跑"是两件事

### 16.8 绿色包的内容清单

现有 Windows 包只有两个文件,而且**有一条内容白名单断言**:多一个少一个都当场失败。

**这条断言要保留,但必须重新设计** —— 新架构的包里会有 .NET 运行时的一大堆文件,
逐个列白名单不现实。改成:

| 断言 | 内容 |
|---|---|
| **必需项存在** | 主程序、核心库、libmpv,逐个 `Test-Path` |
| **禁止项不存在** | 调试符号、`.pdb`、源码、测试夹具、任何含凭据的文件 |
| 体积上下限 | 上限防止误打包整个构建目录;**下限防止漏打**(精简版 libmpv 那类问题,§15.4) |
| 资产命名 | 必须含小写子串 `windows`,更新器按这个挑 |
| 主程序名 | 与构建配置一致(有测试钉住,§15.6) |

> **下限断言容易被忽略。** 上限只防"打多了",而本项目吃过的亏全是"打少了 / 打了个残废的"
> —— 而那种情况下 CI 一路绿,用户双击才发现。

## 附:与现有实现的对应关系

| 现有 | 新架构 | 变化 |
|---|---|---|
| Tauri `invoke` | `lp_call` + 事件队列 | 全异步,错误结构化 |
| Tauri `emit` | 事件队列 | 统一成一条通道 |
| `crates/core` 37.6k 行 | `core/`(Go) | 逐模块移植 + 差分对账 |
| `crates/mpv` 2.3k 行 | `core/player`(Go + cgo) | 独立顶层窗口的对齐逻辑**整段删除** |
| `apps/desktop/src/lib.rs` 5.9k 行 | `core/ffi` + `core/bus` | 窗口管理下沉到 Avalonia |
| `ui/desktop` 22.4k 行 | Avalonia(C#) | 重写 |
| `ui/mobile` 17.5k 行 | Compose(Kotlin) | 重写 |
| `ui/tv` 9.5k 行 | Compose TV(Kotlin) | 重写,焦点逻辑删除 |
| `ui/shared` 3.1k 行 | 部分下沉核心层(表单 schema),部分三端各写 | |
| CDP 自检台 | 各端原生 UI 测试 | 手段替换 |
