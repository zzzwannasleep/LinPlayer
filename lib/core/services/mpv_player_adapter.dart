import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' show max, min;
import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show rootBundle;
import 'package:path_provider/path_provider.dart';
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';
import 'player_adapter.dart';
import 'app_logger.dart';
import 'cache_service.dart';
import 'mpv_config_manager.dart';
import 'subtitle_track_matcher.dart';
import 'subtitle_processor.dart';

class MpvPlayerAdapter implements PlayerAdapter {
  static final _logger = AppLogger();
  static final _configManager = MpvConfigManager();
  static const _subtitleTrackTypes = <String>{'subtitle', 'text', 'bitmap'};
  static const _startupSeekAttemptLimit = 8;
  static const _startupSeekRetryDelay = Duration(milliseconds: 120);
  static const _startupSeekPollInterval = Duration(milliseconds: 40);
  static const _startupSeekPollTimeout = Duration(milliseconds: 240);
  static const _startupSeekTolerance = Duration(milliseconds: 750);

  Player? _player;
  VideoController? _videoController;
  // 缓存 Video Widget，保证每次 build 返回同一实例。
  // 否则播放页 setState（显示控制栏/选项）会重建 Video，
  // 触发 media_kit 纹理重新挂载并瞬时呈现空白帧，造成画面闪现。
  Widget? _videoWidget;

  bool _isInitialized = false;
  bool _isPlaying = false;
  bool _isBuffering = false;
  bool _isCompleted = false;
  Duration _position = Duration.zero;
  Duration _duration = Duration.zero;
  double _speed = 1.0;
  double _volume = 1.0;
  String? _errorMessage;

  double _subtitleDelay = 0.0;
  double _audioDelay = 0.0;
  double _subtitleScale = 1.0;
  double _subtitlePosition = 100.0;
  String? _subtitleFont;
  String? _aspectRatio;
  List<String>? _glslShaders;
  bool _subtitleBackground = false;
  String? _secondarySid;
  bool _hasBitmapSubtitle = false;
  bool _currentSubIsAss = false;
  bool _usingExternalSubtitle = false;
  bool _pgsDecoderAvailable = true;
  String _lastSubtitleCueText = '';
  bool _isSeekBuffering = false;
  Timer? _seekBufferingFallbackTimer;
  Timer? _seekBufferingPollTimer;
  bool _isSeekInFlight = false;

  List<Map<String, dynamic>> _tracks = [];
  List<SubtitleTrack> _subtitleTracks = [];
  List<AudioTrack> _audioTracks = [];
  String? _selectedSubtitleTrackId;
  String? _selectedNativeSubtitleSid;
  String? _selectedAudioTrackId;

  PlayerStateCallbacks? _callbacks;
  final List<StreamSubscription> _subscriptions = [];

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
  bool get pgsDecoderAvailable => _pgsDecoderAvailable;
  @override
  bool get libassReady => true;
  @override
  int? get textureId => null;
  @override
  List<Map<String, dynamic>> getTracksInfo() => _tracks;
  @override
  void setCallbacks(PlayerStateCallbacks callbacks) {
    _callbacks = callbacks;
  }

  NativePlayer? get _nativePlayer {
    final platform = _player?.platform;
    if (platform is NativePlayer) return platform;
    return null;
  }

  bool get _isDesktopPlatform =>
      Platform.isWindows || Platform.isLinux || Platform.isMacOS;

  bool _isHttpUrl(String path) =>
      path.startsWith('http://') || path.startsWith('https://');

  String _extractExtension(String path) {
    var clean = path;
    final qIndex = clean.indexOf('?');
    if (qIndex >= 0) clean = clean.substring(0, qIndex);
    final hashIndex = clean.indexOf('#');
    if (hashIndex >= 0) clean = clean.substring(0, hashIndex);
    final dotIndex = clean.lastIndexOf('.');
    if (dotIndex < 0 || dotIndex < clean.lastIndexOf('/')) return '';
    return clean.substring(dotIndex + 1).toLowerCase();
  }

  String _shaderFileName(String shaderRef) {
    final normalized = shaderRef.replaceAll('\\', '/');
    final slashIndex = normalized.lastIndexOf('/');
    return slashIndex >= 0 ? normalized.substring(slashIndex + 1) : normalized;
  }

  /// 把本地字幕路径转成 mpv `sub-add` 能稳定识别的 URI。
  ///
  /// Windows 下直接把 `C:\\foo\\bar.sup` 传给 mpv 可能被当成相对路径，
  /// 用 `file:///C:/foo/bar.sup` 可以消除歧义；HTTP(S) 字幕保持原样。
  String _toMpvSubtitleUri(String path) {
    if (_isHttpUrl(path)) {
      return path;
    }
    return Uri.file(path).toString();
  }

  Future<void> _openVideoSource(
    String videoUrl, {
    Duration? startPosition,
  }) async {
    // Keep media_kit's own open path as the primary entrypoint so the
    // underlying player state and Flutter Video widget stay in sync.
    // Network edge cases are handled one layer above via playback URL
    // fallback instead of bypassing Player.open here.
    final resumePosition =
        (startPosition != null && startPosition > Duration.zero)
            ? startPosition
            : null;

    // 续播：优先通过 mpv 的 start 选项让加载时直接定位到续播点，
    // 避免 open 之后再 seek 的竞态（慢速/网络源下 seek 可能落空导致从头播放）。
    final np = _nativePlayer;
    if (resumePosition != null && np != null) {
      final seconds = resumePosition.inMilliseconds / 1000.0;
      try {
        await np.setProperty('start', '$seconds');
      } catch (_) {
        // start 设置失败时继续走兜底 seek 流程。
      }
    }

    final media = Media(videoUrl);
    await _player!.open(media, play: false);

    if (resumePosition != null) {
      // 兜底校正：部分协议/解码路径下 start 选项可能不生效，再用重试 seek 落位。
      await _applyStartupSeek(resumePosition);
    }

    // 复位 start，避免 start 选项影响后续可能的加载（防御性处理）。
    if (resumePosition != null && np != null) {
      try {
        await np.setProperty('start', 'none');
      } catch (_) {}
    }
  }

  /// 探测当前 libmpv 是否包含 PGS/SUP 解码器。
  ///
  /// media-kit 的 Windows 预编译包为了体积会 `--disable-decoders` 并漏掉
  /// `hdmv_pgs_subtitle`，这是 PC 端不显示 PGS/SUP 的根因。
  /// 探测结果只用于日志/诊断，真正的修复需要替换为完整版 libmpv-2.dll。
  Future<void> _applyStartupSeek(Duration startPosition) async {
    Object? lastError;
    StackTrace? lastStackTrace;

    for (var attempt = 1; attempt <= _startupSeekAttemptLimit; attempt++) {
      try {
        await _player!.seek(startPosition);
      } catch (error, stackTrace) {
        lastError = error;
        lastStackTrace = stackTrace;
      }

      if (await _waitForStartupSeekPosition(startPosition)) {
        if (attempt > 1) {
          _logger.i(
            'MpvAdapter',
            'media_kit 启动续播已命中，attempt=$attempt, position=${startPosition.inMilliseconds}ms',
          );
        }
        return;
      }

      if (attempt < _startupSeekAttemptLimit) {
        await Future.delayed(_startupSeekRetryDelay);
      }
    }

    if (lastError != null && lastStackTrace != null) {
      Error.throwWithStackTrace(lastError, lastStackTrace);
    }

    _logger.w(
      'MpvAdapter',
      'media_kit 启动续播未在预期时间内落位，target=${startPosition.inMilliseconds}ms, current=${_position.inMilliseconds}ms',
    );
  }

  Future<bool> _waitForStartupSeekPosition(Duration target) async {
    final stopwatch = Stopwatch()..start();
    while (stopwatch.elapsed < _startupSeekPollTimeout) {
      if (_isNearStartupSeekTarget(_position, target)) {
        return true;
      }
      await Future.delayed(_startupSeekPollInterval);
    }
    return _isNearStartupSeekTarget(_position, target);
  }

  bool _isNearStartupSeekTarget(Duration current, Duration target) {
    return (current - target).inMilliseconds.abs() <=
        _startupSeekTolerance.inMilliseconds;
  }

