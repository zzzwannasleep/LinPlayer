import 'package:flutter/material.dart';
import '../theme/tv_design_tokens.dart';
import '../theme/tv_metrics.dart';
import 'tv_focusable.dart';
import 'tv_progress_bar.dart';

/// TV 播放控制层
/// 全屏控制层，包含顶部栏、进度条、底部控制栏
class TvControlOverlay extends StatefulWidget {
  final bool isPlaying;
  final bool isPaused;
  final Duration currentTime;
  final Duration totalTime;
  final double progress;
  final String title;
  final bool hasNextEpisode;
  final bool hasPreviousEpisode;
  final bool showSkipButton;
  final VoidCallback? onPlayPause;
  final VoidCallback? onSeekBackward;
  final VoidCallback? onSeekForward;
  final VoidCallback? onNextEpisode;
  final VoidCallback? onPreviousEpisode;
  final VoidCallback? onSkip;
  final VoidCallback? onMore;
  final VoidCallback? onSubtitle;
  final VoidCallback? onAudioTrack;
  final ValueChanged<double>? onSeek;
  final VoidCallback? onClose;

  const TvControlOverlay({
    super.key,
    required this.isPlaying,
    this.isPaused = false,
    required this.currentTime,
    required this.totalTime,
    required this.progress,
    required this.title,
    this.hasNextEpisode = false,
    this.hasPreviousEpisode = false,
    this.showSkipButton = false,
    this.onPlayPause,
    this.onSeekBackward,
    this.onSeekForward,
    this.onNextEpisode,
    this.onPreviousEpisode,
    this.onSkip,
    this.onMore,
    this.onSubtitle,
    this.onAudioTrack,
    this.onSeek,
    this.onClose,
  });

  @override
  State<TvControlOverlay> createState() => _TvControlOverlayState();
}

class _TvControlOverlayState extends State<TvControlOverlay> {
  bool _showControls = true;
  int _focusedSection = 1; // 0=顶部, 1=进度条, 2=底部

