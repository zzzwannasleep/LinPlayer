import 'dart:math' as math;

import 'package:flutter/material.dart';

enum DesktopPageTransitionStyle {
  push,
  fade,
  flip,
  stack,
}

Route<T> buildDesktopPageRoute<T>({
  required WidgetBuilder builder,
  DesktopPageTransitionStyle transition = DesktopPageTransitionStyle.push,
  Duration duration = const Duration(milliseconds: 360),
  RouteSettings? settings,
}) {
  return PageRouteBuilder<T>(
    settings: settings,
    transitionDuration: duration,
    reverseTransitionDuration: duration,
    pageBuilder: (context, _, __) => builder(context),
    transitionsBuilder: (context, animation, secondaryAnimation, child) {
      final curved = CurvedAnimation(
        parent: animation,
        curve: Curves.easeOutCubic,
        reverseCurve: Curves.easeInCubic,
      );

      switch (transition) {
        case DesktopPageTransitionStyle.push:
          return FadeTransition(
            opacity: Tween<double>(begin: 0.18, end: 1.0).animate(curved),
            child: SlideTransition(
              position: Tween<Offset>(
                begin: const Offset(0.08, 0),
                end: Offset.zero,
              ).animate(curved),
              child: child,
            ),
          );
        case DesktopPageTransitionStyle.fade:
          return FadeTransition(
            opacity: curved,
            child: child,
          );
        case DesktopPageTransitionStyle.flip:
          return FadeTransition(
            opacity: Tween<double>(begin: 0.2, end: 1.0).animate(curved),
            child: AnimatedBuilder(
              animation: curved,
              child: child,
              builder: (context, child) {
                final matrix = Matrix4.identity()
                  ..setEntry(3, 2, 0.0012)
                  ..rotateY((1 - curved.value) * (math.pi / 22));
                return Transform(
                  alignment: Alignment.center,
                  transform: matrix,
                  child: child,
                );
              },
            ),
          );
        case DesktopPageTransitionStyle.stack:
          return FadeTransition(
            opacity: Tween<double>(begin: 0.0, end: 1.0).animate(curved),
            child: ScaleTransition(
              scale: Tween<double>(begin: 0.97, end: 1.0).animate(curved),
              child: child,
            ),
          );
      }
    },
  );
}
