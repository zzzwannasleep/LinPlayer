import 'package:flutter/material.dart';

import '../theme/desktop_theme_extension.dart';
import 'desktop_sidebar_item.dart';

@immutable
class DesktopSidebarDestination {
  const DesktopSidebarDestination({
    required this.id,
    required this.label,
    required this.icon,
    this.enabled = true,
  });

  final String id;
  final String label;
  final IconData icon;
  final bool enabled;
}

class DesktopSidebar extends StatelessWidget {
  const DesktopSidebar({
    super.key,
    required this.destinations,
    required this.selectedId,
    required this.onSelected,
    this.serverLabel,
    this.collapsed = false,
  });

  final List<DesktopSidebarDestination> destinations;
  final String selectedId;
  final ValueChanged<String> onSelected;
  final String? serverLabel;
  final bool collapsed;

  @override
  Widget build(BuildContext context) {
    final theme = DesktopThemeExtension.of(context);

    return DecoratedBox(
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [
            theme.sidebarColor,
            theme.sidebarColor.withValues(alpha: 0.94),
          ],
        ),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: theme.border),
      ),
      child: Padding(
        padding: EdgeInsets.fromLTRB(
          collapsed ? 10 : 12,
          14,
          collapsed ? 10 : 12,
          12,
        ),
        child: Column(
          crossAxisAlignment:
              collapsed ? CrossAxisAlignment.center : CrossAxisAlignment.start,
          children: [
            AnimatedSwitcher(
              duration: const Duration(milliseconds: 200),
              child: collapsed
                  ? Container(
                      key: const ValueKey<String>('collapsed-logo'),
                      width: 34,
                      height: 34,
                      decoration: BoxDecoration(
                        borderRadius: BorderRadius.circular(8),
                        color: theme.accent,
                      ),
                      alignment: Alignment.center,
                      child: const Text(
                        'L',
                        style: TextStyle(
                          color: Colors.white,
                          fontWeight: FontWeight.w800,
                        ),
                      ),
                    )
                  : Row(
                      key: const ValueKey<String>('expanded-logo'),
                      children: [
                        Container(
                          width: 10,
                          height: 10,
                          decoration: BoxDecoration(
                            color: theme.accent,
                            borderRadius: BorderRadius.circular(999),
                          ),
                        ),
                        const SizedBox(width: 8),
                        Text(
                          'LinPlayer◆',
                          style: TextStyle(
                            color: theme.textPrimary,
                            fontWeight: FontWeight.w700,
                            letterSpacing: 0.2,
                          ),
                        ),
                      ],
                    ),
            ),
            const SizedBox(height: 14),
            Expanded(
              child: ListView.separated(
                itemCount: destinations.length,
                itemBuilder: (context, index) {
                  final item = destinations[index];
                  return Opacity(
                    opacity: item.enabled ? 1 : 0.45,
                    child: IgnorePointer(
                      ignoring: !item.enabled,
                      child: DesktopSidebarItem(
                        icon: item.icon,
                        label: item.label,
                        selected: selectedId == item.id,
                        collapsed: collapsed,
                        onTap: () => onSelected(item.id),
                      ),
                    ),
                  );
                },
                separatorBuilder: (_, __) => const SizedBox(height: 8),
              ),
            ),
            if ((serverLabel ?? '').trim().isNotEmpty && !collapsed)
              Container(
                width: double.infinity,
                padding:
                    const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                decoration: BoxDecoration(
                  color: theme.surface.withValues(alpha: 0.72),
                  borderRadius: BorderRadius.circular(12),
                  border: Border.all(color: theme.border),
                ),
                child: Text(
                  serverLabel!,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    color: theme.textMuted,
                    fontSize: 12,
                    fontWeight: FontWeight.w500,
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }
}
