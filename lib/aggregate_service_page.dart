import 'dart:async';

import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';

import 'services/cover_cache_manager.dart';
import 'services/emby_api.dart';
import 'server_adapters/server_access.dart';
import 'show_detail_page.dart';
import 'src/device/device_type.dart';
import 'src/ui/app_components.dart';
import 'src/ui/glass_blur.dart';
import 'src/ui/server_icon_picker.dart';
import 'state/app_state.dart';
import 'state/server_profile.dart';

class AggregateServicePage extends StatefulWidget {
  const AggregateServicePage({super.key, required this.appState});

  final AppState appState;

  @override
  State<AggregateServicePage> createState() => _AggregateServicePageState();
}

class _AggregateServicePageState extends State<AggregateServicePage> {
  @override
  Widget build(BuildContext context) {
    final isTv = DeviceType.isTv;
    final enableBlur = !isTv && widget.appState.enableBlurEffects;

    return DefaultTabController(
      length: 2,
      child: Scaffold(
        appBar: GlassAppBar(
          enableBlur: enableBlur,
          child: AppBar(
            title: const Text('\u805a\u5408\u670d\u52a1'),
            bottom: const TabBar(
              tabs: [
                Tab(text: '\u89c2\u770b\u8bb0\u5f55'),
                Tab(text: '\u805a\u5408\u641c\u7d22'),
              ],
            ),
          ),
        ),
        body: TabBarView(
          children: [
            _AggregateWatchHistoryTab(appState: widget.appState),
            _AggregateSearchTab(appState: widget.appState),
          ],
        ),
      ),
    );
  }
}

class _ServerContinueWatchingState {
  final bool loading;
  final String? error;
  final List<MediaItem> items;

  const _ServerContinueWatchingState({
    required this.loading,
    required this.error,
    required this.items,
  });
}

class _AggregateWatchHistoryTab extends StatefulWidget {
  const _AggregateWatchHistoryTab({required this.appState});

  final AppState appState;

  @override
  State<_AggregateWatchHistoryTab> createState() =>
      _AggregateWatchHistoryTabState();
}

class _AggregateWatchHistoryTabState extends State<_AggregateWatchHistoryTab> {
  static const _limit = 60;
  int _loadSeq = 0;
  final Map<String, _ServerContinueWatchingState> _stateByServer = {};

  @override
  void initState() {
    super.initState();
    unawaited(_reload());
  }

  Future<void> _reload() async {
    final seq = ++_loadSeq;
    final servers = widget.appState.servers;
    setState(() {
      for (final s in servers) {
        final prev = _stateByServer[s.id];
        _stateByServer[s.id] = _ServerContinueWatchingState(
          loading: true,
          error: null,
          items: prev?.items ?? const [],
        );
      }
    });

    await Future.wait<void>(
      servers.map((s) => _loadOne(s, seq)),
    );
  }

