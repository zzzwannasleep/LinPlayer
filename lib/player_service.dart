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
    final bufferSize = isTv ? _mb(100) : _mb(150);
    final networkDemuxerMaxBytes = isTv ? _mb(192) : (isDesktop ? _mb(256) : _mb(192));
    final networkDemuxerMaxBackBytes = isTv ? _mb(48) : (isDesktop ? _mb(64) : _mb(32));

    return PlayerConfiguration(
      vo: isAndroid || isDesktop ? 'gpu' : null,
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
        hardwareDecode ? 'hwdec=auto' : 'hwdec=no',
        'tls-verify=no',
        // Avoid on-disk cache writes for network streams; prefer RAM cache + tuned demuxer buffer.
        if (isNetwork) 'cache-on-disk=no',
        if (isNetwork) 'demuxer-max-bytes=$networkDemuxerMaxBytes',
        if (isNetwork) 'demuxer-max-back-bytes=$networkDemuxerMaxBackBytes',
        // Reduce stutter on Windows by forcing a D3D11 GPU context for `vo=gpu`.
        if (isWindows) 'gpu-context=d3d11',
      ],
    );
  }

  Future<void> initialize(
    String? path, {
    String? networkUrl,
    Map<String, String>? httpHeaders,
    bool isTv = false,
    bool hardwareDecode = true,
  }) async {
    await dispose();
    MediaKit.ensureInitialized();
    final isNetwork = networkUrl != null && networkUrl.isNotEmpty;
    final player = Player(
      configuration: _config(
        isTv: isTv,
        hardwareDecode: hardwareDecode,
        isNetwork: isNetwork,
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
