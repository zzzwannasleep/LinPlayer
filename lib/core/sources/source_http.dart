import 'package:dio/dio.dart';

import '../network/proxy_http_client.dart';

/// 为文件浏览型源后端创建一个走当前代理 + TLS 白名单的 Dio。
///
/// 网盘接口常以非 2xx 携带 JSON 错误体（如 401 也返回 `{code, message}`），
/// 因此放宽 [validateStatus]，由各后端读响应体自行判断成功/失败。
Dio buildSourceDio({
  String? baseUrl,
  Map<String, dynamic>? headers,
  Duration connectTimeout = const Duration(seconds: 15),
  Duration receiveTimeout = const Duration(seconds: 30),
}) {
  final dio = Dio(
    BaseOptions(
      baseUrl: baseUrl ?? '',
      connectTimeout: connectTimeout,
      receiveTimeout: receiveTimeout,
      headers: headers,
      validateStatus: (status) => status != null && status < 500,
      responseType: ResponseType.json,
    ),
  );
  applyProxyToDio(dio);
  return dio;
}

/// 规整 baseUrl：去尾斜杠、补协议（缺省 https）。
String normalizeBaseUrl(String raw) {
  var url = raw.trim();
  if (url.isEmpty) return url;
  if (!url.startsWith('http://') && !url.startsWith('https://')) {
    url = 'https://$url';
  }
  while (url.endsWith('/')) {
    url = url.substring(0, url.length - 1);
  }
  return url;
}