  Future<void> _loadOne(ServerProfile server, int seq) async {
    final baseUrl = server.baseUrl.trim();
    final token = server.token.trim();
    final userId = server.userId.trim();
    if (baseUrl.isEmpty || token.isEmpty || userId.isEmpty) {
      if (!mounted || seq != _loadSeq) return;
      setState(() {
        _stateByServer[server.id] = const _ServerContinueWatchingState(
          loading: false,
          error: '服务器信息不完整',
          items: [],
        );
      });
      return;
    }

    final access =
        resolveServerAccess(appState: widget.appState, server: server);
    if (access == null) {
      if (!mounted || seq != _loadSeq) return;
      setState(() {
        _stateByServer[server.id] = const _ServerContinueWatchingState(
          loading: false,
          error: 'Unsupported server',
          items: [],
        );
      });
      return;
    }

    try {
      final res =
          await access.adapter.fetchContinueWatching(access.auth, limit: _limit);
      if (!mounted || seq != _loadSeq) return;
      setState(() {
        _stateByServer[server.id] = _ServerContinueWatchingState(
          loading: false,
          error: null,
          items: res.items,
        );
      });
    } catch (e) {
      if (!mounted || seq != _loadSeq) return;
      setState(() {
        _stateByServer[server.id] = _ServerContinueWatchingState(
          loading: false,
          error: e.toString(),
          items: const [],
        );
      });
    }
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

  String _episodeTag(MediaItem item) {
    final s = item.seasonNumber ?? 0;
    final e = item.episodeNumber ?? 0;
    if (s <= 0 && e <= 0) return '';
    if (s > 0 && e > 0) {
      return 'S${s.toString().padLeft(2, '0')}E${e.toString().padLeft(2, '0')}';
    }
    if (e > 0) return 'E${e.toString().padLeft(2, '0')}';
    return 'S${s.toString().padLeft(2, '0')}';
  }

  List<MediaItem> _latestWatchPerSeries(List<MediaItem> items) {
    final visible = items.where((e) => e.playbackPositionTicks > 0).toList();
    if (visible.isEmpty) return const [];

    final seenSeries = <String>{};
    final result = <MediaItem>[];
    for (final item in visible) {
      final isEpisode = item.type.toLowerCase() == 'episode';
      if (!isEpisode) {
        result.add(item);
        continue;
      }

      final seriesId = item.seriesId?.trim() ?? '';
      final seriesName = item.seriesName.trim();
      final seriesKey = seriesId.isNotEmpty
          ? seriesId
          : (seriesName.isNotEmpty
              ? 'name:${seriesName.toLowerCase()}'
              : item.id);

      if (seenSeries.add(seriesKey)) {
        result.add(item);
      }
    }
    return result;
  }

  @override
  Widget build(BuildContext context) {
    final servers = widget.appState.servers;
    final isTv = DeviceType.isTv;

    if (servers.isEmpty) {
      return const Center(child: Text('暂无服务器'));
    }

    return RefreshIndicator(
      onRefresh: _reload,
      child: ListView.builder(
        padding: const EdgeInsets.only(bottom: 24),
        itemCount: servers.length,
        itemBuilder: (context, index) {
          final server = servers[index];
          final state = _stateByServer[server.id] ??
              const _ServerContinueWatchingState(
                loading: true,
                error: null,
                items: [],
              );

          final visibleItems = _latestWatchPerSeries(state.items);
          final headerSubtitle = state.loading
              ? '加载中…'
              : (state.error != null
                  ? '加载失败'
                  : (visibleItems.isEmpty
                      ? '暂无记录'
                      : '${visibleItems.length} 条'));

          return ExpansionTile(
            initiallyExpanded: index == 0,
            leading: ServerIconAvatar(
              iconUrl: server.iconUrl,
              name: server.name,
              radius: 18,
            ),
            title:
                Text(server.name, maxLines: 1, overflow: TextOverflow.ellipsis),
            subtitle: Text(headerSubtitle),
            childrenPadding: const EdgeInsets.fromLTRB(12, 0, 12, 12),
            children: [
              if (state.error != null)
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 12),
                  child: Text(
                    state.error!,
                    style: TextStyle(
                      color: Theme.of(context).colorScheme.error,
                      fontSize: 12,
                    ),
                  ),
                )
              else if (visibleItems.isEmpty && !state.loading)
                const Padding(
                  padding: EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                  child: Text('暂无观看记录'),
                )
              else if (state.loading && visibleItems.isEmpty)
                const Padding(
                  padding: EdgeInsets.symmetric(vertical: 12),
                  child: Center(child: CircularProgressIndicator()),
                )
              else
                ListView.separated(
                  shrinkWrap: true,
                  physics: const NeverScrollableScrollPhysics(),
                  itemCount: visibleItems.length,
                  separatorBuilder: (_, __) => const SizedBox(height: 8),
                  itemBuilder: (context, i) {
                    final item = visibleItems[i];
                    final isEpisode = item.type.toLowerCase() == 'episode';
                    final title = isEpisode && item.seriesName.trim().isNotEmpty
                        ? item.seriesName
                        : item.name;
                    final pos = _ticksToDuration(item.playbackPositionTicks);
                    final tag = isEpisode ? _episodeTag(item) : '';
                    final subParts = <String>[
                      if (tag.isNotEmpty) tag,
                      if (pos > Duration.zero) '续播 ${_fmtClock(pos)}',
                    ];
                    final subtitle = subParts.join(' · ');

                     final img = item.hasImage
                         ? EmbyApi.imageUrl(
                             baseUrl: server.baseUrl,
                             itemId: item.id,
                             token: server.token,
                             apiPrefix: server.apiPrefix,
                             imageType: 'Primary',
                             maxWidth: 320,
                           )
                         : '';

                    return Card(
                      clipBehavior: Clip.antiAlias,
                      child: ListTile(
                        leading: img.isEmpty
                            ? const SizedBox(
                                width: 56,
                                height: 56,
                                child: Icon(Icons.image_outlined),
                              )
                            : ClipRRect(
                                borderRadius: BorderRadius.circular(8),
                                child: CachedNetworkImage(
                                  imageUrl: img,
                                  cacheManager: CoverCacheManager.instance,
                                  httpHeaders: {
                                    'User-Agent': EmbyApi.userAgent,
                                  },
                                  width: 56,
                                  height: 56,
                                  fit: BoxFit.cover,
                                  placeholder: (_, __) => const SizedBox(
                                    width: 56,
                                    height: 56,
                                    child: ColoredBox(
                                      color: Colors.black12,
                                      child: Center(
                                        child: Icon(Icons.image_outlined),
                                      ),
                                    ),
                                  ),
                                  errorWidget: (_, __, ___) => const SizedBox(
                                    width: 56,
                                    height: 56,
                                    child: Center(
                                      child: Icon(Icons.broken_image_outlined),
                                    ),
                                  ),
                                ),
                              ),
                        title: Text(
                          title,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                        subtitle: subtitle.isEmpty ? null : Text(subtitle),
                        trailing: state.loading
                            ? const SizedBox(
                                width: 16,
                                height: 16,
                                child:
                                    CircularProgressIndicator(strokeWidth: 2),
                              )
                            : null,
                        onTap: () {
                          Navigator.of(context).push(
                            MaterialPageRoute(
                              builder: (_) => isEpisode
                                  ? EpisodeDetailPage(
                                      episode: item,
                                      appState: widget.appState,
                                      server: server,
                                      isTv: isTv,
                                    )
                                  : ShowDetailPage(
                                      itemId: item.id,
                                      title: item.name,
                                      appState: widget.appState,
                                      server: server,
                                      isTv: isTv,
                                    ),
                            ),
                          );
                        },
                      ),
                    );
                  },
                ),
            ],
          );
        },
      ),
    );
  }
}

