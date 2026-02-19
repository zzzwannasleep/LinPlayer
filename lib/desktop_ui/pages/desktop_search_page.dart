import 'dart:async';
import 'dart:ui';

import 'package:flutter/material.dart';
import 'package:lin_player_server_adapters/lin_player_server_adapters.dart';
import 'package:lin_player_state/lin_player_state.dart';

import '../../server_adapters/server_access.dart';
import '../models/desktop_ui_language.dart';
import '../theme/desktop_theme_extension.dart';
import '../widgets/desktop_media_card.dart';
import '../widgets/hover_effect_wrapper.dart';

typedef DesktopSearchOpenItem = void Function(MediaItem item,
    [ServerProfile? server]);

enum _DesktopAggregateSearchSortMode {
  episodeCountDesc,
  bitrateDesc,
}

class DesktopSearchPage extends StatefulWidget {
  const DesktopSearchPage({
    super.key,
    required this.appState,
    required this.query,
    required this.onOpenItem,
    this.refreshSignal = 0,
    this.language = DesktopUiLanguage.zhCn,
  });

  final AppState appState;
  final String query;
  final DesktopSearchOpenItem onOpenItem;
  final int refreshSignal;
  final DesktopUiLanguage language;

  @override
  State<DesktopSearchPage> createState() => _DesktopSearchPageState();
}

class _ServerSearchHit {
  const _ServerSearchHit({required this.server, required this.item});

  final ServerProfile server;
  final MediaItem item;
}

class _WorkGroup {
  const _WorkGroup({
    required this.key,
    required this.title,
    required this.type,
    required this.year,
    required this.hits,
  });

  final String key;
  final String title;
  final String type; // Series / Movie
  final int? year;
  final List<_ServerSearchHit> hits;
}

class _SeriesMeta {
  const _SeriesMeta({
    required this.episodeCount,
    required this.latestEpisodeBitrateBps,
  });

  final int episodeCount;
  final double? latestEpisodeBitrateBps;
}

class _DesktopSearchPageState extends State<DesktopSearchPage> {
  static const int _kSearchLimitPerServer = 40;
  static const double _kTicksPerSecond = 10000000;

  bool _loading = false;
  String? _error;
  List<_WorkGroup> _groups = const <_WorkGroup>[];
  Map<String, String> _serverErrors = const <String, String>{};
  int _searchSeq = 0;
  String _activeQuery = '';

  _DesktopAggregateSearchSortMode _sortMode =
      _DesktopAggregateSearchSortMode.episodeCountDesc;

  final Map<String, Future<_SeriesMeta?>> _seriesMetaFutures =
      <String, Future<_SeriesMeta?>>{};
  final Map<String, _SeriesMeta?> _seriesMetaCache = <String, _SeriesMeta?>{};

  String _t({required String zh, required String en}) =>
      widget.language.pick(zh: zh, en: en);

  @override
  void initState() {
    super.initState();
    _activeQuery = widget.query.trim();
    if (_activeQuery.isNotEmpty) {
      unawaited(_search(_activeQuery));
    }
  }

