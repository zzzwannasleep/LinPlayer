import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';

import 'package:lin_player_core/app_config/app_config.dart';
import 'stream_cache.dart';
import 'src/external_player/external_mpv_launcher.dart';
import 'package:lin_player_prefs/preferences.dart';

class PlayerService {
  Player? _player;
  VideoController? _controller;
  StreamSubscription<String>? _errorSub;

  bool _externalPlayback = false;
  String? _externalPlaybackMessage;
  int? _demuxerMaxBackBytes;

  Player get player => _player!;
  VideoController get controller => _controller!;
  bool get isInitialized => _player != null && _controller != null;
  bool get isExternalPlayback => _externalPlayback;
  String? get externalPlaybackMessage => _externalPlaybackMessage;

  Duration get position => _player?.state.position ?? Duration.zero;
  Duration get duration => _player?.state.duration ?? Duration.zero;
  bool get isPlaying => _player?.state.playing ?? false;

  static int _mb(int value) => value * 1024 * 1024;

  VideoControllerConfiguration _videoConfig({
    required bool hardwareDecode,
    required bool dolbyVisionMode,
    required bool hdrMode,
  }) {
    final platform = defaultTargetPlatform;
    final isAndroid = !kIsWeb && platform == TargetPlatform.android;
    final hwdec = dolbyVisionMode || !hardwareDecode
        ? 'no'
        : (isAndroid ? 'mediacodec-copy' : 'auto-safe');
    final useGpuNext = isAndroid && (dolbyVisionMode || hdrMode);

    return VideoControllerConfiguration(
      // `vo` is platform specific: desktop uses `libmpv` (render API), Android uses `gpu`.
      // For HDR on Android, `gpu-next` may help fix incorrect colors on some files.
      vo: useGpuNext ? 'gpu-next' : null,
      hwdec: hwdec,
      enableHardwareAcceleration: true,
    );
  }

  PlayerConfiguration _config({
    required bool hardwareDecode,
    required bool isNetwork,
    required int mpvCacheSizeMb,
    required double bufferBackRatio,
    required bool dolbyVisionMode,
    required bool hdrMode,
    required bool unlimitedStreamCache,
    required int? networkStreamSizeBytes,
    required String? httpProxy,
  }) {
    final platform = defaultTargetPlatform;
    final isAndroid = !kIsWeb && platform == TargetPlatform.android;
    final isWindows = !kIsWeb && platform == TargetPlatform.windows;
    final useGpuNext = isAndroid && (dolbyVisionMode || hdrMode);

    final cacheMb = mpvCacheSizeMb.clamp(200, 2048);
    final split = PlaybackBufferSplit.from(
      totalMb: cacheMb,
      backRatio: bufferBackRatio,
    );
    final bufferSize = split.totalBytes;

    final effectiveStreamBytes = (unlimitedStreamCache && isNetwork)
        ? (networkStreamSizeBytes != null && networkStreamSizeBytes > 0
            ? networkStreamSizeBytes
            : _mb(8192))
        : bufferSize;
    final networkDemuxerMaxBytes = effectiveStreamBytes;
    final networkDemuxerMaxBackBytes =
        split.backBytes.clamp(0, networkDemuxerMaxBytes).toInt();
    _demuxerMaxBackBytes = networkDemuxerMaxBackBytes;

    return PlayerConfiguration(
      osc: false,
      title: AppConfig.current.displayName,
      logLevel: MPVLogLevel.warn,
      libass: !kIsWeb,
      bufferSize: bufferSize,
      protocolWhitelist: const [
        'udp',
        'rtp',
        'tcp',
        'tls',
        'http',
        'https',
        'crypto',
        'data',
        'file',
        'fd',
        'content',
        'rtmp',
        'rtmps',
        'rtsp',
        'ftp',
      ],
      extraMpvOptions: [
        'tls-verify=no',
        if (isAndroid) 'sub-fonts-dir=/system/fonts',
        if (isNetwork && (httpProxy ?? '').trim().isNotEmpty)
          'http-proxy=${httpProxy!.trim()}',
        if (useGpuNext) 'gpu-context=android',
        if (useGpuNext) 'gpu-api=opengl',
        if (dolbyVisionMode || hdrMode) 'target-colorspace-hint=yes',
        if (hdrMode) 'tone-mapping=bt.2390',
        if (hdrMode) 'hdr-compute-peak=yes',
        if (isNetwork && unlimitedStreamCache) ...[
          'cache-on-disk=yes',
          'cache-dir=${StreamCache.directory.path}',
        ],
        // Default: avoid on-disk cache writes for network streams; prefer RAM cache + tuned demuxer buffer.
        if (isNetwork && !unlimitedStreamCache) 'cache-on-disk=no',
        if (isNetwork) 'demuxer-max-bytes=$networkDemuxerMaxBytes',
        'demuxer-max-back-bytes=$networkDemuxerMaxBackBytes',
        // Reduce stutter on Windows by forcing a D3D11 GPU context for `vo=gpu`.
        if (isWindows && !dolbyVisionMode) 'gpu-context=d3d11',
      ],
    );
  }

