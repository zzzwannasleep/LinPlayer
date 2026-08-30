# AGENTS.md · 在这个仓库里干活的规矩

> 面向所有编码 agent(与人类新人)。Claude Code 专属的部分见 [`CLAUDE.md`](CLAUDE.md)。
> **开工前把本文读完。** 这里每一条都对应过一次真实故障。

---

## 0. 这是什么项目

**LinPlayer** —— 第三方媒体播放器。接 Emby 媒体服务器、网盘/局域网/资源站等十几种媒体源,
自带插件市场、弹幕、追番、下载、跨服续播。

覆盖端:**Windows / Linux / Android 手机 / Android TV**。苹果全线暂不做。

播放引擎是 **libmpv**,不是自研解码器 —— 涉及播放的问题先想"mpv 该怎么配",别先想"我们该怎么算"。

## 0.1 ⚠️ 当前处于架构迁移期

正在从 **Rust + React/Tauri** 迁到 **Go 核心 + 各端原生 UI**。

- 目标架构、迁移方案、任务清单:[`docs/go-migration/`](docs/go-migration/README.md)
- **现有 Rust 版是黄金实现,不是待淘汰的旧代码。** 它承载了两年的踩坑结论。
- 迁移期 **Rust 版功能冻结**:新功能只在 Go 版做,Rust 版只修 P0。
- 在现有代码里"顺手优化"是**明确禁止**的 —— 会静默破坏对账基准。要改单独立 issue。

---

## 1. 仓库结构

```
crates/
  core/            各端共用业务核心(数据源/网络/配置/同步/下载/插件),不依赖平台专属 crate
  mpv/             libmpv 封装 + 各平台渲染面。注意 overlay 有 4 个 cfg 变体
  danmaku-proxy/
apps/
  desktop/         Tauri 桌面壳(Windows / Linux)
  android/         安卓壳(手机 / TV,同一份代码两个包)
ui/
  shared/          命令桥 api.ts / theme / tokens.css
  desktop/  mobile/  tv/
docs/
  go-migration/    ★ 迁移文档(SPEC / MIGRATION / TODO / COMMANDS / knowledge/)
  desktop-drafts.html  tv-drafts.html  mobile-drafts/   ← UI 必须照着草稿做
scripts/           构建与门禁脚本
```

**老文档里的路径可能已作废**(2026-07 做过一次仓库重构)。以实际目录为准。

---

## 2. 构建与检查

| 干什么 | 命令 | 备注 |
|---|---|---|
| 前端开发服务器 | `npm run dev` | |
| 前端构建 | `npm run build` | |
| **桌面出包(必做)** | `npm run pack` | 出绿色 zip + 解包测试目录 |
| 桌面快速刷新测试目录 | `npm run pack:fast` | 跳过打 zip |
| Rust 检查(桌面) | `cargo check -p app` | **只编 Windows,照不到安卓** |
| **安卓检查(推前必跑)** | `bash scripts/check-android.sh` | 约 30 秒,不出 APK |
| 安卓出包 | `bash scripts/build-android-apk.sh [--tv\|--phone]` | 默认 `--release --tv --arm64` |
| 命令注册门禁 | `bash scripts/check-commands.sh` | 写了命令忘注册 = 静默失败 |
| workflow 语法门禁 | `bash scripts/check-workflows.sh` | |
| 命令契约校验 | `python scripts/gen-commands.py --check` | |
| 单元测试 | `cargo test` | |
| 前端逻辑自检 | `npm run check:telemetry` / `check:shortcuts` / `check:lan` | 直跑真模块,不是副本 |

### 2.1 「编译绿」不等于「做完了」

| 改了什么 | 最低交付 |
|---|---|
| 桌面端任何改动 | **必须 `npm run pack` 出 exe**。只报"编译通过"= 没交付 |
| 安卓端任何改动 | 至少跑 `check-android.sh`;涉及 UI 要出 APK |
| `crates/mpv` | 四个 cfg 变体都要顾到(Windows / Linux-X11 / Android / 兜底桩)。兜底桩任何 CI 目标都编不到,会静默烂掉 |
| 前端布局/焦点/可见性 | 必须真渲染验证(见 §5) |

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

### Android
- `libmpv.so` 走 **Git LFS**。CI 必须 `lfs: true` + 校验 ELF 魔数,否则 APK 里是指针文本
- release 默认开 R8:只被 JNI 调的方法会被裁 → 必须写 keep 规则
- **`-night` 资源限定符压过 `-vXX`**:按 API 分主题要同时建 `values-vXX` 和 `values-night-vXX`
- release 变体没配 `signingConfig` 会出 `-unsigned.apk`。**`keystore.properties` 写了 ≠ 用了**
- 裸 `cargo check` 会死在 host bindgen 缺 WinSDK 头,必须走 `scripts/` 里的脚本

### CI
- 构建 job 漏传编译期凭据 = 功能静默残废而 CI 全绿。已在 `check-workflows.sh` 设闸门
- 版本号唯一权威是 `tauri.conf.json`;仓库重组曾把它静默顶退,老用户永远收不到更新

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
| 媒体源 / 网盘 / 登录 | `docs/lessons/sources.md` |
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
| Ani-RSS 集成(51 条命令) | `docs/go-migration/knowledge/ANIRSS.md` |
| libmpv 控制层 | `docs/go-migration/knowledge/MPV.md` |
| 弹幕渲染 / ASS 格式 | `docs/go-migration/knowledge/ASS_DANMAKU.md` |
| 弹幕载体格式(XML 方案) | `docs/go-migration/knowledge/DANMAKU_CARRIER.md` |
| 超分 / Anime4K / 画质 | `docs/go-migration/knowledge/UPSCALING.md` |
| 网络层 / 预取代理 | `docs/go-migration/knowledge/NETWORK.md` |
| 媒体源 / 登录逆向 | `docs/go-migration/knowledge/SOURCES.md` |
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
