import 'dart:async';
import 'dart:math' show max, min;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'player_adapter.dart';
import 'app_logger.dart';
import 'cache_service.dart';
import '../app_identity.dart';
import '../network/proxy_settings.dart';

/// Native mpv player adapter for Android.
///
/// Communicates with mpv via platform channels (MethodChannel/EventChannel)
/// through MpvPlayerPlugin.kt → MPVLib → libplayer.so → libmpv.so.
///
/// Unlike ExoPlayerAdapter, subtitles are rendered natively by mpv/libass,
/// so no Flutter subtitle overlay is needed.
class NativeMpvPlayerAdapter implements PlayerAdapter {
  static const _channel = MethodChannel('com.linplayer/mpv');
  static final _logger = AppLogger();

  // Completer for waiting on SurfaceView creation (used when gpu-next is enabled)
  // Flag: AndroidView for gpu-next should render even before _useSurfaceView is set
  bool _waitingForSurfaceView = false;

  String? _playerId;
  int? _textureId;
  // 逐流取流鉴权（网盘/聚合源直链）：create 与 reload 共用。Kotlin 侧把
  // httpHeaders 透传给 mpv http-header-fields、userAgent 覆盖默认 UA。
  Map<String, String>? _httpHeaders;
  String? _userAgentOverride;
  int? _surfaceViewId;  // For gpu-next rendering via SurfaceView
  bool _useSurfaceView = false;
  EventChannel? _eventChannel;
  StreamSubscription? _eventSub;

  bool _isInitialized = false;
  bool _isPlaying = false;
  bool _isBuffering = false;
  bool _isCompleted = false;
  Duration _position = Duration.zero;
  Duration _duration = Duration.zero;
  double _speed = 1.0;
  double _volume = 1.0;
  String? _errorMessage;

  List<Map<String, dynamic>> _tracks = [];
  int _videoWidth = 0;
  int _videoHeight = 0;
  String _aspectRatio = '自动';

  // Shader state
  List<String> _currentShaders = [];
  bool _superResolutionEnabled = false;
  String _superResolutionLevel = 'off';

  PlayerStateCallbacks? _callbacks;
  Timer? _positionTimer;

  // 流式翻译：仅翻译进行时开启 sub-text 取词轮询，避免常态开销。
  bool _emitSubtitleCue = false;
  String _lastSubText = '';

  @override
  bool get isInitialized => _isInitialized;
  @override
  bool get isPlaying => _isPlaying;
  @override
  bool get isBuffering => _isBuffering;
  @override
  bool get isCompleted => _isCompleted;
  @override
  Duration get position => _position;
  @override
  Duration get duration => _duration;
  @override
  double get speed => _speed;
  @override
  double get volume => _volume;
  @override
  double get progress {
    final dur = _duration.inMilliseconds;
    if (dur <= 0) return 0.0;
    return _position.inMilliseconds / dur;
  }

  @override
  bool get hasError => _errorMessage != null;
  @override
  String? get errorMessage => _errorMessage;

  @override
  bool get libassReady => true; // libass is built into libmpv.so

  double? get videoAspectRatio {
    if (_videoWidth <= 0 || _videoHeight <= 0) return null;
    return _videoWidth / _videoHeight;
  }

  String get aspectRatioMode => _aspectRatio;

  @override
  int? get textureId => _textureId;

  @override
  List<Map<String, dynamic>> getTracksInfo() => _tracks;

  @override
  void setCallbacks(PlayerStateCallbacks callbacks) {
    _callbacks = callbacks;
  }

  @override
  void setSubtitleSelectionHint(String? codec, {String? title}) {
    // mpv selects subtitle tracks directly by ID, no hint needed
  }

  // ---- Initialize ----

  /// 是否为网络流地址（仅网络播放才需要磁盘缓存把缓冲挪出内存防 OOM）。
  bool _isHttpUrl(String url) {
    final lower = url.toLowerCase();
    return lower.startsWith('http://') || lower.startsWith('https://');
  }

