import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import '../../core/providers/app_providers.dart';
import '../platform/desktop_ui_style.dart';
import 'desktop_content_gate.dart';
import 'desktop_nav_model.dart';
import 'fluent_shell.dart';
import 'macos_shell.dart';

/// 桌面端外壳调度器：按平台选择原生导航外壳，并共享“恢复上次服务器”的逻辑。
///
/// 主体内容为 [StatefulNavigationShell]（indexedStack），各一级 Tab 保活，
/// 切换时不重建、不重新拉取/解码，从而消除切页卡顿与海报“刷新”。
class DesktopShell extends ConsumerStatefulWidget {
  final StatefulNavigationShell navigationShell;

  const DesktopShell({super.key, required this.navigationShell});

  @override
  ConsumerState<DesktopShell> createState() => _DesktopShellState();
}

class _DesktopShellState extends ConsumerState<DesktopShell> {
  bool _hasAttemptedRestore = false;

  @override
  Widget build(BuildContext context) {
    final servers = ref.watch(serverListProvider);
    final currentServer = ref.watch(currentServerProvider);

    if (servers.isNotEmpty && currentServer == null && !_hasAttemptedRestore) {
      _hasAttemptedRestore = true;
      Future.microtask(() async {
        await ref.read(currentServerProvider.notifier).loadFromSaved(servers);
      });
    }

    switch (desktopUiStyle) {
      case DesktopUiStyle.fluent:
        return FluentDesktopShell(navigationShell: widget.navigationShell);
      case DesktopUiStyle.macos:
        return MacosDesktopShell(navigationShell: widget.navigationShell);
      case DesktopUiStyle.material:
        return MaterialDesktopShell(navigationShell: widget.navigationShell);
    }
  }
}

const double _kSidebarWidth = 220;
const double _kSidebarCollapsedWidth = 72;

/// Linux 外壳：Material 侧边栏（保留原桌面端外观）。
class MaterialDesktopShell extends ConsumerWidget {
  final StatefulNavigationShell navigationShell;

  const MaterialDesktopShell({super.key, required this.navigationShell});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final collapsed = ref.watch(sidebarCollapsedProvider);
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final selectedIndex = navigationShell.currentIndex;
    final sidebarWidth = collapsed ? _kSidebarCollapsedWidth : _kSidebarWidth;

    return Scaffold(
      body: Row(
        children: [
          AnimatedContainer(
            duration: const Duration(milliseconds: 160),
            curve: Curves.fastOutSlowIn,
            width: sidebarWidth,
            decoration: BoxDecoration(
              color: isDark ? const Color(0xFF1E1E1E) : const Color(0xFFF8F9FA),
              border: Border(
                right: BorderSide(
                  color: isDark
                      ? const Color(0xFF333333)
                      : const Color(0xFFE8EAED),
                  width: 1,
                ),
              ),
            ),
            child: Column(
              children: [
                SizedBox(height: collapsed ? 12 : 20),
                Expanded(
                  child: ListView.builder(
                    padding: const EdgeInsets.symmetric(horizontal: 12),
                    itemCount: desktopNavItems.length,
                    itemBuilder: (context, index) {
                      return _buildNavItem(
                        context,
                        desktopNavItems[index],
                        index == selectedIndex,
                        isDark,
                        collapsed,
                        () => navigationShell.goBranch(index),
                      );
                    },
                  ),
                ),
                _ServerStatusTile(isDark: isDark, collapsed: collapsed),
                const SizedBox(height: 16),
              ],
            ),
          ),
          Expanded(
            child: Container(
              color: Theme.of(context).scaffoldBackgroundColor,
              child: DesktopContentGate(
                index: navigationShell.currentIndex,
                child: navigationShell,
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildNavItem(
    BuildContext context,
    DesktopNavItem item,
    bool isSelected,
    bool isDark,
    bool collapsed,
    VoidCallback onTap,
  ) {
    final theme = Theme.of(context);
    final bgColor = isSelected
        ? const Color(0xFF5B8DEF).withValues(alpha: 0.15)
        : Colors.transparent;
    final iconColor = isSelected
        ? const Color(0xFF5B8DEF)
        : isDark
            ? const Color(0xFFAAAAAA)
            : const Color(0xFF666666);
    final textColor = isSelected
        ? const Color(0xFF5B8DEF)
        : isDark
            ? const Color(0xFFFFFFFF)
            : const Color(0xFF1A1A1A);

    return Padding(
      padding: const EdgeInsets.only(bottom: 4),
      child: MouseRegion(
        cursor: SystemMouseCursors.click,
        child: GestureDetector(
          onTap: onTap,
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 120),
            curve: Curves.fastOutSlowIn,
            padding: EdgeInsets.symmetric(
              horizontal: collapsed ? 0 : 14,
              vertical: 10,
            ),
            decoration: BoxDecoration(
              color: bgColor,
              borderRadius: BorderRadius.circular(10),
            ),
            child: collapsed
                ? Center(
                    child: Tooltip(
                      message: item.label,
                      child: Icon(
                        isSelected ? item.selectedIcon : item.icon,
                        color: iconColor,
                        size: 22,
                      ),
                    ),
                  )
                : Row(
                    children: [
                      Icon(
                        isSelected ? item.selectedIcon : item.icon,
                        color: iconColor,
                        size: 22,
                      ),
                      const SizedBox(width: 12),
                      Text(
                        item.label,
                        style: theme.textTheme.titleSmall?.copyWith(
                          fontWeight:
                              isSelected ? FontWeight.w700 : FontWeight.w400,
                          color: textColor,
                        ),
                      ),
                      if (isSelected) ...[
                        const Spacer(),
                        Container(
                          width: 4,
                          height: 4,
                          decoration: const BoxDecoration(
                            color: Color(0xFF5B8DEF),
                            shape: BoxShape.circle,
                          ),
                        ),
                      ],
                    ],
                  ),
          ),
        ),
      ),
    );
  }
}

class _ServerStatusTile extends ConsumerWidget {
  final bool isDark;
  final bool collapsed;

  const _ServerStatusTile({required this.isDark, required this.collapsed});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final currentServer = ref.watch(currentServerProvider);
    final authState = ref.watch(authStateProvider);
    final theme = Theme.of(context);

    if (currentServer == null) return const SizedBox.shrink();

    final isConnected = authState == AuthState.authenticated;
    final statusColor =
        isConnected ? const Color(0xFF4CAF50) : const Color(0xFFFFA726);

    return Container(
      margin: const EdgeInsets.fromLTRB(12, 8, 12, 0),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: isDark ? const Color(0xFF2A2A2A) : const Color(0xFFFFFFFF),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(
          color: isDark ? const Color(0xFF333333) : const Color(0xFFE8EAED),
        ),
      ),
      child: collapsed
          ? Center(
              child: Container(
                width: 8,
                height: 8,
                decoration:
                    BoxDecoration(color: statusColor, shape: BoxShape.circle),
              ),
            )
          : Row(
              children: [
                Container(
                  width: 8,
                  height: 8,
                  decoration: BoxDecoration(
                    color: statusColor,
                    shape: BoxShape.circle,
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    currentServer.name,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.labelMedium?.copyWith(
                      fontWeight: FontWeight.w400,
                    ),
                  ),
                ),
              ],
            ),
    );
  }
}
