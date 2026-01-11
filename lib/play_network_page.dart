import 'package:flutter/material.dart';
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';
import 'player_service.dart';

class PlayNetworkPage extends StatefulWidget {
  const PlayNetworkPage({
    super.key,
    required this.title,
    required this.streamUrl,
    this.isTv = false,
  });

  final String title;
  final String streamUrl;
  final bool isTv;

  @override
  State<PlayNetworkPage> createState() => _PlayNetworkPageState();
}

class _PlayNetworkPageState extends State<PlayNetworkPage> {
  final PlayerService _playerService = getPlayerService();
  bool _loading = true;
  String? _playError;
  bool _hwdecOn = true;
  Tracks _tracks = const Tracks();

  @override
  void initState() {
    super.initState();
    _init();
  }

  Future<void> _init() async {
    try {
      await _playerService.initialize(
        null,
        networkUrl: widget.streamUrl,
        isTv: widget.isTv,
        hardwareDecode: _hwdecOn,
      );
      _tracks = _playerService.player.state.tracks;
      _playerService.player.stream.tracks.listen((t) {
        if (!mounted) return;
        setState(() => _tracks = t);
      });
    } catch (e) {
      _playError = e.toString();
    } finally {
      if (mounted) {
        setState(() => _loading = false);
      }
    }
  }

  @override
  void dispose() {
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
          IconButton(
            tooltip: '选集',
            icon: const Icon(Icons.playlist_play),
            onPressed: () {
              showModalBottomSheet(
                context: context,
                builder: (_) => const Padding(
                  padding: EdgeInsets.all(16),
                  child: Text('当前只有单集播放，暂无可选集。'),
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
                  ? Video(
                      controller: _playerService.controller,
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
