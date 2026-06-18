import 'dart:async';
import 'dart:math' show max, min;
import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../api/api_interfaces.dart';
import '../../plugins/runtime/plugin_player_bridge.dart';
import 'app_logger.dart';
import 'player_adapter.dart';
import 'exo_player_adapter.dart';
import 'mpv_player_adapter.dart';
import 'native_mpv_player_adapter.dart';

/// 播放器内核类型
enum PlayerCoreType {
  exoPlayer,  // ExoPlayer（Android 原生）
  mpv,        // MPV（libmpv FFI，桌面/iOS）
  nativeMpv,  // MPV 原生 JNI（Android 专用，通过平台通道调用）
}

/// 视频播放器服务
///
/// 支持动态切换播放器内核：
/// - ExoPlayer: Android 原生，轻量稳定
/// - MPV: libmpv FFI，全格式支持、HDR、高级字幕控制
class VideoPlayerService extends ChangeNotifier {
  static final AppLogger _logger = AppLogger();
  static const int _maxDirectRetryCount = 5;

  PlayerAdapter? _adapter;
  PlayerCoreType _coreType = PlayerCoreType.exoPlayer;
  bool _hasReportedStart = false;
  bool _lastInitializationUsedFallback = false;
  String? _lastFallbackReason;
  Duration? _initialStartPosition;
  bool _lastDolbyVisionFix = false;
  bool _lastUseLibass = false;
  String? _lastPreferredSubtitleLanguage;
  bool _lastHardwareDecoding = true;
  bool _lastStartWithSoftwareDecoding = false;
  String? _primaryVideoUrl;
  String? _fallbackVideoUrl;
  bool _fallbackActivated = false;
  bool _autoRetryInFlight = false;
  int _startupRetryCount = 0;
  String? _selectedSubtitleTrackId;
  String? _selectedAudioTrackId;
  int? _surfaceViewId;  // For gpu-next rendering on Android
  bool _useGpuNext = false;  // gpu-next rendering mode

  Timer? _progressTimer;
  Timer? _hideControlsTimer;
  Timer? _pendingPlaybackTimer;
  bool? _pendingPlayingState;

  // 手势状态
  bool _showControls = true;
  bool _isLocked = false;
  bool _isDragging = false;
  bool _isScrubbingPosition = false;
  double _dragStartX = 0;
  double _dragStartY = 0;
  Duration _dragStartPosition = Duration.zero;
  Duration _dragPreviewPosition = Duration.zero;
  double _dragStartVolume = 1.0;
  double _currentBrightness = 1.0;
  double _dragStartBrightness = 1.0;

  // 播放上报
  String? _currentItemId;
  String? _mediaSourceId;
  Function(PlaybackProgressInfo)? _onProgressReport;
  Function(PlaybackStartInfo)? _onStartReport;
  Function(PlaybackStopInfo)? _onStopReport;

  // Getters
  bool get isPlaying => _adapter?.isPlaying ?? false;
  bool get isBuffering => _adapter?.isBuffering ?? false;
  bool get isInitialized => _adapter?.isInitialized ?? false;
  bool get hasError => (_adapter?.hasError ?? false) && !_autoRetryInFlight;
  String? get errorMessage => hasError ? _adapter?.errorMessage : null;
  Duration get position => _adapter?.position ?? Duration.zero;
  Duration get duration => _adapter?.duration ?? Duration.zero;
  double get speed => _adapter?.speed ?? 1.0;
  double get volume => _adapter?.volume ?? 1.0;
  bool get showControls => _showControls;
  bool get isLocked => _isLocked;
  bool get isDragging => _isDragging;
  bool get isScrubbingPosition => _isScrubbingPosition;
  bool get isCompleted => _adapter?.isCompleted ?? false;
  double get progress => _adapter?.progress ?? 0.0;
  PlayerCoreType get coreType => _coreType;
  bool get lastInitializationUsedFallback => _lastInitializationUsedFallback;
  String? get lastFallbackReason => _lastFallbackReason;
  Duration get dragPreviewPosition => _dragPreviewPosition;
  bool get isPlaybackActionPending => _pendingPlayingState != null;

  /// 当前播放器适配器（用于内核特定操作）
  PlayerAdapter? get adapter => _adapter;

  double get brightness => _currentBrightness;

