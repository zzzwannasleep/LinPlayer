import 'dart:async';
import 'dart:io';
import 'dart:math' as math;
import 'dart:ui';

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
import 'package:shared_preferences/shared_preferences.dart';

import 'play_network_page_exo.dart';
import 'server_adapters/server_access.dart';
import 'services/app_route_observer.dart';
import 'services/built_in_proxy/built_in_proxy_service.dart';
import 'services/desktop_window.dart';
import 'widgets/danmaku_manual_search_dialog.dart';
import 'widgets/list_picker_dialog.dart';

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
  static const String _kLocalPlaybackProgressPrefix =
      'networkPlaybackProgress_v1:';

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
  bool _skipAutoResumeOnce = false;
  int _lastLocalProgressSecond = -1;
  bool _localProgressWriteInFlight = false;
  int? _pendingLocalProgressTicks;
  bool _reportedStart = false;
  bool _reportedStop = false;
  bool _markPlayedThresholdReached = false;
  bool _autoMarkedPlayed = false;
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
  bool get _useDesktopPlaybackUi =>
      !widget.isTv &&
      !kIsWeb &&
      (defaultTargetPlatform == TargetPlatform.windows ||
          defaultTargetPlatform == TargetPlatform.macOS ||
          defaultTargetPlatform == TargetPlatform.linux);

  static const Duration _controlsAutoHideDelay = Duration(seconds: 3);
  static const Duration _desktopControlsAutoHideDelay = Duration(seconds: 1);
  Timer? _controlsHideTimer;
  bool _controlsVisible = true;
  bool _isScrubbing = false;
  _DesktopSidePanel _desktopSidePanel = _DesktopSidePanel.none;
  bool _desktopTopBarHovered = false;
  bool _desktopBottomBarHovered = false;
  bool _desktopSpaceKeyPressed = false;
  bool _desktopEpisodeGridMode = false;
  bool _desktopSpeedPanelVisible = false;
  bool _desktopDanmakuOnlineLoading = false;
  bool _desktopDanmakuManualLoading = false;
  bool _desktopLineLoading = false;
  bool _desktopRouteSwitching = false;
  static const int _desktopRouteHistoryLimit = 5;
  final List<String> _desktopRouteHistory = <String>[];
  bool _desktopFullscreen = false;
  double _danmakuTimeOffsetSeconds = 0.0;

  final GlobalKey<DanmakuStageState> _danmakuKey =
      GlobalKey<DanmakuStageState>();
  final List<DanmakuSource> _danmakuSources = [];
  int _danmakuSourceIndex = -1;
  bool _danmakuEnabled = false;
  double _danmakuOpacity = 1.0;
  double _danmakuScale = 1.0;
  double _danmakuSpeed = 1.0;
  bool _danmakuBold = true;
  int _danmakuMaxLines = 30;
  int _danmakuTopMaxLines = 30;
  int _danmakuBottomMaxLines = 30;
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
    _lastLocalProgressSecond = -1;
    _pendingLocalProgressTicks = null;
    _localProgressWriteInFlight = false;
    _reportedStart = false;
    _reportedStop = false;
    _markPlayedThresholdReached = false;
    _autoMarkedPlayed = false;
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
    _desktopSidePanel = _DesktopSidePanel.none;
    _desktopSpeedPanelVisible = false;
    _desktopDanmakuOnlineLoading = false;
    _desktopDanmakuManualLoading = false;
    _desktopLineLoading = false;
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
      final cloudStart = _overrideStartPosition ?? widget.startPosition;
      final localStart = await _readLocalProgressDuration();
      Duration? start = cloudStart;
      if (localStart != null && (start == null || localStart > start)) {
        start = localStart;
      }
      final resumeImmediately =
          _overrideResumeImmediately || widget.resumeImmediately;
      final skipAutoResume = _skipAutoResumeOnce;
      _overrideStartPosition = null;
      _overrideResumeImmediately = false;
      _skipAutoResumeOnce = false;
      if (!skipAutoResume && start != null && start > Duration.zero) {
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
        final displayTitle =
            title.isEmpty ? 'episodeId=${candidate.episodeId}' : title;
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
    if (seriesName.isNotEmpty) {
      final episodeNo = item.episodeNumber;
      if (episodeNo != null && episodeNo > 0) {
        return '$seriesName 第$episodeNo集';
      }
      return seriesName;
    }
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
    final cursorPosition = _effectiveDanmakuTimelinePosition(position);
    final items = _danmakuSources[_danmakuSourceIndex].items;
    _nextDanmakuIndex = DanmakuParser.lowerBoundByTime(items, cursorPosition);
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

    final cursorPosition = _effectiveDanmakuTimelinePosition(position);
    final items = _danmakuSources[_danmakuSourceIndex].items;
    while (_nextDanmakuIndex < items.length &&
        items[_nextDanmakuIndex].time <= cursorPosition) {
      stage.emit(items[_nextDanmakuIndex]);
      _nextDanmakuIndex++;
    }
  }

  Duration _effectiveDanmakuTimelinePosition(Duration playbackPosition) {
    final shifted = playbackPosition -
        Duration(milliseconds: (_danmakuTimeOffsetSeconds * 1000).round());
    return shifted < Duration.zero ? Duration.zero : shifted;
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
                    subtitle: Text(
                      selectedName,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                    trailing: OutlinedButton(
                      onPressed: !hasSources
                          ? null
                          : () async {
                              final names = _danmakuSources
                                  .map((e) => e.name)
                                  .toList(growable: false);
                              final picked = await showListPickerDialog(
                                context: context,
                                title: '选择弹幕源',
                                items: names,
                                initialIndex: _danmakuSourceIndex >= 0
                                    ? _danmakuSourceIndex
                                    : null,
                                height: 320,
                              );
                              if (!mounted || picked == null) return;
                              setState(() {
                                _danmakuSourceIndex = picked;
                                _danmakuEnabled = true;
                                _rebuildDanmakuHeatmap();
                                _syncDanmakuCursor(_lastPosition);
                              });
                              if (widget
                                      .appState.danmakuRememberSelectedSource &&
                                  picked >= 0 &&
                                  picked < _danmakuSources.length) {
                                // ignore: unawaited_futures
                                widget.appState
                                    .setDanmakuLastSelectedSourceName(
                                  _danmakuSources[picked].name,
                                );
                              }
                              setSheetState(() {});
                            },
                      child: const Text('选择'),
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
        } else {
          ms = sources.first;
        }
        final resolvedSelectedId = (ms['Id'] as String? ?? '').trim();
        _selectedMediaSourceId =
            resolvedSelectedId.isEmpty ? null : resolvedSelectedId;
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

  String get _localProgressKey {
    final serverId =
        (widget.server?.id ?? widget.appState.activeServerId ?? '').trim();
    final base = _baseUrl ?? '';
    final scope = serverId.isNotEmpty ? serverId : base;
    final normalized = scope.replaceAll(RegExp(r'[^A-Za-z0-9._-]'), '_');
    return '$_kLocalPlaybackProgressPrefix$normalized:${widget.itemId}';
  }

  Future<Duration?> _readLocalProgressDuration() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final ticks = prefs.getInt(_localProgressKey);
      if (ticks == null || ticks <= 0) return null;
      return Duration(microseconds: (ticks / 10).round());
    } catch (_) {
      return null;
    }
  }

  Future<void> _clearLocalProgress() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.remove(_localProgressKey);
    } catch (_) {}
    _lastLocalProgressSecond = -1;
    _pendingLocalProgressTicks = null;
  }

  void _persistLocalProgress(Duration position, {bool force = false}) {
    final safe = position < Duration.zero ? Duration.zero : position;
    final second = safe.inSeconds;
    if (!force && second == _lastLocalProgressSecond) return;
    _lastLocalProgressSecond = second;
    _pendingLocalProgressTicks = _toTicks(safe);
    // ignore: unawaited_futures
    _flushPendingLocalProgress();
  }

  Future<void> _flushPendingLocalProgress() async {
    if (_localProgressWriteInFlight) return;
    _localProgressWriteInFlight = true;
    try {
      while (_pendingLocalProgressTicks != null) {
        final ticks = _pendingLocalProgressTicks!;
        _pendingLocalProgressTicks = null;
        final prefs = await SharedPreferences.getInstance();
        await prefs.setInt(_localProgressKey, ticks);
      }
    } finally {
      _localProgressWriteInFlight = false;
    }
  }

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

  bool _hasVideoSignal(VideoParams? params) {
    if (params == null) return false;
    final width = params.dw ?? params.w ?? 0;
    final height = params.dh ?? params.h ?? 0;
    if (width > 0 && height > 0) return true;
    if ((params.pixelformat ?? '').trim().isNotEmpty) return true;
    if ((params.hwPixelformat ?? '').trim().isNotEmpty) return true;
    return false;
  }

  Future<bool> _waitForVideoSignal({
    Duration timeout = const Duration(seconds: 3),
  }) async {
    final deadline = DateTime.now().add(timeout);
    while (mounted && DateTime.now().isBefore(deadline)) {
      if (_playError != null || !_playerService.isInitialized) return false;
      final params =
          _lastVideoParams ?? _playerService.player.state.videoParams;
      if (_hasVideoSignal(params)) return true;
      await Future<void>.delayed(const Duration(milliseconds: 120));
    }
    return false;
  }

  Future<void> _resumePlaybackAfterSwitch(Duration resumePos) async {
    if (resumePos <= Duration.zero) return;
    if (!_playerService.isInitialized || _playError != null) return;

    final hasVideo =
        await _waitForVideoSignal(timeout: const Duration(seconds: 2));
    if (!hasVideo) return;

    final deadline = DateTime.now().add(const Duration(seconds: 2));
    while (mounted &&
        _playerService.duration <= Duration.zero &&
        DateTime.now().isBefore(deadline)) {
      await Future<void>.delayed(const Duration(milliseconds: 120));
    }
    if (!mounted || !_playerService.isInitialized || _playError != null) return;

    final total = _playerService.duration;
    if (total <= Duration.zero) return;
    final target = _safeSeekTarget(resumePos, total);
    if (target <= Duration.zero) return;

    await _playerService.seek(
      target,
      flushBuffer: _flushBufferOnSeek,
    );
    if (!mounted) return;

    _resumeHintTimer?.cancel();
    _resumeHintTimer = null;
    setState(() {
      _lastPosition = target;
      _resumeHintPosition = null;
      _showResumeHint = false;
    });
    _syncDanmakuCursor(target);
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
    _persistLocalProgress(position, force: force);
    _maybeAutoMarkPlayed(position);
  }

  bool _isPlayedByThreshold(Duration position, Duration duration) {
    if (duration <= Duration.zero) return false;
    final durUs = duration.inMicroseconds;
    if (durUs <= 0) return false;
    final threshold =
        widget.appState.markPlayedThresholdPercent.clamp(75, 100);
    final posUs = position.inMicroseconds;
    return posUs * 100 >= durUs * threshold;
  }

  void _maybeAutoMarkPlayed(Duration position) {
    if (_reportedStop) return;
    if (_autoMarkedPlayed) return;

    final duration = _playerService.duration;
    if (!_isPlayedByThreshold(position, duration)) return;

    _markPlayedThresholdReached = true;
    _autoMarkedPlayed = true;
    // ignore: unawaited_futures
    _autoMarkPlayedBestEffort(position);
  }

  Future<void> _autoMarkPlayedBestEffort(Duration position) async {
    final access = _serverAccess;
    if (access == null) return;
    if (access.auth.baseUrl.isEmpty || access.auth.token.isEmpty) return;
    if (access.auth.userId.isEmpty) return;

    try {
      await access.adapter.updatePlaybackPosition(
        access.auth,
        itemId: widget.itemId,
        positionTicks: _toTicks(position),
        played: true,
      );
    } catch (_) {}
  }

  Future<void> _reportPlaybackStoppedBestEffort(
      {bool completed = false}) async {
    if (_reportedStop) return;
    _reportedStop = true;

    final pos =
        _playerService.isInitialized ? _playerService.position : _lastPosition;
    final dur = _playerService.duration;
    final played = completed ||
        _markPlayedThresholdReached ||
        _isPlayedByThreshold(pos, dur);
    final ticks = _toTicks(pos);
    _persistLocalProgress(pos, force: true);
    await _flushPendingLocalProgress();

    final access = _serverAccess;
    if (access == null ||
        access.auth.baseUrl.isEmpty ||
        access.auth.token.isEmpty) {
      if (played) {
        await _clearLocalProgress();
      }
      return;
    }

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

    if (played) {
      await _clearLocalProgress();
    }
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

    final refreshSeconds = _useDesktopPlaybackUi
        ? 0.2
        : widget.appState.bufferSpeedRefreshSeconds.clamp(0.2, 3.0).toDouble();
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
    if (_desktopFullscreen) {
      unawaited(DesktopWindow.setBorderlessFullscreen(false));
    }
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

  Duration get _activeControlsAutoHideDelay => _useDesktopPlaybackUi
      ? _desktopControlsAutoHideDelay
      : _controlsAutoHideDelay;

  bool get _desktopBarsHovered =>
      _desktopTopBarHovered || _desktopBottomBarHovered;

  bool get _editableTextFocused {
    final focusContext = FocusManager.instance.primaryFocus?.context;
    if (focusContext == null) return false;
    if (focusContext.widget is EditableText) return true;
    return focusContext.findAncestorWidgetOfExactType<EditableText>() != null;
  }

  void _setDesktopBarHover({
    required bool top,
    required bool hover,
  }) {
    if (!_useDesktopPlaybackUi) return;
    final changed = top
        ? _desktopTopBarHovered != hover
        : _desktopBottomBarHovered != hover;
    if (!changed) return;

    setState(() {
      if (top) {
        _desktopTopBarHovered = hover;
      } else {
        _desktopBottomBarHovered = hover;
      }
      if (hover) _controlsVisible = true;
    });

    if (hover) {
      _showControls(scheduleHide: false);
    } else {
      _scheduleControlsHide();
    }
  }

  KeyEventResult _handleDesktopShortcutKeyEvent(KeyEvent event) {
    if (!_useDesktopPlaybackUi || _remoteEnabled) {
      return KeyEventResult.ignored;
    }
    if (_editableTextFocused || !_gesturesEnabled) {
      return KeyEventResult.ignored;
    }

    final key = event.logicalKey;
    if (key == LogicalKeyboardKey.space) {
      if (event is KeyDownEvent) {
        if (_desktopSpaceKeyPressed) return KeyEventResult.handled;
        _desktopSpaceKeyPressed = true;
        _showControls();
        // ignore: unawaited_futures
        unawaited(_togglePlayPause(showOverlay: false));
        return KeyEventResult.handled;
      }
      if (event is KeyUpEvent) {
        _desktopSpaceKeyPressed = false;
        return KeyEventResult.handled;
      }
      return KeyEventResult.ignored;
    }

    if (event is! KeyDownEvent) {
      return KeyEventResult.ignored;
    }

    final pressed = HardwareKeyboard.instance.logicalKeysPressed;
    final hasModifier = pressed.contains(LogicalKeyboardKey.controlLeft) ||
        pressed.contains(LogicalKeyboardKey.controlRight) ||
        pressed.contains(LogicalKeyboardKey.metaLeft) ||
        pressed.contains(LogicalKeyboardKey.metaRight) ||
        pressed.contains(LogicalKeyboardKey.altLeft) ||
        pressed.contains(LogicalKeyboardKey.altRight);
    if (hasModifier) return KeyEventResult.ignored;

    if (key == LogicalKeyboardKey.keyF) {
      _showControls(scheduleHide: false);
      _toggleDesktopFullscreen();
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.keyR) {
      _showControls(scheduleHide: false);
      // ignore: unawaited_futures
      unawaited(_showDesktopRouteSheet());
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.keyV) {
      _showControls(scheduleHide: false);
      // ignore: unawaited_futures
      unawaited(_showDesktopVersionSheet());
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.keyA) {
      _showControls(scheduleHide: false);
      _showAudioTracks(context);
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.keyS) {
      _showControls(scheduleHide: false);
      _showSubtitleTracks(context);
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.keyD) {
      _showControls(scheduleHide: false);
      // ignore: unawaited_futures
      unawaited(_showDanmakuSheet());
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.keyE) {
      _showControls(scheduleHide: false);
      _toggleDesktopPanel(_DesktopSidePanel.episode);
      return KeyEventResult.handled;
    }

    if (key == LogicalKeyboardKey.arrowLeft) {
      _showControls();
      // ignore: unawaited_futures
      unawaited(
        _seekRelative(
          Duration(seconds: -_seekBackSeconds),
          showOverlay: false,
        ),
      );
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.arrowRight) {
      _showControls();
      // ignore: unawaited_futures
      unawaited(
        _seekRelative(
          Duration(seconds: _seekForwardSeconds),
          showOverlay: false,
        ),
      );
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  void _showControls({bool scheduleHide = true}) {
    if (!_controlsVisible) {
      setState(() => _controlsVisible = true);
    }
    // ignore: unawaited_futures
    _exitImmersiveMode();
    final canScheduleHide = scheduleHide &&
        !_remoteEnabled &&
        _desktopSidePanel == _DesktopSidePanel.none &&
        !_desktopSpeedPanelVisible;
    if (canScheduleHide) {
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
    setState(() {
      _controlsVisible = false;
      _desktopSidePanel = _DesktopSidePanel.none;
      _desktopSpeedPanelVisible = false;
    });
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
      setState(() {
        _controlsVisible = false;
        _desktopSidePanel = _DesktopSidePanel.none;
        _desktopSpeedPanelVisible = false;
      });
    }
    // ignore: unawaited_futures
    _enterImmersiveMode();
    _focusTvSurface();
  }

  void _scheduleControlsHide() {
    _controlsHideTimer?.cancel();
    _controlsHideTimer = null;
    if (_remoteEnabled) return;
    if (_useDesktopPlaybackUi && _desktopBarsHovered) return;
    if (_desktopSidePanel != _DesktopSidePanel.none ||
        _desktopSpeedPanelVisible) {
      return;
    }
    if (!_controlsVisible || _isScrubbing) return;
    _controlsHideTimer = Timer(_activeControlsAutoHideDelay, () {
      if (!mounted || _isScrubbing || _remoteEnabled) return;
      if (_useDesktopPlaybackUi && _desktopBarsHovered) return;
      setState(() {
        _controlsVisible = false;
        _desktopSidePanel = _DesktopSidePanel.none;
        _desktopSpeedPanelVisible = false;
      });
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

  Future<List<Map<String, dynamic>>> _ensureMediaSourcesLoaded({
    bool forceRefresh = false,
  }) async {
    if (!forceRefresh && _availableMediaSources.isNotEmpty) {
      return List<Map<String, dynamic>>.from(_availableMediaSources);
    }
    final access = _serverAccess;
    if (access == null) return const <Map<String, dynamic>>[];
    final info = await access.adapter
        .fetchPlaybackInfo(access.auth, itemId: widget.itemId);
    final sources = List<Map<String, dynamic>>.from(
      info.mediaSources.cast<Map<String, dynamic>>(),
    );
    _availableMediaSources = List<Map<String, dynamic>>.from(sources);
    return sources;
  }

  Future<void> _rememberSeriesMediaSourceIndex({
    required List<Map<String, dynamic>> sources,
    required String selectedSourceId,
  }) async {
    final sid = (widget.seriesId ?? '').trim();
    final serverId = widget.server?.id ?? widget.appState.activeServerId;
    if (serverId == null || serverId.isEmpty || sid.isEmpty) return;
    final normalizedId = selectedSourceId.trim();
    if (normalizedId.isEmpty) return;
    final canonicalSources =
        _availableMediaSources.isNotEmpty ? _availableMediaSources : sources;
    var idx = canonicalSources.indexWhere(
      (ms) => (ms['Id']?.toString() ?? '') == normalizedId,
    );
    if (idx < 0) {
      idx = sources.indexWhere(
        (ms) => (ms['Id']?.toString() ?? '') == normalizedId,
      );
    }
    if (idx < 0) return;
    await widget.appState.setSeriesMediaSourceIndex(
      serverId: serverId,
      seriesId: sid,
      mediaSourceIndex: idx,
    );
  }

  Future<void> _switchMediaSourceById(
    String sourceId, {
    List<Map<String, dynamic>>? knownSources,
  }) async {
    final selected = sourceId.trim();
    if (selected.isEmpty) return;
    final current = (_mediaSourceId ?? _selectedMediaSourceId ?? '').trim();
    if (selected == current) return;

    final pos = _playerService.isInitialized ? _lastPosition : Duration.zero;
    _maybeReportPlaybackProgress(pos, force: true);

    final sources = knownSources ??
        await _ensureMediaSourcesLoaded(
            forceRefresh: _availableMediaSources.isEmpty);
    await _rememberSeriesMediaSourceIndex(
      sources: sources,
      selectedSourceId: selected,
    );

    if (!mounted) return;
    setState(() {
      _selectedMediaSourceId = selected;
      _selectedAudioStreamIndex = null;
      _selectedSubtitleStreamIndex = null;
      _overrideStartPosition = null;
      _overrideResumeImmediately = false;
      _skipAutoResumeOnce = true;
      _loading = true;
      _playError = null;
    });
    await _init();
    if (!mounted || _playError != null || !_playerService.isInitialized) return;
    await _resumePlaybackAfterSwitch(pos);
  }

  Future<void> _switchVersion() async {
    late final List<Map<String, dynamic>> sources;
    try {
      sources = await _ensureMediaSourcesLoaded();
    } catch (_) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('无法获取版本列表')),
      );
      return;
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
    await _switchMediaSourceById(selected, knownSources: sources);
  }

  @override
  Widget build(BuildContext context) {
    final initialized = _playerService.isInitialized;
    final controlsEnabled = initialized &&
        !_loading &&
        _playError == null &&
        !_desktopRouteSwitching;
    final duration = initialized ? _playerService.duration : Duration.zero;
    final isPlaying = initialized ? _playerService.isPlaying : false;
    final enableBlur = !widget.isTv && widget.appState.enableBlurEffects;
    final useDesktopCinematic = _useDesktopPlaybackUi;
    final remoteEnabled = widget.isTv ||
        (!useDesktopCinematic && widget.appState.forceRemoteControlKeys);
    _remoteEnabled = remoteEnabled;

    return Focus(
      focusNode: _tvSurfaceFocusNode,
      autofocus: remoteEnabled || useDesktopCinematic,
      canRequestFocus: remoteEnabled || useDesktopCinematic,
      skipTraversal: true,
      onKeyEvent: (node, event) {
        final desktopShortcutResult = _handleDesktopShortcutKeyEvent(event);
        if (desktopShortcutResult != KeyEventResult.ignored) {
          return desktopShortcutResult;
        }
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
        backgroundColor:
            useDesktopCinematic ? Colors.transparent : Colors.black,
        extendBodyBehindAppBar: !useDesktopCinematic,
        appBar: useDesktopCinematic
            ? null
            : PreferredSize(
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
                                          style: const TextStyle(
                                              color: Colors.white),
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
                                      defaultTargetPlatform ==
                                          TargetPlatform.android)
                                    PopupMenuItem(
                                      value: _PlayerMenuAction.switchCore,
                                      child: Row(
                                        children: [
                                          Icon(Icons.tune,
                                              color: scheme.secondary),
                                          const SizedBox(width: 10),
                                          const Text(
                                            '切换内核',
                                            style:
                                                TextStyle(color: Colors.white),
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
        body: useDesktopCinematic
            ? _buildDesktopCinematicBody(
                context,
                controlsEnabled: controlsEnabled,
                duration: duration,
                isPlaying: isPlaying,
              )
            : Column(
                children: [
                  Expanded(
                    child: Container(
                      color: Colors.black,
                      child: initialized
                          ? Stack(
                              fit: StackFit.expand,
                              children: [
                                Video(
                                  key: ValueKey(_playerService.controller),
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
                                            padding:
                                                const EdgeInsets.only(top: 12),
                                            child: Text(
                                              '缓冲中 ${(_bufferingPct! <= 1 ? _bufferingPct! * 100 : _bufferingPct!).clamp(0, 100).toStringAsFixed(0)}%',
                                              style: const TextStyle(
                                                  color: Colors.white),
                                            ),
                                          ),
                                        if (widget.appState.showBufferSpeed)
                                          Padding(
                                            padding: EdgeInsets.only(
                                              top: _bufferingPct != null
                                                  ? 6
                                                  : 12,
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
                                                final pos =
                                                    _doubleTapDownPosition ??
                                                        Offset(w / 2, 0);
                                                // ignore: unawaited_futures
                                                _handleDoubleTap(pos, w);
                                              }
                                            : null,
                                        onHorizontalDragStart:
                                            (controlsEnabled &&
                                                    widget.appState.gestureSeek)
                                                ? _onSeekDragStart
                                                : null,
                                        onHorizontalDragUpdate:
                                            (controlsEnabled &&
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
                                        onVerticalDragStart: (controlsEnabled &&
                                                sideDragEnabled)
                                            ? (d) =>
                                                _onSideDragStart(d, width: w)
                                            : null,
                                        onVerticalDragUpdate:
                                            (controlsEnabled && sideDragEnabled)
                                                ? (d) => _onSideDragUpdate(d,
                                                    height: h)
                                                : null,
                                        onVerticalDragEnd:
                                            (controlsEnabled && sideDragEnabled)
                                                ? _onSideDragEnd
                                                : null,
                                        onLongPressStart: (controlsEnabled &&
                                                widget.appState
                                                    .gestureLongPressSpeed)
                                            ? _onLongPressStart
                                            : null,
                                        onLongPressMoveUpdate:
                                            (controlsEnabled &&
                                                    widget.appState
                                                        .gestureLongPressSpeed &&
                                                    widget.appState
                                                        .longPressSlideSpeed)
                                                ? (d) => _onLongPressMoveUpdate(
                                                      d,
                                                      height: h,
                                                    )
                                                : null,
                                        onLongPressEnd: (controlsEnabled &&
                                                widget.appState
                                                    .gestureLongPressSpeed)
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
                                        padding: const EdgeInsets.fromLTRB(
                                            12, 12, 12, 0),
                                        child: Material(
                                          color: Colors.black54,
                                          borderRadius:
                                              BorderRadius.circular(999),
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
                                                  final end =
                                                      _introTimestamps?.end;
                                                  final endText = (end !=
                                                              null &&
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
                                                      BorderRadius.circular(
                                                          999),
                                                  child: Container(
                                                    padding: const EdgeInsets
                                                        .symmetric(
                                                      horizontal: 10,
                                                      vertical: 6,
                                                    ),
                                                    decoration: BoxDecoration(
                                                      color: Colors.white
                                                          .withValues(
                                                              alpha: 0.18),
                                                      borderRadius:
                                                          BorderRadius.circular(
                                                              999),
                                                    ),
                                                    child: const Row(
                                                      mainAxisSize:
                                                          MainAxisSize.min,
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
                                                  onTap:
                                                      _dismissSkipIntroPrompt,
                                                  borderRadius:
                                                      BorderRadius.circular(
                                                          999),
                                                  child: Container(
                                                    padding: const EdgeInsets
                                                        .symmetric(
                                                      horizontal: 10,
                                                      vertical: 6,
                                                    ),
                                                    decoration: BoxDecoration(
                                                      color: Colors.white
                                                          .withValues(
                                                              alpha: 0.12),
                                                      borderRadius:
                                                          BorderRadius.circular(
                                                              999),
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
                                        padding: const EdgeInsets.symmetric(
                                            vertical: 12),
                                        child: Material(
                                          color: Colors.black54,
                                          borderRadius:
                                              BorderRadius.circular(999),
                                          clipBehavior: Clip.antiAlias,
                                          child: InkWell(
                                            onTap: _resumeToHistoryPosition,
                                            child: Padding(
                                              padding:
                                                  const EdgeInsets.symmetric(
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
                                        padding: const EdgeInsets.symmetric(
                                            vertical: 12),
                                        child: Material(
                                          color: Colors.black54,
                                          borderRadius:
                                              BorderRadius.circular(999),
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
                                                      BorderRadius.circular(
                                                          999),
                                                  child: Container(
                                                    padding: const EdgeInsets
                                                        .symmetric(
                                                      horizontal: 10,
                                                      vertical: 6,
                                                    ),
                                                    decoration: BoxDecoration(
                                                      color: Colors.white
                                                          .withValues(
                                                              alpha: 0.18),
                                                      borderRadius:
                                                          BorderRadius.circular(
                                                              999),
                                                    ),
                                                    child: const Row(
                                                      mainAxisSize:
                                                          MainAxisSize.min,
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
                                    minimum: const EdgeInsets.fromLTRB(
                                        12, 0, 12, 12),
                                    child: AnimatedOpacity(
                                      opacity: _controlsVisible ? 1 : 0,
                                      duration:
                                          const Duration(milliseconds: 200),
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
                                                  LogicalKeyboardKey
                                                      .arrowDown) {
                                                final moved =
                                                    FocusScope.of(context)
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
                                              playbackRate: _playerService
                                                  .player.state.rate,
                                              onSetPlaybackRate: (rate) async {
                                                _showControls();
                                                if (!_playerService
                                                    .isInitialized) {
                                                  return;
                                                }
                                                await _playerService.player
                                                    .setRate(rate);
                                                if (mounted) setState(() {});
                                              },
                                              heatmap: _danmakuHeatmap,
                                              showHeatmap:
                                                  _danmakuShowHeatmap &&
                                                      _danmakuHeatmap
                                                          .isNotEmpty,
                                              seekBackwardSeconds:
                                                  _seekBackSeconds,
                                              seekForwardSeconds:
                                                  _seekForwardSeconds,
                                              showSystemTime: widget.appState
                                                  .showSystemTimeInControls,
                                              showBattery: widget.appState
                                                  .showBatteryInControls,
                                              showBufferSpeed: widget
                                                  .appState.showBufferSpeed,
                                              buffering: _buffering,
                                              bufferSpeedX: _bufferSpeedX,
                                              netSpeedBytesPerSecond:
                                                  _netSpeedBytesPerSecond,
                                              onRequestThumbnail:
                                                  _thumbnailer == null
                                                      ? null
                                                      : (pos) => _thumbnailer!
                                                              .getThumbnail(
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
                                                  flushBuffer:
                                                      _flushBufferOnSeek,
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
                                                        seconds:
                                                            _seekBackSeconds);
                                                final pos =
                                                    target < Duration.zero
                                                        ? Duration.zero
                                                        : target;
                                                await _playerService.seek(
                                                  pos,
                                                  flushBuffer:
                                                      _flushBufferOnSeek,
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
                                                        seconds:
                                                            _seekForwardSeconds);
                                                final pos =
                                                    (d > Duration.zero &&
                                                            target > d)
                                                        ? d
                                                        : target;
                                                await _playerService.seek(
                                                  pos,
                                                  flushBuffer:
                                                      _flushBufferOnSeek,
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
                                _buildEpisodePickerOverlay(
                                    enableBlur: enableBlur),
                              ],
                            )
                          : _playError != null
                              ? Center(
                                  child: Text(
                                  '播放失败：$_playError',
                                  style:
                                      const TextStyle(color: Colors.redAccent),
                                ))
                              : const Center(
                                  child: CircularProgressIndicator()),
                    ),
                  ),
                  if (_loading) const LinearProgressIndicator(),
                ],
              ),
      ),
    );
  }

  static const Duration _desktopAnimDuration = Duration(milliseconds: 220);

  void _toggleDesktopPanel(_DesktopSidePanel panel) {
    if (panel == _DesktopSidePanel.line) {
      // ignore: unawaited_futures
      unawaited(_showDesktopRouteSheet());
      return;
    }
    if (panel == _DesktopSidePanel.audio) {
      _showAudioTracks(context);
      return;
    }
    if (panel == _DesktopSidePanel.subtitle) {
      _showSubtitleTracks(context);
      return;
    }
    if (panel == _DesktopSidePanel.none) {
      setState(() {
        _desktopSidePanel = _DesktopSidePanel.none;
        _desktopSpeedPanelVisible = false;
      });
      _scheduleControlsHide();
      return;
    }

    final next = _desktopSidePanel == panel ? _DesktopSidePanel.none : panel;
    setState(() {
      _desktopSidePanel = next;
      _desktopSpeedPanelVisible = false;
    });
    if (next == _DesktopSidePanel.episode) {
      // ignore: unawaited_futures
      unawaited(_ensureEpisodePickerLoaded());
    }
    if (next == _DesktopSidePanel.none) {
      _scheduleControlsHide();
    } else {
      _showControls(scheduleHide: false);
    }
  }

  void _toggleDesktopFullscreen() {
    setState(() {
      _desktopFullscreen = !_desktopFullscreen;
      _desktopSidePanel = _DesktopSidePanel.none;
      _desktopSpeedPanelVisible = false;
    });
    unawaited(DesktopWindow.setBorderlessFullscreen(_desktopFullscreen));
    _showControls(scheduleHide: false);
  }

  Future<void> _loadDesktopLineSources({bool forceRefresh = false}) async {
    if (_desktopLineLoading) return;
    setState(() => _desktopLineLoading = true);
    try {
      final sources =
          await _ensureMediaSourcesLoaded(forceRefresh: forceRefresh);
      if (!mounted) return;
      setState(() => _availableMediaSources = sources);
    } catch (_) {
      // Keep current cache and show empty state.
    } finally {
      if (mounted) setState(() => _desktopLineLoading = false);
    }
  }

  String? get _playbackServerId =>
      widget.server?.id ?? widget.appState.activeServerId;

  String? _playbackDomainRemark(String url) {
    final serverId = _playbackServerId;
    if (serverId == null || serverId.isEmpty) {
      return widget.appState.domainRemark(url);
    }
    return widget.appState.serverDomainRemark(serverId, url);
  }

  Future<List<RouteEntry>> _resolveDesktopRouteEntries({
    bool forceRefresh = false,
  }) async {
    final serverId = _playbackServerId;
    final usingActiveServer = serverId == null ||
        serverId.isEmpty ||
        serverId == widget.appState.activeServerId;

    final customDomains = (serverId == null || serverId.isEmpty)
        ? widget.appState.customDomains
        : widget.appState.customDomainsOfServer(serverId);
    final customEntries = customDomains
        .map((d) => DomainInfo(name: d.name, url: d.url))
        .toList(growable: false);

    List<DomainInfo> pluginDomains = const [];
    if (usingActiveServer) {
      if (forceRefresh || widget.appState.domains.isEmpty) {
        await widget.appState.refreshDomains();
      }
      pluginDomains = List<DomainInfo>.from(widget.appState.domains);
    } else {
      final access = _serverAccess;
      if (access != null) {
        try {
          pluginDomains = List<DomainInfo>.from(
            await access.adapter.fetchDomains(access.auth, allowFailure: true),
          );
        } catch (_) {}
      }
    }

    final knownUrls = <String>{
      for (final d in customEntries) d.url,
      for (final d in pluginDomains) d.url,
      (_baseUrl ?? '').trim(),
    };
    final historyEntries = <DomainInfo>[];
    for (final raw in _desktopRouteHistory) {
      final url = raw.trim();
      if (url.isEmpty || knownUrls.contains(url)) continue;
      historyEntries.add(
        DomainInfo(name: '上次线路 ${historyEntries.length + 1}', url: url),
      );
      knownUrls.add(url);
      if (historyEntries.length >= _desktopRouteHistoryLimit) break;
    }

    return buildRouteEntries(
      currentUrl: _baseUrl,
      customEntries: [...historyEntries, ...customEntries],
      pluginDomains: pluginDomains,
    );
  }

  void _rememberDesktopRouteHistory(String url) {
    final v = url.trim();
    if (v.isEmpty) return;
    _desktopRouteHistory.removeWhere((e) => e == v);
    _desktopRouteHistory.insert(0, v);
    if (_desktopRouteHistory.length > _desktopRouteHistoryLimit) {
      _desktopRouteHistory.removeRange(
        _desktopRouteHistoryLimit,
        _desktopRouteHistory.length,
      );
    }
  }

  Future<void> _switchPlaybackRoute(String url) async {
    final nextUrl = url.trim();
    if (nextUrl.isEmpty) return;
    final currentUrl = (_baseUrl ?? '').trim();
    if (currentUrl == nextUrl) return;
    final serverId = _playbackServerId;
    if (serverId == null || serverId.isEmpty) return;
    if (_desktopRouteSwitching) return;

    if (mounted) {
      setState(() => _desktopRouteSwitching = true);
    } else {
      _desktopRouteSwitching = true;
    }
    _rememberDesktopRouteHistory(currentUrl);

    final resumePos =
        _playerService.isInitialized ? _lastPosition : Duration.zero;
    _maybeReportPlaybackProgress(resumePos, force: true);
    final previousSources =
        List<Map<String, dynamic>>.from(_availableMediaSources);
    final previousSelectedSourceId = _selectedMediaSourceId;
    final previousAudioIndex = _selectedAudioStreamIndex;
    final previousSubtitleIndex = _selectedSubtitleStreamIndex;
    var routeUpdated = false;

    Future<void> restorePreviousRoute({String? message}) async {
      try {
        await widget.appState.updateServerRoute(serverId, url: currentUrl);
      } catch (_) {}
      _serverAccess =
          resolveServerAccess(appState: widget.appState, server: widget.server);
      if (!mounted) return;
      setState(() {
        _availableMediaSources = previousSources;
        _selectedMediaSourceId = previousSelectedSourceId;
        _selectedAudioStreamIndex = previousAudioIndex;
        _selectedSubtitleStreamIndex = previousSubtitleIndex;
        _overrideStartPosition = null;
        _overrideResumeImmediately = false;
        _skipAutoResumeOnce = true;
        _desktopSidePanel = _DesktopSidePanel.none;
        _desktopSpeedPanelVisible = false;
        _loading = true;
        _playError = null;
      });
      await _init();
      if (!mounted) return;
      await _resumePlaybackAfterSwitch(resumePos);
      if (!mounted || message == null || message.trim().isEmpty) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(message.trim())),
      );
    }

    try {
      await widget.appState.updateServerRoute(serverId, url: nextUrl);
      routeUpdated = true;
      _serverAccess =
          resolveServerAccess(appState: widget.appState, server: widget.server);
      if (!mounted) return;
      setState(() {
        _availableMediaSources = const [];
        _selectedMediaSourceId = null;
        _selectedAudioStreamIndex = null;
        _selectedSubtitleStreamIndex = null;
        _overrideStartPosition = null;
        _overrideResumeImmediately = false;
        _skipAutoResumeOnce = true;
        _desktopSidePanel = _DesktopSidePanel.none;
        _desktopSpeedPanelVisible = false;
        _loading = true;
        _playError = null;
      });
      await _init();
      final hasVideo = await _waitForVideoSignal();
      final switchOk = mounted &&
          _playError == null &&
          _playerService.isInitialized &&
          hasVideo;
      if (!switchOk) {
        await restorePreviousRoute(
          message: '新线路无画面，已还原到原线路',
        );
        return;
      }
      await _resumePlaybackAfterSwitch(resumePos);
    } catch (e) {
      if (routeUpdated) {
        await restorePreviousRoute();
      }
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('线路切换失败：$e')),
      );
    } finally {
      if (mounted) {
        setState(() => _desktopRouteSwitching = false);
      } else {
        _desktopRouteSwitching = false;
      }
    }
  }

  Future<void> _showDesktopRouteSheet() async {
    if (!mounted) return;
    _showControls(scheduleHide: false);
    Future<List<RouteEntry>> entriesFuture = _resolveDesktopRouteEntries();

    await showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      isScrollControlled: true,
      builder: (ctx) {
        return SafeArea(
          child: StatefulBuilder(
            builder: (context, setSheetState) {
              return SizedBox(
                height: math.min(MediaQuery.sizeOf(context).height * 0.72, 620),
                child: FutureBuilder<List<RouteEntry>>(
                  future: entriesFuture,
                  builder: (context, snapshot) {
                    final loading =
                        snapshot.connectionState != ConnectionState.done;
                    final entries = snapshot.data ?? const <RouteEntry>[];
                    final isDark =
                        Theme.of(context).brightness == Brightness.dark;
                    return Column(
                      children: [
                        Padding(
                          padding: const EdgeInsets.fromLTRB(16, 6, 10, 6),
                          child: Row(
                            children: [
                              Expanded(
                                child: Text(
                                  '线路切换',
                                  style:
                                      Theme.of(context).textTheme.titleMedium,
                                ),
                              ),
                              IconButton(
                                tooltip: '刷新线路',
                                onPressed: loading
                                    ? null
                                    : () {
                                        setSheetState(() {
                                          entriesFuture =
                                              _resolveDesktopRouteEntries(
                                            forceRefresh: true,
                                          );
                                        });
                                      },
                                icon: const Icon(Icons.refresh),
                              ),
                            ],
                          ),
                        ),
                        const Divider(height: 1),
                        if (loading)
                          const Expanded(
                            child: Center(child: CircularProgressIndicator()),
                          )
                        else if (entries.isEmpty)
                          const Expanded(
                            child: Center(child: Text('当前服务器暂无可用线路')),
                          )
                        else
                          Expanded(
                            child: ListView.separated(
                              padding: const EdgeInsets.symmetric(
                                horizontal: 12,
                                vertical: 8,
                              ),
                              itemCount: entries.length,
                              separatorBuilder: (_, __) =>
                                  const SizedBox(height: 6),
                              itemBuilder: (context, index) {
                                final entry = entries[index];
                                final d = entry.domain;
                                final selected =
                                    (_baseUrl ?? '').trim() == d.url;
                                final name = d.name.trim().isEmpty
                                    ? d.url
                                    : d.name.trim();
                                final remark = _playbackDomainRemark(d.url);
                                return ListTile(
                                  dense: true,
                                  shape: RoundedRectangleBorder(
                                    borderRadius: BorderRadius.circular(12),
                                  ),
                                  tileColor: isDark
                                      ? Colors.white.withValues(
                                          alpha: selected ? 0.16 : 0.06,
                                        )
                                      : Colors.black.withValues(
                                          alpha: selected ? 0.1 : 0.04,
                                        ),
                                  title: Text(
                                    name,
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                  ),
                                  subtitle: (remark ?? '').trim().isEmpty
                                      ? Text(
                                          d.url,
                                          maxLines: 1,
                                          overflow: TextOverflow.ellipsis,
                                        )
                                      : Column(
                                          crossAxisAlignment:
                                              CrossAxisAlignment.start,
                                          children: [
                                            Text(
                                              remark!.trim(),
                                              maxLines: 1,
                                              overflow: TextOverflow.ellipsis,
                                            ),
                                            Text(
                                              d.url,
                                              maxLines: 1,
                                              overflow: TextOverflow.ellipsis,
                                            ),
                                          ],
                                        ),
                                  trailing: selected
                                      ? const Icon(Icons.check_circle_rounded)
                                      : null,
                                  onTap: () async {
                                    Navigator.of(ctx).pop();
                                    await _switchPlaybackRoute(d.url);
                                  },
                                );
                              },
                            ),
                          ),
                      ],
                    );
                  },
                ),
              );
            },
          ),
        );
      },
    );
  }

  Future<void> _showDesktopVersionSheet() async {
    if (!mounted) return;
    _showControls(scheduleHide: false);
    Future<List<Map<String, dynamic>>> sourcesFuture =
        _ensureMediaSourcesLoaded();

    await showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      isScrollControlled: true,
      builder: (ctx) {
        return SafeArea(
          child: StatefulBuilder(
            builder: (context, setSheetState) {
              return SizedBox(
                height: math.min(MediaQuery.sizeOf(context).height * 0.72, 620),
                child: FutureBuilder<List<Map<String, dynamic>>>(
                  future: sourcesFuture,
                  builder: (context, snapshot) {
                    final loading =
                        snapshot.connectionState != ConnectionState.done;
                    final sources =
                        snapshot.data ?? const <Map<String, dynamic>>[];
                    final errorText =
                        snapshot.hasError ? snapshot.error.toString() : '';
                    final sortedSources =
                        List<Map<String, dynamic>>.from(sources)
                          ..sort(_compareMediaSourcesByQuality);
                    final current =
                        (_mediaSourceId ?? _selectedMediaSourceId ?? '').trim();
                    final isDark =
                        Theme.of(context).brightness == Brightness.dark;

                    return Column(
                      children: [
                        Padding(
                          padding: const EdgeInsets.fromLTRB(16, 6, 10, 6),
                          child: Row(
                            children: [
                              Expanded(
                                child: Text(
                                  '版本选择',
                                  style:
                                      Theme.of(context).textTheme.titleMedium,
                                ),
                              ),
                              IconButton(
                                tooltip: '刷新版本',
                                onPressed: loading
                                    ? null
                                    : () {
                                        setSheetState(() {
                                          sourcesFuture =
                                              _ensureMediaSourcesLoaded(
                                            forceRefresh: true,
                                          );
                                        });
                                      },
                                icon: const Icon(Icons.refresh),
                              ),
                            ],
                          ),
                        ),
                        const Divider(height: 1),
                        if (loading)
                          const Expanded(
                            child: Center(child: CircularProgressIndicator()),
                          )
                        else if (errorText.trim().isNotEmpty &&
                            sortedSources.isEmpty)
                          Expanded(
                            child: Center(
                              child: Text(
                                errorText.trim(),
                                textAlign: TextAlign.center,
                              ),
                            ),
                          )
                        else if (sortedSources.isEmpty)
                          const Expanded(
                            child: Center(child: Text('当前视频暂无可切换版本')),
                          )
                        else
                          Expanded(
                            child: ListView.separated(
                              padding: const EdgeInsets.symmetric(
                                horizontal: 12,
                                vertical: 8,
                              ),
                              itemCount: sortedSources.length,
                              separatorBuilder: (_, __) =>
                                  const SizedBox(height: 6),
                              itemBuilder: (context, index) {
                                final ms = sortedSources[index];
                                final sourceId =
                                    (ms['Id']?.toString() ?? '').trim();
                                final selected =
                                    sourceId.isNotEmpty && sourceId == current;
                                return ListTile(
                                  dense: true,
                                  shape: RoundedRectangleBorder(
                                    borderRadius: BorderRadius.circular(12),
                                  ),
                                  tileColor: isDark
                                      ? Colors.white.withValues(
                                          alpha: selected ? 0.16 : 0.06,
                                        )
                                      : Colors.black.withValues(
                                          alpha: selected ? 0.1 : 0.04,
                                        ),
                                  title: Text(
                                    _mediaSourceTitle(ms),
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                  ),
                                  subtitle: Text(
                                    _mediaSourceSubtitle(ms),
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                  ),
                                  trailing: selected
                                      ? const Icon(Icons.check_circle_rounded)
                                      : null,
                                  onTap: sourceId.isEmpty
                                      ? null
                                      : () async {
                                          Navigator.of(ctx).pop();
                                          await _switchMediaSourceById(
                                            sourceId,
                                            knownSources: sources,
                                          );
                                        },
                                );
                              },
                            ),
                          ),
                      ],
                    );
                  },
                ),
              );
            },
          ),
        );
      },
    );
  }

  String _desktopEpisodeMark(
    MediaItem episode, {
    int fallbackSeason = 1,
    int fallbackEpisode = 1,
  }) {
    final season = (episode.seasonNumber ?? fallbackSeason).clamp(1, 999);
    final ep = (episode.episodeNumber ?? fallbackEpisode).clamp(1, 999);
    return 'S${season.toString().padLeft(2, '0')}E${ep.toString().padLeft(2, '0')}';
  }

  String _desktopTopCenterTitle() {
    final item = _episodePickerItem;
    final title = (item?.name.trim().isNotEmpty ?? false)
        ? item!.name.trim()
        : widget.title.trim();
    final season = (item?.seasonNumber ?? 1).clamp(1, 999);
    final episode = (item?.episodeNumber ?? 1).clamp(1, 999);
    final mark =
        'S${season.toString().padLeft(2, '0')}E${episode.toString().padLeft(2, '0')}';
    return '第${season.toString().padLeft(2, '0')}季  $mark  $title';
  }

  String _desktopRouteTooltipText() {
    final url = (_baseUrl ?? '').trim();
    if (url.isEmpty) return '未连接线路';
    final remark = (_playbackDomainRemark(url) ?? '').trim();
    if (remark.isEmpty) return url;
    return '$remark\n$url';
  }

  String _desktopVersionTooltipText() {
    final currentId = (_mediaSourceId ?? _selectedMediaSourceId ?? '').trim();
    if (currentId.isEmpty) return '版本：默认';
    if (_availableMediaSources.isEmpty) return '版本：点击加载';

    Map<String, dynamic>? current;
    for (final ms in _availableMediaSources) {
      final id = (ms['Id']?.toString() ?? '').trim();
      if (id == currentId) {
        current = ms;
        break;
      }
    }
    if (current == null) return '版本：点击加载';

    final title = _mediaSourceTitle(current);
    final subtitle = _mediaSourceSubtitle(current).trim();
    if (subtitle.isEmpty) return '版本：$title';
    return '版本：$title\n$subtitle';
  }

  String _desktopNetSpeedMbPerSecondLabel() {
    final bytes = _netSpeedBytesPerSecond;
    if (bytes == null || !bytes.isFinite || bytes <= 0) return '-- MB/S';
    final mb = bytes / (1024 * 1024);
    if (mb >= 10) return '${mb.toStringAsFixed(1)} MB/S';
    return '${mb.toStringAsFixed(2)} MB/S';
  }

  Widget _buildDesktopCinematicBody(
    BuildContext context, {
    required bool controlsEnabled,
    required Duration duration,
    required bool isPlaying,
  }) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final shellColor =
        isDark ? const Color(0xB017191D) : const Color(0xD9FFFFFF);
    final shellBorder = isDark
        ? Colors.white.withValues(alpha: 0.1)
        : Colors.black.withValues(alpha: 0.08);
    final shellRadius = BorderRadius.circular(_desktopFullscreen ? 0 : 30);

    return SafeArea(
      top: !_desktopFullscreen,
      bottom: !_desktopFullscreen,
      left: !_desktopFullscreen,
      right: !_desktopFullscreen,
      child: Stack(
        fit: StackFit.expand,
        children: [
          _desktopFullscreen
              ? const ColoredBox(color: Colors.black)
              : _buildDesktopBackdrop(isDark: isDark),
          Padding(
            padding: _desktopFullscreen
                ? EdgeInsets.zero
                : const EdgeInsets.fromLTRB(20, 16, 20, 20),
            child: _buildDesktopGlassPanel(
              context: context,
              blurSigma: _desktopFullscreen ? 0 : 14,
              color: _desktopFullscreen ? Colors.transparent : shellColor,
              borderRadius: shellRadius,
              borderColor:
                  _desktopFullscreen ? Colors.transparent : shellBorder,
              child: Padding(
                padding: _desktopFullscreen
                    ? EdgeInsets.zero
                    : const EdgeInsets.all(16),
                child: _buildDesktopVideoSurface(
                  context,
                  isDark: isDark,
                  controlsEnabled: controlsEnabled,
                  duration: duration,
                  isPlaying: isPlaying,
                ),
              ),
            ),
          ),
          if (_loading)
            const Align(
              alignment: Alignment.topCenter,
              child: LinearProgressIndicator(minHeight: 2),
            ),
        ],
      ),
    );
  }

  Widget _buildDesktopBackdrop({required bool isDark}) {
    final background =
        isDark ? const Color(0xFF060607) : const Color(0xFFF2F4F7);
    final centerGlowA = isDark
        ? const Color(0xFF3A4F7C).withValues(alpha: 0.42)
        : const Color(0xFFA8BCE8).withValues(alpha: 0.52);
    final centerGlowB = isDark
        ? const Color(0xFF5A3148).withValues(alpha: 0.35)
        : const Color(0xFFF4C5DA).withValues(alpha: 0.48);
    final cornerGlow = isDark
        ? Colors.white.withValues(alpha: 0.05)
        : Colors.black.withValues(alpha: 0.04);

    return DecoratedBox(
      decoration: BoxDecoration(color: background),
      child: Stack(
        fit: StackFit.expand,
        children: [
          DecoratedBox(
            decoration: BoxDecoration(
              gradient: RadialGradient(
                center: const Alignment(-0.2, -0.45),
                radius: 1.2,
                colors: [centerGlowA, centerGlowB, background],
              ),
            ),
          ),
          Positioned(
            left: -120,
            top: -80,
            child: Container(
              width: 300,
              height: 300,
              decoration:
                  BoxDecoration(shape: BoxShape.circle, color: cornerGlow),
            ),
          ),
          Positioned(
            right: -90,
            bottom: -130,
            child: Container(
              width: 340,
              height: 340,
              decoration:
                  BoxDecoration(shape: BoxShape.circle, color: cornerGlow),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildDesktopVideoSurface(
    BuildContext context, {
    required bool isDark,
    required bool controlsEnabled,
    required Duration duration,
    required bool isPlaying,
  }) {
    final frameRadius = _desktopFullscreen ? 0.0 : 30.0;
    final panelColor =
        isDark ? const Color(0x99111113) : const Color(0xD9FFFFFF);
    final panelBorder = isDark
        ? Colors.white.withValues(alpha: 0.14)
        : Colors.black.withValues(alpha: 0.08);

    return _buildDesktopGlassPanel(
      context: context,
      blurSigma: _desktopFullscreen ? 0 : 14,
      color: _desktopFullscreen ? Colors.transparent : panelColor,
      borderRadius: BorderRadius.circular(frameRadius),
      borderColor: _desktopFullscreen ? Colors.transparent : panelBorder,
      child: ClipRRect(
        borderRadius: BorderRadius.circular(frameRadius),
        child: DecoratedBox(
          decoration: const BoxDecoration(color: Colors.black),
          child: Stack(
            fit: StackFit.expand,
            children: [
              if (_playerService.isInitialized) ...[
                Video(
                  key: ValueKey(_playerService.controller),
                  controller: _playerService.controller,
                  controls: NoVideoControls,
                  subtitleViewConfiguration: _subtitleViewConfiguration,
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
                  Positioned.fill(
                    child: ColoredBox(
                      color: Colors.black54,
                      child: Center(
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            const CircularProgressIndicator(),
                            const SizedBox(height: 12),
                            Text(
                              '网速：${_desktopNetSpeedMbPerSecondLabel()}',
                              style: const TextStyle(color: Colors.white),
                            ),
                          ],
                        ),
                      ),
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
                            ? (d) => _doubleTapDownPosition = d.localPosition
                            : null,
                        onDoubleTap: controlsEnabled
                            ? () {
                                final pos =
                                    _doubleTapDownPosition ?? Offset(w / 2, 0);
                                // ignore: unawaited_futures
                                _handleDoubleTap(pos, w);
                              }
                            : null,
                        onHorizontalDragStart:
                            (controlsEnabled && widget.appState.gestureSeek)
                                ? _onSeekDragStart
                                : null,
                        onHorizontalDragUpdate:
                            (controlsEnabled && widget.appState.gestureSeek)
                                ? (d) => _onSeekDragUpdate(
                                      d,
                                      width: w,
                                      duration: duration,
                                    )
                                : null,
                        onHorizontalDragEnd:
                            (controlsEnabled && widget.appState.gestureSeek)
                                ? _onSeekDragEnd
                                : null,
                        onVerticalDragStart:
                            (controlsEnabled && sideDragEnabled)
                                ? (d) => _onSideDragStart(d, width: w)
                                : null,
                        onVerticalDragUpdate:
                            (controlsEnabled && sideDragEnabled)
                                ? (d) => _onSideDragUpdate(d, height: h)
                                : null,
                        onVerticalDragEnd: (controlsEnabled && sideDragEnabled)
                            ? _onSideDragEnd
                            : null,
                        onLongPressStart: (controlsEnabled &&
                                widget.appState.gestureLongPressSpeed)
                            ? _onLongPressStart
                            : null,
                        onLongPressMoveUpdate: (controlsEnabled &&
                                widget.appState.gestureLongPressSpeed &&
                                widget.appState.longPressSlideSpeed)
                            ? (d) => _onLongPressMoveUpdate(d, height: h)
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
                                _gestureOverlayIcon ?? Icons.info_outline,
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
                Positioned.fill(
                  child: SafeArea(
                    minimum: _desktopFullscreen
                        ? const EdgeInsets.fromLTRB(8, 8, 8, 8)
                        : const EdgeInsets.fromLTRB(12, 12, 12, 12),
                    child: Stack(
                      children: [
                        Align(
                          alignment: Alignment.topCenter,
                          child: MouseRegion(
                            onEnter: (_) =>
                                _setDesktopBarHover(top: true, hover: true),
                            onExit: (_) =>
                                _setDesktopBarHover(top: true, hover: false),
                            child: AnimatedOpacity(
                              opacity: _controlsVisible ? 1 : 0,
                              duration: _desktopAnimDuration,
                              child: IgnorePointer(
                                ignoring: !_controlsVisible,
                                child: _buildDesktopTopStatusBar(
                                  context,
                                  isDark: isDark,
                                  controlsEnabled: controlsEnabled,
                                ),
                              ),
                            ),
                          ),
                        ),
                        Align(
                          alignment: Alignment.bottomCenter,
                          child: MouseRegion(
                            onEnter: (_) =>
                                _setDesktopBarHover(top: false, hover: true),
                            onExit: (_) =>
                                _setDesktopBarHover(top: false, hover: false),
                            child: AnimatedOpacity(
                              opacity: _controlsVisible ? 1 : 0,
                              duration: _desktopAnimDuration,
                              child: IgnorePointer(
                                ignoring: !_controlsVisible,
                                child: Listener(
                                  onPointerDown: (_) =>
                                      _showControls(scheduleHide: false),
                                  child: _buildDesktopPlaybackControls(
                                    context,
                                    isDark: isDark,
                                    controlsEnabled: controlsEnabled,
                                    duration: duration,
                                    isPlaying: isPlaying,
                                  ),
                                ),
                              ),
                            ),
                          ),
                        ),
                        Align(
                          alignment: Alignment.centerRight,
                          child: Padding(
                            padding: _desktopFullscreen
                                ? const EdgeInsets.fromLTRB(0, 44, 0, 104)
                                : const EdgeInsets.fromLTRB(0, 56, 0, 124),
                            child: AnimatedSlide(
                              duration: _desktopAnimDuration,
                              curve: Curves.easeOutCubic,
                              offset: (_controlsVisible &&
                                      _desktopSidePanel !=
                                          _DesktopSidePanel.none)
                                  ? Offset.zero
                                  : const Offset(1, 0),
                              child: AnimatedOpacity(
                                duration: _desktopAnimDuration,
                                opacity: (_controlsVisible &&
                                        _desktopSidePanel !=
                                            _DesktopSidePanel.none)
                                    ? 1
                                    : 0,
                                child: IgnorePointer(
                                  ignoring: !_controlsVisible ||
                                      _desktopSidePanel ==
                                          _DesktopSidePanel.none,
                                  child: _buildDesktopSidePanel(
                                    context,
                                    isDark: isDark,
                                  ),
                                ),
                              ),
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ] else if (_playError != null)
                Center(
                  child: Text(
                    '播放失败：$_playError',
                    style: const TextStyle(color: Colors.redAccent),
                  ),
                )
              else
                const Center(child: CircularProgressIndicator()),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildDesktopTopStatusBar(
    BuildContext context, {
    required bool isDark,
    required bool controlsEnabled,
  }) {
    final titleColor = isDark ? Colors.white : Colors.black87;
    final subtitleColor = isDark ? Colors.white70 : Colors.black54;
    final chipBg = isDark
        ? Colors.black.withValues(alpha: 0.56)
        : Colors.white.withValues(alpha: 0.9);
    final chipBorder = isDark
        ? Colors.white.withValues(alpha: 0.18)
        : Colors.black.withValues(alpha: 0.12);
    final switchingRoute = _desktopRouteSwitching;

    return _buildDesktopGlassPanel(
      context: context,
      blurSigma: 0,
      color: Colors.transparent,
      borderRadius: BorderRadius.circular(18),
      borderColor: Colors.transparent,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(10, 8, 10, 8),
        child: Row(
          children: [
            IconButton(
              style: IconButton.styleFrom(
                backgroundColor: chipBg,
                foregroundColor: titleColor,
                side: BorderSide(color: chipBorder),
              ),
              tooltip: '返回',
              onPressed: Navigator.of(context).canPop()
                  ? () => Navigator.of(context).pop()
                  : null,
              icon: const Icon(Icons.arrow_back_rounded),
            ),
            const SizedBox(width: 6),
            Expanded(
              child: Text(
                _desktopTopCenterTitle(),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                textAlign: TextAlign.center,
                style: Theme.of(context).textTheme.titleSmall?.copyWith(
                      color: titleColor,
                      fontWeight: FontWeight.w700,
                    ),
              ),
            ),
            const SizedBox(width: 12),
            SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              child: Row(
                children: [
                  Container(
                    padding:
                        const EdgeInsets.symmetric(horizontal: 10, vertical: 7),
                    decoration: BoxDecoration(
                      color: chipBg,
                      borderRadius: BorderRadius.circular(12),
                      border: Border.all(
                        color: chipBorder,
                      ),
                    ),
                    child: Text(
                      '缓冲网速 ${_desktopNetSpeedMbPerSecondLabel()}',
                      style: Theme.of(context).textTheme.labelMedium?.copyWith(
                            color: subtitleColor,
                            fontWeight: FontWeight.w600,
                          ),
                    ),
                  ),
                  const SizedBox(width: 8),
                  _desktopTopActionChip(
                    context,
                    isDark: isDark,
                    icon: switchingRoute ? Icons.sync : Icons.route_outlined,
                    label: switchingRoute ? '切换中' : '切换线路',
                    active: switchingRoute,
                    tooltip: _desktopRouteTooltipText(),
                    onTap: controlsEnabled
                        ? () {
                            // ignore: unawaited_futures
                            unawaited(_showDesktopRouteSheet());
                          }
                        : null,
                  ),
                  const SizedBox(width: 8),
                  _desktopTopActionChip(
                    context,
                    isDark: isDark,
                    icon: Icons.video_file_outlined,
                    label: '版本',
                    active: (_selectedMediaSourceId ?? '').trim().isNotEmpty,
                    tooltip: _desktopVersionTooltipText(),
                    onTap: controlsEnabled
                        ? () {
                            // ignore: unawaited_futures
                            unawaited(_showDesktopVersionSheet());
                          }
                        : null,
                  ),
                  const SizedBox(width: 8),
                  _desktopTopActionChip(
                    context,
                    isDark: isDark,
                    icon: Icons.audiotrack_outlined,
                    label: '音轨选择',
                    active: false,
                    onTap: controlsEnabled
                        ? () => _showAudioTracks(context)
                        : null,
                  ),
                  const SizedBox(width: 8),
                  _desktopTopActionChip(
                    context,
                    isDark: isDark,
                    icon: Icons.subtitles_outlined,
                    label: '字幕选择',
                    active: false,
                    onTap: controlsEnabled
                        ? () => _showSubtitleTracks(context)
                        : null,
                  ),
                  const SizedBox(width: 8),
                  _desktopTopActionChip(
                    context,
                    isDark: isDark,
                    icon: Icons.comment_outlined,
                    label: '弹幕',
                    active: false,
                    onTap: controlsEnabled
                        ? () {
                            // ignore: unawaited_futures
                            unawaited(_showDanmakuSheet());
                          }
                        : null,
                  ),
                  const SizedBox(width: 8),
                  _desktopTopActionChip(
                    context,
                    isDark: isDark,
                    icon: _anime4kPreset.isOff
                        ? Icons.auto_fix_high_outlined
                        : Icons.auto_fix_high,
                    label: 'Anime4K',
                    onTap: controlsEnabled ? _showAnime4kSheet : null,
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _desktopTopActionChip(
    BuildContext context, {
    required bool isDark,
    required IconData icon,
    required String label,
    required VoidCallback? onTap,
    bool active = false,
    String? tooltip,
    double? maxLabelWidth,
  }) {
    final fg = active
        ? (isDark ? Colors.white : Colors.black87)
        : (isDark ? Colors.white70 : Colors.black54);
    final bg = active
        ? (isDark
            ? Colors.white.withValues(alpha: 0.22)
            : Colors.white.withValues(alpha: 0.9))
        : (isDark
            ? Colors.black.withValues(alpha: 0.56)
            : Colors.white.withValues(alpha: 0.9));
    final labelText = Text(
      label,
      maxLines: 1,
      overflow: TextOverflow.ellipsis,
      style: Theme.of(context).textTheme.labelMedium?.copyWith(
            color: fg,
            fontWeight: FontWeight.w600,
          ),
    );
    final labelWidget = maxLabelWidth == null
        ? labelText
        : ConstrainedBox(
            constraints: BoxConstraints(maxWidth: maxLabelWidth),
            child: labelText,
          );

    final chip = Material(
      color: Colors.transparent,
      child: InkWell(
        borderRadius: BorderRadius.circular(12),
        onTap: onTap,
        child: Ink(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 7),
          decoration: BoxDecoration(
            color: bg,
            borderRadius: BorderRadius.circular(12),
            border: Border.all(
              color: isDark
                  ? Colors.white.withValues(alpha: 0.18)
                  : Colors.black.withValues(alpha: 0.12),
            ),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(icon, size: 16, color: fg),
              const SizedBox(width: 6),
              labelWidget,
            ],
          ),
        ),
      ),
    );

    final tip = (tooltip ?? '').trim();
    if (tip.isEmpty) return chip;
    return Tooltip(message: tip, child: chip);
  }

  Widget _buildDesktopSidePanel(
    BuildContext context, {
    required bool isDark,
  }) {
    final width = (MediaQuery.sizeOf(context).width * 0.34)
        .clamp(360.0, 480.0)
        .toDouble();
    final panelColor =
        isDark ? const Color(0xEE121417) : const Color(0xF3F9FAFD);
    final panelBorder = isDark
        ? Colors.white.withValues(alpha: 0.16)
        : Colors.black.withValues(alpha: 0.08);

    return _buildDesktopGlassPanel(
      context: context,
      blurSigma: 18,
      color: panelColor,
      borderRadius: BorderRadius.circular(18),
      borderColor: panelBorder,
      child: SizedBox(
        width: width,
        child: Column(
          children: [
            _buildDesktopPanelHeader(context, title: _desktopSidePanel.title),
            const Divider(height: 1),
            Expanded(
              child: switch (_desktopSidePanel) {
                _DesktopSidePanel.line =>
                  _buildDesktopLinePanel(context, isDark: isDark),
                _DesktopSidePanel.audio =>
                  _buildDesktopAudioPanel(context, isDark: isDark),
                _DesktopSidePanel.subtitle =>
                  _buildDesktopSubtitlePanel(context, isDark: isDark),
                _DesktopSidePanel.danmaku =>
                  _buildDesktopDanmakuPanel(context, isDark: isDark),
                _DesktopSidePanel.episode =>
                  _buildDesktopEpisodePanel(context, isDark: isDark),
                _DesktopSidePanel.none => const SizedBox.shrink(),
              },
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildDesktopPanelHeader(
    BuildContext context, {
    required String title,
  }) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(14, 10, 8, 10),
      child: Row(
        children: [
          Expanded(
            child: Text(
              title,
              style: Theme.of(context).textTheme.titleSmall?.copyWith(
                    fontWeight: FontWeight.w700,
                  ),
            ),
          ),
          IconButton(
            tooltip: '关闭',
            onPressed: () {
              setState(() => _desktopSidePanel = _DesktopSidePanel.none);
              _scheduleControlsHide();
            },
            icon: const Icon(Icons.close),
          ),
        ],
      ),
    );
  }

  Widget _buildDesktopLinePanel(
    BuildContext context, {
    required bool isDark,
  }) {
    final current = (_mediaSourceId ?? _selectedMediaSourceId ?? '').trim();
    final sortedSources =
        List<Map<String, dynamic>>.from(_availableMediaSources)
          ..sort(_compareMediaSourcesByQuality);

    if (_desktopLineLoading) {
      return const Center(child: CircularProgressIndicator());
    }
    if (sortedSources.length <= 1) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Text(
                '当前剧集暂无可切换线路',
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 10),
              OutlinedButton.icon(
                onPressed: () {
                  // ignore: unawaited_futures
                  unawaited(_loadDesktopLineSources(forceRefresh: true));
                },
                icon: const Icon(Icons.refresh),
                label: const Text('刷新线路'),
              ),
            ],
          ),
        ),
      );
    }

    return ListView.separated(
      padding: const EdgeInsets.fromLTRB(12, 10, 12, 12),
      itemCount: sortedSources.length,
      separatorBuilder: (_, __) => const SizedBox(height: 8),
      itemBuilder: (context, i) {
        final source = sortedSources[i];
        final sourceId = (source['Id']?.toString() ?? '').trim();
        final selected = sourceId.isNotEmpty && sourceId == current;
        return ListTile(
          shape:
              RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
          tileColor: isDark
              ? Colors.white.withValues(alpha: selected ? 0.16 : 0.06)
              : Colors.black.withValues(alpha: selected ? 0.1 : 0.04),
          title: Text(_mediaSourceTitle(source)),
          subtitle: Text(_mediaSourceSubtitle(source)),
          trailing:
              selected ? const Icon(Icons.check_circle_outline_rounded) : null,
          onTap: sourceId.isEmpty
              ? null
              : () async {
                  await _switchMediaSourceById(
                    sourceId,
                    knownSources: sortedSources,
                  );
                },
        );
      },
    );
  }

  Widget _buildDesktopAudioPanel(
    BuildContext context, {
    required bool isDark,
  }) {
    final audios = List<AudioTrack>.from(_tracks.audio);
    final current = _playerService.player.state.track.audio;
    if (!_playerService.isInitialized) {
      return const Center(child: Text('当前未开始播放'));
    }
    if (audios.isEmpty) {
      return const Center(child: Text('暂无可选音轨'));
    }
    return ListView(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
      children: audios
          .map(
            (a) => ListTile(
              dense: true,
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(12),
              ),
              title: Text(a.title ?? a.language ?? '音轨 ${a.id}'),
              subtitle: Text(a.codec ?? ''),
              trailing: current == a ? const Icon(Icons.check) : null,
              onTap: () {
                _playerService.player.setAudioTrack(a);
                setState(() {});
              },
            ),
          )
          .toList(),
    );
  }

  Widget _buildDesktopSubtitlePanel(
    BuildContext context, {
    required bool isDark,
  }) {
    if (!_playerService.isInitialized) {
      return const Center(child: Text('当前未开始播放'));
    }
    final subs = List<SubtitleTrack>.from(_tracks.subtitle);
    final value = _playerService.player.state.track.subtitle;
    final messenger = ScaffoldMessenger.of(context);

    Future<void> pickAndAddSubtitle() async {
      final result = await FilePicker.platform.pickFiles(
        type: FileType.custom,
        allowedExtensions: const ['srt', 'ass', 'ssa', 'vtt', 'sub'],
      );
      if (result == null || result.files.isEmpty) return;
      final f = result.files.first;
      final path = (f.path ?? '').trim();
      if (path.isEmpty) {
        messenger.showSnackBar(const SnackBar(content: Text('无法读取字幕文件路径')));
        return;
      }
      try {
        await _playerService.player.setSubtitleTrack(
          SubtitleTrack.uri(path, title: f.name),
        );
        if (!mounted) return;
        setState(() => _tracks = _playerService.player.state.tracks);
      } catch (e) {
        messenger.showSnackBar(SnackBar(content: Text('添加字幕失败：$e')));
      }
    }

    return ListView(
      padding: const EdgeInsets.fromLTRB(12, 10, 12, 12),
      children: [
        Text(
          '字幕轨道',
          style: Theme.of(context).textTheme.labelLarge?.copyWith(
                fontWeight: FontWeight.w600,
              ),
        ),
        const SizedBox(height: 6),
        RadioGroup<SubtitleTrack>(
          groupValue: value,
          onChanged: (next) {
            if (next == null) return;
            _playerService.player.setSubtitleTrack(next);
            setState(() {});
          },
          child: Column(
            children: [
              RadioListTile<SubtitleTrack>(
                value: SubtitleTrack.no(),
                title: const Text('关闭'),
                dense: true,
                contentPadding: EdgeInsets.zero,
              ),
              for (final s in subs)
                RadioListTile<SubtitleTrack>(
                  value: s,
                  title: Text(_subtitleTrackTitle(s)),
                  subtitle: Text(_subtitleTrackSubtitle(s)),
                  dense: true,
                  contentPadding: EdgeInsets.zero,
                ),
            ],
          ),
        ),
        const SizedBox(height: 8),
        OutlinedButton.icon(
          onPressed: pickAndAddSubtitle,
          icon: const Icon(Icons.upload_file_outlined),
          label: const Text('导入本地字幕'),
        ),
        const Divider(height: 20),
        ListTile(
          contentPadding: EdgeInsets.zero,
          title: const Text('字幕同步'),
          subtitle: Slider(
            min: -10.0,
            max: 10.0,
            divisions: 200,
            value: _subtitleDelaySeconds.clamp(-10.0, 10.0).toDouble(),
            label: '${_subtitleDelaySeconds.toStringAsFixed(1)}s',
            onChanged: (v) async {
              setState(() => _subtitleDelaySeconds = v);
              await _applyMpvSubtitleOptions();
            },
          ),
          trailing: TextButton(
            onPressed: () async {
              setState(() => _subtitleDelaySeconds = 0.0);
              await _applyMpvSubtitleOptions();
            },
            child: const Text('重置'),
          ),
        ),
        ListTile(
          contentPadding: EdgeInsets.zero,
          title: const Text('字幕大小'),
          subtitle: Slider(
            min: 12,
            max: 60,
            divisions: 48,
            value: _subtitleFontSize.clamp(12.0, 60.0).toDouble(),
            onChanged: (v) async {
              setState(() => _subtitleFontSize = v);
              await _applyMpvSubtitleOptions();
            },
          ),
          trailing: Text('${_subtitleFontSize.round()}'),
        ),
        ListTile(
          contentPadding: EdgeInsets.zero,
          title: const Text('字幕位置'),
          subtitle: Slider(
            min: 0,
            max: 20,
            divisions: 20,
            value: _subtitlePositionStep.toDouble().clamp(0, 20),
            onChanged: (v) async {
              setState(() => _subtitlePositionStep = v.round());
              await _applyMpvSubtitleOptions();
            },
          ),
          trailing: Text('$_subtitlePositionStep'),
        ),
        SwitchListTile(
          contentPadding: EdgeInsets.zero,
          title: const Text('设置为粗体'),
          value: _subtitleBold,
          onChanged: (v) async {
            setState(() => _subtitleBold = v);
            await _applyMpvSubtitleOptions();
          },
        ),
        SwitchListTile(
          contentPadding: EdgeInsets.zero,
          title: const Text('强制覆盖 ASS/SSA 字幕'),
          value: _subtitleAssOverrideForce,
          onChanged: (v) async {
            setState(() => _subtitleAssOverrideForce = v);
            await _applyMpvSubtitleOptions();
          },
        ),
      ],
    );
  }

  Widget _buildDesktopDanmakuPanel(
    BuildContext context, {
    required bool isDark,
  }) {
    final hasSources = _danmakuSources.isNotEmpty;
    final selectedSource = (_danmakuSourceIndex >= 0 &&
            _danmakuSourceIndex < _danmakuSources.length)
        ? _danmakuSourceIndex
        : null;
    final appState = widget.appState;

    Future<void> loadOnline() async {
      if (_desktopDanmakuOnlineLoading) return;
      setState(() => _desktopDanmakuOnlineLoading = true);
      try {
        await _loadOnlineDanmakuForNetwork(showToast: true);
      } finally {
        if (mounted) setState(() => _desktopDanmakuOnlineLoading = false);
      }
    }

    Future<void> manualSearch() async {
      if (_desktopDanmakuManualLoading) return;
      setState(() => _desktopDanmakuManualLoading = true);
      try {
        await _manualMatchOnlineDanmakuForCurrent(showToast: true);
      } finally {
        if (mounted) setState(() => _desktopDanmakuManualLoading = false);
      }
    }

    Future<void> persistSelectionName() async {
      if (!appState.danmakuRememberSelectedSource) return;
      final idx = _danmakuSourceIndex;
      if (idx < 0 || idx >= _danmakuSources.length) return;
      await appState
          .setDanmakuLastSelectedSourceName(_danmakuSources[idx].name);
    }

    Future<void> pickDanmakuSource() async {
      if (!hasSources) return;
      final names = _danmakuSources.map((e) => e.name).toList(growable: false);
      final picked = await showListPickerDialog(
        context: context,
        title: '选择弹幕源',
        items: names,
        initialIndex: selectedSource,
        height: 320,
      );
      if (!mounted || picked == null) return;
      setState(() {
        _danmakuSourceIndex = picked;
        _danmakuEnabled = true;
        _rebuildDanmakuHeatmap();
        _syncDanmakuCursor(_lastPosition);
      });
      await persistSelectionName();
    }

    return ListView(
      padding: const EdgeInsets.fromLTRB(12, 10, 12, 12),
      children: [
        SwitchListTile(
          contentPadding: EdgeInsets.zero,
          title: const Text('启用弹幕'),
          value: _danmakuEnabled,
          onChanged: (v) {
            setState(() => _danmakuEnabled = v);
            if (!v) _danmakuKey.currentState?.clear();
            // ignore: unawaited_futures
            appState.setDanmakuEnabled(v);
          },
        ),
        OutlinedButton.icon(
          onPressed: () async {
            await _pickDanmakuFile();
            if (mounted) setState(() {});
          },
          icon: const Icon(Icons.upload_file_outlined),
          label: const Text('导入本地弹幕'),
        ),
        const SizedBox(height: 8),
        FilledButton.icon(
          onPressed: _desktopDanmakuOnlineLoading ? null : loadOnline,
          icon: _desktopDanmakuOnlineLoading
              ? const SizedBox(
                  width: 16,
                  height: 16,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : const Icon(Icons.cloud_download_outlined),
          label: const Text('加载在线弹幕'),
        ),
        const SizedBox(height: 8),
        OutlinedButton.icon(
          onPressed:
              (_desktopDanmakuOnlineLoading || _desktopDanmakuManualLoading)
                  ? null
                  : manualSearch,
          icon: _desktopDanmakuManualLoading
              ? const SizedBox(
                  width: 16,
                  height: 16,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : const Icon(Icons.search),
          label: const Text('手动搜索弹幕'),
        ),
        const SizedBox(height: 8),
        ListTile(
          contentPadding: EdgeInsets.zero,
          leading: const Icon(Icons.layers_outlined),
          title: const Text('弹幕源'),
          subtitle: Text(
            selectedSource == null
                ? '未选择'
                : _danmakuSources[selectedSource].name,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
          trailing: OutlinedButton(
            onPressed: hasSources ? pickDanmakuSource : null,
            child: const Text('选择'),
          ),
          onTap: hasSources ? pickDanmakuSource : null,
        ),
        const SizedBox(height: 10),
        ListTile(
          contentPadding: EdgeInsets.zero,
          title: const Text('弹幕同步'),
          subtitle: Slider(
            min: -10.0,
            max: 10.0,
            divisions: 200,
            value: _danmakuTimeOffsetSeconds.clamp(-10.0, 10.0).toDouble(),
            label: '${_danmakuTimeOffsetSeconds.toStringAsFixed(1)}s',
            onChanged: (v) {
              setState(() => _danmakuTimeOffsetSeconds = v);
              _syncDanmakuCursor(_lastPosition);
            },
          ),
          trailing: TextButton(
            onPressed: () {
              setState(() => _danmakuTimeOffsetSeconds = 0.0);
              _syncDanmakuCursor(_lastPosition);
            },
            child: const Text('重置'),
          ),
        ),
        ListTile(
          contentPadding: EdgeInsets.zero,
          title: const Text('滚动弹幕最大行数'),
          subtitle: Slider(
            min: 10,
            max: 200,
            divisions: 190,
            value: _danmakuMaxLines.clamp(10, 200).toDouble(),
            label: '$_danmakuMaxLines',
            onChanged: (v) => setState(() => _danmakuMaxLines = v.round()),
            onChangeEnd: (v) {
              // ignore: unawaited_futures
              appState.setDanmakuMaxLines(v.round());
            },
          ),
        ),
        ListTile(
          contentPadding: EdgeInsets.zero,
          title: const Text('顶部弹幕最大行数'),
          subtitle: Slider(
            min: 10,
            max: 200,
            divisions: 190,
            value: _danmakuTopMaxLines.clamp(10, 200).toDouble(),
            label: '$_danmakuTopMaxLines',
            onChanged: (v) => setState(() => _danmakuTopMaxLines = v.round()),
            onChangeEnd: (v) {
              // ignore: unawaited_futures
              appState.setDanmakuTopMaxLines(v.round());
            },
          ),
        ),
        ListTile(
          contentPadding: EdgeInsets.zero,
          title: const Text('底部弹幕最大行数'),
          subtitle: Slider(
            min: 10,
            max: 200,
            divisions: 190,
            value: _danmakuBottomMaxLines.clamp(10, 200).toDouble(),
            label: '$_danmakuBottomMaxLines',
            onChanged: (v) =>
                setState(() => _danmakuBottomMaxLines = v.round()),
            onChangeEnd: (v) {
              // ignore: unawaited_futures
              appState.setDanmakuBottomMaxLines(v.round());
            },
          ),
        ),
        ListTile(
          contentPadding: EdgeInsets.zero,
          title: const Text('弹幕大小缩放'),
          subtitle: Slider(
            min: 0.1,
            max: 3.0,
            divisions: 29,
            value: _danmakuScale.clamp(0.1, 3.0).toDouble(),
            label: _danmakuScale.toStringAsFixed(2),
            onChanged: (v) => setState(() => _danmakuScale = v),
            onChangeEnd: (v) {
              // ignore: unawaited_futures
              appState.setDanmakuScale(v);
            },
          ),
        ),
        ListTile(
          contentPadding: EdgeInsets.zero,
          title: const Text('弹幕透明度'),
          subtitle: Slider(
            min: 0,
            max: 1.0,
            divisions: 100,
            value: _danmakuOpacity.clamp(0.0, 1.0).toDouble(),
            label: '${(_danmakuOpacity * 100).round()}%',
            onChanged: (v) => setState(() => _danmakuOpacity = v),
            onChangeEnd: (v) {
              // ignore: unawaited_futures
              appState.setDanmakuOpacity(v);
            },
          ),
        ),
        ListTile(
          contentPadding: EdgeInsets.zero,
          title: const Text('弹幕滚动速度'),
          subtitle: Slider(
            min: 0.1,
            max: 3.0,
            divisions: 29,
            value: _danmakuSpeed.clamp(0.1, 3.0).toDouble(),
            label: _danmakuSpeed.toStringAsFixed(2),
            onChanged: (v) => setState(() => _danmakuSpeed = v),
            onChangeEnd: (v) {
              // ignore: unawaited_futures
              appState.setDanmakuSpeed(v);
            },
          ),
        ),
        const Divider(height: 18),
        Text(
          '杂项',
          style: Theme.of(context).textTheme.labelLarge?.copyWith(
                fontWeight: FontWeight.w600,
              ),
        ),
        SwitchListTile(
          contentPadding: EdgeInsets.zero,
          title: const Text('设置为粗体'),
          value: _danmakuBold,
          onChanged: (v) {
            setState(() => _danmakuBold = v);
            // ignore: unawaited_futures
            appState.setDanmakuBold(v);
          },
        ),
        SwitchListTile(
          contentPadding: EdgeInsets.zero,
          title: const Text('合并重复弹幕'),
          value: appState.danmakuMergeDuplicates,
          onChanged: (v) {
            // ignore: unawaited_futures
            appState.setDanmakuMergeDuplicates(v);
            setState(() {});
          },
        ),
        SwitchListTile(
          contentPadding: EdgeInsets.zero,
          title: const Text('防止弹幕重叠'),
          value: _danmakuPreventOverlap,
          onChanged: (v) {
            setState(() => _danmakuPreventOverlap = v);
            // ignore: unawaited_futures
            appState.setDanmakuPreventOverlap(v);
          },
        ),
      ],
    );
  }

  Widget _buildDesktopEpisodePanel(
    BuildContext context, {
    required bool isDark,
  }) {
    final seasons = _episodeSeasons;
    if (_episodePickerLoading) {
      return const Center(child: CircularProgressIndicator());
    }
    if (_episodePickerError != null) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(_episodePickerError!, textAlign: TextAlign.center),
              const SizedBox(height: 10),
              OutlinedButton.icon(
                onPressed: _ensureEpisodePickerLoaded,
                icon: const Icon(Icons.refresh),
                label: const Text('重试'),
              ),
            ],
          ),
        ),
      );
    }
    if (seasons.isEmpty) {
      return const Center(child: Text('暂无可选剧集'));
    }

    final selectedSeasonId = (_episodeSelectedSeasonId != null &&
            seasons.any((s) => s.id == _episodeSelectedSeasonId))
        ? _episodeSelectedSeasonId!
        : seasons.first.id;
    final selectedSeason = seasons.firstWhere((s) => s.id == selectedSeasonId);

    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 10, 12, 12),
      child: Column(
        children: [
          Row(
            children: [
              Expanded(
                child: DropdownButtonFormField<String>(
                  initialValue: selectedSeason.id,
                  decoration: const InputDecoration(
                    isDense: true,
                    labelText: '季度',
                    border: OutlineInputBorder(),
                  ),
                  items: [
                    for (final entry in seasons.asMap().entries)
                      DropdownMenuItem(
                        value: entry.value.id,
                        child: Text(_seasonLabel(entry.value, entry.key)),
                      ),
                  ],
                  onChanged: (v) {
                    if (v == null || v.isEmpty) return;
                    if (v == _episodeSelectedSeasonId) return;
                    setState(() => _episodeSelectedSeasonId = v);
                  },
                ),
              ),
              const SizedBox(width: 8),
              ToggleButtons(
                isSelected: [_desktopEpisodeGridMode, !_desktopEpisodeGridMode],
                constraints: const BoxConstraints(minWidth: 40, minHeight: 36),
                borderRadius: BorderRadius.circular(10),
                onPressed: (index) {
                  setState(() => _desktopEpisodeGridMode = index == 0);
                },
                children: const [
                  Tooltip(message: '正方形模式', child: Icon(Icons.grid_view)),
                  Tooltip(message: '条形模式', child: Icon(Icons.view_agenda)),
                ],
              ),
              const SizedBox(width: 4),
              IconButton(
                tooltip: '关闭',
                onPressed: () {
                  setState(() => _desktopSidePanel = _DesktopSidePanel.none);
                  _scheduleControlsHide();
                },
                icon: const Icon(Icons.close),
              ),
            ],
          ),
          const SizedBox(height: 10),
          Expanded(
            child: FutureBuilder<List<MediaItem>>(
              future: _episodesFutureForSeasonId(selectedSeason.id),
              builder: (ctx, snapshot) {
                if (snapshot.connectionState != ConnectionState.done) {
                  return const Center(child: CircularProgressIndicator());
                }
                if (snapshot.hasError) {
                  return Center(
                    child: Padding(
                      padding: const EdgeInsets.all(16),
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Text('加载失败：${snapshot.error}',
                              textAlign: TextAlign.center),
                          const SizedBox(height: 10),
                          OutlinedButton.icon(
                            onPressed: () {
                              setState(() {
                                _episodeEpisodesCache.remove(selectedSeason.id);
                                _episodeEpisodesFutureCache
                                    .remove(selectedSeason.id);
                              });
                            },
                            icon: const Icon(Icons.refresh),
                            label: const Text('重试'),
                          ),
                        ],
                      ),
                    ),
                  );
                }
                final eps = snapshot.data ?? const <MediaItem>[];
                if (eps.isEmpty) {
                  return const Center(child: Text('暂无剧集'));
                }
                return _desktopEpisodeGridMode
                    ? _buildDesktopEpisodeGrid(
                        context, eps, selectedSeason, isDark)
                    : _buildDesktopEpisodeList(
                        context, eps, selectedSeason, isDark);
              },
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildDesktopEpisodeGrid(
    BuildContext context,
    List<MediaItem> episodes,
    MediaItem season,
    bool isDark,
  ) {
    final columns = MediaQuery.sizeOf(context).width >= 1400 ? 5 : 4;
    return GridView.builder(
      gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
        crossAxisCount: columns,
        mainAxisSpacing: 8,
        crossAxisSpacing: 8,
        childAspectRatio: 1.0,
      ),
      itemCount: episodes.length,
      itemBuilder: (ctx, index) {
        final e = episodes[index];
        final mark = _desktopEpisodeMark(
          e,
          fallbackSeason: season.seasonNumber ?? 1,
          fallbackEpisode: index + 1,
        );
        final isCurrent = e.id == widget.itemId;
        return InkWell(
          borderRadius: BorderRadius.circular(12),
          onTap: () => _playEpisodeFromPicker(e),
          child: Ink(
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(12),
              color: isDark
                  ? Colors.white.withValues(alpha: 0.08)
                  : Colors.black.withValues(alpha: 0.04),
              border: Border.all(
                color: isCurrent
                    ? Theme.of(context).colorScheme.primary
                    : (isDark
                        ? Colors.white.withValues(alpha: 0.14)
                        : Colors.black.withValues(alpha: 0.10)),
              ),
            ),
            child: Center(
              child: Text(
                mark,
                style: Theme.of(context).textTheme.labelLarge?.copyWith(
                      fontWeight: FontWeight.w700,
                    ),
              ),
            ),
          ),
        );
      },
    );
  }

  Widget _buildDesktopEpisodeList(
    BuildContext context,
    List<MediaItem> episodes,
    MediaItem season,
    bool isDark,
  ) {
    return ListView.separated(
      itemCount: episodes.length,
      separatorBuilder: (_, __) => const SizedBox(height: 8),
      itemBuilder: (ctx, index) {
        final e = episodes[index];
        final isCurrent = e.id == widget.itemId;
        final epNo = e.episodeNumber ?? (index + 1);
        final mark = _desktopEpisodeMark(
          e,
          fallbackSeason: season.seasonNumber ?? 1,
          fallbackEpisode: epNo,
        );
        final title = e.name.trim().isNotEmpty ? e.name.trim() : mark;
        final access = _serverAccess;
        final img = access?.adapter.imageUrl(
          access.auth,
          itemId: e.hasImage ? e.id : season.id,
          maxWidth: 520,
        );
        return InkWell(
          borderRadius: BorderRadius.circular(12),
          onTap: () => _playEpisodeFromPicker(e),
          child: Ink(
            padding: const EdgeInsets.all(8),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(12),
              color: isDark
                  ? Colors.white.withValues(alpha: 0.08)
                  : Colors.black.withValues(alpha: 0.04),
              border: Border.all(
                color: isCurrent
                    ? Theme.of(context).colorScheme.primary
                    : (isDark
                        ? Colors.white.withValues(alpha: 0.14)
                        : Colors.black.withValues(alpha: 0.10)),
              ),
            ),
            child: Row(
              children: [
                ClipRRect(
                  borderRadius: BorderRadius.circular(8),
                  child: SizedBox(
                    width: 92,
                    height: 56,
                    child: img == null
                        ? const ColoredBox(
                            color: Color(0x22000000),
                            child: Icon(
                              Icons.image_outlined,
                              color: Colors.white54,
                            ),
                          )
                        : Image.network(
                            img,
                            fit: BoxFit.cover,
                            errorBuilder: (_, __, ___) {
                              return const ColoredBox(
                                color: Color(0x22000000),
                                child: Icon(
                                  Icons.image_not_supported_outlined,
                                  color: Colors.white54,
                                ),
                              );
                            },
                          ),
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(
                        mark,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style:
                            Theme.of(context).textTheme.labelMedium?.copyWith(
                                  fontWeight: FontWeight.w700,
                                ),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        title,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: Theme.of(context).textTheme.bodySmall,
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  Widget _buildDesktopPlaybackControls(
    BuildContext context, {
    required bool isDark,
    required bool controlsEnabled,
    required Duration duration,
    required bool isPlaying,
  }) {
    final sliderMaxMs = math.max(duration.inMilliseconds, 1);
    final sliderValueMs = _lastPosition.inMilliseconds.clamp(0, sliderMaxMs);
    final sliderEnabled = controlsEnabled && duration > Duration.zero;
    final chipBg = isDark
        ? Colors.black.withValues(alpha: 0.58)
        : Colors.white.withValues(alpha: 0.92);
    final chipBorder = isDark
        ? Colors.white.withValues(alpha: 0.18)
        : Colors.black.withValues(alpha: 0.12);
    final iconColor = isDark ? Colors.white : Colors.black87;
    final secondaryIconColor = isDark ? Colors.white70 : Colors.black54;
    final panelBorder = isDark
        ? Colors.white.withValues(alpha: 0.08)
        : Colors.black.withValues(alpha: 0.04);
    final timelineActive = isDark ? Colors.white : Colors.black87;
    final timelineBuffered = isDark
        ? Colors.white.withValues(alpha: 0.88)
        : Colors.black.withValues(alpha: 0.48);
    final timelineInactive = isDark
        ? Colors.white.withValues(alpha: 0.24)
        : Colors.black.withValues(alpha: 0.18);
    final bufferedMs = math
        .max(_lastBuffer.inMilliseconds, sliderValueMs)
        .clamp(0, sliderMaxMs);
    final rate =
        _playerService.isInitialized ? _playerService.player.state.rate : 1.0;
    final speedHint = '${rate.toStringAsFixed(2)}x';

    return _buildDesktopGlassPanel(
      context: context,
      blurSigma: 0,
      color: Colors.transparent,
      borderRadius: BorderRadius.circular(24),
      borderColor: Colors.transparent,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(14, 8, 14, 10),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 12),
              decoration: BoxDecoration(
                color: Colors.transparent,
                borderRadius: BorderRadius.circular(16),
                border: Border.all(color: Colors.transparent),
              ),
              child: Row(
                children: [
                  Text(
                    _fmtClock(_lastPosition),
                    style: Theme.of(context).textTheme.labelMedium?.copyWith(
                          color: secondaryIconColor,
                        ),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: SliderTheme(
                      data: SliderTheme.of(context).copyWith(
                        trackHeight: 5,
                        activeTrackColor: timelineActive,
                        secondaryActiveTrackColor: timelineBuffered,
                        inactiveTrackColor: timelineInactive,
                        thumbShape:
                            const RoundSliderThumbShape(enabledThumbRadius: 5),
                        overlayShape:
                            const RoundSliderOverlayShape(overlayRadius: 12),
                      ),
                      child: Slider(
                        min: 0,
                        max: sliderMaxMs.toDouble(),
                        value: sliderValueMs.toDouble(),
                        secondaryTrackValue: bufferedMs.toDouble(),
                        onChangeStart:
                            sliderEnabled ? (_) => _onScrubStart() : null,
                        onChanged: sliderEnabled
                            ? (value) => setState(
                                  () => _lastPosition =
                                      Duration(milliseconds: value.round()),
                                )
                            : null,
                        onChangeEnd: sliderEnabled
                            ? (value) async {
                                final target =
                                    Duration(milliseconds: value.round());
                                await _playerService.seek(
                                  target,
                                  flushBuffer: _flushBufferOnSeek,
                                );
                                _lastPosition = target;
                                _syncDanmakuCursor(target);
                                _maybeReportPlaybackProgress(target,
                                    force: true);
                                _onScrubEnd();
                                if (mounted) setState(() {});
                              }
                            : null,
                      ),
                    ),
                  ),
                  const SizedBox(width: 10),
                  Text(
                    _fmtClock(duration),
                    style: Theme.of(context).textTheme.labelMedium?.copyWith(
                          color: secondaryIconColor,
                        ),
                  ),
                ],
              ),
            ),
            if (_desktopSpeedPanelVisible) ...[
              const SizedBox(height: 8),
              Align(
                alignment: Alignment.centerRight,
                child: Container(
                  width: 290,
                  padding: const EdgeInsets.fromLTRB(12, 10, 12, 8),
                  decoration: BoxDecoration(
                    color: isDark
                        ? Colors.black.withValues(alpha: 0.42)
                        : Colors.black.withValues(alpha: 0.04),
                    borderRadius: BorderRadius.circular(12),
                    border: Border.all(color: panelBorder),
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          Text(
                            '倍速',
                            style: Theme.of(context)
                                .textTheme
                                .labelMedium
                                ?.copyWith(
                                  color: secondaryIconColor,
                                  fontWeight: FontWeight.w600,
                                ),
                          ),
                          const Spacer(),
                          Text(
                            speedHint,
                            style: Theme.of(context)
                                .textTheme
                                .labelMedium
                                ?.copyWith(
                                  color: iconColor,
                                  fontWeight: FontWeight.w700,
                                ),
                          ),
                        ],
                      ),
                      Slider(
                        min: 0.1,
                        max: 5.0,
                        divisions: 49,
                        value: rate.clamp(0.1, 5.0).toDouble(),
                        onChanged: !controlsEnabled
                            ? null
                            : (value) {
                                // ignore: unawaited_futures
                                _playerService.player.setRate(value);
                                setState(() {});
                              },
                      ),
                      DefaultTextStyle(
                        style: Theme.of(context).textTheme.labelSmall!.copyWith(
                              color: secondaryIconColor,
                            ),
                        child: const Row(
                          children: [
                            Text('0.1x'),
                            Spacer(),
                            Text('0.5x'),
                            Spacer(),
                            Text('1x'),
                            Spacer(),
                            Text('2x'),
                            Spacer(),
                            Text('3x'),
                            Spacer(),
                            Text('5x'),
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ],
            const SizedBox(height: 8),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
              decoration: BoxDecoration(
                color: Colors.transparent,
                borderRadius: BorderRadius.circular(16),
                border: Border.all(color: Colors.transparent),
              ),
              child: Row(
                children: [
                  const SizedBox(width: 156),
                  Expanded(
                    child: Row(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        _desktopControlButton(
                          context,
                          isDark: isDark,
                          icon: Icons.fast_rewind_rounded,
                          tooltip: '快退',
                          onTap: controlsEnabled
                              ? () async {
                                  _showControls();
                                  await _seekRelative(
                                    Duration(seconds: -_seekBackSeconds),
                                    showOverlay: false,
                                  );
                                }
                              : null,
                        ),
                        const SizedBox(width: 8),
                        _desktopControlButton(
                          context,
                          isDark: isDark,
                          icon: isPlaying
                              ? Icons.pause_rounded
                              : Icons.play_arrow_rounded,
                          tooltip: isPlaying ? '暂停' : '播放',
                          emphasized: true,
                          onTap: controlsEnabled
                              ? () => _togglePlayPause(showOverlay: false)
                              : null,
                        ),
                        const SizedBox(width: 8),
                        _desktopControlButton(
                          context,
                          isDark: isDark,
                          icon: Icons.fast_forward_rounded,
                          tooltip: '快进',
                          onTap: controlsEnabled
                              ? () async {
                                  _showControls();
                                  await _seekRelative(
                                    Duration(seconds: _seekForwardSeconds),
                                    showOverlay: false,
                                  );
                                }
                              : null,
                        ),
                      ],
                    ),
                  ),
                  SizedBox(
                    width: 236,
                    child: Row(
                      mainAxisAlignment: MainAxisAlignment.end,
                      children: [
                        OutlinedButton(
                          style: OutlinedButton.styleFrom(
                            visualDensity: VisualDensity.compact,
                            backgroundColor: chipBg,
                            foregroundColor: iconColor,
                            side: BorderSide(color: chipBorder),
                            shape: const StadiumBorder(),
                            padding: const EdgeInsets.symmetric(
                              horizontal: 14,
                              vertical: 8,
                            ),
                          ),
                          onPressed: !controlsEnabled
                              ? null
                              : () {
                                  final next = !_desktopSpeedPanelVisible;
                                  setState(() {
                                    _desktopSidePanel = _DesktopSidePanel.none;
                                    _desktopSpeedPanelVisible = next;
                                  });
                                  if (next) {
                                    _showControls(scheduleHide: false);
                                  } else {
                                    _scheduleControlsHide();
                                  }
                                },
                          child: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              const Icon(Icons.speed_outlined, size: 18),
                              const SizedBox(width: 6),
                              Text(speedHint),
                            ],
                          ),
                        ),
                        const SizedBox(width: 4),
                        IconButton(
                          tooltip: _desktopFullscreen
                              ? 'Exit fullscreen'
                              : 'Fullscreen',
                          style: IconButton.styleFrom(
                            backgroundColor: chipBg,
                            foregroundColor: iconColor,
                            side: BorderSide(color: chipBorder),
                          ),
                          onPressed:
                              controlsEnabled ? _toggleDesktopFullscreen : null,
                          icon: Icon(
                            _desktopFullscreen
                                ? Icons.fullscreen_exit
                                : Icons.fullscreen,
                          ),
                        ),
                        const SizedBox(width: 4),
                        IconButton(
                          tooltip: '选集',
                          style: IconButton.styleFrom(
                            backgroundColor: chipBg,
                            foregroundColor: iconColor,
                            side: BorderSide(color: chipBorder),
                          ),
                          onPressed: controlsEnabled
                              ? () =>
                                  _toggleDesktopPanel(_DesktopSidePanel.episode)
                              : null,
                          icon: Icon(
                            _desktopSidePanel == _DesktopSidePanel.episode
                                ? Icons.close
                                : Icons.format_list_numbered,
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _desktopControlButton(
    BuildContext context, {
    required bool isDark,
    required IconData icon,
    required String tooltip,
    required VoidCallback? onTap,
    bool emphasized = false,
  }) {
    final size = emphasized ? 54.0 : 46.0;
    final bg = emphasized
        ? (isDark
            ? Colors.white.withValues(alpha: 0.2)
            : Colors.white.withValues(alpha: 0.96))
        : (isDark
            ? Colors.black.withValues(alpha: 0.35)
            : Colors.white.withValues(alpha: 0.92));
    final border = isDark
        ? Colors.white.withValues(alpha: emphasized ? 0.28 : 0.14)
        : Colors.black.withValues(alpha: emphasized ? 0.12 : 0.08);
    final iconColor = isDark ? Colors.white : Colors.black87;

    return Tooltip(
      message: tooltip,
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          borderRadius: BorderRadius.circular(16),
          onTap: onTap,
          child: Ink(
            width: size,
            height: size,
            decoration: BoxDecoration(
              color: bg,
              borderRadius: BorderRadius.circular(16),
              border: Border.all(color: border),
            ),
            child: Icon(icon, color: iconColor),
          ),
        ),
      ),
    );
  }

  Widget _buildDesktopGlassPanel({
    required BuildContext context,
    required Widget child,
    BorderRadius borderRadius = const BorderRadius.all(Radius.circular(20)),
    Color? color,
    Color? borderColor,
    double blurSigma = 16,
  }) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final resolvedColor =
        color ?? (isDark ? const Color(0xAA15171C) : const Color(0xEAF9FAFD));
    final resolvedBorder = borderColor ??
        (isDark
            ? Colors.white.withValues(alpha: 0.12)
            : Colors.black.withValues(alpha: 0.08));
    return ClipRRect(
      borderRadius: borderRadius,
      child: BackdropFilter(
        filter: ImageFilter.blur(sigmaX: blurSigma, sigmaY: blurSigma),
        child: DecoratedBox(
          decoration: BoxDecoration(
            color: resolvedColor,
            borderRadius: borderRadius,
            border: Border.all(color: resolvedBorder),
          ),
          child: child,
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

enum _DesktopSidePanel { none, line, audio, subtitle, danmaku, episode }

extension on _DesktopSidePanel {
  String get title {
    return switch (this) {
      _DesktopSidePanel.none => '',
      _DesktopSidePanel.line => '线路切换',
      _DesktopSidePanel.audio => '音轨选择',
      _DesktopSidePanel.subtitle => '字幕选择',
      _DesktopSidePanel.danmaku => '弹幕',
      _DesktopSidePanel.episode => '选集',
    };
  }
}
