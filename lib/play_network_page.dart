import 'dart:async';
import 'dart:io';
import 'dart:math' as math;

import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:lin_player_player/lin_player_player.dart';
import 'package:lin_player_prefs/lin_player_prefs.dart';
import 'package:lin_player_server_adapters/lin_player_server_adapters.dart';
import 'package:lin_player_state/lin_player_state.dart';
import 'package:lin_player_ui/lin_player_ui.dart';
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';

import 'play_network_page_exo.dart';
import 'server_adapters/server_access.dart';
import 'services/app_route_observer.dart';
import 'services/built_in_proxy/built_in_proxy_service.dart';
import 'widgets/danmaku_manual_search_dialog.dart';

class PlayNetworkPage extends StatefulWidget {
  const PlayNetworkPage({
    super.key,
    required this.title,
    required this.itemId,
    required this.appState,
    this.server,
    this.isTv = false,
    this.seriesId,
    this.startPosition,
    this.resumeImmediately = true,
    this.mediaSourceId,
    this.audioStreamIndex,
    this.subtitleStreamIndex,
  });

  final String title;
  final String itemId;
  final AppState appState;
  final ServerProfile? server;
  final bool isTv;
  final String? seriesId;
  final Duration? startPosition;
  final bool resumeImmediately;
  final String? mediaSourceId;
  final int? audioStreamIndex; // Emby MediaStream Index
  final int? subtitleStreamIndex; // Emby MediaStream Index, -1 = off

  @override
  State<PlayNetworkPage> createState() => _PlayNetworkPageState();
}

