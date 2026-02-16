import 'package:flutter/material.dart';

class WindowPaddingContainer extends StatelessWidget {
  const WindowPaddingContainer({
    super.key,
    required this.child,
    this.padding = const EdgeInsets.fromLTRB(16, 14, 16, 16),
    this.dragRegionHeight = 36,
    this.onDragRegionPointerDown,
    this.dragRegion,
  });

  final Widget child;
  final EdgeInsetsGeometry padding;

  /// Reserved area for borderless-window drag integration.
  final double dragRegionHeight;
  final ValueChanged<PointerDownEvent>? onDragRegionPointerDown;
  final Widget? dragRegion;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: padding,
      child: Stack(
        children: [
          Positioned.fill(child: child),
          if (dragRegionHeight > 0)
            Positioned(
              left: 0,
              right: 0,
              top: 0,
              height: dragRegionHeight,
              child: Listener(
                behavior: HitTestBehavior.translucent,
                onPointerDown: onDragRegionPointerDown,
                child: dragRegion ?? const SizedBox.expand(),
              ),
            ),
        ],
      ),
    );
  }
}
