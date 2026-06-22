import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import '../../../core/api/api_interfaces.dart';
import '../../../core/providers/app_providers.dart';
import '../../../core/providers/media_providers.dart';
import '../../../core/services/cast_service.dart';
import '../../../core/utils/color_extractor.dart';
import '../../../core/utils/platform_utils.dart';
import '../../../core/widgets/app_shimmer.dart';
import '../../../core/providers/download_providers.dart';
import '../../../core/services/download/download_helper.dart';
import '../../utils/media_helpers.dart';
import '../../widgets/common/dynamic_background.dart';
import '../../widgets/common/media_widgets.dart';
import '../../widgets/common/playback_options.dart';
import '../../widgets/common/video_background.dart';

/// 媒体详情页（剧/电影通用）
class MediaDetailScreen extends ConsumerWidget {
  final String itemId;

  const MediaDetailScreen({super.key, required this.itemId});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final itemAsync = ref.watch(mediaItemProvider(itemId));

    return Scaffold(
      body: itemAsync.when(
        data: (item) => _DetailContent(item: item, itemId: itemId),
        loading: () => const AppLoadingIndicator(),
        error: (error, stackTrace) => _ErrorView(
          error: error,
          onRetry: () => ref.invalidate(mediaItemProvider(itemId)),
        ),
      ),
    );
  }
}

class _DetailContent extends StatefulWidget {
  final MediaItem item;
  final String itemId;

  const _DetailContent({required this.item, required this.itemId});

  @override
  State<_DetailContent> createState() => _DetailContentState();
}

class _DetailContentState extends State<_DetailContent> {
  Color _backgroundColor = const Color(0xFF121212);

  void _onColorChanged(Color color) {
    if (_backgroundColor != color) {
      setState(() {
        _backgroundColor = color;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final foregroundColor = readableTextColorForBackground(_backgroundColor);
    return Scaffold(
      backgroundColor: _backgroundColor,
      body: DynamicBackground(
        backgroundColor: _backgroundColor,
        child: CustomScrollView(
        slivers: [
          // 封面区域
          SliverToBoxAdapter(
            child: _DetailHeader(
              item: widget.item,
              onColorChanged: _onColorChanged,
            ),
          ),

          // 简介
          if (widget.item.overview != null && widget.item.overview!.isNotEmpty)
            SliverToBoxAdapter(
              child: _OverviewSection(
                overview: widget.item.overview!,
                textColor: foregroundColor,
              ),
            ),

          // 剧集相关区块（季 + 集；集数走懒加载 Sliver，几百集也只构建可视项）
          if (widget.item.type == 'Series') ...[
            _SeasonsSliver(
              itemId: widget.itemId,
              onSeasonTap: (season) => context.push('/season/${season.id}', extra: _backgroundColor),
            ),
            _EpisodesSliver(
              itemId: widget.itemId,
              onEpisodeTap: (episode) => context.push('/episode/${episode.id}'),
            ),
          ],

          // 电影播放选项 + 按钮
          if (widget.item.type == 'Movie') ...[
            SliverToBoxAdapter(
              child: _MoviePlaybackSection(itemId: widget.itemId),
            ),
          ],

          const SliverPadding(padding: EdgeInsets.only(bottom: 32)),
        ],
        ),
      ),
    );
  }
}

/// 季列表 Sliver（横向卡片，数量少，整体一个 box adapter）。
class _SeasonsSliver extends ConsumerWidget {
  final String itemId;
  final Function(Season) onSeasonTap;

  const _SeasonsSliver({
    required this.itemId,
    required this.onSeasonTap,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final seasonsAsync = ref.watch(seasonsProvider(itemId));
    // 季横向列表项不多，整体放进一个 box adapter 即可。
    return SliverToBoxAdapter(
      child: _SeasonsSection(
        seasonsAsync: seasonsAsync,
        onSeasonTap: onSeasonTap,
      ),
    );
  }
}

class _ErrorView extends StatelessWidget {
  final Object error;
  final VoidCallback onRetry;

  const _ErrorView({required this.error, required this.onRetry});

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(
              Icons.error_outline,
              size: 48,
              color: Theme.of(context).colorScheme.error,
            ),
            const SizedBox(height: 16),
            Text(
              '加载详情失败',
              style: TextStyle(
                fontSize: 18,
                fontWeight: FontWeight.w600,
                color: Theme.of(context).colorScheme.error,
              ),
            ),
            const SizedBox(height: 8),
            Text(
              error.toString().replaceAll('Exception: ', '').replaceAll('DioException ', ''),
              textAlign: TextAlign.center,
              style: TextStyle(
                fontSize: 13,
                color: Theme.of(context).textTheme.bodySmall?.color,
              ),
            ),
            const SizedBox(height: 24),
            FilledButton.icon(
              onPressed: onRetry,
              icon: const Icon(Icons.refresh),
              label: const Text('重试'),
            ),
          ],
        ),
      ),
    );
  }
}

