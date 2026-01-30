import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../../services/emby_api.dart';
import '../../ui/glass_blur.dart';
import 'player_gestures.dart';

typedef EpisodePickerFetchItemDetail = Future<MediaItem> Function(
    String itemId);

typedef EpisodePickerFetchSeasons = Future<List<MediaItem>> Function(
  String seriesId,
);

typedef EpisodePickerFetchEpisodes = Future<List<MediaItem>> Function(
  String seasonId,
);

class EpisodePickerController extends ChangeNotifier {
  EpisodePickerController({
    required this.itemId,
    required this.fetchItemDetail,
    required this.fetchSeasons,
    required this.fetchEpisodes,
  });

  final String itemId;
  final EpisodePickerFetchItemDetail fetchItemDetail;
  final EpisodePickerFetchSeasons fetchSeasons;
  final EpisodePickerFetchEpisodes fetchEpisodes;

  MediaItem? _item;
  bool _itemLoading = false;

  bool _visible = false;
  bool _loading = false;
  String? _error;

  List<MediaItem> _seasons = const [];
  String? _selectedSeasonId;

  final Map<String, List<MediaItem>> _episodesCache = {};
  final Map<String, Future<List<MediaItem>>> _episodesFutureCache = {};

  bool _disposed = false;

  MediaItem? get item => _item;
  bool get itemLoading => _itemLoading;
  bool get visible => _visible;
  bool get loading => _loading;
  String? get error => _error;
  List<MediaItem> get seasons => _seasons;
  String? get selectedSeasonId => _selectedSeasonId;

  bool get canShowButton {
    if (_visible) return true;
    if (_itemLoading) return true;
    final seriesId = (_item?.seriesId ?? '').trim();
    return seriesId.isNotEmpty;
  }

  MediaItem? get selectedSeason {
    final seasons = _seasons;
    final selectedId = (_selectedSeasonId ?? '').trim();
    if (selectedId.isNotEmpty) {
      for (final s in seasons) {
        if (s.id == selectedId) return s;
      }
    }
    return seasons.isNotEmpty ? seasons.first : null;
  }

  String seasonLabel(MediaItem season, int index) {
    final name = season.name.trim();
    final seasonNo = season.seasonNumber ?? season.episodeNumber;
    return seasonNo != null
        ? '第$seasonNo季'
        : (name.isNotEmpty ? name : '第${index + 1}季');
  }

  void hide() {
    if (!_visible) return;
    _visible = false;
    notifyListeners();
  }

  void selectSeason(String? seasonId) {
    final next = (seasonId ?? '').trim();
    if (next.isEmpty) return;
    if (next == _selectedSeasonId) return;
    _selectedSeasonId = next;
    notifyListeners();
  }

  void invalidateSeason(String seasonId) {
    final id = seasonId.trim();
    if (id.isEmpty) return;
    _episodesCache.remove(id);
    _episodesFutureCache.remove(id);
    notifyListeners();
  }

  Future<void> preloadItem() async {
    if (_itemLoading || _item != null) return;
    _itemLoading = true;
    notifyListeners();
    try {
      final detail = await fetchItemDetail(itemId);
      if (_disposed) return;
      _item = detail;
    } catch (_) {
      // Optional: if this fails, we simply hide the entry point.
    } finally {
      _itemLoading = false;
      if (!_disposed) {
        notifyListeners();
      }
    }
  }

  Future<void> toggle(
      {required ControlsVisibilityCallback showControls}) async {
    if (_visible) {
      hide();
      return;
    }

    showControls(scheduleHide: false);
    _visible = true;
    _error = null;
    notifyListeners();
    await ensureLoaded();
  }

