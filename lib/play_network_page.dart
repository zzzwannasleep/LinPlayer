import 'dart:async';

import 'package:flutter/material.dart';
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';

import 'player_service.dart';
import 'services/emby_api.dart';
import 'state/app_state.dart';

class PlayNetworkPage extends StatefulWidget {
  const PlayNetworkPage({
    super.key,
    required this.title,
    required this.itemId,
    required this.appState,
    this.isTv = false,
    this.mediaSourceId,
    this.audioStreamIndex,
    this.subtitleStreamIndex,
  });

  final String title;
  final String itemId;
  final AppState appState;
  final bool isTv;
  final String? mediaSourceId;
  final int? audioStreamIndex; // Emby MediaStream Index
  final int? subtitleStreamIndex; // Emby MediaStream Index, -1 = off

  @override
  State<PlayNetworkPage> createState() => _PlayNetworkPageState();
}

class _PlayNetworkPageState extends State<PlayNetworkPage> {
  final PlayerService _playerService = getPlayerService();
  bool _loading = true;
  String? _playError;
  bool _hwdecOn = true;
  Tracks _tracks = const Tracks();
  StreamSubscription<String>? _errorSub;
  String? _resolvedStream;
  StreamSubscription<bool>? _bufferingSub;
  StreamSubscription<double>? _bufferingPctSub;
  bool _buffering = false;
  double? _bufferingPct;
  bool _appliedAudioPref = false;
  bool _appliedSubtitlePref = false;

  @override
  void initState() {
    super.initState();
    _init();
  }

  Future<void> _init() async {
    await _errorSub?.cancel();
    _errorSub = null;
    await _bufferingSub?.cancel();
    _bufferingSub = null;
    await _bufferingPctSub?.cancel();
    _bufferingPctSub = null;
    _appliedAudioPref = false;
    _appliedSubtitlePref = false;
    try {
      final streamUrl = await _buildStreamUrl();
      _resolvedStream = streamUrl;
      await _playerService.initialize(
        null,
        networkUrl: streamUrl,
        httpHeaders: {
          'X-Emby-Token': widget.appState.token!,
          'X-Emby-Authorization':
              'MediaBrowser Client="LinPlayer", Device="Flutter", DeviceId="${widget.appState.deviceId}", Version="1.0.0"',
        },
        isTv: widget.isTv,
        hardwareDecode: _hwdecOn,
      );
      _tracks = _playerService.player.state.tracks;
      _maybeApplyInitialTracks(_tracks);
      _playerService.player.stream.tracks.listen((t) {
        if (!mounted) return;
        _maybeApplyInitialTracks(t);
        setState(() => _tracks = t);
      });
      _bufferingSub = _playerService.player.stream.buffering.listen((value) {
        if (!mounted) return;
        setState(() => _buffering = value);
      });
      _bufferingPctSub =
          _playerService.player.stream.bufferingPercentage.listen((value) {
        if (!mounted) return;
        setState(() => _bufferingPct = value);
      });
      _errorSub?.cancel();
      _errorSub = _playerService.player.stream.error.listen((message) {
        if (!mounted) return;
        setState(() => _playError = message);
      });
    } catch (e) {
      _playError = e.toString();
    } finally {
      if (mounted) {
        setState(() => _loading = false);
      }
    }
  }

  void _maybeApplyInitialTracks(Tracks tracks) {
    final player = _playerService.isInitialized ? _playerService.player : null;
    if (player == null) return;

    if (!_appliedAudioPref && widget.audioStreamIndex != null) {
      final target = widget.audioStreamIndex!.toString();
      for (final a in tracks.audio) {
        if (a.id == target) {
          player.setAudioTrack(a);
          break;
        }
      }
      _appliedAudioPref = true;
    }

    if (!_appliedSubtitlePref && widget.subtitleStreamIndex != null) {
      if (widget.subtitleStreamIndex == -1) {
        player.setSubtitleTrack(SubtitleTrack.no());
      } else {
        final target = widget.subtitleStreamIndex!.toString();
        for (final s in tracks.subtitle) {
          if (s.id == target) {
            player.setSubtitleTrack(s);
            break;
          }
        }
      }
      _appliedSubtitlePref = true;
    }
  }

