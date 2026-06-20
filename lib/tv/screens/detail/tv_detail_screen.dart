import 'package:flutter/material.dart';
import 'package:flutter_animate/flutter_animate.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../core/api/api_interfaces.dart';
import '../../../core/providers/app_providers.dart';
import '../../../core/providers/media_providers.dart';
import '../../../core/services/preload_service.dart';
import '../../../ui/utils/media_helpers.dart';
import '../../../ui/widgets/common/media_widgets.dart';
import '../../theme/tv_design_tokens.dart';
import '../../theme/tv_metrics.dart';
import '../../widgets/tv_button.dart';
import '../../widgets/tv_focusable.dart';
import '../../widgets/tv_toast.dart';

/// TV 详情页（剧/电影）—— 接入真实数据。
/// Hero 背景 + 标题信息 + 操作按钮 + 季选择 + 集列表。
class TvDetailScreen extends ConsumerStatefulWidget {
  final String? mediaId;

  const TvDetailScreen({super.key, this.mediaId});

  @override
  ConsumerState<TvDetailScreen> createState() => _TvDetailScreenState();
}

class _TvDetailScreenState extends ConsumerState<TvDetailScreen> {
  String? _selectedSeasonId;
  bool? _favoriteOverride; // 本地乐观状态

  @override
  void initState() {
    super.initState();
    _triggerPreload();
  }

  /// 进入详情页即按规范流程预热真实播放流（受「预加载」开关控制，fire-and-forget）。
  /// 剧集根等非可直接播放条目会在服务内部自动 no-op。
  void _triggerPreload() {
    final id = widget.mediaId;
    if (id == null || id.isEmpty) return;
    if (!ref.read(preloadEnabledProvider)) return;
    final ApiClientFactory api;
    try {
      api = ref.read(apiClientProvider);
    } catch (_) {
      return; // 未连接服务器
    }
    PreloadService.instance.preloadItem(
      api: api,
      itemId: id,
      enabled: true,
      preferredMediaSourceId: ref.read(selectedMediaSourceProvider),
      versionRegex: ref.read(preferredVersionRegexProvider),
      strmDirectPlay: ref.read(strmDirectPlayProvider),
    );
  }

  @override
  Widget build(BuildContext context) {
    final m = context.tv;
    final id = widget.mediaId;
    if (id == null || id.isEmpty) {
      return _errorScaffold('无效的媒体 ID', m);
    }
    final itemAsync = ref.watch(mediaItemProvider(id));

    return Scaffold(
      backgroundColor: TvDesignTokens.background,
      body: itemAsync.when(
        data: (item) => _buildContent(item, m),
        loading: () => const Center(
          child: CircularProgressIndicator(color: TvDesignTokens.brand),
        ),
        error: (e, _) => _errorBody('加载详情失败：$e', m),
      ),
    );
  }

