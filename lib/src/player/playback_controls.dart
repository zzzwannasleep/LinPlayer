import 'dart:async';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter/material.dart';

class PlaybackControls extends StatefulWidget {
  const PlaybackControls({
    super.key,
    required this.position,
    required this.duration,
    required this.isPlaying,
    required this.enabled,
    required this.onSeek,
    required this.onPlay,
    required this.onPause,
    required this.onSeekBackward,
    required this.onSeekForward,
    this.onScrubStart,
    this.onScrubEnd,
    this.onRequestThumbnail,
    this.onSwitchCore,
    this.onSwitchVersion,
    this.backgroundColor = const Color(0x99000000),
  });

  final Duration position;
  final Duration duration;
  final bool isPlaying;
  final bool enabled;

  final FutureOr<void> Function(Duration position) onSeek;
  final FutureOr<void> Function() onPlay;
  final FutureOr<void> Function() onPause;
  final FutureOr<void> Function() onSeekBackward;
  final FutureOr<void> Function() onSeekForward;

  final VoidCallback? onScrubStart;
  final VoidCallback? onScrubEnd;

  /// Best-effort thumbnail provider used during scrubbing.
  ///
  /// Return encoded image bytes (e.g. JPEG/PNG). Return `null` if unavailable.
  final FutureOr<Uint8List?> Function(Duration position)? onRequestThumbnail;

  /// Optional extra actions shown in the controls menu.
  final FutureOr<void> Function()? onSwitchCore;
  final FutureOr<void> Function()? onSwitchVersion;

  final Color backgroundColor;

  @override
  State<PlaybackControls> createState() => _PlaybackControlsState();
}

enum _PlaybackMenuAction { switchCore, switchVersion }

class _PlaybackControlsState extends State<PlaybackControls> {
  double? _scrubMs;
  Uint8List? _thumbnailBytes;
  int? _thumbnailKeyMs;
  bool _thumbnailLoading = false;
  Timer? _thumbnailDebounceTimer;
  int _thumbnailRequestId = 0;

  static String _fmt(Duration d) {
    String two(int v) => v.toString().padLeft(2, '0');
    final h = d.inHours;
    final m = d.inMinutes.remainder(60);
    final s = d.inSeconds.remainder(60);
    return h > 0 ? '${two(h)}:${two(m)}:${two(s)}' : '${two(m)}:${two(s)}';
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
    if (_thumbnailKeyMs == ms && (_thumbnailBytes != null || _thumbnailLoading)) {
      return;
    }

    _thumbnailDebounceTimer?.cancel();
    final requestId = ++_thumbnailRequestId;
    setState(() {
      _thumbnailKeyMs = ms;
      _thumbnailBytes = null;
      _thumbnailLoading = true;
    });

    _thumbnailDebounceTimer = Timer(const Duration(milliseconds: 120), () async {
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
  void dispose() {
    _thumbnailDebounceTimer?.cancel();
    _thumbnailDebounceTimer = null;
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final durationMs = widget.duration.inMilliseconds;
    final maxMs = math.max(durationMs, 1);
    final posMs = widget.position.inMilliseconds;
    final displayMs = (_scrubMs ?? posMs).clamp(0, maxMs).toDouble();

    final displayPos = Duration(milliseconds: displayMs.round());

    final enabled = widget.enabled;

    return Material(
      color: widget.backgroundColor,
      borderRadius: BorderRadius.circular(12),
      clipBehavior: Clip.antiAlias,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(12, 10, 12, 10),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
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
                      final sliderTheme = SliderTheme.of(context).copyWith(
                        trackHeight: 3,
                        overlayShape: SliderComponentShape.noOverlay,
                      );

                      final bubbleWidth = math.min(160.0, constraints.maxWidth);
                      final bubbleHeight = bubbleWidth * 9 / 16;

                      final ratio = maxMs <= 0
                          ? 0.0
                          : (displayMs / maxMs).clamp(0.0, 1.0);
                      final bubbleLeft = (ratio * constraints.maxWidth) -
                          (bubbleWidth / 2);
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
                                  max: maxMs.toDouble().clamp(1, double.infinity),
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
                                                child: CircularProgressIndicator(
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
                        const PopupMenuItem(
                          value: _PlaybackMenuAction.switchCore,
                          child: Row(
                            children: [
                              Icon(Icons.tune, color: Colors.white),
                              SizedBox(width: 10),
                              Text('切换内核',
                                  style: TextStyle(color: Colors.white)),
                            ],
                          ),
                        ),
                      if (widget.onSwitchVersion != null)
                        const PopupMenuItem(
                          value: _PlaybackMenuAction.switchVersion,
                          child: Row(
                            children: [
                              Icon(Icons.video_file_outlined,
                                  color: Colors.white),
                              SizedBox(width: 10),
                              Text('切换版本',
                                  style: TextStyle(color: Colors.white)),
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
                IconButton(
                  tooltip: '后退 10 秒',
                  icon: const Icon(Icons.replay_10),
                  color: Colors.white,
                  onPressed:
                      !enabled ? null : () => _call0(widget.onSeekBackward),
                ),
                IconButton(
                  tooltip: widget.isPlaying ? '暂停' : '播放',
                  icon: Icon(
                    widget.isPlaying ? Icons.pause_circle : Icons.play_circle,
                  ),
                  iconSize: 44,
                  color: Colors.white,
                  onPressed: !enabled
                      ? null
                      : () => widget.isPlaying
                          ? _call0(widget.onPause)
                          : _call0(widget.onPlay),
                ),
                IconButton(
                  tooltip: '前进 10 秒',
                  icon: const Icon(Icons.forward_10),
                  color: Colors.white,
                  onPressed:
                      !enabled ? null : () => _call0(widget.onSeekForward),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}
