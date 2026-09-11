# LinPlayer

<p align="center">
  <a href="https://github.com/zzzwannasleep/LinPlayer/stargazers"><img src="https://img.shields.io/endpoint?url=https://291277.xyz/gh/stars&style=flat&logo=github&label=Stars" alt="Stars"></a>
  <a href="https://github.com/zzzwannasleep/LinPlayer/releases"><img src="https://img.shields.io/endpoint?url=https://291277.xyz/gh/stable&label=stable" alt="Stable"></a>
  <a href="https://github.com/zzzwannasleep/LinPlayer/releases"><img src="https://img.shields.io/endpoint?url=https://291277.xyz/gh/prerelease&label=pre-release" alt="Pre-release"></a>
  <a href="https://github.com/zzzwannasleep/LinPlayer/releases"><img src="https://img.shields.io/endpoint?url=https://291277.xyz/gh/downloads&logo=github&label=downloads" alt="Downloads"></a>
  <a href="https://linplayer.sentry.io"><img src="https://img.shields.io/endpoint?url=https://linplayeroaproxy.pages.dev/sentry/users" alt="Active Users"></a>
  <a href="https://github.com/zzzwannasleep/LinPlayer/blob/main/LICENSE"><img src="https://img.shields.io/endpoint?url=https://291277.xyz/gh/license&label=license" alt="License"></a>
  <img src="https://img.shields.io/badge/Go-1.24+-00ADD8?logo=go&logoColor=white" alt="Go">
  <img src="https://img.shields.io/badge/C%23-.NET%2010-512BD4?logo=dotnet&logoColor=white" alt="C#">
  <img src="https://img.shields.io/badge/Avalonia-11-8B44AC" alt="Avalonia">
  <a href="https://github.com/zzzwannasleep/LinPlayer/actions"><img src="https://img.shields.io/github/actions/workflow/status/zzzwannasleep/LinPlayer/build.yml?branch=main&label=build&logo=github" alt="Build"></a>
  <a href="https://t.me/MikudesuChannels"><img src="https://img.shields.io/badge/Telegram-MikudesuChannels-26A5E4?logo=telegram&logoColor=white" alt="Telegram"></a>
</p>

<p align="center">
  <b>简体中文</b> ·
  <a href="docs/README.en.md">English</a> ·
  <a href="docs/README.ja.md">日本語</a>
</p>

**LinPlayer** 是一个 Emby 第三方客户端。一份 Go 核心层 + 各端自己写的原生 UI，目标平台 **Windows / Android / Android TV / Linux**，当前 **Windows 与 Android（手机 / 平板）可用**。

