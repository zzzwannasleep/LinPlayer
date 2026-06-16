import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:dio/dio.dart';

import '../translation_engine.dart';

/// 百度文本翻译引擎（通用 / 大模型共用一套签名）。
///
/// 通用接口(113)与大模型接口(133)鉴权一致：sign = MD5(appid + q + salt + 密钥)。
/// 多条字幕用 `\n` 拼成单个 q 一次提交，trans_result 按行回包，从而批量翻译。
/// 两者只在 endpoint 上有别（[BaiduEngineConfig.generalEndpoint] /
/// [BaiduEngineConfig.llmEndpoint]），设置里可覆盖以适配官方调整。
class BaiduTranslationEngine extends TranslationEngine {
  BaiduTranslationEngine(
    this.config, {
    required this.engineId,
    required this.defaultEndpoint,
  }) : _dio = Dio(BaseOptions(
          connectTimeout: const Duration(seconds: 15),
          receiveTimeout: const Duration(seconds: 30),
        ));

  final BaiduEngineConfig config;
  final String engineId;
  final String defaultEndpoint;
  final Dio _dio;

  @override
  String get id => engineId;

  // 百度免费版 QPS=1，必须串行；单条 q 上限 6000 字节，按行数与字符双限。
  @override
  int get maxBatchSize => 50;
  @override
  int get maxBatchChars => 2000;
  @override
  int get maxConcurrency => 1;

  String get _endpoint =>
      config.endpoint.isNotEmpty ? config.endpoint : defaultEndpoint;

  @override
  Future<List<String>> translate(
    List<String> texts, {
    required String sourceLang,
    required String targetLang,
  }) async {
    if (texts.isEmpty) return const [];
    // 把每条内部换行压成空格，避免破坏「一行一条」的回包对齐。
    final lines = texts.map((t) => t.replaceAll('\n', ' ').trim()).toList();
    final q = lines.join('\n');
    final salt = '${texts.length}${q.length}${q.hashCode}';
    final from = TranslationLang.toBaidu(sourceLang);
    final to = TranslationLang.toBaidu(targetLang);
    final sign =
        md5.convert(utf8.encode('${config.appId}$q$salt${config.secretKey}'))
            .toString();

    try {
      final resp = await _dio.post(
        _endpoint,
        options: Options(
          contentType: Headers.formUrlEncodedContentType,
          headers: {'Content-Type': 'application/x-www-form-urlencoded'},
        ),
        data: {
          'q': q,
          'from': from,
          'to': to,
          'appid': config.appId,
          'salt': salt,
          'sign': sign,
        },
      );
      final data = resp.data is String
          ? jsonDecode(resp.data as String) as Map
          : resp.data as Map;

      if (data['error_code'] != null) {
        throw TranslationException(
          id,
          '百度翻译错误 ${data['error_code']}: ${data['error_msg']}',
        );
      }
      final results = (data['trans_result'] as List?) ?? const [];
      final dst = results.map((e) => (e['dst'] ?? '').toString()).toList();
      if (dst.length != texts.length) {
        // 行数对不齐（百度偶发合并空行），交给服务层缩小批次重试。
        throw TranslationException(
          id,
          '回包行数(${dst.length})与请求(${texts.length})不一致',
        );
      }
      return dst;
    } on DioException catch (e) {
      throw TranslationException(id, '百度翻译请求失败: ${e.response?.statusCode}',
          cause: e.response?.data ?? e.message);
    }
  }
}

/// 百度大模型文本翻译引擎（POST JSON + Bearer API Key）。
///
/// 接口 `/ait/api/aiTextTranslate`：body 为 JSON {appid,q,from,to,model_type}，
/// 推荐用 `Authorization: Bearer <apiKey>` 鉴权；未填 apiKey 时回退 appid+salt+sign。
/// 返回结构与通用接口一致（trans_result[].dst），多行 q 用 `\n` 拼接以批量翻译。
class BaiduLlmTranslationEngine extends TranslationEngine {
  BaiduLlmTranslationEngine(this.config)
      : _dio = Dio(BaseOptions(
          connectTimeout: const Duration(seconds: 20),
          receiveTimeout: const Duration(seconds: 60),
        ));

  final BaiduEngineConfig config;
  final Dio _dio;

  @override
  String get id => 'baidu_llm';

  @override
  int get maxBatchSize => 40;
  @override
  int get maxBatchChars => 2000; // 单次 q 上限 6000 字符，留余量。
  @override
  int get maxConcurrency => 1;

  String get _endpoint => config.endpoint.isNotEmpty
      ? config.endpoint
      : BaiduEngineConfig.llmEndpoint;

  @override
  Future<List<String>> translate(
    List<String> texts, {
    required String sourceLang,
    required String targetLang,
  }) async {
    if (texts.isEmpty) return const [];
    final lines = texts.map((t) => t.replaceAll('\n', ' ').trim()).toList();
    final q = lines.join('\n');
    final from = TranslationLang.toBaidu(sourceLang);
    final to = TranslationLang.toBaidu(targetLang);

    final body = <String, dynamic>{
      'appid': config.appId,
      'q': q,
      'from': from,
      'to': to,
      'model_type': 'llm',
    };
    final headers = <String, dynamic>{'Content-Type': 'application/json'};
    if (config.apiKey.isNotEmpty) {
      headers['Authorization'] = 'Bearer ${config.apiKey}';
    } else {
      // 回退签名鉴权：appid+q+salt+密钥 的 MD5。
      final salt = '${texts.length}${q.length}${q.hashCode}';
      body['salt'] = salt;
      body['sign'] = md5
          .convert(utf8.encode('${config.appId}$q$salt${config.secretKey}'))
          .toString();
    }

    try {
      final resp = await _dio.post(
        _endpoint,
        options: Options(headers: headers),
        data: body,
      );
      final data = resp.data is String
          ? jsonDecode(resp.data as String) as Map
          : resp.data as Map;
      if (data['error_code'] != null) {
        throw TranslationException(
          id,
          '百度大模型翻译错误 ${data['error_code']}: ${data['error_msg']}',
        );
      }
      final results = (data['trans_result'] as List?) ?? const [];
      final dst = results.map((e) => (e['dst'] ?? '').toString()).toList();
      if (dst.length != texts.length) {
        throw TranslationException(
          id,
          '回包条数(${dst.length})与请求(${texts.length})不一致',
        );
      }
      return dst;
    } on DioException catch (e) {
      throw TranslationException(id, '百度大模型翻译请求失败: ${e.response?.statusCode}',
          cause: e.response?.data ?? e.message);
    }
  }
}
