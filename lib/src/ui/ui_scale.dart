import 'package:flutter/material.dart';

extension UiScaleContext on BuildContext {
  /// UI scale factor based on the current logical screen width.
  ///
  /// - Landscape tablets typically end up at `1.0`.
  /// - Portrait tablets / phones scale up (clamped) to avoid tiny UI.
  double get uiScale {
    final width = MediaQuery.sizeOf(this).width;
    if (width <= 0) return 1.0;

    const referenceWidth = 1000.0;
    const minScale = 1.0;
    const maxScale = 1.3;
    return (referenceWidth / width).clamp(minScale, maxScale);
  }
}
