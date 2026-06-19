import 'dart:ui' as ui;
import 'package:flutter/scheduler.dart';
import 'package:flutter/material.dart';
import '../../../core/api/api_interfaces.dart';

class DanmakuOverlay extends StatefulWidget {
  final List<DanmakuItem> items;
  final Duration position;
  final bool isPlaying;
  final double opacity;
  final double fontSizeFactor;
  final double speedFactor;
  final double densityFactor;

  /// 显示区域占视频高度比例（0.25/0.5/1.0），弹幕只用顶部这一段轨道。
  final double displayArea;

  /// 描边文字（黑边）。关闭则用半透明底框。
  final bool stroke;

  const DanmakuOverlay({
    super.key,
    required this.items,
    required this.position,
    this.isPlaying = true,
    this.opacity = 0.8,
    this.fontSizeFactor = 0.5,
    this.speedFactor = 0.5,
    this.densityFactor = 0.5,
    this.displayArea = 1.0,
    this.stroke = true,
  });

  @override
  State<DanmakuOverlay> createState() => _DanmakuOverlayState();
}

class _DanmakuOverlayState extends State<DanmakuOverlay>
    with SingleTickerProviderStateMixin {
  Ticker? _ticker;
  Duration _tickerElapsed = Duration.zero;
  Duration _smoothPosition = Duration.zero;
  Duration _lastSyncPosition = Duration.zero;
  Duration _lastSyncElapsed = Duration.zero;

  /// 段落缓存随 State 存活（跨帧持久），替代旧的 static 缓存（跨实例共享是隐患）。
  final DanmakuLayoutCache _cache = DanmakuLayoutCache();

  @override
  void initState() {
    super.initState();
    _smoothPosition = widget.position;
    _lastSyncPosition = widget.position;
    _ticker = createTicker(_onTick)..start();
  }

  void _onTick(Duration elapsed) {
    _tickerElapsed = elapsed;
    if (!widget.isPlaying) return;
    final delta = elapsed - _lastSyncElapsed;
    _smoothPosition = _lastSyncPosition + delta;
    setState(() {});
  }

  @override
  void didUpdateWidget(DanmakuOverlay old) {
    super.didUpdateWidget(old);
    if (widget.position != old.position) {
      _lastSyncPosition = widget.position;
      _lastSyncElapsed = _tickerElapsed;
      _smoothPosition = widget.position;
    }
    if (widget.isPlaying && !old.isPlaying) {
      _lastSyncPosition = _smoothPosition;
      _lastSyncElapsed = _tickerElapsed;
    }
  }

  @override
  void dispose() {
    _cache.clear();
    _ticker?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Opacity(
      opacity: widget.opacity.clamp(0.0, 1.0),
      child: CustomPaint(
        painter: DanmakuPainter(
          items: widget.items,
          videoPosition: _smoothPosition,
          fontSizeFactor: widget.fontSizeFactor,
          speedFactor: widget.speedFactor,
          densityFactor: widget.densityFactor,
          displayArea: widget.displayArea,
          stroke: widget.stroke,
          cache: _cache,
        ),
        size: Size.infinite,
      ),
    );
  }
}

/// 跨帧持久的段落布局缓存（按 items 引用 + 字号 + 宽度 + 描边 失效）。
class DanmakuLayoutCache {
  List<DanmakuItem>? _items;
  double? _fontSize;
  double? _width;
  bool? _stroke;

  List<ui.Paragraph?> _fill = const [];
  List<ui.Paragraph?> _strokeParas = const [];
  List<double> _widths = const [];

  void ensure(List<DanmakuItem> items, double fontSize, double width,
      bool stroke) {
    if (identical(_items, items) &&
        _fontSize == fontSize &&
        _width == width &&
        _stroke == stroke) {
      return;
    }
    _items = items;
    _fontSize = fontSize;
    _width = width;
    _stroke = stroke;
    _fill = List<ui.Paragraph?>.filled(items.length, null);
    _strokeParas = List<ui.Paragraph?>.filled(items.length, null);
    _widths = List<double>.filled(items.length, 0);
  }

  void clear() {
    _items = null;
    _fill = const [];
    _strokeParas = const [];
    _widths = const [];
  }

