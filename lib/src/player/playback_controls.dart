import 'dart:async';
import 'dart:math' as math;

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

  final Color backgroundColor;

  @override
  State<PlaybackControls> createState() => _PlaybackControlsState();
}

class _PlaybackControlsState extends State<PlaybackControls> {
  double? _scrubMs;

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
                  child: SliderTheme(
                    data: SliderTheme.of(context).copyWith(
                      trackHeight: 3,
                      overlayShape: SliderComponentShape.noOverlay,
                    ),
                    child: Slider(
                      value: displayMs,
                      min: 0,
                      max: maxMs.toDouble().clamp(1, double.infinity),
                      onChangeStart: !enabled
                          ? null
                          : (v) {
                              widget.onScrubStart?.call();
                              setState(() => _scrubMs = v);
                            },
                      onChanged:
                          !enabled ? null : (v) => setState(() => _scrubMs = v),
                      onChangeEnd: !enabled
                          ? null
                          : (v) async {
                              widget.onScrubEnd?.call();
                              setState(() => _scrubMs = null);
                              await _call1(
                                widget.onSeek,
                                Duration(milliseconds: v.round()),
                              );
                            },
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                Text(
                  _fmt(widget.duration),
                  style: const TextStyle(color: Colors.white),
                ),
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
