# AGENTS.md · 在这个仓库里干活的规矩

> 面向所有编码 agent(与人类新人)。Claude Code 专属的部分见 [`CLAUDE.md`](CLAUDE.md)。
> **开工前把本文读完。** 这里每一条都对应过一次真实故障。

---

## 0. 这是什么项目

**LinPlayer** —— 第三方媒体播放器。**只做 Emby**(2026-09-04 定的范围):
网盘、局域网源(SMB/WebDAV/FTP)、Ani-RSS 全部不做,已从代码里删净;
资源站(VOD)将来只以**插件**形式出现,走 `plugin:<插件id>/<源id>` 开放键通道。
本机文件夹播放(`local`)保留 —— 它是播放器的基础能力,不算网盘。
自带插件市场、弹幕、追番、下载、跨服续播。

覆盖端:**Windows / Linux / Android 手机 / Android TV**。苹果全线暂不做。

播放引擎是 **libmpv**,不是自研解码器 —— 涉及播放的问题先想"mpv 该怎么配",别先想"我们该怎么算"。

## 0.1 ⚠️ 架构迁移:Rust 栈已于 2026-09-04 删除

技术栈是 **Go 核心层 + C#(Avalonia) Windows 外壳**。

- 目标架构、迁移方案、任务清单:[`docs/go-migration/`](docs/go-migration/README.md)
- **Rust + React/Tauri 那一整套已从仓库删除**(`crates/` `apps/desktop` `apps/android` `ui/`)。
  需要查旧实现时:`git show rust-final:<路径>`,或 `git log -- <路径>`。
- `core/**` 的注释里原先有 57 处「移植自 `crates/…`」的溯源引用,已随本次删除一并清掉 ——
  注释现在只讲**这段代码本身**为什么这么写,不再指向仓库外的东西。
- **当前只有 Windows 一个端能出包。** Linux 与 Android/TV 的 Go 版 UI 一行没写
  (进度见 `docs/go-migration/TODO.md`),删 Rust 时它们的旧实现一并没了。

---

## 1. 仓库结构

```
core/              ★ Go 核心层。业务全在这:emby / player / plugin / net / danmaku / sync …
                     出库为 lpcore.dll(c-shared),三通道见 SPEC §5
apps/
  windows/         C# + Avalonia 的 Windows 外壳(唯一还活着的端)
bindings/
  csharp/  kotlin/ 从 COMMANDS.md 生成的命令绑定(Commands.g.cs / .kt)
third_party/
  libmpv/          libmpv 的头文件与导入库(cgo 链接用);dll 不入库,CI 现拉
oauth-proxy/       Cloudflare Worker(OAuth 中转)+ 官网静态站
docs/
  go-migration/    ★ 迁移文档(SPEC / MIGRATION / TODO / COMMANDS / knowledge/)
  lessons/         踩坑经验正本(按领域分文件)
scripts/           构建与门禁脚本
VERSION            ★ 版本号唯一权威,见 docs/VERSIONING.md
```

**老文档里的路径可能已作废**(2026-07 做过一次仓库重构)。以实际目录为准。

---

## 2. 构建与检查

| 干什么 | 命令 | 备注 |
|---|---|---|
| **拉工具链(新机器第一步)** | `bash scripts/fetch-toolchain.sh` | Go + C 编译器,版本与 sha256 钉在脚本里 |
| **激活工具链** | `source scripts/env.sh` | PowerShell:`. .\scripts\env.ps1` |
| **工具链自检** | `bash scripts/check-toolchain.sh` | 含反向注入,见 §2.2 |
| **核心层出库** | `bash scripts/build-core.sh` | Go → `build/core/lpcore.dll` |
| **核心层门禁(推前必跑)** | `bash scripts/check-core.sh` | 四关:go test / 出库 / FFI 契约 / C# 契约测试 |
| **绑定层门禁(推前必跑)** | `bash scripts/check-bindings.sh` | 四关:产物最新 / C# 编译 / Kotlin 编译 / 四方比对 |
| **Windows 出包(必做)** | `bash scripts/pack-win.sh` | 出绿色 zip。只报"编译通过"= 没交付 |
| Windows 真机自检 | `bash scripts/selfcheck-win.sh` | 编核心 → 编壳 → 起假 Emby → 起 exe → 截图 |
| workflow 语法 + 凭据闸门 | `bash scripts/check-workflows.sh` | 漏配编译期凭据 = 功能静默残废 |
| 接线报告(不是门禁) | `python scripts/report-wiring.py` | 哪些核心层命令宿主一次都没调过 |