class _AggregateSearchTab extends StatelessWidget {
  const _AggregateSearchTab({required this.appState});

  final AppState appState;

  @override
  Widget build(BuildContext context) =>
      _AggregateSearchTabStateful(appState: appState);
}

class _ServerSearchHit {
  final ServerProfile server;
  final MediaItem item;

  const _ServerSearchHit({required this.server, required this.item});
}

class _WorkGroup {
  final String key;
  final String title;
  final String type; // Series / Movie
  final int? year;
  final List<_ServerSearchHit> hits;

  const _WorkGroup({
    required this.key,
    required this.title,
    required this.type,
    required this.year,
    required this.hits,
  });
}

class _LatestEpisodeResult {
  final MediaItem episode;

  const _LatestEpisodeResult(this.episode);

  int get seasonNumber => episode.seasonNumber ?? 0;
  int get episodeNumber => episode.episodeNumber ?? 0;
}

typedef _LatestEpisodeResolver = Future<_LatestEpisodeResult?> Function(
  ServerProfile server,
  String seriesId,
);

class _AggregateSearchTabStateful extends StatefulWidget {
  const _AggregateSearchTabStateful({required this.appState});

  final AppState appState;

  @override
  State<_AggregateSearchTabStateful> createState() =>
      _AggregateSearchTabStatefulState();
}