  /// 手势起始 X 坐标（用于判断亮度/音量区域）
  double get dragStartX => _dragStartX;

  /// 拖动方向：1=向前, -1=向后, 0=无
  int get dragDirection {
    if (!_isDragging) return 0;
    final dx =
        _dragPreviewPosition.inMilliseconds - _dragStartPosition.inMilliseconds;
    if (dx < -500) return 1; // 向后拖 = 快进
    if (dx > 500) return -1; // 向前拖 = 快退
    return 0;
  }

  /// Flutter Texture ID（用于 Texture widget 渲染视频，旧架构）
  int? get textureId => _adapter?.textureId;

  /// 构建视频渲染 Widget
  ///
  /// ExoPlayer 返回 Texture widget，media_kit 返回 Video widget
  Widget buildVideo() {
    return _adapter?.buildVideo() ??
        const Center(
          child: CircularProgressIndicator(),
        );
  }

  /// libass 是否已就绪
  bool get libassReady => _adapter?.libassReady ?? false;

  /// 获取当前可用轨道列表
  List<Map<String, dynamic>> get tracksInfo => _adapter?.getTracksInfo() ?? [];

  /// 设置播放器内核
  void setCoreType(PlayerCoreType type) {
    if (_coreType == type) return;
    _coreType = type;
    if (_adapter?.isInitialized ?? false) {
      // TODO: 重新加载当前视频
    }
    notifyListeners();
  }

  /// 创建适配器
  PlayerAdapter _createAdapter() {
    switch (_coreType) {
      case PlayerCoreType.exoPlayer:
        return ExoPlayerAdapter();
      case PlayerCoreType.mpv:
        return MpvPlayerAdapter();
      case PlayerCoreType.nativeMpv:
        return NativeMpvPlayerAdapter();
    }
  }

  /// 向插件系统暴露的播放控制钩子。
  PluginPlayerHooks? _pluginHooks;

  /// 播放事件附带的基础数据（详细媒体信息由插件 ctx.player.getCurrentMedia 获取）。
  Map<String, dynamic> _pluginEventData() => {
        'itemId': _currentItemId,
        'mediaSourceId': _mediaSourceId,
        'positionMs': position.inMilliseconds,
        'durationMs': duration.inMilliseconds,
      };

  /// 绑定插件播放桥（让插件可控制播放并接收事件）。
  void _bindPluginBridge() {
    final hooks = PluginPlayerHooks();
    hooks.play = () => play();
    hooks.pause = () => pause();
    hooks.seek = (pos) => seekTo(pos);
    hooks.position = () => position;
    hooks.duration = () => duration;
    hooks.isPlaying = () => isPlaying;
    _pluginHooks = hooks;
    PluginPlayerBridge.instance.bind(hooks);
  }

  void _bindAdapterCallbacks() {
    _bindPluginBridge();
    _adapter!.setCallbacks(PlayerStateCallbacks(
      onPositionChanged: () => notifyListeners(),
      onDurationChanged: () => notifyListeners(),
      onPlayingStateChanged: () {
        final isNowPlaying = _adapter?.isPlaying ?? false;
        if (_pendingPlayingState == isNowPlaying) {
          _setPendingPlayingState(null, notify: false);
        }
        if (isNowPlaying) {
          if (!_hasReportedStart) {
            _reportStart();
            _hasReportedStart = true;
          }
          _startHideControlsTimer();
          PluginPlayerBridge.instance.emit('onPlay', _pluginEventData());
        } else {
          _cancelHideControlsTimer();
          PluginPlayerBridge.instance.emit('onPause', _pluginEventData());
        }
        notifyListeners();
      },
      onBufferingStateChanged: () => notifyListeners(),
      onCompleted: () {
        notifyListeners();
        // 通知插件系统：一集播放结束（示例 Telegram 插件监听此事件）。
        PluginPlayerBridge.instance.emit('onPlayEnd', _pluginEventData());
        // TODO: 自动播放下一集
      },
      onError: () {
        _setPendingPlayingState(null, notify: false);
        unawaited(_attemptStartupRetry());
        notifyListeners();
      },
      onSubtitleCue: (text, start, end) =>
          subtitleCueHandler?.call(text, start, end),
    ));
  }

