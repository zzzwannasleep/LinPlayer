# LinPlayer 架构说明（Architecture）

> 面向二次开发与排障的开发者文档。本文以当前 `main` 分支代码结构为准。

## 1. 文档目标

- 快速理解项目的“分层边界”和“关键调用链”。
- 明确每个目录/模块该放什么，不该放什么。
- 为后续新增服务器类型、播放能力、TV 能力提供落点参考。

## 2. 架构总览

LinPlayer 采用“页面层 + 状态层 + 适配层 + API 层 + 播放层 + 平台服务层”的结构：

```text
Flutter 页面(lib/*.dart)
  -> AppState (packages/lin_player_state)
    -> Server Adapter (packages/lin_player_server_adapters)
      -> API Client (packages/lin_player_server_api)
        -> Emby/Jellyfin/WebDAV/Plex 等服务

播放页(lib/player_screen*.dart, lib/play_network_page*.dart)
  -> lin_player_player (PlayerService / Danmaku / 播放控制)
    -> media_kit(mpv) 或 video_player_android(Exo)
```

## 3. 顶层目录职责

- `.github/`
  - CI/CD、Nightly/Latest 发布流程、安装包脚本。
- `assets/`
  - 图标、Anime4K shader、TV 代理资源、TV 远程网页静态资源。
- `lib/`
  - Flutter 业务页面与应用编排（入口、路由、页面、平台服务 glue）。
- `packages/`
  - 模块化后的核心包（state/ui/player/server/api/core/prefs）与 patched 依赖。
- `docs/`
  - 用户与开发文档。
- `tool/`
  - 构建辅助脚本（如 TV 代理资源拉取）。
- `workers/`
  - 辅助 Worker（当前有 `workers/dandanplay-proxy`）。

## 4. 分层说明

### 4.1 页面与编排层（`lib/`）

入口：`lib/main.dart`

职责：
- 初始化媒体后端（`MediaKit.ensureInitialized()`）。
- 初始化设备信息与 User-Agent（`ServerApiBootstrap.configure(...)`）。
- 加载全局状态（`AppState.loadFromStorage()`）。
- 根据设备类型与当前服务类型，选择 Home 壳：
  - TV：`lib/tv/tv_shell.dart`
  - Desktop：`lib/desktop_ui/desktop_shell.dart`
  - Mobile/Tablet：`lib/home_page.dart` 或 `lib/webdav_home_page.dart`

关键页面：
- 服务管理：`lib/server_page.dart`
- 首页与库：`lib/home_page.dart`、`lib/library_page.dart`、`lib/library_items_page.dart`
- 详情页：`lib/show_detail_page.dart`
- 播放页：
  - MPV：`lib/player_screen.dart`、`lib/play_network_page.dart`
  - Exo：`lib/player_screen_exo.dart`、`lib/play_network_page_exo.dart`
- WebDAV：首页壳与浏览器：`lib/webdav_home_page.dart`、`lib/webdav_browser_page.dart`
- 聚合检索：`lib/aggregate_service_page.dart`

### 4.2 状态层（`packages/lin_player_state`）

核心：`packages/lin_player_state/lib/app_state.dart`

职责：
- 全局状态中心（`ChangeNotifier`）。
- 持久化（SharedPreferences）与缓存（库缓存、首页缓存、播放偏好、弹幕偏好、TV 偏好等）。
- 服务管理流程：
  - `addServer(...)`（Emby/Jellyfin）
  - `addWebDavServer(...)`
  - `addPlexServer(...)`
  - `enterServer(...)` / `leaveServer()`
- 数据加载流程：`loadItems(...)`、`loadHome(...)`、`loadMediaStats(...)`

相关模型：
- `packages/lin_player_state/lib/server_profile.dart`
- `packages/lin_player_state/lib/local_playback_handoff.dart`
- `packages/lin_player_state/lib/route_entries.dart`

### 4.3 适配层（`packages/lin_player_server_adapters`）

核心接口：`packages/lin_player_server_adapters/lib/server_adapters/server_adapter.dart`

职责：
- 定义统一服务能力接口 `MediaServerAdapter`，对页面层屏蔽服务端差异。
- 在工厂 `server_adapter_factory.dart` 中按产品线选择具体适配器实现。

