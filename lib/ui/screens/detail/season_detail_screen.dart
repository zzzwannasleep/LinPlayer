import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import '../../../core/api/api_interfaces.dart';
import '../../../core/providers/app_providers.dart';
import '../../../core/providers/media_providers.dart';
import '../../../core/services/cast_service.dart';
import '../../../core/services/preload_service.dart';
import '../../../core/theme/app_motion.dart';
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

/// 季详情页
class SeasonDetailScreen extends ConsumerStatefulWidget {
  final String seasonId;
  final Color? backgroundColor;

  const SeasonDetailScreen({
    super.key,
    required this.seasonId,
    this.backgroundColor,
  });

  @override
  ConsumerState<SeasonDetailScreen> createState() => _SeasonDetailScreenState();
}

class _SeasonDetailScreenState extends ConsumerState<SeasonDetailScreen> {
  String? _seriesId;
  String? _seasonName;

  @override
  void initState() {
    super.initState();
    _loadSeasonInfo();
  }

  Future<void> _loadSeasonInfo() async {
    try {
      final api = ref.read(apiClientProvider);
      final season = await api.media.getItemDetails(widget.seasonId);
      if (mounted) {
        setState(() {
          _seriesId = season.seriesId;
          _seasonName = season.name;
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _seasonName = '加载失败';
        });
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('加载季信息失败: $e')),
        );
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final api = ref.read(apiClientProvider);

    return DynamicBackground(
      backgroundColor: widget.backgroundColor ?? const Color(0xFF121212),
      child: Scaffold(
        appBar: AppBar(
          title: Text(_seasonName ?? '季详情'),
        ),
        body: _seriesId == null
            ? const AppLoadingIndicator()
            : _buildEpisodeList(api),
      ),
    );
  }

  Widget _buildEpisodeList(ApiClientFactory api) {
    final episodesAsync = ref.watch(
      episodesProvider((seriesId: _seriesId!, seasonId: widget.seasonId)),
    );

    return episodesAsync.when(
      data: (episodes) {
        if (episodes.isEmpty) {
          return const Center(child: Text('暂无集数'));
        }
        // 预计算所有图片 URL，避免在 itemBuilder 中重复计算
        final episodesWithImages = episodes.map((episode) {
          return _EpisodeWithImage(
            episode: episode,
            imageUrls: resolveEpisodeLandscapeImageUrls(api, episode, maxWidth: 480),
          );
        }).toList();

        return ListView.builder(
          padding: const EdgeInsets.all(16),
          itemCount: episodesWithImages.length,
          itemExtent: 84.0, // 固定高度优化布局计算 (ListTile 72px + margin 12px)
          itemBuilder: (context, index) {
            final item = episodesWithImages[index];
            // 使用 RepaintBoundary 隔离每个列表项的重绘
            return RepaintBoundary(
              child: _EpisodeListItem(item: item).appEntrance(index: index),
            );
          },
        );
      },
      loading: () => const AppLoadingIndicator(),
      error: (error, _) => Center(child: Text('错误: $error')),
    );
  }
}

/// 剧集数据与预计算的图片 URL
class _EpisodeWithImage {
  final Episode episode;
  final List<String> imageUrls;

  const _EpisodeWithImage({
    required this.episode,
    required this.imageUrls,
  });
}

/// 剧集列表项
class _EpisodeListItem extends StatelessWidget {
  final _EpisodeWithImage item;

  const _EpisodeListItem({required this.item});

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final textTheme = Theme.of(context).textTheme;

    return Card(
      margin: const EdgeInsets.only(bottom: 12),
      child: ListTile(
        onTap: () => context.push('/episode/${item.episode.id}'),
        leading: ClipRRect(
          borderRadius: BorderRadius.circular(8),
          child: Container(
            width: 100,
            height: 60,
            color: colorScheme.surfaceContainerHighest,
            child: item.imageUrls.isNotEmpty
                ? MediaImage(
                    imageUrl: item.imageUrls.first,
                    imageUrls: item.imageUrls.length > 1
                        ? item.imageUrls.sublist(1)
                        : null,
                    width: 100,
                    height: 60,
                    cacheWidth: 200, // 2x 显示尺寸，优化内存和解码性能
                    cacheHeight: 120,
                    fit: BoxFit.cover,
                  )
                : const Center(child: Icon(Icons.play_arrow)),
          ),
        ),
        title: Text('E${item.episode.indexNumber} ${item.episode.name}'),
        subtitle: Text(
          item.episode.formattedRuntime ?? '',
          style: TextStyle(color: textTheme.bodySmall?.color),
        ),
        trailing: item.episode.userData?.played ?? false
            ? const Icon(Icons.check_circle, color: Color(0xFF5B8DEF))
            : null,
      ),
    );
  }
}

