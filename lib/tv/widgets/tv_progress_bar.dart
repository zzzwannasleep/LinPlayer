import 'package:flutter/material.dart';
import '../theme/tv_design_tokens.dart';
import '../theme/tv_metrics.dart';
import 'tv_focusable.dart';

/// TV 进度条
/// 支持焦点状态（高度变化），遥控器左右键快退/快进
class TvProgressBar extends StatefulWidget {
  final double progress; // 0.0 - 1.0
  final double buffered; // 0.0 - 1.0
  final Duration currentTime;
  final Duration totalTime;
  final ValueChanged<double>? onSeek;
  final bool isFocused;
  final bool showTime;

  const TvProgressBar({
    super.key,
    required this.progress,
    this.buffered = 0.0,
    required this.currentTime,
    required this.totalTime,
    this.onSeek,
    this.isFocused = false,
    this.showTime = true,
  });

  @override
  State<TvProgressBar> createState() => _TvProgressBarState();
}

class _TvProgressBarState extends State<TvProgressBar> {
  double _dragProgress = 0.0;
  bool _isDragging = false;

  String _formatDuration(Duration duration) {
    final hours = duration.inHours;
    final minutes = duration.inMinutes.remainder(60);
    final seconds = duration.inSeconds.remainder(60);
    if (hours > 0) {
      return '${hours.toString().padLeft(2, '0')}:${minutes.toString().padLeft(2, '0')}:${seconds.toString().padLeft(2, '0')}';
    }
    return '${minutes.toString().padLeft(2, '0')}:${seconds.toString().padLeft(2, '0')}';
  }

  @override
  Widget build(BuildContext context) {
    final m = context.tv;
    final displayProgress = _isDragging ? _dragProgress : widget.progress;
    final currentTime = Duration(
      milliseconds: (displayProgress * widget.totalTime.inMilliseconds).toInt(),
    );
    final remainingTime = widget.totalTime - currentTime;

    return Column(
      children: [
        if (widget.showTime)
          Padding(
            padding: EdgeInsets.only(bottom: m.spacingSm),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Text(
                  _formatDuration(currentTime),
                  style: TextStyle(
                    fontSize: m.fontSizeSm,
                    color: TvDesignTokens.textSecondary,
                  ),
                ),
                Text(
                  '-${_formatDuration(remainingTime)}',
                  style: TextStyle(
                    fontSize: m.fontSizeSm,
                    color: TvDesignTokens.textSecondary,
                  ),
                ),
              ],
            ),
          ),
        // 进度条
        TvFocusable(
          onSelect: () {},
          child: Container(
            height: widget.isFocused
                ? m.playerProgressBarFocusedHeight
                : m.playerProgressBarHeight,
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(
                widget.isFocused ? m.s(4) : m.s(2),
              ),
              color: TvDesignTokens.divider,
            ),
            child: FractionallySizedBox(
              alignment: Alignment.centerLeft,
              widthFactor: displayProgress.clamp(0.0, 1.0),
              child: Container(
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(
                    widget.isFocused ? m.s(4) : m.s(2),
                  ),
                  color: TvDesignTokens.brand,
                ),
              ),
            ),
          ),
        ),
      ],
    );
  }
}