  @override
  Future<void> initialize({
    required String videoUrl,
    Duration? startPosition,
    bool dolbyVisionFix = false,
    bool useLibass = false,
    bool hardwareDecoding = true,
    String? preferredSubtitleLanguage,
    int? surfaceViewId,  // Optional: for gpu-next rendering
    bool useGpuNext = false,  // Optional: gpu-next rendering mode
    Map<String, String>? httpHeaders,
    String? userAgentOverride,
  }) async {
    _logger.i('NativeMpv', '开始初始化 - videoUrl=$videoUrl, surfaceViewId=$surfaceViewId, useGpuNext=$useGpuNext');
    try {
      await dispose();
      _errorMessage = null;
      _isCompleted = false;
      _tracks = [];
      _videoWidth = 0;
      _videoHeight = 0;
      _httpHeaders = (httpHeaders != null && httpHeaders.isNotEmpty)
          ? Map<String, String>.from(httpHeaders)
          : null;
      _userAgentOverride = userAgentOverride;

      // gpu-next uses SurfaceTexture just like gpu mode.
      // SurfaceView is not used because it creates a separate window layer
      // that conflicts with Flutter overlay controls.
      // 用户自定义代理：仅 HTTP 代理且开启「代理媒体流」时透传给 mpv（mpv 不支持 SOCKS）。
      final mediaProxy = ProxyRuntime.instance.current;
      final httpProxy = mediaProxy.appliesToMedia ? mediaProxy.mpvHttpProxy : null;

      // 网络播放：把按用户设置（300MB–8GB）算出的磁盘缓存参数透传给原生 mpv。
      // 之前 Kotlin 侧硬编码 64+32MB 纯内存缓冲、忽略用户设置、也没开 cache-on-disk，
      // 这正是"视频持久化缓存好像没做"的原因。本地文件播放不需要网络缓存。
      String? videoCacheDir;
      int diskCacheForwardBytes = 0;
      int diskCacheBackBytes = 0;
      if (_isHttpUrl(videoUrl)) {
        // demuxer-max-bytes 常驻 RAM，与磁盘缓存档位解耦、按平台硬限，
        // 避免大档位把内存吃到 GB 级（移动/TV OOM）。见 getDemuxerRamBudgetBytes。
        final ramBudget = await CacheService.getDemuxerRamBudgetBytes();
        diskCacheForwardBytes = ramBudget.forward;
        diskCacheBackBytes = ramBudget.back;
        videoCacheDir = await CacheService.videoStreamCacheDirPath;
      }

      final params = <String, dynamic>{
        'videoUrl': videoUrl,
        'startPositionMs': startPosition?.inMilliseconds ?? 0,
        'hardwareDecoding': hardwareDecoding,
        'preferredSubtitleLanguage': preferredSubtitleLanguage,
        'useGpuNext': useGpuNext,
        'httpProxy': httpProxy,
        // 统一 UA：部分 CDN 拒绝 mpv 默认 UA 导致取流失败。网盘源可覆盖。
        'userAgent': _userAgentOverride ?? kAppUserAgent,
        // 逐流 HTTP 头（Cookie/Authorization/Referer）：Kotlin 侧设 mpv http-header-fields。
        'httpHeaders': _httpHeaders,
        // 为 0 / null 时 Kotlin 侧按"不启用磁盘缓存"处理（本地文件）。
        'videoCacheDir': videoCacheDir,
        'diskCacheForwardBytes': diskCacheForwardBytes,
        'diskCacheBackBytes': diskCacheBackBytes,
      };

      final result = await _channel.invokeMethod<Map<dynamic, dynamic>>('createPlayer', params);

      if (result == null) {
        throw Exception('Failed to create native mpv player: result is null');
      }

      _playerId = result['playerId'] as String?;

      // Always use SurfaceTexture rendering
      _textureId = result['textureId'] as int?;
      _useSurfaceView = false;
      _surfaceViewId = null;
      _waitingForSurfaceView = false;

      _logger.i('NativeMpv', '使用 SurfaceTexture 渲染 (textureId=$_textureId)');

      if (_playerId == null) {
        throw Exception('Invalid player creation result: missing playerId');
      }
      if (_textureId == null) {
        throw Exception('Invalid player creation result: missing textureId');
      }

      _isInitialized = true;

      // Listen for events from native
      _eventChannel = EventChannel('com.linplayer/mpv/events/$_playerId');
      _eventSub = _eventChannel!.receiveBroadcastStream().listen(
        _onEvent,
        onError: _onEventError,
      );

      // Poll position/duration at 200ms intervals
      _positionTimer = Timer.periodic(
        const Duration(milliseconds: 200),
        (_) => _pollState(),
      );

      // Re-apply shaders if super resolution was previously enabled
      if (_superResolutionEnabled) {
        _applyShaderList();
      }

      _callbacks?.onDurationChanged?.call();
      final surfaceMode = 'SurfaceTexture';
      _logger.i('NativeMpv', '初始化完成，渲染模式: $surfaceMode');
    } catch (e, stackTrace) {
      _errorMessage = e.toString();
      _isInitialized = false;
      _waitingForSurfaceView = false;
      _logger.eWithStack('NativeMpv', '初始化失败', e, stackTrace);
      _callbacks?.onError?.call();
    }
  }