/// 集详情页（电影/单集通用播放准备页）
class EpisodeDetailScreen extends ConsumerStatefulWidget {
  final String episodeId;

  const EpisodeDetailScreen({super.key, required this.episodeId});

  @override
  ConsumerState<EpisodeDetailScreen> createState() => _EpisodeDetailScreenState();
}

class _EpisodeDetailScreenState extends ConsumerState<EpisodeDetailScreen> {
  @override
  void initState() {
    super.initState();
    _resetPlaybackSelections();
    _triggerPreload();
  }

  @override
  void didUpdateWidget(covariant EpisodeDetailScreen oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.episodeId != widget.episodeId) {
      _resetPlaybackSelections();
      _triggerPreload();
    }
  }

  /// 进入详情页即按规范流程预热真实播放流（受「预加载」开关控制，fire-and-forget）。
  void _triggerPreload() {
    if (!ref.read(preloadEnabledProvider)) return;
    final ApiClientFactory api;
    try {
      api = ref.read(apiClientProvider);
    } catch (_) {
      return; // 未连接服务器
    }
    PreloadService.instance.preloadItem(
      api: api,
      itemId: widget.episodeId,
      enabled: true,
      preferredMediaSourceId: ref.read(selectedMediaSourceProvider),
      versionRegex: ref.read(preferredVersionRegexProvider),
      strmDirectPlay: ref.read(strmDirectPlayProvider),
    );
  }

  void _resetPlaybackSelections() {
    // 使用 Future.microtask 延迟执行，避免在 widget 生命周期中直接修改 provider
    Future.microtask(() {
      ref.read(selectedMediaSourceProvider.notifier).state = null;
      ref.read(audioTrackProvider.notifier).state = null;
      ref.read(subtitleTrackProvider.notifier).state = null;
      ref.read(secondarySubtitleTrackProvider.notifier).state = null;
    });
  }

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
    final itemAsync = ref.watch(mediaItemProvider(widget.episodeId));
    final playbackAsync = ref.watch(playbackInfoProvider(widget.episodeId));
    final foregroundColor = readableTextColorForBackground(_backgroundColor);

    return Scaffold(
      backgroundColor: _backgroundColor,
      body: itemAsync.when(
        data: (item) => DynamicBackground(
          backgroundColor: _backgroundColor,
          child: CustomScrollView(
          slivers: [
            // 封面区域
            SliverToBoxAdapter(
              child: _DetailHeader(
                item: item,
                onColorChanged: _onColorChanged,
              ),
            ),

            // 简介
            if (item.overview != null && item.overview!.isNotEmpty)
              SliverToBoxAdapter(
                child: _OverviewSection(
                  overview: item.overview!,
                  textColor: foregroundColor,
                ),
              ),

            // 播放选项
            SliverToBoxAdapter(
              child: playbackAsync.when(
                data: (info) => _EpisodePlaybackOptions(
                  episodeId: widget.episodeId,
                  info: info,
                ),
                loading: () => const SizedBox.shrink(),
                error: (_, __) => const Padding(
                  padding: EdgeInsets.all(16),
                  child: Text('加载播放信息失败'),
                ),
              ),
            ),

            // 已观看进度（播放按钮上方）
            SliverToBoxAdapter(
              child: Builder(
                builder: (context) {
                  final label = formatWatchedProgressLabel(
                      item.userData?.playbackPositionTicks);
                  if (label == null) return const SizedBox.shrink();
                  final color = Theme.of(context).textTheme.bodySmall?.color;
                  return Padding(
                    padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
                    child: Row(
                      children: [
                        Icon(Icons.history, size: 15, color: color),
                        const SizedBox(width: 6),
                        Text(label,
                            style: TextStyle(fontSize: 12.5, color: color)),
                      ],
                    ),
                  );
                },
              ),
            ),

            // 播放按钮
            SliverToBoxAdapter(
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                child: _PlayButtons(itemId: widget.episodeId),
              ),
            ),

            // 演职人员
            SliverToBoxAdapter(
              child: _CastSection(itemId: widget.episodeId),
            ),

            // 版本信息
            SliverToBoxAdapter(
              child: playbackAsync.when(
                data: (info) => _VersionInfoSection(info: info),
                loading: () => const SizedBox.shrink(),
                error: (_, __) => const SizedBox.shrink(),
              ),
            ),

            const SliverPadding(padding: EdgeInsets.only(bottom: 32)),
          ],
          ),
        ),
        loading: () => const Scaffold(
          body: AppLoadingIndicator(),
        ),
        error: (error, _) => Scaffold(
          body: Center(child: Text('错误: $error')),
        ),
      ),
    );
  }
}

