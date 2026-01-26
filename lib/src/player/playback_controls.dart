import 'dart:async';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter/material.dart';

import '../../state/preferences.dart';
import '../device/device_type.dart';
import '../ui/app_style.dart';

class PlaybackControls extends StatefulWidget {
  const PlaybackControls({
    super.key,
    required this.position,
    this.buffered = Duration.zero,
    required this.duration,
    required this.isPlaying,
    required this.enabled,
    required this.onSeek,
    required this.onPlay,
    required this.onPause,
    required this.onSeekBackward,
    required this.onSeekForward,
    this.heatmap,
    this.showHeatmap = false,
    this.seekBackwardSeconds = 10,
    this.seekForwardSeconds = 10,
    this.showSystemTime = false,
    this.showBattery = false,
    this.showBufferSpeed = false,
    this.buffering = false,
    this.bufferSpeedX,
    this.onScrubStart,
    this.onScrubEnd,
    this.onRequestThumbnail,
    this.onOpenEpisodePicker,
    this.episodePickerLabel = '选集',
    this.onSwitchCore,
    this.onSwitchVersion,
    this.backgroundColor,
  });

  final Duration position;
  final Duration buffered;
  final Duration duration;
  final bool isPlaying;
  final bool enabled;

  final FutureOr<void> Function(Duration position) onSeek;
  final FutureOr<void> Function() onPlay;
  final FutureOr<void> Function() onPause;
  final FutureOr<void> Function() onSeekBackward;
  final FutureOr<void> Function() onSeekForward;

  /// Optional heatmap values along the progress bar.
  ///
  /// Each value should be within `[0, 1]`.
  final List<double>? heatmap;
  final bool showHeatmap;

  final int seekBackwardSeconds;
  final int seekForwardSeconds;
  final bool showSystemTime;
  final bool showBattery;
  final bool showBufferSpeed;
  final bool buffering;
  final double? bufferSpeedX;

  final VoidCallback? onScrubStart;
  final VoidCallback? onScrubEnd;

  /// Best-effort thumbnail provider used during scrubbing.
  ///
  /// Return encoded image bytes (e.g. JPEG/PNG). Return `null` if unavailable.
  final FutureOr<Uint8List?> Function(Duration position)? onRequestThumbnail;

  /// Optional "Episodes" entry point, typically used when playing a TV episode.
  final FutureOr<void> Function()? onOpenEpisodePicker;
  final String episodePickerLabel;

  /// Optional extra actions shown in the controls menu.
  final FutureOr<void> Function()? onSwitchCore;
  final FutureOr<void> Function()? onSwitchVersion;

  final Color? backgroundColor;

  @override
  State<PlaybackControls> createState() => _PlaybackControlsState();
}

enum _PlaybackMenuAction { switchCore, switchVersion }

class _RingThumbShape extends SliderComponentShape {
  const _RingThumbShape({
    required this.radius,
    required this.ringWidth,
    required this.ringColor,
  });

  final double radius;
  final double ringWidth;
  final Color ringColor;

  @override
  Size getPreferredSize(bool isEnabled, bool isDiscrete) =>
      Size.fromRadius(radius + ringWidth);

  @override
  void paint(
    PaintingContext context,
    Offset center, {
    required Animation<double> activationAnimation,
    required Animation<double> enableAnimation,
    required bool isDiscrete,
    required TextPainter labelPainter,
    required RenderBox parentBox,
    required SliderThemeData sliderTheme,
    required TextDirection textDirection,
    required double value,
    required double textScaleFactor,
    required Size sizeWithOverflow,
  }) {
    final canvas = context.canvas;
    final fill = sliderTheme.thumbColor ?? Colors.white;

    final fillPaint = Paint()..color = fill;
    canvas.drawCircle(center, radius, fillPaint);

    final ringPaint = Paint()
      ..color = ringColor
      ..style = PaintingStyle.stroke
      ..strokeWidth = ringWidth;
    canvas.drawCircle(center, radius, ringPaint);
  }
}

class _HeatmapSliderTrackShape extends RoundedRectSliderTrackShape {
  const _HeatmapSliderTrackShape(this.heatmap, {required this.heatColor});

