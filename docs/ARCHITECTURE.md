# LinPlayer 源码导览（Architecture）

本文面向想二次开发/排查问题的开发者，解释项目目录结构、核心模块职责，以及 Emby/Jellyfin 接口与播放链路（并包含 Plex PIN 登录添加服务器）的实现逻辑。

## 目录结构（顶层）

- `.github/`：CI/CD（GitHub Actions）与打包脚本。
  - `.github/workflows/build-all.yml`：多平台 Nightly 构建并发布 `nightly` Release。
  - `.github/workflows/release-latest.yml`：将 `nightly` 产物提升为 `latest` Release。
  - `.github/scripts/compute_version.*`：把 `workflow_dispatch` 输入的版本写入环境变量。
  - `.github/installer/windows/linplayer.iss`：Windows 安装包（Inno Setup）脚本。
- `assets/`：项目资源（目前主要用于应用图标）。
  - `assets/app_icon.jpg`：图标源文件。
  - `assets/README.md`：图标生成说明（`dart run flutter_launcher_icons`）。
- `lib/`：Flutter 应用代码（UI、状态、Emby/Jellyfin API 封装、Plex PIN 登录封装、播放器封装）。
- `packages/`：项目内置/改造后的依赖。
  - `packages/media_kit_patched/`：对 `media_kit` 的小改造版本，用于更细粒度传递 mpv 参数（见下文）。
  - `packages/video_player_android_patched/`：对 `video_player_android` 的改造版本，用于 Exo 内核的字幕轨道枚举/选择与 platformView 字幕渲染（见下文）。
- `android/`、`ios/`、`macos/`、`windows/`、`linux/`：Flutter 各平台宿主工程（应用名、图标、打包配置都在这里落地）。
- `test/`：Flutter 测试（widget test + 部分单元测试）。
- `build/`、`.dart_tool/`：构建/缓存产物（生成目录，通常不入库）。

## 关键配置文件

- `pubspec.yaml`
  - Flutter/Dart 依赖清单。
  - `dependency_overrides`：指向 `packages/media_kit_patched` 与 `packages/video_player_android_patched`（项目内改造的 `media_kit`/`video_player_android`）。
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
    - 弹幕设置（启用/来源、本地/在线、在线源列表、开放平台凭证、样式参数等）
    - SharedPreferences 持久化（servers/activeServer/theme/danmaku...）
  - 关键流程：
    - `addServer(...)`：登录并保存服务器（调用 `EmbyApi.authenticate` → `fetchDomains`/`fetchLibraries`）。
    - `addPlexServer(...)`：保存 Plex 服务器信息（Token/连接地址等；当前仅保存登录信息，暂不支持浏览/播放）。
    - `enterServer(serverId)`：切换服务器并刷新线路/媒体库/首页区块。
    - `loadItems(...)`：拉取分页列表并写入缓存（用于库列表、搜索等）。
    - `loadHome()`：按媒体库拉取最新条目，组成首页区块。
- `lib/state/server_profile.dart`
  - 角色：单个服务器配置与用户偏好。
  - 字段：
    - `serverType/apiPrefix`：服务器类型与 API 前缀（Emby 常见为 `emby`，Jellyfin 常见为空字符串）。
    - `baseUrl/token/userId`：Emby/Jellyfin 访问三要素
    - `hiddenLibraries`：隐藏的媒体库（长按媒体库卡片切换）
    - `domainRemarks`：线路备注（可选）
    - `plexMachineIdentifier`：Plex 服务器机器标识（可选，用于后续匹配/识别）
- `lib/state/danmaku_preferences.dart`
  - 角色：弹幕偏好枚举与序列化（本地/在线）。

### Emby/Jellyfin 接口封装（HTTP）
- `lib/services/emby_api.dart`
  - 角色：封装 Emby/Jellyfin 常用接口 + 必要的 Header（`X-Emby-Token`、`X-Emby-Authorization`、`User-Agent`）。
  - 主要方法（对应 UI/状态层调用）：
    - `authenticate(username, password, deviceId)`：
      - 尝试 http/https + 可选端口组合（`_candidates()`），命中后返回 `token/userId/baseUrlUsed`。
    - `fetchDomains(token, baseUrl)`：
      - 拉取扩展线路：`/emby/System/Ext/ServerDomains`（允许失败，失败即返回空；可配合 `https://github.com/uhdnow/emby_ext_domains` 部署/使用）。
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

