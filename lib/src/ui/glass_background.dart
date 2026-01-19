import 'package:flutter/material.dart';

import 'app_style.dart';

/// Subtle, cheap background used to make glass blur effects visible.
class GlassBackground extends StatelessWidget {
  const GlassBackground({super.key, this.intensity = 1.0});

  /// 0..1. Larger = more color.
  final double intensity;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final style = Theme.of(context).extension<AppStyle>();
    final isDark = scheme.brightness == Brightness.dark;
    final kawaii = style?.kawaii == true;

    double a(double v) => (v * intensity).clamp(0.0, 1.0);

    final base = scheme.surface;
    final primary = scheme.primary;
    final secondary = scheme.secondary;
    final tertiary = scheme.tertiary;

    final primaryAlpha =
        kawaii ? (isDark ? 0.16 : 0.14) : (isDark ? 0.10 : 0.08);
    final secondaryAlpha =
        kawaii ? (isDark ? 0.14 : 0.12) : (isDark ? 0.08 : 0.06);
    final tertiaryAlpha =
        kawaii ? (isDark ? 0.20 : 0.18) : (isDark ? 0.14 : 0.12);

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
                    primary.withValues(alpha: a(primaryAlpha)),
                    secondary.withValues(alpha: a(secondaryAlpha)),
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
                    tertiary.withValues(alpha: a(tertiaryAlpha)),
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
                    primary.withValues(alpha: a(primaryAlpha)),
                    Colors.transparent,
                  ],
                ),
              ),
            ),
            if (kawaii && intensity > 0) ...[
              Positioned.fill(
                child: CustomPaint(
                  painter: _KawaiiPatternPainter(
                    dotColor: scheme.onSurfaceVariant,
                    sparkleColor: scheme.primary,
                    opacity: (style?.patternOpacity ?? (isDark ? 0.04 : 0.06)) *
                        intensity.clamp(0.0, 1.0),
                  ),
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

class _KawaiiPatternPainter extends CustomPainter {
  const _KawaiiPatternPainter({
    required this.dotColor,
    required this.sparkleColor,
    required this.opacity,
  });

  final Color dotColor;
  final Color sparkleColor;
  final double opacity;

  @override
  void paint(Canvas canvas, Size size) {
    if (opacity <= 0) return;

    final dotPaint = Paint()
      ..color = dotColor.withValues(alpha: opacity)
      ..style = PaintingStyle.fill;

    final sparklePaint = Paint()
      ..color = sparkleColor.withValues(alpha: (opacity * 1.3).clamp(0.0, 1.0))
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.2
      ..strokeCap = StrokeCap.round;

    const spacing = 28.0;
    const radius = 1.2;

    for (double y = 0; y < size.height + spacing; y += spacing) {
      final row = (y / spacing).floor();
      final xOffset = row.isEven ? 0.0 : spacing / 2;
      for (double x = -spacing; x < size.width + spacing; x += spacing) {
        canvas.drawCircle(Offset(x + xOffset, y), radius, dotPaint);
      }
    }

    void drawSparkle(Offset center, double r) {
      final diag = r * 0.7;
      canvas.drawLine(
          center + Offset(-r, 0), center + Offset(r, 0), sparklePaint);
      canvas.drawLine(
          center + Offset(0, -r), center + Offset(0, r), sparklePaint);
      canvas.drawLine(
        center + Offset(-diag, -diag),
        center + Offset(diag, diag),
        sparklePaint,
      );
      canvas.drawLine(
        center + Offset(-diag, diag),
        center + Offset(diag, -diag),
        sparklePaint,
      );
    }

    drawSparkle(Offset(size.width * 0.18, size.height * 0.22), 6);
    drawSparkle(Offset(size.width * 0.78, size.height * 0.18), 7);
    drawSparkle(Offset(size.width * 0.85, size.height * 0.72), 7);
    drawSparkle(Offset(size.width * 0.25, size.height * 0.78), 6);
  }

  @override
  bool shouldRepaint(covariant _KawaiiPatternPainter oldDelegate) {
    return oldDelegate.dotColor != dotColor ||
        oldDelegate.sparkleColor != sparkleColor ||
        oldDelegate.opacity != opacity;
  }
}
