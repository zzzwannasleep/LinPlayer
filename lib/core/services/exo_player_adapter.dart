import 'dart:async';
import 'dart:convert';
import 'dart:math' show max, min;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'player_adapter.dart';
import 'app_logger.dart';
import '../app_identity.dart';

class ExoPlayerAdapter implements PlayerAdapter {
  static const _channel = MethodChannel('com.linplayer/exoplayer');
  static final _logger = AppLogger();

  String? _playerId;
  int? _textureId;
  // 逐流取流鉴权（网盘/聚合源直链）：Kotlin 侧设到 ExoPlayer DataSource headers。
  Map<String, String>? _httpHeaders;
  String? _userAgentOverride;
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

  List<Map<dynamic, dynamic>> _tracks = [];
  String _subtitleText = '';
  double _subtitleSize = 0.5;
  double _subtitlePosition = 0.0;
  bool _subtitleBackground = false;
  String _subtitleFont = '默认';
  bool _isBitmapSubtitle = false;
  // 流式翻译期间隐藏自带字幕渲染：原文/译文统一由叠加层按排版显示，
  // 但原文 cue 仍照常抛给取词器供翻译。
  bool _subtitlesHidden = false;

  PlayerStateCallbacks? _callbacks;
  Timer? _positionTimer;

  final ValueNotifier<String> subtitleNotifier = ValueNotifier('');
  // 位图字幕（PGS / libass 渲染的 ASS）当前帧的全部分片，各自带占帧比例的
  // left/top/width/height，便于按视频内容区精确定位、原比例绘制。
  final ValueNotifier<List<BitmapSubtitleCue>> bitmapNotifier =
      ValueNotifier(const []);
  final ValueNotifier<int> _subtitleSettingsVersion = ValueNotifier(0);

  int _videoWidth = 0;
  int _videoHeight = 0;
  String _aspectRatio = '自动';
  bool _enableAssSupport = false;

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
  bool get libassReady => _enableAssSupport;
  double? get videoAspectRatio {
    if (_videoWidth <= 0 || _videoHeight <= 0) return null;
    return _videoWidth / _videoHeight;
  }
  String get aspectRatioMode => _aspectRatio;
  @override
  int? get textureId => _textureId;
  @override
  List<Map<String, dynamic>> getTracksInfo() =>
      _tracks.map((e) => e.map((k, v) => MapEntry(k.toString(), v))).toList();
  @override
  void setCallbacks(PlayerStateCallbacks callbacks) {
    _callbacks = callbacks;
  }

  @override
  void setSubtitleSelectionHint(String? codec, {String? title}) {
    // ExoPlayer currently selects subtitle tracks directly by track id/index,
    // so the desktop hint is not needed here.
  }

