import 'dart:async';
import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:video_player/video_player.dart';
import 'package:video_player_android/exo_tracks.dart' as vp_android;
import 'package:video_player_platform_interface/video_player_platform_interface.dart';

import 'play_network_page.dart';
import 'services/dandanplay_api.dart';
import 'services/emby_api.dart';
import 'state/app_state.dart';
import 'state/danmaku_preferences.dart';
import 'state/preferences.dart';
import 'src/player/danmaku.dart';
import 'src/player/danmaku_processing.dart';
import 'src/player/danmaku_stage.dart';
import 'src/player/playback_controls.dart';
import 'src/ui/glass_blur.dart';

class ExoPlayNetworkPage extends StatefulWidget {
  const ExoPlayNetworkPage({
    super.key,
    required this.title,
    required this.itemId,
    required this.appState,
    this.isTv = false,
    this.startPosition,
    this.resumeImmediately = false,
    this.mediaSourceId,
    this.audioStreamIndex,
    this.subtitleStreamIndex,
  });

  final String title;
  final String itemId;
  final AppState appState;
  final bool isTv;
  final Duration? startPosition;
  final bool resumeImmediately;
  final String? mediaSourceId;
  final int? audioStreamIndex;
  final int? subtitleStreamIndex; // Emby MediaStream Index, -1 = off

  @override
  State<ExoPlayNetworkPage> createState() => _ExoPlayNetworkPageState();
}

class _ExoPlayNetworkPageState extends State<ExoPlayNetworkPage> {
  EmbyApi? _embyApi;
  VideoPlayerController? _controller;
  Timer? _uiTimer;

  bool _loading = true;
  String? _playError;
  String? _resolvedStream;
  bool _buffering = false;
  Duration _position = Duration.zero;
  Duration _duration = Duration.zero;
  DateTime? _lastUiTickAt;
  _OrientationMode _orientationMode = _OrientationMode.auto;
  Duration? _resumeHintPosition;
  bool _showResumeHint = false;
  Timer? _resumeHintTimer;
  bool _deferProgressReporting = false;

  static const Duration _controlsAutoHideDelay = Duration(seconds: 3);
  Timer? _controlsHideTimer;
  bool _controlsVisible = true;
  bool _isScrubbing = false;

  VideoViewType _viewType = VideoViewType.platformView;
  bool _switchingViewType = false;

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

  String? _playSessionId;
  String? _mediaSourceId;
  List<Map<String, dynamic>> _availableMediaSources = const [];
  String? _selectedMediaSourceId;
  int? _selectedAudioStreamIndex;
  int? _selectedSubtitleStreamIndex;
  Duration? _overrideStartPosition;
  bool _overrideResumeImmediately = false;
  DateTime? _lastProgressReportAt;
  bool _lastProgressReportPaused = false;
  bool _reportedStart = false;
  bool _reportedStop = false;
  bool _progressReportInFlight = false;

  bool get _isAndroid =>
      !kIsWeb && defaultTargetPlatform == TargetPlatform.android;

  bool get _isPlaying => _controller?.value.isPlaying ?? false;

  @override
  void initState() {
    super.initState();
    final baseUrl = widget.appState.baseUrl;
    if (baseUrl != null && baseUrl.trim().isNotEmpty) {
      _embyApi = EmbyApi(hostOrUrl: baseUrl, preferredScheme: 'https');
    }
    _danmakuEnabled = widget.appState.danmakuEnabled;
    _danmakuOpacity = widget.appState.danmakuOpacity;
    _danmakuScale = widget.appState.danmakuScale;
    _danmakuSpeed = widget.appState.danmakuSpeed;
    _danmakuBold = widget.appState.danmakuBold;
    _danmakuMaxLines = widget.appState.danmakuMaxLines;
    _danmakuTopMaxLines = widget.appState.danmakuTopMaxLines;
    _danmakuBottomMaxLines = widget.appState.danmakuBottomMaxLines;
    _danmakuPreventOverlap = widget.appState.danmakuPreventOverlap;
    _selectedMediaSourceId = widget.mediaSourceId;
    _selectedAudioStreamIndex = widget.audioStreamIndex;
    _selectedSubtitleStreamIndex = widget.subtitleStreamIndex;
    // ignore: unawaited_futures
    _enterImmersiveMode();
    _init();
  }