### 2.2 项目级工具链(Go 侧)

迁移期新增的 Go 工具链**不装进系统**,全部在 `.toolchain/` 下(已 gitignore,约 700 MB):

```
.toolchain/
  go/        GOROOT(钉 go1.27.0)
  zig/       cgo 用的 C 编译器(钉 0.16.0)
  gopath/  gocache/  zigcache/     全部缓存
```

三条要知道的事:

1. **Go 编 `c-shared`(核心层那个 `lpcore.dll`)必须走 cgo,cgo 要 gcc/clang 口径的编译器 ——
   MSVC 不算。** 这台机器上原本一个都没有,所以工具链里必须带一个。
   选 zig 是因为一个包同时能当 Windows 和 Linux 的 cc(核心层要出三平台产物),
   且官方发布带 sha256、是纯 zip。**安卓那边不用它**,走已装的 NDK clang。
2. **`GOTOOLCHAIN=local`。** 不许 Go 因为某个 `go.mod` 写了更高版本就自己下一个工具链 ——
   那会静默换掉编译器,还说不清产物是谁编的。
3. **「项目级」是有判据的,不是说法。** `check-toolchain.sh` 逐项断言
   `GOROOT / GOPATH / GOMODCACHE / GOCACHE / GOENV / ZIG_*_CACHE` 都落在 `.toolchain/` 下 ——
   这三处都实测抓到过默认往用户目录写。唯一挪不动的是 Go 的遥测标记
   (`GOTELEMETRYDIR` 由操作系统用户配置目录推导,环境变量不认),
   已用 `go telemetry off` 在那里留一个 14 字节的 "off" 塞子。

自检的第 4 关是**反向注入**:把 `CC` 指到一个不存在的编译器,`c-shared` 构建必须变红。
不做这一步,第 3 关可能压根没走 cgo —— 那就是条恒绿的假门禁(§4.1)。

### 2.1 「编译绿」不等于「做完了」

| 改了什么 | 最低交付 |
|---|---|
| Windows 端任何改动 | **必须 `bash scripts/pack-win.sh` 出 exe**。只报"编译通过"= 没交付 |
| 核心层任何改动 | `bash scripts/check-core.sh`(含 18 条差分对账) |
| 命令表增删 | `bash scripts/check-bindings.sh` —— 命令名是**字符串**,拼错了编译器不管 |
| UI 布局/焦点/可见性 | 必须真渲染验证(见 §5) |

---

## 3. 🚫 红线

### 3.1 提交内容

**任何 IP、域名、线路/中转地址、端口、账号、密码、密钥、token,不得出现在任何提交里。**
包括代码、配置、注释、文档、commit message、issue、PR。私有仓库同样适用。

做法:
- 这类值放**不进版本控制**的文件(`config.sh` / `.env` / `*.local`),仓库里只留 `*.example`
- 写脚本时就抽成变量,不要"先硬编码之后再清"——之后不会清
- 推之前扫:
  ```bash
  grep -rnE '[0-9]{1,3}(\.[0-9]{1,3}){3}|root@|:[0-9]{4,5}\b|passw|token'
  ```
- 已经推上去了:**改写历史或删库重建**,光删最新一版没用

### 3.2 仓库卫生

- **禁用 `git add -A`。** 逐个文件加
- 构建产物必须 gitignore;反向也查:别漏提了整个目录
- 脚本能拉的产物不入库 —— 但**删之前必须先给 CI 补 fetch**,否则构建绿而功能静默失灵

### 3.3 破坏性操作

