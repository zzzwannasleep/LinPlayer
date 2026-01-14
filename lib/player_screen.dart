import 'dart:async';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart' show kIsWeb, defaultTargetPlatform;
import 'package:flutter/material.dart';
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';

import 'player_service.dart';
import 'src/player/track_preferences.dart';
import 'state/app_state.dart';

class PlayerScreen extends StatefulWidget {
  const PlayerScreen({super.key, this.appState});

  final AppState? appState;

  @override
  State<PlayerScreen> createState() => _PlayerScreenState();
}

class _PlayerScreenState extends State<PlayerScreen> {
  final PlayerService _playerService = getPlayerService();
  final List<PlatformFile> _playlist = [];
  int _currentlyPlayingIndex = -1;
  StreamSubscription<Duration>? _posSub;
  StreamSubscription<String>? _errorSub;
  Duration _position = Duration.zero;
  Duration _duration = Duration.zero;
  String? _playError;
  late bool _hwdecOn;
  Tracks _tracks = const Tracks();
  DateTime? _lastPositionUiUpdate;
  bool _appliedAudioPref = false;
  bool _appliedSubtitlePref = false;

  @override
  void initState() {
    super.initState();
    _hwdecOn = widget.appState?.preferHardwareDecode ?? true;
  }

  @override
  void dispose() {
    _posSub?.cancel();
    _errorSub?.cancel();
    _playerService.dispose();
    super.dispose();
  }

  bool _isTv(BuildContext context) =>
      defaultTargetPlatform == TargetPlatform.android &&
      MediaQuery.of(context).size.shortestSide > 600;

  Future<void> _pickFile() async {
    final result = await FilePicker.platform.pickFiles(
      type: FileType.video,
      allowMultiple: true,
      withData: kIsWeb,
    );
    if (result != null) {
      setState(() => _playlist.addAll(result.files));
      if (_currentlyPlayingIndex == -1 && _playlist.isNotEmpty) {
        _playFile(_playlist.first, 0);
      }
    }
  }

  Future<void> _playFile(PlatformFile file, int index) async {
    setState(() {
      _currentlyPlayingIndex = index;
      _playError = null;
      _appliedAudioPref = false;
      _appliedSubtitlePref = false;
    });
    final isTv = _isTv(context);
    await _errorSub?.cancel();
    _errorSub = null;
    try {
      await _playerService.dispose();
    } catch (_) {}

    try {
      if (kIsWeb) {
        await _playerService.initialize(
          null,
          networkUrl: file.path ?? '',
          isTv: isTv,
          hardwareDecode: _hwdecOn,
        );
      } else {
        await _playerService.initialize(
          file.path,
          isTv: isTv,
          hardwareDecode: _hwdecOn,
        );
      }
      if (!mounted) return;
      _tracks = _playerService.player.state.tracks;
      _maybeApplyPreferredTracks(_tracks);
      _playerService.player.stream.tracks.listen((t) {
        if (!mounted) return;
        _maybeApplyPreferredTracks(t);
        setState(() => _tracks = t);
      });
      _errorSub?.cancel();
      _errorSub = _playerService.player.stream.error.listen((message) {
        if (!mounted) return;
        setState(() => _playError = message);
      });
      _duration = _playerService.duration;
      _posSub?.cancel();
      _posSub = _playerService.player.stream.position.listen((d) {
        if (!mounted) return;
        final now = DateTime.now();
        final deltaMs = (d.inMilliseconds - _position.inMilliseconds).abs();
        final shouldRebuild = _lastPositionUiUpdate == null ||
            now.difference(_lastPositionUiUpdate!) >= const Duration(milliseconds: 250) ||
            deltaMs >= 1000;
        _position = d;
        if (shouldRebuild) {
          _lastPositionUiUpdate = now;
          setState(() {});
        }
      });
    } catch (e) {
      setState(() => _playError = e.toString());
    }
    setState(() {});
  }