/// 详情页头部
class _DetailHeader extends ConsumerStatefulWidget {
  final MediaItem item;
  final ValueChanged<Color>? onColorChanged;

  const _DetailHeader({required this.item, this.onColorChanged});

  @override
  ConsumerState<_DetailHeader> createState() => _DetailHeaderState();
}

class _DetailHeaderState extends ConsumerState<_DetailHeader> {
  Color _dominantColor = Colors.black;
  Color _backgroundColor = const Color(0xFF121212);
  bool _isDownloadingSeries = false;
  bool _isFavorite = false;
  bool _favoriteBusy = false;

  @override
  void initState() {
    super.initState();
    _isFavorite = widget.item.userData?.isFavorite ?? false;
    _extractColor();
  }

  @override
  void didUpdateWidget(covariant _DetailHeader oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.item.id != widget.item.id) {
      _isFavorite = widget.item.userData?.isFavorite ?? false;
      _extractColor();
    }
  }

  /// 收藏 / 取消收藏当前条目。
  Future<void> _toggleFavorite() async {
    if (_favoriteBusy) return;
    final api = ref.read(apiClientProvider);
    final messenger = ScaffoldMessenger.of(context);
    final next = !_isFavorite;
    setState(() => _favoriteBusy = true);
    try {
      if (next) {
        await api.favorite.addFavorite(widget.item.id);
      } else {
        await api.favorite.removeFavorite(widget.item.id);
      }
      if (mounted) setState(() => _isFavorite = next);
      messenger.showSnackBar(
        SnackBar(
          content: Text(next ? '已加入收藏' : '已取消收藏'),
          duration: const Duration(seconds: 1),
        ),
      );
    } catch (_) {
      messenger.showSnackBar(
        const SnackBar(content: Text('操作失败，请稍后重试')),
      );
    } finally {
      if (mounted) setState(() => _favoriteBusy = false);
    }
  }

  Future<void> _extractColor() async {
    final api = ref.read(apiClientProvider);
    final imageUrls = resolveMediaItemLandscapeImageUrls(
      api,
      widget.item,
      maxWidth: 640,
    );
    final imageUrl = imageUrls.isNotEmpty ? imageUrls.first : null;

    if (imageUrl == null) return;

    // 跟随用户主题明暗取色：浅色模式取浅色系背景，深色模式取深色系。
    final brightness = Theme.of(context).brightness;
    final colors =
        await ColorExtractor.extractFromUrl(imageUrl, brightness: brightness);
    if (mounted) {
      setState(() {
        _dominantColor = colors.gradientStart;
        _backgroundColor = colors.background;
      });
      widget.onColorChanged?.call(colors.background);
    }
  }

  /// 整剧下载：一键把全剧所有分集加入下载队列。
  Future<void> _downloadWholeSeries() async {
    final api = ref.read(apiClientProvider);
    final messenger = ScaffoldMessenger.of(context);

    final allowedByPolicy = await ref.read(downloadPermissionProvider.future);
    if (!allowedByPolicy) {
      messenger.showSnackBar(
        const SnackBar(content: Text('当前服务器未开放下载权限')),
      );
      return;
    }

    setState(() => _isDownloadingSeries = true);
    messenger.showSnackBar(
      const SnackBar(content: Text('正在解析剧集，准备下载…')),
    );
    try {
      final result = await startSeriesDownload(
        api: api,
        manager: ref.read(downloadManagerProvider),
        series: widget.item,
      );
      messenger.showSnackBar(
        SnackBar(
          content: Text(result.queued > 0
              ? '已加入下载 ${result.queued} 集'
                  '${result.skipped > 0 ? '（${result.skipped} 集已存在）' : ''}'
              : '全部 ${result.total} 集已在下载列表'),
        ),
      );
    } catch (e) {
      messenger.showSnackBar(
        const SnackBar(content: Text('整剧下载失败，请稍后重试')),
      );
    } finally {
      if (mounted) setState(() => _isDownloadingSeries = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final screenWidth = MediaQuery.of(context).size.width;
    final isMovie = widget.item.type == 'Movie';
    final api = ref.read(apiClientProvider);
    final useVideoBackground = ref.watch(useVideoBackgroundProvider);
    final imageUrls = resolveMediaItemLandscapeImageUrls(
      api,
      widget.item,
      maxWidth: isDesktopPlatform ? 1600 : 960,
    );
    final hasLandscapeImage = imageUrls.isNotEmpty;
    final headerHeight = isDesktopPlatform
        ? (isMovie ? 400.0 : 420.0)
        : (hasLandscapeImage
            ? screenWidth * 0.6
            : (isMovie ? screenWidth * 0.85 : screenWidth * 0.75));
    final videoUrl = (useVideoBackground && widget.item.remoteTrailers != null && widget.item.remoteTrailers!.isNotEmpty)
        ? widget.item.remoteTrailers!.first
        : null;

    // 标题/元信息坐落在「渐变→海报主色」的底部，前景色按主色亮度自适配：
    // 深底用浅字、浅底用深字；阴影取反色保证两种模式下都清晰。
    final fg = readableTextColorForBackground(_backgroundColor);
    final shadowColor = fg.computeLuminance() > 0.5
        ? Colors.black.withValues(alpha: 0.5)
        : Colors.white.withValues(alpha: 0.5);

    return Stack(
      children: [
        Container(
          height: headerHeight,
          width: double.infinity,
          color: _dominantColor,
          child: videoUrl != null
              ? VideoBackground(
                  videoUrl: videoUrl,
                  width: double.infinity,
                  height: headerHeight,
                  fit: BoxFit.cover,
                  placeholder: imageUrls.isNotEmpty
                      ? MediaImage(
                          imageUrl: imageUrls.first,
                          imageUrls: imageUrls.length > 1 ? imageUrls.sublist(1) : null,
                          width: double.infinity,
                          height: headerHeight,
                          fit: BoxFit.cover,
                        )
                      : null,
                )
              : MediaImage(
                  imageUrl: imageUrls.isNotEmpty ? imageUrls.first : null,
                  imageUrls: imageUrls.length > 1 ? imageUrls.sublist(1) : null,
                  width: double.infinity,
                  height: headerHeight,
                  fit: BoxFit.cover,
                ),
        ),

        // 底部渐变
        Positioned(
          bottom: 0,
          left: 0,
          right: 0,
          child: Container(
            height: 150,
            decoration: BoxDecoration(
              gradient: LinearGradient(
                begin: Alignment.topCenter,
                end: Alignment.bottomCenter,
                colors: [
                  Colors.transparent,
                  _backgroundColor.withValues(alpha: 0.9),
                  _backgroundColor,
                ],
              ),
            ),
          ),
        ),

        // 返回按钮
        SafeArea(
          child: Padding(
            padding: const EdgeInsets.all(8),
            child: CircleAvatar(
              backgroundColor: Colors.black.withValues(alpha: 0.4),
              child: IconButton(
                icon: const Icon(Icons.arrow_back, color: Colors.white),
                onPressed: () => context.pop(),
              ),
            ),
          ),
        ),

        // 右上角操作：收藏（通用）+ 下载整部剧（仅剧集）
        SafeArea(
          child: Align(
            alignment: Alignment.topRight,
            child: Padding(
              padding: const EdgeInsets.all(8),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  CircleAvatar(
                    backgroundColor: Colors.black.withValues(alpha: 0.4),
                    child: IconButton(
                      tooltip: _isFavorite ? '取消收藏' : '添加收藏',
                      icon: _favoriteBusy
                          ? const SizedBox(
                              width: 20,
                              height: 20,
                              child: CircularProgressIndicator(
                                  strokeWidth: 2, color: Colors.white),
                            )
                          : Icon(
                              _isFavorite
                                  ? Icons.favorite
                                  : Icons.favorite_border,
                              color: _isFavorite
                                  ? const Color(0xFFFF6B6B)
                                  : Colors.white,
                            ),
                      onPressed: _favoriteBusy ? null : _toggleFavorite,
                    ),
                  ),
                  if (widget.item.type == 'Series') ...[
                    const SizedBox(width: 8),
                    CircleAvatar(
                      backgroundColor: Colors.black.withValues(alpha: 0.4),
                      child: IconButton(
                        tooltip: '下载整部剧',
                        icon: _isDownloadingSeries
                            ? const SizedBox(
                                width: 20,
                                height: 20,
                                child: CircularProgressIndicator(
                                    strokeWidth: 2, color: Colors.white),
                              )
                            : const Icon(Icons.download, color: Colors.white),
                        onPressed:
                            _isDownloadingSeries ? null : _downloadWholeSeries,
                      ),
                    ),
                  ],
                ],
              ),
            ),
          ),
        ),

        // 标题信息
        Positioned(
          bottom: 16,
          left: 16,
          right: 16,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                widget.item.name,
                style: TextStyle(
                  fontSize: 26,
                  fontWeight: FontWeight.w800,
                  color: fg,
                  shadows: [
                    Shadow(blurRadius: 8, color: shadowColor),
                  ],
                ),
              ),
              const SizedBox(height: 8),
              Row(
                children: [
                  if (widget.item.communityRating != null) ...[
                    const Icon(Icons.star, size: 16, color: Colors.amber),
                    const SizedBox(width: 4),
                    Text(
                      widget.item.communityRating!.toStringAsFixed(1),
                      style: TextStyle(
                        fontSize: 14,
                        fontWeight: FontWeight.w600,
                        color: fg,
                        shadows: [Shadow(blurRadius: 4, color: shadowColor)],
                      ),
                    ),
                    const SizedBox(width: 12),
                  ],
                  ...?widget.item.genres?.take(5).map((genre) => Padding(
                    padding: const EdgeInsets.only(right: 6),
                    child: Container(
                      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                      decoration: BoxDecoration(
                        color: fg.withValues(alpha: 0.18),
                        borderRadius: BorderRadius.circular(4),
                      ),
                      child: Text(
                        genre,
                        style: TextStyle(fontSize: 11, color: fg),
                      ),
                    ),
                  )),
                ],
              ),
              if (isMovie && widget.item.productionYear != null) ...[
                const SizedBox(height: 8),
                Wrap(
                  spacing: 12,
                  crossAxisAlignment: WrapCrossAlignment.center,
                  children: [
                    Text(
                      '${widget.item.productionYear}',
                      style: TextStyle(
                        fontSize: 14,
                        color: fg,
                        shadows: [Shadow(blurRadius: 4, color: shadowColor)],
                      ),
                    ),
                    if ((widget.item.formattedRuntime ?? '').isNotEmpty)
                      Text(
                        widget.item.formattedRuntime!,
                        style: TextStyle(
                          fontSize: 14,
                          color: fg,
                          shadows: [Shadow(blurRadius: 4, color: shadowColor)],
                        ),
                      ),
                  ],
                ),
              ],
            ],
          ),
        ),
      ],
    );
  }
}

