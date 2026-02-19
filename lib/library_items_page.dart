import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';

import 'package:lin_player_server_adapters/lin_player_server_adapters.dart';
import 'package:lin_player_state/lin_player_state.dart';
import 'package:lin_player_ui/lin_player_ui.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'show_detail_page.dart';
import 'server_adapters/server_access.dart';

enum _LibraryItemsViewMode {
  items,
  tags,
}

enum _LibraryItemsSortBy {
  communityRating('CommunityRating', '评分'),
  dateLastContentAdded('DateLastContentAdded', '最近更新'),
  dateCreated('DateCreated', '加入日期'),
  productionYear('ProductionYear', '发行年份'),
  premiereDate('PremiereDate', '发行日期'),
  officialRating('OfficialRating', '家长分级'),
  runtime('Runtime', '时间长度');

  const _LibraryItemsSortBy(this.serverValue, this.zhLabel);

  final String serverValue;
  final String zhLabel;

  static _LibraryItemsSortBy? tryParse(String? value) {
    final v = (value ?? '').trim();
    if (v.isEmpty) return null;
    for (final mode in _LibraryItemsSortBy.values) {
      if (mode.serverValue == v) return mode;
    }
    return null;
  }
}

enum _LibraryItemsSortOrder {
  ascending('Ascending', Icons.arrow_upward_rounded, '升序'),
  descending('Descending', Icons.arrow_downward_rounded, '降序');

  const _LibraryItemsSortOrder(this.serverValue, this.icon, this.zhLabel);

  final String serverValue;
  final IconData icon;
  final String zhLabel;

  static _LibraryItemsSortOrder? tryParse(String? value) {
    final v = (value ?? '').trim();
    if (v.isEmpty) return null;
    for (final mode in _LibraryItemsSortOrder.values) {
      if (mode.serverValue.toLowerCase() == v.toLowerCase()) return mode;
    }
    return null;
  }
}

class LibraryItemsPage extends StatefulWidget {
  const LibraryItemsPage({
    super.key,
    required this.appState,
    required this.parentId,
    required this.title,
    this.isTv = false,
  });

  final AppState appState;
  final String parentId;
  final String title;
  final bool isTv;

  @override
  State<LibraryItemsPage> createState() => _LibraryItemsPageState();
}

class _LibraryItemsPageState extends State<LibraryItemsPage> {
  static const String _kPrefsPrefix = 'libraryItemsPrefs_v1:';

  final _scroll = ScrollController();
  bool _loadingMore = false;
  bool _prefetchingAll = false;
  bool _isRequesting = false;
  int _prefetchEpoch = 0;
  String? _error;

  _LibraryItemsViewMode _viewMode = _LibraryItemsViewMode.items;
  _LibraryItemsSortBy _sortBy = _LibraryItemsSortBy.dateCreated;
  _LibraryItemsSortOrder _sortOrder = _LibraryItemsSortOrder.descending;
  final Set<String> _selectedTags = <String>{};

  String get _prefsKey {
    final serverId = widget.appState.activeServerId ?? 'none';
    return '$_kPrefsPrefix$serverId:${widget.parentId}';
  }

  @override
  void initState() {
    super.initState();
    _scroll.addListener(_onScroll);
    unawaited(_restorePrefsAndLoad());
  }

  void _onScroll() {
    if (_loadingMore) return;
    if (_scroll.position.pixels > _scroll.position.maxScrollExtent - 320) {
      _load(reset: false);
    }
  }

  Future<void> _restorePrefsAndLoad() async {
    await _restorePrefs();
    if (!mounted) return;
    await _load(reset: true);
    if (_viewMode == _LibraryItemsViewMode.tags) {
      _startPrefetchAllIfNeeded();
    }
  }

  Future<void> _restorePrefs() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString(_prefsKey);
      if (raw == null || raw.trim().isEmpty) return;
      final decoded = jsonDecode(raw);
      if (decoded is! Map) return;

