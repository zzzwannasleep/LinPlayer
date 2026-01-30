import 'dart:async';

import 'package:flutter/material.dart';

import '../app_config/app_config_scope.dart';
import '../services/emos_api.dart';
import '../state/app_state.dart';
import 'emos_video_assets_page.dart';

class EmosVideoGenre {
  const EmosVideoGenre({required this.id, required this.name});

  final int id;
  final String name;

  factory EmosVideoGenre.fromJson(Map<String, dynamic> json) {
    return EmosVideoGenre(
      id: (json['id'] as num?)?.toInt() ?? 0,
      name: (json['name'] as String? ?? '').trim(),
    );
  }
}

class EmosVideoItem {
  const EmosVideoItem({
    required this.videoId,
    required this.videoType,
    required this.videoTitle,
    required this.videoOriginTitle,
    required this.videoDescription,
    required this.videoImagePoster,
    required this.videoDateAir,
    required this.tmdbId,
    required this.todbId,
    required this.mediasCount,
    required this.subtitlesCount,
    required this.partsCount,
    required this.requestCount,
    required this.genres,
    required this.isDelete,
  });

  final int videoId;
  final String videoType;
  final String videoTitle;
  final String videoOriginTitle;
  final String videoDescription;
  final String videoImagePoster;
  final String videoDateAir;
  final int? tmdbId;
  final int? todbId;
  final int mediasCount;
  final int subtitlesCount;
  final int partsCount;
  final int requestCount;
  final List<EmosVideoGenre> genres;
  final bool isDelete;

  factory EmosVideoItem.fromJson(Map<String, dynamic> json) {
    return EmosVideoItem(
      videoId: (json['video_id'] as num?)?.toInt() ?? 0,
      videoType: (json['video_type'] as String? ?? '').trim(),
      videoTitle: (json['video_title'] as String? ?? '').trim(),
      videoOriginTitle: (json['video_origin_title'] as String? ?? '').trim(),
      videoDescription: (json['video_description'] as String? ?? '').trim(),
      videoImagePoster: (json['video_image_poster'] as String? ?? '').trim(),
      videoDateAir: (json['video_date_air'] as String? ?? '').trim(),
      tmdbId: (json['tmdb_id'] as num?)?.toInt(),
      todbId: (json['todb_id'] as num?)?.toInt(),
      mediasCount: (json['medias_count'] as num?)?.toInt() ?? 0,
      subtitlesCount: (json['subtitles_count'] as num?)?.toInt() ?? 0,
      partsCount: (json['parts_count'] as num?)?.toInt() ?? 0,
      requestCount: (json['request_count'] as num?)?.toInt() ?? 0,
      genres: (json['genres'] as List<dynamic>? ?? const [])
          .whereType<Map>()
          .map((e) => EmosVideoGenre.fromJson(e.cast<String, dynamic>()))
          .toList(),
      isDelete: json['is_delete'] == true,
    );
  }
}

class EmosVideoTreeEpisode {
  const EmosVideoTreeEpisode({
    required this.itemType,
    required this.itemId,
    required this.episodeTitle,
    required this.episodeNumber,
    required this.dateAir,
  });

  final String itemType;
  final int itemId;
  final String episodeTitle;
  final int episodeNumber;
  final String dateAir;

  factory EmosVideoTreeEpisode.fromJson(Map<String, dynamic> json) {
    return EmosVideoTreeEpisode(
      itemType: (json['item_type'] as String? ?? '').trim(),
      itemId: (json['item_id'] as num?)?.toInt() ?? 0,
      episodeTitle: (json['episode_title'] as String? ?? '').trim(),
      episodeNumber: (json['episode_number'] as num?)?.toInt() ?? 0,
      dateAir: (json['date_air'] as String? ?? '').trim(),
    );
  }
}

class EmosVideoTreeSeason {
  const EmosVideoTreeSeason({
    required this.itemType,
    required this.itemId,
    required this.seasonTitle,
    required this.seasonNumber,
    required this.dateAir,
    required this.episodes,
  });

  final String itemType;
  final int itemId;
  final String seasonTitle;
  final int seasonNumber;
  final String dateAir;
  final List<EmosVideoTreeEpisode> episodes;

  factory EmosVideoTreeSeason.fromJson(Map<String, dynamic> json) {
    return EmosVideoTreeSeason(
      itemType: (json['item_type'] as String? ?? '').trim(),
      itemId: (json['item_id'] as num?)?.toInt() ?? 0,
      seasonTitle: (json['season_title'] as String? ?? '').trim(),
      seasonNumber: (json['season_number'] as num?)?.toInt() ?? 0,
      dateAir: (json['date_air'] as String? ?? '').trim(),
      episodes: (json['episodes'] as List<dynamic>? ?? const [])
          .whereType<Map>()
          .map((e) => EmosVideoTreeEpisode.fromJson(e.cast<String, dynamic>()))
          .toList(),
    );
  }
}