  Future<String> _buildStreamUrl() async {
    final base = widget.appState.baseUrl!;
    final token = widget.appState.token!;
    final userId = widget.appState.userId!;
    String applyQueryPrefs(String url) {
      final uri = Uri.parse(url);
      final params = Map<String, String>.from(uri.queryParameters);
      if (!params.containsKey('api_key')) params['api_key'] = token;
      if (widget.audioStreamIndex != null) {
        params['AudioStreamIndex'] = widget.audioStreamIndex.toString();
      }
      if (widget.subtitleStreamIndex != null && widget.subtitleStreamIndex! >= 0) {
        params['SubtitleStreamIndex'] = widget.subtitleStreamIndex.toString();
      }
      return uri.replace(queryParameters: params).toString();
    }

    String resolve(String candidate) {
      final resolved = Uri.parse(base).resolve(candidate).toString();
      return applyQueryPrefs(resolved);
    }
    try {
      final api = EmbyApi(hostOrUrl: widget.appState.baseUrl!, preferredScheme: 'https');
      final info = await api.fetchPlaybackInfo(
        token: token,
        baseUrl: base,
        userId: userId,
        deviceId: widget.appState.deviceId,
        itemId: widget.itemId,
      );
      final sources = info.mediaSources.cast<Map<String, dynamic>>();
      Map<String, dynamic>? ms;
      if (sources.isNotEmpty) {
        final selectedId = widget.mediaSourceId;
        if (selectedId != null && selectedId.isNotEmpty) {
          ms = sources.firstWhere(
            (s) => (s['Id'] as String? ?? '') == selectedId,
            orElse: () => sources.first,
          );
        } else {
          ms = sources.first;
        }
      }
      final directStreamUrl = ms?['DirectStreamUrl'] as String?;
      if (directStreamUrl != null && directStreamUrl.isNotEmpty) {
        return resolve(directStreamUrl);
      }
      // Prefer direct stream (no transcoding). Even if server reports unsupported direct play/stream,
      // the static stream endpoint may still work with mpv's broader codec/container support.
      final mediaSourceId = (ms?['Id'] as String?) ?? info.mediaSourceId;
      return applyQueryPrefs(
        '$base/emby/Videos/${widget.itemId}/stream?static=true&MediaSourceId=$mediaSourceId'
            '&PlaySessionId=${info.playSessionId}&UserId=$userId&DeviceId=${widget.appState.deviceId}'
            '&api_key=$token',
      );
    } catch (_) {
      return applyQueryPrefs(
        '$base/emby/Videos/${widget.itemId}/stream?static=true&UserId=$userId'
            '&DeviceId=${widget.appState.deviceId}&api_key=$token',
      );
      // 回退：无需 playbackInfo 的直链（部分服务器禁用该接口）
    }
  }

