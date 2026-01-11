import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';

class PlayerService {
  late final Player _player;
  late final VideoController _controller;
  bool _initialized = false;

  Player get player => _player;
  VideoController get controller => _controller;
  bool get isInitialized => _initialized;

  Duration get position => _player.state.position;
  Duration get duration => _player.state.duration;
  bool get isPlaying => _player.state.playing;

  PlayerConfiguration _config({
    required bool isTv,
    required bool hardwareDecode,
  }) {
    // 基于 mpv_PlayKit 思路的精简版：启用 gpu-next 输出、适度放大缓存、放宽协议白名单。
    return PlayerConfiguration(
      vo: 'gpu-next',
      osc: false,
      title: 'LinPlayer',
      logLevel: MPVLogLevel.warn,
      // 对标 mpv 配置里 demuxer-max-bytes=150MiB
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
        'rtmp',
        'rtmps',
        'rtsp',
        'ftp',
      ],
      extraMpvOptions: [
        'gpu-context=d3d11',
        hardwareDecode ? 'hwdec=auto-safe' : 'hwdec=no',
        'video-sync=audio',
        'scale=lanczos',
        'dscale=hermite',
        'sigmoid-upscaling=yes',
        'linear-downscaling=yes',
        'correct-downscaling=yes',
      ],
    );
  }

  Future<void> initialize(
    String? path, {
    String? networkUrl,
    bool isTv = false,
    bool hardwareDecode = true,
  }) async {
    _player = Player(configuration: _config(isTv: isTv, hardwareDecode: hardwareDecode));
    _controller = VideoController(_player);
    if (networkUrl != null) {
      await _player.open(Media(networkUrl));
    } else if (path != null) {
      await _player.open(Media(path));
    } else {
      throw Exception('No media source provided');
    }
    _initialized = true;
  }

  Future<void> play() => _player.play();
  Future<void> pause() => _player.pause();
  Future<void> seek(Duration pos) => _player.seek(pos);
  Future<void> dispose() async {
    await _player.dispose();
  }
}

PlayerService getPlayerService() => PlayerService();