class EmosVideoTreeRoot {
  const EmosVideoTreeRoot({
    required this.videoType,
    required this.itemType,
    required this.itemId,
    required this.tmdbId,
    required this.todbId,
    required this.title,
    required this.dateAir,
    required this.seasons,
  });

  final String videoType;
  final String itemType;
  final int itemId;
  final int? tmdbId;
  final int? todbId;
  final String title;
  final String dateAir;
  final List<EmosVideoTreeSeason> seasons;

  factory EmosVideoTreeRoot.fromJson(Map<String, dynamic> json) {
    return EmosVideoTreeRoot(
      videoType: (json['video_type'] as String? ?? '').trim(),
      itemType: (json['item_type'] as String? ?? '').trim(),
      itemId: (json['item_id'] as num?)?.toInt() ?? 0,
      tmdbId: (json['tmdb_id'] as num?)?.toInt(),
      todbId: (json['todb_id'] as num?)?.toInt(),
      title: (json['title'] as String? ?? '').trim(),
      dateAir: (json['date_air'] as String? ?? '').trim(),
      seasons: (json['seasons'] as List<dynamic>? ?? const [])
          .whereType<Map>()
          .map((e) => EmosVideoTreeSeason.fromJson(e.cast<String, dynamic>()))
          .toList(),
    );
  }
}

class EmosVideoManagerPage extends StatefulWidget {
  const EmosVideoManagerPage({super.key, required this.appState});

  final AppState appState;

  @override
  State<EmosVideoManagerPage> createState() => _EmosVideoManagerPageState();
}

class _EmosVideoManagerPageState extends State<EmosVideoManagerPage> {
  bool _loading = false;
  String? _error;
  List<EmosVideoItem> _items = const [];
  int _page = 1;
  int _total = 0;

  String _titleQuery = '';
  String _type = '';
  bool _onlyDeleted = false;
  String _withMedia = '';

  EmosApi _api() {
    final config = AppConfigScope.of(context);
    final token = widget.appState.emosSession?.token ?? '';
    return EmosApi(baseUrl: config.emosBaseUrl, token: token);
  }

  @override
  void initState() {
    super.initState();
    unawaited(_reload(resetPage: true));
  }

