import 'package:flutter/material.dart';

import '../../ui/widgets/common/media_widgets.dart';
import 'desktop_cover_radii.dart';

/// 桌面端 Ani-rss 番剧海报卡：复刻 [DesktopMediaCard] 的视觉（2:3 海报 + 评分角标
/// + hover 上移/遮罩），但不依赖 MediaItem，改吃裸字段，供追番迷你应用使用。
class DesktopAniPosterCard extends StatefulWidget {
  final List<String> imageUrls;
  final String title;
  final String? subtitle;
  final double? rating;

  /// 右上角小角标（如「未启用」）。
  final String? badge;

  /// 角标是否警示色（如未启用订阅）。
  final bool badgeMuted;
  final double width;
  final VoidCallback? onTap;

  const DesktopAniPosterCard({
    super.key,
    required this.imageUrls,
    required this.title,
    required this.width,
    this.subtitle,
    this.rating,
    this.badge,
    this.badgeMuted = false,
    this.onTap,
  });

  @override
  State<DesktopAniPosterCard> createState() => _DesktopAniPosterCardState();
}

class _DesktopAniPosterCardState extends State<DesktopAniPosterCard> {
  bool _isHovered = false;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    const aspectRatio = 2 / 3;

    return RepaintBoundary(
      child: MouseRegion(
        onEnter: (_) => setState(() => _isHovered = true),
        onExit: (_) => setState(() => _isHovered = false),
        cursor: SystemMouseCursors.click,
        child: GestureDetector(
          onTap: widget.onTap,
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 160),
            curve: Curves.fastOutSlowIn,
            width: widget.width,
            transform: _isHovered
                ? (Matrix4.identity()..translateByDouble(0.0, -4.0, 0.0, 1.0))
                : Matrix4.identity(),
            transformAlignment: Alignment.center,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                AspectRatio(
                  aspectRatio: aspectRatio,
                  child: ClipRRect(
                    borderRadius: desktopPortraitCoverRadius,
                    child: Stack(
                      fit: StackFit.expand,
                      children: [
                        MediaImage(
                          imageUrl: widget.imageUrls.isNotEmpty
                              ? widget.imageUrls.first
                              : null,
                          imageUrls: widget.imageUrls,
                          width: widget.width,
                          height: widget.width / aspectRatio,
                          fit: BoxFit.cover,
                        ),
                        AnimatedOpacity(
                          duration: const Duration(milliseconds: 120),
                          opacity: _isHovered ? 1.0 : 0.0,
                          child: Container(
                            decoration: BoxDecoration(
                              gradient: LinearGradient(
                                begin: Alignment.topCenter,
                                end: Alignment.bottomCenter,
                                colors: [
                                  Colors.transparent,
                                  Colors.black.withValues(alpha: 0.6),
                                ],
                              ),
                            ),
                            child: const Center(
                              child: Icon(
                                Icons.play_circle_outline,
                                size: 48,
                                color: Colors.white,
                              ),
                            ),
                          ),
                        ),
                        if (widget.rating != null && widget.rating! > 0)
                          Positioned(
                            top: 8,
                            left: 8,
                            child: _Chip(
                              icon: Icons.star_rounded,
                              iconColor: Colors.amber,
                              text: widget.rating!.toStringAsFixed(1),
                            ),
                          ),
                        if (widget.badge != null)
                          Positioned(
                            top: 8,
                            right: 8,
                            child: _Chip(
                              text: widget.badge!,
                              muted: widget.badgeMuted,
                            ),
                          ),
                      ],
                    ),
                  ),
                ),
                const SizedBox(height: 8),
                Text(
                  widget.title,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.titleSmall?.copyWith(
                    height: 1.24,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                if (widget.subtitle != null && widget.subtitle!.isNotEmpty)
                  Padding(
                    padding: const EdgeInsets.only(top: 2),
                    child: Text(
                      widget.subtitle!,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.bodySmall?.copyWith(height: 1.22),
                    ),
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _Chip extends StatelessWidget {
  final String text;
  final IconData? icon;
  final Color? iconColor;
  final bool muted;
  const _Chip({
    required this.text,
    this.icon,
    this.iconColor,
    this.muted = false,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 3),
      decoration: BoxDecoration(
        color: (muted ? Colors.red.shade900 : Colors.black)
            .withValues(alpha: 0.62),
        borderRadius: BorderRadius.circular(4),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (icon != null) ...[
            Icon(icon, size: 12, color: iconColor ?? Colors.white),
            const SizedBox(width: 2),
          ],
          Text(
            text,
            style: const TextStyle(
              fontSize: 11,
              fontWeight: FontWeight.w600,
              color: Colors.white,
            ),
          ),
        ],
      ),
    );
  }
}
