import 'package:flutter/material.dart';

@immutable
class DesktopThemeExtension extends ThemeExtension<DesktopThemeExtension> {
  const DesktopThemeExtension({
    required this.background,
    required this.backgroundGradientStart,
    required this.backgroundGradientEnd,
    required this.sidebarColor,
    required this.surface,
    required this.surfaceElevated,
    required this.border,
    required this.textPrimary,
    required this.textSecondary,
    required this.textMuted,
    required this.link,
    required this.accent,
    required this.headerBackground,
    required this.headerScrolledBackground,
    required this.topTabBackground,
    required this.topTabActiveBackground,
    required this.topTabInactiveForeground,
    required this.categoryOverlay,
    required this.posterOverlay,
    required this.posterControlBackground,
    required this.posterBadgeBackground,
    required this.shadowColor,
    required this.hover,
    required this.focus,
  });

  final Color background;
  final Color backgroundGradientStart;
  final Color backgroundGradientEnd;
  final Color sidebarColor;
  final Color surface;
  final Color surfaceElevated;
  final Color border;
  final Color textPrimary;
  final Color textSecondary;
  final Color textMuted;
  final Color link;
  final Color accent;
  final Color headerBackground;
  final Color headerScrolledBackground;
  final Color topTabBackground;
  final Color topTabActiveBackground;
  final Color topTabInactiveForeground;
  final Color categoryOverlay;
  final Color posterOverlay;
  final Color posterControlBackground;
  final Color posterBadgeBackground;
  final Color shadowColor;
  final Color hover;
  final Color focus;

  factory DesktopThemeExtension.fallback(Brightness brightness) {
    if (brightness == Brightness.dark) {
      return const DesktopThemeExtension(
        background: Color(0xFF070707),
        backgroundGradientStart: Color(0xFF0B0B0B),
        backgroundGradientEnd: Color(0xFF020202),
        sidebarColor: Color(0xF0111111),
        surface: Color(0xFF161616),
        surfaceElevated: Color(0xFF1E1E1E),
        border: Color(0x33474747),
        textPrimary: Color(0xFFFFFFFF),
        textSecondary: Color(0xFFD0D0D0),
        textMuted: Color(0xFF7F7F7F),
        link: Color(0xFFA7A7A7),
        accent: Color(0xFF4CAF50),
        headerBackground: Color(0x66000000),
        headerScrolledBackground: Color(0xF0000000),
        topTabBackground: Color(0x331A1A1A),
        topTabActiveBackground: Color(0xFF232323),
        topTabInactiveForeground: Color(0xAAFFFFFF),
        categoryOverlay: Color(0xAA000000),
        posterOverlay: Color(0xBF000000),
        posterControlBackground: Color(0xA8000000),
        posterBadgeBackground: Color(0xFF4CAF50),
        shadowColor: Color(0x8A000000),
        hover: Color(0x424CAF50),
        focus: Color(0xFF78D37C),
      );
    }
    return const DesktopThemeExtension(
      background: Color(0xFF1A1A1A),
      backgroundGradientStart: Color(0xFF1A1A1A),
      backgroundGradientEnd: Color(0xFF0D0D0D),
      sidebarColor: Color(0xEB202020),
      surface: Color(0xFF242424),
      surfaceElevated: Color(0xFF2A2A2A),
      border: Color(0x33464646),
      textPrimary: Color(0xFFFFFFFF),
      textSecondary: Color(0xFFCECECE),
      textMuted: Color(0xFF8E8E8E),
      link: Color(0xFFAAAAAA),
      accent: Color(0xFF4CAF50),
      headerBackground: Color(0x4A0D0D0D),
      headerScrolledBackground: Color(0xE60D0D0D),
      topTabBackground: Color(0x332A2A2A),
      topTabActiveBackground: Color(0xFF2A2A2A),
      topTabInactiveForeground: Color(0xB3FFFFFF),
      categoryOverlay: Color(0x8A000000),
      posterOverlay: Color(0xB3000000),
      posterControlBackground: Color(0xA3000000),
      posterBadgeBackground: Color(0xFF4CAF50),
      shadowColor: Color(0x70000000),
      hover: Color(0x394CAF50),
      focus: Color(0xFF6CCF70),
    );
  }

  static DesktopThemeExtension of(BuildContext context) {
    final fallback = DesktopThemeExtension.fallback(
      Theme.of(context).brightness,
    );
    return Theme.of(context).extension<DesktopThemeExtension>() ?? fallback;
  }