/// 简介区块
class _OverviewSection extends StatefulWidget {
  final String overview;
  final Color? textColor;
  
  const _OverviewSection({
    required this.overview,
    this.textColor,
  });
  
  @override
  State<_OverviewSection> createState() => _OverviewSectionState();
}

class _OverviewSectionState extends State<_OverviewSection> {
  bool _expanded = false;
  
  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            widget.overview,
            maxLines: _expanded ? null : 3,
            overflow: _expanded ? TextOverflow.visible : TextOverflow.ellipsis,
            style: TextStyle(
              fontSize: 14,
              height: 1.5,
              color: widget.textColor ?? Theme.of(context).textTheme.bodyMedium?.color,
            ),
          ),
          if (widget.overview.length > 100)
            GestureDetector(
              onTap: () => setState(() => _expanded = !_expanded),
              child: Padding(
                padding: const EdgeInsets.only(top: 4),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      _expanded ? '收起' : '展开',
                      style: TextStyle(
                        fontSize: 13,
                        color: Theme.of(context).colorScheme.primary,
                        fontWeight: FontWeight.w500,
                      ),
                    ),
                    Icon(
                      _expanded ? Icons.keyboard_arrow_up : Icons.keyboard_arrow_down,
                      size: 18,
                      color: Theme.of(context).colorScheme.primary,
                    ),
                  ],
                ),
              ),
            ),
        ],
      ),
    );
  }
}