  Future<void> _reload({required bool resetPage}) async {
    if (_loading) return;
    setState(() {
      _loading = true;
      _error = null;
      if (resetPage) _page = 1;
    });
    try {
      final raw = await _api().fetchVideoList(
        title: _titleQuery.trim().isEmpty ? null : _titleQuery.trim(),
        type: _type.trim().isEmpty ? null : _type.trim(),
        onlyDelete: _onlyDeleted ? '1' : null,
        withMedia: _withMedia.trim().isEmpty ? null : _withMedia.trim(),
        page: _page,
        pageSize: 15,
      );
      final map = raw as Map<String, dynamic>;
      final items = (map['items'] as List<dynamic>? ?? const [])
          .whereType<Map>()
          .map((e) => EmosVideoItem.fromJson(e.cast<String, dynamic>()))
          .toList();
      if (!mounted) return;
      setState(() {
        _items = items;
        _total = (map['total'] as num?)?.toInt() ?? items.length;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() => _error = e.toString());
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _toggleDelete(EmosVideoItem item) async {
    await _api().toggleVideoDelete('${item.videoId}');
    await _reload(resetPage: false);
  }

  Future<void> _openDetail(EmosVideoItem item) async {
    await Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => EmosVideoDetailPage(
          appState: widget.appState,
          video: item,
        ),
      ),
    );
    await _reload(resetPage: false);
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: widget.appState,
      builder: (context, _) {
        if (!widget.appState.hasEmosSession) {
          return const Scaffold(body: Center(child: Text('Not signed in')));
        }

        return Scaffold(
          appBar: AppBar(
            title: const Text('Video Manager'),
            actions: [
              IconButton(
                tooltip: 'Refresh',
                onPressed: _loading ? null : () => _reload(resetPage: false),
                icon: const Icon(Icons.refresh),
              ),
            ],
          ),
          body: ListView(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 24),
            children: [
              TextField(
                decoration: const InputDecoration(
                  labelText: 'Title',
                  prefixIcon: Icon(Icons.search),
                ),
                onChanged: (v) => setState(() => _titleQuery = v),
                onSubmitted: (_) => _reload(resetPage: true),
              ),
              const SizedBox(height: 12),
              Wrap(
                spacing: 10,
                runSpacing: 10,
                crossAxisAlignment: WrapCrossAlignment.center,
                children: [
                  DropdownMenu<String>(
                    width: 160,
                    initialSelection: _type,
                    label: const Text('Type'),
                    dropdownMenuEntries: const [
                      DropdownMenuEntry(value: '', label: 'All'),
                      DropdownMenuEntry(value: 'tv', label: 'TV'),
                      DropdownMenuEntry(value: 'movie', label: 'Movie'),
                    ],
                    onSelected: (v) => setState(() => _type = v ?? ''),
                  ),
                  DropdownMenu<String>(
                    width: 180,
                    initialSelection: _withMedia,
                    label: const Text('With media'),
                    dropdownMenuEntries: const [
                      DropdownMenuEntry(value: '', label: 'All'),
                      DropdownMenuEntry(value: 'true', label: 'Only with media'),
                      DropdownMenuEntry(value: 'false', label: 'Only without media'),
                    ],
                    onSelected: (v) => setState(() => _withMedia = v ?? ''),
                  ),
                  FilterChip(
                    label: const Text('Only deleted'),
                    selected: _onlyDeleted,
                    onSelected: (v) => setState(() => _onlyDeleted = v),
                  ),
                  FilledButton.icon(
                    onPressed: _loading ? null : () => _reload(resetPage: true),
                    icon: const Icon(Icons.search),
                    label: const Text('Apply'),
                  ),
                ],
              ),
              const SizedBox(height: 12),
              if (_loading) const LinearProgressIndicator(),
              if (_error != null)
                Padding(
                  padding: const EdgeInsets.only(top: 8),
                  child: Text(
                    _error!,
                    style: TextStyle(color: Theme.of(context).colorScheme.error),
                  ),
                ),
              if (!_loading && _error == null && _items.isEmpty)
                const Padding(
                  padding: EdgeInsets.all(24),
                  child: Center(child: Text('No videos')),
                ),
              if (_total > 0)
                Padding(
                  padding: const EdgeInsets.only(bottom: 8),
                  child: Text('Total: $_total'),
                ),
              ..._items.map(
                (v) => Card(
                  child: ListTile(
                    leading: v.videoImagePoster.isNotEmpty
                        ? ClipRRect(
                            borderRadius: BorderRadius.circular(6),
                            child: Image.network(
                              v.videoImagePoster,
                              width: 44,
                              height: 44,
                              fit: BoxFit.cover,
                            ),
                          )
                        : const Icon(Icons.movie_outlined),
                    title: Text(v.videoTitle.isEmpty ? '(no title)' : v.videoTitle),
                    subtitle: Text(
                      [
                        if (v.videoOriginTitle.isNotEmpty) v.videoOriginTitle,
                        '${v.videoType} · ${v.videoDateAir}',
                        'Media: ${v.mediasCount} · Subs: ${v.subtitlesCount} · Requests: ${v.requestCount}',
                      ].join('\n'),
                    ),
                    trailing: IconButton(
                      tooltip: v.isDelete ? 'Restore' : 'Delete',
                      icon: Icon(
                        v.isDelete
                            ? Icons.restore_from_trash_outlined
                            : Icons.delete_outline,
                      ),
                      onPressed: _loading ? null : () => _toggleDelete(v),
                    ),
                    onTap: () => _openDetail(v),
                  ),
                ),
              ),
            ],
          ),
        );
      },
    );
  }
}

class EmosVideoDetailPage extends StatefulWidget {
  const EmosVideoDetailPage({super.key, required this.appState, required this.video});

  final AppState appState;
  final EmosVideoItem video;

  @override
  State<EmosVideoDetailPage> createState() => _EmosVideoDetailPageState();
}

class _EmosVideoDetailPageState extends State<EmosVideoDetailPage> {
  bool _loading = false;
  String? _error;
  EmosVideoTreeRoot? _tree;

  EmosApi _api() {
    final config = AppConfigScope.of(context);
    final token = widget.appState.emosSession?.token ?? '';
    return EmosApi(baseUrl: config.emosBaseUrl, token: token);
  }

  @override
  void initState() {
    super.initState();
    unawaited(_reload());
  }