  /// 流式字幕翻译的取词处理器：当前字幕 cue 变化时回调（仅 mpv 内核触发）。
  SubtitleCueCallback? subtitleCueHandler;

  void _setPendingPlayingState(bool? targetState, {bool notify = true}) {
    _pendingPlaybackTimer?.cancel();
    _pendingPlaybackTimer = null;

    final changed = _pendingPlayingState != targetState;
    _pendingPlayingState = targetState;

    if (targetState != null) {
      _pendingPlaybackTimer = Timer(const Duration(milliseconds: 900), () {
        if (_pendingPlayingState == targetState) {
          _pendingPlayingState = null;
          notifyListeners();
        }
      });
    }

    if (notify && changed) {
      notifyListeners();
    }
  }

  Future<void> _initializeAdapterForUrl(
    String videoUrl, {
    required Duration? startPosition,
    required bool hardwareDecoding,
    required String? preferredSubtitleLanguage,
    bool useGpuNext = false,
  }) async {
    await _adapter!.initialize(
      videoUrl: videoUrl,
      startPosition: startPosition,
      dolbyVisionFix: _lastDolbyVisionFix,
      useLibass: _lastUseLibass,
      hardwareDecoding: hardwareDecoding,
      preferredSubtitleLanguage: preferredSubtitleLanguage,
      surfaceViewId: _surfaceViewId,  // Pass for gpu-next rendering
      useGpuNext: useGpuNext,
    );
    _logger.i('VideoPlayerService', '适配器初始化完成, surfaceViewId=$_surfaceViewId');
    if (!(_adapter?.isInitialized ?? false) || (_adapter?.hasError ?? false)) {
      throw StateError(_adapter?.errorMessage ?? '播放器初始化失败');
    }
  }

  Future<void> _recreateAdapter() async {
    await _adapter?.dispose();
    _adapter = _createAdapter();
    _bindAdapterCallbacks();
  }

  Future<void> _restoreTrackSelections({
    String? audioTrackId,
    String? subtitleTrackId,
  }) async {
    if (audioTrackId != null && audioTrackId.isNotEmpty) {
      try {
        await _adapter!.selectAudioTrack(audioTrackId);
      } catch (e, stackTrace) {
        _logger.eWithStack(
          'VideoPlayerService',
          '恢复音轨选择失败: $audioTrackId',
          e,
          stackTrace,
        );
      }
    }

    if (subtitleTrackId != null && subtitleTrackId.isNotEmpty) {
      try {
        await _adapter!.selectSubtitleTrack(subtitleTrackId);
      } catch (e, stackTrace) {
        _logger.eWithStack(
          'VideoPlayerService',
          '恢复字幕轨选择失败: $subtitleTrackId',
          e,
          stackTrace,
        );
      }
    }
  }

  Future<bool> _tryActivateFallbackUrl({
    required Duration? startPosition,
    required bool hardwareDecoding,
    required String? preferredSubtitleLanguage,
    String? audioTrackId,
    String? subtitleTrackId,
    bool autoPlay = false,
  }) async {
    final fallbackUrl = _fallbackVideoUrl;
    if (_fallbackActivated ||
        fallbackUrl == null ||
        fallbackUrl.isEmpty ||
        fallbackUrl == _primaryVideoUrl) {
      return false;
    }

    _logger.w(
      'VideoPlayerService',
      '主播放链路失败，切换到兜底链路: reason=${_lastFallbackReason ?? 'unknown'}',
    );

    try {
      _fallbackActivated = true;
      await _recreateAdapter();
      await _initializeAdapterForUrl(
        fallbackUrl,
        startPosition: startPosition,
        hardwareDecoding: hardwareDecoding,
        preferredSubtitleLanguage: preferredSubtitleLanguage,
      );
      _primaryVideoUrl = fallbackUrl;
      _lastInitializationUsedFallback = true;
      _startupRetryCount = 0;

      if (autoPlay) {
        await _adapter!.play();
      }

      await _restoreTrackSelections(
        audioTrackId: audioTrackId,
        subtitleTrackId: subtitleTrackId,
      );
      return true;
    } catch (error, stackTrace) {
      _fallbackActivated = false;
      _logger.eWithStack(
        'VideoPlayerService',
        '兜底播放链路初始化失败',
        error,
        stackTrace,
      );
      return false;
    }
  }