- 删除/覆盖前先看目标内容
- `git reset --hard` / `push --force` 之前先想有没有更安全的做法
- 不跳过 hook(`--no-verify`),hook 挂了就修根因

---

## 4. 工作纪律

### 4.1 测试必须先红

新测试/脚本写完,**反向注入一个真 bug 看它变红**,再修好。没红过的测试不算测试。

假绿的五种形态:
1. 注入不忠实(注入的 bug 和真实 bug 不是一回事)
2. 环境不同(测试环境碰不到真实条件)
3. 夹具不真实(自己造的数据不像真数据)
4. 语料选错(挑了个恰好通过的样本)
5. **断言的时序让 bug 没机会发生**(清理类断言最容易测成空集)

另:**长期红的门禁 = 没有门禁**,真信号会淹在噪音里。红了就修或者删。

### 4.2 未验证的归因是甩锅

说"可能是环境问题"、"API 不支持"、"版本不兼容"之前,先用工具验证。
`curl` / `ffprobe` / 读源码 / 打真接口 —— 观察和推理冲突时,以观察为准。

典型教训:「只有我们不行」就该去测别人在用的地址;只复现自己那条路径 = 误判成服务器的锅。

### 4.3 修 bug 要修那一类

一个 bug 进来,一类 bug 出去。修完问三件事:
- 同模块有没有同类问题?
- 上下游会不会被波及?
- **一个功能有几套入口?**(桌面/手机/TV × 右键/长按/按钮)每套都要点一遍

加横切逻辑(比如一个统一的过滤点)时,**grep 一遍所有调用者** —— 「一处过滤」的反噬是它也过滤了不该过滤的地方。

### 4.4 别过度解读需求

用户点名的元素,形态照留,只改他要改的属性。要换控件先问。
需求说 A 就做 A,不要顺手把 B 也改了。

### 4.5 做完所有再交付

用户说"先全做完我再测",就别中途丢半成品让他测。整体闭环后一次交。

---

## 5. 真渲染自检:那一类只有跑起来才现形的 bug

**编译绿 + 单测绿照不到**:布局、焦点、可见性、时序、层叠。这类问题占历史故障的很大一部分。

| 场景 | 手段 |
|---|---|
| 桌面 UI | WebView2 远程调试端口挂真 exe,读真 DOM / `elementFromPoint` / 直调 `__TAURI_INTERNALS__.invoke` |
| 手机端布局 | CDP `Emulation.setDeviceMetricsOverride`。**`--window-size=390` 实测 innerWidth 是 504,不能用** |
| 视频窗可见性 | Win32 `EnumWindows` 找窗口类 `lpvid` 量。**CDP 截不到视频层** |
| TV 焦点 | 认 `[data-focused]`;`getBoundingClientRect` 是缩放后设备 px,和 transform 的 CSS px 要换算 |
| 播放链路 | 回读 mpv 日志确认(比如 Device Name 确认真跑在独显上) |

**核层单测全绿照不到前端接线错误。** 有过整整几个月一次都没生效的功能(正则筛选),
只有真渲染断言 `invoke` 的实际参数才抓得到。

---

## 6. 平台特定陷阱

### Windows / PowerShell
- **别用 PS 5.1 批量重写带中文的源码**,会 GBK 乱码。用 `sed` 或 git blob
- **`.ps1` 含非 ASCII 必须带 BOM**,否则 GBK 错位会吞掉下一行代码(打包脚本曾整个失效而 CI 全绿)
- 无边框窗口最大化会四周溢出 8px 顶掉按钮 → `WM_GETMINMAXINFO` 钉 `rcWork`

### Bash 工具
- commit message **别用 PowerShell here-string** `@'...'@`,会污染标题。用 `$'...'` 或 heredoc
- 大文档别硬塞 heredoc,容易被 shell 吃引号 —— 用文件写入工具

