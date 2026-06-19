import 'dart:convert';
import 'dart:math';
import 'package:crypto/crypto.dart';
import 'package:dio/dio.dart';
import '../api_interfaces.dart';

enum DanmakuSourceType { dandanplay, custom }

/// 自定义弹幕源的鉴权方式。深度适配三个后端：
/// - [none]：无鉴权（自建且未开启鉴权）。
/// - [dandanplaySignature]：弹弹Play 开放平台签名（X-AppId/X-Timestamp/X-Signature），
///   也可用于自建的签名网关。
/// - [pathToken]：token 放在路径里，形如 `{host}/{token}/api/v2/...`（huangxd-/danmu_api）。
/// - [headerToken]：token 放在请求头（misaka_danmu_server 等）。
/// - [queryToken]：token 作为 `?token=` 查询参数。
enum DanmakuAuthType {
  none,
  dandanplaySignature,
  pathToken,
  headerToken,
  queryToken,
}

DanmakuAuthType danmakuAuthTypeFromName(String? name) {
  switch (name) {
    case 'dandanplaySignature':
      return DanmakuAuthType.dandanplaySignature;
    case 'pathToken':
      return DanmakuAuthType.pathToken;
    case 'headerToken':
      return DanmakuAuthType.headerToken;
    case 'queryToken':
      return DanmakuAuthType.queryToken;
    default:
      return DanmakuAuthType.none;
  }
}

class DanmakuSourceConfig {
  final String id;
  final DanmakuSourceType type;
  final String name;
  final String apiUrl;
  final int priority;
  final bool enabled;
  final DanmakuAuthType authType;
  final String? token;
  final String? appId;
  final String? appSecret;

  DanmakuSourceConfig({
    required this.id,
    required this.type,
    required this.name,
    required this.apiUrl,
    this.priority = 0,
    this.enabled = true,
    this.authType = DanmakuAuthType.none,
    this.token,
    this.appId,
    this.appSecret,
  });

  DanmakuSourceConfig copyWith({
    String? name,
    String? apiUrl,
    int? priority,
    bool? enabled,
    DanmakuAuthType? authType,
    String? token,
    String? appId,
    String? appSecret,
  }) {
    return DanmakuSourceConfig(
      id: id,
      type: type,
      name: name ?? this.name,
      apiUrl: apiUrl ?? this.apiUrl,
      priority: priority ?? this.priority,
      enabled: enabled ?? this.enabled,
      authType: authType ?? this.authType,
      token: token ?? this.token,
      appId: appId ?? this.appId,
      appSecret: appSecret ?? this.appSecret,
    );
  }

  /// 归一化到以 `/api/v2` 结尾的基础地址（不含路径 token）。
  String get baseUrl {
    var url = apiUrl.trim();
    while (url.endsWith('/')) {
      url = url.substring(0, url.length - 1);
    }
    if (url.endsWith('/api/v2')) return url;
    if (url.endsWith('/api/v1')) return '${url.substring(0, url.length - 7)}/api/v2';
    return '$url/api/v2';
  }

  /// 应用 [pathToken] 后的真正请求基础地址：把 token 插到 `/api/v2` 前面。
  /// 若用户已把 token 写进 URL（旧写法），token 字段留空即可，不会重复注入。
  String get requestBaseUrl {
    final base = baseUrl;
    if (authType != DanmakuAuthType.pathToken) return base;
    final t = token?.trim();
    if (t == null || t.isEmpty) return base;
    if (base.contains('/$t/')) return base; // 已包含
    if (base.endsWith('/api/v2')) {
      final host = base.substring(0, base.length - '/api/v2'.length);
      return '$host/$t/api/v2';
    }
    return '$base/$t';
  }
}

abstract class DanmakuSource {
  DanmakuSourceConfig get config;
  final Dio _dio = Dio(BaseOptions(
    connectTimeout: const Duration(seconds: 15),
    receiveTimeout: const Duration(seconds: 30),
  ));

  Dio get dio => _dio;

  Future<DanmakuMatchResult> match({
    required String fileName,
    String? fileHash,
    int? fileSize,
    double? videoDuration,
  });