class _PlayNetworkPageState extends State<PlayNetworkPage>
    with WidgetsBindingObserver, RouteAware {
  final PlayerService _playerService = getPlayerService();
  MediaKitThumbnailGenerator? _thumbnailer;
  ServerAccess? _serverAccess;
  bool _loading = true;
  String? _playError;
  late bool _hwdecOn;
  late Anime4kPreset _anime4kPreset;
  Tracks _tracks = const Tracks();

  // Subtitle options (MPV + media_kit_video SubtitleView).
  double _subtitleDelaySeconds = 0.0;
  double _subtitleFontSize = 32.0;
  int _subtitlePositionStep = 5; // 0..20, maps to padding-bottom in 5px steps.
  bool _subtitleBold = false;
  bool _subtitleAssOverrideForce = false;

  StreamSubscription<String>? _errorSub;
  int? _resolvedStreamSizeBytes;
  StreamSubscription<bool>? _bufferingSub;
  StreamSubscription<double>? _bufferingPctSub;
  StreamSubscription<Duration>? _bufferSub;
  StreamSubscription<Duration>? _posSub;
  StreamSubscription<bool>? _playingSub;
  StreamSubscription<bool>? _completedSub;
  bool _buffering = false;
  double? _bufferingPct;
  Duration _lastBuffer = Duration.zero;
  DateTime? _lastBufferAt;
  Duration _lastBufferSample = Duration.zero;
  double? _bufferSpeedX;
  Timer? _netSpeedTimer;
  bool _netSpeedPollInFlight = false;
  double? _netSpeedBytesPerSecond;
  int? _lastTotalRxBytes;
  DateTime? _lastTotalRxAt;
  bool _appliedAudioPref = false;
  bool _appliedSubtitlePref = false;
  PageRoute<dynamic>? _route;
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
  StreamSubscription<VideoParams>? _videoParamsSub;
  VideoParams? _lastVideoParams;
  _OrientationMode _orientationMode = _OrientationMode.auto;
  String? _lastOrientationKey;
  bool _remoteEnabled = false;
  final FocusNode _tvSurfaceFocusNode =
      FocusNode(debugLabel: 'network_player_tv_surface');
  final FocusNode _tvPlayPauseFocusNode =
      FocusNode(debugLabel: 'network_player_tv_play_pause');
  Duration? _resumeHintPosition;
  bool _showResumeHint = false;
  Timer? _resumeHintTimer;
  Duration? _startOverHintPosition;
  bool _showStartOverHint = false;
  Timer? _startOverHintTimer;
  bool _deferProgressReporting = false;

  IntroTimestamps? _introTimestamps;
  int _introSeq = 0;
  bool _skipIntroPromptVisible = false;
  bool _skipIntroHandled = false;

  static const Duration _gestureOverlayAutoHideDelay =
      Duration(milliseconds: 800);
  Timer? _gestureOverlayTimer;
  IconData? _gestureOverlayIcon;
  String? _gestureOverlayText;
  Offset? _doubleTapDownPosition;

  static const Duration _tvOkLongPressDelay = Duration(milliseconds: 420);
  Timer? _tvOkLongPressTimer;
  bool _tvOkLongPressTriggered = false;
  double? _tvOkLongPressBaseRate;

  double _screenBrightness = 1.0; // 0.2..1.0 (visual overlay only)
  double _playerVolume = 1.0; // 0..1 (maps to mpv 0..100)

  _GestureMode _gestureMode = _GestureMode.none;
  Offset? _gestureStartPos;
  Duration _seekGestureStartPosition = Duration.zero;
  Duration? _seekGesturePreviewPosition;
  double _gestureStartBrightness = 1.0;
  double _gestureStartVolume = 1.0;

  double? _longPressBaseRate;
  Offset? _longPressStartPos;

  String? get _baseUrl => widget.server?.baseUrl ?? widget.appState.baseUrl;
  String? get _token => widget.server?.token ?? widget.appState.token;
  String? get _userId => widget.server?.userId ?? widget.appState.userId;

  static const Duration _controlsAutoHideDelay = Duration(seconds: 3);
  Timer? _controlsHideTimer;
  bool _controlsVisible = true;
  bool _isScrubbing = false;

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
  Duration _lastPosition = Duration.zero;
  bool _danmakuPaused = false;
  DateTime? _lastUiTickAt;

  MediaItem? _episodePickerItem;
  bool _episodePickerItemLoading = false;

  bool _episodePickerVisible = false;
  bool _episodePickerLoading = false;
  String? _episodePickerError;
  List<MediaItem> _episodeSeasons = const [];
  String? _episodeSelectedSeasonId;
  final Map<String, List<MediaItem>> _episodeEpisodesCache = {};
  final Map<String, Future<List<MediaItem>>> _episodeEpisodesFutureCache = {};

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _serverAccess =
        resolveServerAccess(appState: widget.appState, server: widget.server);
    _hwdecOn = widget.appState.preferHardwareDecode;
    _anime4kPreset = widget.appState.anime4kPreset;
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
    _selectedMediaSourceId = widget.mediaSourceId;
    _selectedAudioStreamIndex = widget.audioStreamIndex;
    _selectedSubtitleStreamIndex = widget.subtitleStreamIndex;
    final sid = (widget.seriesId ?? '').trim();
    final serverId = widget.server?.id ?? widget.appState.activeServerId;
    if (serverId != null && serverId.isNotEmpty && sid.isNotEmpty) {
      _selectedAudioStreamIndex ??= widget.appState
          .seriesAudioStreamIndex(serverId: serverId, seriesId: sid);
      _selectedSubtitleStreamIndex ??= widget.appState
          .seriesSubtitleStreamIndex(serverId: serverId, seriesId: sid);
    }
    // ignore: unawaited_futures
    _exitImmersiveMode();
    _init();
    // ignore: unawaited_futures
    _loadEpisodePickerItem();
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final route = ModalRoute.of(context);
    if (route is PageRoute && route != _route) {
      if (_route != null) appRouteObserver.unsubscribe(this);
      _route = route;
      appRouteObserver.subscribe(this, route);
    }
  }

  @override
  void didPushNext() {
    // User navigated away from the playback page: stop playback & buffering.
    _netSpeedTimer?.cancel();
    _netSpeedTimer = null;
    // ignore: unawaited_futures
    _reportPlaybackStoppedBestEffort();
    // ignore: unawaited_futures
    _playerService.dispose();
  }

  Future<void> _init() async {
    await _errorSub?.cancel();
    _errorSub = null;
    await _bufferingSub?.cancel();
    _bufferingSub = null;
    await _bufferingPctSub?.cancel();
    _bufferingPctSub = null;
    await _bufferSub?.cancel();
    _bufferSub = null;
    await _posSub?.cancel();
    _posSub = null;
    await _playingSub?.cancel();
    _playingSub = null;
    await _completedSub?.cancel();
    _completedSub = null;
    await _videoParamsSub?.cancel();
    _videoParamsSub = null;
    _lastVideoParams = null;
    _lastOrientationKey = null;
    _lastBuffer = Duration.zero;
    _lastBufferAt = null;
    _lastBufferSample = Duration.zero;
    _bufferSpeedX = null;
    _netSpeedTimer?.cancel();
    _netSpeedTimer = null;
    _netSpeedPollInFlight = false;
    _netSpeedBytesPerSecond = null;
    _appliedAudioPref = false;
    _appliedSubtitlePref = false;
    _playSessionId = null;
    _mediaSourceId = null;
    _lastProgressReportAt = null;
    _lastProgressReportPaused = false;
    _reportedStart = false;
    _reportedStop = false;
    _progressReportInFlight = false;
    _nextDanmakuIndex = 0;
    _danmakuKey.currentState?.clear();
    _lastUiTickAt = null;
    _resumeHintTimer?.cancel();
    _resumeHintTimer = null;
    _resumeHintPosition = null;
    _showResumeHint = false;
    _startOverHintTimer?.cancel();
    _startOverHintTimer = null;
    _startOverHintPosition = null;
    _showStartOverHint = false;
    _deferProgressReporting = false;
    _introSeq++;
    _introTimestamps = null;
    _skipIntroPromptVisible = false;
    _skipIntroHandled = false;
    _controlsVisible = true;
    _isScrubbing = false;
    _controlsHideTimer?.cancel();
    _controlsHideTimer = null;
    try {
      await _thumbnailer?.dispose();
    } catch (_) {}
    _thumbnailer = null;
    try {
      final builtInProxyEnabled =
          widget.isTv && widget.appState.tvBuiltInProxyEnabled;
      final builtInProxy = BuiltInProxyService.instance;
      if (builtInProxyEnabled) {
        try {
          await builtInProxy.start();
        } catch (_) {}
      }

      final streamUrl = await _buildStreamUrl();
      final access = _serverAccess;
      if (access == null) {
        _playError = 'Unsupported server';
        return;
      }
      final embyHeaders = access.adapter.buildStreamHeaders(access.auth);
      final proxyReady = builtInProxyEnabled &&
          builtInProxy.status.state == BuiltInProxyState.running;
      final httpProxy = (proxyReady && streamUrl.isNotEmpty)
          ? (() {
              final uri = Uri.tryParse(streamUrl);
              if (uri == null) return null;
              return BuiltInProxyService.proxyUrlForUri(uri);
            })()
          : null;
      if (!kIsWeb && streamUrl.isNotEmpty) {
        _thumbnailer = MediaKitThumbnailGenerator(
          media: Media(streamUrl, httpHeaders: embyHeaders),
          httpProxy: httpProxy,
        );
      }
      await _playerService.initialize(
        null,
        networkUrl: streamUrl,
        httpHeaders: embyHeaders,
        isTv: widget.isTv,
        hardwareDecode: _hwdecOn,
        mpvCacheSizeMb: widget.appState.mpvCacheSizeMb,
        bufferBackRatio: widget.appState.playbackBufferBackRatio,
        unlimitedStreamCache: widget.appState.unlimitedStreamCache,
        networkStreamSizeBytes: _resolvedStreamSizeBytes,
        externalMpvPath: widget.appState.externalMpvPath,
        httpProxy: httpProxy,
      );
      if (_playerService.isExternalPlayback) {
        _playError = _playerService.externalPlaybackMessage ?? '已使用外部播放器播放';
        return;
      }

      // ignore: unawaited_futures
      _pollNetSpeed();
      _scheduleNetSpeedTick();

      try {
        await Anime4k.apply(_playerService.player, _anime4kPreset);
      } catch (_) {
        _anime4kPreset = Anime4kPreset.off;
        // ignore: unawaited_futures
        widget.appState.setAnime4kPreset(Anime4kPreset.off);
      }

      await _applyMpvSubtitleOptions();
      final start = _overrideStartPosition ?? widget.startPosition;
      final resumeImmediately =
          _overrideResumeImmediately || widget.resumeImmediately;
      _overrideStartPosition = null;
      _overrideResumeImmediately = false;
      if (start != null && start > Duration.zero) {
        final target = _safeSeekTarget(start, _playerService.duration);
        _deferProgressReporting = true;
        if (resumeImmediately) {
          await _playerService.seek(target, flushBuffer: _flushBufferOnSeek);
          final applied = _playerService.position;
          _lastPosition = applied;
          _syncDanmakuCursor(applied);

          final ok = (applied - target).inMilliseconds.abs() <= 1000;
          if (ok) {
            _deferProgressReporting = false;
            if (applied > Duration.zero) {
              _startOverHintPosition = applied;
              _showStartOverHint = true;
            }
          } else {
            _resumeHintPosition = target;
            _showResumeHint = true;
          }
        } else {
          _resumeHintPosition = target;
          _showResumeHint = true;
        }
      }
      _tracks = _playerService.player.state.tracks;
      _maybeApplyInitialTracks(_tracks);
      _playerService.player.stream.tracks.listen((t) {
        if (!mounted) return;
        _maybeApplyInitialTracks(t);
        setState(() => _tracks = t);
      });
      _bufferingSub = _playerService.player.stream.buffering.listen((value) {
        if (!mounted) return;
        _buffering = value;
        _bufferSpeedX = null;
        _lastBufferAt = null;
        _lastBufferSample = _lastBuffer;
        _applyDanmakuPauseState(_buffering || !_playerService.isPlaying);
        setState(() {});
      });
      _bufferingPctSub =
          _playerService.player.stream.bufferingPercentage.listen((value) {
        if (!mounted) return;
        setState(() => _bufferingPct = value);
      });
      _bufferSub = _playerService.player.stream.buffer.listen((value) {
        _lastBuffer = value;

        final show = widget.appState.showBufferSpeed;
        if (!show || !_buffering) return;

        final now = DateTime.now();
        final refreshSeconds = widget.appState.bufferSpeedRefreshSeconds
            .clamp(0.2, 3.0)
            .toDouble();
        final refreshMs = (refreshSeconds * 1000).round();

        final prevAt = _lastBufferAt;
        if (prevAt == null) {
          _bufferSpeedX = null;
          _lastBufferAt = now;
          _lastBufferSample = value;
          if (mounted) setState(() {});
          return;
        }

        final dtMs = now.difference(prevAt).inMilliseconds;
        if (dtMs < refreshMs) return;

        final deltaMs = (value - _lastBufferSample).inMilliseconds;
        _lastBufferAt = now;
        _lastBufferSample = value;
        _bufferSpeedX = (dtMs > 0 && deltaMs >= 0) ? (deltaMs / dtMs) : null;

        if (!mounted) return;
        setState(() {});
      });
      _posSub = _playerService.player.stream.position.listen((pos) {
        if (!mounted) return;
        final prev = _lastPosition;
        final wentBack = pos + const Duration(seconds: 2) < prev;
        final jumpedForward = pos > prev + const Duration(seconds: 3);
        _lastPosition = pos;
        if (wentBack || jumpedForward) {
          _syncDanmakuCursor(pos);
        }
        _drainDanmaku(pos);
        _maybeReportPlaybackProgress(pos);
        _maybeUpdateSkipIntroPrompt(pos);

        final now = DateTime.now();
        final shouldRebuild = _lastUiTickAt == null ||
            now.difference(_lastUiTickAt!) >= const Duration(milliseconds: 250);
        if (shouldRebuild) {
          _lastUiTickAt = now;
          setState(() {});
        }
      });
      _playingSub = _playerService.player.stream.playing.listen((playing) {
        if (!mounted) return;
        _applyDanmakuPauseState(_buffering || !playing);
        _maybeReportPlaybackProgress(_lastPosition, force: true);
        setState(() {});
      });
      _applyDanmakuPauseState(_buffering || !_playerService.isPlaying);
      _completedSub = _playerService.player.stream.completed.listen((value) {
        if (!value) return;
        // ignore: unawaited_futures
        _reportPlaybackStoppedBestEffort(completed: true);
      });
      _videoParamsSub = _playerService.player.stream.videoParams.listen((p) {
        _lastVideoParams = p;
        // ignore: unawaited_futures
        _applyOrientationForMode(videoParams: p);
      });
      _lastVideoParams = _playerService.player.state.videoParams;
      // ignore: unawaited_futures
      _applyOrientationForMode(videoParams: _lastVideoParams);
      _errorSub?.cancel();
      _errorSub = _playerService.player.stream.error.listen((message) {
        if (!mounted) return;
        final lower = message.toLowerCase();
        final isShaderError =
            lower.contains('glsl') || lower.contains('shader');
        if (!_anime4kPreset.isOff && isShaderError) {
          setState(() => _anime4kPreset = Anime4kPreset.off);
          // ignore: unawaited_futures
          widget.appState.setAnime4kPreset(Anime4kPreset.off);
          // ignore: unawaited_futures
          Anime4k.clear(_playerService.player);
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('Anime4K 加载失败，已自动关闭')),
          );
          return;
        }
        setState(() => _playError = message);
      });
      if (!_deferProgressReporting) {
        // ignore: unawaited_futures
        _reportPlaybackStartBestEffort();
      }
      _maybeAutoLoadOnlineDanmaku();
      // ignore: unawaited_futures
      _loadIntroTimestampsBestEffort();
    } catch (e) {
      _playError = e.toString();
      _resumeHintPosition = null;
      _showResumeHint = false;
      _startOverHintPosition = null;
      _showStartOverHint = false;
      _deferProgressReporting = false;
    } finally {
      if (mounted) {
        setState(() => _loading = false);
        if (_showResumeHint && _resumeHintPosition != null) {
          _startResumeHintTimer();
        }
        if (_showStartOverHint && _startOverHintPosition != null) {
          _startStartOverHintTimer();
        }
        _scheduleControlsHide();
      }
    }
  }

  void _maybeAutoLoadOnlineDanmaku() {
    final appState = widget.appState;
    if (!appState.danmakuEnabled) return;
    if (appState.danmakuLoadMode != DanmakuLoadMode.online) return;
    if (kIsWeb) return;
    // ignore: unawaited_futures
    _loadOnlineDanmakuForNetwork(showToast: false);
  }

  static bool _looksLikeIntroChapterName(String raw) {
    final name = raw.trim().toLowerCase();
    if (name.isEmpty) return false;
    if (name.contains('片头')) return true;
    if (name.contains('intro') || name.contains('opening')) return true;
    if (RegExp(r'\bop\b').hasMatch(name)) return true;
    return false;
  }

  static IntroTimestamps? _introFromChapters(List<ChapterInfo> chapters) {
    if (chapters.length < 2) return null;
    final sorted = List<ChapterInfo>.from(chapters)
      ..sort((a, b) => a.startTicks.compareTo(b.startTicks));
    for (var i = 0; i < sorted.length - 1; i++) {
      final cur = sorted[i];
      if (!_looksLikeIntroChapterName(cur.name)) continue;
      final next = sorted[i + 1];
      final intro = IntroTimestamps(
        startTicks: cur.startTicks,
        endTicks: next.startTicks,
      );
      if (!intro.isValid) continue;
      if (intro.end - intro.start > const Duration(minutes: 10)) continue;
      return intro;
    }
    return null;
  }

  Future<void> _loadIntroTimestampsBestEffort() async {
    if (!widget.appState.autoSkipIntro) return;
    final access = _serverAccess;
    if (access == null) return;

    final seq = _introSeq;

    try {
      final ts = await access.adapter.fetchIntroTimestamps(
        access.auth,
        itemId: widget.itemId,
      );
      if (!mounted || seq != _introSeq) return;
      if (ts != null && ts.isValid) {
        _introTimestamps = ts;
        _maybeUpdateSkipIntroPrompt(_lastPosition);
        return;
      }
    } catch (_) {
      // Ignore unsupported endpoints or transient errors.
    }

    try {
      final chapters = await access.adapter
          .fetchChapters(access.auth, itemId: widget.itemId);
      if (!mounted || seq != _introSeq) return;
      final ts = _introFromChapters(chapters);
      if (ts == null) return;
      _introTimestamps = ts;
      _maybeUpdateSkipIntroPrompt(_lastPosition);
    } catch (_) {
      // Ignore chapter failures.
    }
  }

  void _maybeUpdateSkipIntroPrompt(Duration pos) {
    if (_skipIntroHandled ||
        !_skipIntroPromptVisible && !widget.appState.autoSkipIntro) {
      return;
    }

    final ts = _introTimestamps;
    if (ts == null || !ts.isValid || !widget.appState.autoSkipIntro) {
      if (_skipIntroPromptVisible) {
        setState(() => _skipIntroPromptVisible = false);
      }
      return;
    }

    final start = ts.start;
    final end = ts.end;
    if (pos > end) {
      if (_skipIntroPromptVisible) {
        setState(() => _skipIntroPromptVisible = false);
      }
      _skipIntroHandled = true;
      return;
    }

    final inIntro = pos >= start && pos <= end;
    if (inIntro && !_skipIntroPromptVisible) {
      setState(() => _skipIntroPromptVisible = true);
    } else if (!inIntro && _skipIntroPromptVisible) {
      setState(() => _skipIntroPromptVisible = false);
    }
  }

  void _dismissSkipIntroPrompt() {
    if (_skipIntroHandled) return;
    _skipIntroHandled = true;
    if (_skipIntroPromptVisible) {
      setState(() => _skipIntroPromptVisible = false);
    }
  }

  Future<void> _skipIntro() async {
    final ts = _introTimestamps;
    if (ts == null || !ts.isValid) return;

    _skipIntroHandled = true;
    if (mounted) setState(() => _skipIntroPromptVisible = false);

    final target = _safeSeekTarget(ts.end, _playerService.duration);
    await _playerService.seek(target, flushBuffer: _flushBufferOnSeek);
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

    var fileName = widget.title;
    int fileSizeBytes = 0;
    int videoDurationSeconds = 0;
    try {
      final access =
          resolveServerAccess(appState: appState, server: widget.server);
      if (access != null) {
        final item = await access.adapter
            .fetchItemDetail(access.auth, itemId: widget.itemId);
        fileName = _buildDanmakuMatchName(item);
        fileSizeBytes = item.sizeBytes ?? 0;
        final ticks = item.runTimeTicks ?? 0;
        if (ticks > 0) {
          videoDurationSeconds = (ticks / 10000000).round().clamp(0, 1 << 31);
        }
      }
    } catch (_) {}

    if (videoDurationSeconds <= 0) {
      videoDurationSeconds = _playerService.duration.inSeconds;
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
        _syncDanmakuCursor(_lastPosition);
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

  Future<void> _manualMatchOnlineDanmakuForCurrent({
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

    var matchName = widget.title;
    try {
      final access = _serverAccess;
      if (access != null) {
        final item = await access.adapter.fetchItemDetail(
          access.auth,
          itemId: widget.itemId,
        );
        matchName = _buildDanmakuMatchName(item);
      }
    } catch (_) {}

    final fallbackKeyword = stripFileExtension(matchName);
    final hint = suggestDandanplaySearchInput(fallbackKeyword);
    if (!mounted) return;
    final candidate = await showDanmakuManualSearchDialog(
      context: context,
      apiUrls: appState.danmakuApiUrls,
      appId: appState.danmakuAppId,
      appSecret: appState.danmakuAppSecret,
      initialKeyword: hint.keyword.isEmpty ? fallbackKeyword : hint.keyword,
      initialEpisodeHint: null,
    );
    if (!mounted || candidate == null) return;

    try {
      final title = '${candidate.animeTitle} ${candidate.episodeTitle}'.trim();
      final source = await loadOnlineDanmakuByEpisodeId(
        apiUrl: candidate.inputBaseUrl,
        episodeId: candidate.episodeId,
        sourceHost: candidate.sourceHost,
        title: title,
        chConvert: appState.danmakuChConvert,
        mergeRelated: appState.danmakuMergeRelated,
        appId: appState.danmakuAppId,
        appSecret: appState.danmakuAppSecret,
      );
      if (!mounted) return;
      if (source == null) {
        if (showToast) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('该条目未返回可用弹幕')),
          );
        }
        return;
      }

      final processed = processDanmakuSources(
        [source],
        blockWords: appState.danmakuBlockWords,
        mergeDuplicates: appState.danmakuMergeDuplicates,
      );
      if (processed.isEmpty) {
        if (showToast) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('弹幕已加载但被过滤规则全部移除')),
          );
        }
        return;
      }

      setState(() {
        _danmakuSources.addAll(processed);
        _danmakuSourceIndex = _danmakuSources.length - 1;
        _danmakuEnabled = true;
        _rebuildDanmakuHeatmap();
        _syncDanmakuCursor(_lastPosition);
      });

      if (showToast) {
        final displayTitle = title.isEmpty ? 'episodeId=${candidate.episodeId}' : title;
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('已手动匹配并加载弹幕：$displayTitle')),
        );
      }
    } catch (e) {
      if (showToast && mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('手动匹配加载失败：$e')),
        );
      }
    }
  }

  void _maybeApplyInitialTracks(Tracks tracks) {
    final player = _playerService.isInitialized ? _playerService.player : null;
    if (player == null) return;

    if (!_appliedAudioPref) {
      if (_selectedAudioStreamIndex != null) {
        final target = _selectedAudioStreamIndex!.toString();
        for (final a in tracks.audio) {
          if (a.id == target) {
            player.setAudioTrack(a);
            break;
          }
        }
      } else {
        final pref = widget.appState.preferredAudioLang;
        final picked = pickPreferredAudioTrack(tracks, pref);
        if (picked != null) {
          player.setAudioTrack(picked);
        }
      }
      _appliedAudioPref = true;
    }

    if (!_appliedSubtitlePref) {
      if (_selectedSubtitleStreamIndex != null) {
        if (_selectedSubtitleStreamIndex == -1) {
          player.setSubtitleTrack(SubtitleTrack.no());
        } else {
          final target = _selectedSubtitleStreamIndex!.toString();
          for (final s in tracks.subtitle) {
            if (s.id == target) {
              player.setSubtitleTrack(s);
              break;
            }
          }
        }
      } else {
        final pref = widget.appState.preferredSubtitleLang;
        if (isSubtitleOffPreference(pref)) {
          player.setSubtitleTrack(SubtitleTrack.no());
        } else {
          final picked = pickPreferredSubtitleTrack(tracks, pref);
          if (picked != null) {
            player.setSubtitleTrack(picked);
          }
        }
      }
      _appliedSubtitlePref = true;
    }
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
    if (seriesName.isNotEmpty) return seriesName;
    final name = item.name.trim();
    final raw = name.isNotEmpty ? name : widget.title;
    final hint = suggestDandanplaySearchInput(stripFileExtension(raw));
    return hint.keyword.isNotEmpty ? hint.keyword : raw;
  }

  bool get _canShowEpisodePickerButton {
    if (_episodePickerVisible) return true;
    if (_episodePickerItemLoading) return true;
    final seriesId = (_episodePickerItem?.seriesId ?? '').trim();
    return seriesId.isNotEmpty;
  }

  Future<void> _loadEpisodePickerItem() async {
    if (_episodePickerItemLoading || _episodePickerItem != null) return;
    final baseUrl = _baseUrl;
    final token = _token;
    final userId = _userId;
    if (baseUrl == null || token == null || userId == null) return;

    setState(() => _episodePickerItemLoading = true);
    final access = _serverAccess;
    if (access == null) {
      if (mounted) {
        setState(() => _episodePickerItemLoading = false);
      }
      return;
    }

    try {
      final detail = await access.adapter
          .fetchItemDetail(access.auth, itemId: widget.itemId);
      if (!mounted) return;
      setState(() => _episodePickerItem = detail);
    } catch (_) {
      // Optional: if this fails, we simply hide the entry point.
    } finally {
      if (mounted) {
        setState(() => _episodePickerItemLoading = false);
      }
    }
  }

  String _seasonLabel(MediaItem season, int index) {
    final name = season.name.trim();
    final seasonNo = season.seasonNumber ?? season.episodeNumber;
    return seasonNo != null
        ? '第$seasonNo季'
        : (name.isNotEmpty ? name : '第${index + 1}季');
  }

  Future<void> _toggleEpisodePicker() async {
    if (_episodePickerVisible) {
      setState(() => _episodePickerVisible = false);
      return;
    }

    _showControls(scheduleHide: false);
    setState(() {
      _episodePickerVisible = true;
      _episodePickerError = null;
    });
    await _ensureEpisodePickerLoaded();
  }

  Future<void> _ensureEpisodePickerLoaded() async {
    if (_episodePickerLoading) return;

    final baseUrl = _baseUrl;
    final token = _token;
    final userId = _userId;
    if (baseUrl == null || token == null || userId == null) {
      setState(() => _episodePickerError = '未连接服务器');
      return;
    }

    setState(() {
      _episodePickerLoading = true;
      _episodePickerError = null;
    });

    try {
      await _loadEpisodePickerItem();
      final detail = _episodePickerItem;
      final seriesId = (detail?.seriesId ?? '').trim();
      if (seriesId.isEmpty) {
        throw Exception('当前不是剧集，无法选集');
      }

      final access = _serverAccess;
      if (access == null) {
        throw Exception('Not connected');
      }

      final seasons =
          await access.adapter.fetchSeasons(access.auth, seriesId: seriesId);
      final seasonItems =
          seasons.items.where((s) => s.type.toLowerCase() == 'season').toList();
      seasonItems.sort((a, b) {
        final aNo = a.seasonNumber ?? a.episodeNumber ?? 0;
        final bNo = b.seasonNumber ?? b.episodeNumber ?? 0;
        return aNo.compareTo(bNo);
      });

      final seasonsVirtual = seasonItems.isEmpty;
      final seasonsForUi = seasonsVirtual
          ? [
              MediaItem(
                id: seriesId,
                name: '第1季',
                type: 'Season',
                overview: '',
                communityRating: null,
                premiereDate: null,
                genres: const [],
                runTimeTicks: null,
                sizeBytes: null,
                container: null,
                providerIds: const {},
                seriesId: seriesId,
                seriesName: (detail?.seriesName ?? '').trim().isNotEmpty
                    ? detail!.seriesName
                    : detail?.name ?? '',
                seasonName: '第1季',
                seasonNumber: 1,
                episodeNumber: null,
                hasImage: detail?.hasImage ?? false,
                playbackPositionTicks: 0,
                people: const [],
                parentId: seriesId,
              ),
            ]
          : seasonItems;

      final previousSelected = _episodeSelectedSeasonId;
      final currentSeasonId = (detail?.parentId ?? '').trim();
      final defaultSeasonId = (currentSeasonId.isNotEmpty &&
              seasonsForUi.any((s) => s.id == currentSeasonId))
          ? currentSeasonId
          : (seasonsForUi.isNotEmpty ? seasonsForUi.first.id : '');
      final selectedSeasonId = (previousSelected != null &&
              seasonsForUi.any((s) => s.id == previousSelected))
          ? previousSelected
          : (defaultSeasonId.isNotEmpty ? defaultSeasonId : null);

      if (!mounted) return;
      setState(() {
        _episodeSeasons = seasonsForUi;
        _episodeSelectedSeasonId = selectedSeasonId;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() => _episodePickerError = e.toString());
    } finally {
      if (mounted) {
        setState(() => _episodePickerLoading = false);
      }
    }
  }

  Future<List<MediaItem>> _episodesForSeasonId(String seasonId) async {
    final cached = _episodeEpisodesCache[seasonId];
    if (cached != null) return cached;

    final baseUrl = _baseUrl;
    final token = _token;
    final userId = _userId;
    if (baseUrl == null || token == null || userId == null) {
      throw Exception('未连接服务器');
    }

    final access = _serverAccess;
    if (access == null) {
      throw Exception('Not connected');
    }

    final eps =
        await access.adapter.fetchEpisodes(access.auth, seasonId: seasonId);
    final items = List<MediaItem>.from(eps.items);
    items.sort((a, b) {
      final aNo = a.episodeNumber ?? 0;
      final bNo = b.episodeNumber ?? 0;
      return aNo.compareTo(bNo);
    });
    _episodeEpisodesCache[seasonId] = items;
    return items;
  }

  Future<List<MediaItem>> _episodesFutureForSeasonId(String seasonId) {
    final cachedFuture = _episodeEpisodesFutureCache[seasonId];
    if (cachedFuture != null) return cachedFuture;

    final cached = _episodeEpisodesCache[seasonId];
    final future = cached != null
        ? Future<List<MediaItem>>.value(cached)
        : _episodesForSeasonId(seasonId);
    _episodeEpisodesFutureCache[seasonId] = future;
    return future;
  }

  void _playEpisodeFromPicker(MediaItem episode) {
    if (episode.id == widget.itemId) {
      setState(() => _episodePickerVisible = false);
      return;
    }

    setState(() => _episodePickerVisible = false);
    final ticks = episode.playbackPositionTicks;
    final start =
        ticks > 0 ? Duration(microseconds: (ticks / 10).round()) : null;
    final episodeSeriesId = (episode.seriesId ?? '').trim();
    Navigator.of(context).pushReplacement(
      MaterialPageRoute(
        builder: (_) => PlayNetworkPage(
          title: episode.name,
          itemId: episode.id,
          appState: widget.appState,
          server: widget.server,
          isTv: widget.isTv,
          seriesId:
              episodeSeriesId.isNotEmpty ? episodeSeriesId : widget.seriesId,
          startPosition: start,
          resumeImmediately: true,
          audioStreamIndex: _selectedAudioStreamIndex,
          subtitleStreamIndex: _selectedSubtitleStreamIndex,
        ),
      ),
    );
  }

  Widget _buildEpisodePickerOverlay({required bool enableBlur}) {
    final size = MediaQuery.sizeOf(context);
    final drawerWidth = math.min(
      420.0,
      size.width * (size.width > size.height ? 0.50 : 0.78),
    );

    final theme = Theme.of(context);
    final accent = theme.colorScheme.secondary;
    final showTitle = widget.appState.episodePickerShowTitle;

    final seasons = _episodeSeasons;
    final selectedSeasonId = _episodeSelectedSeasonId;
    MediaItem? selectedSeason;
    if (selectedSeasonId != null && selectedSeasonId.isNotEmpty) {
      for (final s in seasons) {
        if (s.id == selectedSeasonId) {
          selectedSeason = s;
          break;
        }
      }
    }
    selectedSeason ??= seasons.isNotEmpty ? seasons.first : null;

    return Positioned.fill(
      child: Stack(
        children: [
          IgnorePointer(
            ignoring: !_episodePickerVisible,
            child: AnimatedOpacity(
              opacity: _episodePickerVisible ? 1 : 0,
              duration: const Duration(milliseconds: 180),
              child: GestureDetector(
                behavior: HitTestBehavior.opaque,
                onTap: () => setState(() => _episodePickerVisible = false),
                child: ColoredBox(
                  color: Colors.black.withValues(alpha: 0.25),
                  child: const SizedBox.expand(),
                ),
              ),
            ),
          ),
          AnimatedPositioned(
            duration: const Duration(milliseconds: 220),
            curve: Curves.easeOutCubic,
            top: 0,
            bottom: 0,
            right: _episodePickerVisible ? 0 : -drawerWidth,
            width: drawerWidth,
            child: IgnorePointer(
              ignoring: !_episodePickerVisible,
              child: SafeArea(
                left: false,
                child: GlassCard(
                  enableBlur: enableBlur,
                  margin: EdgeInsets.zero,
                  elevation: 0,
                  shadowColor: Colors.transparent,
                  surfaceTintColor: Colors.transparent,
                  color: Colors.black.withValues(alpha: 0.35),
                  shape: const RoundedRectangleBorder(
                    borderRadius: BorderRadius.horizontal(
                      left: Radius.circular(16),
                    ),
                  ),
                  child: Column(
                    children: [
                      Padding(
                        padding: const EdgeInsets.fromLTRB(12, 10, 8, 8),
                        child: Row(
                          children: [
                            const Icon(
                              Icons.format_list_numbered,
                              color: Colors.white,
                              size: 18,
                            ),
                            const SizedBox(width: 8),
                            const Text(
                              '选集',
                              style: TextStyle(
                                color: Colors.white,
                                fontWeight: FontWeight.w700,
                              ),
                            ),
                            const SizedBox(width: 8),
                            if (selectedSeason != null)
                              Expanded(
                                child: Container(
                                  height: 36,
                                  padding:
                                      const EdgeInsets.symmetric(horizontal: 8),
                                  decoration: BoxDecoration(
                                    color: Colors.black.withValues(alpha: 0.18),
                                    borderRadius: BorderRadius.circular(10),
                                    border: Border.all(
                                      color:
                                          Colors.white.withValues(alpha: 0.12),
                                    ),
                                  ),
                                  child: DropdownButtonHideUnderline(
                                    child: DropdownButton<String>(
                                      value: selectedSeason.id,
                                      isExpanded: true,
                                      isDense: true,
                                      dropdownColor: const Color(0xFF202020),
                                      iconEnabledColor: Colors.white70,
                                      style: const TextStyle(
                                        color: Colors.white,
                                        fontSize: 12,
                                      ),
                                      items: [
                                        for (final entry
                                            in seasons.asMap().entries)
                                          DropdownMenuItem(
                                            value: entry.value.id,
                                            child: Text(
                                              _seasonLabel(
                                                entry.value,
                                                entry.key,
                                              ),
                                              maxLines: 1,
                                              overflow: TextOverflow.ellipsis,
                                            ),
                                          ),
                                      ],
                                      onChanged: (v) {
                                        if (v == null || v.isEmpty) return;
                                        if (v == _episodeSelectedSeasonId) {
                                          return;
                                        }
                                        setState(() {
                                          _episodeSelectedSeasonId = v;
                                        });
                                      },
                                    ),
                                  ),
                                ),
                              )
                            else
                              const Spacer(),
                            IconButton(
                              tooltip: showTitle ? '仅显示集数' : '显示标题+封面',
                              icon: Icon(
                                showTitle
                                    ? Icons.grid_view_outlined
                                    : Icons.view_agenda_outlined,
                              ),
                              color: Colors.white,
                              onPressed: () {
                                final next =
                                    !widget.appState.episodePickerShowTitle;
                                // ignore: unawaited_futures
                                widget.appState.setEpisodePickerShowTitle(next);
                                setState(() {});
                              },
                            ),
                            IconButton(
                              tooltip: '关闭',
                              icon: const Icon(Icons.close),
                              color: Colors.white,
                              onPressed: () =>
                                  setState(() => _episodePickerVisible = false),
                            ),
                          ],
                        ),
                      ),
                      if (_episodePickerLoading)
                        const Padding(
                          padding: EdgeInsets.all(16),
                          child: Center(child: CircularProgressIndicator()),
                        )
                      else if (_episodePickerError != null)
                        Padding(
                          padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.stretch,
                            children: [
                              Text(
                                _episodePickerError!,
                                style: const TextStyle(color: Colors.white70),
                              ),
                              const SizedBox(height: 10),
                              OutlinedButton.icon(
                                onPressed: _ensureEpisodePickerLoaded,
                                icon: const Icon(Icons.refresh),
                                label: const Text('重试'),
                              ),
                            ],
                          ),
                        )
                      else if (selectedSeason == null)
                        const Padding(
                          padding: EdgeInsets.all(16),
                          child: Text(
                            '暂无剧集信息',
                            style: TextStyle(color: Colors.white70),
                          ),
                        )
                      else ...[
                        Expanded(
                          child: FutureBuilder<List<MediaItem>>(
                            future:
                                _episodesFutureForSeasonId(selectedSeason.id),
                            builder: (ctx, snapshot) {
                              if (snapshot.connectionState !=
                                  ConnectionState.done) {
                                return const Center(
                                  child: CircularProgressIndicator(),
                                );
                              }
                              if (snapshot.hasError) {
                                return Padding(
                                  padding:
                                      const EdgeInsets.fromLTRB(16, 0, 16, 16),
                                  child: Column(
                                    crossAxisAlignment:
                                        CrossAxisAlignment.stretch,
                                    children: [
                                      Text(
                                        '加载失败：${snapshot.error}',
                                        style: const TextStyle(
                                          color: Colors.white70,
                                        ),
                                      ),
                                      const SizedBox(height: 10),
                                      OutlinedButton.icon(
                                        onPressed: () => setState(() {
                                          final season = selectedSeason;
                                          if (season == null) return;
                                          _episodeEpisodesCache
                                              .remove(season.id);
                                          _episodeEpisodesFutureCache
                                              .remove(season.id);
                                        }),
                                        icon: const Icon(Icons.refresh),
                                        label: const Text('重试'),
                                      ),
                                    ],
                                  ),
                                );
                              }

                              final eps = snapshot.data ?? const <MediaItem>[];
                              if (eps.isEmpty) {
                                return const Center(
                                  child: Text(
                                    '暂无剧集',
                                    style: TextStyle(color: Colors.white70),
                                  ),
                                );
                              }

                              if (showTitle) {
                                return ListView.separated(
                                  padding: const EdgeInsets.fromLTRB(
                                    12,
                                    0,
                                    12,
                                    12,
                                  ),
                                  itemCount: eps.length,
                                  separatorBuilder: (_, __) =>
                                      const SizedBox(height: 10),
                                  itemBuilder: (ctx, index) {
                                    final e = eps[index];
                                    final epNo = e.episodeNumber ?? (index + 1);
                                    final isCurrent = e.id == widget.itemId;
                                    final borderColor = isCurrent
                                        ? accent.withValues(alpha: 0.85)
                                        : Colors.white.withValues(alpha: 0.10);
                                    final access = _serverAccess;
                                    final img = access?.adapter.imageUrl(
                                      access.auth,
                                      itemId: e.hasImage
                                          ? e.id
                                          : selectedSeason!.id,
                                      maxWidth: 520,
                                    );
                                    final title = e.name.trim().isNotEmpty
                                        ? e.name.trim()
                                        : '第$epNo集';
                                    return Material(
                                      color:
                                          Colors.black.withValues(alpha: 0.18),
                                      shape: RoundedRectangleBorder(
                                        borderRadius: BorderRadius.circular(12),
                                        side: BorderSide(color: borderColor),
                                      ),
                                      clipBehavior: Clip.antiAlias,
                                      child: InkWell(
                                        onTap: () => _playEpisodeFromPicker(e),
                                        child: Padding(
                                          padding: const EdgeInsets.all(10),
                                          child: Row(
                                            children: [
                                              ClipRRect(
                                                borderRadius:
                                                    BorderRadius.circular(10),
                                                child: SizedBox(
                                                  width: 110,
                                                  height: 62,
                                                  child: Stack(
                                                    fit: StackFit.expand,
                                                    children: [
                                                      if (img != null)
                                                        Image.network(
                                                          img,
                                                          fit: BoxFit.cover,
                                                          errorBuilder:
                                                              (_, __, ___) {
                                                            return const ColoredBox(
                                                              color: Color(
                                                                0x22000000,
                                                              ),
                                                              child: Center(
                                                                child: Icon(
                                                                  Icons
                                                                      .image_not_supported_outlined,
                                                                  color: Colors
                                                                      .white54,
                                                                ),
                                                              ),
                                                            );
                                                          },
                                                        )
                                                      else
                                                        const ColoredBox(
                                                          color:
                                                              Color(0x22000000),
                                                          child: Center(
                                                            child: Icon(
                                                              Icons
                                                                  .image_outlined,
                                                              color: Colors
                                                                  .white54,
                                                            ),
                                                          ),
                                                        ),
                                                      Positioned(
                                                        left: 6,
                                                        bottom: 6,
                                                        child: DecoratedBox(
                                                          decoration:
                                                              BoxDecoration(
                                                            color: const Color(
                                                              0xAA000000,
                                                            ),
                                                            borderRadius:
                                                                BorderRadius
                                                                    .circular(
                                                              6,
                                                            ),
                                                          ),
                                                          child: Padding(
                                                            padding:
                                                                const EdgeInsets
                                                                    .symmetric(
                                                              horizontal: 6,
                                                              vertical: 3,
                                                            ),
                                                            child: Text(
                                                              'E$epNo',
                                                              style:
                                                                  const TextStyle(
                                                                color: Colors
                                                                    .white,
                                                                fontSize: 11,
                                                                fontWeight:
                                                                    FontWeight
                                                                        .w700,
                                                              ),
                                                            ),
                                                          ),
                                                        ),
                                                      ),
                                                      if (isCurrent)
                                                        const Positioned(
                                                          right: 6,
                                                          top: 6,
                                                          child: Icon(
                                                            Icons.play_circle,
                                                            color: Colors.white,
                                                          ),
                                                        ),
                                                    ],
                                                  ),
                                                ),
                                              ),
                                              const SizedBox(width: 12),
                                              Expanded(
                                                child: Text(
                                                  title,
                                                  maxLines: 2,
                                                  overflow:
                                                      TextOverflow.ellipsis,
                                                  style: const TextStyle(
                                                    color: Colors.white,
                                                    fontSize: 12,
                                                    fontWeight: FontWeight.w600,
                                                  ),
                                                ),
                                              ),
                                            ],
                                          ),
                                        ),
                                      ),
                                    );
                                  },
                                );
                              }

                              final columns = drawerWidth >= 360 ? 4 : 3;

                              return GridView.builder(
                                padding: const EdgeInsets.fromLTRB(
                                  12,
                                  0,
                                  12,
                                  12,
                                ),
                                gridDelegate:
                                    SliverGridDelegateWithFixedCrossAxisCount(
                                  crossAxisCount: columns,
                                  crossAxisSpacing: 10,
                                  mainAxisSpacing: 10,
                                  childAspectRatio: 2.2,
                                ),
                                itemCount: eps.length,
                                itemBuilder: (ctx, index) {
                                  final e = eps[index];
                                  final epNo = e.episodeNumber ?? (index + 1);
                                  final isCurrent = e.id == widget.itemId;
                                  final borderColor = isCurrent
                                      ? accent.withValues(alpha: 0.85)
                                      : Colors.white.withValues(alpha: 0.10);

                                  return Material(
                                    color: Colors.black.withValues(alpha: 0.18),
                                    shape: RoundedRectangleBorder(
                                      borderRadius: BorderRadius.circular(12),
                                      side: BorderSide(color: borderColor),
                                    ),
                                    clipBehavior: Clip.antiAlias,
                                    child: InkWell(
                                      onTap: () => _playEpisodeFromPicker(e),
                                      child: Stack(
                                        fit: StackFit.expand,
                                        children: [
                                          Center(
                                            child: Text(
                                              'E$epNo',
                                              style: const TextStyle(
                                                color: Colors.white,
                                                fontSize: 16,
                                                fontWeight: FontWeight.w800,
                                                letterSpacing: 0.2,
                                              ),
                                            ),
                                          ),
                                          if (isCurrent)
                                            const Positioned(
                                              right: 6,
                                              top: 6,
                                              child: Icon(
                                                Icons.play_circle,
                                                color: Colors.white,
                                              ),
                                            ),
                                        ],
                                      ),
                                    ),
                                  );
                                },
                              );
                            },
                          ),
                        ),
                      ],
                    ],
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
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
    final duration = _playerService.duration;
    if (duration <= Duration.zero ||
        _danmakuSourceIndex < 0 ||
        _danmakuSourceIndex >= _danmakuSources.length) {
      _danmakuHeatmap = const [];
      return;
    }
    _danmakuHeatmap = buildDanmakuHeatmap(
      _danmakuSources[_danmakuSourceIndex].items,
      duration: duration,
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
      _syncDanmakuCursor(_lastPosition);
    });
  }

  Future<void> _showDanmakuSheet() async {
    await showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      builder: (ctx) {
        var onlineLoading = false;
        var manualLoading = false;
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
                        label: const Text('加载'),
                      ),
                    ],
                  ),
                  Align(
                    alignment: Alignment.centerRight,
                    child: TextButton.icon(
                      onPressed: onlineLoading
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
                              child: CircularProgressIndicator(strokeWidth: 2),
                            )
                          : const Icon(Icons.cloud_download_outlined),
                      label: const Text('在线加载'),
                    ),
                  ),
                  Align(
                    alignment: Alignment.centerRight,
                    child: TextButton.icon(
                      onPressed: manualLoading || onlineLoading || _loading
                          ? null
                          : () async {
                              manualLoading = true;
                              setSheetState(() {});
                              try {
                                await _manualMatchOnlineDanmakuForCurrent(
                                  showToast: true,
                                );
                              } finally {
                                manualLoading = false;
                                setSheetState(() {});
                              }
                            },
                      icon: manualLoading
                          ? const SizedBox(
                              width: 18,
                              height: 18,
                              child: CircularProgressIndicator(strokeWidth: 2),
                            )
                          : const Icon(Icons.search),
                      label: const Text('手动匹配'),
                    ),
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
                                  _rebuildDanmakuHeatmap();
                                  _syncDanmakuCursor(_lastPosition);
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
                    subtitle: AppSlider(
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

  Future<String> _buildStreamUrl() async {
    final base = _baseUrl!;
    final token = _token!;
    final userId = _userId!;
    _playSessionId = null;
    _mediaSourceId = null;
    _resolvedStreamSizeBytes = null;
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
      final access = _serverAccess;
      if (access == null) throw Exception('Not connected');
      final info = await access.adapter
          .fetchPlaybackInfo(access.auth, itemId: widget.itemId);
      final sources = info.mediaSources.cast<Map<String, dynamic>>();
      _availableMediaSources = List<Map<String, dynamic>>.from(sources);
      Map<String, dynamic>? ms;
      if (sources.isNotEmpty) {
        var selectedId = (_selectedMediaSourceId ?? '').trim();
        if (selectedId.isEmpty) {
          final sid = (widget.seriesId ?? '').trim();
          final serverId = widget.server?.id ?? widget.appState.activeServerId;
          if (serverId != null && serverId.isNotEmpty && sid.isNotEmpty) {
            final idx = widget.appState
                .seriesMediaSourceIndex(serverId: serverId, seriesId: sid);
            if (idx != null && idx >= 0 && idx < sources.length) {
              selectedId = (sources[idx]['Id'] as String? ?? '').trim();
            }
          }
        }
        if (selectedId.isEmpty) {
          final preferredId = _pickPreferredMediaSourceId(
            sources,
            widget.appState.preferredVideoVersion,
          );
          if (preferredId != null && preferredId.trim().isNotEmpty) {
            selectedId = preferredId.trim();
          }
        }
        if (selectedId.isNotEmpty) {
          ms = sources.firstWhere(
            (s) => (s['Id'] as String? ?? '') == selectedId,
            orElse: () => sources.first,
          );
          _selectedMediaSourceId = selectedId;
        } else {
          ms = sources.first;
        }
      }
      _playSessionId = info.playSessionId;
      _mediaSourceId = (ms?['Id'] as String?) ?? info.mediaSourceId;
      _resolvedStreamSizeBytes = _asInt(ms?['Size']);
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

  static int _compareMediaSourcesByQuality(
    Map<String, dynamic> a,
    Map<String, dynamic> b,
  ) {
    int heightOf(Map<String, dynamic> ms) {
      final videos = _streamsOfType(ms, 'Video');
      final video = videos.isNotEmpty ? videos.first : null;
      return _asInt(video?['Height']) ?? 0;
    }

    int bitrateOf(Map<String, dynamic> ms) => _asInt(ms['Bitrate']) ?? 0;

    int sizeOf(Map<String, dynamic> ms) {
      final v = ms['Size'];
      if (v is int) return v;
      if (v is num) return v.toInt();
      if (v is String) return int.tryParse(v) ?? 0;
      return 0;
    }

    final h = heightOf(b) - heightOf(a);
    if (h != 0) return h;
    final br = bitrateOf(b) - bitrateOf(a);
    if (br != 0) return br;
    return sizeOf(b) - sizeOf(a);
  }

  static String? _pickPreferredMediaSourceId(
    List<Map<String, dynamic>> sources,
    VideoVersionPreference pref,
  ) {
    if (sources.isEmpty) return null;
    if (pref == VideoVersionPreference.defaultVersion) return null;

    int heightOf(Map<String, dynamic> ms) {
      final videos = _streamsOfType(ms, 'Video');
      final video = videos.isNotEmpty ? videos.first : null;
      return _asInt(video?['Height']) ?? 0;
    }

    int bitrateOf(Map<String, dynamic> ms) => _asInt(ms['Bitrate']) ?? 0;

    String videoCodecOf(Map<String, dynamic> ms) {
      final msCodec = (ms['VideoCodec'] as String?)?.trim();
      if (msCodec != null && msCodec.isNotEmpty) return msCodec.toLowerCase();
      final videos = _streamsOfType(ms, 'Video');
      final v = videos.isNotEmpty ? videos.first : null;
      final codec = (v?['Codec'] as String?)?.trim() ?? '';
      return codec.toLowerCase();
    }

    bool isHevc(Map<String, dynamic> ms) {
      final c = videoCodecOf(ms);
      return c.contains('hevc') ||
          c.contains('h265') ||
          c.contains('h.265') ||
          c.contains('x265');
    }

    bool isAvc(Map<String, dynamic> ms) {
      final c = videoCodecOf(ms);
      return c.contains('avc') ||
          c.contains('h264') ||
          c.contains('h.264') ||
          c.contains('x264');
    }

    Map<String, dynamic>? pickBest(
      List<Map<String, dynamic>> list, {
      required int Function(Map<String, dynamic> ms) primary,
      required int Function(Map<String, dynamic> ms) secondary,
      required bool higherIsBetter,
    }) {
      if (list.isEmpty) return null;
      Map<String, dynamic> chosen = list.first;
      var bestPrimary = primary(chosen);
      var bestSecondary = secondary(chosen);
      for (final ms in list.skip(1)) {
        final p = primary(ms);
        final s = secondary(ms);
        final better = higherIsBetter
            ? (p > bestPrimary || (p == bestPrimary && s > bestSecondary))
            : (p < bestPrimary || (p == bestPrimary && s < bestSecondary));
        if (better) {
          chosen = ms;
          bestPrimary = p;
          bestSecondary = s;
        }
      }
      return chosen;
    }

    Map<String, dynamic>? chosen;
    switch (pref) {
      case VideoVersionPreference.highestResolution:
        chosen = pickBest(
          sources,
          primary: heightOf,
          secondary: bitrateOf,
          higherIsBetter: true,
        );
        break;
      case VideoVersionPreference.lowestBitrate:
        chosen = pickBest(
          sources,
          primary: (ms) => bitrateOf(ms) == 0 ? 1 << 30 : bitrateOf(ms),
          secondary: heightOf,
          higherIsBetter: false,
        );
        break;
      case VideoVersionPreference.preferHevc:
        final hevc = sources.where(isHevc).toList();
        chosen = pickBest(
          hevc.isNotEmpty ? hevc : sources,
          primary: heightOf,
          secondary: bitrateOf,
          higherIsBetter: true,
        );
        break;
      case VideoVersionPreference.preferAvc:
        final avc = sources.where(isAvc).toList();
        chosen = pickBest(
          avc.isNotEmpty ? avc : sources,
          primary: heightOf,
          secondary: bitrateOf,
          higherIsBetter: true,
        );
        break;
      case VideoVersionPreference.defaultVersion:
        break;
    }

    final id = chosen?['Id']?.toString();
    return (id == null || id.trim().isEmpty) ? null : id.trim();
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
        _maybeReportPlaybackProgress(_lastPosition, force: true);
      }
      setState(() {});
    });
  }

  void _startStartOverHintTimer() {
    _startOverHintTimer?.cancel();
    _startOverHintTimer = Timer(const Duration(seconds: 5), () {
      if (!mounted) return;
      if (!_showStartOverHint) return;
      _showStartOverHint = false;
      setState(() {});
    });
  }

  Future<void> _restartFromBeginning() async {
    if (!_playerService.isInitialized) return;
    _showControls(scheduleHide: false);

    try {
      await _playerService.seek(
        Duration.zero,
        flushBuffer: _flushBufferOnSeek,
      );
    } catch (_) {}

    _lastPosition = Duration.zero;
    _syncDanmakuCursor(Duration.zero);
    _maybeReportPlaybackProgress(_lastPosition, force: true);

    _startOverHintTimer?.cancel();
    _startOverHintTimer = null;
    _showStartOverHint = false;
    if (mounted) setState(() {});
  }

  Future<void> _resumeToHistoryPosition() async {
    final target = _resumeHintPosition;
    if (target == null || target <= Duration.zero) return;
    if (!_playerService.isInitialized) return;

    final safeTarget = _safeSeekTarget(target, _playerService.duration);
    try {
      final seekFuture =
          _playerService.seek(safeTarget, flushBuffer: _flushBufferOnSeek);
      await seekFuture.timeout(const Duration(seconds: 3));
      _lastPosition = safeTarget;
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
      _maybeReportPlaybackProgress(_lastPosition, force: true);
    }
    if (mounted) setState(() {});
  }

  Future<void> _reportPlaybackStartBestEffort() async {
    if (_reportedStart || _reportedStop) return;
    final access = _serverAccess;
    if (access == null) return;
    if (access.auth.baseUrl.isEmpty || access.auth.token.isEmpty) return;

    _reportedStart = true;
    final posTicks = _toTicks(_lastPosition);
    final paused = !_playerService.isPlaying;
    try {
      final ps = _playSessionId;
      final ms = _mediaSourceId;
      if (ps != null && ps.isNotEmpty && ms != null && ms.isNotEmpty) {
        await access.adapter.reportPlaybackStart(
          access.auth,
          itemId: widget.itemId,
          mediaSourceId: ms,
          playSessionId: ps,
          positionTicks: posTicks,
          isPaused: paused,
        );
      }
    } catch (_) {}
  }

  void _maybeReportPlaybackProgress(Duration position, {bool force = false}) {
    if (_reportedStop) return;
    if (_deferProgressReporting) return;
    if (_progressReportInFlight) return;
    final access = _serverAccess;
    if (access == null) return;
    if (access.auth.baseUrl.isEmpty || access.auth.token.isEmpty) return;

    final now = DateTime.now();
    final paused = !_playerService.isPlaying;

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
          await access.adapter.reportPlaybackProgress(
            access.auth,
            itemId: widget.itemId,
            mediaSourceId: ms,
            playSessionId: ps,
            positionTicks: ticks,
            isPaused: paused,
          );
        } else if (access.auth.userId.isNotEmpty) {
          await access.adapter.updatePlaybackPosition(
            access.auth,
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

    final access = _serverAccess;
    if (access == null) return;
    if (access.auth.baseUrl.isEmpty || access.auth.token.isEmpty) return;

    final pos =
        _playerService.isInitialized ? _playerService.position : _lastPosition;
    final dur = _playerService.duration;
    final played = completed ||
        (dur > Duration.zero && pos >= dur - const Duration(seconds: 20));
    final ticks = _toTicks(pos);

    try {
      final ps = _playSessionId;
      final ms = _mediaSourceId;
      if (ps != null && ps.isNotEmpty && ms != null && ms.isNotEmpty) {
        await access.adapter.reportPlaybackStopped(
          access.auth,
          itemId: widget.itemId,
          mediaSourceId: ms,
          playSessionId: ps,
          positionTicks: ticks,
        );
      }
    } catch (_) {}

    try {
      if (access.auth.userId.isNotEmpty) {
        await access.adapter.updatePlaybackPosition(
          access.auth,
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

  Future<void> _exitImmersiveMode({bool resetOrientations = false}) async {
    if (!_shouldControlSystemUi) return;
    try {
      await SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
    } catch (_) {}
    if (!resetOrientations) return;
    try {
      await SystemChrome.setPreferredOrientations(const []);
    } catch (_) {}
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

  void _scheduleNetSpeedTick() {
    _netSpeedTimer?.cancel();
    _netSpeedTimer = null;

    if (!_playerService.isInitialized || _playerService.isExternalPlayback) {
      _lastTotalRxBytes = null;
      _lastTotalRxAt = null;
      if (_netSpeedBytesPerSecond != null && mounted) {
        setState(() => _netSpeedBytesPerSecond = null);
      }
      return;
    }

    final refreshSeconds =
        widget.appState.bufferSpeedRefreshSeconds.clamp(0.2, 3.0).toDouble();
    final refreshMs = (refreshSeconds * 1000).round();

    _netSpeedTimer = Timer(Duration(milliseconds: refreshMs), () async {
      if (!mounted) return;
      await _pollNetSpeed();
      if (!mounted) return;
      _scheduleNetSpeedTick();
    });
  }

  Future<void> _pollNetSpeed() async {
    if (_netSpeedPollInFlight) return;
    if (!_playerService.isInitialized || _playerService.isExternalPlayback) {
      _lastTotalRxBytes = null;
      _lastTotalRxAt = null;
      if (_netSpeedBytesPerSecond != null && mounted) {
        setState(() => _netSpeedBytesPerSecond = null);
      }
      return;
    }

    _netSpeedPollInFlight = true;
    try {
      final totalRx = await DeviceType.totalRxBytes();
      final sampleAt = DateTime.now();
      if (totalRx != null) {
        final prevBytes = _lastTotalRxBytes;
        final prevAt = _lastTotalRxAt;
        _lastTotalRxBytes = totalRx;
        _lastTotalRxAt = sampleAt;

        if (prevBytes != null && prevAt != null) {
          final dtMs = sampleAt.difference(prevAt).inMilliseconds;
          final delta = totalRx - prevBytes;
          if (dtMs > 0 && delta >= 0) {
            final next = delta * 1000.0 / dtMs;
            final prev = _netSpeedBytesPerSecond;
            final smoothed = prev == null ? next : (prev * 0.7 + next * 0.3);
            if (mounted) {
              setState(() => _netSpeedBytesPerSecond = smoothed);
            }
            return;
          }
        }
      }

      final rate = await _playerService.queryNetworkInputRateBytesPerSecond();
      if (!mounted) return;
      final next = (rate != null && rate.isFinite) ? rate : null;
      if (next == null) {
        if (_netSpeedBytesPerSecond != null) {
          setState(() => _netSpeedBytesPerSecond = null);
        }
        return;
      }

      final prev = _netSpeedBytesPerSecond;
      final smoothed = prev == null ? next : (prev * 0.7 + next * 0.3);
      setState(() => _netSpeedBytesPerSecond = smoothed);
    } finally {
      _netSpeedPollInFlight = false;
    }
  }

  @override
  void dispose() {
    if (_route != null) {
      appRouteObserver.unsubscribe(this);
      _route = null;
    }
    WidgetsBinding.instance.removeObserver(this);
    // ignore: unawaited_futures
    _reportPlaybackStoppedBestEffort();
    // ignore: unawaited_futures
    _exitImmersiveMode(resetOrientations: true);
    _resumeHintTimer?.cancel();
    _resumeHintTimer = null;
    _startOverHintTimer?.cancel();
    _startOverHintTimer = null;
    _controlsHideTimer?.cancel();
    _controlsHideTimer = null;
    _gestureOverlayTimer?.cancel();
    _gestureOverlayTimer = null;
    _tvOkLongPressTimer?.cancel();
    _tvOkLongPressTimer = null;
    _netSpeedTimer?.cancel();
    _netSpeedTimer = null;
    _errorSub?.cancel();
    _bufferingSub?.cancel();
    _bufferingPctSub?.cancel();
    _bufferSub?.cancel();
    _posSub?.cancel();
    _playingSub?.cancel();
    _completedSub?.cancel();
    _videoParamsSub?.cancel();
    final thumb = _thumbnailer;
    _thumbnailer = null;
    if (thumb != null) {
      // ignore: unawaited_futures
      thumb.dispose();
    }
    _tvSurfaceFocusNode.dispose();
    _tvPlayPauseFocusNode.dispose();
    _playerService.dispose();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state != AppLifecycleState.inactive &&
        state != AppLifecycleState.paused) {
      return;
    }
    if (widget.appState.returnHomeBehavior != ReturnHomeBehavior.pause) return;

    if (!_playerService.isInitialized) return;
    if (!_playerService.isPlaying) return;
    // ignore: unawaited_futures
    _playerService.pause();
    _applyDanmakuPauseState(true);
  }

  void _showControls({bool scheduleHide = true}) {
    if (!_controlsVisible) {
      setState(() => _controlsVisible = true);
    }
    // ignore: unawaited_futures
    _exitImmersiveMode();
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
    // ignore: unawaited_futures
    _enterImmersiveMode();
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
    // ignore: unawaited_futures
    _enterImmersiveMode();
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
      // ignore: unawaited_futures
      _enterImmersiveMode();
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

  void _setGestureOverlay({required IconData icon, required String text}) {
    _gestureOverlayTimer?.cancel();
    _gestureOverlayTimer = null;
    if (!mounted) {
      _gestureOverlayIcon = icon;
      _gestureOverlayText = text;
      return;
    }
    setState(() {
      _gestureOverlayIcon = icon;
      _gestureOverlayText = text;
    });
  }

  void _hideGestureOverlay([Duration delay = _gestureOverlayAutoHideDelay]) {
    _gestureOverlayTimer?.cancel();
    _gestureOverlayTimer = Timer(delay, () {
      if (!mounted) return;
      setState(() {
        _gestureOverlayIcon = null;
        _gestureOverlayText = null;
      });
    });
  }

  bool get _gesturesEnabled =>
      _playerService.isInitialized && !_loading && _playError == null;

  int get _seekBackSeconds => widget.appState.seekBackwardSeconds;
  int get _seekForwardSeconds => widget.appState.seekForwardSeconds;
  bool get _flushBufferOnSeek => widget.appState.flushBufferOnSeek;

  Future<void> _togglePlayPause({bool showOverlay = true}) async {
    if (!_gesturesEnabled) return;
    _showControls();
    if (_playerService.isPlaying) {
      await _playerService.pause();
      _applyDanmakuPauseState(true);
      if (showOverlay) {
        _setGestureOverlay(icon: Icons.pause, text: '暂停');
        _hideGestureOverlay();
      }
      return;
    }
    await _playerService.play();
    _applyDanmakuPauseState(false);
    if (showOverlay) {
      _setGestureOverlay(icon: Icons.play_arrow, text: '播放');
      _hideGestureOverlay();
    }
  }

  Future<void> _seekRelative(Duration delta, {bool showOverlay = true}) async {
    if (!_gesturesEnabled) return;
    final duration = _playerService.duration;
    final current = _lastPosition;
    var target = current + delta;
    if (target < Duration.zero) target = Duration.zero;
    if (duration > Duration.zero && target > duration) target = duration;

    await _playerService.seek(target, flushBuffer: _flushBufferOnSeek);
    _lastPosition = target;
    _syncDanmakuCursor(target);
    _maybeReportPlaybackProgress(target, force: true);
    if (mounted) setState(() {});

    if (showOverlay) {
      final absSeconds = delta.inSeconds.abs();
      _setGestureOverlay(
        icon: delta.isNegative ? Icons.fast_rewind : Icons.fast_forward,
        text: '${delta.isNegative ? '快退' : '快进'} ${absSeconds}s',
      );
      _hideGestureOverlay();
    }
  }

  Future<void> _handleDoubleTap(Offset localPos, double width) async {
    if (!_gesturesEnabled) return;

    final region = width <= 0
        ? 1
        : (localPos.dx < width / 3)
            ? 0
            : (localPos.dx < width * 2 / 3)
                ? 1
                : 2;

    final action = switch (region) {
      0 => widget.appState.doubleTapLeft,
      1 => widget.appState.doubleTapCenter,
      _ => widget.appState.doubleTapRight,
    };

    switch (action) {
      case DoubleTapAction.none:
        return;
      case DoubleTapAction.playPause:
        await _togglePlayPause();
        return;
      case DoubleTapAction.seekBackward:
        await _seekRelative(Duration(seconds: -_seekBackSeconds));
        return;
      case DoubleTapAction.seekForward:
        await _seekRelative(Duration(seconds: _seekForwardSeconds));
        return;
    }
  }

  void _onSeekDragStart(DragStartDetails details) {
    if (!_gesturesEnabled) return;
    if (!widget.appState.gestureSeek) return;
    _gestureMode = _GestureMode.seek;
    _gestureStartPos = details.localPosition;
    _seekGestureStartPosition = _lastPosition;
    _seekGesturePreviewPosition = _lastPosition;
    _showControls(scheduleHide: false);
    _setGestureOverlay(icon: Icons.swap_horiz, text: _fmtClock(_lastPosition));
  }

  void _onSeekDragUpdate(
    DragUpdateDetails details, {
    required double width,
    required Duration duration,
  }) {
    if (_gestureMode != _GestureMode.seek) return;
    if (_gestureStartPos == null) return;
    if (width <= 0) return;
    if (!_gesturesEnabled) return;

    final dx = details.localPosition.dx - _gestureStartPos!.dx;
    final d = duration;
    if (d <= Duration.zero) return;

    final maxSeekSeconds = math.min(d.inSeconds.toDouble(), 300.0);
    if (maxSeekSeconds <= 0) return;

    final deltaSeconds = (dx / width) * maxSeekSeconds;
    final delta = Duration(seconds: deltaSeconds.round());
    final target = _safeSeekTarget(_seekGestureStartPosition + delta, d);
    _seekGesturePreviewPosition = target;

    _setGestureOverlay(
      icon: delta.isNegative ? Icons.fast_rewind : Icons.fast_forward,
      text:
          '${_fmtClock(target)}（${delta.isNegative ? '-' : '+'}${delta.inSeconds.abs()}s）',
    );

    if (mounted) setState(() {});
  }

  Future<void> _onSeekDragEnd(DragEndDetails details) async {
    if (_gestureMode != _GestureMode.seek) return;
    final target = _seekGesturePreviewPosition;
    _gestureMode = _GestureMode.none;
    _gestureStartPos = null;
    _seekGesturePreviewPosition = null;

    if (target != null && _gesturesEnabled) {
      await _playerService.seek(target, flushBuffer: _flushBufferOnSeek);
      _lastPosition = target;
      _syncDanmakuCursor(target);
      _maybeReportPlaybackProgress(target, force: true);
      if (mounted) setState(() {});
    }

    _hideGestureOverlay();
    _scheduleControlsHide();
  }

  void _onSideDragStart(DragStartDetails details, {required double width}) {
    if (!_gesturesEnabled) return;
    _gestureStartPos = details.localPosition;
    final isLeft = width <= 0 ? true : details.localPosition.dx < width / 2;
    if (isLeft && widget.appState.gestureBrightness) {
      _gestureMode = _GestureMode.brightness;
      _gestureStartBrightness = _screenBrightness;
      _setGestureOverlay(
        icon: Icons.brightness_6_outlined,
        text: '亮度 ${(100 * _screenBrightness).round()}%',
      );
      return;
    }
    if (!isLeft && widget.appState.gestureVolume) {
      _gestureMode = _GestureMode.volume;
      final player = _playerService.player;
      _playerVolume = (player.state.volume / 100).clamp(0.0, 1.0);
      _gestureStartVolume = _playerVolume;
      _setGestureOverlay(
        icon: Icons.volume_up,
        text: '音量 ${(100 * _playerVolume).round()}%',
      );
      return;
    }
    _gestureMode = _GestureMode.none;
  }

  void _onSideDragUpdate(
    DragUpdateDetails details, {
    required double height,
  }) {
    if (!_gesturesEnabled) return;
    if (_gestureStartPos == null) return;
    if (height <= 0) return;
    if (_gestureMode != _GestureMode.brightness &&
        _gestureMode != _GestureMode.volume) {
      return;
    }

    final dy = details.localPosition.dy - _gestureStartPos!.dy;
    final delta = (-dy / height).clamp(-1.0, 1.0);

    switch (_gestureMode) {
      case _GestureMode.brightness:
        final v = (_gestureStartBrightness + delta).clamp(0.2, 1.0).toDouble();
        if (v == _screenBrightness) return;
        setState(() => _screenBrightness = v);
        _setGestureOverlay(
          icon: Icons.brightness_6_outlined,
          text: '亮度 ${(100 * v).round()}%',
        );
        break;
      case _GestureMode.volume:
        final v = (_gestureStartVolume + delta).clamp(0.0, 1.0).toDouble();
        _playerVolume = v;
        // ignore: unawaited_futures
        _playerService.player.setVolume(v * 100);
        _setGestureOverlay(
          icon: v == 0 ? Icons.volume_off : Icons.volume_up,
          text: '音量 ${(100 * v).round()}%',
        );
        break;
      default:
        break;
    }
  }

  void _onSideDragEnd(DragEndDetails details) {
    if (_gestureMode == _GestureMode.brightness ||
        _gestureMode == _GestureMode.volume) {
      _hideGestureOverlay();
    }
    _gestureMode = _GestureMode.none;
    _gestureStartPos = null;
  }

  void _onLongPressStart(LongPressStartDetails details) {
    if (!_gesturesEnabled) return;
    if (!widget.appState.gestureLongPressSpeed) return;

    _gestureMode = _GestureMode.speed;
    _longPressStartPos = details.localPosition;
    final player = _playerService.player;
    _longPressBaseRate = player.state.rate;
    final targetRate =
        (_longPressBaseRate! * widget.appState.longPressSpeedMultiplier)
            .clamp(0.25, 5.0)
            .toDouble();
    // ignore: unawaited_futures
    player.setRate(targetRate);
    _setGestureOverlay(
      icon: Icons.speed,
      text: '倍速 ×${(targetRate / _longPressBaseRate!).toStringAsFixed(2)}',
    );
  }

  void _onLongPressMoveUpdate(LongPressMoveUpdateDetails details,
      {required double height}) {
    if (_gestureMode != _GestureMode.speed) return;
    if (!_gesturesEnabled) return;
    if (!widget.appState.longPressSlideSpeed) return;
    if (_longPressBaseRate == null || _longPressStartPos == null) return;
    if (height <= 0) return;

    final dy = details.localPosition.dy - _longPressStartPos!.dy;
    final delta = (-dy / height) * 2.0;
    final multiplier = (widget.appState.longPressSpeedMultiplier + delta)
        .clamp(0.25, 5.0)
        .toDouble();
    final targetRate =
        (_longPressBaseRate! * multiplier).clamp(0.25, 5.0).toDouble();
    // ignore: unawaited_futures
    _playerService.player.setRate(targetRate);
    _setGestureOverlay(
      icon: Icons.speed,
      text: '倍速 ×${multiplier.toStringAsFixed(2)}',
    );
  }

  void _onLongPressEnd(LongPressEndDetails details) {
    if (_gestureMode != _GestureMode.speed) return;
    final base = _longPressBaseRate;
    _gestureMode = _GestureMode.none;
    _longPressBaseRate = null;
    _longPressStartPos = null;
    if (base != null && _playerService.isInitialized) {
      // ignore: unawaited_futures
      _playerService.player.setRate(base);
    }
    _hideGestureOverlay();
  }

  Future<void> _switchCore() async {
    if (kIsWeb || defaultTargetPlatform != TargetPlatform.android) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Exo 内核仅支持 Android')),
      );
      return;
    }

    final pos = _lastPosition;
    _maybeReportPlaybackProgress(pos, force: true);
    await widget.appState.setPlayerCore(PlayerCore.exo);
    if (!mounted) return;
    Navigator.of(context).pushReplacement(
      MaterialPageRoute(
        builder: (_) => ExoPlayNetworkPage(
          title: widget.title,
          itemId: widget.itemId,
          appState: widget.appState,
          server: widget.server,
          isTv: widget.isTv,
          seriesId: widget.seriesId,
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
    final pos = _playerService.isInitialized ? _lastPosition : Duration.zero;
    _maybeReportPlaybackProgress(pos, force: true);

    var sources = _availableMediaSources;
    if (sources.isEmpty) {
      try {
        final access = _serverAccess;
        if (access == null) throw Exception('Not connected');
        final info = await access.adapter
            .fetchPlaybackInfo(access.auth, itemId: widget.itemId);
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
    final sortedSources = List<Map<String, dynamic>>.from(sources)
      ..sort(_compareMediaSourcesByQuality);
    if (!mounted) return;
    final selected = await showModalBottomSheet<String>(
      context: context,
      builder: (ctx) {
        return SafeArea(
          child: ListView(
            children: [
              const ListTile(title: Text('版本选择')),
              for (final ms in sortedSources)
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

    final sid = (widget.seriesId ?? '').trim();
    final serverId = widget.server?.id ?? widget.appState.activeServerId;
    if (serverId != null && serverId.isNotEmpty && sid.isNotEmpty) {
      final idx = sources.indexWhere(
        (ms) => (ms['Id']?.toString() ?? '') == selected.trim(),
      );
      if (idx >= 0) {
        // ignore: unawaited_futures
        unawaited(
          widget.appState.setSeriesMediaSourceIndex(
            serverId: serverId,
            seriesId: sid,
            mediaSourceIndex: idx,
          ),
        );
      }
    }

    setState(() {
      _selectedMediaSourceId = selected.trim();
      _selectedAudioStreamIndex = null;
      _selectedSubtitleStreamIndex = null;
      _overrideStartPosition = pos;
      _overrideResumeImmediately = true;
      _loading = true;
      _playError = null;
    });
    await _init();
  }

  @override
  Widget build(BuildContext context) {
    final initialized = _playerService.isInitialized;
    final controlsEnabled = initialized && !_loading && _playError == null;
    final duration = initialized ? _playerService.duration : Duration.zero;
    final isPlaying = initialized ? _playerService.isPlaying : false;
    final enableBlur = !widget.isTv && widget.appState.enableBlurEffects;
    final remoteEnabled = widget.isTv || widget.appState.forceRemoteControlKeys;
    _remoteEnabled = remoteEnabled;

    return Focus(
      focusNode: _tvSurfaceFocusNode,
      autofocus: remoteEnabled,
      canRequestFocus: remoteEnabled,
      skipTraversal: true,
      onKeyEvent: (node, event) {
        if (!remoteEnabled) return KeyEventResult.ignored;
        if (!node.hasPrimaryFocus) return KeyEventResult.ignored;
        final key = event.logicalKey;

        if (event is KeyDownEvent) {
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
        }

        if (!controlsEnabled) return KeyEventResult.ignored;

        final isOkKey = key == LogicalKeyboardKey.space ||
            key == LogicalKeyboardKey.enter ||
            key == LogicalKeyboardKey.select;
        if (isOkKey) {
          // If long-press speed is disabled, keep original behavior (toggle on key-down).
          if (!widget.appState.gestureLongPressSpeed) {
            if (event is KeyDownEvent) {
              // ignore: unawaited_futures
              _togglePlayPause();
              return KeyEventResult.handled;
            }
            return KeyEventResult.ignored;
          }

          if (event is KeyDownEvent) {
            if (_tvOkLongPressTimer != null) return KeyEventResult.handled;
            _tvOkLongPressTriggered = false;
            _tvOkLongPressBaseRate = _playerService.player.state.rate;
            _tvOkLongPressTimer = Timer(_tvOkLongPressDelay, () {
              if (!mounted) return;
              if (!_playerService.isInitialized) return;
              final base =
                  _tvOkLongPressBaseRate ?? _playerService.player.state.rate;
              final targetRate =
                  (base * widget.appState.longPressSpeedMultiplier)
                      .clamp(0.25, 5.0)
                      .toDouble();
              _tvOkLongPressTriggered = true;
              // ignore: unawaited_futures
              _playerService.player.setRate(targetRate);
              _setGestureOverlay(
                icon: Icons.speed,
                text: '倍速 ×${(targetRate / base).toStringAsFixed(2)}',
              );
            });
            return KeyEventResult.handled;
          }

          if (event is KeyUpEvent) {
            final t = _tvOkLongPressTimer;
            _tvOkLongPressTimer = null;
            t?.cancel();

            if (_tvOkLongPressTriggered) {
              final base = _tvOkLongPressBaseRate;
              _tvOkLongPressTriggered = false;
              _tvOkLongPressBaseRate = null;
              if (base != null && _playerService.isInitialized) {
                // ignore: unawaited_futures
                _playerService.player.setRate(base);
              }
              _hideGestureOverlay();
              return KeyEventResult.handled;
            }

            _tvOkLongPressBaseRate = null;
            // ignore: unawaited_futures
            _togglePlayPause();
            return KeyEventResult.handled;
          }

          return KeyEventResult.ignored;
        }

        if (event is! KeyDownEvent) return KeyEventResult.ignored;

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
        extendBodyBehindAppBar: true,
        appBar: PreferredSize(
          preferredSize: _controlsVisible
              ? const Size.fromHeight(kToolbarHeight)
              : Size.zero,
          child: AnimatedOpacity(
            opacity: _controlsVisible ? 1 : 0,
            duration: const Duration(milliseconds: 200),
            child: IgnorePointer(
              ignoring: !_controlsVisible,
              child: SafeArea(
                top: false,
                bottom: false,
                child: GlassAppBar(
                  enableBlur: enableBlur,
                  child: AppBar(
                    backgroundColor: Colors.transparent,
                    foregroundColor: Colors.white,
                    elevation: 0,
                    scrolledUnderElevation: 0,
                    shadowColor: Colors.transparent,
                    surfaceTintColor: Colors.transparent,
                    forceMaterialTransparency: true,
                    title: Text(widget.title),
                    centerTitle: true,
                    actions: [
                      IconButton(
                        tooltip: '重新加载',
                        icon: const Icon(Icons.refresh),
                        onPressed: _loading
                            ? null
                            : () async {
                                setState(() {
                                  _loading = true;
                                  _playError = null;
                                });
                                await _init();
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
                        tooltip: '软硬解切换（当前：${_hwdecOn ? '硬解' : '软解'}）',
                        icon: const Icon(Icons.memory),
                        onPressed: () async {
                          setState(() {
                            _hwdecOn = !_hwdecOn;
                            _loading = true;
                            _playError = null;
                          });
                          await _init();
                        },
                      ),
                      IconButton(
                        tooltip: _orientationTooltip,
                        icon: Icon(_orientationIcon),
                        onPressed: _cycleOrientationMode,
                      ),
                      PopupMenuButton<_PlayerMenuAction>(
                        tooltip: '更多',
                        icon: const Icon(Icons.more_vert),
                        color: const Color(0xFF202020),
                        onSelected: (action) async {
                          switch (action) {
                            case _PlayerMenuAction.anime4k:
                              await _showAnime4kSheet();
                              break;
                            case _PlayerMenuAction.switchCore:
                              await _switchCore();
                              break;
                            case _PlayerMenuAction.switchVersion:
                              await _switchVersion();
                              break;
                          }
                        },
                        itemBuilder: (ctx) {
                          final scheme = Theme.of(ctx).colorScheme;
                          return [
                            PopupMenuItem(
                              value: _PlayerMenuAction.anime4k,
                              child: Row(
                                children: [
                                  Icon(
                                    Icons.auto_fix_high,
                                    color: scheme.primary,
                                  ),
                                  const SizedBox(width: 10),
                                  Text(
                                    'Anime4K：${_anime4kPreset.label}',
                                    style: const TextStyle(color: Colors.white),
                                  ),
                                ],
                              ),
                            ),
                            PopupMenuItem(
                              value: _PlayerMenuAction.switchVersion,
                              child: Row(
                                children: [
                                  Icon(Icons.video_file_outlined,
                                      color: scheme.primary),
                                  const SizedBox(width: 10),
                                  const Text(
                                    '版本选择',
                                    style: TextStyle(color: Colors.white),
                                  ),
                                ],
                              ),
                            ),
                            if (!kIsWeb &&
                                defaultTargetPlatform == TargetPlatform.android)
                              PopupMenuItem(
                                value: _PlayerMenuAction.switchCore,
                                child: Row(
                                  children: [
                                    Icon(Icons.tune, color: scheme.secondary),
                                    const SizedBox(width: 10),
                                    const Text(
                                      '切换内核',
                                      style: TextStyle(color: Colors.white),
                                    ),
                                  ],
                                ),
                              ),
                          ];
                        },
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
            Expanded(
              child: Container(
                color: Colors.black,
                child: initialized
                    ? Stack(
                        fit: StackFit.expand,
                        children: [
                          Video(
                            controller: _playerService.controller,
                            controls: NoVideoControls,
                            subtitleViewConfiguration:
                                _subtitleViewConfiguration,
                          ),
                          Positioned.fill(
                            child: DanmakuStage(
                              key: _danmakuKey,
                              enabled: _danmakuEnabled,
                              opacity: _danmakuOpacity,
                              scale: _danmakuScale,
                              speed: _danmakuSpeed,
                              timeScale: _playerService.player.state.rate,
                              bold: _danmakuBold,
                              scrollMaxLines: _danmakuMaxLines,
                              topMaxLines: _danmakuTopMaxLines,
                              bottomMaxLines: _danmakuBottomMaxLines,
                              preventOverlap: _danmakuPreventOverlap,
                            ),
                          ),
                          if (_screenBrightness < 0.999)
                            Positioned.fill(
                              child: IgnorePointer(
                                child: ColoredBox(
                                  color: Colors.black.withValues(
                                    alpha: (1.0 - _screenBrightness)
                                        .clamp(0.0, 0.8)
                                        .toDouble(),
                                  ),
                                ),
                              ),
                            ),
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
                                        style: const TextStyle(
                                            color: Colors.white),
                                      ),
                                    ),
                                  if (widget.appState.showBufferSpeed)
                                    Padding(
                                      padding: EdgeInsets.only(
                                        top: _bufferingPct != null ? 6 : 12,
                                      ),
                                      child: Text(
                                        '网速：${_netSpeedBytesPerSecond == null ? '—' : formatBytesPerSecond(_netSpeedBytesPerSecond!)}',
                                        style: const TextStyle(
                                          color: Colors.white,
                                        ),
                                      ),
                                    ),
                                ],
                              ),
                            ),
                          Positioned.fill(
                            child: LayoutBuilder(
                              builder: (ctx, constraints) {
                                final w = constraints.maxWidth;
                                final h = constraints.maxHeight;
                                final sideDragEnabled =
                                    widget.appState.gestureBrightness ||
                                        widget.appState.gestureVolume;
                                return GestureDetector(
                                  behavior: HitTestBehavior.translucent,
                                  onTap: _toggleControls,
                                  onDoubleTapDown: controlsEnabled
                                      ? (d) => _doubleTapDownPosition =
                                          d.localPosition
                                      : null,
                                  onDoubleTap: controlsEnabled
                                      ? () {
                                          final pos = _doubleTapDownPosition ??
                                              Offset(w / 2, 0);
                                          // ignore: unawaited_futures
                                          _handleDoubleTap(pos, w);
                                        }
                                      : null,
                                  onHorizontalDragStart: (controlsEnabled &&
                                          widget.appState.gestureSeek)
                                      ? _onSeekDragStart
                                      : null,
                                  onHorizontalDragUpdate: (controlsEnabled &&
                                          widget.appState.gestureSeek)
                                      ? (d) => _onSeekDragUpdate(
                                            d,
                                            width: w,
                                            duration: duration,
                                          )
                                      : null,
                                  onHorizontalDragEnd: (controlsEnabled &&
                                          widget.appState.gestureSeek)
                                      ? _onSeekDragEnd
                                      : null,
                                  onVerticalDragStart:
                                      (controlsEnabled && sideDragEnabled)
                                          ? (d) => _onSideDragStart(d, width: w)
                                          : null,
                                  onVerticalDragUpdate: (controlsEnabled &&
                                          sideDragEnabled)
                                      ? (d) => _onSideDragUpdate(d, height: h)
                                      : null,
                                  onVerticalDragEnd:
                                      (controlsEnabled && sideDragEnabled)
                                          ? _onSideDragEnd
                                          : null,
                                  onLongPressStart: (controlsEnabled &&
                                          widget.appState.gestureLongPressSpeed)
                                      ? _onLongPressStart
                                      : null,
                                  onLongPressMoveUpdate: (controlsEnabled &&
                                          widget
                                              .appState.gestureLongPressSpeed &&
                                          widget.appState.longPressSlideSpeed)
                                      ? (d) => _onLongPressMoveUpdate(
                                            d,
                                            height: h,
                                          )
                                      : null,
                                  onLongPressEnd: (controlsEnabled &&
                                          widget.appState.gestureLongPressSpeed)
                                      ? _onLongPressEnd
                                      : null,
                                  child: const SizedBox.expand(),
                                );
                              },
                            ),
                          ),
                          if (_gestureOverlayText != null)
                            Center(
                              child: IgnorePointer(
                                child: Material(
                                  color: Colors.black54,
                                  borderRadius: BorderRadius.circular(12),
                                  child: Padding(
                                    padding: const EdgeInsets.symmetric(
                                      horizontal: 14,
                                      vertical: 10,
                                    ),
                                    child: Row(
                                      mainAxisSize: MainAxisSize.min,
                                      children: [
                                        Icon(
                                          _gestureOverlayIcon ??
                                              Icons.info_outline,
                                          size: 20,
                                          color: Colors.white,
                                        ),
                                        const SizedBox(width: 8),
                                        Text(
                                          _gestureOverlayText!,
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
                          if (_skipIntroPromptVisible)
                            Align(
                              alignment: Alignment.topRight,
                              child: SafeArea(
                                bottom: false,
                                child: Padding(
                                  padding:
                                      const EdgeInsets.fromLTRB(12, 12, 12, 0),
                                  child: Material(
                                    color: Colors.black54,
                                    borderRadius: BorderRadius.circular(999),
                                    clipBehavior: Clip.antiAlias,
                                    child: Padding(
                                      padding: const EdgeInsets.symmetric(
                                        horizontal: 12,
                                        vertical: 10,
                                      ),
                                      child: Row(
                                        mainAxisSize: MainAxisSize.min,
                                        children: [
                                          const Icon(
                                            Icons.skip_next,
                                            size: 18,
                                            color: Colors.white,
                                          ),
                                          const SizedBox(width: 6),
                                          Builder(builder: (context) {
                                            final end = _introTimestamps?.end;
                                            final endText = (end != null &&
                                                    end > Duration.zero)
                                                ? '（至 ${_fmtClock(end)}）'
                                                : '';
                                            return Text(
                                              '检测到片头$endText',
                                              style: const TextStyle(
                                                color: Colors.white,
                                                fontSize: 13,
                                              ),
                                            );
                                          }),
                                          const SizedBox(width: 10),
                                          InkWell(
                                            onTap: _skipIntro,
                                            borderRadius:
                                                BorderRadius.circular(999),
                                            child: Container(
                                              padding:
                                                  const EdgeInsets.symmetric(
                                                horizontal: 10,
                                                vertical: 6,
                                              ),
                                              decoration: BoxDecoration(
                                                color: Colors.white
                                                    .withValues(alpha: 0.18),
                                                borderRadius:
                                                    BorderRadius.circular(999),
                                              ),
                                              child: const Row(
                                                mainAxisSize: MainAxisSize.min,
                                                children: [
                                                  Icon(
                                                    Icons.fast_forward,
                                                    size: 18,
                                                    color: Colors.white,
                                                  ),
                                                  SizedBox(width: 4),
                                                  Text(
                                                    '跳过',
                                                    style: TextStyle(
                                                      color: Colors.white,
                                                      fontSize: 13,
                                                      fontWeight:
                                                          FontWeight.w600,
                                                    ),
                                                  ),
                                                ],
                                              ),
                                            ),
                                          ),
                                          const SizedBox(width: 6),
                                          InkWell(
                                            onTap: _dismissSkipIntroPrompt,
                                            borderRadius:
                                                BorderRadius.circular(999),
                                            child: Container(
                                              padding:
                                                  const EdgeInsets.symmetric(
                                                horizontal: 10,
                                                vertical: 6,
                                              ),
                                              decoration: BoxDecoration(
                                                color: Colors.white
                                                    .withValues(alpha: 0.12),
                                                borderRadius:
                                                    BorderRadius.circular(999),
                                              ),
                                              child: const Text(
                                                '不跳过',
                                                style: TextStyle(
                                                  color: Colors.white,
                                                  fontSize: 13,
                                                ),
                                              ),
                                            ),
                                          ),
                                        ],
                                      ),
                                    ),
                                  ),
                                ),
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
                          if (controlsEnabled &&
                              _showStartOverHint &&
                              _startOverHintPosition != null)
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
                                            '已从 ${_fmtClock(_startOverHintPosition!)} 继续播放',
                                            style: const TextStyle(
                                              color: Colors.white,
                                              fontSize: 13,
                                            ),
                                          ),
                                          const SizedBox(width: 10),
                                          InkWell(
                                            onTap: _restartFromBeginning,
                                            borderRadius:
                                                BorderRadius.circular(999),
                                            child: Container(
                                              padding:
                                                  const EdgeInsets.symmetric(
                                                horizontal: 10,
                                                vertical: 6,
                                              ),
                                              decoration: BoxDecoration(
                                                color: Colors.white
                                                    .withValues(alpha: 0.18),
                                                borderRadius:
                                                    BorderRadius.circular(999),
                                              ),
                                              child: const Row(
                                                mainAxisSize: MainAxisSize.min,
                                                children: [
                                                  Icon(
                                                    Icons.replay,
                                                    size: 18,
                                                    color: Colors.white,
                                                  ),
                                                  SizedBox(width: 4),
                                                  Text(
                                                    '从头开始',
                                                    style: TextStyle(
                                                      color: Colors.white,
                                                      fontSize: 13,
                                                      fontWeight:
                                                          FontWeight.w600,
                                                    ),
                                                  ),
                                                ],
                                              ),
                                            ),
                                          ),
                                        ],
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
                              minimum: const EdgeInsets.fromLTRB(12, 0, 12, 12),
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
                                        position: _lastPosition,
                                        buffered: _lastBuffer,
                                        duration: duration,
                                        isPlaying: isPlaying,
                                        playbackRate:
                                            _playerService.player.state.rate,
                                        onSetPlaybackRate: (rate) async {
                                          _showControls();
                                          if (!_playerService.isInitialized) {
                                            return;
                                          }
                                          await _playerService.player
                                              .setRate(rate);
                                          if (mounted) setState(() {});
                                        },
                                        heatmap: _danmakuHeatmap,
                                        showHeatmap: _danmakuShowHeatmap &&
                                            _danmakuHeatmap.isNotEmpty,
                                        seekBackwardSeconds: _seekBackSeconds,
                                        seekForwardSeconds: _seekForwardSeconds,
                                        showSystemTime: widget
                                            .appState.showSystemTimeInControls,
                                        showBattery: widget
                                            .appState.showBatteryInControls,
                                        showBufferSpeed:
                                            widget.appState.showBufferSpeed,
                                        buffering: _buffering,
                                        bufferSpeedX: _bufferSpeedX,
                                        netSpeedBytesPerSecond:
                                            _netSpeedBytesPerSecond,
                                        onRequestThumbnail: _thumbnailer == null
                                            ? null
                                            : (pos) =>
                                                _thumbnailer!.getThumbnail(
                                                  pos,
                                                ),
                                        onOpenEpisodePicker:
                                            _canShowEpisodePickerButton
                                                ? _toggleEpisodePicker
                                                : null,
                                        onScrubStart: _onScrubStart,
                                        onScrubEnd: _onScrubEnd,
                                        onSeek: (pos) async {
                                          await _playerService.seek(
                                            pos,
                                            flushBuffer: _flushBufferOnSeek,
                                          );
                                          _lastPosition = pos;
                                          _syncDanmakuCursor(pos);
                                          _maybeReportPlaybackProgress(
                                            pos,
                                            force: true,
                                          );
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
                                          final target = _lastPosition -
                                              Duration(
                                                  seconds: _seekBackSeconds);
                                          final pos = target < Duration.zero
                                              ? Duration.zero
                                              : target;
                                          await _playerService.seek(
                                            pos,
                                            flushBuffer: _flushBufferOnSeek,
                                          );
                                          _lastPosition = pos;
                                          _syncDanmakuCursor(pos);
                                          _maybeReportPlaybackProgress(
                                            pos,
                                            force: true,
                                          );
                                          if (mounted) setState(() {});
                                        },
                                        onSeekForward: () async {
                                          _showControls();
                                          final d = duration;
                                          final target = _lastPosition +
                                              Duration(
                                                  seconds: _seekForwardSeconds);
                                          final pos =
                                              (d > Duration.zero && target > d)
                                                  ? d
                                                  : target;
                                          await _playerService.seek(
                                            pos,
                                            flushBuffer: _flushBufferOnSeek,
                                          );
                                          _lastPosition = pos;
                                          _syncDanmakuCursor(pos);
                                          _maybeReportPlaybackProgress(
                                            pos,
                                            force: true,
                                          );
                                          if (mounted) setState(() {});
                                        },
                                      ),
                                    ),
                                  ),
                                ),
                              ),
                            ),
                          ),
                          _buildEpisodePickerOverlay(enableBlur: enableBlur),
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
          ],
        ),
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
    widget.appState.setAnime4kPreset(selected);

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
      widget.appState.setAnime4kPreset(Anime4kPreset.off);
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
            final subs = List<SubtitleTrack>.from(_tracks.subtitle);
            final current = _playerService.player.state.track.subtitle;

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
                await _playerService.player.setSubtitleTrack(
                  SubtitleTrack.uri(path, title: f.name),
                );
                _selectedSubtitleStreamIndex = null;
                _tracks = _playerService.player.state.tracks;
                setSheetState(() {});
              } catch (e) {
                messenger.showSnackBar(SnackBar(content: Text('添加字幕失败：$e')));
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
                      signed: true,
                    ),
                    decoration: const InputDecoration(
                      hintText: '单位：秒，例如 0.5 或 -1.2',
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
              _subtitleDelaySeconds = value.clamp(-60.0, 60.0).toDouble();
              await _applyMpvSubtitleOptions();
              setSheetState(() {});
            }

            Future<void> pickAssOverride() async {
              final next = await showDialog<bool>(
                context: ctx,
                builder: (dctx) => SimpleDialog(
                  title: const Text('强制覆盖 ASS/SSA 字幕'),
                  children: [
                    ListTile(
                      title: const Text('No'),
                      trailing: !_subtitleAssOverrideForce
                          ? const Icon(Icons.check)
                          : null,
                      onTap: () => Navigator.of(dctx).pop(false),
                    ),
                    ListTile(
                      title: const Text('Force'),
                      trailing: _subtitleAssOverrideForce
                          ? const Icon(Icons.check)
                          : null,
                      onTap: () => Navigator.of(dctx).pop(true),
                    ),
                  ],
                ),
              );
              if (next == null) return;
              _subtitleAssOverrideForce = next;
              await _applyMpvSubtitleOptions();
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
                      RadioGroup<SubtitleTrack>(
                        groupValue: current,
                        onChanged: (value) {
                          if (value == null) return;
                          _selectedSubtitleStreamIndex =
                              value.id == 'no' ? -1 : int.tryParse(value.id);
                          _playerService.player.setSubtitleTrack(value);
                          setSheetState(() {});
                        },
                        child: Column(
                          children: [
                            RadioListTile<SubtitleTrack>(
                              value: SubtitleTrack.no(),
                              title: const Text('关闭'),
                              contentPadding: EdgeInsets.zero,
                              dense: true,
                            ),
                            for (final s in subs)
                              RadioListTile<SubtitleTrack>(
                                value: s,
                                title: Text(_subtitleTrackTitle(s)),
                                subtitle: Text(_subtitleTrackSubtitle(s)),
                                contentPadding: EdgeInsets.zero,
                                dense: true,
                              ),
                          ],
                        ),
                      ),
                      if (subs.isEmpty)
                        const Padding(
                          padding: EdgeInsets.fromLTRB(40, 0, 0, 8),
                          child: Text('暂无字幕'),
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
                              _subtitleDelaySeconds =
                                  (_subtitleDelaySeconds - 0.1)
                                      .clamp(-60.0, 60.0)
                                      .toDouble();
                              await _applyMpvSubtitleOptions();
                              setSheetState(() {});
                            },
                            icon: Icons.remove,
                            tooltip: '-0.1s',
                          ),
                          Text('${_subtitleDelaySeconds.toStringAsFixed(1)}s'),
                          miniIconButton(
                            onPressed: () async {
                              _subtitleDelaySeconds =
                                  (_subtitleDelaySeconds + 0.1)
                                      .clamp(-60.0, 60.0)
                                      .toDouble();
                              await _applyMpvSubtitleOptions();
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
                              _subtitleDelaySeconds = 0.0;
                              await _applyMpvSubtitleOptions();
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
                      subtitle: AppSlider(
                        value: _subtitleFontSize.clamp(12.0, 60.0),
                        min: 12.0,
                        max: 60.0,
                        divisions: 48,
                        onChanged: (v) {
                          setState(() => _subtitleFontSize = v);
                          setSheetState(() {});
                        },
                      ),
                      trailing: Text('${_subtitleFontSize.round()}'),
                    ),
                    ListTile(
                      contentPadding: EdgeInsets.zero,
                      title: const Text('字幕位置'),
                      subtitle: AppSlider(
                        value: _subtitlePositionStep.toDouble().clamp(0, 20),
                        min: 0,
                        max: 20,
                        divisions: 20,
                        onChanged: (v) {
                          setState(() => _subtitlePositionStep = v.round());
                          setSheetState(() {});
                        },
                      ),
                      trailing: Text('$_subtitlePositionStep'),
                    ),
                    SwitchListTile(
                      contentPadding: EdgeInsets.zero,
                      title: const Text('粗体'),
                      value: _subtitleBold,
                      onChanged: (v) {
                        setState(() => _subtitleBold = v);
                        setSheetState(() {});
                      },
                    ),
                    ListTile(
                      contentPadding: EdgeInsets.zero,
                      title: const Text('强制覆盖 ASS/SSA 字幕'),
                      subtitle:
                          Text(_subtitleAssOverrideForce ? 'Force' : 'No'),
                      onTap: pickAssOverride,
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

  static String _subtitleTrackTitle(SubtitleTrack s) {
    final t = (s.title ?? '').trim();
    if (t.isNotEmpty) return t;
    final lang = (s.language ?? '').trim();
    if (lang.isNotEmpty) return lang;
    return '字幕 ${s.id}';
  }

  static String _subtitleTrackSubtitle(SubtitleTrack s) {
    final parts = <String>[];
    final lang = (s.language ?? '').trim();
    final codec = (s.codec ?? '').trim();
    if (lang.isNotEmpty) parts.add(lang);
    if (codec.isNotEmpty) parts.add(codec);
    return parts.join('  ');
  }

  SubtitleViewConfiguration get _subtitleViewConfiguration {
    const base = SubtitleViewConfiguration();
    final bottom =
        (_subtitlePositionStep.clamp(0, 20) * 5.0).clamp(0.0, 200.0).toDouble();
    return SubtitleViewConfiguration(
      visible: base.visible,
      style: base.style.copyWith(
        fontSize: _subtitleFontSize.clamp(12.0, 60.0),
        fontWeight: _subtitleBold ? FontWeight.w600 : FontWeight.normal,
      ),
      textAlign: base.textAlign,
      textScaler: base.textScaler,
      padding: base.padding.copyWith(bottom: bottom),
    );
  }

  Future<void> _applyMpvSubtitleOptions() async {
    if (!_playerService.isInitialized || _playerService.isExternalPlayback) {
      return;
    }
    final platform = _playerService.player.platform as dynamic;
    try {
      await platform.setProperty(
        'sub-delay',
        _subtitleDelaySeconds.toStringAsFixed(3),
      );
    } catch (_) {}
    try {
      await platform.setProperty(
        'sub-font-size',
        _subtitleFontSize.clamp(12.0, 60.0),
      );
    } catch (_) {}
    try {
      await platform.setProperty(
        'sub-margin-y',
        (_subtitlePositionStep.clamp(0, 20) * 5.0).clamp(0.0, 200.0).round(),
      );
    } catch (_) {}
    try {
      await platform.setProperty(
        'sub-bold',
        _subtitleBold ? 'yes' : 'no',
      );
    } catch (_) {}
    try {
      await platform.setProperty('sub-border-size', 2.2);
    } catch (_) {}
    try {
      await platform.setProperty('sub-shadow-offset', 1.0);
    } catch (_) {}
    try {
      await platform.setProperty(
        'sub-ass-override',
        _subtitleAssOverrideForce ? 'force' : 'no',
      );
    } catch (_) {}
  }
}

enum _PlayerMenuAction { anime4k, switchCore, switchVersion }

enum _OrientationMode { auto, landscape, portrait }

enum _GestureMode { none, brightness, volume, seek, speed }
