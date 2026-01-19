import 'dart:async';
import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:video_player/video_player.dart';
import 'package:video_player_android/exo_tracks.dart' as vp_android;
import 'package:video_player_platform_interface/video_player_platform_interface.dart';

import 'state/app_state.dart';
import 'state/local_playback_handoff.dart';
import 'state/preferences.dart';
import 'src/player/playback_controls.dart';

class ExoPlayerScreen extends StatefulWidget {
  const ExoPlayerScreen({super.key, required this.appState});

  final AppState appState;

  @override
  State<ExoPlayerScreen> createState() => _ExoPlayerScreenState();
}

class _ExoPlayerScreenState extends State<ExoPlayerScreen> {
  final List<PlatformFile> _playlist = [];
  int _currentIndex = -1;

  VideoPlayerController? _controller;
  Timer? _uiTimer;

  bool _buffering = false;
  Duration _position = Duration.zero;
  Duration _duration = Duration.zero;
  String? _playError;
  DateTime? _lastUiTickAt;
  _OrientationMode _orientationMode = _OrientationMode.auto;

  static const Duration _controlsAutoHideDelay = Duration(seconds: 3);
  Timer? _controlsHideTimer;
  bool _controlsVisible = true;
  bool _isScrubbing = false;

  bool get _isAndroid =>
      !kIsWeb && defaultTargetPlatform == TargetPlatform.android;

  @override
  void initState() {
    super.initState();
    final handoff = widget.appState.takeLocalPlaybackHandoff();
    if (handoff != null && handoff.playlist.isNotEmpty) {
      final files = handoff.playlist
          .where((e) => e.path.trim().isNotEmpty)
          .map(
            (e) => PlatformFile(
              name: e.name,
              size: 0,
              path: e.path,
            ),
          )
          .toList();
      if (files.isNotEmpty) {
        _playlist.addAll(files);
        final idx = handoff.index < 0
            ? 0
            : handoff.index >= files.length
                ? files.length - 1
                : handoff.index;
        unawaited(
          _playFile(
            files[idx],
            idx,
            startPosition: handoff.position,
            autoPlay: handoff.wasPlaying,
          ),
        );
      }
    }
  }

  Future<void> _switchCore() async {
    final playlist = _playlist
        .where((f) => (f.path ?? '').trim().isNotEmpty)
        .map((f) => LocalPlaybackItem(name: f.name, path: f.path!.trim()))
        .toList();
    if (playlist.isNotEmpty) {
      final idx = _currentIndex < 0
          ? 0
          : _currentIndex >= playlist.length
              ? playlist.length - 1
              : _currentIndex;
      widget.appState.setLocalPlaybackHandoff(
        LocalPlaybackHandoff(
          playlist: playlist,
          index: idx,
          position: _position,
          wasPlaying: _controller?.value.isPlaying ?? false,
        ),
      );
    }
    await widget.appState.setPlayerCore(PlayerCore.mpv);
  }

  @override
  void dispose() {
    _controlsHideTimer?.cancel();
    _controlsHideTimer = null;
    _uiTimer?.cancel();
    _uiTimer = null;
    // ignore: unawaited_futures
    _exitOrientationLock();
    // ignore: unawaited_futures
    _controller?.dispose();
    _controller = null;
    super.dispose();
  }

  void _showControls({bool scheduleHide = true}) {
    if (!_controlsVisible) {
      setState(() => _controlsVisible = true);
    }
    if (scheduleHide) _scheduleControlsHide();
  }

  void _scheduleControlsHide() {
    _controlsHideTimer?.cancel();
    _controlsHideTimer = null;
    if (!_controlsVisible || _isScrubbing) return;
    _controlsHideTimer = Timer(_controlsAutoHideDelay, () {
      if (!mounted || _isScrubbing) return;
      setState(() => _controlsVisible = false);
    });
  }

  void _onScrubStart() {
    _isScrubbing = true;
    _controlsHideTimer?.cancel();
    _controlsHideTimer = null;
    _showControls(scheduleHide: false);
  }

  void _onScrubEnd() {
    _isScrubbing = false;
    _scheduleControlsHide();
  }

