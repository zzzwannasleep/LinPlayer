import 'package:flutter/material.dart';
import 'package:flutter_animate/flutter_animate.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../core/api/api_interfaces.dart';
import '../../../core/providers/app_providers.dart';
import '../../../core/providers/media_providers.dart';
import '../../../ui/utils/media_helpers.dart';
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
    final servers = ref.watch(serverListProvider);
    if (servers.isEmpty) {
      return _buildEmptyServers(m);
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
              // Hero Banner（每日推荐）
              recommendationsAsync.when(
                data: (items) {
                  final heroItems = _heroItems(api, items);
                  if (heroItems.isEmpty) return _heroPlaceholder(m);
                  return Focus(
                    onFocusChange: (f) => setState(() => _heroFocused = f),
                    child: TvHeroBanner(items: heroItems),
                  );
                },
                loading: () => _heroPlaceholder(m),
                error: (_, __) => _heroPlaceholder(m),
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
              // 媒体库
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
      return TvPosterCardData(
        imageUrl: urls.isNotEmpty ? urls.first : null,
        title: _continueTitle(it),
        subtitle: _continueSubtitle(it),
        progress: it.progress,
        onTap: () => context.push('/tv/player?mediaId=${it.id}'),
      );
    }).toList(growable: false);
  }

  List<TvPosterCardData> _libraryCards(ApiClientFactory api, List<Library> libs) {
    return libs.map((lib) {
      final urls = resolveLibraryImageUrls(api, lib, maxWidth: 400);
      return TvPosterCardData(
        imageUrl: urls.isNotEmpty ? urls.first : null,
        title: lib.name,
        onTap: () => context.go('/tv/library'),
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

  // ============ 占位 / 空态 ============

  Widget _heroPlaceholder(TvMetrics m) {
    return Container(
      height: m.heroHeight,
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