  Future<DanmakuSearchResult> searchAnime({required String keyword});

  Future<DanmakuSearchResult> searchEpisodes({
    String? anime,
    int? tmdbId,
    String? episode,
  });

  Future<DanmakuAnime> getBangumiDetails({required String bangumiId});

  Future<List<DanmakuItem>> getComments({
    required String episodeId,
    int? from,
    bool withRelated = true,
    int chConvert = 0,
  });

  // ====== 共享解析（统一打上来源标签）======

  DanmakuItem parseComment(Map<String, dynamic> d) {
    // 弹弹Play `p` 字段格式： time,mode,color,userId （第 4 段是用户ID，不是字号）。
    final p = (d['p'] as String?)?.split(',') ?? const [];
    return DanmakuItem(
      time: double.tryParse(p.isNotEmpty ? p[0] : '0') ?? 0.0,
      text: d['m'] as String? ?? '',
      type: p.length > 1 ? (int.tryParse(p[1]) ?? 1) : 1,
      color: p.length > 2 ? (int.tryParse(p[2]) ?? 16777215) : 16777215,
      size: 25,
      source: config.name,
      cid: d['cid']?.toString(),
      userId: p.length > 3 ? p[3] : null,
    );
  }

  List<DanmakuItem> parseComments(dynamic raw) {
    final comments = raw as List<dynamic>? ?? const [];
    return comments
        .whereType<Map<String, dynamic>>()
        .map(parseComment)
        .toList();
  }

  DanmakuAnime parseAnime(Map<String, dynamic> a) {
    return DanmakuAnime(
      animeId: a['animeId']?.toString() ?? '',
      animeTitle: a['animeTitle'] as String? ?? '',
      bangumiId: a['bangumiId']?.toString(),
      type: a['type']?.toString(),
      typeDescription: a['typeDescription'] as String?,
      imageUrl: a['imageUrl'] as String?,
      year: a['year'] as int?,
      episodeCount: a['episodeCount'] as int?,
      sourceId: config.id,
      sourceName: config.name,
    );
  }

  DanmakuAnime parseAnimeWithEpisodes(Map<String, dynamic> a) {
    final episodes = (a['episodes'] as List<dynamic>? ?? const [])
        .whereType<Map<String, dynamic>>()
        .map((ep) => DanmakuEpisode(
              episodeId: ep['episodeId']?.toString() ?? '',
              episodeTitle: ep['episodeTitle'] as String? ?? '',
              episodeNumber: ep['episodeNumber']?.toString(),
              sourceId: config.id,
              sourceName: config.name,
            ))
        .toList();
    return DanmakuAnime(
      animeId: a['animeId']?.toString() ?? '',
      animeTitle: a['animeTitle'] as String? ?? '',
      bangumiId: a['bangumiId']?.toString(),
      type: a['type']?.toString(),
      typeDescription: a['typeDescription'] as String?,
      imageUrl: a['imageUrl'] as String?,
      year: a['year'] as int?,
      episodeCount: a['episodeCount'] as int?,
      episodes: episodes,
      bangumiUrl: a['bangumiUrl'] as String?,
      sourceId: config.id,
      sourceName: config.name,
    );
  }

  DanmakuMatchResult parseMatchResult(Map<String, dynamic> data) {
    final isMatched = data['isMatched'] as bool? ?? false;
    final matches = (data['matches'] as List<dynamic>? ?? const [])
        .whereType<Map<String, dynamic>>()
        .map((item) => DanmakuMatchItem(
              episodeId: item['episodeId']?.toString() ?? '',
              animeId: item['animeId']?.toString() ?? '',
              animeTitle: item['animeTitle'] as String? ?? '',
              episodeTitle: item['episodeTitle'] as String? ?? '',
              type: item['type']?.toString(),
              typeDescription: item['typeDescription'] as String?,
              shift: item['shift'] as int?,
              sourceId: config.id,
              sourceName: config.name,
            ))
        .toList();
    return DanmakuMatchResult(isMatched: isMatched, matches: matches);
  }
}