  Future<void> _probePgsDecoderAvailability() async {
    if (!_isDesktopPlatform) return;
    try {
      // 注意：mpv 的 `decoder-list` 只含音视频解码器，不含字幕解码器，
      // 故不能据它判断 PGS。改用「libmpv 是否完整版」判定。
      if (Platform.isWindows) {
        final bytes = _activeLibmpvDllBytes();
        // 完整版 libmpv（含 ffmpeg/pgssub，约 117MB）才能解 PGS；
        // media-kit 预编译桩约 30MB。阈值取 60MB。
        _pgsDecoderAvailable = bytes != null && bytes > 60 * 1024 * 1024;
        final evidence = _describeWindowsLibmpvRuntimeEvidence();
        if (_pgsDecoderAvailable) {
          _logger.i('MpvAdapter',
              '检测到完整版 libmpv，PGS/SUP 图形字幕可渲染。运行时证据: $evidence');
        } else {
          _logger.w(
            'MpvAdapter',
            '当前 libmpv 为精简版（无 PGS/SUP 解码器）。'
                '请运行 windows/scripts/upgrade_libmpv_for_pgs.ps1 替换完整版 libmpv-2.dll。'
                '运行时证据: $evidence',
          );
        }
        return;
      }
      // macOS/Linux：随包 Mpv.framework 或系统 libmpv 通常含 pgssub，默认可用。
      _pgsDecoderAvailable = true;
      _logger.i('MpvAdapter',
          '非 Windows 桌面，默认 libmpv 含 PGS/SUP 解码器。运行时证据: ${_describeLibmpvRuntimeEvidence()}');
    } catch (e) {
      _logger.w('MpvAdapter', '探测 PGS 解码器失败: $e');
    }
  }

  /// 当前运行目录下 libmpv-2.dll 的字节数（无法获取返回 null）。
  int? _activeLibmpvDllBytes() {
    try {
      final dir = File(Platform.resolvedExecutable).parent;
      final dll =
          File('${dir.path}${Platform.pathSeparator}libmpv-2.dll');
      if (dll.existsSync()) return dll.lengthSync();
    } catch (_) {}
    return null;
  }

  String _describeWindowsLibmpvRuntimeEvidence() {
    try {
      final executablePath = Platform.resolvedExecutable;
      final executableDir = File(executablePath).parent;
      final dllFile =
          File('${executableDir.path}${Platform.pathSeparator}libmpv-2.dll');
      final backupFile = File(
          '${executableDir.path}${Platform.pathSeparator}libmpv-2.dll.orig');
      final manifestFile = File(
          '${executableDir.path}${Platform.pathSeparator}libmpv-upgrade.json');

      final parts = <String>[
        'exe=$executablePath',
        'dir=${executableDir.path}',
        'dll=${dllFile.existsSync()}',
        'backup=${backupFile.existsSync()}',
        'manifest=${manifestFile.existsSync()}',
      ];
      if (dllFile.existsSync()) {
        parts.add('dllBytes=${dllFile.lengthSync()}');
      }
      if (backupFile.existsSync()) {
        parts.add('backupBytes=${backupFile.lengthSync()}');
      }
      final parentDir = executableDir.parent;
      final grandParentDir = parentDir.parent;
      if (executableDir.path.isNotEmpty &&
          parentDir.path.isNotEmpty &&
          grandParentDir.path.isNotEmpty &&
          parentDir.path
              .toLowerCase()
              .endsWith('${Platform.pathSeparator}runner')) {
        final sharedLibmpvDir =
            Directory('${grandParentDir.path}${Platform.pathSeparator}libmpv');
        final sharedDllFile = File(
            '${sharedLibmpvDir.path}${Platform.pathSeparator}libmpv-2.dll');
        final sharedManifestFile = File(
            '${sharedLibmpvDir.path}${Platform.pathSeparator}libmpv-upgrade.json');
        parts.add('sharedDir=${sharedLibmpvDir.path}');
        parts.add('sharedDll=${sharedDllFile.existsSync()}');
        parts.add('sharedManifest=${sharedManifestFile.existsSync()}');
        if (sharedDllFile.existsSync()) {
          parts.add('sharedDllBytes=${sharedDllFile.lengthSync()}');
        }
      }
      return parts.join(', ');
    } catch (e) {
      return 'runtime-evidence-error=$e';
    }
  }

  String _describeLibmpvRuntimeEvidence() {
    if (Platform.isWindows) {
      return _describeWindowsLibmpvRuntimeEvidence();
    }
    if (Platform.isMacOS) {
      return _describeMacosLibmpvRuntimeEvidence();
    }
    return _describeGenericDesktopLibmpvRuntimeEvidence();
  }

  String _describeMacosLibmpvRuntimeEvidence() {
    try {
      final executablePath = Platform.resolvedExecutable;
      final executableDir = File(executablePath).parent;
      final contentsDir = executableDir.parent;
      final frameworkFile = File(
        '${contentsDir.path}${Platform.pathSeparator}Frameworks'
        '${Platform.pathSeparator}Mpv.framework${Platform.pathSeparator}Mpv',
      );

      final parts = <String>[
        'exe=$executablePath',
        'dir=${executableDir.path}',
        'framework=${frameworkFile.existsSync()}',
      ];
      if (frameworkFile.existsSync()) {
        parts.add('frameworkBytes=${frameworkFile.lengthSync()}');
      }
      return parts.join(', ');
    } catch (e) {
      return 'runtime-evidence-error=$e';
    }
  }

  String _describeGenericDesktopLibmpvRuntimeEvidence() {
    try {
      final executablePath = Platform.resolvedExecutable;
      final executableDir = File(executablePath).parent;
      return [
        'exe=$executablePath',
        'dir=${executableDir.path}',
        'os=${Platform.operatingSystemVersion}',
      ].join(', ');
    } catch (e) {
      return 'runtime-evidence-error=$e';
    }
  }

  Future<String> _ensureShaderAssetFile(String shaderRef) async {
    final fileName = _shaderFileName(shaderRef);
    final assetPath = 'assets/mpv/shaders/$fileName';
    final supportDir = await getApplicationSupportDirectory();
    final shaderDir = Directory('${supportDir.path}/shaders');
    if (!shaderDir.existsSync()) {
      shaderDir.createSync(recursive: true);
    }

    final shaderFile = File('${shaderDir.path}/$fileName');
    final shaderData = await rootBundle.load(assetPath);
    final bytes = shaderData.buffer.asUint8List(
      shaderData.offsetInBytes,
      shaderData.lengthInBytes,
    );

    if (!shaderFile.existsSync() || await shaderFile.length() != bytes.length) {
      await shaderFile.writeAsBytes(bytes, flush: true);
    }

    return shaderFile.path.replaceAll('\\', '/');
  }

  Future<void> _applyShaderList(List<String>? shaderRefs) async {
    final np = _nativePlayer;
    if (np == null) {
      return;
    }

    try {
      await np.command(['change-list', 'glsl-shaders', 'clr', '']);
    } catch (_) {
      await np.setProperty('glsl-shaders', '');
    }

    if (shaderRefs == null || shaderRefs.isEmpty) {
      _logger.i('MpvAdapter', 'Anime4K 已关闭');
      return;
    }

    final resolvedPaths = <String>[];
    for (final shaderRef in shaderRefs) {
      try {
        resolvedPaths.add(await _ensureShaderAssetFile(shaderRef));
      } catch (e) {
        throw StateError(
            '缺少 Anime4K shader 资源: ${_shaderFileName(shaderRef)} ($e)');
      }
    }

    for (final shaderPath in resolvedPaths) {
      await np.command(['change-list', 'glsl-shaders', 'append', shaderPath]);
    }
    _logger.i('MpvAdapter', 'Anime4K shaders 已应用: ${resolvedPaths.join(', ')}');
  }