class _AggregateSearchTabStatefulState
    extends State<_AggregateSearchTabStateful> {
  static const _searchLimitPerServer = 40;
  static const _debounceMs = 280;

  final TextEditingController _controller = TextEditingController();
  Timer? _debounce;
  int _searchSeq = 0;

  bool _loading = false;
  String? _error;
  List<_WorkGroup> _groups = const [];
  Map<String, String> _serverErrors = const {};

  final Map<String, Future<_LatestEpisodeResult?>> _latestEpisodeFutures = {};
  final Map<String, _LatestEpisodeResult?> _latestEpisodeCache = {};

  @override
  void dispose() {
    _debounce?.cancel();
    _controller.dispose();
    super.dispose();
  }

  void _scheduleSearch(String query, {bool immediate = false}) {
    _debounce?.cancel();
    if (immediate) {
      unawaited(_doSearch(query));
      return;
    }
    _debounce = Timer(const Duration(milliseconds: _debounceMs), () {
      unawaited(_doSearch(query));
    });
  }

  static int? _yearOf(MediaItem item) {
    final d = (item.premiereDate ?? '').trim();
    if (d.isEmpty) return null;
    final parsed = DateTime.tryParse(d);
    if (parsed != null) return parsed.year;
    if (d.length >= 4) {
      final y = int.tryParse(d.substring(0, 4));
      if (y != null && y > 1800 && y < 2200) return y;
    }
    return null;
  }

  static String _normalizeTitle(String raw) {
    var t = raw.trim().toLowerCase();
    if (t.isEmpty) return '';
    t = t.replaceAll(RegExp(r'\s+'), '');
    t = t.replaceAll("'", '');
    t = t.replaceAll(
      RegExp(
        r'[\-_·•:：/\\|｜()（）\[\]【】{}「」“”"’!?！？,，.。]',
      ),
      '',
    );
    return t;
  }

  static int? _seasonFromTitle(String raw) {
    final s = raw.toLowerCase();
    final cn = RegExp(r'第\s*(\d{1,2})\s*季');
    final cnM = cn.firstMatch(s);
    if (cnM != null) return int.tryParse(cnM.group(1) ?? '');
    final en = RegExp(r'season\s*(\d{1,2})');
    final enM = en.firstMatch(s);
    if (enM != null) return int.tryParse(enM.group(1) ?? '');
    final sx = RegExp(r'\bs(\d{1,2})\b');
    final sxM = sx.firstMatch(s);
    if (sxM != null) return int.tryParse(sxM.group(1) ?? '');
    return null;
  }

  static String _providerKey(Map<String, String> providerIds) {
    if (providerIds.isEmpty) return '';
    String? pick(String contains) {
      for (final e in providerIds.entries) {
        if (e.key.toLowerCase().contains(contains) &&
            e.value.trim().isNotEmpty) {
          return e.value.trim();
        }
      }
      return null;
    }

    final tmdb = pick('tmdb');
    if (tmdb != null) return 'tmdb:$tmdb';
    final imdb = pick('imdb');
    if (imdb != null) return 'imdb:$imdb';
    final douban = pick('douban');
    if (douban != null) return 'douban:$douban';
    return '';
  }

  static String _workKeyFor(MediaItem item) {
    final type = item.type.trim().toLowerCase();
    final pk = _providerKey(item.providerIds);
    if (pk.isNotEmpty) return '$type|$pk';

    final year = _yearOf(item);
    final season = _seasonFromTitle(item.name);
    final title = _normalizeTitle(item.name);
    return '$type|$title|${year ?? ''}|${season ?? ''}';
  }

  Future<_LatestEpisodeResult?> _fetchLatestEpisode(
    ServerProfile server,
    String seriesId,
  ) async {
    final baseUrl = server.baseUrl.trim();
    final token = server.token.trim();
    final userId = server.userId.trim();
    if (baseUrl.isEmpty || token.isEmpty || userId.isEmpty) return null;

    final access =
        resolveServerAccess(appState: widget.appState, server: server);
    if (access == null) return null;

    final res = await access.adapter.fetchItems(
      access.auth,
      parentId: seriesId,
      includeItemTypes: 'Episode',
      recursive: true,
      excludeFolders: true,
      limit: 1,
      sortBy: 'DateCreated',
      sortOrder: 'Descending',
    );
    if (res.items.isEmpty) return null;
    return _LatestEpisodeResult(res.items.first);
  }

  Future<_LatestEpisodeResult?> _resolveLatestEpisode(
    ServerProfile server,
    String seriesId,
  ) {
    final key = '${server.id}:$seriesId';
    final cached = _latestEpisodeCache[key];
    if (_latestEpisodeCache.containsKey(key)) {
      return Future.value(cached);
    }
    final existing = _latestEpisodeFutures[key];
    if (existing != null) return existing;

    final future = _fetchLatestEpisode(server, seriesId).then((value) {
      _latestEpisodeCache[key] = value;
      return value;
    });
    _latestEpisodeFutures[key] = future;
    future.whenComplete(() {
      if (mounted) setState(() {});
    });
    return future;
  }

  static int _progressScore(_LatestEpisodeResult? r) {
    if (r == null) return 0;
    return r.seasonNumber * 10000 + r.episodeNumber;
  }

  static String _episodeTag(_LatestEpisodeResult? r) {
    if (r == null) return '更新未知';
    final s = r.seasonNumber;
    final e = r.episodeNumber;
    if (s <= 0 && e <= 0) return '更新未知';
    if (s > 0 && e > 0) {
      return '更新至 S${s.toString().padLeft(2, '0')}E${e.toString().padLeft(2, '0')}';
    }
    if (e > 0) return '更新至 E${e.toString().padLeft(2, '0')}';
    return '更新至 S${s.toString().padLeft(2, '0')}';
  }

  Future<void> _doSearch(String raw) async {
    final query = raw.trim();
    final seq = ++_searchSeq;

    if (query.isEmpty) {
      setState(() {
        _loading = false;
        _error = null;
        _groups = const [];
        _serverErrors = const {};
      });
      return;
    }

    final servers = widget.appState.servers;
    if (servers.isEmpty) {
      setState(() {
        _loading = false;
        _error = null;
        _groups = const [];
        _serverErrors = const {};
      });
      return;
    }

    setState(() {
      _loading = true;
      _error = null;
      _serverErrors = const {};
    });

    final hits = <_ServerSearchHit>[];
    final serverErrors = <String, String>{};

    await Future.wait<void>(
      servers.map((server) async {
        final baseUrl = server.baseUrl.trim();
        final token = server.token.trim();
        final userId = server.userId.trim();
        if (baseUrl.isEmpty || token.isEmpty || userId.isEmpty) {
          serverErrors[server.id] = '服务器信息不完整';
          return;
        }
        try {
          final access =
              resolveServerAccess(appState: widget.appState, server: server);
          if (access == null) {
            serverErrors[server.id] = 'Unsupported server';
            return;
          }

          final res = await access.adapter.fetchItems(
            access.auth,
            searchTerm: query,
            includeItemTypes: 'Series,Movie',
            recursive: true,
            excludeFolders: false,
            limit: _searchLimitPerServer,
            sortBy: 'SortName',
            sortOrder: 'Ascending',
          );
          for (final item in res.items) {
            final t = item.type.toLowerCase();
            if (t != 'series' && t != 'movie') continue;
            hits.add(_ServerSearchHit(server: server, item: item));
          }
        } catch (e) {
          serverErrors[server.id] = e.toString();
        }
      }),
    );

    if (!mounted || seq != _searchSeq) return;

    if (hits.isEmpty) {
      setState(() {
        _loading = false;
        _groups = const [];
        _serverErrors = serverErrors;
      });
      return;
    }

    final grouped = <String, List<_ServerSearchHit>>{};
    for (final hit in hits) {
      final key = _workKeyFor(hit.item);
      grouped.putIfAbsent(key, () => <_ServerSearchHit>[]).add(hit);
    }

    final groups = <_WorkGroup>[];
    for (final entry in grouped.entries) {
      final list = entry.value;
      if (list.isEmpty) continue;
      final first = list.first.item;
      groups.add(
        _WorkGroup(
          key: entry.key,
          title: first.name,
          type: first.type.trim(),
          year: _yearOf(first),
          hits: list,
        ),
      );
    }

    setState(() {
      _loading = false;
      _groups = groups;
      _serverErrors = serverErrors;
    });
  }

  List<_WorkGroup> _sortedGroups(List<_WorkGroup> input) {
    final groups = List<_WorkGroup>.from(input);
    groups.sort((a, b) {
      if (a.type.toLowerCase() == 'series' &&
          b.type.toLowerCase() != 'series') {
        return -1;
      }
      if (a.type.toLowerCase() != 'series' &&
          b.type.toLowerCase() == 'series') {
        return 1;
      }

      if (a.type.toLowerCase() == 'series') {
        int maxScore(_WorkGroup g) {
          var max = 0;
          for (final h in g.hits) {
            final v = _latestEpisodeCache['${h.server.id}:${h.item.id}'];
            final score = _progressScore(v);
            if (score > max) max = score;
          }
          return max;
        }

        final diff = maxScore(b) - maxScore(a);
        if (diff != 0) return diff;
      }

      final t = a.title.compareTo(b.title);
      if (t != 0) return t;
      return (a.year ?? 0).compareTo(b.year ?? 0);
    });
    return groups;
  }

  List<_ServerSearchHit> _sortedHits(_WorkGroup group) {
    final hits = List<_ServerSearchHit>.from(group.hits);
    if (group.type.toLowerCase() != 'series') {
      hits.sort((a, b) => a.server.name.compareTo(b.server.name));
      return hits;
    }

    hits.sort((a, b) {
      final aKey = '${a.server.id}:${a.item.id}';
      final bKey = '${b.server.id}:${b.item.id}';
      final aScore = _progressScore(_latestEpisodeCache[aKey]);
      final bScore = _progressScore(_latestEpisodeCache[bKey]);
      final diff = bScore - aScore;
      if (diff != 0) return diff;
      return a.server.name.compareTo(b.server.name);
    });
    return hits;
  }

  @override
  Widget build(BuildContext context) {
    final isTv = DeviceType.isTv;
    final query = _controller.text.trim();
    final groups = _sortedGroups(_groups);

    Widget content;
    if (query.isEmpty) {
      content = const Center(child: Text('输入剧名开始搜索'));
    } else if (_groups.isEmpty) {
      content = _loading
          ? const Center(child: CircularProgressIndicator())
          : const Center(child: Text('没有结果'));
    } else {
      content = ListView.builder(
        padding: const EdgeInsets.fromLTRB(12, 8, 12, 24),
        itemCount: groups.length,
        itemBuilder: (context, index) {
          final group = groups[index];
          final hits = _sortedHits(group);

          final badge = group.type.toLowerCase() == 'series'
              ? '剧集'
              : (group.type.toLowerCase() == 'movie' ? '电影' : '');
          final yearText = group.year == null ? '' : group.year.toString();

          _ServerSearchHit? posterHit;
          for (final h in hits) {
            if (h.item.hasImage) {
              posterHit = h;
              break;
            }
          }
          final posterUrl = posterHit == null
              ? ''
               : EmbyApi.imageUrl(
                   baseUrl: posterHit.server.baseUrl,
                   itemId: posterHit.item.id,
                   token: posterHit.server.token,
                   apiPrefix: posterHit.server.apiPrefix,
                   imageType: 'Primary',
                   maxWidth: 320,
                 );

          final shownHits = hits.length <= 3 ? hits : hits.take(3).toList();

          return Card(
            clipBehavior: Clip.antiAlias,
            child: InkWell(
              onTap: () {
                Navigator.of(context).push(
                  MaterialPageRoute(
                    builder: (_) => _AggregateWorkDetailPage(
                      appState: widget.appState,
                      group: group,
                      isTv: isTv,
                      resolveLatestEpisode: _resolveLatestEpisode,
                      latestEpisodeCache: _latestEpisodeCache,
                    ),
                  ),
                );
              },
              child: Padding(
                padding: const EdgeInsets.all(12),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    ClipRRect(
                      borderRadius: BorderRadius.circular(10),
                      child: posterUrl.isEmpty
                          ? const SizedBox(
                              width: 72,
                              height: 104,
                              child: ColoredBox(
                                color: Colors.black12,
                                child:
                                    Center(child: Icon(Icons.image_outlined)),
                              ),
                            )
                          : CachedNetworkImage(
                              imageUrl: posterUrl,
                              cacheManager: CoverCacheManager.instance,
                              httpHeaders: {'User-Agent': EmbyApi.userAgent},
                              width: 72,
                              height: 104,
                              fit: BoxFit.cover,
                              placeholder: (_, __) => const SizedBox(
                                width: 72,
                                height: 104,
                                child: ColoredBox(
                                  color: Colors.black12,
                                  child:
                                      Center(child: Icon(Icons.image_outlined)),
                                ),
                              ),
                              errorWidget: (_, __, ___) => const SizedBox(
                                width: 72,
                                height: 104,
                                child: ColoredBox(
                                  color: Colors.black12,
                                  child: Center(
                                      child: Icon(Icons.broken_image_outlined)),
                                ),
                              ),
                            ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Row(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Expanded(
                                child: Text(
                                  group.title,
                                  maxLines: 2,
                                  overflow: TextOverflow.ellipsis,
                                  style: Theme.of(context)
                                      .textTheme
                                      .titleMedium
                                      ?.copyWith(fontWeight: FontWeight.w700),
                                ),
                              ),
                              if (badge.isNotEmpty) ...[
                                const SizedBox(width: 8),
                                MediaLabelBadge(text: badge),
                              ],
                            ],
                          ),
                          if (yearText.isNotEmpty)
                            Padding(
                              padding: const EdgeInsets.only(top: 2),
                              child: Text(
                                yearText,
                                style: Theme.of(context)
                                    .textTheme
                                    .bodySmall
                                    ?.copyWith(
                                      color: Theme.of(context)
                                          .colorScheme
                                          .onSurfaceVariant,
                                    ),
                              ),
                            ),
                          const SizedBox(height: 10),
                          for (final h in shownHits)
                            _ServerProgressRow(
                              hit: h,
                              isSeries: group.type.toLowerCase() == 'series',
                              resolveLatestEpisode: _resolveLatestEpisode,
                              latestEpisodeCache: _latestEpisodeCache,
                            ),
                          if (hits.length > shownHits.length)
                            Padding(
                              padding: const EdgeInsets.only(top: 6),
                              child: Text(
                                '还有 ${hits.length - shownHits.length} 个服务器…',
                                style: Theme.of(context)
                                    .textTheme
                                    .bodySmall
                                    ?.copyWith(
                                      color: Theme.of(context)
                                          .colorScheme
                                          .onSurfaceVariant,
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
          );
        },
      );
    }

    final serverErrorCount = _serverErrors.length;
    final banner = (query.isNotEmpty && serverErrorCount > 0)
        ? Padding(
            padding: const EdgeInsets.fromLTRB(12, 6, 12, 0),
            child: Text(
              '部分服务器搜索失败：$serverErrorCount',
              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                    color: Theme.of(context).colorScheme.onSurfaceVariant,
                  ),
            ),
          )
        : const SizedBox.shrink();

    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(12, 12, 12, 6),
          child: TextField(
            controller: _controller,
            decoration: InputDecoration(
              hintText: '聚合搜索（跨服务器）',
              prefixIcon: const Icon(Icons.search),
              suffixIcon: _controller.text.trim().isEmpty
                  ? null
                  : IconButton(
                      tooltip: '清空',
                      icon: const Icon(Icons.clear),
                      onPressed: () {
                        _controller.clear();
                        _scheduleSearch('', immediate: true);
                        setState(() {});
                      },
                    ),
            ),
            textInputAction: TextInputAction.search,
            onChanged: (v) {
              _scheduleSearch(v);
              setState(() {});
            },
            onSubmitted: (v) => _scheduleSearch(v, immediate: true),
          ),
        ),
        banner,
        if (_error != null)
          Padding(
            padding: const EdgeInsets.all(12),
            child: Text(
              _error!,
              style: TextStyle(color: Theme.of(context).colorScheme.error),
            ),
          ),
        if (_loading && query.isNotEmpty && _groups.isNotEmpty)
          const LinearProgressIndicator(minHeight: 2),
        Expanded(child: content),
      ],
    );
  }
}

class _ServerProgressRow extends StatelessWidget {
  const _ServerProgressRow({
    required this.hit,
    required this.isSeries,
    required this.resolveLatestEpisode,
    required this.latestEpisodeCache,
  });

  final _ServerSearchHit hit;
  final bool isSeries;
  final _LatestEpisodeResolver resolveLatestEpisode;
  final Map<String, _LatestEpisodeResult?> latestEpisodeCache;

  @override
  Widget build(BuildContext context) {
    final server = hit.server;
    final item = hit.item;

    final key = '${server.id}:${item.id}';
    final cached = latestEpisodeCache[key];
    final future =
        isSeries ? resolveLatestEpisode(server, item.id) : Future.value(null);

    return Padding(
      padding: const EdgeInsets.only(bottom: 6),
      child: Row(
        children: [
          ServerIconAvatar(
            iconUrl: server.iconUrl,
            name: server.name,
            radius: 12,
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              server.name,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                    fontWeight: FontWeight.w600,
                  ),
            ),
          ),
          const SizedBox(width: 8),
          if (!isSeries)
            Text(
              '可用',
              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                    color: Theme.of(context).colorScheme.onSurfaceVariant,
                  ),
            )
          else if (cached != null)
            Text(
              _AggregateSearchTabStatefulState._episodeTag(cached),
              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                    color: Theme.of(context).colorScheme.onSurfaceVariant,
                  ),
            )
          else
            FutureBuilder<_LatestEpisodeResult?>(
              future: future,
              builder: (context, snap) {
                final r = snap.data;
                if (snap.connectionState == ConnectionState.waiting) {
                  return Text(
                    '获取中…',
                    style: Theme.of(context).textTheme.bodySmall?.copyWith(
                          color: Theme.of(context).colorScheme.onSurfaceVariant,
                        ),
                  );
                }
                return Text(
                  _AggregateSearchTabStatefulState._episodeTag(r),
                  style: Theme.of(context).textTheme.bodySmall?.copyWith(
                        color: Theme.of(context).colorScheme.onSurfaceVariant,
                      ),
                );
              },
            ),
        ],
      ),
    );
  }
}