  final List<double> heatmap;
  final Color heatColor;

  @override
  void paint(
    PaintingContext context,
    Offset offset, {
    required RenderBox parentBox,
    required SliderThemeData sliderTheme,
    required Animation<double> enableAnimation,
    required TextDirection textDirection,
    required Offset thumbCenter,
    Offset? secondaryOffset,
    bool isDiscrete = false,
    bool isEnabled = false,
    double additionalActiveTrackHeight = 2,
  }) {
    final hm = heatmap;
    if (hm.isNotEmpty) {
      final canvas = context.canvas;
      final trackRect = getPreferredRect(
        parentBox: parentBox,
        offset: offset,
        sliderTheme: sliderTheme,
        isEnabled: isEnabled,
        isDiscrete: isDiscrete,
      );

      final binWidth = trackRect.width / hm.length;
      final paint = Paint();
      for (var i = 0; i < hm.length; i++) {
        final intensity = hm[i].clamp(0.0, 1.0);
        if (intensity <= 0) continue;
        paint.color = heatColor.withValues(
          alpha: (0.08 + 0.62 * intensity).clamp(0.0, 1.0),
        );
        canvas.drawRect(
          Rect.fromLTWH(
            trackRect.left + i * binWidth,
            trackRect.top - 1,
            binWidth,
            trackRect.height + 2,
          ),
          paint,
        );
      }
    }

    super.paint(
      context,
      offset,
      parentBox: parentBox,
      sliderTheme: sliderTheme,
      enableAnimation: enableAnimation,
      textDirection: textDirection,
      thumbCenter: thumbCenter,
      secondaryOffset: secondaryOffset,
      isDiscrete: isDiscrete,
      isEnabled: isEnabled,
      additionalActiveTrackHeight: additionalActiveTrackHeight,
    );
  }
}

class _PlaybackControlsState extends State<PlaybackControls> {
  double? _scrubMs;
  Uint8List? _thumbnailBytes;
  int? _thumbnailKeyMs;
  bool _thumbnailLoading = false;
  Timer? _thumbnailDebounceTimer;
  int _thumbnailRequestId = 0;

  Timer? _clockTimer;
  DateTime _now = DateTime.now();
  Timer? _batteryTimer;
  int? _batteryLevel;

  static String _fmt(Duration d) {
    String two(int v) => v.toString().padLeft(2, '0');
    final h = d.inHours;
    final m = d.inMinutes.remainder(60);
    final s = d.inSeconds.remainder(60);
    return h > 0 ? '${two(h)}:${two(m)}:${two(s)}' : '${two(m)}:${two(s)}';
  }

  static String _fmtTime(DateTime t) {
    String two(int v) => v.toString().padLeft(2, '0');
    return '${two(t.hour)}:${two(t.minute)}';
  }

  static IconData _replayIcon(int seconds) {
    return switch (seconds) {
      5 => Icons.replay_5,
      10 => Icons.replay_10,
      30 => Icons.replay_30,
      _ => Icons.replay,
    };
  }

  static IconData _forwardIcon(int seconds) {
    return switch (seconds) {
      5 => Icons.forward_5,
      10 => Icons.forward_10,
      30 => Icons.forward_30,
      _ => Icons.forward,
    };
  }

  Future<void> _call0(FutureOr<void> Function() fn) => Future<void>.sync(fn);

  Future<void> _call1(
    FutureOr<void> Function(Duration position) fn,
    Duration position,
  ) =>
      Future<void>.sync(() => fn(position));

  Future<void> _callMaybe(FutureOr<void> Function()? fn) =>
      fn == null ? Future<void>.value() : Future<void>.sync(fn);

  static int _quantizeMs(int ms) => (ms ~/ 2000) * 2000;