  @override
  Future<void> reload(String url, {Duration? startPosition}) async {
    final id = _playerId;
    if (id == null) {
      throw StateError('原生 mpv 未就绪，无法重载');
    }
    // 复用同一 mpv 上下文/texture，仅 loadfile replace 切到重签后的新地址。
    _errorMessage = null;
    _isCompleted = false;
    await _channel.invokeMethod('reloadPlayer', {
      'playerId': id,
      'videoUrl': url,
      'startPositionMs': startPosition?.inMilliseconds ?? 0,
      // 重签后复用同一鉴权（夸克 302 过期重解析时 URL 变、Cookie 不变）。
      'httpHeaders': _httpHeaders,
      'userAgent': _userAgentOverride ?? kAppUserAgent,
    });
    _callbacks?.onDurationChanged?.call();
  }

  // ---- Playback control ----

  @override
  Future<void> play() async {
    if (_playerId == null) return;
    _logger.i('NativeMpv', 'play() called, isPlaying=$_isPlaying');
    await _channel.invokeMethod('play', {'playerId': _playerId});
    _isCompleted = false;
  }

  @override
  Future<void> pause() async {
    if (_playerId == null) return;
    _logger.i('NativeMpv', 'pause() called, isPlaying=$_isPlaying');
    await _channel.invokeMethod('pause', {'playerId': _playerId});
  }

  @override
  Future<void> seekTo(Duration position) async {
    if (_playerId == null || !_isInitialized) return;
    final clamped = Duration(
      milliseconds: max(0, min(position.inMilliseconds, _duration.inMilliseconds)),
    );
    await _channel.invokeMethod('seekTo', {
      'playerId': _playerId,
      'positionMs': clamped.inMilliseconds,
    });
    _isCompleted = false;
  }

  @override
  Future<void> setSpeed(double speed) async {
    if (_playerId == null || !_isInitialized) return;
    final clamped = speed.clamp(0.25, 8.0);
    await _channel.invokeMethod('setSpeed', {
      'playerId': _playerId,
      'speed': clamped,
    });
    _speed = clamped;
  }

  @override
  Future<void> setVolume(double volume) async {
    if (_playerId == null || !_isInitialized) return;
    final clamped = volume.clamp(0.0, 1.0);
    await _channel.invokeMethod('setVolume', {
      'playerId': _playerId,
      'volume': clamped,
    });
    _volume = clamped;
  }

  // ---- Track management ----

  @override
  Future<void> selectSubtitleTrack(String trackId) async {
    if (_playerId == null || !_isInitialized) return;
    _logger.i('NativeMpv', '选择字幕轨道: $trackId');
    await _channel.invokeMethod('selectSubtitleTrack', {
      'playerId': _playerId,
      'trackId': trackId,
    });
  }

  @override
  Future<void> deselectSubtitleTrack() async {
    if (_playerId == null || !_isInitialized) return;
    await _channel.invokeMethod('deselectSubtitleTrack', {
      'playerId': _playerId,
    });
  }