class _AggregateWorkDetailPage extends StatefulWidget {
  const _AggregateWorkDetailPage({
    required this.appState,
    required this.group,
    required this.isTv,
    required this.resolveLatestEpisode,
    required this.latestEpisodeCache,
  });

  final AppState appState;
  final _WorkGroup group;
  final bool isTv;
  final _LatestEpisodeResolver resolveLatestEpisode;
  final Map<String, _LatestEpisodeResult?> latestEpisodeCache;

  @override
  State<_AggregateWorkDetailPage> createState() =>
      _AggregateWorkDetailPageState();
}

class _AggregateWorkDetailPageState extends State<_AggregateWorkDetailPage> {
  String? _loadingKey;

  @override
  Widget build(BuildContext context) {
    final isSeries = widget.group.type.toLowerCase() == 'series';
    final hits = List<_ServerSearchHit>.from(widget.group.hits);
    hits.sort((a, b) {
      if (!isSeries) return a.server.name.compareTo(b.server.name);
      final aKey = '${a.server.id}:${a.item.id}';
      final bKey = '${b.server.id}:${b.item.id}';
      final aScore = _AggregateSearchTabStatefulState._progressScore(
          widget.latestEpisodeCache[aKey]);
      final bScore = _AggregateSearchTabStatefulState._progressScore(
          widget.latestEpisodeCache[bKey]);
      final diff = bScore - aScore;
      if (diff != 0) return diff;
      return a.server.name.compareTo(b.server.name);
    });

    return Scaffold(
      appBar: GlassAppBar(
        enableBlur: !widget.isTv && widget.appState.enableBlurEffects,
        child: AppBar(
          title: Text(widget.group.title),
        ),
      ),
      body: ListView.separated(
        padding: const EdgeInsets.all(12),
        itemCount: hits.length,
        separatorBuilder: (_, __) => const SizedBox(height: 8),
        itemBuilder: (context, index) {
          final hit = hits[index];
          final server = hit.server;
          final item = hit.item;
          final rowKey = '${server.id}:${item.id}';
          final busy = _loadingKey == rowKey;

          return Card(
            clipBehavior: Clip.antiAlias,
            child: ListTile(
              leading: ServerIconAvatar(
                iconUrl: server.iconUrl,
                name: server.name,
                radius: 18,
              ),
              title: Text(server.name),
              subtitle: isSeries
                  ? FutureBuilder<_LatestEpisodeResult?>(
                      future: widget.resolveLatestEpisode(server, item.id),
                      builder: (context, snap) {
                        if (snap.connectionState == ConnectionState.waiting) {
                          return const Text('获取更新信息…');
                        }
                        return Text(
                          _AggregateSearchTabStatefulState._episodeTag(
                            snap.data,
                          ),
                        );
                      },
                    )
                  : const Text('可用'),
              trailing: busy
                  ? const SizedBox(
                      width: 16,
                      height: 16,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Icon(Icons.chevron_right),
              onTap: busy
                  ? null
                  : () async {
                      setState(() => _loadingKey = rowKey);
                      try {
                        if (!isSeries) {
                          if (!mounted) return;
                          Navigator.of(context).push(
                            MaterialPageRoute(
                              builder: (_) => ShowDetailPage(
                                itemId: item.id,
                                title: item.name,
                                appState: widget.appState,
                                server: server,
                                isTv: widget.isTv,
                              ),
                            ),
                          );
                          return;
                        }

                        final latest =
                            await widget.resolveLatestEpisode(server, item.id);
                        if (!context.mounted) return;
                        if (latest == null) {
                          Navigator.of(context).push(
                            MaterialPageRoute(
                              builder: (_) => ShowDetailPage(
                                itemId: item.id,
                                title: item.name,
                                appState: widget.appState,
                                server: server,
                                isTv: widget.isTv,
                              ),
                            ),
                          );
                          return;
                        }

                        Navigator.of(context).push(
                          MaterialPageRoute(
                            builder: (_) => EpisodeDetailPage(
                              episode: latest.episode,
                              appState: widget.appState,
                              server: server,
                              isTv: widget.isTv,
                            ),
                          ),
                        );
                      } finally {
                        if (mounted) setState(() => _loadingKey = null);
                      }
                    },
            ),
          );
        },
      ),
    );
  }
}