  @override
  void dispose() {
    _errorSub?.cancel();
    _bufferingSub?.cancel();
    _bufferingPctSub?.cancel();
    _playerService.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final initialized = _playerService.isInitialized;
    return Scaffold(
      appBar: AppBar(
        title: Text(widget.title),
        actions: [
          if (_resolvedStream != null)
            IconButton(
              tooltip: '复制链接',
              icon: const Icon(Icons.link),
              onPressed: () {
                ScaffoldMessenger.of(context)
                    .showSnackBar(const SnackBar(content: Text('已生成播放链接')));
              },
            ),
          IconButton(
            tooltip: '音轨',
            icon: const Icon(Icons.audiotrack),
            onPressed: () => _showAudioTracks(context),
          ),
          IconButton(
            tooltip: '字幕',
            icon: const Icon(Icons.subtitles),
            onPressed: () => _showSubtitleTracks(context),
          ),
          IconButton(
            tooltip: _hwdecOn ? '切换软解' : '切换硬解',
            icon: Icon(_hwdecOn ? Icons.memory : Icons.settings_backup_restore),
            onPressed: () async {
              setState(() {
                _hwdecOn = !_hwdecOn;
                _loading = true;
                _playError = null;
              });
              try {
                await _playerService.dispose();
              } catch (_) {}
              await _init();
            },
          ),
        ],
      ),
      body: Column(
        children: [
          AspectRatio(
            aspectRatio: 16 / 9,
            child: Container(
              color: Colors.black,
              child: initialized
                  ? Stack(
                      fit: StackFit.expand,
                      children: [
                        Video(controller: _playerService.controller),
                        if (_buffering)
                          Container(
                            color: Colors.black54,
                            alignment: Alignment.center,
                            child: Column(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                const CircularProgressIndicator(),
                                if (_bufferingPct != null)
                                  Padding(
                                    padding: const EdgeInsets.only(top: 12),
                                    child: Text(
                                      '缓冲中 ${(_bufferingPct! <= 1 ? _bufferingPct! * 100 : _bufferingPct!).clamp(0, 100).toStringAsFixed(0)}%',
                                      style: const TextStyle(color: Colors.white),
                                    ),
                                  ),
                              ],
                            ),
                          ),
                      ],
                    )
                  : _playError != null
                      ? Center(
                          child: Text(
                          '播放失败：$_playError',
                          style: const TextStyle(color: Colors.redAccent),
                        ))
                      : const Center(child: CircularProgressIndicator()),
            ),
          ),
          if (_loading) const LinearProgressIndicator(),
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceEvenly,
            children: [
              IconButton(
                icon: Icon(_playerService.isPlaying ? Icons.pause : Icons.play_arrow),
                onPressed: !initialized
                    ? null
                    : () {
                        setState(() {
                          _playerService.isPlaying ? _playerService.pause() : _playerService.play();
                        });
                      },
              ),
            ],
          ),
        ],
      ),
    );
  }

  void _showAudioTracks(BuildContext context) {
    final audios = List<AudioTrack>.from(_tracks.audio);
    showModalBottomSheet(
      context: context,
      builder: (ctx) {
        if (audios.isEmpty) {
          return const Padding(
            padding: EdgeInsets.all(16),
            child: Text('暂无音轨'),
          );
        }
        final current = _playerService.player.state.track.audio;
        return ListView(
          children: audios
              .map(
                (a) => ListTile(
                  title: Text(a.title ?? a.language ?? '音轨 ${a.id}'),
                  subtitle: Text(a.codec ?? ''),
                  trailing: current == a ? const Icon(Icons.check) : null,
                  onTap: () {
                    Navigator.of(ctx).pop();
                    _playerService.player.setAudioTrack(a);
                  },
                ),
              )
              .toList(),
        );
      },
    );
  }

  void _showSubtitleTracks(BuildContext context) {
    final subs = List<SubtitleTrack>.from(_tracks.subtitle);
    showModalBottomSheet(
      context: context,
      builder: (ctx) {
        if (subs.isEmpty) {
          return const Padding(
            padding: EdgeInsets.all(16),
            child: Text('暂无字幕'),
          );
        }
        final current = _playerService.player.state.track.subtitle;
        return ListView(
          children: subs
              .map(
                (s) => ListTile(
                  title: Text(s.title ?? s.language ?? '字幕 ${s.id}'),
                  trailing: current == s ? const Icon(Icons.check) : null,
                  onTap: () {
                    Navigator.of(ctx).pop();
                    _playerService.player.setSubtitleTrack(s);
                  },
                ),
              )
              .toList(),
        );
      },
    );
  }
}
