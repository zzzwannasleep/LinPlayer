# Go 核心 + 各端原生 UI · 文档索引

> 2026-08-30 起草。这套文档描述 LinPlayer 从 **Rust + React/Tauri** 迁到
> **Go 核心 + 各端原生 UI** 的目标架构、迁移方案与任务清单。

## 一句话结论

**后端 Go 一份,UI 三套原生:Kotlin/Compose(Android 手机 + TV)、C#/Avalonia(Windows + Linux)、
Swift/SwiftUI(Apple,后置)。**

选择 Go 不是偏好,是约束算出来的:核心层要被 Kotlin(JNI)、Swift、C#(P/Invoke)同时加载,
就必须能编译成 C ABI 库 —— 候选集只有 Go / Rust / C++ 三个,排除 Rust 与 C++ 后只剩 Go。

## 文档

| 文档 | 内容 | 什么时候读 |
|---|---|---|
| [`SPEC.md`](SPEC.md) | **架构规格**。三通道模型、FFI 契约、视频通道、各端 UI 规格、平台职责分工 | 动手前必读。有争议时以它为准 |
| [`SPEC.md` §15 / §16](SPEC.md) | **双端差异 + Windows 端规格**。§15 两端哪里不同(20 处分叉),§16 只有 Windows 才有的坑(数据根探针 / 签名 / WebView2 / DPI 几何 / 文件系统语义) | 做 PC 端之前 |
| [`UI_PC.md`](UI_PC.md) | **PC 端 UI 规格**(Windows / Linux)。设计系统、动效、组件状态矩阵、快捷键、19 页逐页规格、播放页 OSD、无障碍、性能预算、验收清单 | 做 PC 端 UI 之前必读 |
| [`MIGRATION.md`](MIGRATION.md) | **迁移方案**。阶段划分、逐模块映射表(含每个模块必须保留的坑)、差分对账机制 | 开始移植某个模块前读对应那行 |
| [`TODO.md`](TODO.md) | **任务清单**。每条带客观判据 | 每天 |
| [`COMMANDS.md`](COMMANDS.md) | **命令契约**,266 条。自动生成 | 写绑定层、移植命令时 |
| [`knowledge/`](knowledge/) | **领域知识库**。每份都是从现有代码里挖出来的、带 `文件:行号` 出处的事实 | 移植某个模块之前 |

### knowledge/ 里有什么

| 文件 | 内容 |
|---|---|
| `EMBY.md` | Emby 协议、Items 参数矩阵、取流、图片、上报、各 fork 的怪癖与绕法 |
| `ANIRSS.md` | Ani-RSS 集成。**51 条命令,本项目命令数最多的一个域**,比 Emby 还多 |
| `MPV.md` | libmpv 控制层。初始化参数、事件线程、属性表、时序约束、四个 cfg 变体 |
| `ASS_DANMAKU.md` | 弹幕渲染与 ASS 字幕格式(教程级) |
| `DANMAKU_CARRIER.md` | 弹幕载体格式评估:XML 方案可不可行、怎么落 |
| `UPSCALING.md` | Anime4K / ArtCNN 等超分模型、mpv 内置画质选项、档位设计 |
| `NETWORK.md` | 预取代理、环形磁盘缓存、Range/seek、下载、线路优选、HTTP 策略 |
| `SOURCES.md` | 媒体源抽象、19 个后端、登录逆向与签名算法 |
| `PLUGINS.md` | 插件宿主契约(`ctx.*` API、manifest、权限、贡献点) |
| `UI_LESSONS.md` | 前端经验甄别:哪些换 UI 框架后依然成立、哪些是浏览器/架构包袱 |

> 另见仓库根的 [`docs/lessons/`](../lessons/) —— 按领域整理的**历史踩坑全集**(123 条)。
> `knowledge/` 是「这块该怎么做」,`lessons/` 是「以前在这块栽过什么」。

## 现在该做什么

**阶段 0:四个 SPIKE。** 它们全部有结论之前不写第二行业务代码。

| SPIKE | 问题 | 为什么它排第一 |
|---|---|---|
| **SPIKE-1** | Windows/Linux 上视频能不能合成进 UI 场景;**Linux 侧 X11 与 Wayland 各跑一条** | 唯一可能推翻 UI 选型的风险。强制 X11 的旧理由已随架构失效(`SPEC.md` §15.2) |
| **SPIKE-2** | Go 的 C ABI 能不能被三个宿主稳定调用 | 整个架构的地基 |
| **SPIKE-3** | quickjs-go 能不能跑现有插件 | 插件生态是否断代 |
| **SPIKE-4** | Compose TV 焦点是不是真的白送 | TV 端最大的收益点 |

详见 [`TODO.md` §1](TODO.md)。每个 SPIKE 的产出写进 `spikes/SPIKE-N.md`,
**必须含实测数据**,不接受"应该可以"。

## 三条不许违反的规矩

1. **现有 Rust 版是黄金实现。** Go 版的验收不是"跑起来了",是"输出和 Rust 版一致"。
   顺手改行为 = 静默退化。要改单独立 issue。
2. **迁移期 Rust 版功能冻结。** 允许它继续加功能 = Go 版永远追不上 = 迁移永远做不完。
   这是所有重写项目的头号死因。
3. **新测试必须先红。** 反向注入真 bug 确认它变红,再修好。
   长期红的门禁 = 没有门禁。

## 这次迁移会顺手消灭的

视频窗几何漂移、全屏白边、wndproc 钩子重入、透明窗 JS 崩了变黑屏、
CSS flex/transform 的一堆布局坑、React effect 与 DOM 时序打架、
TV 焦点矩形膨胀、Tauri capabilities 漏配全黑不报错、前端各持副本要靠广播……

完整清单见 [`MIGRATION.md` §7](MIGRATION.md),里面也列了**不会**消失的那些
(Emby fork 的 API 怪癖、网盘协议、mpv 的约束)。

## 文档纪律

- `SPEC.md` 里标 `【一次做对】` 的段落一旦冻结,改动要有变更记录(见 `CHANGELOG.md`)。
- `SPEC.md` 定跨端契约,`UI_PC.md` 定 PC 端呈现。**同一件事不要两边都写** ——
  写在哪边的判据是「换个 UI 框架它还成不成立」:成立的进 `SPEC.md`,不成立的进 `UI_PC.md`。
- `COMMANDS.md` 的表格段**自动生成**,别手改:
  ```
  python scripts/gen-commands.py           # 重新生成
  python scripts/gen-commands.py --check   # CI 校验
  ```