  @override
  Future<void> initialize({
    required String videoUrl,
    Duration? startPosition,
    bool dolbyVisionFix = false,
    bool useLibass = false,
    bool hardwareDecoding = true,
    String? preferredSubtitleLanguage,
    int? surfaceViewId, // Not used by media_kit, only for native mpv
    bool useGpuNext = false, // Not used by media_kit, only for native mpv
  }) async {
    _logger.i('MpvAdapter', '开始初始化 media_kit 内核');
    try {
      await dispose();
      _errorMessage = null;
      _isCompleted = false;
      _tracks = [];
      _subtitleTracks = [];
      _audioTracks = [];
      _secondarySid = null;
      _usingExternalSubtitle = false;

      await _configManager.initialize();
      await _configManager.writeConfig(
        subtitleFont: _subtitleFont,
        subtitleScale: _subtitleScale,
        subtitlePosition: _subtitlePosition,
        subtitleDelay: _subtitleDelay,
        audioDelay: _audioDelay,
        aspectRatio: _aspectRatio,
        glslShaders: _glslShaders,
        subtitleBackground: _subtitleBackground,
      );

      // 启用 native mpv 字幕管线，并关闭 Flutter 侧字幕 overlay。
      // media_kit 在 libass=false 时会把 sub-visibility 预设为 no，
      // 这会让内封/外挂 PGS/SUP 即便选中轨道也无法稳定显示。
      _player = Player(
        configuration: const PlayerConfiguration(
          libass: true,
          logLevel: MPVLogLevel.warn,
        ),
      );
      _videoController = VideoController(_player!);
      _videoWidget = null; // 新控制器，丢弃旧的缓存 Video 实例
      _setupStreamListeners();

      {
        final np = _nativePlayer;
        if (np != null) {
          final fontsDir = _configManager.fontsDirectory;
          const systemFontsDir = '/system/fonts';
          final dir = Directory(fontsDir);
          if (dir.listSync().isNotEmpty) {
            await np.setProperty('sub-fonts-dir', fontsDir);
          } else {
            await np.setProperty('sub-fonts-dir', systemFontsDir);
          }
          // 默认关闭次字幕可见性，只有用户明确选择次字幕时才开启
          // 避免同时显示两个字幕（主字幕+次字幕）
          await np.setProperty('secondary-sub-visibility', 'no');
          // 字幕走 OSD 覆盖层渲染（不混入视频帧）。
          // blend-subtitles=video 会让位图字幕(PGS/SUP)每次刷新都重绘整帧，
          // 导致视频画面闪现；覆盖层渲染同样能稳定显示 PGS/SUP。
          await np.setProperty('blend-subtitles', 'no');
          await np.setProperty('sub-visibility', 'yes');
          await np.setProperty('hwdec', hardwareDecoding ? 'auto-safe' : 'no');
          await _applyShaderList(_glslShaders);
          if (_isHttpUrl(videoUrl)) {
            // 视频播放缓存：写到磁盘而非内存，避免大缓冲吃满 RAM 导致卡顿/OOM。
            // 缓冲总量由用户设置（300MB–8GB）控制，按 3:1 分给前向/回退。
            final cacheMaxMB = await CacheService.getVideoCacheMaxSizeMB();
            final totalBytes = cacheMaxMB * 1024 * 1024;
            final forwardBytes = (totalBytes * 3) ~/ 4;
            final backBytes = totalBytes ~/ 4;
            final cacheDir = await CacheService.videoStreamCacheDirPath;

            await np.setProperty('cache', 'yes');
            // 关键：缓存落盘，不占内存。
            await np.setProperty('cache-on-disk', 'yes');
            await np.setProperty('cache-dir', cacheDir);
            await np.setProperty('cache-pause', 'yes');
            // Don't block startup on an aggressive initial cache fill.
            // We still keep pause-on-underflow for mid-playback stability.
            await np.setProperty('cache-pause-wait', '2.5');
            await np.setProperty('cache-pause-initial', 'no');
            await np.setProperty('cache-secs', '300');
            await np.setProperty('demuxer-max-bytes', '$forwardBytes');
            await np.setProperty('demuxer-max-back-bytes', '$backBytes');
            await np.setProperty('demuxer-readahead-secs', '180');
            await np.setProperty('demuxer-seekable-cache', 'yes');
            await np.setProperty('demuxer-cache-wait', 'no');
            await np.setProperty('network-timeout', '20');
            await np.setProperty('stream-buffer-size', '33554432');
            await np.setProperty('interpolation', 'no');
            await np.setProperty('prefetch-playlist', 'no');
            await np.setProperty('vd-lavc-threads', '0');
            await np.setProperty('ad-lavc-threads', '0');
          }
        }
      }

      await _openVideoSource(videoUrl, startPosition: startPosition);

      _isInitialized = true;
      _callbacks?.onDurationChanged?.call();
      _logger.i('MpvAdapter', 'media_kit 初始化完成');

      // 异步探测 PGS 解码器，不阻塞初始化。
      unawaited(_probePgsDecoderAvailability());
    } catch (e, stackTrace) {
      _errorMessage = e.toString();
      _isInitialized = false;
      _logger.eWithStack('MpvAdapter', '初始化失败', e, stackTrace);
      _callbacks?.onError?.call();
    }
  }

  /// 读取当前 cue 的起止时间并回调（供流式翻译）。
  Future<void> _emitSubtitleCue(String text) async {
    Duration? start, end;
    final np = _nativePlayer;
    if (np != null) {
      try {
        start = _parseSecondsToDuration(await np.getProperty('sub-start'));
        end = _parseSecondsToDuration(await np.getProperty('sub-end'));
      } catch (_) {}
    }
    _callbacks?.onSubtitleCue?.call(text, start, end);
  }

  Duration? _parseSecondsToDuration(String? raw) {
    if (raw == null || raw.isEmpty) return null;
    final s = double.tryParse(raw);
    if (s == null) return null;
    return Duration(milliseconds: (s * 1000).round());
  }

  void _setupStreamListeners() {
    if (_player == null) return;

    _subscriptions.add(_player!.stream.playing.listen((playing) {
      _isPlaying = playing;
      _callbacks?.onPlayingStateChanged?.call();
    }));
    _subscriptions.add(_player!.stream.position.listen((position) {
      _position = position;
      if (_isSeekBuffering &&
          position.inMilliseconds >= 0 &&
          (_duration == Duration.zero || position <= _duration)) {
        _isSeekInFlight = false;
      }
      _callbacks?.onPositionChanged?.call();
    }));
    _subscriptions.add(_player!.stream.duration.listen((duration) {
      _duration = duration;
      _callbacks?.onDurationChanged?.call();
    }));
    _subscriptions.add(_player!.stream.buffering.listen((buffering) {
      _setBufferingState(buffering);
      if (_isSeekBuffering && !buffering) {
        unawaited(() async {
          try {
            final stillBuffering = await _isCacheStillBuffering();
            if (!stillBuffering) {
              _completeSeekBuffering();
            }
          } catch (_) {
            _completeSeekBuffering();
          }
        }());
      }
      _callbacks?.onBufferingStateChanged?.call();
    }));
    _subscriptions.add(_player!.stream.completed.listen((completed) {
      if (completed) {
        _isCompleted = true;
        _callbacks?.onCompleted?.call();
      }
    }));
    _subscriptions.add(_player!.stream.error.listen((error) {
      _errorMessage = error.toString();
      _logger.e('MpvAdapter', '播放器错误: $_errorMessage');
      _callbacks?.onError?.call();
    }));
    // 转发 libmpv 原生日志（warn 及以上），以便捕获崩溃前的 native 报错。
    _subscriptions.add(_player!.stream.log.listen((log) {
      final level = log.level.toLowerCase();
      final msg = 'mpv[${log.prefix}] ${log.text}'.trimRight();
      if (level == 'error' || level == 'fatal') {
        _logger.e('MpvNative', msg);
      } else {
        _logger.w('MpvNative', msg);
      }
    }));
    // 当前字幕 cue 文本变化 → 供流式翻译实时取词（含起止时间）。
    _subscriptions.add(_player!.stream.subtitle.listen((lines) {
      final text =
          lines.where((l) => l.trim().isNotEmpty).join('\n').trim();
      if (text == _lastSubtitleCueText) return;
      _lastSubtitleCueText = text;
      if (text.isEmpty) return;
      unawaited(_emitSubtitleCue(text));
    }));
    _subscriptions.add(_player!.stream.tracks.listen((tracks) {
      _subtitleTracks = tracks.subtitle;
      _audioTracks = tracks.audio;
      var resolvedSubtitleKind =
          !_usingExternalSubtitle ? SubtitleKind.text : null;

      final trackList = <Map<String, dynamic>>[];
      for (final track in tracks.video) {
        trackList.add({
          'id': track.id,
          'type': 'video',
          'title': track.title ?? '',
          'language': track.language ?? '',
          'codec': track.codec ?? '',
        });
      }
      for (final track in tracks.audio) {
        trackList.add({
          'id': track.id,
          'type': 'audio',
          'title': track.title ?? '',
          'language': track.language ?? '',
          'codec': track.codec ?? '',
          'selected': _trackIdEquals(track.id, _selectedAudioTrackId),
        });
      }
      for (final track in tracks.subtitle) {
        final id = track.id;
        if (id == 'auto' || id == 'no') continue;
        final kind = SubtitleTrackMatcher.classifyKind(
          codec: track.codec,
          title: track.title,
        );
        final isBitmap = kind == SubtitleKind.bitmap;
        final isAss = kind == SubtitleKind.ass;
        if (!_usingExternalSubtitle &&
            _trackIdEquals(track.id, _selectedSubtitleTrackId)) {
          resolvedSubtitleKind = kind;
        }
        trackList.add({
          'id': track.id,
          'type': isBitmap ? 'bitmap' : 'text',
          'title': track.title ?? '',
          'language': track.language ?? '',
          'codec': track.codec ?? '',
          'isBitmap': isBitmap,
          'isAss': isAss,
          'selected': _trackIdEquals(track.id, _selectedSubtitleTrackId),
        });
      }
      if (!_usingExternalSubtitle) {
        _hasBitmapSubtitle = resolvedSubtitleKind == SubtitleKind.bitmap;
        _currentSubIsAss = resolvedSubtitleKind == SubtitleKind.ass;
      }
      _tracks = trackList;
      _logger.d('MpvAdapter',
          '轨道变更: video=${tracks.video.length}, audio=${tracks.audio.length}, subtitle=${tracks.subtitle.length}');
      _tryPendingSubtitleSelection();
    }));
  }

  String? _pendingSubtitleLang;
  String? _pendingSubtitleCodec;
  String? _pendingSubtitleTitle;

  void setPendingSubtitle(String codec, {String? title}) {
    _pendingSubtitleLang = null;
    setSubtitleSelectionHint(codec, title: title);
  }

  @override
  void setSubtitleSelectionHint(String? codec, {String? title}) {
    _pendingSubtitleCodec = codec?.toLowerCase();
    _pendingSubtitleTitle = title;
  }