  Future<void> _attemptStartupRetry() async {
    if (_autoRetryInFlight ||
        _primaryVideoUrl == null ||
        _primaryVideoUrl!.isEmpty ||
        _adapter == null ||
        !(_adapter?.hasError ?? false) ||
        _startupRetryCount >= _maxDirectRetryCount) {
      return;
    }

    final resumePosition = position > Duration.zero
        ? position
        : (_initialStartPosition ?? Duration.zero);
    final hardwareDecoding =
        _lastStartWithSoftwareDecoding ? false : _lastHardwareDecoding;
    final audioTrackId = _selectedAudioTrackId;
    final subtitleTrackId = _selectedSubtitleTrackId;

    _autoRetryInFlight = true;
    notifyListeners();
    try {
      Object? lastError;
      for (var attempt = _startupRetryCount + 1;
          attempt <= _maxDirectRetryCount;
          attempt++) {
        _startupRetryCount = attempt;
        try {
          _logger.w(
            'VideoPlayerService',
            '播放器直连自动重试: attempt=$attempt, resume=${resumePosition.inMilliseconds}ms',
          );

          await _recreateAdapter();

          await _initializeAdapterForUrl(
            _primaryVideoUrl!,
            startPosition: resumePosition,
            hardwareDecoding: hardwareDecoding,
            preferredSubtitleLanguage: _lastPreferredSubtitleLanguage,
          );

          await _adapter!.play();

          await _restoreTrackSelections(
            audioTrackId: audioTrackId,
            subtitleTrackId: subtitleTrackId,
          );

          _logger.i(
            'VideoPlayerService',
            '播放器直连自动重试成功: attempt=$attempt',
          );
          return;
        } catch (error, stackTrace) {
          lastError = error;
          _logger.eWithStack(
            'VideoPlayerService',
            '播放器直连自动重试失败: attempt=$attempt',
            error,
            stackTrace,
          );
          if (attempt < _maxDirectRetryCount) {
            await Future.delayed(const Duration(milliseconds: 350));
          }
        }
      }
      final fallbackActivated = await _tryActivateFallbackUrl(
        startPosition: resumePosition,
        hardwareDecoding: hardwareDecoding,
        preferredSubtitleLanguage: _lastPreferredSubtitleLanguage,
        audioTrackId: audioTrackId,
        subtitleTrackId: subtitleTrackId,
        autoPlay: true,
      );
      if (fallbackActivated) {
        _logger.i('VideoPlayerService', '播放器已切换到兜底播放链路');
        return;
      }
      throw lastError ?? StateError('播放器直连重试失败');
    } finally {
      _autoRetryInFlight = false;
      notifyListeners();
    }
  }

  /// 初始化播放器
  /// 已释放标记。在异步初始化途中用户返回（dispose 先于 initialize 完成）时，
  /// 用它让 initialize/play 直接短路，避免在屏幕已销毁后才创建适配器、
  /// 导致播放器在后台空跑出声却无画面。
  bool _disposed = false;

