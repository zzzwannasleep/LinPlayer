import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:dio/dio.dart';

import 'media_source_backend.dart';
import 'source_http.dart';

/// 夸克 TV OAuth（扫码）API 客户端。
///
/// 与 Cookie 网页 API（drive.quark.cn）是两套独立鉴权：这里走 TV 开放 API
/// `open-api-drive.quark.cn`，用 access_token + 每请求签名（x-pan-token）。
/// 登录走设备码扫码流程；令牌兑换/刷新经第三方代理 `api.extscreen.com`
/// （TV 驱动既定做法，代理持有 app 密钥）。参考 OpenList `quark_uc_tv` 驱动。
///
/// 全部为逆向接口，可能随夸克更新失效；需真实账号 + 扫码验证。
class QuarkTvClient {
  static const String api = 'https://open-api-drive.quark.cn';
  static const String clientId = 'd3194e61504e493eb6222857bccfed94';
  static const String signKey = 'kw2dvtd7p4t3pjl2d9ed9yc8yej8kw2d';
  static const String appVer = '1.8.2.2';
  static const String channel = 'GENERAL';
  static const String codeApi = 'http://api.extscreen.com/quarkdrive';
  static const String ua =
      'Mozilla/5.0 (Linux; U; Android 13; zh-cn; M2004J7AC Build/UKQ1.231108.001) '
      'AppleWebKit/533.1 (KHTML, like Gecko) Mobile Safari/533.1';

  ({String tm, String token, String reqId}) _sign(
    String method,
    String pathname,
    String deviceId,
  ) {
    final tm = DateTime.now().millisecondsSinceEpoch.toString();
    final reqId = md5.convert(utf8.encode(deviceId + tm)).toString();
    final tokenData = '$method&$pathname&$tm&$signKey';
    final token = sha256.convert(utf8.encode(tokenData)).toString();
    return (tm: tm, token: token, reqId: reqId);
  }

  Map<String, String> _commonQuery(
    String deviceId,
    String accessToken,
    String reqId,
  ) =>
      {
        'req_id': reqId,
        'access_token': accessToken,
        'app_ver': appVer,
        'device_id': deviceId,
        'device_brand': 'Xiaomi',
        'platform': 'tv',
        'device_name': 'M2004J7AC',
        'device_model': 'M2004J7AC',
        'build_device': 'M2004J7AC',
        'build_product': 'M2004J7AC',
        'device_gpu': 'Adreno (TM) 550',
        'activity_rect': '{}',
        'channel': channel,
      };

  Future<Map<String, dynamic>> _request(
    String pathname, {
    String method = 'GET',
    required String deviceId,
    String accessToken = '',
    Map<String, dynamic>? query,
  }) async {
    final s = _sign(method, pathname, deviceId);
    final resp = await buildSourceDio().request(
      '$api$pathname',
      queryParameters: {..._commonQuery(deviceId, accessToken, s.reqId), ...?query},
      options: Options(
        method: method,
        headers: {
          'Accept': 'application/json, text/plain, */*',
          'User-Agent': ua,
          'x-pan-tm': s.tm,
          'x-pan-token': s.token,
          'x-pan-client-id': clientId,
        },
      ),
    );
    final data = resp.data;
    if (data is! Map) throw SourceException('夸克响应异常');
    final status = data['status'];
    final errno = data['errno'];
    if ((status is int && status >= 400) || (errno is int && errno != 0)) {
      final info = (data['error_info'] ?? '').toString();
      final lower = info.toLowerCase();
      final isAuth = (status == -1 && (errno == 10001 || errno == 11001)) ||
          lower.contains('access token') ||
          lower.contains('access_token') ||
          lower.contains('token无效') ||
          lower.contains('token 无效');
      throw SourceException(info.isEmpty ? '夸克请求失败' : info, isAuth: isAuth);
    }
    return data.cast<String, dynamic>();
  }

  /// 1) 取扫码二维码内容 + query_token。
  Future<({String qrData, String queryToken})> getLoginCode(
      String deviceId) async {
    final data = await _request('/oauth/authorize', deviceId: deviceId, query: {
      'auth_type': 'code',
      'client_id': clientId,
      'scope': 'netdisk',
      'qrcode': '1',
      'qr_width': '460',
      'qr_height': '460',
    });
    return (
      qrData: (data['qr_data'] ?? '').toString(),
      queryToken: (data['query_token'] ?? '').toString(),
    );
  }