  void _showNotSupported(String feature) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text('Exo 内核暂不支持：$feature')));
  }

  String _audioTrackTitle(VideoAudioTrack t) {
    final label = (t.label ?? '').trim();
    if (label.isNotEmpty) return label;
    final lang = (t.language ?? '').trim();
    if (lang.isNotEmpty) return lang;
    return '音轨 ${t.id}';
  }

  String _audioTrackSubtitle(VideoAudioTrack t) {
    final parts = <String>[];
    final codec = (t.codec ?? '').trim();
    if (codec.isNotEmpty) parts.add(codec);
    if (t.channelCount != null && t.channelCount! > 0) {
      parts.add('${t.channelCount}ch');
    }
    if (t.sampleRate != null && t.sampleRate! > 0) {
      parts.add('${t.sampleRate}Hz');
    }
    if (t.bitrate != null && t.bitrate! > 0) {
      parts.add('${(t.bitrate! / 1000).round()} kbps');
    }
    return parts.join('  ');
  }

  Future<void> _showAudioTracks(BuildContext context) async {
    final controller = _controller;
    if (controller == null || !controller.value.isInitialized) return;

    final platform = VideoPlayerPlatform.instance;
    if (!platform.isAudioTrackSupportAvailable()) {
      _showNotSupported('音轨切换');
      return;
    }

    late final List<VideoAudioTrack> tracks;
    try {
      // ignore: invalid_use_of_visible_for_testing_member
      tracks = await platform.getAudioTracks(controller.playerId);
    } catch (e) {
      if (!context.mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('获取音轨失败：$e')),
      );
      return;
    }

    if (!context.mounted) return;
    showModalBottomSheet(
      context: context,
      builder: (ctx) {
        if (tracks.isEmpty) {
          return const Padding(
            padding: EdgeInsets.all(16),
            child: Text('暂无音轨'),
          );
        }
        return ListView(
          children: tracks
              .map(
                (t) => ListTile(
                  title: Text(_audioTrackTitle(t)),
                  subtitle: Text(_audioTrackSubtitle(t)),
                  trailing: t.isSelected ? const Icon(Icons.check) : null,
                  onTap: () async {
                    Navigator.of(ctx).pop();
                    try {
                      // ignore: invalid_use_of_visible_for_testing_member
                      await platform.selectAudioTrack(
                          controller.playerId, t.id);
                    } catch (e) {
                      if (!context.mounted) return;
                      ScaffoldMessenger.of(context).showSnackBar(
                        SnackBar(content: Text('切换音轨失败：$e')),
                      );
                    }
                  },
                ),
              )
              .toList(),
        );
      },
    );
  }

  String _subtitleTrackTitle(vp_android.ExoPlayerSubtitleTrackData t) {
    final label = (t.label ?? '').trim();
    if (label.isNotEmpty) return label;
    final lang = (t.language ?? '').trim();
    if (lang.isNotEmpty) return lang;
    return '字幕 ${t.groupIndex}_${t.trackIndex}';
  }

  String _subtitleTrackSubtitle(vp_android.ExoPlayerSubtitleTrackData t) {
    final parts = <String>[];
    final codec = (t.codec ?? '').trim();
    final mime = (t.mimeType ?? '').trim();
    if (codec.isNotEmpty) parts.add(codec);
    if (mime.isNotEmpty) parts.add(mime);
    return parts.join('  ');
  }

  Future<void> _showSubtitleTracks(BuildContext context) async {
    final controller = _controller;
    if (controller == null || !controller.value.isInitialized) return;

    final api = vp_android.VideoPlayerInstanceApi(
      // ignore: invalid_use_of_visible_for_testing_member
      messageChannelSuffix: controller.playerId.toString(),
    );

    late final vp_android.NativeSubtitleTrackData data;
    try {
      data = await api.getSubtitleTracks();
    } catch (e) {
      if (!context.mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('获取字幕失败：$e')),
      );
      return;
    }

    final tracks =
        data.exoPlayerTracks ?? const <vp_android.ExoPlayerSubtitleTrackData>[];
    final anySelected = tracks.any((e) => e.isSelected);

    if (!context.mounted) return;
    showModalBottomSheet(
      context: context,
      builder: (ctx) {
        if (tracks.isEmpty) {
          return const Padding(
            padding: EdgeInsets.all(16),
            child: Text('暂无字幕'),
          );
        }

        return ListView(
          children: [
            ListTile(
              title: const Text('关闭'),
              trailing: anySelected ? null : const Icon(Icons.check),
              onTap: () async {
                Navigator.of(ctx).pop();
                try {
                  await api.deselectSubtitleTrack();
                } catch (e) {
                  if (!context.mounted) return;
                  ScaffoldMessenger.of(context).showSnackBar(
                    SnackBar(content: Text('关闭字幕失败：$e')),
                  );
                }
              },
            ),
            ...tracks.map(
              (t) => ListTile(
                title: Text(_subtitleTrackTitle(t)),
                subtitle: Text(_subtitleTrackSubtitle(t)),
                trailing: t.isSelected ? const Icon(Icons.check) : null,
                onTap: () async {
                  Navigator.of(ctx).pop();
                  try {
                    await api.selectSubtitleTrack(t.groupIndex, t.trackIndex);
                  } catch (e) {
                    if (!context.mounted) return;
                    ScaffoldMessenger.of(context).showSnackBar(
                      SnackBar(content: Text('切换字幕失败：$e')),
                    );
                  }
                },
              ),
            ),
          ],
        );
      },
    );
  }

  bool get _shouldControlSystemUi {
    if (kIsWeb) return false;
    return Platform.isAndroid || Platform.isIOS;
  }

  String get _orientationTooltip {
    switch (_orientationMode) {
      case _OrientationMode.auto:
        return '自动旋转';
      case _OrientationMode.landscape:
        return '锁定横屏';
      case _OrientationMode.portrait:
        return '锁定竖屏';
    }
  }

  IconData get _orientationIcon {
    switch (_orientationMode) {
      case _OrientationMode.auto:
        return Icons.screen_rotation;
      case _OrientationMode.landscape:
        return Icons.screen_lock_landscape;
      case _OrientationMode.portrait:
        return Icons.screen_lock_portrait;
    }
  }

  Future<void> _cycleOrientationMode() async {
    if (!_shouldControlSystemUi) {
      _showNotSupported('旋转锁定');
      return;
    }

    final next = switch (_orientationMode) {
      _OrientationMode.auto => _OrientationMode.landscape,
      _OrientationMode.landscape => _OrientationMode.portrait,
      _OrientationMode.portrait => _OrientationMode.auto,
    };

    if (mounted) {
      setState(() => _orientationMode = next);
      ScaffoldMessenger.of(context)
        ..hideCurrentSnackBar()
        ..showSnackBar(
          SnackBar(
            content: Text(_orientationTooltip),
            duration: const Duration(milliseconds: 800),
          ),
        );
    } else {
      _orientationMode = next;
    }

    await _applyOrientationForMode();
  }

  Future<void> _applyOrientationForMode() async {
    if (!_shouldControlSystemUi) return;

    List<DeviceOrientation> orientations;
    switch (_orientationMode) {
      case _OrientationMode.landscape:
        orientations = const [
          DeviceOrientation.landscapeLeft,
          DeviceOrientation.landscapeRight,
        ];
        break;
      case _OrientationMode.portrait:
        orientations = const [DeviceOrientation.portraitUp];
        break;
      case _OrientationMode.auto:
        orientations = const [];
        break;
    }

    try {
      await SystemChrome.setPreferredOrientations(orientations);
    } catch (_) {}
  }

  Future<void> _exitOrientationLock() async {
    if (!_shouldControlSystemUi) return;
    try {
      await SystemChrome.setPreferredOrientations(const []);
    } catch (_) {}
  }

  Future<void> _pickFiles() async {
    final result = await FilePicker.platform.pickFiles(
      type: FileType.video,
      allowMultiple: true,
      withData: false,
    );
    if (!mounted) return;
    if (result == null) return;

    setState(() => _playlist.addAll(result.files));
    if (_currentIndex == -1 && _playlist.isNotEmpty) {
      // ignore: unawaited_futures
      _playFile(_playlist.first, 0);
    }
  }

  Future<void> _playFile(
    PlatformFile file,
    int index, {
    Duration? startPosition,
    bool? autoPlay,
  }) async {
    final path = (file.path ?? '').trim();
    if (path.isEmpty) {
      setState(() => _playError = '无法读取文件路径');
      return;
    }

    setState(() {
      _currentIndex = index;
      _playError = null;
      _buffering = false;
      _position = Duration.zero;
      _duration = Duration.zero;
      _controlsVisible = true;
      _isScrubbing = false;
    });

    _controlsHideTimer?.cancel();
    _controlsHideTimer = null;
    _uiTimer?.cancel();
    _uiTimer = null;

    final prev = _controller;
    _controller = null;
    if (prev != null) {
      await prev.dispose();
    }

    try {
      final uri = Uri.tryParse(path);
      final isUri = uri != null && uri.scheme.isNotEmpty;
      // Use platform view on Android to avoid color issues with some HDR/Dolby Vision sources.
      // (Texture-based rendering may show green/purple tint on certain P8 files.)
      final viewType =
          _isAndroid ? VideoViewType.platformView : VideoViewType.textureView;
      final controller = isUri
          ? VideoPlayerController.networkUrl(uri, viewType: viewType)
          : VideoPlayerController.file(File(path), viewType: viewType);
      _controller = controller;
      await controller.initialize();
      if (startPosition != null && startPosition > Duration.zero) {
        final d = controller.value.duration;
        final target =
            (d > Duration.zero && startPosition > d) ? d : startPosition;
        await controller.seekTo(target);
        _position = target;
      }
      if (autoPlay == false) {
        await controller.pause();
      } else {
        await controller.play();
      }

      _uiTimer = Timer.periodic(const Duration(milliseconds: 250), (_) {
        final c = _controller;
        if (!mounted || c == null) return;
        final v = c.value;
        _buffering = v.isBuffering;
        _position = v.position;
        _duration = v.duration;
        final now = DateTime.now();
        final shouldRebuild = _lastUiTickAt == null ||
            now.difference(_lastUiTickAt!) >= const Duration(milliseconds: 250);
        if (shouldRebuild) {
          _lastUiTickAt = now;
          setState(() {});
        }
      });

      _scheduleControlsHide();
      if (mounted) setState(() {});
    } catch (e) {
      setState(() => _playError = e.toString());
    }
  }

  @override
  Widget build(BuildContext context) {
    final fileName = _currentIndex >= 0 && _currentIndex < _playlist.length
        ? _playlist[_currentIndex].name
        : '本地播放（Exo）';

    if (!_isAndroid) {
      return Scaffold(
        appBar: AppBar(title: const Text('本地播放（Exo）'), centerTitle: true),
        body: const Center(child: Text('Exo 内核仅支持 Android')),
      );
    }

    final controller = _controller;
    final isReady = controller != null && controller.value.isInitialized;
    final controlsEnabled = isReady && _playError == null;

    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        title: Text(fileName),
        centerTitle: true,
        actions: [
          IconButton(
            tooltip: '选择文件',
            icon: const Icon(Icons.folder_open),
            onPressed: _pickFiles,
          ),
          IconButton(
            tooltip: '选集',
            icon: const Icon(Icons.playlist_play),
            onPressed: _playlist.isEmpty
                ? null
                : () {
                    showModalBottomSheet(
                      context: context,
                      builder: (ctx) => ListView.builder(
                        itemCount: _playlist.length,
                        itemBuilder: (_, i) {
                          final f = _playlist[i];
                          return ListTile(
                            title: Text(f.name),
                            trailing: i == _currentIndex
                                ? const Icon(Icons.play_arrow)
                                : null,
                            onTap: () {
                              Navigator.of(ctx).pop();
                              // ignore: unawaited_futures
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
            tooltip: '弹幕',
            icon: const Icon(Icons.comment_outlined),
            onPressed: () => _showNotSupported('弹幕'),
          ),
          IconButton(
            tooltip: '软/硬解切换',
            icon: const Icon(Icons.memory),
            onPressed: () => _showNotSupported('软/硬解切换'),
          ),
          IconButton(
            tooltip: _orientationTooltip,
            icon: Icon(_orientationIcon),
            onPressed: _cycleOrientationMode,
          ),
        ],
      ),
      body: Column(
        children: [
          AspectRatio(
            aspectRatio: 16 / 9,
            child: Container(
              color: Colors.black,
              child: isReady
                  ? Stack(
                      fit: StackFit.expand,
                      children: [
                        Center(
                          child: AspectRatio(
                            aspectRatio: controller.value.aspectRatio == 0
                                ? 16 / 9
                                : controller.value.aspectRatio,
                            child: VideoPlayer(controller),
                          ),
                        ),
                        if (_buffering)
                          const Positioned.fill(
                            child: ColoredBox(
                              color: Colors.black54,
                              child: Center(child: CircularProgressIndicator()),
                            ),
                          ),
                        if (_playError != null)
                          Center(
                            child: Text(
                              '播放失败：$_playError',
                              style: const TextStyle(color: Colors.redAccent),
                              textAlign: TextAlign.center,
                            ),
                          ),
                        Positioned.fill(
                          child: GestureDetector(
                            behavior: HitTestBehavior.translucent,
                            onTapDown: (_) => _showControls(),
                            child: const SizedBox.expand(),
                          ),
                        ),
                        Align(
                          alignment: Alignment.bottomCenter,
                          child: SafeArea(
                            top: false,
                            left: false,
                            right: false,
                            minimum: const EdgeInsets.fromLTRB(12, 0, 12, 12),
                            child: AnimatedOpacity(
                              opacity: _controlsVisible ? 1 : 0,
                              duration: const Duration(milliseconds: 200),
                              child: IgnorePointer(
                                ignoring: !_controlsVisible,
                                child: Listener(
                                  onPointerDown: (_) => _showControls(),
                                  child: PlaybackControls(
                                    enabled: controlsEnabled,
                                    position: _position,
                                    duration: _duration,
                                    isPlaying: controller.value.isPlaying,
                                    onSwitchCore: _switchCore,
                                    onScrubStart: _onScrubStart,
                                    onScrubEnd: _onScrubEnd,
                                    onSeek: (pos) async {
                                      await controller.seekTo(pos);
                                      _position = pos;
                                      if (mounted) setState(() {});
                                    },
                                    onPlay: () async {
                                      _showControls();
                                      await controller.play();
                                      if (mounted) setState(() {});
                                    },
                                    onPause: () async {
                                      _showControls();
                                      await controller.pause();
                                      if (mounted) setState(() {});
                                    },
                                    onSeekBackward: () async {
                                      _showControls();
                                      final target = _position -
                                          const Duration(seconds: 10);
                                      final pos = target < Duration.zero
                                          ? Duration.zero
                                          : target;
                                      await controller.seekTo(pos);
                                      _position = pos;
                                      if (mounted) setState(() {});
                                    },
                                    onSeekForward: () async {
                                      _showControls();
                                      final d = _duration;
                                      final target = _position +
                                          const Duration(seconds: 10);
                                      final pos =
                                          (d > Duration.zero && target > d)
                                              ? d
                                              : target;
                                      await controller.seekTo(pos);
                                      _position = pos;
                                      if (mounted) setState(() {});
                                    },
                                  ),
                                ),
                              ),
                            ),
                          ),
                        ),
                      ],
                    )
                  : _playError != null
                      ? Center(
                          child: Text(
                            '播放失败：$_playError',
                            style: const TextStyle(color: Colors.redAccent),
                            textAlign: TextAlign.center,
                          ),
                        )
                      : const Center(child: Text('选择一个视频播放')),
            ),
          ),
          const SizedBox(height: 8),
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
                final isPlaying = index == _currentIndex;
                return ListTile(
                  leading:
                      Icon(isPlaying ? Icons.play_circle_filled : Icons.movie),
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
}

enum _OrientationMode { auto, landscape, portrait }
