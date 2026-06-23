import 'package:flutter/material.dart';
import 'package:flutter_animate/flutter_animate.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../core/api/api_interfaces.dart';
import '../../../core/providers/app_providers.dart';
import '../../../core/providers/media_providers.dart';
import '../../../ui/utils/media_helpers.dart';
import '../source/tv_source_browse_screen.dart';
import '../../theme/tv_design_tokens.dart';
import '../../theme/tv_metrics.dart';
import '../../widgets/tv_button.dart';
import '../../widgets/tv_content_row.dart';
import '../../widgets/tv_hero_banner.dart';

/// TV 首页
/// Hero Banner（每日推荐）+ 继续观看 + 媒体库，全部接入真实数据。
class TvHomeScreen extends ConsumerStatefulWidget {
  const TvHomeScreen({super.key});

  @override
  ConsumerState<TvHomeScreen> createState() => _TvHomeScreenState();
}

class _TvHomeScreenState extends ConsumerState<TvHomeScreen> {
  bool _heroFocused = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _refresh();
    });
  }

  void _refresh() {
    ref.invalidate(resumeItemsProvider);
    ref.invalidate(librariesProvider);
    ref.invalidate(randomRecommendationsProvider);
  }

  @override
  Widget build(BuildContext context) {
    final m = context.tv;
    // Hero 至少占首屏一半：以视口高度的 56% 作为目标高度。
    final double heroHeight = MediaQuery.sizeOf(context).height * 0.56;
    final servers = ref.watch(serverListProvider);
    if (servers.isEmpty) {
      return _buildEmptyServers(m);
    }

    // 网盘/聚合源：首页改渲染文件浏览视图（保留侧边栏）。
    final currentServer = ref.watch(currentServerProvider);
    if (currentServer != null && currentServer.isFileBrowse) {
      return TvSourceBrowseView(server: currentServer);
    }

    final api = ref.read(apiClientProvider);
    final recommendationsAsync = ref.watch(randomRecommendationsProvider);
    final resumeAsync = ref.watch(resumeItemsProvider);
    final librariesAsync = ref.watch(librariesProvider);

    return Scaffold(
      backgroundColor: TvDesignTokens.background,
      body: Focus(
        autofocus: true,
        onKeyEvent: (node, event) => KeyEventResult.ignored,
        child: SingleChildScrollView(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // Hero Banner（每日推荐）—— 放大至首屏一半以上
              recommendationsAsync.when(
                data: (items) {
                  final heroItems = _heroItems(api, items);
                  if (heroItems.isEmpty) {
                    return _heroPlaceholder(m, heroHeight);
                  }
                  return Focus(
                    onFocusChange: (f) => setState(() => _heroFocused = f),
                    child: TvHeroBanner(items: heroItems, height: heroHeight),
                  );
                },
                loading: () => _heroPlaceholder(m, heroHeight),
                error: (_, __) => _heroPlaceholder(m, heroHeight),
              ),
              SizedBox(height: m.spacingLg),
              // 继续观看
              resumeAsync.when(
                data: (items) {
                  final visible = items
                      .where((i) => !(i.userData?.played ?? false))
                      .toList(growable: false);
                  if (visible.isEmpty) return const SizedBox.shrink();
                  return TvContentRow(
                    title: '继续观看',
                    items: _resumeCards(api, visible),
                    autofocusFirstItem: !_heroFocused,
                  );
                },
                loading: () => _rowPlaceholder('继续观看', m),
                error: (_, __) => const SizedBox.shrink(),
              ),
              SizedBox(height: m.spacingLg),
              // 媒体库快捷入口
              librariesAsync.when(
                data: (libs) {
                  if (libs.isEmpty) return const SizedBox.shrink();
                  return TvContentRow(
                    title: '媒体库',
                    items: _libraryCards(api, libs),
                    onSeeAll: () => context.go('/tv/library'),
                  );
                },
                loading: () => _rowPlaceholder('媒体库', m),
                error: (_, __) => const SizedBox.shrink(),
              ),
              SizedBox(height: m.spacingLg),
              // 各媒体库最新内容（对齐 PC 端首页布局）
              librariesAsync.when(
                data: (libs) => Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    for (final lib in libs)
                      Padding(
                        padding: EdgeInsets.only(bottom: m.spacingMd),
                        child: _TvLibraryLatestRow(library: lib),
                      ),
                  ],
                ),
                loading: () => const SizedBox.shrink(),
                error: (_, __) => const SizedBox.shrink(),
              ),
              SizedBox(height: m.spacingXxl),
            ],
          ),
        ),
      ),
    );
  }

  // ============ 数据映射 ============

  List<TvHeroItem> _heroItems(ApiClientFactory api, List<MediaItem> items) {
    final result = <TvHeroItem>[];
    for (final it in items) {
      final banner = resolveMediaItemBannerImageUrls(
        api,
        it,
        maxWidth: 1600,
        allowPosterFallback: true,
      );
      if (banner.isEmpty) continue;
      final logo = (it.logoItemId != null && it.logoImageTag != null)
          ? api.image
              .getLogoImageUrl(it.logoItemId!, tag: it.logoImageTag, maxWidth: 280)
          : null;
      result.add(TvHeroItem(
        imageUrl: banner.first,
        logoUrl: logo,
        title: it.name,
        subtitle: _heroSubtitle(it),
        tags: it.genres?.take(3).toList(growable: false),
        onPlay: () => context.push('/tv/player?mediaId=${it.id}'),
        onDetail: () => context.push('/tv/detail/${it.id}'),
      ));
      if (result.length >= 6) break;
    }
    return result;
  }

  List<TvPosterCardData> _resumeCards(
      ApiClientFactory api, List<MediaItem> items) {
    return items.map((it) {
      final urls = resolveMediaItemLandscapeImageUrls(api, it, maxWidth: 720);
      // 点击继续观看 → 进入详情页（剧集回到所属剧的详情，便于挑集/查看信息）。
      final detailId =
          (it.type == 'Episode' && (it.seriesId?.isNotEmpty ?? false))
              ? it.seriesId!
              : it.id;
      return TvPosterCardData(
        imageUrl: urls.isNotEmpty ? urls.first : null,
        title: _continueTitle(it),
        subtitle: _continueSubtitle(it),
        nextEpisodeLabel: _continueBadge(it),
        progress: it.progress,
        onTap: () => context.push('/tv/detail/$detailId'),
      );
    }).toList(growable: false);
  }

  List<TvPosterCardData> _libraryCards(ApiClientFactory api, List<Library> libs) {
    return libs.map((lib) {
      final urls = resolveLibraryImageUrls(api, lib, maxWidth: 400);
      return TvPosterCardData(
        imageUrl: urls.isNotEmpty ? urls.first : null,
        title: lib.name,
        onTap: () => context.go('/tv/library?libraryId=${lib.id}'),
      );
    }).toList(growable: false);
  }

  String? _heroSubtitle(MediaItem it) {
    final parts = <String>[];
    if (it.productionYear != null) parts.add('${it.productionYear}');
    if (it.communityRating != null) {
      parts.add('★ ${it.communityRating!.toStringAsFixed(1)}');
    }
    return parts.isEmpty ? null : parts.join('  ·  ');
  }

  String _continueTitle(MediaItem it) {
    if (it.type == 'Episode') {
      final s = it.seriesName?.trim();
      if (s != null && s.isNotEmpty) return s;
    }
    return it.name;
  }

  String? _continueSubtitle(MediaItem it) {
    if (it.type != 'Episode') return null;
    final parts = <String>[];
    if (it.parentIndexNumber != null) parts.add('第${it.parentIndexNumber}季');
    if (it.indexNumber != null) parts.add('第${it.indexNumber}集');
    if (it.name.trim().isNotEmpty) parts.add(it.name);
    return parts.isEmpty ? null : parts.join(' · ');
  }

  /// 继续观看卡片右上角的「SxEx」角标，保证季/集信息醒目可见。
  String? _continueBadge(MediaItem it) {
    if (it.type != 'Episode') return null;
    final s = it.parentIndexNumber;
    final e = it.indexNumber;
    if (s == null && e == null) return null;
    final sb = StringBuffer();
    if (s != null) sb.write('S$s');
    if (e != null) sb.write('E$e');
    return sb.toString();
  }

  // ============ 占位 / 空态 ============

  Widget _heroPlaceholder(TvMetrics m, double height) {
    return Container(
      height: height,
      color: TvDesignTokens.surface,
      alignment: Alignment.center,
      child: Icon(
        Icons.movie_outlined,
        color: TvDesignTokens.textDisabled,
        size: m.s(64),
      ),
    ).animate(onPlay: (c) => c.repeat()).shimmer(
          duration: TvDesignTokens.shimmerDuration,
          color: Colors.white10,
        );
  }

  Widget _rowPlaceholder(String title, TvMetrics m) {
    return Padding(
      padding: EdgeInsets.symmetric(
        horizontal: m.spacingXl,
        vertical: m.spacingMd,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            title,
            style: TextStyle(
              fontSize: m.fontSizeLg,
              color: TvDesignTokens.textPrimary,
              fontWeight: FontWeight.bold,
            ),
          ),
          SizedBox(height: m.spacingMd),
          SizedBox(
            height: m.posterHeight16_9,
            child: Row(
              children: List.generate(
                4,
                (i) => Container(
                  width: m.posterWidth16_9,
                  height: m.posterHeight16_9,
                  margin: EdgeInsets.only(right: m.posterSpacing),
                  decoration: BoxDecoration(
                    color: TvDesignTokens.surfaceElevated,
                    borderRadius: BorderRadius.circular(m.posterRadius),
                  ),
                ),
              ),
            ),
          ).animate(onPlay: (c) => c.repeat()).shimmer(
                duration: TvDesignTokens.shimmerDuration,
                color: Colors.white10,
              ),
        ],
      ),
    );
  }

  Widget _buildEmptyServers(TvMetrics m) {
    return Scaffold(
      backgroundColor: TvDesignTokens.background,
      body: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              Icons.dns_outlined,
              color: TvDesignTokens.textSecondary,
              size: m.s(96),
            ),
            SizedBox(height: m.spacingLg),
            Text(
              '还没有连接服务器',
              style: TextStyle(
                fontSize: m.fontSizeXl,
                color: TvDesignTokens.textPrimary,
                fontWeight: FontWeight.bold,
              ),
            ),
            SizedBox(height: m.spacingSm),
            Text(
              '连接 Emby 服务器后即可浏览媒体库',
              style: TextStyle(
                fontSize: m.fontSizeSm,
                color: TvDesignTokens.textSecondary,
              ),
            ),
            SizedBox(height: m.spacingXl),
            TvButton(
              text: '添加服务器',
              icon: Icons.add,
              autofocus: true,
              onPressed: () => context.go('/tv/server'),
            ),
          ],
        ).animate().fadeIn(duration: TvDesignTokens.contentFadeDuration).moveY(
              begin: 12,
              end: 0,
              duration: TvDesignTokens.contentFadeDuration,
              curve: Curves.easeOut,
            ),
      ),
    );
  }
}

/// 单个媒体库的「最新内容」横向行（对齐 PC 端首页：每个媒体库一行最新条目）。
class _TvLibraryLatestRow extends ConsumerWidget {
  final Library library;

  const _TvLibraryLatestRow({required this.library});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final m = context.tv;
    final api = ref.read(apiClientProvider);
    final latestAsync = ref.watch(latestItemsProvider(library.id));

    return latestAsync.when(
      data: (items) {
        if (items.isEmpty) return const SizedBox.shrink();
        final cards = items.map((it) {
          final urls = resolveMediaItemImageUrls(api, it, maxWidth: 360);
          return TvPosterCardData(
            imageUrl: urls.isNotEmpty ? urls.first : null,
            title: it.name,
            subtitle: it.productionYear != null ? '${it.productionYear}' : null,
            width: m.posterWidth2_3,
            height: m.posterHeight2_3,
            onTap: () => context.push('/tv/detail/${it.id}'),
          );
        }).toList(growable: false);
        return TvContentRow(
          title: library.name,
          items: cards,
          onSeeAll: () => context.go('/tv/library?libraryId=${library.id}'),
        );
      },
      loading: () => const SizedBox.shrink(),
      error: (_, __) => const SizedBox.shrink(),
    );
  }
}
