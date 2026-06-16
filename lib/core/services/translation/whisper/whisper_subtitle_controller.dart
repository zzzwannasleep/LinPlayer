import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:path_provider/path_provider.dart';

import '../../app_logger.dart';
import '../subtitle_document.dart';
import '../subtitle_translation_service.dart';
import '../translation_engine.dart';
import 'whisper_audio_extractor.dart';
import 'whisper_transcriber.dart';

/// Whisper 流式字幕控制器（PC 端）。
///
/// 边播边转写：以滚动窗口在播放头前方抽取音频段 → whisper 转写 → 经翻译引擎
/// 译成中文 → 合并进累积文档 → 重写同一个 SRT 文件并回调，让播放器重新加载，
/// 从而实现「随播放实时出字幕」。一次只处理一个窗口（whisper 为 CPU 密集型）。
class WhisperSubtitleController {
  WhisperSubtitleController({
    required this.engine,
    required this.translationService,
    required this.extractor,
    required this.transcriber,
    required this.sourceLang,
    required this.targetLang,
    required this.layout,
    required this.onSubtitleUpdated,
    AppLogger? logger,
    this.windowSize = const Duration(seconds: 30),
    this.lookahead = const Duration(seconds: 20),
  }) : _logger = logger ?? AppLogger();

  final TranslationEngine engine;
  final SubtitleTranslationService translationService;
  final WhisperAudioExtractor extractor;
  final WhisperTranscriber transcriber;
  final String sourceLang;
  final String targetLang;
  final BilingualLayout layout;

  /// 每次累积字幕文件就绪后回调，参数为 SRT 路径（路径稳定不变）。
  final void Function(String path) onSubtitleUpdated;

  final Duration windowSize;
  final Duration lookahead;
  final AppLogger _logger;
  static const _tag = 'WhisperStream';

  final List<SubtitleCue> _cues = [];
  Duration _nextStart = Duration.zero;
  bool _running = false;
  bool _processing = false;
  String? _outputPath;

  bool get isRunning => _running;

  /// 启动流式转写。[positionGetter] 返回当前播放位置，[total] 为总时长。
  Future<void> start({
    required String source,
    required Duration total,
    required Duration Function() positionGetter,
    String? authToken,
    int? audioStreamIndex,
  }) async {
    if (_running) return;
    _running = true;
    _outputPath = await _resolveOutputPath(source);
    _logger.i(_tag, '流式转写启动 → $_outputPath');

    while (_running) {
      if (_nextStart >= total) {
        _logger.i(_tag, '已覆盖全片，流式转写结束');
        break;
      }
      final pos = positionGetter();
      // 播放头逼近未处理区域才推进，避免无谓地领先太多。
      if (pos + lookahead < _nextStart) {
        await Future.delayed(const Duration(seconds: 2));
        continue;
      }
      _processing = true;
      try {
        await _processWindow(
          source: source,
          total: total,
          authToken: authToken,
          audioStreamIndex: audioStreamIndex,
        );
      } catch (e) {
        _logger.w(_tag, '窗口处理失败，跳过 @${_nextStart.inSeconds}s: $e');
      } finally {
        _processing = false;
      }
      _nextStart += windowSize;
    }
    _running = false;
  }

  Future<void> _processWindow({
    required String source,
    required Duration total,
    String? authToken,
    int? audioStreamIndex,
  }) async {
    final remaining = total - _nextStart;
    final dur = remaining < windowSize ? remaining : windowSize;
    if (dur <= Duration.zero) return;

    final wav = await extractor.extractSegment(
      source: source,
      start: _nextStart,
      duration: dur,
      authToken: authToken,
      audioStreamIndex: audioStreamIndex,
    );
    final doc = await transcriber.transcribe(
      wav,
      offset: _nextStart,
      language: sourceLang,
    );
    if (doc.isEmpty) return;

    // 译成中文（复用批量管线的分块与容错）。
    await translationService.translateDocument(
      doc,
      engine: engine,
      sourceLang: sourceLang,
      targetLang: targetLang,
    );

    _cues.addAll(doc.cues);
    _cues.sort((a, b) => a.start.compareTo(b.start));
    await _flush();
  }

  Future<void> _flush() async {
    final path = _outputPath;
    if (path == null) return;
    final srt = SubtitleDocument(_cues).toSrt(layout: layout);
    await File(path).writeAsString(srt);
    onSubtitleUpdated(path);
  }

  void stop() {
    _running = false;
    _logger.i(_tag, '流式转写停止（已处理 ${_cues.length} 条）');
  }

  bool get isProcessing => _processing;

  Future<String> _resolveOutputPath(String source) async {
    final base = await getTemporaryDirectory();
    final dir = Directory('${base.path}/whisper_live');
    if (!dir.existsSync()) dir.createSync(recursive: true);
    final id = md5.convert(utf8.encode(source)).toString().substring(0, 12);
    return '${dir.path}/whisper_$id.srt';
  }
}
