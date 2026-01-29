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
    this.timeScale = 1.0,
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
  final double timeScale;
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
  static const Duration _staticBaseDuration = Duration(milliseconds: 4000);
  static const double _scrollMinDurationSec = 1.8;
  static const double _scrollMaxDurationSec = 16.0;

  final List<_FlyingDanmaku> _scrolling = [];
  final List<_StaticDanmaku> _static = [];
  double _width = 0;
  double _height = 0;
  bool _paused = false;

  int _scrollRowCursor = 0;
  List<_FlyingDanmaku?> _scrollRowLast = const [];

  int _topRowCursor = 0;
  List<_StaticDanmaku?> _topRowLast = const [];

  int _bottomRowCursor = 0;
  List<_StaticDanmaku?> _bottomRowLast = const [];

  static double _clampSpeed(double v) => v.clamp(0.4, 2.5).toDouble();
  static double _clampTimeScale(double v) => v.clamp(0.25, 4.0).toDouble();

  double get _effectiveTimeScale => _clampTimeScale(widget.timeScale);

  double get _effectiveScrollSpeedMultiplier =>
      _clampSpeed(widget.speed) * _effectiveTimeScale;

  Duration get _effectiveStaticDuration {
    final scaled = _staticBaseDuration.inMilliseconds / _effectiveTimeScale;
    final ms = scaled.round().clamp(800, 20000).toInt();
    return Duration(milliseconds: ms);
  }

  @override
  void didUpdateWidget(covariant DanmakuStage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!widget.enabled && oldWidget.enabled) {
      clear();
      return;
    }

    if (widget.enabled &&
        widget.preventOverlap &&
        !oldWidget.preventOverlap &&
        (_scrolling.isNotEmpty || _static.isNotEmpty)) {
      // We don't track row occupancy when overlap prevention is off.
      // Clearing avoids immediately emitting into already-occupied rows.
      clear();
      return;
    }

    final speedChanged = (widget.speed - oldWidget.speed).abs() > 0.0001;
    final timeScaleChanged =
        (widget.timeScale - oldWidget.timeScale).abs() > 0.0001;
    if (widget.enabled && (speedChanged || timeScaleChanged)) {
      _rescaleActiveDanmaku();
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
    _scrollRowLast = const [];
    _topRowLast = const [];
    _bottomRowLast = const [];
    _scrollRowCursor = 0;
    _topRowCursor = 0;
    _bottomRowCursor = 0;
    _paused = false;
    if (mounted) setState(() {});
  }

  void pause() {
    if (_paused) return;
    _paused = true;
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

    int pickedRow;
    if (widget.preventOverlap) {
      if (_scrollRowLast.length != rows) {
        _scrollRowLast = List<_FlyingDanmaku?>.filled(
          rows,
          null,
          growable: false,
        );
        _scrollRowCursor = 0;
      }

      final startX = _width + 12;
      var found = -1;
      for (var i = 0; i < rows; i++) {
        final row = (_scrollRowCursor + i) % rows;
        final last = _scrollRowLast[row];
        if (last == null ||
            last.controller.status == AnimationStatus.completed) {
          found = row;
          break;
        }
        final rightEdge = last.left.value + last.textWidth;
        if (rightEdge + _scrollGapPx <= startX) {
          found = row;
          break;
        }
      }
      if (found < 0) return;
      pickedRow = found;
      _scrollRowCursor = (pickedRow + 1) % rows;
    } else {
      pickedRow = _scrollRowCursor++ % rows;
    }

    final top = (rowStart + pickedRow) * lineHeight + _topPadding;
    final distance = _width + textWidth + _scrollGapPx;
    final seconds = (distance /
            (_scrollBaseSpeedPxPerSec * _effectiveScrollSpeedMultiplier))
        .clamp(_scrollMinDurationSec, _scrollMaxDurationSec);
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
      row: pickedRow,
      canvasWidth: _width,
      textWidth: textWidth,
    );

    controller.addStatusListener((s) {
      if (s != AnimationStatus.completed) return;
      _scrolling.remove(flying);
      if (_scrollRowLast.length > flying.row &&
          _scrollRowLast[flying.row] == flying) {
        _scrollRowLast[flying.row] = null;
      }
      controller.dispose();
      if (mounted) setState(() {});
    });

    _scrolling.add(flying);
    if (widget.preventOverlap &&
        pickedRow >= 0 &&
        pickedRow < _scrollRowLast.length) {
      _scrollRowLast[pickedRow] = flying;
    }
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
    final duration = _effectiveStaticDuration;

    int pickedRow;
    if (widget.preventOverlap) {
      if (isBottom) {
        if (_bottomRowLast.length != rows) {
          _bottomRowLast =
              List<_StaticDanmaku?>.filled(rows, null, growable: false);
          _bottomRowCursor = 0;
        }
        var found = -1;
        for (var i = 0; i < rows; i++) {
          final row = (_bottomRowCursor + i) % rows;
          final last = _bottomRowLast[row];
          if (last == null ||
              last.controller.status == AnimationStatus.completed) {
            found = row;
            break;
          }
        }
        if (found < 0) return;
        pickedRow = found;
        _bottomRowCursor = (pickedRow + 1) % rows;
      } else {
        if (_topRowLast.length != rows) {
          _topRowLast =
              List<_StaticDanmaku?>.filled(rows, null, growable: false);
          _topRowCursor = 0;
        }
        var found = -1;
        for (var i = 0; i < rows; i++) {
          final row = (_topRowCursor + i) % rows;
          final last = _topRowLast[row];
          if (last == null ||
              last.controller.status == AnimationStatus.completed) {
            found = row;
            break;
          }
        }
        if (found < 0) return;
        pickedRow = found;
        _topRowCursor = (pickedRow + 1) % rows;
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
      duration: duration,
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
      row: pickedRow,
      isBottom: isBottom,
    );

    controller.addStatusListener((s) {
      if (s != AnimationStatus.completed) return;
      _static.remove(floating);
      if (floating.isBottom) {
        if (_bottomRowLast.length > floating.row &&
            _bottomRowLast[floating.row] == floating) {
          _bottomRowLast[floating.row] = null;
        }
      } else {
        if (_topRowLast.length > floating.row &&
            _topRowLast[floating.row] == floating) {
          _topRowLast[floating.row] = null;
        }
      }
      controller.dispose();
      if (mounted) setState(() {});
    });

    _static.add(floating);
    if (widget.preventOverlap) {
      if (floating.isBottom) {
        if (pickedRow >= 0 && pickedRow < _bottomRowLast.length) {
          _bottomRowLast[pickedRow] = floating;
        }
      } else {
        if (pickedRow >= 0 && pickedRow < _topRowLast.length) {
          _topRowLast[pickedRow] = floating;
        }
      }
    }
    if (!_paused) controller.forward();
    if (mounted) setState(() {});
  }

  void _rescaleActiveDanmaku() {
    final speedMultiplier = _effectiveScrollSpeedMultiplier;
    final staticDuration = _effectiveStaticDuration;

    for (final a in List<_FlyingDanmaku>.from(_scrolling)) {
      final controller = a.controller;
      if (controller.status == AnimationStatus.completed) continue;
      final distance = a.canvasWidth + a.textWidth + _scrollGapPx;
      final seconds = (distance / (_scrollBaseSpeedPxPerSec * speedMultiplier))
          .clamp(_scrollMinDurationSec, _scrollMaxDurationSec);
      final newTotalMs =
          (seconds * 1000).round().clamp(1, 1 << 31).toInt();

      final progress = controller.value.clamp(0.0, 1.0);
      controller.duration = Duration(milliseconds: newTotalMs);
      if (_paused || !controller.isAnimating) continue;

      final remainingMs = ((1.0 - progress) * newTotalMs)
          .round()
          .clamp(1, newTotalMs)
          .toInt();
      controller
        ..stop(canceled: false)
        ..animateTo(
          1.0,
          duration: Duration(milliseconds: remainingMs),
          curve: Curves.linear,
        );
    }

    for (final a in List<_StaticDanmaku>.from(_static)) {
      final controller = a.controller;
      if (controller.status == AnimationStatus.completed) continue;
      final newTotalMs =
          staticDuration.inMilliseconds.clamp(1, 1 << 31).toInt();
      final progress = controller.value.clamp(0.0, 1.0);
      controller.duration = Duration(milliseconds: newTotalMs);
      if (_paused || !controller.isAnimating) continue;

      final remainingMs = ((1.0 - progress) * newTotalMs)
          .round()
          .clamp(1, newTotalMs)
          .toInt();
      controller
        ..stop(canceled: false)
        ..animateTo(
          1.0,
          duration: Duration(milliseconds: remainingMs),
          curve: Curves.linear,
        );
    }
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
    required this.row,
    required this.canvasWidth,
    required this.textWidth,
  });

  final DanmakuItem item;
  final AnimationController controller;
  final Animation<double> left;
  final double top;
  final int row;
  final double canvasWidth;
  final double textWidth;
}

class _StaticDanmaku {
  _StaticDanmaku({
    required this.item,
    required this.controller,
    required this.opacity,
    required this.top,
    required this.row,
    required this.isBottom,
  });

  final DanmakuItem item;
  final AnimationController controller;
  final Animation<double> opacity;
  final double top;
  final int row;
  final bool isBottom;
}