/// 弹弹Play 官方源（固定基址 + 签名验证模式）。
///
/// 凭据仅编译期注入（Action 环境变量 DANDANPLAY_APP_ID / DANDANPLAY_APP_SECRET，
/// 二者均可多行、一行一个并按行配对，用于分摊调用配额）。普通用户无凭据、也不手填。
/// 签名按官方文档：`X-Signature = Base64(SHA256(AppId + Timestamp + Path + AppSecret))`。
class DandanplaySource extends DanmakuSource {
  @override
  final DanmakuSourceConfig config;
  final List<({String appId, String secret})> _credentials;
  static const String _baseUrl = 'https://api.dandanplay.net';
  static final _random = Random();

  DandanplaySource({
    required this.config,
    required String appSecret,
    required String appId,
  }) : _credentials = _buildCredentials(appId, appSecret);

  // 兼容多种分隔：换行/逗号/分号（CI 可能把多行凭据合成逗号分隔）。
  static List<String> _lines(String v) => v
      .split(RegExp(r'[\n,;]'))
      .map((s) => s.trim())
      .where((s) => s.isNotEmpty)
      .toList();

  static List<({String appId, String secret})> _buildCredentials(
      String appIdRaw, String secretRaw) {
    final ids = _lines(appIdRaw);
    final secrets = _lines(secretRaw);
    if (ids.isEmpty || secrets.isEmpty) return const [];
    // 多对凭据按行配对；只有一个 AppId 时与每个 Secret 配对（兼容单 App 多 Secret）。
    if (ids.length == 1) {
      return [for (final s in secrets) (appId: ids.first, secret: s)];
    }
    final n = ids.length < secrets.length ? ids.length : secrets.length;
    return [for (var i = 0; i < n; i++) (appId: ids[i], secret: secrets[i])];
  }

  bool get hasCredentials => _credentials.isNotEmpty;

  String _generateSignature(
      String appId, String path, int timestamp, String secret) {
    final data = '$appId$timestamp$path$secret';
    return base64.encode(sha256.convert(utf8.encode(data)).bytes);
  }

  Options _authOptions(String path) {
    if (_credentials.isEmpty) return Options();
    final cred = _credentials[_random.nextInt(_credentials.length)];
    final timestamp = DateTime.now().millisecondsSinceEpoch ~/ 1000;
    final signature =
        _generateSignature(cred.appId, path, timestamp, cred.secret);
    return Options(headers: {
      'X-AppId': cred.appId,
      'X-Timestamp': timestamp.toString(),
      'X-Signature': signature,
    });
  }

  @override
  Future<DanmakuMatchResult> match({
    required String fileName,
    String? fileHash,
    int? fileSize,
    double? videoDuration,
  }) async {
    const path = '/api/v2/match';
    final resp = await dio.post(
      '$_baseUrl$path',
      data: {
        'fileName': fileName,
        'fileHash': fileHash ?? '',
        'fileSize': fileSize ?? 0,
        'videoDuration': videoDuration ?? 0,
      },
      options: _authOptions(path),
    );
    return parseMatchResult(resp.data as Map<String, dynamic>);
  }

  @override
  Future<DanmakuSearchResult> searchAnime({required String keyword}) async {
    const path = '/api/v2/search/anime';
    final resp = await dio.get(
      '$_baseUrl$path',
      queryParameters: {'keyword': keyword},
      options: _authOptions(path),
    );
    final data = resp.data as Map<String, dynamic>;
    final animes = (data['animes'] as List<dynamic>? ?? const [])
        .whereType<Map<String, dynamic>>()
        .map(parseAnime)
        .toList();
    return DanmakuSearchResult(animes: animes);
  }

  @override
  Future<DanmakuSearchResult> searchEpisodes({
    String? anime,
    int? tmdbId,
    String? episode,
  }) async {
    const path = '/api/v2/search/episodes';
    final params = <String, dynamic>{};
    if (anime != null) params['anime'] = anime;
    if (tmdbId != null) params['tmdbId'] = tmdbId;
    if (episode != null) params['episode'] = episode;
    final resp = await dio.get(
      '$_baseUrl$path',
      queryParameters: params,
      options: _authOptions(path),
    );
    final data = resp.data as Map<String, dynamic>;
    final hasMore = data['hasMore'] as bool? ?? false;
    final animes = (data['animes'] as List<dynamic>? ?? const [])
        .whereType<Map<String, dynamic>>()
        .map(parseAnimeWithEpisodes)
        .toList();
    return DanmakuSearchResult(animes: animes, hasMore: hasMore);
  }

