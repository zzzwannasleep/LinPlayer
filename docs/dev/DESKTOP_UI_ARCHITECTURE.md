# Desktop UI 架构说明

本文档描述 `lib/desktop_ui/` 的桌面端 UI 架构、关键交互和开发约束。

适用范围：

- Windows / macOS 桌面端 UI
- 页面编排、组件组织、主题扩展、交互规则

不在本文档范围：

- Core/Adapter/Player 协议重构
- 移动端（Android/iOS）页面设计

---

## 1. 架构边界

桌面层只做 UI 与交互，不改底层协议：

- Core：`packages/lin_player_core`
- Adapter：`packages/lin_player_server_adapters`
- State：`packages/lin_player_state`
- Player：`packages/lin_player_player`

桌面层通过 `AppState` + `resolveServerAccess(...)` 获取数据，不直接 new 服务端 API 客户端。

---

## 2. 入口与路由分流

入口文件：`lib/desktop_ui/desktop_shell.dart`

分流规则：

1. 没有可用服务器 -> `pages/desktop_server_page.dart`
2. 当前为 WebDAV -> `pages/desktop_webdav_home_page.dart`
3. Emby/Jellyfin -> 桌面工作区 `_DesktopWorkspace`

工作区内部页面状态：

- Library：`pages/desktop_library_page.dart`
- Search：`pages/desktop_search_page.dart`
- Detail：`pages/desktop_detail_page.dart`

---

## 3. 布局模型

主布局组件：`pages/desktop_navigation_layout.dart`

结构：

- 顶部：TopBar
- 左侧：可折叠/浮层 Sidebar（服务器列表）
- 主区：内容页（Library/Search/Detail）

新增行为：

- 支持 `topBarVisibility`（0~1）
- 顶栏随滚动渐隐，滚动结束后吸附为全显/全隐

---

## 4. 主题系统

主题扩展：`theme/desktop_theme_extension.dart`

要求：

- 使用统一 token（background/surface/text/border/accent 等）
- 深色/浅色均可读
- 新组件禁止硬编码白底或黑底

---

## 5. 数据流与状态

### 5.1 首页与详情数据

- 首页：`desktop_library_page.dart` 使用 `AppState` 的 libraries/home/continueWatching 数据
- 详情：`desktop_detail_page.dart` 通过 `DesktopDetailViewModel` 拉取 detail、episodes、playbackInfo 等

### 5.2 继续观看（本地优先）

状态在 `packages/lin_player_state/lib/app_state.dart`：

- 每服务器缓存 continue watching
- 页面先渲染本地缓存，避免首屏闪烁
- 后台强制刷新云端后与本地合并
- 合并规则按条目键去重（剧集按 series 优先），并优先保留“未看完 + 更大进度”

---

## 6. 组件职责

### 6.1 `desktop_top_bar.dart`

- 左：菜单/返回、应用标识、当前服务器与资源统计
- 中：搜索框或首页 Tab
- 右：搜索、线路管理、设置、刷新

说明：

- 已移除投屏入口
- 已移除外层边框线

### 6.2 `desktop_sidebar.dart` + `desktop_sidebar_item.dart`

- 仅承担服务器选择
- 每行：服务器图标 + 名称 + 副标题
- 点击切服并进入桌面主区

### 6.3 `desktop_media_card.dart`

- 通用封面卡片
- 支持进度条、收藏、角标
- 支持 `titleOverride` / `subtitleOverride` / `subtitleMaxLines` 以适配继续观看等专用场景

---

## 7. 页面交互规范（当前版本）

### 7.1 Library 页

文件：`pages/desktop_library_page.dart`

- “我的媒体”已改为“媒体库”
- 媒体库列表改为单行横向滚动
- 点击某个媒体库卡片会自动滚动到视口中间
- 各分区标题移除“最新”前缀

继续观看区：

- 卡片比例改为 16:9
- 去掉右上角角标
- 文案两行：
  - 剧集：`剧名` + `SxxExx | 时间`
  - 电影：`片名` + `时间`

### 7.2 Detail 页

文件：`pages/desktop_detail_page.dart`

- 选集横向列表支持自动居中：
  - 初次进入时当前集居中
  - 点击某一集后自动居中该集
- 电影详情不展示“选集”区块
- 电影与剧集都展示视频/音频/字幕选择区

### 7.3 TopBar 行为

文件：`desktop_shell.dart` + `desktop_navigation_layout.dart`

- 内容区滚动时，顶栏按滚动距离逐步隐藏/出现
- 滚动停止后自动吸附到全显/全隐状态

---

## 8. 目录结构（当前）

```text
lib/desktop_ui/
  desktop_shell.dart
  models/
    desktop_ui_language.dart
  pages/
    desktop_continue_watching_page.dart
    desktop_detail_page.dart
    desktop_favorites_items_page.dart
    desktop_library_page.dart
    desktop_navigation_layout.dart
    desktop_search_page.dart
    desktop_server_page.dart
    desktop_ui_settings_page.dart
    desktop_webdav_home_page.dart
  theme/
    desktop_theme_extension.dart
  view_models/
    desktop_detail_view_model.dart
  widgets/
    desktop_media_card.dart
    desktop_sidebar.dart
    desktop_sidebar_item.dart
    desktop_top_bar.dart
    ...
```

注：`desktop_home_page.dart` / `desktop_root_page.dart` 属于旧路径，当前桌面主流程以 `desktop_shell.dart` 为准。

---

## 9. 开发约束与评审清单

提交桌面 UI 改动前至少检查：

1. 深浅色模式都可读，无突兀反差
2. 顶栏、侧栏、详情页行为符合交互规范
3. 继续观看不会出现“先空再闪现”
4. 电影与剧集详情行为一致性符合预期
5. `dart format` 与 `flutter analyze` 通过

---

## 10. 常用命令

```bash
dart format lib/desktop_ui
flutter analyze
```