  @override
  DesktopThemeExtension copyWith({
    Color? background,
    Color? backgroundGradientStart,
    Color? backgroundGradientEnd,
    Color? sidebarColor,
    Color? surface,
    Color? surfaceElevated,
    Color? border,
    Color? textPrimary,
    Color? textSecondary,
    Color? textMuted,
    Color? link,
    Color? accent,
    Color? headerBackground,
    Color? headerScrolledBackground,
    Color? topTabBackground,
    Color? topTabActiveBackground,
    Color? topTabInactiveForeground,
    Color? categoryOverlay,
    Color? posterOverlay,
    Color? posterControlBackground,
    Color? posterBadgeBackground,
    Color? shadowColor,
    Color? hover,
    Color? focus,
  }) {
    return DesktopThemeExtension(
      background: background ?? this.background,
      backgroundGradientStart:
          backgroundGradientStart ?? this.backgroundGradientStart,
      backgroundGradientEnd:
          backgroundGradientEnd ?? this.backgroundGradientEnd,
      sidebarColor: sidebarColor ?? this.sidebarColor,
      surface: surface ?? this.surface,
      surfaceElevated: surfaceElevated ?? this.surfaceElevated,
      border: border ?? this.border,
      textPrimary: textPrimary ?? this.textPrimary,
      textSecondary: textSecondary ?? this.textSecondary,
      textMuted: textMuted ?? this.textMuted,
      link: link ?? this.link,
      accent: accent ?? this.accent,
      headerBackground: headerBackground ?? this.headerBackground,
      headerScrolledBackground:
          headerScrolledBackground ?? this.headerScrolledBackground,
      topTabBackground: topTabBackground ?? this.topTabBackground,
      topTabActiveBackground:
          topTabActiveBackground ?? this.topTabActiveBackground,
      topTabInactiveForeground:
          topTabInactiveForeground ?? this.topTabInactiveForeground,
      categoryOverlay: categoryOverlay ?? this.categoryOverlay,
      posterOverlay: posterOverlay ?? this.posterOverlay,
      posterControlBackground:
          posterControlBackground ?? this.posterControlBackground,
      posterBadgeBackground:
          posterBadgeBackground ?? this.posterBadgeBackground,
      shadowColor: shadowColor ?? this.shadowColor,
      hover: hover ?? this.hover,
      focus: focus ?? this.focus,
    );
  }

  @override
  ThemeExtension<DesktopThemeExtension> lerp(
    covariant ThemeExtension<DesktopThemeExtension>? other,
    double t,
  ) {
    if (other is! DesktopThemeExtension) {
      return this;
    }
    return DesktopThemeExtension(
      background: Color.lerp(background, other.background, t) ?? background,
      backgroundGradientStart: Color.lerp(
              backgroundGradientStart, other.backgroundGradientStart, t) ??
          backgroundGradientStart,
      backgroundGradientEnd:
          Color.lerp(backgroundGradientEnd, other.backgroundGradientEnd, t) ??
              backgroundGradientEnd,
      sidebarColor:
          Color.lerp(sidebarColor, other.sidebarColor, t) ?? sidebarColor,
      surface: Color.lerp(surface, other.surface, t) ?? surface,
      surfaceElevated: Color.lerp(surfaceElevated, other.surfaceElevated, t) ??
          surfaceElevated,
      border: Color.lerp(border, other.border, t) ?? border,
      textPrimary: Color.lerp(textPrimary, other.textPrimary, t) ?? textPrimary,
      textSecondary:
          Color.lerp(textSecondary, other.textSecondary, t) ?? textSecondary,
      textMuted: Color.lerp(textMuted, other.textMuted, t) ?? textMuted,
      link: Color.lerp(link, other.link, t) ?? link,
      accent: Color.lerp(accent, other.accent, t) ?? accent,
      headerBackground:
          Color.lerp(headerBackground, other.headerBackground, t) ??
              headerBackground,
      headerScrolledBackground: Color.lerp(
              headerScrolledBackground, other.headerScrolledBackground, t) ??
          headerScrolledBackground,
      topTabBackground:
          Color.lerp(topTabBackground, other.topTabBackground, t) ??
              topTabBackground,
      topTabActiveBackground:
          Color.lerp(topTabActiveBackground, other.topTabActiveBackground, t) ??
              topTabActiveBackground,
      topTabInactiveForeground: Color.lerp(
              topTabInactiveForeground, other.topTabInactiveForeground, t) ??
          topTabInactiveForeground,
      categoryOverlay: Color.lerp(categoryOverlay, other.categoryOverlay, t) ??
          categoryOverlay,
      posterOverlay:
          Color.lerp(posterOverlay, other.posterOverlay, t) ?? posterOverlay,
      posterControlBackground: Color.lerp(
              posterControlBackground, other.posterControlBackground, t) ??
          posterControlBackground,
      posterBadgeBackground:
          Color.lerp(posterBadgeBackground, other.posterBadgeBackground, t) ??
              posterBadgeBackground,
      shadowColor: Color.lerp(shadowColor, other.shadowColor, t) ?? shadowColor,
      hover: Color.lerp(hover, other.hover, t) ?? hover,
      focus: Color.lerp(focus, other.focus, t) ?? focus,
    );
  }
}