  @override
  Future<void> selectAudioTrack(String trackId) async {
    if (_playerId == null || !_isInitialized) return;
    _logger.i('NativeMpv', '选择音频轨道: $trackId');
    await _channel.invokeMethod('selectAudioTrack', {
      'playerId': _playerId,
      'trackId': trackId,
    });
  }

  @override
  Future<void> loadLibassSubtitle(String path) async {
    if (_playerId == null || !_isInitialized) return;
    _logger.i('NativeMpv', '加载字幕: $path');
    await _channel.invokeMethod('loadSubtitle', {
      'playerId': _playerId,
      'subtitleUrl': path,
      'subtitleLanguage': 'und',
    });
  }

  @override
  Future<void> loadLibassSubtitleMemory(Uint8List data, {String codec = 'ass'}) async {
    if (_playerId == null || !_isInitialized) return;
    try {
      // Write subtitle data to a temp file, then load via sub-add
      final ext = codec == 'ass' ? 'ass' : codec == 'ssa' ? 'ssa' : 'srt';
      final cacheDir = await _getCacheDir();
      if (cacheDir == null) {
        _logger.e('NativeMpv', '无法获取缓存目录，跳过从内存加载字幕');
        return;
      }
      final tempPath = '$cacheDir/temp_sub_${DateTime.now().millisecondsSinceEpoch}.$ext';
      await _channel.invokeMethod('writeFile', {
        'playerId': _playerId,
        'path': tempPath,
        'data': data,
      });
      await loadLibassSubtitle(tempPath);
    } catch (e) {
      _logger.e('NativeMpv', '从内存加载字幕失败: $e');
    }
  }

  Future<String?> _getCacheDir() async {
    try {
      return await _channel.invokeMethod<String>('getCacheDir', {
        'playerId': _playerId,
      });
    } catch (_) {
      return null;
    }
  }

  // ---- Secondary subtitles (mpv supports this natively) ----

  @override
  Future<void> loadSecondarySubtitle(String path) async {
    if (_playerId == null || !_isInitialized) return;
    _logger.i('NativeMpv', '加载次字幕: $path');
    await _channel.invokeMethod('command', {
      'playerId': _playerId,
      'args': ['sub-add', path, 'auto', 'secondary-sub', 'und'],
    });
  }

  @override
  Future<void> selectSecondarySubtitleTrack(String trackId) async {
    if (_playerId == null || !_isInitialized) return;
    await _channel.invokeMethod('setProperty', {
      'playerId': _playerId,
      'name': 'secondary-sid',
      'value': trackId,
    });
  }

  @override
  Future<void> deselectSecondarySubtitle() async {
    if (_playerId == null || !_isInitialized) return;
    await _channel.invokeMethod('setProperty', {
      'playerId': _playerId,
      'name': 'secondary-sid',
      'value': 'no',
    });
  }

  // ---- Subtitle settings ----

  @override
  Future<void> setSubtitleDelay(double seconds) async {
    if (_playerId == null) return;
    await _channel.invokeMethod('setSubtitleDelay', {
      'playerId': _playerId,
      'seconds': seconds,
    });
  }

  @override
  Future<void> setAudioDelay(double seconds) async {
    if (_playerId == null) return;
    await _channel.invokeMethod('setAudioDelay', {
      'playerId': _playerId,
      'seconds': seconds,
    });
  }

  @override
  Future<void> setSubtitleFont(String fontName) async {
    if (_playerId == null) return;
    // '默认'/空 不是真实字体名，若强行写入 mpv 的 sub-font，libass 找不到该字体，
    // 在没有有效回退时会导致整段文本字幕不渲染。跳过设置，保留 libass 默认字体
    // （配合 init 里设置的 sub-fonts-dir=/system/fonts 即可正常显示中文）。
    if (fontName.isEmpty || fontName == '默认') return;
    await _channel.invokeMethod('setSubtitleFont', {
      'playerId': _playerId,
      'fontName': fontName,
    });
  }

