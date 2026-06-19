import 'package:flutter/material.dart';
import '../../ui/widgets/common/media_widgets.dart';
import '../theme/tv_design_tokens.dart';
import '../theme/tv_metrics.dart';

/// TV 海报卡片
/// 16:9 或 2:3 比例，支持焦点效果
class TvPosterCard extends StatelessWidget {
  final String? imageUrl;
  final String title;
  final String? subtitle;
  final double? progress; // 0.0 - 1.0，null 表示不显示进度条
  final bool isNew;
  final String? nextEpisodeLabel;
  /// 卡片宽度，传 null 时按当前屏幕响应式取 16:9 海报宽度。
  final double? width;
  /// 卡片高度，传 null 时按当前屏幕响应式取 16:9 海报高度。
  final double? height;
  final VoidCallback? onTap;

  const TvPosterCard({
    super.key,
    this.imageUrl,
    required this.title,
    this.subtitle,
    this.progress,
    this.isNew = false,
    this.nextEpisodeLabel,
    this.width,
    this.height,
    this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final m = context.tv;
    final double width = this.width ?? m.posterWidth16_9;
    final double height = this.height ?? m.posterHeight16_9;
    return SizedBox(
      width: width,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // 海报图片
          Stack(
            children: [
              ClipRRect(
                borderRadius: BorderRadius.circular(m.posterRadius),
                child: SizedBox(
                  width: width,
                  height: height,
                  child: imageUrl != null
                      ? MediaImage(
                          imageUrl: imageUrl,
                          width: width,
                          height: height,
                          fit: BoxFit.cover,
                        )
                      : _buildPlaceholder(),
                ),
              ),
              // 进度条
              if (progress != null)
                Positioned(
                  bottom: 0,
                  left: 0,
                  right: 0,
                  child: Container(
                    height: m.s(4),
                    decoration: BoxDecoration(
                      borderRadius: BorderRadius.only(
                        bottomLeft: Radius.circular(m.posterRadius),
                        bottomRight: Radius.circular(m.posterRadius),
                      ),
                      color: Colors.black.withOpacity(0.3),
                    ),
                    child: FractionallySizedBox(
                      alignment: Alignment.centerLeft,
                      widthFactor: progress!.clamp(0.0, 1.0),
                      child: Container(
                        decoration: BoxDecoration(
                          borderRadius: BorderRadius.only(
                            bottomLeft: Radius.circular(m.posterRadius),
                            bottomRight: progress! >= 1.0
                                ? Radius.circular(m.posterRadius)
                                : Radius.zero,
                          ),
                          color: TvDesignTokens.brand,
                        ),
                      ),
                    ),
                  ),
                ),
              // "新" 标签
              if (isNew)
                Positioned(
                  top: m.spacingXs,
                  right: m.spacingXs,
                  child: Container(
                    padding: EdgeInsets.symmetric(
                      horizontal: m.spacingXs,
                      vertical: m.s(4),
                    ),
                    decoration: BoxDecoration(
                      color: TvDesignTokens.brand,
                      borderRadius: BorderRadius.circular(m.s(4)),
                    ),
                    child: Text(
                      '新',
                      style: TextStyle(
                        fontSize: m.fs(12),
                        color: Colors.white,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                  ),
                ),
              // 下一集标签
              if (nextEpisodeLabel != null)
                Positioned(
                  top: m.spacingXs,
                  right: m.spacingXs,
                  child: Container(
                    padding: EdgeInsets.symmetric(
                      horizontal: m.spacingXs,
                      vertical: m.s(4),
                    ),
                    decoration: BoxDecoration(
                      color: TvDesignTokens.brand.withOpacity(0.9),
                      borderRadius: BorderRadius.circular(m.s(4)),
                    ),
                    child: Text(
                      nextEpisodeLabel!,
                      style: TextStyle(
                        fontSize: m.fs(12),
                        color: Colors.white,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                  ),
                ),
            ],
          ),
          SizedBox(height: m.spacingXs),
          // 标题
          Text(
            title,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              fontSize: m.fontSizeSm,
              color: TvDesignTokens.textPrimary,
              fontWeight: FontWeight.w500,
            ),
          ),
          // 副标题
          if (subtitle != null)
            Text(
              subtitle!,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                fontSize: m.fontSizeXs,
                color: TvDesignTokens.textSecondary,
              ),
            ),
        ],
      ),
    );
  }

  Widget _buildPlaceholder() {
    return const ColoredBox(
      color: TvDesignTokens.surfaceElevated,
      child: Center(
        child: Icon(
          Icons.image_not_supported_outlined,
          color: TvDesignTokens.textDisabled,
          size: 48,
        ),
      ),
    );
  }
}