  @override
  Future<DanmakuAnime> getBangumiDetails({required String bangumiId}) async {
    final path = '/api/v2/bangumi/$bangumiId';
    final resp = await dio.get('$_baseUrl$path', options: _authOptions(path));
    final data = resp.data as Map<String, dynamic>;
    final bangumi = data['bangumi'] as Map<String, dynamic>? ?? data;
    return parseAnimeWithEpisodes(bangumi);
  }

  Future<DanmakuAnime> getBangumiByBgmtvId({required int bgmtvSubjectId}) async {
    final path = '/api/v2/bangumi/bgmtv/$bgmtvSubjectId';
    final resp = await dio.get('$_baseUrl$path', options: _authOptions(path));
    final data = resp.data as Map<String, dynamic>;
    final bangumi = data['bangumi'] as Map<String, dynamic>? ?? data;
    return parseAnimeWithEpisodes(bangumi);
  }

  @override
  Future<List<DanmakuItem>> getComments({
    required String episodeId,
    int? from,
    bool withRelated = true,
    int chConvert = 0,
  }) async {
    final path = '/api/v2/comment/$episodeId';
    final params = <String, dynamic>{
      'withRelated': withRelated,
      'chConvert': chConvert,
    };
    if (from != null) params['from'] = from;
    final resp = await dio.get(
      '$_baseUrl$path',
      queryParameters: params,
      options: _authOptions(path),
    );
    final data = resp.data as Map<String, dynamic>;
    return parseComments(data['comments']);
  }
}

/// 通用自建源（兼容弹弹Play /api/v2 接口）。按 [DanmakuAuthType] 应用鉴权。
class CustomDanmakuSource extends DanmakuSource {
  @override
  final DanmakuSourceConfig config;

  CustomDanmakuSource({required this.config});

  String get _base => config.requestBaseUrl;

  /// 自建签名网关（极少见）：复用弹弹Play 签名头。
  final _rand = Random();

  Map<String, dynamic> _withTokenQuery(Map<String, dynamic> params) {
    if (config.authType == DanmakuAuthType.queryToken) {
      final t = config.token?.trim();
      if (t != null && t.isNotEmpty) {
        return {...params, 'token': t};
      }
    }
    return params;
  }

  Options? _authOptions(String pathForSignature) {
    switch (config.authType) {
      case DanmakuAuthType.headerToken:
        final t = config.token?.trim();
        if (t == null || t.isEmpty) return null;
        return Options(headers: {
          'Authorization': 'Bearer $t',
          'X-Token': t,
          'X-Api-Key': t,
        });
      case DanmakuAuthType.dandanplaySignature:
        final appId = config.appId?.trim() ?? '';
        final secrets = (config.appSecret ?? '')
            .split('\n')
            .map((s) => s.trim())
            .where((s) => s.isNotEmpty)
            .toList();
        if (appId.isEmpty || secrets.isEmpty) return null;
        final ts = DateTime.now().millisecondsSinceEpoch ~/ 1000;
        final secret = secrets[_rand.nextInt(secrets.length)];
        final sig = base64
            .encode(sha256.convert(utf8.encode('$appId$ts$pathForSignature$secret')).bytes);
        return Options(headers: {
          'X-AppId': appId,
          'X-Timestamp': ts.toString(),
          'X-Signature': sig,
        });
      case DanmakuAuthType.none:
      case DanmakuAuthType.pathToken:
      case DanmakuAuthType.queryToken:
        return null;
    }
  }