  Future<void> initialize({
    required String videoUrl,
    required String itemId,
    String? mediaSourceId,
    String? fallbackVideoUrl,
    Duration? startPosition,
    PlayerCoreType? coreType,
    Function(PlaybackStartInfo)? onStart,
    Function(PlaybackProgressInfo)? onProgress,
    Function(PlaybackStopInfo)? onStop,
    bool? dolbyVisionFix,
    bool? useLibass,
    bool? hardwareDecoding,
    bool startWithSoftwareDecoding = false,
    String? fallbackReason,
    String? preferredSubtitleLanguage,
    int? surfaceViewId,  // For gpu-next rendering on Android
    bool useGpuNext = false,  // gpu-next rendering mode
  }) async {
    // 屏幕已销毁：不要再创建/初始化适配器，否则会留下后台空跑的孤儿播放器。
    if (_disposed) return;
    _currentItemId = itemId;
    _mediaSourceId = mediaSourceId ?? itemId;
    _onStartReport = onStart;
    _onProgressReport = onProgress;
    _onStopReport = onStop;
    _hasReportedStart = false;
    _lastInitializationUsedFallback = false;
    _lastFallbackReason = fallbackReason;
    _primaryVideoUrl = videoUrl;
    _fallbackVideoUrl = fallbackVideoUrl;
    _fallbackActivated = false;
    _initialStartPosition = startPosition;
    _lastDolbyVisionFix = dolbyVisionFix ?? false;
    _lastUseLibass = useLibass ?? false;
    _lastPreferredSubtitleLanguage = preferredSubtitleLanguage;
    _lastHardwareDecoding = hardwareDecoding ?? true;
    _lastStartWithSoftwareDecoding = startWithSoftwareDecoding;
    _autoRetryInFlight = false;
    _startupRetryCount = 0;
    _selectedSubtitleTrackId = null;
    _selectedAudioTrackId = null;
    _surfaceViewId = surfaceViewId;  // Store for gpu-next rendering
    _useGpuNext = useGpuNext;  // Store gpu-next rendering mode
    _setPendingPlayingState(null, notify: false);

    if (coreType != null) {
      _coreType = coreType;
    }

    // 释放旧适配器
    await _recreateAdapter();

    // _recreateAdapter 期间可能发生 dispose（用户返回）。若已释放，立即把
    // 刚建好的适配器销毁并退出，避免它继续初始化并播放。
    if (_disposed) {
      await _adapter?.dispose();
      _adapter = null;
      return;
    }

    // 初始化
    final desiredHardwareDecoding =
        startWithSoftwareDecoding ? false : (hardwareDecoding ?? true);
    try {
      await _initializeAdapterForUrl(
        videoUrl,
        startPosition: startPosition,
        hardwareDecoding: desiredHardwareDecoding,
        preferredSubtitleLanguage: preferredSubtitleLanguage,
        useGpuNext: _useGpuNext,
      );
    } catch (error, stackTrace) {
      final fallbackActivated = await _tryActivateFallbackUrl(
        startPosition: startPosition,
        hardwareDecoding: desiredHardwareDecoding,
        preferredSubtitleLanguage: preferredSubtitleLanguage,
      );
      if (!fallbackActivated) {
        Error.throwWithStackTrace(error, stackTrace);
      }
    }

    // 适配器初始化为异步过程，期间用户可能已返回销毁本服务。
    if (_disposed) {
      await _adapter?.dispose();
      _adapter = null;
      return;
    }

    // 加载 libass 字幕（如果启用）
    if (useLibass ?? false) {
      // 由调用方在 initialize 后手动加载字幕
    }

    // 启动进度定时器
    _startProgressTimer();

    notifyListeners();
  }

  /// 加载外部字幕文件（通过 libass）
  Future<void> loadLibassSubtitle(String path) async {
    await _adapter?.loadLibassSubtitle(path);
  }

  /// 原生 mpv 属性读取（仅 media_kit/mpv 内核，其他返回 null）。
  Future<String?> mpvGetProperty(String name) async {
    final a = _adapter;
    return a is MpvPlayerAdapter ? a.mpvGetProperty(name) : null;
  }

  /// 原生 mpv 属性设置（仅 mpv 内核）。
  Future<void> mpvSetProperty(String name, String value) async {
    final a = _adapter;
    if (a is MpvPlayerAdapter) await a.mpvSetProperty(name, value);
  }

  /// 原生 mpv 命令（仅 mpv 内核）。
  Future<void> mpvCommand(List<String> args) async {
    final a = _adapter;
    if (a is MpvPlayerAdapter) await a.mpvCommand(args);
  }

  /// 当前内核是否为 media_kit/mpv（流式 sub-step 预读仅此内核可用）。
  bool get isMpvCore => _adapter is MpvPlayerAdapter;

  /// 加载字幕数据到内存（通过 libass）
  Future<void> loadLibassSubtitleMemory(Uint8List data,
      {String codec = 'ass'}) async {
    await _adapter?.loadLibassSubtitleMemory(data, codec: codec);
  }

  /// 为底层播放器提供字幕类型/标题提示，帮助匹配内封字幕。
  void setSubtitleSelectionHint({String? codec, String? title}) {
    _adapter?.setSubtitleSelectionHint(codec, title: title);
  }

  /// 当前选中的字幕 / 音频轨道 id（未选则为 null）。
  String? get selectedSubtitleTrackId => _selectedSubtitleTrackId;
  String? get selectedAudioTrackId => _selectedAudioTrackId;

