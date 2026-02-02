<div align="center">
  <img src="assets/app_icon.jpg" width="120" alt="LinPlayer" />
  <h1>LinPlayer</h1>
  <p>跨平台媒体播放器：本地 / Emby / Jellyfin / WebDAV（含 Plex PIN 登录）</p>
  <p><sub>Windows / macOS / Linux / Android / Android TV · 重构中 / WIP</sub></p>
  <p>
    <img alt="Flutter" src="https://img.shields.io/badge/Flutter-3.x-02569B?logo=flutter&logoColor=white" />
    <img alt="Platforms" src="https://img.shields.io/badge/Platforms-Windows%20%7C%20macOS%20%7C%20Android%20%7C%20Android%20TV-informational" />
    <img alt="Sources" src="https://img.shields.io/badge/Sources-Local%20%7C%20Emby%2FJellyfin%20%7C%20WebDAV-informational" />
    <img alt="Player" src="https://img.shields.io/badge/Player-MPV%20%7C%20Exo-informational" />
    <img alt="Danmaku" src="https://img.shields.io/badge/Danmaku-Local%20XML%20%7C%20Dandanplay-informational" />
  </p>
  <p>
    <a href="#refactor">重构说明</a> ·
    <a href="#download">下载</a> ·
    <a href="#features">特性</a> ·
    <a href="#quickstart">快速上手</a> ·
    <a href="#tv">TV 使用说明</a> ·
    <a href="#build">构建与运行</a> ·
    <a href="docs/SERVER_IMPORT.md">批量导入</a> ·
    <a href="docs/ANDROID_SIGNING.md">Android 签名</a> ·
    <a href="docs/ARCHITECTURE.md">源码导览</a> ·
    <a href="docs/TV_PROXY_ROADMAP.md">TV 代理路线图</a>
  </p>
</div>

A cross-platform local & Emby/Jellyfin & WebDAV media player built with Flutter (with Plex PIN flow for adding servers).

> [!WARNING]
> 当前处于架构级重构期，功能与兼容性可能频繁变化；如追求稳定可用，建议先观望等待稳定版。
> 如愿意协助测试，请优先使用 nightly 并提交复现步骤与日志/截图。

---

<details>
<summary><b>目录</b></summary>

