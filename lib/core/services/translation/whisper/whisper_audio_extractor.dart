import 'dart:io';

import 'package:path_provider/path_provider.dart';

import '../../app_logger.dart';

/// 用 ffmpeg 抽取一段音频为 Whisper 所需的 16kHz 单声道 WAV。
///
/// libmpv 内含 ffmpeg 但未单独暴露可执行文件，故走外部 ffmpeg：优先用设置里
/// 指定的路径，否则尝试 PATH 中的 `ffmpeg`。支持从 HTTP 流（带 Emby 鉴权头）
/// 直接抽取，无需先下载整片。
class WhisperAudioExtractor {
  WhisperAudioExtractor({String? ffmpegPath, AppLogger? logger})
      : _ffmpeg = (ffmpegPath != null && ffmpegPath.isNotEmpty)
            ? ffmpegPath
            : 'ffmpeg',
        _logger = logger ?? AppLogger();

  final String _ffmpeg;
  final AppLogger _logger;
  static const _tag = 'WhisperAudio';

  /// ffmpeg 是否可用（用于设置页探测）。
  Future<bool> isAvailable() async {
    try {
      final r = await Process.run(_ffmpeg, ['-version']);
      return r.exitCode == 0;
    } catch (_) {
      return false;
    }
  }

  /// 抽取 [source] 自 [start] 起、时长 [duration] 的音频段。
  /// 返回生成的 WAV 路径。[authToken] 用于 Emby 流鉴权。
  Future<String> extractSegment({
    required String source,
    required Duration start,
    required Duration duration,
    String? authToken,
    int? audioStreamIndex,
  }) async {
    final dir = await _workDir();
    final out =
        '${dir.path}/seg_${start.inMilliseconds}_${duration.inMilliseconds}.wav';

    final args = <String>[
      '-y',
      '-loglevel', 'error',
      if (authToken != null && source.startsWith('http')) ...[
        '-headers',
        'X-Emby-Token: $authToken\r\nX-MediaBrowser-Token: $authToken\r\n',
      ],
      '-ss', _fmt(start),
      '-t', _fmt(duration),
      '-i', source,
      if (audioStreamIndex != null) ...['-map', '0:a:$audioStreamIndex'],
      '-vn',
      '-ar', '16000',
      '-ac', '1',
      '-f', 'wav',
      out,
    ];

    _logger.i(_tag, 'ffmpeg 抽取音频段 @${_fmt(start)} +${_fmt(duration)}');
    final result = await Process.run(_ffmpeg, args);
    if (result.exitCode != 0) {
      throw StateError('ffmpeg 抽取失败(${result.exitCode}): ${result.stderr}');
    }
    final file = File(out);
    if (!file.existsSync() || await file.length() < 1024) {
      throw StateError('ffmpeg 输出为空: $out');
    }
    return out;
  }

  static String _fmt(Duration d) {
    final h = d.inHours;
    final m = d.inMinutes % 60;
    final s = d.inSeconds % 60;
    final ms = d.inMilliseconds % 1000;
    String p2(int n) => n.toString().padLeft(2, '0');
    String p3(int n) => n.toString().padLeft(3, '0');
    return '${p2(h)}:${p2(m)}:${p2(s)}.${p3(ms)}';
  }

  Future<Directory> _workDir() async {
    final base = await getTemporaryDirectory();
    final dir = Directory('${base.path}/whisper_audio');
    if (!dir.existsSync()) dir.createSync(recursive: true);
    return dir;
  }
}
