import 'package:flutter/material.dart';

import '../../state/preferences.dart';
import 'app_style.dart';

/// Centralized theme (light/dark + optional Material You dynamic color).
class AppTheme {
  static ThemeData light({
    ColorScheme? dynamicScheme,
    required UiTemplate template,
    Color? seed,
    Color? secondarySeed,
    bool compact = false,
  }) {
    final resolvedSeed = seed ?? template.seed;
    final resolvedSecondary = secondarySeed ?? template.secondarySeed;
    final scheme = (dynamicScheme ??
            ColorScheme.fromSeed(
              seedColor: resolvedSeed,
              brightness: Brightness.light,
            ))
        .copyWith(secondary: resolvedSecondary);
    return _build(scheme, template: template, compact: compact);
  }

  static ThemeData dark({
    ColorScheme? dynamicScheme,
    required UiTemplate template,
    Color? seed,
    Color? secondarySeed,
    bool compact = false,
  }) {
    final resolvedSeed = seed ?? template.seed;
    final resolvedSecondary = secondarySeed ?? template.secondarySeed;
    final scheme = (dynamicScheme ??
            ColorScheme.fromSeed(
              seedColor: resolvedSeed,
              brightness: Brightness.dark,
            ))
        .copyWith(secondary: resolvedSecondary);
    return _build(scheme, template: template, compact: compact);
  }

