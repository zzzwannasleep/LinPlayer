import 'dart:async';
import 'dart:io';
import 'dart:math' as math;
import 'dart:ui';

import 'package:crypto/crypto.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart' show kIsWeb, defaultTargetPlatform;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:lin_player_player/lin_player_player.dart';
import 'package:lin_player_prefs/lin_player_prefs.dart';
import 'package:lin_player_state/lin_player_state.dart';
import 'package:lin_player_ui/lin_player_ui.dart';
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';

import 'services/app_route_observer.dart';
import 'services/built_in_proxy/built_in_proxy_service.dart';
import 'widgets/danmaku_manual_search_dialog.dart';

class PlayerScreen extends StatefulWidget {
  const PlayerScreen({
    super.key,
    this.appState,
    this.startFullScreen = false,
  });

  final AppState? appState;
  final bool startFullScreen;

  @override
  State<PlayerScreen> createState() => _PlayerScreenState();
}

class _PlayerScreenState extends State<PlayerScreen>
    with WidgetsBindingObserver, RouteAware {
  final PlayerService _playerService = getPlayerService();
  MediaKitThumbnailGenerator? _thumbnailer;
  final List<PlatformFile> _playlist = [];
  int _currentlyPlayingIndex = -1;
  StreamSubscription<Duration>? _posSub;
  StreamSubscription<String>? _errorSub;
  StreamSubscription<VideoParams>? _videoParamsSub;
  StreamSubscription<bool>? _playingSub;
  StreamSubscription<bool>? _bufferingSub;
  StreamSubscription<Duration>? _bufferSub;
  VideoParams? _lastVideoParams;
  _OrientationMode _orientationMode = _OrientationMode.auto;
  String? _lastOrientationKey;
  bool _isTvDevice = false;
  bool _remoteEnabled = false;
  final FocusNode _tvSurfaceFocusNode =
      FocusNode(debugLabel: 'player_tv_surface');
  final FocusNode _tvPlayPauseFocusNode =
      FocusNode(debugLabel: 'player_tv_play_pause');
  Duration _position = Duration.zero;
  Duration _duration = Duration.zero;
  String? _playError;
  late bool _hwdecOn;
  late Anime4kPreset _anime4kPreset;
  Tracks _tracks = const Tracks();
  PageRoute<dynamic>? _route;
  DateTime? _lastPositionUiUpdate;
  bool _appliedAudioPref = false;
  bool _appliedSubtitlePref = false;

  // Subtitle options (MPV + media_kit_video SubtitleView).
  double _subtitleDelaySeconds = 0.0;
  double _subtitleFontSize = 32.0;
  int _subtitlePositionStep = 5; // 0..20, maps to padding-bottom in 5px steps.
  bool _subtitleBold = false;
  bool _subtitleAssOverrideForce = false;

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
  bool _buffering = false;
  bool _danmakuPaused = false;
  Duration _lastBuffer = Duration.zero;
  DateTime? _lastBufferAt;
  Duration _lastBufferSample = Duration.zero;
  double? _bufferSpeedX;
  bool _isNetworkPlayback = false;
  Timer? _netSpeedTimer;
  bool _netSpeedPollInFlight = false;
  double? _netSpeedBytesPerSecond;
  int? _lastTotalRxBytes;
  DateTime? _lastTotalRxAt;
  bool _exitInProgress = false;
  bool _allowRoutePop = false;

  static const Duration _controlsAutoHideDelay = Duration(seconds: 3);
  Timer? _controlsHideTimer;
  bool _controlsVisible = true;
  bool _isScrubbing = false;
  _DesktopSidePanel _desktopSidePanel = _DesktopSidePanel.none;
  bool _desktopEpisodeGridMode = false;
  bool _desktopSpeedPanelVisible = false;
  bool _desktopFullscreen = false;
  int? _desktopSelectedSeason;
  bool _desktopDanmakuOnlineLoading = false;
  bool _desktopDanmakuManualLoading = false;
  double _danmakuTimeOffsetSeconds = 0.0;

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

  late final bool _fullScreen = widget.startFullScreen;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    final appState = widget.appState;
    _hwdecOn = appState?.preferHardwareDecode ?? true;
    _anime4kPreset = appState?.anime4kPreset ?? Anime4kPreset.off;
    _danmakuEnabled = appState?.danmakuEnabled ?? true;
    _danmakuOpacity = appState?.danmakuOpacity ?? 1.0;
    _danmakuScale = appState?.danmakuScale ?? 1.0;
    _danmakuSpeed = appState?.danmakuSpeed ?? 1.0;
    _danmakuBold = appState?.danmakuBold ?? true;
    _danmakuMaxLines = appState?.danmakuMaxLines ?? 30;
    _danmakuTopMaxLines = appState?.danmakuTopMaxLines ?? 30;
    _danmakuBottomMaxLines = appState?.danmakuBottomMaxLines ?? 30;
    _danmakuPreventOverlap = appState?.danmakuPreventOverlap ?? true;
    _danmakuShowHeatmap = appState?.danmakuShowHeatmap ?? true;

    final handoff = appState?.takeLocalPlaybackHandoff();
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

  @override
  void dispose() {
    if (_route != null) {
      appRouteObserver.unsubscribe(this);
      _route = null;
    }
    WidgetsBinding.instance.removeObserver(this);
    _controlsHideTimer?.cancel();
    _controlsHideTimer = null;
    _gestureOverlayTimer?.cancel();
    _gestureOverlayTimer = null;
    _tvOkLongPressTimer?.cancel();
    _tvOkLongPressTimer = null;
    _netSpeedTimer?.cancel();
    _netSpeedTimer = null;
    _posSub?.cancel();
    _errorSub?.cancel();
    _videoParamsSub?.cancel();
    _playingSub?.cancel();
    _bufferingSub?.cancel();
    _bufferSub?.cancel();
    // ignore: unawaited_futures
    _exitOrientationLock();
    if (_fullScreen) {
      // ignore: unawaited_futures
      _exitImmersiveMode(resetOrientations: true);
    }
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

  void _scheduleNetSpeedTick() {
    _netSpeedTimer?.cancel();
    _netSpeedTimer = null;

    if (!_isNetworkPlayback) return;
    if (!_playerService.isInitialized || _playerService.isExternalPlayback) {
      _lastTotalRxBytes = null;
      _lastTotalRxAt = null;
      if (_netSpeedBytesPerSecond != null && mounted) {
        setState(() => _netSpeedBytesPerSecond = null);
      }
      return;
    }

    final refreshSeconds = (widget.appState?.bufferSpeedRefreshSeconds ?? 0.5)
        .clamp(0.2, 3.0)
        .toDouble();
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

  Future<void> _requestExitThenPop() async {
    if (_exitInProgress) return;
    _exitInProgress = true;

    _controlsHideTimer?.cancel();
    _controlsHideTimer = null;
    _gestureOverlayTimer?.cancel();
    _gestureOverlayTimer = null;
    _tvOkLongPressTimer?.cancel();
    _tvOkLongPressTimer = null;

    final cancels = <Future<void>>[];
    final posSub = _posSub;
    _posSub = null;
    if (posSub != null) cancels.add(posSub.cancel().catchError((_) {}));
    final errorSub = _errorSub;
    _errorSub = null;
    if (errorSub != null) cancels.add(errorSub.cancel().catchError((_) {}));
    final videoParamsSub = _videoParamsSub;
    _videoParamsSub = null;
    if (videoParamsSub != null) {
      cancels.add(videoParamsSub.cancel().catchError((_) {}));
    }
    final playingSub = _playingSub;
    _playingSub = null;
    if (playingSub != null) cancels.add(playingSub.cancel().catchError((_) {}));
    final bufferingSub = _bufferingSub;
    _bufferingSub = null;
    if (bufferingSub != null) {
      cancels.add(bufferingSub.cancel().catchError((_) {}));
    }
    final bufferSub = _bufferSub;
    _bufferSub = null;
    if (bufferSub != null) cancels.add(bufferSub.cancel().catchError((_) {}));
    if (cancels.isNotEmpty) await Future.wait(cancels);

    await _exitOrientationLock();
    if (_fullScreen) {
      await _exitImmersiveMode(resetOrientations: true);
    }

    final thumb = _thumbnailer;
    _thumbnailer = null;

    final disposeFuture = _playerService.dispose();
    if (mounted) {
      setState(() {
        _controlsVisible = false;
        _gestureOverlayIcon = null;
        _gestureOverlayText = null;
      });
    }
    try {
      await disposeFuture;
    } catch (_) {}

    if (thumb != null) {
      try {
        await thumb.dispose();
      } catch (_) {}
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

    final appState = widget.appState;
    if (appState == null) return;
    if (appState.returnHomeBehavior != ReturnHomeBehavior.pause) return;

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
    setState(() {
      _controlsVisible = false;
      _desktopSidePanel = _DesktopSidePanel.none;
      _desktopSpeedPanelVisible = false;
    });
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
    if (_desktopSidePanel != _DesktopSidePanel.none ||
        _desktopSpeedPanelVisible) {
      return;
    }
    if (!_controlsVisible || _isScrubbing) return;
    _controlsHideTimer = Timer(_controlsAutoHideDelay, () {
      if (!mounted || _isScrubbing || _remoteEnabled) return;
      setState(() {
        _controlsVisible = false;
        _desktopSidePanel = _DesktopSidePanel.none;
        _desktopSpeedPanelVisible = false;
      });
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

  static String _fmtClock(Duration d) {
    String two(int v) => v.toString().padLeft(2, '0');
    final h = d.inHours;
    final m = d.inMinutes.remainder(60);
    final s = d.inSeconds.remainder(60);
    return h > 0 ? '${two(h)}:${two(m)}:${two(s)}' : '${two(m)}:${two(s)}';
  }

  static String _fmtRate(double rate) {
    final v = rate.clamp(0.1, 5.0).toDouble();
    final asInt = v.roundToDouble();
    if ((v - asInt).abs() < 0.001) return asInt.toStringAsFixed(0);
    if (((v * 10) - (v * 10).roundToDouble()).abs() < 0.001) {
      return v.toStringAsFixed(1);
    }
    return v.toStringAsFixed(2);
  }

  static Duration _safeSeekTarget(Duration target, Duration duration) {
    if (target < Duration.zero) return Duration.zero;
    if (duration > Duration.zero && target > duration) return duration;
    return target;
  }

  bool get _gesturesEnabled =>
      _playerService.isInitialized && _playError == null;

  bool get _gestureSeekEnabled => widget.appState?.gestureSeek ?? true;
  bool get _gestureBrightnessEnabled =>
      widget.appState?.gestureBrightness ?? true;
  bool get _gestureVolumeEnabled => widget.appState?.gestureVolume ?? true;
  bool get _gestureLongPressEnabled =>
      widget.appState?.gestureLongPressSpeed ?? true;
  bool get _longPressSlideEnabled =>
      widget.appState?.longPressSlideSpeed ?? true;

  double get _longPressMultiplier =>
      widget.appState?.longPressSpeedMultiplier ?? 2.0;

  int get _seekBackSeconds => widget.appState?.seekBackwardSeconds ?? 10;
  int get _seekForwardSeconds => widget.appState?.seekForwardSeconds ?? 20;
  bool get _flushBufferOnSeek => widget.appState?.flushBufferOnSeek ?? true;

  DoubleTapAction get _doubleTapLeft =>
      widget.appState?.doubleTapLeft ?? DoubleTapAction.seekBackward;
  DoubleTapAction get _doubleTapCenter =>
      widget.appState?.doubleTapCenter ?? DoubleTapAction.playPause;
  DoubleTapAction get _doubleTapRight =>
      widget.appState?.doubleTapRight ?? DoubleTapAction.seekForward;

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
    final duration =
        _duration > Duration.zero ? _duration : _playerService.duration;
    final current = _position;
    var target = current + delta;
    if (target < Duration.zero) target = Duration.zero;
    if (duration > Duration.zero && target > duration) target = duration;

    await _playerService.seek(target, flushBuffer: _flushBufferOnSeek);
    _position = target;
    _syncDanmakuCursor(target);
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
      0 => _doubleTapLeft,
      1 => _doubleTapCenter,
      _ => _doubleTapRight,
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
    if (!_gestureSeekEnabled) return;
    _gestureMode = _GestureMode.seek;
    _gestureStartPos = details.localPosition;
    _seekGestureStartPosition = _position;
    _seekGesturePreviewPosition = _position;
    _showControls(scheduleHide: false);
    _setGestureOverlay(icon: Icons.swap_horiz, text: _fmtClock(_position));
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
      _position = target;
      _syncDanmakuCursor(target);
      if (mounted) setState(() {});
    }

    _hideGestureOverlay();
    _scheduleControlsHide();
  }

  void _onSideDragStart(DragStartDetails details, {required double width}) {
    if (!_gesturesEnabled) return;
    _gestureStartPos = details.localPosition;
    final isLeft = width <= 0 ? true : details.localPosition.dx < width / 2;
    if (isLeft && _gestureBrightnessEnabled) {
      _gestureMode = _GestureMode.brightness;
      _gestureStartBrightness = _screenBrightness;
      _setGestureOverlay(
        icon: Icons.brightness_6_outlined,
        text: '亮度 ${(100 * _screenBrightness).round()}%',
      );
      return;
    }
    if (!isLeft && _gestureVolumeEnabled) {
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
    if (!_gestureLongPressEnabled) return;

    _gestureMode = _GestureMode.speed;
    _longPressStartPos = details.localPosition;
    final player = _playerService.player;
    _longPressBaseRate = player.state.rate;
    final targetRate = (_longPressBaseRate! * _longPressMultiplier)
        .clamp(0.25, 5.0)
        .toDouble();
    // ignore: unawaited_futures
    player.setRate(targetRate);
    _setGestureOverlay(
      icon: Icons.speed,
      text: '倍速 ×${(targetRate / _longPressBaseRate!).toStringAsFixed(2)}',
    );
  }

  void _onLongPressMoveUpdate(
    LongPressMoveUpdateDetails details, {
    required double height,
  }) {
    if (_gestureMode != _GestureMode.speed) return;
    if (!_gesturesEnabled) return;
    if (!_longPressSlideEnabled) return;
    if (_longPressBaseRate == null || _longPressStartPos == null) return;
    if (height <= 0) return;

    final dy = details.localPosition.dy - _longPressStartPos!.dy;
    final delta = (-dy / height) * 2.0;
    final multiplier =
        (_longPressMultiplier + delta).clamp(0.25, 5.0).toDouble();
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
        .map(
          (f) => LocalPlaybackItem(
            name: f.name,
            path: f.path!.trim(),
            size: f.size,
          ),
        )
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

  bool _isTv(BuildContext context) => DeviceType.isTv;

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
    // ignore: unawaited_futures
    _playerService.dispose();
  }

  Future<void> _playFile(
    PlatformFile file,
    int index, {
    Duration? startPosition,
    bool? autoPlay,
  }) async {
    final rawPath = (file.path ?? '').trim();
    final uri = Uri.tryParse(rawPath);
    final isHttpUrl = uri != null &&
        (uri.scheme == 'http' || uri.scheme == 'https') &&
        uri.host.isNotEmpty;
    final isNetwork = kIsWeb || isHttpUrl;

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
      _danmakuMaxLines = appState?.danmakuMaxLines ?? 30;
      _danmakuTopMaxLines = appState?.danmakuTopMaxLines ?? 30;
      _danmakuBottomMaxLines = appState?.danmakuBottomMaxLines ?? 30;
      _danmakuPreventOverlap = appState?.danmakuPreventOverlap ?? true;
      _danmakuShowHeatmap = appState?.danmakuShowHeatmap ?? true;
      _danmakuHeatmap = const [];
      _controlsVisible = true;
      _isScrubbing = false;
      _isNetworkPlayback = isNetwork;
      _netSpeedBytesPerSecond = null;
      _desktopSidePanel = _DesktopSidePanel.none;
      _desktopSpeedPanelVisible = false;
      _desktopDanmakuOnlineLoading = false;
      _desktopDanmakuManualLoading = false;
      _desktopSelectedSeason = _desktopEpisodeInfoForFile(file.name).season;
    });
    _controlsHideTimer?.cancel();
    _controlsHideTimer = null;
    _danmakuKey.currentState?.clear();
    final isTv = _isTv(context);
    _isTvDevice = isTv;
    if (_fullScreen) {
      // ignore: unawaited_futures
      _enterImmersiveMode();
    }
    await _errorSub?.cancel();
    _errorSub = null;
    await _videoParamsSub?.cancel();
    _videoParamsSub = null;
    await _playingSub?.cancel();
    _playingSub = null;
    await _bufferingSub?.cancel();
    _bufferingSub = null;
    await _bufferSub?.cancel();
    _bufferSub = null;
    _lastBuffer = Duration.zero;
    _lastBufferAt = null;
    _lastBufferSample = Duration.zero;
    _bufferSpeedX = null;
    _netSpeedTimer?.cancel();
    _netSpeedTimer = null;
    _netSpeedPollInFlight = false;
    _netSpeedBytesPerSecond = null;
    try {
      await _playerService.dispose();
    } catch (_) {}
    try {
      await _thumbnailer?.dispose();
    } catch (_) {}
    _thumbnailer = null;

    try {
      final builtInProxyEnabled =
          isTv && (widget.appState?.tvBuiltInProxyEnabled ?? false);
      final builtInProxy = BuiltInProxyService.instance;
      if (builtInProxyEnabled) {
        try {
          await builtInProxy.start();
        } catch (_) {}
      }

      final proxyReady = builtInProxyEnabled &&
          builtInProxy.status.state == BuiltInProxyState.running;

      final httpProxy = (proxyReady && isNetwork)
          ? (() {
              final uri = Uri.tryParse(rawPath);
              if (uri == null) return null;
              return BuiltInProxyService.proxyUrlForUri(uri);
            })()
          : null;

      await _playerService.initialize(
        isNetwork ? null : rawPath,
        networkUrl: isNetwork ? rawPath : null,
        isTv: isTv,
        hardwareDecode: _hwdecOn,
        mpvCacheSizeMb: widget.appState?.mpvCacheSizeMb ?? 500,
        bufferBackRatio: widget.appState?.playbackBufferBackRatio ?? 0.05,
        unlimitedStreamCache: widget.appState?.unlimitedStreamCache ?? false,
        networkStreamSizeBytes: (isNetwork && file.size > 0) ? file.size : null,
        externalMpvPath: widget.appState?.externalMpvPath,
        httpProxy: httpProxy,
      );
      if (!mounted) return;
      if (_playerService.isExternalPlayback) {
        setState(() => _playError =
            _playerService.externalPlaybackMessage ?? '已使用外部播放器播放');
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
        widget.appState?.setAnime4kPreset(Anime4kPreset.off);
      }

      await _applyMpvSubtitleOptions();
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
        _bufferSpeedX = null;
        _lastBufferAt = null;
        _lastBufferSample = _lastBuffer;
        _applyDanmakuPauseState(_buffering || !_playerService.isPlaying);
        setState(() {});
      });
      _bufferSub = _playerService.player.stream.buffer.listen((value) {
        _lastBuffer = value;

        final appState = widget.appState;
        final show = (appState?.showBufferSpeed ?? false);
        if (!show || !_buffering) return;

        final now = DateTime.now();
        final refreshSeconds = (appState?.bufferSpeedRefreshSeconds ?? 0.5)
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
      _playingSub = _playerService.player.stream.playing.listen((playing) {
        if (!mounted) return;
        _applyDanmakuPauseState(_buffering || !playing);
        setState(() {});
      });
      _applyDanmakuPauseState(_buffering || !_playerService.isPlaying);
      _duration = _playerService.duration;
      if (!kIsWeb && rawPath.isNotEmpty) {
        _thumbnailer = MediaKitThumbnailGenerator(
          media: Media(rawPath),
          httpProxy: httpProxy,
        );
      }
      if (startPosition != null && startPosition > Duration.zero) {
        final d = _duration;
        final target =
            (d > Duration.zero && startPosition > d) ? d : startPosition;
        await _playerService.seek(target, flushBuffer: _flushBufferOnSeek);
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
    if (_currentlyPlayingIndex < 0 || _currentlyPlayingIndex >= _playlist.length) {
      if (showToast && mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('当前没有可匹配的视频')),
        );
      }
      return;
    }

    final currentName = _playlist[_currentlyPlayingIndex].name;
    final hint = suggestDandanplaySearchInput(stripFileExtension(currentName));
    final candidate = await showDanmakuManualSearchDialog(
      context: context,
      apiUrls: appState.danmakuApiUrls,
      appId: appState.danmakuAppId,
      appSecret: appState.danmakuAppSecret,
      initialKeyword: hint.keyword.isEmpty ? stripFileExtension(currentName) : hint.keyword,
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
        _syncDanmakuCursor(_position);
      });
      if (showToast) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('已手动匹配并加载弹幕：$title')),
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
      _rebuildDanmakuHeatmap();
      _syncDanmakuCursor(_position);
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
                      const SizedBox(width: 8),
                      TextButton.icon(
                        onPressed: manualLoading ||
                                onlineLoading ||
                                _currentlyPlayingIndex < 0 ||
                                _currentlyPlayingIndex >= _playlist.length
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
                                child:
                                    CircularProgressIndicator(strokeWidth: 2),
                              )
                            : const Icon(Icons.search),
                        label: const Text('手动'),
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
                                  _rebuildDanmakuHeatmap();
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
        : AppConfigScope.of(context).displayName;

    _isTvDevice = _isTv(context);

    final remoteEnabled =
        _isTvDevice || (widget.appState?.forceRemoteControlKeys ?? false);
    _remoteEnabled = remoteEnabled;

    Widget wrapVideo(Widget child) {
      if (_fullScreen) return Expanded(child: child);
      return AspectRatio(aspectRatio: 16 / 9, child: child);
    }

    final isAndroid =
        !kIsWeb && defaultTargetPlatform == TargetPlatform.android;
    final useDesktopCinematic = !kIsWeb &&
        !_fullScreen &&
        (defaultTargetPlatform == TargetPlatform.windows ||
            defaultTargetPlatform == TargetPlatform.macOS ||
            defaultTargetPlatform == TargetPlatform.linux);
    final canPopRoute = Navigator.of(context).canPop();
    final needsSafeExit = isAndroid &&
        canPopRoute &&
        !_allowRoutePop &&
        _playerService.isInitialized &&
        !_playerService.isExternalPlayback;

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

          if (!_gesturesEnabled) return KeyEventResult.ignored;

          final isOkKey = key == LogicalKeyboardKey.space ||
              key == LogicalKeyboardKey.enter ||
              key == LogicalKeyboardKey.select;
          if (isOkKey) {
            // If long-press speed is disabled, keep original behavior (toggle on key-down).
            if (!_gestureLongPressEnabled) {
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
                    (base * _longPressMultiplier).clamp(0.25, 5.0).toDouble();
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
          backgroundColor: useDesktopCinematic
              ? Colors.transparent
              : Colors.black,
          extendBodyBehindAppBar: _fullScreen && !useDesktopCinematic,
          appBar: useDesktopCinematic
              ? null
              : PreferredSize(
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
                      title: Text(currentFileName),
                      centerTitle: true,
                      actions: [
                        IconButton(
                          tooltip: '选集',
                          icon: const Icon(Icons.playlist_play),
                          onPressed: () => _showPlaylistSheet(context),
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
                          icon: Icon(_hwdecOn
                              ? Icons.memory
                              : Icons.settings_backup_restore),
                          onPressed: _toggleHardwareDecode,
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
                  ),
                ),
              ),
            ),
          ),
          body: useDesktopCinematic
              ? _buildDesktopCinematicBody(
                  context,
                  currentFileName: currentFileName,
                )
              : Column(
            children: [
              wrapVideo(
                Container(
                  color: Colors.black,
                  child: _playerService.isInitialized
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
                              Positioned.fill(
                                child: ColoredBox(
                                  color: Colors.black54,
                                  child: Center(
                                    child: Column(
                                      mainAxisSize: MainAxisSize.min,
                                      children: [
                                        const CircularProgressIndicator(),
                                        if ((widget.appState?.showBufferSpeed ??
                                                false) &&
                                            _isNetworkPlayback)
                                          Padding(
                                            padding:
                                                const EdgeInsets.only(top: 12),
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
                                ),
                              ),
                            Positioned.fill(
                              child: LayoutBuilder(
                                builder: (ctx, constraints) {
                                  final w = constraints.maxWidth;
                                  final h = constraints.maxHeight;
                                  final sideDragEnabled =
                                      _gestureBrightnessEnabled ||
                                          _gestureVolumeEnabled;
                                  return GestureDetector(
                                    behavior: HitTestBehavior.translucent,
                                    onTap: _toggleControls,
                                    onDoubleTapDown: _gesturesEnabled
                                        ? (d) => _doubleTapDownPosition =
                                            d.localPosition
                                        : null,
                                    onDoubleTap: _gesturesEnabled
                                        ? () {
                                            final pos =
                                                _doubleTapDownPosition ??
                                                    Offset(w / 2, 0);
                                            // ignore: unawaited_futures
                                            _handleDoubleTap(pos, w);
                                          }
                                        : null,
                                    onHorizontalDragStart: (_gesturesEnabled &&
                                            _gestureSeekEnabled)
                                        ? _onSeekDragStart
                                        : null,
                                    onHorizontalDragUpdate: (_gesturesEnabled &&
                                            _gestureSeekEnabled)
                                        ? (d) => _onSeekDragUpdate(
                                              d,
                                              width: w,
                                              duration: _duration,
                                            )
                                        : null,
                                    onHorizontalDragEnd: (_gesturesEnabled &&
                                            _gestureSeekEnabled)
                                        ? _onSeekDragEnd
                                        : null,
                                    onVerticalDragStart: (_gesturesEnabled &&
                                            sideDragEnabled)
                                        ? (d) => _onSideDragStart(d, width: w)
                                        : null,
                                    onVerticalDragUpdate: (_gesturesEnabled &&
                                            sideDragEnabled)
                                        ? (d) => _onSideDragUpdate(d, height: h)
                                        : null,
                                    onVerticalDragEnd:
                                        (_gesturesEnabled && sideDragEnabled)
                                            ? _onSideDragEnd
                                            : null,
                                    onLongPressStart: (_gesturesEnabled &&
                                            _gestureLongPressEnabled)
                                        ? _onLongPressStart
                                        : null,
                                    onLongPressMoveUpdate: (_gesturesEnabled &&
                                            _gestureLongPressEnabled &&
                                            _longPressSlideEnabled)
                                        ? (d) => _onLongPressMoveUpdate(
                                              d,
                                              height: h,
                                            )
                                        : null,
                                    onLongPressEnd: (_gesturesEnabled &&
                                            _gestureLongPressEnabled)
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
                                          enabled:
                                              _playerService.isInitialized &&
                                                  _playError == null,
                                          playPauseFocusNode:
                                              _tvPlayPauseFocusNode,
                                          position: _position,
                                          buffered: _lastBuffer,
                                          duration: _duration,
                                          isPlaying: _playerService.isPlaying,
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
                                          seekForwardSeconds:
                                              _seekForwardSeconds,
                                          showSystemTime: widget.appState
                                                  ?.showSystemTimeInControls ??
                                              false,
                                          showBattery: widget.appState
                                                  ?.showBatteryInControls ??
                                              false,
                                          showBufferSpeed: widget
                                                  .appState?.showBufferSpeed ??
                                              false,
                                          buffering: _buffering,
                                          bufferSpeedX: _bufferSpeedX,
                                          netSpeedBytesPerSecond:
                                              _netSpeedBytesPerSecond,
                                          onRequestThumbnail: _thumbnailer ==
                                                  null
                                              ? null
                                              : (pos) =>
                                                  _thumbnailer!.getThumbnail(
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
                                            await _playerService.seek(
                                              pos,
                                              flushBuffer: _flushBufferOnSeek,
                                            );
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
                                                Duration(
                                                    seconds: _seekBackSeconds);
                                            final pos = target < Duration.zero
                                                ? Duration.zero
                                                : target;
                                            await _playerService.seek(
                                              pos,
                                              flushBuffer: _flushBufferOnSeek,
                                            );
                                            _position = pos;
                                            _syncDanmakuCursor(pos);
                                            if (mounted) setState(() {});
                                          },
                                          onSeekForward: () async {
                                            _showControls();
                                            final d = _duration;
                                            final target = _position +
                                                Duration(
                                                    seconds:
                                                        _seekForwardSeconds);
                                            final pos = (d > Duration.zero &&
                                                    target > d)
                                                ? d
                                                : target;
                                            await _playerService.seek(
                                              pos,
                                              flushBuffer: _flushBufferOnSeek,
                                            );
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
                      final isPlaying = index == _currentlyPlayingIndex;
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

  Widget _buildDesktopCinematicBody(
    BuildContext context, {
    required String currentFileName,
  }) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final shellColor = isDark ? const Color(0xB017191D) : const Color(0xD9FFFFFF);
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
              borderColor: _desktopFullscreen ? Colors.transparent : shellBorder,
              child: Padding(
                padding: _desktopFullscreen
                    ? EdgeInsets.zero
                    : const EdgeInsets.all(16),
                child: _buildDesktopVideoSurface(
                  context,
                  isDark: isDark,
                  currentFileName: currentFileName,
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildDesktopBackdrop({required bool isDark}) {
    final background = isDark ? const Color(0xFF060607) : const Color(0xFFF2F4F7);
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
                colors: [
                  centerGlowA,
                  centerGlowB,
                  background,
                ],
              ),
            ),
          ),
          Positioned(
            left: -120,
            top: -80,
            child: Container(
              width: 300,
              height: 300,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: cornerGlow,
              ),
            ),
          ),
          Positioned(
            right: -90,
            bottom: -130,
            child: Container(
              width: 340,
              height: 340,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: cornerGlow,
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildDesktopVideoSurface(
    BuildContext context, {
    required bool isDark,
    required String currentFileName,
  }) {
    final textTheme = Theme.of(context).textTheme;
    final frameRadius = _desktopFullscreen ? 0.0 : 30.0;
    final panelColor = isDark ? const Color(0x99111113) : const Color(0xD9FFFFFF);
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
                            if ((widget.appState?.showBufferSpeed ?? false) &&
                                _isNetworkPlayback)
                              Padding(
                                padding: const EdgeInsets.only(top: 12),
                                child: Text(
                                  'Network: ${_netSpeedBytesPerSecond == null ? '--' : formatBytesPerSecond(_netSpeedBytesPerSecond!)}',
                                  style: const TextStyle(color: Colors.white),
                                ),
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
                          _gestureBrightnessEnabled || _gestureVolumeEnabled;
                      return GestureDetector(
                        behavior: HitTestBehavior.translucent,
                        onTap: _toggleControls,
                        onDoubleTapDown: _gesturesEnabled
                            ? (d) => _doubleTapDownPosition = d.localPosition
                            : null,
                        onDoubleTap: _gesturesEnabled
                            ? () {
                                final pos =
                                    _doubleTapDownPosition ?? Offset(w / 2, 0);
                                // ignore: unawaited_futures
                                _handleDoubleTap(pos, w);
                              }
                            : null,
                        onHorizontalDragStart:
                            (_gesturesEnabled && _gestureSeekEnabled)
                                ? _onSeekDragStart
                                : null,
                        onHorizontalDragUpdate:
                            (_gesturesEnabled && _gestureSeekEnabled)
                                ? (d) => _onSeekDragUpdate(
                                      d,
                                      width: w,
                                      duration: _duration,
                                    )
                                : null,
                        onHorizontalDragEnd:
                            (_gesturesEnabled && _gestureSeekEnabled)
                                ? _onSeekDragEnd
                                : null,
                        onVerticalDragStart: (_gesturesEnabled && sideDragEnabled)
                            ? (d) => _onSideDragStart(d, width: w)
                            : null,
                        onVerticalDragUpdate:
                            (_gesturesEnabled && sideDragEnabled)
                                ? (d) => _onSideDragUpdate(d, height: h)
                                : null,
                        onVerticalDragEnd: (_gesturesEnabled && sideDragEnabled)
                            ? _onSideDragEnd
                            : null,
                        onLongPressStart:
                            (_gesturesEnabled && _gestureLongPressEnabled)
                                ? _onLongPressStart
                                : null,
                        onLongPressMoveUpdate: (_gesturesEnabled &&
                                _gestureLongPressEnabled &&
                                _longPressSlideEnabled)
                            ? (d) => _onLongPressMoveUpdate(d, height: h)
                            : null,
                        onLongPressEnd:
                            (_gesturesEnabled && _gestureLongPressEnabled)
                                ? _onLongPressEnd
                                : null,
                        child: const SizedBox.expand(),
                      );
                    },
                  ),
                ),
              ] else if (_playError != null) ...[
                Center(
                  child: Text(
                    'Playback failed: $_playError',
                    style: const TextStyle(color: Colors.redAccent),
                    textAlign: TextAlign.center,
                  ),
                ),
              ] else ...[
                Center(
                  child: Text(
                    'Open a media file to start playback',
                    style: textTheme.bodyMedium?.copyWith(
                      color: Colors.white70,
                    ),
                  ),
                ),
              ],
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
              Align(
                alignment: Alignment.topCenter,
                child: SafeArea(
                  bottom: false,
                  minimum: _desktopFullscreen
                      ? const EdgeInsets.fromLTRB(8, 8, 8, 0)
                      : const EdgeInsets.fromLTRB(16, 14, 16, 0),
                  child: AnimatedOpacity(
                    opacity: _controlsVisible ? 1 : 0,
                    duration: const Duration(milliseconds: 180),
                    child: IgnorePointer(
                      ignoring: !_controlsVisible,
                      child: Listener(
                        onPointerDown: (_) => _showControls(scheduleHide: false),
                        child: _buildDesktopTopStatusBar(
                          context,
                          isDark: isDark,
                          currentFileName: currentFileName,
                        ),
                      ),
                    ),
                  ),
                ),
              ),
              Align(
                alignment: Alignment.centerRight,
                child: SafeArea(
                  child: Padding(
                    padding: _desktopFullscreen
                        ? const EdgeInsets.fromLTRB(0, 44, 0, 104)
                        : const EdgeInsets.fromLTRB(0, 74, 14, 126),
                    child: AnimatedSlide(
                      offset: _desktopSidePanel == _DesktopSidePanel.none
                          ? const Offset(1.08, 0)
                          : Offset.zero,
                      duration: const Duration(milliseconds: 180),
                      curve: Curves.easeOutCubic,
                      child: AnimatedOpacity(
                        opacity:
                            _desktopSidePanel == _DesktopSidePanel.none ? 0 : 1,
                        duration: const Duration(milliseconds: 160),
                        child: IgnorePointer(
                          ignoring: _desktopSidePanel == _DesktopSidePanel.none,
                          child: _buildDesktopSidePanel(context, isDark: isDark),
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
                  minimum: _desktopFullscreen
                      ? const EdgeInsets.fromLTRB(8, 0, 8, 8)
                      : const EdgeInsets.fromLTRB(18, 0, 18, 14),
                  child: AnimatedOpacity(
                    opacity: _controlsVisible ? 1 : 0,
                    duration: const Duration(milliseconds: 200),
                    child: IgnorePointer(
                      ignoring: !_controlsVisible,
                      child: Listener(
                        onPointerDown: (_) => _showControls(scheduleHide: false),
                        child: _buildDesktopPlaybackControls(
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
    );
  }

  Widget _buildDesktopPlaybackControls(
    BuildContext context, {
    required bool isDark,
  }) {
    final enabled = _playerService.isInitialized && _playError == null;
    final sliderMaxMs = math.max(_duration.inMilliseconds, 1);
    final sliderValueMs = _position.inMilliseconds.clamp(0, sliderMaxMs);
    final sliderEnabled = enabled && _duration > Duration.zero;
    final chipBg = isDark
        ? Colors.black.withValues(alpha: 0.58)
        : Colors.white.withValues(alpha: 0.92);
    final chipBorder = isDark
        ? Colors.white.withValues(alpha: 0.18)
        : Colors.black.withValues(alpha: 0.12);
    final timelineActive =
        isDark ? Colors.white.withValues(alpha: 0.92) : Colors.black87;
    final timelineBuffered =
        isDark ? Colors.white.withValues(alpha: 0.45) : Colors.black38;
    final timelineInactive =
        isDark ? Colors.white.withValues(alpha: 0.2) : Colors.black12;
    final iconColor = isDark ? Colors.white : Colors.black87;
    final secondaryIconColor = isDark ? Colors.white70 : Colors.black54;
    final dividerColor = isDark
        ? Colors.white.withValues(alpha: 0.14)
        : Colors.black.withValues(alpha: 0.1);
    final rate = _playerService.isInitialized ? _playerService.player.state.rate : 1.0;
    final rightActionEnabled = enabled && _playlist.isNotEmpty;
    final speedHint = '${_fmtRate(rate)}x';

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
                color: chipBg,
                borderRadius: BorderRadius.circular(16),
                border: Border.all(color: chipBorder),
              ),
              child: Row(
                children: [
                Text(
                  _fmtClock(_position),
                  style: Theme.of(context).textTheme.labelMedium?.copyWith(
                        color: secondaryIconColor,
                        fontFeatures: const [FontFeature.tabularFigures()],
                      ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: SliderTheme(
                    data: SliderTheme.of(context).copyWith(
                      trackHeight: 3,
                      activeTrackColor: timelineActive,
                      secondaryActiveTrackColor: timelineBuffered,
                      inactiveTrackColor: timelineInactive,
                      thumbShape:
                          const RoundSliderThumbShape(enabledThumbRadius: 6),
                      overlayShape:
                          const RoundSliderOverlayShape(overlayRadius: 12),
                    ),
                    child: Slider(
                      min: 0,
                      max: sliderMaxMs.toDouble(),
                      value: sliderValueMs.toDouble(),
                      secondaryTrackValue: _lastBuffer.inMilliseconds
                          .clamp(0, sliderMaxMs)
                          .toDouble(),
                      onChangeStart: sliderEnabled ? (_) => _onScrubStart() : null,
                      onChanged: sliderEnabled
                          ? (value) => setState(
                                () => _position =
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
                              _position = target;
                              _syncDanmakuCursor(target);
                              _onScrubEnd();
                              if (mounted) setState(() {});
                            }
                          : null,
                    ),
                  ),
                ),
                const SizedBox(width: 10),
                Text(
                  _fmtClock(_duration),
                  style: Theme.of(context).textTheme.labelMedium?.copyWith(
                        color: secondaryIconColor,
                        fontFeatures: const [FontFeature.tabularFigures()],
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
                    border: Border.all(color: dividerColor),
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          Text(
                            '倍速',
                            style: Theme.of(context).textTheme.labelMedium?.copyWith(
                                  color: secondaryIconColor,
                                  fontWeight: FontWeight.w600,
                                ),
                          ),
                          const Spacer(),
                          Text(
                            speedHint,
                            style: Theme.of(context).textTheme.labelMedium?.copyWith(
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
                        onChanged: !enabled
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
                color: chipBg,
                borderRadius: BorderRadius.circular(16),
                border: Border.all(color: chipBorder),
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
                        onTap: enabled
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
                        icon: _playerService.isPlaying
                            ? Icons.pause_rounded
                            : Icons.play_arrow_rounded,
                        tooltip: _playerService.isPlaying ? '暂停' : '播放',
                        emphasized: true,
                        onTap:
                            enabled ? () => _togglePlayPause(showOverlay: false) : null,
                      ),
                      const SizedBox(width: 8),
                      _desktopControlButton(
                        context,
                        isDark: isDark,
                        icon: Icons.fast_forward_rounded,
                        tooltip: '快进',
                        onTap: enabled
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
                      OutlinedButton.icon(
                        style: OutlinedButton.styleFrom(
                          visualDensity: VisualDensity.compact,
                          side: BorderSide(color: dividerColor),
                        ),
                        onPressed: !enabled
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
                        icon: const Icon(Icons.speed_outlined, size: 18),
                        label: Text(speedHint),
                      ),
                      const SizedBox(width: 4),
                      IconButton(
                        tooltip:
                            _desktopFullscreen ? 'Exit fullscreen' : 'Fullscreen',
                        onPressed: enabled ? _toggleDesktopFullscreen : null,
                        icon: Icon(
                          _desktopFullscreen
                              ? Icons.fullscreen_exit
                              : Icons.fullscreen,
                          color: iconColor,
                        ),
                      ),
                      const SizedBox(width: 4),
                      IconButton(
                        tooltip: '选集',
                        onPressed: rightActionEnabled
                            ? () => _toggleDesktopPanel(_DesktopSidePanel.episode)
                            : null,
                        icon: Icon(
                          _desktopSidePanel == _DesktopSidePanel.episode
                              ? Icons.close
                              : Icons.format_list_numbered,
                          color: iconColor,
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

  void _toggleDesktopPanel(_DesktopSidePanel panel) {
    final next = _desktopSidePanel == panel ? _DesktopSidePanel.none : panel;
    setState(() {
      _desktopSidePanel = next;
      _desktopSpeedPanelVisible = false;
      if (next == _DesktopSidePanel.episode &&
          _currentlyPlayingIndex >= 0 &&
          _currentlyPlayingIndex < _playlist.length) {
        _desktopSelectedSeason =
            _desktopEpisodeInfoForIndex(_currentlyPlayingIndex).season;
      }
    });
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
    _showControls(scheduleHide: false);
  }

  Widget _buildDesktopTopStatusBar(
    BuildContext context, {
    required bool isDark,
    required String currentFileName,
  }) {
    final titleColor = isDark ? Colors.white : Colors.black87;
    final subtitleColor = isDark ? Colors.white70 : Colors.black54;
    final chipBg = isDark
        ? Colors.black.withValues(alpha: 0.56)
        : Colors.white.withValues(alpha: 0.9);
    final chipBorder = isDark
        ? Colors.white.withValues(alpha: 0.18)
        : Colors.black.withValues(alpha: 0.12);
    final hasCurrent = _currentlyPlayingIndex >= 0 &&
        _currentlyPlayingIndex < _playlist.length;
    final info = hasCurrent
        ? _desktopEpisodeInfoForIndex(_currentlyPlayingIndex)
        : _desktopEpisodeInfoForFile(currentFileName);
    final centerText = hasCurrent
        ? '第${info.season.toString().padLeft(2, '0')}季  ${info.mark}  ${info.title}'
        : currentFileName;
    final canPop = Navigator.of(context).canPop();
    final netSpeed = _desktopNetSpeedMbPerSecondLabel();

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
              onPressed: canPop ? () => Navigator.of(context).pop() : null,
              icon: const Icon(Icons.arrow_back_rounded),
            ),
            const SizedBox(width: 6),
            Expanded(
              child: Text(
                centerText,
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
                      '缓冲网速 $netSpeed',
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
                    icon: Icons.route_outlined,
                    label: '切换线路',
                    active: _desktopSidePanel == _DesktopSidePanel.line,
                    onTap: _playlist.isEmpty
                        ? null
                        : () => _toggleDesktopPanel(_DesktopSidePanel.line),
                  ),
                  const SizedBox(width: 8),
                  _desktopTopActionChip(
                    context,
                    isDark: isDark,
                    icon: Icons.audiotrack_outlined,
                    label: '音轨',
                    active: _desktopSidePanel == _DesktopSidePanel.audio,
                    onTap: _playerService.isInitialized
                        ? () => _toggleDesktopPanel(_DesktopSidePanel.audio)
                        : null,
                  ),
                  const SizedBox(width: 8),
                  _desktopTopActionChip(
                    context,
                    isDark: isDark,
                    icon: Icons.subtitles_outlined,
                    label: '字幕',
                    active: _desktopSidePanel == _DesktopSidePanel.subtitle,
                    onTap: _playerService.isInitialized
                        ? () => _toggleDesktopPanel(_DesktopSidePanel.subtitle)
                        : null,
                  ),
                  const SizedBox(width: 8),
                  _desktopTopActionChip(
                    context,
                    isDark: isDark,
                    icon: Icons.comment_outlined,
                    label: '弹幕',
                    active: _desktopSidePanel == _DesktopSidePanel.danmaku,
                    onTap: _playerService.isInitialized
                        ? () => _toggleDesktopPanel(_DesktopSidePanel.danmaku)
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
                    onTap: _showAnime4kSheet,
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
  }) {
    final fg = active
        ? (isDark ? Colors.white : Colors.black87)
        : (isDark ? Colors.white70 : Colors.black54);
    final bg = active
        ? (isDark
            ? Colors.white.withValues(alpha: 0.22)
            : Colors.black.withValues(alpha: 0.12))
        : (isDark
            ? Colors.black.withValues(alpha: 0.56)
            : Colors.white.withValues(alpha: 0.9));
    return Material(
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
              Text(
                label,
                style: Theme.of(context).textTheme.labelMedium?.copyWith(
                      color: fg,
                      fontWeight: FontWeight.w600,
                    ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildDesktopSidePanel(
    BuildContext context, {
    required bool isDark,
  }) {
    final width = (MediaQuery.sizeOf(context).width * 0.34)
        .clamp(360.0, 460.0)
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
            _buildDesktopPanelHeader(
              context,
              title: _desktopSidePanel.title,
            ),
            const Divider(height: 1),
            Expanded(
              child: switch (_desktopSidePanel) {
                _DesktopSidePanel.audio =>
                  _buildDesktopAudioPanel(context, isDark: isDark),
                _DesktopSidePanel.subtitle =>
                  _buildDesktopSubtitlePanel(context, isDark: isDark),
                _DesktopSidePanel.danmaku =>
                  _buildDesktopDanmakuPanel(context, isDark: isDark),
                _DesktopSidePanel.episode =>
                  _buildDesktopEpisodePanel(context, isDark: isDark),
                _DesktopSidePanel.line =>
                  _buildDesktopLinePanel(context, isDark: isDark),
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
    final current = _playerService.player.state.track.subtitle;
    final value = current;

    Future<void> pickAndAddSubtitle() async {
      final result = await FilePicker.platform.pickFiles(
        type: FileType.custom,
        allowedExtensions: const ['srt', 'ass', 'ssa', 'vtt', 'sub'],
      );
      if (result == null || result.files.isEmpty) return;
      final f = result.files.first;
      final path = (f.path ?? '').trim();
      if (path.isEmpty) {
        if (!mounted) return;
        ScaffoldMessenger.of(this.context).showSnackBar(
          const SnackBar(content: Text('无法读取字幕文件路径')),
        );
        return;
      }
      await _playerService.player.setSubtitleTrack(
        SubtitleTrack.uri(path, title: f.name),
      );
      if (!mounted) return;
      setState(() => _tracks = _playerService.player.state.tracks);
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
          title: const Text('粗体'),
          value: _subtitleBold,
          onChanged: (v) async {
            setState(() => _subtitleBold = v);
            await _applyMpvSubtitleOptions();
          },
        ),
        SwitchListTile(
          contentPadding: EdgeInsets.zero,
          title: const Text('强制覆盖 ASS/SSA'),
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
    final appState = widget.appState;
    final hasCurrent = _currentlyPlayingIndex >= 0 &&
        _currentlyPlayingIndex < _playlist.length;
    final hasSources = _danmakuSources.isNotEmpty;
    final selectedSource = (_danmakuSourceIndex >= 0 &&
            _danmakuSourceIndex < _danmakuSources.length)
        ? _danmakuSourceIndex
        : null;

    Future<void> loadOnline() async {
      if (!hasCurrent || _desktopDanmakuOnlineLoading) return;
      setState(() => _desktopDanmakuOnlineLoading = true);
      try {
        await _loadOnlineDanmakuForFile(
          _playlist[_currentlyPlayingIndex],
          showToast: true,
        );
      } finally {
        if (mounted) setState(() => _desktopDanmakuOnlineLoading = false);
      }
    }

    Future<void> manualSearch() async {
      if (!hasCurrent || _desktopDanmakuManualLoading) return;
      setState(() => _desktopDanmakuManualLoading = true);
      try {
        await _manualMatchOnlineDanmakuForCurrent(showToast: true);
      } finally {
        if (mounted) setState(() => _desktopDanmakuManualLoading = false);
      }
    }

    Future<void> persistSelectionName() async {
      if (appState == null) return;
      if (!appState.danmakuRememberSelectedSource) return;
      final idx = _danmakuSourceIndex;
      if (idx < 0 || idx >= _danmakuSources.length) return;
      await appState.setDanmakuLastSelectedSourceName(_danmakuSources[idx].name);
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
            if (appState != null) {
              // ignore: unawaited_futures
              appState.setDanmakuEnabled(v);
            }
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
        Row(
          children: [
            Expanded(
              child: FilledButton.icon(
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
            ),
            const SizedBox(width: 8),
            Expanded(
              child: OutlinedButton.icon(
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
                label: const Text('手动搜索'),
              ),
            ),
          ],
        ),
        const SizedBox(height: 10),
        if (appState != null && appState.danmakuApiUrls.isNotEmpty)
          Text(
            '在线源：${appState.danmakuApiUrls.join('  |  ')}',
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: Theme.of(context).textTheme.bodySmall?.copyWith(
                  color: isDark ? Colors.white60 : Colors.black54,
                ),
          ),
        const SizedBox(height: 8),
        DropdownButtonFormField<int>(
          initialValue: selectedSource,
          isExpanded: true,
          decoration: const InputDecoration(
            labelText: '弹幕源',
            isDense: true,
            border: OutlineInputBorder(),
          ),
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
                  await persistSelectionName();
                },
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
              _syncDanmakuCursor(_position);
            },
          ),
          trailing: TextButton(
            onPressed: () {
              setState(() => _danmakuTimeOffsetSeconds = 0.0);
              _syncDanmakuCursor(_position);
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
              if (appState != null) {
                // ignore: unawaited_futures
                appState.setDanmakuMaxLines(v.round());
              }
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
              if (appState != null) {
                // ignore: unawaited_futures
                appState.setDanmakuTopMaxLines(v.round());
              }
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
            onChanged: (v) => setState(() => _danmakuBottomMaxLines = v.round()),
            onChangeEnd: (v) {
              if (appState != null) {
                // ignore: unawaited_futures
                appState.setDanmakuBottomMaxLines(v.round());
              }
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
              if (appState != null) {
                // ignore: unawaited_futures
                appState.setDanmakuScale(v);
              }
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
              if (appState != null) {
                // ignore: unawaited_futures
                appState.setDanmakuOpacity(v);
              }
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
              if (appState != null) {
                // ignore: unawaited_futures
                appState.setDanmakuSpeed(v);
              }
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
            if (appState != null) {
              // ignore: unawaited_futures
              appState.setDanmakuBold(v);
            }
          },
        ),
        SwitchListTile(
          contentPadding: EdgeInsets.zero,
          title: const Text('合并重复弹幕'),
          value: appState?.danmakuMergeDuplicates ?? false,
          onChanged: appState == null
              ? null
              : (v) {
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
            if (appState != null) {
              // ignore: unawaited_futures
              appState.setDanmakuPreventOverlap(v);
            }
          },
        ),
      ],
    );
  }

  Widget _buildDesktopEpisodePanel(
    BuildContext context, {
    required bool isDark,
  }) {
    if (_playlist.isEmpty) {
      return const Center(child: Text('暂无可选剧集'));
    }
    final seasonMap = _desktopSeasonMap();
    final seasons = seasonMap.keys.toList()..sort();
    if (seasons.isEmpty) {
      return const Center(child: Text('暂无可选剧集'));
    }
    final currentSeason = _desktopSelectedSeason != null &&
            seasonMap.containsKey(_desktopSelectedSeason)
        ? _desktopSelectedSeason!
        : seasons.first;
    final episodeIndexes = seasonMap[currentSeason]!;
    final selectedBorder = isDark
        ? Colors.white.withValues(alpha: 0.35)
        : Colors.black.withValues(alpha: 0.22);
    final normalBorder = isDark
        ? Colors.white.withValues(alpha: 0.12)
        : Colors.black.withValues(alpha: 0.09);
    final tileColor = isDark
        ? Colors.white.withValues(alpha: 0.06)
        : Colors.white.withValues(alpha: 0.75);

    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 10, 12, 12),
      child: Column(
        children: [
          Row(
            children: [
              Expanded(
                child: DropdownButtonFormField<int>(
                  initialValue: currentSeason,
                  decoration: const InputDecoration(
                    isDense: true,
                    labelText: '季度',
                    border: OutlineInputBorder(),
                  ),
                  items: [
                    for (final season in seasons)
                      DropdownMenuItem(
                        value: season,
                        child: Text('第${season.toString().padLeft(2, '0')}季'),
                      ),
                  ],
                  onChanged: (v) {
                    if (v == null) return;
                    setState(() => _desktopSelectedSeason = v);
                  },
                ),
              ),
              const SizedBox(width: 8),
              IconButton(
                tooltip: _desktopEpisodeGridMode ? '切换为列表' : '切换为方块',
                onPressed: () =>
                    setState(() => _desktopEpisodeGridMode = !_desktopEpisodeGridMode),
                icon: Icon(
                  _desktopEpisodeGridMode ? Icons.view_agenda : Icons.grid_view,
                ),
              ),
            ],
          ),
          const SizedBox(height: 10),
          Expanded(
            child: _desktopEpisodeGridMode
                ? GridView.builder(
                    gridDelegate:
                        const SliverGridDelegateWithFixedCrossAxisCount(
                      crossAxisCount: 4,
                      mainAxisSpacing: 8,
                      crossAxisSpacing: 8,
                      childAspectRatio: 1,
                    ),
                    itemCount: episodeIndexes.length,
                    itemBuilder: (context, i) {
                      final index = episodeIndexes[i];
                      final info = _desktopEpisodeInfoForIndex(index);
                      final selected = index == _currentlyPlayingIndex;
                      return InkWell(
                        borderRadius: BorderRadius.circular(12),
                        onTap: () {
                          final wasPlaying = _playerService.isPlaying;
                          final start = _position;
                          _playFile(
                            _playlist[index],
                            index,
                            startPosition: start,
                            autoPlay: wasPlaying,
                          );
                        },
                        child: Ink(
                          decoration: BoxDecoration(
                            color: tileColor,
                            borderRadius: BorderRadius.circular(12),
                            border: Border.all(
                              color: selected ? selectedBorder : normalBorder,
                            ),
                          ),
                          child: Center(
                            child: Text(
                              info.mark,
                              style: Theme.of(context).textTheme.labelLarge?.copyWith(
                                    fontWeight: FontWeight.w700,
                                  ),
                            ),
                          ),
                        ),
                      );
                    },
                  )
                : ListView.separated(
                    itemCount: episodeIndexes.length,
                    separatorBuilder: (_, __) => const SizedBox(height: 8),
                    itemBuilder: (context, i) {
                      final index = episodeIndexes[i];
                      final file = _playlist[index];
                      final info = _desktopEpisodeInfoForIndex(index);
                      final selected = index == _currentlyPlayingIndex;
                      final hue = (file.name.hashCode.abs() % 360).toDouble();
                      final thumbA = HSLColor.fromAHSL(
                        1,
                        hue,
                        isDark ? 0.46 : 0.62,
                        isDark ? 0.4 : 0.82,
                      ).toColor();
                      final thumbB = HSLColor.fromAHSL(
                        1,
                        (hue + 28) % 360,
                        isDark ? 0.56 : 0.64,
                        isDark ? 0.6 : 0.9,
                      ).toColor();
                      return InkWell(
                        borderRadius: BorderRadius.circular(12),
                        onTap: () {
                          final wasPlaying = _playerService.isPlaying;
                          final start = _position;
                          _playFile(
                            file,
                            index,
                            startPosition: start,
                            autoPlay: wasPlaying,
                          );
                        },
                        child: Ink(
                          padding: const EdgeInsets.all(8),
                          decoration: BoxDecoration(
                            color: tileColor,
                            borderRadius: BorderRadius.circular(12),
                            border: Border.all(
                              color: selected ? selectedBorder : normalBorder,
                            ),
                          ),
                          child: Row(
                            children: [
                              ClipRRect(
                                borderRadius: BorderRadius.circular(8),
                                child: SizedBox(
                                  width: 92,
                                  height: 56,
                                  child: DecoratedBox(
                                    decoration: BoxDecoration(
                                      gradient: LinearGradient(
                                        begin: Alignment.topLeft,
                                        end: Alignment.bottomRight,
                                        colors: [thumbA, thumbB],
                                      ),
                                    ),
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
                                      info.mark,
                                      maxLines: 1,
                                      overflow: TextOverflow.ellipsis,
                                      style: Theme.of(context)
                                          .textTheme
                                          .labelMedium
                                          ?.copyWith(fontWeight: FontWeight.w700),
                                    ),
                                    const SizedBox(height: 2),
                                    Text(
                                      info.title,
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
                  ),
          ),
        ],
      ),
    );
  }

  Widget _buildDesktopLinePanel(
    BuildContext context, {
    required bool isDark,
  }) {
    if (_currentlyPlayingIndex < 0 || _currentlyPlayingIndex >= _playlist.length) {
      return const Center(child: Text('当前没有可切换线路'));
    }
    final lineIndexes = _desktopLineIndexesForCurrent();
    if (lineIndexes.length <= 1) {
      return const Center(
        child: Padding(
          padding: EdgeInsets.all(16),
          child: Text(
            '当前剧集暂无可切换线路',
            textAlign: TextAlign.center,
          ),
        ),
      );
    }
    return ListView.separated(
      padding: const EdgeInsets.fromLTRB(12, 10, 12, 12),
      itemCount: lineIndexes.length,
      separatorBuilder: (_, __) => const SizedBox(height: 8),
      itemBuilder: (context, i) {
        final index = lineIndexes[i];
        final selected = index == _currentlyPlayingIndex;
        final info = _desktopEpisodeInfoForIndex(index);
        return ListTile(
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
          tileColor: isDark
              ? Colors.white.withValues(alpha: selected ? 0.16 : 0.06)
              : Colors.black.withValues(alpha: selected ? 0.1 : 0.04),
          title: Text('线路 ${i + 1}'),
          subtitle: Text(
            _playlist[index].name,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
          trailing: selected
              ? const Icon(Icons.check_circle_outline_rounded)
              : Text(info.mark),
          onTap: () {
            if (selected) return;
            final wasPlaying = _playerService.isPlaying;
            final start = _position;
            _playFile(
              _playlist[index],
              index,
              startPosition: start,
              autoPlay: wasPlaying,
            );
          },
        );
      },
    );
  }

  String _desktopNetSpeedMbPerSecondLabel() {
    final bytes = _netSpeedBytesPerSecond;
    if (bytes == null || !bytes.isFinite || bytes <= 0) return '-- MB/S';
    final mb = bytes / (1024 * 1024);
    if (mb >= 10) return '${mb.toStringAsFixed(1)} MB/S';
    return '${mb.toStringAsFixed(2)} MB/S';
  }

  _DesktopEpisodeInfo _desktopEpisodeInfoForIndex(int index) {
    if (index < 0 || index >= _playlist.length) {
      return const _DesktopEpisodeInfo(
        season: 1,
        episode: 1,
        mark: 'S01E01',
        title: '',
        lineKey: 'unknown',
      );
    }
    return _desktopEpisodeInfoForFile(_playlist[index].name, fallbackEpisode: index + 1);
  }

  _DesktopEpisodeInfo _desktopEpisodeInfoForFile(
    String rawName, {
    int fallbackEpisode = 1,
  }) {
    final source = rawName.trim();
    if (source.isEmpty) {
      final ep = fallbackEpisode.clamp(1, 999);
      return _DesktopEpisodeInfo(
        season: 1,
        episode: ep,
        mark: 'S01E${ep.toString().padLeft(2, '0')}',
        title: '未知标题',
        lineKey: 's01e$ep',
      );
    }

    final normalized = source.replaceAll('_', ' ').replaceAll('.', ' ');
    var season = 1;
    var episode = fallbackEpisode.clamp(1, 999);
    var title = source;

    final seMatch = RegExp(
      r's(\d{1,3})\s*[- ]*\s*e(\d{1,3})',
      caseSensitive: false,
    ).firstMatch(normalized);
    if (seMatch != null) {
      season = int.tryParse(seMatch.group(1) ?? '') ?? 1;
      episode = int.tryParse(seMatch.group(2) ?? '') ?? episode;
      title = normalized.replaceRange(seMatch.start, seMatch.end, ' ');
    } else {
      final seasonMatch =
          RegExp(r'season\s*(\d{1,3})', caseSensitive: false)
              .firstMatch(normalized);
      if (seasonMatch != null) {
        season = int.tryParse(seasonMatch.group(1) ?? '') ?? 1;
      }
      final enEpisode = RegExp(
        r'(?:ep|episode|e)\s*[-_ ]*(\d{1,3})',
        caseSensitive: false,
      ).firstMatch(normalized);
      if (enEpisode != null) {
        episode = int.tryParse(enEpisode.group(1) ?? '') ?? episode;
      }
    }

    title = title
        .replaceAll(
          RegExp(r'(?:\bline\b|\bsource\b|线路)\s*\d+', caseSensitive: false),
          '',
        )
        .replaceAll(RegExp(r'\[[^\]]+\]'), '')
        .replaceAll(RegExp(r'\([^)]*\)$'), '')
        .replaceAll(RegExp(r'\s+'), ' ')
        .trim();
    if (title.isEmpty) title = source;

    final s = season.clamp(1, 999);
    final e = episode.clamp(1, 999);
    final mark = 'S${s.toString().padLeft(2, '0')}E${e.toString().padLeft(2, '0')}';
    final key = '${s.toString().padLeft(3, '0')}_${e.toString().padLeft(3, '0')}';
    return _DesktopEpisodeInfo(
      season: s,
      episode: e,
      mark: mark,
      title: title,
      lineKey: key,
    );
  }

  Map<int, List<int>> _desktopSeasonMap() {
    final map = <int, List<int>>{};
    for (var i = 0; i < _playlist.length; i++) {
      final info = _desktopEpisodeInfoForIndex(i);
      map.putIfAbsent(info.season, () => <int>[]).add(i);
    }
    for (final entry in map.entries) {
      entry.value.sort((a, b) {
        final aa = _desktopEpisodeInfoForIndex(a);
        final bb = _desktopEpisodeInfoForIndex(b);
        final byEpisode = aa.episode.compareTo(bb.episode);
        if (byEpisode != 0) return byEpisode;
        return a.compareTo(b);
      });
    }
    return map;
  }

  List<int> _desktopLineIndexesForCurrent() {
    if (_currentlyPlayingIndex < 0 || _currentlyPlayingIndex >= _playlist.length) {
      return const <int>[];
    }
    final current = _desktopEpisodeInfoForIndex(_currentlyPlayingIndex);
    final indexes = <int>[];
    for (var i = 0; i < _playlist.length; i++) {
      if (_desktopEpisodeInfoForIndex(i).lineKey == current.lineKey) {
        indexes.add(i);
      }
    }
    if (!indexes.contains(_currentlyPlayingIndex)) {
      indexes.insert(0, _currentlyPlayingIndex);
    }
    return indexes;
  }

  Widget _desktopControlButton(
    BuildContext context, {
    required bool isDark,
    required IconData icon,
    required String tooltip,
    required FutureOr<void> Function()? onTap,
    bool emphasized = false,
  }) {
    final bg = emphasized
        ? (isDark
            ? Colors.white.withValues(alpha: 0.22)
            : Colors.black.withValues(alpha: 0.12))
        : (isDark
            ? Colors.white.withValues(alpha: 0.1)
            : Colors.black.withValues(alpha: 0.06));
    final fg = emphasized
        ? (isDark ? Colors.white : Colors.black87)
        : (isDark ? Colors.white70 : Colors.black54);

    return Tooltip(
      message: tooltip,
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          borderRadius: BorderRadius.circular(12),
          onTap: onTap == null
              ? null
              : () {
                  final result = onTap();
                  if (result is Future<void>) {
                    unawaited(result);
                  }
                },
          child: Ink(
            width: 36,
            height: 36,
            decoration: BoxDecoration(
              color: bg,
              borderRadius: BorderRadius.circular(12),
            ),
            child: Icon(icon, size: 20, color: fg),
          ),
        ),
      ),
    );
  }

  Widget _buildDesktopGlassPanel({
    required BuildContext context,
    required Widget child,
    required double blurSigma,
    required Color color,
    required BorderRadius borderRadius,
    required Color borderColor,
  }) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    return ClipRRect(
      borderRadius: borderRadius,
      child: BackdropFilter(
        filter: ImageFilter.blur(sigmaX: blurSigma, sigmaY: blurSigma),
        child: DecoratedBox(
          decoration: BoxDecoration(
            color: color,
            borderRadius: borderRadius,
            border: Border.all(color: borderColor),
            boxShadow: [
              BoxShadow(
                color: isDark
                    ? Colors.black.withValues(alpha: 0.35)
                    : Colors.black.withValues(alpha: 0.12),
                blurRadius: 24,
                offset: const Offset(0, 16),
              ),
            ],
          ),
          child: child,
        ),
      ),
    );
  }

  void _showPlaylistSheet(BuildContext context) {
    showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      builder: (ctx) {
        if (_playlist.isEmpty) {
          return const SafeArea(
            child: Padding(
              padding: EdgeInsets.all(16),
              child: Text('No playlist items'),
            ),
          );
        }
        return SafeArea(
          child: ListView.builder(
            itemCount: _playlist.length,
            itemBuilder: (_, i) {
              final f = _playlist[i];
              return ListTile(
                title: Text(f.name),
                trailing:
                    i == _currentlyPlayingIndex ? const Icon(Icons.play_arrow) : null,
                onTap: () {
                  Navigator.of(ctx).pop();
                  _playFile(f, i);
                },
              );
            },
          ),
        );
      },
    );
  }

  void _toggleHardwareDecode() {
    setState(() => _hwdecOn = !_hwdecOn);
    if (_currentlyPlayingIndex >= 0 && _playlist.isNotEmpty) {
      _playFile(_playlist[_currentlyPlayingIndex], _currentlyPlayingIndex);
    }
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

class _DesktopEpisodeInfo {
  const _DesktopEpisodeInfo({
    required this.season,
    required this.episode,
    required this.mark,
    required this.title,
    required this.lineKey,
  });

  final int season;
  final int episode;
  final String mark;
  final String title;
  final String lineKey;
}
