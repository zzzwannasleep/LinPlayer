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

  PlayerConfiguration _config({
    required bool isTv,
    required bool hardwareDecode,
  }) {
    final platform = defaultTargetPlatform;
    final isAndroid = !kIsWeb && platform == TargetPlatform.android;
    final isDesktop = !kIsWeb &&
        (platform == TargetPlatform.windows ||
            platform == TargetPlatform.linux ||
            platform == TargetPlatform.macOS);

    return PlayerConfiguration(
      vo: isAndroid || isDesktop ? 'gpu' : null,
      osc: false,
      title: 'LinPlayer',
      logLevel: MPVLogLevel.warn,
      bufferSize: isTv ? 100 * 1024 * 1024 : 150 * 1024 * 1024,
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
    );
  }

  Future<void> initialize(
    String? path, {
    String? networkUrl,
    bool isTv = false,
    bool hardwareDecode = true,
  }) async {
    await dispose();
    MediaKit.ensureInitialized();
    final player = Player(
      configuration: _config(
        isTv: isTv,
        hardwareDecode: hardwareDecode,
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
        await player.open(Media(networkUrl));
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
