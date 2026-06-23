import 'dart:convert';

import 'package:dio/dio.dart';

import '../providers/server_providers.dart';
import 'media_source_backend.dart';
import 'source_http.dart';

/// Ani-rss 后端（wushuo894/ani-rss）。
///
/// 它是追番下载管理器，但暴露了可播放的文件接口：
/// - `POST /api/login` {username,password} → `data` 是令牌字符串。
/// - 鉴权：请求头 `Authorization: <token>` 或查询 `?s=<token>`（源码 auth/fun Header/Form）。
/// - `POST /api/listAni` → `data.weekList[].items[]` 为番剧列表（当作「文件夹」）。
/// - `POST /api/playList`（body=Ani）→ `data` 为 `PlayItem[]`（每集文件）。
/// - `GET /api/file?filename=<base64>` 流式返回视频（服务端 base64 解码 filename）。
///
/// 浏览映射：根目录列番剧；进入某番剧 → 列该番剧的剧集文件；点文件 → /api/file 取流。
class AniRssBackend implements MediaSourceBackend {
  @override
  SourceKind get kind => SourceKind.anirss;

  final Map<String, String> _tokenCache = {};

  Dio _dio(ServerConfig server) =>
      buildSourceDio(baseUrl: normalizeBaseUrl(server.activeLineUrl));

  /// 账密登录拿令牌。
  static Future<String> login(
    String baseUrl,
    String username,
    String password,
  ) async {
    final dio = buildSourceDio(baseUrl: normalizeBaseUrl(baseUrl));
    final Response resp;
    try {
      resp = await dio.post('/api/login', data: {
        'username': username,
        'password': password,
      });
    } catch (e) {
      throw SourceException('无法连接服务器: $e', cause: e);
    }
    final body = resp.data;
    if (body is! Map) throw SourceException('登录响应异常');
    if (body['code'] != 200) {
      throw SourceException(
        body['message']?.toString() ?? '登录失败',
        isAuth: true,
      );
    }
    final token = (body['data'] ?? '').toString();
    if (token.isEmpty) throw SourceException('登录未返回令牌', isAuth: true);
    return token;
  }

  Future<String> _ensureToken(ServerConfig server, {bool force = false}) async {
    if (!force) {
      final cached = _tokenCache[server.id] ?? server.authToken;
      if (cached != null && cached.isNotEmpty) return cached;
    }
    final u = server.username ?? '';
    final p = server.password ?? '';
    if (u.isEmpty) throw SourceException('登录已过期，请重新登录', isAuth: true);
    final token = await login(server.activeLineUrl, u, p);
    _tokenCache[server.id] = token;
    return token;
  }

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
    if (code == 403 && !retried) {
      _tokenCache.remove(server.id);
      return _authed(server, path, data: data, retried: true);
    }
    if (code != 200) {
      final msg = body is Map ? body['message']?.toString() : null;
      throw SourceException(msg ?? 'Ani-rss 请求失败（$code）', isAuth: code == 403);
    }
    return resp;
  }

  @override
  Future<List<SourceEntry>> listDir(ServerConfig server, {String? dirId}) async {
    // 根目录：列番剧（当作文件夹）。
    if (dirId == null || dirId.isEmpty) {
      final resp = await _authed(server, '/api/listAni');
      final data = resp.data['data'] as Map?;
      final weekList = (data?['weekList'] as List?) ?? const [];
      final entries = <SourceEntry>[];
      final seen = <String>{};
      for (final w in weekList) {
        final items = ((w as Map)['items'] as List?) ?? const [];
        for (final a in items) {
          final am = (a as Map).cast<String, dynamic>();
          final id = am['id']?.toString() ?? am['title']?.toString() ?? '';
          if (id.isEmpty || !seen.add(id)) continue;
          entries.add(SourceEntry(
            id: 'ani:${jsonEncode(am)}',
            name: am['title']?.toString() ?? '未命名',
            isDir: true,
            thumbUrl: _httpOrNull(am['cover']?.toString()),
            raw: {'ani': am},
          ));
        }
      }
      entries.sort((a, b) => a.name.compareTo(b.name));
      return entries;
    }

    // 番剧层：用该 Ani 调 playList 列出剧集文件。
    if (dirId.startsWith('ani:')) {
      final aniMap = jsonDecode(dirId.substring(4)) as Map<String, dynamic>;
      final resp = await _authed(server, '/api/playList', data: aniMap);
      final list = (resp.data['data'] as List?) ?? const [];
      return list.map<SourceEntry>((p) {
        final pm = (p as Map);
        final filename = pm['filename']?.toString() ?? '';
        return SourceEntry(
          id: 'file:${base64.encode(utf8.encode(filename))}',
          name: pm['title']?.toString() ??
              pm['name']?.toString() ??
              filename.split('/').last,
          isDir: false,
          isVideo: true,
          raw: {'filename': filename},
        );
      }).toList();
    }

    return const [];
  }

  @override
  Future<List<SourceEntry>> search(ServerConfig server, String query) =>
      // 无源端搜索：交给浏览控制器降级为当前目录本地名称过滤。
      throw UnsupportedError('Ani-rss 不支持源端搜索');

  @override
  Future<ResolvedPlay> resolvePlay(ServerConfig server, SourceEntry entry) async {
    final filename = (entry.raw?['filename'] ?? '').toString();
    if (filename.isEmpty) throw SourceException('缺少文件信息');
    final token = await _ensureToken(server);
    final base = normalizeBaseUrl(server.activeLineUrl);
    final b64 = base64.encode(utf8.encode(filename));
    // 鉴权走查询参数 ?s=<token>，免去逐流 header（服务端 Form 鉴权）。
    final url = '$base/api/file'
        '?filename=${Uri.encodeQueryComponent(b64)}'
        '&s=${Uri.encodeQueryComponent(token)}';
    return ResolvedPlay(url: url, title: entry.name);
  }

  String? _httpOrNull(String? url) {
    if (url == null || url.isEmpty) return null;
    return url.startsWith('http') ? url : null;
  }
}