### Android(暂无实现,写 Go 版 UI 时再看)
2026-09-04 删 Rust 栈时安卓端一并没了。下面这些是那套踩出来的,重写时仍然成立 ——
细节连同代码去 `git show rust-final:` 里翻:
- `libmpv.so` 走 **Git LFS**。CI 必须 `lfs: true` + 校验 ELF 魔数,否则 APK 里是指针文本
- release 默认开 R8:只被 JNI 调的方法会被裁 → 必须写 keep 规则
- **`-night` 资源限定符压过 `-vXX`**:按 API 分主题要同时建 `values-vXX` 和 `values-night-vXX`
- release 变体没配 `signingConfig` 会出 `-unsigned.apk`。**`keystore.properties` 写了 ≠ 用了**

### CI
- 构建 job 漏传编译期凭据 = 功能静默残废而 CI 全绿。已在 `check-workflows.sh` 设闸门
  (它认 `pack-win.sh` / `build-core.sh` 步骤,9 个变量一个都不能少)
- **版本号唯一权威是仓库根的 `VERSION`**,见 `docs/VERSIONING.md`。
  写死字面量害过三次 —— 版本一退,更新检查判「已是最新」并**静默**卡死所有老用户

---

## 7. 领域知识在哪

不要从零推理,先查:

### 7.1 踩坑与经验(先查这里)

**`docs/lessons/`** —— 按领域整理的历史踩坑全集。**遇到任何"这为什么这么写"的疑问,先 grep 这里。**

| 领域 | 文件 |
|---|---|
| 播放器 / mpv / 字幕 / 画质 | `docs/lessons/player-mpv.md` |
| 网络 / 预取 / 下载 / 线路 | `docs/lessons/network.md` |
| Emby / 媒体库 | `docs/lessons/emby.md` |
| 媒体源 / 网盘 / 登录 | `docs/lessons/sources.md` ⚠️**仅本地,不入公开库** |
| 弹幕 / 追番 / 同步 | `docs/lessons/danmaku-sync.md` |
| 插件系统 | `docs/lessons/plugins.md` |
| UI · 桌面 / 手机 / TV | `docs/lessons/ui-desktop.md` / `ui-mobile.md` / `ui-tv.md` |
| 安卓平台 | `docs/lessons/android.md` |
| 构建 / CI / 发布 | `docs/lessons/build-release.md` |
| 工作方法与纪律 | `docs/lessons/methodology.md` |
| 架构决策 | `docs/lessons/decisions.md` |

### 7.2 领域深度知识

| 想知道 | 看 |
|---|---|
| Emby 协议与适配 | `docs/go-migration/knowledge/EMBY.md` |
| libmpv 控制层 | `docs/go-migration/knowledge/MPV.md` |
| 弹幕渲染 / ASS 格式 | `docs/go-migration/knowledge/ASS_DANMAKU.md` |
| 弹幕载体格式(XML 方案) | `docs/go-migration/knowledge/DANMAKU_CARRIER.md` |
| 超分 / Anime4K / 画质 | `docs/go-migration/knowledge/UPSCALING.md` |
| 网络层 / 预取代理 | `docs/go-migration/knowledge/NETWORK.md` |
| 媒体源 / 登录逆向 | `docs/go-migration/knowledge/SOURCES.md` ⚠️**仅本地,不入公开库** |
| 插件系统宿主契约 | `docs/go-migration/knowledge/PLUGINS.md` |
| 前端经验甄别(A/B/C 三类) | `docs/go-migration/knowledge/UI_LESSONS.md` |
| 目标架构 | `docs/go-migration/SPEC.md` |
| 命令契约(266 条) | `docs/go-migration/COMMANDS.md` |

### 7.3 代码里的中文注释是一等文档

很多注释写着某次真实故障的根因,以及"为什么不能改成看起来更简洁的写法"。
**动一段带长注释的代码之前,先把注释读完。** 把注释当噪音删掉,下一次同样的坑会原样炸回来。

---

## 8. UI 必须照草稿做

PC / TV / 手机的 UI 有既定草稿:`docs/desktop-drafts.html`、`docs/tv-drafts.html`、`docs/mobile-drafts/`。
**逐页实现,别凭空造。**

草稿本身也可能有历史错误 —— 发现和现有实现冲突时,以**现有实现 + 用户最新反馈**为准,并在文档里记一笔。
