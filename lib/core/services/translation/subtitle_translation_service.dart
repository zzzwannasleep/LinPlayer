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

/// 翻译失败统计（用于判断引擎是否整体不可用）。
class _TranslateStats {
  int failed = 0;
  Object? lastError;
}

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
    required List<String> urls,
    required TranslationEngine engine,
    required String sourceLang,
    required String targetLang,
    required BilingualLayout layout,
    String? authToken,
    String cacheKeySeed = '',
    TranslationProgress? onProgress,
  }) async {
    final cacheDir = await _cacheDir();
    final seed = cacheKeySeed.isNotEmpty ? cacheKeySeed : urls.join('|');
    final cacheKey =
        _cacheKey(seed, engine.id, sourceLang, targetLang, layout);
    final outFile = File('${cacheDir.path}/trans_$cacheKey.srt');
    if (outFile.existsSync() && await outFile.length() > 0) {
      _logger.i(_tag, '命中翻译缓存: ${outFile.path}');
      onProgress?.call(1, 1, '已使用缓存');
      return outFile.path;
    }

    onProgress?.call(0, 1, '下载字幕…');
    final raw = await _fetchFirst(urls, authToken);
    final doc = SubtitleDocument.parseString(raw); // 按内容嗅探格式
    _logger.i(
      _tag,
      '源字幕拉取完成: ${raw.length}字节, 解析 ${doc.cues.length} 条, '
      '引擎=${engine.id}, $sourceLang→$targetLang',
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
    final stats = _TranslateStats();

    Future<void> runChunk(List<SubtitleCue> chunk) async {
      final translated = await _translateChunk(
        engine,
        chunk.map((c) => c.text).toList(),
        sourceLang: sourceLang,
        targetLang: targetLang,
        stats: stats,
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

    // 全部条目都翻译失败（回退原文）通常意味着引擎根本不可用
    // （如未开通服务/鉴权错误），此时直接报错而非静默产出未翻译文件。
    if (total > 0 && stats.failed >= total && stats.lastError != null) {
      throw TranslationException(
          engine.id, '翻译引擎不可用，全部 $total 条均失败', cause: stats.lastError);
    }
    if (stats.failed > 0) {
      _logger.w(_tag, '部分条目翻译失败回退原文: ${stats.failed}/$total');
    }
    return doc;
  }

  /// 翻译一块文本；遇到引擎抛错（如回包条数不齐）时二分重试，
  /// 单条仍失败则回退原文，保证不中断整体流程，并记入 [stats]。
  Future<List<String>> _translateChunk(
    TranslationEngine engine,
    List<String> texts, {
    required String sourceLang,
    required String targetLang,
    _TranslateStats? stats,
  }) async {
    if (texts.isEmpty) return const [];
    try {
      return await engine.translate(texts,
          sourceLang: sourceLang, targetLang: targetLang);
    } catch (e) {
      if (texts.length == 1) {
        _logger.w(_tag, '单条翻译失败，回退原文: $e');
        stats?.failed += 1;
        stats?.lastError = e;
        return [texts.first];
      }
      final mid = texts.length ~/ 2;
      _logger.w(_tag, '批次翻译失败，二分重试(${texts.length}条): $e');
      final left = await _translateChunk(engine, texts.sublist(0, mid),
          sourceLang: sourceLang, targetLang: targetLang, stats: stats);
      final right = await _translateChunk(engine, texts.sublist(mid),
          sourceLang: sourceLang, targetLang: targetLang, stats: stats);
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

  /// 依次尝试候选地址，返回第一个「内容确为字幕」的响应体。
  ///
  /// 不同服务端的内封字幕导出路由不一（有的需要 `/Subtitles/{i}/0/Stream.srt`
  /// 的 StartPositionTicks 段，有的提供 deliveryUrl），故逐个尝试并校验内容。
  Future<String> _fetchFirst(List<String> urls, String? authToken) async {
    final dio = Dio(BaseOptions(
      connectTimeout: const Duration(seconds: 15),
      receiveTimeout: const Duration(seconds: 60),
      responseType: ResponseType.plain,
      // 不让 dio 因 4xx 抛异常，统一手动判定以便尝试下一个候选。
      validateStatus: (s) => s != null && s < 500,
    ));
    if (authToken != null) {
      dio.options.headers['X-Emby-Token'] = authToken;
      dio.options.headers['X-MediaBrowser-Token'] = authToken;
    }

    Object? lastError;
    for (final url in urls) {
      if (url.isEmpty) continue;
      try {
        if (!url.startsWith('http')) {
          final body = await File(url).readAsString();
          if (_looksLikeSubtitle(body)) return body;
          continue;
        }
        final resp = await dio.get<String>(url);
        final code = resp.statusCode ?? 0;
        final body = resp.data ?? '';
        if (code >= 200 && code < 300 && _looksLikeSubtitle(body)) {
          _logger.i(_tag, '字幕拉取成功: HTTP $code, ${body.length}字节, url=$url');
          return body;
        }
        _logger.w(_tag,
            '字幕地址不可用: HTTP $code, ${body.length}字节${_looksLikeSubtitle(body) ? '' : '(非字幕内容)'}, url=$url');
      } catch (e) {
        lastError = e;
        _logger.w(_tag, '字幕地址请求异常: $e, url=$url');
      }
    }
    throw StateError(
        '所有字幕地址均不可用（共 ${urls.length} 个候选${lastError != null ? '，最后错误: $lastError' : ''}）');
  }

  /// 粗判内容是否为字幕文本（SRT/VTT/ASS），避免把 404/HTML 错误页当字幕。
  bool _looksLikeSubtitle(String body) {
    if (body.trim().isEmpty) return false;
    final head = body.length > 4000 ? body.substring(0, 4000) : body;
    return head.contains('-->') ||
        head.contains('Dialogue:') ||
        head.trimLeft().startsWith('WEBVTT') ||
        head.contains('[Script Info]');
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