/// 季选择区块
class _SeasonsSection extends ConsumerWidget {
  final AsyncValue<List<Season>> seasonsAsync;
  final Function(Season) onSeasonTap;
  
  const _SeasonsSection({
    required this.seasonsAsync,
    required this.onSeasonTap,
  });
  
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return seasonsAsync.when(
      data: (seasons) {
        if (seasons.isEmpty) return const SizedBox.shrink();
        
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const SectionHeader(title: '季度选择'),
            HorizontalList(
              height: 182,
              children: seasons.map((season) {
                return SizedBox(
                  width: 196,
                  child: InkWell(
                    onTap: () => onSeasonTap(season),
                    borderRadius: BorderRadius.circular(8),
                    child: Column(
                      children: [
                        Expanded(
                          child: _SeasonCard(season: season),
                        ),
                        const SizedBox(height: 6),
                        Text(
                          season.name,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(fontSize: 13),
                        ),
                      ],
                    ),
                  ),
                );
              }).toList(),
            ),
          ],
        );
      },
      loading: () => const SizedBox.shrink(),
      error: (_, __) => const SizedBox.shrink(),
    );
  }
}

class _SeasonCard extends ConsumerWidget {
  final Season season;

  const _SeasonCard({required this.season});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final api = ref.read(apiClientProvider);
    final imageUrls = resolveSeasonImageUrls(api, season, maxWidth: 480);

