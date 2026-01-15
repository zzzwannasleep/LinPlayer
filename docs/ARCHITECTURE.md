# LinPlayer 源码导览（Architecture）

本文面向想二次开发/排查问题的开发者，解释项目目录结构、核心模块职责，以及 Emby 接口与播放链路的实现逻辑。

## 目录结构（顶层）

- `.github/`：CI/CD（GitHub Actions）与打包脚本。
  - `.github/workflows/build-all.yml`：多平台 Nightly 构建并发布 `nightly` Release。
  - `.github/workflows/release-latest.yml`：将 `nightly` 产物提升为 `latest` Release。
  - `.github/scripts/compute_version.*`：把 `workflow_dispatch` 输入的版本写入环境变量。
  - `.github/installer/windows/linplayer.iss`：Windows 安装包（Inno Setup）脚本。
- `assets/`：项目资源（目前主要用于应用图标）。
  - `assets/app_icon.jpg`：图标源文件。
  - `assets/README.md`：图标生成说明（`dart run flutter_launcher_icons`）。
- `lib/`：Flutter 应用代码（UI、状态、Emby API 封装、播放器封装）。
- `packages/`：项目内置/改造后的依赖。
  - `packages/media_kit_patched/`：对 `media_kit` 的小改造版本，用于更细粒度传递 mpv 参数（见下文）。
- `android/`、`ios/`、`macos/`、`windows/`、`linux/`：Flutter 各平台宿主工程（应用名、图标、打包配置都在这里落地）。
- `test/`：Flutter 测试（目前是基础 widget test）。
- `build/`、`.dart_tool/`：构建/缓存产物（生成目录，通常不入库）。

## 关键配置文件

- `pubspec.yaml`
  - Flutter/Dart 依赖清单。
  - `dependency_overrides`：指向 `packages/media_kit_patched`（项目内改造的 `media_kit`）。
  - `flutter_launcher_icons`：图标生成配置（源文件为 `assets/app_icon.jpg`）。
- `analysis_options.yaml`：Dart/Flutter lints 配置。
- `.gitignore`
  - 忽略构建产物（如 `build/`、`.dart_tool/` 等）。
  - 当前仓库也忽略了 `web/`（如果你需要 Web 端，建议先移除该忽略规则并补齐 Web 配置）。

## Flutter 端结构（lib/）

### 入口与路由
- `lib/main.dart`
  - `MediaKit.ensureInitialized()`：确保 native 播放后端（mpv）初始化。
  - `PackageInfo.fromPlatform()`：写入 `EmbyApi.setAppVersion()`，用于 User-Agent。
  - `AppState.loadFromStorage()`：恢复已保存的服务器、主题等状态。
  - `MaterialApp.builder`：对竖屏/小屏做全局 UI 缩放（文本/图标/部分组件尺寸）。
  - 根据 `appState.hasActiveServer` 决定进入：
    - `ServerPage`（未登录/未选择服务器）
    - `HomePage`（已选择服务器）

### 全局状态（数据源）
- `lib/state/app_state.dart`
  - 角色：全局 Store（`ChangeNotifier`），负责：
    - 服务器列表/当前服务器（`ServerProfile`）
    - Emby 线路（`DomainInfo`）、媒体库（`LibraryInfo`）
    - 列表缓存（`_itemsCache`、`_itemsTotal`、`_homeSections`）
    - 主题与动态取色开关（Material You）
    - SharedPreferences 持久化（servers/activeServer/theme）
  - 关键流程：
    - `addServer(...)`：登录并保存服务器（调用 `EmbyApi.authenticate` → `fetchDomains`/`fetchLibraries`）。
    - `enterServer(serverId)`：切换服务器并刷新线路/媒体库/首页区块。
    - `loadItems(...)`：拉取分页列表并写入缓存（用于库列表、搜索等）。
    - `loadHome()`：按媒体库拉取最新条目，组成首页区块。
- `lib/state/server_profile.dart`
  - 角色：单个服务器配置与用户偏好。
  - 字段：
    - `baseUrl/token/userId`：Emby 访问三要素
    - `hiddenLibraries`：隐藏的媒体库（长按媒体库卡片切换）
    - `domainRemarks`：线路备注（可选）

### Emby 接口封装（HTTP）
- `lib/services/emby_api.dart`
  - 角色：封装 Emby 常用接口 + 必要的 Header（`X-Emby-Token`、`X-Emby-Authorization`、`User-Agent`）。
  - 主要方法（对应 UI/状态层调用）：
    - `authenticate(username, password, deviceId)`：
      - 尝试 http/https + 可选端口组合（`_candidates()`），命中后返回 `token/userId/baseUrlUsed`。
    - `fetchDomains(token, baseUrl)`：
      - 拉取扩展线路：`/emby/System/Ext/ServerDomains`（允许失败，失败即返回空）。
    - `fetchLibraries(token, baseUrl, userId)`：
      - 拉取媒体库视图：`/emby/Users/{userId}/Views`。
    - `fetchItems(...)`：
      - 统一的分页列表查询：`/emby/Users/{userId}/Items?...`（支持搜索、排序、类型过滤等）。
      - `fetchSeasons/fetchEpisodes` 基于它做细分封装。
    - `fetchContinueWatching / fetchLatestMovies / fetchLatestEpisodes / fetchLatestFromLibrary`：
      - 首页“继续观看/最新内容”的数据来源。
    - `fetchPlaybackInfo(token, baseUrl, userId, deviceId, itemId)`：
      - 获取 `PlaySessionId` / `MediaSources` / `MediaSourceId`。
      - 兼容策略：先 GET，遇到 404/5xx 或返回缺字段则 fallback 到 POST（带 `DeviceProfile`）。
    - `fetchItemDetail / fetchChapters / fetchSimilar`：
      - 详情页、章节、相似推荐等。
  - `imageUrl(...)` / `personImageUrl(...)`：
    - 统一生成封面/人物图片 URL（UI 用 `CachedNetworkImage` 加载）。

