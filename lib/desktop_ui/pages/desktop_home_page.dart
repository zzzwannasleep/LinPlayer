import 'dart:async';
import 'dart:math';

import 'package:cached_network_image/cached_network_image.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:lin_player_prefs/lin_player_prefs.dart';
import 'package:lin_player_server_adapters/lin_player_server_adapters.dart';
import 'package:lin_player_state/lin_player_state.dart';
import 'package:lin_player_ui/lin_player_ui.dart';

import '../../aggregate_service_page.dart';
import '../../library_items_page.dart';
import '../../player_screen.dart';
import '../../player_screen_exo.dart';
import '../../search_page.dart';
import '../../server_page.dart';
import '../../server_adapters/server_access.dart';
import '../../settings_page.dart';
import '../../show_detail_page.dart';
import '../widgets/desktop_unified_background.dart';

class DesktopHomePage extends StatefulWidget {
  const DesktopHomePage({super.key, required this.appState});

  final AppState appState;

  @override
  State<DesktopHomePage> createState() => _DesktopHomePageState();
}

enum _DesktopHomeTab { home, favorites }

class _DesktopHomePageState extends State<DesktopHomePage> {
  _DesktopHomeTab _selectedTab = _DesktopHomeTab.home;
  bool _bootstrapping = true;
  bool _refreshing = false;
  String? _loadError;
  Future<List<MediaItem>>? _continueWatchingFuture;

  final Set<String> _favoriteItemIds = <String>{};
  final Map<String, bool> _playedOverrides = <String, bool>{};
  final Set<String> _updatingPlayedIds = <String>{};
  String? _activeCardId;

  @override
  void initState() {
    super.initState();
    _continueWatchingFuture =
        widget.appState.loadContinueWatching(forceRefresh: false);
    unawaited(_refreshAll(showBusy: true, forceContinueRefresh: false));
  }

  Future<void> _refreshAll({
    bool showBusy = false,
    bool forceContinueRefresh = true,
  }) async {
    if (showBusy) {
      setState(() {
        _bootstrapping = true;
        _loadError = null;
      });
    } else {
      setState(() {
        _refreshing = true;
        _loadError = null;
      });
    }

    try {
      if (!widget.appState.isLoading) {
        await widget.appState.refreshLibraries();
      }
      await widget.appState.loadHome(forceRefresh: true);
      if (!mounted) return;
      setState(() {
        _continueWatchingFuture = widget.appState.loadContinueWatching(
          forceRefresh: forceContinueRefresh,
        );
      });
    } catch (e) {
      if (!mounted) return;
      setState(() => _loadError = '加载首页失败：$e');
    } finally {
      if (mounted) {
        setState(() {
          _bootstrapping = false;
          _refreshing = false;
        });
      }
    }
  }

  void _reloadContinueWatching({bool forceRefresh = true}) {
    setState(() {
      _continueWatchingFuture = widget.appState.loadContinueWatching(
        forceRefresh: forceRefresh,
      );
    });
  }

