import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../core/providers/server_providers.dart';
import '../../../core/sources/anirss/anirss_nav_args.dart';
import '../../../core/sources/anirss/anirss_providers.dart';
import '../../../core/sources/anirss/models/ani.dart';
import '../../../core/theme/app_motion.dart';
import '../../../core/widgets/app_shimmer.dart';
import '../../utils/desktop_smooth_scroll.dart';
import '../../widgets/desktop_ani_poster_card.dart';

/// 桌面端 Ani-rss 首页：番剧海报墙（响应式多列网格）。
class DesktopAniRssHomeTab extends ConsumerWidget {
  const DesktopAniRssHomeTab({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final asyncList = ref.watch(aniListProvider);

    return asyncList.when(
      loading: () => const Center(child: AppLoadingIndicator()),
      error: (e, _) => _ErrorView(
        message: '$e',
        onRetry: () => ref.invalidate(aniListProvider),
      ),
      data: (list) {
        if (list.isEmpty) {
          return _EmptyView(onRefresh: () => ref.invalidate(aniListProvider));
        }
        return DesktopSmoothScrollBuilder(
          builder: (context, controller) => CustomScrollView(
            controller: controller,
            slivers: [
              SliverPadding(
                padding: const EdgeInsets.fromLTRB(24, 20, 24, 28),
                sliver: SliverLayoutBuilder(
                  builder: (context, constraints) {
                    const crossAxisSpacing = 18.0;
                    const mainAxisSpacing = 28.0;
                    const targetCardWidth = 168.0;

                    final availableWidth = constraints.crossAxisExtent;
                    final crossAxisCount =
                        ((availableWidth + crossAxisSpacing) /
                                (targetCardWidth + crossAxisSpacing))
                            .floor()
                            .clamp(2, 8)
                            .toInt();
                    final actualWidth = (availableWidth -
                            crossAxisSpacing * (crossAxisCount - 1)) /
                        crossAxisCount;
                    final cardHeight = actualWidth / (2 / 3) + 52;

                    return SliverGrid(
                      gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
                        crossAxisCount: crossAxisCount,
                        childAspectRatio: actualWidth / cardHeight,
                        crossAxisSpacing: crossAxisSpacing,
                        mainAxisSpacing: mainAxisSpacing,
                      ),
                      delegate: SliverChildBuilderDelegate(
                        (context, index) {
                          final ani = list[index];
                          return DesktopAniPosterCard(
                            width: actualWidth,
                            imageUrls: [if (ani.image != null) ani.image!],
                            title: ani.title,
                            rating: ani.rating,
                            subtitle: _episodeLabel(ani),
                            badge: ani.enable ? null : '未启用',
                            badgeMuted: !ani.enable,
                            onTap: () => _openDetail(context, ref, ani),
                          ).appEntrance(index: index);
                        },
                        childCount: list.length,
                      ),
                    );
                  },
                ),
              ),
            ],
          ),
        );
      },
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
    context.push('/anirss-detail',
        extra: AniRssDetailArgs(server: server, ani: ani));
  }
}

class _EmptyView extends StatelessWidget {
  final VoidCallback onRefresh;
  const _EmptyView({required this.onRefresh});
  @override
  Widget build(BuildContext context) {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Icon(Icons.rss_feed_rounded, size: 56, color: Colors.grey),
          const SizedBox(height: 12),
          const Text('暂无订阅，去「订阅」页添加番剧'),
          const SizedBox(height: 16),
          OutlinedButton.icon(
            onPressed: onRefresh,
            icon: const Icon(Icons.refresh),
            label: const Text('刷新'),
          ),
        ],
      ),
    );
  }
}

class _ErrorView extends StatelessWidget {
  final String message;
  final VoidCallback onRetry;
  const _ErrorView({required this.message, required this.onRetry});
  @override
  Widget build(BuildContext context) {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Icon(Icons.error_outline, size: 48, color: Colors.grey),
          const SizedBox(height: 12),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 32),
            child: Text(message, textAlign: TextAlign.center),
          ),
          const SizedBox(height: 16),
          FilledButton.tonal(onPressed: onRetry, child: const Text('重试')),
        ],
      ),
    );
  }
}
