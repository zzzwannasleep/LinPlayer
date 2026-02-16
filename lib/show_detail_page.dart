import 'dart:async';

import 'dart:ui';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:lin_player_prefs/lin_player_prefs.dart';
import 'package:lin_player_server_adapters/lin_player_server_adapters.dart';
import 'package:lin_player_state/lin_player_state.dart';
import 'package:lin_player_ui/lin_player_ui.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:url_launcher/url_launcher_string.dart';
import 'server_adapters/server_access.dart';
import 'play_network_page.dart';
import 'play_network_page_exo.dart';

class _DetailUiTokens {
  static const pagePadding = EdgeInsets.fromLTRB(20, 74, 20, 24);
  static const sectionGap = 16.0;
  static const sectionTitleGap = 8.0;
  static const panelPadding = EdgeInsets.all(16);
  static const cardRadius = 12.0;
  static const heroPosterRadius = 14.0;
  static const actionRadius = 999.0;
  static const horizontalGap = 12.0;
  static const horizontalEpisodeCardWidth = 288.0;
  static const horizontalEpisodeStripHeight = 206.0;
}

Widget _sectionTitle(
  BuildContext context,
  String title, {
  Widget? trailing,
}) {
  final text = Text(
    title,
    style: Theme.of(context).textTheme.titleMedium?.copyWith(
          color: Colors.white.withValues(alpha: 0.96),
          fontWeight: FontWeight.w700,
        ),
  );
  if (trailing == null) return text;
  return Row(
    children: [
      Expanded(child: text),
      const SizedBox(width: _DetailUiTokens.sectionTitleGap),
      trailing,
    ],
  );
}

Widget _detailActionButton(
  BuildContext context, {
  required IconData icon,
  required String label,
  required VoidCallback? onTap,
  bool primary = false,
}) {
  const fg = Colors.white;
  final bg = primary
      ? const Color(0xFF1F9F75).withValues(alpha: 0.84)
      : Colors.black.withValues(alpha: 0.34);
  final borderColor = primary
      ? Colors.transparent
      : Colors.white.withValues(alpha: 0.20);
  return Material(
    color: Colors.transparent,
    child: InkWell(
      borderRadius: BorderRadius.circular(_DetailUiTokens.actionRadius),
      onTap: onTap,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 180),
        curve: Curves.easeOut,
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
        decoration: BoxDecoration(
          color: bg,
          borderRadius: BorderRadius.circular(_DetailUiTokens.actionRadius),
          border: Border.all(color: borderColor),
        ),
        child: AnimatedSwitcher(
          duration: const Duration(milliseconds: 160),
          switchInCurve: Curves.easeOut,
          switchOutCurve: Curves.easeIn,
          transitionBuilder: (child, animation) => FadeTransition(
            opacity: animation,
            child: ScaleTransition(scale: animation, child: child),
          ),
          child: Row(
            key: ValueKey<String>('$icon|$label|$primary'),
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(icon, size: 18, color: fg),
              const SizedBox(width: 6),
              Text(
                label,
                style: Theme.of(context).textTheme.labelLarge?.copyWith(
                      color: fg,
                      fontWeight: FontWeight.w700,
                    ),
              ),
            ],
          ),
        ),
      ),
    ),
  );
}

Widget _detailGlassPanel({
  required Widget child,
  EdgeInsetsGeometry? padding,
  bool enableBlur = true,
  double radius = 16,
}) {
  final borderRadius = BorderRadius.circular(radius);
  final surface = Container(
    padding: padding,
    decoration: BoxDecoration(
      borderRadius: borderRadius,
      gradient: LinearGradient(
        begin: Alignment.topLeft,
        end: Alignment.bottomRight,
        colors: [
          Colors.black.withValues(alpha: 0.46),
          Colors.black.withValues(alpha: 0.34),
        ],
      ),
      border: Border.all(color: Colors.white.withValues(alpha: 0.20)),
      boxShadow: [
        BoxShadow(
          color: Colors.black.withValues(alpha: 0.22),
          blurRadius: 20,
          offset: const Offset(0, 10),
        ),
      ],
    ),
    child: child,
  );
  if (!enableBlur) return ClipRRect(borderRadius: borderRadius, child: surface);
  return ClipRRect(
    borderRadius: borderRadius,
    child: BackdropFilter(
      filter: ImageFilter.blur(sigmaX: 18, sigmaY: 18),
      child: surface,
    ),
  );
}

class ShowDetailPage extends StatefulWidget {
  const ShowDetailPage({
    super.key,
    required this.itemId,
    required this.title,
    required this.appState,
    this.server,
    this.isTv = false,
  });

  final String itemId;
  final String title;
  final AppState appState;
  final ServerProfile? server;
  final bool isTv;

  @override
  State<ShowDetailPage> createState() => _ShowDetailPageState();
}

class _ShowDetailPageState extends State<ShowDetailPage> {
  MediaItem? _detail;
  List<MediaItem> _seasons = [];
  bool _seasonsVirtual = false;
  List<MediaItem> _similar = [];
  bool _loading = true;
  String? _error;
  MediaItem? _featuredEpisode;
  String? _selectedSeasonId;
  final Map<String, List<MediaItem>> _episodesCache = {};
  List<String> _album = [];
  PlaybackInfoResult? _playInfo;
  List<ChapterInfo> _chapters = [];
  String? _selectedMediaSourceId;
  int? _selectedAudioStreamIndex; // null = default
  int? _selectedSubtitleStreamIndex; // null = default, -1 = off
  bool _localFavorite = false;
  bool _favoriteLoaded = false;

  String? get _baseUrl => widget.server?.baseUrl ?? widget.appState.baseUrl;
  String? get _token => widget.server?.token ?? widget.appState.token;
  String? get _userId => widget.server?.userId ?? widget.appState.userId;

  @override
  void initState() {
    super.initState();
    _loadLocalFavorite();
    _load();
  }

  String get _localFavoriteKey {
    final serverKey = (_baseUrl ?? 'default').replaceAll(RegExp(r'[^a-zA-Z0-9]'), '_');
    return 'show_detail_local_favorite_${serverKey}_${widget.itemId}';
  }

