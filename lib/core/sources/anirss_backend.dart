import 'dart:convert';

import 'anirss/anirss_token.dart';
import '../providers/server_providers.dart';
import 'media_source_backend.dart';
import 'source_http.dart';

/// Ani-rss 后端（wushuo894/ani-rss），负责**播放路径**（列目录 / 取流 / 字幕）。
/// 浏览/订阅/设置等深度适配走类型化的 `AniRssApi`，二者共享 [AniRssAuth] 的 token。
///
/// 端点/字段以仓库根 `api-docs.json`（OpenAPI v3）为准：
/// - `POST /api/listAni` → `ResultListAni`，data=`ListAni{weekList:[{items:Ani[]}]}`。
/// - `POST /api/playList` body=`Ani` → `ResultListPlayItem`，data=`PlayItem[]`。
///   `PlayItem.filename` 已是「路径+文件名」base64，`subtitles[]` 随列表返回。
/// - `GET /api/file?filename=<base64>` 流式返回视频（filename 直接用，勿再编码）。
///
/// 浏览映射（泛用浏览页用）：根目录列番剧；进入某番剧 → playList 列剧集；点文件 → 取流。
class AniRssBackend implements MediaSourceBackend {
  @override
  SourceKind get kind => SourceKind.anirss;

  AniRssAuth get _auth => AniRssAuth.instance;

  /// 账密登录拿令牌（登录页复用）。
  static Future<String> login(
    String baseUrl,
    String username,
    String password,
  ) =>
      AniRssAuth.login(baseUrl, username, password);

  @override
  Future<List<SourceEntry>> listDir(ServerConfig server, {String? dirId}) async {
    // 根目录：列番剧（当作文件夹）。data=ListAni{weekList:[{items:Ani[]}]}。
    if (dirId == null || dirId.isEmpty) {
      final resp = await _auth.authed(server, '/api/listAni');
      final data = _auth.unwrap(resp) as Map?;
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
            // image 是 https:// 封面；cover 是服务端本地路径，不可直接取。
            thumbUrl: _httpOrNull(am['image']?.toString()),
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
      final resp = await _auth.authed(server, '/api/playList', data: aniMap);
      final list = (_auth.unwrap(resp) as List?) ?? const [];
      final entries = list.map<SourceEntry>((p) {
        final pm = (p as Map).cast<String, dynamic>();
        // filename 已是 base64（路径+文件名），原样保存供取流用。
        final b64Filename = pm['filename']?.toString() ?? '';
        final display = pm['title']?.toString() ??
            pm['name']?.toString() ??
            _safeDecode(b64Filename);
        return SourceEntry(
          id: 'file:$b64Filename',
          name: display,
          isDir: false,
          isVideo: true,
          raw: {
            'filename': b64Filename,
            'episode': pm['episode'],
            'subtitles': pm['subtitles'],
          },
        );
      }).toList();
      entries.sort((a, b) {
        final ea = (a.raw?['episode'] as num?)?.toDouble() ?? double.infinity;
        final eb = (b.raw?['episode'] as num?)?.toDouble() ?? double.infinity;
        final c = ea.compareTo(eb);
        return c != 0 ? c : a.name.compareTo(b.name);
      });
      return entries;
    }

    return const [];
  }

  @override
  Future<List<SourceEntry>> search(ServerConfig server, String query) =>
      throw UnsupportedError('Ani-rss 不支持源端搜索');

  @override
  Future<ResolvedPlay> resolvePlay(ServerConfig server, SourceEntry entry) async {
    final b64Filename = (entry.raw?['filename'] ?? '').toString();
    if (b64Filename.isEmpty) throw SourceException('缺少文件信息');
    final token = await _auth.ensureToken(server);
    final base = normalizeBaseUrl(server.activeLineUrl);
    // filename 已是 base64，仅做查询参数转义，不可二次 base64。
    final url = '$base/api/file'
        '?filename=${Uri.encodeQueryComponent(b64Filename)}'
        '&${AniRssAuth.header}=${Uri.encodeQueryComponent(token)}';
    final headers = {AniRssAuth.header: token};
    return ResolvedPlay(
      url: url,
      title: entry.name,
      httpHeaders: headers,
      subtitles: _subtitlesOf(entry, base, token, headers),
    );
  }

  /// 把 PlayItem.subtitles 映射成外挂字幕轨（仅取可解析的绝对/相对 URL）。
  List<SourceSubtitle> _subtitlesOf(
    SourceEntry entry,
    String base,
    String token,
    Map<String, String> headers,
  ) {
    final raw = entry.raw?['subtitles'];
    if (raw is! List) return const [];
    final subs = <SourceSubtitle>[];
    for (final s in raw) {
      if (s is! Map) continue;
      final u = s['url']?.toString() ?? '';
      if (u.isEmpty) continue;
      final full = u.startsWith('http')
          ? u
          : '$base${u.startsWith('/') ? '' : '/'}$u';
      final sep = full.contains('?') ? '&' : '?';
      subs.add(SourceSubtitle(
        url: '$full$sep${AniRssAuth.header}=${Uri.encodeQueryComponent(token)}',
        title: s['name']?.toString(),
        httpHeaders: headers,
      ));
    }
    return subs;
  }

  String _safeDecode(String b64) {
    try {
      return utf8.decode(base64.decode(b64)).split('/').last;
    } catch (_) {
      return b64;
    }
  }

  String? _httpOrNull(String? url) {
    if (url == null || url.isEmpty) return null;
    return url.startsWith('http') ? url : null;
  }
}
