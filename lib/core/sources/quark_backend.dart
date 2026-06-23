import 'package:dio/dio.dart';

import '../providers/server_providers.dart';
import 'media_source_backend.dart';
import 'quark_tv.dart';
import 'source_credentials.dart';
import 'source_http.dart';

/// 夸克网盘后端（Cookie / 网页 API 路径）。
///
/// 逆向自夸克 PC 客户端网页 API（参考 AList/OpenList `quark_uc` 驱动）：
/// - 鉴权：请求头带 `Cookie`，配套 `Referer: https://pan.quark.cn` 与客户端 UA。
/// - 列目录：`GET /file/sort?pdir_fid={fid}` → `data.list[]`。根目录 fid=`0`。
/// - 取流：优先 `POST /file/v2/play/project`（转码自适应播放地址），失败回退
///   `POST /file/download`（原文件直链，播放时需带 Cookie/Referer/UA）。
/// - 夸克会通过响应 `Set-Cookie` 轮换 `__puus`/`__pus`，这里实时回写内存 Cookie，
///   避免会话中途失效。
///
/// 注意：所有接口均为非官方逆向，可能随夸克更新失效；需真实账号验证。
class QuarkBackend implements MediaSourceBackend {
  @override
  SourceKind get kind => SourceKind.quark;

  static const String api = 'https://drive.quark.cn/1/clouddrive';
  static const String referer = 'https://pan.quark.cn';
  static const String ua =
      'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 '
      '(KHTML, like Gecko) quark-cloud-drive/2.5.20 Chrome/100.0.4896.160 '
      'Electron/18.3.5.4-b478491100 Safari/537.36 Channel/pckk_other_ch';
  static const String _pr = 'ucpro';
  static const int _pageSize = 100;
  static const int _maxPages = 200;

  /// 内存 Cookie 缓存（serverId → 含轮换后 __puus 的最新 Cookie）。
  final Map<String, String> _cookieCache = {};

  /// TV（扫码）模式：客户端 + 内存 access_token 缓存（serverId → access_token）。
  final QuarkTvClient _tv = QuarkTvClient();
  final Map<String, String> _tvAccess = {};

  /// 是否 TV（扫码）模式：附加凭据里存了 refresh_token 即是。否则走 Cookie 网页 API。
  bool _isTvMode(ServerConfig server) =>
      (SourceCredentialStore.instance.read(server.id)['refresh_token'] ?? '')
          .isNotEmpty;

  /// 取 TV 模式的 access_token（必要时用 refresh_token 刷新，并回写轮换后的 refresh_token）。
  Future<({String accessToken, String deviceId})> _tvAuth(
    ServerConfig server, {
    bool force = false,
  }) async {
    final creds = SourceCredentialStore.instance.read(server.id);
    final deviceId = creds['device_id'] ?? '';
    final refresh = creds['refresh_token'] ?? '';
    if (deviceId.isEmpty || refresh.isEmpty) {
      throw SourceException('夸克未登录，请重新扫码', isAuth: true);
    }
    var access = force ? null : _tvAccess[server.id];
    if (access == null || access.isEmpty) {
      final r = await _tv.exchangeToken(deviceId, refresh, isRefresh: true);
      access = r.accessToken;
      _tvAccess[server.id] = access;
      if (r.refreshToken.isNotEmpty && r.refreshToken != refresh) {
        await SourceCredentialStore.instance
            .merge(server.id, {'refresh_token': r.refreshToken});
      }
    }
    return (accessToken: access, deviceId: deviceId);
  }

  /// TV 模式调用包装：token 失效自动刷新重试一次。
  Future<T> _tvCall<T>(
    ServerConfig server,
    Future<T> Function(String accessToken, String deviceId) fn,
  ) async {
    var auth = await _tvAuth(server);
    try {
      return await fn(auth.accessToken, auth.deviceId);
    } on SourceException catch (e) {
      if (!e.isAuth) rethrow;
      auth = await _tvAuth(server, force: true);
      return await fn(auth.accessToken, auth.deviceId);
    }
  }

  String cookieOf(ServerConfig server) =>
      _cookieCache[server.id] ?? server.authToken ?? '';

  Dio _dio() => buildSourceDio();

  Future<Response> _request(
    ServerConfig server,
    String path, {
    String method = 'GET',
    Map<String, dynamic>? query,
    Object? body,
  }) async {
    final cookie = cookieOf(server);
    if (cookie.isEmpty) {
      throw SourceException('夸克未登录，请重新添加', isAuth: true);
    }
    final resp = await _dio().request(
      '$api$path',
      queryParameters: {'pr': _pr, 'fr': 'pc', ...?query},
      data: body,
      options: Options(
        method: method,
        headers: {
          'Cookie': cookie,
          'Referer': referer,
          'User-Agent': ua,
          'Accept': 'application/json, text/plain, */*',
          if (body != null) 'Content-Type': 'application/json',
        },
      ),
    );
    _absorbRotatedCookie(server, resp);
    final data = resp.data;
    final status = data is Map ? data['status'] : null;
    if (status == 200) return resp;
    final code = data is Map ? data['code'] : null;
    final msg = data is Map ? data['message']?.toString() : null;
    // 登录态相关错误码：cookie 失效。
    final isAuth = status == 400 &&
        (code == 31001 || code == 31002 || code == 31003 || code == 31023);
    throw SourceException(msg ?? '夸克请求失败（status=$status）', isAuth: isAuth);
  }