  @override
  Future<void> setSubtitleSize(double size) async {
    if (_playerId == null) return;
    await _channel.invokeMethod('setSubtitleSize', {
      'playerId': _playerId,
      'size': size,
    });
  }

  @override
  Future<void> setSubtitlePosition(double position) async {
    if (_playerId == null) return;
    await _channel.invokeMethod('setSubtitlePosition', {
      'playerId': _playerId,
      'position': position,
    });
  }

  @override
  Future<void> setSubtitleBackground(bool enabled) async {
    if (_playerId == null) return;
    await _channel.invokeMethod('setSubtitleBackground', {
      'playerId': _playerId,
      'enabled': enabled,
    });
  }

  @override
  Future<void> setSubtitleBlendMode(String mode) async {
    // 安卓原生 mpv 暂未透传该实验项（PGS 闪现排查目前针对桌面）；空操作。
  }

  // ---- Aspect ratio ----

  @override
  Future<void> setAspectRatio(String ratio) async {
    _aspectRatio = ratio;
    if (_playerId == null) return;
    await _channel.invokeMethod('setAspectRatio', {
      'playerId': _playerId,
      'ratio': ratio,
    });
    _callbacks?.onPositionChanged?.call();
  }

  // ---- Super resolution (Anime4K shaders) ----

  @override
  Future<void> applySuperResolution(bool enable) async {
    if (_playerId == null || !_isInitialized) return;
    _superResolutionEnabled = enable;
    if (enable) {
      _applyShaderList();
    } else {
      _clearShaders();
    }
  }

  @override
  Future<void> applySuperResolutionLevel(String level) async {
    _superResolutionLevel = level;
    if (_superResolutionEnabled) {
      _applyShaderList();
    }
  }

  void _applyShaderList() {
    if (_playerId == null) return;
    // Shader paths are set from the MpvPlayerAdapter's asset loading logic.
    // For now, send the command to clear and re-add shaders.
    _clearShaders();
    for (final shader in _currentShaders) {
      _channel.invokeMethod('command', {
        'playerId': _playerId,
        'args': ['change-list', 'glsl-shaders', 'append', shader],
      });
    }
  }

  void _clearShaders() {
    if (_playerId == null) return;
    _channel.invokeMethod('command', {
      'playerId': _playerId,
      'args': ['change-list', 'glsl-shaders', 'clr', ''],
    });
  }

  void setShaderPaths(List<String> paths) {
    _currentShaders = paths;
    if (_superResolutionEnabled) {
      _applyShaderList();
    }
  }

  // ---- Screenshot ----

  @override
  Future<Uint8List?> screenshot() async {
    if (_playerId == null) return null;
    try {
      return await _channel.invokeMethod<Uint8List>('screenshot', {
        'playerId': _playerId,
      });
    } catch (_) {
      return null;
    }
  }

  // ---- Playback stats ----

  @override
  Future<Map<String, String>> getPlaybackStats() async {
    if (_playerId == null || !_isInitialized) return {};
    try {
      final stats = <String, String>{};
      final properties = {
        'video-bitrate': 'videoBitrate',
        'audio-bitrate': 'audioBitrate',
        'video-params/w': 'width',
        'video-params/h': 'height',
        'estimated-vf-fps': 'fps',
        'decoder-frame-drop-count': 'decoderDropFrames',
        'vo-drop-frame-count': 'voDropFrames',
        'hwdec-current': 'hwdec',
        'video-codec': 'videoCodec',
        'audio-codec': 'audioCodec',
        'demuxer-cache-duration': 'cacheDuration',
        'demuxer-cache-state/fw-bytes': 'cacheForwardBytes',
      };

      for (final entry in properties.entries) {
        try {
          final value = await _channel.invokeMethod<String>('getProperty', {
            'playerId': _playerId,
            'name': entry.key,
          });
          if (value != null && value.isNotEmpty && value != 'unknown') {
            stats[entry.key] = value;
          }
        } catch (_) {}
      }
      return stats;
    } catch (_) {
      return {};
    }
  }