> ### 🚧 迁移进行中
>
> 项目已从 **Rust 核心 + React/Tauri** 换成 **Go 核心 + 各端原生 UI**。
> 2026-09-04 旧的 Rust/Tauri 栈从仓库删除，tag [`rust-final`](https://github.com/zzzwannasleep/LinPlayer/tree/rust-final) 是它的最后状态。
>
> | 端 | 状态 |
> |:--|:--|
> | **Windows** | 可用，正常发布。免安装绿色包，数据全在主程序同级的 `userdata/` |
> | **Android 手机 / 平板** | 可用（2026-09-06 起）。Jetpack Compose 原生 UI，出已签名 APK |
> | **Android TV** | 未开始 —— 手机端那套触摸交互搬不上遥控器，要单独做一版焦点导航 |
> | **Linux** | 未开始 —— 旧的 Tauri 实现已随重构删除，历史版本仍在 Releases 里 |
> | **苹果全线** | 不做 |

## 下载

去 [**Releases**](https://github.com/zzzwannasleep/LinPlayer/releases) 拿：

- **Windows** —— `LinPlayer-Windows-v*.zip`。免安装，解压即用，不写注册表；升级时覆盖同一个目录即可，账号和配置在 `userdata/` 里不会丢。
- **Android** —— `app-arm64-v8a-release.apk`（arm64 手机 / 平板）。
- 两个渠道：**stable**（稳）与 **pre-release**（快）。装好之后「设置 → 关于 → 检查更新」可以直接下载覆盖，不用再来这里。

## 功能特性

业务能力（Emby 协议 / 网络 / 播放控制 / 同步 / 下载 / 插件）集中在一份**各端共用的 Go 核心层**里，编译成 `lpcore` 动态库；每端只写自己的 UI，按各自的交互语言实现。所以下表里标 ⬜ 的并不是"还没做"，而是**核心已就绪、只差那一端的 UI 接线**。

| 功能 | 说明 | Windows | Android |
|:--|:--|:--:|:--:|
| **MPV 播放内核** | 全格式；HDR / Dolby Vision（自动切 gpu-next + 软解）；PGS/SUP 图形字幕；Anime4K 六档画面增强 | ✅ | ✅ |
| **第二内核（ExoPlayer）** | 安卓专有，播放键长按即可换；该内核下没有画面增强（glsl-shaders 是 mpv 的） | — | ✅ |
| **弹幕** | 弹弹play 等多后端，智能集数匹配、并行分源、搜索与九项显示设置 | ✅ | ✅ |
| **字幕** | 自动加载 Emby 字幕流；轨道切换、延迟、字体/大小/位置；libass 完整特效与内嵌字体 | ✅ | ✅ |
| **播放记录同步** | Emby 进度上报，跨服务器续播 | ✅ | ✅ |
| **追剧日历** | Trakt / Bangumi 放送表（安卓端目前只有 Bangumi 一路） | ✅ | ✅ |
| **排行榜** | 弹弹play 动漫榜 + TMDB 影视榜 | ✅ | ✅ |
| **下载** | 自建多线程 Range 分段下载引擎 | ✅ | ✅ |
| **多线程加载** | 本地预取代理，并发 Range 超前拉流喂播放器 | ✅ | ✅ |
| **插件系统** | QuickJS 脚本引擎，逐插件隔离与授权清单，崩溃/超时不影响宿主 | ✅ | ✅ |
| **应用内更新** | 双渠道（stable / pre）下载覆盖 | ✅ | ✅ |
| **Trakt / Bangumi** | 观看记录 Scrobble 与追番进度同步 | ✅ | ⬜ |
| **代理** | 自定义代理 + CF 优选 IP 本地反代 | ✅ | ⬜ |
| **批量添加服务器** | 粘贴多行配置一次性解析导入 | ✅ | ⬜ |
| **配置迁移** | 扫码在设备间直传服务器配置（含凭据，离线不过云） | ✅ | ⬜ |
| **快捷键** | 播放页键盘操作与按键提示层 | ✅ | — |

<sub>✅ 已接线可用 · ⬜ 核心已就绪，该端 UI 还没接 · — 该端不适用</sub>

> **不做的东西**（2026-09-04 定）：网盘（阿里 / 百度 / 115 / 189 / 139 / 夸克 / OpenList / 飞牛）、
> 局域网源（SMB / WebDAV / FTP）、Ani-RSS 全部下线，代码已删净。
> 资源站将来只以**插件**形式出现。本机文件夹播放保留 —— 它是播放器的基础能力。

## 界面预览

### 桌面端（Windows）

> 截图内容来自 [**UHD MEDIA**](https://www.uhdnow.com)。

<table>
  <tr>
    <td colspan="2"><img src="docs/images/screenshots/pc-player.jpg" width="100%" alt="播放页"><br><sub><b>播放页</b> —— 弹幕、双语字幕、画面增强都在这一层</sub></td>
  </tr>
  <tr>
    <td width="50%"><img src="docs/images/screenshots/pc-home.jpg" width="100%" alt="首页"><br><sub><b>首页</b></sub></td>
    <td width="50%"><img src="docs/images/screenshots/pc-library.jpg" width="100%" alt="媒体库"><br><sub><b>媒体库</b></sub></td>
  </tr>
  <tr>
    <td><img src="docs/images/screenshots/pc-series-detail.jpg" width="100%" alt="剧集详情"><br><sub><b>剧集详情</b></sub></td>
    <td><img src="docs/images/screenshots/pc-movie-detail.jpg" width="100%" alt="电影详情"><br><sub><b>电影详情</b></sub></td>
  </tr>
  <tr>
    <td><img src="docs/images/screenshots/pc-episode-detail.jpg" width="100%" alt="集详情"><br><sub><b>集详情</b></sub></td>
    <td><img src="docs/images/screenshots/pc-add-server.jpg" width="100%" alt="添加服务器"><br><sub><b>添加服务器</b> —— 首次启动的登录闸口</sub></td>
  </tr>
</table>

### 平板（Android）

<table>
  <tr>
    <td width="33%"><img src="docs/images/screenshots/tablet-home.jpg" width="100%" alt="首页"><br><sub><b>首页</b></sub></td>
    <td width="33%"><img src="docs/images/screenshots/tablet-series-detail.jpg" width="100%" alt="剧集详情"><br><sub><b>剧集详情</b></sub></td>
    <td width="33%"><img src="docs/images/screenshots/tablet-episode-detail.jpg" width="100%" alt="集详情"><br><sub><b>集详情</b></sub></td>
  </tr>
  <tr>
    <td><img src="docs/images/screenshots/tablet-player.jpg" width="100%" alt="播放页"><br><sub><b>播放页</b></sub></td>
    <td><img src="docs/images/screenshots/tablet-rankings.jpg" width="100%" alt="排行榜"><br><sub><b>排行榜</b></sub></td>
    <td><img src="docs/images/screenshots/tablet-calendar.jpg" width="100%" alt="追剧日历"><br><sub><b>追剧日历</b></sub></td>
  </tr>
</table>

### 手机（Android）

<table>
  <tr>
    <td colspan="3"><img src="docs/images/screenshots/phone-player.jpg" width="100%" alt="播放页"><br><sub><b>播放页</b> —— 横屏 OSD，右侧是画面比例 / 版本与线路 / 音轨 / 弹幕 / 字幕样式</sub></td>
  </tr>
  <tr>
    <td width="33%"><img src="docs/images/screenshots/phone-home.jpg" width="100%" alt="首页"><br><sub><b>首页</b></sub></td>
    <td width="33%"><img src="docs/images/screenshots/phone-aggregate.jpg" width="100%" alt="聚合视界"><br><sub><b>聚合视界</b> —— 跨服务器的收藏 / 下载 / 排行榜 / 日历</sub></td>
    <td width="33%"><img src="docs/images/screenshots/phone-rankings.jpg" width="100%" alt="排行榜"><br><sub><b>排行榜</b></sub></td>
  </tr>
  <tr>
    <td><img src="docs/images/screenshots/phone-series-detail.jpg" width="100%" alt="剧集详情"><br><sub><b>剧集详情</b></sub></td>
    <td><img src="docs/images/screenshots/phone-calendar.jpg" width="100%" alt="追剧日历"><br><sub><b>追剧日历</b></sub></td>
    <td><img src="docs/images/screenshots/phone-settings.jpg" width="100%" alt="设置"><br><sub><b>设置</b></sub></td>
  </tr>
</table>

## 开发与技术

仓库结构、本地开发与构建、技术栈详见 **[开发文档](docs/DEVELOPMENT.md)**。

## 免责声明

### 关于内容与资源

- LinPlayer 是一款**纯本地播放器 / 第三方客户端**,自身**不提供、不存储、不托管、不分发任何影视资源**,也不内置任何内容源。
- 应用内展示与播放的所有媒体,均来自**用户自行添加的服务器(如 Emby)或用户自行配置的网络来源**,资源的来源、版权与合法性**由用户自行负责**。
- 请仅用于播放你**依法拥有或已获授权**的内容,并遵守你所在国家/地区的法律法规。因使用者不当使用而产生的任何纠纷、损失或法律责任,**由使用者自行承担**,与本项目及开发者无关。
- 本项目为**免费开源、非营利**软件,不以任何形式从内容传播中获利。如有版权方认为相关内容不妥,问题在于内容来源方,请联系对应的资源/服务器提供者。

### 关于匿名遥测与隐私

- **当前发行的 Windows 与 Android 版都不含任何遥测或崩溃上报。** 原先集成的 Sentry
  随 2026-09-04 删除 Rust/Tauri 栈一并移除，`git grep -i sentry -- core/ apps/ bindings/`
  没有任何命中。
- 我们**绝不采集任何可识别你个人身份的信息**：不采集你的账号、密码、Cookie、Token、服务器地址、
  媒体库内容、观看记录或 IP；**不录屏、不追踪你的行为轨迹**。
- 将来若重新引入匿名崩溃上报，会在本节写明采集范围，并保证**绝不出售、共享或用于广告及任何商业用途**。

## 许可证

[LICENSE](LICENSE)

## 致谢

感谢以下开源项目、媒体服务与内核，LinPlayer 站在它们的肩膀上：

### 播放内核

- [mpv](https://github.com/mpv-player/mpv) / [libmpv](https://github.com/mpv-player/mpv) — 全格式播放核心
- [shinchiro mpv-winbuild](https://github.com/shinchiro/mpv-winbuild-cmake) — Windows 完整版 libmpv 预编译（含 PGS/SUP 解码器）
- [Anime4K](https://github.com/bloc97/Anime4K) — 动漫实时超分辨率 GLSL 着色器
- [mpv_PlayKit](https://github.com/hooke007/mpv_PlayKit) — 画质档位 shader 移植与文档
- [AMD FidelityFX (FSR / CAS)](https://github.com/GPUOpen-LibrariesAndSDKs/FidelityFX-SDK) — 放大与锐化着色器
- [NVIDIA Image Scaling](https://github.com/NVIDIAGameWorks/NVIDIAImageScaling) — NVScaler / NVSharpen 着色器

### UI 与框架

- [Go](https://go.dev) — 各端共用的业务核心（编译成 `lpcore` 动态库，经 C ABI 供各端调用）
- [.NET 10](https://dotnet.microsoft.com) / [Avalonia](https://avaloniaui.net) — Windows 外壳与 UI
- [Kotlin](https://kotlinlang.org) / [Jetpack Compose](https://developer.android.com/compose) — 安卓外壳与 UI
- [AndroidX Media3 / ExoPlayer](https://github.com/androidx/media) — 安卓端可切换的第二播放内核

### 服务与数据源

- [Emby](https://emby.media/) — 媒体服务器
- [弹弹play (DanDanPlay)](https://www.dandanplay.com/) — 弹幕与动漫排行榜数据
- [TMDB](https://www.themoviedb.org/) — 影视排行榜数据
- [Bangumi (bgm.tv)](https://bgm.tv/) — 番剧追番进度与收藏同步
- [Trakt](https://trakt.tv/) — 影视观看记录同步（Scrobble）

### Emby 服

感谢以下 Emby 服为 LinPlayer 提供界面演示与长期支持：

- [UHD MEDIA](https://www.uhdnow.com) — 桌面端截图内容来源
- [BAVA 服](https://shop.mebimmer.de) — 早期移动端截图内容来源

### 网络与代理

- [CloudflareSpeedTest](https://github.com/XIU2/CloudflareSpeedTest) — 优选 IP 本地反代的灵感来自 XIU2 大佬的这个项目

### 脚本与工具

- [QuickJS](https://bellard.org/quickjs/) — 插件脚本引擎

> 数据来源 TMDB 与弹弹play 的内容版权归各自所有；本项目仅作聚合展示，不存储或分发受版权保护的媒体。

## Star History

<!-- 自建实时图(oauth-proxy/functions/star/history.svg.js)。
     不用 star-history.com:它没命中缓存就现场去 GitHub 拉,超过自己 10 秒上限就回 500，
     README 里那张图「时不时看不了」就是这么来的（实测连 facebook/react 都 500）。 -->
<a href="https://github.com/zzzwannasleep/LinPlayer/stargazers">
 <picture>
   <source media="(prefers-color-scheme: dark)" srcset="https://291277.xyz/star/history.svg?theme=dark" />
   <source media="(prefers-color-scheme: light)" srcset="https://291277.xyz/star/history.svg" />
   <img alt="Star History Chart" src="https://291277.xyz/star/history.svg" width="100%" />
 </picture>
</a>

## 项目活跃度

![Alt](https://repobeats.axiom.co/api/embed/4858243f2148dfeaa4e82f119fa918f3ec581a11.svg "Repobeats analytics image")

## 赞助

感谢在 [爱发电](https://afdian.com/a/zzzwannasleep) 支持 LinPlayer 的各位（名单实时更新）：

<p align="center">
  <a href="https://afdian.com/a/zzzwannasleep"><img src="https://291277.xyz/afdian/sponsors.svg" alt="爱发电赞助者"></a>
</p>

## 加入频道

Telegram 频道 [**@MikudesuChannels**](https://t.me/MikudesuChannels) —— 版本发布、更新预告与讨论。
