import 'dart:convert';

import 'package:dio/dio.dart';

import '../translation_engine.dart';

/// AI 翻译引擎基类：把一批字幕作为 JSON 数组交给大模型整体翻译。
///
/// 整批翻译相比逐条翻译能让模型看到上下文，质量更好，也更省请求数。
/// 子类只需实现具体的 HTTP 调用（OpenAI / Anthropic 协议不同）。
abstract class AiTranslationEngine extends TranslationEngine {
  AiTranslationEngine(this.config)
      : _dio = Dio(BaseOptions(
          connectTimeout: const Duration(seconds: 20),
          receiveTimeout: const Duration(seconds: 120),
        ));

  final AiEngineConfig config;
  final Dio _dio;

  Dio get dio => _dio;

  // AI 单批可承载较多条目，但要控制 token；按条数+字符数双限制。
  @override
  int get maxBatchSize => 40;
  @override
  int get maxBatchChars => 4000;
  @override
  int get maxConcurrency => 3;

  String _systemPrompt(String targetName) =>
      'You are a professional subtitle translator. '
      'Translate every item of the input JSON array into $targetName. '
      'Rules: (1) Return ONLY a JSON array of strings, same length and order as the input. '
      '(2) Keep line breaks inside an item as \\n. '
      "(3) Do not merge or split items, add numbering, notes, or romanization. "
      '(4) Keep proper nouns natural. Output must be valid JSON, nothing else.';

  /// 子类实现：发送提示词，返回模型纯文本回复。
  Future<String> complete(String systemPrompt, String userContent);

  @override
  Future<List<String>> translate(
    List<String> texts, {
    required String sourceLang,
    required String targetLang,
  }) async {
    if (texts.isEmpty) return const [];
    final targetName = TranslationLang.humanName(targetLang);
    final userContent = jsonEncode(texts);
    final raw = await complete(_systemPrompt(targetName), userContent);
    final parsed = _parseJsonArray(raw, texts.length);
    if (parsed != null) return parsed;
    // 解析失败时退化为按行切分兜底，长度对不齐就回退原文。
    throw TranslationException(id, 'AI 返回无法解析为等长 JSON 数组');
  }

  List<String>? _parseJsonArray(String raw, int expected) {
    final start = raw.indexOf('[');
    final end = raw.lastIndexOf(']');
    if (start < 0 || end <= start) return null;
    try {
      final decoded = jsonDecode(raw.substring(start, end + 1));
      if (decoded is! List) return null;
      final list = decoded.map((e) => e?.toString() ?? '').toList();
      if (list.length != expected) return null;
      return list;
    } catch (_) {
      return null;
    }
  }
}

/// OpenAI 兼容协议（含各类自建/中转 OpenAI 格式端点）。
class OpenAiTranslationEngine extends AiTranslationEngine {
  OpenAiTranslationEngine(super.config);

  @override
  String get id => 'openai';

  @override
  Future<String> complete(String systemPrompt, String userContent) async {
    final base = config.baseUrl.replaceAll(RegExp(r'/+$'), '');
    try {
      final resp = await dio.post(
        '$base/chat/completions',
        options: Options(headers: {
          'Authorization': 'Bearer ${config.apiKey}',
          'Content-Type': 'application/json',
        }),
        data: {
          'model': config.model,
          'temperature': 0.2,
          'messages': [
            {'role': 'system', 'content': systemPrompt},
            {'role': 'user', 'content': userContent},
          ],
        },
      );
      final data = resp.data as Map;
      final choices = data['choices'] as List?;
      final content =
          (choices?.firstOrNull?['message']?['content'])?.toString();
      if (content == null || content.isEmpty) {
        throw TranslationException(id, 'OpenAI 响应为空');
      }
      return content;
    } on DioException catch (e) {
      throw TranslationException(id, 'OpenAI 请求失败: ${e.response?.statusCode}',
          cause: e.response?.data ?? e.message);
    }
  }
}

/// Anthropic 兼容协议（Messages API）。
class AnthropicTranslationEngine extends AiTranslationEngine {
  AnthropicTranslationEngine(super.config);

  @override
  String get id => 'anthropic';

  @override
  Future<String> complete(String systemPrompt, String userContent) async {
    final base = config.baseUrl.replaceAll(RegExp(r'/+$'), '');
    try {
      final resp = await dio.post(
        '$base/messages',
        options: Options(headers: {
          'x-api-key': config.apiKey,
          'anthropic-version': '2023-06-01',
          'Content-Type': 'application/json',
        }),
        data: {
          'model': config.model,
          'max_tokens': 8192,
          'temperature': 0.2,
          'system': systemPrompt,
          'messages': [
            {'role': 'user', 'content': userContent},
          ],
        },
      );
      final data = resp.data as Map;
      final content = data['content'] as List?;
      final text = content?.firstOrNull?['text']?.toString();
      if (text == null || text.isEmpty) {
        throw TranslationException(id, 'Anthropic 响应为空');
      }
      return text;
    } on DioException catch (e) {
      throw TranslationException(id, 'Anthropic 请求失败: ${e.response?.statusCode}',
          cause: e.response?.data ?? e.message);
    }
  }
}