现有实现：
- `lin/lin_emby_adapter.dart`（Emby/Jellyfin 主实现）
- `emos/emos_adapter.dart`
- `uhd/uhd_adapter.dart`

页面侧统一接入点：
- `lib/server_adapters/server_access.dart`（`resolveServerAccess(...)`）

### 4.4 API 层（`packages/lin_player_server_api`）

主要文件：
- `services/emby_api.dart`
- `services/plex_api.dart`
- `services/webdav_api.dart`
- `services/webdav_proxy.dart`
- `services/server_share_text_parser.dart`
- `network/lin_http_client.dart`

职责：
- 原始 HTTP 能力与协议细节（header、鉴权、重试、fallback）。
- 业务接口封装：鉴权、列表、详情、播放信息、播放上报、章节、相似推荐等。

说明：
- Emby/Jellyfin 共用 `EmbyApi`（通过 `MediaServerType` 区分 header 与 prefix 策略）。
- WebDAV 负责目录列举与鉴权处理（含 Digest/Basic）。
- Plex 负责 PIN 登录和服务器资源发现（当前项目中主要是“登录与保存服务器信息”）。

### 4.5 播放层（`packages/lin_player_player`）

主要文件：
- `player_service.dart`：MPV 播放能力封装。
- `src/player/playback_controls.dart`：播放控制 UI 复用组件。
- `src/player/danmaku_stage.dart` + `danmaku*.dart`：弹幕管线。
- `src/player/anime4k.dart`：Anime4K shader 管线。
- `dandanplay_api.dart`：在线弹幕匹配与下载。

说明：
- MPV 路径使用 `media_kit`。
- Exo 路径使用 `video_player_android`（并通过 patched 包增强轨道能力）。

### 4.6 UI 基建层（`packages/lin_player_ui`）

主要文件：
- `src/ui/app_theme.dart`、`theme_sheet.dart`、`ui_scale.dart`
- `src/ui/glass_background.dart`、`frosted_card.dart`
- `src/ui/app_components.dart`、`rating_badge.dart` 等

职责：
- 统一主题、风格模板、缩放与基础组件。
- 保证页面层不重复实现公共视觉逻辑。

### 4.7 配置与偏好层（`packages/lin_player_prefs`）

主要文件：
- `preferences.dart`
- `interaction_preferences.dart`
- `danmaku_preferences.dart`
- `anime4k_preferences.dart`

职责：
- 偏好枚举、配置模型定义（供 `AppState` 与 UI 使用）。

### 4.8 核心配置层（`packages/lin_player_core`）

主要文件：
- `app_config/app_config.dart`
- `app_config/app_feature_flags.dart`
- `app_config/app_product.dart`
- `state/media_server_type.dart`

职责：
- 产品线差异（`lin/emos/uhd`）
- 功能开关（允许的 server type）
- 基础枚举与全局配置上下文

## 5. patched 依赖说明

- `packages/media_kit_patched`
  - 为 MPV 路径提供更细粒度参数传递能力。
- `packages/video_player_android_patched`
  - 增强 Exo 轨道相关能力（音轨/字幕轨选择等）。

`pubspec.yaml` 中通过 `dependency_overrides` 强制覆盖到项目内 patched 包。

## 6. 关键业务链路

### 6.1 启动链路

1. `main.dart` 初始化媒体内核、设备信息、AppConfig。
2. `AppState.loadFromStorage()` 恢复服务、主题、偏好、缓存。
3. 根据设备类型进入 `TvShell` / `DesktopShell` / 普通 Home。
4. 启动可选服务：TV Remote、Built-in Proxy、自动更新检查。

### 6.2 添加服务器链路

页面：`lib/server_page.dart`

- Emby/Jellyfin：`AppState.addServer(...)`
  - 内部通过 adapter/API 完成鉴权与基础信息拉取。
- WebDAV：`AppState.addWebDavServer(...)`
- Plex：
  - 账号授权流（PIN）+ 资源选择，或手动填 token。
  - 最终进入 `AppState.addPlexServer(...)`。

### 6.3 首页/列表加载链路