  Future<void> ensureLoaded() async {
    if (_loading) return;

    _loading = true;
    _error = null;
    notifyListeners();

    try {
      await preloadItem();
      if (_disposed) return;
      final detail = _item;
      final seriesId = (detail?.seriesId ?? '').trim();
      if (seriesId.isEmpty) {
        throw Exception('当前不是剧集，无法选集');
      }

      final seasons = await fetchSeasons(seriesId);
      if (_disposed) return;

      final seasonItems =
          seasons.where((s) => s.type.toLowerCase() == 'season').toList();
      seasonItems.sort((a, b) {
        final aNo = a.seasonNumber ?? a.episodeNumber ?? 0;
        final bNo = b.seasonNumber ?? b.episodeNumber ?? 0;
        return aNo.compareTo(bNo);
      });

      final seasonsVirtual = seasonItems.isEmpty;
      final seasonsForUi = seasonsVirtual
          ? [
              MediaItem(
                id: seriesId,
                name: '第1季',
                type: 'Season',
                overview: '',
                communityRating: null,
                premiereDate: null,
                genres: const [],
                runTimeTicks: null,
                sizeBytes: null,
                container: null,
                providerIds: const {},
                seriesId: seriesId,
                seriesName: '',
                seasonName: '',
                seasonNumber: 1,
                episodeNumber: null,
                hasImage: false,
                playbackPositionTicks: 0,
                people: const [],
                parentId: seriesId,
              ),
            ]
          : seasonItems;

      final previousSelected = _selectedSeasonId;
      final currentSeasonId = (detail?.parentId ?? '').trim();
      final defaultSeasonId = (currentSeasonId.isNotEmpty &&
              seasonsForUi.any((s) => s.id == currentSeasonId))
          ? currentSeasonId
          : (seasonsForUi.isNotEmpty ? seasonsForUi.first.id : '');
      final selectedSeasonId = (previousSelected != null &&
              seasonsForUi.any((s) => s.id == previousSelected))
          ? previousSelected
          : (defaultSeasonId.isNotEmpty ? defaultSeasonId : null);

      _seasons = seasonsForUi;
      _selectedSeasonId = selectedSeasonId;
      notifyListeners();
    } catch (e) {
      if (_disposed) return;
      _error = e.toString();
      notifyListeners();
    } finally {
      _loading = false;
      if (!_disposed) {
        notifyListeners();
      }
    }
  }

  Future<List<MediaItem>> _episodesForSeasonId(String seasonId) async {
    final cached = _episodesCache[seasonId];
    if (cached != null) return cached;

    final eps = await fetchEpisodes(seasonId);
    final items = List<MediaItem>.from(eps);
    items.sort((a, b) {
      final aNo = a.episodeNumber ?? 0;
      final bNo = b.episodeNumber ?? 0;
      return aNo.compareTo(bNo);
    });
    _episodesCache[seasonId] = items;
    return items;
  }

  Future<List<MediaItem>> episodesFutureForSeasonId(String seasonId) {
    final cachedFuture = _episodesFutureCache[seasonId];
    if (cachedFuture != null) return cachedFuture;

    final cached = _episodesCache[seasonId];
    final future = cached != null
        ? Future<List<MediaItem>>.value(cached)
        : _episodesForSeasonId(seasonId);
    _episodesFutureCache[seasonId] = future;
    return future;
  }

  @override
  void dispose() {
    _disposed = true;
    super.dispose();
  }
}

class EpisodePickerOverlay extends StatelessWidget {
  const EpisodePickerOverlay({
    super.key,
    required this.controller,
    required this.enableBlur,
    required this.showCover,
    required this.onToggleShowCover,
    required this.currentItemId,
    required this.onPlayEpisode,
    required this.baseUrl,
    required this.token,
    required this.apiPrefix,
  });

  final EpisodePickerController controller;
  final bool enableBlur;
  final bool showCover;
  final VoidCallback? onToggleShowCover;
  final String currentItemId;
  final ValueChanged<MediaItem> onPlayEpisode;
  final String? baseUrl;
  final String? token;
  final String apiPrefix;

