import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:dio/dio.dart';

import '../translation_engine.dart';

/// 腾讯机器翻译引擎（TextTranslateBatch，TC3-HMAC-SHA256 签名）。
///
/// 走批量接口 TextTranslateBatch：一次提交 SourceTextList，回 TargetTextList，
/// 天然支持整批字幕翻译。签名遵循腾讯云 V3（service=tmt）。
class TencentTranslationEngine extends TranslationEngine {
  TencentTranslationEngine(this.config)
      : _dio = Dio(BaseOptions(
          connectTimeout: const Duration(seconds: 15),
          receiveTimeout: const Duration(seconds: 30),
        ));

  final TencentEngineConfig config;
  final Dio _dio;

  static const _service = 'tmt';
  static const _host = TencentEngineConfig.endpoint;
  static const _version = '2018-03-21';

  @override
  String get id => 'tencent';

  // 腾讯批量接口单次条数有限制，保守取 50；免费 QPS 较低，串行更稳。
  @override
  int get maxBatchSize => 50;
  @override
  int get maxBatchChars => 4000;
  @override
  int get maxConcurrency => 1;

  @override
  Future<List<String>> translate(
    List<String> texts, {
    required String sourceLang,
    required String targetLang,
  }) async {
    if (texts.isEmpty) return const [];
    final source = TranslationLang.toTencent(sourceLang);
    final target = TranslationLang.toTencent(targetLang);

    // TextTranslateBatch 不支持源语言 auto；源语言未知时退回支持 auto 的单条接口。
    if (source == 'auto') {
      final out = <String>[];
      for (final t in texts) {
        out.add(await _translateSingle(t, source, target));
      }
      return out;
    }
    return _translateBatch(texts, source, target);
  }

  Future<List<String>> _translateBatch(
      List<String> texts, String source, String target) async {
    final response = await _call('TextTranslateBatch', {
      'Source': source,
      'Target': target,
      'ProjectId': config.projectId,
      'SourceTextList': texts,
    });
    final list = (response['TargetTextList'] as List?) ?? const [];
    final out = list.map((e) => e.toString()).toList();
    if (out.length != texts.length) {
      throw TranslationException(
          id, '回包条数(${out.length})与请求(${texts.length})不一致');
    }
    return out;
  }

  Future<String> _translateSingle(
      String text, String source, String target) async {
    final response = await _call('TextTranslate', {
      'SourceText': text,
      'Source': source,
      'Target': target,
      'ProjectId': config.projectId,
    });
    return (response['TargetText'] ?? '').toString();
  }

  /// 发起一次腾讯云 V3 签名请求，返回 Response 对象（出错抛异常）。
  Future<Map> _call(String action, Map<String, dynamic> payloadMap) async {
    final payload = jsonEncode(payloadMap);
    final now = DateTime.now().toUtc();
    final timestamp = now.millisecondsSinceEpoch ~/ 1000;
    final date =
        '${now.year.toString().padLeft(4, '0')}-${now.month.toString().padLeft(2, '0')}-${now.day.toString().padLeft(2, '0')}';
    final authorization =
        _buildAuthorization(action, payload, timestamp.toString(), date);

    try {
      final httpResp = await _dio.post(
        'https://$_host',
        options: Options(headers: {
          'Authorization': authorization,
          'Content-Type': 'application/json; charset=utf-8',
          'Host': _host,
          'X-TC-Action': action,
          'X-TC-Timestamp': timestamp.toString(),
          'X-TC-Version': _version,
          'X-TC-Region': config.region,
        }),
        data: payload,
      );
      final data = httpResp.data is String
          ? jsonDecode(httpResp.data as String) as Map
          : httpResp.data as Map;
      final response = data['Response'] as Map?;
      if (response == null) {
        throw TranslationException(id, '腾讯翻译响应缺少 Response 字段');
      }
      final error = response['Error'];
      if (error != null) {
        throw TranslationException(
            id, '腾讯翻译错误 ${error['Code']}: ${error['Message']}');
      }
      return response;
    } on DioException catch (e) {
      throw TranslationException(id, '腾讯翻译请求失败: ${e.response?.statusCode}',
          cause: e.response?.data ?? e.message);
    }
  }

  String _buildAuthorization(
      String action, String payload, String timestamp, String date) {
    const algorithm = 'TC3-HMAC-SHA256';
    const signedHeaders = 'content-type;host;x-tc-action';
    final canonicalHeaders =
        'content-type:application/json; charset=utf-8\nhost:$_host\nx-tc-action:${action.toLowerCase()}\n';
    final hashedPayload = _sha256Hex(payload);
    final canonicalRequest =
        'POST\n/\n\n$canonicalHeaders\n$signedHeaders\n$hashedPayload';

    final credentialScope = '$date/$_service/tc3_request';
    final stringToSign =
        '$algorithm\n$timestamp\n$credentialScope\n${_sha256Hex(canonicalRequest)}';

    final secretDate = _hmac(utf8.encode('TC3${config.secretKey}'), date);
    final secretService = _hmac(secretDate, _service);
    final secretSigning = _hmac(secretService, 'tc3_request');
    final signature = _hex(_hmac(secretSigning, stringToSign));

    return '$algorithm Credential=${config.secretId}/$credentialScope, '
        'SignedHeaders=$signedHeaders, Signature=$signature';
  }

  static String _sha256Hex(String s) =>
      sha256.convert(utf8.encode(s)).toString();

  static List<int> _hmac(List<int> key, String msg) =>
      Hmac(sha256, key).convert(utf8.encode(msg)).bytes;

  static String _hex(List<int> bytes) =>
      bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
}