  Future<void> _openSearch() async {
    await Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => SearchPage(appState: widget.appState),
      ),
    );
  }

  Future<void> _openServerManager() async {
    await Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => ServerPage(
          appState: widget.appState,
          desktopLayout: true,
        ),
      ),
    );
  }

  Future<void> _openSettings() async {
    await Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => SettingsPage(appState: widget.appState),
      ),
    );
  }

  Future<void> _openAggregateSearch() async {
    await Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => AggregateServicePage(appState: widget.appState),
      ),
    );
  }

  Future<void> _openLocalPlayer() async {
    final useExoCore = !kIsWeb &&
        defaultTargetPlatform == TargetPlatform.android &&
        widget.appState.playerCore == PlayerCore.exo;
    await Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => useExoCore
            ? ExoPlayerScreen(appState: widget.appState)
            : PlayerScreen(appState: widget.appState),
      ),
    );
  }

  Future<void> _showThemePicker() {
    double? opacityDraft;
    double? blurDraft;
    return showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      backgroundColor: const Color(0xF012141A),
      builder: (sheetContext) {
        return StatefulBuilder(
          builder: (context, setSheetState) {
            return AnimatedBuilder(
              animation: widget.appState,
              builder: (context, _) {
                final appState = widget.appState;
                final currentMode = appState.themeMode;
                final selectedMode = currentMode == ThemeMode.system
                    ? (Theme.of(context).brightness == Brightness.dark
                        ? ThemeMode.dark
                        : ThemeMode.light)
                    : currentMode;
                final backgroundImage = appState.desktopBackgroundImage.trim();
                final opacity =
                    (opacityDraft ?? appState.desktopBackgroundOpacity)
                        .clamp(0.0, 1.0)
                        .toDouble();
                final blur = (blurDraft ?? appState.desktopBackgroundBlurSigma)
                    .clamp(0.0, 30.0)
                    .toDouble();
                final opacityPct = (opacity * 100).round();

                return SafeArea(
                  child: Padding(
                    padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          '主题样式',
                          style: Theme.of(context).textTheme.titleLarge,
                        ),
                        const SizedBox(height: 12),
                        const Text(
                          '主题模式',
                          style: TextStyle(
                            color: Colors.white70,
                            fontSize: 13,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                        const SizedBox(height: 8),
                        SegmentedButton<ThemeMode>(
                          segments: const <ButtonSegment<ThemeMode>>[
                            ButtonSegment(
                              value: ThemeMode.light,
                              label: Text('浅色'),
                            ),
                            ButtonSegment(
                              value: ThemeMode.dark,
                              label: Text('深色'),
                            ),
                          ],
                          selected: {selectedMode},
                          onSelectionChanged: (s) {
                            unawaited(appState.setThemeMode(s.first));
                          },
                        ),
                        const SizedBox(height: 14),
                        ListTile(
                          contentPadding: EdgeInsets.zero,
                          leading: const Icon(Icons.image_outlined),
                          title: const Text('自定义背景图'),
                          subtitle: Text(
                            backgroundImage.isEmpty ? '未设置' : backgroundImage,
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                          ),
                          trailing: Wrap(
                            spacing: 8,
                            children: [
                              FilledButton.tonal(
                                onPressed: () async {
                                  final result =
                                      await FilePicker.platform.pickFiles(
                                    dialogTitle: '选择背景图片',
                                    allowMultiple: false,
                                    type: FileType.image,
                                    withData: false,
                                  );
                                  final path = result?.files.single.path;
                                  if (path == null || path.trim().isEmpty) {
                                    return;
                                  }
                                  await appState.setDesktopBackgroundImage(
                                    path.trim(),
                                  );
                                },
                                child: const Text('选择'),
                              ),
                              if (backgroundImage.isNotEmpty)
                                FilledButton.tonal(
                                  onPressed: () =>
                                      appState.setDesktopBackgroundImage(''),
                                  child: const Text('清空'),
                                ),
                            ],
                          ),
                        ),
                        if (backgroundImage.isNotEmpty) ...[
                          const Divider(height: 1),
                          const SizedBox(height: 10),
                          const Text(
                            '背景透明度',
                            style: TextStyle(
                              color: Colors.white70,
                              fontSize: 13,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                          AppSlider(
                            value: opacity,
                            min: 0.0,
                            max: 1.0,
                            divisions: 20,
                            label: '$opacityPct%',
                            onChanged: (v) =>
                                setSheetState(() => opacityDraft = v),
                            onChangeEnd: (v) {
                              setSheetState(() => opacityDraft = null);
                              unawaited(appState.setDesktopBackgroundOpacity(v));
                            },
                          ),
                          const SizedBox(height: 8),
                          const Text(
                            '背景模糊度',
                            style: TextStyle(
                              color: Colors.white70,
                              fontSize: 13,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                          AppSlider(
                            value: blur,
                            min: 0.0,
                            max: 30.0,
                            divisions: 30,
                            label: blur.toStringAsFixed(0),
                            onChanged: (v) =>
                                setSheetState(() => blurDraft = v),
                            onChangeEnd: (v) {
                              setSheetState(() => blurDraft = null);
                              unawaited(
                                appState.setDesktopBackgroundBlurSigma(v),
                              );
                            },
                          ),
                        ],
                      ],
                    ),
                  ),
                );
              },
            );
          },
        );
      },
    );
  }

  Future<void> _showMainMenu() async {
    await showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      backgroundColor: const Color(0xF012141A),
      builder: (sheetContext) {
        return SafeArea(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              ListTile(
                leading: const Icon(Icons.storage_outlined),
                title: const Text('服务器管理'),
                onTap: () {
                  Navigator.of(sheetContext).pop();
                  unawaited(_openServerManager());
                },
              ),
              ListTile(
                leading: const Icon(Icons.search),
                title: const Text('聚合搜索'),
                onTap: () {
                  Navigator.of(sheetContext).pop();
                  unawaited(_openAggregateSearch());
                },
              ),
              ListTile(
                leading: const Icon(Icons.folder_open_outlined),
                title: const Text('本地播放'),
                onTap: () {
                  Navigator.of(sheetContext).pop();
                  unawaited(_openLocalPlayer());
                },
              ),
              ListTile(
                leading: const Icon(Icons.palette_outlined),
                title: const Text('主题样式'),
                onTap: () {
                  Navigator.of(sheetContext).pop();
                  unawaited(_showThemePicker());
                },
              ),
              ListTile(
                leading: const Icon(Icons.settings_outlined),
                title: const Text('设置'),
                onTap: () {
                  Navigator.of(sheetContext).pop();
                  unawaited(_openSettings());
                },
              ),
              ListTile(
                leading: const Icon(Icons.refresh),
                title: const Text('刷新首页'),
                onTap: () {
                  Navigator.of(sheetContext).pop();
                  unawaited(_refreshAll(forceContinueRefresh: true));
                },
              ),
              const SizedBox(height: 8),
            ],
          ),
        );
      },
    );
  }

  Future<void> _showRoutePicker() async {
    if (widget.appState.domains.isEmpty && !widget.appState.isLoading) {
      unawaited(widget.appState.refreshDomains());
    }

    await showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      backgroundColor: const Color(0xF012141A),
      builder: (sheetContext) {
        return AnimatedBuilder(
          animation: widget.appState,
          builder: (context, _) {
            final current = widget.appState.baseUrl;
            final customEntries = widget.appState.customDomains
                .map((d) => DomainInfo(name: d.name, url: d.url))
                .toList(growable: false);
            final pluginDomains = widget.appState.domains;
            final entries = buildRouteEntries(
              currentUrl: current,
              customEntries: customEntries,
              pluginDomains: pluginDomains,
            );

            return SafeArea(
              child: Padding(
                padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        const Expanded(
                          child: Text(
                            '线路',
                            style: TextStyle(
                              fontSize: 18,
                              fontWeight: FontWeight.w700,
                            ),
                          ),
                        ),
                        IconButton(
                          tooltip: '添加自定义线路',
                          onPressed: _addCustomRoute,
                          icon: const Icon(Icons.add),
                        ),
                        IconButton(
                          tooltip: '刷新',
                          onPressed: widget.appState.isLoading
                              ? null
                              : widget.appState.refreshDomains,
                          icon: const Icon(Icons.refresh),
                        ),
                      ],
                    ),
                    const SizedBox(height: 4),
                    if (entries.isEmpty && !widget.appState.isLoading)
                      const Padding(
                        padding: EdgeInsets.symmetric(vertical: 16),
                        child: Text('暂无可用线路（未部署扩展时属于正常情况）'),
                      )
                    else
                      Flexible(
                        child: ListView.separated(
                          shrinkWrap: true,
                          itemCount: entries.length,
                          separatorBuilder: (_, __) => const Divider(height: 1),
                          itemBuilder: (context, index) {
                            final entry = entries[index];
                            final domain = entry.domain;
                            final selected = current == domain.url;
                            final remark = widget.appState.domainRemark(domain.url);
                            return ListTile(
                              dense: true,
                              contentPadding: EdgeInsets.zero,
                              title: Text(
                                domain.name.trim().isEmpty
                                    ? domain.url
                                    : domain.name.trim(),
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                              ),
                              subtitle: Text(
                                [
                                  if ((remark ?? '').trim().isNotEmpty)
                                    remark!.trim(),
                                  domain.url,
                                ].join(' · '),
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                              ),
                              trailing: selected
                                  ? const Icon(Icons.check, color: Colors.green)
                                  : null,
                              onLongPress: !entry.isCustom
                                  ? null
                                  : () => _removeCustomRoute(domain.url),
                              onTap: () async {
                                await widget.appState.setBaseUrl(domain.url);
                                await widget.appState.refreshLibraries();
                                await widget.appState.loadHome(forceRefresh: true);
                                _reloadContinueWatching(forceRefresh: true);
                                if (!sheetContext.mounted) return;
                                Navigator.of(sheetContext).pop();
                              },
                            );
                          },
                        ),
                      ),
                  ],
                ),
              ),
            );
          },
        );
      },
    );
  }

  Future<void> _addCustomRoute() async {
    final nameCtrl = TextEditingController();
    final urlCtrl = TextEditingController();
    final remarkCtrl = TextEditingController();

    final result = await showDialog<Map<String, String>>(
      context: context,
      builder: (dialogContext) {
        return AlertDialog(
          title: const Text('添加自定义线路'),
          content: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                TextField(
                  controller: nameCtrl,
                  decoration: const InputDecoration(
                    labelText: '名称',
                    hintText: '例如：直连 / 备用',
                  ),
                ),
                const SizedBox(height: 10),
                TextField(
                  controller: urlCtrl,
                  decoration: const InputDecoration(
                    labelText: '地址',
                    hintText: '例如：https://emby.example.com:8920',
                  ),
                  keyboardType: TextInputType.url,
                ),
                const SizedBox(height: 10),
                TextField(
                  controller: remarkCtrl,
                  decoration: const InputDecoration(
                    labelText: '备注（可选）',
                    hintText: '例如：移动网络',
                  ),
                ),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(dialogContext).pop(),
              child: const Text('取消'),
            ),
            FilledButton(
              onPressed: () {
                Navigator.of(dialogContext).pop({
                  'name': nameCtrl.text.trim(),
                  'url': urlCtrl.text.trim(),
                  'remark': remarkCtrl.text.trim(),
                });
              },
              child: const Text('保存'),
            ),
          ],
        );
      },
    );

    if (result == null) return;
    try {
      await widget.appState.addCustomDomain(
        name: result['name'] ?? '',
        url: result['url'] ?? '',
        remark: (result['remark'] ?? '').trim().isEmpty
            ? null
            : (result['remark'] ?? '').trim(),
      );
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(e.toString())),
      );
    }
  }

  Future<void> _removeCustomRoute(String url) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) {
        return AlertDialog(
          title: const Text('删除线路？'),
          content: const Text('将删除该自定义线路。'),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(dialogContext).pop(false),
              child: const Text('取消'),
            ),
            FilledButton(
              onPressed: () => Navigator.of(dialogContext).pop(true),
              child: const Text('删除'),
            ),
          ],
        );
      },
    );
    if (confirmed != true) return;
    await widget.appState.removeCustomDomain(url);
  }

  Future<void> _openItemDetail(MediaItem item) async {
    final isEpisode = item.type.toLowerCase() == 'episode';
    await Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => isEpisode
            ? EpisodeDetailPage(
                episode: item,
                appState: widget.appState,
              )
            : ShowDetailPage(
                itemId: item.id,
                title: item.name,
                appState: widget.appState,
              ),
      ),
    );
  }

  Future<void> _openLibraryItems(String parentId, String title) async {
    await Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => LibraryItemsPage(
          appState: widget.appState,
          parentId: parentId,
          title: title,
          isTv: false,
        ),
      ),
    );
  }

  void _setActiveCard(String? cardId) {
    if (_activeCardId == cardId) return;
    setState(() => _activeCardId = cardId);
  }

  void _toggleFavorite(String itemId) {
    setState(() {
      if (_favoriteItemIds.contains(itemId)) {
        _favoriteItemIds.remove(itemId);
      } else {
        _favoriteItemIds.add(itemId);
      }
    });
  }

  bool _isFavorite(String itemId) => _favoriteItemIds.contains(itemId);

  bool _isPlayed(MediaItem item) => _playedOverrides[item.id] ?? item.played;

  void _applyPlayedOverride({
    required String itemId,
    required bool value,
    required bool original,
  }) {
    if (value == original) {
      _playedOverrides.remove(itemId);
      return;
    }
    _playedOverrides[itemId] = value;
  }

  Future<void> _togglePlayed(MediaItem item) async {
    final access = resolveServerAccess(appState: widget.appState);
    if (access == null) return;
    if (_updatingPlayedIds.contains(item.id)) return;

    final previousPlayed = _isPlayed(item);
    final nextPlayed = !previousPlayed;
    final runTimeTicks = item.runTimeTicks ?? 0;
    final nextPositionTicks = nextPlayed
        ? max(item.playbackPositionTicks, runTimeTicks > 0 ? runTimeTicks : 1)
        : 0;

    setState(() {
      _updatingPlayedIds.add(item.id);
      _applyPlayedOverride(
        itemId: item.id,
        value: nextPlayed,
        original: item.played,
      );
    });

    try {
      await access.adapter.updatePlaybackPosition(
        access.auth,
        itemId: item.id,
        positionTicks: nextPositionTicks,
        played: nextPlayed,
      );
      if (!mounted) return;
      _reloadContinueWatching(forceRefresh: true);
      unawaited(widget.appState.loadHome(forceRefresh: true));
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(nextPlayed ? '已标记为已播放' : '已标记为未播放'),
          duration: const Duration(milliseconds: 1200),
        ),
      );
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _applyPlayedOverride(
          itemId: item.id,
          value: previousPlayed,
          original: item.played,
        );
      });
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('操作失败：$e')),
      );
    } finally {
      if (mounted) {
        setState(() => _updatingPlayedIds.remove(item.id));
      }
    }
  }

  List<HomeEntry> _entriesForCurrentTab(List<HomeEntry> source) {
    if (_selectedTab == _DesktopHomeTab.home) {
      return source.where((entry) => entry.items.isNotEmpty).toList();
    }
    final result = <HomeEntry>[];
    for (final entry in source) {
      final filtered = entry.items
          .where((item) => _favoriteItemIds.contains(item.id))
          .toList(growable: false);
      if (filtered.isEmpty) continue;
      result.add(
        HomeEntry(
          key: entry.key,
          displayName: entry.displayName,
          items: filtered,
        ),
      );
    }
    return result;
  }

  List<LibraryInfo> _visibleLibraries() {
    return widget.appState.libraries
        .where((lib) => !widget.appState.isLibraryHidden(lib.id))
        .toList(growable: false);
  }

  String? _libraryId(HomeEntry entry) {
    if (!entry.key.startsWith('lib_')) return null;
    final id = entry.key.substring(4);
    if (id.trim().isEmpty) return null;
    return id;
  }

  String _episodeTag(MediaItem item) {
    final season = item.seasonNumber ?? 0;
    final episode = item.episodeNumber ?? 0;
    if (season <= 0 && episode <= 0) return '';
    if (season > 0 && episode > 0) {
      return 'S${season.toString().padLeft(2, '0')}E${episode.toString().padLeft(2, '0')}';
    }
    if (episode > 0) return 'E${episode.toString().padLeft(2, '0')}';
    return 'S${season.toString().padLeft(2, '0')}';
  }

  String _formatPosition(Duration d) {
    final h = d.inHours;
    final m = d.inMinutes.remainder(60);
    final s = d.inSeconds.remainder(60);
    if (h > 0) {
      return '${h.toString().padLeft(2, '0')}:${m.toString().padLeft(2, '0')}:${s.toString().padLeft(2, '0')}';
    }
    return '${m.toString().padLeft(2, '0')}:${s.toString().padLeft(2, '0')}';
  }

  Duration _ticksToDuration(int ticks) =>
      Duration(microseconds: (ticks / 10).round());

  String _continueSubtitle(MediaItem item) {
    final pieces = <String>[];
    if (item.seriesName.trim().isNotEmpty) pieces.add(item.seriesName.trim());
    final tag = _episodeTag(item);
    if (tag.isNotEmpty) pieces.add(tag);
    if (item.playbackPositionTicks > 0) {
      pieces.add('观看到 ${_formatPosition(_ticksToDuration(item.playbackPositionTicks))}');
    }
    return pieces.join(' · ');
  }

  String _itemYear(MediaItem item) {
    final raw = item.premiereDate;
    if (raw == null || raw.length < 4) return '';
    final value = int.tryParse(raw.substring(0, 4));
    return value == null ? '' : value.toString();
  }

  String _itemMeta(MediaItem item) {
    final year = _itemYear(item);
    final type = switch (item.type.toLowerCase()) {
      'movie' => '电影',
      'series' => '剧集',
      'season' => '分季',
      'episode' => '剧集',
      _ => '媒体',
    };
    if (year.isEmpty) return type;
    return '$year · $type';
  }

  String? _itemBadge(MediaItem item) {
    if (item.type.toLowerCase() == 'episode' && item.episodeNumber != null) {
      return 'E${item.episodeNumber}';
    }
    if (item.communityRating != null) {
      return item.communityRating!.toStringAsFixed(1);
    }
    if (item.played) return '看过';
    return null;
  }

  Color _badgeColor(MediaItem item) {
    if (item.played) return const Color(0xFFEF4444);
    if (item.type.toLowerCase() == 'episode') return const Color(0xFF10B981);
    return const Color(0xFF3B82F6);
  }

  IconData _libraryIcon(LibraryInfo library) {
    return switch (library.type.toLowerCase()) {
      'movies' => Icons.movie_outlined,
      'tvshows' => Icons.live_tv_outlined,
      'music' => Icons.music_note_outlined,
      'boxsets' => Icons.collections_bookmark_outlined,
      'homevideos' => Icons.video_library_outlined,
      _ => Icons.folder_open_outlined,
    };
  }

  String _librarySubtitle(LibraryInfo library) {
    return switch (library.type.toLowerCase()) {
      'movies' => 'Movies',
      'tvshows' => 'Series',
      'music' => 'Music',
      'boxsets' => 'Collections',
      'homevideos' => 'Videos',
      _ => 'Library',
    };
  }

  double _contentHorizontalPadding(double width) {
    if (width >= 1440) return 24;
    if (width >= 1024) return 20;
    if (width >= 768) return 16;
    return 14;
  }

  String? _itemImageUrl(
    ServerAccess? access,
    MediaItem item, {
    String imageType = 'Primary',
    int? maxWidth,
  }) {
    if (access == null) return null;
    final targetId = item.hasImage
        ? item.id
        : (item.parentId ?? item.seriesId ?? item.id);
    return access.adapter.imageUrl(
      access.auth,
      itemId: targetId,
      imageType: imageType,
      maxWidth: maxWidth,
    );
  }

  List<String> _itemImageCandidates(
    ServerAccess? access,
    MediaItem item, {
    int? maxWidth,
  }) {
    if (access == null) return const [];
    final ids = <String>{
      item.id,
      if ((item.parentId ?? '').trim().isNotEmpty) item.parentId!.trim(),
      if ((item.seriesId ?? '').trim().isNotEmpty) item.seriesId!.trim(),
    };
    final urls = <String>{};
    for (final id in ids) {
      urls.add(
        access.adapter.imageUrl(
          access.auth,
          itemId: id,
          imageType: 'Backdrop',
          maxWidth: maxWidth,
        ),
      );
      urls.add(
        access.adapter.imageUrl(
          access.auth,
          itemId: id,
          imageType: 'Primary',
          maxWidth: maxWidth,
        ),
      );
      urls.add(
        access.adapter.imageUrl(
          access.auth,
          itemId: id,
          imageType: 'Thumb',
          maxWidth: maxWidth,
        ),
      );
    }
    return urls.toList(growable: false);
  }

  String? _libraryImageUrl(
    ServerAccess? access,
    LibraryInfo library, {
    int? maxWidth,
  }) {
    if (access == null) return null;
    return access.adapter.imageUrl(
      access.auth,
      itemId: library.id,
      maxWidth: maxWidth,
    );
  }

  Widget _buildMediaLibrarySection({
    required double horizontalPadding,
    required List<LibraryInfo> libraries,
    required ServerAccess? access,
  }) {
    if (libraries.isEmpty) return const SizedBox.shrink();

    const palettes = <List<Color>>[
      [Color(0xFF1E3A8A), Color(0xFF2563EB)],
      [Color(0xFF0F766E), Color(0xFF14B8A6)],
      [Color(0xFF4C1D95), Color(0xFF7C3AED)],
      [Color(0xFF7F1D1D), Color(0xFFEF4444)],
      [Color(0xFF365314), Color(0xFF65A30D)],
      [Color(0xFF1F2937), Color(0xFF4B5563)],
      [Color(0xFF78350F), Color(0xFFF59E0B)],
      [Color(0xFF0F172A), Color(0xFF475569)],
    ];
    final width = MediaQuery.of(context).size.width;
    final cardWidth = width >= 1600
        ? 260.0
        : width >= 1280
            ? 240.0
            : width >= 960
                ? 220.0
                : 200.0;
    final listHeight = cardWidth * 9 / 16;

    return Padding(
      padding: EdgeInsets.symmetric(horizontal: horizontalPadding),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const _SectionTitleBar(title: '媒体库'),
          const SizedBox(height: 16),
          _HorizontalCarousel(
            height: listHeight,
            itemCount: libraries.length,
            separatorWidth: 16,
            scrollStep: cardWidth * 2.4,
            itemBuilder: (context, index) {
              final library = libraries[index];
              final cardId = 'library:${library.id}:$index';
              final colors = palettes[index % palettes.length];
              return SizedBox(
                width: cardWidth,
                child: _LibraryCard(
                  title: library.name,
                  subtitle: _librarySubtitle(library),
                  icon: _libraryIcon(library),
                  imageUrl: _libraryImageUrl(
                    access,
                    library,
                    maxWidth: 900,
                  ),
                  palette: colors,
                  selected: _activeCardId == cardId,
                  onActiveChanged: (active) {
                    if (active) {
                      _setActiveCard(cardId);
                    } else if (_activeCardId == cardId) {
                      _setActiveCard(null);
                    }
                  },
                  onTap: () => _openLibraryItems(library.id, library.name),
                ),
              );
            },
          ),
        ],
      ),
    );
  }

  Widget _buildContinueWatchingSection({
    required double horizontalPadding,
    required ServerAccess? access,
  }) {
    final future = _continueWatchingFuture ??
        widget.appState.loadContinueWatching(forceRefresh: false);

    return FutureBuilder<List<MediaItem>>(
      future: future,
      builder: (context, snapshot) {
        final scheme = Theme.of(context).colorScheme;
        final isDark = scheme.brightness == Brightness.dark;
        final allItems = snapshot.data ?? const <MediaItem>[];
        final items = _selectedTab == _DesktopHomeTab.home
            ? allItems
            : allItems
                .where((item) => _favoriteItemIds.contains(item.id))
                .toList(growable: false);

        if (snapshot.connectionState == ConnectionState.waiting &&
            items.isEmpty &&
            _bootstrapping) {
          return Padding(
            padding: EdgeInsets.symmetric(horizontal: horizontalPadding),
            child: const SizedBox(
              height: 220,
              child: Center(child: CircularProgressIndicator()),
            ),
          );
        }

        if (snapshot.hasError && items.isEmpty) {
          return Padding(
            padding: EdgeInsets.symmetric(horizontal: horizontalPadding),
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
              decoration: BoxDecoration(
                color: (isDark ? scheme.surface : scheme.surfaceContainerHighest)
                    .withValues(alpha: isDark ? 0.34 : 0.92),
                borderRadius: BorderRadius.circular(14),
                border: Border.all(
                  color: scheme.outlineVariant
                      .withValues(alpha: isDark ? 0.28 : 0.55),
                ),
              ),
              child: Row(
                children: [
                  Expanded(
                    child: Text(
                      '继续观看加载失败：${snapshot.error}',
                      style: TextStyle(color: scheme.onSurfaceVariant),
                    ),
                  ),
                  const SizedBox(width: 12),
                  TextButton.icon(
                    onPressed: () => _reloadContinueWatching(forceRefresh: true),
                    icon: const Icon(Icons.refresh),
                    label: const Text('重试'),
                  ),
                ],
              ),
            ),
          );
        }

        if (items.isEmpty && _selectedTab == _DesktopHomeTab.favorites) {
          return const SizedBox.shrink();
        }
        if (items.isEmpty) {
          return Padding(
            padding: EdgeInsets.symmetric(horizontal: horizontalPadding),
            child: const SizedBox.shrink(),
          );
        }

        final width = MediaQuery.of(context).size.width;
        final cardWidth = width >= 1600
            ? 320.0
            : width >= 1280
                ? 300.0
                : width >= 960
                    ? 280.0
                    : 250.0;
        final listHeight = cardWidth * 9 / 16 + 66;

        return Padding(
          padding: EdgeInsets.symmetric(horizontal: horizontalPadding),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              _SectionTitleBar(
                title: _selectedTab == _DesktopHomeTab.home ? '继续观看' : '喜欢',
                actionLabel: '刷新',
                onAction: _refreshing
                    ? null
                    : () => _reloadContinueWatching(forceRefresh: true),
              ),
              const SizedBox(height: 14),
              _HorizontalCarousel(
                height: listHeight,
                itemCount: items.length,
                separatorWidth: 16,
                scrollStep: cardWidth * 2.2,
                itemBuilder: (context, index) {
                  final item = items[index];
                  final cardId = 'continue:${item.id}:$index';
                  final played = _isPlayed(item);
                  final progress = (() {
                    final total = item.runTimeTicks ?? 0;
                    if (total <= 0) return 0.0;
                    final ratio = item.playbackPositionTicks / total;
                    return ratio.clamp(0.0, 1.0);
                  })();
                  final imageCandidates = _itemImageCandidates(
                    access,
                    item,
                    maxWidth: 900,
                  );

                  return SizedBox(
                    width: cardWidth,
                    child: _ContinueWatchingCard(
                      title: item.name,
                      subtitle: _continueSubtitle(item),
                      imageUrl:
                          imageCandidates.isEmpty ? null : imageCandidates.first,
                      fallbackImageUrls: imageCandidates.length > 1
                          ? imageCandidates.sublist(1)
                          : const <String>[],
                      progress: progress,
                      played: played,
                      favorite: _isFavorite(item.id),
                      selected: _activeCardId == cardId,
                      onActiveChanged: (active) {
                        if (active) {
                          _setActiveCard(cardId);
                        } else if (_activeCardId == cardId) {
                          _setActiveCard(null);
                        }
                      },
                      updatingPlayed: _updatingPlayedIds.contains(item.id),
                      onTap: () => _openItemDetail(item),
                      onTogglePlayed: () => _togglePlayed(item),
                      onToggleFavorite: () => _toggleFavorite(item.id),
                    ),
                  );
                },
              ),
            ],
          ),
        );
      },
    );
  }

  Widget _buildCategorySection({
    required double horizontalPadding,
    required HomeEntry entry,
    required ServerAccess? access,
  }) {
    final width = MediaQuery.of(context).size.width;
    final posterWidth = width >= 1600
        ? 190.0
        : width >= 1280
            ? 176.0
            : width >= 960
                ? 164.0
                : 144.0;
    final sectionHeight = posterWidth * 3 / 2 + 56;
    final libraryId = _libraryId(entry);

    return Padding(
      padding: EdgeInsets.symmetric(horizontal: horizontalPadding),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _SectionTitleBar(
            title: entry.displayName,
            actionLabel: libraryId == null ? null : '查看全部',
            onAction: libraryId == null
                ? null
                : () => _openLibraryItems(libraryId, entry.displayName),
          ),
          const SizedBox(height: 12),
          _HorizontalCarousel(
            height: sectionHeight,
            itemCount: entry.items.length,
            separatorWidth: 14,
            scrollStep: posterWidth * 4.5,
            itemBuilder: (context, index) {
              final item = entry.items[index];
              final cardId = 'entry:${entry.key}:${item.id}:$index';
              return SizedBox(
                width: posterWidth,
                child: _PosterCard(
                  title: item.name,
                  meta: _itemMeta(item),
                  imageUrl: _itemImageUrl(
                    access,
                    item,
                    imageType: 'Primary',
                    maxWidth: 600,
                  ),
                  badgeText: _itemBadge(item),
                  badgeColor: _badgeColor(item),
                  favorite: _isFavorite(item.id),
                  selected: _activeCardId == cardId,
                  onActiveChanged: (active) {
                    if (active) {
                      _setActiveCard(cardId);
                    } else if (_activeCardId == cardId) {
                      _setActiveCard(null);
                    }
                  },
                  onTap: () => _openItemDetail(item),
                  onToggleFavorite: () => _toggleFavorite(item.id),
                ),
              );
            },
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: widget.appState,
      builder: (context, _) {
        final allHomeEntries = widget.appState.homeEntries.toList(growable: false);
        final visibleEntries = _entriesForCurrentTab(allHomeEntries);
        final visibleLibraries = _visibleLibraries();
        final access = resolveServerAccess(appState: widget.appState);
        final width = MediaQuery.of(context).size.width;
        final horizontalPadding = _contentHorizontalPadding(width);
        final scheme = Theme.of(context).colorScheme;
        final isDark = scheme.brightness == Brightness.dark;
        final baseBackgroundColor = DesktopUnifiedBackground.baseColorForBrightness(
          Theme.of(context).brightness,
        );

        final emptyState = !_bootstrapping &&
            visibleEntries.isEmpty &&
            (_selectedTab == _DesktopHomeTab.favorites
                ? _favoriteItemIds.isEmpty
                : visibleLibraries.isEmpty);

        return Scaffold(
          backgroundColor: baseBackgroundColor,
          body: Stack(
            children: [
              Positioned.fill(
                child: DesktopUnifiedBackground(
                  appState: widget.appState,
                  baseColor: baseBackgroundColor,
                ),
              ),
              SafeArea(
                child: Column(
                  children: [
                    const SizedBox(height: 8),
                    _DesktopHeaderBar(
                      horizontalPadding: horizontalPadding,
                      onMenuTap: _showMainMenu,
                      onSearchTap: _openSearch,
                      onRouteTap: _showRoutePicker,
                    ),
                    const SizedBox(height: 10),
                    _HomeTabSwitcher(
                      selectedTab: _selectedTab,
                      onChanged: (next) => setState(() => _selectedTab = next),
                    ),
                    const SizedBox(height: 12),
                    Expanded(
                      child: RefreshIndicator(
                        onRefresh: () =>
                            _refreshAll(forceContinueRefresh: true),
                        child: ListView(
                          physics: const AlwaysScrollableScrollPhysics(
                            parent: BouncingScrollPhysics(),
                          ),
                          padding: const EdgeInsets.only(bottom: 24),
                          children: [
                            if (_loadError != null)
                              Padding(
                                padding: EdgeInsets.fromLTRB(
                                  horizontalPadding,
                                  0,
                                  horizontalPadding,
                                  14,
                                ),
                                child: Container(
                                  padding: const EdgeInsets.symmetric(
                                    horizontal: 14,
                                    vertical: 12,
                                  ),
                                  decoration: BoxDecoration(
                                    color: const Color(0x44EF4444),
                                    borderRadius: BorderRadius.circular(12),
                                    border: Border.all(
                                      color: const Color(0x88EF4444),
                                    ),
                                  ),
                                  child: Text(
                                    _loadError!,
                                    style: const TextStyle(color: Colors.white),
                                  ),
                                ),
                              ),
                            if (_selectedTab == _DesktopHomeTab.home) ...[
                              _buildMediaLibrarySection(
                                horizontalPadding: horizontalPadding,
                                libraries: visibleLibraries,
                                access: access,
                              ),
                              const SizedBox(height: 26),
                            ],
                            _buildContinueWatchingSection(
                              horizontalPadding: horizontalPadding,
                              access: access,
                            ),
                            if (visibleEntries.isNotEmpty) const SizedBox(height: 28),
                            for (var i = 0; i < visibleEntries.length; i++) ...[
                              _buildCategorySection(
                                horizontalPadding: horizontalPadding,
                                entry: visibleEntries[i],
                                access: access,
                              ),
                              const SizedBox(height: 28),
                            ],
                            if (_bootstrapping &&
                                visibleEntries.isEmpty &&
                                visibleLibraries.isEmpty)
                              Padding(
                                padding: EdgeInsets.symmetric(
                                  horizontal: horizontalPadding,
                                ),
                                child: const SizedBox(
                                  height: 180,
                                  child: Center(
                                    child: CircularProgressIndicator(),
                                  ),
                                ),
                              ),
                            if (emptyState)
                              Padding(
                                padding: EdgeInsets.fromLTRB(
                                  horizontalPadding,
                                  10,
                                  horizontalPadding,
                                  0,
                                ),
                                child: Container(
                                  padding: const EdgeInsets.symmetric(
                                    horizontal: 16,
                                    vertical: 18,
                                  ),
                                  decoration: BoxDecoration(
                                    color: (isDark
                                            ? scheme.surface
                                            : scheme.surfaceContainerHighest)
                                        .withValues(alpha: isDark ? 0.30 : 0.90),
                                    borderRadius: BorderRadius.circular(14),
                                    border: Border.all(
                                      color: scheme.outlineVariant
                                          .withValues(alpha: isDark ? 0.30 : 0.55),
                                    ),
                                  ),
                                  child: Text(
                                    _selectedTab == _DesktopHomeTab.favorites
                                        ? '喜欢列表为空，先点亮卡片右下角心形。'
                                        : '当前暂无首页内容，点击下拉刷新重试。',
                                    style: TextStyle(
                                      color: scheme.onSurfaceVariant,
                                      fontSize: 14,
                                    ),
                                  ),
                                ),
                              ),
                          ],
                        ),
                      ),
                    ),
                  ],
                ),
              ),
              if (_refreshing)
                const Positioned(
                  top: 8,
                  right: 16,
                  child: SizedBox(
                    width: 20,
                    height: 20,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  ),
                ),
            ],
          ),
        );
      },
    );
  }
}