    if (imageUrls.isNotEmpty) {
      return AspectRatio(
        aspectRatio: 2 / 3,
        child: ClipRRect(
          borderRadius: BorderRadius.circular(8),
          child: MediaImage(
            imageUrl: imageUrls.first,
            imageUrls: imageUrls.length > 1 ? imageUrls.sublist(1) : null,
            width: 196,
            height: 294,
            fit: BoxFit.cover,
            borderRadius: BorderRadius.circular(8),
          ),
        ),
      );
    }

    return AspectRatio(
      aspectRatio: 2 / 3,
      child: Container(
        decoration: BoxDecoration(
          color: const Color(0xFF5B8DEF).withValues(alpha: 0.1),
          borderRadius: BorderRadius.circular(8),
        ),
        child: Center(
          child: Text(
            'S${season.indexNumber}',
            style: const TextStyle(
              fontSize: 24,
              fontWeight: FontWeight.bold,
              color: Color(0xFF5B8DEF),
            ),
          ),
        ),
      ),
    );
  }
}

/// 集数选择区块（懒加载 Sliver）。
///
/// 之前用 Wrap / `...episodes.map()` 一次性把整季所有集都构建进内存，几百集的番剧
/// 会瞬间堆出几百个 widget + 缩略图。改为 SliverList/SliverGrid.builder，只构建
/// 视口内可见的集，离屏自动回收——内存与集数解耦。
class _EpisodesSliver extends ConsumerStatefulWidget {
  final String itemId;
  final Function(Episode) onEpisodeTap;

  const _EpisodesSliver({
    required this.itemId,
    required this.onEpisodeTap,
  });

  @override
  ConsumerState<_EpisodesSliver> createState() => _EpisodesSliverState();
}

class _EpisodesSliverState extends ConsumerState<_EpisodesSliver> {
  bool _isGridView = false;

  @override
  Widget build(BuildContext context) {
    final episodesAsync =
        ref.watch(episodesProvider((seriesId: widget.itemId, seasonId: null)));
    return episodesAsync.when(
      data: (episodes) {
        if (episodes.isEmpty) {
          return const SliverToBoxAdapter(child: SizedBox.shrink());
        }
        return SliverMainAxisGroup(
          slivers: [
            SliverToBoxAdapter(child: _header()),
            if (_isGridView)
              SliverPadding(
                padding: const EdgeInsets.symmetric(horizontal: 16),
                sliver: SliverGrid.builder(
                  gridDelegate:
                      const SliverGridDelegateWithMaxCrossAxisExtent(
                    maxCrossAxisExtent: 68,
                    mainAxisExtent: 60,
                    crossAxisSpacing: 8,
                    mainAxisSpacing: 8,
                  ),
                  itemCount: episodes.length,
                  itemBuilder: (_, i) => _gridCell(episodes[i]),
                ),
              )
            else
              SliverList.builder(
                itemCount: episodes.length,
                itemBuilder: (_, i) => _EpisodeListTile(
                  episode: episodes[i],
                  onTap: () => widget.onEpisodeTap(episodes[i]),
                ),
              ),
          ],
        );
      },
      loading: () => const SliverToBoxAdapter(child: SizedBox.shrink()),
      error: (_, __) => const SliverToBoxAdapter(child: SizedBox.shrink()),
    );
  }

  Widget _header() {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          const Text(
            '集数选择',
            style: TextStyle(fontSize: 18, fontWeight: FontWeight.w700),
          ),
          IconButton(
            icon: Icon(_isGridView ? Icons.view_list : Icons.grid_view),
            onPressed: () => setState(() => _isGridView = !_isGridView),
          ),
        ],
      ),
    );
  }

  Widget _gridCell(Episode episode) {
    final isWatched = episode.userData?.played ?? false;
    return GestureDetector(
      onTap: () => widget.onEpisodeTap(episode),
      child: Container(
        decoration: BoxDecoration(
          color: isWatched
              ? const Color(0xFF5B8DEF).withValues(alpha: 0.1)
              : Theme.of(context).colorScheme.surfaceContainerHighest,
          borderRadius: BorderRadius.circular(8),
        ),
        child: Center(
          child: isWatched
              ? const Icon(Icons.check, color: Color(0xFF5B8DEF))
              : Text(
                  'E${episode.indexNumber}',
                  style: const TextStyle(fontWeight: FontWeight.w600),
                ),
        ),
      ),
    );
  }
}

class _EpisodeListTile extends ConsumerWidget {
  final Episode episode;
  final VoidCallback onTap;
  
  const _EpisodeListTile({required this.episode, required this.onTap});
  
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final isWatched = episode.userData?.played ?? false;
    final api = ref.read(apiClientProvider);
    final imageUrls = resolveEpisodeLandscapeImageUrls(
      api,
      episode,
      maxWidth: 480,
    );
    
