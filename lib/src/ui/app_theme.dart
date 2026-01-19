import 'package:flutter/material.dart';

import 'app_style.dart';

/// Centralized theme (light/dark + optional Material You dynamic color).
class AppTheme {
  static const _defaultSeed = Color(0xFF8CB4FF);
  static const _defaultSecondarySeed = Color(0xFFFFC27A);

  static ThemeData light({
    ColorScheme? dynamicScheme,
    Color seed = _defaultSeed,
    Color secondarySeed = _defaultSecondarySeed,
    bool kawaii = false,
    bool compact = false,
  }) {
    final scheme = (dynamicScheme ??
            ColorScheme.fromSeed(seedColor: seed, brightness: Brightness.light))
        .copyWith(secondary: secondarySeed);
    return _build(scheme, kawaii: kawaii, compact: compact);
  }

  static ThemeData dark({
    ColorScheme? dynamicScheme,
    Color seed = _defaultSeed,
    Color secondarySeed = _defaultSecondarySeed,
    bool kawaii = false,
    bool compact = false,
  }) {
    final scheme = (dynamicScheme ??
            ColorScheme.fromSeed(seedColor: seed, brightness: Brightness.dark))
        .copyWith(secondary: secondarySeed);
    return _build(scheme, kawaii: kawaii, compact: compact);
  }

  static ThemeData _build(
    ColorScheme scheme, {
    required bool kawaii,
    required bool compact,
  }) {
    final isDark = scheme.brightness == Brightness.dark;
    final radiusValue = kawaii ? 22.0 : 18.0;
    final style = AppStyle(
      kawaii: kawaii,
      compact: compact,
      radius: radiusValue,
      panelRadius: radiusValue,
      borderWidth: 1.0,
      backgroundIntensity: kawaii ? 1.0 : 0.0,
      patternOpacity: !kawaii ? 0.0 : (isDark ? 0.04 : 0.06),
    );

    final base = ThemeData(
      useMaterial3: true,
      colorScheme: scheme,
      brightness: scheme.brightness,
      visualDensity: compact
          ? VisualDensity.compact
          : VisualDensity.adaptivePlatformDensity,
      materialTapTargetSize: compact
          ? MaterialTapTargetSize.shrinkWrap
          : MaterialTapTargetSize.padded,
      extensions: <ThemeExtension<dynamic>>[style],
    );

    final radius = BorderRadius.circular(radiusValue);
    TextStyle? scale(TextStyle? style) {
      if (style == null) return null;
      final size = style.fontSize;
      if (size == null) return style;
      return style.copyWith(fontSize: size * (compact ? 0.90 : 0.92));
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

    final appBarBg = kawaii
        ? scheme.surface.withValues(alpha: isDark ? 0.74 : 0.88)
        : scheme.surface;
    final navBarBg = kawaii
        ? scheme.surfaceContainerHigh.withValues(alpha: isDark ? 0.82 : 0.90)
        : scheme.surfaceContainerHigh;
    final surfaceHigh = kawaii
        ? scheme.surfaceContainerHigh.withValues(alpha: isDark ? 0.74 : 0.86)
        : scheme.surfaceContainerHigh;
    final outline =
        scheme.outlineVariant.withValues(alpha: isDark ? 0.42 : 0.7);
    final outlineSoft =
        scheme.outlineVariant.withValues(alpha: isDark ? 0.36 : 0.55);

    return base.copyWith(
      textTheme: textTheme,
      scaffoldBackgroundColor: kawaii ? Colors.transparent : scheme.surface,
      appBarTheme: base.appBarTheme.copyWith(
        backgroundColor: appBarBg,
        surfaceTintColor: Colors.transparent,
        elevation: 0,
        toolbarHeight: compact ? 44 : 48,
        titleTextStyle:
            textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w700),
      ),
      navigationBarTheme: base.navigationBarTheme.copyWith(
        backgroundColor: navBarBg,
        indicatorColor: scheme.primary.withValues(
          alpha: isDark ? (kawaii ? 0.22 : 0.18) : (kawaii ? 0.18 : 0.14),
        ),
        labelBehavior: NavigationDestinationLabelBehavior.alwaysShow,
        height: compact ? 50 : 54,
      ),
      cardTheme: base.cardTheme.copyWith(
        color: surfaceHigh,
        surfaceTintColor: Colors.transparent,
        margin: EdgeInsets.zero,
        shape: RoundedRectangleBorder(borderRadius: radius),
      ),
      listTileTheme: base.listTileTheme.copyWith(
        iconColor: scheme.onSurfaceVariant,
        contentPadding: EdgeInsets.symmetric(
          horizontal: compact ? 10 : 12,
          vertical: compact ? 2 : 4,
        ),
        horizontalTitleGap: 12,
      ),
      chipTheme: base.chipTheme.copyWith(
        backgroundColor: surfaceHigh,
        selectedColor: scheme.primary.withValues(alpha: 0.2),
        padding: EdgeInsets.symmetric(
          horizontal: compact ? 8 : 10,
          vertical: compact ? 4 : 6,
        ),
        shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(kawaii ? 14 : 12)),
        labelStyle: const TextStyle(fontWeight: FontWeight.w600),
      ),
      inputDecorationTheme: base.inputDecorationTheme.copyWith(
        filled: true,
        fillColor: surfaceHigh,
        border: OutlineInputBorder(
            borderRadius: radius, borderSide: BorderSide.none),
        enabledBorder: !kawaii
            ? null
            : OutlineInputBorder(
                borderRadius: radius,
                borderSide: BorderSide(color: outlineSoft),
              ),
        focusedBorder: !kawaii
            ? null
            : OutlineInputBorder(
                borderRadius: radius,
                borderSide: BorderSide(
                  color: scheme.primary.withValues(alpha: isDark ? 0.95 : 1.0),
                  width: style.borderWidth + 0.2,
                ),
              ),
        contentPadding: EdgeInsets.symmetric(
            horizontal: compact ? 12 : 14, vertical: compact ? 10 : 12),
      ),
      floatingActionButtonTheme: base.floatingActionButtonTheme.copyWith(
        backgroundColor: scheme.primary,
        foregroundColor: scheme.onPrimary,
        shape: RoundedRectangleBorder(borderRadius: radius),
      ),
      dividerTheme: base.dividerTheme.copyWith(
        color: outline,
        thickness: 1,
        space: compact ? 12 : 16,
      ),
    );
  }
}
