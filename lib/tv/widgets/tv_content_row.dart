import 'package:flutter/material.dart';
import '../../core/theme/app_motion.dart';
import '../theme/tv_design_tokens.dart';
import '../theme/tv_metrics.dart';
import 'tv_focusable.dart';
import 'tv_poster_card.dart';

/// TV 横向内容行
/// 包含标题 + 横向可滚动的海报卡片列表
class TvContentRow extends StatelessWidget {
  final String title;
  final List<TvPosterCardData> items;
  final VoidCallback? onSeeAll;
  final bool autofocusFirstItem;

  const TvContentRow({
    super.key,
    required this.title,
    required this.items,
    this.onSeeAll,
    this.autofocusFirstItem = false,
  });

  @override
  Widget build(BuildContext context) {
    final m = context.tv;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // 行标题
        Padding(
          padding: EdgeInsets.symmetric(
            horizontal: m.spacingXl,
            vertical: m.spacingMd,
          ),
          child: Row(
            children: [
              Text(
                title,
                style: TextStyle(
                  fontSize: m.fontSizeLg,
                  color: TvDesignTokens.textPrimary,
                  fontWeight: FontWeight.bold,
                ),
              ),
              if (onSeeAll != null) ...[
                const Spacer(),
                TvFocusable(
                  onSelect: onSeeAll,
                  child: Container(
                    padding: EdgeInsets.symmetric(
                      horizontal: m.spacingMd,
                      vertical: m.spacingXs,
                    ),
                    child: Row(
                      children: [
                        Text(
                          '查看全部',
                          style: TextStyle(
                            fontSize: m.fontSizeSm,
                            color: TvDesignTokens.brand,
                          ),
                        ),
                        Icon(
                          Icons.chevron_right,
                          color: TvDesignTokens.brand,
                          size: m.s(24),
                        ),
                      ],
                    ),
                  ),
                ),
              ],
            ],
          ),
        ),
        // 横向滚动列表：行高随卡片高度自适应（支持 16:9 与 2:3 海报混用）
        SizedBox(
          height: ((items.isNotEmpty ? items.first.height : null) ??
                  m.posterHeight16_9) +
              m.s(60), // 海报 + 文字区域
          child: ListView.builder(
            scrollDirection: Axis.horizontal,
            padding: EdgeInsets.symmetric(
              horizontal: m.spacingXl,
            ),
            itemCount: items.length,
            itemBuilder: (context, index) {
              final item = items[index];
              return Padding(
                padding: EdgeInsets.only(
                  right: m.posterSpacing,
                ),
                child: TvFocusable(
                  autofocus: autofocusFirstItem && index == 0,
                  onSelect: item.onTap,
                  child: TvPosterCard(
                    imageUrl: item.imageUrl,
                    title: item.title,
                    subtitle: item.subtitle,
                    progress: item.progress,
                    isNew: item.isNew,
                    nextEpisodeLabel: item.nextEpisodeLabel,
                    width: item.width ?? m.posterWidth16_9,
                    height: item.height ?? m.posterHeight16_9,
                  ),
                ),
              ).appEntrance(index: index);
            },
          ),
        ),
      ],
    );
  }
}

/// TV 海报卡片数据模型
class TvPosterCardData {
  final String? imageUrl;
  final String title;
  final String? subtitle;
  final double? progress;
  final bool isNew;
  final String? nextEpisodeLabel;
  final double? width;
  final double? height;
  final VoidCallback? onTap;

  const TvPosterCardData({
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
}