  /// 选择字幕轨道（内封字幕切换）
  Future<void> selectSubtitleTrack(String trackId) async {
    _selectedSubtitleTrackId = trackId;
    await _adapter?.selectSubtitleTrack(trackId);
    notifyListeners();
  }

  /// 关闭字幕
  Future<void> deselectSubtitleTrack() async {
    _selectedSubtitleTrackId = null;
    await _adapter?.deselectSubtitleTrack();
    notifyListeners();
  }

  /// 选择音频轨道
  Future<void> selectAudioTrack(String trackId) async {
    _selectedAudioTrackId = trackId;
    await _adapter?.selectAudioTrack(trackId);
    notifyListeners();
  }

  /// 加载次字幕文件
  Future<void> loadSecondarySubtitle(String path) async {
    await _adapter?.loadSecondarySubtitle(path);
    notifyListeners();
  }

  /// 通过轨道ID选择内封字幕作为次字幕
  Future<void> selectSecondarySubtitleTrack(String trackId) async {
    await _adapter?.selectSecondarySubtitleTrack(trackId);
    notifyListeners();
  }

  /// 取消次字幕
  Future<void> deselectSecondarySubtitle() async {
    await _adapter?.deselectSecondarySubtitle();
    notifyListeners();
  }

  /// 播放
  Future<void> play() async {
    if (_disposed ||
        _adapter == null ||
        !isInitialized ||
        hasError ||
        isPlaying ||
        isPlaybackActionPending) {
      return;
    }
    _setPendingPlayingState(true);
    try {
      await _playWithStartupRetries();
    } catch (_) {
      _setPendingPlayingState(null);
      rethrow;
    }
    _startHideControlsTimer();
    notifyListeners();
  }

  Future<void> _playWithStartupRetries() async {
    Object? lastError;
    for (var attempt = 0; attempt < 3; attempt++) {
      try {
        await _adapter!.play();
        return;
      } catch (error) {
        lastError = error;
        if (_hasReportedStart ||
            attempt >= 2 ||
            _primaryVideoUrl == null ||
            _primaryVideoUrl!.isEmpty) {
          rethrow;
        }
        _startupRetryCount = attempt + 1;
        await _recreateAdapter();
        await _initializeAdapterForUrl(
          _primaryVideoUrl!,
          startPosition: _initialStartPosition,
          hardwareDecoding:
              _lastStartWithSoftwareDecoding ? false : _lastHardwareDecoding,
          preferredSubtitleLanguage: _lastPreferredSubtitleLanguage,
        );
      }
    }
    final fallbackActivated = await _tryActivateFallbackUrl(
      startPosition: _initialStartPosition,
      hardwareDecoding:
          _lastStartWithSoftwareDecoding ? false : _lastHardwareDecoding,
      preferredSubtitleLanguage: _lastPreferredSubtitleLanguage,
      autoPlay: true,
    );
    if (fallbackActivated) {
      _logger.i('VideoPlayerService', '起播阶段已切换到兜底播放链路');
      return;
    }
    throw lastError ?? StateError('播放器直连重试失败');
  }

  /// 暂停
  Future<void> pause() async {
    if (_adapter == null ||
        !isInitialized ||
        hasError ||
        !isPlaying ||
        isPlaybackActionPending) {
      return;
    }
    _setPendingPlayingState(false);
    try {
      await _adapter!.pause();
    } catch (_) {
      _setPendingPlayingState(null);
      rethrow;
    }
    _reportProgress();
    _cancelHideControlsTimer();
    notifyListeners();
  }

  /// 播放/暂停切换
  Future<void> togglePlay() async {
    if (!isInitialized || hasError || isPlaybackActionPending) {
      return;
    }
    if (isPlaying) {
      await pause();
    } else {
      await play();
    }
  }

  /// 跳转到指定位置
  Future<void> seekTo(Duration position) async {
    await _adapter?.seekTo(position);
    _dragPreviewPosition = Duration.zero;
    _isScrubbingPosition = false;
    _reportProgress();
    notifyListeners();
  }

  /// 快进/快退
  Future<void> seekBy(Duration offset) async {
    await seekTo(position + offset);
  }

  /// 设置播放速度
  Future<void> setSpeed(double speed) async {
    await _adapter?.setSpeed(speed);
    notifyListeners();
  }

