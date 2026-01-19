import 'dart:ui';

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
    final background = style?.background ?? AppBackgroundKind.none;
    final pattern = style?.pattern ?? AppPatternKind.none;

    final effectiveIntensity =
        (intensity.clamp(0.0, 1.0) * (style?.backgroundIntensity ?? 1.0))
            .clamp(0.0, 1.0);
    double a(double v) => (v * effectiveIntensity).clamp(0.0, 1.0);

    final base = scheme.surface;
    final primary = scheme.primary;
    final secondary = scheme.secondary;
    final tertiary = scheme.tertiary;

    final vivid = pattern == AppPatternKind.grid;
    final cute = pattern == AppPatternKind.dotsSparkles;

    final primaryAlpha = isDark
        ? (vivid ? 0.17 : (cute ? 0.15 : 0.12))
        : (vivid ? 0.14 : (cute ? 0.12 : 0.10));
    final secondaryAlpha = isDark
        ? (vivid ? 0.14 : (cute ? 0.12 : 0.10))
        : (vivid ? 0.12 : (cute ? 0.10 : 0.08));
    final tertiaryAlpha = isDark
        ? (vivid ? 0.22 : (cute ? 0.20 : 0.16))
        : (vivid ? 0.19 : (cute ? 0.17 : 0.14));

    return IgnorePointer(
      child: DecoratedBox(
        decoration: BoxDecoration(color: base),
        child: Stack(
          fit: StackFit.expand,
          children: [
            if (background == AppBackgroundKind.gradient &&
                effectiveIntensity > 0) ...[
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
            ],
            if (pattern != AppPatternKind.none && effectiveIntensity > 0) ...[
              Positioned.fill(
                child: CustomPaint(
                  painter: _patternPainterFor(
                    pattern,
                    scheme: scheme,
                    opacity: (style?.patternOpacity ?? 0) * effectiveIntensity,
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

CustomPainter _patternPainterFor(
  AppPatternKind pattern, {
  required ColorScheme scheme,
  required double opacity,
}) {
  switch (pattern) {
    case AppPatternKind.none:
      return const _NullPainter();
    case AppPatternKind.dotsSparkles:
      return _DotsSparklesPainter(
        dotColor: scheme.onSurfaceVariant,
        sparkleColor: scheme.primary,
        opacity: opacity,
      );
    case AppPatternKind.grid:
      return _GridPainter(
        lineColor: scheme.onSurfaceVariant,
        glowColor: scheme.primary,
        opacity: opacity,
      );
    case AppPatternKind.halftone:
      return _HalftonePainter(
        dotColor: scheme.onSurface,
        opacity: opacity,
      );
    case AppPatternKind.pixels:
      return _PixelNoisePainter(
        pixelColor: scheme.onSurfaceVariant,
        accentColor: scheme.primary,
        opacity: opacity,
      );
  }
}

class _NullPainter extends CustomPainter {
  const _NullPainter();

  @override
  void paint(Canvas canvas, Size size) {}

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => false;
}

class _DotsSparklesPainter extends CustomPainter {
  const _DotsSparklesPainter({
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
  bool shouldRepaint(covariant _DotsSparklesPainter oldDelegate) {
    return oldDelegate.dotColor != dotColor ||
        oldDelegate.sparkleColor != sparkleColor ||
        oldDelegate.opacity != opacity;
  }
}

class _GridPainter extends CustomPainter {
  const _GridPainter({
    required this.lineColor,
    required this.glowColor,
    required this.opacity,
  });

  final Color lineColor;
  final Color glowColor;
  final double opacity;

  @override
  void paint(Canvas canvas, Size size) {
    if (opacity <= 0) return;

    final basePaint = Paint()
      ..color = lineColor.withValues(alpha: opacity)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1;

    final glowPaint = Paint()
      ..color = glowColor.withValues(alpha: (opacity * 1.6).clamp(0.0, 1.0))
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.2;

    const spacing = 34.0;
    for (double x = 0; x <= size.width; x += spacing) {
      canvas.drawLine(Offset(x, 0), Offset(x, size.height), basePaint);
    }
    for (double y = 0; y <= size.height; y += spacing) {
      canvas.drawLine(Offset(0, y), Offset(size.width, y), basePaint);
    }

    canvas.drawLine(
      Offset(size.width * 0.12, 0),
      Offset(size.width * 0.12, size.height),
      glowPaint,
    );
    canvas.drawLine(
      Offset(0, size.height * 0.18),
      Offset(size.width, size.height * 0.18),
      glowPaint,
    );
  }

  @override
  bool shouldRepaint(covariant _GridPainter oldDelegate) {
    return oldDelegate.lineColor != lineColor ||
        oldDelegate.glowColor != glowColor ||
        oldDelegate.opacity != opacity;
  }
}

class _HalftonePainter extends CustomPainter {
  const _HalftonePainter({
    required this.dotColor,
    required this.opacity,
  });

  final Color dotColor;
  final double opacity;

  @override
  void paint(Canvas canvas, Size size) {
    if (opacity <= 0) return;

    final paint = Paint()
      ..color = dotColor.withValues(alpha: opacity)
      ..style = PaintingStyle.fill;

    const spacing = 22.0;
    final centerA = Offset(size.width * 0.12, size.height * 0.16);
    final centerB = Offset(size.width * 0.86, size.height * 0.78);
    final radiusA = size.shortestSide * 0.65;
    final radiusB = size.shortestSide * 0.70;

    double falloff(Offset p, Offset c, double r) {
      final d = (p - c).distance;
      return (1.0 - (d / r)).clamp(0.0, 1.0);
    }

    for (double y = -spacing; y < size.height + spacing; y += spacing) {
      for (double x = -spacing; x < size.width + spacing; x += spacing) {
        final p = Offset(x, y);
        final f = (falloff(p, centerA, radiusA) * 0.9) +
            (falloff(p, centerB, radiusB) * 0.9);
        if (f <= 0) continue;
        final r = lerpDouble(0.6, 3.0, f.clamp(0.0, 1.0)) ?? 1.0;
        canvas.drawCircle(p, r, paint);
      }
    }
  }

  @override
  bool shouldRepaint(covariant _HalftonePainter oldDelegate) {
    return oldDelegate.dotColor != dotColor || oldDelegate.opacity != opacity;
  }
}

class _PixelNoisePainter extends CustomPainter {
  const _PixelNoisePainter({
    required this.pixelColor,
    required this.accentColor,
    required this.opacity,
  });

  final Color pixelColor;
  final Color accentColor;
  final double opacity;

  @override
  void paint(Canvas canvas, Size size) {
    if (opacity <= 0) return;

    final basePaint = Paint()
      ..color = pixelColor.withValues(alpha: opacity)
      ..style = PaintingStyle.fill;
    final accentPaint = Paint()
      ..color = accentColor.withValues(alpha: (opacity * 1.4).clamp(0.0, 1.0))
      ..style = PaintingStyle.fill;

    const step = 18.0;
    for (double y = 0; y < size.height + step; y += step) {
      for (double x = 0; x < size.width + step; x += step) {
        final ix = (x / step).floor();
        final iy = (y / step).floor();
        final h = (ix * 1103515245 + iy * 12345) & 0x7fffffff;
        final mod = h % 19;
        if (mod == 0 || mod == 1) {
          final s = (mod == 0) ? 7.0 : 5.0;
          canvas.drawRect(Rect.fromLTWH(x + 3, y + 4, s, s), basePaint);
        } else if (mod == 2) {
          canvas.drawRect(Rect.fromLTWH(x + 4, y + 3, 6, 6), accentPaint);
        }
      }
    }
  }

  @override
  bool shouldRepaint(covariant _PixelNoisePainter oldDelegate) {
    return oldDelegate.pixelColor != pixelColor ||
        oldDelegate.accentColor != accentColor ||
        oldDelegate.opacity != opacity;
  }
}
