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
  });

  final List<DesktopSidebarDestination> destinations;
  final String selectedId;
  final ValueChanged<String> onSelected;
  final String? serverLabel;

  @override
  Widget build(BuildContext context) {
    final desktopTheme = DesktopThemeExtension.of(context);

    return DecoratedBox(
      decoration: BoxDecoration(
        color: desktopTheme.sidebarColor,
        borderRadius: BorderRadius.circular(18),
        border: Border.all(color: desktopTheme.border),
      ),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(12, 16, 12, 12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Container(
                  width: 10,
                  height: 10,
                  decoration: BoxDecoration(
                    color: desktopTheme.accent,
                    borderRadius: BorderRadius.circular(999),
                  ),
                ),
                const SizedBox(width: 8),
                Text(
                  'LinPlayer Desktop',
                  style: TextStyle(
                    color: desktopTheme.textPrimary,
                    fontWeight: FontWeight.w700,
                    letterSpacing: 0.2,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 18),
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
                        onTap: () => onSelected(item.id),
                      ),
                    ),
                  );
                },
                separatorBuilder: (_, __) => const SizedBox(height: 6),
              ),
            ),
            if ((serverLabel ?? '').trim().isNotEmpty)
              Container(
                width: double.infinity,
                padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                decoration: BoxDecoration(
                  color: desktopTheme.surface,
                  borderRadius: BorderRadius.circular(12),
                  border: Border.all(color: desktopTheme.border),
                ),
                child: Text(
                  serverLabel!,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    color: desktopTheme.textMuted,
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