  @override
  Widget build(BuildContext context) {
    final m = context.tv;
    return Stack(
      children: [
        // 背景渐变（暗化）
        AnimatedOpacity(
          duration: TvDesignTokens.playerControlFadeDuration,
          opacity: _showControls ? 1.0 : 0.0,
          child: Container(
            decoration: BoxDecoration(
              gradient: LinearGradient(
                begin: Alignment.topCenter,
                end: Alignment.bottomCenter,
                colors: [
                  Colors.black.withOpacity(0.6),
                  Colors.transparent,
                  Colors.transparent,
                  Colors.black.withOpacity(0.6),
                ],
                stops: const [0.0, 0.2, 0.8, 1.0],
              ),
            ),
          ),
        ),
        // 控制内容
        AnimatedOpacity(
          duration: TvDesignTokens.playerControlFadeDuration,
          opacity: _showControls ? 1.0 : 0.0,
          child: SafeArea(
            child: Column(
              children: [
                // 顶部栏
                _buildTopBar(m),
                const Spacer(),
                // 进度条区域
                _buildProgressSection(m),
                // 底部控制栏
                _buildBottomBar(m),
              ],
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildTopBar(TvMetrics m) {
    return Container(
      height: m.playerTopBarHeight,
      padding: EdgeInsets.symmetric(
        horizontal: m.spacingXl,
      ),
      child: Row(
        children: [
          // 返回按钮
          TvFocusable(
            onSelect: widget.onClose,
            child: Icon(
              Icons.arrow_back,
              color: TvDesignTokens.textPrimary,
              size: m.s(32),
            ),
          ),
          SizedBox(width: m.spacingLg),
          // 标题
          Expanded(
            child: Text(
              widget.title,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                fontSize: m.fontSizeLg,
                color: TvDesignTokens.textPrimary,
                fontWeight: FontWeight.bold,
              ),
            ),
          ),
          // 跳过按钮
          if (widget.showSkipButton)
            TvFocusable(
              onSelect: widget.onSkip,
              child: Container(
                padding: EdgeInsets.symmetric(
                  horizontal: m.spacingMd,
                  vertical: m.spacingXs,
                ),
                decoration: BoxDecoration(
                  color: TvDesignTokens.brand,
                  borderRadius: BorderRadius.circular(m.posterRadius),
                ),
                child: Text(
                  '跳过',
                  style: TextStyle(
                    fontSize: m.fontSizeSm,
                    color: Colors.white,
                    fontWeight: FontWeight.bold,
                  ),
                ),
              ),
            ),
          SizedBox(width: m.spacingMd),
          // 更多按钮
          TvFocusable(
            onSelect: widget.onMore,
            child: Icon(
              Icons.more_vert,
              color: TvDesignTokens.textPrimary,
              size: m.s(32),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildProgressSection(TvMetrics m) {
    return Padding(
      padding: EdgeInsets.symmetric(
        horizontal: m.spacingXl,
      ),
      child: TvFocusable(
        onSelect: () {},
        child: TvProgressBar(
          progress: widget.progress,
          currentTime: widget.currentTime,
          totalTime: widget.totalTime,
          onSeek: widget.onSeek,
          isFocused: _focusedSection == 1,
        ),
      ),
    );
  }

  Widget _buildBottomBar(TvMetrics m) {
    return Container(
      height: m.playerControlBarHeight,
      padding: EdgeInsets.symmetric(
        horizontal: m.spacingXl,
      ),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          // 上一集
          if (widget.hasPreviousEpisode)
            TvFocusable(
              onSelect: widget.onPreviousEpisode,
              child: Icon(
                Icons.skip_previous,
                color: TvDesignTokens.textPrimary,
                size: m.s(40),
              ),
            ),
          SizedBox(width: m.spacingLg),
          // 快退
          TvFocusable(
            onSelect: widget.onSeekBackward,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(
                  Icons.replay_10,
                  color: TvDesignTokens.textPrimary,
                  size: m.s(40),
                ),
                Text(
                  '10s',
                  style: TextStyle(
                    fontSize: m.fontSizeXs,
                    color: TvDesignTokens.textSecondary,
                  ),
                ),
              ],
            ),
          ),
          SizedBox(width: m.spacingLg),
          // 播放/暂停
          TvFocusable(
            autofocus: true,
            onSelect: widget.onPlayPause,
            child: Container(
              width: m.s(72),
              height: m.s(72),
              decoration: const BoxDecoration(
                color: TvDesignTokens.brand,
                shape: BoxShape.circle,
              ),
              child: Icon(
                widget.isPlaying ? Icons.pause : Icons.play_arrow,
                color: Colors.white,
                size: m.s(40),
              ),
            ),
          ),
          SizedBox(width: m.spacingLg),
          // 快进
          TvFocusable(
            onSelect: widget.onSeekForward,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(
                  Icons.forward_10,
                  color: TvDesignTokens.textPrimary,
                  size: m.s(40),
                ),
                Text(
                  '10s',
                  style: TextStyle(
                    fontSize: m.fontSizeXs,
                    color: TvDesignTokens.textSecondary,
                  ),
                ),
              ],
            ),
          ),
          SizedBox(width: m.spacingLg),
          // 下一集
          if (widget.hasNextEpisode)
            TvFocusable(
              onSelect: widget.onNextEpisode,
              child: Icon(
                Icons.skip_next,
                color: TvDesignTokens.textPrimary,
                size: m.s(40),
              ),
            ),
          const Spacer(),
          // 字幕
          TvFocusable(
            onSelect: widget.onSubtitle,
            child: Icon(
              Icons.subtitles_outlined,
              color: TvDesignTokens.textPrimary,
              size: m.s(32),
            ),
          ),
          SizedBox(width: m.spacingMd),
          // 音轨
          TvFocusable(
            onSelect: widget.onAudioTrack,
            child: Icon(
              Icons.audiotrack_outlined,
              color: TvDesignTokens.textPrimary,
              size: m.s(32),
            ),
          ),
          SizedBox(width: m.spacingMd),
          // 更多
          TvFocusable(
            onSelect: widget.onMore,
            child: Icon(
              Icons.more_vert,
              color: TvDesignTokens.textPrimary,
              size: m.s(32),
            ),
          ),
        ],
      ),
    );
  }
}