  /// 设置音量
  Future<void> setVolume(double volume) async {
    await _adapter?.setVolume(volume);
    notifyListeners();
  }

  /// 截图
  Future<Uint8List?> screenshot() async {
    return await _adapter?.screenshot();
  }

  /// 设置字幕同步偏移
  Future<void> setSubtitleDelay(double seconds) async {
    await _adapter?.setSubtitleDelay(seconds);
    notifyListeners();
  }

  /// 设置音频同步偏移
  Future<void> setAudioDelay(double seconds) async {
    await _adapter?.setAudioDelay(seconds);
    notifyListeners();
  }

  /// 设置字幕字体
  Future<void> setSubtitleFont(String fontName) async {
    await _adapter?.setSubtitleFont(fontName);
    notifyListeners();
  }

  /// 设置字幕大小
  Future<void> setSubtitleSize(double size) async {
    await _adapter?.setSubtitleSize(size);
    notifyListeners();
  }

  /// 设置字幕位置
  Future<void> setSubtitlePosition(double position) async {
    await _adapter?.setSubtitlePosition(position);
    notifyListeners();
  }

  /// 设置字幕黑色背景
  Future<void> setSubtitleBackground(bool enabled) async {
    await _adapter?.setSubtitleBackground(enabled);
    notifyListeners();
  }

  /// 设置画面比例
  Future<void> setAspectRatio(String ratio) async {
    await _adapter?.setAspectRatio(ratio);
    notifyListeners();
  }

  /// 应用超分辨率
  Future<void> applySuperResolution(bool enable) async {
    await _adapter?.applySuperResolution(enable);
    notifyListeners();
  }

  /// 应用超分辨率档位
  Future<void> applySuperResolutionLevel(String level) async {
    await _adapter?.applySuperResolutionLevel(level);
    notifyListeners();
  }

  /// 获取播放统计信息
  Future<Map<String, String>> getPlaybackStats() async {
    return await _adapter?.getPlaybackStats() ?? {};
  }

  /// 设置亮度
  void setBrightness(double brightness) {
    _currentBrightness = brightness.clamp(0.1, 1.0);
    notifyListeners();
  }

