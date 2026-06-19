import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../../core/theme/app_motion.dart';
import '../../ui/widgets/common/media_widgets.dart';
import '../theme/tv_design_tokens.dart';
import '../theme/tv_metrics.dart';
import 'tv_button.dart';

/// TV Hero Banner
/// 自动轮播（10秒），支持遥控器左右切换
class TvHeroBanner extends StatefulWidget {
  final List<TvHeroItem> items;
  final VoidCallback? onAutoPlayStarted;
  final VoidCallback? onAutoPlayStopped;

  /// 可选高度覆盖；传 null 时按响应式 [TvMetrics.heroHeight]。
  /// 首页传入视口比例高度，让 Hero 至少占首屏一半。
  final double? height;

  const TvHeroBanner({
    super.key,
    required this.items,
    this.onAutoPlayStarted,
    this.onAutoPlayStopped,
    this.height,
  });

  @override
  State<TvHeroBanner> createState() => _TvHeroBannerState();
}

class _TvHeroBannerState extends State<TvHeroBanner> {
  int _currentIndex = 0;
  Timer? _autoPlayTimer;
  bool _isPaused = false;
  final PageController _pageController = PageController();

  @override
  void initState() {
    super.initState();
    _startAutoPlay();
  }

  @override
  void dispose() {
    _autoPlayTimer?.cancel();
    _pageController.dispose();
    super.dispose();
  }

  void _startAutoPlay() {
    _autoPlayTimer?.cancel();
    _autoPlayTimer = Timer.periodic(
      TvDesignTokens.heroAutoPlayInterval,
      (_) => _nextPage(),
    );
    widget.onAutoPlayStarted?.call();
  }

  void _stopAutoPlay() {
    _autoPlayTimer?.cancel();
    widget.onAutoPlayStopped?.call();
  }

  void _nextPage() {
    if (_isPaused || widget.items.length <= 1) return;
    final nextIndex = (_currentIndex + 1) % widget.items.length;
    _pageController.animateToPage(
      nextIndex,
      duration: TvDesignTokens.heroTransitionDuration,
      curve: TvDesignTokens.heroTransitionCurve,
    );
  }

  void _previousPage() {
    if (widget.items.length <= 1) return;
    final prevIndex = (_currentIndex - 1 + widget.items.length) % widget.items.length;
    _pageController.animateToPage(
      prevIndex,
      duration: TvDesignTokens.heroTransitionDuration,
      curve: TvDesignTokens.heroTransitionCurve,
    );
  }