  Future<void> _loadLocalFavorite() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      if (!mounted) return;
      setState(() {
        _localFavorite = prefs.getBool(_localFavoriteKey) ?? false;
        _favoriteLoaded = true;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() => _favoriteLoaded = true);
    }
  }

  Future<void> _toggleLocalFavorite() async {
    final next = !_localFavorite;
    setState(() => _localFavorite = next);
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setBool(_localFavoriteKey, next);
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(next ? '已加入本地收藏' : '已取消本地收藏'),
        ),
      );
    } catch (_) {
      if (!mounted) return;
      setState(() => _localFavorite = !next);
    }
  }

  Future<void> _refreshProgressAfterReturn(
      {Duration delay = const Duration(milliseconds: 350)}) async {
    final access =
        resolveServerAccess(appState: widget.appState, server: widget.server);
    if (access == null) return;

    final before = _detail?.playbackPositionTicks;
    for (var attempt = 0; attempt < 3; attempt++) {
      final attemptDelay =
          attempt == 0 ? delay : const Duration(milliseconds: 300);
      if (attemptDelay > Duration.zero) {
        await Future<void>.delayed(attemptDelay);
      }

      try {
        final detail = await access.adapter
            .fetchItemDetail(access.auth, itemId: widget.itemId);
        if (!mounted) return;
        setState(() => _detail = detail);
        if (before == null || detail.playbackPositionTicks != before) return;
      } catch (_) {
        // Best-effort refresh. Keep existing state on failure.
      }
    }
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    final baseUrl = _baseUrl;
    final token = _token;
    final userId = _userId;
    if (baseUrl == null || token == null || userId == null) {
      setState(() {
        _error = '未连接服务器';
      });
      return;
    }

    final access =
        resolveServerAccess(appState: widget.appState, server: widget.server);
    if (access == null) {
      setState(() {
        _error = 'Unsupported server';
        _loading = false;
      });
      return;
    }
    try {
      final detail = await access.adapter.fetchItemDetail(
        access.auth,
        itemId: widget.itemId,
      );
      final isSeries = detail.type.toLowerCase() == 'series';

      final seasons = isSeries
          ? await access.adapter.fetchSeasons(
              access.auth,
              seriesId: widget.itemId,
            )
          : PagedResult<MediaItem>(const [], 0);

      final seasonItems = isSeries
          ? seasons.items
              .where((s) => s.type.toLowerCase() == 'season')
              .toList()
          : <MediaItem>[];
      seasonItems.sort((a, b) {
        final aNo = a.seasonNumber ?? a.episodeNumber ?? 0;
        final bNo = b.seasonNumber ?? b.episodeNumber ?? 0;
        return aNo.compareTo(bNo);
      });

      final virtualSeason = isSeries && seasonItems.isEmpty;
      final seasonsForUi = isSeries
          ? (virtualSeason
              ? [
                  MediaItem(
                    id: widget.itemId,
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
                    seriesId: widget.itemId,
                    seriesName: detail.name,
                    seasonName: '第1季',
                    seasonNumber: 1,
                    episodeNumber: null,
                    hasImage: detail.hasImage,
                    playbackPositionTicks: 0,
                    people: const [],
                    parentId: widget.itemId,
                  ),
                ]
              : seasonItems)
          : <MediaItem>[];

      MediaItem? firstEp;
      if (isSeries) {
        final previousSeasonId = _selectedSeasonId;
        final defaultSeasonId = (virtualSeason
                ? widget.itemId
                : (seasonItems.isNotEmpty ? seasonItems.first.id : null)) ??
            '';
        final selectedSeasonId = (previousSeasonId != null &&
                seasonsForUi.any((s) => s.id == previousSeasonId))
            ? previousSeasonId
            : defaultSeasonId;

        if (selectedSeasonId.isNotEmpty) {
          try {
            final eps = await access.adapter.fetchEpisodes(
              access.auth,
              seasonId: selectedSeasonId,
            );
            final items = List<MediaItem>.from(eps.items);
            items.sort((a, b) {
              final aNo = a.episodeNumber ?? 0;
              final bNo = b.episodeNumber ?? 0;
              return aNo.compareTo(bNo);
            });
            _episodesCache[selectedSeasonId] = items;
            if (items.isNotEmpty) firstEp = items.first;
          } catch (_) {}
        }
      }
      PagedResult<MediaItem> similar = PagedResult(const [], 0);
      try {
        similar = await access.adapter
            .fetchSimilar(access.auth, itemId: widget.itemId, limit: 12);
      } catch (_) {}

      PlaybackInfoResult? playInfo;
      List<ChapterInfo> chaps = const [];
      String? selectedMediaSourceId = _selectedMediaSourceId;
      int? selectedAudioStreamIndex = _selectedAudioStreamIndex;
      int? selectedSubtitleStreamIndex = _selectedSubtitleStreamIndex;
      if (!isSeries) {
        try {
          playInfo = await access.adapter
              .fetchPlaybackInfo(access.auth, itemId: widget.itemId);
          final sources = playInfo.mediaSources.cast<Map<String, dynamic>>();
          if (sources.isNotEmpty) {
            final validSelection = selectedMediaSourceId != null &&
                sources.any(
                    (s) => (s['Id'] as String? ?? '') == selectedMediaSourceId);
            if (!validSelection) {
              selectedMediaSourceId = _pickPreferredMediaSourceId(
                    sources,
                    widget.appState.preferredVideoVersion,
                  ) ??
                  (sources.first['Id'] as String?);
              selectedAudioStreamIndex = null;
              selectedSubtitleStreamIndex = null;
            }
          }
        } catch (_) {
          // PlaybackInfo is optional for the detail UI.
        }
        try {
          chaps = await access.adapter
              .fetchChapters(access.auth, itemId: widget.itemId);
        } catch (_) {
          // Chapters are optional; hide section when unavailable.
        }
      }
      _album = [
        access.adapter.imageUrl(
          access.auth,
          itemId: widget.itemId,
          imageType: 'Primary',
          maxWidth: 800,
        ),
        access.adapter.imageUrl(
          access.auth,
          itemId: widget.itemId,
          imageType: 'Backdrop',
          maxWidth: 1200,
        ),
      ];
      setState(() {
        _detail = detail;
        _seasons = seasonsForUi;
        _seasonsVirtual = virtualSeason;
        _featuredEpisode = firstEp;
        _selectedSeasonId = isSeries && seasonsForUi.isNotEmpty
            ? ((_selectedSeasonId != null &&
                    seasonsForUi.any((s) => s.id == _selectedSeasonId))
                ? _selectedSeasonId
                : seasonsForUi.first.id)
            : null;
        _similar = similar.items;
        _playInfo = playInfo;
        _chapters = chaps;
        _selectedMediaSourceId = selectedMediaSourceId;
        _selectedAudioStreamIndex = selectedAudioStreamIndex;
        _selectedSubtitleStreamIndex = selectedSubtitleStreamIndex;
      });
    } catch (e) {
      setState(() => _error = e.toString());
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  String _seasonLabel(MediaItem season, int index) {
    final name = season.name.trim();
    final seasonNo = season.seasonNumber ?? season.episodeNumber;
    return seasonNo != null
        ? '第$seasonNo季'
        : (name.isNotEmpty ? name : '第${index + 1}季');
  }

  MediaItem? get _selectedSeason {
    if (_seasons.isEmpty) return null;
    final selectedId = _selectedSeasonId;
    if (selectedId == null || selectedId.isEmpty) return _seasons.first;
    for (final s in _seasons) {
      if (s.id == selectedId) return s;
    }
    return _seasons.first;
  }

  String _selectedSeasonLabel() {
    if (_seasons.isEmpty) return '选择季';
    final selectedId = _selectedSeasonId;
    for (int i = 0; i < _seasons.length; i++) {
      final s = _seasons[i];
      if (selectedId != null && s.id == selectedId) return _seasonLabel(s, i);
    }
    return _seasonLabel(_seasons.first, 0);
  }

  Future<List<MediaItem>> _episodesForSeason(MediaItem season) async {
    final cached = _episodesCache[season.id];
    if (cached != null) return cached;

    final access =
        resolveServerAccess(appState: widget.appState, server: widget.server);
    if (access == null) return const [];

    final eps = await access.adapter.fetchEpisodes(
      access.auth,
      seasonId: season.id,
    );
    final items = List<MediaItem>.from(eps.items);
    items.sort((a, b) {
      final aNo = a.episodeNumber ?? 0;
      final bNo = b.episodeNumber ?? 0;
      return aNo.compareTo(bNo);
    });
    _episodesCache[season.id] = items;
    return items;
  }

  Future<void> _pickSeason(BuildContext context) async {
    if (_seasons.isEmpty) return;

    final selected = await showModalBottomSheet<String>(
      context: context,
      builder: (ctx) {
        return SafeArea(
          child: ListView(
            children: [
              const ListTile(title: Text('季选择')),
              ..._seasons.asMap().entries.map((entry) {
                final idx = entry.key;
                final s = entry.value;
                final selectedNow = s.id == _selectedSeasonId;
                return ListTile(
                  leading: Icon(
                      selectedNow ? Icons.check_circle : Icons.circle_outlined),
                  title: Text(_seasonLabel(s, idx)),
                  onTap: () => Navigator.of(ctx).pop(s.id),
                );
              }),
            ],
          ),
        );
      },
    );

    if (!mounted) return;
    if (selected == null || selected.isEmpty || selected == _selectedSeasonId) {
      return;
    }

    setState(() {
      _selectedSeasonId = selected;
      _featuredEpisode = null;
    });

    final season = _selectedSeason;
    if (season == null) return;
    try {
      final episodes = await _episodesForSeason(season);
      if (!mounted || _selectedSeasonId != selected) return;
      setState(() {
        _featuredEpisode = episodes.isNotEmpty ? episodes.first : null;
      });
    } catch (_) {
      // Episode list is optional for the detail UI.
    }
  }

  String _episodeLabel(MediaItem episode, int index) {
    final epNo = episode.episodeNumber ?? (index + 1);
    final epName = episode.name.trim();
    return epName.isNotEmpty ? '$epNo. $epName' : '$epNo. 第$epNo集';
  }

  Future<void> _pickEpisode(BuildContext context) async {
    final season = _selectedSeason;
    if (season == null) return;

    final seasonLabel = _selectedSeasonLabel();
    final selectedEp = await showModalBottomSheet<MediaItem>(
      context: context,
      isScrollControlled: true,
      builder: (ctx) {
        return SafeArea(
          child: DraggableScrollableSheet(
            expand: false,
            initialChildSize: widget.isTv ? 0.5 : 0.75,
            minChildSize: 0.4,
            maxChildSize: 0.95,
            builder: (ctx, controller) {
              return FutureBuilder<List<MediaItem>>(
                future: _episodesForSeason(season),
                builder: (ctx, snapshot) {
                  if (snapshot.connectionState != ConnectionState.done) {
                    return ListView(
                      controller: controller,
                      children: const [
                        ListTile(title: Text('选集')),
                        SizedBox(height: 24),
                        Center(child: CircularProgressIndicator()),
                      ],
                    );
                  }
                  if (snapshot.hasError) {
                    return ListView(
                      controller: controller,
                      children: [
                        const ListTile(title: Text('选集')),
                        Padding(
                          padding: const EdgeInsets.all(16),
                          child: Text('加载失败：${snapshot.error}'),
                        ),
                      ],
                    );
                  }
                  final eps = snapshot.data ?? const <MediaItem>[];
                  if (eps.isEmpty) {
                    return ListView(
                      controller: controller,
                      children: const [
                        ListTile(title: Text('选集')),
                        Padding(
                          padding: EdgeInsets.all(16),
                          child: Text('暂无剧集'),
                        ),
                      ],
                    );
                  }

                  return ListView.separated(
                    controller: controller,
                    itemCount: eps.length + 1,
                    separatorBuilder: (_, __) => const Divider(height: 1),
                    itemBuilder: (ctx, index) {
                      if (index == 0) {
                        return ListTile(title: Text('选集（$seasonLabel）'));
                      }
                      final epIndex = index - 1;
                      final ep = eps[epIndex];
                      return ListTile(
                        leading: const Icon(Icons.play_circle_outline),
                        title: Text(_episodeLabel(ep, epIndex)),
                        onTap: () => Navigator.of(ctx).pop(ep),
                      );
                    },
                  );
                },
              );
            },
          ),
        );
      },
    );

    if (!context.mounted) return;
    if (selectedEp == null) return;

    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => EpisodeDetailPage(
          episode: selectedEp,
          appState: widget.appState,
          server: widget.server,
          isTv: widget.isTv,
        ),
      ),
    );
  }

  Future<void> _openEpisode(BuildContext context, MediaItem episode) async {
    await Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => EpisodeDetailPage(
          episode: episode,
          appState: widget.appState,
          server: widget.server,
          isTv: widget.isTv,
        ),
      ),
    );
  }

  String _yearText(MediaItem item) {
    final date = (item.premiereDate ?? '').trim();
    if (date.isEmpty) return '';
    final parsed = DateTime.tryParse(date);
    if (parsed != null) return parsed.year.toString();
    if (date.length >= 4) return date.substring(0, 4);
    return '';
  }

  String _episodeTitle(MediaItem ep) {
    final epNo = ep.episodeNumber ?? 1;
    final name = ep.name.trim();
    return name.isNotEmpty ? 'S${ep.seasonNumber ?? 1}:E$epNo - $name' : 'S${ep.seasonNumber ?? 1}:E$epNo';
  }

  void _showTopActionHint(String label) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text('$label 功能待接入')),
    );
  }

  Future<void> _playMovie(MediaItem item) async {
    final start = item.playbackPositionTicks > 0
        ? _ticksToDuration(item.playbackPositionTicks)
        : null;
    final useExoCore = !kIsWeb &&
        defaultTargetPlatform == TargetPlatform.android &&
        widget.appState.playerCore == PlayerCore.exo;
    await Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => useExoCore
            ? ExoPlayNetworkPage(
                title: item.name,
                itemId: item.id,
                appState: widget.appState,
                server: widget.server,
                isTv: widget.isTv,
                startPosition: start,
                mediaSourceId: _selectedMediaSourceId,
                audioStreamIndex: _selectedAudioStreamIndex,
                subtitleStreamIndex: _selectedSubtitleStreamIndex,
              )
            : PlayNetworkPage(
                title: item.name,
                itemId: item.id,
                appState: widget.appState,
                server: widget.server,
                isTv: widget.isTv,
                startPosition: start,
                mediaSourceId: _selectedMediaSourceId,
                audioStreamIndex: _selectedAudioStreamIndex,
                subtitleStreamIndex: _selectedSubtitleStreamIndex,
              ),
      ),
    );
    if (!mounted) return;
    await _refreshProgressAfterReturn();
  }

  Widget _heroActionButton(
    BuildContext context, {
    required IconData icon,
    required String label,
    required VoidCallback? onTap,
    bool primary = false,
  }) {
    return _detailActionButton(
      context,
      icon: icon,
      label: label,
      onTap: onTap,
      primary: primary,
    );
  }

  Widget _topNavOverlay(BuildContext context) {
    return SafeArea(
      bottom: false,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(8, 6, 8, 0),
        child: IconTheme(
          data: const IconThemeData(color: Colors.white),
          child: Row(
            children: [
              IconButton(
                onPressed: () {
                  if (Navigator.of(context).canPop()) {
                    Navigator.of(context).pop();
                  }
                },
                icon: const Icon(Icons.arrow_back),
              ),
              IconButton(
                onPressed: () =>
                    Navigator.of(context).popUntil((r) => r.isFirst),
                icon: const Icon(Icons.home),
              ),
              IconButton(
                onPressed: () => _showTopActionHint('菜单'),
                icon: const Icon(Icons.menu),
              ),
              const Spacer(),
              IconButton(
                onPressed: () => _showTopActionHint('投屏'),
                icon: const Icon(Icons.cast),
              ),
              IconButton(
                onPressed: () => _showTopActionHint('搜索'),
                icon: const Icon(Icons.search),
              ),
              IconButton(
                onPressed: () => _showTopActionHint('设置'),
                icon: const Icon(Icons.settings),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _detailHeroSection(
    BuildContext context, {
    required MediaItem item,
    required ServerAccess? access,
    required bool isSeries,
    required Duration? runtime,
  }) {
    final theme = Theme.of(context);
    final width = MediaQuery.of(context).size.width;
    final wide = width >= 980;
    const heroTextColor = Colors.white;
    final heroMutedTextColor = Colors.white.withValues(alpha: 0.88);
    final heroMetaBg = Colors.black.withValues(alpha: 0.32);
    final heroMetaBorder = Colors.white.withValues(alpha: 0.22);
    final posterUrl = access == null
        ? ''
        : access.adapter.imageUrl(
            access.auth,
            itemId: item.id,
            imageType: 'Primary',
            maxWidth: 720,
          );
    final year = _yearText(item);
    final meta = <String>[
      if (item.communityRating != null)
        '★ ${item.communityRating!.toStringAsFixed(1)}',
      if (year.isNotEmpty) year,
      'MBS',
      'SG-PG13',
      if (isSeries) '共${_seasons.length}季',
      if (!isSeries && runtime != null) _fmt(runtime),
    ];
    final featuredLabel = _featuredEpisode == null ? '' : _episodeTitle(_featuredEpisode!);

    final posterCard = SizedBox(
      width: wide ? 290 : 220,
      child: Stack(
        children: [
          Container(
            padding: const EdgeInsets.all(4),
            decoration: BoxDecoration(
              color: Colors.pinkAccent.withValues(alpha: 0.82),
              borderRadius:
                  BorderRadius.circular(_DetailUiTokens.heroPosterRadius),
              boxShadow: [
                BoxShadow(
                  color: Colors.black.withValues(alpha: 0.25),
                  blurRadius: 24,
                  spreadRadius: 1,
                ),
              ],
            ),
            child: ClipRRect(
              borderRadius: BorderRadius.circular(_DetailUiTokens.cardRadius),
              child: AspectRatio(
                aspectRatio: 2 / 3,
                child: posterUrl.isEmpty
                    ? const ColoredBox(color: Colors.black26)
                    : Image.network(
                        posterUrl,
                        fit: BoxFit.cover,
                        headers: {'User-Agent': LinHttpClientFactory.userAgent},
                        errorBuilder: (_, __, ___) =>
                            const ColoredBox(color: Colors.black26),
                      ),
              ),
            ),
          ),
          Positioned(
            top: 10,
            left: 10,
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
              decoration: BoxDecoration(
                color: Colors.green.withValues(alpha: 0.9),
                borderRadius: BorderRadius.circular(999),
              ),
              child: Text(
                item.communityRating?.toStringAsFixed(1) ?? '--',
                style: Theme.of(context).textTheme.labelMedium?.copyWith(
                      color: Colors.white,
                      fontWeight: FontWeight.w700,
                    ),
              ),
            ),
          ),
          Positioned(
            top: 8,
            right: 8,
            child: Material(
              color: Colors.black.withValues(alpha: 0.55),
              borderRadius: BorderRadius.circular(999),
              child: IconButton(
                onPressed: _favoriteLoaded ? _toggleLocalFavorite : null,
                icon: Icon(
                  _localFavorite ? Icons.star : Icons.star_border_rounded,
                  color: _localFavorite ? Colors.pinkAccent : heroTextColor,
                ),
              ),
            ),
          ),
        ],
      ),
    );

    final infoContent = Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          item.name,
          style: (wide ? theme.textTheme.headlineMedium : theme.textTheme.headlineSmall)
              ?.copyWith(
                color: heroTextColor,
                fontWeight: FontWeight.w800,
              ),
        ),
        const SizedBox(height: 8),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: meta
              .map(
                (m) => Container(
                  padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                  decoration: BoxDecoration(
                    color: heroMetaBg,
                    borderRadius: BorderRadius.circular(999),
                    border: Border.all(color: heroMetaBorder),
                  ),
                  child: Text(
                    m,
                    style: theme.textTheme.labelMedium?.copyWith(
                          color: heroTextColor,
                        ),
                  ),
                ),
              )
              .toList(),
        ),
        const SizedBox(height: 8),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: item.genres
              .take(3)
              .map((g) => _pill(context, g))
              .toList(),
        ),
        const SizedBox(height: 14),
        Wrap(
          spacing: 10,
          runSpacing: 10,
          children: [
            _heroActionButton(
              context,
              icon: Icons.play_arrow,
              label: '播放',
              primary: true,
              onTap: isSeries
                  ? (_featuredEpisode == null
                      ? null
                      : () => _openEpisode(context, _featuredEpisode!))
                  : () => _playMovie(item),
            ),
            _heroActionButton(
              context,
              icon: item.played ? Icons.check_circle : Icons.radio_button_unchecked,
              label: item.played ? '已播放' : '未播放',
              onTap: null,
            ),
            _heroActionButton(
              context,
              icon: _localFavorite ? Icons.favorite : Icons.favorite_border,
              label: _localFavorite ? '已收藏' : '收藏',
              onTap: _favoriteLoaded ? _toggleLocalFavorite : null,
            ),
            _heroActionButton(
              context,
              icon: Icons.more_horiz,
              label: '更多',
              onTap: () => _showTopActionHint('更多'),
            ),
          ],
        ),
        if (featuredLabel.isNotEmpty) ...[
          const SizedBox(height: 16),
          Text(
            featuredLabel,
            style: theme.textTheme.titleSmall?.copyWith(
                  color: heroTextColor,
                  fontWeight: FontWeight.w700,
                ),
          ),
        ],
        const SizedBox(height: 8),
        Text(
          item.overview,
          maxLines: 4,
          overflow: TextOverflow.ellipsis,
          style: theme.textTheme.bodyMedium?.copyWith(
                color: heroMutedTextColor,
                height: 1.45,
              ),
        ),
      ],
    );

    final logoText = Text(
      item.name,
      maxLines: 1,
      overflow: TextOverflow.ellipsis,
      style: theme.textTheme.headlineSmall?.copyWith(
            color: heroTextColor,
            fontWeight: FontWeight.w900,
            shadows: const [
              Shadow(color: Colors.black54, blurRadius: 10),
            ],
          ),
    );

    final infoPanel = wide
        ? Stack(
            children: [
              Padding(
                padding: const EdgeInsets.only(right: 240),
                child: infoContent,
              ),
              Positioned(
                right: 0,
                top: 8,
                child: SizedBox(width: 220, child: logoText),
              ),
            ],
          )
        : Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              infoContent,
              const SizedBox(height: 12),
              logoText,
            ],
          );

    return _detailGlassPanel(
      enableBlur: !widget.isTv && widget.appState.enableBlurEffects,
      padding: _DetailUiTokens.panelPadding,
      child: wide
          ? Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                posterCard,
                const SizedBox(width: 18),
                Expanded(child: infoPanel),
              ],
            )
          : Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Align(alignment: Alignment.centerLeft, child: posterCard),
                const SizedBox(height: 16),
                infoPanel,
              ],
            ),
    );
  }

  Widget _unwatchedEpisodesSection(
    BuildContext context, {
    required MediaItem seriesItem,
    required ServerAccess? access,
  }) {
    final season = _selectedSeason;
    if (season == null) return const SizedBox.shrink();

    return FutureBuilder<List<MediaItem>>(
      future: _episodesForSeason(season),
      builder: (context, snapshot) {
        if (snapshot.connectionState != ConnectionState.done) {
          return const SizedBox(
            height: 200,
            child: Center(child: CircularProgressIndicator()),
          );
        }
        if (snapshot.hasError) {
          return Text(
            '加载剧集失败：${snapshot.error}',
            style: Theme.of(context).textTheme.bodySmall,
          );
        }

        final episodes = snapshot.data ?? const <MediaItem>[];
        final unwatched = episodes.where((ep) => !ep.played).toList();
        if (unwatched.isEmpty) {
          return Text(
            '暂无未观看剧集',
            style: Theme.of(context).textTheme.bodySmall,
          );
        }

        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _sectionTitle(context, '尚未观看'),
            const SizedBox(height: 8),
            SizedBox(
              height: _DetailUiTokens.horizontalEpisodeStripHeight,
              child: _withHorizontalEdgeFade(
                context,
                child: ListView.separated(
                  scrollDirection: Axis.horizontal,
                  padding: const EdgeInsets.symmetric(horizontal: 2),
                  itemCount: unwatched.length,
                  separatorBuilder: (_, __) =>
                      const SizedBox(width: _DetailUiTokens.horizontalGap),
                  itemBuilder: (context, index) {
                    final ep = unwatched[index];
                    final epNo = ep.episodeNumber ?? (index + 1);
                    final seasonNo = ep.seasonNumber ?? season.seasonNumber ?? 1;
                    final imageUrl = access == null
                        ? ''
                        : access.adapter.imageUrl(
                            access.auth,
                            itemId: ep.hasImage
                                ? ep.id
                                : (season.id.isNotEmpty ? season.id : seriesItem.id),
                            maxWidth: 640,
                          );
                    return _HoverScale(
                      child: SizedBox(
                        width: _DetailUiTokens.horizontalEpisodeCardWidth,
                        child: Material(
                          color: Colors.transparent,
                          child: InkWell(
                            onTap: () => _openEpisode(context, ep),
                            borderRadius:
                                BorderRadius.circular(_DetailUiTokens.cardRadius),
                            child: Ink(
                              decoration: BoxDecoration(
                                color: Theme.of(context)
                                    .colorScheme
                                    .surfaceContainerHighest
                                    .withValues(alpha: 0.28),
                                borderRadius:
                                    BorderRadius.circular(_DetailUiTokens.cardRadius),
                                border: Border.all(
                                  color: Theme.of(context)
                                      .colorScheme
                                      .outlineVariant
                                      .withValues(alpha: 0.35),
                                ),
                              ),
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  ClipRRect(
                                    borderRadius: const BorderRadius.vertical(
                                      top: Radius.circular(
                                          _DetailUiTokens.cardRadius),
                                    ),
                                    child: AspectRatio(
                                      aspectRatio: 16 / 9,
                                      child: Stack(
                                        fit: StackFit.expand,
                                        children: [
                                          imageUrl.isEmpty
                                              ? const ColoredBox(
                                                  color: Colors.black26,
                                                )
                                              : Image.network(
                                                  imageUrl,
                                                  fit: BoxFit.cover,
                                                  headers: {
                                                    'User-Agent':
                                                        LinHttpClientFactory
                                                            .userAgent,
                                                  },
                                                  errorBuilder: (_, __, ___) =>
                                                      const ColoredBox(
                                                    color: Colors.black26,
                                                  ),
                                                ),
                                          Align(
                                            alignment: Alignment.bottomCenter,
                                            child: DecoratedBox(
                                              decoration: BoxDecoration(
                                                gradient: LinearGradient(
                                                  begin: Alignment.topCenter,
                                                  end: Alignment.bottomCenter,
                                                  colors: [
                                                    Colors.transparent,
                                                    Colors.black.withValues(
                                                        alpha: 0.78),
                                                  ],
                                                ),
                                              ),
                                              child: const SizedBox(
                                                width: double.infinity,
                                                height: 52,
                                              ),
                                            ),
                                          ),
                                        ],
                                      ),
                                    ),
                                  ),
                                  Padding(
                                    padding: const EdgeInsets.fromLTRB(
                                        10, 8, 10, 10),
                                    child: Column(
                                      crossAxisAlignment:
                                          CrossAxisAlignment.start,
                                      children: [
                                        Text(
                                          'S$seasonNo:E$epNo',
                                          style: Theme.of(context)
                                              .textTheme
                                              .labelMedium,
                                        ),
                                        const SizedBox(height: 4),
                                        Text(
                                          ep.name.trim().isNotEmpty
                                              ? ep.name.trim()
                                              : '第$epNo集',
                                          maxLines: 1,
                                          overflow: TextOverflow.ellipsis,
                                          style: Theme.of(context)
                                              .textTheme
                                              .bodyMedium
                                              ?.copyWith(
                                                fontWeight: FontWeight.w600,
                                              ),
                                        ),
                                      ],
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          ),
                        ),
                      ),
                    );
                  },
                ),
              ),
            ),
          ],
        );
      },
    );
  }

  Widget _seasonEpisodeControlPanel(
    BuildContext context, {
    required bool enableBlur,
  }) {
    if (_seasons.isEmpty) return const SizedBox.shrink();
    return _detailGlassPanel(
      enableBlur: enableBlur,
      padding: const EdgeInsets.all(12),
      child: Row(
        children: [
          Expanded(
            child: OutlinedButton(
              onPressed: () => _pickSeason(context),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  const Icon(Icons.layers_outlined, size: 18),
                  const SizedBox(width: 8),
                  Flexible(
                    child: Text(
                      '季：${_selectedSeasonLabel()}',
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                  const SizedBox(width: 4),
                  const Icon(Icons.arrow_drop_down),
                ],
              ),
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: OutlinedButton(
              onPressed: _selectedSeason == null ? null : () => _pickEpisode(context),
              child: const Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Icon(Icons.format_list_numbered, size: 18),
                  SizedBox(width: 8),
                  Text('选集'),
                  SizedBox(width: 4),
                  Icon(Icons.arrow_drop_down),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  static int? _asInt(dynamic value) {
    if (value is int) return value;
    if (value is num) return value.toInt();
    if (value is String) return int.tryParse(value);
    return null;
  }

  static Map<String, dynamic>? _findMediaSource(
      PlaybackInfoResult info, String? id) {
    final sources = info.mediaSources.cast<Map<String, dynamic>>();
    if (sources.isEmpty) return null;
    if (id != null && id.isNotEmpty) {
      for (final s in sources) {
        if ((s['Id'] as String? ?? '') == id) return s;
      }
    }
    return sources.first;
  }

  static List<Map<String, dynamic>> _streamsOfType(
      Map<String, dynamic> ms, String type) {
    final streams = (ms['MediaStreams'] as List?) ?? const [];
    return streams
        .where((e) => (e as Map)['Type'] == type)
        .map((e) => e as Map<String, dynamic>)
        .toList();
  }

  static Map<String, dynamic>? _defaultStream(
      List<Map<String, dynamic>> streams) {
    for (final s in streams) {
      if (s['IsDefault'] == true) return s;
    }
    return streams.isNotEmpty ? streams.first : null;
  }

  static String _streamLabel(Map<String, dynamic> stream,
      {bool includeCodec = true}) {
    final title = (stream['DisplayTitle'] as String?) ??
        (stream['Title'] as String?) ??
        (stream['Language'] as String?) ??
        '未知';
    final codec = (stream['Codec'] as String?) ?? '';
    return includeCodec && codec.isNotEmpty ? '$title ($codec)' : title;
  }

  static String _mediaSourceTitle(Map<String, dynamic> ms) {
    return (ms['Name'] as String?) ?? (ms['Container'] as String?) ?? '默认版本';
  }

  static int _compareMediaSourcesByQuality(
    Map<String, dynamic> a,
    Map<String, dynamic> b,
  ) {
    int heightOf(Map<String, dynamic> ms) {
      final videoStreams = _streamsOfType(ms, 'Video');
      final video = videoStreams.isNotEmpty ? videoStreams.first : null;
      return _asInt(video?['Height']) ?? 0;
    }

    int bitrateOf(Map<String, dynamic> ms) => _asInt(ms['Bitrate']) ?? 0;

    int sizeOf(Map<String, dynamic> ms) {
      final v = ms['Size'];
      if (v is int) return v;
      if (v is num) return v.toInt();
      if (v is String) return int.tryParse(v) ?? 0;
      return 0;
    }

    final h = heightOf(b) - heightOf(a);
    if (h != 0) return h;
    final br = bitrateOf(b) - bitrateOf(a);
    if (br != 0) return br;
    return sizeOf(b) - sizeOf(a);
  }

  static String? _pickPreferredMediaSourceId(
    List<Map<String, dynamic>> sources,
    VideoVersionPreference pref,
  ) {
    if (pref == VideoVersionPreference.defaultVersion) return null;

    int heightOf(Map<String, dynamic> ms) {
      final videos = _streamsOfType(ms, 'Video');
      final video = videos.isNotEmpty ? videos.first : null;
      return _asInt(video?['Height']) ?? 0;
    }

    int bitrateOf(Map<String, dynamic> ms) => _asInt(ms['Bitrate']) ?? 0;

    String codecOf(Map<String, dynamic> ms) {
      final videos = _streamsOfType(ms, 'Video');
      final video = videos.isNotEmpty ? videos.first : null;
      return ((ms['VideoCodec'] as String?) ??
              (video?['Codec'] as String?) ??
              '')
          .toLowerCase();
    }

    bool isHevc(Map<String, dynamic> ms) {
      final c = codecOf(ms);
      return c.contains('hevc') || c.contains('h265') || c.contains('x265');
    }

    bool isAvc(Map<String, dynamic> ms) {
      final c = codecOf(ms);
      return c.contains('h264') || c.contains('avc') || c.contains('x264');
    }

    Map<String, dynamic> pickBest(
      Iterable<Map<String, dynamic>> list, {
      required int Function(Map<String, dynamic>) primary,
      required int Function(Map<String, dynamic>) secondary,
      required bool higherIsBetter,
    }) {
      return list.reduce((a, b) {
        final ap = primary(a);
        final bp = primary(b);
        if (ap != bp) {
          return (higherIsBetter ? ap > bp : ap < bp) ? a : b;
        }
        final as = secondary(a);
        final bs = secondary(b);
        if (as != bs) {
          return (higherIsBetter ? as > bs : as < bs) ? a : b;
        }
        return a;
      });
    }

    Map<String, dynamic>? chosen;
    switch (pref) {
      case VideoVersionPreference.highestResolution:
        chosen = pickBest(
          sources,
          primary: heightOf,
          secondary: bitrateOf,
          higherIsBetter: true,
        );
        break;
      case VideoVersionPreference.lowestBitrate:
        chosen = pickBest(
          sources,
          primary: (ms) => bitrateOf(ms) == 0 ? 1 << 30 : bitrateOf(ms),
          secondary: heightOf,
          higherIsBetter: false,
        );
        break;
      case VideoVersionPreference.preferHevc:
        final hevc = sources.where(isHevc).toList();
        chosen = pickBest(
          hevc.isNotEmpty ? hevc : sources,
          primary: heightOf,
          secondary: bitrateOf,
          higherIsBetter: true,
        );
        break;
      case VideoVersionPreference.preferAvc:
        final avc = sources.where(isAvc).toList();
        chosen = pickBest(
          avc.isNotEmpty ? avc : sources,
          primary: heightOf,
          secondary: bitrateOf,
          higherIsBetter: true,
        );
        break;
      case VideoVersionPreference.defaultVersion:
        break;
    }

    final id = chosen?['Id']?.toString();
    return (id == null || id.trim().isEmpty) ? null : id.trim();
  }

  String _mediaSourceSubtitle(Map<String, dynamic> ms) {
    final size = ms['Size'];
    final sizeGb =
        size is num ? (size / (1024 * 1024 * 1024)).toStringAsFixed(1) : null;
    final bitrate = _asInt(ms['Bitrate']);
    final bitrateMbps =
        bitrate != null ? (bitrate / 1000000).toStringAsFixed(1) : null;

    final videoStreams = _streamsOfType(ms, 'Video');
    final video = videoStreams.isNotEmpty ? videoStreams.first : null;
    final height = _asInt(video?['Height']);
    final vCodec =
        (ms['VideoCodec'] as String?) ?? (video?['Codec'] as String?);

    final parts = <String>[];
    if (height != null) parts.add('${height}p');
    if (vCodec != null && vCodec.isNotEmpty) parts.add(vCodec.toUpperCase());
    if (sizeGb != null) parts.add('$sizeGb GB');
    if (bitrateMbps != null) parts.add('$bitrateMbps Mbps');
    return parts.isEmpty ? '直连播放' : parts.join(' / ');
  }

  Widget _floatingPlaybackSettingsDock(
    BuildContext context,
    PlaybackInfoResult info, {
    required bool enableBlur,
  }) {
    final ms = _findMediaSource(info, _selectedMediaSourceId);
    if (ms == null) return const SizedBox.shrink();

    final audioStreams = _streamsOfType(ms, 'Audio');
    final subtitleStreams = _streamsOfType(ms, 'Subtitle');

    final defaultAudio = _defaultStream(audioStreams);
    final selectedAudio = _selectedAudioStreamIndex != null
        ? audioStreams.firstWhere(
            (s) => _asInt(s['Index']) == _selectedAudioStreamIndex,
            orElse: () => defaultAudio ?? const <String, dynamic>{},
          )
        : defaultAudio;

    final audioText = selectedAudio != null && selectedAudio.isNotEmpty
        ? _streamLabel(selectedAudio, includeCodec: false) +
            (selectedAudio == defaultAudio ? ' (默认)' : '')
        : '默认';

    final defaultSub = _defaultStream(subtitleStreams);
    final Map<String, dynamic>? selectedSub;
    if (_selectedSubtitleStreamIndex == -1) {
      selectedSub = null;
    } else if (_selectedSubtitleStreamIndex != null) {
      selectedSub = subtitleStreams.firstWhere(
        (s) => _asInt(s['Index']) == _selectedSubtitleStreamIndex,
        orElse: () => defaultSub ?? const <String, dynamic>{},
      );
    } else {
      selectedSub = defaultSub;
    }

    final hasSubs = subtitleStreams.isNotEmpty;
    final subtitleText = _selectedSubtitleStreamIndex == -1
        ? '关闭'
        : selectedSub != null && selectedSub.isNotEmpty
            ? _streamLabel(selectedSub, includeCodec: false)
            : hasSubs
                ? '默认'
                : '关闭';

    final scheme = Theme.of(context).colorScheme;
    final disabledColor = scheme.onSurface.withValues(alpha: 0.38);

    const radius = 24.0;
    final dividerColor = scheme.outlineVariant.withValues(alpha: 0.35);

    Widget divider() => Container(width: 1, height: 26, color: dividerColor);

    Widget segment({
      required IconData icon,
      required String tooltip,
      required VoidCallback? onTap,
      required BorderRadius borderRadius,
    }) {
      final enabled = onTap != null;
      return Tooltip(
        message: tooltip,
        child: InkWell(
          onTap: onTap,
          borderRadius: borderRadius,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
            child: Icon(
              icon,
              size: 20,
              color: enabled ? scheme.onSurface : disabledColor,
            ),
          ),
        ),
      );
    }

    return FrostedCard(
      enableBlur: enableBlur,
      borderRadius: radius,
      padding: EdgeInsets.zero,
      child: Material(
        type: MaterialType.transparency,
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            segment(
              icon: Icons.video_file_outlined,
              tooltip:
                  '版本：${_mediaSourceTitle(ms)}\n${_mediaSourceSubtitle(ms)}',
              onTap: () => _pickMediaSource(context, info),
              borderRadius:
                  const BorderRadius.horizontal(left: Radius.circular(radius)),
            ),
            divider(),
            segment(
              icon: Icons.audiotrack,
              tooltip: '音轨：$audioText',
              onTap: audioStreams.isEmpty
                  ? null
                  : () => _pickAudioStream(context, ms),
              borderRadius: BorderRadius.zero,
            ),
            divider(),
            segment(
              icon: Icons.subtitles,
              tooltip: '字幕：$subtitleText',
              onTap: hasSubs ? () => _pickSubtitleStream(context, ms) : null,
              borderRadius:
                  const BorderRadius.horizontal(right: Radius.circular(radius)),
            ),
          ],
        ),
      ),
    );
  }

  Widget _moviePlaybackOptionsCard(
      BuildContext context, PlaybackInfoResult info) {
    final ms = _findMediaSource(info, _selectedMediaSourceId);
    if (ms == null) return const SizedBox.shrink();

    final audioStreams = _streamsOfType(ms, 'Audio');
    final subtitleStreams = _streamsOfType(ms, 'Subtitle');

    final defaultAudio = _defaultStream(audioStreams);
    final selectedAudio = _selectedAudioStreamIndex != null
        ? audioStreams.firstWhere(
            (s) => _asInt(s['Index']) == _selectedAudioStreamIndex,
            orElse: () => defaultAudio ?? const <String, dynamic>{},
          )
        : defaultAudio;

    final defaultSub = _defaultStream(subtitleStreams);
    final Map<String, dynamic>? selectedSub;
    if (_selectedSubtitleStreamIndex == -1) {
      selectedSub = null;
    } else if (_selectedSubtitleStreamIndex != null) {
      selectedSub = subtitleStreams.firstWhere(
        (s) => _asInt(s['Index']) == _selectedSubtitleStreamIndex,
        orElse: () => defaultSub ?? const <String, dynamic>{},
      );
    } else {
      selectedSub = defaultSub;
    }

    final hasSubs = subtitleStreams.isNotEmpty;
    final subtitleText = _selectedSubtitleStreamIndex == -1
        ? '关闭'
        : selectedSub != null && selectedSub.isNotEmpty
            ? _streamLabel(selectedSub, includeCodec: false)
            : hasSubs
                ? '默认'
                : '关闭';

    final audioText = selectedAudio != null && selectedAudio.isNotEmpty
        ? _streamLabel(selectedAudio, includeCodec: false) +
            (selectedAudio == defaultAudio ? ' (默认)' : '')
        : '默认';

    return Card(
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          ListTile(
            leading: const Icon(Icons.video_file),
            title: Text(_mediaSourceTitle(ms)),
            subtitle: Text(_mediaSourceSubtitle(ms)),
            trailing: const Icon(Icons.arrow_drop_down),
            onTap: () => _pickMediaSource(context, info),
          ),
          const Divider(height: 1),
          ListTile(
            leading: const Icon(Icons.audiotrack),
            title: Text(audioText),
            trailing: const Icon(Icons.arrow_drop_down),
            onTap: audioStreams.isEmpty
                ? null
                : () => _pickAudioStream(context, ms),
          ),
          const Divider(height: 1),
          ListTile(
            leading: const Icon(Icons.subtitles),
            title: Text(subtitleText),
            trailing: const Icon(Icons.arrow_drop_down),
            onTap: hasSubs ? () => _pickSubtitleStream(context, ms) : null,
          ),
        ],
      ),
    );
  }

  Future<void> _pickMediaSource(
      BuildContext context, PlaybackInfoResult info) async {
    final sources = info.mediaSources.cast<Map<String, dynamic>>();
    if (sources.isEmpty) return;

    final sortedSources = List<Map<String, dynamic>>.from(sources)
      ..sort(_compareMediaSourcesByQuality);

    final selected = await showModalBottomSheet<String>(
      context: context,
      builder: (ctx) {
        return SafeArea(
          child: ListView(
            children: [
              const ListTile(title: Text('版本选择')),
              ...sortedSources.map((ms) {
                final id = ms['Id'] as String? ?? '';
                final selectedNow =
                    id.isNotEmpty && id == _selectedMediaSourceId;
                return ListTile(
                  leading: Icon(
                      selectedNow ? Icons.check_circle : Icons.circle_outlined),
                  title: Text(_mediaSourceTitle(ms)),
                  subtitle: Text(_mediaSourceSubtitle(ms)),
                  onTap: () => Navigator.of(ctx).pop(id),
                );
              }),
            ],
          ),
        );
      },
    );

    if (!mounted) return;
    if (selected == null || selected.isEmpty) return;
    setState(() {
      _selectedMediaSourceId = selected;
      // Streams differ between sources; reset to defaults.
      _selectedAudioStreamIndex = null;
      _selectedSubtitleStreamIndex = null;
    });
  }

  Future<void> _pickAudioStream(
      BuildContext context, Map<String, dynamic> ms) async {
    final audioStreams = _streamsOfType(ms, 'Audio');
    if (audioStreams.isEmpty) return;

    final selected = await showModalBottomSheet<int?>(
      context: context,
      builder: (ctx) {
        final def = _defaultStream(audioStreams);
        final defIndex = _asInt(def?['Index']);
        return SafeArea(
          child: ListView(
            children: [
              const ListTile(title: Text('音轨选择')),
              ListTile(
                leading: Icon(_selectedAudioStreamIndex == null
                    ? Icons.check
                    : Icons.circle_outlined),
                title: const Text('默认'),
                onTap: () => Navigator.of(ctx).pop(null),
              ),
              ...audioStreams.map((s) {
                final idx = _asInt(s['Index']);
                final selectedNow =
                    idx != null && idx == _selectedAudioStreamIndex;
                final title = _streamLabel(s, includeCodec: false);
                return ListTile(
                  leading: Icon(
                      selectedNow ? Icons.check_circle : Icons.circle_outlined),
                  title: Text(idx == defIndex ? '$title (默认)' : title),
                  subtitle: (s['Codec'] as String?)?.isNotEmpty == true
                      ? Text(s['Codec'] as String)
                      : null,
                  onTap: idx == null ? null : () => Navigator.of(ctx).pop(idx),
                );
              }),
            ],
          ),
        );
      },
    );

    if (!mounted) return;
    setState(() => _selectedAudioStreamIndex = selected);
  }

  Future<void> _pickSubtitleStream(
      BuildContext context, Map<String, dynamic> ms) async {
    final subtitleStreams = _streamsOfType(ms, 'Subtitle');
    if (subtitleStreams.isEmpty) return;

    final selected = await showModalBottomSheet<int?>(
      context: context,
      builder: (ctx) {
        final def = _defaultStream(subtitleStreams);
        final defIndex = _asInt(def?['Index']);
        final isOff = _selectedSubtitleStreamIndex == -1;
        final isDefault = _selectedSubtitleStreamIndex == null;
        return SafeArea(
          child: ListView(
            children: [
              const ListTile(title: Text('字幕选择')),
              ListTile(
                leading: Icon(isOff ? Icons.check : Icons.circle_outlined),
                title: const Text('关闭'),
                onTap: () => Navigator.of(ctx).pop(-1),
              ),
              ListTile(
                leading: Icon(isDefault ? Icons.check : Icons.circle_outlined),
                title: const Text('默认'),
                onTap: () => Navigator.of(ctx).pop(null),
              ),
              ...subtitleStreams.map((s) {
                final idx = _asInt(s['Index']);
                final selectedNow =
                    idx != null && idx == _selectedSubtitleStreamIndex;
                final title = _streamLabel(s, includeCodec: false);
                return ListTile(
                  leading: Icon(
                      selectedNow ? Icons.check_circle : Icons.circle_outlined),
                  title: Text(idx == defIndex ? '$title (默认)' : title),
                  subtitle: (s['Codec'] as String?)?.isNotEmpty == true
                      ? Text(s['Codec'] as String)
                      : null,
                  onTap: idx == null ? null : () => Navigator.of(ctx).pop(idx),
                );
              }),
            ],
          ),
        );
      },
    );

    if (!mounted) return;
    setState(() => _selectedSubtitleStreamIndex = selected);
  }

  @override
  Widget build(BuildContext context) {
    if (_loading) {
      return const Scaffold(body: Center(child: CircularProgressIndicator()));
    }
    final enableBlur = !widget.isTv && widget.appState.enableBlurEffects;
    if (_error != null || _detail == null) {
      return Scaffold(
        appBar: GlassAppBar(
          enableBlur: enableBlur,
          child: AppBar(title: Text(widget.title)),
        ),
        body: Center(child: Text(_error ?? '加载失败')),
      );
    }
    final item = _detail!;
    final access = resolveServerAccess(
      appState: widget.appState,
      server: widget.server,
    );
    final isSeries = item.type.toLowerCase() == 'series';
    final playInfo = _playInfo;
    final showFloatingSettings = !widget.isTv &&
        !isSeries &&
        playInfo != null &&
        _findMediaSource(playInfo, _selectedMediaSourceId) != null;
    final runtime = item.runTimeTicks != null
        ? Duration(microseconds: item.runTimeTicks! ~/ 10)
        : null;
    final heroBackdrop = (access == null)
        ? ''
        : access.adapter.imageUrl(
            access.auth,
            itemId: item.id,
            imageType: 'Backdrop',
            maxWidth: 1600,
          );
    final heroPrimary = (access == null)
        ? ''
        : access.adapter.imageUrl(
            access.auth,
            itemId: item.id,
            imageType: 'Primary',
            maxWidth: 1200,
          );
    final hero = heroBackdrop.isNotEmpty ? heroBackdrop : heroPrimary;
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final style = theme.extension<AppStyle>() ?? const AppStyle();
    final template = style.template;
    final isDark = scheme.brightness == Brightness.dark;

    const grayscale = ColorFilter.matrix(<double>[
      0.2126, 0.7152, 0.0722, 0, 0, //
      0.2126, 0.7152, 0.0722, 0, 0, //
      0.2126, 0.7152, 0.0722, 0, 0, //
      0, 0, 0, 1, 0, //
    ]);

    final heroFilter = switch (template) {
      UiTemplate.mangaStoryboard => grayscale,
      UiTemplate.neonHud => ColorFilter.mode(
          scheme.primary.withValues(alpha: isDark ? 0.18 : 0.12),
          BlendMode.overlay,
        ),
      UiTemplate.pixelArcade => ColorFilter.mode(
          scheme.secondary.withValues(alpha: isDark ? 0.18 : 0.12),
          BlendMode.overlay,
        ),
      UiTemplate.candyGlass => ColorFilter.mode(
          scheme.secondary.withValues(alpha: isDark ? 0.10 : 0.08),
          BlendMode.softLight,
        ),
      UiTemplate.stickerJournal => ColorFilter.mode(
          scheme.secondary.withValues(alpha: isDark ? 0.10 : 0.08),
          BlendMode.softLight,
        ),
      UiTemplate.washiWatercolor => ColorFilter.mode(
          scheme.tertiary.withValues(alpha: isDark ? 0.10 : 0.08),
          BlendMode.softLight,
        ),
      UiTemplate.proTool => null,
      UiTemplate.minimalCovers => null,
    };

    final scrimBottom = Colors.black.withValues(alpha: 0.72);

    const heroTitleColor = Colors.white;

    Widget heroImage = hero.isEmpty
        ? const ColoredBox(color: Colors.black26)
        : Image.network(
            hero,
            fit: BoxFit.cover,
            headers: {'User-Agent': LinHttpClientFactory.userAgent},
            errorBuilder: (_, __, ___) =>
                const ColoredBox(color: Colors.black26),
          );
    if (heroFilter != null) {
      heroImage = ColorFiltered(colorFilter: heroFilter, child: heroImage);
    }

    return Scaffold(
      body: Stack(
        children: [
          RefreshIndicator(
            onRefresh: _load,
            child: CustomScrollView(
              slivers: [
                SliverAppBar(
                  automaticallyImplyLeading: false,
                  backgroundColor: Colors.transparent,
                  surfaceTintColor: Colors.transparent,
                  elevation: 0,
                  pinned: true,
                  expandedHeight: 340,
                  flexibleSpace: FlexibleSpaceBar(
                    background: Stack(
                      fit: StackFit.expand,
                      children: [
                        heroImage,
                        DecoratedBox(
                          decoration: BoxDecoration(
                            gradient: LinearGradient(
                              begin: Alignment.topCenter,
                              end: Alignment.bottomCenter,
                              colors: [Colors.transparent, scrimBottom],
                            ),
                          ),
                        ),
                        Positioned.fill(
                          child: _topNavOverlay(context),
                        ),
                        if (widget.itemId.isEmpty)
                          Positioned(
                          left: 16,
                          bottom: 16,
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(item.name,
                                  style: theme.textTheme.headlineSmall
                                      ?.copyWith(
                                          color: heroTitleColor,
                                          fontWeight: FontWeight.w700)),
                              const SizedBox(height: 8),
                              Wrap(
                                spacing: 8,
                                children: [
                                  if (item.communityRating != null)
                                    _pill(context,
                                        '★ ${item.communityRating!.toStringAsFixed(1)}'),
                                  if (item.premiereDate != null)
                                    _pill(context,
                                        item.premiereDate!.split('T').first),
                                  if (item.genres.isNotEmpty)
                                    _pill(context, item.genres.first),
                                  if (isSeries)
                                    _pill(context, '${_seasons.length} 季')
                                  else if (runtime != null)
                                    _pill(context, _fmt(runtime)),
                                ],
                              ),
                            ],
                          ),
                        ),
                        if (widget.itemId.isEmpty)
                          Positioned(
                          right: 16,
                          top: MediaQuery.of(context).padding.top + 16,
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.end,
                            children: [
                              if (item.communityRating != null)
                                Container(
                                  padding: const EdgeInsets.symmetric(
                                      horizontal: 10, vertical: 6),
                                  decoration: BoxDecoration(
                                    color: Colors.green.withValues(alpha: 0.85),
                                    borderRadius: BorderRadius.circular(999),
                                  ),
                                  child: Text(
                                    item.communityRating!.toStringAsFixed(1),
                                    style: theme.textTheme.labelMedium?.copyWith(
                                      color: Colors.white,
                                      fontWeight: FontWeight.w700,
                                    ),
                                  ),
                                ),
                              const SizedBox(height: 8),
                              Material(
                                color: Colors.black.withValues(alpha: 0.55),
                                borderRadius: BorderRadius.circular(999),
                                child: IconButton(
                                  onPressed: _favoriteLoaded
                                      ? _toggleLocalFavorite
                                      : null,
                                  tooltip: _localFavorite
                                      ? '已本地收藏'
                                      : '添加到本地收藏',
                                  icon: Icon(
                                    _localFavorite
                                        ? Icons.star
                                        : Icons.star_border_rounded,
                                    color: _localFavorite
                                        ? Colors.pinkAccent
                                        : Colors.white,
                                  ),
                                ),
                              ),
                            ],
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
                SliverToBoxAdapter(
                  child: Padding(
                    padding: _DetailUiTokens.panelPadding,
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        _detailHeroSection(
                          context,
                          item: item,
                          access: access,
                          isSeries: isSeries,
                          runtime: runtime,
                        ),
                        const SizedBox(height: 16),
                        if (widget.itemId.isEmpty && _featuredEpisode != null)
                          _playButton(
                            context,
                            label:
                                '播放 S${_featuredEpisode!.seasonNumber ?? 1}:E${_featuredEpisode!.episodeNumber ?? 1}',
                            onTap: () {
                              Navigator.of(context).push(
                                MaterialPageRoute(
                                  builder: (_) => EpisodeDetailPage(
                                    episode: _featuredEpisode!,
                                    appState: widget.appState,
                                    server: widget.server,
                                    isTv: widget.isTv,
                                  ),
                                ),
                              );
                            },
                          ),
                        if (widget.itemId.isEmpty && !isSeries) ...[
                          if (playInfo != null && !showFloatingSettings)
                            _moviePlaybackOptionsCard(context, playInfo),
                          if (playInfo != null && !showFloatingSettings)
                            const SizedBox(height: 12),
                          _playButton(
                            context,
                            label: item.playbackPositionTicks > 0
                                ? '继续播放（${_fmtClock(_ticksToDuration(item.playbackPositionTicks))}）'
                                : '播放',
                            onTap: () async {
                              final start = item.playbackPositionTicks > 0
                                  ? _ticksToDuration(item.playbackPositionTicks)
                                  : null;
                              final useExoCore = !kIsWeb &&
                                  defaultTargetPlatform ==
                                      TargetPlatform.android &&
                                  widget.appState.playerCore == PlayerCore.exo;
                              await Navigator.of(context).push(
                                MaterialPageRoute(
                                  builder: (_) => useExoCore
                                      ? ExoPlayNetworkPage(
                                          title: item.name,
                                          itemId: item.id,
                                          appState: widget.appState,
                                          server: widget.server,
                                          isTv: widget.isTv,
                                          startPosition: start,
                                          mediaSourceId: _selectedMediaSourceId,
                                          audioStreamIndex:
                                              _selectedAudioStreamIndex,
                                          subtitleStreamIndex:
                                              _selectedSubtitleStreamIndex,
                                        )
                                      : PlayNetworkPage(
                                          title: item.name,
                                          itemId: item.id,
                                          appState: widget.appState,
                                          server: widget.server,
                                          isTv: widget.isTv,
                                          startPosition: start,
                                          mediaSourceId: _selectedMediaSourceId,
                                          audioStreamIndex:
                                              _selectedAudioStreamIndex,
                                          subtitleStreamIndex:
                                              _selectedSubtitleStreamIndex,
                                        ),
                                ),
                              );
                              if (!mounted) return;
                              await _refreshProgressAfterReturn();
                            },
                          ),
                        ],
                        if (isSeries && _seasons.isNotEmpty) ...[
                          const SizedBox(height: 12),
                          _seasonEpisodeControlPanel(
                            context,
                            enableBlur: enableBlur,
                          ),
                          const SizedBox(height: 12),
                        ] else
                          const SizedBox(height: 12),
                        if (isSeries) ...[
                          _unwatchedEpisodesSection(
                            context,
                            seriesItem: item,
                            access: access,
                          ),
                          const SizedBox(height: 16),
                        ],
                        if (widget.itemId.isEmpty)
                          Text(
                            item.overview,
                            style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                                  color: Colors.white.withValues(alpha: 0.88),
                                ),
                          ),
                        const SizedBox(height: 16),
                        if (_chapters.isNotEmpty) ...[
                          _chaptersSection(context, _chapters),
                          const SizedBox(height: 16),
                        ],
                        if (item.people.isNotEmpty && access != null) ...[
                          _peopleSection(
                            context,
                            item.people,
                            access: access,
                          ),
                          const SizedBox(height: 16),
                        ],
                        if (widget.itemId.isEmpty && _album.isNotEmpty) ...[
                          _sectionTitle(context, '相册'),
                          const SizedBox(height: 8),
                          SizedBox(
                            height: 140,
                            child: _withHorizontalEdgeFade(
                              context,
                              child: ListView.separated(
                                scrollDirection: Axis.horizontal,
                                itemCount: _album.length,
                                separatorBuilder: (_, __) =>
                                    const SizedBox(width: 10),
                                itemBuilder: (context, index) {
                                  final url = _album[index];
                                  return _HoverScale(
                                    child: ClipRRect(
                                      borderRadius: BorderRadius.circular(12),
                                      child: Image.network(
                                        url,
                                        width: 220,
                                        height: 140,
                                        fit: BoxFit.cover,
                                        headers: {
                                          'User-Agent':
                                              LinHttpClientFactory.userAgent,
                                        },
                                        errorBuilder: (_, __, ___) =>
                                            const SizedBox(
                                          width: 220,
                                          height: 140,
                                          child:
                                              ColoredBox(color: Colors.black26),
                                        ),
                                      ),
                                    ),
                                  );
                                },
                              ),
                            ),
                          ),
                          const SizedBox(height: 16),
                        ],
                        if (widget.itemId.isEmpty && _seasons.isNotEmpty) ...[
                          Text('全部剧季',
                              style: Theme.of(context).textTheme.titleMedium),
                          const SizedBox(height: 8),
                          SizedBox(
                            height: 220,
                            child: _withHorizontalEdgeFade(
                              context,
                              child: ListView.separated(
                                scrollDirection: Axis.horizontal,
                                itemCount: _seasons.length,
                                separatorBuilder: (_, __) =>
                                    const SizedBox(width: 12),
                                itemBuilder: (context, index) {
                                  final s = _seasons[index];
                                  final label = _seasonLabel(s, index);
                                  final img = access?.adapter.imageUrl(
                                    access.auth,
                                    itemId: s.hasImage ? s.id : item.id,
                                    maxWidth: 400,
                                  );
                                  return _HoverScale(
                                    child: SizedBox(
                                      width: 140,
                                      child: MediaPosterTile(
                                        title: label,
                                        imageUrl: img,
                                        onTap: () {
                                          Navigator.of(context).push(
                                            MaterialPageRoute(
                                              builder: (_) => SeasonEpisodesPage(
                                                season: s,
                                                appState: widget.appState,
                                                server: widget.server,
                                                isTv: widget.isTv,
                                                isVirtual: _seasonsVirtual,
                                              ),
                                            ),
                                          );
                                        },
                                      ),
                                    ),
                                  );
                                },
                              ),
                            ),
                          ),
                          const SizedBox(height: 16),
                        ],
                        if (_seasons.isNotEmpty) ...[
                          _sectionTitle(context, '全部剧季'),
                          const SizedBox(height: 8),
                          Column(
                            children: _seasons.asMap().entries.map((entry) {
                              final index = entry.key;
                              final s = entry.value;
                              final label = _seasonLabel(s, index);
                              final count = _episodesCache[s.id]?.length;
                              final img = access?.adapter.imageUrl(
                                access.auth,
                                itemId: s.hasImage ? s.id : item.id,
                                maxWidth: 240,
                              );
                              return Padding(
                                padding: const EdgeInsets.only(bottom: 12),
                                child: _HoverScale(
                                  child: _detailGlassPanel(
                                    enableBlur: enableBlur,
                                    padding: const EdgeInsets.all(10),
                                    child: InkWell(
                                      borderRadius: BorderRadius.circular(12),
                                      onTap: () {
                                        Navigator.of(context).push(
                                          MaterialPageRoute(
                                            builder: (_) => SeasonEpisodesPage(
                                              season: s,
                                              appState: widget.appState,
                                              server: widget.server,
                                              isTv: widget.isTv,
                                              isVirtual: _seasonsVirtual,
                                            ),
                                          ),
                                        );
                                      },
                                      child: Row(
                                        children: [
                                          Stack(
                                            children: [
                                              ClipRRect(
                                                borderRadius:
                                                    BorderRadius.circular(10),
                                                child: SizedBox(
                                                  width: 74,
                                                  height: 106,
                                                  child: img == null
                                                      ? const ColoredBox(
                                                          color: Colors.black26)
                                                      : Image.network(
                                                          img,
                                                          fit: BoxFit.cover,
                                                          headers: {
                                                            'User-Agent':
                                                                LinHttpClientFactory
                                                                    .userAgent,
                                                          },
                                                          errorBuilder:
                                                              (_, __, ___) =>
                                                                  const ColoredBox(
                                                            color:
                                                                Colors.black26,
                                                          ),
                                                        ),
                                                ),
                                              ),
                                              if (count != null)
                                                Positioned(
                                                  right: 4,
                                                  top: 4,
                                                  child: Container(
                                                    padding: const EdgeInsets
                                                        .symmetric(
                                                        horizontal: 6,
                                                        vertical: 2),
                                                    decoration: BoxDecoration(
                                                      color: Colors.green
                                                          .withValues(
                                                              alpha: 0.9),
                                                      borderRadius:
                                                          BorderRadius.circular(
                                                              999),
                                                    ),
                                                    child: Text(
                                                      '$count',
                                                      style: Theme.of(context)
                                                          .textTheme
                                                          .labelSmall
                                                          ?.copyWith(
                                                            color: Colors.white,
                                                            fontWeight:
                                                                FontWeight.w700,
                                                          ),
                                                    ),
                                                  ),
                                                ),
                                            ],
                                          ),
                                          const SizedBox(width: 12),
                                          Expanded(
                                            child: Text(
                                              label,
                                              style: Theme.of(context)
                                                  .textTheme
                                                  .titleMedium
                                                  ?.copyWith(
                                                    fontWeight: FontWeight.w700,
                                                  ),
                                            ),
                                          ),
                                          const Icon(
                                              Icons.chevron_right_rounded),
                                        ],
                                      ),
                                    ),
                                  ),
                                ),
                              );
                            }).toList(),
                          ),
                        ],
                        if (_similar.isNotEmpty) ...[
                          _sectionTitle(context, '更多类似'),
                          const SizedBox(height: 8),
                          SizedBox(
                            height: 240,
                            child: _withHorizontalEdgeFade(
                              context,
                              child: ListView.separated(
                                scrollDirection: Axis.horizontal,
                                itemCount: _similar.length,
                                separatorBuilder: (_, __) =>
                                    const SizedBox(width: 12),
                                itemBuilder: (context, index) {
                                  final s = _similar[index];
                                  final img = s.hasImage && access != null
                                      ? access.adapter.imageUrl(
                                          access.auth,
                                          itemId: s.id,
                                          maxWidth: 400,
                                        )
                                      : null;
                                  final date = (s.premiereDate ?? '').trim();
                                  final parsed = date.isEmpty
                                      ? null
                                      : DateTime.tryParse(date);
                                  final year = parsed != null
                                      ? parsed.year.toString()
                                      : (date.length >= 4
                                          ? date.substring(0, 4)
                                          : '');
                                  final badge = s.type == 'Movie'
                                      ? '电影'
                                      : (s.type == 'Series' ? '剧集' : '');

                                  return _HoverScale(
                                    child: SizedBox(
                                      width: 140,
                                      child: MediaPosterTile(
                                        title: s.name,
                                        titleMaxLines: 2,
                                        imageUrl: img,
                                        year: year,
                                        rating: s.communityRating,
                                        badgeText: badge,
                                        onTap: () {
                                          Navigator.of(context).push(
                                            MaterialPageRoute(
                                              builder: (_) => ShowDetailPage(
                                                itemId: s.id,
                                                title: s.name,
                                                appState: widget.appState,
                                                server: widget.server,
                                                isTv: widget.isTv,
                                              ),
                                            ),
                                          );
                                        },
                                      ),
                                    ),
                                  );
                                },
                              ),
                            ),
                          ),
                        ],
                        const SizedBox(height: 16),
                        _externalLinksSection(context, item, widget.appState),
                        if (showFloatingSettings) const SizedBox(height: 88),
                      ],
                    ),
                  ),
                ),
              ],
            ),
          ),
          if (showFloatingSettings)
            Align(
              alignment: Alignment.bottomCenter,
              child: SafeArea(
                top: false,
                left: false,
                right: false,
                minimum: const EdgeInsets.fromLTRB(16, 0, 16, 12),
                child: _floatingPlaybackSettingsDock(
                  context,
                  playInfo,
                  enableBlur: enableBlur,
                ),
              ),
            ),
        ],
      ),
    );
  }
}

class SeasonEpisodesPage extends StatefulWidget {
  const SeasonEpisodesPage({
    super.key,
    required this.season,
    required this.appState,
    this.server,
    this.isTv = false,
    this.isVirtual = false,
  });

  final MediaItem season;
  final AppState appState;
  final ServerProfile? server;
  final bool isTv;
  final bool isVirtual;

  @override
  State<SeasonEpisodesPage> createState() => _SeasonEpisodesPageState();
}

class _SeasonEpisodesPageState extends State<SeasonEpisodesPage> {
  List<MediaItem> _episodes = [];
  bool _loading = true;
  String? _error;
  MediaItem? _detailSeason;

  String? get _baseUrl => widget.server?.baseUrl ?? widget.appState.baseUrl;
  String? get _token => widget.server?.token ?? widget.appState.token;
  String? get _userId => widget.server?.userId ?? widget.appState.userId;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    final baseUrl = _baseUrl;
    final token = _token;
    final userId = _userId;
    if (baseUrl == null || token == null || userId == null) {
      setState(() {
        _error = '未连接服务器';
        _loading = false;
      });
      return;
    }

    final access =
        resolveServerAccess(appState: widget.appState, server: widget.server);
    if (access == null) {
      setState(() {
        _error = 'Unsupported server';
        _loading = false;
      });
      return;
    }
    try {
      final eps = await access.adapter.fetchEpisodes(
        access.auth,
        seasonId: widget.season.id,
      );
      final items = List<MediaItem>.from(eps.items);
      items.sort((a, b) {
        final aNo = a.episodeNumber ?? 0;
        final bNo = b.episodeNumber ?? 0;
        return aNo.compareTo(bNo);
      });
      MediaItem? detail;
      if (!widget.isVirtual) {
        try {
          detail = await access.adapter.fetchItemDetail(
            access.auth,
            itemId: widget.season.id,
          );
        } catch (_) {}
      }
      setState(() {
        _episodes = items;
        _detailSeason = detail;
      });
    } catch (e) {
      setState(() => _error = e.toString());
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final seasonName = _detailSeason?.name ?? widget.season.name;
    final enableBlur = !widget.isTv && widget.appState.enableBlurEffects;
    final access =
        resolveServerAccess(appState: widget.appState, server: widget.server);
    return Scaffold(
      appBar: GlassAppBar(
        enableBlur: enableBlur,
        child: AppBar(title: Text(seasonName)),
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : _error != null
              ? Center(child: Text(_error!))
              : _episodes.isEmpty
                  ? const Center(child: Text('暂无剧集'))
                  : ListView.separated(
                      padding: const EdgeInsets.all(16),
                      itemCount: _episodes.length,
                      separatorBuilder: (_, __) => const SizedBox(height: 12),
                      itemBuilder: (context, index) {
                        final e = _episodes[index];
                        final epNo = e.episodeNumber ?? (index + 1);
                        final epName = e.name.trim();
                        final titleText = epName.isNotEmpty
                            ? '$epNo. $epName'
                            : '$epNo. 第$epNo集';
                        final dur = e.runTimeTicks != null
                            ? Duration(
                                microseconds: (e.runTimeTicks! / 10).round())
                            : null;
                        final img = access == null
                            ? ''
                            : access.adapter.imageUrl(
                                access.auth,
                                itemId: e.hasImage ? e.id : widget.season.id,
                                maxWidth: 700,
                              );
                        return Card(
                          clipBehavior: Clip.antiAlias,
                          child: InkWell(
                            onTap: () {
                              Navigator.of(context).push(
                                MaterialPageRoute(
                                  builder: (_) => EpisodeDetailPage(
                                    episode: e,
                                    appState: widget.appState,
                                    server: widget.server,
                                    isTv: widget.isTv,
                                  ),
                                ),
                              );
                            },
                            child: Padding(
                              padding: const EdgeInsets.all(12),
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Row(
                                    crossAxisAlignment:
                                        CrossAxisAlignment.start,
                                    children: [
                                      SizedBox(
                                        width: 170,
                                        child: AspectRatio(
                                          aspectRatio: 16 / 9,
                                          child: ClipRRect(
                                            borderRadius:
                                                BorderRadius.circular(12),
                                            child: Image.network(
                                              img,
                                              fit: BoxFit.cover,
                                              headers: {
                                                'User-Agent':
                                                    LinHttpClientFactory
                                                        .userAgent
                                              },
                                              errorBuilder: (_, __, ___) =>
                                                  const ColoredBox(
                                                      color: Colors.black26),
                                            ),
                                          ),
                                        ),
                                      ),
                                      const SizedBox(width: 12),
                                      Expanded(
                                        child: Column(
                                          crossAxisAlignment:
                                              CrossAxisAlignment.start,
                                          children: [
                                            Text(
                                              titleText,
                                              maxLines: 2,
                                              overflow: TextOverflow.ellipsis,
                                              style: Theme.of(context)
                                                  .textTheme
                                                  .titleMedium
                                                  ?.copyWith(
                                                      fontWeight:
                                                          FontWeight.w700),
                                            ),
                                            if (dur != null) ...[
                                              const SizedBox(height: 6),
                                              Text(
                                                _fmt(dur),
                                                style: Theme.of(context)
                                                    .textTheme
                                                    .bodySmall
                                                    ?.copyWith(
                                                      color: Theme.of(context)
                                                          .colorScheme
                                                          .onSurfaceVariant,
                                                      fontWeight:
                                                          FontWeight.w600,
                                                    ),
                                              ),
                                            ],
                                          ],
                                        ),
                                      ),
                                    ],
                                  ),
                                  if (e.overview.isNotEmpty) ...[
                                    const SizedBox(height: 10),
                                    Text(
                                      e.overview,
                                      maxLines: 4,
                                      overflow: TextOverflow.ellipsis,
                                      style: Theme.of(context)
                                          .textTheme
                                          .bodyMedium,
                                    ),
                                  ],
                                ],
                              ),
                            ),
                          ),
                        );
                      },
                    ),
    );
  }
}

class EpisodeDetailPage extends StatefulWidget {
  const EpisodeDetailPage({
    super.key,
    required this.episode,
    required this.appState,
    this.server,
    this.isTv = false,
  });

  final MediaItem episode;
  final AppState appState;
  final ServerProfile? server;
  final bool isTv;

  @override
  State<EpisodeDetailPage> createState() => _EpisodeDetailPageState();
}

class _EpisodeDetailPageState extends State<EpisodeDetailPage> {
  PlaybackInfoResult? _playInfo;
  String? _selectedMediaSourceId;
  int? _selectedAudioStreamIndex; // null = default
  int? _selectedSubtitleStreamIndex; // null = default, -1 = off
  String? _error;
  bool _loading = true;
  MediaItem? _detail;
  List<ChapterInfo> _chapters = [];
  String? _seriesId;
  String _seriesName = '';
  List<MediaItem> _seasons = [];
  bool _seasonsVirtual = false;
  String? _selectedSeasonId;
  final Map<String, List<MediaItem>> _episodesCache = {};
  String? _seriesError;
  bool _seriesLoading = false;
  bool _markBusy = false;
  bool _localFavorite = false;
  bool _favoriteLoaded = false;

  Future<void> _toggleEpisodePlayedMark() async {
    if (_markBusy) return;
    final access =
        resolveServerAccess(appState: widget.appState, server: widget.server);
    if (access == null) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('未连接服务器')),
      );
      return;
    }

    final currentPlayed = _detail?.played ?? false;
    final nextPlayed = !currentPlayed;

    setState(() => _markBusy = true);
    try {
      await access.adapter.updatePlaybackPosition(
        access.auth,
        itemId: widget.episode.id,
        positionTicks: 0,
        played: nextPlayed,
      );

      final detail = await access.adapter
          .fetchItemDetail(access.auth, itemId: widget.episode.id);
      if (!mounted) return;
      setState(() => _detail = detail);

      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(nextPlayed ? '已标记为已播放' : '已标记为未播放')),
      );
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('标记失败：$e')),
      );
    } finally {
      if (mounted) setState(() => _markBusy = false);
    }
  }

  String? get _baseUrl => widget.server?.baseUrl ?? widget.appState.baseUrl;
  String? get _token => widget.server?.token ?? widget.appState.token;
  String? get _userId => widget.server?.userId ?? widget.appState.userId;

  String get _episodeFavoriteKey {
    final serverKey =
        (_baseUrl ?? 'default').replaceAll(RegExp(r'[^a-zA-Z0-9]'), '_');
    return 'episode_detail_local_favorite_${serverKey}_${widget.episode.id}';
  }

  @override
  void initState() {
    super.initState();
    _loadLocalFavorite();
    _load();
  }

  Future<void> _loadLocalFavorite() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      if (!mounted) return;
      setState(() {
        _localFavorite = prefs.getBool(_episodeFavoriteKey) ?? false;
        _favoriteLoaded = true;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() => _favoriteLoaded = true);
    }
  }

  Future<void> _toggleLocalFavorite() async {
    final next = !_localFavorite;
    setState(() => _localFavorite = next);
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setBool(_episodeFavoriteKey, next);
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(next ? '已加入本地收藏' : '已取消本地收藏')),
      );
    } catch (_) {
      if (!mounted) return;
      setState(() => _localFavorite = !next);
    }
  }

  Future<void> _refreshProgressAfterReturn(
      {Duration delay = const Duration(milliseconds: 350)}) async {
    final access =
        resolveServerAccess(appState: widget.appState, server: widget.server);
    if (access == null) return;

    final before = _detail?.playbackPositionTicks;
    for (var attempt = 0; attempt < 3; attempt++) {
      final attemptDelay =
          attempt == 0 ? delay : const Duration(milliseconds: 300);
      if (attemptDelay > Duration.zero) {
        await Future<void>.delayed(attemptDelay);
      }

      try {
        final detail = await access.adapter
            .fetchItemDetail(access.auth, itemId: widget.episode.id);
        if (!mounted) return;
        setState(() => _detail = detail);
        if (before == null || detail.playbackPositionTicks != before) return;
      } catch (_) {
        // Best-effort refresh. Keep existing state on failure.
      }
    }
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    final baseUrl = _baseUrl;
    final token = _token;
    final userId = _userId;
    if (baseUrl == null || token == null || userId == null) {
      setState(() {
        _error = '未连接服务器';
        _loading = false;
      });
      return;
    }

    final access =
        resolveServerAccess(appState: widget.appState, server: widget.server);
    if (access == null) {
      setState(() {
        _error = 'Unsupported server';
        _loading = false;
      });
      return;
    }
    try {
      final detail = await access.adapter
          .fetchItemDetail(access.auth, itemId: widget.episode.id);

      final resolvedSeriesId =
          (detail.seriesId ?? widget.episode.seriesId ?? '').trim();
      final resolvedSeriesName = detail.seriesName.trim().isNotEmpty
          ? detail.seriesName.trim()
          : widget.episode.seriesName.trim();

      if (resolvedSeriesId.isNotEmpty) {
        setState(() {
          _seriesId = resolvedSeriesId;
          _seriesName = resolvedSeriesName;
          _seriesLoading = true;
        });
        unawaited(
          _loadSeriesEpisodes(
            access: access,
            episodeDetail: detail,
            seriesId: resolvedSeriesId,
            seriesName: resolvedSeriesName,
          ),
        );
      }
      final info = await access.adapter
          .fetchPlaybackInfo(access.auth, itemId: widget.episode.id);
      final sources = info.mediaSources.cast<Map<String, dynamic>>();
      final preferred = sources.isEmpty
          ? null
          : _ShowDetailPageState._pickPreferredMediaSourceId(
              sources,
              widget.appState.preferredVideoVersion,
            );

      final serverId = widget.server?.id ?? widget.appState.activeServerId;
      final seriesId = resolvedSeriesId.trim();

      String? selectedMediaSourceId = _selectedMediaSourceId;
      if ((selectedMediaSourceId ?? '').trim().isEmpty &&
          serverId != null &&
          serverId.trim().isNotEmpty &&
          seriesId.isNotEmpty &&
          sources.isNotEmpty) {
        final idx = widget.appState.seriesMediaSourceIndex(
            serverId: serverId.trim(), seriesId: seriesId);
        if (idx != null && idx >= 0 && idx < sources.length) {
          selectedMediaSourceId = sources[idx]['Id']?.toString();
        }
      }
      selectedMediaSourceId = (selectedMediaSourceId ?? '').trim();
      if (selectedMediaSourceId.isEmpty) {
        selectedMediaSourceId = (preferred ?? '').trim();
      }
      if (selectedMediaSourceId.isEmpty && sources.isNotEmpty) {
        selectedMediaSourceId = (sources.first['Id']?.toString() ?? '').trim();
      }
      if (selectedMediaSourceId.isEmpty) selectedMediaSourceId = null;

      int? selectedAudioStreamIndex = _selectedAudioStreamIndex;
      int? selectedSubtitleStreamIndex = _selectedSubtitleStreamIndex;
      if (serverId != null &&
          serverId.trim().isNotEmpty &&
          seriesId.isNotEmpty) {
        selectedAudioStreamIndex ??= widget.appState.seriesAudioStreamIndex(
            serverId: serverId.trim(), seriesId: seriesId);
        selectedSubtitleStreamIndex ??=
            widget.appState.seriesSubtitleStreamIndex(
          serverId: serverId.trim(),
          seriesId: seriesId,
        );
      }
      List<ChapterInfo> chaps = const [];
      try {
        chaps = await access.adapter
            .fetchChapters(access.auth, itemId: widget.episode.id);
      } catch (_) {
        // Chapters are optional; hide section when unavailable.
      }
      setState(() {
        _playInfo = info;
        _detail = detail;
        _chapters = chaps;
        _selectedMediaSourceId = selectedMediaSourceId;
        _selectedAudioStreamIndex = selectedAudioStreamIndex;
        _selectedSubtitleStreamIndex = selectedSubtitleStreamIndex;
      });
    } catch (e) {
      setState(() => _error = e.toString());
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  String _mediaSourceSubtitle(Map<String, dynamic> ms) {
    final size = ms['Size'];
    final sizeGb =
        size is num ? (size / (1024 * 1024 * 1024)).toStringAsFixed(1) : null;
    final bitrate = _ShowDetailPageState._asInt(ms['Bitrate']);
    final bitrateMbps =
        bitrate != null ? (bitrate / 1000000).toStringAsFixed(1) : null;

    final videoStreams = _ShowDetailPageState._streamsOfType(ms, 'Video');
    final video = videoStreams.isNotEmpty ? videoStreams.first : null;
    final height = _ShowDetailPageState._asInt(video?['Height']);
    final vCodec =
        (ms['VideoCodec'] as String?) ?? (video?['Codec'] as String?);

    final parts = <String>[];
    if (height != null) parts.add('${height}p');
    if (vCodec != null && vCodec.isNotEmpty) parts.add(vCodec.toUpperCase());
    if (sizeGb != null) parts.add('$sizeGb GB');
    if (bitrateMbps != null) parts.add('$bitrateMbps Mbps');
    return parts.isEmpty ? '直连播放' : parts.join(' / ');
  }

  Widget _episodePlaybackOptionsCard(
      BuildContext context, PlaybackInfoResult info) {
    final ms =
        _ShowDetailPageState._findMediaSource(info, _selectedMediaSourceId);
    if (ms == null) return const SizedBox.shrink();

    final audioStreams = _ShowDetailPageState._streamsOfType(ms, 'Audio');
    final subtitleStreams = _ShowDetailPageState._streamsOfType(ms, 'Subtitle');

    final defaultAudio = _ShowDetailPageState._defaultStream(audioStreams);
    final selectedAudio = _selectedAudioStreamIndex != null
        ? audioStreams.firstWhere(
            (s) =>
                _ShowDetailPageState._asInt(s['Index']) ==
                _selectedAudioStreamIndex,
            orElse: () => defaultAudio ?? const <String, dynamic>{},
          )
        : defaultAudio;

    final defaultSub = _ShowDetailPageState._defaultStream(subtitleStreams);
    final Map<String, dynamic>? selectedSub;
    if (_selectedSubtitleStreamIndex == -1) {
      selectedSub = null;
    } else if (_selectedSubtitleStreamIndex != null) {
      selectedSub = subtitleStreams.firstWhere(
        (s) =>
            _ShowDetailPageState._asInt(s['Index']) ==
            _selectedSubtitleStreamIndex,
        orElse: () => defaultSub ?? const <String, dynamic>{},
      );
    } else {
      selectedSub = defaultSub;
    }

    final hasSubs = subtitleStreams.isNotEmpty;
    final subtitleText = _selectedSubtitleStreamIndex == -1
        ? '关闭'
        : selectedSub != null && selectedSub.isNotEmpty
            ? _ShowDetailPageState._streamLabel(selectedSub,
                includeCodec: false)
            : hasSubs
                ? '默认'
                : '关闭';

    final audioText = selectedAudio != null && selectedAudio.isNotEmpty
        ? _ShowDetailPageState._streamLabel(selectedAudio,
                includeCodec: false) +
            (selectedAudio == defaultAudio ? ' (默认)' : '')
        : '默认';

    final theme = Theme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Card(
          shape:
              RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              ListTile(
                leading: const Icon(Icons.video_file),
                title: Text(_ShowDetailPageState._mediaSourceTitle(ms)),
                subtitle: Text(_mediaSourceSubtitle(ms)),
                trailing: const Icon(Icons.arrow_drop_down),
                onTap: () => _pickMediaSource(context, info),
              ),
              const Divider(height: 1),
              ListTile(
                leading: const Icon(Icons.audiotrack),
                title: Text(audioText),
                trailing: const Icon(Icons.arrow_drop_down),
                onTap: audioStreams.isEmpty
                    ? null
                    : () => _pickAudioStream(context, ms),
              ),
              const Divider(height: 1),
              ListTile(
                leading: const Icon(Icons.subtitles),
                title: Text(subtitleText),
                trailing: const Icon(Icons.arrow_drop_down),
                onTap: hasSubs ? () => _pickSubtitleStream(context, ms) : null,
              ),
            ],
          ),
        ),
        const SizedBox(height: 6),
        Text(
          '提示：以上选择会应用到本剧后续集数',
          style: theme.textTheme.bodySmall?.copyWith(
            color: theme.colorScheme.onSurfaceVariant,
          ),
        ),
      ],
    );
  }

  Future<void> _pickMediaSource(
      BuildContext context, PlaybackInfoResult info) async {
    final sources = info.mediaSources.cast<Map<String, dynamic>>();
    if (sources.isEmpty) return;

    final sortedSources = List<Map<String, dynamic>>.from(sources)
      ..sort(_ShowDetailPageState._compareMediaSourcesByQuality);

    final current = (_selectedMediaSourceId ?? '').trim();
    final selected = await showModalBottomSheet<String>(
      context: context,
      builder: (ctx) {
        return SafeArea(
          child: ListView(
            children: [
              const ListTile(title: Text('版本选择')),
              ...sortedSources.map((ms) {
                final id = (ms['Id']?.toString() ?? '').trim();
                final selectedNow = id.isNotEmpty && id == current;
                return ListTile(
                  leading: Icon(
                      selectedNow ? Icons.check_circle : Icons.circle_outlined),
                  title: Text(_ShowDetailPageState._mediaSourceTitle(ms)),
                  subtitle: Text(_mediaSourceSubtitle(ms)),
                  onTap: id.isEmpty ? null : () => Navigator.of(ctx).pop(id),
                );
              }),
            ],
          ),
        );
      },
    );

    if (!mounted) return;
    final picked = (selected ?? '').trim();
    if (picked.isEmpty || picked == current) return;

    setState(() {
      _selectedMediaSourceId = picked;
    });

    final serverId = widget.server?.id ?? widget.appState.activeServerId;
    final sid = (_seriesId ?? '').trim();
    if (serverId == null || serverId.trim().isEmpty || sid.isEmpty) return;
    final idx = sources
        .indexWhere((ms) => (ms['Id']?.toString() ?? '').trim() == picked);
    if (idx < 0) return;
    unawaited(
      widget.appState.setSeriesMediaSourceIndex(
        serverId: serverId.trim(),
        seriesId: sid,
        mediaSourceIndex: idx,
      ),
    );
  }

  Future<void> _pickAudioStream(
      BuildContext context, Map<String, dynamic> ms) async {
    final audioStreams = _ShowDetailPageState._streamsOfType(ms, 'Audio');
    if (audioStreams.isEmpty) return;

    final selected = await showModalBottomSheet<int?>(
      context: context,
      builder: (ctx) {
        final def = _ShowDetailPageState._defaultStream(audioStreams);
        final defIndex = _ShowDetailPageState._asInt(def?['Index']);
        return SafeArea(
          child: ListView(
            children: [
              const ListTile(title: Text('音轨选择')),
              ListTile(
                leading: Icon(_selectedAudioStreamIndex == null
                    ? Icons.check
                    : Icons.circle_outlined),
                title: const Text('默认'),
                onTap: () => Navigator.of(ctx).pop(null),
              ),
              ...audioStreams.map((s) {
                final idx = _ShowDetailPageState._asInt(s['Index']);
                final selectedNow =
                    idx != null && idx == _selectedAudioStreamIndex;
                final title =
                    _ShowDetailPageState._streamLabel(s, includeCodec: false);
                return ListTile(
                  leading: Icon(
                      selectedNow ? Icons.check_circle : Icons.circle_outlined),
                  title: Text(idx == defIndex ? '$title (默认)' : title),
                  subtitle: (s['Codec'] as String?)?.isNotEmpty == true
                      ? Text(s['Codec'] as String)
                      : null,
                  onTap: idx == null ? null : () => Navigator.of(ctx).pop(idx),
                );
              }),
            ],
          ),
        );
      },
    );

    if (!mounted) return;
    setState(() => _selectedAudioStreamIndex = selected);

    final serverId = widget.server?.id ?? widget.appState.activeServerId;
    final sid = (_seriesId ?? '').trim();
    if (serverId == null || serverId.trim().isEmpty || sid.isEmpty) return;
    unawaited(
      widget.appState.setSeriesAudioStreamIndex(
        serverId: serverId.trim(),
        seriesId: sid,
        audioStreamIndex: selected,
      ),
    );
  }

  Future<void> _pickSubtitleStream(
      BuildContext context, Map<String, dynamic> ms) async {
    final subtitleStreams = _ShowDetailPageState._streamsOfType(ms, 'Subtitle');
    if (subtitleStreams.isEmpty) return;

    final selected = await showModalBottomSheet<int?>(
      context: context,
      builder: (ctx) {
        final def = _ShowDetailPageState._defaultStream(subtitleStreams);
        final defIndex = _ShowDetailPageState._asInt(def?['Index']);
        final isOff = _selectedSubtitleStreamIndex == -1;
        final isDefault = _selectedSubtitleStreamIndex == null;
        return SafeArea(
          child: ListView(
            children: [
              const ListTile(title: Text('字幕选择')),
              ListTile(
                leading: Icon(isOff ? Icons.check : Icons.circle_outlined),
                title: const Text('关闭'),
                onTap: () => Navigator.of(ctx).pop(-1),
              ),
              ListTile(
                leading: Icon(isDefault ? Icons.check : Icons.circle_outlined),
                title: const Text('默认'),
                onTap: () => Navigator.of(ctx).pop(null),
              ),
              ...subtitleStreams.map((s) {
                final idx = _ShowDetailPageState._asInt(s['Index']);
                final selectedNow =
                    idx != null && idx == _selectedSubtitleStreamIndex;
                final title =
                    _ShowDetailPageState._streamLabel(s, includeCodec: false);
                return ListTile(
                  leading: Icon(
                      selectedNow ? Icons.check_circle : Icons.circle_outlined),
                  title: Text(idx == defIndex ? '$title (默认)' : title),
                  subtitle: (s['Codec'] as String?)?.isNotEmpty == true
                      ? Text(s['Codec'] as String)
                      : null,
                  onTap: idx == null ? null : () => Navigator.of(ctx).pop(idx),
                );
              }),
            ],
          ),
        );
      },
    );

    if (!mounted) return;
    setState(() => _selectedSubtitleStreamIndex = selected);

    final serverId = widget.server?.id ?? widget.appState.activeServerId;
    final sid = (_seriesId ?? '').trim();
    if (serverId == null || serverId.trim().isEmpty || sid.isEmpty) return;
    unawaited(
      widget.appState.setSeriesSubtitleStreamIndex(
        serverId: serverId.trim(),
        seriesId: sid,
        subtitleStreamIndex: selected,
      ),
    );
  }

  String _episodeLine(MediaItem ep) {
    final seasonNo = ep.seasonNumber ?? 1;
    final epNo = ep.episodeNumber ?? 1;
    final name = ep.name.trim();
    return name.isNotEmpty ? 'S$seasonNo:E$epNo - $name' : 'S$seasonNo:E$epNo';
  }

  String _episodeDateText(MediaItem ep) {
    final raw = (ep.premiereDate ?? '').trim();
    if (raw.isEmpty) return '';
    final dt = DateTime.tryParse(raw);
    if (dt == null) return raw.length >= 10 ? raw.substring(0, 10) : raw;
    return '${dt.year}/${dt.month}/${dt.day}';
  }

  Map<String, dynamic>? _currentMediaSource() {
    final info = _playInfo;
    if (info == null) return null;
    return _ShowDetailPageState._findMediaSource(info, _selectedMediaSourceId);
  }

  String _currentVideoText() {
    final ms = _currentMediaSource();
    if (ms == null) return '未知';
    return _mediaSourceSubtitle(ms);
  }

  String _currentAudioText() {
    final ms = _currentMediaSource();
    if (ms == null) return '默认';
    final streams = _ShowDetailPageState._streamsOfType(ms, 'Audio');
    if (streams.isEmpty) return '默认';
    final def = _ShowDetailPageState._defaultStream(streams);
    final selected = _selectedAudioStreamIndex != null
        ? streams.firstWhere(
            (s) =>
                _ShowDetailPageState._asInt(s['Index']) ==
                _selectedAudioStreamIndex,
            orElse: () => def ?? const <String, dynamic>{},
          )
        : def;
    if (selected == null || selected.isEmpty) return '默认';
    return _ShowDetailPageState._streamLabel(selected, includeCodec: false);
  }

  String _currentSubtitleText() {
    if (_selectedSubtitleStreamIndex == -1) return '关闭';
    final ms = _currentMediaSource();
    if (ms == null) return '默认';
    final streams = _ShowDetailPageState._streamsOfType(ms, 'Subtitle');
    if (streams.isEmpty) return '默认';
    final def = _ShowDetailPageState._defaultStream(streams);
    final selected = _selectedSubtitleStreamIndex != null
        ? streams.firstWhere(
            (s) =>
                _ShowDetailPageState._asInt(s['Index']) ==
                _selectedSubtitleStreamIndex,
            orElse: () => def ?? const <String, dynamic>{},
          )
        : def;
    if (selected == null || selected.isEmpty) return '默认';
    return _ShowDetailPageState._streamLabel(selected, includeCodec: false);
  }

  Future<void> _playCurrentEpisode({Duration? startPosition}) async {
    final ep = _detail ?? widget.episode;
    final useExoCore = !kIsWeb &&
        defaultTargetPlatform == TargetPlatform.android &&
        widget.appState.playerCore == PlayerCore.exo;
    await Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => useExoCore
            ? ExoPlayNetworkPage(
                title: ep.name,
                itemId: ep.id,
                appState: widget.appState,
                server: widget.server,
                isTv: widget.isTv,
                seriesId: _seriesId,
                startPosition: startPosition,
                mediaSourceId: _selectedMediaSourceId,
                audioStreamIndex: _selectedAudioStreamIndex,
                subtitleStreamIndex: _selectedSubtitleStreamIndex,
              )
            : PlayNetworkPage(
                title: ep.name,
                itemId: ep.id,
                appState: widget.appState,
                server: widget.server,
                isTv: widget.isTv,
                seriesId: _seriesId,
                startPosition: startPosition,
                mediaSourceId: _selectedMediaSourceId,
                audioStreamIndex: _selectedAudioStreamIndex,
                subtitleStreamIndex: _selectedSubtitleStreamIndex,
              ),
      ),
    );
    if (!mounted) return;
    await _refreshProgressAfterReturn();
  }

  Widget _episodeActionButton({
    required IconData icon,
    required String label,
    required VoidCallback? onTap,
    bool primary = false,
  }) {
    return _detailActionButton(
      context,
      icon: icon,
      label: label,
      onTap: onTap,
      primary: primary,
    );
  }

  Widget _episodeTopNavOverlay() {
    void showHint(String label) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('$label 功能待接入')),
      );
    }

    return SafeArea(
      bottom: false,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(8, 6, 8, 0),
        child: IconTheme(
          data: const IconThemeData(color: Colors.white),
          child: Row(
            children: [
              IconButton(
                onPressed: () {
                  if (Navigator.of(context).canPop()) {
                    Navigator.of(context).pop();
                  }
                },
                icon: const Icon(Icons.arrow_back),
              ),
              IconButton(
                onPressed: () => Navigator.of(context).popUntil((r) => r.isFirst),
                icon: const Icon(Icons.home),
              ),
              IconButton(
                onPressed: () => ScaffoldMessenger.of(context).showSnackBar(
                  const SnackBar(content: Text('菜单功能待接入')),
                ),
                icon: const Icon(Icons.menu),
              ),
              const Spacer(),
              IconButton(
                onPressed: () => showHint('投屏'),
                icon: const Icon(Icons.cast),
              ),
              IconButton(
                onPressed: () => showHint('搜索'),
                icon: const Icon(Icons.search),
              ),
              IconButton(
                onPressed: () => showHint('设置'),
                icon: const Icon(Icons.settings),
              ),
            ],
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    const heroTextColor = Colors.white;
    final heroMutedTextColor = Colors.white.withValues(alpha: 0.88);
    final heroMetaBg = Colors.black.withValues(alpha: 0.32);
    final heroMetaBorder = Colors.white.withValues(alpha: 0.22);
    final enableBlur = !widget.isTv && widget.appState.enableBlurEffects;
    final access = resolveServerAccess(
      appState: widget.appState,
      server: widget.server,
    );
    if (_loading) {
      return const Scaffold(body: Center(child: CircularProgressIndicator()));
    }
    if (_error != null) {
      return Scaffold(
        appBar: GlassAppBar(
          enableBlur: enableBlur,
          child: AppBar(title: const Text('集详情')),
        ),
        body: Center(child: Text(_error!)),
      );
    }

    final ep = _detail ?? widget.episode;
    final ms = _currentMediaSource();
    final played = _detail?.played ?? false;
    final ticks = _detail?.playbackPositionTicks ?? 0;
    final hasResume = ticks > 0 && !played;
    final playLabel =
        hasResume ? '继续播放（${_fmtClock(_ticksToDuration(ticks))}）' : (played ? '重播' : '播放');
    final runtime = ep.runTimeTicks != null
        ? Duration(microseconds: (ep.runTimeTicks! / 10).round())
        : null;
    final dateText = _episodeDateText(ep);
    final backdropUrl = access == null
        ? ''
        : access.adapter.imageUrl(
            access.auth,
            itemId: ep.id,
            imageType: 'Backdrop',
            maxWidth: 1600,
          );
    final thumbUrl = access == null
        ? ''
        : access.adapter.imageUrl(
            access.auth,
            itemId: ep.hasImage ? ep.id : (_selectedSeason?.id ?? ep.id),
            maxWidth: 900,
          );
    final seriesTitle = _seriesName.trim().isNotEmpty
        ? _seriesName.trim()
        : (ep.seriesName.trim().isNotEmpty ? ep.seriesName.trim() : ep.name);

    Widget background = backdropUrl.isNotEmpty
        ? Image.network(
            backdropUrl,
            fit: BoxFit.cover,
            headers: {'User-Agent': LinHttpClientFactory.userAgent},
            errorBuilder: (_, __, ___) =>
                const ColoredBox(color: Colors.black26),
          )
        : const ColoredBox(color: Colors.black26);

    return Scaffold(
      body: Stack(
        children: [
          Positioned.fill(child: background),
          Positioned.fill(
            child: DecoratedBox(
              decoration: BoxDecoration(
                color: Colors.black.withValues(alpha: 0.40),
                gradient: LinearGradient(
                  begin: Alignment.topCenter,
                  end: Alignment.bottomCenter,
                  colors: [
                    Colors.black.withValues(alpha: 0.38),
                    Colors.black.withValues(alpha: 0.58),
                  ],
                ),
              ),
            ),
          ),
          RefreshIndicator(
            onRefresh: _load,
            child: SingleChildScrollView(
              physics: const AlwaysScrollableScrollPhysics(),
              padding: _DetailUiTokens.pagePadding,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  _detailGlassPanel(
                    enableBlur: enableBlur,
                    padding: _DetailUiTokens.panelPadding,
                    child: LayoutBuilder(
                      builder: (context, c) {
                        final wide = c.maxWidth >= 1000;
                        final poster = ClipRRect(
                          borderRadius:
                              BorderRadius.circular(_DetailUiTokens.cardRadius),
                          child: AspectRatio(
                            aspectRatio: 16 / 9,
                            child: thumbUrl.isEmpty
                                ? const ColoredBox(color: Colors.black26)
                                : Image.network(
                                    thumbUrl,
                                    fit: BoxFit.cover,
                                    headers: {
                                      'User-Agent': LinHttpClientFactory.userAgent
                                    },
                                    errorBuilder: (_, __, ___) =>
                                        const ColoredBox(color: Colors.black26),
                                  ),
                          ),
                        );

                        final metaItems = <String>[
                          if (ep.communityRating != null)
                            '★ ${ep.communityRating!.toStringAsFixed(1)}',
                          if (dateText.isNotEmpty) dateText,
                          if (runtime != null) _fmt(runtime),
                        ];

                        final info = Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              seriesTitle,
                              style: (wide
                                      ? theme.textTheme.headlineMedium
                                      : theme.textTheme.headlineSmall)
                                   ?.copyWith(
                                     color: heroTextColor,
                                     fontWeight: FontWeight.w800,
                                   ),
                            ),
                            const SizedBox(height: 6),
                            Text(
                              _episodeLine(ep),
                              style: theme.textTheme.titleLarge?.copyWith(
                                    color: heroTextColor,
                                    fontWeight: FontWeight.w700,
                                  ),
                            ),
                            const SizedBox(height: 8),
                            Wrap(
                              spacing: 8,
                              runSpacing: 8,
                              children: metaItems
                                  .map(
                                    (m) => Container(
                                      padding: const EdgeInsets.symmetric(
                                          horizontal: 8, vertical: 4),
                                      decoration: BoxDecoration(
                                        color: heroMetaBg,
                                        border: Border.all(color: heroMetaBorder),
                                        borderRadius:
                                            BorderRadius.circular(999),
                                      ),
                                      child: Text(
                                        m,
                                        style: theme.textTheme.labelMedium
                                            ?.copyWith(color: heroTextColor),
                                      ),
                                    ),
                                  )
                                  .toList(),
                            ),
                            const SizedBox(height: 12),
                            Text(
                              '视频：${_currentVideoText()}',
                              style: theme.textTheme.bodyMedium?.copyWith(
                                  color: heroTextColor),
                            ),
                            const SizedBox(height: 6),
                            if (ms != null)
                              InkWell(
                                borderRadius: BorderRadius.circular(8),
                                onTap: () => _pickAudioStream(context, ms),
                                child: Padding(
                                  padding:
                                      const EdgeInsets.symmetric(vertical: 2),
                                  child: Text(
                                    '音频：${_currentAudioText()}',
                                    style: theme.textTheme.bodyMedium
                                        ?.copyWith(color: heroTextColor),
                                  ),
                                ),
                              )
                            else
                              Text(
                                '音频：${_currentAudioText()}',
                                style: theme.textTheme.bodyMedium
                                    ?.copyWith(color: heroTextColor),
                              ),
                            const SizedBox(height: 6),
                            if (ms != null)
                              InkWell(
                                borderRadius: BorderRadius.circular(8),
                                onTap: () => _pickSubtitleStream(context, ms),
                                child: Container(
                                  padding: const EdgeInsets.symmetric(
                                      horizontal: 10, vertical: 6),
                                  decoration: BoxDecoration(
                                    color: heroMetaBg,
                                    border: Border.all(color: heroMetaBorder),
                                    borderRadius: BorderRadius.circular(10),
                                  ),
                                  child: Row(
                                    mainAxisSize: MainAxisSize.min,
                                    children: [
                                      Text(
                                        '字幕：${_currentSubtitleText()}',
                                        style: theme.textTheme.bodyMedium
                                            ?.copyWith(color: heroTextColor),
                                      ),
                                      const SizedBox(width: 6),
                                      const Icon(Icons.expand_more,
                                          color: Colors.white, size: 18),
                                    ],
                                  ),
                                ),
                              )
                            else
                              Text(
                                '字幕：${_currentSubtitleText()}',
                                style: theme.textTheme.bodyMedium
                                    ?.copyWith(color: heroTextColor),
                              ),
                            const SizedBox(height: 12),
                            Wrap(
                              spacing: 10,
                              runSpacing: 10,
                              children: [
                                _episodeActionButton(
                                  icon: Icons.play_arrow,
                                  label: playLabel,
                                  primary: true,
                                  onTap: () => _playCurrentEpisode(
                                    startPosition:
                                        hasResume ? _ticksToDuration(ticks) : null,
                                  ),
                                ),
                                _episodeActionButton(
                                  icon: played
                                      ? Icons.check_circle
                                      : Icons.radio_button_unchecked,
                                  label: played ? '已播放' : '未播放',
                                  onTap:
                                      _markBusy ? null : _toggleEpisodePlayedMark,
                                ),
                                _episodeActionButton(
                                  icon: _localFavorite
                                      ? Icons.favorite
                                      : Icons.favorite_border,
                                  label: _localFavorite ? '已收藏' : '收藏',
                                  onTap: _favoriteLoaded
                                      ? _toggleLocalFavorite
                                      : null,
                                ),
                                _episodeActionButton(
                                  icon: Icons.more_horiz,
                                  label: '更多',
                                  onTap: () => _pickEpisode(context),
                                ),
                              ],
                            ),
                            if ((_detail?.overview ?? '').trim().isNotEmpty) ...[
                              const SizedBox(height: 12),
                              Text(
                                _detail!.overview,
                                maxLines: 3,
                                overflow: TextOverflow.ellipsis,
                                style: theme.textTheme.bodyMedium?.copyWith(
                                  color: heroMutedTextColor,
                                  height: 1.45,
                                ),
                              ),
                            ],
                          ],
                        );

                        final logo = Align(
                          alignment: Alignment.topRight,
                          child: Text(
                            seriesTitle,
                            maxLines: 2,
                            textAlign: TextAlign.right,
                            style: theme.textTheme.headlineMedium?.copyWith(
                              color: heroTextColor,
                              fontWeight: FontWeight.w900,
                              shadows: const [
                                Shadow(color: Colors.black54, blurRadius: 10),
                              ],
                            ),
                          ),
                        );

                        if (wide) {
                          return Row(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              SizedBox(width: 520, child: poster),
                              const SizedBox(width: 16),
                              Expanded(child: info),
                              const SizedBox(width: 12),
                              SizedBox(width: 220, child: logo),
                            ],
                          );
                        }
                        return Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            poster,
                            const SizedBox(height: 12),
                            info,
                            const SizedBox(height: 10),
                            logo,
                          ],
                        );
                      },
                    ),
                  ),
                  const SizedBox(height: 16),
                  if ((_seriesId ?? '').trim().isNotEmpty) ...[
                    _otherEpisodesSection(context),
                    const SizedBox(height: _DetailUiTokens.sectionGap),
                  ],
                  _externalLinksSection(context, ep, widget.appState),
                  if (_playInfo != null) ...[
                    const SizedBox(height: 16),
                    _episodePlaybackOptionsCard(context, _playInfo!),
                  ],
                  if (_playInfo != null) ...[
                    const SizedBox(height: 16),
                    _mediaInfo(
                      context,
                      _playInfo!,
                      selectedMediaSourceId: _selectedMediaSourceId,
                    ),
                  ],
                  if (_detail?.people.isNotEmpty == true && access != null) ...[
                    const SizedBox(height: _DetailUiTokens.sectionGap),
                    _castSection(
                      context,
                      _detail!.people,
                      access: access,
                    ),
                  ],
                  if (_chapters.isNotEmpty) ...[
                    const SizedBox(height: _DetailUiTokens.sectionGap),
                    _sectionTitle(context, '章节'),
                    const SizedBox(height: 8),
                    Wrap(
                      spacing: 8,
                      runSpacing: 8,
                      children: _chapters
                          .map((c) => Chip(label: Text('${c.name} ${_fmt(c.start)}')))
                          .toList(),
                    ),
                  ],
                ],
              ),
            ),
          ),
          Positioned.fill(child: _episodeTopNavOverlay()),
        ],
      ),
    );
  }

  Future<void> _loadSeriesEpisodes({
    required ServerAccess access,
    required MediaItem episodeDetail,
    required String seriesId,
    required String seriesName,
  }) async {
    try {
      final seasons =
          await access.adapter.fetchSeasons(access.auth, seriesId: seriesId);
      final seasonItems =
          seasons.items.where((s) => s.type.toLowerCase() == 'season').toList();
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
                name: '全部剧集',
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
                seriesName: seriesName,
                seasonName: '全部剧集',
                seasonNumber: null,
                episodeNumber: null,
                hasImage: episodeDetail.hasImage,
                playbackPositionTicks: 0,
                people: const [],
                parentId: seriesId,
              ),
            ]
          : seasonItems;

      final currentSeasonId =
          (episodeDetail.parentId ?? widget.episode.parentId ?? '').trim();
      final previousSeasonId = _selectedSeasonId;
      final selectedSeasonId = currentSeasonId.isNotEmpty &&
              seasonsForUi.any((s) => s.id == currentSeasonId)
          ? currentSeasonId
          : (previousSeasonId != null &&
                  seasonsForUi.any((s) => s.id == previousSeasonId))
              ? previousSeasonId
              : (seasonsForUi.isNotEmpty ? seasonsForUi.first.id : null);

      final episodesCacheForUi = <String, List<MediaItem>>{};
      if (selectedSeasonId != null && selectedSeasonId.isNotEmpty) {
        final eps = await access.adapter.fetchEpisodes(
          access.auth,
          seasonId: selectedSeasonId,
        );
        final items = List<MediaItem>.from(eps.items);
        items.sort((a, b) {
          final aNo = a.episodeNumber ?? 0;
          final bNo = b.episodeNumber ?? 0;
          return aNo.compareTo(bNo);
        });
        episodesCacheForUi[selectedSeasonId] = items;
      }

      if (!mounted) return;
      setState(() {
        _seasons = seasonsForUi;
        _seasonsVirtual = seasonsVirtual;
        _selectedSeasonId = selectedSeasonId;
        _episodesCache
          ..clear()
          ..addAll(episodesCacheForUi);
        _seriesError = null;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _seriesError = e.toString();
        _seasons = const [];
        _seasonsVirtual = false;
        _selectedSeasonId = null;
        _episodesCache.clear();
      });
    } finally {
      if (mounted) {
        setState(() {
          _seriesLoading = false;
        });
      }
    }
  }

  String _seasonLabel(MediaItem season, int index) {
    final name = season.name.trim();
    final seasonNo = season.seasonNumber ?? season.episodeNumber;
    return seasonNo != null
        ? '第$seasonNo季'
        : (name.isNotEmpty ? name : '第${index + 1}季');
  }

  MediaItem? get _selectedSeason {
    if (_seasons.isEmpty) return null;
    final selectedId = _selectedSeasonId;
    if (selectedId == null || selectedId.isEmpty) return _seasons.first;
    for (final s in _seasons) {
      if (s.id == selectedId) return s;
    }
    return _seasons.first;
  }

  String _selectedSeasonLabel() {
    if (_seasons.isEmpty) return '选择季';
    final selectedId = _selectedSeasonId;
    for (int i = 0; i < _seasons.length; i++) {
      final s = _seasons[i];
      if (selectedId != null && s.id == selectedId) return _seasonLabel(s, i);
    }
    return _seasonLabel(_seasons.first, 0);
  }

  Future<List<MediaItem>> _episodesForSeason(MediaItem season) async {
    final cached = _episodesCache[season.id];
    if (cached != null) return cached;
    final access =
        resolveServerAccess(appState: widget.appState, server: widget.server);
    if (access == null) return const [];

    final eps = await access.adapter.fetchEpisodes(
      access.auth,
      seasonId: season.id,
    );
    final items = List<MediaItem>.from(eps.items);
    items.sort((a, b) {
      final aNo = a.episodeNumber ?? 0;
      final bNo = b.episodeNumber ?? 0;
      return aNo.compareTo(bNo);
    });
    _episodesCache[season.id] = items;
    return items;
  }

  Future<void> _pickSeason(BuildContext context) async {
    if (_seasons.isEmpty) return;

    final selected = await showModalBottomSheet<String>(
      context: context,
      builder: (ctx) {
        return SafeArea(
          child: ListView(
            children: [
              const ListTile(title: Text('季选择')),
              ..._seasons.asMap().entries.map((entry) {
                final idx = entry.key;
                final s = entry.value;
                final selectedNow = s.id == _selectedSeasonId;
                return ListTile(
                  leading: Icon(
                      selectedNow ? Icons.check_circle : Icons.circle_outlined),
                  title: Text(_seasonLabel(s, idx)),
                  onTap: () => Navigator.of(ctx).pop(s.id),
                );
              }),
            ],
          ),
        );
      },
    );

    if (!mounted) return;
    if (selected == null || selected.isEmpty || selected == _selectedSeasonId) {
      return;
    }

    setState(() {
      _selectedSeasonId = selected;
    });

    final season = _selectedSeason;
    if (season == null) return;
    try {
      await _episodesForSeason(season);
    } catch (_) {
      // Episode list is optional for the UI.
    }
  }

  String _episodeLabel(MediaItem episode, int index) {
    final epNo = episode.episodeNumber ?? (index + 1);
    final epName = episode.name.trim();
    return epName.isNotEmpty ? '$epNo. $epName' : '第$epNo集';
  }

  Future<void> _pickEpisode(BuildContext context) async {
    final season = _selectedSeason;
    if (season == null) return;

    final seasonLabel = _selectedSeasonLabel();
    final selectedEp = await showModalBottomSheet<MediaItem>(
      context: context,
      isScrollControlled: true,
      builder: (ctx) {
        return SafeArea(
          child: DraggableScrollableSheet(
            expand: false,
            initialChildSize: widget.isTv ? 0.5 : 0.75,
            minChildSize: 0.4,
            maxChildSize: 0.95,
            builder: (ctx, controller) {
              return FutureBuilder<List<MediaItem>>(
                future: _episodesForSeason(season),
                builder: (ctx, snapshot) {
                  if (snapshot.connectionState != ConnectionState.done) {
                    return ListView(
                      controller: controller,
                      children: const [
                        ListTile(title: Text('选集')),
                        SizedBox(height: 24),
                        Center(child: CircularProgressIndicator()),
                      ],
                    );
                  }
                  if (snapshot.hasError) {
                    return ListView(
                      controller: controller,
                      children: [
                        const ListTile(title: Text('选集')),
                        Padding(
                          padding: const EdgeInsets.all(16),
                          child: Text('加载失败：${snapshot.error}'),
                        ),
                      ],
                    );
                  }
                  final eps = snapshot.data ?? const [];
                  if (eps.isEmpty) {
                    return ListView(
                      controller: controller,
                      children: const [
                        ListTile(title: Text('选集')),
                        Padding(
                          padding: EdgeInsets.all(16),
                          child: Text('暂无剧集'),
                        ),
                      ],
                    );
                  }
                  return ListView.builder(
                    controller: controller,
                    itemCount: eps.length + 1,
                    itemBuilder: (ctx, idx) {
                      if (idx == 0) {
                        return ListTile(title: Text('选集（$seasonLabel）'));
                      }
                      final epIndex = idx - 1;
                      final ep = eps[epIndex];
                      final isCurrent = ep.id == widget.episode.id;
                      return ListTile(
                        leading: Icon(
                          isCurrent
                              ? Icons.check_circle
                              : Icons.play_circle_outline,
                        ),
                        title: Text(_episodeLabel(ep, epIndex)),
                        onTap: () => Navigator.of(ctx).pop(ep),
                      );
                    },
                  );
                },
              );
            },
          ),
        );
      },
    );

    if (!mounted ||
        !context.mounted ||
        selectedEp == null ||
        selectedEp.id.isEmpty) {
      return;
    }
    if (selectedEp.id == widget.episode.id) {
      return;
    }
    Navigator.of(context).pushReplacement(
      MaterialPageRoute(
        builder: (_) => EpisodeDetailPage(
          episode: selectedEp,
          appState: widget.appState,
          server: widget.server,
          isTv: widget.isTv,
        ),
      ),
    );
  }

  void _openSeasonEpisodesPage(BuildContext context, MediaItem season) {
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => SeasonEpisodesPage(
          season: season,
          appState: widget.appState,
          server: widget.server,
          isTv: widget.isTv,
          isVirtual: _seasonsVirtual,
        ),
      ),
    );
  }

  Widget _otherEpisodesSection(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final season = _selectedSeason;
    final seasonText = _selectedSeasonLabel();
    final epAccess =
        resolveServerAccess(appState: widget.appState, server: widget.server);
    final controls = Wrap(
      spacing: 8,
      runSpacing: 8,
      children: [
        FilledButton.tonalIcon(
          onPressed: season == null ? null : () => _openSeasonEpisodesPage(context, season),
          icon: const Icon(Icons.grid_view_rounded, size: 16),
          label: const Text('查看全部'),
        ),
        FilledButton.tonalIcon(
          onPressed: _seasons.isEmpty ? null : () => _pickSeason(context),
          icon: const Icon(Icons.layers_outlined, size: 16),
          label: const Text('切换季'),
        ),
        FilledButton.tonalIcon(
          onPressed: season == null ? null : () => _pickEpisode(context),
          icon: const Icon(Icons.format_list_numbered, size: 16),
          label: const Text('选集'),
        ),
      ],
    );

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _sectionTitle(context, '更多来自：$seasonText'),
        const SizedBox(height: 8),
        controls,
        if (_seriesError != null) ...[
          const SizedBox(height: 8),
          Text(
            '加载剧集失败：$_seriesError',
            style: theme.textTheme.bodySmall?.copyWith(
              color: scheme.error,
            ),
          ),
        ],
        const SizedBox(height: 8),
        if (season == null && _seriesLoading)
          const SizedBox(
            height: 180,
            child: Center(child: CircularProgressIndicator()),
          ),
        if (season != null)
          SizedBox(
            height: _DetailUiTokens.horizontalEpisodeStripHeight,
            child: FutureBuilder<List<MediaItem>>(
              future: _episodesForSeason(season),
              builder: (ctx, snapshot) {
                if (snapshot.connectionState != ConnectionState.done) {
                  return const Center(child: CircularProgressIndicator());
                }
                if (snapshot.hasError) {
                  return Center(child: Text('加载剧集失败：${snapshot.error}'));
                }
                final eps = snapshot.data ?? const [];
                if (eps.isEmpty) {
                  return const Center(child: Text('暂无剧集'));
                }
                return _withHorizontalEdgeFade(
                  context,
                  child: ListView.separated(
                    scrollDirection: Axis.horizontal,
                    itemCount: eps.length,
                    separatorBuilder: (_, __) =>
                        const SizedBox(width: _DetailUiTokens.horizontalGap),
                    itemBuilder: (context, index) {
                      final e = eps[index];
                      final isCurrent = e.id == widget.episode.id;
                      final epNo = e.episodeNumber ?? (index + 1);
                      final img = epAccess == null
                          ? ''
                          : epAccess.adapter.imageUrl(
                              epAccess.auth,
                              itemId: e.hasImage ? e.id : season.id,
                              maxWidth: 700,
                            );
                      return _HoverScale(
                        child: SizedBox(
                          width: _DetailUiTokens.horizontalEpisodeCardWidth,
                          child: Material(
                            color: Colors.transparent,
                            child: InkWell(
                              borderRadius:
                                  BorderRadius.circular(_DetailUiTokens.cardRadius),
                              onTap: () {
                                if (isCurrent) return;
                                Navigator.of(context).pushReplacement(
                                  MaterialPageRoute(
                                    builder: (_) => EpisodeDetailPage(
                                      episode: e,
                                      appState: widget.appState,
                                      server: widget.server,
                                      isTv: widget.isTv,
                                    ),
                                  ),
                                );
                              },
                              child: Ink(
                                decoration: BoxDecoration(
                                  borderRadius:
                                      BorderRadius.circular(_DetailUiTokens.cardRadius),
                                  border: Border.all(
                                    color: isCurrent
                                        ? scheme.primary
                                        : Colors.white.withValues(alpha: 0.24),
                                    width: isCurrent ? 1.4 : 1.0,
                                  ),
                                ),
                                child: Stack(
                                  fit: StackFit.expand,
                                  children: [
                                    ClipRRect(
                                      borderRadius:
                                          BorderRadius.circular(_DetailUiTokens.cardRadius),
                                      child: img.isEmpty
                                          ? const ColoredBox(color: Colors.black26)
                                          : Image.network(
                                              img,
                                              fit: BoxFit.cover,
                                              headers: {
                                                'User-Agent':
                                                    LinHttpClientFactory.userAgent
                                              },
                                              errorBuilder: (_, __, ___) =>
                                                  const ColoredBox(
                                                      color: Colors.black26),
                                            ),
                                    ),
                                    Align(
                                      alignment: Alignment.bottomCenter,
                                      child: DecoratedBox(
                                        decoration: BoxDecoration(
                                          gradient: LinearGradient(
                                            begin: Alignment.topCenter,
                                            end: Alignment.bottomCenter,
                                            colors: [
                                              Colors.transparent,
                                              Colors.black.withValues(alpha: 0.8),
                                            ],
                                          ),
                                        ),
                                        child: SizedBox(
                                          width: double.infinity,
                                          child: Padding(
                                            padding: const EdgeInsets.fromLTRB(
                                                10, 18, 10, 10),
                                            child: Text(
                                              '$epNo. ${e.name.trim().isNotEmpty ? e.name.trim() : '第$epNo集'}',
                                              maxLines: 1,
                                              overflow: TextOverflow.ellipsis,
                                              style: theme.textTheme.bodyMedium
                                                  ?.copyWith(
                                                color: Colors.white,
                                                fontWeight: isCurrent
                                                    ? FontWeight.w700
                                                    : FontWeight.w500,
                                              ),
                                            ),
                                          ),
                                        ),
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                            ),
                          ),
                        ),
                      );
                    },
                  ),
                );
              },
            ),
          ),
      ],
    );
  }
}

String _fmt(Duration d) {
  final h = d.inHours;
  final m = d.inMinutes.remainder(60);
  final s = d.inSeconds.remainder(60);
  if (h > 0) return '${h}h ${m}m ${s}s';
  return '${m}m ${s}s';
}

Duration _ticksToDuration(int ticks) =>
    Duration(microseconds: (ticks / 10).round());

String _fmtClock(Duration d) {
  final h = d.inHours;
  final m = d.inMinutes.remainder(60);
  final s = d.inSeconds.remainder(60);
  if (h > 0) {
    return '${h.toString().padLeft(2, '0')}:${m.toString().padLeft(2, '0')}:${s.toString().padLeft(2, '0')}';
  }
  return '${m.toString().padLeft(2, '0')}:${s.toString().padLeft(2, '0')}';
}

Widget _chaptersSection(BuildContext context, List<ChapterInfo> chapters) {
  final width = MediaQuery.of(context).size.width;
  final crossAxisCount = width >= 900 ? 4 : (width >= 600 ? 3 : 2);
  return Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      _sectionTitle(context, '章节'),
      const SizedBox(height: 8),
      GridView.builder(
        shrinkWrap: true,
        physics: const NeverScrollableScrollPhysics(),
        gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
          crossAxisCount: crossAxisCount,
          mainAxisSpacing: 12,
          crossAxisSpacing: 12,
          childAspectRatio: 16 / 9,
        ),
        itemCount: chapters.length,
        itemBuilder: (context, index) {
          final c = chapters[index];
          return Card(
            clipBehavior: Clip.antiAlias,
            child: Padding(
              padding: const EdgeInsets.all(12),
              child: Row(
                children: [
                  const Icon(Icons.menu_book, size: 28),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          c.name.isNotEmpty ? c.name : 'Chapter ${index + 1}',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                        const SizedBox(height: 4),
                        Text(
                          _fmt(c.start),
                          style: Theme.of(context).textTheme.bodySmall,
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          );
        },
      ),
    ],
  );
}

Widget _pill(BuildContext context, String text) {
  final theme = Theme.of(context);
  return Container(
    padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
    decoration: BoxDecoration(
      color: Colors.black.withValues(alpha: 0.30),
      borderRadius: BorderRadius.circular(20),
      border: Border.all(color: Colors.white.withValues(alpha: 0.24)),
    ),
    child: Text(
      text,
      style: theme.textTheme.labelMedium?.copyWith(
            color: Colors.white,
            fontWeight: FontWeight.w700,
          ) ??
          const TextStyle(
            color: Colors.white,
            fontWeight: FontWeight.w700,
          ),
    ),
  );
}

Widget _playButton(BuildContext context,
    {required String label, required VoidCallback onTap}) {
  final theme = Theme.of(context);
  final scheme = theme.colorScheme;
  final style = theme.extension<AppStyle>() ?? const AppStyle();
  final isDark = scheme.brightness == Brightness.dark;

  final radius = switch (style.template) {
    UiTemplate.neonHud => 14.0,
    UiTemplate.pixelArcade => 12.0,
    UiTemplate.mangaStoryboard => 12.0,
    UiTemplate.proTool => 16.0,
    UiTemplate.stickerJournal => 20.0,
    _ => 30.0,
  };

  final (Color bg, Color fg, BorderSide border, Color glow) =
      switch (style.template) {
    UiTemplate.neonHud => (
        scheme.surface.withValues(alpha: isDark ? 0.55 : 0.90),
        scheme.primary,
        BorderSide(
          color: scheme.primary.withValues(alpha: isDark ? 0.85 : 0.95),
          width: 1.4,
        ),
        scheme.primary.withValues(alpha: isDark ? 0.22 : 0.14),
      ),
    UiTemplate.pixelArcade => (
        scheme.surface.withValues(alpha: isDark ? 0.70 : 0.92),
        scheme.secondary,
        BorderSide(
          color: scheme.secondary.withValues(alpha: isDark ? 0.85 : 0.95),
          width: 1.8,
        ),
        Colors.transparent,
      ),
    UiTemplate.mangaStoryboard => (
        scheme.surface,
        scheme.onSurface,
        BorderSide(
          color: scheme.onSurface.withValues(alpha: isDark ? 0.70 : 0.90),
          width: 1.8,
        ),
        Colors.transparent,
      ),
    UiTemplate.stickerJournal => (
        scheme.secondaryContainer,
        scheme.onSecondaryContainer,
        BorderSide(
          color: scheme.secondary.withValues(alpha: isDark ? 0.55 : 0.75),
          width: 1.2,
        ),
        Colors.transparent,
      ),
    UiTemplate.candyGlass => (
        scheme.primaryContainer,
        scheme.onPrimaryContainer,
        BorderSide.none,
        Colors.transparent,
      ),
    UiTemplate.washiWatercolor => (
        scheme.primaryContainer,
        scheme.onPrimaryContainer,
        BorderSide.none,
        Colors.transparent,
      ),
    UiTemplate.proTool => (
        scheme.surfaceContainerHigh,
        scheme.onSurface,
        BorderSide(
          color: scheme.outlineVariant.withValues(alpha: isDark ? 0.55 : 0.70),
          width: 1.1,
        ),
        Colors.transparent,
      ),
    UiTemplate.minimalCovers => (
        scheme.primaryContainer,
        scheme.onPrimaryContainer,
        BorderSide.none,
        Colors.transparent,
      ),
  };

  return Material(
    color: Colors.transparent,
    child: InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(radius),
      child: Ink(
        width: double.infinity,
        padding: const EdgeInsets.symmetric(vertical: 14),
        decoration: BoxDecoration(
          color: bg,
          borderRadius: BorderRadius.circular(radius),
          border:
              border == BorderSide.none ? null : Border.fromBorderSide(border),
          boxShadow: glow == Colors.transparent
              ? null
              : [
                  BoxShadow(
                    color: glow,
                    blurRadius: 22,
                    spreadRadius: 1,
                  ),
                ],
        ),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.center,
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.play_arrow, color: fg),
            const SizedBox(width: 6),
            Text(
              label,
              style: theme.textTheme.titleSmall?.copyWith(
                    color: fg,
                    fontWeight: FontWeight.w800,
                    letterSpacing:
                        style.template == UiTemplate.neonHud ? 0.25 : null,
                  ) ??
                  TextStyle(
                    color: fg,
                    fontWeight: FontWeight.w800,
                    fontSize: 16,
                  ),
            ),
          ],
        ),
      ),
    ),
  );
}

