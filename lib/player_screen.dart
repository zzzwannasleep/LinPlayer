import 'dart:async';
import 'dart:io';
import 'dart:math' as math;

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
import 'src/device/device_type.dart';
import 'src/ui/glass_blur.dart';
import 'state/app_state.dart';
import 'state/anime4k_preferences.dart';
import 'state/danmaku_preferences.dart';
import 'state/interaction_preferences.dart';
import 'state/local_playback_handoff.dart';
import 'state/preferences.dart';

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
    with WidgetsBindingObserver {
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
  int _danmakuMaxLines = 10;
  int _danmakuTopMaxLines = 10;
  int _danmakuBottomMaxLines = 10;
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
  bool _exitInProgress = false;
  bool _allowRoutePop = false;

  static const Duration _controlsAutoHideDelay = Duration(seconds: 3);
  Timer? _controlsHideTimer;
  bool _controlsVisible = true;
  bool _isScrubbing = false;

  static const Duration _gestureOverlayAutoHideDelay =
      Duration(milliseconds: 800);
  Timer? _gestureOverlayTimer;
  IconData? _gestureOverlayIcon;
  String? _gestureOverlayText;
  Offset? _doubleTapDownPosition;

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
    _danmakuMaxLines = appState?.danmakuMaxLines ?? 10;
    _danmakuTopMaxLines = appState?.danmakuTopMaxLines ?? 0;
    _danmakuBottomMaxLines = appState?.danmakuBottomMaxLines ?? 0;
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
    WidgetsBinding.instance.removeObserver(this);
    _controlsHideTimer?.cancel();
    _controlsHideTimer = null;
    _gestureOverlayTimer?.cancel();
    _gestureOverlayTimer = null;
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

  Future<void> _requestExitThenPop() async {
    if (_exitInProgress) return;
    _exitInProgress = true;

    _controlsHideTimer?.cancel();
    _controlsHideTimer = null;
    _gestureOverlayTimer?.cancel();
    _gestureOverlayTimer = null;

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
      widget.appState?.longPressSpeedMultiplier ?? 2.5;

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
    final targetRate =
        (_longPressBaseRate! * _longPressMultiplier).clamp(0.1, 4.0).toDouble();
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
        (_longPressMultiplier + delta).clamp(1.0, 4.0).toDouble();
    final targetRate =
        (_longPressBaseRate! * multiplier).clamp(0.1, 4.0).toDouble();
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
      _danmakuShowHeatmap = appState?.danmakuShowHeatmap ?? true;
      _danmakuHeatmap = const [];
      _controlsVisible = true;
      _isScrubbing = false;
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
    try {
      await _playerService.dispose();
    } catch (_) {}
    try {
      await _thumbnailer?.dispose();
    } catch (_) {}
    _thumbnailer = null;

    try {
      final rawPath = (file.path ?? '').trim();
      final uri = Uri.tryParse(rawPath);
      final isHttpUrl = uri != null &&
          (uri.scheme == 'http' || uri.scheme == 'https') &&
          uri.host.isNotEmpty;
      final isNetwork = kIsWeb || isHttpUrl;

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
      );
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
            .clamp(0.1, 3.0)
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
        _thumbnailer = MediaKitThumbnailGenerator(media: Media(rawPath));
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

    final remoteEnabled =
        _isTvDevice || (widget.appState?.forceRemoteControlKeys ?? false);
    _remoteEnabled = remoteEnabled;

    Widget wrapVideo(Widget child) {
      if (_fullScreen) return Expanded(child: child);
      return AspectRatio(aspectRatio: 16 / 9, child: child);
    }

    final isAndroid =
        !kIsWeb && defaultTargetPlatform == TargetPlatform.android;
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

          if (!_gesturesEnabled) return KeyEventResult.ignored;

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
                        icon: Icon(_hwdecOn
                            ? Icons.memory
                            : Icons.settings_backup_restore),
                        onPressed: () {
                          setState(() => _hwdecOn = !_hwdecOn);
                          if (_currentlyPlayingIndex >= 0 &&
                              _playlist.isNotEmpty) {
                            _playFile(_playlist[_currentlyPlayingIndex],
                                _currentlyPlayingIndex);
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
                ),
              ),
            ),
          ),
          body: Column(
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
                                                false))
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
                                left: false,
                                right: false,
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
                      subtitle: Slider(
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
                      subtitle: Slider(
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
        'sub-ass-override',
        _subtitleAssOverrideForce ? 'force' : 'no',
      );
    } catch (_) {}
  }
}

enum _OrientationMode { auto, landscape, portrait }

enum _GestureMode { none, brightness, volume, seek, speed }