class _DesktopHeaderBar extends StatelessWidget {
  const _DesktopHeaderBar({
    required this.horizontalPadding,
    required this.onMenuTap,
    required this.onSearchTap,
    required this.onRouteTap,
  });

  final double horizontalPadding;
  final VoidCallback onMenuTap;
  final VoidCallback onSearchTap;
  final VoidCallback onRouteTap;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final isDark = scheme.brightness == Brightness.dark;
    return Padding(
      padding: EdgeInsets.symmetric(horizontal: horizontalPadding),
      child: SizedBox(
        height: 60,
        child: Row(
          children: [
            _HeaderIconButton(
              icon: Icons.menu_rounded,
              tooltip: '菜单',
              onTap: onMenuTap,
            ),
            const SizedBox(width: 10),
            Container(
              width: 30,
              height: 30,
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(8),
                gradient: const LinearGradient(
                  begin: Alignment.topLeft,
                  end: Alignment.bottomRight,
                  colors: [Color(0xFF1D4ED8), Color(0xFF38BDF8)],
                ),
              ),
              child: const Icon(Icons.play_arrow_rounded, color: Colors.white),
            ),
            const SizedBox(width: 10),
            Text(
              'Linplayer',
              style: TextStyle(
                color: isDark ? Colors.white : scheme.onSurface,
                fontSize: 22,
                fontWeight: FontWeight.w700,
                letterSpacing: 0.2,
              ),
            ),
            const Spacer(),
            _HeaderIconButton(
              icon: Icons.search_rounded,
              tooltip: '搜索',
              onTap: onSearchTap,
            ),
            const SizedBox(width: 10),
            _HeaderIconButton(
              icon: Icons.alt_route_rounded,
              tooltip: '线路',
              onTap: onRouteTap,
            ),
          ],
        ),
      ),
    );
  }
}