Widget _withHorizontalEdgeFade(
  BuildContext context, {
  required Widget child,
  double fadeWidth = 18,
}) {
  final background = Theme.of(context).scaffoldBackgroundColor;
  return Stack(
    children: [
      Positioned.fill(child: child),
      Positioned.fill(
        child: IgnorePointer(
          child: Row(
            children: [
              Container(
                width: fadeWidth,
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                    begin: Alignment.centerLeft,
                    end: Alignment.centerRight,
                    colors: [
                      background,
                      background.withValues(alpha: 0),
                    ],
                  ),
                ),
              ),
              const Spacer(),
              Container(
                width: fadeWidth,
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                    begin: Alignment.centerLeft,
                    end: Alignment.centerRight,
                    colors: [
                      background.withValues(alpha: 0),
                      background,
                    ],
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    ],
  );
}

class _HoverScale extends StatefulWidget {
  const _HoverScale({
    required this.child,
  });

  final Widget child;

  @override
  State<_HoverScale> createState() => _HoverScaleState();
}

class _HoverScaleState extends State<_HoverScale> {
  bool _hovered = false;

  bool get _supportsHover {
    if (kIsWeb) return true;
    switch (defaultTargetPlatform) {
      case TargetPlatform.windows:
      case TargetPlatform.macOS:
      case TargetPlatform.linux:
        return true;
      case TargetPlatform.android:
      case TargetPlatform.iOS:
      case TargetPlatform.fuchsia:
        return false;
    }
  }

  @override
  Widget build(BuildContext context) {
    if (!_supportsHover) return widget.child;
    return MouseRegion(
      onEnter: (_) => setState(() => _hovered = true),
      onExit: (_) => setState(() => _hovered = false),
      child: AnimatedScale(
        scale: _hovered ? 1.05 : 1,
        duration: const Duration(milliseconds: 140),
        curve: Curves.easeOut,
        child: widget.child,
      ),
    );
  }
}

Widget _peopleSection(
  BuildContext context,
  List<MediaPerson> people, {
  required ServerAccess access,
}) {
  final scheme = Theme.of(context).colorScheme;
  final avatarBg = scheme.surfaceContainerHighest.withValues(
    alpha: scheme.brightness == Brightness.dark ? 0.55 : 0.88,
  );
  final roleColor = scheme.onSurfaceVariant;
  return Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      _sectionTitle(context, '演职人员'),
      const SizedBox(height: 8),
      SizedBox(
        height: 150,
        child: _withHorizontalEdgeFade(
          context,
          child: ListView.separated(
            scrollDirection: Axis.horizontal,
            itemCount: people.length,
            separatorBuilder: (_, __) => const SizedBox(width: 12),
            itemBuilder: (context, index) {
              final p = people[index];
              final img = access.adapter.personImageUrl(
                access.auth,
                personId: p.id,
                maxWidth: 200,
              );
              return _HoverScale(
                child: Column(
                  children: [
                    CircleAvatar(
                      radius: 42,
                      backgroundImage: img.isNotEmpty ? NetworkImage(img) : null,
                      backgroundColor: avatarBg,
                      child: img.isEmpty
                          ? Text(p.name.isNotEmpty ? p.name[0] : '?')
                          : null,
                    ),
                    const SizedBox(height: 6),
                    Text(p.name, maxLines: 1, overflow: TextOverflow.ellipsis),
                    Text(
                      p.role,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: Theme.of(context).textTheme.bodySmall?.copyWith(
                            color: roleColor,
                          ),
                    ),
                  ],
                ),
              );
            },
          ),
        ),
      ),
    ],
  );
}

Widget _castSection(
  BuildContext context,
  List<MediaPerson> people, {
  required ServerAccess access,
}) {
  final scheme = Theme.of(context).colorScheme;
  final avatarBg = scheme.surfaceContainerHighest.withValues(
    alpha: scheme.brightness == Brightness.dark ? 0.55 : 0.88,
  );
  final roleColor = scheme.onSurfaceVariant;
  return Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      _sectionTitle(context, '演职人员'),
      const SizedBox(height: 8),
      SizedBox(
        height: 162,
        child: _withHorizontalEdgeFade(
          context,
          child: ListView.separated(
            scrollDirection: Axis.horizontal,
            itemCount: people.length,
            separatorBuilder: (_, __) => const SizedBox(width: 12),
            itemBuilder: (context, index) {
              final p = people[index];
              final img = access.adapter.personImageUrl(
                access.auth,
                personId: p.id,
                maxWidth: 220,
              );
              return _HoverScale(
                child: SizedBox(
                  width: 108,
                  child: Column(
                    children: [
                      CircleAvatar(
                        radius: 42,
                        backgroundImage: img.isNotEmpty ? NetworkImage(img) : null,
                        backgroundColor: avatarBg,
                        child: img.isEmpty
                            ? Text(p.name.isNotEmpty ? p.name[0] : '?')
                            : null,
                      ),
                      const SizedBox(height: 8),
                      Text(
                        p.name,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        textAlign: TextAlign.center,
                      ),
                      Text(
                        p.role,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        textAlign: TextAlign.center,
                        style: Theme.of(context).textTheme.bodySmall?.copyWith(
                              color: roleColor,
                            ),
                      ),
                    ],
                  ),
                ),
              );
            },
          ),
        ),
      ),
    ],
  );
}