  static bool _isDolbyVisionCodec(String? codec) {
    final c = (codec ?? '').toLowerCase();
    return c.contains('dvhe') || c.contains('dvh1') || c.contains('dovi');
  }

  static bool _isHdrTransfer(String? gamma) {
    final g = (gamma ?? '').toLowerCase().trim();
    if (g.isEmpty) return false;
    if (g == 'pq' || g == 'hlg') return true;
    if (g.contains('2084') || g.contains('smpte')) return true;
    if (g.contains('arib') || g.contains('std-b67')) return true;
    return false;
  }

  Future<String?> _tryGetProperty(Player player, String name) async {
    try {
      final value = await (player.platform as dynamic).getProperty(name);
      final s = value?.toString().trim();
      if (s == null || s.isEmpty) return null;
      return s;
    } catch (_) {
      return null;
    }
  }

  static double? _asDouble(dynamic value) {
    if (value is num) return value.toDouble();
    if (value is String) return double.tryParse(value.trim());
    return null;
  }

  static double? _readMpvNodeNumber(dynamic node, String key) {
    if (node == null) return null;

    if (node is Map) {
      final direct = node[key];
      final directNum = _asDouble(direct);
      if (directNum != null) return directNum;

      for (final entry in node.entries) {
        if (entry.key?.toString() == key) {
          return _asDouble(entry.value);
        }
      }
      return null;
    }

    if (node is String) {
      final s = node.trim();
      if (s.isEmpty) return null;
      final directNum = double.tryParse(s);
      if (directNum != null) return directNum;
      try {
        return _readMpvNodeNumber(jsonDecode(s), key);
      } catch (_) {
        return null;
      }
    }

    return null;
  }

  Future<double?> queryNetworkInputRateBytesPerSecond() async {
    final player = _player;
    if (player == null) return null;

    final platform = player.platform as dynamic;

    try {
      final state = await platform.getProperty('demuxer-cache-state');
      final rate = _readMpvNodeNumber(state, 'raw-input-rate') ??
          _readMpvNodeNumber(state, 'raw_input_rate') ??
          _readMpvNodeNumber(state, 'cache-speed') ??
          _readMpvNodeNumber(state, 'cache_speed');
      if (rate != null) return rate;
    } catch (_) {}

    try {
      final rate = await platform.getProperty('cache-speed');
      return _asDouble(rate);
    } catch (_) {
      return null;
    }
  }

  Future<Tracks> _waitForTracks(Player player) async {
    final current = player.state.tracks;
    if (current.video.isNotEmpty ||
        current.audio.isNotEmpty ||
        current.subtitle.isNotEmpty) {
      return current;
    }

    try {
      return await player.stream.tracks
          .firstWhere((t) =>
              t.video.isNotEmpty || t.audio.isNotEmpty || t.subtitle.isNotEmpty)
          .timeout(const Duration(seconds: 2));
    } catch (_) {
      return current;
    }
  }

  Future<VideoParams> _waitForVideoParams(Player player) async {
    final current = player.state.videoParams;
    bool hasSignal(VideoParams p) =>
        (p.colormatrix ?? '').trim().isNotEmpty ||
        (p.colorlevels ?? '').trim().isNotEmpty ||
        (p.primaries ?? '').trim().isNotEmpty ||
        (p.gamma ?? '').trim().isNotEmpty ||
        (p.pixelformat ?? '').trim().isNotEmpty ||
        (p.hwPixelformat ?? '').trim().isNotEmpty;

    if (hasSignal(current)) return current;

    try {
      return await player.stream.videoParams
          .firstWhere((p) => hasSignal(p))
          .timeout(const Duration(seconds: 2));
    } catch (_) {
      return current;
    }
  }