  @override
  Future<void> initialize({
    required String videoUrl,
    Duration? startPosition,
    bool dolbyVisionFix = false,
    bool useLibass = false,
    bool hardwareDecoding = true,
    String? preferredSubtitleLanguage,
    int? surfaceViewId,  // Not used by ExoPlayer, only for native mpv
    bool useGpuNext = false,  // Not used by ExoPlayer, only for native mpv
    Map<String, String>? httpHeaders,
    String? userAgentOverride,
  }) async {
    _logger.i('ExoPlayer', '开始初始化 - videoUrl=$videoUrl');
    try {
      await dispose();
      _errorMessage = null;
      _isCompleted = false;
      _tracks = [];
      _subtitleText = '';
      _videoWidth = 0;
      _videoHeight = 0;
      _enableAssSupport = useLibass;
      _httpHeaders = (httpHeaders != null && httpHeaders.isNotEmpty)
          ? Map<String, String>.from(httpHeaders)
          : null;
      _userAgentOverride = userAgentOverride;

      final result = await _channel.invokeMethod<Map<dynamic, dynamic>>('createPlayer', {
        'videoUrl': videoUrl,
        'startPositionMs': startPosition?.inMilliseconds ?? 0,
        'dolbyVisionFix': dolbyVisionFix,
        'preferredSubtitleLanguage': preferredSubtitleLanguage,
        'enableAssSupport': useLibass,
        'hardwareDecoding': hardwareDecoding,
        // 统一 UA：部分 CDN 拒绝默认 UA 导致取流失败。网盘源可覆盖。
        'userAgent': _userAgentOverride ?? kAppUserAgent,
        // 逐流 HTTP 头（Cookie/Authorization/Referer）：Kotlin 侧设到 DataSource。
        'httpHeaders': _httpHeaders,
      });

      if (result == null) {
        throw Exception('Failed to create ExoPlayer: result is null');
      }

      _playerId = result['playerId'] as String?;
      _textureId = result['textureId'] as int?;

      if (_playerId == null || _textureId == null) {
        throw Exception('Invalid player creation result');
      }

      _isInitialized = true;

      _eventChannel = EventChannel('com.linplayer/exoplayer/events/$_playerId');
      _eventSub = _eventChannel!.receiveBroadcastStream().listen(
        _onEvent,
        onError: _onEventError,
      );

      _positionTimer = Timer.periodic(
        const Duration(milliseconds: 200),
        (_) => _pollState(),
      );

      _callbacks?.onDurationChanged?.call();
      _logger.i('ExoPlayer', '初始化完成');
    } catch (e, stackTrace) {
      _errorMessage = e.toString();
      _isInitialized = false;
      _logger.eWithStack('ExoPlayer', '初始化失败', e, stackTrace);
      _callbacks?.onError?.call();
    }
  }

  @override
  Future<void> reload(String url, {Duration? startPosition}) async {
    // ExoPlayer 暂未实现原生原地重载：抛出由 VideoPlayerService 捕获，
    // 降级到「整体重建 + 重解析后的新地址」，仍能重签 302、续播到当前位置，
    // 只是会有一次重建闪屏（ExoPlayer 自身亦有内置 load error 重试兜底）。
    throw UnsupportedError('ExoPlayer 不支持原地重载，改走整体重建');
  }

  @override
  Future<void> selectSubtitleTrack(String trackId) async {
    if (_playerId == null || !_isInitialized) return;
    _logger.i('ExoPlayer', '选择字幕轨道: $trackId');
    try {
      final allTracks = _tracks;
      Map<dynamic, dynamic>? target;

      for (final t in allTracks) {
        if (t['id']?.toString() == trackId) { target = t; break; }
      }
      if (target == null) {
        for (final t in allTracks) {
          final type = t['type']?.toString();
          if ((type == 'text' || type == 'bitmap') && t['trackIndex']?.toString() == trackId) {
            target = t; break;
          }
        }
      }

      if (target != null) {
        final groupIndex = target['groupIndex'] ?? 0;
        final trackIndex = target['trackIndex'] ?? 0;
        final nativeTrackType = target['trackType'] ?? 3;
        final isBitmap = target['isBitmap'] == true || target['type'] == 'bitmap';

        _isBitmapSubtitle = isBitmap;

        _logger.i('ExoPlayer', '调用selectTrack: group=$groupIndex, track=$trackIndex, nativeType=$nativeTrackType, isBitmap=$isBitmap');
        await _channel.invokeMethod('selectTrack', {
          'playerId': _playerId,
          'groupIndex': groupIndex,
          'trackIndex': trackIndex,
          'trackType': nativeTrackType,
        });
      } else {
        _logger.w('ExoPlayer', '未找到字幕轨道: $trackId, 可用: ${allTracks.where((t) => t['type'] == 'text' || t['type'] == 'bitmap').map((t) => t['id']).toList()}');
      }
    } catch (e, stackTrace) {
      _logger.eWithStack('ExoPlayer', '选择字幕轨道失败', e, stackTrace);
    }
  }