    return ListTile(
      onTap: onTap,
      leading: Container(
        width: 100,
        height: 60,
        decoration: BoxDecoration(
          color: Theme.of(context).colorScheme.surfaceContainerHighest,
          borderRadius: BorderRadius.circular(6),
        ),
        clipBehavior: Clip.antiAlias,
        child: imageUrls.isNotEmpty
            ? MediaImage(
                imageUrl: imageUrls.first,
                imageUrls: imageUrls.length > 1 ? imageUrls.sublist(1) : null,
                width: 100,
                height: 60,
                fit: BoxFit.cover,
              )
            : const Center(child: Icon(Icons.play_arrow)),
      ),
      title: Row(
        children: [
          if (isWatched)
            const Padding(
              padding: EdgeInsets.only(right: 6),
              child: Icon(Icons.check_circle, size: 16, color: Color(0xFF5B8DEF)),
            ),
          Expanded(
            child: Text(
              'E${episode.indexNumber} ${episode.name}',
              style: TextStyle(color: Theme.of(context).textTheme.bodyLarge?.color ?? Colors.white),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ),
        ],
      ),
      subtitle: Text(
        episode.formattedRuntime ?? '',
        style: TextStyle(fontSize: 12, color: Theme.of(context).textTheme.bodySmall?.color),
      ),
    );
  }
}

/// 电影播放区块（选项 + 按钮 + 版本信息）
class _MoviePlaybackSection extends ConsumerWidget {
  final String itemId;

  const _MoviePlaybackSection({required this.itemId});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final playbackAsync = ref.watch(playbackInfoProvider(itemId));

    return playbackAsync.when(
      data: (info) => Column(
        children: [
          PlaybackOptions(
            key: ValueKey('movie_playback_$itemId'),
            itemId: itemId,
            info: info,
          ),
          _WatchedProgressLabel(itemId: itemId),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
            child: _MoviePlayButtons(itemId: itemId),
          ),
          _VersionInfoSection(itemId: itemId),
        ],
      ),
      loading: () => const Padding(
        padding: EdgeInsets.all(16),
        child: AppLoadingIndicator(),
      ),
      error: (_, __) => const SizedBox.shrink(),
    );
  }
}

/// 播放键上方的「已观看 XX:XX」进度提示（无进度时不显示）。
class _WatchedProgressLabel extends ConsumerWidget {
  final String itemId;

  const _WatchedProgressLabel({required this.itemId});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final label = ref.watch(mediaItemProvider(itemId)).maybeWhen(
          data: (item) =>
              formatWatchedProgressLabel(item.userData?.playbackPositionTicks),
          orElse: () => null,
        );
    if (label == null) return const SizedBox.shrink();
    final color = Theme.of(context).textTheme.bodySmall?.color;
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 10, 16, 0),
      child: Row(
        children: [
          Icon(Icons.history, size: 15, color: color),
          const SizedBox(width: 6),
          Text(
            label,
            style: TextStyle(fontSize: 12.5, color: color),
          ),
        ],
      ),
    );
  }
}

/// 电影播放按钮
class _MoviePlayButtons extends ConsumerWidget {
  final String itemId;