  @override
  Widget build(BuildContext context) {
    if (widget.items.isEmpty) return const SizedBox.shrink();

    final m = context.tv;
    return Focus(
      onFocusChange: (focused) {
        setState(() => _isPaused = !focused);
        if (focused) {
          _startAutoPlay();
        } else {
          _stopAutoPlay();
        }
      },
      onKeyEvent: (node, event) {
        if (event is KeyDownEvent) {
          if (event.logicalKey == LogicalKeyboardKey.arrowRight) {
            _nextPage();
            return KeyEventResult.handled;
          } else if (event.logicalKey == LogicalKeyboardKey.arrowLeft) {
            _previousPage();
            return KeyEventResult.handled;
          }
        }
        return KeyEventResult.ignored;
      },
      child: SizedBox(
        height: widget.height ?? m.heroHeight,
        child: Stack(
          children: [
            // PageView 轮播
            PageView.builder(
              controller: _pageController,
              itemCount: widget.items.length,
              onPageChanged: (index) => setState(() => _currentIndex = index),
              itemBuilder: (context, index) =>
                  _buildHeroItem(widget.items[index], m),
            ),
            // 底部渐变遮罩
            Positioned(
              bottom: 0,
              left: 0,
              right: 0,
              height: m.heroOverlayHeight,
              child: Container(
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                    begin: Alignment.topCenter,
                    end: Alignment.bottomCenter,
                    colors: [
                      Colors.transparent,
                      TvDesignTokens.background.withOpacity(0.7),
                      TvDesignTokens.background,
                    ],
                  ),
                ),
              ),
            ),
            // 指示器
            Positioned(
              bottom: m.spacingLg,
              left: 0,
              right: 0,
              child: Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: List.generate(
                  widget.items.length,
                  (index) => AnimatedContainer(
                    duration: TvDesignTokens.focusAnimationDuration,
                    margin: EdgeInsets.symmetric(horizontal: m.s(4)),
                    width: _currentIndex == index ? m.s(24) : m.s(8),
                    height: m.s(8),
                    decoration: BoxDecoration(
                      color: _currentIndex == index
                          ? TvDesignTokens.brand
                          : const Color(0x40FFFFFF),
                      borderRadius: BorderRadius.circular(m.s(4)),
                    ),
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildHeroItem(TvHeroItem item, TvMetrics m) {
    return Stack(
      fit: StackFit.expand,
      children: [
        // 背景图（走持久化缓存，避免轮播回切时重新下载）
        item.imageUrl != null
            ? MediaImage(
                imageUrl: item.imageUrl,
                width: double.infinity,
                height: double.infinity,
                fit: BoxFit.cover,
              )
            : _buildPlaceholder(m),
        // 渐变遮罩
        Container(
          decoration: BoxDecoration(
            gradient: LinearGradient(
              begin: Alignment.centerLeft,
              end: Alignment.centerRight,
              colors: [
                TvDesignTokens.background.withOpacity(0.8),
                Colors.transparent,
              ],
            ),
          ),
        ),
        // 内容信息（随每张轮播淡入上滑）
        Positioned(
          left: m.spacingXxl,
          bottom: m.spacingXxl,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              _buildLogoOrTitle(item, m),
              if (item.subtitle != null) ...[
                SizedBox(height: m.spacingSm),
                Text(
                  item.subtitle!,
                  style: TextStyle(
                    fontSize: m.heroSubtitleSize,
                    color: TvDesignTokens.textSecondary,
                  ),
                ),
              ],
              if (item.tags != null && item.tags!.isNotEmpty) ...[
                SizedBox(height: m.spacingSm),
                Row(
                  children: item.tags!.map((tag) {
                    return Container(
                      margin: EdgeInsets.only(right: m.spacingSm),
                      padding: EdgeInsets.symmetric(
                        horizontal: m.spacingSm,
                        vertical: m.s(4),
                      ),
                      decoration: BoxDecoration(
                        color: TvDesignTokens.surface,
                        borderRadius: BorderRadius.circular(m.s(4)),
                      ),
                      child: Text(
                        tag,
                        style: TextStyle(
                          fontSize: m.fontSizeXs,
                          color: TvDesignTokens.textSecondary,
                        ),
                      ),
                    );
                  }).toList(),
                ),
              ],
              SizedBox(height: m.spacingLg),
              // 操作按钮（TDesign 按钮 + TV 焦点）
              Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  if (item.onPlay != null)
                    TvButton(
                      text: '播放',
                      icon: Icons.play_arrow,
                      onPressed: item.onPlay,
                    ),
                  if (item.onDetail != null) ...[
                    SizedBox(width: m.spacingSm),
                    TvButton(
                      text: '详情',
                      icon: Icons.info_outline,
                      outlined: true,
                      onPressed: item.onDetail,
                    ),
                  ],
                ],
              ),
            ],
          ).appEntrance(),
        ),
      ],
    );
  }

  /// 优先使用 Logo 艺术字图片，无 Logo 时回退到文字标题
  Widget _buildLogoOrTitle(TvHeroItem item, TvMetrics m) {
    if (item.logoUrl != null && item.logoUrl!.isNotEmpty) {
      return Image.network(
        item.logoUrl!,
        height: m.s(48),
        fit: BoxFit.contain,
        alignment: Alignment.centerLeft,
        errorBuilder: (_, __, ___) => _buildTitleText(item.title, m),
        frameBuilder: (_, child, frame, wasSynchronouslyLoaded) {
          if (wasSynchronouslyLoaded || frame != null) return child;
          return _buildTitleText(item.title, m);
        },
      );
    }
    return _buildTitleText(item.title, m);
  }

  Widget _buildTitleText(String title, TvMetrics m) {
    return Text(
      title,
      style: TextStyle(
        fontSize: m.heroTitleSize,
        color: TvDesignTokens.textPrimary,
        fontWeight: FontWeight.bold,
      ),
    );
  }

  Widget _buildPlaceholder(TvMetrics m) {
    return Container(
      color: TvDesignTokens.surfaceElevated,
      child: Center(
        child: Icon(
          Icons.image_not_supported_outlined,
          color: TvDesignTokens.textDisabled,
          size: m.s(64),
        ),
      ),
    );
  }
}

/// Hero Banner 数据模型
class TvHeroItem {
  final String? imageUrl;
  final String title;
  final String? subtitle;
  final List<String>? tags;
  final VoidCallback? onPlay;
  final VoidCallback? onDetail;
  final String? logoUrl;      // Logo 艺术字图片 URL

  const TvHeroItem({
    this.imageUrl,
    required this.title,
    this.subtitle,
    this.tags,
    this.onPlay,
    this.onDetail,
    this.logoUrl,
  });
}
