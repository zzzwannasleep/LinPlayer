import 'dart:async';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart' show kIsWeb, defaultTargetPlatform;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';

import 'player_service.dart';
import 'services/dandanplay_api.dart';
import 'src/player/danmaku.dart';
import 'src/player/danmaku_processing.dart';
import 'src/player/playback_controls.dart';
import 'src/player/danmaku_stage.dart';
import 'src/player/anime4k.dart';
import 'src/player/thumbnail_generator.dart';
import 'src/player/track_preferences.dart';
import 'state/app_state.dart';
import 'state/anime4k_preferences.dart';
import 'state/danmaku_preferences.dart';
import 'state/local_playback_handoff.dart';
import 'state/preferences.dart';

class PlayerScreen extends StatefulWidget {
  const PlayerScreen({super.key, this.appState});

  final AppState? appState;

  @override
  State<PlayerScreen> createState() => _PlayerScreenState();
}

class _PlayerScreenState extends State<PlayerScreen> {
  final PlayerService _playerService = getPlayerService();
  MediaKitThumbnailGenerator? _thumbnailer;
  final List<PlatformFile> _playlist = [];
  int _currentlyPlayingIndex = -1;
  StreamSubscription<Duration>? _posSub;
  StreamSubscription<String>? _errorSub;
  StreamSubscription<VideoParams>? _videoParamsSub;
  StreamSubscription<bool>? _playingSub;
  StreamSubscription<bool>? _bufferingSub;
  VideoParams? _lastVideoParams;
  _OrientationMode _orientationMode = _OrientationMode.auto;
  String? _lastOrientationKey;
  bool _isTvDevice = false;
  Duration _position = Duration.zero;
  Duration _duration = Duration.zero;
  String? _playError;
  late bool _hwdecOn;
  late Anime4kPreset _anime4kPreset;
  Tracks _tracks = const Tracks();
  DateTime? _lastPositionUiUpdate;
  bool _appliedAudioPref = false;
  bool _appliedSubtitlePref = false;

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
  bool _buffering = false;
  bool _danmakuPaused = false;

  static const Duration _controlsAutoHideDelay = Duration(seconds: 3);
  Timer? _controlsHideTimer;
  bool _controlsVisible = true;
  bool _isScrubbing = false;

