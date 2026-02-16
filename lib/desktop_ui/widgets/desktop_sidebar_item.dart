import 'package:flutter/material.dart';

import '../theme/desktop_theme_extension.dart';
import 'hover_effect_wrapper.dart';

class DesktopSidebarItem extends StatelessWidget {
  const DesktopSidebarItem({
    super.key,
    required this.icon,
    required this.label,
    required this.selected,
    required this.onTap,
  });

  final IconData icon;
  final String label;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final desktopTheme = DesktopThemeExtension.of(context);
    final fg = selected ? desktopTheme.textPrimary : desktopTheme.textMuted;

    return HoverEffectWrapper(
      onTap: onTap,
      borderRadius: BorderRadius.circular(12),
      hoverScale: 1.01,
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: selected ? desktopTheme.accent.withValues(alpha: 0.18) : null,
          borderRadius: BorderRadius.circular(12),
        ),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
          child: Row(
            children: [
              Icon(
                icon,
                size: 20,
                color: selected ? desktopTheme.accent : fg,
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Text(
                  label,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    color: fg,
                    fontWeight: selected ? FontWeight.w700 : FontWeight.w500,
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