/// 详情页头部封面
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

  @override
  void initState() {
    super.initState();
    _extractColor();
  }

  @override
  void didUpdateWidget(covariant _DetailHeader oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.item.id != widget.item.id) {
      _extractColor();
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

  @override
  Widget build(BuildContext context) {
    final screenWidth = MediaQuery.of(context).size.width;
    final api = ref.read(apiClientProvider);
    final useVideoBackground = ref.watch(useVideoBackgroundProvider);
    final imageUrls = resolveMediaItemLandscapeImageUrls(
      api,
      widget.item,
      maxWidth: isDesktopPlatform ? 1600 : 960,
    );
    final hasLandscapeImage = imageUrls.isNotEmpty;
    final headerHeight = isDesktopPlatform
        ? 400.0
        : (hasLandscapeImage ? screenWidth * 0.6 : screenWidth * 0.85);
    final videoUrl = (useVideoBackground && widget.item.remoteTrailers != null && widget.item.remoteTrailers!.isNotEmpty)
        ? widget.item.remoteTrailers!.first
        : null;

    // 标题/元信息在「渐变→海报主色」底部，前景色按主色亮度自适配（深底浅字、
    // 浅底深字），阴影取反色保证两种模式下都清晰。
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

        // 底部渐变（使用提取的颜色）
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
                  if (widget.item.productionYear != null)
                    Text(
                      '${widget.item.productionYear}',
                      style: TextStyle(
                        fontSize: 14,
                        color: fg,
                        shadows: [Shadow(blurRadius: 4, color: shadowColor)],
                      ),
                    ),
                  if (widget.item.productionYear != null && widget.item.formattedRuntime != null)
                    const SizedBox(width: 12),
                  if (widget.item.formattedRuntime != null)
                    Text(
                      widget.item.formattedRuntime!,
                      style: TextStyle(
                        fontSize: 14,
                        color: fg,
                        shadows: [Shadow(blurRadius: 4, color: shadowColor)],
                      ),
                    ),
                  const SizedBox(width: 12),
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
            ],
          ),
        ),
      ],
    );
  }
}

/// 集播放选项包装器（确保 ConsumerWidget 正确 rebuild）
class _EpisodePlaybackOptions extends ConsumerWidget {
  final String episodeId;
  final PlaybackInfo info;