Widget _mediaInfo(
  BuildContext context,
  PlaybackInfoResult info, {
  String? selectedMediaSourceId,
}) {
  final map =
      _ShowDetailPageState._findMediaSource(info, selectedMediaSourceId) ??
          (info.mediaSources.first as Map<String, dynamic>);
  final streams = (map['MediaStreams'] as List?) ?? const [];
  final video = streams
      .where((e) => (e as Map)['Type'] == 'Video')
      .map((e) => e as Map)
      .toList();
  final audio = streams
      .where((e) => (e as Map)['Type'] == 'Audio')
      .map((e) => e as Map)
      .toList();
  final subtitle = streams
      .where((e) => (e as Map)['Type'] == 'Subtitle')
      .map((e) => e as Map)
      .toList();
  return Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      _sectionTitle(context, '媒体源信息'),
      const SizedBox(height: 8),
      Wrap(
        spacing: 12,
        runSpacing: 12,
        children: [
          _infoCard(
              '视频',
              video.map((v) {
                final title = (v['DisplayTitle'] ?? '').toString().trim();
                final codec = (v['Codec'] ?? '').toString().trim();
                final aspect =
                    _formatVideoAspectRatio(v.cast<String, dynamic>());
                final parts = <String>[
                  if (title.isNotEmpty) title,
                  if (codec.isNotEmpty) codec,
                  if (aspect != null) '视频比例：$aspect',
                ];
                return parts.join('\n');
              }).join('\n\n')),
          _infoCard(
              '音频',
              audio
                  .map((a) => '${a['DisplayTitle'] ?? ''}\n${a['Codec'] ?? ''}')
                  .join('\n')),
          _infoCard(
              '字幕',
              subtitle.isEmpty
                  ? '无'
                  : subtitle
                      .take(3)
                      .map((s) =>
                          '${s['DisplayTitle'] ?? s['Language'] ?? ''}\n${s['Codec'] ?? ''}')
                      .join('\n\n')),
        ],
      ),
    ],
  );
}