  @override
  void dispose() {
    _controlsHideTimer?.cancel();
    _controlsHideTimer = null;
    _uiTimer?.cancel();
    _uiTimer = null;
    _resumeHintTimer?.cancel();
    _resumeHintTimer = null;
    // ignore: unawaited_futures
    _reportPlaybackStoppedBestEffort();
    // ignore: unawaited_futures
    _exitImmersiveMode();
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

  String _buildDanmakuMatchName(MediaItem item) {
    final seriesName = item.seriesName.trim();
    final name = item.name.trim();
    final season = item.seasonNumber ?? 0;
    final episode = item.episodeNumber ?? 0;

    final base = seriesName.isNotEmpty
        ? seriesName
        : (name.isNotEmpty ? name : widget.title);
    final extra = (name.isNotEmpty && name != base) ? ' $name' : '';

    if (season > 0 && episode > 0) {
      final s = season.toString().padLeft(2, '0');
      final e = episode.toString().padLeft(2, '0');
      return '$base S${s}E$e$extra'.trim();
    }
    if (episode > 0) {
      final e = episode.toString().padLeft(2, '0');
      return '$base EP$e$extra'.trim();
    }
    if (seriesName.isNotEmpty && name.isNotEmpty && name != seriesName) {
      return '$seriesName $name'.trim();
    }
    return widget.title;
  }

  void _maybeAutoLoadOnlineDanmaku() {
    final appState = widget.appState;
    if (!appState.danmakuEnabled) return;
    if (appState.danmakuLoadMode != DanmakuLoadMode.online) return;
    if (kIsWeb) return;
    // ignore: unawaited_futures
    _loadOnlineDanmakuForNetwork(showToast: false);
  }

  Future<void> _loadOnlineDanmakuForNetwork({bool showToast = true}) async {
    final appState = widget.appState;
    if (appState.danmakuApiUrls.isEmpty) {
      if (showToast && mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('请先在设置-弹幕中添加在线弹幕源')),
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

    var fileName = widget.title;
    int fileSizeBytes = 0;
    int videoDurationSeconds = 0;
    try {
      final api = _embyApi ??
          EmbyApi(hostOrUrl: appState.baseUrl!, preferredScheme: 'https');
      final item = await api.fetchItemDetail(
        token: appState.token!,
        baseUrl: appState.baseUrl!,
        userId: appState.userId!,
        itemId: widget.itemId,
      );
      fileName = _buildDanmakuMatchName(item);
      fileSizeBytes = item.sizeBytes ?? 0;
      final ticks = item.runTimeTicks ?? 0;
      if (ticks > 0) {
        videoDurationSeconds = (ticks / 10000000).round().clamp(0, 1 << 31);
      }
    } catch (_) {}

    if (videoDurationSeconds <= 0) {
      videoDurationSeconds = _duration.inSeconds;
    }

    try {
      final sources = await loadOnlineDanmakuSources(
        apiUrls: appState.danmakuApiUrls,
        fileName: fileName,
        fileHash: null,
        fileSizeBytes: fileSizeBytes,
        videoDurationSeconds: videoDurationSeconds,
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

  Map<String, String> _embyHeaders() => {
        'X-Emby-Token': widget.appState.token!,
        'X-Emby-Authorization':
            'MediaBrowser Client="LinPlayer", Device="Flutter", DeviceId="${widget.appState.deviceId}", Version="1.0.0"',
      };

  Future<void> _ensureDanmakuVisible() async {
    if (!_isAndroid) return;
    if (_viewType == VideoViewType.textureView) return;
    if (_switchingViewType) return;

    final stream = _resolvedStream;
    if (stream == null || stream.trim().isEmpty) {
      setState(() => _viewType = VideoViewType.textureView);
      return;
    }

    _switchingViewType = true;
    try {
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
      await _reopenStreamWithViewType(VideoViewType.textureView);
    } finally {
      _switchingViewType = false;
    }
  }

  Future<void> _reopenStreamWithViewType(VideoViewType next) async {
    if (!_isAndroid) return;
    final stream = _resolvedStream;
    if (stream == null || stream.trim().isEmpty) return;
    if (_viewType == next && _controller != null) return;

    final wasPlaying = _isPlaying;
    final pos = _position;

    _uiTimer?.cancel();
    _uiTimer = null;

    final prev = _controller;
    _controller = null;
    if (prev != null) {
      await prev.dispose();
    }

    setState(() {
      _viewType = next;
      _buffering = false;
      _playError = null;
    });

    final controller = VideoPlayerController.networkUrl(
      Uri.parse(stream),
      httpHeaders: _embyHeaders(),
      viewType: next,
    );
    _controller = controller;
    await controller.initialize();

    final target = _safeSeekTarget(pos, controller.value.duration);
    if (target > Duration.zero) {
      try {
        await controller.seekTo(target).timeout(const Duration(seconds: 3));
        _position = target;
        _syncDanmakuCursor(target);
      } catch (_) {}
    }

    if (wasPlaying) {
      await controller.play();
    } else {
      await controller.pause();
    }

    _uiTimer = Timer.periodic(const Duration(milliseconds: 250), (_) {
      final c = _controller;
      if (!mounted || c == null) return;
      final v = c.value;
      _buffering = v.isBuffering;
      _position = v.position;
      _duration = v.duration;

      _applyDanmakuPauseState(_buffering || !_isPlaying);
      _drainDanmaku(_position);

      _maybeReportPlaybackProgress(_position);

      if (!_reportedStop &&
          _duration > Duration.zero &&
          !_buffering &&
          !v.isPlaying &&
          _position >= _duration - const Duration(milliseconds: 200)) {
        // ignore: unawaited_futures
        _reportPlaybackStoppedBestEffort(completed: true);
      }

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
                        onPressed: onlineLoading || _loading
                            ? null
                            : () async {
                                onlineLoading = true;
                                setSheetState(() {});
                                try {
                                  await _loadOnlineDanmakuForNetwork(
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

  Future<void> _switchCore() async {
    final pos = _position;
    _maybeReportPlaybackProgress(pos, force: true);
    await widget.appState.setPlayerCore(PlayerCore.mpv);
    if (!mounted) return;
    Navigator.of(context).pushReplacement(
      MaterialPageRoute(
        builder: (_) => PlayNetworkPage(
          title: widget.title,
          itemId: widget.itemId,
          appState: widget.appState,
          isTv: widget.isTv,
          startPosition: pos,
          resumeImmediately: true,
          mediaSourceId:
              _selectedMediaSourceId ?? _mediaSourceId ?? widget.mediaSourceId,
          audioStreamIndex: _selectedAudioStreamIndex,
          subtitleStreamIndex: _selectedSubtitleStreamIndex,
        ),
      ),
    );
  }

  Future<void> _switchVersion() async {
    final pos = _position;
    _maybeReportPlaybackProgress(pos, force: true);

    var sources = _availableMediaSources;
    if (sources.isEmpty) {
      try {
        final base = widget.appState.baseUrl!;
        final token = widget.appState.token!;
        final userId = widget.appState.userId!;
        final api = _embyApi ??
            EmbyApi(
                hostOrUrl: widget.appState.baseUrl!, preferredScheme: 'https');
        final info = await api.fetchPlaybackInfo(
          token: token,
          baseUrl: base,
          userId: userId,
          deviceId: widget.appState.deviceId,
          itemId: widget.itemId,
        );
        sources = info.mediaSources.cast<Map<String, dynamic>>();
        _availableMediaSources = List<Map<String, dynamic>>.from(sources);
      } catch (_) {
        sources = const [];
      }
    }

    if (sources.isEmpty) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('无法获取版本列表')),
      );
      return;
    }

    final current = _mediaSourceId ?? _selectedMediaSourceId ?? '';
    if (!mounted) return;
    final selected = await showModalBottomSheet<String>(
      context: context,
      builder: (ctx) {
        return SafeArea(
          child: ListView(
            children: [
              const ListTile(title: Text('版本选择')),
              for (final ms in sources)
                ListTile(
                  leading: Icon(
                    (ms['Id']?.toString() ?? '') == current
                        ? Icons.check_circle
                        : Icons.circle_outlined,
                  ),
                  title: Text(_mediaSourceTitle(ms)),
                  subtitle: Text(_mediaSourceSubtitle(ms)),
                  onTap: () =>
                      Navigator.of(ctx).pop(ms['Id']?.toString() ?? ''),
                ),
            ],
          ),
        );
      },
    );

    if (!mounted) return;
    if (selected == null || selected.trim().isEmpty) return;
    if (selected.trim() == current) return;

    setState(() {
      _selectedMediaSourceId = selected.trim();
      _selectedAudioStreamIndex = null;
      _selectedSubtitleStreamIndex = null;
      _overrideStartPosition = pos;
      _overrideResumeImmediately = true;
    });
    await _init();
  }

  Future<void> _init() async {
    _uiTimer?.cancel();
    _uiTimer = null;
    _playError = null;
    _loading = true;
    _nextDanmakuIndex = 0;
    _danmakuKey.currentState?.clear();
    _danmakuSources.clear();
    _danmakuSourceIndex = -1;
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

    _reportedStart = false;
    _reportedStop = false;
    _progressReportInFlight = false;
    _lastProgressReportAt = null;
    _lastProgressReportPaused = false;

    _playSessionId = null;
    _mediaSourceId = null;
    _resolvedStream = null;
    _resumeHintTimer?.cancel();
    _resumeHintTimer = null;
    _resumeHintPosition = null;
    _showResumeHint = false;
    _deferProgressReporting = false;
    _controlsVisible = true;
    _isScrubbing = false;
    _controlsHideTimer?.cancel();
    _controlsHideTimer = null;

    final prev = _controller;
    _controller = null;
    if (prev != null) {
      await prev.dispose();
    }

    if (!mounted) return;
    setState(() {});

    try {
      if (!_isAndroid) {
        throw Exception('Exo 内核仅支持 Android');
      }
      final streamUrl = await _buildStreamUrl();
      _resolvedStream = streamUrl;
      final controller = VideoPlayerController.networkUrl(
        Uri.parse(streamUrl),
        httpHeaders: _embyHeaders(),
        // Use platform view on Android to avoid color issues with some HDR/Dolby Vision sources.
        // (Texture-based rendering may show green/purple tint on certain P8 files.)
        viewType: _viewType,
      );
      _controller = controller;
      await controller.initialize();
      final start = _overrideStartPosition ?? widget.startPosition;
      final resumeImmediately =
          _overrideResumeImmediately || widget.resumeImmediately;
      _overrideStartPosition = null;
      _overrideResumeImmediately = false;
      if (start != null && start > Duration.zero) {
        final target = _safeSeekTarget(start, controller.value.duration);
        if (resumeImmediately) {
          await controller.seekTo(target);
          _position = target;
        } else {
          _resumeHintPosition = target;
          _showResumeHint = true;
          _deferProgressReporting = true;
        }
      }
      await controller.play();

      _uiTimer = Timer.periodic(const Duration(milliseconds: 250), (_) {
        final c = _controller;
        if (!mounted || c == null) return;
        final v = c.value;
        _buffering = v.isBuffering;
        _position = v.position;
        _duration = v.duration;

        _applyDanmakuPauseState(_buffering || !_isPlaying);
        _drainDanmaku(_position);

        _maybeReportPlaybackProgress(_position);

        if (!_reportedStop &&
            _duration > Duration.zero &&
            !_buffering &&
            !v.isPlaying &&
            _position >= _duration - const Duration(milliseconds: 200)) {
          // ignore: unawaited_futures
          _reportPlaybackStoppedBestEffort(completed: true);
        }

        final now = DateTime.now();
        final shouldRebuild = _lastUiTickAt == null ||
            now.difference(_lastUiTickAt!) >= const Duration(milliseconds: 250);
        if (shouldRebuild) {
          _lastUiTickAt = now;
          setState(() {});
        }
      });

      _maybeAutoLoadOnlineDanmaku();

      if (!_deferProgressReporting) {
        // ignore: unawaited_futures
        _reportPlaybackStartBestEffort();
      }
    } catch (e) {
      _playError = e.toString();
      _resumeHintPosition = null;
      _showResumeHint = false;
      _deferProgressReporting = false;
    } finally {
      if (mounted) {
        setState(() => _loading = false);
        if (_showResumeHint && _resumeHintPosition != null) {
          _startResumeHintTimer();
        }
        _scheduleControlsHide();
      }
    }
  }

  Future<String> _buildStreamUrl() async {
    final base = widget.appState.baseUrl!;
    final token = widget.appState.token!;
    final userId = widget.appState.userId!;
    _playSessionId = null;
    _mediaSourceId = null;

    String applyQueryPrefs(String url) {
      final uri = Uri.parse(url);
      final params = Map<String, String>.from(uri.queryParameters);
      if (!params.containsKey('api_key')) params['api_key'] = token;
      if (_selectedAudioStreamIndex != null) {
        params['AudioStreamIndex'] = _selectedAudioStreamIndex.toString();
      }
      if (_selectedSubtitleStreamIndex != null &&
          _selectedSubtitleStreamIndex! >= 0) {
        params['SubtitleStreamIndex'] = _selectedSubtitleStreamIndex.toString();
      }
      return uri.replace(queryParameters: params).toString();
    }

    String resolve(String candidate) {
      final resolved = Uri.parse(base).resolve(candidate).toString();
      return applyQueryPrefs(resolved);
    }

    try {
      final api = _embyApi ??
          EmbyApi(
              hostOrUrl: widget.appState.baseUrl!, preferredScheme: 'https');
      final info = await api.fetchPlaybackInfo(
        token: token,
        baseUrl: base,
        userId: userId,
        deviceId: widget.appState.deviceId,
        itemId: widget.itemId,
      );
      final sources = info.mediaSources.cast<Map<String, dynamic>>();
      _availableMediaSources = List<Map<String, dynamic>>.from(sources);
      Map<String, dynamic>? ms;
      if (sources.isNotEmpty) {
        final selectedId = _selectedMediaSourceId;
        if (selectedId != null && selectedId.isNotEmpty) {
          ms = sources.firstWhere(
            (s) => (s['Id'] as String? ?? '') == selectedId,
            orElse: () => sources.first,
          );
        } else {
          ms = sources.first;
        }
      }
      _playSessionId = info.playSessionId;
      _mediaSourceId = (ms?['Id'] as String?) ?? info.mediaSourceId;
      final directStreamUrl = ms?['DirectStreamUrl'] as String?;
      if (directStreamUrl != null && directStreamUrl.isNotEmpty) {
        return resolve(directStreamUrl);
      }
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
    }
  }

  int _toTicks(Duration d) => d.inMicroseconds * 10;

  static String _fmtClock(Duration d) {
    String two(int v) => v.toString().padLeft(2, '0');
    final h = d.inHours;
    final m = d.inMinutes.remainder(60);
    final s = d.inSeconds.remainder(60);
    return h > 0 ? '${two(h)}:${two(m)}:${two(s)}' : '${two(m)}:${two(s)}';
  }

  static int? _asInt(dynamic value) {
    if (value is int) return value;
    if (value is num) return value.toInt();
    if (value is String) return int.tryParse(value);
    return null;
  }

  static List<Map<String, dynamic>> _streamsOfType(
      Map<String, dynamic> ms, String type) {
    final streams = (ms['MediaStreams'] as List?) ?? const [];
    return streams
        .where((e) => (e as Map)['Type'] == type)
        .map((e) => e as Map<String, dynamic>)
        .toList();
  }

  static String _mediaSourceTitle(Map<String, dynamic> ms) {
    return (ms['Name'] as String?) ?? (ms['Container'] as String?) ?? '默认版本';
  }

  static String _mediaSourceSubtitle(Map<String, dynamic> ms) {
    final size = ms['Size'];
    final sizeGb =
        size is num ? (size / (1024 * 1024 * 1024)).toStringAsFixed(1) : null;
    final bitrate = _asInt(ms['Bitrate']);
    final bitrateMbps =
        bitrate != null ? (bitrate / 1000000).toStringAsFixed(1) : null;

    final videoStreams = _streamsOfType(ms, 'Video');
    final video = videoStreams.isNotEmpty ? videoStreams.first : null;
    final height = _asInt(video?['Height']);
    final vCodec =
        (ms['VideoCodec'] as String?) ?? (video?['Codec'] as String?);

    final parts = <String>[];
    if (height != null) parts.add('${height}p');
    if (vCodec != null && vCodec.isNotEmpty) parts.add(vCodec.toUpperCase());
    if (sizeGb != null) parts.add('$sizeGb GB');
    if (bitrateMbps != null) parts.add('$bitrateMbps Mbps');
    return parts.isEmpty ? '直连播放' : parts.join(' / ');
  }

  Duration _safeSeekTarget(Duration target, Duration total) {
    if (target <= Duration.zero) return Duration.zero;
    if (total <= Duration.zero) return target;
    if (target < total) return target;
    final rewind = total - const Duration(seconds: 5);
    return rewind > Duration.zero ? rewind : Duration.zero;
  }

  void _startResumeHintTimer() {
    _resumeHintTimer?.cancel();
    _resumeHintTimer = Timer(const Duration(seconds: 5), () {
      if (!mounted) return;
      if (!_showResumeHint) return;
      _showResumeHint = false;
      final shouldStartReporting = _deferProgressReporting;
      _deferProgressReporting = false;
      if (shouldStartReporting) {
        // ignore: unawaited_futures
        _reportPlaybackStartBestEffort();
        _maybeReportPlaybackProgress(_position, force: true);
      }
      setState(() {});
    });
  }

  Future<void> _resumeToHistoryPosition() async {
    final controller = _controller;
    final target = _resumeHintPosition;
    if (controller == null) return;
    if (target == null || target <= Duration.zero) return;
    if (!controller.value.isInitialized) return;

    final safeTarget = _safeSeekTarget(target, controller.value.duration);
    try {
      final seekFuture = controller.seekTo(safeTarget);
      await seekFuture.timeout(const Duration(seconds: 3));
      _position = safeTarget;
      _syncDanmakuCursor(safeTarget);
    } catch (_) {}

    _resumeHintTimer?.cancel();
    _resumeHintTimer = null;
    _showResumeHint = false;
    final shouldStartReporting = _deferProgressReporting;
    _deferProgressReporting = false;
    if (shouldStartReporting) {
      // ignore: unawaited_futures
      _reportPlaybackStartBestEffort();
      _maybeReportPlaybackProgress(_position, force: true);
    }
    if (mounted) setState(() {});
  }

  Future<void> _reportPlaybackStartBestEffort() async {
    if (_reportedStart || _reportedStop) return;
    final api = _embyApi;
    if (api == null) return;
    final baseUrl = widget.appState.baseUrl;
    final token = widget.appState.token;
    final userId = widget.appState.userId;
    if (baseUrl == null || baseUrl.isEmpty || token == null || token.isEmpty) {
      return;
    }

    _reportedStart = true;
    final posTicks = _toTicks(_position);
    final paused = !_isPlaying;
    try {
      final ps = _playSessionId;
      final ms = _mediaSourceId;
      if (ps != null && ps.isNotEmpty && ms != null && ms.isNotEmpty) {
        await api.reportPlaybackStart(
          token: token,
          baseUrl: baseUrl,
          deviceId: widget.appState.deviceId,
          itemId: widget.itemId,
          mediaSourceId: ms,
          playSessionId: ps,
          positionTicks: posTicks,
          isPaused: paused,
          userId: userId,
        );
      }
    } catch (_) {}
  }

  void _maybeReportPlaybackProgress(Duration position, {bool force = false}) {
    if (_reportedStop) return;
    if (_deferProgressReporting) return;
    if (_progressReportInFlight) return;
    final api = _embyApi;
    if (api == null) return;
    final baseUrl = widget.appState.baseUrl;
    final token = widget.appState.token;
    final userId = widget.appState.userId;
    if (baseUrl == null || baseUrl.isEmpty || token == null || token.isEmpty) {
      return;
    }

    final now = DateTime.now();
    final paused = !_isPlaying;

    final due = _lastProgressReportAt == null ||
        now.difference(_lastProgressReportAt!) >= const Duration(seconds: 15);
    final pausedChanged = paused != _lastProgressReportPaused &&
        (_lastProgressReportAt == null ||
            now.difference(_lastProgressReportAt!) >=
                const Duration(seconds: 1));
    final shouldReport = force || due || pausedChanged;
    if (!shouldReport) return;

    _lastProgressReportAt = now;
    _lastProgressReportPaused = paused;
    _progressReportInFlight = true;

    final ticks = _toTicks(position);

    // ignore: unawaited_futures
    () async {
      try {
        final ps = _playSessionId;
        final ms = _mediaSourceId;
        if (ps != null && ps.isNotEmpty && ms != null && ms.isNotEmpty) {
          await api.reportPlaybackProgress(
            token: token,
            baseUrl: baseUrl,
            deviceId: widget.appState.deviceId,
            itemId: widget.itemId,
            mediaSourceId: ms,
            playSessionId: ps,
            positionTicks: ticks,
            isPaused: paused,
            userId: userId,
          );
        } else if (userId != null && userId.isNotEmpty) {
          await api.updatePlaybackPosition(
            token: token,
            baseUrl: baseUrl,
            userId: userId,
            itemId: widget.itemId,
            positionTicks: ticks,
          );
        }
      } finally {
        _progressReportInFlight = false;
      }
    }();
  }

  Future<void> _reportPlaybackStoppedBestEffort(
      {bool completed = false}) async {
    if (_reportedStop) return;
    _reportedStop = true;

    final api = _embyApi;
    if (api == null) return;
    final baseUrl = widget.appState.baseUrl;
    final token = widget.appState.token;
    final userId = widget.appState.userId;
    if (baseUrl == null || baseUrl.isEmpty || token == null || token.isEmpty) {
      return;
    }

    final pos = _position;
    final dur = _duration;
    final played = completed ||
        (dur > Duration.zero && pos >= dur - const Duration(seconds: 20));
    final ticks = _toTicks(pos);

    try {
      final ps = _playSessionId;
      final ms = _mediaSourceId;
      if (ps != null && ps.isNotEmpty && ms != null && ms.isNotEmpty) {
        await api.reportPlaybackStopped(
          token: token,
          baseUrl: baseUrl,
          deviceId: widget.appState.deviceId,
          itemId: widget.itemId,
          mediaSourceId: ms,
          playSessionId: ps,
          positionTicks: ticks,
          userId: userId,
        );
      }
    } catch (_) {}

    try {
      if (userId != null && userId.isNotEmpty) {
        await api.updatePlaybackPosition(
          token: token,
          baseUrl: baseUrl,
          userId: userId,
          itemId: widget.itemId,
          positionTicks: ticks,
          played: played,
        );
      }
    } catch (_) {}
  }

  bool get _shouldControlSystemUi {
    if (kIsWeb) return false;
    if (widget.isTv) return false;
    return Platform.isAndroid || Platform.isIOS;
  }

  Future<void> _enterImmersiveMode() async {
    if (!_shouldControlSystemUi) return;
    try {
      await SystemChrome.setEnabledSystemUIMode(
        SystemUiMode.immersiveSticky,
        overlays: const [],
      );
    } catch (_) {}
  }

  Future<void> _exitImmersiveMode() async {
    if (!_shouldControlSystemUi) return;
    try {
      await SystemChrome.setEnabledSystemUIMode(
        SystemUiMode.manual,
        overlays: SystemUiOverlay.values,
      );
    } catch (_) {}
    try {
      await SystemChrome.setPreferredOrientations(const []);
    } catch (_) {}
  }

  void _showNotSupported(String feature) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(
        SnackBar(content: Text('Exo 内核暂不支持：$feature')),
      );
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
        orientations = const [];
        break;
    }

    try {
      await SystemChrome.setPreferredOrientations(orientations);
    } catch (_) {}
  }

  @override
  Widget build(BuildContext context) {
    final controller = _controller;
    final isReady = controller != null && controller.value.isInitialized;
    final controlsEnabled = isReady && !_loading && _playError == null;
    final stream = _resolvedStream;
    final enableBlur = !widget.isTv && widget.appState.enableBlurEffects;

    return Scaffold(
      backgroundColor: Colors.black,
      extendBodyBehindAppBar: true,
      appBar: GlassAppBar(
        enableBlur: enableBlur,
        child: AppBar(
          backgroundColor: Colors.transparent,
          elevation: 0,
          foregroundColor: Colors.white,
          title: Text(widget.title),
          centerTitle: true,
          actions: [
            IconButton(
              tooltip: '重新加载',
              icon: const Icon(Icons.refresh),
              onPressed: _loading ? null : _init,
            ),
            if (stream != null && stream.isNotEmpty)
              IconButton(
                tooltip: '复制链接',
                icon: const Icon(Icons.link),
                onPressed: () async {
                  await Clipboard.setData(ClipboardData(text: stream));
                  if (!context.mounted) return;
                  ScaffoldMessenger.of(context).showSnackBar(
                    const SnackBar(content: Text('已复制播放链接')),
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
          Expanded(
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
                              color: Colors.black26,
                              child: Center(child: CircularProgressIndicator()),
                            ),
                          ),
                        Positioned.fill(
                          child: GestureDetector(
                            behavior: HitTestBehavior.translucent,
                            onTapDown: (_) => _showControls(),
                            child: const SizedBox.expand(),
                          ),
                        ),
                        if (controlsEnabled &&
                            _showResumeHint &&
                            _resumeHintPosition != null)
                          Align(
                            alignment: Alignment.topCenter,
                            child: SafeArea(
                              bottom: false,
                              child: Padding(
                                padding:
                                    const EdgeInsets.symmetric(vertical: 12),
                                child: Material(
                                  color: Colors.black54,
                                  borderRadius: BorderRadius.circular(999),
                                  clipBehavior: Clip.antiAlias,
                                  child: InkWell(
                                    onTap: _resumeToHistoryPosition,
                                    child: Padding(
                                      padding: const EdgeInsets.symmetric(
                                        horizontal: 12,
                                        vertical: 10,
                                      ),
                                      child: Row(
                                        mainAxisSize: MainAxisSize.min,
                                        children: [
                                          const Icon(
                                            Icons.history,
                                            size: 18,
                                            color: Colors.white,
                                          ),
                                          const SizedBox(width: 6),
                                          Text(
                                            '跳转到 ${_fmtClock(_resumeHintPosition!)} 继续观看',
                                            style: const TextStyle(
                                              color: Colors.white,
                                              fontSize: 13,
                                            ),
                                          ),
                                        ],
                                      ),
                                    ),
                                  ),
                                ),
                              ),
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
                                    isPlaying: _isPlaying,
                                    onSwitchCore: _switchCore,
                                    onSwitchVersion: _switchVersion,
                                    onScrubStart: _onScrubStart,
                                    onScrubEnd: _onScrubEnd,
                                    onSeek: (pos) async {
                                      await controller.seekTo(pos);
                                      _maybeReportPlaybackProgress(
                                        pos,
                                        force: true,
                                      );
                                      _syncDanmakuCursor(pos);
                                      if (mounted) setState(() {});
                                    },
                                    onPlay: () async {
                                      _showControls();
                                      await controller.play();
                                      _maybeReportPlaybackProgress(
                                        controller.value.position,
                                        force: true,
                                      );
                                      _applyDanmakuPauseState(false);
                                      if (mounted) setState(() {});
                                    },
                                    onPause: () async {
                                      _showControls();
                                      await controller.pause();
                                      _maybeReportPlaybackProgress(
                                        controller.value.position,
                                        force: true,
                                      );
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
                                      _maybeReportPlaybackProgress(
                                        controller.value.position,
                                        force: true,
                                      );
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
                                      _maybeReportPlaybackProgress(
                                        controller.value.position,
                                        force: true,
                                      );
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
                            _playError!,
                            style: const TextStyle(color: Colors.redAccent),
                            textAlign: TextAlign.center,
                          ),
                        )
                      : const Center(child: CircularProgressIndicator()),
            ),
          ),
          if (_loading) const LinearProgressIndicator(),
        ],
      ),
    );
  }
}

enum _OrientationMode { auto, landscape, portrait }
