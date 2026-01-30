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
import 'state/interaction_preferences.dart';
import 'state/local_playback_handoff.dart';
import 'state/preferences.dart';
import 'src/player/danmaku.dart';
import 'src/player/danmaku_processing.dart';
import 'src/player/danmaku_stage.dart';
import 'src/player/playback_controls.dart';
import 'src/player/features/player_gestures.dart';
import 'src/player/shared/player_types.dart';
import 'src/player/shared/system_ui.dart';
import 'src/device/device_type.dart';
import 'src/ui/glass_blur.dart';

class ExoPlayerScreen extends StatefulWidget {
  const ExoPlayerScreen({
    super.key,
    required this.appState,
    this.startFullScreen = false,
  });

  final AppState appState;
  final bool startFullScreen;

  @override
  State<ExoPlayerScreen> createState() => _ExoPlayerScreenState();
}

class _ExoPlayerScreenState extends State<ExoPlayerScreen>
    with WidgetsBindingObserver {
  final List<PlatformFile> _playlist = [];
  int _currentIndex = -1;

  VideoPlayerController? _controller;
  Timer? _uiTimer;
  bool _exitInProgress = false;
  bool _allowRoutePop = false;

  bool _buffering = false;
  Duration _lastBufferedEnd = Duration.zero;
  DateTime? _lastBufferedAt;
  Duration _bufferSpeedSampleEnd = Duration.zero;
  double? _bufferSpeedX;
  Duration _position = Duration.zero;
  Duration _duration = Duration.zero;
  String? _playError;
  DateTime? _lastUiTickAt;
  _OrientationMode _orientationMode = _OrientationMode.auto;
  String? _lastOrientationKey;
  bool _remoteEnabled = false;
  final FocusNode _tvSurfaceFocusNode =
      FocusNode(debugLabel: 'exo_player_tv_surface');
  final FocusNode _tvPlayPauseFocusNode =
      FocusNode(debugLabel: 'exo_player_tv_play_pause');

  VideoViewType _viewType = VideoViewType.platformView;

  // Subtitle options (EXO).
  double _subtitleDelaySeconds = 0.0;
  double _subtitleFontSize = 18.0;
  int _subtitlePositionStep = 5; // 0..20, maps to padding-bottom in 5px steps.
  bool _subtitleBold = false;
  String _subtitleText = '';
  bool _subtitlePollInFlight = false;

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
  bool _danmakuShowHeatmap = true;
  List<double> _danmakuHeatmap = const [];
  int _nextDanmakuIndex = 0;
  bool _danmakuPaused = false;

  static const Duration _controlsAutoHideDelay = Duration(seconds: 3);
  Timer? _controlsHideTimer;
  bool _controlsVisible = true;
  bool _isScrubbing = false;

  late final PlayerGestureController _gestureController;

  late final bool _fullScreen = widget.startFullScreen;

  bool get _isAndroid =>
      !kIsWeb && defaultTargetPlatform == TargetPlatform.android;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _gestureController = PlayerGestureController();
    _danmakuEnabled = widget.appState.danmakuEnabled;
    _danmakuOpacity = widget.appState.danmakuOpacity;
    _danmakuScale = widget.appState.danmakuScale;
    _danmakuSpeed = widget.appState.danmakuSpeed;
    _danmakuBold = widget.appState.danmakuBold;
    _danmakuMaxLines = widget.appState.danmakuMaxLines;
    _danmakuTopMaxLines = widget.appState.danmakuTopMaxLines;
    _danmakuBottomMaxLines = widget.appState.danmakuBottomMaxLines;
    _danmakuPreventOverlap = widget.appState.danmakuPreventOverlap;
    _danmakuShowHeatmap = widget.appState.danmakuShowHeatmap;

    final handoff = widget.appState.takeLocalPlaybackHandoff();
    if (handoff != null && handoff.playlist.isNotEmpty) {
      final files = handoff.playlist
          .where((e) => e.path.trim().isNotEmpty)
          .map(
            (e) => PlatformFile(
              name: e.name,
              size: e.size < 0 ? 0 : e.size,
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
        .map(
          (f) => LocalPlaybackItem(
            name: f.name,
            path: f.path!.trim(),
            size: f.size,
          ),
        )
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
    WidgetsBinding.instance.removeObserver(this);
    _controlsHideTimer?.cancel();
    _controlsHideTimer = null;
    _uiTimer?.cancel();
    _uiTimer = null;
    _gestureController.dispose();
    // ignore: unawaited_futures
    _exitOrientationLock();
    if (_fullScreen) {
      // ignore: unawaited_futures
      _exitImmersiveMode(resetOrientations: true);
    }
    // ignore: unawaited_futures
    _controller?.dispose();
    _controller = null;
    _tvSurfaceFocusNode.dispose();
    _tvPlayPauseFocusNode.dispose();
    super.dispose();
  }

  Future<void> _requestExitThenPop() async {
    if (_exitInProgress) return;
    _exitInProgress = true;

    _controlsHideTimer?.cancel();
    _controlsHideTimer = null;
    _uiTimer?.cancel();
    _uiTimer = null;
    _gestureController.hideOverlay(Duration.zero);

    final controller = _controller;
    _controller = null;
    if (mounted) {
      setState(() {
        _buffering = false;
        _controlsVisible = false;
        _isScrubbing = false;
      });
    }

    if (controller != null) {
      try {
        if (controller.value.isInitialized && controller.value.isPlaying) {
          await controller.pause();
        }
      } catch (_) {}
      try {
        await controller.dispose();
      } catch (_) {}
    }

    await _exitOrientationLock();
    if (_fullScreen) {
      await _exitImmersiveMode(resetOrientations: true);
    }

    try {
      await WidgetsBinding.instance.endOfFrame;
    } catch (_) {}

    if (!mounted) return;
    setState(() => _allowRoutePop = true);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      if (!Navigator.of(context).canPop()) return;
      Navigator.of(context).pop();
    });
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state != AppLifecycleState.inactive &&
        state != AppLifecycleState.paused) {
      return;
    }
    if (widget.appState.returnHomeBehavior != ReturnHomeBehavior.pause) return;

    final controller = _controller;
    if (controller == null) return;
    if (!controller.value.isInitialized) return;
    if (!controller.value.isPlaying) return;
    // ignore: unawaited_futures
    controller.pause();
    _applyDanmakuPauseState(true);
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

  void _rebuildDanmakuHeatmap() {
    if (!_danmakuShowHeatmap) {
      _danmakuHeatmap = const [];
      return;
    }
    if (_duration <= Duration.zero ||
        _danmakuSourceIndex < 0 ||
        _danmakuSourceIndex >= _danmakuSources.length) {
      _danmakuHeatmap = const [];
      return;
    }
    _danmakuHeatmap = buildDanmakuHeatmap(
      _danmakuSources[_danmakuSourceIndex].items,
      duration: _duration,
    );
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
        mergeRelated: appState.danmakuMergeRelated,
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
        _rebuildDanmakuHeatmap();
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
      _rebuildDanmakuHeatmap();
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
                                  _rebuildDanmakuHeatmap();
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
                            _danmakuHeatmap = const [];
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
    if (_fullScreen) {
      // ignore: unawaited_futures
      _exitImmersiveMode();
    }
    if (scheduleHide && !_remoteEnabled) {
      _scheduleControlsHide();
    } else {
      _controlsHideTimer?.cancel();
      _controlsHideTimer = null;
    }
  }

  void _toggleControls() {
    if (!_controlsVisible) {
      _showControls();
      return;
    }
    _controlsHideTimer?.cancel();
    _controlsHideTimer = null;
    setState(() => _controlsVisible = false);
    if (_fullScreen) {
      // ignore: unawaited_futures
      _enterImmersiveMode();
    }
    if (_remoteEnabled) _focusTvSurface();
  }

  void _focusTvSurface() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      FocusScope.of(context).requestFocus(_tvSurfaceFocusNode);
    });
  }

  void _focusTvPlayPause() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      if (!_controlsVisible) return;
      FocusScope.of(context).requestFocus(_tvPlayPauseFocusNode);
    });
  }

  void _hideControlsForRemote() {
    _controlsHideTimer?.cancel();
    _controlsHideTimer = null;
    if (_controlsVisible) {
      setState(() => _controlsVisible = false);
    }
    if (_fullScreen) {
      // ignore: unawaited_futures
      _enterImmersiveMode();
    }
    _focusTvSurface();
  }

  void _scheduleControlsHide() {
    _controlsHideTimer?.cancel();
    _controlsHideTimer = null;
    if (_remoteEnabled) return;
    if (!_controlsVisible || _isScrubbing) return;
    _controlsHideTimer = Timer(_controlsAutoHideDelay, () {
      if (!mounted || _isScrubbing || _remoteEnabled) return;
      setState(() => _controlsVisible = false);
      if (_fullScreen) {
        // ignore: unawaited_futures
        _enterImmersiveMode();
      }
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

  bool get _gesturesEnabled {
    final controller = _controller;
    return controller != null &&
        controller.value.isInitialized &&
        _playError == null;
  }

  int get _seekBackSeconds => widget.appState.seekBackwardSeconds;
  int get _seekForwardSeconds => widget.appState.seekForwardSeconds;

  Future<void> _togglePlayPause({bool showOverlay = true}) async {
    if (!_gesturesEnabled) return;
    final controller = _controller!;
    _showControls();
    if (controller.value.isPlaying) {
      await controller.pause();
      _applyDanmakuPauseState(true);
      if (showOverlay) {
        _gestureController.showOverlay(icon: Icons.pause, text: '暂停');
      }
      if (mounted) setState(() {});
      return;
    }
    await controller.play();
    _applyDanmakuPauseState(false);
    if (showOverlay) {
      _gestureController.showOverlay(icon: Icons.play_arrow, text: '播放');
    }
    if (mounted) setState(() {});
  }

  Future<void> _seekRelative(Duration delta, {bool showOverlay = true}) async {
    if (!_gesturesEnabled) return;
    final controller = _controller!;
    final duration = _duration;
    final current = _position;
    var target = current + delta;
    if (target < Duration.zero) target = Duration.zero;
    if (duration > Duration.zero && target > duration) target = duration;

    await controller.seekTo(target);
    _position = target;
    _syncDanmakuCursor(target);
    if (mounted) setState(() {});

    if (showOverlay) {
      final absSeconds = delta.inSeconds.abs();
      _gestureController.showOverlay(
        icon: delta.isNegative ? Icons.fast_rewind : Icons.fast_forward,
        text: '${delta.isNegative ? '快退' : '快进'} ${absSeconds}s',
      );
    }
  }

  Future<void> _seekTo(Duration pos) async {
    if (!_gesturesEnabled) return;
    final controller = _controller!;
    await controller.seekTo(pos);
    _position = pos;
    _syncDanmakuCursor(pos);
    if (mounted) setState(() {});
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

  double get _subtitleBottomPadding =>
      (_subtitlePositionStep.clamp(0, 20) * 5.0).clamp(0.0, 200.0).toDouble();

  Future<void> _applyExoSubtitleOptions() async {
    final controller = _controller;
    if (controller == null || !controller.value.isInitialized) return;

    // ignore: invalid_use_of_visible_for_testing_member
    final playerId = controller.playerId;

    final api = vp_android.VideoPlayerInstanceApi(
      messageChannelSuffix: playerId.toString(),
    );

    try {
      await api.setSubtitleDelay((_subtitleDelaySeconds * 1000).round());
    } catch (_) {}

    try {
      await api.setSubtitleStyle(
        vp_android.SubtitleStyleMessage(
          fontSize: _subtitleFontSize.clamp(8.0, 96.0),
          bottomPadding: _subtitleBottomPadding,
          bold: _subtitleBold,
        ),
      );
    } catch (_) {}
  }

  Future<void> _pollSubtitleText() async {
    if (_subtitlePollInFlight) return;
    final controller = _controller;
    if (controller == null || !controller.value.isInitialized) return;
    if (_isAndroid && _viewType != VideoViewType.textureView) return;

    _subtitlePollInFlight = true;
    try {
      // ignore: invalid_use_of_visible_for_testing_member
      final playerId = controller.playerId;
      final api = vp_android.VideoPlayerInstanceApi(
        messageChannelSuffix: playerId.toString(),
      );
      final text = await api.getSubtitleText();
      if (!mounted) return;
      if (text != _subtitleText) {
        setState(() => _subtitleText = text);
      }
    } catch (_) {
      // ignore
    } finally {
      _subtitlePollInFlight = false;
    }
  }

  Future<void> _showSubtitleTracks(BuildContext context) async {
    final controller = _controller;
    if (controller == null || !controller.value.isInitialized) return;

    // ignore: invalid_use_of_visible_for_testing_member
    final playerId = controller.playerId;

    final api = vp_android.VideoPlayerInstanceApi(
      messageChannelSuffix: playerId.toString(),
    );

    Future<List<vp_android.ExoPlayerSubtitleTrackData>> fetchTracks() async {
      final data = await api.getSubtitleTracks();
      return data.exoPlayerTracks ??
          const <vp_android.ExoPlayerSubtitleTrackData>[];
    }

    late List<vp_android.ExoPlayerSubtitleTrackData> tracks;
    try {
      tracks = await fetchTracks();
    } catch (e) {
      if (!context.mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('获取字幕失败：$e')),
      );
      return;
    }

    if (!context.mounted) return;
    showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      isScrollControlled: true,
      builder: (ctx) {
        var tracksExpanded = true;
        final messenger = ScaffoldMessenger.of(context);

        IconButton miniIconButton({
          required VoidCallback? onPressed,
          required IconData icon,
          String? tooltip,
        }) {
          return IconButton(
            onPressed: onPressed,
            tooltip: tooltip,
            icon: Icon(icon),
            padding: EdgeInsets.zero,
            visualDensity: VisualDensity.compact,
            constraints: const BoxConstraints.tightFor(width: 34, height: 34),
          );
        }

        return StatefulBuilder(
          builder: (context, setSheetState) {
            String selectedKey = 'off';
            for (final t in tracks) {
              if (t.isSelected) {
                selectedKey = '${t.groupIndex}_${t.trackIndex}';
                break;
              }
            }

            Future<void> refreshTracks() async {
              try {
                tracks = await fetchTracks();
                setSheetState(() {});
              } catch (e) {
                messenger.showSnackBar(
                  SnackBar(content: Text('获取字幕失败：$e')),
                );
              }
            }

            Future<void> selectTrackKey(String key) async {
              try {
                if (key == 'off') {
                  await api.deselectSubtitleTrack();
                } else {
                  final parts = key.split('_');
                  final g = int.parse(parts[0]);
                  final t = int.parse(parts[1]);
                  await api.selectSubtitleTrack(g, t);
                }
                await refreshTracks();
              } catch (e) {
                messenger.showSnackBar(
                  SnackBar(content: Text('切换字幕失败：$e')),
                );
              }
            }

            Future<void> pickAndAddSubtitle() async {
              final result = await FilePicker.platform.pickFiles(
                type: FileType.custom,
                allowedExtensions: const ['srt', 'ass', 'ssa', 'vtt', 'sub'],
              );
              if (result == null || result.files.isEmpty) return;
              final f = result.files.first;
              final path = (f.path ?? '').trim();
              if (path.isEmpty) {
                messenger.showSnackBar(
                  const SnackBar(content: Text('无法读取字幕文件路径')),
                );
                return;
              }
              try {
                await api.addSubtitleSource(path, null, null, f.name);
                await refreshTracks();
              } catch (e) {
                messenger.showSnackBar(
                  SnackBar(content: Text('添加字幕失败：$e')),
                );
              }
            }

            Future<void> editSubtitleDelay() async {
              final controller = TextEditingController(
                text: _subtitleDelaySeconds.toStringAsFixed(1),
              );
              final value = await showDialog<double>(
                context: ctx,
                builder: (dctx) => AlertDialog(
                  title: const Text('字幕同步'),
                  content: TextField(
                    controller: controller,
                    keyboardType: const TextInputType.numberWithOptions(
                      decimal: true,
                      signed: false,
                    ),
                    decoration: const InputDecoration(
                      hintText: '单位：秒，例如 0.5',
                    ),
                  ),
                  actions: [
                    TextButton(
                      onPressed: () => Navigator.of(dctx).pop(),
                      child: const Text('取消'),
                    ),
                    TextButton(
                      onPressed: () {
                        final v = double.tryParse(controller.text.trim());
                        Navigator.of(dctx).pop(v);
                      },
                      child: const Text('确定'),
                    ),
                  ],
                ),
              );
              if (value == null) return;
              setState(() => _subtitleDelaySeconds = value.clamp(0.0, 60.0));
              await _applyExoSubtitleOptions();
              setSheetState(() {});
            }

            return SafeArea(
              child: Padding(
                padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
                child: ListView(
                  children: [
                    Row(
                      children: [
                        Expanded(
                          child: Text(
                            '字幕',
                            style: Theme.of(context).textTheme.titleLarge,
                          ),
                        ),
                        IconButton(
                          tooltip: '关闭',
                          icon: const Icon(Icons.close),
                          onPressed: () => Navigator.of(ctx).pop(),
                        ),
                      ],
                    ),
                    ListTile(
                      contentPadding: EdgeInsets.zero,
                      leading: const Icon(Icons.closed_caption_outlined),
                      title: const Text('轨道'),
                      trailing: IconButton(
                        icon: Icon(
                          tracksExpanded
                              ? Icons.expand_less
                              : Icons.expand_more,
                        ),
                        onPressed: () {
                          tracksExpanded = !tracksExpanded;
                          setSheetState(() {});
                        },
                      ),
                    ),
                    if (tracksExpanded) ...[
                      RadioGroup<String>(
                        groupValue: selectedKey,
                        onChanged: (value) {
                          if (value == null) return;
                          // ignore: unawaited_futures
                          selectTrackKey(value);
                        },
                        child: Column(
                          children: [
                            const RadioListTile<String>(
                              value: 'off',
                              title: Text('关闭'),
                              contentPadding: EdgeInsets.zero,
                              dense: true,
                            ),
                            if (tracks.isEmpty)
                              const Padding(
                                padding: EdgeInsets.fromLTRB(40, 0, 0, 8),
                                child: Text('暂无字幕'),
                              ),
                            for (final t in tracks)
                              RadioListTile<String>(
                                value: '${t.groupIndex}_${t.trackIndex}',
                                title: Text(_subtitleTrackTitle(t)),
                                subtitle: Text(_subtitleTrackSubtitle(t)),
                                contentPadding: EdgeInsets.zero,
                                dense: true,
                              ),
                          ],
                        ),
                      ),
                      ListTile(
                        contentPadding: EdgeInsets.zero,
                        leading: const Icon(Icons.add),
                        title: const Text('添加字幕'),
                        onTap: pickAndAddSubtitle,
                      ),
                    ],
                    const Divider(height: 1),
                    ListTile(
                      contentPadding: EdgeInsets.zero,
                      title: const Text('字幕同步'),
                      trailing: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          miniIconButton(
                            onPressed: () async {
                              setState(() {
                                _subtitleDelaySeconds =
                                    (_subtitleDelaySeconds - 0.1)
                                        .clamp(0.0, 60.0)
                                        .toDouble();
                              });
                              await _applyExoSubtitleOptions();
                              setSheetState(() {});
                            },
                            icon: Icons.remove,
                            tooltip: '-0.1s',
                          ),
                          Text('${_subtitleDelaySeconds.toStringAsFixed(1)}s'),
                          miniIconButton(
                            onPressed: () async {
                              setState(() {
                                _subtitleDelaySeconds =
                                    (_subtitleDelaySeconds + 0.1)
                                        .clamp(0.0, 60.0)
                                        .toDouble();
                              });
                              await _applyExoSubtitleOptions();
                              setSheetState(() {});
                            },
                            icon: Icons.add,
                            tooltip: '+0.1s',
                          ),
                          const SizedBox(width: 6),
                          miniIconButton(
                            onPressed: editSubtitleDelay,
                            icon: Icons.edit_outlined,
                            tooltip: '输入',
                          ),
                          miniIconButton(
                            onPressed: () async {
                              setState(() => _subtitleDelaySeconds = 0.0);
                              await _applyExoSubtitleOptions();
                              setSheetState(() {});
                            },
                            icon: Icons.history,
                            tooltip: '重置',
                          ),
                        ],
                      ),
                    ),
                    ListTile(
                      contentPadding: EdgeInsets.zero,
                      title: const Text('字幕大小'),
                      subtitle: Slider(
                        value: _subtitleFontSize.clamp(12.0, 60.0),
                        min: 12.0,
                        max: 60.0,
                        divisions: 48,
                        onChanged: (v) {
                          setState(() => _subtitleFontSize = v);
                          setSheetState(() {});
                        },
                        onChangeEnd: (_) async {
                          await _applyExoSubtitleOptions();
                          setSheetState(() {});
                        },
                      ),
                      trailing: Text('${_subtitleFontSize.round()}'),
                    ),
                    ListTile(
                      contentPadding: EdgeInsets.zero,
                      title: const Text('字幕位置'),
                      subtitle: Slider(
                        value: _subtitlePositionStep.toDouble().clamp(0, 20),
                        min: 0,
                        max: 20,
                        divisions: 20,
                        onChanged: (v) {
                          setState(() => _subtitlePositionStep = v.round());
                          setSheetState(() {});
                        },
                        onChangeEnd: (_) async {
                          await _applyExoSubtitleOptions();
                          setSheetState(() {});
                        },
                      ),
                      trailing: Text('$_subtitlePositionStep'),
                    ),
                    SwitchListTile(
                      contentPadding: EdgeInsets.zero,
                      title: const Text('粗体'),
                      value: _subtitleBold,
                      onChanged: (v) async {
                        setState(() => _subtitleBold = v);
                        await _applyExoSubtitleOptions();
                        setSheetState(() {});
                      },
                    ),
                    const ListTile(
                      contentPadding: EdgeInsets.zero,
                      enabled: false,
                      title: Text('强制覆盖 ASS/SSA 字幕'),
                      subtitle: Text('仅 MPV 支持'),
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

  Future<void> _enterImmersiveMode() =>
      enterImmersiveMode(isTv: DeviceType.isTv);

  Future<void> _exitImmersiveMode({bool resetOrientations = false}) =>
      exitImmersiveMode(
        isTv: DeviceType.isTv,
        resetOrientations: resetOrientations,
      );

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
    if (!canControlSystemUi(isTv: DeviceType.isTv)) {
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
    if (!canControlSystemUi(isTv: DeviceType.isTv)) return;

    List<DeviceOrientation>? orientations;
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
        final controller = _controller;
        if (controller == null || !controller.value.isInitialized) return;
        var aspect = controller.value.aspectRatio;
        if (aspect <= 0) {
          final size = controller.value.size;
          if (size.width > 0 && size.height > 0) {
            aspect = size.width / size.height;
          }
        }
        if (aspect <= 0) return;
        orientations = aspect < 1.0
            ? const [DeviceOrientation.portraitUp]
            : const [
                DeviceOrientation.landscapeLeft,
                DeviceOrientation.landscapeRight,
              ];
        break;
    }

    final key = orientations.map((o) => o.name).join(',');
    if (_lastOrientationKey == key) return;
    _lastOrientationKey = key;
    try {
      await SystemChrome.setPreferredOrientations(orientations);
    } catch (_) {}
  }

  Future<void> _exitOrientationLock() async {
    if (!canControlSystemUi(isTv: DeviceType.isTv)) return;
    _lastOrientationKey = null;
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
      _lastBufferedEnd = Duration.zero;
      _lastBufferedAt = null;
      _bufferSpeedSampleEnd = Duration.zero;
      _bufferSpeedX = null;
      _position = Duration.zero;
      _duration = Duration.zero;
      _controlsVisible = true;
      _isScrubbing = false;
      _subtitleText = '';
      _subtitlePollInFlight = false;
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
        _danmakuShowHeatmap = widget.appState.danmakuShowHeatmap;
        _danmakuHeatmap = const [];
        _danmakuPaused = false;
      }
    });

    if (_fullScreen) {
      // ignore: unawaited_futures
      _enterImmersiveMode();
    }

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
      // Use platform view on Android to avoid color issues with some HDR/Dolby Vision sources.
      // (Texture-based rendering may show green/purple tint on certain P8 files.)
      final viewType = _isAndroid ? _viewType : VideoViewType.textureView;

      late final VideoPlayerController controller;
      if (uri == null || uri.scheme.isEmpty) {
        controller = VideoPlayerController.file(File(path), viewType: viewType);
      } else {
        final scheme = uri.scheme.toLowerCase();
        final isHttpUrl = (scheme == 'http' || scheme == 'https') &&
            uri.host.trim().isNotEmpty;
        if (isHttpUrl) {
          controller =
              VideoPlayerController.networkUrl(uri, viewType: viewType);
        } else if (scheme == 'content' && _isAndroid) {
          controller =
              VideoPlayerController.contentUri(uri, viewType: viewType);
        } else if (scheme == 'file') {
          controller = VideoPlayerController.file(
            File.fromUri(uri),
            viewType: viewType,
          );
        } else {
          // Fall back to networkUrl for other non-file URI schemes (e.g. rtsp).
          controller =
              VideoPlayerController.networkUrl(uri, viewType: viewType);
        }
      }
      _controller = controller;
      await controller.initialize();
      await _applyOrientationForMode();
      await _applyExoSubtitleOptions();
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
        final now = DateTime.now();
        _buffering = v.isBuffering;
        _position = v.position;
        _duration = v.duration;

        var bufferedEnd = Duration.zero;
        for (final r in v.buffered) {
          if (r.end > bufferedEnd) bufferedEnd = r.end;
        }
        _lastBufferedEnd = bufferedEnd;

        if (widget.appState.showBufferSpeed) {
          if (_buffering) {
            final refreshSeconds = widget.appState.bufferSpeedRefreshSeconds
                .clamp(0.2, 3.0)
                .toDouble();
            final refreshMs = (refreshSeconds * 1000).round();

            final prevAt = _lastBufferedAt;
            if (prevAt == null) {
              _bufferSpeedX = null;
              _lastBufferedAt = now;
              _bufferSpeedSampleEnd = bufferedEnd;
            } else {
              final dtMs = now.difference(prevAt).inMilliseconds;
              if (dtMs >= refreshMs) {
                final deltaMs =
                    (bufferedEnd - _bufferSpeedSampleEnd).inMilliseconds;
                _lastBufferedAt = now;
                _bufferSpeedSampleEnd = bufferedEnd;
                _bufferSpeedX =
                    (dtMs > 0 && deltaMs >= 0) ? (deltaMs / dtMs) : null;
              }
            }
          } else {
            _bufferSpeedX = null;
            _lastBufferedAt = null;
            _bufferSpeedSampleEnd = bufferedEnd;
          }
        } else {
          _bufferSpeedX = null;
          _lastBufferedAt = null;
        }

        _applyDanmakuPauseState(_buffering || !v.isPlaying);
        _drainDanmaku(_position);
        if (!_isAndroid || _viewType == VideoViewType.textureView) {
          // ignore: unawaited_futures
          _pollSubtitleText();
        }
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
    final isTv = DeviceType.isTv;

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

    final remoteEnabled = isTv || widget.appState.forceRemoteControlKeys;
    _remoteEnabled = remoteEnabled;

    Widget wrapVideo(Widget child) {
      if (_fullScreen) return Expanded(child: child);
      return AspectRatio(aspectRatio: 16 / 9, child: child);
    }

    final canPopRoute = Navigator.of(context).canPop();
    final needsSafeExit = canPopRoute &&
        !_allowRoutePop &&
        controller != null &&
        _viewType == VideoViewType.platformView;

    return PopScope(
      canPop: !needsSafeExit,
      onPopInvokedWithResult: (didPop, result) {
        if (didPop || !needsSafeExit) return;
        unawaited(_requestExitThenPop());
      },
      child: Focus(
        focusNode: _tvSurfaceFocusNode,
        autofocus: remoteEnabled,
        canRequestFocus: remoteEnabled,
        skipTraversal: true,
        onKeyEvent: (node, event) {
          if (!remoteEnabled) return KeyEventResult.ignored;
          if (!node.hasPrimaryFocus) return KeyEventResult.ignored;
          if (event is! KeyDownEvent) return KeyEventResult.ignored;

          final key = event.logicalKey;
          if (key == LogicalKeyboardKey.arrowUp) {
            _showControls(scheduleHide: false);
            _focusTvPlayPause();
            return KeyEventResult.handled;
          }
          if (key == LogicalKeyboardKey.arrowDown) {
            if (_controlsVisible) {
              _hideControlsForRemote();
              return KeyEventResult.handled;
            }
            return KeyEventResult.ignored;
          }

          if (!controlsEnabled) return KeyEventResult.ignored;

          if (key == LogicalKeyboardKey.space ||
              key == LogicalKeyboardKey.enter ||
              key == LogicalKeyboardKey.select) {
            // ignore: unawaited_futures
            _togglePlayPause();
            return KeyEventResult.handled;
          }
          if (key == LogicalKeyboardKey.arrowLeft) {
            // ignore: unawaited_futures
            _seekRelative(Duration(seconds: -_seekBackSeconds));
            return KeyEventResult.handled;
          }
          if (key == LogicalKeyboardKey.arrowRight) {
            // ignore: unawaited_futures
            _seekRelative(Duration(seconds: _seekForwardSeconds));
            return KeyEventResult.handled;
          }
          return KeyEventResult.ignored;
        },
        child: Scaffold(
          backgroundColor: Colors.black,
          extendBodyBehindAppBar: _fullScreen,
          appBar: PreferredSize(
            preferredSize: _fullScreen
                ? (_controlsVisible
                    ? const Size.fromHeight(kToolbarHeight)
                    : Size.zero)
                : const Size.fromHeight(kToolbarHeight),
            child: AnimatedOpacity(
              opacity: (!_fullScreen || _controlsVisible) ? 1 : 0,
              duration: const Duration(milliseconds: 200),
              child: IgnorePointer(
                ignoring: _fullScreen && !_controlsVisible,
                child: SafeArea(
                  top: false,
                  bottom: false,
                  child: GlassAppBar(
                    enableBlur: false,
                    child: AppBar(
                      backgroundColor: _fullScreen ? Colors.transparent : null,
                      foregroundColor: _fullScreen ? Colors.white : null,
                      elevation: _fullScreen ? 0 : null,
                      scrolledUnderElevation: _fullScreen ? 0 : null,
                      shadowColor: _fullScreen ? Colors.transparent : null,
                      surfaceTintColor: _fullScreen ? Colors.transparent : null,
                      forceMaterialTransparency: _fullScreen,
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
                ),
              ),
            ),
          ),
          body: Column(
            children: [
              wrapVideo(
                Container(
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
                                timeScale: controller.value.playbackSpeed,
                                bold: _danmakuBold,
                                scrollMaxLines: _danmakuMaxLines,
                                topMaxLines: _danmakuTopMaxLines,
                                bottomMaxLines: _danmakuBottomMaxLines,
                                preventOverlap: _danmakuPreventOverlap,
                              ),
                            ),
                            if ((!_isAndroid ||
                                    _viewType == VideoViewType.textureView) &&
                                _subtitleText.trim().isNotEmpty)
                              Positioned.fill(
                                child: IgnorePointer(
                                  child: Align(
                                    alignment: Alignment.bottomCenter,
                                    child: Padding(
                                      padding: EdgeInsets.fromLTRB(
                                        16,
                                        0,
                                        16,
                                        _subtitleBottomPadding,
                                      ),
                                      child: DecoratedBox(
                                        decoration: BoxDecoration(
                                          color: Colors.black.withValues(
                                            alpha: 0.55,
                                          ),
                                          borderRadius:
                                              BorderRadius.circular(6),
                                        ),
                                        child: Padding(
                                          padding: const EdgeInsets.symmetric(
                                            horizontal: 8,
                                            vertical: 4,
                                          ),
                                          child: Text(
                                            _subtitleText.trim(),
                                            textAlign: TextAlign.center,
                                            style: TextStyle(
                                              height: 1.4,
                                              fontSize: _subtitleFontSize.clamp(
                                                12.0,
                                                60.0,
                                              ),
                                              fontWeight: _subtitleBold
                                                  ? FontWeight.w600
                                                  : FontWeight.normal,
                                              color: Colors.white,
                                              shadows: const [
                                                Shadow(
                                                  blurRadius: 6,
                                                  offset: Offset(2, 2),
                                                  color: Colors.black,
                                                ),
                                              ],
                                            ),
                                          ),
                                        ),
                                      ),
                                    ),
                                  ),
                                ),
                              ),
                            Positioned.fill(
                              child: IgnorePointer(
                                child: AnimatedBuilder(
                                  animation: _gestureController,
                                  builder: (context, _) {
                                    final alpha = (1.0 -
                                            _gestureController.brightness)
                                        .clamp(0.0, 0.8)
                                        .toDouble();
                                    if (alpha <= 0) {
                                      return const SizedBox.expand();
                                    }
                                    return ColoredBox(
                                      color:
                                          Colors.black.withValues(alpha: alpha),
                                    );
                                  },
                                ),
                              ),
                            ),
                            if (_buffering)
                              Positioned.fill(
                                child: ColoredBox(
                                  color: Colors.black54,
                                  child: Center(
                                    child: Column(
                                      mainAxisSize: MainAxisSize.min,
                                      children: [
                                        const CircularProgressIndicator(),
                                        if (widget.appState.showBufferSpeed)
                                          Padding(
                                            padding:
                                                const EdgeInsets.only(top: 12),
                                            child: Text(
                                              _bufferSpeedX == null
                                                  ? '缓冲速度：—'
                                                  : '缓冲速度：${_bufferSpeedX!.clamp(0.0, 99.0).toStringAsFixed(1)}x',
                                              style: const TextStyle(
                                                color: Colors.white,
                                              ),
                                            ),
                                          ),
                                      ],
                                    ),
                                  ),
                                ),
                              ),
                            if (_playError != null)
                              Center(
                                child: Text(
                                  '播放失败：$_playError',
                                  style:
                                      const TextStyle(color: Colors.redAccent),
                                  textAlign: TextAlign.center,
                                ),
                              ),
                            Positioned.fill(
                              child: PlayerGestureDetectorLayer(
                                controller: _gestureController,
                                enabled: controlsEnabled,
                                position: _position,
                                duration: _duration,
                                onToggleControls: _toggleControls,
                                onTogglePlayPause: () => _togglePlayPause(),
                                onSeekRelative: (d) => _seekRelative(d),
                                onSeekTo: _seekTo,
                                doubleTapLeft: widget.appState.doubleTapLeft,
                                doubleTapCenter: widget.appState.doubleTapCenter,
                                doubleTapRight: widget.appState.doubleTapRight,
                                seekBackwardSeconds: _seekBackSeconds,
                                seekForwardSeconds: _seekForwardSeconds,
                                gestureSeekEnabled: widget.appState.gestureSeek,
                                gestureBrightnessEnabled:
                                    widget.appState.gestureBrightness,
                                gestureVolumeEnabled: widget.appState.gestureVolume,
                                gestureLongPressEnabled:
                                    widget.appState.gestureLongPressSpeed,
                                longPressSlideEnabled:
                                    widget.appState.longPressSlideSpeed,
                                longPressSpeedMultiplier:
                                    widget.appState.longPressSpeedMultiplier,
                                getPlaybackRate: controlsEnabled
                                    ? () => controller.value.playbackSpeed
                                    : null,
                                onSetPlaybackRate: controlsEnabled
                                    ? (rate) async {
                                        await controller.setPlaybackSpeed(rate);
                                        if (mounted) setState(() {});
                                      }
                                    : null,
                                onSetVolume: controlsEnabled
                                    ? (volume) => controller.setVolume(volume)
                                    : null,
                                clampSeekTarget: (target, duration) =>
                                    safeSeekTarget(
                                      target,
                                      duration,
                                      rewind: Duration.zero,
                                    ),
                                onShowControls: _showControls,
                                onScheduleControlsHide: _scheduleControlsHide,
                              ),
                            ),
                            Align(
                              alignment: Alignment.bottomCenter,
                              child: SafeArea(
                                top: false,
                                minimum:
                                    const EdgeInsets.fromLTRB(12, 0, 12, 12),
                                child: AnimatedOpacity(
                                  opacity: _controlsVisible ? 1 : 0,
                                  duration: const Duration(milliseconds: 200),
                                  child: IgnorePointer(
                                    ignoring: !_controlsVisible,
                                    child: Listener(
                                      onPointerDown: (_) => _showControls(),
                                      child: Focus(
                                        canRequestFocus: false,
                                        onKeyEvent: (node, event) {
                                          if (!_remoteEnabled) {
                                            return KeyEventResult.ignored;
                                          }
                                          if (event is! KeyDownEvent) {
                                            return KeyEventResult.ignored;
                                          }
                                          if (event.logicalKey ==
                                              LogicalKeyboardKey.arrowDown) {
                                            final moved = FocusScope.of(context)
                                                .focusInDirection(
                                              TraversalDirection.down,
                                            );
                                            if (moved) {
                                              return KeyEventResult.handled;
                                            }
                                            _hideControlsForRemote();
                                            return KeyEventResult.handled;
                                          }
                                          return KeyEventResult.ignored;
                                        },
                                        child: PlaybackControls(
                                          enabled: controlsEnabled,
                                          playPauseFocusNode:
                                              _tvPlayPauseFocusNode,
                                          position: _position,
                                          buffered: _lastBufferedEnd,
                                          duration: _duration,
                                          isPlaying: controller.value.isPlaying,
                                          playbackRate:
                                              controller.value.playbackSpeed,
                                          onSetPlaybackRate: (rate) async {
                                            _showControls();
                                            await controller.setPlaybackSpeed(
                                              rate,
                                            );
                                            if (mounted) setState(() {});
                                          },
                                          heatmap: _danmakuHeatmap,
                                          showHeatmap: _danmakuShowHeatmap &&
                                              _danmakuHeatmap.isNotEmpty,
                                          seekBackwardSeconds: _seekBackSeconds,
                                          seekForwardSeconds:
                                              _seekForwardSeconds,
                                          showSystemTime: widget.appState
                                              .showSystemTimeInControls,
                                          showBattery: widget
                                              .appState.showBatteryInControls,
                                          showBufferSpeed:
                                              widget.appState.showBufferSpeed,
                                          buffering: _buffering,
                                          bufferSpeedX: _bufferSpeedX,
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
                                                Duration(
                                                  seconds: _seekBackSeconds,
                                                );
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
                                                Duration(
                                                  seconds: _seekForwardSeconds,
                                                );
                                            final pos = (d > Duration.zero &&
                                                    target > d)
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
              if (!_fullScreen) const SizedBox(height: 8),
              if (!_fullScreen)
                const Padding(
                  padding: EdgeInsets.all(8.0),
                  child: Text(
                    '播放列表',
                    style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
                  ),
                ),
              if (!_fullScreen)
                Expanded(
                  child: ListView.builder(
                    itemCount: _playlist.length,
                    itemBuilder: (context, index) {
                      final file = _playlist[index];
                      final isPlaying = index == _currentIndex;
                      return ListTile(
                        leading: Icon(
                            isPlaying ? Icons.play_circle_filled : Icons.movie),
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
        ),
      ),
    );
  }
}

typedef _OrientationMode = OrientationMode;