String? _formatVideoAspectRatio(Map<String, dynamic> stream) {
  final raw = stream['AspectRatio'];
  if (raw is String) {
    final trimmed = raw.trim();
    if (trimmed.isEmpty) return null;
    if (trimmed.contains(':')) return trimmed;
    final n = double.tryParse(trimmed);
    if (n != null && n.isFinite && n > 0) return _formatAspectRatioValue(n);
    return trimmed;
  }

  final width = _ShowDetailPageState._asInt(stream['Width']);
  final height = _ShowDetailPageState._asInt(stream['Height']);
  if (width == null || height == null || width <= 0 || height <= 0) {
    return null;
  }
  return _formatAspectRatioValue(width / height, width: width, height: height);
}

String _formatAspectRatioValue(
  double ratio, {
  int? width,
  int? height,
}) {
  const known = <String, double>{
    '1:1': 1.0,
    '4:3': 4 / 3,
    '3:2': 3 / 2,
    '16:9': 16 / 9,
    '21:9': 21 / 9,
    '2:1': 2.0,
    '1.85:1': 1.85,
    '2.39:1': 2.39,
  };
  const tol = 0.03;
  for (final e in known.entries) {
    if ((ratio - e.value).abs() <= tol) return e.key;
  }

  if (width != null &&
      height != null &&
      width > 0 &&
      height > 0 &&
      width < 100000 &&
      height < 100000) {
    final g = _gcd(width, height);
    if (g > 0) {
      final a = (width / g).round();
      final b = (height / g).round();
      if (a > 0 && b > 0 && a <= 100 && b <= 100) return '$a:$b';
    }
  }

  return ratio.toStringAsFixed(2);
}