  const _MoviePlayButtons({required this.itemId});
  
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final mediaSourceId = ref.watch(selectedMediaSourceProvider);
    final canDownload = ref.watch(mediaItemProvider(itemId)).maybeWhen(
          data: (item) => item.canDownload ?? false,
          orElse: () => false,
        );
    return Row(
      children: [
        Expanded(
          flex: 5,
          child: FilledButton.icon(
            onPressed: () => context.push(
              mediaSourceId != null && mediaSourceId.isNotEmpty
                  ? '/player/$itemId?mediaSourceId=$mediaSourceId'
                  : '/player/$itemId',
            ),
            icon: const Icon(Icons.play_arrow),
            label: const Text('播放'),
            style: FilledButton.styleFrom(
              padding: const EdgeInsets.symmetric(vertical: 14),
            ),
          ),
        ),
        const SizedBox(width: 8),
        Expanded(
          flex: 1,
          child: OutlinedButton(
            onPressed: () => _showMoreMenu(context, ref, canDownload: canDownload),
            child: const Icon(Icons.more_vert),
          ),
        ),
      ],
    );
  }
  
  void _showMoreMenu(BuildContext context, WidgetRef ref, {required bool canDownload}) {
    final api = ref.read(apiClientProvider);
    showModalBottomSheet(
      context: context,
      builder: (context) => DefaultTextStyle.merge(
        style: TextStyle(color: Theme.of(context).textTheme.bodyLarge?.color),
        child: SafeArea(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
            ListTile(
              leading: const Icon(Icons.cast),
              title: const Text('投屏'),
              subtitle: const Text('搜索局域网设备', style: TextStyle(fontSize: 12)),
              onTap: () {
                Navigator.pop(context);
                _showCastDialog(context, ref);
              },
            ),
            ListTile(
              leading: const Icon(Icons.search),
              title: const Text('搜索其他播放源'),
              onTap: () {
                Navigator.pop(context);
                context.push('/search');
              },
            ),
            ListTile(
              leading: const Icon(Icons.download),
              title: const Text('下载'),
              enabled: canDownload,
              onTap: () {
                Navigator.pop(context);
                if (canDownload) {
                  _addToDownload(context, ref);
                }
              },
            ),
            ListTile(
              leading: const Icon(Icons.visibility),
              title: const Text('标记为已/未观看'),
              onTap: () async {
                Navigator.pop(context);
                try {
                  final item = await api.media.getItemDetails(itemId);
                  final isWatched = item.userData?.played ?? false;
                  if (isWatched) {
                    await api.playback.reportPlaybackStopped(PlaybackStopInfo(
                      itemId: itemId,
                      mediaSourceId: '',
                      positionTicks: 0,
                    ));
                  } else {
                    await api.playback.reportPlaybackStart(PlaybackStartInfo(
                      itemId: itemId,
                      mediaSourceId: '',
                    ));
                    await api.playback.reportPlaybackStopped(PlaybackStopInfo(
                      itemId: itemId,
                      mediaSourceId: '',
                      positionTicks: item.runTimeTicks ?? 0,
                    ));
                  }
                  ref.invalidate(mediaItemProvider(itemId));
                } catch (_) {}
              },
            ),
            ListTile(
              leading: const Icon(Icons.favorite),
              title: const Text('添加到喜欢'),
              onTap: () async {
                Navigator.pop(context);
                try {
                  final item = await api.media.getItemDetails(itemId);
                  final isFav = item.userData?.isFavorite ?? false;
                  if (isFav) {
                    await api.favorite.removeFavorite(itemId);
                  } else {
                    await api.favorite.addFavorite(itemId);
                  }
                  refreshFavorites(ref);
                  ref.invalidate(mediaItemProvider(itemId));
                } catch (_) {}
              },
            ),
          ],
        ),
      ),
      ),
    );
  }

  void _addToDownload(BuildContext context, WidgetRef ref) async {
    final api = ref.read(apiClientProvider);
    final item = await api.media.getItemDetails(itemId);

    // 服务端下载许可：先看用户策略，再看条目级 CanDownload。
    final allowedByPolicy =
        await ref.read(downloadPermissionProvider.future);
    final allowedByItem = item.canDownload ?? true;
    if (!allowedByPolicy || !allowedByItem) {
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('当前服务器未开放下载权限')),
        );
      }
      return;
    }

    final manager = ref.read(downloadManagerProvider);
    final task = await startMediaDownload(
      api: api,
      manager: manager,
      item: item,
    );

    if (context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(task != null ? '已添加到下载队列' : '添加下载失败')),
      );
    }
  }

  void _showCastDialog(BuildContext context, WidgetRef ref) {
    final castService = CastService();
    
    showDialog(
      context: context,
      builder: (context) => DefaultTextStyle.merge(
        style: TextStyle(color: Theme.of(context).textTheme.bodyLarge?.color),
        child: AlertDialog(
          title: Row(
          children: [
            const Text('投屏设备'),
            const Spacer(),
            SizedBox(
              width: 20,
              height: 20,
              child: CircularProgressIndicator(
                strokeWidth: 2,
                color: Theme.of(context).colorScheme.primary,
              ),
            ),
          ],
        ),
        content: SizedBox(
          width: double.maxFinite,
          height: 300,
          child: _CastDeviceList(
            castService: castService,
            onDeviceSelected: (device) async {
              Navigator.pop(context);
              final api = ref.read(apiClientProvider);
              final videoUrl = api.playback.getVideoStreamUrl(itemId);
              
              final connected = await castService.connect(device);
              if (connected) {
                final success = await castService.castVideo(videoUrl);
                if (context.mounted) {
                  ScaffoldMessenger.of(context).showSnackBar(
                    SnackBar(
                      content: Text(success 
                        ? '已投屏到 ${device.name}'
                        : '投屏失败，请重试'),
                    ),
                  );
                }
              } else {
                if (context.mounted) {
                  ScaffoldMessenger.of(context).showSnackBar(
                    const SnackBar(content: Text('连接设备失败')),
                  );
                }
              }
            },
          ),
        ),
        actions: [
          TextButton(
            onPressed: () {
              castService.dispose();
              Navigator.pop(context);
            },
            child: const Text('关闭'),
          ),
        ],
      ),
      ),
    );

    // 开始扫描
    castService.startDiscovery();
  }
}

