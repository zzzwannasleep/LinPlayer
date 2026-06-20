import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:macos_ui/macos_ui.dart';

import '../../core/providers/app_providers.dart';
import 'desktop_content_gate.dart';
import 'desktop_nav_model.dart';

const double _kSidebarWidth = 220;
const double _kSidebarCollapsedWidth = 68;

/// macOS 外壳：使用 macos_ui 主题令牌构建的原生风格侧边栏。
///
/// 不使用 [MacosWindow]（它会接管整窗，与本应用的全屏路由冲突），而是以
/// [MacosTheme] 的颜色/强调色还原 AppKit 侧边栏观感：半透明背景、圆角选中态。
/// 内容为 [StatefulNavigationShell]（indexedStack，保活）。
class MacosDesktopShell extends ConsumerWidget {
  final StatefulNavigationShell navigationShell;

  const MacosDesktopShell({super.key, required this.navigationShell});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = MacosTheme.of(context);
    final collapsed = ref.watch(sidebarCollapsedProvider);
    final selectedIndex = navigationShell.currentIndex;
    final isDark = theme.brightness == Brightness.dark;

    final sidebarColor = isDark
        ? const Color(0xFF2A2A2C).withValues(alpha: 0.92)
        : const Color(0xFFF2F2F4).withValues(alpha: 0.92);
    final dividerColor =
        isDark ? const Color(0x33FFFFFF) : const Color(0x14000000);

    return Row(
      children: [
        Container(
          width: collapsed ? _kSidebarCollapsedWidth : _kSidebarWidth,
          decoration: BoxDecoration(
            color: sidebarColor,
            border: Border(right: BorderSide(color: dividerColor, width: 0.5)),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              const SizedBox(height: 12),
              Expanded(
                child: ListView.builder(
                  padding: const EdgeInsets.symmetric(horizontal: 10),
                  itemCount: desktopNavItems.length,
                  itemBuilder: (context, index) {
                    final item = desktopNavItems[index];
                    return _MacosNavTile(
                      item: item,
                      selected: index == selectedIndex,
                      accent: theme.primaryColor,
                      isDark: isDark,
                      collapsed: collapsed,
                      onTap: () => navigationShell.goBranch(index),
                    );
                  },
                ),
              ),
              if (!collapsed) _ServerStatus(isDark: isDark),
              const SizedBox(height: 12),
            ],
          ),
        ),
        Expanded(
          child: Container(
            color: theme.canvasColor,
            child: DesktopContentGate(
              index: navigationShell.currentIndex,
              child: navigationShell,
            ),
          ),
        ),
      ],
    );
  }
}

class _MacosNavTile extends StatefulWidget {
  final DesktopNavItem item;
  final bool selected;
  final Color accent;
  final bool isDark;
  final bool collapsed;
  final VoidCallback onTap;

  const _MacosNavTile({
    required this.item,
    required this.selected,
    required this.accent,
    required this.isDark,
    required this.collapsed,
    required this.onTap,
  });

  @override
  State<_MacosNavTile> createState() => _MacosNavTileState();
}

class _MacosNavTileState extends State<_MacosNavTile> {
  bool _hovered = false;

  @override
  Widget build(BuildContext context) {
    final selected = widget.selected;
    final Color bg;
    if (selected) {
      bg = widget.accent;
    } else if (_hovered) {
      bg = widget.isDark
          ? Colors.white.withValues(alpha: 0.06)
          : Colors.black.withValues(alpha: 0.05);
    } else {
      bg = Colors.transparent;
    }
    final fg = selected
        ? Colors.white
        : widget.isDark
            ? const Color(0xFFE3E3E6)
            : const Color(0xFF1D1D1F);

    return Padding(
      padding: const EdgeInsets.only(bottom: 2),
      child: MouseRegion(
        cursor: SystemMouseCursors.click,
        onEnter: (_) => setState(() => _hovered = true),
        onExit: (_) => setState(() => _hovered = false),
        child: GestureDetector(
          onTap: widget.onTap,
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 7),
            decoration: BoxDecoration(
              color: bg,
              borderRadius: BorderRadius.circular(7),
            ),
            child: widget.collapsed
                ? Tooltip(
                    message: widget.item.label,
                    child: Icon(
                      selected ? widget.item.selectedIcon : widget.item.icon,
                      size: 17,
                      color: fg,
                    ),
                  )
                : Row(
                    children: [
                      Icon(
                        selected ? widget.item.selectedIcon : widget.item.icon,
                        size: 17,
                        color: fg,
                      ),
                      const SizedBox(width: 9),
                      Text(
                        widget.item.label,
                        style: TextStyle(
                          fontSize: 13,
                          fontWeight:
                              selected ? FontWeight.w600 : FontWeight.w500,
                          color: fg,
                        ),
                      ),
                    ],
                  ),
          ),
        ),
      ),
    );
  }
}

class _ServerStatus extends ConsumerWidget {
  final bool isDark;

  const _ServerStatus({required this.isDark});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final currentServer = ref.watch(currentServerProvider);
    final authState = ref.watch(authStateProvider);
    if (currentServer == null) return const SizedBox.shrink();

    final isConnected = authState == AuthState.authenticated;
    final statusColor =
        isConnected ? const Color(0xFF4CAF50) : const Color(0xFFFFA726);

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16),
      child: Row(
        children: [
          Container(
            width: 8,
            height: 8,
            decoration: BoxDecoration(color: statusColor, shape: BoxShape.circle),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              currentServer.name,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                fontSize: 12,
                color: isDark ? const Color(0xFFAAAAAA) : const Color(0xFF666666),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