  Future<bool> _isDolbyVision(Player player) async {
    final videoParams = await _waitForVideoParams(player);
    final matrix = (videoParams.colormatrix ?? '').toLowerCase().trim();
    if (matrix == 'dolbyvision') return true;

    final profile = await _tryGetProperty(
          player,
          'current-tracks/video/dolby-vision-profile',
        ) ??
        await _tryGetProperty(player, 'video-params/dolby-vision-profile');
    if (profile != null && profile != '0') return true;

    final tracks = await _waitForTracks(player);
    for (final v in tracks.video) {
      if (_isDolbyVisionCodec(v.codec)) return true;
      if ((v.title ?? '').toLowerCase().contains('dolby')) return true;
      if ((v.decoder ?? '').toLowerCase().contains('dolby')) return true;
    }
    return false;
  }

  Future<bool> _isHdr(Player player) async {
    final videoParams = await _waitForVideoParams(player);
    final matrix = (videoParams.colormatrix ?? '').toLowerCase().trim();
    if (matrix == 'dolbyvision') return false;

    final gamma = (videoParams.gamma ?? '').toLowerCase().trim();
    if (_isHdrTransfer(gamma)) return true;

    final primaries = (videoParams.primaries ?? '').toLowerCase().trim();
    final wideGamut = primaries.contains('bt.2020') ||
        primaries.contains('bt2020') ||
        primaries.contains('2020');
    return wideGamut && gamma.isNotEmpty && gamma != 'bt.1886';
  }

  Future<int?> _dolbyVisionProfile(Player player) async {
    String? profile = await _tryGetProperty(
          player,
          'current-tracks/video/dolby-vision-profile',
        ) ??
        await _tryGetProperty(player, 'video-params/dolby-vision-profile');

    if (profile != null) {
      profile = profile.trim();
      // mpv may expose values like "5" or "8.1". We only need the major.
      final major = int.tryParse(profile.split('.').first);
      if (major != null && major > 0) return major;
    }

    final tracks = await _waitForTracks(player);
    for (final v in tracks.video) {
      final codec = (v.codec ?? '').toLowerCase();
      final m = RegExp(r'(?:dvhe|dvh1)\.(\d{2})').firstMatch(codec);
      if (m != null) {
        final p = int.tryParse(m.group(1)!);
        if (p != null && p > 0) return p;
      }
    }

    return null;
  }