### Plex 接口封装（PIN 登录）
- `lib/services/plex_api.dart`
  - 角色：封装 Plex PIN 登录与资源列表接口（plex.tv API v2），用于在 App 内完成“账号授权 → 选择服务器 → 保存”。
  - 主要方法：
    - `createPin()`：创建 PIN（返回 `id/code/expiresAt`）。
    - `buildAuthUrl(code)`：拼接授权 URL（在外部浏览器打开）。
    - `fetchPin(id)`：轮询 PIN 状态，直到获得 `authToken`。
    - `fetchResources(authToken)`：拉取账号资源列表并筛选 `server`。
  - UI 集成：`lib/server_page.dart` 中选择 Plex 后可用“账号登录（推荐）”走浏览器授权，或在“手动添加”里登录获取 Token 并填入。

### 在线弹幕接口封装（弹弹play）
- `lib/services/dandanplay_api.dart`
  - 角色：封装弹弹play API v2 的匹配与弹幕下载（`/api/v2/match`、`/api/v2/comment/{episodeId}`）。
  - 鉴权：
    - 优先使用开放平台签名头：`X-AppId` / `X-Timestamp` / `X-Signature`。
    - 若返回 403 且提示缺少鉴权，会回退到 `X-AppSecret` 模式（方便自建兼容服务）。
  - 兼容服务示例（自建/第三方）：`https://github.com/huangxd-/danmu_api`、`https://github.com/l429609201/misaka_danmu_server`

### 播放器封装与播放链路

#### 1) 播放器封装
- `lib/player_service.dart`
  - 角色：对 `media_kit`/`media_kit_video` 的轻量封装，屏蔽初始化/销毁细节。
  - `PlayerConfiguration` 关键点：
    - `hwdec=auto` / `hwdec=no`：硬解/软解切换。
    - 网络播放时增大 forward cache、限制 back cache，减少内存占用与回退卡顿。
    - Windows 上设置 `gpu-context=d3d11`，降低 `vo=gpu` 的卡顿概率。
  - 注意：该配置依赖 `packages/media_kit_patched` 暴露的 `extraMpvOptions`（用于传入 mpv 原生参数）。

#### 1.1) 播放器共享模块（为多内核/后续扩展做拆分）
- `lib/src/player/shared/player_types.dart`
  - 角色：播放器 UI 共享的枚举与工具方法（例如方向/手势模式、时间格式化、seek 目标裁剪）。
- `lib/src/player/shared/system_ui.dart`
  - 角色：对沉浸模式/系统 UI 控制做平台封装（统一判断是否支持 + enter/exit）。
- `lib/src/player/network/emby_stream_resolver.dart`
  - 角色：把 Emby/Jellyfin 的 playbackInfo + mediaSource 选择逻辑封装为 `resolveEmbyStreamUrl(...)`，供 MPV/Exo 等不同播放内核复用。
- `lib/src/player/network/network_playback_backend.dart`
  - 角色：网络播放“后端”抽象（resolve URL + headers），当前默认实现为 Emby-like（Emby/Jellyfin）。
- `lib/src/player/network/network_playback_reporter.dart`
  - 角色：把 Emby 的播放上报（start/progress/stop + updatePosition）节流封装为 `NetworkPlaybackReporter`，不同内核只需提供 position/duration/paused 状态即可复用。
- `lib/src/player/network/emby_media_source_utils.dart`
  - 角色：mediaSource 元信息解析与展示（版本标题/副标题、按偏好选择版本等）。
- `lib/src/player/network/emby_http_headers.dart`
  - 角色：集中构造 Emby/Jellyfin 鉴权请求头，供网络播放复用。
- `lib/src/player/features/**`
  - 角色：把“手势/选集/字幕样式/切核”等高层能力拆成可复用模块（便于多内核复用）。

> 播放器拆分的更多细节与后续路线：`docs/PLAYER_MODULARIZATION.md`。

#### 1.5) 画质增强（Anime4K）
- `lib/src/player/anime4k.dart`：通过 mpv `glsl-shaders` 管线加载 Anime4K 预设（仅 MPV 内核）。
- Shader 资源位于 `assets/shaders/anime4k/`（来自 Anime4K：`https://github.com/bloc97/Anime4K`；具体版本与 License 见该目录 `README.md` / `LICENSE`）。
- 预设枚举与说明：`lib/state/anime4k_preferences.dart`。

#### 2) 本地播放（文件）
- `lib/player_screen.dart`
  - `FilePicker` 选择本地视频 → `PlayerService.initialize(path)`。
  - 支持：播放列表、进度条、10s 快进/快退、音轨/字幕切换、硬解/软解切换。
  - 弹幕：
    - `Video` 上方叠加 `DanmakuStage`（覆盖层渲染）。
    - 支持本地 XML 加载与在线加载（在线匹配使用文件名前 16MB 的 MD5 + 文件名）。

