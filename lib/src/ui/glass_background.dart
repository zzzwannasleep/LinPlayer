import 'package:flutter/material.dart';

/// Subtle, cheap background used to make glass blur effects visible.
class GlassBackground extends StatelessWidget {
  const GlassBackground({super.key, this.intensity = 1.0});

  /// 0..1. Larger = more color.
  final double intensity;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final isDark = scheme.brightness == Brightness.dark;

    double a(double v) => (v * intensity).clamp(0.0, 1.0);

    final base = scheme.surface;
    final primary = scheme.primary;
    final secondary = scheme.secondary;
    final tertiary = scheme.tertiary;

    return IgnorePointer(
      child: DecoratedBox(
        decoration: BoxDecoration(color: base),
        child: Stack(
          fit: StackFit.expand,
          children: [
            DecoratedBox(
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  begin: Alignment.topLeft,
                  end: Alignment.bottomRight,
                  colors: [
                    primary.withValues(alpha: a(isDark ? 0.10 : 0.08)),
                    secondary.withValues(alpha: a(isDark ? 0.08 : 0.06)),
                  ],
                ),
              ),
            ),
            DecoratedBox(
              decoration: BoxDecoration(
                gradient: RadialGradient(
                  center: Alignment.topLeft,
                  radius: 1.1,
                  colors: [
                    tertiary.withValues(alpha: a(isDark ? 0.14 : 0.12)),
                    Colors.transparent,
                  ],
                ),
              ),
            ),
            DecoratedBox(
              decoration: BoxDecoration(
                gradient: RadialGradient(
                  center: Alignment.bottomRight,
                  radius: 1.2,
                  colors: [
                    primary.withValues(alpha: a(isDark ? 0.10 : 0.08)),
                    Colors.transparent,
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

