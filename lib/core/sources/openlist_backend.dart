import 'package:dio/dio.dart';

import '../providers/server_providers.dart';
import 'media_source_backend.dart';
import 'source_http.dart';

/// OpenList / AList 后端。
///
/// 账密登录拿 JWT，`/api/fs/list` 列目录，`/api/fs/get` 取 `raw_url` 直链。
/// token 存 [ServerConfig.authToken]；401 时用 username/password 自动重登。
/// 文档：https://doc.oplist.org/ 。
class OpenListBackend implements MediaSourceBackend {
  @override
  SourceKind get kind => SourceKind.openlist;

  /// 内存 token 缓存（serverId → token），避免每次请求都重登。
  final Map<String, String> _tokenCache = {};

  Dio _dio(ServerConfig server) =>
      buildSourceDio(baseUrl: normalizeBaseUrl(server.activeLineUrl));

  /// 账密登录拿 token。供登录页首次登录与 401 自动重登复用。
  static Future<String> login(
    String baseUrl,
    String username,
    String password,
  ) async {
    final dio = buildSourceDio(baseUrl: normalizeBaseUrl(baseUrl));
    final Response resp;
    try {
      resp = await dio.post('/api/auth/login', data: {
        'username': username,
        'password': password,
      });
    } catch (e) {
      throw SourceException('无法连接服务器: $e', cause: e);
    }
    final body = resp.data;
    if (body is! Map) throw SourceException('登录响应异常');
    final code = body['code'];
    if (code != 200) {
      throw SourceException(
        body['message']?.toString() ?? '登录失败（$code）',
        isAuth: true,
      );
    }
    final token = (body['data'] is Map ? body['data']['token'] : null)?.toString() ?? '';
    if (token.isEmpty) throw SourceException('登录未返回 token', isAuth: true);
    return token;
  }

  Future<String> _ensureToken(ServerConfig server, {bool force = false}) async {
    if (!force) {
      final cached = _tokenCache[server.id] ?? server.authToken;
      if (cached != null && cached.isNotEmpty) return cached;
    }
    final u = server.username ?? '';
    final p = server.password ?? '';
    if (u.isEmpty) {
      throw SourceException('登录已过期，请重新登录', isAuth: true);
    }
    final token = await login(server.activeLineUrl, u, p);
    _tokenCache[server.id] = token;
    return token;
  }

  /// 带鉴权 POST，401 自动重登一次。
  Future<Response> _authed(
    ServerConfig server,
    String path, {
    Object? data,
    bool retried = false,
  }) async {
    final token = await _ensureToken(server, force: retried);
    final resp = await _dio(server).post(
      path,
      data: data,
      options: Options(headers: {'Authorization': token}),
    );
    final body = resp.data;
    final code = body is Map ? body['code'] : null;
    if (code == 401 && !retried) {
      _tokenCache.remove(server.id);
      return _authed(server, path, data: data, retried: true);
    }
    if (code != 200) {
      final msg = body is Map ? body['message']?.toString() : null;
      throw SourceException(msg ?? 'OpenList 请求失败（$code）', isAuth: code == 401);
    }
    return resp;
  }

  @override
  Future<List<SourceEntry>> listDir(ServerConfig server, {String? dirId}) async {
    final path = (dirId == null || dirId.isEmpty) ? '/' : dirId;
    final resp = await _authed(server, '/api/fs/list', data: {
      'path': path,
      'password': '',
      'page': 1,
      'per_page': 0, // 0 = 全部
      'refresh': false,
    });
    final content =
        ((resp.data['data'] as Map?)?['content'] as List?) ?? const [];
    final entries = content.map<SourceEntry>((e) {
      final m = e as Map;
      final name = (m['name'] ?? '').toString();
      final isDir = m['is_dir'] == true;
      final childPath = path == '/' ? '/$name' : '$path/$name';
      return SourceEntry(
        id: childPath,
        name: name,
        isDir: isDir,
        isVideo: !isDir && isVideoFileName(name),
        size: (m['size'] as num?)?.toInt(),
        thumbUrl: _absThumb(server, m['thumb']?.toString()),
        raw: {'path': childPath},
      );
    }).toList();
    // 文件夹在前、各自按名排序，浏览更顺手。
    entries.sort((a, b) {
      if (a.isDir != b.isDir) return a.isDir ? -1 : 1;
      return a.name.toLowerCase().compareTo(b.name.toLowerCase());
    });
    return entries;
  }

  @override
  Future<List<SourceEntry>> search(ServerConfig server, String query) async {
    final resp = await _authed(server, '/api/fs/search', data: {
      'parent': '/',
      'keywords': query,
      'scope': 0,
      'page': 1,
      'per_page': 100,
      'password': '',
    });
    final content =
        ((resp.data['data'] as Map?)?['content'] as List?) ?? const [];
    return content.map<SourceEntry>((e) {
      final m = e as Map;
      final parent = (m['parent'] ?? '/').toString();
      final name = (m['name'] ?? '').toString();
      final isDir = m['is_dir'] == true;
      final full = parent.endsWith('/') ? '$parent$name' : '$parent/$name';
      return SourceEntry(
        id: full,
        name: name,
        isDir: isDir,
        isVideo: !isDir && isVideoFileName(name),
        size: (m['size'] as num?)?.toInt(),
      );
    }).toList();
  }

  @override
  Future<ResolvedPlay> resolvePlay(ServerConfig server, SourceEntry entry) async {
    final resp = await _authed(server, '/api/fs/get', data: {
      'path': entry.id,
      'password': '',
    });
    final data = resp.data['data'] as Map?;
    final rawUrl = (data?['raw_url'] ?? '').toString();
    if (rawUrl.isEmpty) throw SourceException('未获取到播放地址');

    // OpenList 的 /p /d 代理直链通常自带 sign，无需额外 header。仅当直链回指
    // 本服务器时附带 Authorization 兜底（部分需鉴权的存储），避免把 token
    // 泄露给第三方 CDN 直链。
    final headers = <String, String>{};
    final token = _tokenCache[server.id] ?? server.authToken;
    final base = normalizeBaseUrl(server.activeLineUrl);
    if (token != null && token.isNotEmpty && rawUrl.startsWith(base)) {
      headers['Authorization'] = token;
    }
    return ResolvedPlay(url: rawUrl, title: entry.name, httpHeaders: headers);
  }

  String? _absThumb(ServerConfig server, String? thumb) {
    if (thumb == null || thumb.isEmpty) return null;
    if (thumb.startsWith('http')) return thumb;
    return normalizeBaseUrl(server.activeLineUrl) + thumb;
  }
}