#### 3) Emby 在线播放（网络）
- `lib/play_network_page.dart`
  - 流程：
    1. `_buildStream()`：通过 `NetworkPlaybackBackend` 解析出可播放 URL + headers（内部会复用 `resolveEmbyStreamUrl(...)`）。
    2. `PlayerService.initialize(networkUrl, httpHeaders)`：
       - 关键 Header：`X-Emby-Token`、`X-Emby-Authorization`（以及 User-Agent）。
    3. 监听 buffering / error / tracks：
       - UI 展示缓冲进度。
       - 初始音轨/字幕偏好只应用一次（避免 tracks 更新时反复覆盖）。
    4. 播放上报：通过 `NetworkPlaybackReporter` 做节流上报（start/progress/stop + updatePosition）。
  - 弹幕：
    - `Video` 上方叠加 `DanmakuStage`（覆盖层渲染）。
    - 在线匹配默认仅使用标题/文件名（无法获取文件 Hash 时准确度可能下降）。

#### 4) Exo 播放内核（Android，可选）
- 入口：设置 → 播放 → 播放器内核（`PlayerCore.exo`）。
- 本地播放：`lib/player_screen_exo.dart`
  - 基于 `video_player`（Android 底层为 Media3 ExoPlayer）。
  - 默认使用 `VideoViewType.platformView`（用于规避部分 HDR/Dolby Vision 片源的颜色问题）。
  - 支持音轨/字幕切换：
    - 音轨：通过 `video_player_platform_interface` 的 `getAudioTracks/selectAudioTrack`（Android 支持）。
    - 字幕：通过本项目对 `video_player_android` 的补丁接口（支持枚举/选择/关闭）。
- 在线播放：`lib/play_network_page_exo.dart`
  - 仍通过 Emby 的 `AudioStreamIndex/SubtitleStreamIndex` 把“默认音轨/字幕”写入 URL；播放过程中也可再次切换。
  - 播放 URL + headers 构造通过 `NetworkPlaybackBackend`，播放上报通过 `NetworkPlaybackReporter`（便于未来接入更多“网络播放后端/播放内核”）。
- 实现与维护：
  - `packages/video_player_android_patched/lib/exo_tracks.dart`：对外暴露 Pigeon 生成的 Exo 字幕相关 API，避免直接 `import` 依赖包的 `lib/src`。
  - `packages/video_player_android_patched/android/.../PlatformVideoView.java`：Android 侧监听 `Player.Listener.onCues` 并叠加 `TextView` 显示字幕。
  - 如需升级 `video_player_android`，建议先阅读 `packages/video_player_android_patched/README_LINPLAYER.md`。

### 主要页面（UI）
- `lib/server_page.dart`：服务器管理（添加/编辑/删除/选择），并提供主题设置入口。
- `lib/home_page.dart`：主入口（底部导航：首页/媒体库/本地），含全局搜索与线路选择。
- `lib/library_page.dart`：媒体库列表（刷新、排序、显示/隐藏库）。
- `lib/library_items_page.dart`：媒体库内容列表（分页加载、进入详情）。
- `lib/show_detail_page.dart`：详情页（Series/Season/Episode 结构、相似推荐、章节、播放入口与可选媒体源/音轨/字幕）。
- `lib/danmaku_settings_page.dart`：弹幕设置页（本地/在线、在线源管理、样式设置）。
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

### Plex PIN 登录（仅保存）
1. `ServerPage` 选择 Plex → 调用 `PlexApi.createPin()`，并在外部浏览器打开 `buildAuthUrl(code)`。
2. App 轮询 `PlexApi.fetchPin(id)` 直到拿到 `authToken`。
3. 账号登录模式：`PlexApi.fetchResources(authToken)` 获取服务器列表 → 用户选择服务器 → `AppState.addPlexServer(...)` 保存。
4. 手动添加模式：用户填写服务器地址/端口 + Token → `AppState.addPlexServer(...)` 保存。

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
- **改 Emby/Jellyfin 接口/字段**：`lib/services/emby_api.dart`（必要时同步调整 `MediaItem` 字段解析）。
- **改 Plex PIN 登录/资源列表**：`lib/services/plex_api.dart`、`lib/server_page.dart`。
- **改缓存/状态/持久化**：`lib/state/app_state.dart`。
- **调播放器体验（硬解/缓冲/参数）**：`lib/player_service.dart`。
- **改主题/视觉规范**：`lib/src/ui/app_theme.dart`。

## 参考项目（灵感/对照实现）

- Anime4K：https://github.com/bloc97/Anime4K
- Playboy Player：https://github.com/Playboy-Player/Playboy
- NipaPlay Reload：https://github.com/MCDFsteve/NipaPlay-Reload
