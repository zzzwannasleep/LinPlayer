import 'dart:ui';

import 'package:flutter/material.dart';

enum AppBackgroundKind {
  none,
  gradient,
}

enum AppPatternKind {
  none,
  dotsSparkles,
  grid,
  halftone,
  pixels,
}

@immutable
class AppStyle extends ThemeExtension<AppStyle> {
  const AppStyle({
    this.compact = false,
    this.radius = 18,
    this.panelRadius = 18,
    this.borderWidth = 1,
    this.background = AppBackgroundKind.none,
    this.pattern = AppPatternKind.none,
    this.backgroundIntensity = 0,
    this.patternOpacity = 0,
  });

  final bool compact;
  final double radius;
  final double panelRadius;
  final double borderWidth;
  final AppBackgroundKind background;
  final AppPatternKind pattern;
  final double backgroundIntensity;
  final double patternOpacity;

  @override
  AppStyle copyWith({
    bool? compact,
    double? radius,
    double? panelRadius,
    double? borderWidth,
    AppBackgroundKind? background,
    AppPatternKind? pattern,
    double? backgroundIntensity,
    double? patternOpacity,
  }) {
    return AppStyle(
      compact: compact ?? this.compact,
      radius: radius ?? this.radius,
      panelRadius: panelRadius ?? this.panelRadius,
      borderWidth: borderWidth ?? this.borderWidth,
      background: background ?? this.background,
      pattern: pattern ?? this.pattern,
      backgroundIntensity: backgroundIntensity ?? this.backgroundIntensity,
      patternOpacity: patternOpacity ?? this.patternOpacity,
    );
  }

  @override
  AppStyle lerp(ThemeExtension<AppStyle>? other, double t) {
    if (other is! AppStyle) return this;
    return AppStyle(
      compact: t < 0.5 ? compact : other.compact,
      radius: lerpDouble(radius, other.radius, t) ?? radius,
      panelRadius: lerpDouble(panelRadius, other.panelRadius, t) ?? panelRadius,
      borderWidth: lerpDouble(borderWidth, other.borderWidth, t) ?? borderWidth,
      background: t < 0.5 ? background : other.background,
      pattern: t < 0.5 ? pattern : other.pattern,
      backgroundIntensity:
          lerpDouble(backgroundIntensity, other.backgroundIntensity, t) ??
              backgroundIntensity,
      patternOpacity:
          lerpDouble(patternOpacity, other.patternOpacity, t) ?? patternOpacity,
    );
  }
}