- [重构说明](#refactor)
- [下载](#download)
- [特性](#features)
- [快速上手](#quickstart)
- [Android TV 使用说明](#tv)
- [构建与运行](#build)

</details>

## <a id="refactor"></a>重构说明（请等待稳定）

本项目正在进行架构级重构，目标是把目前偏“单体堆叠”的实现，逐步演进为 **边界清晰、模块可复用、平台差异可控** 的播放器工程。

### 变成什么样子（目标形态）
- **模块化**：把通用能力（网络/状态/播放器配置/通用 UI 基建等）沉淀为可复用模块；平台相关实现集中在平台层。
- **适配层收口**：通过 `Server Adapter` 把服务端差异收敛到少数实现里，UI 不再到处直接依赖具体 API 类。
- **可选能力可插拔（TV）**：Android TV 提供可选的 **内置代理（mihomo）+ 管理面板（metacubexd）**，并让 App HTTP + 播放器网络流按需走代理（路线图见 `docs/TV_PROXY_ROADMAP.md`）。

### 为什么要模块化（目的）
- **降低耦合与回归成本**：减少“改一处炸一片”，让核心逻辑更容易定位/测试/复用。
- **让重构可渐进**：优先加“收口点/插槽”，再逐步迁移实现，避免一次性大改导致难以回滚。
- **控制平台差异**：Android TV/桌面/移动端的差异集中处理，不在业务与 UI 层散落大量 `if (platform...)`。

### 当前阶段的预期（重要）
> 重构期会有很多问题：功能/设置项/交互可能频繁调整；nightly 可能出现闪退、播放失败、UI/性能问题等。
>
> 如果你只是想“稳定可用”，建议先等待；如果你愿意帮忙定位问题，请使用 nightly 并提供复现步骤与日志/截图。

## <a id="download"></a>下载

从 GitHub Releases 下载：
- **latest**：稳定版
- **nightly**：每日构建（产物会覆盖同名资产）

> 当前重构期建议以 nightly 为主；latest 可能滞后或暂停更新。

下载入口：[latest](../../releases/latest) / [nightly](../../releases/tag/nightly) / [Releases](../../releases)

| 平台 | 产物文件（Release Assets） | 备注 |
| --- | --- | --- |
| Android / Android TV | `LinPlayer-Android.apk`（通用）<br/>`LinPlayer-Android-arm64-v8a.apk`<br/>`LinPlayer-Android-armeabi-v7a.apk` | TV 可直接安装通用版或对应 ABI 版本 |
| Windows (x64) | `LinPlayer-Windows-Setup-x64.exe` | Inno Setup 安装包 |
| macOS | `LinPlayer-macOS-arm64.dmg`<br/>`LinPlayer-macOS-x86_64.dmg` | Apple Silicon / Intel |
| iOS | `LinPlayer-iOS-unsigned.ipa` | 未签名 IPA，需要自行签名/侧载 |
| Linux (x86_64) | `LinPlayer-Linux-x86_64.tar.gz` | 解压后：`cd LinPlayer && ./LinPlayer` |

### 升级/更新（覆盖安装，不丢配置）
- App 内：设置 →「检查更新」/「自动更新」（会下载对应安装包并引导安装）。
- Windows：直接运行新的 `LinPlayer-Windows-Setup-x64.exe` 覆盖安装即可（不要先卸载）。
- Android：直接安装新版 APK 覆盖安装即可；如提示“签名不一致/无法安装”，说明不是同一签名，需卸载重装（会清空数据），建议先在「设置 → 备份与迁移」导出备份。
- 发版注意：不要更改包名（`applicationId` / `PRODUCT_BUNDLE_IDENTIFIER` / `APPLICATION_ID`）或签名证书，否则无法 OTA 覆盖安装；Android 签名配置见 `docs/ANDROID_SIGNING.md`。

> 说明：本项目为非官方客户端，与 Emby / Jellyfin / Plex / 弹弹play 无官方隶属关系。

## <a id="features"></a>特性

> 说明：重构期间部分功能/交互可能临时调整，以 nightly 实际表现为准。

### 亮点
- 本地 + Emby/Jellyfin + WebDAV：一套 UI 统一体验
- 播放器：MPV（跨平台）+ Android 可切换 Exo（Media3）
- Android TV：遥控/焦点优化 + 手机扫码输入
- TV 内置代理：mihomo + metacubexd 面板（App HTTP + MPV 可按需走代理）
- 弹幕：本地 XML + 在线弹幕（弹弹play API v2）

### 媒体源
- 本地播放：原生文件选择与播放。
- Emby/Jellyfin：支持 http/https 与自定义端口；可选的线路扩展服务未部署时，线路列表可能为空，但播放/浏览可用；支持从“分享文本”批量导入服务器（见 `docs/SERVER_IMPORT.md`）。
- WebDAV（只读）：支持“像服务器一样”添加与切换；支持目录浏览 + 播放（含 Range），兼容 Basic/Digest 等常见鉴权。
- Plex（PIN 登录）：支持浏览器授权获取 Token，并从账号资源列表中选择服务器保存（当前仅保存登录信息，暂不支持浏览/播放）。

### 播放与体验
- 播放器：默认 MPV（`media_kit`），Android 可选 Exo（Media3 / ExoPlayer）。
- 字幕：MPV 默认启用 libass（ASS/SSA 样式更完整）；Exo 仍以文本字幕渲染为主。
- 播放链接更稳：自动携带 `MediaSourceId`，减少 404。
- 缓冲策略：总预算（200–2048MB）+ 预设（拖动秒开/均衡/稳定优先）+ 自定义回退比例（0–30%）+ 跳转时清空旧缓冲。
- Anime4K（MPV shader）：内置 Anime4K GLSL 预设，播放页一键开关/切换（仅 MPV 内核有效）。

### UI 与交互
- 首页推荐：继续观看 / 最新电影 / 最新剧集 卡片流；点击即播或进详情。
- 单集详情：播放键旁可标记「已播放 / 未播放」。
- 选集列表：支持条形（封面 + 标题）/ 网格（仅集数）两种显示（设置 → 播放 → 选集列表显示标题）。
- 媒体库与缓存：自动刷新并缓存，减少偶发不显示；浏览首页时后台渐进更新。
- 搜索：历史搜索记录本地持久化；支持无限下拉懒加载。
- 自适应缩放：竖屏平板/手机自动放大 UI（文本/图标/间距）。
- Material 3：跟随系统明/暗色；桌面/手机轻量毛玻璃；Android TV 默认关闭毛玻璃以减少卡顿。

### Android TV
- 遥控器方向键/确认键完整可用（播放页支持快进/快退与控制栏聚焦）。
- 长按确认键：临时倍速播放（松开恢复；倍率 0.25–5×，默认 2×，可在「设置 → 交互」调整）。
- 手机扫码输入：设置 → TV 专区 → 开启「手机扫码控制」，扫码后可在手机端填写服务器地址/账号/密码并直接添加到 TV。
- TV 内置代理：设置 → TV 专区 → 内置代理（mihomo）+ 代理面板（metacubexd），并让 App HTTP + MPV 走代理（路线图见 `docs/TV_PROXY_ROADMAP.md`）。

### 弹幕
- 本地 XML + 在线弹幕（兼容弹弹play API v2），支持样式调节。

### 构建与分发
- Android 同时支持 32 位与 64 位；Windows 打包附带运行时与 DLL。

## <a id="quickstart"></a>快速上手
1. 启动应用，进入「连接服务器」页（未登录也可用）：
   - 点「本地播放」：直接进入本地播放器，选择本地文件播放。
   - 右上角 `+` 添加服务器：可选 Emby / Jellyfin / WebDAV / Plex（仅保存）。
   - 批量导入（Emby/Jellyfin）：在「添加服务器」面板右上角点「批量导入」，粘贴分享文本一键解析导入（见 `docs/SERVER_IMPORT.md`）。
2. 添加 Emby / Jellyfin：
   - 选择服务器类型：Emby / Jellyfin（默认 Emby）。
   - 选择协议：http / https（默认 https）。
   - 填写服务器地址（域名或 IP）。
   - 端口：留空自动 80/443，或手动填写如 8096/8920。
   - 输入账号密码，点击「连接」。未部署扩展线路服务时，只是“线路”页为空，其它功能正常。
3. 添加 WebDAV（只读）：
   - 选择服务器类型：WebDAV。
   - 填写 WebDAV 地址（支持带路径/端口），可选填写账号/密码。
   - 点击「连接并保存」后进入 WebDAV 首页，目录浏览点文件即可播放。
4. 登录 Emby / Jellyfin 后默认进入首页：继续观看、最新电影/剧集；点击卡片可播放（电影/剧集）或下钻（剧集/合集）；从继续观看进入单集详情也可选季/选集快速跳转。
5. 搜索页：首页右上角点「搜索」进入搜索页；搜索框为空时显示历史搜索（前 6 条 +「更多」展开全部）。
6. 媒体库页：显示库海报；点库进入分层列表，可搜索并无限滚动；Episode / Movie 直接播放，Series / Season / Folder 继续下钻。
7. 本地播放器：底部导航「本地」进入，选择本地文件播放。

> Plex：在「连接服务器」页选择 Plex，可用「账号登录（推荐）」走浏览器 PIN 授权并选择服务器；或切换到「手动添加」填写服务器地址/端口（默认 32400）+ Plex Token。当前版本仅保存登录信息，暂不支持浏览/播放。

## <a id="tv"></a>Android TV 使用说明（仅用方向键 + 确认键）

> 提示：非 TV 设备也可以在「设置 → 交互」开启「强制启用遥控器按键支持」，用键盘方向键 + Enter 模拟。

### 全局导航
- ↑ ↓ ← →：移动焦点（高亮）
- 确认键（OK / Enter）：点击/选择当前焦点项

### 手机扫码输入（TV）
- 进入「设置 → TV 专区」
  - 开启「手机扫码控制」
  - 点击「配对地址」右侧二维码图标，在手机上扫码打开
- 手机与 TV 需在同一局域网。
- 在手机页面填写服务器信息并提交：TV 端会自动添加服务器（无需在 TV 上输入）。

### TV 内置代理（mihomo）+ 面板（metacubexd）
- 进入「设置 → TV 专区」
  - 开启「内置代理（mihomo）」：启动/停止/状态（Android TV）
  - 「代理面板（metacubexd）」→ 打开：本地 WebView 打开面板
- 走代理范围：
  - App HTTP：通过 `HttpClient.findProxy` 走 mixed 代理（对 `127.0.0.1`/局域网地址自动 DIRECT）
  - 播放器网络流（MPV）：注入 mpv `http-proxy=http://127.0.0.1:7890`（对局域网地址自动不注入）
- 端口（本机回环）：mixed `127.0.0.1:7890`，external-controller `127.0.0.1:9090`（面板：`/ui/`）
- 配置文件：设置页会显示 `config.yaml` 路径（仅监听 `127.0.0.1`）。
- 安全默认：`allow-lan=false` + `bind-address=127.0.0.1`，不会暴露到局域网；初始配置为 DIRECT（无订阅/节点）。

### 播放页（本地播放 / Emby 在线播放）
- 焦点在视频画面时：
  - 确认：播放/暂停
  - 长按确认：临时倍速播放（松开恢复；需在「设置 → 交互」开启「长按加速」）
  - ← / →：快退/快进（秒数可在「设置 → 交互」调整）
  - ↑：呼出控制栏并自动聚焦到「播放/暂停」
- 焦点在控制栏时：
  - ↑ ↓ ← →：在进度条/按钮之间移动
  - 确认：执行当前按钮/选项
  - ↓：隐藏控制栏并回到视频画面
- 返回上一页：↑ 呼出控制栏后，把焦点移到顶部返回按钮，按确认。

## WebDAV（只读）说明
- 只支持浏览 + 播放（不支持上传/删除/移动）。
- 为了兼容更多 NAS/服务器的鉴权与 Range 请求，播放时会通过本地回环代理 `127.0.0.1` 转发到真实 WebDAV 地址。
- 若服务器不支持 Range（或被反代/网关禁用），可能无法拖动进度条/仅支持顺序播放。

## 播放器内核（MPV / Exo）

- 默认：MPV（`media_kit`），跨平台可用。
- MPV 字幕：默认启用 libass（更好支持 ASS/SSA 样式字幕；Android 读取系统字体）。
- Android 可选：Exo（Media3 / ExoPlayer，基于 `video_player`），在「设置 → 播放 → 播放器内核」切换。
- Exo 更适合部分杜比视界 P8 片源（在 MPV 下可能出现偏紫/偏绿问题），并默认使用 `VideoViewType.platformView` 渲染。
- Exo 内核支持音轨切换与字幕选择/关闭（本地播放与 Emby 在线播放均支持）。
- 播放控制栏可选显示系统时间/电量/网速（设置 → 交互 → 控制栏显示项；网速仅对网络播放有效）。
- 如遇到 Exo/platformView 兼容性或性能问题，可切回 MPV。

### 播放缓冲策略（统一）
设置入口：设置 → 播放 → 播放缓冲大小 / 缓冲策略 / 跳转时清空旧缓冲

- 「播放缓冲大小」是总预算（200-2048MB）：MPV/Exo 都会参考该值（Exo 会按设备内存做安全上限）。
- 「缓冲策略」把总预算拆成「回退缓冲 + 前向缓冲」：回退用于保留已播放内容，前向用于预取后续内容；可选预设或手动调回退比例（0-30%）。
  - 拖动秒开：回退 5% / 前向 95%（默认）
  - 均衡：回退 15% / 前向 85%
  - 稳定优先：回退 25% / 前向 75%
- 「跳转时清空旧缓冲」开启后，快进/快退/拖动进度会优先清掉旧位置缓冲，让新位置更快起播（MPV 会做额外 flush；Exo seek 本身会丢弃旧缓冲）。
- 「不限制视频流缓存」仅影响 MPV 在线播放：会尽量把网络流缓存在磁盘（可能被服务器误判为下载）；可在同页「清理视频流缓存」删除。

## 弹幕（本地 / 在线）

设置入口：设置 → 播放 → 弹幕

### 本地弹幕
- 播放时点击右上角「弹幕」按钮 → 「本地」加载 XML。
- 当前解析器支持 Bilibili 弹幕 XML 格式（常见 `<d p="...">文本</d>`）。

### 在线弹幕（弹弹play）
- 在「设置 → 播放 → 弹幕」中把「弹幕来源」切换为「在线」，并配置一个或多个「弹幕 API URL」（可拖动调整优先级）。
- 默认弹幕源：`https://api.dandanplay.net`
- 重要：使用官方弹弹play源通常需要配置开放平台 `AppId` / `AppSecret`（文档：`https://doc.dandanplay.com/open/`）。
- 播放时会自动尝试匹配并加载；也可以在播放页「弹幕」面板中点击「在线加载」手动触发。

### 样式设置
- 支持：弹幕缩放、透明度、滚动速度、最大行数、粗体。

### 说明与限制
- 本地播放：使用「文件名前 16MB 的 MD5」+ 文件名进行匹配，准确率更高。
- Emby 在线播放：无法获取文件 Hash 时默认仅用标题/文件名匹配，可能需要更准确的命名。
- Web 端暂不支持在线弹幕匹配。
- 目前在线弹幕按「弹弹play API v2」实现；其它弹幕服务器仅当实现了同样的接口（如 `/api/v2/match`、`/api/v2/comment/{episodeId}`）才能直接作为弹幕源使用。
  - 示例（自建/第三方服务）：`https://github.com/huangxd-/danmu_api`、`https://github.com/l429609201/misaka_danmu_server`

## <a id="build"></a>构建与运行

> 建议使用 Flutter stable 3.x，并先运行 `flutter doctor -v` 确认环境正常。

> Android release 签名（保证 APK 可覆盖安装升级）见 `docs/ANDROID_SIGNING.md`。

> 构建/更新 TV 内置代理资源（mihomo + metacubexd）（可选，仅 Android TV 用）：
>
> ```powershell
> powershell -NoProfile -ExecutionPolicy Bypass -File tool/fetch_tv_proxy_assets.ps1
> ```

```bash
# 依赖
flutter pub get

# 运行（当前平台）
flutter run

# 生成应用图标（仅当你替换了 assets/app_icon.jpg）
dart run flutter_launcher_icons

# 分析与测试
flutter analyze
flutter test

# Android（含 32 位）
flutter build apk --split-per-abi

# Windows
flutter build windows --release

# macOS
flutter build macos --release

# iOS（无签名）
flutter build ios --release --no-codesign

# Linux
flutter build linux --release
```

> Windows 本地构建如果提示 “Building with plugins requires symlink support”，请先在系统设置中开启「开发者模式」。

## 应用名称与图标

### 名称（为什么会看到 `lin_player`）
- `pubspec.yaml` 的 `name: lin_player` 是 **Flutter/Dart 包名**（依赖导入、构建目录等会用到），不等同于各平台桌面/桌面图标上显示的应用名。
- 各平台“展示名 / 窗口标题”在平台工程里配置，例如：
  - Android：`android/app/src/main/AndroidManifest.xml`（`android:label`）
  - iOS：`ios/Runner/Info.plist`（`CFBundleDisplayName`）
  - macOS：`macos/Runner/Configs/AppInfo.xcconfig`（`PRODUCT_NAME`）
  - Windows：`windows/CMakeLists.txt`（`BINARY_NAME`）与 `windows/runner/main.cpp`（窗口标题）
  - Linux：`linux/runner/my_application.cc`（窗口标题）

### 图标
- 图标源文件：`assets/app_icon.jpg`（建议至少 1024×1024）。
- 生成各平台图标：`dart run flutter_launcher_icons`（见 `assets/README.md`）。
- CI（GitHub Actions）构建前会自动生成图标；如果你在本地替换了图标，建议同样运行一次以保证仓库内各平台图标文件同步。

## CI / 发布（GitHub Actions）
- Nightly 构建：`.github/workflows/build-all.yml`
  - 手动触发（`workflow_dispatch`），需要输入 `build_name` 与 `build_number`。
  - 产物会上传到 GitHub Release 的 `nightly`（覆盖同名资产）。
- 稳定版发布：`.github/workflows/release-latest.yml`
  - 将 `nightly` 的产物“提升”为 `latest`。
  - 如果 nightly 的资产文件名与预期不同（例如 Android 可能是 `app-release.apk`），工作流会自动兼容并上传到 `latest`。

## 源码导览
- 架构/目录结构/播放链路：[docs/ARCHITECTURE.md](docs/ARCHITECTURE.md)
- Android 签名与 OTA 覆盖安装：[docs/ANDROID_SIGNING.md](docs/ANDROID_SIGNING.md)
- 从分享文本批量导入服务器：[docs/SERVER_IMPORT.md](docs/SERVER_IMPORT.md)
- 模块化（packages）：
  - [packages/lin_player_core/README.md](packages/lin_player_core/README.md)：基础定义（AppConfig / MediaServerType 等）
  - [packages/lin_player_prefs/README.md](packages/lin_player_prefs/README.md)：偏好设置定义（UI 模板/播放器设置枚举等）
  - [packages/lin_player_server_api/README.md](packages/lin_player_server_api/README.md)：服务端/网络 API（Emby/WebDAV/Plex）
  - [packages/lin_player_server_adapters/README.md](packages/lin_player_server_adapters/README.md)：Server Adapter 适配层（UI 只依赖接口）
  - [packages/lin_player_ui/README.md](packages/lin_player_ui/README.md)：UI 基建（主题/样式/玻璃效果/图标库等）
  - [packages/lin_player_player/README.md](packages/lin_player_player/README.md)：播放器模块（PlayerService/弹幕/播放控制等）
  - [packages/lin_player_state/README.md](packages/lin_player_state/README.md)：全局状态与持久化（AppState/ServerProfile/备份等）
  - [packages/README.md](packages/README.md)：模块索引（推荐）
- TV 内置代理路线图：[docs/TV_PROXY_ROADMAP.md](docs/TV_PROXY_ROADMAP.md)

## UI 自适应（开发者）

<details>
<summary><b>展开</b></summary>

- 全局缩放逻辑在 `packages/lin_player_ui/lib/src/ui/ui_scale.dart`；应用入口通过 `MaterialApp.builder` 统一应用缩放（文本/图标/部分组件尺寸）。
- 如果你新增了包含“固定尺寸”的页面（尤其是 `GridView` 的 `maxCrossAxisExtent`），建议显式乘上 `context.uiScale`，避免竖屏/小屏出现卡片过小。

</details>

## 自定义 mpv 参数（进阶）

<details>
<summary><b>展开</b></summary>

- 工程内已内置 `packages/media_kit_patched`，在 `pubspec.yaml` 通过 `dependency_overrides` 覆盖原包。
- `PlayerConfiguration` 新增 `extraMpvOptions` 列表，可直接传入 mpv 的原生参数（形如 `key=value`，无 `=` 时默认视为 `key=yes`）。示例：
  ```dart
  PlayerConfiguration(
    extraMpvOptions: [
      'gpu-context=d3d11',
      'hwdec=auto-safe',
      'video-sync=audio',
      'scale=lanczos',
    ],
  )
  ```
- TV 和桌面可按需分别传入不同配置，现有播放器创建处已支持该字段。
- 播放页右上角提供“硬解/软解”切换，切换后会重新初始化播放器并应用 `hwdec` 参数。

</details>

## 常见问题
- DNS 解析失败 / Host lookup：请确认域名在设备浏览器可访问；必要时改填 IP 或切换 http/端口（如 8096/8920）。
- 电影或剧集 404：已使用 MediaSourceId 的播放 URL；若仍异常，请确认服务器对应条目可在网页端播放。
- 线路列表为空：未部署 `emby_ext_domains` 时属正常，不影响媒体库与播放。
- 批量导入解析不到服务器地址：请确认分享文本里包含 http(s) URL 或域名/IP（支持无 scheme，如 `example.com 443`；也支持 `端口: 443` 的全局端口行）；非线路链接（Telegram/仓库等）会默认不勾选。
- 网速不显示：到「设置 → 交互」开启「显示网速」；网速仅对网络播放有效，显示位置在底部控制栏（随控制栏显隐）。

## 目录导航

<details>
<summary><b>展开：App / packages 目录索引</b></summary>

### App（Flutter / `lib/`）
- `lib/main.dart` 应用入口（初始化、主题、路由）
- `lib/server_page.dart` 服务器管理/登录入口
- `lib/home_page.dart` 首页（继续观看、最新电影/剧集）
- `lib/search_page.dart` 搜索页（历史搜索/搜索结果）
- `lib/webdav_home_page.dart` WebDAV 首页（WebDAV / 本地 / 设置）
- `lib/webdav_browser_page.dart` WebDAV 浏览页（目录列表/点播入口）
- `lib/library_page.dart` 媒体库列表
- `lib/library_items_page.dart` 分层/搜索/播放列表
- `lib/show_detail_page.dart` 详情页（Series/Season/Episode；单集详情含选季/选集与同剧剧集栏）
- `lib/danmaku_settings_page.dart` 弹幕设置页（本地/在线、样式、在线源管理）
- `lib/play_network_page.dart` Emby 在线播放
- `lib/player_screen.dart` 本地播放器
- `packages/lin_player_player/lib/player_service.dart` 播放器封装（mpv 参数、硬解/软解）
- `packages/lin_player_player/lib/dandanplay_api.dart` 在线弹幕（弹弹play API v2）封装
- `packages/lin_player_player/lib/src/player/danmaku.dart` 弹幕解析（本地 XML / 在线列表）
- `packages/lin_player_player/lib/src/player/danmaku_stage.dart` 弹幕渲染（覆盖层）
- `packages/lin_player_state/lib/app_state.dart` 状态/登录/缓存

### 模块（`packages/`）
- `packages/lin_player_core/README.md` 核心定义（AppConfig / FeatureFlags / MediaServerType 等）
- `packages/lin_player_prefs/README.md` 偏好设置定义（UI 模板/播放器设置枚举等）
- `packages/lin_player_server_api/README.md` 服务端/网络 API（Emby/WebDAV/Plex）
- `packages/lin_player_server_adapters/README.md` Server Adapter 适配层（UI 只依赖接口）
- `packages/lin_player_ui/README.md` UI 基建（主题/样式/玻璃效果/图标库等）
- `packages/lin_player_player/README.md` 播放器模块（PlayerService/弹幕/播放控制等）
- `packages/lin_player_state/README.md` 全局状态与持久化（AppState/ServerProfile/备份等）
- `packages/media_kit_patched/` mpv/media_kit 的本地改造版本
- `packages/video_player_android_patched/` Exo/video_player_android 的本地改造版本

</details>

## TODO（重构路线图）
- [x] 模块化（基础拆分）：提取 `lin_player_core` / `lin_player_server_api` / `lin_player_server_adapters`（见 `packages/`）
- [x] 模块化（下一步）：继续抽离 state / player / UI 基建等通用能力（已拆分出 `lin_player_prefs` / `lin_player_ui` / `lin_player_player` / `lin_player_state`）
- [x] Server Adapter（收口）：UI 不再直接依赖具体 API（只依赖 adapter/interface）
- [x] 网络收口：统一 HTTP client 创建入口（为代理/证书/重试/超时等打基础）
- [x] TV 形态：设置页 TV 专区 + 遥控/焦点优化（`DeviceType.isTv`）
- [x] TV 内置代理 MVP：mihomo start/stop/status（仅 Android TV）
- [x] 代理面板：metacubexd 打包/解压 + 本地 WebView 打开
- [x] 走代理：App HTTP + 播放器网络流（mpv 参数注入）
- [ ] 合规：确认 mihomo / metacubexd 许可证与分发声明

## 鸣谢与参考

### 引用 / 上游
- Anime4K：https://github.com/bloc97/Anime4K（本项目内置部分 GLSL shader：`assets/shaders/anime4k/`，用于 MPV 内核的 Anime4K 预设）

### 参考 / 灵感
- Playboy Player：https://github.com/Playboy-Player/Playboy
- NipaPlay Reload：https://github.com/MCDFsteve/NipaPlay-Reload

### 可配合使用的服务
- Emby 扩展线路：`emby_ext_domains`（可自行部署/使用相关开源实现）
- 在线弹幕兼容服务：`https://github.com/huangxd-/danmu_api`、`https://github.com/l429609201/misaka_danmu_server`

### 文档
- Emby 项目与文档：https://dev.emby.media/doc/restapi/index.html
- Jellyfin API 文档：https://api.jellyfin.org/
- Plex 开发者文档：https://developer.plex.tv/pms/