1. 页面触发 `AppState.loadHome()` / `loadItems(...)`。
2. `AppState` 使用当前 active server 构建访问上下文。
3. 调 adapter 拉取数据并写入本地缓存。
4. `notifyListeners()` 驱动 UI 更新。

### 6.4 播放链路（网络媒体）

入口：`show_detail_page.dart` / 列表页 -> `play_network_page*.dart`

1. 通过 `resolveServerAccess(...)` 获取 `adapter + auth`。
2. `fetchPlaybackInfo(...)` 获取 `PlaySessionId/MediaSources`。
3. 组装流 URL 与 header，交给 MPV 或 Exo 播放。
4. 播放期间上报：
  - `reportPlaybackStart`
  - `reportPlaybackProgress`
  - `reportPlaybackStopped`
  - `updatePlaybackPosition`

### 6.5 播放链路（本地文件/WebDAV）

- 本地：`player_screen*.dart` 直接从本地路径建立播放列表。
- WebDAV：`webdav_browser_page.dart`
  - 先通过 `webdav_proxy.dart` 注册本地代理 URL。
  - 再把 URL 作为本地播放队列交给播放器。

### 6.6 弹幕链路

1. 播放页叠加 `DanmakuStage`。
2. 数据来源：本地 XML 或在线（`dandanplay_api.dart`）。
3. 渲染参数来自 `AppState`（透明度、字号、速度、去重、防遮挡等）。

### 6.7 TV 专项链路

- TV 遥控网页：`tv_remote_service.dart`
  - 内置 HTTP + WebSocket 服务，提供移动端控制入口。
- TV 内置代理：`built_in_proxy_service.dart`
  - 管理 mihomo 进程、配置生成、代理规则及 UI 面板资源。

## 7. 平台与壳层

### 7.1 Desktop 壳层

目录：`lib/desktop_ui/`

职责：
- 提供桌面端独立壳与页面组织。
- 与移动端共享状态层、适配层、API 层。

### 7.2 TV 壳层

目录：`lib/tv/`

职责：
- TV 首页、背景模式、首启向导、遥控操作体验。

## 8. 数据与持久化策略

持久化入口：`AppState`（SharedPreferences）

典型内容：
- 当前服务与服务器列表。
- 主题、缩放、交互手势、播放器偏好。
- 弹幕偏好、TV 偏好、自动更新设置。
- 轻量缓存：库列表、首页区块、部分统计信息。

## 9. 扩展指南

### 9.1 新增一个服务端类型

建议步骤：
1. 在 `lin_player_core` 扩展 `MediaServerType` 与 FeatureFlag。
2. 在 `lin_player_server_api` 新增 API 客户端。
3. 在 `lin_player_server_adapters` 实现新的 Adapter。
4. 在 `ServerAdapterFactory` 与 `server_page.dart` 接入。
5. 在 `AppState` 补充服务保存/切换逻辑。

### 9.2 新增播放能力

建议步骤：
1. 优先落在 `lin_player_player`（而不是页面直接写）。
2. 页面层只做参数编排与状态展示。
3. 涉及平台特性时，通过 patched 包或平台通道落地。

### 9.3 新增 UI 模板或全局视觉能力

建议步骤：
1. 在 `lin_player_ui` 扩展主题/样式模型。
2. 由 `AppState` 持久化模板/参数。
3. 页面层仅消费，不重复定义 token。

## 10. 调试与维护建议

- 静态检查：`flutter analyze`
- 测试：`flutter test`
- 平台构建前先确认：`flutter doctor -v`
- 对外接口异常优先查：
  - 当前 active server 信息
  - Adapter 选型是否正确
  - API prefix / token / userId 是否一致
- 播放异常优先查：
  - `fetchPlaybackInfo` 返回的 `MediaSources`
  - 选中的音轨/字幕索引
  - MPV/Exo 内核是否匹配当前片源

## 11. 相关文档

- `docs/dev/README.md`
- `docs/dev/ANDROID_SIGNING.md`
- `docs/dev/TV_PROXY_ROADMAP.md`
- `docs/SERVER_IMPORT.md`

---

如果你准备继续模块化重构，建议下一步先统一：
- 页面层对 `AppState` 的直接读写边界
- 播放页的共享 ViewModel/Controller 抽象
- 详情页（剧/集）的公共组件拆分