  const _EpisodePlaybackOptions({
    required this.episodeId,
    required this.info,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return PlaybackOptions(
      key: ValueKey('episode_playback_${episodeId}_${info.mediaSources.length}'),
      itemId: episodeId,
      info: info,
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



/// 播放按钮组（播放 5/6 + 更多 1/6）
class _PlayButtons extends ConsumerWidget {
  final String itemId;

  const _PlayButtons({required this.itemId});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final mediaSourceId = ref.watch(selectedMediaSourceProvider);
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
              padding: const EdgeInsets.symmetric(vertical: 16),
            ),
          ),
        ),
        const SizedBox(width: 8),
        Expanded(
          flex: 1,
          child: OutlinedButton(
            onPressed: () => _showMoreMenu(context, ref),
            style: OutlinedButton.styleFrom(
              padding: const EdgeInsets.symmetric(vertical: 16),
            ),
            child: const Icon(Icons.more_vert),
          ),
        ),
      ],
    );
  }

  void _showMoreMenu(BuildContext context, WidgetRef ref) {
    final api = ref.read(apiClientProvider);
    final mediaSourceId = ref.read(selectedMediaSourceProvider);
    showModalBottomSheet(
      context: context,
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: const Icon(Icons.cast),
              title: const Text('投屏'),
              subtitle: const Text('搜索局域网设备', style: TextStyle(fontSize: 12)),
              onTap: () {
                Navigator.pop(ctx);
                _showCastDialog(context, ref);
              },
            ),
            ListTile(
              leading: const Icon(Icons.search),
              title: const Text('搜索其他播放源'),
              onTap: () {
                Navigator.pop(ctx);
                context.push('/search');
              },
            ),
            ListTile(
              leading: const Icon(Icons.download),
              title: const Text('下载'),
              onTap: () async {
                Navigator.pop(ctx);
                final item = await api.media.getItemDetails(itemId);
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
                final task = await startMediaDownload(
                  api: api,
                  manager: ref.read(downloadManagerProvider),
                  item: item,
                  mediaSourceIdOverride: mediaSourceId,
                );
                if (context.mounted) {
                  ScaffoldMessenger.of(context).showSnackBar(
                    SnackBar(content: Text(task != null ? '已添加到下载队列' : '添加下载失败')),
                  );
                }
              },
            ),
            ListTile(
              leading: const Icon(Icons.visibility),
              title: const Text('标记为已/未观看'),
              onTap: () async {
                Navigator.pop(ctx);
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
                  if (context.mounted) {
                    ScaffoldMessenger.of(context).showSnackBar(
                      SnackBar(content: Text(isWatched ? '已标记为未观看' : '已标记为已观看')),
                    );
                  }
                } catch (e) {
                  if (context.mounted) {
                    ScaffoldMessenger.of(context).showSnackBar(
                      SnackBar(content: Text('操作失败: $e')),
                    );
                  }
                }
              },
            ),
            ListTile(
              leading: const Icon(Icons.favorite),
              title: const Text('添加到喜欢'),
              onTap: () async {
                Navigator.pop(ctx);
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
                  if (context.mounted) {
                    ScaffoldMessenger.of(context).showSnackBar(
                      SnackBar(content: Text(isFav ? '已取消喜欢' : '已添加到喜欢')),
                    );
                  }
                } catch (e) {
                  if (context.mounted) {
                    ScaffoldMessenger.of(context).showSnackBar(
                      SnackBar(content: Text('操作失败: $e')),
                    );
                  }
                }
              },
            ),
          ],
        ),
      ),
    );
  }

  void _showCastDialog(BuildContext context, WidgetRef ref) {
    final castService = CastService();
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
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
          child: AnimatedBuilder(
            animation: castService,
            builder: (context, _) {
              final devices = castService.devices;
              if (devices.isEmpty) {
                return const Center(
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Icon(Icons.cast_connected, size: 48, color: Colors.grey),
                      SizedBox(height: 16),
                      Text('正在搜索设备...'),
                      SizedBox(height: 8),
                      Text(
                        '请确保电视/投屏器与手机在同一WiFi下',
                        style: TextStyle(fontSize: 12, color: Colors.grey),
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
                    trailing: device.isConnected
                        ? const Icon(Icons.check_circle, color: Color(0xFF5B8DEF))
                        : null,
                    onTap: () async {
                      final api = ref.read(apiClientProvider);
                      final mediaSourceId = ref.read(selectedMediaSourceProvider);
                      final videoUrl = api.playback.getVideoStreamUrl(
                        itemId,
                        mediaSourceId: mediaSourceId,
                      );
                      final connected = await castService.connect(device);
                      if (connected) {
                        final success = await castService.castVideo(videoUrl);
                        if (context.mounted) {
                          Navigator.pop(ctx);
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
                  );
                },
              );
            },
          ),
        ),
        actions: [
          TextButton(
            onPressed: () {
              castService.dispose();
              Navigator.pop(ctx);
            },
            child: const Text('关闭'),
          ),
        ],
      ),
    );
    castService.startDiscovery();
  }
}

/// 演职人员区块
class _CastSection extends ConsumerWidget {
  final String itemId;

  const _CastSection({required this.itemId});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final personsAsync = ref.watch(personsProvider(itemId));

    return personsAsync.when(
      data: (persons) {
        if (persons.isEmpty) return const SizedBox.shrink();

        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const SectionHeader(title: '演职人员'),
            HorizontalList(
              height: 140,
              children: persons.map((person) {
                return SizedBox(
                  width: 80,
                  child: _PersonCard(person: person),
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

class _PersonCard extends ConsumerWidget {
  final Person person;

  const _PersonCard({required this.person});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final api = ref.read(apiClientProvider);
    final imageUrl = person.primaryImageTag != null
        ? api.image.getPrimaryImageUrl(person.id, tag: person.primaryImageTag, maxWidth: 200)
        : null;

    return Column(
      children: [
        ClipRRect(
          borderRadius: BorderRadius.circular(40),
          child: Container(
            width: 72,
            height: 72,
            color: Theme.of(context).colorScheme.surfaceContainerHighest,
            child: imageUrl != null
                ? MediaImage(imageUrl: imageUrl, width: 72, height: 72, fit: BoxFit.cover)
                : const Icon(Icons.person, size: 32, color: Colors.grey),
          ),
        ),
        const SizedBox(height: 6),
        Text(
          person.name,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          textAlign: TextAlign.center,
          style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w500),
        ),
        if (person.role != null)
          Text(
            person.role!,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            textAlign: TextAlign.center,
            style: TextStyle(
              fontSize: 11,
              color: Theme.of(context).textTheme.bodySmall?.color,
            ),
          ),
      ],
    );
  }
}

/// 版本信息区块
class _VersionInfoSection extends StatelessWidget {
  final PlaybackInfo info;

  const _VersionInfoSection({required this.info});

  @override
  Widget build(BuildContext context) {
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
                  if (video.videoFormatLabel.isNotEmpty) video.videoFormatLabel,
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
                            Text(subtitle.displayTitle ?? subtitle.language ?? '', style: const TextStyle(fontSize: 13)),
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
  }
}
