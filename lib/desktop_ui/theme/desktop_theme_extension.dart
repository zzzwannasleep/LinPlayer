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
    required this.textMuted,
    required this.accent,
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
  final Color textMuted;
  final Color accent;
  final Color hover;
  final Color focus;

  factory DesktopThemeExtension.fallback(Brightness brightness) {
    if (brightness == Brightness.dark) {
      return const DesktopThemeExtension(
        background: Color(0xFF0A101A),
        backgroundGradientStart: Color(0xFF0A101A),
        backgroundGradientEnd: Color(0xFF101B2A),
        sidebarColor: Color(0xFF0D1624),
        surface: Color(0xCC111B2A),
        surfaceElevated: Color(0xE619273A),
        border: Color(0x335B6A7D),
        textPrimary: Color(0xFFF1F5FB),
        textMuted: Color(0xFFA3AFBF),
        accent: Color(0xFF2D8CFF),
        hover: Color(0x2A7FB0FF),
        focus: Color(0xFF79B6FF),
      );
    }
    return const DesktopThemeExtension(
      background: Color(0xFFEAF0F8),
      backgroundGradientStart: Color(0xFFF4F8FF),
      backgroundGradientEnd: Color(0xFFE5ECF7),
      sidebarColor: Color(0xFFF5F8FD),
      surface: Color(0xD8FFFFFF),
      surfaceElevated: Color(0xF6FFFFFF),
      border: Color(0x290D243F),
      textPrimary: Color(0xFF102038),
      textMuted: Color(0xFF56667D),
      accent: Color(0xFF1E6FD6),
      hover: Color(0x122D76D4),
      focus: Color(0xFF3A8CFF),
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
    Color? textMuted,
    Color? accent,
    Color? hover,
    Color? focus,
  }) {
    return DesktopThemeExtension(
      background: background ?? this.background,
      backgroundGradientStart:
          backgroundGradientStart ?? this.backgroundGradientStart,
      backgroundGradientEnd: backgroundGradientEnd ?? this.backgroundGradientEnd,
      sidebarColor: sidebarColor ?? this.sidebarColor,
      surface: surface ?? this.surface,
      surfaceElevated: surfaceElevated ?? this.surfaceElevated,
      border: border ?? this.border,
      textPrimary: textPrimary ?? this.textPrimary,
      textMuted: textMuted ?? this.textMuted,
      accent: accent ?? this.accent,
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
      backgroundGradientStart:
          Color.lerp(backgroundGradientStart, other.backgroundGradientStart, t) ??
              backgroundGradientStart,
      backgroundGradientEnd:
          Color.lerp(backgroundGradientEnd, other.backgroundGradientEnd, t) ??
              backgroundGradientEnd,
      sidebarColor: Color.lerp(sidebarColor, other.sidebarColor, t) ?? sidebarColor,
      surface: Color.lerp(surface, other.surface, t) ?? surface,
      surfaceElevated:
          Color.lerp(surfaceElevated, other.surfaceElevated, t) ?? surfaceElevated,
      border: Color.lerp(border, other.border, t) ?? border,
      textPrimary: Color.lerp(textPrimary, other.textPrimary, t) ?? textPrimary,
      textMuted: Color.lerp(textMuted, other.textMuted, t) ?? textMuted,
      accent: Color.lerp(accent, other.accent, t) ?? accent,
      hover: Color.lerp(hover, other.hover, t) ?? hover,
      focus: Color.lerp(focus, other.focus, t) ?? focus,
    );
  }
}