  Future<void> initialize(
    String? path, {
    String? networkUrl,
    Map<String, String>? httpHeaders,
    bool isTv = false,
    bool hardwareDecode = true,
    int mpvCacheSizeMb = 500,
    double bufferBackRatio = 0.05,
    bool unlimitedStreamCache = false,
    int? networkStreamSizeBytes,
    bool dolbyVisionMode = false,
    bool hdrMode = false,
    String? externalMpvPath,
    String? httpProxy,
  }) async {
    await dispose();
    _externalPlayback = false;
    _externalPlaybackMessage = null;
    MediaKit.ensureInitialized();

    var effectivePath = path;
    var effectiveNetworkUrl = networkUrl;

    if ((effectiveNetworkUrl == null || effectiveNetworkUrl.trim().isEmpty) &&
        effectivePath != null &&
        effectivePath.trim().isNotEmpty) {
      final uri = Uri.tryParse(effectivePath.trim());
      if (uri != null &&
          (uri.scheme == 'http' || uri.scheme == 'https') &&
          uri.host.isNotEmpty) {
        effectiveNetworkUrl = effectivePath.trim();
        effectivePath = null;
      }
    }

    final isNetwork =
        effectiveNetworkUrl != null && effectiveNetworkUrl.isNotEmpty;
    if (isNetwork && unlimitedStreamCache) {
      await StreamCache.ensureDirectory();
    }
    final player = Player(
      configuration: _config(
        hardwareDecode: hardwareDecode,
        isNetwork: isNetwork,
        mpvCacheSizeMb: mpvCacheSizeMb,
        bufferBackRatio: bufferBackRatio,
        dolbyVisionMode: dolbyVisionMode,
        hdrMode: hdrMode,
        unlimitedStreamCache: unlimitedStreamCache,
        networkStreamSizeBytes: networkStreamSizeBytes,
        httpProxy: httpProxy,
      ),
    );
    final controller = VideoController(
      player,
      configuration: _videoConfig(
        hardwareDecode: hardwareDecode,
        dolbyVisionMode: dolbyVisionMode,
        hdrMode: hdrMode,
      ),
    );
    _player = player;
    _controller = controller;
    _errorSub = player.stream.error.listen((message) {
      debugPrint('Player error: $message');
    });

    try {
      if (effectiveNetworkUrl != null && effectiveNetworkUrl.isNotEmpty) {
        await player.open(Media(effectiveNetworkUrl, httpHeaders: httpHeaders));
      } else if (effectivePath != null && effectivePath.isNotEmpty) {
        await player.open(Media(effectivePath));
      } else {
        throw Exception('No media source provided');
      }

      // Desktop workaround: libmpv render API (vo=libmpv) cannot use gpu-next for Dolby Vision reshaping.
      // For common single-layer Dolby Vision (Profile 5), launching external mpv is the only reliable fix.
      if (!kIsWeb) {
        final platform = defaultTargetPlatform;
        final isDesktop = platform == TargetPlatform.windows ||
            platform == TargetPlatform.linux ||
            platform == TargetPlatform.macOS;
        if (isDesktop) {
          final dvProfile = await _dolbyVisionProfile(player);
          if (dvProfile == 5) {
            final source = (networkUrl != null && networkUrl.isNotEmpty)
                ? networkUrl
                : (path ?? '');
            if (source.isNotEmpty) {
              final launched = await launchExternalMpv(
                executablePath: externalMpvPath,
                source: source,
                httpHeaders: httpHeaders,
              );
              if (launched) {
                _externalPlayback = true;
                _externalPlaybackMessage =
                    '检测到杜比视界（Profile 5），已尝试使用外部 mpv 播放。可在设置里选择 mpv 可执行文件。';
                await _errorSub?.cancel();
                _errorSub = null;
                _player = null;
                _controller = null;
                await player.dispose();
                return;
              }
            }
          }
        }
      }

      // Best-effort: Dolby Vision workaround on Android & desktop.
      // Many devices show green/purple tint with DV when hwdec is enabled or vo isn't gpu-next.
      if (!dolbyVisionMode && !kIsWeb) {
        final platform = defaultTargetPlatform;
        final isSupportedPlatform = platform == TargetPlatform.android ||
            platform == TargetPlatform.windows ||
            platform == TargetPlatform.linux ||
            platform == TargetPlatform.macOS;
        if (isSupportedPlatform) {
          final isDv = await _isDolbyVision(player);
          if (isDv) {
            await dispose();
            return initialize(
              path,
              networkUrl: networkUrl,
              httpHeaders: httpHeaders,
              isTv: isTv,
              hardwareDecode: false,
              mpvCacheSizeMb: mpvCacheSizeMb,
              bufferBackRatio: bufferBackRatio,
              unlimitedStreamCache: unlimitedStreamCache,
              networkStreamSizeBytes: networkStreamSizeBytes,
              dolbyVisionMode: true,
              hdrMode: false,
            );
          }
        }
      }

      // Best-effort: HDR (PQ/HLG) workaround.
      // Some builds/devices show incorrect colors on HDR content unless using gpu-next + proper colorspace hints.
      if (!hdrMode && !dolbyVisionMode && !kIsWeb) {
        final platform = defaultTargetPlatform;
        final isSupportedPlatform = platform == TargetPlatform.android ||
            platform == TargetPlatform.windows ||
            platform == TargetPlatform.linux ||
            platform == TargetPlatform.macOS;
        if (isSupportedPlatform) {
          final isHdr = await _isHdr(player);
          if (isHdr) {
            await dispose();
            return initialize(
              path,
              networkUrl: networkUrl,
              httpHeaders: httpHeaders,
              isTv: isTv,
              hardwareDecode: hardwareDecode,
              mpvCacheSizeMb: mpvCacheSizeMb,
              bufferBackRatio: bufferBackRatio,
              unlimitedStreamCache: unlimitedStreamCache,
              networkStreamSizeBytes: networkStreamSizeBytes,
              dolbyVisionMode: false,
              hdrMode: true,
              externalMpvPath: externalMpvPath,
            );
          }
        }
      }
    } catch (_) {
      await dispose();
      rethrow;
    }
  }

  Future<void> play() => _player!.play();
  Future<void> pause() => _player!.pause();
  Future<void> seek(Duration pos, {bool flushBuffer = false}) async {
    final player = _player;
    if (player == null) return;
    if (!flushBuffer) {
      await player.seek(pos);
      return;
    }

    final platform = player.platform as dynamic;
    try {
      await platform.setProperty('demuxer-max-back-bytes', '0');
    } catch (_) {}

    await player.seek(pos);

    final restore = _demuxerMaxBackBytes;
    if (restore != null) {
      try {
        await platform.setProperty('demuxer-max-back-bytes', '$restore');
      } catch (_) {}
    }
  }

  Future<void> dispose() async {
    await _errorSub?.cancel();
    _errorSub = null;
    _externalPlayback = false;
    _externalPlaybackMessage = null;
    _demuxerMaxBackBytes = null;
    final player = _player;
    _player = null;
    _controller = null;
    if (player != null) {
      await player.dispose();
    }
  }
}

PlayerService getPlayerService() => PlayerService();
