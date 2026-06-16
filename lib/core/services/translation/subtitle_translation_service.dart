import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:dio/dio.dart';
import 'package:path_provider/path_provider.dart';

import '../app_logger.dart';
import 'subtitle_document.dart';
import 'translation_engine.dart';

/// 翻译进度回调：[done] 已完成条数，[total] 总条数，[stage] 阶段描述。
typedef TranslationProgress = void Function(int done, int total, String stage);

/// 批量字幕翻译服务（AI / API 模式共用）。
///
/// 管线：下载/读取源字幕 → 解析为 cue → 按引擎能力分块并发翻译 → 序列化为
/// SRT → 写入缓存文件，返回路径供 `VideoPlayerService.loadLibassSubtitle` 加载。
/// 同一 (源, 引擎, 目标语言, 排版) 命中缓存直接复用，避免重复消耗额度。
class SubtitleTranslationService {
  SubtitleTranslationService({AppLogger? logger})
      : _logger = logger ?? AppLogger();

  final AppLogger _logger;
  static const _tag = 'SubtitleTranslate';

  /// 翻译远程/本地字幕文件，返回生成的中文 SRT 路径。
  Future<String> translateSubtitleUrl({
    required String url,
    required TranslationEngine engine,
    required String sourceLang,
    required String targetLang,
    required BilingualLayout layout,
    String? authToken,
    String cacheKeySeed = '',
    TranslationProgress? onProgress,
  }) async {
    final cacheDir = await _cacheDir();
    final cacheKey = _cacheKey(
        '$url|$cacheKeySeed', engine.id, sourceLang, targetLang, layout);
    final outFile = File('${cacheDir.path}/trans_$cacheKey.srt');
    if (outFile.existsSync() && await outFile.length() > 0) {
      _logger.i(_tag, '命中翻译缓存: ${outFile.path}');
      onProgress?.call(1, 1, '已使用缓存');
      return outFile.path;
    }

    onProgress?.call(0, 1, '下载字幕…');
    final raw = await _fetch(url, authToken);
    final ext = _extOf(url);
    final doc = SubtitleDocument.parseString(raw, ext: ext);
    _logger.i(
      _tag,
      '源字幕拉取完成: ${raw.length}字节, 解析 ${doc.cues.length} 条, '
      '引擎=${engine.id}, $sourceLang→$targetLang, ext=$ext',
    );
    if (doc.isEmpty) {
      throw StateError(
          '源字幕解析为空（拉取 ${raw.length} 字节）。该轨可能无法被服务端导出为文本');
    }

    await translateDocument(
      doc,
      engine: engine,
      sourceLang: sourceLang,
      targetLang: targetLang,
      onProgress: onProgress,
    );

    final srt = doc.toSrt(layout: layout);
    await outFile.writeAsString(srt);
    _logger.i(_tag, '翻译完成并写入: ${outFile.path}');
    return outFile.path;
  }

  /// 就地翻译一个已解析的文档（填充每条 cue 的 translatedText）。
  Future<SubtitleDocument> translateDocument(
    SubtitleDocument doc, {
    required TranslationEngine engine,
    required String sourceLang,
    required String targetLang,
    TranslationProgress? onProgress,
  }) async {
    final cues = doc.cues;
    final total = cues.length;
    final chunks = _chunk(cues, engine.maxBatchSize, engine.maxBatchChars);
    var done = 0;

    Future<void> runChunk(List<SubtitleCue> chunk) async {
      final translated = await _translateChunk(
        engine,
        chunk.map((c) => c.text).toList(),
        sourceLang: sourceLang,
        targetLang: targetLang,
      );
      for (var i = 0; i < chunk.length; i++) {
        chunk[i].translatedText = translated[i];
      }
      done += chunk.length;
      onProgress?.call(done, total, '翻译中…');
    }

    // 按引擎并发能力分批跑。
    final concurrency = engine.maxConcurrency.clamp(1, 8);
    for (var i = 0; i < chunks.length; i += concurrency) {
      final slice = chunks.skip(i).take(concurrency);
      await Future.wait(slice.map(runChunk));
    }
    return doc;
  }

  /// 翻译一块文本；遇到引擎抛错（如回包条数不齐）时二分重试，
  /// 单条仍失败则回退原文，保证不中断整体流程。
  Future<List<String>> _translateChunk(
    TranslationEngine engine,
    List<String> texts, {
    required String sourceLang,
    required String targetLang,
  }) async {
    if (texts.isEmpty) return const [];
    try {
      return await engine.translate(texts,
          sourceLang: sourceLang, targetLang: targetLang);
    } catch (e) {
      if (texts.length == 1) {
        _logger.w(_tag, '单条翻译失败，回退原文: $e');
        return [texts.first];
      }
      final mid = texts.length ~/ 2;
      _logger.w(_tag, '批次翻译失败，二分重试(${texts.length}条): $e');
      final left = await _translateChunk(engine, texts.sublist(0, mid),
          sourceLang: sourceLang, targetLang: targetLang);
      final right = await _translateChunk(engine, texts.sublist(mid),
          sourceLang: sourceLang, targetLang: targetLang);
      return [...left, ...right];
    }
  }

  List<List<SubtitleCue>> _chunk(
      List<SubtitleCue> cues, int maxSize, int maxChars) {
    final result = <List<SubtitleCue>>[];
    var current = <SubtitleCue>[];
    var chars = 0;
    for (final cue in cues) {
      final len = cue.text.length;
      final overSize = current.length >= maxSize;
      final overChars = maxChars > 0 && chars + len > maxChars;
      if (current.isNotEmpty && (overSize || overChars)) {
        result.add(current);
        current = <SubtitleCue>[];
        chars = 0;
      }
      current.add(cue);
      chars += len;
    }
    if (current.isNotEmpty) result.add(current);
    return result;
  }

  Future<String> _fetch(String url, String? authToken) async {
    if (!url.startsWith('http')) {
      return File(url).readAsString();
    }
    final dio = Dio(BaseOptions(
      connectTimeout: const Duration(seconds: 15),
      receiveTimeout: const Duration(seconds: 60),
      responseType: ResponseType.plain,
    ));
    if (authToken != null) {
      dio.options.headers['X-Emby-Token'] = authToken;
      dio.options.headers['X-MediaBrowser-Token'] = authToken;
    }
    final resp = await dio.get<String>(url);
    return resp.data ?? '';
  }

  String _extOf(String url) {
    final clean = url.split('?').first;
    return clean.contains('.') ? clean.split('.').last.toLowerCase() : '';
  }

  String _cacheKey(String source, String engineId, String from, String to,
      BilingualLayout layout) {
    final raw = '$source|$engineId|$from|$to|${layout.name}';
    return md5.convert(utf8.encode(raw)).toString();
  }

  Future<Directory> _cacheDir() async {
    final base = await getTemporaryDirectory();
    final dir = Directory('${base.path}/translated_subtitles');
    if (!dir.existsSync()) dir.createSync(recursive: true);
    return dir;
  }
}