class _HeaderIconButton extends StatelessWidget {
  const _HeaderIconButton({
    required this.icon,
    required this.tooltip,
    required this.onTap,
  });

  final IconData icon;
  final String tooltip;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final isDark = scheme.brightness == Brightness.dark;
    final bgColor = isDark
        ? Colors.white.withValues(alpha: 0.08)
        : scheme.surface.withValues(alpha: 0.78);
    final borderColor = isDark
        ? Colors.white.withValues(alpha: 0.18)
        : scheme.outlineVariant.withValues(alpha: 0.55);
    final iconColor = isDark ? Colors.white : scheme.onSurface;
    return Tooltip(
      message: tooltip,
      child: Material(
        color: Colors.transparent,
        borderRadius: BorderRadius.circular(12),
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(12),
          child: Ink(
            width: 42,
            height: 42,
            decoration: BoxDecoration(
              color: bgColor,
              borderRadius: BorderRadius.circular(12),
              border: Border.all(
                color: borderColor,
              ),
            ),
            child: Icon(
              icon,
              color: iconColor,
              size: 22,
            ),
          ),
        ),
      ),
    );
  }
}

class _HomeTabSwitcher extends StatelessWidget {
  const _HomeTabSwitcher({
    required this.selectedTab,
    required this.onChanged,
  });

