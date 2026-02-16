# Desktop UI

桌面端 UI 专项重构层（Windows/macOS），只负责桌面页面组织与视觉组件。

## 1. 边界

本目录遵循以下边界：

- 不修改 Core 层（`packages/lin_player_core`）
- 不修改 Adapter 层（`packages/lin_player_server_adapters`）
- 不修改 Playback 层（`packages/lin_player_player` 与播放页逻辑）
- 不改变现有数据接口（仍通过 `AppState` + `ServerAccess`）
- 不影响移动端入口与页面

## 2. 入口与路由

- 桌面入口：`lib/desktop_ui/desktop_shell.dart`
- 应用主入口在 `lib/main.dart`，当 `DesktopShell.isDesktopTarget == true` 时进入桌面壳。
- `DesktopShell` 内部分流：
  - 无活跃服务：`pages/desktop_server_page.dart`
  - WebDAV：`pages/desktop_webdav_home_page.dart`
  - Emby/Jellyfin/Plex：桌面导航工作区（Library / Search / Detail）

## 3. 布局结构

桌面主布局由 `pages/desktop_navigation_layout.dart` 提供，固定为：

```text
Row
 ├── Sidebar（固定宽度）
 └── Expanded
       ├── TopBar
       └── ContentArea
```

不复用移动端 `Scaffold` 导航模式。

## 4. 目录结构

```text
lib/desktop_ui/
  desktop_shell.dart
  pages/
    desktop_navigation_layout.dart
    desktop_library_page.dart
    desktop_search_page.dart
    desktop_detail_page.dart
    desktop_server_page.dart
    desktop_webdav_home_page.dart
  view_models/
    desktop_detail_view_model.dart
  widgets/
    desktop_sidebar.dart
    desktop_sidebar_item.dart
    desktop_top_bar.dart
    desktop_media_card.dart
    desktop_horizontal_section.dart
    desktop_hero_section.dart
    desktop_action_button_group.dart
    hover_effect_wrapper.dart
    focus_traversal_manager.dart
    desktop_shortcut_wrapper.dart
    window_padding_container.dart
    desktop_media_meta.dart
  theme/
    desktop_theme_extension.dart
```

## 5. 关键组件职责

- `DesktopSidebar` / `DesktopSidebarItem`
  - 左侧导航、选中态、禁用态、服务器信息显示。
- `DesktopTopBar`
  - 页面标题、统一搜索入口、刷新/设置动作。
- `DesktopMediaCard`
  - 统一媒体卡片（海报、类型、元信息、进度条、hover 动画）。
- `DesktopHorizontalSection`
  - 横向列表区块容器（标题、副标题、空态）。
- `DesktopHeroSection`
  - 详情页顶部 Hero 区（Backdrop + 渐变 + 左封面 + 右元信息）。
- `DesktopActionButtonGroup`
  - 详情页动作按钮（播放、收藏）。

## 6. 桌面增强能力

- `HoverEffectWrapper`
  - 统一 hover/focus 动画与视觉反馈。
- `FocusTraversalManager`
  - 键盘焦点遍历（方向键、Tab/Shift+Tab）。
- `DesktopShortcutWrapper`
  - 全局快捷键预留接口（当前默认不启用）。
- `WindowPaddingContainer`
  - 无边框窗口拖拽区预留容器（当前仅预留事件口）。

## 7. 数据流约束

桌面页不直接访问 Repository，不自建 API 层：

- 列表页（Library/Search）通过 `AppState` 与 `resolveServerAccess(...)` 获取数据。
- 详情页通过 `DesktopDetailViewModel` 拉取：
  - `fetchItemDetail`
  - `fetchSeasons`
  - `fetchEpisodes`
  - `fetchSimilar`
- 详情页只消费 `ViewModel/Model`，不绑定服务器类型分支。

## 8. 主题扩展

- `DesktopThemeExtension` 提供桌面专属 token（背景、表面、边框、强调色、hover/focus）。
- 以 `ThemeData.extension` 方式挂载，仅在桌面壳生效，不改移动端主题配置。

## 9. 开发建议

- 新增桌面页面优先复用 `DesktopMediaCard` / `DesktopHorizontalSection`。
- 复杂页面状态放入 `view_models/`，避免页面文件膨胀。
- 新能力先加在 `widgets/` 独立组件，再由页面组装。
- 保持桌面层只做 UI 与编排，不下沉到核心业务层。

## 10. 详细文档

完整设计与接入文档见：

- `docs/dev/DESKTOP_UI_ARCHITECTURE.md`