  @override
  Future<void> deselectSubtitleTrack() async {
    if (_playerId == null || !_isInitialized) return;
    try {
      await _channel.invokeMethod('deselectSubtitleTrack', {
        'playerId': _playerId,
      });
      _subtitleText = '';
      subtitleNotifier.value = '';
      bitmapNotifier.value = const [];
      _isBitmapSubtitle = false;
    } catch (e, stackTrace) {
      _logger.eWithStack('ExoPlayer', '关闭字幕失败', e, stackTrace);
    }
  }

  /// 流式翻译期间隐藏 ExoPlayer 自带字幕渲染（原文/译文改由叠加层显示）。
  /// 不动原生轨道选择，停止时调用 setNativeSubtitleHidden(false) 即恢复。
  void setNativeSubtitleHidden(bool hidden) {
    if (_subtitlesHidden == hidden) return;
    _subtitlesHidden = hidden;
    if (hidden) {
      subtitleNotifier.value = '';
      bitmapNotifier.value = const [];
    } else {
      subtitleNotifier.value = _subtitleText;
    }
  }

  @override
  Future<void> selectAudioTrack(String trackId) async {
    if (_playerId == null || !_isInitialized) return;
    try {
      final target = _tracks.where((t) =>
          (t['type'] == 'audio') &&
          (t['id']?.toString() == trackId || t['trackIndex']?.toString() == trackId)).firstOrNull;
      if (target != null) {
        await _channel.invokeMethod('selectTrack', {
          'playerId': _playerId,
          'groupIndex': target['groupIndex'] ?? 0,
          'trackIndex': target['trackIndex'] ?? 0,
          'trackType': 1,
        });
      }
    } catch (e, stackTrace) {
      _logger.eWithStack('ExoPlayer', '选择音频轨道失败', e, stackTrace);
    }
  }

  @override
  Future<void> loadSecondarySubtitle(String path) async {
    _logger.w('ExoPlayer', '次字幕暂不支持，请使用 MPV 内核');
  }

  @override
  Future<void> selectSecondarySubtitleTrack(String trackId) async {
    _logger.w('ExoPlayer', '次字幕暂不支持，请使用 MPV 内核');
  }

  @override
  Future<void> deselectSecondarySubtitle() async {
    _logger.w('ExoPlayer', '次字幕暂不支持，请使用 MPV 内核');
  }

  @override
  Future<void> loadLibassSubtitle(String path) async {
    if (_playerId == null || !_isInitialized) return;
    final mimeType = _detectSubtitleMimeType(path);
    final ext = _extractExtension(path);
    final isAss = ext == 'ass' || ext == 'ssa';
    final isPgs = ext == 'pgs' || ext == 'sup';
    _logger.i('ExoPlayer', '加载字幕: $path (mime=$mimeType, isAss=$isAss, isPgs=$isPgs)');

    _isBitmapSubtitle = isPgs;

    if (isPgs) {
      _logger.w('ExoPlayer', 'PGS/SUP图形字幕仍依赖设备侧 Media3 解析，如无法显示请切换MPV内核');
    } else if (isAss) {
      emitEvent('subtitleType', 'ass');
    }

    try {
      await _channel.invokeMethod('loadSubtitle', {
        'playerId': _playerId,
        'subtitleUrl': path,
        'subtitleMimeType': mimeType,
        'subtitleLanguage': 'und',
      });
    } catch (e, stackTrace) {
      _logger.eWithStack('ExoPlayer', '加载字幕失败', e, stackTrace);
    }
  }

  String _extractExtension(String path) {
    var clean = path;
    final qIndex = clean.indexOf('?');
    if (qIndex >= 0) clean = clean.substring(0, qIndex);
    final hIndex = clean.indexOf('#');
    if (hIndex >= 0) clean = clean.substring(0, hIndex);
    final dotIndex = clean.lastIndexOf('.');
    if (dotIndex < 0 || dotIndex < clean.lastIndexOf('/')) return '';
    return clean.substring(dotIndex + 1).toLowerCase();
  }

