import 'package:flutter/widgets.dart';

class UiScaleScope extends InheritedWidget {
  const UiScaleScope({
    super.key,
    required this.scale,
    required super.child,
  });

  final double scale;

  static UiScaleScope? maybeOf(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<UiScaleScope>();

  /// UI scale factor based on the current logical screen width.
  ///
  /// - Landscape tablets typically end up at `1.0`.
  /// - Portrait tablets / phones scale up (clamped) to avoid tiny UI.
  static double autoScaleFor(BuildContext context) {
    final width = MediaQuery.sizeOf(context).width;
    if (width <= 0) return 1.0;

    const referenceWidth = 1000.0;
    const minScale = 1.0;
    const maxScale = 1.3;
    return (referenceWidth / width).clamp(minScale, maxScale).toDouble();
  }

  @override
  bool updateShouldNotify(UiScaleScope oldWidget) => scale != oldWidget.scale;
}

extension UiScaleContext on BuildContext {
  double get uiScale {
    final scoped = UiScaleScope.maybeOf(this);
    if (scoped != null) return scoped.scale;
    return UiScaleScope.autoScaleFor(this);
  }
}