  void _setBufferingState(bool buffering) {
    final effective = buffering || _isSeekBuffering;
    if (_isBuffering == effective) {
      return;
    }
    _isBuffering = effective;
  }

  void _beginSeekBuffering() {
    _isSeekBuffering = true;
    _isSeekInFlight = true;
    _seekBufferingPollTimer?.cancel();
    _seekBufferingFallbackTimer?.cancel();
    _seekBufferingFallbackTimer = Timer(const Duration(seconds: 3), () {
      _completeSeekBuffering();
    });
    _setBufferingState(true);
    _callbacks?.onBufferingStateChanged?.call();
  }

  void _completeSeekBuffering() {
    if (!_isSeekBuffering) {
      _isSeekInFlight = false;
      _seekBufferingPollTimer?.cancel();
      _seekBufferingPollTimer = null;
      return;
    }
    _isSeekBuffering = false;
    _isSeekInFlight = false;
    _seekBufferingPollTimer?.cancel();
    _seekBufferingPollTimer = null;
    _seekBufferingFallbackTimer?.cancel();
    _seekBufferingFallbackTimer = null;
    _setBufferingState(false);
    _callbacks?.onBufferingStateChanged?.call();
  }

  Future<bool> _isCacheStillBuffering() async {
    final np = _nativePlayer;
    if (np == null) {
      return false;
    }
    final pausedForCache =
        (await np.getProperty('paused-for-cache')).toLowerCase();
    final cacheBufferingState =
        (await np.getProperty('cache-buffering-state')).toLowerCase();
    final cacheDurationRaw = await np.getProperty('demuxer-cache-duration');
    final cacheDuration = double.tryParse(cacheDurationRaw) ?? 0.0;
    return pausedForCache == 'yes' ||
        cacheBufferingState == 'yes' ||
        cacheBufferingState == 'true' ||
        cacheBufferingState == '1' ||
        (_isSeekInFlight && cacheDuration <= 0.05);
  }

  void _startSeekBufferingMonitor() {
    _seekBufferingPollTimer?.cancel();
    _seekBufferingPollTimer = Timer.periodic(
      const Duration(milliseconds: 180),
      (_) async {
        if (!_isSeekBuffering) {
          _seekBufferingPollTimer?.cancel();
          _seekBufferingPollTimer = null;
          return;
        }
        try {
          final stillBuffering = await _isCacheStillBuffering();
          if (!stillBuffering) {
            _completeSeekBuffering();
          }
        } catch (_) {
          // Let the fallback timer close the buffering state.
        }
      },
    );
  }

  SubtitleKind _classifySubtitleTrackKind(
    SubtitleTrack track, {
    String? hintedCodec,
    String? hintedTitle,
  }) {
    final trackInfo =
        _tracks.where((t) => t['id']?.toString() == track.id).firstOrNull;
    return SubtitleTrackMatcher.classifyKind(
      codec: track.codec,
      title: track.title,
      isBitmap:
          trackInfo?['isBitmap'] == true || trackInfo?['type'] == 'bitmap',
      isAss: trackInfo?['isAss'] == true,
      expectedCodec: hintedCodec,
      expectedTitle: hintedTitle,
    );
  }

  bool _trackIdEquals(dynamic rawId, String? targetId) {
    if (targetId == null) {
      return false;
    }
    return rawId?.toString() == targetId;
  }

  bool _languagesMatch(String? expected, String? actual) {
    final e = (expected ?? '').trim().toLowerCase();
    final a = (actual ?? '').trim().toLowerCase();
    if (e.isEmpty || a.isEmpty) {
      return false;
    }
    if (e == a) {
      return true;
    }
    const zhAliases = {'chi', 'zh', 'zho', 'chs', 'cht'};
    if (zhAliases.contains(e) && zhAliases.contains(a)) {
      return true;
    }
    return false;
  }

  Future<String?> _resolveNativeSubtitleSid(
    SubtitleTrack target, {
    String? hintedCodec,
    String? hintedTitle,
  }) async {
    final np = _nativePlayer;
    if (np == null) {
      return null;
    }
    try {
      final trackListJson = await np.getProperty('track-list');
      if (trackListJson.isEmpty || trackListJson == 'null') {
        return null;
      }
      final decoded = jsonDecode(trackListJson);
      if (decoded is! List) {
        return null;
      }

      final targetKind = _classifySubtitleTrackKind(
        target,
        hintedCodec: hintedCodec,
        hintedTitle: hintedTitle,
      );
      final targetTitleLower =
          (hintedTitle ?? target.title ?? '').toLowerCase();
      final targetLang = target.language?.toLowerCase();
      final targetCodecLower =
          (hintedCodec ?? target.codec ?? '').toLowerCase();
      final candidates = <Map<String, dynamic>>[];

      for (final raw in decoded) {
        if (raw is! Map) continue;
        final type = raw['type']?.toString();
        if (type != 'sub') continue;
        final rawId = raw['id']?.toString();
        if (rawId == null ||
            rawId.isEmpty ||
            rawId == 'no' ||
            rawId == 'auto') {
          continue;
        }
        final title = raw['title']?.toString() ?? '';
        final lang =
            raw['lang']?.toString() ?? raw['language']?.toString() ?? '';
        final codec = raw['codec']?.toString() ?? '';
        final bitmap = raw['image'] == true ||
            raw['isBitmap'] == true ||
            raw['albumart'] == true;
        final ass = raw['isAss'] == true;
        final kind = SubtitleTrackMatcher.classifyKind(
          codec: codec,
          title: title,
          isBitmap: bitmap,
          isAss: ass,
          expectedCodec: targetCodecLower,
          expectedTitle: targetTitleLower,
        );
        if (kind != targetKind) {
          continue;
        }
        candidates.add({
          'id': rawId,
          'title': title,
          'language': lang,
          'codec': codec,
        });
      }

      if (candidates.isEmpty) {
        return null;
      }
      if (candidates.length == 1) {
        return candidates.first['id']?.toString();
      }

      for (final candidate in candidates) {
        final title = (candidate['title'] ?? '').toString();
        if (targetTitleLower.isNotEmpty &&
            title.isNotEmpty &&
            _matchTitles(targetTitleLower, title.toLowerCase())) {
          return candidate['id']?.toString();
        }
      }

      for (final candidate in candidates) {
        if (_languagesMatch(targetLang, candidate['language']?.toString())) {
          return candidate['id']?.toString();
        }
      }

      for (final candidate in candidates) {
        final codec = (candidate['codec'] ?? '').toString().toLowerCase();
        if (targetCodecLower.isNotEmpty && codec == targetCodecLower) {
          return candidate['id']?.toString();
        }
      }

      return candidates.first['id']?.toString();
    } catch (e) {
      _logger.w('MpvAdapter', '解析原生字幕 track-list 失败: $e');
      return null;
    }
  }

  void _markTrackSelected({
    String? subtitleTrackId,
    String? nativeSubtitleSid,
    String? audioTrackId,
  }) {
    if (subtitleTrackId != null) {
      _selectedSubtitleTrackId = subtitleTrackId;
    }
    if (nativeSubtitleSid != null) {
      _selectedNativeSubtitleSid = nativeSubtitleSid;
    }
    if (audioTrackId != null) {
      _selectedAudioTrackId = audioTrackId;
    }
    for (final track in _tracks) {
      final type = track['type']?.toString();
      if (_subtitleTrackTypes.contains(type)) {
        track['selected'] =
            _trackIdEquals(track['id'], _selectedSubtitleTrackId);
      } else if (type == 'audio') {
        track['selected'] = _trackIdEquals(track['id'], _selectedAudioTrackId);
      }
    }
  }

  Future<bool> _ensureNativeSubtitleTrackSelection(String trackId) async {
    final np = _nativePlayer;
    if (np == null) {
      return true;
    }
    try {
      for (var attempt = 1; attempt <= 6; attempt++) {
        var sid = await np.getProperty('sid');
        if (sid != trackId) {
          await np.setProperty('sid', trackId);
          sid = await np.getProperty('sid');
        }
        _logger.d(
          'MpvAdapter',
          '字幕轨道校验: attempt=$attempt, expected=$trackId, sid=$sid',
        );
        if (sid == trackId) {
          return true;
        }
        await Future.delayed(const Duration(milliseconds: 120));
      }
      _logger.w('MpvAdapter', '字幕轨道校验失败: expected=$trackId');
    } catch (e) {
      _logger.w('MpvAdapter', '字幕轨道校验失败: $e');
    }
    return false;
  }