  // ---- 流式字幕翻译支持（原生 libmpv：sub-step 预读 + sub-text 取词）----

  /// 原生 mpv 属性读取（供 sub-step 预读读取 sub-text / sub-delay 等）。
  Future<String?> mpvGetProperty(String name) async {
    if (_playerId == null) return null;
    try {
      return await _channel.invokeMethod<String>('getProperty', {
        'playerId': _playerId,
        'name': name,
      });
    } catch (_) {
      return null;
    }
  }

  /// 原生 mpv 属性设置（供隐藏原文字幕 sub-visibility、还原 sub-delay 等）。
  Future<void> mpvSetProperty(String name, String value) async {
    if (_playerId == null) return;
    try {
      await _channel.invokeMethod('setProperty', {
        'playerId': _playerId,
        'name': name,
        'value': value,
      });
    } catch (_) {}
  }

  /// 原生 mpv 命令（供 sub-step 从已缓冲区向前偷看 cue 文本）。
  Future<void> mpvCommand(List<String> args) async {
    if (_playerId == null) return;
    try {
      await _channel.invokeMethod('command', {
        'playerId': _playerId,
        'args': args,
      });
    } catch (_) {}
  }

  /// 流式翻译期间隐藏 mpv 自带字幕（原文/译文统一走叠加层按排版显示）。
  void setNativeSubtitleHidden(bool hidden) {
    unawaited(mpvSetProperty('sub-visibility', hidden ? 'no' : 'yes'));
  }

  /// 开启/关闭 sub-text 取词轮询（仅流式翻译进行时启用）。
  void setSubtitleCueObservation(bool enabled) {
    _emitSubtitleCue = enabled;
    if (!enabled) _lastSubText = '';
  }

  // ---- Video rendering ----

  /// Build the video widget.
  ///
  /// Always uses Texture widget (SurfaceTexture backend) for both gpu and gpu-next modes.
  /// SurfaceView is not used because it creates a separate window layer that conflicts
  /// with Flutter's overlay controls.
  @override
  Widget buildVideo() {
    if (_textureId != null) {
      return Texture(textureId: _textureId!);
    }
    return const Center(child: CircularProgressIndicator());
  }

  // ---- Event handling ----

  void _onEvent(dynamic event) {
    if (event is! Map) return;
    final type = event['type'] as String?;
    // mpv 原生日志单独处理：不打 "Event: log" 噪声，直接按级别落 App 日志。
    if (type == 'log') {
      _logMpvMessage(event['value']);
      return;
    }
    _logger.d('NativeMpv', 'Event: $type');
    switch (type) {
      case 'playing':
        _isPlaying = event['value'] as bool? ?? false;
        _logger.i('NativeMpv', 'playing event: $_isPlaying');
        _callbacks?.onPlayingStateChanged?.call();
        break;
      case 'buffering':
        _isBuffering = event['value'] as bool? ?? false;
        _callbacks?.onBufferingStateChanged?.call();
        break;
      case 'completed':
        _isCompleted = true;
        _callbacks?.onCompleted?.call();
        break;
      case 'error':
        _errorMessage = event['value'] as String?;
        _callbacks?.onError?.call();
        break;
      case 'duration':
        final ms = (event['value'] as num?)?.toInt() ?? 0;
        if (ms > 0) {
          _duration = Duration(milliseconds: ms);
          _callbacks?.onDurationChanged?.call();
        }
        break;
      case 'timePos':
        final ms = (event['value'] as num?)?.toInt() ?? 0;
        _position = Duration(milliseconds: ms);
        _callbacks?.onPositionChanged?.call();
        break;
      case 'speed':
        _speed = (event['value'] as num?)?.toDouble() ?? 1.0;
        break;
      case 'volume':
        _volume = (event['value'] as num?)?.toDouble() ?? 1.0;
        break;
      case 'videoSize':
        final value = event['value'] as Map?;
        if (value != null) {
          final width = (value['width'] as num?)?.toInt() ?? 0;
          final height = (value['height'] as num?)?.toInt() ?? 0;
          if (width > 0 && height > 0) {
            _videoWidth = width;
            _videoHeight = height;
            _logger.i('NativeMpv', '视频尺寸更新: ${width}x$height');
            _callbacks?.onPositionChanged?.call();
          }
        }
        break;
      case 'tracksChanged':
        final tracksList = event['value'] as List<dynamic>?;
        if (tracksList != null) {
          _tracks = tracksList.map((e) {
            final map = e as Map<dynamic, dynamic>;
            return map.map((k, v) => MapEntry(k.toString(), v));
          }).toList();
          _logger.d('NativeMpv', '轨道变更: ${_tracks.length} 条轨道');
        }
        break;
    }
  }