  void emitEvent(String type, dynamic value) {
    _logger.d('ExoPlayer', '内部事件: type=$type, value=$value');
  }

  @override
  Future<void> loadLibassSubtitleMemory(Uint8List data, {String codec = 'ass'}) async {
    _logger.w('ExoPlayer', 'ExoPlayer 暂不支持从内存直接加载 ASS 字幕，请先写入文件后再加载');
  }

  String? _detectSubtitleMimeType(String path) {
    var clean = path;
    final qIndex = clean.indexOf('?');
    if (qIndex >= 0) clean = clean.substring(0, qIndex);
    final hIndex = clean.indexOf('#');
    if (hIndex >= 0) clean = clean.substring(0, hIndex);
    final lower = clean.toLowerCase();
    if (lower.endsWith('.srt') || lower.endsWith('.subrip')) return 'application/x-subrip';
    if (lower.endsWith('.ass') || lower.endsWith('.ssa')) return 'text/x-ssa';
    if (lower.endsWith('.vtt') || lower.endsWith('.webvtt')) return 'text/vtt';
    if (lower.endsWith('.ttml') || lower.endsWith('.dfxp')) return 'application/ttml+xml';
    if (lower.endsWith('.pgs') || lower.endsWith('.sup')) return 'application/pgs';
    if (lower.endsWith('.vob')) return 'application/vobsub';
    return 'application/x-subrip';
  }

  void _onEvent(dynamic event) {
    if (event is! Map) return;
    final type = event['type'] as String?;
    switch (type) {
      case 'playing':
        _isPlaying = event['value'] as bool? ?? false;
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
        _duration = Duration(milliseconds: (event['value'] as num).toInt());
        _callbacks?.onDurationChanged?.call();
        break;
      case 'videoSize':
        final value = event['value'] as Map?;
        if (value != null) {
          final width = (value['width'] as num?)?.toInt() ?? 0;
          final height = (value['height'] as num?)?.toInt() ?? 0;
          if (width > 0 && height > 0) {
            _videoWidth = width;
            _videoHeight = height;
            _logger.i('ExoPlayer', '视频尺寸更新: ${width}x$height');
            _callbacks?.onPositionChanged?.call();
          }
        }
        break;
      case 'tracksChanged':
        final tracksList = event['value'] as List<dynamic>?;
        if (tracksList != null) {
          _tracks = tracksList.cast<Map<dynamic, dynamic>>();
          _logger.d('ExoPlayer', '轨道变更: ${_tracks.length} 条轨道');
        }
        break;
      case 'subtitle':
        _subtitleText = event['value'] as String? ?? '';
        // 始终把原文 cue 抛给流式翻译取词器（即便隐藏了自带字幕渲染）。
        _callbacks?.onSubtitleCue?.call(_subtitleText, null, null);
        subtitleNotifier.value = _subtitlesHidden ? '' : _subtitleText;
        bitmapNotifier.value = const [];
        if (_subtitleText.isEmpty) {
          _isBitmapSubtitle = false;
        }
        break;
      case 'subtitleBitmap':
        final data = event['value'] as Map?;
        if (data != null) {
          final images = data['images'] as List?;
          final positions = data['positions'] as List?;
          if (images != null && images.isNotEmpty) {
            // 渲染**所有**分片（ASS 一帧常有多段文字/字幕特效），按下标取各自几何。
            final cues = <BitmapSubtitleCue>[];
            for (var i = 0; i < images.length; i++) {
              try {
                final bytes = base64Decode(images[i] as String);
                final pos = (positions != null && i < positions.length)
                    ? positions[i] as Map?
                    : null;
                cues.add(BitmapSubtitleCue(
                  bytes: bytes,
                  left: (pos?['left'] as num?)?.toDouble(),
                  top: (pos?['top'] as num?)?.toDouble(),
                  width: (pos?['width'] as num?)?.toDouble(),
                  height: (pos?['height'] as num?)?.toDouble(),
                ));
              } catch (_) {}
            }
            bitmapNotifier.value = cues;
            _isBitmapSubtitle = true;
          } else {
            bitmapNotifier.value = const [];
          }
          _subtitleText = data['text'] as String? ?? '';
          subtitleNotifier.value = _subtitlesHidden ? '' : _subtitleText;
        }
        break;
      case 'subtitleType':
        final subType = event['value'] as String?;
        _logger.d('ExoPlayer', '字幕类型: $subType');
        if (subType == 'bitmap') {
          _isBitmapSubtitle = true;
        } else {
          _isBitmapSubtitle = false;
        }
        break;
    }
  }