  void _scheduleThumbnailRequest(double rawMs) {
    final cb = widget.onRequestThumbnail;
    if (cb == null) return;
    final ms = _quantizeMs(rawMs.round());
    if (_thumbnailKeyMs == ms &&
        (_thumbnailBytes != null || _thumbnailLoading)) {
      return;
    }

    _thumbnailDebounceTimer?.cancel();
    final requestId = ++_thumbnailRequestId;
    setState(() {
      _thumbnailKeyMs = ms;
      _thumbnailBytes = null;
      _thumbnailLoading = true;
    });

    _thumbnailDebounceTimer =
        Timer(const Duration(milliseconds: 120), () async {
      Uint8List? bytes;
      try {
        bytes = await Future<Uint8List?>.sync(
          () => cb(Duration(milliseconds: ms)),
        );
      } catch (_) {
        bytes = null;
      }
      if (!mounted) return;
      if (requestId != _thumbnailRequestId) return;
      setState(() {
        _thumbnailBytes = bytes;
        _thumbnailLoading = false;
      });
    });
  }

  void _clearThumbnail() {
    _thumbnailDebounceTimer?.cancel();
    _thumbnailDebounceTimer = null;
    _thumbnailRequestId++;
    _thumbnailKeyMs = null;
    _thumbnailBytes = null;
    _thumbnailLoading = false;
  }

  @override
  void initState() {
    super.initState();
    _syncStatusTimers();
  }