  /// 保存亮度到本地
  Future<void> saveBrightness() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setDouble('player_brightness', _currentBrightness);
  }

  /// 从本地加载亮度
  Future<void> loadBrightness() async {
    final prefs = await SharedPreferences.getInstance();
    final savedBrightness = prefs.getDouble('player_brightness');
    if (savedBrightness != null) {
      _currentBrightness = savedBrightness;
      notifyListeners();
    }
  }

  /// 显示/隐藏控制栏
  void toggleControls() {
    if (_isLocked) return;
    _showControls = !_showControls;
    if (_showControls) {
      _startHideControlsTimer();
    } else {
      _cancelHideControlsTimer();
    }
    notifyListeners();
  }

  /// 锁定/解锁屏幕
  void toggleLock() {
    _isLocked = !_isLocked;
    if (_isLocked) {
      _showControls = false;
      _cancelHideControlsTimer();
    }
    notifyListeners();
  }

  // ========== 手势控制 ==========

  void onDragStart(DragStartDetails details, BoxConstraints constraints) {
    if (_isLocked || !isInitialized) return;
    _isDragging = true;
    _isScrubbingPosition = false;
    _dragStartX = details.globalPosition.dx;
    _dragStartY = details.globalPosition.dy;
    _dragStartPosition = position;
    _dragPreviewPosition = position;
    _dragStartVolume = volume;
    _dragStartBrightness = _currentBrightness;
    _cancelHideControlsTimer();
    notifyListeners();
  }

  void onDragUpdate(DragUpdateDetails details, BoxConstraints constraints) {
    if (!_isDragging || _isLocked) return;

    final dx = details.globalPosition.dx - _dragStartX;
    final dy = details.globalPosition.dy - _dragStartY;
    final width = constraints.maxWidth;
    final height = constraints.maxHeight;

    // 手势灵敏度阈值：至少移动 10 个逻辑像素才开始响应
    const threshold = 10.0;
    if (dx.abs() < threshold && dy.abs() < threshold) return;

    if (dx.abs() > dy.abs() * 1.5) {
      // 水平滑动（进度调节）：需要水平移动明显大于垂直移动
      _isScrubbingPosition = true;
      final progressDelta =
          dx / width * duration.inMilliseconds * 0.5; // 降低灵敏度系数
      final newPositionMs = max(
          0,
          min(
            _dragStartPosition.inMilliseconds + progressDelta.round(),
            duration.inMilliseconds,
          ));
      _dragPreviewPosition = Duration(milliseconds: newPositionMs);
      notifyListeners();
    } else if (dy.abs() > dx.abs() * 1.5) {
      _isScrubbingPosition = false;
      // 垂直滑动（亮度/音量）：需要垂直移动明显大于水平移动
      if (_dragStartX < width / 2) {
        // 左侧：亮度
        final brightnessDelta = -dy / height * 0.7; // 降低灵敏度系数
        final newBrightness =
            (_dragStartBrightness + brightnessDelta).clamp(0.1, 1.0);
        setBrightness(newBrightness);
      } else {
        // 右侧：音量
        final volumeDelta = -dy / height * 0.7; // 降低灵敏度系数
        final newVolume = (_dragStartVolume + volumeDelta).clamp(0.0, 1.0);
        setVolume(newVolume);
      }
    }
    // 如果移动方向不明确（水平和垂直移动差不多），则不响应，避免误触
  }

  void onDragEnd(DragEndDetails details) {
    if (!_isDragging) return;
    _isDragging = false;
    final targetPosition =
        _isScrubbingPosition ? _dragPreviewPosition : _dragStartPosition;
    _isScrubbingPosition = false;
    seekTo(targetPosition);
    _startHideControlsTimer();
    notifyListeners();
  }

  // ========== 内部方法 ==========

  void _startProgressTimer() {
    _progressTimer?.cancel();
    _progressTimer = Timer.periodic(const Duration(seconds: 5), (_) {
      _reportProgress();
    });
  }

  void _stopProgressTimer() {
    _progressTimer?.cancel();
    _progressTimer = null;
  }

  void _startHideControlsTimer() {
    _cancelHideControlsTimer();
    _hideControlsTimer = Timer(const Duration(seconds: 3), () {
      if (isPlaying && !_isDragging) {
        _showControls = false;
        notifyListeners();
      }
    });
  }

  void _cancelHideControlsTimer() {
    _hideControlsTimer?.cancel();
    _hideControlsTimer = null;
  }

  // ========== 播放上报 ==========

  void _reportStart() {
    if (_onStartReport == null || _currentItemId == null) return;
    _onStartReport!(PlaybackStartInfo(
      itemId: _currentItemId!,
      mediaSourceId: _mediaSourceId ?? _currentItemId!,
    ));
  }

  void _reportProgress() {
    if (_onProgressReport == null || _currentItemId == null) return;
    _onProgressReport!(PlaybackProgressInfo(
      itemId: _currentItemId!,
      mediaSourceId: _mediaSourceId ?? _currentItemId!,
      positionTicks: (position.inMilliseconds * 10000).round(),
      isPaused: !isPlaying,
      volumeLevel: volume,
    ));
  }

  void _reportStop() {
    if (_onStopReport == null || _currentItemId == null) return;
    _onStopReport!(PlaybackStopInfo(
      itemId: _currentItemId!,
      mediaSourceId: _mediaSourceId ?? _currentItemId!,
      positionTicks: (position.inMilliseconds * 10000).round(),
    ));
  }

  /// 释放资源
  @override
  Future<void> dispose() async {
    if (_disposed) return;
    // 同步置位，让仍在途中的 initialize/play 立刻短路。
    _disposed = true;
    _setPendingPlayingState(null, notify: false);
    _pendingPlaybackTimer?.cancel();
    _pendingPlaybackTimer = null;
    _primaryVideoUrl = null;
    _fallbackVideoUrl = null;
    _fallbackActivated = false;
    _initialStartPosition = null;
    _lastPreferredSubtitleLanguage = null;
    _autoRetryInFlight = false;
    _startupRetryCount = 0;
    _reportStop();
    _stopProgressTimer();
    _cancelHideControlsTimer();
    _hasReportedStart = false;
    final hooks = _pluginHooks;
    if (hooks != null) {
      PluginPlayerBridge.instance.unbind(hooks);
      _pluginHooks = null;
    }
    await _adapter?.dispose();
    _adapter = null;
    super.dispose();
  }
}