  @override
  void didUpdateWidget(covariant DesktopSearchPage oldWidget) {
    super.didUpdateWidget(oldWidget);
    final nextQuery = widget.query.trim();
    final queryChanged = nextQuery != _activeQuery;
    final refreshChanged = oldWidget.refreshSignal != widget.refreshSignal;

    if (queryChanged) {
      _activeQuery = nextQuery;
      unawaited(_search(_activeQuery));
      return;
    }

    if (refreshChanged && _activeQuery.isNotEmpty) {
      unawaited(_search(_activeQuery));
    }
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
    t = t.replaceAll(
        RegExp(r"""[\\\-/_.:;(){}\[\]"'`~!@#$%^&*+=|<>?,，。！？【】（）《》、·]"""), '');
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

  static double? _bitrateBpsOf(MediaItem item) {
    final size = item.sizeBytes;
    final ticks = item.runTimeTicks;
    if (size == null || size <= 0) return null;
    if (ticks == null || ticks <= 0) return null;
    final seconds = ticks / _kTicksPerSecond;
    if (seconds <= 1e-6) return null;
    return (size * 8) / seconds;
  }

  static String _fmtBitrate(double? bps) {
    final v = bps ?? 0;
    if (v <= 0) return '--';
    final mbps = v / 1000000;
    if (mbps >= 100) return '${mbps.toStringAsFixed(0)} Mbps';
    if (mbps >= 10) return '${mbps.toStringAsFixed(1)} Mbps';
    return '${mbps.toStringAsFixed(2)} Mbps';
  }

  Future<_SeriesMeta?> _fetchSeriesMeta(
    ServerProfile server,
    String seriesId,
  ) async {
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
    final latest = res.items.isNotEmpty ? res.items.first : null;
    return _SeriesMeta(
      episodeCount: res.total,
      latestEpisodeBitrateBps: latest == null ? null : _bitrateBpsOf(latest),
    );
  }

  Future<_SeriesMeta?> _resolveSeriesMeta(
    ServerProfile server,
    String seriesId,
  ) {
    final key = '${server.id}:$seriesId';
    if (_seriesMetaCache.containsKey(key)) {
      return Future.value(_seriesMetaCache[key]);
    }
    final existing = _seriesMetaFutures[key];
    if (existing != null) return existing;

    final future = _fetchSeriesMeta(server, seriesId).then((value) {
      _seriesMetaCache[key] = value;
      return value;
    });
    _seriesMetaFutures[key] = future;
    future.whenComplete(() {
      if (mounted) setState(() {});
    });
    return future;
  }

  int _episodeCountOfHit(_ServerSearchHit hit) {
    final meta = _seriesMetaCache['${hit.server.id}:${hit.item.id}'];
    return meta?.episodeCount ?? 0;
  }

  double _bitrateBpsOfHit(_ServerSearchHit hit) {
    final type = hit.item.type.trim().toLowerCase();
    if (type == 'movie') return _bitrateBpsOf(hit.item) ?? 0;
    if (type != 'series') return 0;
    final meta = _seriesMetaCache['${hit.server.id}:${hit.item.id}'];
    return meta?.latestEpisodeBitrateBps ?? 0;
  }

  List<_ServerSearchHit> _sortedHits(_WorkGroup group) {
    final hits = List<_ServerSearchHit>.from(group.hits);
    final isSeries = group.type.trim().toLowerCase() == 'series';

    if (isSeries) {
      for (final hit in hits) {
        unawaited(_resolveSeriesMeta(hit.server, hit.item.id));
      }
    }

    hits.sort((a, b) {
      switch (_sortMode) {
        case _DesktopAggregateSearchSortMode.episodeCountDesc:
          if (isSeries) {
            final diff = _episodeCountOfHit(b) - _episodeCountOfHit(a);
            if (diff != 0) return diff;
          }
          final bitrateDiff =
              _bitrateBpsOfHit(b).compareTo(_bitrateBpsOfHit(a));
          if (bitrateDiff != 0) return bitrateDiff;
          return a.server.name.compareTo(b.server.name);
        case _DesktopAggregateSearchSortMode.bitrateDesc:
          final bitrateDiff =
              _bitrateBpsOfHit(b).compareTo(_bitrateBpsOfHit(a));
          if (bitrateDiff != 0) return bitrateDiff;
          if (isSeries) {
            final diff = _episodeCountOfHit(b) - _episodeCountOfHit(a);
            if (diff != 0) return diff;
          }
          return a.server.name.compareTo(b.server.name);
      }
    });
    return hits;
  }

  int _groupEpisodeCount(_WorkGroup group) {
    if (group.type.trim().toLowerCase() != 'series') return 0;
    var max = 0;
    for (final hit in group.hits) {
      final v = _episodeCountOfHit(hit);
      if (v > max) max = v;
    }
    return max;
  }

  double _groupBitrateBps(_WorkGroup group) {
    var max = 0.0;
    for (final hit in group.hits) {
      final v = _bitrateBpsOfHit(hit);
      if (v > max) max = v;
    }
    return max;
  }

  List<_WorkGroup> _sortedGroups(List<_WorkGroup> input) {
    final groups = List<_WorkGroup>.from(input);
    groups.sort((a, b) {
      final aType = a.type.trim().toLowerCase();
      final bType = b.type.trim().toLowerCase();
      if (aType == 'series' && bType != 'series') return -1;
      if (aType != 'series' && bType == 'series') return 1;

      switch (_sortMode) {
        case _DesktopAggregateSearchSortMode.episodeCountDesc:
          final diff = _groupEpisodeCount(b) - _groupEpisodeCount(a);
          if (diff != 0) return diff;
          break;
        case _DesktopAggregateSearchSortMode.bitrateDesc:
          final diff = _groupBitrateBps(b).compareTo(_groupBitrateBps(a));
          if (diff != 0) return diff;
          break;
      }

      final titleDiff = a.title.toLowerCase().compareTo(b.title.toLowerCase());
      if (titleDiff != 0) return titleDiff;
      return (a.year ?? 0).compareTo(b.year ?? 0);
    });
    return groups;
  }

  Future<void> _search(String raw) async {
    final query = raw.trim();
    final seq = ++_searchSeq;

    if (query.isEmpty) {
      setState(() {
        _loading = false;
        _error = null;
        _groups = const <_WorkGroup>[];
        _serverErrors = const <String, String>{};
      });
      return;
    }

    final servers = widget.appState.servers;
    if (servers.isEmpty) {
      setState(() {
        _loading = false;
        _error = _t(zh: '没有已配置的服务器', en: 'No servers configured');
        _groups = const <_WorkGroup>[];
        _serverErrors = const <String, String>{};
      });
      return;
    }

    setState(() {
      _loading = true;
      _error = null;
      _serverErrors = const <String, String>{};
    });

    final hits = <_ServerSearchHit>[];
    final serverErrors = <String, String>{};

    await Future.wait<void>(
      servers.map((server) async {
        final baseUrl = server.baseUrl.trim();
        final token = server.token.trim();
        final userId = server.userId.trim();
        if (baseUrl.isEmpty || token.isEmpty || userId.isEmpty) {
          serverErrors[server.id] = _t(
            zh: '服务器信息不完整',
            en: 'Server info incomplete',
          );
          return;
        }

        final access =
            resolveServerAccess(appState: widget.appState, server: server);
        if (access == null) {
          serverErrors[server.id] = _t(
            zh: '暂不支持的服务器',
            en: 'Unsupported server',
          );
          return;
        }

        try {
          final res = await access.adapter.fetchItems(
            access.auth,
            searchTerm: query,
            includeItemTypes: 'Series,Movie',
            recursive: true,
            excludeFolders: false,
            limit: _kSearchLimitPerServer,
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
        _error = null;
        _groups = const <_WorkGroup>[];
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
      _error = null;
      _groups = groups;
      _serverErrors = serverErrors;
    });

    for (final group in groups) {
      if (group.type.trim().toLowerCase() != 'series') continue;
      for (final hit in group.hits) {
        unawaited(_resolveSeriesMeta(hit.server, hit.item.id));
      }
    }
  }

  Widget _buildFilterButton(DesktopThemeExtension theme, bool enabled) {
    PopupMenuItem<_DesktopAggregateSearchSortMode> item({
      required _DesktopAggregateSearchSortMode value,
      required String label,
    }) {
      return CheckedPopupMenuItem<_DesktopAggregateSearchSortMode>(
        value: value,
        checked: _sortMode == value,
        child: Text(label),
      );
    }

    return Tooltip(
      message: _t(zh: '筛选', en: 'Sort'),
      child: PopupMenuButton<_DesktopAggregateSearchSortMode>(
        enabled: enabled,
        tooltip: _t(zh: '筛选', en: 'Sort'),
        onSelected: (v) => setState(() => _sortMode = v),
        itemBuilder: (context) => [
          item(
            value: _DesktopAggregateSearchSortMode.episodeCountDesc,
            label: _t(zh: '按集数（多→少）', en: 'Episodes (high → low)'),
          ),
          item(
            value: _DesktopAggregateSearchSortMode.bitrateDesc,
            label: _t(zh: '按码率（大→小）', en: 'Bitrate (high → low)'),
          ),
        ],
        child: Container(
          width: 34,
          height: 34,
          decoration: BoxDecoration(
            color: Colors.white.withValues(alpha: enabled ? 0.06 : 0.02),
            borderRadius: BorderRadius.circular(18),
            border: Border.all(
              color: theme.border.withValues(alpha: enabled ? 0.66 : 0.35),
            ),
          ),
          child: Icon(
            Icons.tune_rounded,
            size: 18,
            color: enabled
                ? theme.textPrimary
                : theme.textMuted.withValues(alpha: 0.5),
          ),
        ),
      ),
    );
  }

  Widget _buildPoster(_WorkGroup group) {
    final hits = _sortedHits(group);
    _ServerSearchHit? posterHit;
    for (final h in hits) {
      if (!h.item.hasImage) continue;
      posterHit = h;
      break;
    }
    final access = posterHit == null
        ? null
        : resolveServerAccess(
            appState: widget.appState, server: posterHit.server);

    if (posterHit == null || access == null) {
      return Container(
        width: 92,
        height: 130,
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(10),
          color: Colors.white.withValues(alpha: 0.06),
          border: Border.all(color: DesktopThemeExtension.of(context).border),
        ),
        child: const Center(child: Icon(Icons.image_outlined)),
      );
    }

    return DesktopMediaCard(
      item: posterHit.item,
      access: access,
      width: 92,
      showMeta: false,
      showProgress: false,
      showBadge: false,
    );
  }

  Widget _buildServerIcon(ServerProfile server, DesktopThemeExtension theme) {
    final rawIconUrl = (server.iconUrl ?? '').trim();
    final name = server.name.trim();
    final initial = name.isEmpty ? '?' : name.substring(0, 1);

    Widget fallback() {
      return Center(
        child: Text(
          initial.toUpperCase(),
          style: TextStyle(
            color: theme.accent,
            fontSize: 12,
            fontWeight: FontWeight.w800,
          ),
        ),
      );
    }

    return Container(
      width: 26,
      height: 26,
      clipBehavior: Clip.antiAlias,
      decoration: BoxDecoration(
        color: theme.accent.withValues(alpha: 0.14),
        borderRadius: BorderRadius.circular(7),
        border: Border.all(color: theme.border.withValues(alpha: 0.6)),
      ),
      child: rawIconUrl.isEmpty
          ? fallback()
          : Image.network(
              rawIconUrl,
              fit: BoxFit.cover,
              errorBuilder: (_, __, ___) => fallback(),
              loadingBuilder: (context, child, loadingProgress) {
                if (loadingProgress == null) return child;
                return fallback();
              },
            ),
    );
  }

  Widget _buildHitRow(_ServerSearchHit hit, {required bool isSeries}) {
    final theme = DesktopThemeExtension.of(context);
    final item = hit.item;

    final metaKey = '${hit.server.id}:${item.id}';
    final meta = isSeries ? _seriesMetaCache[metaKey] : null;
    if (isSeries) {
      unawaited(_resolveSeriesMeta(hit.server, item.id));
    }

    final episodesText = isSeries
        ? (meta == null
            ? _t(zh: '集数: ...', en: 'Eps: ...')
            : _t(
                zh: '集数: ${meta.episodeCount}',
                en: 'Eps: ${meta.episodeCount}'))
        : '';
    final bitrateText = _fmtBitrate(
      isSeries ? meta?.latestEpisodeBitrateBps : _bitrateBpsOf(item),
    );

    return HoverEffectWrapper(
      borderRadius: BorderRadius.circular(12),
      hoverScale: 1.01,
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
      onTap: () => widget.onOpenItem(item, hit.server),
      child: ColoredBox(
        color: Colors.white.withValues(alpha: 0.02),
        child: Row(
          children: [
            _buildServerIcon(hit.server, theme),
            const SizedBox(width: 10),
            Expanded(
              child: Text(
                hit.server.name,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  color: theme.textPrimary,
                  fontSize: 14,
                  fontWeight: FontWeight.w700,
                ),
              ),
            ),
            const SizedBox(width: 10),
            Text(
              [if (episodesText.isNotEmpty) episodesText, '码率: $bitrateText']
                  .join('  |  '),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                color: theme.textMuted,
                fontSize: 12.5,
                fontWeight: FontWeight.w600,
              ),
            ),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final desktopTheme = DesktopThemeExtension.of(context);
    final query = widget.query.trim();
    final groups = _sortedGroups(_groups);

    Widget body;
    if (query.isEmpty) {
      body = Center(
        child: Text(
          _t(
            zh: '请在顶部搜索框输入关键词',
            en: 'Type in the top search box to find media',
          ),
          style: TextStyle(color: desktopTheme.textMuted),
        ),
      );
    } else if (_loading && _groups.isEmpty) {
      body = const Center(child: CircularProgressIndicator());
    } else if ((_error ?? '').trim().isNotEmpty) {
      body = Center(child: Text(_error!));
    } else if (_groups.isEmpty) {
      body = Center(
        child: Text(
          _t(zh: '未找到“$query”的结果', en: 'No results for "$query"'),
          style: TextStyle(color: desktopTheme.textMuted),
        ),
      );
    } else {
      body = ListView.builder(
        padding: const EdgeInsets.fromLTRB(16, 10, 16, 24),
        itemCount: groups.length,
        itemBuilder: (context, index) {
          final group = groups[index];
          final type = group.type.trim().toLowerCase();
          final isSeries = type == 'series';
          final hits = _sortedHits(group);
          final badge = isSeries
              ? _t(zh: '剧集', en: 'Series')
              : (type == 'movie' ? _t(zh: '电影', en: 'Movie') : group.type);
          final yearText = group.year == null ? '' : group.year.toString();
          final metricText = switch (_sortMode) {
            _DesktopAggregateSearchSortMode.episodeCountDesc => isSeries
                ? _t(
                    zh: '最多 ${_groupEpisodeCount(group)} 集',
                    en: 'Up to ${_groupEpisodeCount(group)} eps')
                : '',
            _DesktopAggregateSearchSortMode.bitrateDesc => _t(
                zh: '最高 ${_fmtBitrate(_groupBitrateBps(group))}',
                en: 'Up to ${_fmtBitrate(_groupBitrateBps(group))}',
              ),
          };

          return Padding(
            padding: const EdgeInsets.only(bottom: 14),
            child: ClipRRect(
              borderRadius: BorderRadius.circular(16),
              child: DecoratedBox(
                decoration: BoxDecoration(
                  color: desktopTheme.surface.withValues(alpha: 0.66),
                  borderRadius: BorderRadius.circular(16),
                  border: Border.all(color: desktopTheme.border),
                ),
                child: Padding(
                  padding: const EdgeInsets.all(14),
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      _buildPoster(group),
                      const SizedBox(width: 14),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              group.title.trim().isEmpty
                                  ? _t(zh: '未命名', en: 'Untitled')
                                  : group.title,
                              maxLines: 2,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(
                                color: desktopTheme.textPrimary,
                                fontSize: 18,
                                fontWeight: FontWeight.w800,
                                height: 1.12,
                              ),
                            ),
                            const SizedBox(height: 8),
                            Text(
                              [
                                badge,
                                if (yearText.isNotEmpty) yearText,
                                _t(
                                    zh: '服务器 ${hits.length} 个',
                                    en: '${hits.length} servers'),
                                if (metricText.isNotEmpty) metricText
                              ].join('  ·  '),
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(
                                color: desktopTheme.textMuted,
                                fontSize: 12.5,
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                            const SizedBox(height: 12),
                            for (final hit in hits) ...[
                              _buildHitRow(hit, isSeries: isSeries),
                              const SizedBox(height: 8),
                            ],
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          );
        },
      );
    }

    final showServerErrors = query.isNotEmpty && _serverErrors.isNotEmpty;
    final serverErrorText = showServerErrors
        ? _t(
            zh: '部分服务器搜索失败：${_serverErrors.length} 个',
            en: 'Some servers failed: ${_serverErrors.length}',
          )
        : '';

    return ClipRRect(
      borderRadius: BorderRadius.circular(20),
      child: BackdropFilter(
        filter: ImageFilter.blur(sigmaX: 16, sigmaY: 16),
        child: DecoratedBox(
          decoration: BoxDecoration(
            color: desktopTheme.surface.withValues(alpha: 0.66),
            borderRadius: BorderRadius.circular(20),
            border: Border.all(color: desktopTheme.border),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(18, 14, 18, 8),
                child: Row(
                  children: [
                    Expanded(
                      child: Text(
                        query.isEmpty
                            ? _t(zh: '聚合搜索', en: 'Aggregate Search')
                            : _t(zh: '“$query”的结果', en: 'Results for "$query"'),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          color: desktopTheme.textPrimary,
                          fontSize: 20,
                          fontWeight: FontWeight.w800,
                        ),
                      ),
                    ),
                    if (query.isNotEmpty)
                      Padding(
                        padding: const EdgeInsets.only(right: 10),
                        child: Text(
                          _t(
                              zh: '共 ${_groups.length} 部',
                              en: '${_groups.length} works'),
                          style: TextStyle(
                            color: desktopTheme.textMuted,
                            fontSize: 13,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ),
                    _buildFilterButton(desktopTheme, query.isNotEmpty),
                  ],
                ),
              ),
              if (showServerErrors)
                Padding(
                  padding: const EdgeInsets.fromLTRB(18, 0, 18, 8),
                  child: Tooltip(
                    message: _serverErrors.entries
                        .map((e) => '${e.key}: ${e.value}')
                        .join('\\n'),
                    child: Row(
                      children: [
                        const Icon(
                          Icons.warning_amber_rounded,
                          size: 16,
                          color: Color(0xFFFFC36D),
                        ),
                        const SizedBox(width: 8),
                        Expanded(
                          child: Text(
                            serverErrorText,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              color: desktopTheme.textMuted,
                              fontSize: 12.5,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              const SizedBox(height: 4),
              Expanded(
                child: Stack(
                  children: [
                    Positioned.fill(child: body),
                    if (_loading && _groups.isNotEmpty)
                      const Positioned(
                        left: 0,
                        right: 0,
                        top: 0,
                        child: LinearProgressIndicator(minHeight: 2),
                      ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
