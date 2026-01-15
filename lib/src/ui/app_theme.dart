import 'package:flutter/material.dart';

/// Centralized theme (light/dark + optional Material You dynamic color).
class AppTheme {
  static const _defaultSeed = Color(0xFF8CB4FF);
  static const _defaultSecondarySeed = Color(0xFFFFC27A);

  static ThemeData light({
    ColorScheme? dynamicScheme,
    Color seed = _defaultSeed,
    Color secondarySeed = _defaultSecondarySeed,
  }) {
    final scheme =
        (dynamicScheme ?? ColorScheme.fromSeed(seedColor: seed, brightness: Brightness.light))
            .copyWith(secondary: secondarySeed);
    return _build(scheme);
  }

  static ThemeData dark({
    ColorScheme? dynamicScheme,
    Color seed = _defaultSeed,
    Color secondarySeed = _defaultSecondarySeed,
  }) {
    final scheme =
        (dynamicScheme ?? ColorScheme.fromSeed(seedColor: seed, brightness: Brightness.dark))
            .copyWith(secondary: secondarySeed);
    return _build(scheme);
  }

  static ThemeData _build(ColorScheme scheme) {
    final base = ThemeData(
      useMaterial3: true,
      colorScheme: scheme,
      brightness: scheme.brightness,
      visualDensity: VisualDensity.adaptivePlatformDensity,
    );

    final radius = BorderRadius.circular(18);
    final isDark = scheme.brightness == Brightness.dark;
    TextStyle? scale(TextStyle? style) {
      if (style == null) return null;
      final size = style.fontSize;
      if (size == null) return style;
      return style.copyWith(fontSize: size * 0.92);
    }

    final textTheme = base.textTheme.copyWith(
      displayLarge: scale(base.textTheme.displayLarge),
      displayMedium: scale(base.textTheme.displayMedium),
      displaySmall: scale(base.textTheme.displaySmall),
      headlineLarge: scale(base.textTheme.headlineLarge),
      headlineMedium: scale(base.textTheme.headlineMedium),
      headlineSmall: scale(base.textTheme.headlineSmall),
      titleLarge: scale(base.textTheme.titleLarge),
      titleMedium: scale(base.textTheme.titleMedium),
      titleSmall: scale(base.textTheme.titleSmall),
      bodyLarge: scale(base.textTheme.bodyLarge),
      bodyMedium: scale(base.textTheme.bodyMedium),
      bodySmall: scale(base.textTheme.bodySmall),
      labelLarge: scale(base.textTheme.labelLarge),
      labelMedium: scale(base.textTheme.labelMedium),
      labelSmall: scale(base.textTheme.labelSmall),
    );

    return base.copyWith(
      textTheme: textTheme,
      scaffoldBackgroundColor: scheme.surface,
      appBarTheme: base.appBarTheme.copyWith(
        backgroundColor: scheme.surface,
        surfaceTintColor: Colors.transparent,
        elevation: 0,
        toolbarHeight: 48,
        titleTextStyle: textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w700),
      ),
      navigationBarTheme: base.navigationBarTheme.copyWith(
        backgroundColor: scheme.surfaceContainerHigh,
        indicatorColor: scheme.primary.withValues(alpha: isDark ? 0.18 : 0.14),
        labelBehavior: NavigationDestinationLabelBehavior.alwaysShow,
        height: 54,
      ),
      cardTheme: base.cardTheme.copyWith(
        color: scheme.surfaceContainerHigh,
        surfaceTintColor: Colors.transparent,
        margin: EdgeInsets.zero,
        shape: RoundedRectangleBorder(borderRadius: radius),
      ),
      listTileTheme: base.listTileTheme.copyWith(
        iconColor: scheme.onSurfaceVariant,
        contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
        horizontalTitleGap: 12,
      ),
      chipTheme: base.chipTheme.copyWith(
        backgroundColor: scheme.surfaceContainerHigh,
        selectedColor: scheme.primary.withValues(alpha: 0.2),
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
        labelStyle: const TextStyle(fontWeight: FontWeight.w600),
      ),
      inputDecorationTheme: base.inputDecorationTheme.copyWith(
        filled: true,
        fillColor: scheme.surfaceContainerHigh,
        border: OutlineInputBorder(borderRadius: radius, borderSide: BorderSide.none),
        contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
      ),
      floatingActionButtonTheme: base.floatingActionButtonTheme.copyWith(
        backgroundColor: scheme.primary,
        foregroundColor: scheme.onPrimary,
        shape: RoundedRectangleBorder(borderRadius: radius),
      ),
      dividerTheme: base.dividerTheme.copyWith(
        color: scheme.outlineVariant.withValues(alpha: isDark ? 0.55 : 0.8),
        thickness: 1,
        space: 16,
      ),
    );
  }
}