  void _onEventError(Object error) {
    _errorMessage = error.toString();
    _logger.e('ExoPlayer', '事件通道错误: $error');
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
    } catch (_) {}
  }

  @override
  Future<void> play() async {
    if (_playerId == null) return;
    await _channel.invokeMethod('play', {'playerId': _playerId});
    _isCompleted = false;
  }

  @override
  Future<void> pause() async {
    if (_playerId == null) return;
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
    final clamped = speed.clamp(0.25, 4.0);
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
    _subtitleFont = fontName;
    _subtitleSettingsVersion.value++;
    if (_playerId == null) return;
    await _channel.invokeMethod('setSubtitleFont', {
      'playerId': _playerId,
      'fontName': fontName,
    });
  }

  @override
  Future<void> setSubtitleSize(double size) async {
    _subtitleSize = size;
    _subtitleSettingsVersion.value++;
    if (_playerId == null) return;
    await _channel.invokeMethod('setSubtitleSize', {
      'playerId': _playerId,
      'size': size,
    });
  }

  @override
  Future<void> setSubtitlePosition(double position) async {
    _subtitlePosition = position;
    _subtitleSettingsVersion.value++;
    if (_playerId == null) return;
    await _channel.invokeMethod('setSubtitlePosition', {
      'playerId': _playerId,
      'position': position,
    });
  }

  @override
  Future<void> setSubtitleBlendMode(String mode) async {
    // ExoPlayer 无 mpv blend-subtitles 概念，空操作。
  }

  @override
  Future<void> setSubtitleBackground(bool enabled) async {
    _subtitleBackground = enabled;
    _subtitleSettingsVersion.value++;
    if (_playerId == null) return;
    await _channel.invokeMethod('setSubtitleBackground', {
      'playerId': _playerId,
      'enabled': enabled,
    });
  }

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

  /// 绘制当前帧全部位图字幕分片。
  /// - 有完整 left/top/width/height（libass 渲染的 ASS）：按占帧比例 1:1 定位、
  ///   `BoxFit.fill` 还原 libass 的字号/位置/样式，逐片叠加。
  /// - 仅 left/top/width（部分图形字幕）：按宽度缩放、高度自适应。
  /// - 无几何信息（如部分 PGS）：退化为底部居中。
  Widget _buildBitmapCues(List<BitmapSubtitleCue> cues, Size videoSize) {
    final children = <Widget>[];
    for (final cue in cues) {
      if (cue.hasFullGeometry) {
        children.add(Positioned(
          left: cue.left!.clamp(0.0, 1.0) * videoSize.width,
          top: cue.top!.clamp(0.0, 1.0) * videoSize.height,
          width: cue.width!.clamp(0.0, 1.0) * videoSize.width,
          height: cue.height!.clamp(0.0, 1.0) * videoSize.height,
          child: Image.memory(
            cue.bytes,
            fit: BoxFit.fill,
            gaplessPlayback: true,
            filterQuality: FilterQuality.medium,
          ),
        ));
      } else if (cue.hasLegacyGeometry) {
        children.add(Positioned(
          left: cue.left!.clamp(0.0, 1.0) * videoSize.width,
          top: cue.top!.clamp(0.0, 1.0) * videoSize.height,
          width: cue.width!.clamp(0.0, 1.0) * videoSize.width,
          child: Image.memory(
            cue.bytes,
            fit: BoxFit.fitWidth,
            gaplessPlayback: true,
            filterQuality: FilterQuality.medium,
          ),
        ));
      } else {
        children.add(Positioned(
          left: 0,
          right: 0,
          bottom: 20.0,
          child: Center(
            child: ConstrainedBox(
              constraints: BoxConstraints(
                maxWidth: videoSize.width - 16,
                maxHeight: videoSize.height * 0.35,
              ),
              child: Image.memory(
                cue.bytes,
                fit: BoxFit.contain,
                gaplessPlayback: true,
                filterQuality: FilterQuality.medium,
              ),
            ),
          ),
        ));
      }
    }
    if (children.isEmpty) return const SizedBox.shrink();
    return Stack(fit: StackFit.expand, children: children);
  }

  @override
  Widget buildVideo() {
    if (_textureId != null) {
      return LayoutBuilder(
        builder: (context, constraints) {
          final videoSize = Size(constraints.maxWidth, constraints.maxHeight);
          return Stack(
            fit: StackFit.expand,
            children: [
          Texture(textureId: _textureId!),
          ValueListenableBuilder<int>(
            valueListenable: _subtitleSettingsVersion,
            builder: (context, _, __) {
              return ValueListenableBuilder<List<BitmapSubtitleCue>>(
                valueListenable: bitmapNotifier,
                builder: (context, cues, _) {
                  if (cues.isNotEmpty) {
                    return _buildBitmapCues(cues, videoSize);
                  }
                  return ValueListenableBuilder<String>(
                    valueListenable: subtitleNotifier,
                    builder: (context, text, _) {
                      // 位图/ libass 模式下不再回退到「扒标签的纯文本」渲染，
                      // 避免与位图字幕重叠或显示错位的降级文本。
                      if (_isBitmapSubtitle) return const SizedBox.shrink();
                      if (text.isEmpty) return const SizedBox.shrink();
                      final cleanText = _stripAssTags(text);
                      if (cleanText.isEmpty) return const SizedBox.shrink();
                      final fontSize = 16.0 + (_subtitleSize * 10.0);
                      return Positioned(
                        left: 16,
                        right: 16,
                        bottom: 20.0 + (_subtitlePosition * 180.0),
                        child: Center(
                          child: Container(
                            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                            decoration: _subtitleBackground
                                ? BoxDecoration(
                                    color: Colors.black.withValues(alpha: 0.7),
                                    borderRadius: BorderRadius.circular(4),
                                  )
                                : null,
                            child: Text(
                              cleanText,
                              textAlign: TextAlign.center,
                              style: TextStyle(
                                color: Colors.white,
                                fontSize: fontSize,
                                fontFamily: (_subtitleFont.isNotEmpty && _subtitleFont != '默认') ? _subtitleFont : null,
                                height: 1.4,
                                decoration: TextDecoration.none,
                                shadows: _subtitleBackground
                                    ? []
                                    : [
                                        Shadow(
                                          offset: const Offset(1, 1),
                                          blurRadius: 2,
                                          color: Colors.black.withValues(alpha: 0.8),
                                        ),
                                        Shadow(
                                          offset: const Offset(-1, -1),
                                          blurRadius: 2,
                                          color: Colors.black.withValues(alpha: 0.8),
                                        ),
                                        Shadow(
                                          offset: const Offset(1, -1),
                                          blurRadius: 2,
                                          color: Colors.black.withValues(alpha: 0.8),
                                        ),
                                        Shadow(
                                          offset: const Offset(-1, 1),
                                          blurRadius: 2,
                                          color: Colors.black.withValues(alpha: 0.8),
                                        ),
                                      ],
                              ),
                            ),
                          ),
                        ),
                      );
                    },
                  );
                },
              );
            },
          ),
            ],
          );
        },
      );
    }
    return const Center(child: CircularProgressIndicator());
  }

  Widget buildVideoContent() {
    if (_textureId == null) {
      return const Center(child: CircularProgressIndicator());
    }
    return Texture(textureId: _textureId!);
  }

  static String _stripAssTags(String text) {
    var result = text;
    result = result.replaceAll(RegExp(r'\{\\*[^}]*\}'), '');
    result = result.replaceAll(RegExp(
      r'\\(?:'
      r'an\d+|pos\([^)]*\)|fad\([^)]*\)|fade\([^)]*\)|move\([^)]*\)|'
      r't\([^)]*\)|t\[[^\]]*\]\([^)]*\)|'
      r'fn[^\\}]*|fs\d+|fsp-?\d+(?:\.\d+)?|fscx\d+(?:\.\d+)?|fscy\d+(?:\.\d+)?|'
      r'b\d+|i\d+|u\d+|s\d+|'
      r'c&H[0-9a-fA-F]+&|1c&H[0-9a-fA-F]+&|2c&H[0-9a-fA-F]+&|3c&H[0-9a-fA-F]+&|4c&H[0-9a-fA-F]+&|'
      r'a&H[0-9a-fA-F]+&|1a&H[0-9a-fA-F]+&|2a&H[0-9a-fA-F]+&|3a&H[0-9a-fA-F]+&|4a&H[0-9a-fA-F]+&|'
      r'k\d+|kf\d+|ko\d+|K\d+|'
      r'q\d+|r[^\\}]*|'
      r'org\([^)]*\)|clip\([^)]*\)|iclip\([^)]*\)|'
      r'draw\d+|pbo-?\d+|'
      r'xbord-?\d+(?:\.\d+)?|ybord-?\d+(?:\.\d+)?|xshad-?\d+(?:\.\d+)?|yshad-?\d+(?:\.\d+)?|'
      r'be\d+|blur\d+(?:\.\d+)?|'
      r'frz-?\d+(?:\.\d+)?|frx-?\d+(?:\.\d+)?|fry-?\d+(?:\.\d+)?|'
      r'fax-?\d+(?:\.\d+)?|fay-?\d+(?:\.\d+)?|'
      r' Bord(?:er)?\d+|Shad(?:ow)?\d+'
      r')'
    ), '');
    result = result.replaceAll('\\N', '\n');
    result = result.replaceAll('\\n', '\n');
    result = result.replaceAll(RegExp(r'[^\S\n]+'), ' ').trim();
    return result;
  }

  @override
  Future<void> applySuperResolution(bool enable) async {}

  @override
  Future<void> applySuperResolutionLevel(String level) async {}

  @override
  Future<Map<String, String>> getPlaybackStats() async => {};

  @override
  Future<void> dispose() async {
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
    _enableAssSupport = false;
    _textureId = null;
    _isInitialized = false;
    _isPlaying = false;
    _isBuffering = false;
    _position = Duration.zero;
    _duration = Duration.zero;
    _tracks = [];
    _subtitleText = '';
    _isBitmapSubtitle = false;
    subtitleNotifier.value = '';
    bitmapNotifier.value = const [];
    _subtitleSettingsVersion.value = 0;
  }
}

/// 单个位图字幕分片。几何字段为占视频帧的比例（0~1），可能缺失。
class BitmapSubtitleCue {
  final Uint8List bytes;
  final double? left;
  final double? top;
  final double? width;
  final double? height;

  const BitmapSubtitleCue({
    required this.bytes,
    this.left,
    this.top,
    this.width,
    this.height,
  });

  bool get hasFullGeometry =>
      left != null && top != null && width != null && height != null;
  bool get hasLegacyGeometry =>
      left != null && top != null && width != null;
}