  Future<void> _reload() async {
    if (_loading) return;
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final raw = await _api().fetchVideoTree(videoId: '${widget.video.videoId}');
      final list = (raw as List<dynamic>? ?? const [])
          .whereType<Map>()
          .map((e) => EmosVideoTreeRoot.fromJson(e.cast<String, dynamic>()))
          .toList();
      if (!mounted) return;
      setState(() => _tree = list.isNotEmpty ? list.first : null);
    } catch (e) {
      if (!mounted) return;
      setState(() => _error = e.toString());
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _sync() async {
    await _api().syncVideos(
      tmdbId: widget.video.tmdbId?.toString(),
      todbId: widget.video.todbId?.toString(),
    );
    await _reload();
  }

  Future<void> _toggleDelete() async {
    await _api().toggleVideoDelete('${widget.video.videoId}');
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('Updated')),
    );
  }

  Future<void> _openAssets({
    required String title,
    required String videoListId,
    String? videoSeasonId,
    String? videoEpisodeId,
  }) async {
    await Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => EmosVideoAssetsPage(
          appState: widget.appState,
          title: title,
          videoListId: videoListId,
          videoSeasonId: videoSeasonId,
          videoEpisodeId: videoEpisodeId,
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: widget.appState,
      builder: (context, _) {
        if (!widget.appState.hasEmosSession) {
          return const Scaffold(body: Center(child: Text('Not signed in')));
        }

        final tree = _tree;
        final videoListId = tree?.itemId.toString();

        return Scaffold(
          appBar: AppBar(
            title: Text(widget.video.videoTitle.isEmpty ? 'Video' : widget.video.videoTitle),
            actions: [
              IconButton(
                tooltip: 'Refresh',
                onPressed: _loading ? null : _reload,
                icon: const Icon(Icons.refresh),
              ),
              IconButton(
                tooltip: 'Sync',
                onPressed: _loading ? null : _sync,
                icon: const Icon(Icons.sync),
              ),
              IconButton(
                tooltip: widget.video.isDelete ? 'Restore' : 'Delete',
                onPressed: _loading ? null : _toggleDelete,
                icon: Icon(
                  widget.video.isDelete
                      ? Icons.restore_from_trash_outlined
                      : Icons.delete_outline,
                ),
              ),
            ],
          ),
          body: ListView(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 24),
            children: [
              if (_loading) const LinearProgressIndicator(),
              if (_error != null)
                Padding(
                  padding: const EdgeInsets.only(top: 8),
                  child: Text(
                    _error!,
                    style: TextStyle(color: Theme.of(context).colorScheme.error),
                  ),
                ),
              Card(
                child: ListTile(
                  leading: widget.video.videoImagePoster.isNotEmpty
                      ? ClipRRect(
                          borderRadius: BorderRadius.circular(8),
                          child: Image.network(
                            widget.video.videoImagePoster,
                            width: 56,
                            height: 56,
                            fit: BoxFit.cover,
                          ),
                        )
                      : const Icon(Icons.movie_outlined),
                  title: Text(widget.video.videoTitle),
                  subtitle: Text(
                    [
                      if (widget.video.videoOriginTitle.isNotEmpty)
                        widget.video.videoOriginTitle,
                      '${widget.video.videoType} · ${widget.video.videoDateAir}',
                    ].join('\n'),
                  ),
                  trailing: (videoListId == null)
                      ? null
                      : TextButton(
                          onPressed: () => _openAssets(
                            title: 'Video assets',
                            videoListId: videoListId,
                          ),
                          child: const Text('Assets'),
                        ),
                ),
              ),
              const SizedBox(height: 12),
              if (tree == null)
                const Padding(
                  padding: EdgeInsets.all(24),
                  child: Center(child: Text('No tree data')),
                )
              else if (tree.seasons.isEmpty)
                Card(
                  child: ListTile(
                    leading: const Icon(Icons.folder_outlined),
                    title: const Text('No seasons'),
                    subtitle: const Text('This might be a movie'),
                    onTap: (videoListId == null)
                        ? null
                        : () => _openAssets(
                              title: 'Video assets',
                              videoListId: videoListId,
                            ),
                  ),
                )
              else
                ...tree.seasons.map(
                  (s) => Card(
                    child: ExpansionTile(
                      leading: const Icon(Icons.folder_outlined),
                      title: Text(
                        s.seasonTitle.isNotEmpty
                            ? s.seasonTitle
                            : 'Season ${s.seasonNumber}',
                      ),
                      subtitle: Text('Episodes: ${s.episodes.length}'),
                      children: [
                        for (final e in s.episodes)
                          ListTile(
                            leading: const Icon(Icons.play_circle_outline),
                            title: Text(
                              e.episodeTitle.isNotEmpty
                                  ? e.episodeTitle
                                  : 'E${e.episodeNumber}',
                            ),
                            subtitle: Text('E${e.episodeNumber} · ${e.dateAir}'),
                            trailing: const Icon(Icons.chevron_right),
                            onTap: (videoListId == null)
                                ? null
                                : () => _openAssets(
                                      title: e.episodeTitle.isNotEmpty
                                          ? e.episodeTitle
                                          : 'Episode ${e.episodeNumber}',
                                      videoListId: videoListId,
                                      videoSeasonId: s.itemId.toString(),
                                      videoEpisodeId: e.itemId.toString(),
                                    ),
                          ),
                      ],
                    ),
                  ),
                ),
            ],
          ),
        );
      },
    );
  }
}