  /// 把原生 mpv 转发上来的 warn/error/fatal 日志写入 App 日志文件，
  /// 以便原生崩溃后用户导出的日志里能看到 mpv 的「最后遗言」。
  /// mpv 级别：FATAL=10 ERROR=20 WARN=30（数字越小越严重）。
  void _logMpvMessage(dynamic value) {
    if (value is! Map) return;
    final level = (value['level'] as num?)?.toInt() ?? 40;
    final prefix = value['prefix']?.toString() ?? 'mpv';
    final text = value['text']?.toString() ?? '';
    if (text.isEmpty) return;
    final message = 'mpv/$prefix: $text';
    if (level <= 20) {
      _logger.e('NativeMpv', message);
    } else if (level <= 30) {
      _logger.w('NativeMpv', message);
    } else {
      _logger.i('NativeMpv', message);
    }
  }

  void _onEventError(Object error) {
    _errorMessage = error.toString();
    _logger.e('NativeMpv', '事件通道错误: $error');
    _callbacks?.onError?.call();
  }

  Future<void> _pollState() async {
    if (_playerId == null || !_isInitialized) return;
    try {
      final pos = await _channel.invokeMethod<int>('getPosition', {'playerId': _playerId});
      if (pos != null) {
        _position = Duration(milliseconds: pos);
        _callbacks?.onPositionChanged?.call();
      }
      final dur = await _channel.invokeMethod<int>('getDuration', {'playerId': _playerId});
      if (dur != null && dur > 0) {
        _duration = Duration(milliseconds: dur);
      }
      // 轮询播放状态作为 EventChannel 的兜底，确保 UI 状态同步
      final pauseStr = await _channel.invokeMethod<String>('getProperty', {
        'playerId': _playerId,
        'name': 'pause',
      });
      if (pauseStr != null) {
        final playing = pauseStr == 'no';
        if (_isPlaying != playing) {
          _isPlaying = playing;
          _logger.d('NativeMpv', '播放状态变更: playing=$playing');
          _callbacks?.onPlayingStateChanged?.call();
        }
      }
      // 流式翻译取词：仅翻译进行时轮询当前字幕原文，变化即抛给取词器。
      if (_emitSubtitleCue) {
        final sub = await _channel.invokeMethod<String>('getProperty', {
          'playerId': _playerId,
          'name': 'sub-text',
        });
        final text = sub ?? '';
        if (text != _lastSubText) {
          _lastSubText = text;
          _callbacks?.onSubtitleCue?.call(text, null, null);
        }
      }
    } catch (_) {}
  }

  // ---- Dispose ----

  @override
  Future<void> dispose() async {
    _logger.i('NativeMpv', '释放资源');
    _positionTimer?.cancel();
    _positionTimer = null;
    _eventSub?.cancel();
    _eventSub = null;
    _eventChannel = null;
    if (_playerId != null) {
      try {
        await _channel.invokeMethod('disposePlayer', {'playerId': _playerId});
      } catch (_) {}
      _playerId = null;
    }
    _videoWidth = 0;
    _videoHeight = 0;
    _textureId = null;
    _surfaceViewId = null;
    _useSurfaceView = false;
    _isInitialized = false;
    _isPlaying = false;
    _isBuffering = false;
    _isCompleted = false;
    _position = Duration.zero;
    _duration = Duration.zero;
    _tracks = [];
    _currentShaders = [];
    _logger.i('NativeMpv', '资源已释放');
  }
}
