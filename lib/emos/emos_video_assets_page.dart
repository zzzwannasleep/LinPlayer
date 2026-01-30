import 'dart:async';

import 'package:flutter/material.dart';

import '../app_config/app_config_scope.dart';
import '../services/emos_api.dart';
import '../state/app_state.dart';

class EmosMediaItem {
  const EmosMediaItem({
    required this.mediaId,
    required this.mediaName,
    required this.mediaStatus,
    required this.mediaFileSize,
    required this.mediaFileSecond,
    required this.userPseudonym,
    required this.subtitleCount,
    required this.isSelfUpload,
    required this.createdAt,
  });

  final String mediaId;
  final String mediaName;
  final String mediaStatus;
  final int mediaFileSize;
  final int? mediaFileSecond;
  final String userPseudonym;
  final int subtitleCount;
  final bool isSelfUpload;
  final DateTime? createdAt;

  factory EmosMediaItem.fromJson(Map<String, dynamic> json) {
    return EmosMediaItem(
      mediaId: (json['media_id'] as String? ?? '').trim(),
      mediaName: (json['media_name'] as String? ?? '').trim(),
      mediaStatus: (json['media_status'] as String? ?? '').trim(),
      mediaFileSize: (json['media_file_size'] as num?)?.toInt() ?? 0,
      mediaFileSecond: (json['media_file_second'] as num?)?.toInt(),
      userPseudonym: (json['user_pseudonym'] as String? ?? '').trim(),
      subtitleCount: (json['subtitle_count'] as num?)?.toInt() ?? 0,
      isSelfUpload: json['is_self_upload'] == true,
      createdAt: DateTime.tryParse((json['created_at'] as String? ?? '').trim()),
    );
  }
}

class EmosSubtitleItem {
  const EmosSubtitleItem({
    required this.subtitleId,
    required this.subtitleTitle,
    required this.subtitleCodec,
    required this.userPseudonym,
    required this.isSelfUpload,
    required this.createdAt,
  });

  final String subtitleId;
  final String subtitleTitle;
  final String subtitleCodec;
  final String userPseudonym;
  final bool isSelfUpload;
  final DateTime? createdAt;

  factory EmosSubtitleItem.fromJson(Map<String, dynamic> json) {
    return EmosSubtitleItem(
      subtitleId: (json['subtitle_id'] as String? ?? '').trim(),
      subtitleTitle: (json['subtitle_title'] as String? ?? '').trim(),
      subtitleCodec: (json['subtitle_codec'] as String? ?? '').trim(),
      userPseudonym: (json['user_pseudonym'] as String? ?? '').trim(),
      isSelfUpload: json['is_self_upload'] == true,
      createdAt: DateTime.tryParse((json['created_at'] as String? ?? '').trim()),
    );
  }
}

class EmosVideoAssetsPage extends StatefulWidget {
  const EmosVideoAssetsPage({
    super.key,
    required this.appState,
    required this.title,
    required this.videoListId,
    this.videoSeasonId,
    this.videoEpisodeId,
    this.videoPartId,
  });

  final AppState appState;
  final String title;
  final String videoListId;
  final String? videoSeasonId;
  final String? videoEpisodeId;
  final String? videoPartId;

  @override
  State<EmosVideoAssetsPage> createState() => _EmosVideoAssetsPageState();
}

class _EmosVideoAssetsPageState extends State<EmosVideoAssetsPage> {
  bool _loadingMedia = false;
  String? _mediaError;
  List<EmosMediaItem> _media = const [];

  bool _loadingSub = false;
  String? _subError;
  List<EmosSubtitleItem> _subs = const [];

  EmosApi _api() {
    final config = AppConfigScope.of(context);
    final token = widget.appState.emosSession?.token ?? '';
    return EmosApi(baseUrl: config.emosBaseUrl, token: token);
  }

  @override
  void initState() {
    super.initState();
    unawaited(_reloadAll());
  }

  Future<void> _reloadAll() async {
    await Future.wait<void>([_reloadMedia(), _reloadSubs()]);
  }

