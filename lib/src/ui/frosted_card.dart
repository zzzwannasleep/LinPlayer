import 'dart:ui';

import 'package:flutter/material.dart';

import 'app_style.dart';

/// A lightweight "glass" surface: gradient + optional backdrop blur.
///
/// Use [enableBlur] to disable blur on low-performance targets (e.g. Android TV).
class FrostedCard extends StatelessWidget {
  const FrostedCard({
    super.key,
    required this.child,
    this.padding,
    this.borderRadius,
    this.enableBlur = true,
  });

  final Widget child;
  final EdgeInsetsGeometry? padding;
  final double? borderRadius;
  final bool enableBlur;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final style = Theme.of(context).extension<AppStyle>();
    final isDark = scheme.brightness == Brightness.dark;
    final radius =
        BorderRadius.circular(borderRadius ?? style?.panelRadius ?? 18);

    final a = enableBlur ? (isDark ? 0.62 : 0.78) : (isDark ? 0.98 : 1.0);
    final b = enableBlur ? (isDark ? 0.48 : 0.68) : (isDark ? 0.92 : 0.96);
    final gradient = LinearGradient(
      begin: Alignment.topLeft,
      end: Alignment.bottomRight,
      colors: [
        scheme.surfaceContainerHigh.withValues(alpha: a),
        scheme.surfaceContainerHigh.withValues(alpha: b),
      ],
    );
    final border = Border.all(
      color: scheme.outlineVariant.withValues(alpha: isDark ? 0.42 : 0.7),
      width: style?.borderWidth ?? 1,
    );
    final shadowColor = scheme.shadow
        .withValues(alpha: enableBlur ? (isDark ? 0.18 : 0.12) : 0);

    Widget content = Container(
      padding: padding,
      decoration: BoxDecoration(
        gradient: gradient,
        border: border,
        borderRadius: radius,
        boxShadow: shadowColor.a == 0
            ? null
            : [
                BoxShadow(
                  color: shadowColor,
                  blurRadius: enableBlur ? 18 : 0,
                  offset: const Offset(0, 10),
                ),
              ],
      ),
      child: child,
    );

    if (!enableBlur) return ClipRRect(borderRadius: radius, child: content);

    return ClipRRect(
      borderRadius: radius,
      child: BackdropFilter(
        filter: ImageFilter.blur(sigmaX: 18, sigmaY: 18),
        child: content,
      ),
    );
  }
}