  @override
  void initState() {
    super.initState();
    final appState = widget.appState;
    _hwdecOn = appState?.preferHardwareDecode ?? true;
    _anime4kPreset = appState?.anime4kPreset ?? Anime4kPreset.off;
    _danmakuEnabled = appState?.danmakuEnabled ?? true;
    _danmakuOpacity = appState?.danmakuOpacity ?? 1.0;
    _danmakuScale = appState?.danmakuScale ?? 1.0;
    _danmakuSpeed = appState?.danmakuSpeed ?? 1.0;
    _danmakuBold = appState?.danmakuBold ?? true;
    _danmakuMaxLines = appState?.danmakuMaxLines ?? 10;
    _danmakuTopMaxLines = appState?.danmakuTopMaxLines ?? 0;
    _danmakuBottomMaxLines = appState?.danmakuBottomMaxLines ?? 0;
    _danmakuPreventOverlap = appState?.danmakuPreventOverlap ?? true;

    final handoff = appState?.takeLocalPlaybackHandoff();
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

  @override
  void dispose() {
    _controlsHideTimer?.cancel();
    _controlsHideTimer = null;
    _posSub?.cancel();
    _errorSub?.cancel();
    _videoParamsSub?.cancel();
    _playingSub?.cancel();
    _bufferingSub?.cancel();
    // ignore: unawaited_futures
    _exitOrientationLock();
    final thumb = _thumbnailer;
    _thumbnailer = null;
    if (thumb != null) {
      // ignore: unawaited_futures
      thumb.dispose();
    }
    _playerService.dispose();
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

  Future<void> _switchCore() async {
    final appState = widget.appState;
    if (appState == null) return;
    if (kIsWeb || defaultTargetPlatform != TargetPlatform.android) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Exo 内核仅支持 Android')),
      );
      return;
    }

    final playlist = _playlist
        .where((f) => (f.path ?? '').trim().isNotEmpty)
        .map((f) => LocalPlaybackItem(name: f.name, path: f.path!.trim()))
        .toList();
    if (playlist.isNotEmpty) {
      final idx = _currentlyPlayingIndex < 0
          ? 0
          : _currentlyPlayingIndex >= playlist.length
              ? playlist.length - 1
              : _currentlyPlayingIndex;
      appState.setLocalPlaybackHandoff(
        LocalPlaybackHandoff(
          playlist: playlist,
          index: idx,
          position: _position,
          wasPlaying: _playerService.isPlaying,
        ),
      );
    }
    await appState.setPlayerCore(PlayerCore.exo);
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

  bool _isTv(BuildContext context) =>
      defaultTargetPlatform == TargetPlatform.android &&
      MediaQuery.of(context).orientation == Orientation.landscape &&
      MediaQuery.of(context).size.shortestSide >= 720;

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

  Future<void> _playFile(
    PlatformFile file,
    int index, {
    Duration? startPosition,
    bool? autoPlay,
  }) async {
    setState(() {
      _currentlyPlayingIndex = index;
      _playError = null;
      _appliedAudioPref = false;
      _appliedSubtitlePref = false;
      _nextDanmakuIndex = 0;
      _danmakuSources.clear();
      _danmakuSourceIndex = -1;
      _buffering = false;
      final appState = widget.appState;
      _danmakuEnabled = appState?.danmakuEnabled ?? true;
      _danmakuOpacity = appState?.danmakuOpacity ?? 1.0;
      _danmakuScale = appState?.danmakuScale ?? 1.0;
      _danmakuSpeed = appState?.danmakuSpeed ?? 1.0;
      _danmakuBold = appState?.danmakuBold ?? true;
      _danmakuMaxLines = appState?.danmakuMaxLines ?? 10;
      _danmakuTopMaxLines = appState?.danmakuTopMaxLines ?? 0;
      _danmakuBottomMaxLines = appState?.danmakuBottomMaxLines ?? 0;
      _danmakuPreventOverlap = appState?.danmakuPreventOverlap ?? true;
      _controlsVisible = true;
      _isScrubbing = false;
    });
    _controlsHideTimer?.cancel();
    _controlsHideTimer = null;
    _danmakuKey.currentState?.clear();
    final isTv = _isTv(context);
    _isTvDevice = isTv;
    await _errorSub?.cancel();
    _errorSub = null;
    await _videoParamsSub?.cancel();
    _videoParamsSub = null;
    await _playingSub?.cancel();
    _playingSub = null;
    await _bufferingSub?.cancel();
    _bufferingSub = null;
    try {
      await _playerService.dispose();
    } catch (_) {}
    try {
      await _thumbnailer?.dispose();
    } catch (_) {}
    _thumbnailer = null;

    try {
      if (kIsWeb) {
        await _playerService.initialize(
          null,
          networkUrl: file.path ?? '',
          isTv: isTv,
          hardwareDecode: _hwdecOn,
          mpvCacheSizeMb: widget.appState?.mpvCacheSizeMb ?? 500,
          externalMpvPath: widget.appState?.externalMpvPath,
        );
      } else {
        await _playerService.initialize(
          file.path,
          isTv: isTv,
          hardwareDecode: _hwdecOn,
          mpvCacheSizeMb: widget.appState?.mpvCacheSizeMb ?? 500,
          externalMpvPath: widget.appState?.externalMpvPath,
        );
      }
      if (!mounted) return;
      if (_playerService.isExternalPlayback) {
        setState(() => _playError =
            _playerService.externalPlaybackMessage ?? '已使用外部播放器播放');
        return;
      }

      try {
        await Anime4k.apply(_playerService.player, _anime4kPreset);
      } catch (_) {
        _anime4kPreset = Anime4kPreset.off;
        // ignore: unawaited_futures
        widget.appState?.setAnime4kPreset(Anime4kPreset.off);
      }
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
        final lower = message.toLowerCase();
        final isShaderError =
            lower.contains('glsl') || lower.contains('shader');
        if (!_anime4kPreset.isOff && isShaderError) {
          setState(() => _anime4kPreset = Anime4kPreset.off);
          // ignore: unawaited_futures
          widget.appState?.setAnime4kPreset(Anime4kPreset.off);
          // ignore: unawaited_futures
          Anime4k.clear(_playerService.player);
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('Anime4K 加载失败，已自动关闭')),
          );
          return;
        }
        setState(() => _playError = message);
      });
      _bufferingSub = _playerService.player.stream.buffering.listen((value) {
        if (!mounted) return;
        _buffering = value;
        _applyDanmakuPauseState(_buffering || !_playerService.isPlaying);
        setState(() {});
      });
      _playingSub = _playerService.player.stream.playing.listen((playing) {
        if (!mounted) return;
        _applyDanmakuPauseState(_buffering || !playing);
        setState(() {});
      });
      _applyDanmakuPauseState(_buffering || !_playerService.isPlaying);
      _duration = _playerService.duration;
      if (!kIsWeb && (file.path ?? '').isNotEmpty) {
        _thumbnailer = MediaKitThumbnailGenerator(media: Media(file.path!));
      }
      if (startPosition != null && startPosition > Duration.zero) {
        final d = _duration;
        final target =
            (d > Duration.zero && startPosition > d) ? d : startPosition;
        await _playerService.seek(target);
        _position = target;
        _syncDanmakuCursor(target);
      }
      if (autoPlay == false) {
        await _playerService.pause();
      }
      _maybeAutoLoadOnlineDanmaku(file);
      _videoParamsSub = _playerService.player.stream.videoParams.listen((p) {
        _lastVideoParams = p;
        // ignore: unawaited_futures
        _applyOrientationForMode(videoParams: p);
      });
      _lastVideoParams = _playerService.player.state.videoParams;
      // ignore: unawaited_futures
      _applyOrientationForMode(videoParams: _lastVideoParams);
      _posSub?.cancel();
      _posSub = _playerService.player.stream.position.listen((d) {
        if (!mounted) return;
        final prev = _position;
        final wentBack = d + const Duration(seconds: 2) < prev;
        final jumpedForward = d > prev + const Duration(seconds: 3);
        final now = DateTime.now();
        final deltaMs = (d.inMilliseconds - _position.inMilliseconds).abs();
        final shouldRebuild = _lastPositionUiUpdate == null ||
            now.difference(_lastPositionUiUpdate!) >=
                const Duration(milliseconds: 250) ||
            deltaMs >= 1000;
        _position = d;
        if (wentBack || jumpedForward) {
          _syncDanmakuCursor(d);
        }
        _drainDanmaku(d);
        if (shouldRebuild) {
          _lastPositionUiUpdate = now;
          setState(() {});
        }
      });
      _scheduleControlsHide();
    } catch (e) {
      setState(() => _playError = e.toString());
    }
    setState(() {});
  }

  bool get _shouldControlSystemUi {
    if (kIsWeb) return false;
    if (_isTvDevice) return false;
    return Platform.isAndroid || Platform.isIOS;
  }

  double? _displayAspect(VideoParams p) {
    var aspect = p.aspect;
    if (aspect == null || aspect <= 0) {
      final w = (p.dw ?? p.w)?.toDouble();
      final h = (p.dh ?? p.h)?.toDouble();
      if (w != null && h != null && w > 0 && h > 0) {
        aspect = w / h;
      }
    }
    final rotate = (p.rotate ?? 0) % 180;
    if (rotate != 0 && aspect != null && aspect != 0) {
      aspect = 1 / aspect;
    }
    if (aspect == null || aspect <= 0) return null;
    return aspect;
  }

  Future<void> _applyOrientationForMode({VideoParams? videoParams}) async {
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
        final p = videoParams;
        if (p == null) return;
        final aspect = _displayAspect(p);
        if (aspect == null) return;
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
    if (!_shouldControlSystemUi) return;
    try {
      await SystemChrome.setPreferredOrientations(const []);
    } catch (_) {}
  }

  String get _orientationTooltip => switch (_orientationMode) {
        _OrientationMode.auto => 'Orientation: Auto',
        _OrientationMode.landscape => 'Orientation: Landscape',
        _OrientationMode.portrait => 'Orientation: Portrait',
      };

  IconData get _orientationIcon => switch (_orientationMode) {
        _OrientationMode.auto => Icons.screen_rotation,
        _OrientationMode.landscape => Icons.stay_current_landscape,
        _OrientationMode.portrait => Icons.stay_current_portrait,
      };

  Future<void> _cycleOrientationMode() async {
    final next = switch (_orientationMode) {
      _OrientationMode.auto => _OrientationMode.landscape,
      _OrientationMode.landscape => _OrientationMode.portrait,
      _OrientationMode.portrait => _OrientationMode.auto,
    };
    if (mounted) {
      setState(() => _orientationMode = next);
    } else {
      _orientationMode = next;
    }
    if (mounted) {
      ScaffoldMessenger.of(context)
        ..hideCurrentSnackBar()
        ..showSnackBar(
          SnackBar(
            content: Text(_orientationTooltip),
            duration: const Duration(milliseconds: 800),
          ),
        );
    }
    await _applyOrientationForMode(videoParams: _lastVideoParams);
  }

  Future<String> _computeFileHash16M(String path) async {
    const maxBytes = 16 * 1024 * 1024;
    final file = File(path);
    final digest = await md5.bind(file.openRead(0, maxBytes)).first;
    return digest.toString();
  }

  void _maybeAutoLoadOnlineDanmaku(PlatformFile file) {
    final appState = widget.appState;
    if (appState == null) return;
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
    if (appState == null) {
      if (showToast && mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('未找到应用设置，无法加载在线弹幕')),
        );
      }
      return;
    }
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
    final appState = widget.appState;
    if (appState != null) {
      items = processDanmakuItems(
        items,
        blockWords: appState.danmakuBlockWords,
        mergeDuplicates: appState.danmakuMergeDuplicates,
      );
    }
    if (!mounted) return;
    setState(() {
      _danmakuSources.add(DanmakuSource(name: file.name, items: items));
      final desiredName =
          appState != null && appState.danmakuRememberSelectedSource
              ? appState.danmakuLastSelectedSourceName
              : '';
      final idx = desiredName.isEmpty
          ? -1
          : _danmakuSources.indexWhere((s) => s.name == desiredName);
      _danmakuSourceIndex = idx >= 0 ? idx : (_danmakuSources.length - 1);
      _danmakuEnabled = true;
      _syncDanmakuCursor(_position);
    });
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
                        child: Text('弹幕',
                            style: Theme.of(context).textTheme.titleLarge),
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
                                _currentlyPlayingIndex < 0 ||
                                _currentlyPlayingIndex >= _playlist.length
                            ? null
                            : () async {
                                onlineLoading = true;
                                setSheetState(() {});
                                try {
                                  await _loadOnlineDanmakuForFile(
                                    _playlist[_currentlyPlayingIndex],
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
                    onChanged: (v) {
                      setState(() => _danmakuEnabled = v);
                      if (!v) {
                        _danmakuKey.currentState?.clear();
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
                            : (v) {
                                if (v == null) return;
                                setState(() {
                                  _danmakuSourceIndex = v;
                                  _danmakuEnabled = true;
                                  _syncDanmakuCursor(_position);
                                });
                                final appState = widget.appState;
                                if (appState != null &&
                                    appState.danmakuRememberSelectedSource &&
                                    v >= 0 &&
                                    v < _danmakuSources.length) {
                                  // ignore: unawaited_futures
                                  appState.setDanmakuLastSelectedSourceName(
                                      _danmakuSources[v].name);
                                }
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

  void _maybeApplyPreferredTracks(Tracks tracks) {
    final appState = widget.appState;
    final player = _playerService.isInitialized ? _playerService.player : null;
    if (appState == null || player == null) return;

    if (!_appliedAudioPref) {
      final picked =
          pickPreferredAudioTrack(tracks, appState.preferredAudioLang);
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
    final currentFileName = _currentlyPlayingIndex != -1
        ? _playlist[_currentlyPlayingIndex].name
        : 'LinPlayer';

    _isTvDevice = _isTv(context);

    return Scaffold(
      backgroundColor: Colors.black,
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
            tooltip: _anime4kPreset.isOff
                ? 'Anime4K'
                : 'Anime4K: ${_anime4kPreset.label}',
            icon: Icon(
              _anime4kPreset.isOff
                  ? Icons.auto_fix_high_outlined
                  : Icons.auto_fix_high,
            ),
            onPressed: _showAnime4kSheet,
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
            tooltip: _hwdecOn ? '切换软解' : '切换硬解',
            icon: Icon(_hwdecOn ? Icons.memory : Icons.settings_backup_restore),
            onPressed: () {
              setState(() => _hwdecOn = !_hwdecOn);
              if (_currentlyPlayingIndex >= 0 && _playlist.isNotEmpty) {
                _playFile(
                    _playlist[_currentlyPlayingIndex], _currentlyPlayingIndex);
              }
            },
          ),
          IconButton(
            tooltip: _orientationTooltip,
            icon: Icon(_orientationIcon),
            onPressed: _cycleOrientationMode,
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
                  ? Stack(
                      fit: StackFit.expand,
                      children: [
                        Video(
                          controller: _playerService.controller,
                          controls: NoVideoControls,
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
                                    enabled: _playerService.isInitialized &&
                                        _playError == null,
                                    position: _position,
                                    duration: _duration,
                                    isPlaying: _playerService.isPlaying,
                                    onRequestThumbnail: _thumbnailer == null
                                        ? null
                                        : (pos) => _thumbnailer!.getThumbnail(
                                              pos,
                                            ),
                                    onSwitchCore: (!kIsWeb &&
                                            defaultTargetPlatform ==
                                                TargetPlatform.android &&
                                            widget.appState != null)
                                        ? _switchCore
                                        : null,
                                    onScrubStart: _onScrubStart,
                                    onScrubEnd: _onScrubEnd,
                                    onSeek: (pos) async {
                                      await _playerService.seek(pos);
                                      _position = pos;
                                      _syncDanmakuCursor(pos);
                                      if (mounted) setState(() {});
                                    },
                                    onPlay: () {
                                      _showControls();
                                      return _playerService.play();
                                    },
                                    onPause: () {
                                      _showControls();
                                      return _playerService.pause();
                                    },
                                    onSeekBackward: () async {
                                      _showControls();
                                      final target = _position -
                                          const Duration(seconds: 10);
                                      final pos = target < Duration.zero
                                          ? Duration.zero
                                          : target;
                                      await _playerService.seek(pos);
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
                                      await _playerService.seek(pos);
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
                final isPlaying = index == _currentlyPlayingIndex;
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

  Future<void> _showAnime4kSheet() async {
    final selected = await showModalBottomSheet<Anime4kPreset>(
      context: context,
      showDragHandle: true,
      builder: (ctx) {
        final current = _anime4kPreset;
        return SafeArea(
          child: ListView(
            children: [
              const ListTile(title: Text('Anime4K（M）')),
              for (final preset in Anime4kPreset.values)
                ListTile(
                  leading: Icon(
                    preset == current
                        ? Icons.check_circle
                        : Icons.circle_outlined,
                  ),
                  title: Text(preset.label),
                  subtitle: Text(preset.description),
                  onTap: () => Navigator.of(ctx).pop(preset),
                ),
            ],
          ),
        );
      },
    );

    if (!mounted) return;
    if (selected == null || selected == _anime4kPreset) return;

    setState(() => _anime4kPreset = selected);
    // ignore: unawaited_futures
    widget.appState?.setAnime4kPreset(selected);

    if (!_playerService.isInitialized || _playerService.isExternalPlayback) {
      return;
    }

    final messenger = ScaffoldMessenger.of(context);
    try {
      await Anime4k.apply(_playerService.player, selected);
      if (!mounted) return;
      final text =
          selected.isOff ? '已关闭 Anime4K' : '已启用 Anime4K：${selected.label}';
      messenger.showSnackBar(
        SnackBar(content: Text(text)),
      );
    } catch (_) {
      if (!mounted) return;
      setState(() => _anime4kPreset = Anime4kPreset.off);
      // ignore: unawaited_futures
      widget.appState?.setAnime4kPreset(Anime4kPreset.off);
      try {
        await Anime4k.clear(_playerService.player);
      } catch (_) {}
      messenger.showSnackBar(
        const SnackBar(content: Text('Anime4K 初始化失败')),
      );
    }
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

enum _OrientationMode { auto, landscape, portrait }
