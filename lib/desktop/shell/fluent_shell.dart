import 'package:fluent_ui/fluent_ui.dart';
import 'package:flutter/material.dart' as m;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/providers/app_providers.dart';
import 'desktop_content_gate.dart';
import 'desktop_nav_model.dart';

/// Windows 外壳：fluent_ui 的 [NavigationView]（仿 WinUI 左侧导航）。
///
/// - 收起状态由 [sidebarCollapsedProvider] 控制（标题栏汉堡按钮切换），
///   展开=expanded、收起=compact（仅图标）。
/// - 关闭 NavigationView 自带的内容切换动画，避免与 go_router 过渡叠加导致卡顿。
/// - 内容为 [StatefulNavigationShell]（indexedStack，保活）。
class FluentDesktopShell extends ConsumerWidget {
  final StatefulNavigationShell navigationShell;

  const FluentDesktopShell({super.key, required this.navigationShell});

  @override
  m.Widget build(m.BuildContext context, WidgetRef ref) {
    final collapsed = ref.watch(sidebarCollapsedProvider);
    final selectedIndex = navigationShell.currentIndex;
    final accent = FluentTheme.of(context).accentColor;

    return NavigationView(
      // 关键：禁用 NavigationView 自身的内容切换动画，交由 go_router 统一过渡，
      // 否则两层动画叠加会出现闪烁/不跟手。
      transitionBuilder: (child, animation) => child,
      pane: NavigationPane(
        selected: selectedIndex,
        onChanged: navigationShell.goBranch,
        // fluent_ui 默认 openWidth=320，对仅图标+短标签的导航来说右侧留白过多。
        // 收窄到 220（与 Material/macOS 外壳一致），更紧凑也更协调。
        size: const NavigationPaneSize(openWidth: 220),
        displayMode:
            collapsed ? PaneDisplayMode.compact : PaneDisplayMode.expanded,
        // 收起由标题栏汉堡按钮统一控制，隐藏 pane 内置的切换按钮避免重复。
        toggleButton: const m.SizedBox.shrink(),
        items: [
          for (final item in desktopNavItems)
            PaneItem(
              icon: m.Icon(item.icon, size: 18),
              selectedTileColor: WidgetStateProperty.all(
                accent.withValues(alpha: 0.14),
              ),
              title: m.Text(item.label),
              body: const m.SizedBox.shrink(),
            ),
        ],
        footerItems: [
          PaneItemWidgetAdapter(
            child: _ServerStatus(collapsed: collapsed),
          ),
        ],
      ),
      paneBodyBuilder: (item, child) => DesktopContentGate(
        index: navigationShell.currentIndex,
        child: navigationShell,
      ),
    );
  }
}

class _ServerStatus extends ConsumerWidget {
  final bool collapsed;

  const _ServerStatus({required this.collapsed});

  @override
  m.Widget build(m.BuildContext context, WidgetRef ref) {
    final currentServer = ref.watch(currentServerProvider);
    final authState = ref.watch(authStateProvider);
    if (currentServer == null) return const m.SizedBox.shrink();

    final isConnected = authState == AuthState.authenticated;
    final statusColor =
        isConnected ? const m.Color(0xFF4CAF50) : const m.Color(0xFFFFA726);

    final dot = m.Container(
      width: 8,
      height: 8,
      decoration: m.BoxDecoration(color: statusColor, shape: m.BoxShape.circle),
    );

    if (collapsed) {
      return m.Padding(
        padding: const m.EdgeInsets.symmetric(vertical: 10),
        child: m.Center(child: dot),
      );
    }

    return m.Padding(
      padding: const m.EdgeInsets.fromLTRB(14, 8, 12, 12),
      child: m.Row(
        children: [
          dot,
          const m.SizedBox(width: 8),
          m.Flexible(
            child: m.Text(
              currentServer.name,
              maxLines: 1,
              overflow: m.TextOverflow.ellipsis,
              style: m.TextStyle(
                fontSize: 12,
                color: FluentTheme.of(context).inactiveColor,
              ),
            ),
          ),
        ],
      ),
    );
  }
}