      final restoredSortBy = _LibraryItemsSortBy.tryParse(
        decoded['sortBy']?.toString(),
      );
      final restoredSortOrder = _LibraryItemsSortOrder.tryParse(
        decoded['sortOrder']?.toString(),
      );
      final restoredViewMode = switch (decoded['viewMode']?.toString()) {
        'tags' => _LibraryItemsViewMode.tags,
        _ => _LibraryItemsViewMode.items,
      };
      final restoredTags = (decoded['selectedTags'] is List)
          ? (decoded['selectedTags'] as List)
              .where((e) => e != null)
              .map((e) => e.toString().trim())
              .where((e) => e.isNotEmpty)
              .toSet()
          : const <String>{};

      if (!mounted) return;
      setState(() {
        _sortBy = restoredSortBy ?? _sortBy;
        _sortOrder = restoredSortOrder ?? _sortOrder;
        _viewMode = restoredViewMode;
        _selectedTags
          ..clear()
          ..addAll(restoredTags);
      });
    } catch (_) {
      // Best-effort; ignore broken prefs.
    }
  }

  Future<void> _persistPrefs() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final data = <String, dynamic>{
        'sortBy': _sortBy.serverValue,
        'sortOrder': _sortOrder.serverValue,
        'viewMode': _viewMode == _LibraryItemsViewMode.tags ? 'tags' : 'items',
        'selectedTags': _selectedTags.toList(growable: false),
      };
      await prefs.setString(_prefsKey, jsonEncode(data));
    } catch (_) {
      // Best-effort; ignore failures.
    }
  }

  Future<void> _load({required bool reset}) async {
    if (_isRequesting) return;
    final items = widget.appState.getItems(widget.parentId);
    final total = widget.appState.getTotal(widget.parentId);
    final start = reset ? 0 : items.length;
    if (!reset && items.length >= total && total != 0) return;
    setState(() {
      _isRequesting = true;
      _loadingMore = true;
      if (reset) _error = null;
    });
    try {
      await widget.appState.loadItems(
        parentId: widget.parentId,
        startIndex: start,
        limit: 30,
        includeItemTypes: 'Series,Movie',
        recursive: true,
        excludeFolders: false,
        sortBy: _sortBy.serverValue,
        sortOrder: _sortOrder.serverValue,
      );
    } catch (e) {
      if (!mounted) return;
      setState(() => _error = e.toString());
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(e.toString())),
      );
    } finally {
      if (mounted) {
        setState(() {
          _isRequesting = false;
          _loadingMore = false;
        });
      }
    }
  }

  void _toggleSortOrder() {
    final next = _sortOrder == _LibraryItemsSortOrder.ascending
        ? _LibraryItemsSortOrder.descending
        : _LibraryItemsSortOrder.ascending;
    _setSort(sortBy: _sortBy, sortOrder: next);
  }

  void _setSort({
    required _LibraryItemsSortBy sortBy,
    required _LibraryItemsSortOrder sortOrder,
  }) {
    if (_sortBy == sortBy && _sortOrder == sortOrder) return;
    setState(() {
      _sortBy = sortBy;
      _sortOrder = sortOrder;
      _error = null;
      _prefetchEpoch++;
      _prefetchingAll = false;
    });
    unawaited(_persistPrefs());
    unawaited(_scrollToTop());
    unawaited(_load(reset: true).then((_) {
      if (_viewMode == _LibraryItemsViewMode.tags) {
        _startPrefetchAllIfNeeded();
      }
    }));
  }

  void _setViewMode(_LibraryItemsViewMode mode) {
    if (_viewMode == mode) return;
    setState(() {
      _viewMode = mode;
      _error = null;
      if (mode != _LibraryItemsViewMode.tags) {
        _prefetchEpoch++;
        _prefetchingAll = false;
      }
    });
    unawaited(_persistPrefs());
    if (mode == _LibraryItemsViewMode.tags) {
      _startPrefetchAllIfNeeded();
    }
  }

  Future<void> _scrollToTop() async {
    if (!_scroll.hasClients) return;
    try {
      await _scroll.animateTo(
        0,
        duration: const Duration(milliseconds: 180),
        curve: Curves.easeOut,
      );
    } catch (_) {
      // ignore scroll errors
    }
  }

  void _startPrefetchAllIfNeeded() {
    if (_prefetchingAll) return;
    final epoch = ++_prefetchEpoch;
    setState(() => _prefetchingAll = true);
    unawaited(() async {
      try {
        while (mounted &&
            epoch == _prefetchEpoch &&
            _viewMode == _LibraryItemsViewMode.tags) {
          final items = widget.appState.getItems(widget.parentId);
          final total = widget.appState.getTotal(widget.parentId);
          if (total != 0 && items.length >= total) break;
          if (_isRequesting) {
            await Future<void>.delayed(const Duration(milliseconds: 80));
            continue;
          }
          await _loadPageForPrefetch(startIndex: items.length);
        }
      } finally {
        if (mounted && epoch == _prefetchEpoch) {
          setState(() => _prefetchingAll = false);
        }
      }
    }());
  }

  Future<void> _loadPageForPrefetch({required int startIndex}) async {
    if (_isRequesting) return;
    setState(() => _isRequesting = true);
    try {
      await widget.appState.loadItems(
        parentId: widget.parentId,
        startIndex: startIndex,
        limit: 200,
        includeItemTypes: 'Series,Movie',
        recursive: true,
        excludeFolders: false,
        sortBy: _sortBy.serverValue,
        sortOrder: _sortOrder.serverValue,
      );
    } catch (e) {
      if (!mounted) return;
      setState(() => _error = e.toString());
    } finally {
      if (mounted) setState(() => _isRequesting = false);
    }
  }

  void _toggleTag(String tag) {
    final normalized = tag.trim();
    if (normalized.isEmpty) return;
    setState(() {
      if (_selectedTags.contains(normalized)) {
        _selectedTags.remove(normalized);
      } else {
        _selectedTags.add(normalized);
      }
    });
    unawaited(_persistPrefs());
  }

  @override
  void dispose() {
    _scroll.dispose();
    super.dispose();
  }

  bool _isTv(BuildContext context) => DeviceType.isTv;

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: widget.appState,
      builder: (context, _) {
        final allItems = widget.appState.getItems(widget.parentId);
        final total = widget.appState.getTotal(widget.parentId);
        final tags = <String>{};
        for (final item in allItems) {
          for (final g in item.genres) {
            final normalized = g.trim();
            if (normalized.isNotEmpty) tags.add(normalized);
          }
        }
        final tagList = tags.toList()
          ..sort((a, b) => a.toLowerCase().compareTo(b.toLowerCase()));

        final items = (_viewMode == _LibraryItemsViewMode.tags &&
                _selectedTags.isNotEmpty)
            ? allItems
                .where((item) => item.genres.any(_selectedTags.contains))
                .toList(growable: false)
            : allItems;

        final access = resolveServerAccess(appState: widget.appState);
        final uiScale = context.uiScale;
        final isTv = _isTv(context);
        final enableBlur = !isTv && widget.appState.enableBlurEffects;
        final maxCrossAxisExtent = (isTv ? 160.0 : 180.0) * uiScale;

        Widget pill({
          required Widget child,
          required VoidCallback? onTap,
          bool selected = false,
        }) {
          final theme = Theme.of(context);
          final scheme = theme.colorScheme;
          final background = selected
              ? scheme.primary.withValues(alpha: 0.16)
              : scheme.surface.withValues(alpha: 0.10);
          final border = selected
              ? scheme.primary.withValues(alpha: 0.55)
              : scheme.outline.withValues(alpha: 0.35);
          final fg = selected ? scheme.primary : theme.iconTheme.color;

          return Material(
            color: Colors.transparent,
            child: InkWell(
              onTap: onTap,
              borderRadius: BorderRadius.circular(999),
              child: Container(
                height: 36 * uiScale,
                padding: EdgeInsets.symmetric(horizontal: 12 * uiScale),
                decoration: BoxDecoration(
                  color: background,
                  borderRadius: BorderRadius.circular(999),
                  border: Border.all(color: border),
                ),
                child: IconTheme.merge(
                  data: IconThemeData(color: fg, size: 18 * uiScale),
                  child: DefaultTextStyle.merge(
                    style: TextStyle(
                      color: theme.textTheme.bodyMedium?.color,
                      fontSize: 13 * uiScale,
                    ),
                    child: child,
                  ),
                ),
              ),
            ),
          );
        }

        PopupMenuItem<_LibraryItemsSortBy> sortItem({
          required _LibraryItemsSortBy value,
        }) {
          return CheckedPopupMenuItem<_LibraryItemsSortBy>(
            value: value,
            checked: _sortBy == value,
            child: Text(value.zhLabel),
          );
        }

        Widget sortButton() {
          return PopupMenuButton<_LibraryItemsSortBy>(
            tooltip: '排序',
            onSelected: (v) => _setSort(sortBy: v, sortOrder: _sortOrder),
            itemBuilder: (context) => [
              sortItem(value: _LibraryItemsSortBy.communityRating),
              sortItem(value: _LibraryItemsSortBy.dateLastContentAdded),
              sortItem(value: _LibraryItemsSortBy.dateCreated),
              sortItem(value: _LibraryItemsSortBy.productionYear),
              sortItem(value: _LibraryItemsSortBy.premiereDate),
              sortItem(value: _LibraryItemsSortBy.officialRating),
              sortItem(value: _LibraryItemsSortBy.runtime),
              const PopupMenuDivider(),
              CheckedPopupMenuItem<_LibraryItemsSortBy>(
                value: _sortBy,
                enabled: false,
                checked: false,
                child: Row(
                  children: [
                    Expanded(
                      child: Text('方向：${_sortOrder.zhLabel}'),
                    ),
                    Icon(_sortOrder.icon, size: 18 * uiScale),
                  ],
                ),
              ),
            ],
            child: pill(
              onTap: null,
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const Icon(Icons.sort_rounded),
                  SizedBox(width: 8 * uiScale),
                  Text('排序：${_sortBy.zhLabel}'),
                  SizedBox(width: 8 * uiScale),
                  InkWell(
                    onTap: _toggleSortOrder,
                    borderRadius: BorderRadius.circular(999),
                    child: Padding(
                      padding: EdgeInsets.all(4 * uiScale),
                      child: Icon(_sortOrder.icon, size: 18 * uiScale),
                    ),
                  ),
                ],
              ),
            ),
          );
        }

        Widget tagButton() {
          final selected = _viewMode == _LibraryItemsViewMode.tags;
          final tagCount = _selectedTags.length;
          final label = tagCount == 0 ? '标签' : '标签（$tagCount）';
          return pill(
            selected: selected,
            onTap: () {
              _setViewMode(selected
                  ? _LibraryItemsViewMode.items
                  : _LibraryItemsViewMode.tags);
            },
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Icon(Icons.local_offer_rounded),
                SizedBox(width: 8 * uiScale),
                Text(label),
              ],
            ),
          );
        }

        Widget tagChipsBar() {
          if (_viewMode != _LibraryItemsViewMode.tags) {
            return const SizedBox.shrink();
          }

          final progressText = total == 0
              ? (allItems.isEmpty ? '加载中…' : '已加载 ${allItems.length}')
              : '已加载 ${allItems.length} / $total';

          return Padding(
            padding: EdgeInsets.only(top: 10 * uiScale),
            child: Column(
              children: [
                SizedBox(
                  height: 42 * uiScale,
                  child: ListView.separated(
                    scrollDirection: Axis.horizontal,
                    padding: EdgeInsets.symmetric(horizontal: 12 * uiScale),
                    itemCount: 1 + tagList.length,
                    separatorBuilder: (_, __) => SizedBox(width: 8 * uiScale),
                    itemBuilder: (context, index) {
                      if (index == 0) {
                        final selected = _selectedTags.isEmpty;
                        return FilterChip(
                          selected: selected,
                          label: const Text('全部'),
                          onSelected: (_) {
                            if (_selectedTags.isEmpty) return;
                            setState(() => _selectedTags.clear());
                            unawaited(_persistPrefs());
                          },
                        );
                      }
                      final tag = tagList[index - 1];
                      final selected = _selectedTags.contains(tag);
                      return FilterChip(
                        selected: selected,
                        label: Text(tag),
                        onSelected: (_) => _toggleTag(tag),
                      );
                    },
                  ),
                ),
                Padding(
                  padding: EdgeInsets.only(top: 6 * uiScale),
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Text(
                        progressText,
                        style: Theme.of(context)
                            .textTheme
                            .bodySmall
                            ?.copyWith(
                              color: Theme.of(context)
                                  .textTheme
                                  .bodySmall
                                  ?.color
                                  ?.withValues(alpha: 0.75),
                            ),
                      ),
                      if (_prefetchingAll) ...[
                        SizedBox(width: 10 * uiScale),
                        SizedBox(
                          width: 14 * uiScale,
                          height: 14 * uiScale,
                          child: const CircularProgressIndicator(strokeWidth: 2),
                        ),
                      ],
                    ],
                  ),
                ),
              ],
            ),
          );
        }

        Widget content() {
          if (allItems.isEmpty && _loadingMore) {
            return const Center(child: CircularProgressIndicator());
          }

          if (_error != null && allItems.isEmpty) {
            return Center(child: Text(_error!));
          }

          if (items.isEmpty && _viewMode == _LibraryItemsViewMode.tags) {
            return const Center(child: Text('没有匹配的项目'));
          }

          return Padding(
            padding: const EdgeInsets.all(12),
            child: GridView.builder(
              controller: _scroll,
              gridDelegate: SliverGridDelegateWithMaxCrossAxisExtent(
                maxCrossAxisExtent: maxCrossAxisExtent,
                mainAxisSpacing: 10,
                crossAxisSpacing: 10,
                childAspectRatio: 0.7,
              ),
              itemCount: items.length + (_loadingMore ? 1 : 0),
              itemBuilder: (context, index) {
                if (index >= items.length) {
                  return const Center(child: CircularProgressIndicator());
                }
                final item = items[index];
                return _GridItem(
                  item: item,
                  appState: widget.appState,
                  access: access,
                  onTap: () {
                    Navigator.of(context).push(
                      MaterialPageRoute(
                        builder: (_) => ShowDetailPage(
                          itemId: item.id,
                          title: item.name,
                          appState: widget.appState,
                          isTv: isTv,
                        ),
                      ),
                    );
                  },
                );
              },
            ),
          );
        }

        return Scaffold(
          appBar: GlassAppBar(
            enableBlur: enableBlur,
            child: AppBar(
              title: Text(widget.title),
            ),
          ),
          body: Column(
            children: [
              SizedBox(height: 10 * uiScale),
              if (!isTv)
                Center(
                  child: Wrap(
                    spacing: 10 * uiScale,
                    runSpacing: 10 * uiScale,
                    alignment: WrapAlignment.center,
                    children: [
                      sortButton(),
                      tagButton(),
                    ],
                  ),
                ),
              tagChipsBar(),
              Expanded(child: content()),
            ],
          ),
        );
      },
    );
  }
}

class _GridItem extends StatelessWidget {
  const _GridItem({
    required this.item,
    required this.appState,
    required this.access,
    required this.onTap,
  });

  final MediaItem item;
  final AppState appState;
  final ServerAccess? access;
  final VoidCallback onTap;

  String _yearOf() {
    final d = (item.premiereDate ?? '').trim();
    if (d.isEmpty) return '';
    final parsed = DateTime.tryParse(d);
    if (parsed != null) return parsed.year.toString();
    return d.length >= 4 ? d.substring(0, 4) : '';
  }

  @override
  Widget build(BuildContext context) {
    final access = this.access;
    final image = item.hasImage && access != null
        ? access.adapter.imageUrl(
            access.auth,
            itemId: item.id,
            imageType: 'Primary',
            maxWidth: 320,
          )
        : null;

    final year = _yearOf();
    final rating = item.communityRating;

    String badge = '';
    if (item.type == 'Movie') {
      badge = '电影';
    } else if (item.type == 'Series') {
      badge = '剧集';
    }

    return MediaPosterTile(
      title: item.name,
      imageUrl: image,
      year: year,
      rating: rating,
      badgeText: badge,
      onTap: onTap,
    );
  }
}