  @override
  Future<DanmakuMatchResult> match({
    required String fileName,
    String? fileHash,
    int? fileSize,
    double? videoDuration,
  }) async {
    try {
      final resp = await dio.post(
        '$_base/match',
        data: {
          'fileName': fileName,
          'fileHash': fileHash ?? '',
          'fileSize': fileSize ?? 0,
          'videoDuration': videoDuration ?? 0,
        },
        queryParameters: _withTokenQuery(const {}),
        options: _authOptions('/api/v2/match'),
      );
      return parseMatchResult(resp.data as Map<String, dynamic>);
    } catch (_) {
      return DanmakuMatchResult(isMatched: false, matches: const []);
    }
  }

  @override
  Future<DanmakuSearchResult> searchAnime({required String keyword}) async {
    try {
      final resp = await dio.get(
        '$_base/search/anime',
        queryParameters: _withTokenQuery({'keyword': keyword}),
        options: _authOptions('/api/v2/search/anime'),
      );
      final data = resp.data as Map<String, dynamic>;
      final animes = (data['animes'] as List<dynamic>? ?? const [])
          .whereType<Map<String, dynamic>>()
          .map(parseAnime)
          .toList();
      return DanmakuSearchResult(animes: animes);
    } catch (_) {
      return DanmakuSearchResult(animes: const []);
    }
  }

  @override
  Future<DanmakuSearchResult> searchEpisodes({
    String? anime,
    int? tmdbId,
    String? episode,
  }) async {
    final params = <String, dynamic>{};
    if (anime != null) params['anime'] = anime;
    if (episode != null) params['episode'] = episode;
    try {
      final resp = await dio.get(
        '$_base/search/episodes',
        queryParameters: _withTokenQuery(params),
        options: _authOptions('/api/v2/search/episodes'),
      );
      final data = resp.data as Map<String, dynamic>;
      final hasMore = data['hasMore'] as bool? ?? false;
      final animes = (data['animes'] as List<dynamic>? ?? const [])
          .whereType<Map<String, dynamic>>()
          .map(parseAnimeWithEpisodes)
          .toList();
      return DanmakuSearchResult(animes: animes, hasMore: hasMore);
    } catch (_) {
      return DanmakuSearchResult(animes: const []);
    }
  }

  @override
  Future<DanmakuAnime> getBangumiDetails({required String bangumiId}) async {
    final resp = await dio.get(
      '$_base/bangumi/$bangumiId',
      queryParameters: _withTokenQuery(const {}),
      options: _authOptions('/api/v2/bangumi/$bangumiId'),
    );
    final data = resp.data as Map<String, dynamic>;
    final bangumi = data['bangumi'] as Map<String, dynamic>? ?? data;
    return parseAnimeWithEpisodes(bangumi);
  }

  @override
  Future<List<DanmakuItem>> getComments({
    required String episodeId,
    int? from,
    bool withRelated = true,
    int chConvert = 0,
  }) async {
    final params = <String, dynamic>{
      'async': '1',
      'format': 'json',
    };
    if (from != null) params['from'] = from;
    if (withRelated) params['withRelated'] = 'true';
    if (chConvert != 0) params['chConvert'] = chConvert;
    try {
      final resp = await dio.get(
        '$_base/comment/$episodeId',
        queryParameters: _withTokenQuery(params),
        options: _authOptions('/api/v2/comment/$episodeId'),
      );
      final data = resp.data as Map<String, dynamic>;

      final taskId = data['taskId']?.toString();
      if (taskId != null && taskId.isNotEmpty) {
        return _pollAsyncComments(taskId);
      }
      return parseComments(data['comments']);
    } catch (_) {
      return const [];
    }
  }

  Future<List<DanmakuItem>> _pollAsyncComments(String taskId) async {
    const interval = Duration(seconds: 2);
    const maxAttempts = 15;
    for (var i = 0; i < maxAttempts; i++) {
      await Future.delayed(interval);
      try {
        final resp = await dio.get(
          '$_base/taskcomment/$taskId',
          queryParameters: _withTokenQuery(const {}),
          options: _authOptions('/api/v2/taskcomment/$taskId'),
        );
        final data = resp.data as Map<String, dynamic>;
        final status = data['status']?.toString();
        if (status == 'pending' || status == 'processing') continue;
        return parseComments(data['comments']);
      } catch (_) {
        continue;
      }
    }
    return const [];
  }
}
