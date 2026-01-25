import 'package:flutter/material.dart';

import '../../state/preferences.dart';
import 'app_style.dart';

class EpisodeCountBadge extends StatelessWidget {
  const EpisodeCountBadge({super.key, required this.count});

  final int count;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final style = theme.extension<AppStyle>() ?? const AppStyle();
    final isDark = scheme.brightness == Brightness.dark;

    final (Color bg, Color fg, BorderSide border, Color iconColor) =
        switch (style.template) {
      UiTemplate.neonHud => (
          scheme.surface.withValues(alpha: isDark ? 0.42 : 0.60),
          scheme.onSurface,
          BorderSide(
            color: scheme.primary.withValues(alpha: isDark ? 0.70 : 0.85),
            width: style.borderWidth,
          ),
          scheme.primary,
        ),
      UiTemplate.pixelArcade => (
          scheme.surface.withValues(alpha: isDark ? 0.55 : 0.80),
          scheme.onSurface,
          BorderSide(
            color: scheme.secondary.withValues(alpha: isDark ? 0.70 : 0.85),
            width: style.borderWidth + 0.4,
          ),
          scheme.secondary,
        ),
      UiTemplate.mangaStoryboard => (
          scheme.surface.withValues(alpha: isDark ? 0.60 : 0.85),
          scheme.onSurface,
          BorderSide(
            color: scheme.onSurface.withValues(alpha: isDark ? 0.70 : 0.90),
            width: style.borderWidth + 0.6,
          ),
          scheme.onSurface,
        ),
      _ => (
          Colors.black.withValues(alpha: 0.55),
          Colors.white,
          BorderSide.none,
          Colors.white,
        ),
    };

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 3),
      decoration: BoxDecoration(
        color: bg,
        borderRadius: BorderRadius.circular(8),
        border: border == BorderSide.none ? null : Border.fromBorderSide(border),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.format_list_numbered, size: 14, color: iconColor),
          const SizedBox(width: 3),
          Text(
            '$count集',
            style: theme.textTheme.labelMedium?.copyWith(
                  color: fg,
                  fontWeight: FontWeight.w700,
                ) ??
                TextStyle(
                  color: fg,
                  fontSize: 12,
                  fontWeight: FontWeight.w700,
                ),
          ),
        ],
      ),
    );
  }
}