  Future<void> _reloadMedia() async {
    if (_loadingMedia) return;
    setState(() {
      _loadingMedia = true;
      _mediaError = null;
    });
    try {
      final raw = await _api().fetchMediaList(
        videoListId: widget.videoListId,
        videoSeasonId: widget.videoSeasonId,
        videoEpisodeId: widget.videoEpisodeId,
        videoPartId: widget.videoPartId,
      );
      final list = (raw as List<dynamic>? ?? const [])
          .whereType<Map>()
          .map((e) => EmosMediaItem.fromJson(e.cast<String, dynamic>()))
          .toList();
      if (!mounted) return;
      setState(() => _media = list);
    } catch (e) {
      if (!mounted) return;
      setState(() => _mediaError = e.toString());
    } finally {
      if (mounted) setState(() => _loadingMedia = false);
    }
  }

  Future<void> _reloadSubs() async {
    if (_loadingSub) return;
    setState(() {
      _loadingSub = true;
      _subError = null;
    });
    try {
      final raw = await _api().fetchSubtitleList(
        videoListId: widget.videoListId,
        videoEpisodeId: widget.videoEpisodeId,
        videoPartId: widget.videoPartId,
        videoMediaId: null,
      );
      final list = (raw as List<dynamic>? ?? const [])
          .whereType<Map>()
          .map((e) => EmosSubtitleItem.fromJson(e.cast<String, dynamic>()))
          .toList();
      if (!mounted) return;
      setState(() => _subs = list);
    } catch (e) {
      if (!mounted) return;
      setState(() => _subError = e.toString());
    } finally {
      if (mounted) setState(() => _loadingSub = false);
    }
  }

