import 'package:flutter/material.dart';
import 'package:flutter_animate/flutter_animate.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../core/providers/server_providers.dart';
import '../../../core/sources/anirss/anirss_nav_args.dart';
import '../../../core/sources/anirss/anirss_providers.dart';
import '../../../core/sources/anirss/models/ani.dart';
import '../../../ui/widgets/common/media_widgets.dart';
import '../../theme/tv_design_tokens.dart';
import '../../theme/tv_metrics.dart';
import '../../widgets/tv_focusable.dart';

/// Ani-rss 首页 Tab（TV）：番剧海报墙网格。max-extent 响应式网格 + D-pad 焦点。
class TvAniRssHomeTab extends ConsumerWidget {
  const TvAniRssHomeTab({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final m = context.tv;
    final asyncList = ref.watch(aniListProvider);
    return asyncList.when(
      loading: () => const Center(
          child: CircularProgressIndicator(color: TvDesignTokens.brand)),
      error: (e, _) => _centerHint(m, '加载失败：$e'),
      data: (list) {
        if (list.isEmpty) {
          return _centerHint(m, '暂无订阅，去「订阅」页添加番剧');
        }
        final double maxExtent = m.posterWidth2_3;
        return GridView.builder(
          gridDelegate: SliverGridDelegateWithMaxCrossAxisExtent(
            maxCrossAxisExtent: maxExtent,
            childAspectRatio: 2 / 3.5,
            crossAxisSpacing: m.posterSpacing,
            mainAxisSpacing: m.posterSpacing,
          ),
          itemCount: list.length,
          itemBuilder: (context, index) {
            final ani = list[index];
            return TvFocusable(
              padding: EdgeInsets.all(m.s(6)),
              onSelect: () => _openDetail(context, ref, ani),
              child: _card(m, ani),
            ).animate().fadeIn(
                  delay: Duration(milliseconds: 12 * (index % 6)),
                  duration: TvDesignTokens.contentFadeDuration,
                );
          },
        );
      },
    );
  }

  Widget _card(TvMetrics m, AniModel ani) {
    final epLabel = _episodeLabel(ani);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Expanded(
          child: ClipRRect(
            borderRadius: BorderRadius.circular(m.posterRadius),
            child: Stack(
              fit: StackFit.expand,
              children: [
                ani.image != null
                    ? MediaImage(
                        imageUrl: ani.image,
                        width: double.infinity,
                        height: double.infinity,
                        fit: BoxFit.cover,
                      )
                    : ColoredBox(
                        color: TvDesignTokens.surfaceElevated,
                        child: Icon(Icons.tv_rounded,
                            color: TvDesignTokens.textDisabled, size: m.s(40)),
                      ),
                if (ani.rating != null)
                  Positioned(
                    top: m.spacingXs,
                    left: m.spacingXs,
                    child: Container(
                      padding: EdgeInsets.symmetric(
                          horizontal: m.s(8), vertical: m.s(2)),
                      decoration: BoxDecoration(
                        color: Colors.black.withValues(alpha: 0.6),
                        borderRadius: BorderRadius.circular(m.s(4)),
                      ),
                      child: Text(
                        '★ ${ani.rating!.toStringAsFixed(1)}',
                        style: TextStyle(
                          fontSize: m.fs(12),
                          color: Colors.amber,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                    ),
                  ),
                if (!ani.enable)
                  Positioned(
                    top: m.spacingXs,
                    right: m.spacingXs,
                    child: Container(
                      padding: EdgeInsets.symmetric(
                          horizontal: m.s(8), vertical: m.s(2)),
                      decoration: BoxDecoration(
                        color: Colors.black.withValues(alpha: 0.6),
                        borderRadius: BorderRadius.circular(m.s(4)),
                      ),
                      child: Text(
                        '未启用',
                        style: TextStyle(
                          fontSize: m.fs(12),
                          color: TvDesignTokens.textSecondary,
                        ),
                      ),
                    ),
                  ),
              ],
            ),
          ),
        ),
        SizedBox(height: m.spacingXs),
        Text(
          ani.title,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: TextStyle(
            fontSize: m.fontSizeXs,
            color: TvDesignTokens.textPrimary,
            fontWeight: FontWeight.w500,
          ),
        ),
        if (epLabel != null)
          Text(
            epLabel,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              fontSize: m.fs(12),
              color: TvDesignTokens.textSecondary,
            ),
          ),
      ],
    );
  }

  static String? _episodeLabel(AniModel ani) {
    final cur = ani.currentEpisodeNumber;
    final total = ani.totalEpisodeNumber;
    if (cur != null && total != null && total > 0) return '$cur / $total 集';
    if (cur != null && cur > 0) return '更新至 $cur 集';
    return null;
  }

  void _openDetail(BuildContext context, WidgetRef ref, AniModel ani) {
    final server = ref.read(currentServerProvider);
    if (server == null) return;
    context.push('/tv/anirss-detail',
        extra: AniRssDetailArgs(server: server, ani: ani));
  }

  Widget _centerHint(TvMetrics m, String text) => Center(
        child: Text(
          text,
          style: TextStyle(
            color: TvDesignTokens.textSecondary,
            fontSize: m.fontSizeMd,
          ),
        ),
      );
}
