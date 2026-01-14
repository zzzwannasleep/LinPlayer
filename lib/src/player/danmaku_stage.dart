import 'dart:math' as math;

import 'package:flutter/material.dart';

import 'danmaku.dart';

class DanmakuStage extends StatefulWidget {
  const DanmakuStage({
    super.key,
    required this.enabled,
    required this.opacity,
  });

  final bool enabled;
  final double opacity;

  @override
  State<DanmakuStage> createState() => DanmakuStageState();
}

class DanmakuStageState extends State<DanmakuStage> with TickerProviderStateMixin {
  final List<_FlyingDanmaku> _active = [];
  double _width = 0;
  double _height = 0;
  int _rowCursor = 0;

  @override
  void didUpdateWidget(covariant DanmakuStage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!widget.enabled && oldWidget.enabled) {
      clear();
    }
  }

  void clear() {
    for (final a in _active) {
      a.controller.dispose();
    }
    _active.clear();
    if (mounted) setState(() {});
  }

  void emit(DanmakuItem item) {
    if (!widget.enabled) return;
    if (_width <= 0 || _height <= 0) return;

    const fontSize = 18.0;
    final painter = TextPainter(
      text: TextSpan(text: item.text, style: const TextStyle(fontSize: fontSize)),
      maxLines: 1,
      textDirection: TextDirection.ltr,
    )..layout();
    final textWidth = painter.width;

    const lineHeight = (fontSize + 8);
    final rows = math.max(1, (_height / lineHeight).floor());
    final row = _rowCursor++ % rows;
    final top = row * lineHeight + 6;

    final distance = _width + textWidth + 24;
    const speed = 140.0; // px/s
    final seconds = (distance / speed).clamp(4.0, 12.0);
    final controller =
        AnimationController(vsync: this, duration: Duration(milliseconds: (seconds * 1000).round()));
    final animation = Tween<double>(begin: _width + 12, end: -textWidth - 12).animate(
      CurvedAnimation(parent: controller, curve: Curves.linear),
    );

    final flying = _FlyingDanmaku(
      item: item,
      controller: controller,
      left: animation,
      top: top,
    );

    controller.addStatusListener((s) {
      if (s != AnimationStatus.completed) return;
      _active.remove(flying);
      controller.dispose();
      if (mounted) setState(() {});
    });

    _active.add(flying);
    controller.forward();
    if (mounted) setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    if (!widget.enabled) return const SizedBox.shrink();

    return IgnorePointer(
      child: LayoutBuilder(
        builder: (context, constraints) {
          _width = constraints.maxWidth;
          _height = constraints.maxHeight;

          return Opacity(
            opacity: widget.opacity.clamp(0, 1),
            child: Stack(
              children: [
                for (final a in List<_FlyingDanmaku>.from(_active))
                  AnimatedBuilder(
                    animation: a.left,
                    builder: (context, _) {
                      return Positioned(
                        left: a.left.value,
                        top: a.top,
                        child: _DanmakuText(a.item.text),
                      );
                    },
                  ),
              ],
            ),
          );
        },
      ),
    );
  }
}

class _DanmakuText extends StatelessWidget {
  const _DanmakuText(this.text);

  final String text;

  @override
  Widget build(BuildContext context) {
    return Text(
      text,
      maxLines: 1,
      overflow: TextOverflow.clip,
      style: const TextStyle(
        fontSize: 18,
        color: Colors.white,
        fontWeight: FontWeight.w600,
        shadows: [
          Shadow(
            blurRadius: 4,
            offset: Offset(1, 1),
            color: Colors.black87,
          ),
        ],
      ),
    );
  }
}

class _FlyingDanmaku {
  _FlyingDanmaku({
    required this.item,
    required this.controller,
    required this.left,
    required this.top,
  });

  final DanmakuItem item;
  final AnimationController controller;
  final Animation<double> left;
  final double top;
}