  static ThemeData _build(
    ColorScheme scheme, {
    required UiTemplate template,
    required bool compact,
  }) {
    final isDark = scheme.brightness == Brightness.dark;
    final effectiveCompact = compact || template == UiTemplate.proTool;
    final style = _styleFor(
      template,
      isDark: isDark,
      compact: effectiveCompact,
    );

    final base = ThemeData(
      useMaterial3: true,
      colorScheme: scheme,
      brightness: scheme.brightness,
      visualDensity: effectiveCompact
          ? VisualDensity.compact
          : VisualDensity.adaptivePlatformDensity,
      materialTapTargetSize: effectiveCompact
          ? MaterialTapTargetSize.shrinkWrap
          : MaterialTapTargetSize.padded,
      extensions: <ThemeExtension<dynamic>>[style],
    );

    final radius = BorderRadius.circular(style.radius);
    TextStyle? scale(TextStyle? style) {
      if (style == null) return null;
      final size = style.fontSize;
      if (size == null) return style;
      return style.copyWith(fontSize: size * (effectiveCompact ? 0.90 : 0.92));
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

    final hasBackdrop = style.background != AppBackgroundKind.none ||
        style.pattern != AppPatternKind.none;
    final glassSurfaces = template == UiTemplate.candyGlass ||
        template == UiTemplate.stickerJournal ||
        template == UiTemplate.neonHud ||
        template == UiTemplate.washiWatercolor;

    final appBarBg = glassSurfaces
        ? scheme.surface.withValues(alpha: isDark ? 0.72 : 0.88)
        : scheme.surface;
    final navBarBg = glassSurfaces
        ? scheme.surfaceContainerHigh.withValues(alpha: isDark ? 0.80 : 0.90)
        : scheme.surfaceContainerHigh;
    final surfaceHigh = glassSurfaces
        ? scheme.surfaceContainerHigh.withValues(alpha: isDark ? 0.72 : 0.86)
        : scheme.surfaceContainerHigh;
    final outline =
        scheme.outlineVariant.withValues(alpha: isDark ? 0.42 : 0.7);
    final outlineSoft =
        scheme.outlineVariant.withValues(alpha: isDark ? 0.36 : 0.55);

    final chipRadius = switch (template) {
      UiTemplate.candyGlass => 14.0,
      UiTemplate.stickerJournal => 14.0,
      UiTemplate.neonHud => 10.0,
      UiTemplate.minimalCovers => 12.0,
      UiTemplate.washiWatercolor => 12.0,
      UiTemplate.pixelArcade => 8.0,
      UiTemplate.mangaStoryboard => 10.0,
      UiTemplate.proTool => 10.0,
    };

    final outlinedInputs = template == UiTemplate.candyGlass ||
        template == UiTemplate.stickerJournal ||
        template == UiTemplate.neonHud ||
        template == UiTemplate.pixelArcade ||
        template == UiTemplate.mangaStoryboard;

    return base.copyWith(
      textTheme: textTheme,
      scaffoldBackgroundColor:
          hasBackdrop ? Colors.transparent : scheme.surface,
      appBarTheme: base.appBarTheme.copyWith(
        backgroundColor: appBarBg,
        surfaceTintColor: Colors.transparent,
        elevation: 0,
        toolbarHeight: effectiveCompact ? 44 : 48,
        titleTextStyle:
            textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w700),
      ),
      navigationBarTheme: base.navigationBarTheme.copyWith(
        backgroundColor: navBarBg,
        indicatorColor: scheme.primary.withValues(
          alpha: isDark
              ? (glassSurfaces ? 0.22 : 0.18)
              : (glassSurfaces ? 0.18 : 0.14),
        ),
        labelBehavior: NavigationDestinationLabelBehavior.alwaysShow,
        height: effectiveCompact ? 50 : 54,
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
          horizontal: effectiveCompact ? 10 : 12,
          vertical: effectiveCompact ? 2 : 4,
        ),
        horizontalTitleGap: 12,
      ),
      chipTheme: base.chipTheme.copyWith(
        backgroundColor: surfaceHigh,
        selectedColor: scheme.primary.withValues(alpha: 0.2),
        padding: EdgeInsets.symmetric(
          horizontal: effectiveCompact ? 8 : 10,
          vertical: effectiveCompact ? 4 : 6,
        ),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(chipRadius),
        ),
        labelStyle: const TextStyle(fontWeight: FontWeight.w600),
      ),
      inputDecorationTheme: base.inputDecorationTheme.copyWith(
        filled: true,
        fillColor: surfaceHigh,
        border: OutlineInputBorder(
            borderRadius: radius, borderSide: BorderSide.none),
        enabledBorder: !outlinedInputs
            ? null
            : OutlineInputBorder(
                borderRadius: radius,
                borderSide: BorderSide(color: outlineSoft),
              ),
        focusedBorder: !outlinedInputs
            ? null
            : OutlineInputBorder(
                borderRadius: radius,
                borderSide: BorderSide(
                  color: scheme.primary.withValues(alpha: isDark ? 0.95 : 1.0),
                  width: style.borderWidth + 0.2,
                ),
              ),
        contentPadding: EdgeInsets.symmetric(
          horizontal: effectiveCompact ? 12 : 14,
          vertical: effectiveCompact ? 10 : 12,
        ),
      ),
      floatingActionButtonTheme: base.floatingActionButtonTheme.copyWith(
        backgroundColor: scheme.primary,
        foregroundColor: scheme.onPrimary,
        shape: RoundedRectangleBorder(borderRadius: radius),
      ),
      dividerTheme: base.dividerTheme.copyWith(
        color: outline,
        thickness: 1,
        space: effectiveCompact ? 12 : 16,
      ),
    );
  }

  static AppStyle _styleFor(
    UiTemplate template, {
    required bool isDark,
    required bool compact,
  }) {
    switch (template) {
      case UiTemplate.candyGlass:
        return AppStyle(
          compact: compact,
          radius: 22,
          panelRadius: 22,
          borderWidth: 1.0,
          background: AppBackgroundKind.gradient,
          pattern: AppPatternKind.dotsSparkles,
          backgroundIntensity: 1.0,
          patternOpacity: isDark ? 0.045 : 0.06,
        );
      case UiTemplate.stickerJournal:
        return AppStyle(
          compact: compact,
          radius: 20,
          panelRadius: 20,
          borderWidth: 1.0,
          background: AppBackgroundKind.gradient,
          pattern: AppPatternKind.dotsSparkles,
          backgroundIntensity: 0.9,
          patternOpacity: isDark ? 0.03 : 0.045,
        );
      case UiTemplate.neonHud:
        return AppStyle(
          compact: compact,
          radius: 14,
          panelRadius: 14,
          borderWidth: 1.2,
          background: AppBackgroundKind.gradient,
          pattern: AppPatternKind.grid,
          backgroundIntensity: 0.9,
          patternOpacity: isDark ? 0.05 : 0.06,
        );
      case UiTemplate.minimalCovers:
        return AppStyle(
          compact: compact,
          radius: 18,
          panelRadius: 18,
          borderWidth: 1.0,
          background: AppBackgroundKind.none,
          pattern: AppPatternKind.none,
          backgroundIntensity: 0.0,
          patternOpacity: 0.0,
        );
      case UiTemplate.washiWatercolor:
        return AppStyle(
          compact: compact,
          radius: 20,
          panelRadius: 20,
          borderWidth: 1.0,
          background: AppBackgroundKind.gradient,
          pattern: AppPatternKind.none,
          backgroundIntensity: 0.85,
          patternOpacity: 0.0,
        );
      case UiTemplate.pixelArcade:
        return AppStyle(
          compact: compact,
          radius: 10,
          panelRadius: 10,
          borderWidth: 1.4,
          background: AppBackgroundKind.none,
          pattern: AppPatternKind.pixels,
          backgroundIntensity: 0.7,
          patternOpacity: isDark ? 0.04 : 0.06,
        );
      case UiTemplate.mangaStoryboard:
        return AppStyle(
          compact: compact,
          radius: 16,
          panelRadius: 16,
          borderWidth: 1.0,
          background: AppBackgroundKind.none,
          pattern: AppPatternKind.halftone,
          backgroundIntensity: 0.8,
          patternOpacity: isDark ? 0.03 : 0.055,
        );
      case UiTemplate.proTool:
        return AppStyle(
          compact: true,
          radius: 14,
          panelRadius: 14,
          borderWidth: 1.0,
          background: AppBackgroundKind.none,
          pattern: AppPatternKind.grid,
          backgroundIntensity: 0.35,
          patternOpacity: isDark ? 0.02 : 0.03,
        );
    }
  }
}