  final _DesktopHomeTab selectedTab;
  final ValueChanged<_DesktopHomeTab> onChanged;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final isDark = scheme.brightness == Brightness.dark;
    return Container(
      padding: const EdgeInsets.all(4),
      decoration: BoxDecoration(
        color: (isDark ? Colors.black : scheme.surfaceContainerHighest)
            .withValues(alpha: isDark ? 0.32 : 0.86),
        borderRadius: BorderRadius.circular(20),
        border: Border.all(
          color: isDark
              ? Colors.white.withValues(alpha: 0.12)
              : scheme.outlineVariant.withValues(alpha: 0.45),
        ),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          _TabChip(
            label: '主页',
            selected: selectedTab == _DesktopHomeTab.home,
            onTap: () => onChanged(_DesktopHomeTab.home),
          ),
          const SizedBox(width: 6),
          _TabChip(
            label: '喜欢',
            selected: selectedTab == _DesktopHomeTab.favorites,
            onTap: () => onChanged(_DesktopHomeTab.favorites),
          ),
        ],
      ),
    );
  }
}

class _TabChip extends StatelessWidget {
  const _TabChip({
    required this.label,
    required this.selected,
    required this.onTap,
  });

  final String label;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final isDark = scheme.brightness == Brightness.dark;
    final unselectedColor = isDark ? Colors.white70 : scheme.onSurfaceVariant;
    return Material(
      color: Colors.transparent,
      borderRadius: BorderRadius.circular(16),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(16),
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 180),
          curve: Curves.easeOutCubic,
          padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 8),
          decoration: BoxDecoration(
            color: selected ? const Color(0xFF3B82F6) : Colors.transparent,
            borderRadius: BorderRadius.circular(16),
          ),
          child: Text(
            label,
            style: TextStyle(
              color: selected ? Colors.white : unselectedColor,
              fontSize: 15,
              fontWeight: FontWeight.w600,
            ),
          ),
        ),
      ),
    );
  }
}