  double widthOf(int i) => _widths[i];
  ui.Paragraph? fillOf(int i) => _fill[i];
  ui.Paragraph? strokeOf(int i) => _strokeParas[i];

  void store(int i, ui.Paragraph fill, ui.Paragraph? strokePara, double w) {
    _fill[i] = fill;
    _strokeParas[i] = strokePara;
    _widths[i] = w;
  }
}

class _DanmakuTrackItem {
  final int index;
  final DanmakuItem item;
  double startY;
  final double width;
  final ui.Paragraph fill;
  final ui.Paragraph? stroke;

  _DanmakuTrackItem({
    required this.index,
    required this.item,
    required this.startY,
    required this.width,
    required this.fill,
    required this.stroke,
  });
}

class DanmakuPainter extends CustomPainter {
  final List<DanmakuItem> items;
  final Duration videoPosition;
  final double fontSizeFactor;
  final double speedFactor;
  final double densityFactor;
  final double displayArea;
  final bool stroke;
  final DanmakuLayoutCache cache;

  static const double _maxFontSize = 36.0;
  static const double _minFontSize = 12.0;
  static const double _baseSpeed = 120.0;
  static const double _topBottomDuration = 5.0;
  static const double _trackHeight = 32.0;
  static const double _padding = 4.0;
  static const double _visibleWindow = 30.0;

  DanmakuPainter({
    required this.items,
    required this.videoPosition,
    required this.fontSizeFactor,
    required this.speedFactor,
    required this.densityFactor,
    required this.displayArea,
    required this.stroke,
    required this.cache,
  });

  double get _fontSize =>
      _minFontSize + (_maxFontSize - _minFontSize) * fontSizeFactor;
  double get _speed => _baseSpeed * (0.5 + speedFactor);
  double get _currentSeconds => videoPosition.inMilliseconds / 1000.0;
  int get _maxVisible =>
      (items.length * (0.3 + densityFactor * 0.7)).round().clamp(0, items.length);

  _DanmakuTrackItem _getTrackItem(int index, Size size) {
    var fill = cache.fillOf(index);
    if (fill == null) {
      final item = items[index];
      final fs = item.size > 0 ? (item.size / 25.0 * _fontSize) : _fontSize;
      fill = _buildParagraph(item, size, fs, fillMode: true);
      final strokePara =
          stroke ? _buildParagraph(item, size, fs, fillMode: false) : null;
      cache.store(index, fill, strokePara, fill.maxIntrinsicWidth + _padding * 2);
    }
    return _DanmakuTrackItem(
      index: index,
      item: items[index],
      startY: 0,
      width: cache.widthOf(index),
      fill: fill,
      stroke: cache.strokeOf(index),
    );
  }

  ui.Paragraph _buildParagraph(DanmakuItem item, Size size, double fs,
      {required bool fillMode}) {
    final color = Color(item.color | 0xFF000000);
    final displayText =
        item.count > 1 ? '${item.text} ×${item.count}' : item.text;

    final ui.TextStyle style;
    if (!stroke) {
      // 旧观感：半透明底框 + 实色字。
      style = ui.TextStyle(
        color: color,
        background: ui.Paint()..color = const Color(0x60000000),
        fontSize: fs,
      );
    } else if (fillMode) {
      style = ui.TextStyle(color: color, fontSize: fs);
    } else {
      // 描边层：黑色 stroke。
      final strokeWidth = (fs / 14).clamp(1.2, 2.6);
      style = ui.TextStyle(
        foreground: ui.Paint()
          ..style = ui.PaintingStyle.stroke
          ..strokeWidth = strokeWidth
          ..strokeJoin = ui.StrokeJoin.round
          ..color = const Color(0xCC000000),
        fontSize: fs,
      );
    }

    final builder = ui.ParagraphBuilder(ui.ParagraphStyle(
      fontSize: fs,
      maxLines: 1,
      ellipsis: '',
    ))
      ..pushStyle(style)
      ..addText(displayText);
    final paragraph = builder.build();
    paragraph.layout(ui.ParagraphConstraints(width: size.width));
    return paragraph;
  }

