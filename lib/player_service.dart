import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';

class PlayerService {
  Player? _player;
  VideoController? _controller;
  StreamSubscription<String>? _errorSub;

  Player get player => _player!;
  VideoController get controller => _controller!;
  bool get isInitialized => _player != null && _controller != null;

  Duration get position => _player?.state.position ?? Duration.zero;
  Duration get duration => _player?.state.duration ?? Duration.zero;
  bool get isPlaying => _player?.state.playing ?? false;

  static int _mb(int value) => value * 1024 * 1024;

  PlayerConfiguration _config({
    required bool isTv,
    required bool hardwareDecode,
    required bool isNetwork,
    required int mpvCacheSizeMb,
    required bool dolbyVisionMode,
  }) {
    final platform = defaultTargetPlatform;
    final isAndroid = !kIsWeb && platform == TargetPlatform.android;
    final isWindows = !kIsWeb && platform == TargetPlatform.windows;
    final isDesktop = !kIsWeb &&
        (platform == TargetPlatform.windows ||
            platform == TargetPlatform.linux ||
            platform == TargetPlatform.macOS);

    // Notes:
    // - `media_kit` maps `bufferSize` to both `demuxer-max-bytes` & `demuxer-max-back-bytes`.
    //   For network playback we prefer a larger *forward* cache, while keeping the backward
    //   cache smaller to avoid excessive memory usage.
    final cacheMb = mpvCacheSizeMb.clamp(200, 2048);
    final bufferSize = _mb(cacheMb);
    final networkDemuxerMaxBytes = bufferSize;
    final networkDemuxerMaxBackBytes =
        (bufferSize ~/ 4).clamp(_mb(32), _mb(256)).toInt();

    return PlayerConfiguration(
      vo: isAndroid || isDesktop ? (dolbyVisionMode ? 'gpu-next' : 'gpu') : null,
      osc: false,
      title: 'LinPlayer',
      logLevel: MPVLogLevel.warn,
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
        // `auto` enables zero-copy hardware decoding where possible (often smoother than copy-back).
        if (dolbyVisionMode)
          'hwdec=no'
        else
          (hardwareDecode ? (isAndroid ? 'hwdec=mediacodec-copy' : 'hwdec=auto') : 'hwdec=no'),
        'tls-verify=no',
        if (dolbyVisionMode && isAndroid) 'gpu-context=android',
        if (dolbyVisionMode && isAndroid) 'gpu-api=opengl',
        if (dolbyVisionMode) 'target-colorspace-hint=auto',
        // Avoid on-disk cache writes for network streams; prefer RAM cache + tuned demuxer buffer.
        if (isNetwork) 'cache-on-disk=no',
        if (isNetwork) 'demuxer-max-bytes=$networkDemuxerMaxBytes',
        if (isNetwork) 'demuxer-max-back-bytes=$networkDemuxerMaxBackBytes',
        // Reduce stutter on Windows by forcing a D3D11 GPU context for `vo=gpu`.
        if (isWindows) 'gpu-context=d3d11',
      ],
    );
  }

  static bool _isDolbyVisionCodec(String? codec) {
    final c = (codec ?? '').toLowerCase();
    return c.contains('dvhe') || c.contains('dvh1') || c.contains('dovi');
  }

  Future<bool> _isDolbyVision(Player player) async {
    try {
      final profile = await (player.platform as dynamic).getProperty(
        'current-tracks/video/dolby-vision-profile',
      );
      if (profile.trim().isNotEmpty && profile.trim() != '0') return true;
    } catch (_) {}

    final tracks = player.state.tracks;
    for (final v in tracks.video) {
      if (_isDolbyVisionCodec(v.codec)) return true;
      if ((v.title ?? '').toLowerCase().contains('dolby')) return true;
      if ((v.decoder ?? '').toLowerCase().contains('dolby')) return true;
    }
    return false;
  }

  Future<void> initialize(
    String? path, {
    String? networkUrl,
    Map<String, String>? httpHeaders,
    bool isTv = false,
    bool hardwareDecode = true,
    int mpvCacheSizeMb = 500,
    bool dolbyVisionMode = false,
  }) async {
    await dispose();
    MediaKit.ensureInitialized();
    final isNetwork = networkUrl != null && networkUrl.isNotEmpty;
    final player = Player(
      configuration: _config(
        isTv: isTv,
        hardwareDecode: hardwareDecode,
        isNetwork: isNetwork,
        mpvCacheSizeMb: mpvCacheSizeMb,
        dolbyVisionMode: dolbyVisionMode,
      ),
    );
    final controller = VideoController(player);
    _player = player;
    _controller = controller;
    _errorSub = player.stream.error.listen((message) {
      debugPrint('Player error: $message');
    });

    try {
      if (networkUrl != null && networkUrl.isNotEmpty) {
        await player.open(Media(networkUrl, httpHeaders: httpHeaders));
      } else if (path != null && path.isNotEmpty) {
        await player.open(Media(path));
      } else {
        throw Exception('No media source provided');
      }

      // Best-effort: Dolby Vision workaround on Android.
      // Many devices show green/purple tint with DV when hwdec is enabled or vo isn't gpu-next.
      if (!dolbyVisionMode &&
          !kIsWeb &&
          defaultTargetPlatform == TargetPlatform.android) {
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
            dolbyVisionMode: true,
          );
        }
      }
    } catch (_) {
      await dispose();
      rethrow;
    }
  }

  Future<void> play() => _player!.play();
  Future<void> pause() => _player!.pause();
  Future<void> seek(Duration pos) => _player!.seek(pos);

  Future<void> dispose() async {
    await _errorSub?.cancel();
    _errorSub = null;
    final player = _player;
    _player = null;
    _controller = null;
    if (player != null) {
      await player.dispose();
    }
  }
}

PlayerService getPlayerService() => PlayerService();