  Future<bool> waitForSubtitleTrackSelection(
    String trackId, {
    String? hintedCodec,
    String? hintedTitle,
  }) async {
    var expectedSid = trackId;
    if (_selectedSubtitleTrackId == trackId &&
        _selectedNativeSubtitleSid != null &&
        _selectedNativeSubtitleSid!.isNotEmpty) {
      expectedSid = _selectedNativeSubtitleSid!;
    } else {
      final target = _subtitleTracks
          .where((track) => track.id != 'auto' && track.id != 'no')
          .where((track) => _trackIdEquals(track.id, trackId))
          .firstOrNull;
      if (target != null) {
        expectedSid = await _resolveNativeSubtitleSid(
              target,
              hintedCodec: hintedCodec,
              hintedTitle: hintedTitle,
            ) ??
            trackId;
      }
    }
    return _ensureNativeSubtitleTrackSelection(expectedSid);
  }

  Future<void> _ensureBitmapExternalSubtitleSelection() async {
    final np = _nativePlayer;
    if (np == null || !_hasBitmapSubtitle || !_usingExternalSubtitle) {
      return;
    }
    try {
      String? candidateId;
      for (var attempt = 1; attempt <= 6; attempt++) {
        final trackListJson = await np.getProperty('track-list');
        if (trackListJson.isEmpty || trackListJson == 'null') {
          await Future.delayed(const Duration(milliseconds: 180));
          continue;
        }

        final decoded = jsonDecode(trackListJson);
        if (decoded is! List) {
          _logger.w('MpvAdapter', '位图外挂字幕校验失败: track-list 不是数组');
          return;
        }

        for (final raw in decoded.reversed) {
          if (raw is! Map) continue;
          final type = raw['type']?.toString();
          if (type != 'sub') continue;
          final external = raw['external'];
          final title = raw['title']?.toString().toLowerCase() ?? '';
          final id = raw['id']?.toString();
          if (id == null || id.isEmpty) continue;
          if (external == true || title.contains('external subtitle')) {
            candidateId = id;
            break;
          }
        }

        if (candidateId == null) {
          await Future.delayed(const Duration(milliseconds: 180));
          continue;
        }

        var sid = await np.getProperty('sid');
        if (sid != candidateId) {
          await np.setProperty('sid', candidateId);
          sid = await np.getProperty('sid');
        }
        _logger.d(
          'MpvAdapter',
          '位图外挂字幕轨道校验: attempt=$attempt, expected=$candidateId, sid=$sid',
        );
        if (sid == candidateId) {
          await np.setProperty('sub-visibility', 'yes');
          return;
        }
        await Future.delayed(const Duration(milliseconds: 180));
      }

      _logger.w(
          'MpvAdapter', '位图外挂字幕轨道校验失败: 未选中外挂图形字幕轨道 candidate=$candidateId');
    } catch (e) {
      _logger.w('MpvAdapter', '位图外挂字幕轨道校验失败: $e');
    }
  }

  Future<void> _removeExternalSubtitleTracks() async {
    final np = _nativePlayer;
    if (np == null) {
      return;
    }
    try {
      final trackListJson = await np.getProperty('track-list');
      if (trackListJson.isEmpty || trackListJson == 'null') {
        return;
      }
      final decoded = jsonDecode(trackListJson);
      if (decoded is! List) {
        return;
      }
      for (final raw in decoded.reversed) {
        if (raw is! Map) continue;
        final type = raw['type']?.toString();
        final external = raw['external'] == true;
        if (type != 'sub' || !external) {
          continue;
        }
        final id = raw['id']?.toString();
        if (id == null || id.isEmpty) {
          continue;
        }
        try {
          await np.command(['sub-remove', id]);
        } catch (_) {
          // Ignore if libmpv refuses to remove an already-detached track.
        }
      }
    } catch (e) {
      _logger.w('MpvAdapter', '清理外挂字幕轨道失败: $e');
    }
  }

  Future<void> _logNativeSubtitleState(String context) async {
    final np = _nativePlayer;
    if (np == null) {
      return;
    }
    try {
      final sid = await np.getProperty('sid');
      final subVisibility = await np.getProperty('sub-visibility');
      final subAss = await np.getProperty('sub-ass');
      final blendSubtitles = await np.getProperty('blend-subtitles');
      _logger.i(
        'MpvAdapter',
        '字幕状态[$context]: sid=$sid, visible=$subVisibility, ass=$subAss, blend=$blendSubtitles, bitmap=$_hasBitmapSubtitle, external=$_usingExternalSubtitle',
      );
    } catch (e) {
      _logger.w('MpvAdapter', '读取字幕状态失败[$context]: $e');
    }
  }

  @override
  Future<void> selectSubtitleTrack(String trackId) async {
    if (_player == null || !_isInitialized) return;
    _logger.i(
        'MpvAdapter', '选择字幕轨道: id=$trackId, 已知轨道数=${_subtitleTracks.length}');
    try {
      final hintedCodec = _pendingSubtitleCodec;
      final hintedTitle = _pendingSubtitleTitle;
      final realTracks =
          _subtitleTracks.where((t) => t.id != 'auto' && t.id != 'no').toList();
      if (realTracks.isEmpty) {
        _logger.w('MpvAdapter', '轨道列表为空，先用SubtitleTrack.auto()兜底');
        await _player!.setSubtitleTrack(SubtitleTrack.auto());
        _pendingSubtitleLang = trackId;
        return;
      }
      var target = realTracks.where((t) => t.id == trackId).firstOrNull;
      if (target == null) {
        final trackInfo = _tracks
            .where((t) =>
                (t['type'] == 'text' || t['type'] == 'bitmap') &&
                t['id']?.toString() == trackId)
            .firstOrNull;
        if (trackInfo != null) {
          target = realTracks.where((t) => t.id == trackInfo['id']).firstOrNull;
        }
      }
      if (target != null) {
        final kind = _classifySubtitleTrackKind(
          target,
          hintedCodec: hintedCodec,
          hintedTitle: hintedTitle,
        );
        _hasBitmapSubtitle = kind == SubtitleKind.bitmap;
        _currentSubIsAss = kind == SubtitleKind.ass;
        _usingExternalSubtitle = false;
        _logger.i('MpvAdapter',
            '字幕轨道已选择: id=${target.id}, title=${target.title}, lang=${target.language}, codec=${target.codec}, bitmap=$_hasBitmapSubtitle, ass=$_currentSubIsAss');
        await _player!.setSubtitleTrack(target);
        final nativeSid = await _resolveNativeSubtitleSid(
          target,
          hintedCodec: hintedCodec,
          hintedTitle: hintedTitle,
        );
        if (nativeSid != null && nativeSid.isNotEmpty) {
          final np = _nativePlayer;
          if (np != null) {
            await np.setProperty('sid', nativeSid);
          }
          await _ensureNativeSubtitleTrackSelection(nativeSid);
          _markTrackSelected(
            subtitleTrackId: target.id.toString(),
            nativeSubtitleSid: nativeSid,
          );
          await _logNativeSubtitleState('select:$nativeSid');
        } else {
          await _ensureNativeSubtitleTrackSelection(target.id.toString());
          _markTrackSelected(
            subtitleTrackId: target.id.toString(),
            nativeSubtitleSid: target.id.toString(),
          );
          await _logNativeSubtitleState('select:${target.id}');
        }
      } else {
        _logger.w('MpvAdapter',
            '未找到字幕轨道: id=$trackId, 可用: ${realTracks.map((t) => '${t.id}/${t.language}/${t.codec}').toList()}');
        await _player!.setSubtitleTrack(SubtitleTrack.auto());
        _selectedSubtitleTrackId = null;
        _selectedNativeSubtitleSid = null;
        _usingExternalSubtitle = false;
        _markTrackSelected();
      }
      _pendingSubtitleCodec = null;
      _pendingSubtitleTitle = null;
      await _applySubtitleRuntimeProperties();
    } catch (e, stackTrace) {
      _logger.eWithStack('MpvAdapter', '选择字幕轨道失败', e, stackTrace);
    }
  }