  /// 2) 轮询：用户扫码确认后返回 code（未确认时接口报错，外层捕获后继续轮询）。
  Future<String> getCode(String deviceId, String queryToken) async {
    final data = await _request('/oauth/code', deviceId: deviceId, query: {
      'client_id': clientId,
      'scope': 'netdisk',
      'query_token': queryToken,
    });
    return (data['code'] ?? '').toString();
  }

  /// 3) 用 code 换 token，或用 refresh_token 刷新。经 codeApi 代理。
  Future<({String accessToken, String refreshToken})> exchangeToken(
    String deviceId,
    String codeOrRefresh, {
    required bool isRefresh,
  }) async {
    final s = _sign('POST', '/token', deviceId);
    final body = <String, dynamic>{
      'req_id': s.reqId,
      'app_ver': appVer,
      'device_id': deviceId,
      'device_brand': 'Xiaomi',
      'platform': 'tv',
      'device_name': 'M2004J7AC',
      'device_model': 'M2004J7AC',
      'build_device': 'M2004J7AC',
      'build_product': 'M2004J7AC',
      'device_gpu': 'Adreno (TM) 550',
      'activity_rect': '{}',
      'channel': channel,
      if (isRefresh) 'refresh_token': codeOrRefresh else 'code': codeOrRefresh,
    };
    final resp = await buildSourceDio().post(
      '$codeApi/token',
      data: body,
      options: Options(headers: {'Content-Type': 'application/json'}),
    );
    final data = resp.data;
    if (data is! Map) throw SourceException('夸克令牌响应异常', isAuth: true);
    if (data['code'] != 200) {
      throw SourceException(data['message']?.toString() ?? '令牌兑换失败',
          isAuth: true);
    }
    final d = data['data'] as Map?;
    final access = (d?['access_token'] ?? '').toString();
    final refresh = (d?['refresh_token'] ?? '').toString();
    if (refresh.isEmpty) throw SourceException('未返回 refresh_token', isAuth: true);
    return (accessToken: access, refreshToken: refresh);
  }

  /// 列目录（TV API）。parentFid 根为 '0'。
  Future<List<SourceEntry>> listFiles(
    String deviceId,
    String accessToken,
    String parentFid,
  ) async {
    final entries = <SourceEntry>[];
    var page = 0;
    const size = 100;
    while (page < 200) {
      final data = await _request('/file',
          deviceId: deviceId, accessToken: accessToken, query: {
            'method': 'list',
            'parent_fid': parentFid,
            'order_by': '3',
            'desc': '1',
            'category': '',
            'source': '',
            'ex_source': '',
            'list_all': '0',
            'page_size': '$size',
            'page_index': '$page',
          });
      final dd = data['data'] as Map?;
      final files = (dd?['files'] as List?) ?? const [];
      for (final f in files) {
        final fm = f as Map;
        final isDir = fm['isdir'] == 1 || fm['dir'] == true;
        final name = (fm['filename'] ?? '').toString();
        entries.add(SourceEntry(
          id: (fm['fid'] ?? '').toString(),
          name: name,
          isDir: isDir,
          isVideo: !isDir && (fm['category'] == 1 || isVideoFileName(name)),
          size: (fm['size'] as num?)?.toInt(),
          thumbUrl: _httpOrNull(fm['thumbnail_url']?.toString()),
          raw: {'fid': fm['fid']},
        ));
      }
      final total = (dd?['total_count'] as num?)?.toInt() ?? files.length;
      if ((page + 1) * size >= total || files.isEmpty) break;
      page++;
    }
    return entries;
  }

  /// 取播放地址：优先转码（streaming），失败回退原文件（download）。
  Future<String> fileLink(
    String deviceId,
    String accessToken,
    String fid, {
    required bool streaming,
  }) async {
    final data = await _request('/file',
        deviceId: deviceId, accessToken: accessToken, query: {
          'method': streaming ? 'streaming' : 'download',
          'group_by': 'source',
          'fid': fid,
          'resolution': 'low,normal,high,super,2k,4k',
          'support': 'dolby_vision',
        });
    final dd = data['data'] as Map?;
    if (streaming) {
      final infos = (dd?['video_info'] as List?) ?? const [];
      for (final v in infos) {
        final url = ((v as Map)['url'] ?? '').toString();
        if (url.isNotEmpty) return url;
      }
      throw SourceException('转码地址不可用');
    }
    final url = (dd?['download_url'] ?? '').toString();
    if (url.isEmpty) throw SourceException('未获取到下载地址');
    return url;
  }

  String? _httpOrNull(String? url) =>
      (url != null && url.startsWith('http')) ? url : null;
}
