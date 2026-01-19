import 'dart:ui';

import 'package:flutter/material.dart';

@immutable
class AppStyle extends ThemeExtension<AppStyle> {
  const AppStyle({
    this.kawaii = false,
    this.compact = false,
    this.radius = 18,
    this.panelRadius = 18,
    this.borderWidth = 1,
    this.backgroundIntensity = 0,
    this.patternOpacity = 0,
  });

  final bool kawaii;
  final bool compact;
  final double radius;
  final double panelRadius;
  final double borderWidth;
  final double backgroundIntensity;
  final double patternOpacity;

  @override
  AppStyle copyWith({
    bool? kawaii,
    bool? compact,
    double? radius,
    double? panelRadius,
    double? borderWidth,
    double? backgroundIntensity,
    double? patternOpacity,
  }) {
    return AppStyle(
      kawaii: kawaii ?? this.kawaii,
      compact: compact ?? this.compact,
      radius: radius ?? this.radius,
      panelRadius: panelRadius ?? this.panelRadius,
      borderWidth: borderWidth ?? this.borderWidth,
      backgroundIntensity: backgroundIntensity ?? this.backgroundIntensity,
      patternOpacity: patternOpacity ?? this.patternOpacity,
    );
  }

  @override
  AppStyle lerp(ThemeExtension<AppStyle>? other, double t) {
    if (other is! AppStyle) return this;
    return AppStyle(
      kawaii: t < 0.5 ? kawaii : other.kawaii,
      compact: t < 0.5 ? compact : other.compact,
      radius: lerpDouble(radius, other.radius, t) ?? radius,
      panelRadius: lerpDouble(panelRadius, other.panelRadius, t) ?? panelRadius,
      borderWidth: lerpDouble(borderWidth, other.borderWidth, t) ?? borderWidth,
      backgroundIntensity:
          lerpDouble(backgroundIntensity, other.backgroundIntensity, t) ??
              backgroundIntensity,
      patternOpacity:
          lerpDouble(patternOpacity, other.patternOpacity, t) ?? patternOpacity,
    );
  }
}