  String? _episodeImageUrl(MediaItem episode, MediaItem season) {
    final baseUrl = this.baseUrl;
    final token = this.token;
    if (baseUrl == null || token == null) return null;
    return EmbyApi.imageUrl(
      baseUrl: baseUrl,
      itemId: episode.hasImage ? episode.id : season.id,
      token: token,
      apiPrefix: apiPrefix,
      maxWidth: 520,
    );
  }

  Widget _buildBody({
    required double drawerWidth,
    required Color accent,
    required MediaItem? selectedSeason,
  }) {
    if (controller.loading) {
      return const Padding(
        padding: EdgeInsets.all(16),
        child: Center(child: CircularProgressIndicator()),
      );
    }

    final error = controller.error;
    if (error != null) {
      return Padding(
        padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(error, style: const TextStyle(color: Colors.white70)),
            const SizedBox(height: 10),
            OutlinedButton.icon(
              onPressed: controller.ensureLoaded,
              icon: const Icon(Icons.refresh),
              label: const Text('重试'),
            ),
          ],
        ),
      );
    }

    if (selectedSeason == null) {
      return const Padding(
        padding: EdgeInsets.all(16),
        child: Text(
          '暂无剧集信息',
          style: TextStyle(color: Colors.white70),
        ),
      );
    }

    return Expanded(
      child: FutureBuilder<List<MediaItem>>(
        future: controller.episodesFutureForSeasonId(selectedSeason.id),
        builder: (ctx, snapshot) {
          if (snapshot.connectionState != ConnectionState.done) {
            return const Center(child: CircularProgressIndicator());
          }
          if (snapshot.hasError) {
            return Padding(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Text(
                    '加载失败：${snapshot.error}',
                    style: const TextStyle(color: Colors.white70),
                  ),
                  const SizedBox(height: 10),
                  OutlinedButton.icon(
                    onPressed: () => controller.invalidateSeason(
                      selectedSeason.id,
                    ),
                    icon: const Icon(Icons.refresh),
                    label: const Text('重试'),
                  ),
                ],
              ),
            );
          }

          final eps = snapshot.data ?? const <MediaItem>[];
          if (eps.isEmpty) {
            return const Center(
              child: Text(
                '暂无剧集',
                style: TextStyle(color: Colors.white70),
              ),
            );
          }

          final columns = drawerWidth >= 360 ? 2 : 1;
          if (!showCover) {
            return ListView.separated(
              padding: const EdgeInsets.fromLTRB(12, 0, 12, 12),
              itemCount: eps.length,
              separatorBuilder: (_, __) => const SizedBox(height: 10),
              itemBuilder: (ctx, index) {
                final e = eps[index];
                final epNo = e.episodeNumber ?? (index + 1);
                final isCurrent = e.id == currentItemId;
                final borderColor = isCurrent
                    ? accent.withValues(alpha: 0.85)
                    : Colors.white.withValues(alpha: 0.10);
                final title =
                    e.name.trim().isNotEmpty ? e.name.trim() : '第$epNo集';
                return Material(
                  color: Colors.black.withValues(alpha: 0.18),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(12),
                    side: BorderSide(color: borderColor),
                  ),
                  clipBehavior: Clip.antiAlias,
                  child: InkWell(
                    onTap: () {
                      controller.hide();
                      onPlayEpisode(e);
                    },
                    child: Padding(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 10,
                        vertical: 10,
                      ),
                      child: Row(
                        children: [
                          DecoratedBox(
                            decoration: BoxDecoration(
                              color: accent.withValues(alpha: 0.14),
                              borderRadius: BorderRadius.circular(6),
                            ),
                            child: Padding(
                              padding: const EdgeInsets.symmetric(
                                horizontal: 8,
                                vertical: 4,
                              ),
                              child: Text(
                                epNo.toString(),
                                style: TextStyle(
                                  color: accent,
                                  fontSize: 12,
                                  fontWeight: FontWeight.w700,
                                ),
                              ),
                            ),
                          ),
                          const SizedBox(width: 10),
                          Expanded(
                            child: Text(
                              title,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: const TextStyle(
                                color: Colors.white,
                                fontSize: 12,
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                          ),
                          if (isCurrent)
                            const Icon(
                              Icons.play_circle,
                              color: Colors.white,
                            ),
                        ],
                      ),
                    ),
                  ),
                );
              },
            );
          }

          return GridView.builder(
            padding: const EdgeInsets.fromLTRB(12, 0, 12, 12),
            gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
              crossAxisCount: columns,
              crossAxisSpacing: 10,
              mainAxisSpacing: 10,
              childAspectRatio: columns == 1 ? 1.55 : 1.18,
            ),
            itemCount: eps.length,
            itemBuilder: (ctx, index) {
              final e = eps[index];
              final epNo = e.episodeNumber ?? (index + 1);
              final isCurrent = e.id == currentItemId;
              final img = _episodeImageUrl(e, selectedSeason);
              final borderColor = isCurrent
                  ? accent.withValues(alpha: 0.85)
                  : Colors.white.withValues(alpha: 0.10);
              return Material(
                color: Colors.black.withValues(alpha: 0.18),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(12),
                  side: BorderSide(color: borderColor),
                ),
                clipBehavior: Clip.antiAlias,
                child: InkWell(
                  onTap: () {
                    controller.hide();
                    onPlayEpisode(e);
                  },
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      AspectRatio(
                        aspectRatio: 16 / 9,
                        child: Stack(
                          fit: StackFit.expand,
                          children: [
                            if (img != null)
                              Image.network(
                                img,
                                fit: BoxFit.cover,
                                errorBuilder: (_, __, ___) {
                                  return const ColoredBox(
                                    color: Color(0x22000000),
                                    child: Center(
                                      child: Icon(
                                        Icons.image_not_supported_outlined,
                                        color: Colors.white54,
                                      ),
                                    ),
                                  );
                                },
                              )
                            else
                              const ColoredBox(
                                color: Color(0x22000000),
                                child: Center(
                                  child: Icon(
                                    Icons.image_outlined,
                                    color: Colors.white54,
                                  ),
                                ),
                              ),
                            Positioned(
                              left: 6,
                              bottom: 6,
                              child: DecoratedBox(
                                decoration: BoxDecoration(
                                  color: const Color(0xAA000000),
                                  borderRadius: BorderRadius.circular(6),
                                ),
                                child: Padding(
                                  padding: const EdgeInsets.symmetric(
                                    horizontal: 6,
                                    vertical: 3,
                                  ),
                                  child: Text(
                                    'E$epNo',
                                    style: const TextStyle(
                                      color: Colors.white,
                                      fontSize: 11,
                                      fontWeight: FontWeight.w700,
                                    ),
                                  ),
                                ),
                              ),
                            ),
                            if (isCurrent)
                              const Positioned(
                                right: 6,
                                top: 6,
                                child: Icon(
                                  Icons.play_circle,
                                  color: Colors.white,
                                ),
                              ),
                          ],
                        ),
                      ),
                      Padding(
                        padding: const EdgeInsets.fromLTRB(8, 6, 8, 8),
                        child: Text(
                          e.name.trim().isNotEmpty ? e.name.trim() : '第$epNo集',
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                            color: Colors.white,
                            fontSize: 12,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              );
            },
          );
        },
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final size = MediaQuery.sizeOf(context);
    final drawerWidth = math.min(
      420.0,
      size.width * (size.width > size.height ? 0.50 : 0.78),
    );

    final theme = Theme.of(context);
    final accent = theme.colorScheme.secondary;

    return Positioned.fill(
      child: AnimatedBuilder(
        animation: controller,
        builder: (context, _) {
          final seasons = controller.seasons;
          final selectedSeason = controller.selectedSeason;

          return Stack(
            children: [
              IgnorePointer(
                ignoring: !controller.visible,
                child: AnimatedOpacity(
                  opacity: controller.visible ? 1 : 0,
                  duration: const Duration(milliseconds: 180),
                  child: GestureDetector(
                    behavior: HitTestBehavior.opaque,
                    onTap: controller.hide,
                    child: ColoredBox(
                      color: Colors.black.withValues(alpha: 0.25),
                      child: const SizedBox.expand(),
                    ),
                  ),
                ),
              ),
              AnimatedPositioned(
                duration: const Duration(milliseconds: 220),
                curve: Curves.easeOutCubic,
                top: 0,
                bottom: 0,
                right: controller.visible ? 0 : -drawerWidth,
                width: drawerWidth,
                child: IgnorePointer(
                  ignoring: !controller.visible,
                  child: SafeArea(
                    left: false,
                    child: GlassCard(
                      enableBlur: enableBlur,
                      margin: EdgeInsets.zero,
                      elevation: 0,
                      shadowColor: Colors.transparent,
                      surfaceTintColor: Colors.transparent,
                      color: Colors.black.withValues(alpha: 0.35),
                      shape: const RoundedRectangleBorder(
                        borderRadius: BorderRadius.horizontal(
                          left: Radius.circular(16),
                        ),
                      ),
                      child: Column(
                        children: [
                          Padding(
                            padding: const EdgeInsets.fromLTRB(12, 10, 8, 8),
                            child: Row(
                              children: [
                                const Icon(
                                  Icons.format_list_numbered,
                                  color: Colors.white,
                                  size: 18,
                                ),
                                const SizedBox(width: 8),
                                const Text(
                                  '选集',
                                  style: TextStyle(
                                    color: Colors.white,
                                    fontWeight: FontWeight.w700,
                                  ),
                                ),
                                const SizedBox(width: 8),
                                if (selectedSeason != null)
                                  Expanded(
                                    child: Container(
                                      height: 36,
                                      padding: const EdgeInsets.symmetric(
                                        horizontal: 8,
                                      ),
                                      decoration: BoxDecoration(
                                        color: Colors.black
                                            .withValues(alpha: 0.18),
                                        borderRadius: BorderRadius.circular(10),
                                        border: Border.all(
                                          color: Colors.white
                                              .withValues(alpha: 0.12),
                                        ),
                                      ),
                                      child: DropdownButtonHideUnderline(
                                        child: DropdownButton<String>(
                                          value: selectedSeason.id,
                                          isExpanded: true,
                                          isDense: true,
                                          dropdownColor: Colors.black
                                              .withValues(alpha: 0.9),
                                          icon: const Icon(
                                            Icons.expand_more,
                                            color: Colors.white,
                                          ),
                                          style: const TextStyle(
                                            color: Colors.white,
                                            fontSize: 13,
                                            fontWeight: FontWeight.w600,
                                          ),
                                          onChanged: controller.selectSeason,
                                          items: [
                                            for (var i = 0;
                                                i < seasons.length;
                                                i++)
                                              DropdownMenuItem(
                                                value: seasons[i].id,
                                                child: Text(
                                                  controller.seasonLabel(
                                                    seasons[i],
                                                    i,
                                                  ),
                                                ),
                                              ),
                                          ],
                                        ),
                                      ),
                                    ),
                                  ),
                                if (onToggleShowCover != null)
                                  IconButton(
                                    tooltip: showCover ? '列表' : '封面',
                                    icon: Icon(
                                      showCover
                                          ? Icons.view_list
                                          : Icons.grid_view,
                                    ),
                                    color: Colors.white,
                                    onPressed: onToggleShowCover,
                                  ),
                                IconButton(
                                  tooltip: '关闭',
                                  icon: const Icon(Icons.close),
                                  color: Colors.white,
                                  onPressed: controller.hide,
                                ),
                              ],
                            ),
                          ),
                          _buildBody(
                            drawerWidth: drawerWidth,
                            accent: accent,
                            selectedSeason: selectedSeason,
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
              ),
            ],
          );
        },
      ),
    );
  }
}