  @override
  void didUpdateWidget(covariant PlaybackControls oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.showSystemTime != widget.showSystemTime ||
        oldWidget.showBattery != widget.showBattery) {
      _syncStatusTimers();
    }
  }

  void _syncStatusTimers() {
    _clockTimer?.cancel();
    _clockTimer = null;
    _batteryTimer?.cancel();
    _batteryTimer = null;

    if (widget.showSystemTime) {
      _now = DateTime.now();
      _clockTimer = Timer.periodic(const Duration(seconds: 30), (_) {
        if (!mounted) return;
        setState(() => _now = DateTime.now());
      });
    }

    if (widget.showBattery) {
      // ignore: unawaited_futures
      _refreshBattery();
      _batteryTimer = Timer.periodic(const Duration(minutes: 1), (_) {
        // ignore: unawaited_futures
        _refreshBattery();
      });
    } else {
      _batteryLevel = null;
    }
  }

  Future<void> _refreshBattery() async {
    int? level;
    try {
      level = await DeviceType.batteryLevel();
    } catch (_) {
      level = null;
    }
    if (!mounted) return;
    setState(() => _batteryLevel = level);
  }

  @override
  void dispose() {
    _thumbnailDebounceTimer?.cancel();
    _thumbnailDebounceTimer = null;
    _clockTimer?.cancel();
    _clockTimer = null;
    _batteryTimer?.cancel();
    _batteryTimer = null;
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final style = theme.extension<AppStyle>() ?? const AppStyle();
    final template = style.template;

    const baseBg = Color(0x66000000);
    final bg = widget.backgroundColor ??
        switch (template) {
          UiTemplate.neonHud => Color.lerp(
              baseBg,
              scheme.primary.withValues(alpha: 0.85),
              0.18,
            )!,
          UiTemplate.pixelArcade => Color.lerp(
              baseBg,
              scheme.secondary.withValues(alpha: 0.85),
              0.14,
            )!,
          UiTemplate.stickerJournal => Color.lerp(
              baseBg,
              scheme.secondary.withValues(alpha: 0.75),
              0.10,
            )!,
          UiTemplate.candyGlass => Color.lerp(
              baseBg,
              scheme.primary.withValues(alpha: 0.70),
              0.10,
            )!,
          UiTemplate.washiWatercolor => Color.lerp(
              baseBg,
              scheme.tertiary.withValues(alpha: 0.70),
              0.08,
            )!,
          UiTemplate.mangaStoryboard => const Color(0x78000000),
          UiTemplate.proTool => baseBg,
          UiTemplate.minimalCovers => const Color(0x70000000),
        };

    final radius = switch (template) {
      UiTemplate.pixelArcade => 10.0,
      UiTemplate.neonHud => 12.0,
      UiTemplate.mangaStoryboard => 10.0,
      UiTemplate.proTool => 12.0,
      _ => 12.0,
    };

    final accent = switch (template) {
      UiTemplate.neonHud => scheme.primary,
      UiTemplate.pixelArcade => scheme.secondary,
      UiTemplate.stickerJournal => scheme.secondary,
      UiTemplate.candyGlass => scheme.primary,
      UiTemplate.washiWatercolor => scheme.primary,
      _ => Colors.white,
    };

    final borderSide = switch (template) {
      UiTemplate.neonHud => BorderSide(
          color: scheme.primary.withValues(alpha: 0.75),
          width: math.max(1.0, style.borderWidth),
        ),
      UiTemplate.pixelArcade => BorderSide(
          color: scheme.secondary.withValues(alpha: 0.75),
          width: math.max(1.2, style.borderWidth + 0.6),
        ),
      UiTemplate.mangaStoryboard => BorderSide(
          color: Colors.white.withValues(alpha: 0.55),
          width: math.max(1.1, style.borderWidth + 0.6),
        ),
      _ => BorderSide.none,
    };

    final shape = RoundedRectangleBorder(
      borderRadius: BorderRadius.circular(radius),
      side: borderSide,
    );

    final durationMs = widget.duration.inMilliseconds;
    final maxMs = math.max(durationMs, 1);
    final posMs = widget.position.inMilliseconds;
    final displayMs = (_scrubMs ?? posMs).clamp(0, maxMs).toDouble();

    final displayPos = Duration(milliseconds: displayMs.round());

    final enabled = widget.enabled;
    final backSeconds = widget.seekBackwardSeconds.clamp(1, 120);
    final forwardSeconds = widget.seekForwardSeconds.clamp(1, 120);

    final statusChips = <Widget>[];
    Widget chip({required IconData icon, required String text}) {
      return Container(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
        decoration: BoxDecoration(
          color: Colors.black.withValues(alpha: 0.25),
          borderRadius: BorderRadius.circular(999),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 14, color: Colors.white.withValues(alpha: 0.85)),
            const SizedBox(width: 4),
            Text(
              text,
              style: TextStyle(
                color: Colors.white.withValues(alpha: 0.85),
                fontSize: 11,
              ),
            ),
          ],
        ),
      );
    }

    if (widget.showSystemTime) {
      statusChips.add(chip(icon: Icons.schedule, text: _fmtTime(_now)));
    }
    if (widget.showBattery && _batteryLevel != null) {
      statusChips.add(
        chip(icon: Icons.battery_std, text: '${_batteryLevel!.clamp(0, 100)}%'),
      );
    }
    if (widget.showBufferSpeed && widget.buffering) {
      final x = widget.bufferSpeedX;
      statusChips.add(
        chip(
          icon: Icons.downloading_outlined,
          text: x == null
              ? '缓冲中'
              : '缓冲 ${x.clamp(0.0, 99.0).toStringAsFixed(1)}×',
        ),
      );
    }

    return Material(
      color: bg,
      shape: shape,
      clipBehavior: Clip.antiAlias,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(12, 10, 12, 10),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (statusChips.isNotEmpty) ...[
              Align(
                alignment: Alignment.centerRight,
                child: Wrap(
                  spacing: 6,
                  runSpacing: 6,
                  children: statusChips,
                ),
              ),
              const SizedBox(height: 6),
            ],
            Row(
              children: [
                Text(
                  _fmt(displayPos),
                  style: const TextStyle(color: Colors.white),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: LayoutBuilder(
                    builder: (context, constraints) {
                      final showPreview = widget.onRequestThumbnail != null &&
                          _scrubMs != null &&
                          constraints.maxWidth > 0;

                      final ringColor = accent.computeLuminance() > 0.6
                          ? Colors.black
                          : Colors.white;
                      final showHeatmap = widget.showHeatmap &&
                          (widget.heatmap?.isNotEmpty ?? false);
                      final sliderTheme = SliderTheme.of(context).copyWith(
                        trackHeight: 4,
                        overlayShape: SliderComponentShape.noOverlay,
                        activeTrackColor: accent,
                        secondaryActiveTrackColor:
                            Colors.white.withValues(alpha: 0.30),
                        thumbColor: accent,
                        trackShape: showHeatmap
                            ? _HeatmapSliderTrackShape(
                                widget.heatmap!,
                                heatColor: accent,
                              )
                            : const RoundedRectSliderTrackShape(),
                        thumbShape: _RingThumbShape(
                          radius: 7,
                          ringWidth: 2,
                          ringColor: ringColor,
                        ),
                      );

                      final bubbleWidth = math.min(160.0, constraints.maxWidth);
                      final bubbleHeight = bubbleWidth * 9 / 16;

                      final ratio = maxMs <= 0
                          ? 0.0
                          : (displayMs / maxMs).clamp(0.0, 1.0);
                      final bubbleLeft =
                          (ratio * constraints.maxWidth) - (bubbleWidth / 2);
                      final bubbleLeftClamped = bubbleLeft
                          .clamp(
                            0.0,
                            math.max(0.0, constraints.maxWidth - bubbleWidth),
                          )
                          .toDouble();

                      return SizedBox(
                        height: showPreview ? (bubbleHeight + 28) : 32,
                        child: Stack(
                          fit: StackFit.expand,
                          children: [
                            Align(
                              alignment: Alignment.bottomCenter,
                              child: SliderTheme(
                                data: sliderTheme,
                                child: Slider(
                                  value: displayMs,
                                  min: 0,
                                  max: maxMs
                                      .toDouble()
                                      .clamp(1, double.infinity),
                                  secondaryTrackValue: math
                                      .max(0, widget.buffered.inMilliseconds)
                                      .clamp(0, maxMs)
                                      .toDouble(),
                                  onChangeStart: !enabled
                                      ? null
                                      : (v) {
                                          widget.onScrubStart?.call();
                                          setState(() => _scrubMs = v);
                                          _scheduleThumbnailRequest(v);
                                        },
                                  onChanged: !enabled
                                      ? null
                                      : (v) {
                                          setState(() => _scrubMs = v);
                                          _scheduleThumbnailRequest(v);
                                        },
                                  onChangeEnd: !enabled
                                      ? null
                                      : (v) async {
                                          widget.onScrubEnd?.call();
                                          setState(() => _scrubMs = null);
                                          _clearThumbnail();
                                          await _call1(
                                            widget.onSeek,
                                            Duration(milliseconds: v.round()),
                                          );
                                        },
                                ),
                              ),
                            ),
                            if (showPreview)
                              Positioned(
                                left: bubbleLeftClamped,
                                top: 0,
                                width: bubbleWidth,
                                height: bubbleHeight,
                                child: ClipRRect(
                                  borderRadius: BorderRadius.circular(10),
                                  child: ColoredBox(
                                    color: const Color(0xFF111111),
                                    child: Stack(
                                      fit: StackFit.expand,
                                      children: [
                                        if (_thumbnailBytes != null)
                                          Image.memory(
                                            _thumbnailBytes!,
                                            fit: BoxFit.cover,
                                            gaplessPlayback: true,
                                            filterQuality: FilterQuality.low,
                                          )
                                        else
                                          const Center(
                                            child: Icon(
                                              Icons.image_outlined,
                                              color: Colors.white54,
                                            ),
                                          ),
                                        if (_thumbnailLoading)
                                          const ColoredBox(
                                            color: Color(0x44000000),
                                            child: Center(
                                              child: SizedBox(
                                                width: 18,
                                                height: 18,
                                                child:
                                                    CircularProgressIndicator(
                                                  strokeWidth: 2,
                                                  color: Colors.white70,
                                                ),
                                              ),
                                            ),
                                          ),
                                        Positioned(
                                          right: 6,
                                          bottom: 6,
                                          child: DecoratedBox(
                                            decoration: BoxDecoration(
                                              color: const Color(0xAA000000),
                                              borderRadius:
                                                  BorderRadius.circular(6),
                                              border: switch (template) {
                                                UiTemplate.neonHud =>
                                                  Border.all(
                                                    color: accent.withValues(
                                                        alpha: 0.65),
                                                  ),
                                                UiTemplate.pixelArcade =>
                                                  Border.all(
                                                    color: accent.withValues(
                                                        alpha: 0.65),
                                                    width: 1.2,
                                                  ),
                                                UiTemplate.mangaStoryboard =>
                                                  Border.all(
                                                    color: Colors.white
                                                        .withValues(
                                                            alpha: 0.35),
                                                  ),
                                                _ => null,
                                              },
                                            ),
                                            child: Padding(
                                              padding:
                                                  const EdgeInsets.symmetric(
                                                horizontal: 6,
                                                vertical: 3,
                                              ),
                                              child: Text(
                                                _fmt(displayPos),
                                                style: const TextStyle(
                                                  color: Colors.white,
                                                  fontSize: 11,
                                                ),
                                              ),
                                            ),
                                          ),
                                        ),
                                      ],
                                    ),
                                  ),
                                ),
                              ),
                          ],
                        ),
                      );
                    },
                  ),
                ),
                const SizedBox(width: 8),
                Text(
                  _fmt(widget.duration),
                  style: const TextStyle(color: Colors.white),
                ),
                if (widget.onSwitchCore != null ||
                    widget.onSwitchVersion != null) ...[
                  const SizedBox(width: 2),
                  PopupMenuButton<_PlaybackMenuAction>(
                    tooltip: '更多',
                    icon: const Icon(Icons.more_vert, color: Colors.white),
                    color: const Color(0xFF202020),
                    onSelected: (action) async {
                      switch (action) {
                        case _PlaybackMenuAction.switchCore:
                          await _callMaybe(widget.onSwitchCore);
                          break;
                        case _PlaybackMenuAction.switchVersion:
                          await _callMaybe(widget.onSwitchVersion);
                          break;
                      }
                    },
                    itemBuilder: (context) => [
                      if (widget.onSwitchCore != null)
                        PopupMenuItem(
                          value: _PlaybackMenuAction.switchCore,
                          child: Row(
                            children: [
                              Icon(Icons.tune, color: accent),
                              const SizedBox(width: 10),
                              const Text(
                                '切换内核',
                                style: TextStyle(color: Colors.white),
                              ),
                            ],
                          ),
                        ),
                      if (widget.onSwitchVersion != null)
                        PopupMenuItem(
                          value: _PlaybackMenuAction.switchVersion,
                          child: Row(
                            children: [
                              Icon(Icons.video_file_outlined, color: accent),
                              const SizedBox(width: 10),
                              const Text(
                                '切换版本',
                                style: TextStyle(color: Colors.white),
                              ),
                            ],
                          ),
                        ),
                    ],
                  ),
                ],
              ],
            ),
            const SizedBox(height: 6),
            Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                if (widget.onOpenEpisodePicker != null)
                  const SizedBox(width: 48),
                Expanded(
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      IconButton(
                        tooltip: '快退 $backSeconds 秒',
                        icon: Icon(_replayIcon(backSeconds)),
                        color: Colors.white,
                        onPressed: !enabled
                            ? null
                            : () => _call0(widget.onSeekBackward),
                      ),
                      IconButton(
                        tooltip: widget.isPlaying ? '暂停' : '播放',
                        icon: Icon(
                          widget.isPlaying
                              ? Icons.pause_circle
                              : Icons.play_circle,
                        ),
                        iconSize: 44,
                        color: accent,
                        onPressed: !enabled
                            ? null
                            : () => widget.isPlaying
                                ? _call0(widget.onPause)
                                : _call0(widget.onPlay),
                      ),
                      IconButton(
                        tooltip: '快进 $forwardSeconds 秒',
                        icon: Icon(_forwardIcon(forwardSeconds)),
                        color: Colors.white,
                        onPressed: !enabled
                            ? null
                            : () => _call0(widget.onSeekForward),
                      ),
                    ],
                  ),
                ),
                if (widget.onOpenEpisodePicker != null)
                  IconButton(
                    tooltip: widget.episodePickerLabel,
                    icon: const Icon(Icons.format_list_numbered),
                    color: Colors.white,
                    onPressed: !enabled
                        ? null
                        : () => _callMaybe(widget.onOpenEpisodePicker),
                  ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}