  void _maybeApplyPreferredTracks(Tracks tracks) {
    final appState = widget.appState;
    final player = _playerService.isInitialized ? _playerService.player : null;
    if (appState == null || player == null) return;

    if (!_appliedAudioPref) {
      final picked = pickPreferredAudioTrack(tracks, appState.preferredAudioLang);
      if (picked != null) {
        player.setAudioTrack(picked);
      }
      _appliedAudioPref = true;
    }

    if (!_appliedSubtitlePref) {
      final pref = appState.preferredSubtitleLang;
      if (isSubtitleOffPreference(pref)) {
        player.setSubtitleTrack(SubtitleTrack.no());
      } else {
        final picked = pickPreferredSubtitleTrack(tracks, pref);
        if (picked != null) {
          player.setSubtitleTrack(picked);
        }
      }
      _appliedSubtitlePref = true;
    }
  }

  @override
  Widget build(BuildContext context) {
    final currentFileName =
        _currentlyPlayingIndex != -1 ? _playlist[_currentlyPlayingIndex].name : 'LinPlayer';

    return Scaffold(
      appBar: AppBar(
        title: Text(currentFileName),
        centerTitle: true,
        actions: [
          IconButton(
            tooltip: '选集',
            icon: const Icon(Icons.playlist_play),
            onPressed: () {
              showModalBottomSheet(
                context: context,
                builder: (ctx) => ListView.builder(
                  itemCount: _playlist.length,
                  itemBuilder: (_, i) {
                    final f = _playlist[i];
                    return ListTile(
                      title: Text(f.name),
                      trailing: i == _currentlyPlayingIndex
                          ? const Icon(Icons.play_arrow)
                          : null,
                      onTap: () {
                        Navigator.of(ctx).pop();
                        _playFile(f, i);
                      },
                    );
                  },
                ),
              );
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
            onPressed: () {
              setState(() => _hwdecOn = !_hwdecOn);
              if (_currentlyPlayingIndex >= 0 && _playlist.isNotEmpty) {
                _playFile(_playlist[_currentlyPlayingIndex], _currentlyPlayingIndex);
              }
            },
          ),
          IconButton(
            icon: const Icon(Icons.folder_open),
            onPressed: _pickFile,
          ),
        ],
      ),
      body: Column(
        children: [
          AspectRatio(
            aspectRatio: 16 / 9,
            child: Container(
              color: Colors.black,
              child: _playerService.isInitialized
                  ? Video(controller: _playerService.controller)
                  : _playError != null
                      ? Center(
                          child: Text(
                            '播放失败：$_playError',
                            style: const TextStyle(color: Colors.redAccent),
                          ),
                        )
                      : const Center(child: Text('选择一个视频播放')),
            ),
          ),
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceEvenly,
            children: [
              IconButton(
                icon: const Icon(Icons.replay_10),
                onPressed: !_playerService.isInitialized
                    ? null
                    : () {
                        final newPos = _position - const Duration(seconds: 10);
                        _playerService.seek(newPos);
                      },
              ),
              IconButton(
                icon: const Icon(Icons.forward_10),
                onPressed: !_playerService.isInitialized
                    ? null
                    : () {
                        final newPos = _position + const Duration(seconds: 10);
                        _playerService.seek(newPos);
                      },
              ),
            ],
          ),
          if (_playerService.isInitialized)
            Slider(
              value: _position.inMilliseconds.toDouble().clamp(0, _duration.inMilliseconds + 1),
              max: (_playerService.duration.inMilliseconds + 1).toDouble(),
              onChanged: (v) => _playerService.seek(Duration(milliseconds: v.toInt())),
            ),
          const Padding(
            padding: EdgeInsets.all(8.0),
            child: Text(
              '播放列表',
              style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
            ),
          ),
          Expanded(
            child: ListView.builder(
              itemCount: _playlist.length,
              itemBuilder: (context, index) {
                final file = _playlist[index];
                final isPlaying = index == _currentlyPlayingIndex;
                return ListTile(
                  leading: Icon(isPlaying ? Icons.play_circle_filled : Icons.movie),
                  title: Text(
                    file.name,
                    style: TextStyle(
                      color: isPlaying ? Colors.blue : null,
                    ),
                  ),
                  onTap: () => _playFile(file, index),
                );
              },
            ),
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