  Widget _buildContent(MediaItem item, TvMetrics m) {
    final api = ref.read(apiClientProvider);
    final isSeries = item.type == 'Series';

    return SingleChildScrollView(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _buildHeroArea(api, item, m),
          Padding(
            padding: EdgeInsets.all(m.spacingXl),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                _buildActionButtons(item, m),
                if (item.overview != null && item.overview!.isNotEmpty) ...[
                  SizedBox(height: m.spacingLg),
                  _buildSynopsis(item.overview!, m),
                ],
                if (isSeries) ...[
                  SizedBox(height: m.spacingLg),
                  _buildSeasonsAndEpisodes(api, item, m),
                ],
                SizedBox(height: m.spacingXxl),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildHeroArea(ApiClientFactory api, MediaItem item, TvMetrics m) {
    final banner = resolveMediaItemBannerImageUrls(api, item,
        maxWidth: 1600, allowPosterFallback: true);
    final logo = (item.logoItemId != null && item.logoImageTag != null)
        ? api.image
            .getLogoImageUrl(item.logoItemId!, tag: item.logoImageTag, maxWidth: 320)
        : null;

    return SizedBox(
      height: m.s(420),
      child: Stack(
        fit: StackFit.expand,
        children: [
          if (banner.isNotEmpty)
            MediaImage(
              imageUrl: banner.first,
              imageUrls: banner.length > 1 ? banner.sublist(1) : null,
              width: double.infinity,
              height: double.infinity,
              fit: BoxFit.cover,
            )
          else
            const ColoredBox(color: TvDesignTokens.surfaceElevated),
          Container(
            decoration: BoxDecoration(
              gradient: LinearGradient(
                begin: Alignment.topCenter,
                end: Alignment.bottomCenter,
                colors: [
                  Colors.transparent,
                  TvDesignTokens.background.withValues(alpha: 0.8),
                  TvDesignTokens.background,
                ],
                stops: const [0.4, 0.82, 1.0],
              ),
            ),
          ),
          Positioned(
            left: m.spacingXl,
            right: m.spacingXl,
            bottom: m.spacingLg,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                if (logo != null && logo.isNotEmpty)
                  Image.network(logo,
                      height: m.s(64),
                      fit: BoxFit.contain,
                      alignment: Alignment.centerLeft,
                      errorBuilder: (_, __, ___) => _titleText(item.name, m))
                else
                  _titleText(item.name, m),
                SizedBox(height: m.spacingSm),
                Row(
                  children: [
                    if (item.communityRating != null) ...[
                      Container(
                        padding: EdgeInsets.symmetric(
                            horizontal: m.spacingSm, vertical: m.s(4)),
                        decoration: BoxDecoration(
                          color: TvDesignTokens.brand,
                          borderRadius: BorderRadius.circular(m.s(4)),
                        ),
                        child: Text(
                          '★ ${item.communityRating!.toStringAsFixed(1)}',
                          style: TextStyle(
                            fontSize: m.fontSizeSm,
                            color: Colors.white,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                      ),
                      SizedBox(width: m.spacingMd),
                    ],
                    Expanded(
                      child: Text(
                        _metaLine(item),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontSize: m.fontSizeSm,
                          color: TvDesignTokens.textSecondary,
                        ),
                      ),
                    ),
                  ],
                ),
              ],
            ).animate().fadeIn(duration: TvDesignTokens.contentFadeDuration),
          ),
        ],
      ),
    );
  }

  Widget _titleText(String name, TvMetrics m) => Text(
        name,
        maxLines: 2,
        overflow: TextOverflow.ellipsis,
        style: TextStyle(
          fontSize: m.fontSizeXxl,
          color: TvDesignTokens.textPrimary,
          fontWeight: FontWeight.bold,
        ),
      );

  String _metaLine(MediaItem item) {
    final parts = <String>[];
    if (item.productionYear != null) parts.add('${item.productionYear}');
    final genres = item.genres;
    if (genres != null && genres.isNotEmpty) {
      parts.addAll(genres.take(3));
    }
    return parts.join(' · ');
  }

  Widget _buildActionButtons(MediaItem item, TvMetrics m) {
    final favorited = _favoriteOverride ?? (item.userData?.isFavorite ?? false);
    final resumeTicks = item.userData?.playbackPositionTicks ?? 0;
    final hasResume =
        item.type != 'Series' && !(item.userData?.played ?? false) && resumeTicks > 0;
    return Row(
      children: [
        TvButton(
          text: hasResume ? '继续观看' : '播放',
          icon: Icons.play_arrow,
          autofocus: true,
          onPressed: () => _onPlayMain(item),
        ),
        SizedBox(width: m.spacingMd),
        TvButton(
          text: favorited ? '已收藏' : '收藏',
          icon: favorited ? Icons.favorite : Icons.favorite_border,
          outlined: true,
          onPressed: () => _toggleFavorite(item, favorited),
        ),
      ],
    );
  }

  /// 顶部「播放/继续观看」：影片直接播；剧集挑「进行中 → 首个未看 → 第一集」。
  Future<void> _onPlayMain(MediaItem item) async {
    if (item.type != 'Series') {
      context.push('/tv/player?mediaId=${item.id}');
      return;
    }
    try {
      final api = ref.read(apiClientProvider);
      final seasons = await api.media.getSeasons(item.id);
      final seasonId = seasons.isNotEmpty ? seasons.first.id : null;
      final episodes = await api.media.getEpisodes(item.id, seasonId: seasonId);
      if (episodes.isEmpty) return;
      Episode? target;
      for (final e in episodes) {
        final pos = e.userData?.playbackPositionTicks ?? 0;
        if (!(e.userData?.played ?? false) && pos > 0) {
          target = e;
          break;
        }
      }
      target ??= episodes.firstWhere(
        (e) => !(e.userData?.played ?? false),
        orElse: () => episodes.first,
      );
      if (mounted) context.push('/tv/player?mediaId=${target.id}');
    } catch (_) {
      if (mounted) context.push('/tv/player?mediaId=${item.id}');
    }
  }

  Future<void> _toggleFavorite(MediaItem item, bool current) async {
    setState(() => _favoriteOverride = !current);
    try {
      final api = ref.read(apiClientProvider);
      if (current) {
        await api.favorite.removeFavorite(item.id);
      } else {
        await api.favorite.addFavorite(item.id);
      }
      if (mounted) TvToast.show(context, current ? '已取消收藏' : '已收藏');
    } catch (e) {
      if (mounted) {
        setState(() => _favoriteOverride = current);
        TvToast.show(context, '操作失败');
      }
    }
  }

  Widget _buildSynopsis(String overview, TvMetrics m) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          '简介',
          style: TextStyle(
            fontSize: m.fontSizeLg,
            color: TvDesignTokens.textPrimary,
            fontWeight: FontWeight.bold,
          ),
        ),
        SizedBox(height: m.spacingSm),
        Text(
          overview,
          style: TextStyle(
            fontSize: m.fontSizeSm,
            color: TvDesignTokens.textSecondary,
            height: TvDesignTokens.lineHeightRelaxed,
          ),
        ),
      ],
    );
  }

  Widget _buildSeasonsAndEpisodes(
      ApiClientFactory api, MediaItem series, TvMetrics m) {
    final seasonsAsync = ref.watch(seasonsProvider(series.id));
    return seasonsAsync.when(
      data: (seasons) {
        if (seasons.isEmpty) return const SizedBox.shrink();
        final seasonId = _selectedSeasonId ?? seasons.first.id;
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              '选择季',
              style: TextStyle(
                fontSize: m.fontSizeLg,
                color: TvDesignTokens.textPrimary,
                fontWeight: FontWeight.bold,
              ),
            ),
            SizedBox(height: m.spacingSm),
            SizedBox(
              height: m.s(150) * 1.5 + m.s(48),
              child: ListView.separated(
                scrollDirection: Axis.horizontal,
                itemCount: seasons.length,
                separatorBuilder: (_, __) => SizedBox(width: m.spacingMd),
                itemBuilder: (context, index) {
                  final season = seasons[index];
                  final selected = season.id == seasonId;
                  return TvFocusable(
                    onSelect: () =>
                        setState(() => _selectedSeasonId = season.id),
                    child: _buildSeasonCard(api, season, selected, m),
                  );
                },
              ),
            ),
            SizedBox(height: m.spacingLg),
            _buildEpisodeList(api, series.id, seasonId, m),
          ],
        );
      },
      loading: () => Padding(
        padding: EdgeInsets.all(m.spacingLg),
        child: const CircularProgressIndicator(color: TvDesignTokens.brand),
      ),
      error: (_, __) => const SizedBox.shrink(),
    );
  }

  /// 季封面卡片（竖向 2:3 海报 + 季名「第N季」）。
  Widget _buildSeasonCard(
      ApiClientFactory api, Season season, bool selected, TvMetrics m) {
    final double w = m.s(150);
    final double h = w * 1.5;
    final poster = _seasonImageUrl(api, season);
    return SizedBox(
      width: w,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          Container(
            width: w,
            height: h,
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(m.posterRadius),
              border: selected
                  ? Border.all(color: TvDesignTokens.brand, width: m.s(3))
                  : null,
            ),
            clipBehavior: Clip.antiAlias,
            child: poster != null
                ? MediaImage(
                    imageUrl: poster, width: w, height: h, fit: BoxFit.cover)
                : const ColoredBox(
                    color: TvDesignTokens.surfaceElevated,
                    child: Icon(Icons.video_library_outlined,
                        color: TvDesignTokens.textDisabled),
                  ),
          ),
          SizedBox(height: m.spacingXs),
          Text(
            season.name,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            textAlign: TextAlign.center,
            style: TextStyle(
              fontSize: m.fontSizeSm,
              color:
                  selected ? TvDesignTokens.brand : TvDesignTokens.textPrimary,
              fontWeight: selected ? FontWeight.bold : FontWeight.w500,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildEpisodeList(
      ApiClientFactory api, String seriesId, String seasonId, TvMetrics m) {
    final episodesAsync =
        ref.watch(episodesProvider((seriesId: seriesId, seasonId: seasonId)));
    return episodesAsync.when(
      data: (episodes) {
        if (episodes.isEmpty) return const SizedBox.shrink();
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              '共 ${episodes.length} 集',
              style: TextStyle(
                fontSize: m.fontSizeLg,
                color: TvDesignTokens.textPrimary,
                fontWeight: FontWeight.bold,
              ),
            ),
            SizedBox(height: m.spacingMd),
            // 竖向剧集卡片网格（封面 + 第N集 + 集名），便于遥控器上下左右选集。
            Wrap(
              spacing: m.spacingMd,
              runSpacing: m.spacingLg,
              children: [
                for (final entry in episodes.asMap().entries)
                  TvFocusable(
                    onSelect: () =>
                        context.push('/tv/player?mediaId=${entry.value.id}'),
                    child: _buildEpisodeCard(api, entry.value, m),
                  ).animate().fadeIn(
                        delay: Duration(milliseconds: 20 * (entry.key % 12)),
                        duration: TvDesignTokens.contentFadeDuration,
                      ),
              ],
            ),
          ],
        );
      },
      loading: () => Padding(
        padding: EdgeInsets.all(m.spacingLg),
        child: const CircularProgressIndicator(color: TvDesignTokens.brand),
      ),
      error: (_, __) => const SizedBox.shrink(),
    );
  }

  /// 竖向剧集卡片：16:9 封面（集数角标 + 已看标记 + 进度）+ 第N集 + 集名。
  Widget _buildEpisodeCard(ApiClientFactory api, Episode ep, TvMetrics m) {
    final double w = m.s(260);
    final double coverH = w * 9 / 16;
    final thumbUrl = _episodeImageUrl(api, ep);
    final watched = ep.userData?.played ?? false;
    final progress = _episodeProgress(ep);
    return SizedBox(
      width: w,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          ClipRRect(
            borderRadius: BorderRadius.circular(m.posterRadius),
            child: SizedBox(
              width: w,
              height: coverH,
              child: Stack(
                fit: StackFit.expand,
                children: [
                  thumbUrl != null
                      ? MediaImage(
                          imageUrl: thumbUrl,
                          width: w,
                          height: coverH,
                          fit: BoxFit.cover,
                        )
                      : const ColoredBox(
                          color: TvDesignTokens.surfaceElevated,
                          child: Icon(Icons.movie_outlined,
                              color: TvDesignTokens.textDisabled),
                        ),
                  // 集数角标
                  if (ep.indexNumber != null)
                    Positioned(
                      top: m.spacingXs,
                      left: m.spacingXs,
                      child: Container(
                        padding: EdgeInsets.symmetric(
                            horizontal: m.s(8), vertical: m.s(2)),
                        decoration: BoxDecoration(
                          color: Colors.black.withOpacity(0.6),
                          borderRadius: BorderRadius.circular(m.s(4)),
                        ),
                        child: Text(
                          'E${ep.indexNumber}',
                          style: TextStyle(
                            fontSize: m.fs(12),
                            color: Colors.white,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                      ),
                    ),
                  if (watched)
                    Positioned(
                      top: m.spacingXs,
                      right: m.spacingXs,
                      child: Icon(Icons.check_circle,
                          color: TvDesignTokens.success, size: m.s(22)),
                    ),
                  if (progress > 0)
                    Positioned(
                      left: 0,
                      right: 0,
                      bottom: 0,
                      child: LinearProgressIndicator(
                        value: progress,
                        minHeight: m.s(4),
                        backgroundColor: Colors.black54,
                        valueColor: const AlwaysStoppedAnimation(
                            TvDesignTokens.brand),
                      ),
                    ),
                ],
              ),
            ),
          ),
          SizedBox(height: m.spacingXs),
          Text(
            '第 ${ep.indexNumber ?? '?'} 集',
            style: TextStyle(
              fontSize: m.fontSizeXs,
              color: TvDesignTokens.textSecondary,
            ),
          ),
          Text(
            ep.name,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              fontSize: m.fontSizeSm,
              color: TvDesignTokens.textPrimary,
              fontWeight: FontWeight.w500,
            ),
          ),
        ],
      ),
    );
  }

  String? _seasonImageUrl(ApiClientFactory api, Season s) {
    if (s.primaryImageTag != null) {
      return api.image
          .getPrimaryImageUrl(s.id, tag: s.primaryImageTag, maxWidth: 400);
    }
    if (s.thumbImageTag != null) {
      return api.image
          .getThumbImageUrl(s.id, tag: s.thumbImageTag, maxWidth: 400);
    }
    if (s.seriesId.isNotEmpty && s.seriesPrimaryImageTag != null) {
      return api.image.getPrimaryImageUrl(s.seriesId,
          tag: s.seriesPrimaryImageTag, maxWidth: 400);
    }
    return null;
  }

  double _episodeProgress(Episode ep) {
    if (ep.userData?.played ?? false) return 0;
    final pos = ep.userData?.playbackPositionTicks ?? 0;
    final total = ep.runTimeTicks ?? 0;
    if (total <= 0 || pos <= 0) return 0;
    final p = pos / total;
    return p > 0.98 ? 0 : p.clamp(0.0, 1.0).toDouble();
  }

  String? _episodeImageUrl(ApiClientFactory api, Episode ep) {
    if (ep.primaryImageTag != null) {
      return api.image
          .getPrimaryImageUrl(ep.id, tag: ep.primaryImageTag, maxWidth: 400);
    }
    if (ep.thumbImageTag != null) {
      return api.image
          .getThumbImageUrl(ep.id, tag: ep.thumbImageTag, maxWidth: 400);
    }
    return null;
  }

  Widget _errorScaffold(String msg, TvMetrics m) => Scaffold(
        backgroundColor: TvDesignTokens.background,
        body: _errorBody(msg, m),
      );

  Widget _errorBody(String msg, TvMetrics m) => Center(
        child: Text(
          msg,
          style: TextStyle(
            color: TvDesignTokens.textSecondary,
            fontSize: m.fontSizeMd,
          ),
        ),
      );
}