  @override
  void paint(Canvas canvas, Size size) {
    if (items.isEmpty || size.isEmpty) return;

    final usableHeight = size.height * displayArea.clamp(0.1, 1.0);
    final trackCount = (usableHeight / _trackHeight).floor();
    if (trackCount <= 0) return;

    cache.ensure(items, _fontSize, size.width, stroke);

    final visibleItems = <_DanmakuTrackItem>[];
    var added = 0;
    final maxVisible = _maxVisible;
    for (var i = 0; i < items.length; i++) {
      if (added >= maxVisible) break;
      final diff = items[i].time - _currentSeconds;
      if (diff < -_visibleWindow || diff > _visibleWindow) continue;
      visibleItems.add(_getTrackItem(i, size));
      added++;
    }

    final scrollTracks = List<_DanmakuTrackItem?>.filled(trackCount, null);
    final topTracks = <int, List<_DanmakuTrackItem>>{};
    final bottomTracks = <int, List<_DanmakuTrackItem>>{};

    for (final trackItem in visibleItems) {
      final type = trackItem.item.type;
      if (type == 4) {
        _layoutFixed(trackItem, bottomTracks, trackCount);
      } else if (type == 5) {
        _layoutFixed(trackItem, topTracks, trackCount);
      } else {
        _layoutScroll(trackItem, scrollTracks, trackCount, size);
      }
    }

    for (final trackItem in visibleItems) {
      final x = _computeX(trackItem, size);
      if (x + trackItem.width < 0 || x > size.width) continue;
      final offset = Offset(x, trackItem.startY);
      if (trackItem.stroke != null) {
        canvas.drawParagraph(trackItem.stroke!, offset);
      }
      canvas.drawParagraph(trackItem.fill, offset);
    }
  }

  void _layoutScroll(_DanmakuTrackItem trackItem,
      List<_DanmakuTrackItem?> tracks, int trackCount, Size size) {
    final x = _computeX(trackItem, size);
    for (var i = 0; i < trackCount; i++) {
      final existing = tracks[i];
      if (existing == null) {
        trackItem.startY = i * _trackHeight + _padding;
        tracks[i] = trackItem;
        return;
      }
      final existingX = _computeX(existing, size);
      final existingRight = existingX + existing.width;
      if (x > existingRight + _padding * 2) {
        trackItem.startY = i * _trackHeight + _padding;
        tracks[i] = trackItem;
        return;
      }
    }
    trackItem.startY = (trackCount - 1) * _trackHeight + _padding;
  }

  void _layoutFixed(_DanmakuTrackItem trackItem,
      Map<int, List<_DanmakuTrackItem>> tracks, int trackCount) {
    for (var i = 0; i < trackCount; i++) {
      final trackList = tracks[i];
      if (trackList == null || trackList.isEmpty) {
        tracks[i] = [trackItem];
        trackItem.startY = i * _trackHeight + _padding;
        return;
      }
      final last = trackList.last;
      final diff = _currentSeconds - last.item.time;
      if (diff > _topBottomDuration) {
        trackList.add(trackItem);
        trackItem.startY = i * _trackHeight + _padding;
        return;
      }
    }
    trackItem.startY = (trackCount - 1) * _trackHeight + _padding;
  }

  double _computeX(_DanmakuTrackItem trackItem, Size size) {
    final type = trackItem.item.type;
    final elapsed = _currentSeconds - trackItem.item.time;
    if (elapsed < 0) return -trackItem.width;

    if (type == 4 || type == 5) {
      return (size.width - trackItem.width) / 2;
    }

    final totalDuration = size.width / _speed + trackItem.width / _speed;
    final progress = elapsed / totalDuration;
    final startX = size.width + _padding;
    final endX = -trackItem.width - _padding;
    return startX + (endX - startX) * progress;
  }

  @override
  bool shouldRepaint(DanmakuPainter oldDelegate) {
    return oldDelegate.videoPosition != videoPosition ||
        !identical(oldDelegate.items, items) ||
        oldDelegate.fontSizeFactor != fontSizeFactor ||
        oldDelegate.speedFactor != speedFactor ||
        oldDelegate.densityFactor != densityFactor ||
        oldDelegate.displayArea != displayArea ||
        oldDelegate.stroke != stroke;
  }
}
