import 'package:flutter/material.dart';

import '../common/media_widgets.dart';

/// Ani-rss 番剧海报卡（移动端，复刻 Emby MediaPoster 视觉：2:3 海报 + 评分角标 + 标题）。
class AniPosterCard extends StatelessWidget {
  final List<String> imageUrls;
  final String title;
  final String? subtitle;
  final double? rating;

  /// 右上角小角标（如「12 集」/「未启用」）。
  final String? badge;

  /// 角标是否警示色（如未启用订阅）。
  final bool badgeMuted;
  final VoidCallback? onTap;

  const AniPosterCard({
    super.key,
    required this.imageUrls,
    required this.title,
    this.subtitle,
    this.rating,
    this.badge,
    this.badgeMuted = false,
    this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    const radius = BorderRadius.all(Radius.circular(10));
    return InkWell(
      onTap: onTap,
      borderRadius: radius,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          AspectRatio(
            aspectRatio: 2 / 3,
            child: Stack(
              children: [
                Positioned.fill(
                  child: MediaImage(
                    imageUrl: imageUrls.isEmpty ? null : imageUrls.first,
                    imageUrls: imageUrls,
                    fit: BoxFit.cover,
                    borderRadius: radius,
                  ),
                ),
                if (rating != null && rating! > 0)
                  Positioned(
                    top: 6,
                    left: 6,
                    child: _Chip(
                      icon: Icons.star_rounded,
                      iconColor: Colors.amber,
                      text: rating!.toStringAsFixed(1),
                    ),
                  ),
                if (badge != null)
                  Positioned(
                    top: 6,
                    right: 6,
                    child: _Chip(
                      text: badge!,
                      muted: badgeMuted,
                    ),
                  ),
              ],
            ),
          ),
          const SizedBox(height: 6),
          Text(
            title,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(
              fontSize: 13,
              fontWeight: FontWeight.w600,
              height: 1.2,
            ),
          ),
          if (subtitle != null && subtitle!.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(top: 2),
              child: Text(
                subtitle!,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  fontSize: 11,
                  color: Theme.of(context).textTheme.bodySmall?.color,
                ),
              ),
            ),
        ],
      ),
    );
  }
}

class _Chip extends StatelessWidget {
  final String text;
  final IconData? icon;
  final Color? iconColor;
  final bool muted;
  const _Chip({required this.text, this.icon, this.iconColor, this.muted = false});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 3),
      decoration: BoxDecoration(
        color: (muted ? Colors.red.shade900 : Colors.black).withValues(alpha: 0.62),
        borderRadius: BorderRadius.circular(6),
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