  Future<void> _tryPendingSubtitleSelection() async {
    if (_pendingSubtitleLang == null) return;
    final realTracks =
        _subtitleTracks.where((t) => t.id != 'auto' && t.id != 'no').toList();
    if (realTracks.isEmpty) return;
    final targetId = _pendingSubtitleLang;
    final targetCodec = _pendingSubtitleCodec;
    final targetTitle = _pendingSubtitleTitle;
    _pendingSubtitleLang = null;
    _pendingSubtitleCodec = null;
    _pendingSubtitleTitle = null;
    _logger.i('MpvAdapter',
        '延迟选择字幕轨道: id=$targetId, codec=$targetCodec, title=$targetTitle, 可用=${realTracks.length}个');

    var target = realTracks.where((t) => t.id == targetId).firstOrNull;
    if (target == null) {
      final trackInfo = _tracks
          .where((t) =>
              (t['type'] == 'text' || t['type'] == 'bitmap') &&
              t['id']?.toString() == targetId)
          .firstOrNull;
      if (trackInfo != null) {
        target = realTracks.where((t) => t.id == trackInfo['id']).firstOrNull;
      }
    }

    if (target == null && targetTitle != null && targetTitle.isNotEmpty) {
      for (final t in realTracks) {
        final tTitle = t.title?.toLowerCase() ?? '';
        if (tTitle.isNotEmpty && _matchTitles(targetTitle, tTitle)) {
          target = t;
          break;
        }
      }
    }

    if (target == null && targetCodec != null) {
      final isBitmap =
          SubtitleTrackMatcher.isGraphicalSubtitleCodec(targetCodec);
      final isAss = SubtitleTrackMatcher.isAssSubtitleCodec(targetCodec);
      final candidates = <SubtitleTrack>[];
      for (final t in realTracks) {
        final kind = _classifySubtitleTrackKind(
          t,
          hintedCodec: targetCodec,
          hintedTitle: targetTitle,
        );
        final tIsBitmap = kind == SubtitleKind.bitmap;
        final tIsAss = kind == SubtitleKind.ass;
        if (isBitmap && tIsBitmap) candidates.add(t);
        if (isAss && tIsAss) candidates.add(t);
      }
      if (candidates.length == 1) {
        target = candidates.first;
      } else if (candidates.length > 1 &&
          targetTitle != null &&
          targetTitle.isNotEmpty) {
        for (final t in candidates) {
          final tTitle = t.title?.toLowerCase() ?? '';
          if (tTitle.isNotEmpty && _matchTitles(targetTitle, tTitle)) {
            target = t;
            break;
          }
        }
        target ??= candidates.first;
      }
      target ??= realTracks.first;
    }

    if (target != null) {
      final kind = _classifySubtitleTrackKind(
        target,
        hintedCodec: targetCodec,
        hintedTitle: targetTitle,
      );
      _hasBitmapSubtitle = kind == SubtitleKind.bitmap;
      _currentSubIsAss = kind == SubtitleKind.ass;
      _usingExternalSubtitle = false;
      await _player!.setSubtitleTrack(target);
      final nativeSid = await _resolveNativeSubtitleSid(
        target,
        hintedCodec: targetCodec,
        hintedTitle: targetTitle,
      );
      if (nativeSid != null && nativeSid.isNotEmpty) {
        final np = _nativePlayer;
        if (np != null) {
          await np.setProperty('sid', nativeSid);
        }
        await _ensureNativeSubtitleTrackSelection(nativeSid);
        _markTrackSelected(
          subtitleTrackId: target.id.toString(),
          nativeSubtitleSid: nativeSid,
        );
        await _logNativeSubtitleState('deferred-select:$nativeSid');
      } else {
        await _ensureNativeSubtitleTrackSelection(target.id.toString());
        _markTrackSelected(
          subtitleTrackId: target.id.toString(),
          nativeSubtitleSid: target.id.toString(),
        );
        await _logNativeSubtitleState('deferred-select:${target.id}');
      }
      await _applySubtitleRuntimeProperties();
      _logger.i('MpvAdapter',
          '延迟字幕选择成功: id=${target.id}, title=${target.title}, codec=${target.codec}');
    }
  }

  bool _matchTitles(String embyTitle, String playerTitle) {
    final e = embyTitle.toLowerCase();
    final p = playerTitle.toLowerCase();
    if (e == p) return true;
    if (p.contains(e) || e.contains(p)) return true;
    final simpKeywords = ['简', 'chs', '简体', '简日', 'gb', '简中'];
    final tradKeywords = ['繁', 'cht', '繁体', '繁日', 'big5', '繁中'];
    final eIsSimp = simpKeywords.any((k) => e.contains(k));
    final eIsTrad = tradKeywords.any((k) => e.contains(k));
    final pIsSimp = simpKeywords.any((k) => p.contains(k));
    final pIsTrad = tradKeywords.any((k) => p.contains(k));
    if (eIsSimp && pIsSimp) return true;
    if (eIsTrad && pIsTrad) return true;
    return false;
  }

  @override
  Future<void> deselectSubtitleTrack() async {
    if (_player == null || !_isInitialized) return;
    try {
      await _player!.setSubtitleTrack(SubtitleTrack.no());
      await _removeExternalSubtitleTracks();
      _selectedSubtitleTrackId = null;
      _selectedNativeSubtitleSid = null;
      _hasBitmapSubtitle = false;
      _currentSubIsAss = false;
      _usingExternalSubtitle = false;
      _markTrackSelected();
    } catch (e, stackTrace) {
      _logger.eWithStack('MpvAdapter', '关闭字幕失败', e, stackTrace);
    }
  }

  @override
  Future<void> selectAudioTrack(String trackId) async {
    if (_player == null || !_isInitialized) return;
    try {
      final target =
          _audioTracks.where((t) => _trackIdEquals(t.id, trackId)).firstOrNull;
      if (target != null) {
        await _player!.setAudioTrack(target);
        _markTrackSelected(audioTrackId: target.id.toString());
      }
    } catch (e, stackTrace) {
      _logger.eWithStack('MpvAdapter', '选择音频轨道失败', e, stackTrace);
    }
  }

  // ---- 原生 mpv 属性/命令直通（供流式翻译 sub-step 预读等高级用法）----

  Future<String?> mpvGetProperty(String name) async {
    final np = _nativePlayer;
    if (np == null) return null;
    try {
      return await np.getProperty(name);
    } catch (_) {
      return null;
    }
  }

  Future<void> mpvSetProperty(String name, String value) async {
    final np = _nativePlayer;
    if (np == null) return;
    try {
      await np.setProperty(name, value);
    } catch (_) {}
  }

  Future<void> mpvCommand(List<String> args) async {
    final np = _nativePlayer;
    if (np == null) return;
    try {
      await np.command(args);
    } catch (_) {}
  }

  @override
  Future<void> loadLibassSubtitle(String path) async {
    _logger.i('MpvAdapter', '加载外挂字幕: $path');
    if (_player == null || !_isInitialized) return;

    try {
      if (!_isHttpUrl(path)) {
        final file = File(path);
        if (!file.existsSync()) {
          throw StateError('字幕文件不存在: $path');
        }
        final fileSize = await file.length();
        if (fileSize <= 0) {
          throw StateError('字幕文件为空: $path');
        }
        _logger.i('MpvAdapter', '外挂字幕文件校验: path=$path, size=$fileSize bytes');
      }

      if (_isHttpUrl(path)) {
        _logger.i('MpvAdapter', 'HTTP URL字幕，直接传给mpv加载');
        final ext = _extractExtension(path);
        final normalizedPath = path.toLowerCase();
        final isAss = ext == 'ass' ||
            ext == 'ssa' ||
            normalizedPath.contains('format=ass') ||
            normalizedPath.contains('codec=ass');
        final isPgs = ext == 'pgs' ||
            ext == 'sup' ||
            normalizedPath.contains('format=pgs') ||
            normalizedPath.contains('codec=pgs') ||
            normalizedPath.contains('pgssub') ||
            normalizedPath.contains('hdmv');
        _currentSubIsAss = isAss;
        _hasBitmapSubtitle = isPgs;
        _usingExternalSubtitle = true;
        _logger.i('MpvAdapter',
            'HTTP字幕类型: ext=$ext, isAss=$_currentSubIsAss, isBitmap=$_hasBitmapSubtitle');
        final np = _nativePlayer;
        if (_hasBitmapSubtitle && np != null) {
          await _removeExternalSubtitleTracks();
          final subtitlePath = _toMpvSubtitleUri(path);
          await np.command(
              ['sub-add', subtitlePath, 'select', 'External Subtitle', 'und']);
          await _ensureBitmapExternalSubtitleSelection();
        } else {
          await _player!.setSubtitleTrack(SubtitleTrack.uri(path));
        }
        _selectedSubtitleTrackId = 'external';
        _selectedNativeSubtitleSid = 'external';
        await _applySubtitleRuntimeProperties();
        await _logNativeSubtitleState('load-http-external');
        _logger.i('MpvAdapter', 'HTTP外挂字幕加载成功');
        return;
      }

      final ext = _extractExtension(path);

      if (ext == 'pgs' || ext == 'sup') {
        _logger.i('MpvAdapter', '图形字幕 (PGS/SUP)，直接加载: $path');
        _hasBitmapSubtitle = true;
        _currentSubIsAss = false;
        _usingExternalSubtitle = true;
        // 强制关闭 libass 以允许 MPV 原生渲染位图字幕
        final np = _nativePlayer;
        if (np != null) {
          await _removeExternalSubtitleTracks();
          await np.setProperty('sub-ass', 'no');
          await np.setProperty('sub-ass-override', 'no');
          final subtitlePath = _toMpvSubtitleUri(path);
          await np.command(
              ['sub-add', subtitlePath, 'select', 'External Subtitle', 'und']);
        } else {
          await _player!.setSubtitleTrack(SubtitleTrack.uri(path));
        }
        _selectedSubtitleTrackId = 'external';
        _selectedNativeSubtitleSid = 'external';
        await _ensureBitmapExternalSubtitleSelection();
        await _applySubtitleRuntimeProperties();
        await _logNativeSubtitleState('load-bitmap-external');
        _logger.i('MpvAdapter', '图形字幕加载完成，等待渲染');
        return;
      }

      var processedPath = path;

      if (_subtitleDelay != 0.0) {
        processedPath =
            await SubtitleProcessor.adjustTiming(processedPath, _subtitleDelay);
      }

      if (ext == 'ass' || ext == 'ssa') {
        _currentSubIsAss = true;
        _hasBitmapSubtitle = false;
        _usingExternalSubtitle = true;
        if (_subtitleFont != null && _subtitleFont != '默认') {
          processedPath = await SubtitleProcessor.modifyAssStyle(
            processedPath,
            fontName: _subtitleFont,
          );
        }
      } else {
        _currentSubIsAss = false;
        _hasBitmapSubtitle = false;
        _usingExternalSubtitle = true;
        _logger.i('MpvAdapter', '文本字幕 (SRT/VTT等)，isAss=false');
      }

      await _player!.setSubtitleTrack(SubtitleTrack.uri(processedPath));
      _selectedSubtitleTrackId = 'external';
      _selectedNativeSubtitleSid = 'external';
      await _applySubtitleRuntimeProperties();
      await _logNativeSubtitleState('load-text-external');

      _logger.i('MpvAdapter', '外挂字幕加载成功: $processedPath');
    } catch (e, stackTrace) {
      _logger.eWithStack('MpvAdapter', '外挂字幕加载失败', e, stackTrace);
      rethrow;
    }
  }

