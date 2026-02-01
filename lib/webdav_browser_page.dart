import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:lin_player_prefs/lin_player_prefs.dart';
import 'package:lin_player_state/lin_player_state.dart';
import 'package:lin_player_ui/lin_player_ui.dart';

import 'player_screen.dart';
import 'player_screen_exo.dart';
import 'package:lin_player_server_api/services/webdav_api.dart';
import 'package:lin_player_server_api/services/webdav_proxy.dart';

class WebDavBrowserPage extends StatefulWidget {
  const WebDavBrowserPage({
    super.key,
    required this.appState,
    required this.server,
    this.dirUri,
  });

  final AppState appState;
  final ServerProfile server;
  final Uri? dirUri;

  @override
  State<WebDavBrowserPage> createState() => _WebDavBrowserPageState();
}

class _WebDavBrowserPageState extends State<WebDavBrowserPage> {
  late final Uri _baseUri = WebDavApi.normalizeBaseUri(widget.server.baseUrl);
  late final WebDavApi _api = WebDavApi(
    baseUri: _baseUri,
    username: widget.server.username,
    password: widget.server.token,
  );

  late final Uri _dirUri = widget.dirUri ?? _baseUri;

  bool _loading = true;
  String? _error;
  List<WebDavEntry> _entries = const [];

  bool _isTv(BuildContext context) => DeviceType.isTv;

  String _title() {
    final root = _baseUri.path;
    final current = _dirUri.path;
    if (current == root || current == '$root/') {
      final name = widget.server.name.trim();
      return name.isEmpty ? 'WebDAV' : name;
    }
    final segs = _dirUri.pathSegments;
    if (segs.isNotEmpty) return segs.last;
    return 'WebDAV';
  }

  @override
  void initState() {
    super.initState();
    unawaited(_load());
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final list = await _api.listDirectory(_dirUri);
      if (!mounted) return;
      setState(() {
        _entries = list;
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = e.toString();
      });
    }
  }

  String _fmtSize(int? bytes) {
    final b = bytes ?? 0;
    if (b <= 0) return '';
    const kb = 1024;
    const mb = 1024 * 1024;
    const gb = 1024 * 1024 * 1024;
    if (b >= gb) return '${(b / gb).toStringAsFixed(2)} GB';
    if (b >= mb) return '${(b / mb).toStringAsFixed(2)} MB';
    if (b >= kb) return '${(b / kb).toStringAsFixed(1)} KB';
    return '$b B';
  }

  bool _isProbablyPlayable(WebDavEntry entry) {
    final type = (entry.contentType ?? '').trim().toLowerCase();
    if (type.startsWith('video/') || type.startsWith('audio/')) return true;

    final name = entry.name.toLowerCase();
    final dot = name.lastIndexOf('.');
    if (dot < 0 || dot >= name.length - 1) return false;
    final ext = name.substring(dot + 1);

    const video = <String>{
      'mp4',
      'mkv',
      'avi',
      'mov',
      'flv',
      'ts',
      'm2ts',
      'webm',
      'wmv',
      'mpg',
      'mpeg',
      'm4v',
      '3gp',
      'rm',
      'rmvb',
    };
    const audio = <String>{
      'mp3',
      'flac',
      'aac',
      'm4a',
      'wav',
      'ogg',
      'opus',
    };

    return video.contains(ext) || audio.contains(ext);
  }

  Future<void> _openEntry(WebDavEntry entry) async {
    if (entry.isDirectory) {
      await Navigator.of(context).push(
        MaterialPageRoute(
          builder: (_) => WebDavBrowserPage(
            appState: widget.appState,
            server: widget.server,
            dirUri: entry.uri,
          ),
        ),
      );
      return;
    }

    final dirFiles = _entries.where((e) => !e.isDirectory).toList();
    final mediaFiles = dirFiles.where(_isProbablyPlayable).toList();
    final playlistFiles = (mediaFiles.isNotEmpty ? mediaFiles : dirFiles);

    var index = playlistFiles.indexWhere((e) => e.uri == entry.uri);
    if (index < 0) {
      playlistFiles.add(entry);
      index = playlistFiles.length - 1;
    }

    final items = <LocalPlaybackItem>[];
    for (final f in playlistFiles) {
      final local = await WebDavProxyServer.instance.registerFile(
        remoteUri: f.uri,
        username: widget.server.username,
        password: widget.server.token,
        fileName: f.name,
      );
      items.add(
        LocalPlaybackItem(
          name: f.name,
          path: local.toString(),
          size: f.contentLength ?? 0,
        ),
      );
    }

    widget.appState.setLocalPlaybackHandoff(
      LocalPlaybackHandoff(
        playlist: items,
        index: index,
        position: Duration.zero,
        wasPlaying: true,
      ),
    );

    if (!mounted) return;

    final useExoCore = !kIsWeb &&
        defaultTargetPlatform == TargetPlatform.android &&
        widget.appState.playerCore == PlayerCore.exo;

    await Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => useExoCore
            ? ExoPlayerScreen(appState: widget.appState, startFullScreen: true)
            : PlayerScreen(appState: widget.appState, startFullScreen: true),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final isTv = _isTv(context);
    final enableBlur = !isTv && widget.appState.enableBlurEffects;

    return Scaffold(
      appBar: GlassAppBar(
        enableBlur: enableBlur,
        child: AppBar(
          title: Text(_title()),
          actions: [
            IconButton(
              tooltip: '切换服务器',
              onPressed: () => widget.appState.leaveServer(),
              icon: const Icon(Icons.logout),
            ),
            IconButton(
              tooltip: '刷新',
              onPressed: _loading ? null : _load,
              icon: const Icon(Icons.refresh),
            ),
          ],
        ),
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : (_error != null)
              ? Center(child: Text(_error!, textAlign: TextAlign.center))
              : RefreshIndicator(
                  onRefresh: _load,
                  child: ListView.separated(
                    padding: const EdgeInsets.all(12),
                    itemCount: _entries.length,
                    separatorBuilder: (_, __) => const SizedBox(height: 6),
                    itemBuilder: (context, index) {
                      final e = _entries[index];
                      final subtitle = e.isDirectory
                          ? '文件夹'
                          : [
                              _fmtSize(e.contentLength),
                              if (e.lastModified != null)
                                e.lastModified!.toString().split('.').first,
                            ].where((s) => s.trim().isNotEmpty).join(' · ');
                      return Card(
                        clipBehavior: Clip.antiAlias,
                        child: ListTile(
                          leading:
                              Icon(e.isDirectory ? Icons.folder : Icons.movie),
                          title: Text(e.name),
                          subtitle: subtitle.isEmpty ? null : Text(subtitle),
                          trailing: const Icon(Icons.chevron_right),
                          onTap: () => _openEntry(e),
                        ),
                      );
                    },
                  ),
                ),
    );
  }
}