/// 设备列表组件
class _CastDeviceList extends StatefulWidget {
  final CastService castService;
  final Function(CastDevice) onDeviceSelected;
  
  const _CastDeviceList({
    required this.castService,
    required this.onDeviceSelected,
  });
  
  @override
  State<_CastDeviceList> createState() => _CastDeviceListState();
}

class _CastDeviceListState extends State<_CastDeviceList> {
  @override
  void initState() {
    super.initState();
    widget.castService.addListener(_onUpdate);
  }
  
  @override
  void dispose() {
    widget.castService.removeListener(_onUpdate);
    super.dispose();
  }
  
  void _onUpdate() {
    setState(() {});
  }
  
  @override
  Widget build(BuildContext context) {
    final devices = widget.castService.devices;
    
    if (devices.isEmpty) {
      return Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(
              Icons.cast_connected,
              size: 48,
              color: Theme.of(context).colorScheme.outline,
            ),
            const SizedBox(height: 16),
            Text(
              '正在搜索设备...',
              style: TextStyle(
                color: Theme.of(context).colorScheme.outline,
              ),
            ),
            const SizedBox(height: 8),
            Text(
              '请确保电视/投屏器与手机在同一WiFi下',
              style: TextStyle(
                fontSize: 12,
                color: Theme.of(context).textTheme.bodySmall?.color,
              ),
              textAlign: TextAlign.center,
            ),
          ],
        ),
      );
    }
    
    return ListView.builder(
      itemCount: devices.length,
      itemBuilder: (context, index) {
        final device = devices[index];
        return ListTile(
          leading: const Icon(Icons.tv),
          title: Text(device.name),
          subtitle: Text('${device.host}:${device.port}'),
          trailing: device.isConnected 
              ? const Icon(Icons.check_circle, color: Color(0xFF5B8DEF))
              : null,
          onTap: () => widget.onDeviceSelected(device),
        );
      },
    );
  }
}

/// 版本信息区块
class _VersionInfoSection extends ConsumerWidget {
  final String itemId;
  
  const _VersionInfoSection({required this.itemId});
  
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final playbackAsync = ref.watch(playbackInfoProvider(itemId));
    
    return playbackAsync.when(
      data: (info) {
        if (info.mediaSources.isEmpty) return const SizedBox.shrink();
        
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const SectionHeader(title: '版本信息'),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: Column(
                children: info.mediaSources.map((source) {
                  final video = source.primaryVideoStream;
                  final audio = source.mediaStreams.where((s) => s.isAudio).firstOrNull;
                  final subtitle = source.mediaStreams.where((s) => s.isSubtitle).firstOrNull;
                  String videoLabel = '';
                  if (video != null) {
                    final segs = <String>[
                      if (video.resolution.isNotEmpty) video.resolution,
                      if (video.videoFormatLabel.isNotEmpty)
                        video.videoFormatLabel,
                    ];
                    videoLabel = segs.isNotEmpty
                        ? segs.join(' / ')
                        : (video.displayTitle ?? video.codec ?? '');
                  }
                  return Card(
                    child: Padding(
                      padding: const EdgeInsets.all(12),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          if (source.name != null) ...[
                            Text(source.name!, style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 14)),
                            const SizedBox(height: 6),
                          ],
                          if (video != null)
                            Row(
                              children: [
                                Icon(Icons.videocam, size: 16, color: Theme.of(context).colorScheme.primary),
                                const SizedBox(width: 6),
                                Text(videoLabel, style: const TextStyle(fontSize: 13)),
                              ],
                            ),
                          if (audio != null) ...[
                            const SizedBox(height: 6),
                            Row(
                              children: [
                                Icon(Icons.audiotrack, size: 16, color: Theme.of(context).colorScheme.secondary),
                                const SizedBox(width: 6),
                                Text(audio.displayTitle ?? '${audio.language ?? ""} ${audio.codec ?? ""} ${audio.channels ?? 0}ch', style: const TextStyle(fontSize: 13)),
                              ],
                            ),
                          ],
                          if (subtitle != null) ...[
                            const SizedBox(height: 6),
                            Row(
                              children: [
                                Icon(Icons.subtitles, size: 16, color: Theme.of(context).colorScheme.tertiary),
                                const SizedBox(width: 6),
                                Text(subtitle.readableLabel(), style: const TextStyle(fontSize: 13)),
                              ],
                            ),
                          ],
                        ],
                      ),
                    ),
                  );
                }).toList(),
              ),
            ),
          ],
        );
      },
      loading: () => const SizedBox.shrink(),
      error: (_, __) => const SizedBox.shrink(),
    );
  }
}