  Future<void> _applySubtitleRuntimeProperties() async {
    final np = _nativePlayer;
    if (np == null) return;
    try {
      await np.setProperty('sub-visibility', 'yes');
      await np.setProperty('sub-delay', _subtitleDelay.toStringAsFixed(3));

      if (_hasBitmapSubtitle) {
        // PGS/SUP 位图字幕必须走 OSD 覆盖层渲染：
        // blend-subtitles=video 会把字幕混入视频帧，PGS 频繁的合成刷新
        // (含清屏段) 会触发整帧重绘，在桌面端造成视频画面闪现。
        await np.setProperty('blend-subtitles', 'no');
        // PGS/SUP 等位图字幕：关闭 ASS 处理，避免 libass 干扰原生渲染
        await np.setProperty('sub-ass', 'no');
        await np.setProperty('sub-ass-override', 'no');
        await np.setProperty('sub-back-color', '#00000000');
        await np.setProperty('sub-visibility', 'yes');
        if (_usingExternalSubtitle) {
          await np.setProperty('sub-pos', '100');
        }
        // 位图字幕保留轨道原生布局，只应用缩放。
        await np.setProperty('sub-scale', _subtitleScale.toStringAsFixed(2));
        _logger.i(
            'MpvAdapter', '已应用图形字幕(PGS/SUP)配置: scale=$_subtitleScale, ass=no');
      } else if (_currentSubIsAss) {
        await np.setProperty('blend-subtitles', 'video');
        await np.setProperty('sub-ass', 'yes');
        // 保留 ASS 原始样式、层级与布局，不用 sub-pos 覆盖内封排版。
        await np.setProperty('sub-ass-override', 'no');
        await np.setProperty('sub-scale', _subtitleScale.toStringAsFixed(2));
        if (_subtitleFont != null &&
            _subtitleFont!.isNotEmpty &&
            _subtitleFont != '默认') {
          await np.setProperty('sub-font', _subtitleFont!);
        }
        if (_subtitleBackground) {
          await np.setProperty('sub-back-color', '#000000C0');
        } else {
          await np.setProperty('sub-back-color', '#00000000');
        }
      } else {
        await np.setProperty('blend-subtitles', 'video');
        // 普通文本字幕 (SRT/VTT)
        await np.setProperty('sub-ass', 'yes');
        await np.setProperty('sub-ass-override', 'strip');
        await np.setProperty('sub-scale', _subtitleScale.toStringAsFixed(2));
        await np.setProperty('sub-pos', _subtitlePosition.toStringAsFixed(1));
        if (_subtitleFont != null &&
            _subtitleFont!.isNotEmpty &&
            _subtitleFont != '默认') {
          await np.setProperty('sub-font', _subtitleFont!);
        }
        if (_subtitleBackground) {
          await np.setProperty('sub-back-color', '#000000C0');
        } else {
          await np.setProperty('sub-back-color', '#00000000');
        }
      }

      if (_secondarySid != null) {
        await np.setProperty('secondary-sid', _secondarySid!);
        await np.setProperty('secondary-sub-visibility', 'yes');
      } else {
        // 确保没有次字幕时关闭次字幕显示，避免双字幕问题
        await np.setProperty('secondary-sub-visibility', 'no');
      }
    } catch (e) {
      _logger.e('MpvAdapter', '设置运行时字幕属性失败: $e');
    }
  }

  @override
  Future<void> loadLibassSubtitleMemory(Uint8List data,
      {String codec = 'ass'}) async {
    _logger.i('MpvAdapter', '加载内存字幕 - codec=$codec, size=${data.length} bytes');
    if (_player == null) return;
    try {
      final dataStr = utf8.decode(data, allowMalformed: true);
      _currentSubIsAss = codec.contains('ass') || codec.contains('ssa');
      _hasBitmapSubtitle = codec.contains('pgs') ||
          codec.contains('sup') ||
          codec.contains('hdmv');
      if (!_currentSubIsAss && !_hasBitmapSubtitle) {
        _currentSubIsAss =
            dataStr.contains('[V4+ Styles]') || dataStr.contains('[V4 Styles]');
      }
      await _player!.setSubtitleTrack(
        SubtitleTrack.data(dataStr, title: 'subtitle', language: 'und'),
      );
      await _applySubtitleRuntimeProperties();
    } catch (e, stackTrace) {
      _logger.eWithStack('MpvAdapter', '内存字幕加载失败', e, stackTrace);
    }
  }

  @override
  Future<void> loadSecondarySubtitle(String path) async {
    if (_player == null || !_isInitialized) return;
    _logger.i('MpvAdapter', '加载次字幕: $path');
    try {
      final np = _nativePlayer;
      if (np != null) {
        await np.setProperty('secondary-sub-visibility', 'yes');

        final subtitleTracks = _player!.state.tracks.subtitle;
        final beforeCount = subtitleTracks.length;
        await np.command(
            ['sub-add', _toMpvSubtitleUri(path), 'auto', 'secondary', 'und']);

        SubtitleTrack? newTrack;
        for (int i = 0; i < 20; i++) {
          await Future.delayed(const Duration(milliseconds: 200));
          final afterTracks = _player!.state.tracks.subtitle;
          if (afterTracks.length > beforeCount) {
            newTrack = afterTracks.last;
            break;
          }
        }

        if (newTrack != null) {
          final sid = newTrack.id;
          _secondarySid = sid;
          _logger.i('MpvAdapter', '次字幕轨道ID: $sid, 设置secondary-sid=$sid');
          await np.setProperty('secondary-sid', sid);
        } else {
          _logger.w('MpvAdapter', '次字幕添加后未检测到新轨道，使用secondary-sid=auto兜底');
          await np.setProperty('secondary-sid', 'auto');
          _secondarySid = 'auto';
        }
      }
      _logger.i('MpvAdapter', '次字幕加载成功: $path');
    } catch (e, stackTrace) {
      _logger.eWithStack('MpvAdapter', '次字幕加载失败', e, stackTrace);
    }
  }

  @override
  Future<void> deselectSecondarySubtitle() async {
    if (_player == null || !_isInitialized) return;
    _secondarySid = null;
    try {
      final np = _nativePlayer;
      if (np != null) {
        await np.setProperty('secondary-sid', 'no');
        await np.setProperty('secondary-sub-visibility', 'no');
      }
    } catch (e, stackTrace) {
      _logger.eWithStack('MpvAdapter', '取消次字幕失败', e, stackTrace);
    }
  }

  @override
  Future<void> selectSecondarySubtitleTrack(String trackId) async {
    if (_player == null || !_isInitialized) return;
    _logger.i('MpvAdapter', '选择内封次字幕轨道: id=$trackId');
    try {
      final np = _nativePlayer;
      if (np != null) {
        _secondarySid = trackId;
        await np.setProperty('secondary-sub-visibility', 'yes');
        await np.setProperty('secondary-sid', trackId);
        _logger.i('MpvAdapter', '内封次字幕已设置: secondary-sid=$trackId');
      }
    } catch (e, stackTrace) {
      _logger.eWithStack('MpvAdapter', '设置内封次字幕失败', e, stackTrace);
    }
  }

  @override
  Future<void> setSubtitleDelay(double seconds) async {
    _subtitleDelay = seconds;
    _logger.i('MpvAdapter', '设置字幕延迟: ${seconds}s');
    final np = _nativePlayer;
    if (np != null) {
      await np.setProperty('sub-delay', seconds.toStringAsFixed(3));
    }
    await _configManager.updateConfigValue(
        'sub-delay', seconds.toStringAsFixed(3));
  }

  @override
  Future<void> setAudioDelay(double seconds) async {
    _audioDelay = seconds;
    final np = _nativePlayer;
    if (np != null) {
      await np.setProperty('audio-delay', seconds.toStringAsFixed(3));
    }
    await _configManager.updateConfigValue(
        'audio-delay', seconds.toStringAsFixed(3));
  }

