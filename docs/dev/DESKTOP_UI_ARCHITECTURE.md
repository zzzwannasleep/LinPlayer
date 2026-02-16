# Desktop UI 架构与接入说明

> 适用于 `lib/desktop_ui/` 的桌面端 UI 专项重构实现。  
> 本文档只覆盖 UI/Desktop 层，不涉及 Core/Adapter/Playback 的重构。

## 1. 重构目标

- 仅重构桌面端 UI 层。
- 保持与现有 `AppState + ServerAdapter` 数据接口兼容。
- 不改变移动端页面与路由行为。
- 风格接近 Emby Desktop：低密度、大间距、面板分层、Hero 视觉。
- 组件模块化，避免巨型页面，便于长期维护。

## 2. 架构边界

必须保持：

- 不修改 `packages/lin_player_core`
- 不修改 `packages/lin_player_server_adapters`
- 不修改 `packages/lin_player_player`
- 不新增假服务器实现、不改 API 协议

桌面层允许：

- 新增桌面页面、组件、ViewModel
- 在桌面壳内部做导航编排与主题扩展
- 通过 `resolveServerAccess(...)` 访问现有适配器能力

## 3. 目录与职责

```text
lib/desktop_ui/
  desktop_shell.dart                 # 桌面入口壳 + 状态分流 + 桌面工作区
  pages/
    desktop_navigation_layout.dart   # Row: Sidebar + TopBar + Content
    desktop_library_page.dart        # 桌面库首页（继续观看/推荐/各媒体库）
    desktop_search_page.dart         # 桌面搜索页
    desktop_detail_page.dart         # 桌面详情页（Hero + 区块列表）
    desktop_server_page.dart         # 现有无服务器态页（保留）
    desktop_webdav_home_page.dart    # 现有 WebDAV 桌面页（保留）
  view_models/
    desktop_detail_view_model.dart   # 详情页数据装配与状态管理
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

## 4. 入口分流与路由接入

入口仍是 `main.dart -> DesktopShell(appState)`。

`DesktopShell` 分流逻辑：

1. 无活跃服务或 profile 不完整：进入 `DesktopServerPage`
2. `WebDAV`：进入 `DesktopWebDavHomePage`
3. Emby/Jellyfin/Plex：进入桌面工作区 `_DesktopWorkspace`

因此无需调整移动端路由。桌面重构对移动端是隔离的。

## 5. 桌面布局规范

主布局固定为：

```text
Row
 ├── DesktopSidebar (fixed width)
 └── Expanded
       ├── DesktopTopBar
       └── ContentArea
```

实现文件：`pages/desktop_navigation_layout.dart`。

支持能力：

- 宽屏与窗口拉伸（按可用宽度自适应）
- Hover 动画（`HoverEffectWrapper`）
- 键盘焦点导航（`FocusTraversalManager`）

## 6. 详情页设计（DesktopDetailPage）

详情页由 `DesktopDetailPage + DesktopDetailViewModel` 组成。

视觉结构：

- 深灰蓝背景与分层面板
- Hero 背景大图 + 渐变遮罩
- 左封面、右标题与元信息
- 播放按钮 + 收藏按钮
- 横向剧集列表、推荐列表、演员列表
- 卡片 hover 放大效果

数据来源：

- 输入为 `MediaItem`（seed）
- `DesktopDetailViewModel` 调用既有 adapter：
  - `fetchItemDetail`
  - `fetchSeasons`
  - `fetchEpisodes`
  - `fetchSimilar`
- 页面只消费 ViewModel 状态，不直接访问 Repository

## 7. 主题策略

- 新增 `DesktopThemeExtension` 提供桌面 token。
- 在 `DesktopShell` 内按需挂载 extension（`Theme.copyWith(extensions: ...)`）。
- 不修改全局 `AppTheme.light/dark` 定义，不影响移动端主题。

## 8. 可扩展点

- `DesktopShortcutWrapper`
  - 已预留 `shortcuts/actions/enabled`，可后续接全局快捷键。
- `WindowPaddingContainer`
  - 已预留窗口拖拽区事件，可后续接无边框窗口插件（如 `window_manager`）。
- `DesktopDetailViewModel`
  - 可继续扩展评分、标签、更多媒体源信息，而不影响页面结构。

## 9. 维护约定

- 页面尽量只做布局与事件分发；状态管理下沉至 `view_models/`。
- 横向媒体展示统一用 `DesktopMediaCard`。
- 新区块优先复用 `DesktopHorizontalSection`。
- 不在桌面页中硬编码服务器类型分支逻辑。
- 不在桌面层引入新的 API 调用协议。

## 10. 已实现文件清单（本次重构新增/更新）

新增：

- `lib/desktop_ui/pages/desktop_detail_page.dart`
- `lib/desktop_ui/pages/desktop_library_page.dart`
- `lib/desktop_ui/pages/desktop_navigation_layout.dart`
- `lib/desktop_ui/pages/desktop_search_page.dart`
- `lib/desktop_ui/theme/desktop_theme_extension.dart`
- `lib/desktop_ui/view_models/desktop_detail_view_model.dart`
- `lib/desktop_ui/widgets/desktop_action_button_group.dart`
- `lib/desktop_ui/widgets/desktop_hero_section.dart`
- `lib/desktop_ui/widgets/desktop_horizontal_section.dart`
- `lib/desktop_ui/widgets/desktop_media_card.dart`
- `lib/desktop_ui/widgets/desktop_media_meta.dart`
- `lib/desktop_ui/widgets/desktop_shortcut_wrapper.dart`
- `lib/desktop_ui/widgets/desktop_sidebar.dart`
- `lib/desktop_ui/widgets/desktop_sidebar_item.dart`
- `lib/desktop_ui/widgets/desktop_top_bar.dart`
- `lib/desktop_ui/widgets/focus_traversal_manager.dart`
- `lib/desktop_ui/widgets/hover_effect_wrapper.dart`
- `lib/desktop_ui/widgets/window_padding_container.dart`

更新：

- `lib/desktop_ui/desktop_shell.dart`
- `lib/desktop_ui/README.md`