  /// 从响应 Set-Cookie 中吸收轮换的 __puus/__pus，回写内存 Cookie。
  void _absorbRotatedCookie(ServerConfig server, Response resp) {
    final setCookies = resp.headers.map['set-cookie'];
    if (setCookies == null || setCookies.isEmpty) return;
    var cookie = cookieOf(server);
    final re = RegExp(r'(__puus|__pus)=([^;]+)');
    for (final sc in setCookies) {
      final m = re.firstMatch(sc);
      if (m != null) cookie = _replaceCookie(cookie, m.group(1)!, m.group(2)!);
    }
    _cookieCache[server.id] = cookie;
  }

  String _replaceCookie(String cookie, String key, String value) {
    final parts = cookie
        .split(';')
        .map((e) => e.trim())
        .where((e) => e.isNotEmpty)
        .toList();
    var found = false;
    for (var i = 0; i < parts.length; i++) {
      if (parts[i].startsWith('$key=')) {
        parts[i] = '$key=$value';
        found = true;
      }
    }
    if (!found) parts.add('$key=$value');
    return parts.join('; ');
  }

  /// 用一段 Cookie 创建临时校验：列根目录成功即视为有效。供登录页调用。
  Future<void> verifyCookie(ServerConfig server) async {
    await listDir(server, dirId: '0');
  }

  @override
  Future<List<SourceEntry>> listDir(ServerConfig server, {String? dirId}) async {
    final fid = (dirId == null || dirId.isEmpty) ? '0' : dirId;
    // TV（扫码）模式走开放 API。
    if (_isTvMode(server)) {
      return _tvCall(server, (at, did) => _tv.listFiles(did, at, fid));
    }
    final entries = <SourceEntry>[];
    var page = 1;
    while (page <= _maxPages) {
      final resp = await _request(server, '/file/sort', query: {
        'pdir_fid': fid,
        '_page': '$page',
        '_size': '$_pageSize',
        '_fetch_total': '1',
        'fetch_all_file': '1',
        'fetch_risk_file_name': '1',
        '_sort': 'file_type:asc,updated_at:desc',
      });
      final list = ((resp.data['data'] as Map?)?['list'] as List?) ?? const [];
      for (final f in list) {
        final fm = f as Map;
        final isDir = fm['dir'] == true || fm['file'] == false;
        final name = (fm['file_name'] ?? '').toString();
        entries.add(SourceEntry(
          id: (fm['fid'] ?? '').toString(),
          name: name,
          isDir: isDir,
          isVideo: !isDir && (fm['category'] == 1 || isVideoFileName(name)),
          size: (fm['size'] as num?)?.toInt(),
          raw: {'fid': fm['fid']},
        ));
      }
      if (list.length < _pageSize) break;
      page++;
    }
    return entries;
  }

  @override
  Future<List<SourceEntry>> search(ServerConfig server, String query) =>
      // 夸克有 /file/search，但初版先走本地过滤，降低逆向接口风险。
      throw UnsupportedError('夸克初版暂用本地过滤搜索');

  @override
  Future<ResolvedPlay> resolvePlay(ServerConfig server, SourceEntry entry) async {
    final fid = entry.id;

    // TV（扫码）模式：开放 API 取转码地址，失败回退原文件直链。
    if (_isTvMode(server)) {
      return _tvCall(server, (at, did) async {
        try {
          final url = await _tv.fileLink(did, at, fid, streaming: true);
          return ResolvedPlay(url: url, title: entry.name);
        } on SourceException {
          final url = await _tv.fileLink(did, at, fid, streaming: false);
          return ResolvedPlay(url: url, title: entry.name);
        }
      });
    }

    final headers = {'Cookie': cookieOf(server), 'Referer': referer};

    // 优先转码自适应播放地址。
    try {
      final resp = await _request(
        server,
        '/file/v2/play/project',
        method: 'POST',
        body: {
          'fid': fid,
          'resolutions': 'low,normal,high,super,2k,4k',
          'supports': 'fmp4_av,m3u8,dolby_vision',
        },
      );
      final vlist =
          ((resp.data['data'] as Map?)?['video_list'] as List?) ?? const [];
      for (final v in vlist) {
        final url =
            (((v as Map)['video_info'] as Map?)?['url'] ?? '').toString();
        if (url.isNotEmpty) {
          return ResolvedPlay(
            url: url,
            title: entry.name,
            httpHeaders: headers,
            userAgentOverride: ua,
          );
        }
      }
    } on SourceException {
      // 转码不可用（如未转码完成）→ 回退原文件直链。
    }

    final resp = await _request(
      server,
      '/file/download',
      method: 'POST',
      body: {
        'fids': [fid]
      },
    );
    final list = (resp.data['data'] as List?) ?? const [];
    if (list.isEmpty) throw SourceException('未获取到下载地址');
    final url = ((list.first as Map)['download_url'] ?? '').toString();
    if (url.isEmpty) throw SourceException('未获取到下载地址');
    return ResolvedPlay(
      url: url,
      title: entry.name,
      httpHeaders: {...headers, 'User-Agent': ua},
      userAgentOverride: ua,
    );
  }
}
