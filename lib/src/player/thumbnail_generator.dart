import 'dart:async';
import 'dart:collection';
import 'dart:typed_data';

import 'package:media_kit/media_kit.dart';

/// Best-effort thumbnail generator using a dedicated background `Player`.
///
/// This avoids seeking the main player while scrubbing.
class MediaKitThumbnailGenerator {
  MediaKitThumbnailGenerator({
    required this.media,
    this.maxCacheEntries = 120,
  });

  final Media media;
  final int maxCacheEntries;

  Player? _player;
  Future<void>? _openFuture;

  final LinkedHashMap<int, Uint8List> _cache = LinkedHashMap();
  final Map<int, Future<Uint8List?>> _inFlight = {};

  PlayerConfiguration _config() {
    return const PlayerConfiguration(
      osc: false,
      title: 'LinPlayer Thumbnail',
      logLevel: MPVLogLevel.warn,
      protocolWhitelist: [
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
        // Smaller frames for faster scrubbing previews.
        'vf=scale=320:-2',
        // Avoid decoding audio/subtitles.
        'audio=no',
        'sub=no',
        // Keep everything in memory for previews.
        'cache-on-disk=no',
      ],
    );
  }

  Future<void> _ensureOpen() async {
    if (_openFuture != null) return _openFuture!;
    _openFuture = () async {
      MediaKit.ensureInitialized();
      final player = Player(configuration: _config());
      _player = player;
      await player.open(media, play: false);
    }();
    return _openFuture!;
  }

  static int _keyOf(Duration position) {
    // Match UI quantization (2s buckets) to maximize cache hits.
    final ms = position.inMilliseconds;
    return (ms ~/ 2000) * 2000;
  }

  void _touch(int key, Uint8List bytes) {
    _cache.remove(key);
    _cache[key] = bytes;
    while (_cache.length > maxCacheEntries) {
      _cache.remove(_cache.keys.first);
    }
  }

  Future<Uint8List?> getThumbnail(Duration position) {
    final key = _keyOf(position);
    final cached = _cache[key];
    if (cached != null) return Future.value(cached);
    final inFlight = _inFlight[key];
    if (inFlight != null) return inFlight;

    final future = _generate(key, position);
    _inFlight[key] = future;
    return future;
  }

  Future<Uint8List?> _generate(int key, Duration position) async {
    try {
      await _ensureOpen();
      final player = _player;
      if (player == null) return null;

      await player.seek(position);
      // Give mpv a brief moment to decode the seeked frame.
      await Future<void>.delayed(const Duration(milliseconds: 120));

      Uint8List? bytes = await player.screenshot(format: 'image/jpeg');
      if (bytes == null) {
        // Network seeks can take longer; retry once.
        await Future<void>.delayed(const Duration(milliseconds: 400));
        bytes = await player.screenshot(format: 'image/jpeg');
      }
      if (bytes != null) _touch(key, bytes);
      return bytes;
    } catch (_) {
      return null;
    } finally {
      _inFlight.remove(key);
    }
  }

  Future<void> dispose() async {
    _inFlight.clear();
    _cache.clear();
    _openFuture = null;
    final player = _player;
    _player = null;
    if (player != null) {
      await player.dispose();
    }
  }
}