class _SectionTitleBar extends StatelessWidget {
  const _SectionTitleBar({
    required this.title,
    this.actionLabel,
    this.onAction,
  });

  final String title;
  final String? actionLabel;
  final VoidCallback? onAction;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Row(
      children: [
        Expanded(
          child: Text(
            title,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              color: scheme.onSurface,
              fontSize: 20,
              fontWeight: FontWeight.w700,
            ),
          ),
        ),
        if ((actionLabel ?? '').isNotEmpty)
          TextButton(
            onPressed: onAction,
            child: Text(
              '$actionLabel >',
              style: TextStyle(
                color: scheme.onSurfaceVariant,
                fontSize: 14,
                fontWeight: FontWeight.w500,
              ),
            ),
          ),
      ],
    );
  }
}

class _HorizontalCarousel extends StatefulWidget {
  const _HorizontalCarousel({
    required this.height,
    required this.itemCount,
    required this.itemBuilder,
    this.separatorWidth = 12,
    this.scrollStep = 320,
  });

  final double height;
  final int itemCount;
  final IndexedWidgetBuilder itemBuilder;
  final double separatorWidth;
  final double scrollStep;

  @override
  State<_HorizontalCarousel> createState() => _HorizontalCarouselState();
}

class _HorizontalCarouselState extends State<_HorizontalCarousel> {
  late final ScrollController _controller = ScrollController()
    ..addListener(_updateArrowState);
  bool _canScrollLeft = false;
  bool _canScrollRight = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _updateArrowState());
  }

  @override
  void didUpdateWidget(covariant _HorizontalCarousel oldWidget) {
    super.didUpdateWidget(oldWidget);
    WidgetsBinding.instance.addPostFrameCallback((_) => _updateArrowState());
  }

  @override
  void dispose() {
    _controller
      ..removeListener(_updateArrowState)
      ..dispose();
    super.dispose();
  }

  void _updateArrowState() {
    if (!_controller.hasClients) {
      if (_canScrollLeft || _canScrollRight) {
        setState(() {
          _canScrollLeft = false;
          _canScrollRight = false;
        });
      }
      return;
    }
    final pos = _controller.position;
    final canLeft = pos.pixels > 4;
    final canRight = pos.pixels < pos.maxScrollExtent - 4;
    if (canLeft == _canScrollLeft && canRight == _canScrollRight) return;
    setState(() {
      _canScrollLeft = canLeft;
      _canScrollRight = canRight;
    });
  }

  void _scrollBy(double delta) {
    if (!_controller.hasClients) return;
    final pos = _controller.position;
    final target = (pos.pixels + delta).clamp(0.0, pos.maxScrollExtent);
    _controller.animateTo(
      target,
      duration: const Duration(milliseconds: 280),
      curve: Curves.easeOutCubic,
    );
  }

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: widget.height,
      child: Stack(
        children: [
          Positioned.fill(
            child: ListView.separated(
              controller: _controller,
              scrollDirection: Axis.horizontal,
              physics: const BouncingScrollPhysics(),
              itemCount: widget.itemCount,
              separatorBuilder: (_, __) =>
                  SizedBox(width: widget.separatorWidth),
              itemBuilder: widget.itemBuilder,
            ),
          ),
          if (_canScrollLeft)
            Positioned.fill(
              child: Align(
                alignment: Alignment.centerLeft,
                child: _CarouselArrowButton(
                  icon: Icons.chevron_left_rounded,
                  alignment: Alignment.centerLeft,
                  onTap: () => _scrollBy(-widget.scrollStep),
                ),
              ),
            ),
          if (_canScrollRight)
            Positioned.fill(
              child: Align(
                alignment: Alignment.centerRight,
                child: _CarouselArrowButton(
                  icon: Icons.chevron_right_rounded,
                  alignment: Alignment.centerRight,
                  onTap: () => _scrollBy(widget.scrollStep),
                ),
              ),
            ),
        ],
      ),
    );
  }
}

class _CarouselArrowButton extends StatelessWidget {
  const _CarouselArrowButton({
    required this.icon,
    required this.alignment,
    required this.onTap,
  });

  final IconData icon;
  final Alignment alignment;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final isLeft = alignment == Alignment.centerLeft;
    return Container(
      width: 56,
      alignment: alignment,
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: isLeft ? Alignment.centerLeft : Alignment.centerRight,
          end: isLeft ? Alignment.centerRight : Alignment.centerLeft,
          colors: [
            const Color(0xFF05070B).withValues(alpha: 0.70),
            const Color(0xFF05070B).withValues(alpha: 0.0),
          ],
        ),
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 6),
        child: Material(
          color: Colors.transparent,
          child: InkWell(
            onTap: onTap,
            borderRadius: BorderRadius.circular(18),
            child: Ink(
              width: 32,
              height: 32,
              decoration: BoxDecoration(
                color: Colors.black.withValues(alpha: 0.56),
                shape: BoxShape.circle,
                border: Border.all(
                  color: Colors.white.withValues(alpha: 0.28),
                ),
                boxShadow: [
                  BoxShadow(
                    color: const Color(0xAA020617).withValues(alpha: 0.55),
                    blurRadius: 8,
                    spreadRadius: 1,
                  ),
                ],
              ),
              child: Icon(icon, color: Colors.white, size: 20),
            ),
          ),
        ),
      ),
    );
  }
}