  Future<void> _renameMedia(EmosMediaItem item) async {
    final ctrl = TextEditingController(text: item.mediaName);
    try {
      final name = await showDialog<String>(
        context: context,
        builder: (dctx) => AlertDialog(
          title: const Text('Rename media'),
          content: TextField(
            controller: ctrl,
            decoration: const InputDecoration(labelText: 'Name'),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(dctx).pop(),
              child: const Text('Cancel'),
            ),
            FilledButton(
              onPressed: () => Navigator.of(dctx).pop(ctrl.text),
              child: const Text('Save'),
            ),
          ],
        ),
      );
      if ((name ?? '').trim().isEmpty) return;
      await _api().renameMedia(mediaId: item.mediaId, name: name!.trim());
      await _reloadMedia();
    } finally {
      ctrl.dispose();
    }
  }

  Future<void> _deleteMedia(EmosMediaItem item) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (dctx) => AlertDialog(
        title: const Text('Delete media?'),
        content: Text(item.mediaName),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dctx).pop(false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(dctx).pop(true),
            child: const Text('Delete'),
          ),
        ],
      ),
    );
    if (ok != true) return;
    await _api().deleteMedia(item.mediaId);
    await _reloadMedia();
  }

  Future<void> _renameSubtitle(EmosSubtitleItem item) async {
    final ctrl = TextEditingController(text: item.subtitleTitle);
    try {
      final title = await showDialog<String>(
        context: context,
        builder: (dctx) => AlertDialog(
          title: const Text('Rename subtitle'),
          content: TextField(
            controller: ctrl,
            decoration: const InputDecoration(labelText: 'Title'),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(dctx).pop(),
              child: const Text('Cancel'),
            ),
            FilledButton(
              onPressed: () => Navigator.of(dctx).pop(ctrl.text),
              child: const Text('Save'),
            ),
          ],
        ),
      );
      if ((title ?? '').trim().isEmpty) return;
      await _api().renameSubtitle(subtitleId: item.subtitleId, title: title!.trim());
      await _reloadSubs();
    } finally {
      ctrl.dispose();
    }
  }

  Future<void> _deleteSubtitle(EmosSubtitleItem item) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (dctx) => AlertDialog(
        title: const Text('Delete subtitle?'),
        content: Text(item.subtitleTitle),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dctx).pop(false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(dctx).pop(true),
            child: const Text('Delete'),
          ),
        ],
      ),
    );
    if (ok != true) return;
    await _api().deleteSubtitle(item.subtitleId);
    await _reloadSubs();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: widget.appState,
      builder: (context, _) {
        if (!widget.appState.hasEmosSession) {
          return const Scaffold(body: Center(child: Text('Not signed in')));
        }

        return DefaultTabController(
          length: 2,
          child: Scaffold(
            appBar: AppBar(
              title: Text(widget.title),
              actions: [
                IconButton(
                  tooltip: 'Refresh',
                  onPressed: _reloadAll,
                  icon: const Icon(Icons.refresh),
                ),
              ],
              bottom: const TabBar(
                tabs: [
                  Tab(text: 'Media'),
                  Tab(text: 'Subtitles'),
                ],
              ),
            ),
            body: TabBarView(
              children: [
                ListView(
                  padding: const EdgeInsets.fromLTRB(16, 12, 16, 24),
                  children: [
                    if (_loadingMedia) const LinearProgressIndicator(),
                    if (_mediaError != null)
                      Padding(
                        padding: const EdgeInsets.only(top: 8),
                        child: Text(
                          _mediaError!,
                          style: TextStyle(
                            color: Theme.of(context).colorScheme.error,
                          ),
                        ),
                      ),
                    if (!_loadingMedia && _mediaError == null && _media.isEmpty)
                      const Padding(
                        padding: EdgeInsets.all(24),
                        child: Center(child: Text('No media')),
                      ),
                    ..._media.map(
                      (m) => Card(
                        child: ListTile(
                          leading: const Icon(Icons.movie_outlined),
                          title: Text(m.mediaName.isEmpty ? m.mediaId : m.mediaName),
                          subtitle: Text(
                            [
                              if (m.mediaStatus.isNotEmpty) m.mediaStatus,
                              'Size: ${m.mediaFileSize} bytes · Subs: ${m.subtitleCount}',
                              if (m.userPseudonym.isNotEmpty) 'By: ${m.userPseudonym}',
                            ].join('\n'),
                          ),
                          trailing: PopupMenuButton<String>(
                            onSelected: (v) async {
                              if (v == 'rename') await _renameMedia(m);
                              if (v == 'delete') await _deleteMedia(m);
                            },
                            itemBuilder: (context) => const [
                              PopupMenuItem(
                                value: 'rename',
                                child: Text('Rename'),
                              ),
                              PopupMenuItem(
                                value: 'delete',
                                child: Text('Delete'),
                              ),
                            ],
                          ),
                        ),
                      ),
                    ),
                  ],
                ),
                ListView(
                  padding: const EdgeInsets.fromLTRB(16, 12, 16, 24),
                  children: [
                    if (_loadingSub) const LinearProgressIndicator(),
                    if (_subError != null)
                      Padding(
                        padding: const EdgeInsets.only(top: 8),
                        child: Text(
                          _subError!,
                          style: TextStyle(
                            color: Theme.of(context).colorScheme.error,
                          ),
                        ),
                      ),
                    if (!_loadingSub && _subError == null && _subs.isEmpty)
                      const Padding(
                        padding: EdgeInsets.all(24),
                        child: Center(child: Text('No subtitles')),
                      ),
                    ..._subs.map(
                      (s) => Card(
                        child: ListTile(
                          leading: const Icon(Icons.subtitles_outlined),
                          title:
                              Text(s.subtitleTitle.isEmpty ? s.subtitleId : s.subtitleTitle),
                          subtitle: Text(
                            [
                              if (s.subtitleCodec.isNotEmpty) s.subtitleCodec,
                              if (s.userPseudonym.isNotEmpty) 'By: ${s.userPseudonym}',
                            ].join('\n'),
                          ),
                          trailing: PopupMenuButton<String>(
                            onSelected: (v) async {
                              if (v == 'rename') await _renameSubtitle(s);
                              if (v == 'delete') await _deleteSubtitle(s);
                            },
                            itemBuilder: (context) => const [
                              PopupMenuItem(
                                value: 'rename',
                                child: Text('Rename'),
                              ),
                              PopupMenuItem(
                                value: 'delete',
                                child: Text('Delete'),
                              ),
                            ],
                          ),
                        ),
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
        );
      },
    );
  }
}

