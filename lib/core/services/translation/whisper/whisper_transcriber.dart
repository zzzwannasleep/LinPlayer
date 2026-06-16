import 'dart:io';

import 'package:path_provider/path_provider.dart';

import '../../app_logger.dart';
import '../subtitle_document.dart';

/// 调用 whisper.cpp 可执行文件把一段 WAV 转写为字幕。
///
/// 不内置二进制：用户在设置里指定 whisper-cli 路径（或放进 PATH）。转写产出
/// SRT，解析后按段起始时间整体平移，回到全片绝对时间轴。
class WhisperTranscriber {
  WhisperTranscriber({
    required this.modelPath,
    String? binaryPath,
    AppLogger? logger,
  })  : _binary = (binaryPath != null && binaryPath.isNotEmpty)
            ? binaryPath
            : 'whisper-cli',
        _logger = logger ?? AppLogger();

  final String modelPath;
  final String _binary;
  final AppLogger _logger;
  static const _tag = 'WhisperTranscribe';

  Future<bool> isAvailable() async {
    try {
      final r = await Process.run(_binary, ['--help']);
      return r.exitCode == 0;
    } catch (_) {
      return false;
    }
  }

  /// 转写 [wavPath]，[offset] 为该段在全片中的起始时间，[language] 为源语言
  /// （'auto' 自动检测）。返回平移到绝对时间轴后的字幕文档。
  Future<SubtitleDocument> transcribe(
    String wavPath, {
    required Duration offset,
    String language = 'auto',
    int threads = 4,
  }) async {
    final dir = await _workDir();
    final prefix = '${dir.path}/whisper_${offset.inMilliseconds}';
    final args = <String>[
      '-m', modelPath,
      '-f', wavPath,
      '-l', language,
      '-t', '$threads',
      '-osrt',
      '-of', prefix,
    ];

    _logger.i(_tag, 'whisper 转写 @${offset.inSeconds}s ($language)');
    final result = await Process.run(_binary, args);
    if (result.exitCode != 0) {
      throw StateError('whisper 转写失败(${result.exitCode}): ${result.stderr}');
    }

    final srtFile = File('$prefix.srt');
    if (!srtFile.existsSync()) {
      throw StateError('whisper 未产出字幕: $prefix.srt');
    }
    final content = await srtFile.readAsString();
    final doc = SubtitleDocument.parseString(content, ext: 'srt');
    // 平移到绝对时间轴。
    final shifted = doc.cues
        .map((c) => SubtitleCue(
              start: c.start + offset,
              end: c.end + offset,
              text: c.text,
            ))
        .toList();
    try {
      await srtFile.delete();
      await File(wavPath).delete();
    } catch (_) {}
    return SubtitleDocument(shifted);
  }

  Future<Directory> _workDir() async {
    final base = await getTemporaryDirectory();
    final dir = Directory('${base.path}/whisper_out');
    if (!dir.existsSync()) dir.createSync(recursive: true);
    return dir;
  }
}
