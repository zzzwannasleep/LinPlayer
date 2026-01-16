import 'dart:math' as math;

import 'package:flutter/material.dart';

import 'danmaku.dart';

class DanmakuStage extends StatefulWidget {
  const DanmakuStage({
    super.key,
    required this.enabled,
    required this.opacity,
    this.scale = 1.0,
    this.speed = 1.0,
    this.bold = true,
    this.scrollMaxLines = 10,
    this.topMaxLines = 0,
    this.bottomMaxLines = 0,
    this.preventOverlap = true,
  });

  final bool enabled;
  final double opacity;
  final double scale;
  final double speed;
  final bool bold;
  final int scrollMaxLines;
  final int topMaxLines;
  final int bottomMaxLines;
  final bool preventOverlap;

  @override
  State<DanmakuStage> createState() => DanmakuStageState();
}

class DanmakuStageState extends State<DanmakuStage>
    with TickerProviderStateMixin {
  static const double _baseFontSize = 18.0;
  static const double _lineGap = 8.0;
  static const double _topPadding = 6.0;
  static const double _scrollGapPx = 24.0;
  static const double _scrollBaseSpeedPxPerSec = 140.0;
  static const Duration _staticDuration = Duration(milliseconds: 4000);

  final List<_FlyingDanmaku> _scrolling = [];
  final List<_StaticDanmaku> _static = [];
  final Stopwatch _clock = Stopwatch();
  double _width = 0;
  double _height = 0;
  bool _paused = false;

  int _scrollRowCursor = 0;
  List<int> _scrollRowLastStartMs = const [];
  List<double> _scrollRowLastWidth = const [];

  int _topRowCursor = 0;
  List<int> _topRowExpireMs = const [];

  int _bottomRowCursor = 0;
  List<int> _bottomRowExpireMs = const [];

  @override
  void didUpdateWidget(covariant DanmakuStage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!widget.enabled && oldWidget.enabled) {
      clear();
    }
  }

  void clear() {
    for (final a in _scrolling) {
      a.controller.dispose();
    }
    for (final a in _static) {
      a.controller.dispose();
    }
    _scrolling.clear();
    _static.clear();
    _scrollRowLastStartMs = const [];
    _scrollRowLastWidth = const [];
    _topRowExpireMs = const [];
    _bottomRowExpireMs = const [];
    _scrollRowCursor = 0;
    _topRowCursor = 0;
    _bottomRowCursor = 0;
    _paused = false;
    _clock
      ..stop()
      ..reset();
    if (mounted) setState(() {});
  }

  void pause() {
    if (_paused) return;
    _paused = true;
    _clock.stop();
    for (final a in _scrolling) {
      a.controller.stop(canceled: false);
    }
    for (final a in _static) {
      a.controller.stop(canceled: false);
    }
  }

  void resume() {
    if (!_paused) return;
    _paused = false;
    if (!_clock.isRunning) _clock.start();
    for (final a in _scrolling) {
      if (a.controller.isAnimating) continue;
      if (a.controller.status == AnimationStatus.completed) continue;
      a.controller.forward();
    }
    for (final a in _static) {
      if (a.controller.isAnimating) continue;
      if (a.controller.status == AnimationStatus.completed) continue;
      a.controller.forward();
    }
  }

  void emit(DanmakuItem item) {
    if (!widget.enabled) return;
    if (_width <= 0 || _height <= 0) return;
    if (!_paused && !_clock.isRunning) _clock.start();

    final scale = widget.scale.clamp(0.5, 1.6);
    final fontSize = _baseFontSize * scale;
    final lineHeight = fontSize + _lineGap;

    final totalRows = math.max(1, (_height / lineHeight).floor());
    final cappedTotalRows = math.min(totalRows, 80);

    final desiredTopRows = widget.topMaxLines.clamp(0, 80);
    final desiredBottomRows = widget.bottomMaxLines.clamp(0, 80);
    final desiredScrollRows = widget.scrollMaxLines.clamp(0, 80);

    final topRows = math.min(cappedTotalRows, desiredTopRows);
    final bottomRows = math.min(cappedTotalRows - topRows, desiredBottomRows);
    final maxScrollAreaRows = cappedTotalRows - topRows - bottomRows;
    final scrollRows = math.min(maxScrollAreaRows, desiredScrollRows);

    switch (item.type) {
      case DanmakuType.scrolling:
        if (scrollRows <= 0) return;
        _emitScrolling(
          item,
          fontSize: fontSize,
          lineHeight: lineHeight,
          rowStart: topRows,
          rows: scrollRows,
        );
        break;
      case DanmakuType.top:
        if (topRows <= 0) return;
        _emitStatic(
          item,
          fontSize: fontSize,
          lineHeight: lineHeight,
          rowStart: 0,
          rows: topRows,
          isBottom: false,
        );
        break;
      case DanmakuType.bottom:
        if (bottomRows <= 0) return;
        _emitStatic(
          item,
          fontSize: fontSize,
          lineHeight: lineHeight,
          rowStart: cappedTotalRows - bottomRows,
          rows: bottomRows,
          isBottom: true,
        );
        break;
    }
  }

  void _emitScrolling(
    DanmakuItem item, {
    required double fontSize,
    required double lineHeight,
    required int rowStart,
    required int rows,
  }) {
    final fontWeight = widget.bold ? FontWeight.w600 : FontWeight.w400;
    final style = TextStyle(fontSize: fontSize, fontWeight: fontWeight);
    final painter = TextPainter(
      text: TextSpan(text: item.text, style: style),
      maxLines: 1,
      textDirection: TextDirection.ltr,
    )..layout();
    final textWidth = painter.width;

    final speedPxPerSec =
        _scrollBaseSpeedPxPerSec * widget.speed.clamp(0.4, 2.5);
    final nowMs = _clock.elapsedMilliseconds;

    int pickedRow;
    if (widget.preventOverlap) {
      if (_scrollRowLastStartMs.length != rows) {
        _scrollRowLastStartMs = List<int>.filled(rows, -1, growable: false);
        _scrollRowLastWidth = List<double>.filled(rows, 0, growable: false);
        _scrollRowCursor = 0;
      }

      var foundRow = -1;
      var earliestRow = 0;
      var earliestReadyMs = double.infinity;
      for (var i = 0; i < rows; i++) {
        final lastStart = _scrollRowLastStartMs[i];
        final lastWidth = _scrollRowLastWidth[i];
        final readyAtMs = lastStart < 0
            ? 0.0
            : lastStart + ((lastWidth + _scrollGapPx) / speedPxPerSec) * 1000.0;
        if (readyAtMs <= nowMs) {
          foundRow = i;
          break;
        }
        if (readyAtMs < earliestReadyMs) {
          earliestReadyMs = readyAtMs;
          earliestRow = i;
        }
      }
      pickedRow = foundRow < 0 ? earliestRow : foundRow;
      _scrollRowLastStartMs[pickedRow] = nowMs;
      _scrollRowLastWidth[pickedRow] = textWidth;
    } else {
      pickedRow = _scrollRowCursor++ % rows;
    }

    final top = (rowStart + pickedRow) * lineHeight + _topPadding;
    final distance = _width + textWidth + _scrollGapPx;
    final seconds = (distance / speedPxPerSec).clamp(3.0, 16.0);
    final controller = AnimationController(
      vsync: this,
      duration: Duration(milliseconds: (seconds * 1000).round()),
    );
    final animation = Tween<double>(
      begin: _width + 12,
      end: -textWidth - 12,
    ).animate(CurvedAnimation(parent: controller, curve: Curves.linear));

    final flying = _FlyingDanmaku(
      item: item,
      controller: controller,
      left: animation,
      top: top,
    );

    controller.addStatusListener((s) {
      if (s != AnimationStatus.completed) return;
      _scrolling.remove(flying);
      controller.dispose();
      if (mounted) setState(() {});
    });

    _scrolling.add(flying);
    if (!_paused) controller.forward();
    if (mounted) setState(() {});
  }

  void _emitStatic(
    DanmakuItem item, {
    required double fontSize,
    required double lineHeight,
    required int rowStart,
    required int rows,
    required bool isBottom,
  }) {
    final nowMs = _clock.elapsedMilliseconds;
    final durationMs = _staticDuration.inMilliseconds;

    int pickedRow;
    if (widget.preventOverlap) {
      if (isBottom) {
        if (_bottomRowExpireMs.length != rows) {
          _bottomRowExpireMs = List<int>.filled(rows, 0, growable: false);
          _bottomRowCursor = 0;
        }
        pickedRow = _pickRowByExpire(_bottomRowExpireMs, nowMs);
        _bottomRowExpireMs[pickedRow] = nowMs + durationMs;
      } else {
        if (_topRowExpireMs.length != rows) {
          _topRowExpireMs = List<int>.filled(rows, 0, growable: false);
          _topRowCursor = 0;
        }
        pickedRow = _pickRowByExpire(_topRowExpireMs, nowMs);
        _topRowExpireMs[pickedRow] = nowMs + durationMs;
      }
    } else {
      if (isBottom) {
        pickedRow = _bottomRowCursor++ % rows;
      } else {
        pickedRow = _topRowCursor++ % rows;
      }
    }

    final top = (rowStart + pickedRow) * lineHeight + _topPadding;

    final controller = AnimationController(
      vsync: this,
      duration: _staticDuration,
    );
    final opacity = TweenSequence<double>([
      TweenSequenceItem(
        tween: Tween<double>(begin: 0, end: 1)
            .chain(CurveTween(curve: Curves.easeOut)),
        weight: 10,
      ),
      TweenSequenceItem(
        tween: ConstantTween<double>(1),
        weight: 80,
      ),
      TweenSequenceItem(
        tween: Tween<double>(begin: 1, end: 0)
            .chain(CurveTween(curve: Curves.easeIn)),
        weight: 10,
      ),
    ]).animate(controller);

    final floating = _StaticDanmaku(
      item: item,
      controller: controller,
      opacity: opacity,
      top: top,
    );

    controller.addStatusListener((s) {
      if (s != AnimationStatus.completed) return;
      _static.remove(floating);
      controller.dispose();
      if (mounted) setState(() {});
    });

    _static.add(floating);
    if (!_paused) controller.forward();
    if (mounted) setState(() {});
  }

  static int _pickRowByExpire(List<int> expireMs, int nowMs) {
    var foundRow = -1;
    var earliestRow = 0;
    var earliestReadyMs = double.infinity;
    for (var i = 0; i < expireMs.length; i++) {
      final readyAtMs = expireMs[i].toDouble();
      if (readyAtMs <= nowMs) {
        foundRow = i;
        break;
      }
      if (readyAtMs < earliestReadyMs) {
        earliestReadyMs = readyAtMs;
        earliestRow = i;
      }
    }
    return foundRow < 0 ? earliestRow : foundRow;
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
                for (final a in List<_FlyingDanmaku>.from(_scrolling))
                  AnimatedBuilder(
                    animation: a.left,
                    builder: (context, _) {
                      return Positioned(
                        left: a.left.value,
                        top: a.top,
                        child: _DanmakuText(
                          a.item.text,
                          fontSize:
                              _baseFontSize * widget.scale.clamp(0.5, 1.6),
                          bold: widget.bold,
                        ),
                      );
                    },
                  ),
                for (final a in List<_StaticDanmaku>.from(_static))
                  Positioned(
                    left: 0,
                    right: 0,
                    top: a.top,
                    child: FadeTransition(
                      opacity: a.opacity,
                      child: Center(
                        child: _DanmakuText(
                          a.item.text,
                          fontSize:
                              _baseFontSize * widget.scale.clamp(0.5, 1.6),
                          bold: widget.bold,
                        ),
                      ),
                    ),
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
  const _DanmakuText(
    this.text, {
    required this.fontSize,
    required this.bold,
  });

  final String text;
  final double fontSize;
  final bool bold;

  @override
  Widget build(BuildContext context) {
    return Text(
      text,
      maxLines: 1,
      overflow: TextOverflow.clip,
      style: TextStyle(
        fontSize: fontSize,
        color: Colors.white,
        fontWeight: bold ? FontWeight.w600 : FontWeight.w400,
        shadows: const [
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

class _StaticDanmaku {
  _StaticDanmaku({
    required this.item,
    required this.controller,
    required this.opacity,
    required this.top,
  });

  final DanmakuItem item;
  final AnimationController controller;
  final Animation<double> opacity;
  final double top;
}