int _gcd(int a, int b) {
  var x = a.abs();
  var y = b.abs();
  while (y != 0) {
    final t = x % y;
    x = y;
    y = t;
  }
  return x;
}

Widget _infoCard(String title, String body) => SizedBox(
      width: 240,
      child: _detailGlassPanel(
        enableBlur: true,
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              title,
              style: const TextStyle(
                color: Colors.white,
                fontWeight: FontWeight.w700,
              ),
            ),
            const SizedBox(height: 8),
            Text(
              body.isEmpty ? '无' : body,
              style: const TextStyle(
                color: Colors.white70,
                fontSize: 12,
                height: 1.4,
              ),
              maxLines: 18,
              overflow: TextOverflow.ellipsis,
            ),
          ],
        ),
      ),
    );

String _providerId(MediaItem item, List<String> providerKeys) {
  for (final entry in item.providerIds.entries) {
    final key = entry.key.toLowerCase();
    if (providerKeys.any((k) => key.contains(k))) {
      final value = entry.value.trim();
      if (value.isNotEmpty) return value;
    }
  }
  return '';
}

Widget _externalLinksSection(
    BuildContext context, MediaItem item, AppState appState) {
  final isSeries = item.type.toLowerCase() == 'series';
  final tmdbId = _providerId(item, const ['tmdb']);
  final imdbId = _providerId(item, const ['imdb']);
  final traktId = _providerId(item, const ['trakt']);

  final tmdbUrl = tmdbId.isEmpty
      ? ''
      : (isSeries
          ? 'https://www.themoviedb.org/tv/$tmdbId'
          : 'https://www.themoviedb.org/movie/$tmdbId');
  final imdbUrl = imdbId.isEmpty ? '' : 'https://www.imdb.com/title/$imdbId';
  final traktUrl = traktId.isNotEmpty
      ? (isSeries
          ? 'https://trakt.tv/shows/$traktId'
          : 'https://trakt.tv/movies/$traktId')
      : (imdbId.isNotEmpty
          ? 'https://trakt.tv/search/imdb/$imdbId'
          : (tmdbId.isNotEmpty ? 'https://trakt.tv/search/tmdb/$tmdbId' : ''));

  final links = <({String label, String url, IconData icon})>[
    if (imdbUrl.isNotEmpty) (label: 'IMDb', url: imdbUrl, icon: Icons.movie),
    if (tmdbUrl.isNotEmpty)
      (label: 'TheMovieDb', url: tmdbUrl, icon: Icons.local_movies),
    if (traktUrl.isNotEmpty) (label: 'Trakt', url: traktUrl, icon: Icons.link),
  ];
  if (links.isEmpty) return const SizedBox.shrink();

  Future<void> openExternal(String url) async {
    final opened = await launchUrlString(url);
    if (!opened && context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('无法打开链接')),
      );
    }
  }

  return Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      _sectionTitle(context, '数据库链接'),
      const SizedBox(height: 8),
      Wrap(
        spacing: 8,
        runSpacing: 8,
        children: links
            .map(
              (link) => ActionChip(
                avatar: Icon(link.icon, size: 18),
                label: Text(link.label),
                labelStyle: const TextStyle(color: Colors.white),
                side: BorderSide(color: Colors.white.withValues(alpha: 0.24)),
                backgroundColor: Colors.black.withValues(alpha: 0.30),
                onPressed: () => openExternal(link.url),
              ),
            )
            .toList(),
      )
    ],
  );
}