class _LibraryCard extends StatelessWidget {
  const _LibraryCard({
    required this.title,
    required this.subtitle,
    required this.icon,
    required this.imageUrl,
    required this.palette,
    required this.selected,
    this.onActiveChanged,
    required this.onTap,
  });

  final String title;
  final String subtitle;
  final IconData icon;
  final String? imageUrl;
  final List<Color> palette;
  final bool selected;
  final ValueChanged<bool>? onActiveChanged;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return _HoverScaleSurface(
      onTap: onTap,
      borderRadius: BorderRadius.circular(14),
      hoverScale: 1.03,
      pressedScale: 0.98,
      onActiveChanged: onActiveChanged,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 180),
        curve: Curves.easeOutCubic,
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(14),
          color: selected ? Colors.white.withValues(alpha: 0.02) : null,
          boxShadow: selected
              ? [
                  BoxShadow(
                    color: const Color(0xAA38BDF8).withValues(alpha: 0.35),
                    blurRadius: 24,
                    spreadRadius: 2,
                  ),
                ]
              : const [],
        ),
        child: ClipRRect(
          borderRadius: BorderRadius.circular(14),
          child: Stack(
            fit: StackFit.expand,
            children: [
              DecoratedBox(
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                    begin: Alignment.topLeft,
                    end: Alignment.bottomRight,
                    colors: palette,
                  ),
                ),
              ),
              _CoverImage(
                imageUrl: imageUrl,
                fit: BoxFit.cover,
                fallback: const SizedBox.shrink(),
              ),
              DecoratedBox(
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                    begin: Alignment.centerLeft,
                    end: Alignment.centerRight,
                    colors: [
                      Colors.black.withValues(alpha: 0.58),
                      Colors.black.withValues(alpha: 0.10),
                    ],
                  ),
                ),
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(12, 10, 12, 10),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Icon(icon, color: Colors.white, size: 26),
                    const Spacer(),
                    Text(
                      subtitle,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        color: Colors.white.withValues(alpha: 0.72),
                        fontSize: 11,
                        fontWeight: FontWeight.w500,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        color: Colors.white,
                        fontSize: 15,
                        fontWeight: FontWeight.w700,
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
  }
}

class _ContinueWatchingCard extends StatefulWidget {
  const _ContinueWatchingCard({
    required this.title,
    required this.subtitle,
    required this.imageUrl,
    this.fallbackImageUrls = const <String>[],
    required this.progress,
    required this.played,
    required this.favorite,
    required this.selected,
    this.onActiveChanged,
    required this.updatingPlayed,
    required this.onTap,
    required this.onTogglePlayed,
    required this.onToggleFavorite,
  });

  final String title;
  final String subtitle;
  final String? imageUrl;
  final List<String> fallbackImageUrls;
  final double progress;
  final bool played;
  final bool favorite;
  final bool selected;
  final ValueChanged<bool>? onActiveChanged;
  final bool updatingPlayed;
  final VoidCallback onTap;
  final VoidCallback onTogglePlayed;
  final VoidCallback onToggleFavorite;

  @override
  State<_ContinueWatchingCard> createState() => _ContinueWatchingCardState();
}