  @override
  Future<void> setSubtitleFont(String fontName) async {
    _subtitleFont = fontName == '默认' ? null : fontName;
    final np = _nativePlayer;
    if (np != null && _subtitleFont != null && _subtitleFont!.isNotEmpty) {
      await np.setProperty('sub-font', _subtitleFont!);
    }
    if (fontName.isNotEmpty && fontName != '默认') {
      await _configManager.updateConfigValue('sub-font', '"$fontName"');
    }
  }

  @override
  Future<void> setSubtitleSize(double size) async {
    _subtitleScale = 0.5 + size;
    _logger.i('MpvAdapter', '设置字幕大小: scale=$_subtitleScale');
    final np = _nativePlayer;
    if (np != null) {
      await np.setProperty('sub-scale', _subtitleScale.toStringAsFixed(2));
    }
    await _configManager.updateConfigValue(
        'sub-scale', _subtitleScale.toStringAsFixed(2));
  }

  @override
  Future<void> setSubtitlePosition(double position) async {
    _subtitlePosition = (100 - position * 100).clamp(0.0, 100.0);
    _logger.i('MpvAdapter', '设置字幕位置: pos=$_subtitlePosition');
    final np = _nativePlayer;
    if (np != null) {
      // PGS/SUP 与 ASS 保留轨道自身布局，只有普通文本字幕才覆盖位置。
      if (!_hasBitmapSubtitle && !_currentSubIsAss) {
        await np.setProperty('sub-pos', _subtitlePosition.toStringAsFixed(1));
      }
    }
    await _configManager.updateConfigValue(
        'sub-pos', _subtitlePosition.toStringAsFixed(1));
  }

  @override
  Future<void> setSubtitleBackground(bool enabled) async {
    _subtitleBackground = enabled;
    await _applySubtitleRuntimeProperties();
    await _configManager.updateConfigValue(
      'sub-back-color',
      enabled ? '#000000C0' : '#00000000',
    );
  }

  @override
  Future<void> setAspectRatio(String ratio) async {
    _aspectRatio = ratio;
    String value;
    switch (ratio) {
      case '16:9':
        value = '16/9';
      case '4:3':
        value = '4/3';
      case '21:9':
        value = '21/9';
      case '全屏':
        value = '-1';
      case '原始':
        value = '0';
      default:
        value = '-1';
    }
    final np = _nativePlayer;
    if (np != null) {
      await np.setProperty('video-aspect-override', value);
    }
    await _configManager.updateConfigValue('video-aspect-override', value);
  }

  static final Map<String, List<String>> _anime4KShaderPresets = {
    'modeA': [
      'Anime4K_Clamp_Highlights.glsl',
      'Anime4K_Restore_CNN_S.glsl',
      'Anime4K_Upscale_CNN_x2_S.glsl',
    ],
    'modeB': [
      'Anime4K_Clamp_Highlights.glsl',
      'Anime4K_Restore_CNN_M.glsl',
      'Anime4K_Upscale_CNN_x2_M.glsl',
      'Anime4K_AutoDownscalePre_x2.glsl',
      'Anime4K_AutoDownscalePre_x4.glsl',
      'Anime4K_Upscale_CNN_x2_S.glsl',
    ],
    'modeC': [
      'Anime4K_Clamp_Highlights.glsl',
      'Anime4K_Restore_CNN_VL.glsl',
      'Anime4K_Upscale_CNN_x2_VL.glsl',
      'Anime4K_AutoDownscalePre_x2.glsl',
      'Anime4K_AutoDownscalePre_x4.glsl',
      'Anime4K_Upscale_CNN_x2_M.glsl',
    ],
  };

  @override
  Future<void> applySuperResolution(bool enable) async {
    _glslShaders = enable ? _anime4KShaderPresets['modeB'] : null;
    await _applyShaderList(_glslShaders);
  }

  @override
  Future<void> applySuperResolutionLevel(String level) async {
    _glslShaders = level == 'off'
        ? null
        : (_anime4KShaderPresets[level] ?? _anime4KShaderPresets['modeB']);
    await _applyShaderList(_glslShaders);
  }

  @override
  Future<Map<String, String>> getPlaybackStats() async {
    final np = _nativePlayer;
    if (np == null) return {};

    final props = [
      'width',
      'height',
      'fps',
      'container-fps',
      'video-bitrate',
      'audio-bitrate',
      'video-codec',
      'audio-codec',
      'audio-params/channel-count',
      'audio-params/sample-rate',
      'file-size',
      'path',
      'demuxer-cache-duration',
      'cache-speed',
      'paused-for-cache',
      'cache-buffering-state',
      'demuxer-cache-state',
      'decoder-frame-drop-count',
      'frame-drop-count',
      'hwdec-current',
      'video-params/pixelformat',
      'estimated-vf-fps',
      'vo-drop-frame-count',
      'vo-delayed-frame-count',
      'current-tracks/video/codec',
      'current-tracks/audio/codec',
      'current-tracks/video/default-bitrate',
      'current-tracks/audio/default-bitrate',
    ];

    final stats = <String, String>{};
    for (final prop in props) {
      try {
        final value = await np.getProperty(prop);
        if (value.isNotEmpty && value != 'null') {
          stats[prop] = value;
        }
      } catch (_) {
        // 某些属性可能不存在，忽略错误
      }
    }
    return stats;
  }

  @override
  Widget buildVideo() {
    if (_videoController != null) {
      // 返回缓存实例：identical(old, new) 时 Flutter 会跳过该子树重建，
      // 避免控制栏/选项弹出引起的视频纹理重挂载闪现。
      // RepaintBoundary 进一步隔离上层覆盖层的重绘，不波及视频层。
      return _videoWidget ??= RepaintBoundary(
        child: Video(
          controller: _videoController!,
          fit: BoxFit.contain,
          controls: null,
          // Keep Flutter's text subtitle overlay disabled.
          // We rely on mpv's native subtitle pipeline to avoid duplicate ASS
          // rendering and to preserve bitmap subtitle support.
          subtitleViewConfiguration:
              const SubtitleViewConfiguration(visible: false),
        ),
      );
    }
    return const Center(child: CircularProgressIndicator());
  }

  @override
  Future<void> play() async {
    if (_player == null) return;
    await _player!.play();
    _isCompleted = false;
  }

  @override
  Future<void> pause() async {
    if (_player == null) return;
    await _player!.pause();
  }

  @override
  Future<void> seekTo(Duration position) async {
    if (_player == null || !_isInitialized) return;
    final clamped = Duration(
      milliseconds:
          max(0, min(position.inMilliseconds, _duration.inMilliseconds)),
    );
    _beginSeekBuffering();
    _startSeekBufferingMonitor();
    await _player!.seek(clamped);
    final np = _nativePlayer;
    if (np != null) {
      try {
        final stillBuffering = await _isCacheStillBuffering();
        if (!stillBuffering) {
          _completeSeekBuffering();
        }
      } catch (_) {
        // Ignore property probing failures and let the fallback timer clear state.
      }
    }
    _isCompleted = false;
  }

  @override
  Future<void> setSpeed(double speed) async {
    if (_player == null || !_isInitialized) return;
    final clamped = speed.clamp(0.25, 4.0);
    await _player!.setRate(clamped);
    _speed = clamped;
  }

  @override
  Future<void> setVolume(double volume) async {
    if (_player == null || !_isInitialized) return;
    final clamped = volume.clamp(0.0, 1.0);
    await _player!.setVolume(clamped * 100);
    _volume = clamped;
  }

  @override
  Future<Uint8List?> screenshot() async {
    if (_player == null) return null;
    try {
      return await _player!.screenshot();
    } catch (e, stackTrace) {
      _logger.eWithStack('MpvAdapter', '截图失败', e, stackTrace);
      return null;
    }
  }

  @override
  Future<void> dispose() async {
    _seekBufferingPollTimer?.cancel();
    _seekBufferingPollTimer = null;
    _seekBufferingFallbackTimer?.cancel();
    _seekBufferingFallbackTimer = null;
    for (final sub in _subscriptions) {
      await sub.cancel();
    }
    _subscriptions.clear();
    if (_player != null) {
      await _player!.dispose();
      _player = null;
    }
    _videoController = null;
    _videoWidget = null;
    _isInitialized = false;
    _isPlaying = false;
    _isBuffering = false;
    _position = Duration.zero;
    _duration = Duration.zero;
    _tracks = [];
    _subtitleTracks = [];
    _audioTracks = [];
    _secondarySid = null;
    _hasBitmapSubtitle = false;
    _currentSubIsAss = false;
    _usingExternalSubtitle = false;
    _isSeekBuffering = false;
    _isSeekInFlight = false;
    _selectedSubtitleTrackId = null;
    _selectedNativeSubtitleSid = null;
    _selectedAudioTrackId = null;
    _errorMessage = null;
  }
}