### 播放器封装与播放链路

#### 1) 播放器封装
- `lib/player_service.dart`
  - 角色：对 `media_kit`/`media_kit_video` 的轻量封装，屏蔽初始化/销毁细节。
  - `PlayerConfiguration` 关键点：
    - `hwdec=auto` / `hwdec=no`：硬解/软解切换。
    - 网络播放时增大 forward cache、限制 back cache，减少内存占用与回退卡顿。
    - Windows 上设置 `gpu-context=d3d11`，降低 `vo=gpu` 的卡顿概率。
  - 注意：该配置依赖 `packages/media_kit_patched` 暴露的 `extraMpvOptions`（用于传入 mpv 原生参数）。

#### 2) 本地播放（文件）
- `lib/player_screen.dart`
  - `FilePicker` 选择本地视频 → `PlayerService.initialize(path)`。
  - 支持：播放列表、进度条、10s 快进/快退、音轨/字幕切换、硬解/软解切换。

#### 3) Emby 在线播放（网络）
- `lib/play_network_page.dart`
  - 流程：
    1. `_buildStreamUrl()`：根据 `itemId` 以及（可选）`mediaSourceId/audioStreamIndex/subtitleStreamIndex` 构造可播放 URL。
    2. `PlayerService.initialize(networkUrl, httpHeaders)`：
       - 关键 Header：`X-Emby-Token`、`X-Emby-Authorization`（以及 User-Agent）。
    3. 监听 buffering / error / tracks：
       - UI 展示缓冲进度。
       - 初始音轨/字幕偏好只应用一次（避免 tracks 更新时反复覆盖）。

### 主要页面（UI）
- `lib/server_page.dart`：服务器管理（添加/编辑/删除/选择），并提供主题设置入口。
- `lib/home_page.dart`：主入口（底部导航：首页/媒体库/本地），含全局搜索与线路选择。
- `lib/library_page.dart`：媒体库列表（刷新、排序、显示/隐藏库）。
- `lib/library_items_page.dart`：媒体库内容列表（分页加载、进入详情）。
- `lib/show_detail_page.dart`：详情页（Series/Season/Episode 结构、相似推荐、章节、播放入口与可选媒体源/音轨/字幕）。
- `lib/src/ui/`：UI 基础设施
  - `app_theme.dart`：Material 3 主题与动态取色。
  - `theme_sheet.dart`：主题设置弹窗。
  - `ui_scale.dart`：按屏幕宽度计算 UI 缩放系数（用于竖屏平板/手机避免 UI 过小）。

## 典型数据流（从 UI 到 API）

### 登录与初始化
1. `ServerPage` 提交表单 → `AppState.addServer(...)`
2. `EmbyApi.authenticate(...)` 获取 `token/baseUrl/userId`
3. `EmbyApi.fetchDomains(...)`（可选）+ `EmbyApi.fetchLibraries(...)`
4. `AppState` 保存到 SharedPreferences，并切换到 `HomePage`

### 列表与搜索
- `AppState.loadItems(...)` → `EmbyApi.fetchItems(...)` → 写入 `_itemsCache/_itemsTotal` → UI 通过 `AnimatedBuilder` 刷新。

### 播放（网络）
- 详情/列表点击播放 → `PlayNetworkPage`
- `PlayNetworkPage` 组装 URL + headers → `PlayerService.initialize(...)` → `Video(controller)` 渲染。

## 平台目录（android/ios/macos/windows/linux/）

这些目录是 Flutter 生成的宿主工程：
- 应用展示名、包名、图标、签名/打包配置都在这里落地。
- 例如：
  - Android 应用名/图标：`android/app/src/main/AndroidManifest.xml`
  - iOS 应用名：`ios/Runner/Info.plist`
  - macOS 应用名：`macos/Runner/Configs/AppInfo.xcconfig`
  - Windows exe 名/图标：`windows/CMakeLists.txt`、`windows/runner/Runner.rc`

## 你要改哪里？（常见改动入口）

- **改 UI/交互**：优先看 `lib/home_page.dart`、`lib/show_detail_page.dart`、`lib/play_network_page.dart`。
- **改 Emby 接口/字段**：`lib/services/emby_api.dart`（必要时同步调整 `MediaItem` 字段解析）。
- **改缓存/状态/持久化**：`lib/state/app_state.dart`。
- **调播放器体验（硬解/缓冲/参数）**：`lib/player_service.dart`。
- **改主题/视觉规范**：`lib/src/ui/app_theme.dart`。