class _ContinueWatchingCardState extends State<_ContinueWatchingCard> {
  bool _hovered = false;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return _HoverScaleSurface(
      onTap: widget.onTap,
      borderRadius: BorderRadius.circular(12),
      hoverScale: 1.02,
      pressedScale: 0.985,
      onHoverChanged: (value) {
        setState(() => _hovered = value);
      },
      onActiveChanged: widget.onActiveChanged,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 180),
        curve: Curves.easeOutCubic,
        padding: const EdgeInsets.all(2),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(14),
          color: widget.selected ? Colors.white.withValues(alpha: 0.02) : null,
          boxShadow: widget.selected
              ? [
                  BoxShadow(
                    color: const Color(0xAA38BDF8).withValues(alpha: 0.35),
                    blurRadius: 22,
                    spreadRadius: 2,
                  ),
                ]
              : const [],
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            AspectRatio(
              aspectRatio: 16 / 9,
              child: ClipRRect(
                borderRadius: BorderRadius.circular(12),
                child: Stack(
                  fit: StackFit.expand,
                  children: [
                    _CoverImage(
                      imageUrl: widget.imageUrl,
                      fallbackImageUrls: widget.fallbackImageUrls,
                      fit: BoxFit.cover,
                    ),
                    DecoratedBox(
                      decoration: BoxDecoration(
                        gradient: LinearGradient(
                          begin: Alignment.topCenter,
                          end: Alignment.bottomCenter,
                          colors: [
                            Colors.black.withValues(alpha: 0.05),
                            Colors.black.withValues(alpha: 0.45),
                          ],
                        ),
                      ),
                    ),
                    Center(
                      child: AnimatedOpacity(
                        opacity: _hovered ? 1 : 0,
                        duration: const Duration(milliseconds: 180),
                        curve: Curves.easeOutCubic,
                        child: Container(
                          width: 56,
                          height: 56,
                          decoration: BoxDecoration(
                            color: Colors.black.withValues(alpha: 0.5),
                            shape: BoxShape.circle,
                            border: Border.all(
                              color: Colors.white.withValues(alpha: 0.55),
                            ),
                          ),
                          child: const Icon(
                            Icons.play_arrow_rounded,
                            color: Colors.white,
                            size: 32,
                          ),
                        ),
                      ),
                    ),
                    Positioned(
                      right: 8,
                      bottom: 14,
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          _OverlayCircleButton(
                            icon: widget.updatingPlayed
                                ? Icons.sync_rounded
                                : Icons.check_rounded,
                            active: widget.played,
                            activeColor: const Color(0xFFEF4444),
                            onTap: widget.updatingPlayed
                                ? null
                                : widget.onTogglePlayed,
                          ),
                          const SizedBox(width: 8),
                          _OverlayCircleButton(
                            icon: widget.favorite
                                ? Icons.favorite_rounded
                                : Icons.favorite_border_rounded,
                            active: widget.favorite,
                            activeColor: const Color(0xFFEF4444),
                            onTap: widget.onToggleFavorite,
                          ),
                        ],
                      ),
                    ),
                    Positioned(
                      left: 0,
                      right: 0,
                      bottom: 0,
                      child: SizedBox(
                        height: 4,
                        child: Stack(
                          children: [
                            Container(
                              color: Colors.white.withValues(alpha: 0.26),
                            ),
                            FractionallySizedBox(
                              alignment: Alignment.centerLeft,
                              widthFactor: widget.progress.clamp(0.0, 1.0),
                              child: Container(
                                color: const Color(0xFF10B981),
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 8),
            Text(
              widget.title,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                color: scheme.onSurface,
                fontSize: 14,
                fontWeight: FontWeight.w600,
              ),
            ),
            if (widget.subtitle.trim().isNotEmpty)
              Padding(
                padding: const EdgeInsets.only(top: 2),
                child: Text(
                  widget.subtitle,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    color: scheme.onSurfaceVariant,
                    fontSize: 12,
                    fontWeight: FontWeight.w500,
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

class _OverlayCircleButton extends StatelessWidget {
  const _OverlayCircleButton({
    required this.icon,
    required this.active,
    required this.activeColor,
    required this.onTap,
  });

  final IconData icon;
  final bool active;
  final Color activeColor;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final fg = active ? activeColor : Colors.white;
    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(16),
        child: Ink(
          width: 28,
          height: 28,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            color: Colors.black.withValues(alpha: 0.54),
            border: Border.all(
              color: Colors.white.withValues(alpha: 0.25),
            ),
          ),
          child: Icon(
            icon,
            color: fg,
            size: 16,
          ),
        ),
      ),
    );
  }
}

class _PosterCard extends StatelessWidget {
  const _PosterCard({
    required this.title,
    required this.meta,
    required this.imageUrl,
    required this.badgeText,
    required this.badgeColor,
    required this.favorite,
    required this.selected,
    this.onActiveChanged,
    required this.onTap,
    required this.onToggleFavorite,
  });

  final String title;
  final String meta;
  final String? imageUrl;
  final String? badgeText;
  final Color badgeColor;
  final bool favorite;
  final bool selected;
  final ValueChanged<bool>? onActiveChanged;
  final VoidCallback onTap;
  final VoidCallback onToggleFavorite;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return _HoverScaleSurface(
      onTap: onTap,
      borderRadius: BorderRadius.circular(12),
      hoverScale: 1.03,
      pressedScale: 0.98,
      onActiveChanged: onActiveChanged,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 180),
        curve: Curves.easeOutCubic,
        padding: const EdgeInsets.all(2),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(14),
          color: selected ? Colors.white.withValues(alpha: 0.02) : null,
          boxShadow: selected
              ? [
                  BoxShadow(
                    color: const Color(0xAA38BDF8).withValues(alpha: 0.35),
                    blurRadius: 22,
                    spreadRadius: 2,
                  ),
                ]
              : const [],
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            AspectRatio(
              aspectRatio: 2 / 3,
              child: ClipRRect(
                borderRadius: BorderRadius.circular(12),
                child: Stack(
                  fit: StackFit.expand,
                  children: [
                    _CoverImage(
                      imageUrl: imageUrl,
                      fit: BoxFit.cover,
                    ),
                    if (badgeText != null)
                      Positioned(
                        top: 8,
                        right: 8,
                        child: _PosterBadge(
                          text: badgeText!,
                          color: badgeColor,
                        ),
                      ),
                    Positioned(
                      right: 8,
                      bottom: 8,
                      child: Material(
                        color: Colors.transparent,
                        child: InkWell(
                          onTap: onToggleFavorite,
                          borderRadius: BorderRadius.circular(16),
                          child: Ink(
                            width: 28,
                            height: 28,
                            decoration: BoxDecoration(
                              color: Colors.black.withValues(alpha: 0.55),
                              shape: BoxShape.circle,
                              border: Border.all(
                                color: Colors.white.withValues(alpha: 0.25),
                              ),
                            ),
                            child: Icon(
                              favorite
                                  ? Icons.favorite_rounded
                                  : Icons.favorite_border_rounded,
                              color: favorite
                                  ? const Color(0xFFEF4444)
                                  : Colors.white,
                              size: 16,
                            ),
                          ),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 8),
            Text(
              title,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                color: scheme.onSurface,
                fontSize: 14,
                fontWeight: FontWeight.w600,
                height: 1.25,
              ),
            ),
            const SizedBox(height: 3),
            Text(
              meta,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                color: scheme.onSurfaceVariant,
                fontSize: 12,
                fontWeight: FontWeight.w500,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _PosterBadge extends StatelessWidget {
  const _PosterBadge({
    required this.text,
    required this.color,
  });

  final String text;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.9),
        borderRadius: BorderRadius.circular(10),
      ),
      child: Text(
        text,
        style: const TextStyle(
          color: Colors.white,
          fontSize: 11,
          fontWeight: FontWeight.w700,
        ),
      ),
    );
  }
}

class _HoverScaleSurface extends StatefulWidget {
  const _HoverScaleSurface({
    required this.child,
    required this.borderRadius,
    required this.onTap,
    this.hoverScale = 1.02,
    this.pressedScale = 0.985,
    this.onHoverChanged,
    this.onActiveChanged,
  });

  final Widget child;
  final BorderRadius borderRadius;
  final VoidCallback onTap;
  final double hoverScale;
  final double pressedScale;
  final ValueChanged<bool>? onHoverChanged;
  final ValueChanged<bool>? onActiveChanged;

  @override
  State<_HoverScaleSurface> createState() => _HoverScaleSurfaceState();
}

class _HoverScaleSurfaceState extends State<_HoverScaleSurface> {
  bool _hovered = false;
  bool _focused = false;
  bool _pressed = false;

  bool get _active => _hovered || _focused;

  void _emitActiveChanged() => widget.onActiveChanged?.call(_active);

  void _setHover(bool value) {
    if (_hovered == value) return;
    setState(() => _hovered = value);
    widget.onHoverChanged?.call(value);
    _emitActiveChanged();
  }

  void _setFocused(bool value) {
    if (_focused == value) return;
    setState(() => _focused = value);
    _emitActiveChanged();
  }

  @override
  Widget build(BuildContext context) {
    final scale = _pressed
        ? widget.pressedScale
        : (_active ? widget.hoverScale : 1.0);

    return Shortcuts(
      shortcuts: const <ShortcutActivator, Intent>{
        SingleActivator(LogicalKeyboardKey.arrowLeft):
            DirectionalFocusIntent(TraversalDirection.left),
        SingleActivator(LogicalKeyboardKey.arrowRight):
            DirectionalFocusIntent(TraversalDirection.right),
        SingleActivator(LogicalKeyboardKey.arrowUp):
            DirectionalFocusIntent(TraversalDirection.up),
        SingleActivator(LogicalKeyboardKey.arrowDown):
            DirectionalFocusIntent(TraversalDirection.down),
      },
      child: Actions(
        actions: <Type, Action<Intent>>{
          DirectionalFocusIntent: CallbackAction<DirectionalFocusIntent>(
            onInvoke: (intent) {
              FocusScope.of(context).focusedChild?.focusInDirection(
                intent.direction,
              );
              return null;
            },
          ),
        },
        child: Focus(
          canRequestFocus: true,
          onFocusChange: _setFocused,
          child: MouseRegion(
            onEnter: (_) => _setHover(true),
            onExit: (_) => _setHover(false),
            child: GestureDetector(
              onTapDown: (_) => setState(() => _pressed = true),
              onTapCancel: () => setState(() => _pressed = false),
              onTapUp: (_) => setState(() => _pressed = false),
              child: AnimatedScale(
                scale: scale,
                duration: const Duration(milliseconds: 180),
                curve: Curves.easeOutCubic,
                child: Material(
                  color: Colors.transparent,
                  child: InkWell(
                    borderRadius: widget.borderRadius,
                    onTap: widget.onTap,
                    child: widget.child,
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _CoverImage extends StatefulWidget {
  const _CoverImage({
    required this.imageUrl,
    required this.fit,
    this.fallbackImageUrls = const <String>[],
    this.fallback,
  });

  final String? imageUrl;
  final BoxFit fit;
  final List<String> fallbackImageUrls;
  final Widget? fallback;

  @override
  State<_CoverImage> createState() => _CoverImageState();
}

class _CoverImageState extends State<_CoverImage> {
  late List<String> _candidates;
  int _currentIndex = 0;

  @override
  void initState() {
    super.initState();
    _resetCandidates();
  }

  @override
  void didUpdateWidget(covariant _CoverImage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.imageUrl != widget.imageUrl ||
        !listEquals(oldWidget.fallbackImageUrls, widget.fallbackImageUrls)) {
      _resetCandidates();
    }
  }

  void _resetCandidates() {
    final merged = <String>{};
    final primary = (widget.imageUrl ?? '').trim();
    if (primary.isNotEmpty) merged.add(primary);
    for (final candidate in widget.fallbackImageUrls) {
      final value = candidate.trim();
      if (value.isNotEmpty) merged.add(value);
    }
    _candidates = merged.toList(growable: false);
    _currentIndex = 0;
  }

  void _switchToNextCandidate() {
    if (_currentIndex >= _candidates.length - 1) return;
    setState(() => _currentIndex += 1);
  }

  @override
  Widget build(BuildContext context) {
    final placeHolder = widget.fallback ??
        const ColoredBox(
          color: Color(0xFF1B1E24),
          child: Center(
            child: Icon(
              Icons.image_outlined,
              color: Colors.white30,
              size: 24,
            ),
          ),
        );
    if (_candidates.isEmpty) return placeHolder;
    final activeUrl = _candidates[_currentIndex];
    return CachedNetworkImage(
      imageUrl: activeUrl,
      fit: widget.fit,
      cacheManager: CoverCacheManager.instance,
      httpHeaders: {'User-Agent': LinHttpClientFactory.userAgent},
      placeholder: (_, __) => placeHolder,
      errorWidget: (_, __, ___) {
        if (_currentIndex < _candidates.length - 1) {
          WidgetsBinding.instance.addPostFrameCallback((_) {
            if (mounted) _switchToNextCandidate();
          });
        }
        return placeHolder;
      },
      fadeInDuration: const Duration(milliseconds: 220),
    );
  }
}
