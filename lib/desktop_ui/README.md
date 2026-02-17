# Desktop UI

`lib/desktop_ui/` 是 LinPlayer 桌面端（Windows/macOS）UI 实现目录。

## 1. 边界

- 只负责桌面端页面编排、组件和交互体验。
- 数据来源统一走 `AppState` 与 `ServerAccess`。
- 不在此目录新增底层协议或服务端实现。

## 2. 入口与分流

- 入口壳：`lib/desktop_ui/desktop_shell.dart`
- 分流逻辑：
  - 无可用服务器：`pages/desktop_server_page.dart`
  - WebDAV：`pages/desktop_webdav_home_page.dart`
  - Emby/Jellyfin：桌面工作区（Library/Search/Detail）

## 3. 核心目录

```text
lib/desktop_ui/
  desktop_shell.dart
  pages/
  widgets/
  view_models/
  theme/
  models/
```

## 4. 关键页面

- `pages/desktop_library_page.dart`
  - 媒体库首页
  - 继续观看分区（本地缓存优先显示，后台刷新云端）
  - 收藏模式
- `pages/desktop_search_page.dart`
  - 桌面搜索结果
- `pages/desktop_detail_page.dart`
  - 详情页 Hero、选集、外链、媒体流信息

## 5. 关键组件

- `widgets/desktop_top_bar.dart`
  - 顶栏、搜索、线路管理、设置
- `widgets/desktop_sidebar.dart`
  - 服务器列表侧边栏（图标 + 名称 + 副标题）
- `widgets/desktop_media_card.dart`
  - 通用媒体卡片（封面、进度、收藏、标题/副标题）

## 6. 当前交互规范（2026-02）

- 顶栏随内容滚动渐隐，停止滚动后吸附显示/隐藏。
- 顶栏取消外层边框线，避免视觉割裂。
- “我的媒体”改为“媒体库”，改为单行横向可滚动。
- 点击媒体库卡片时，卡片会自动滚动到视口中间。
- 选集横向列表支持自动居中：
  - 进入页面会把当前集尽量居中；
  - 点击某一集会先居中，再跳转该集。
- 各分区标题移除“最新”前缀。
- 继续观看卡片优化：
  - 16:9 集封面比例；
  - 去掉右上角角标；
  - 两行文案（剧集：剧名 + `SxxExx | 时间`；电影：片名 + 时间）。
- 电影详情不显示“选集”区块，但保留视频/音频/字幕选择。

## 7. 主题规范

- 统一使用 `theme/desktop_theme_extension.dart` 中的 token。
- 详情页与列表页都需适配深色/浅色两套配色。
- 避免在组件内新增硬编码亮色/暗色常量。

## 8. 开发建议

- 新增桌面页面优先复用 `DesktopMediaCard`、`DesktopTopBar`、`DesktopSidebar`。
- 状态复杂逻辑优先下沉到 `view_models/` 或 `AppState`，页面只做展示和交互分发。
- 新交互改动后执行：
  - `dart format lib/desktop_ui`
  - `flutter analyze`

## 9. 详细架构文档

- `docs/dev/DESKTOP_UI_ARCHITECTURE.md`
