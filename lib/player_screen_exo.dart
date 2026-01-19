import 'dart:async';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:video_player/video_player.dart';
import 'package:video_player_android/exo_tracks.dart' as vp_android;
import 'package:video_player_platform_interface/video_player_platform_interface.dart';

import 'services/dandanplay_api.dart';
import 'state/app_state.dart';
import 'state/danmaku_preferences.dart';
import 'state/local_playback_handoff.dart';
import 'state/preferences.dart';
import 'src/player/danmaku.dart';
import 'src/player/danmaku_processing.dart';
import 'src/player/danmaku_stage.dart';
import 'src/player/playback_controls.dart';
import 'src/ui/glass_blur.dart';

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

  VideoViewType _viewType = VideoViewType.platformView;

  final GlobalKey<DanmakuStageState> _danmakuKey =
      GlobalKey<DanmakuStageState>();
  final List<DanmakuSource> _danmakuSources = [];
  int _danmakuSourceIndex = -1;
  bool _danmakuEnabled = false;
  double _danmakuOpacity = 1.0;
  double _danmakuScale = 1.0;
  double _danmakuSpeed = 1.0;
  bool _danmakuBold = true;
  int _danmakuMaxLines = 10;
  int _danmakuTopMaxLines = 10;
  int _danmakuBottomMaxLines = 10;
  bool _danmakuPreventOverlap = true;
  int _nextDanmakuIndex = 0;
  bool _danmakuPaused = false;

  static const Duration _controlsAutoHideDelay = Duration(seconds: 3);
  Timer? _controlsHideTimer;
  bool _controlsVisible = true;
  bool _isScrubbing = false;

  bool get _isAndroid =>
      !kIsWeb && defaultTargetPlatform == TargetPlatform.android;

  @override
  void initState() {
    super.initState();
    _danmakuEnabled = widget.appState.danmakuEnabled;
    _danmakuOpacity = widget.appState.danmakuOpacity;
    _danmakuScale = widget.appState.danmakuScale;
    _danmakuSpeed = widget.appState.danmakuSpeed;
    _danmakuBold = widget.appState.danmakuBold;
    _danmakuMaxLines = widget.appState.danmakuMaxLines;
    _danmakuTopMaxLines = widget.appState.danmakuTopMaxLines;
    _danmakuBottomMaxLines = widget.appState.danmakuBottomMaxLines;
    _danmakuPreventOverlap = widget.appState.danmakuPreventOverlap;

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

  void _applyDanmakuPauseState(bool pause) {
    if (_danmakuPaused == pause) return;
    _danmakuPaused = pause;
    final stage = _danmakuKey.currentState;
    if (pause) {
      stage?.pause();
    } else {
      stage?.resume();
    }
  }

  void _syncDanmakuCursor(Duration position) {
    if (_danmakuSourceIndex < 0 ||
        _danmakuSourceIndex >= _danmakuSources.length) {
      _nextDanmakuIndex = 0;
      return;
    }
    final items = _danmakuSources[_danmakuSourceIndex].items;
    _nextDanmakuIndex = DanmakuParser.lowerBoundByTime(items, position);
    _danmakuKey.currentState?.clear();
  }

  void _drainDanmaku(Duration position) {
    if (!_danmakuEnabled) return;
    if (_danmakuSourceIndex < 0 ||
        _danmakuSourceIndex >= _danmakuSources.length) {
      return;
    }
    final stage = _danmakuKey.currentState;
    if (stage == null) return;

    final items = _danmakuSources[_danmakuSourceIndex].items;
    while (_nextDanmakuIndex < items.length &&
        items[_nextDanmakuIndex].time <= position) {
      stage.emit(items[_nextDanmakuIndex]);
      _nextDanmakuIndex++;
    }
  }

  Future<String> _computeFileHash16M(String path) async {
    const maxBytes = 16 * 1024 * 1024;
    final file = File(path);
    final digest = await md5.bind(file.openRead(0, maxBytes)).first;
    return digest.toString();
  }

  void _maybeAutoLoadOnlineDanmaku(PlatformFile file) {
    final appState = widget.appState;
    if (!appState.danmakuEnabled) return;
    if (appState.danmakuLoadMode != DanmakuLoadMode.online) return;
    if (kIsWeb) return;
    // ignore: unawaited_futures
    _loadOnlineDanmakuForFile(file, showToast: false);
  }

  Future<void> _loadOnlineDanmakuForFile(
    PlatformFile file, {
    bool showToast = true,
  }) async {
    final appState = widget.appState;
    if (appState.danmakuApiUrls.isEmpty) {
      if (showToast && mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('请先在设置-弹幕中添加在线弹幕源')),
        );
      }
      return;
    }
    if (kIsWeb) {
      if (showToast && mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Web 端暂不支持在线弹幕匹配')),
        );
      }
      return;
    }
    final path = file.path;
    if (path == null || path.trim().isEmpty) {
      if (showToast && mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('无法读取视频文件路径')),
        );
      }
      return;
    }

    final hasOfficial = appState.danmakuApiUrls.any((u) {
      final host = Uri.tryParse(u)?.host.toLowerCase() ?? '';
      return host == 'api.dandanplay.net';
    });
    final hasCreds = appState.danmakuAppId.trim().isNotEmpty &&
        appState.danmakuAppSecret.trim().isNotEmpty;

    if (hasOfficial && !hasCreds && showToast && mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('使用官方弹弹play源时通常需要配置 AppId/AppSecret（设置-弹幕）'),
        ),
      );
    }

    try {
      final size = await File(path).length();
      final hash = await _computeFileHash16M(path);
      final sources = await loadOnlineDanmakuSources(
        apiUrls: appState.danmakuApiUrls,
        fileName: file.name,
        fileHash: hash,
        fileSizeBytes: size,
        videoDurationSeconds: _duration.inSeconds,
        matchMode: appState.danmakuMatchMode,
        chConvert: appState.danmakuChConvert,
        appId: appState.danmakuAppId,
        appSecret: appState.danmakuAppSecret,
        throwIfEmpty: showToast,
      );
      if (!mounted) return;
      final processed = processDanmakuSources(
        sources,
        blockWords: appState.danmakuBlockWords,
        mergeDuplicates: appState.danmakuMergeDuplicates,
      );
      if (processed.isEmpty) {
        if (showToast) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('未匹配到在线弹幕')),
          );
        }
        return;
      }
      setState(() {
        _danmakuSources.addAll(processed);
        final desiredName = appState.danmakuRememberSelectedSource
            ? appState.danmakuLastSelectedSourceName
            : '';
        final idx = desiredName.isEmpty
            ? -1
            : _danmakuSources.indexWhere((s) => s.name == desiredName);
        _danmakuSourceIndex = idx >= 0 ? idx : (_danmakuSources.length - 1);
        _danmakuEnabled = true;
        _syncDanmakuCursor(_position);
      });

      await _ensureDanmakuVisible();

      if (showToast && mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('已加载在线弹幕：${sources.length} 个来源')),
        );
      }
    } catch (e) {
      if (showToast && mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('在线弹幕加载失败：$e')),
        );
      }
    }
  }

  Future<void> _pickDanmakuFile() async {
    final result = await FilePicker.platform.pickFiles(
      type: FileType.custom,
      allowedExtensions: const ['xml'],
      withData: kIsWeb,
    );
    if (result == null || result.files.isEmpty) return;
    final file = result.files.first;

    String content = '';
    if (kIsWeb) {
      final bytes = file.bytes;
      if (bytes == null) return;
      content = DanmakuParser.decodeBytes(bytes);
    } else {
      final path = file.path;
      if (path == null || path.trim().isEmpty) return;
      final bytes = await File(path).readAsBytes();
      content = DanmakuParser.decodeBytes(bytes);
    }

    var items = DanmakuParser.parseBilibiliXml(content);
    items = processDanmakuItems(
      items,
      blockWords: widget.appState.danmakuBlockWords,
      mergeDuplicates: widget.appState.danmakuMergeDuplicates,
    );
    if (!mounted) return;
    setState(() {
      _danmakuSources.add(DanmakuSource(name: file.name, items: items));
      final desiredName = widget.appState.danmakuRememberSelectedSource
          ? widget.appState.danmakuLastSelectedSourceName
          : '';
      final idx = desiredName.isEmpty
          ? -1
          : _danmakuSources.indexWhere((s) => s.name == desiredName);
      _danmakuSourceIndex = idx >= 0 ? idx : (_danmakuSources.length - 1);
      _danmakuEnabled = true;
      _syncDanmakuCursor(_position);
    });

    await _ensureDanmakuVisible();
  }

  Future<void> _ensureDanmakuVisible() async {
    if (!_isAndroid) return;
    if (_viewType == VideoViewType.textureView) return;

    final idx = _currentIndex;
    if (idx < 0 || idx >= _playlist.length) {
      setState(() => _viewType = VideoViewType.textureView);
      return;
    }

    final wasPlaying = _controller?.value.isPlaying ?? true;
    final pos = _position;
    if (mounted) {
      ScaffoldMessenger.of(context)
        ..hideCurrentSnackBar()
        ..showSnackBar(
          const SnackBar(
            content: Text('为显示弹幕已切换到纹理渲染（部分 HDR/DV 片源可能偏色）'),
            duration: Duration(milliseconds: 1200),
          ),
        );
    }

    setState(() => _viewType = VideoViewType.textureView);
    await _playFile(
      _playlist[idx],
      idx,
      startPosition: pos,
      autoPlay: wasPlaying,
      resetDanmaku: false,
    );
  }

  Future<void> _showDanmakuSheet() async {
    await showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      builder: (ctx) {
        var onlineLoading = false;
        return StatefulBuilder(
          builder: (context, setSheetState) {
            final hasSources = _danmakuSources.isNotEmpty;
            final selectedName = (_danmakuSourceIndex >= 0 &&
                    _danmakuSourceIndex < _danmakuSources.length)
                ? _danmakuSources[_danmakuSourceIndex].name
                : '未选择';

            return Padding(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Row(
                    children: [
                      Expanded(
                        child: Text(
                          '弹幕',
                          style: Theme.of(context).textTheme.titleLarge,
                        ),
                      ),
                      TextButton.icon(
                        onPressed: () async {
                          await _pickDanmakuFile();
                          setSheetState(() {});
                        },
                        icon: const Icon(Icons.upload_file),
                        label: const Text('本地'),
                      ),
                      const SizedBox(width: 8),
                      TextButton.icon(
                        onPressed: onlineLoading ||
                                _currentIndex < 0 ||
                                _currentIndex >= _playlist.length
                            ? null
                            : () async {
                                onlineLoading = true;
                                setSheetState(() {});
                                try {
                                  await _loadOnlineDanmakuForFile(
                                    _playlist[_currentIndex],
                                    showToast: true,
                                  );
                                } finally {
                                  onlineLoading = false;
                                  setSheetState(() {});
                                }
                              },
                        icon: onlineLoading
                            ? const SizedBox(
                                width: 18,
                                height: 18,
                                child:
                                    CircularProgressIndicator(strokeWidth: 2),
                              )
                            : const Icon(Icons.cloud_download_outlined),
                        label: const Text('在线'),
                      ),
                    ],
                  ),
                  SwitchListTile(
                    value: _danmakuEnabled,
                    onChanged: (v) async {
                      setState(() => _danmakuEnabled = v);
                      if (!v) {
                        _danmakuKey.currentState?.clear();
                      } else if (hasSources) {
                        await _ensureDanmakuVisible();
                      }
                      setSheetState(() {});
                    },
                    title: const Text('启用弹幕'),
                    subtitle:
                        Text(hasSources ? '当前：$selectedName' : '尚未加载弹幕文件'),
                    contentPadding: EdgeInsets.zero,
                  ),
                  const Divider(height: 1),
                  ListTile(
                    contentPadding: EdgeInsets.zero,
                    leading: const Icon(Icons.layers_outlined),
                    title: const Text('弹幕源'),
                    trailing: DropdownButtonHideUnderline(
                      child: DropdownButton<int>(
                        value: _danmakuSourceIndex >= 0
                            ? _danmakuSourceIndex
                            : null,
                        hint: const Text('请选择'),
                        items: [
                          for (var i = 0; i < _danmakuSources.length; i++)
                            DropdownMenuItem(
                              value: i,
                              child: Text(
                                _danmakuSources[i].name,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                              ),
                            ),
                        ],
                        onChanged: !hasSources
                            ? null
                            : (v) async {
                                if (v == null) return;
                                setState(() {
                                  _danmakuSourceIndex = v;
                                  _danmakuEnabled = true;
                                  _syncDanmakuCursor(_position);
                                });
                                if (widget.appState
                                        .danmakuRememberSelectedSource &&
                                    v >= 0 &&
                                    v < _danmakuSources.length) {
                                  // ignore: unawaited_futures
                                  widget.appState
                                      .setDanmakuLastSelectedSourceName(
                                          _danmakuSources[v].name);
                                }
                                await _ensureDanmakuVisible();
                                setSheetState(() {});
                              },
                      ),
                    ),
                  ),
                  const Divider(height: 1),
                  ListTile(
                    contentPadding: EdgeInsets.zero,
                    leading: const Icon(Icons.opacity_outlined),
                    title: const Text('不透明度'),
                    subtitle: Slider(
                      value: _danmakuOpacity,
                      min: 0.2,
                      max: 1.0,
                      onChanged: (v) {
                        setState(() => _danmakuOpacity = v);
                        setSheetState(() {});
                      },
                    ),
                  ),
                  if (hasSources)
                    SizedBox(
                      width: double.infinity,
                      child: OutlinedButton.icon(
                        onPressed: () {
                          setState(() {
                            _danmakuSources.clear();
                            _danmakuSourceIndex = -1;
                            _danmakuEnabled = false;
                            _danmakuKey.currentState?.clear();
                          });
                          setSheetState(() {});
                        },
                        icon: const Icon(Icons.delete_outline),
                        label: const Text('清空弹幕'),
                      ),
                    ),
                ],
              ),
            );
          },
        );
      },
    );
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

    // ignore: invalid_use_of_visible_for_testing_member
    final playerId = controller.playerId;

    final platform = VideoPlayerPlatform.instance;
    if (!platform.isAudioTrackSupportAvailable()) {
      _showNotSupported('音轨切换');
      return;
    }

    late final List<VideoAudioTrack> tracks;
    try {
      tracks = await platform.getAudioTracks(playerId);
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
                      await platform.selectAudioTrack(playerId, t.id);
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

    // ignore: invalid_use_of_visible_for_testing_member
    final playerId = controller.playerId;

    final api = vp_android.VideoPlayerInstanceApi(
      messageChannelSuffix: playerId.toString(),
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
    bool resetDanmaku = true,
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
      if (resetDanmaku) {
        _nextDanmakuIndex = 0;
        _danmakuSources.clear();
        _danmakuSourceIndex = -1;
        _danmakuKey.currentState?.clear();
        _danmakuEnabled = widget.appState.danmakuEnabled;
        _danmakuOpacity = widget.appState.danmakuOpacity;
        _danmakuScale = widget.appState.danmakuScale;
        _danmakuSpeed = widget.appState.danmakuSpeed;
        _danmakuBold = widget.appState.danmakuBold;
        _danmakuMaxLines = widget.appState.danmakuMaxLines;
        _danmakuTopMaxLines = widget.appState.danmakuTopMaxLines;
        _danmakuBottomMaxLines = widget.appState.danmakuBottomMaxLines;
        _danmakuPreventOverlap = widget.appState.danmakuPreventOverlap;
        _danmakuPaused = false;
      }
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
      final viewType = _isAndroid ? _viewType : VideoViewType.textureView;
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
        _applyDanmakuPauseState(_buffering || !v.isPlaying);
        _drainDanmaku(_position);
        final now = DateTime.now();
        final shouldRebuild = _lastUiTickAt == null ||
            now.difference(_lastUiTickAt!) >= const Duration(milliseconds: 250);
        if (shouldRebuild) {
          _lastUiTickAt = now;
          setState(() {});
        }
      });

      if (resetDanmaku) {
        _maybeAutoLoadOnlineDanmaku(file);
      } else {
        _syncDanmakuCursor(_position);
      }

      _scheduleControlsHide();
      if (mounted) setState(() {});
    } catch (e) {
      setState(() => _playError = e.toString());
    }
  }

  @override
  Widget build(BuildContext context) {
    final isTv = defaultTargetPlatform == TargetPlatform.android &&
        MediaQuery.of(context).orientation == Orientation.landscape &&
        MediaQuery.of(context).size.shortestSide >= 720;
    final enableBlur = !isTv && widget.appState.enableBlurEffects;

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
      appBar: GlassAppBar(
        enableBlur: enableBlur,
        child: AppBar(
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
              onPressed: _showDanmakuSheet,
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
                        Positioned.fill(
                          child: DanmakuStage(
                            key: _danmakuKey,
                            enabled: _danmakuEnabled,
                            opacity: _danmakuOpacity,
                            scale: _danmakuScale,
                            speed: _danmakuSpeed,
                            bold: _danmakuBold,
                            scrollMaxLines: _danmakuMaxLines,
                            topMaxLines: _danmakuTopMaxLines,
                            bottomMaxLines: _danmakuBottomMaxLines,
                            preventOverlap: _danmakuPreventOverlap,
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
                                      _syncDanmakuCursor(pos);
                                      if (mounted) setState(() {});
                                    },
                                    onPlay: () async {
                                      _showControls();
                                      await controller.play();
                                      _applyDanmakuPauseState(false);
                                      if (mounted) setState(() {});
                                    },
                                    onPause: () async {
                                      _showControls();
                                      await controller.pause();
                                      _applyDanmakuPauseState(true);
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
                                      _syncDanmakuCursor(pos);
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
                                      _syncDanmakuCursor(pos);
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
