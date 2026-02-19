import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:http/http.dart' as http;
import 'package:lin_player_server_api/network/lin_http_client.dart';

import 'src/player/danmaku.dart';
import 'package:lin_player_prefs/danmaku_preferences.dart';

const String _kOfficialDandanplayHost = 'api.dandanplay.net';
const String _kBuiltInDandanplayProxyRaw = String.fromEnvironment(
  'LINPLAYER_DANDANPLAY_PROXY_URL',
  defaultValue: '',
);

String get builtInDandanplayProxyUrl =>
    normalizeDanmakuApiBaseUrl(_kBuiltInDandanplayProxyRaw);

bool get hasBuiltInDandanplayProxy => builtInDandanplayProxyUrl.isNotEmpty;

bool isOfficialDandanplayUrl(String url) {
  final host = Uri.tryParse(url.trim())?.host.toLowerCase() ?? '';
  return host == _kOfficialDandanplayHost;
}

bool shouldUseBuiltInProxyForOfficialUrl({
  required String inputBaseUrl,
  required String appId,
  required String appSecret,
}) {
  if (!isOfficialDandanplayUrl(inputBaseUrl)) return false;
  if (!hasBuiltInDandanplayProxy) return false;
  return !_hasClientCredentials(appId: appId, appSecret: appSecret);
}

String resolveEffectiveDanmakuApiBaseUrl({
  required String inputBaseUrl,
  required String appId,
  required String appSecret,
}) {
  if (shouldUseBuiltInProxyForOfficialUrl(
    inputBaseUrl: inputBaseUrl,
    appId: appId,
    appSecret: appSecret,
  )) {
    return builtInDandanplayProxyUrl;
  }
  return normalizeDanmakuApiBaseUrl(inputBaseUrl);
}

String normalizeDanmakuApiBaseUrl(String baseUrl) {
  final v = baseUrl.trim();
  if (v.isEmpty) return '';
  final uri = Uri.tryParse(v);
  if (uri == null || uri.host.isEmpty) return v;

  var path = uri.path.replaceAll(RegExp(r'/+$'), '');
  if (path.toLowerCase().endsWith('/api/v2')) {
    path = path.substring(0, path.length - '/api/v2'.length);
  }

  return uri
      .replace(
        path: path,
        query: null,
        fragment: '',
      )
      .toString();
}

bool _hasClientCredentials({
  required String appId,
  required String appSecret,
}) {
  return appId.trim().isNotEmpty && appSecret.trim().isNotEmpty;
}

class DandanplayMatchResult {
  final int episodeId;
  final int animeId;
  final String animeTitle;
  final String episodeTitle;
  final double shiftSeconds;
  final String imageUrl;

  const DandanplayMatchResult({
    required this.episodeId,
    required this.animeId,
    required this.animeTitle,
    required this.episodeTitle,
    required this.shiftSeconds,
    required this.imageUrl,
  });

  factory DandanplayMatchResult.fromJson(Map<String, dynamic> json) {
    return DandanplayMatchResult(
      episodeId: (json['episodeId'] as num?)?.toInt() ?? 0,
      animeId: (json['animeId'] as num?)?.toInt() ?? 0,
      animeTitle: json['animeTitle'] as String? ?? '',
      episodeTitle: json['episodeTitle'] as String? ?? '',
      shiftSeconds: (json['shift'] as num?)?.toDouble() ?? 0.0,
      imageUrl: json['imageUrl'] as String? ?? '',
    );
  }
}

class DandanplayMatchResponse {
  final bool success;
  final int errorCode;
  final String errorMessage;
  final bool isMatched;
  final List<DandanplayMatchResult> matches;

  const DandanplayMatchResponse({
    required this.success,
    required this.errorCode,
    required this.errorMessage,
    required this.isMatched,
    required this.matches,
  });

  factory DandanplayMatchResponse.fromJson(Map<String, dynamic> json) {
    final rawMatches = (json['matches'] as List?) ?? const [];
    return DandanplayMatchResponse(
      success: json['success'] as bool? ?? true,
      errorCode: (json['errorCode'] as num?)?.toInt() ?? 0,
      errorMessage: json['errorMessage'] as String? ?? '',
      isMatched: json['isMatched'] as bool? ?? false,
      matches: rawMatches
          .whereType<Map>()
          .map((e) => DandanplayMatchResult.fromJson(e.cast<String, dynamic>()))
          .where((e) => e.episodeId > 0)
          .toList(),
    );
  }
}

class DandanplayCommentResponse {
  final int count;
  final List<Map<String, dynamic>> comments;

  const DandanplayCommentResponse(
      {required this.count, required this.comments});

  factory DandanplayCommentResponse.fromJson(Map<String, dynamic> json) {
    final raw = (json['comments'] as List?) ?? const [];
    return DandanplayCommentResponse(
      count: (json['count'] as num?)?.toInt() ?? raw.length,
      comments:
          raw.whereType<Map>().map((e) => e.cast<String, dynamic>()).toList(),
    );
  }
}

class DandanplaySearchEpisodeResult {
  final int episodeId;
  final String animeTitle;
  final String episodeTitle;
  final int? episodeNumber;

  const DandanplaySearchEpisodeResult({
    required this.episodeId,
    required this.animeTitle,
    required this.episodeTitle,
    this.episodeNumber,
  });
}

class DandanplaySearchCandidate {
  final String inputBaseUrl;
  final String sourceHost;
  final int episodeId;
  final String animeTitle;
  final String episodeTitle;
  final int? episodeNumber;

  const DandanplaySearchCandidate({
    required this.inputBaseUrl,
    required this.sourceHost,
    required this.episodeId,
    required this.animeTitle,
    required this.episodeTitle,
    this.episodeNumber,
  });
}

class DandanplaySearchInputHint {
  final String keyword;
  final int? episodeHint;

  const DandanplaySearchInputHint({
    required this.keyword,
    required this.episodeHint,
  });
}

class DandanplayApiClient {
  DandanplayApiClient({
    required this.baseUrl,
    this.appId = '',
    this.appSecret = '',
    http.Client? client,
  }) : _client = client ?? LinHttpClientFactory.createClient();

  final String baseUrl;
  final String appId;
  final String appSecret;
  final http.Client _client;
  static const Duration _timeout = Duration(seconds: 12);

  bool get _hasAuth => appId.trim().isNotEmpty && appSecret.trim().isNotEmpty;

  Uri _buildUri(String apiPath, {Map<String, String>? query}) {
    final base = Uri.parse(normalizeDanmakuApiBaseUrl(baseUrl));
    final basePath = base.path.replaceAll(RegExp(r'/+$'), '');
    final path = '$basePath$apiPath';
    final sortedQuery = (query == null || query.isEmpty)
        ? null
        : Map<String, String>.fromEntries(
            query.entries.toList()..sort((a, b) => a.key.compareTo(b.key)),
          );
    return base.replace(
      path: path,
      queryParameters: sortedQuery,
      fragment: '',
    );
  }

  bool _isAuthFailureStatus(int statusCode) =>
      statusCode == 401 || statusCode == 403;

  Map<String, String> _signatureHeaders(
    Uri uri, {
    bool includeQuery = false,
    bool timestampMilliseconds = false,
    bool useHexDigest = false,
  }) {
    if (!_hasAuth) return const {};
    final ts = timestampMilliseconds
        ? DateTime.now().toUtc().millisecondsSinceEpoch.toString()
        : (DateTime.now().toUtc().millisecondsSinceEpoch ~/ 1000).toString();
    final path = uri.path.toLowerCase();
    final target = includeQuery && uri.hasQuery ? '$path?${uri.query}' : path;
    final raw = '$appId$ts$target$appSecret';
    final digest = sha256.convert(utf8.encode(raw));
    final sig = useHexDigest ? digest.toString() : base64.encode(digest.bytes);
    return {
      'X-AppId': appId,
      'X-Timestamp': ts,
      'X-Signature': sig,
    };
  }

  Future<http.Response> _postJson(Uri uri, Object body) async {
    final baseHeaders = <String, String>{
      'Accept': 'application/json',
      'Content-Type': 'application/json',
    };
    final payload = jsonEncode(body);

    Future<http.Response> attempt(Map<String, String> headers) =>
        _client.post(uri, headers: headers, body: payload).timeout(_timeout);

    if (!_hasAuth) return attempt(baseHeaders);

    final isOfficial = isOfficialDandanplayUrl(baseUrl);
    final strategies = isOfficial
        ? const <({bool query, bool ms, bool hex})>[
            (query: false, ms: false, hex: false),
          ]
        : const <({bool query, bool ms, bool hex})>[
            (query: false, ms: false, hex: false),
            (query: true, ms: false, hex: false),
            (query: false, ms: false, hex: true),
            (query: true, ms: false, hex: true),
            (query: false, ms: true, hex: false),
            (query: true, ms: true, hex: false),
            (query: false, ms: true, hex: true),
            (query: true, ms: true, hex: true),
          ];

    http.Response? last;
    for (final s in strategies) {
      final headers = <String, String>{
        ...baseHeaders,
        ..._signatureHeaders(
          uri,
          includeQuery: s.query,
          timestampMilliseconds: s.ms,
          useHexDigest: s.hex,
        ),
      };
      final resp = await attempt(headers);
      last = resp;
      if (!_isAuthFailureStatus(resp.statusCode)) return resp;
    }

    if (isOfficial) {
      final headers = <String, String>{
        ...baseHeaders,
        'X-AppId': appId,
        'X-AppSecret': appSecret,
      };
      final resp = await attempt(headers);
      last = resp;
      if (!_isAuthFailureStatus(resp.statusCode)) return resp;
    }
    return last!;
  }

  Future<http.Response> _get(Uri uri) async {
    final baseHeaders = <String, String>{
      'Accept': 'application/json',
    };

    Future<http.Response> attempt(Map<String, String> headers) =>
        _client.get(uri, headers: headers).timeout(_timeout);

    if (!_hasAuth) return attempt(baseHeaders);

    final isOfficial = isOfficialDandanplayUrl(baseUrl);
    final strategies = isOfficial
        ? const <({bool query, bool ms, bool hex})>[
            (query: false, ms: false, hex: false),
          ]
        : const <({bool query, bool ms, bool hex})>[
            (query: false, ms: false, hex: false),
            (query: true, ms: false, hex: false),
            (query: false, ms: false, hex: true),
            (query: true, ms: false, hex: true),
            (query: false, ms: true, hex: false),
            (query: true, ms: true, hex: false),
            (query: false, ms: true, hex: true),
            (query: true, ms: true, hex: true),
          ];

    http.Response? last;
    for (final s in strategies) {
      final headers = <String, String>{
        ...baseHeaders,
        ..._signatureHeaders(
          uri,
          includeQuery: s.query,
          timestampMilliseconds: s.ms,
          useHexDigest: s.hex,
        ),
      };
      final resp = await attempt(headers);
      last = resp;
      if (!_isAuthFailureStatus(resp.statusCode)) return resp;
    }

    if (isOfficial) {
      final headers = <String, String>{
        ...baseHeaders,
        'X-AppId': appId,
        'X-AppSecret': appSecret,
      };
      final resp = await attempt(headers);
      last = resp;
      if (!_isAuthFailureStatus(resp.statusCode)) return resp;
    }
    return last!;
  }

  String _decodeBody(http.Response resp) {
    final bytes = resp.bodyBytes;
    if (bytes.isEmpty) return '';
    try {
      return utf8.decode(bytes);
    } on FormatException {
      return latin1.decode(bytes);
    }
  }

  dynamic _decodeJson(http.Response resp) {
    final body = _decodeBody(resp).trim();
    if (body.isEmpty) return null;
    return jsonDecode(body);
  }

  Map<String, dynamic> _decodeJsonMap(http.Response resp) {
    final decoded = _decodeJson(resp);
    if (decoded is Map) return decoded.cast<String, dynamic>();
    throw const FormatException('Expected a JSON object.');
  }

  String _extractErrorDetails(http.Response resp) {
    final err = resp.headers['x-error-message']?.trim();
    if (err != null && err.isNotEmpty) return err;

    try {
      final decoded = _decodeJson(resp);
      if (decoded is Map) {
        final map = decoded.cast<dynamic, dynamic>();
        final msg = _firstNonEmptyString(
          map['errorMessage'],
          map['message'],
          map['error'],
          map['msg'],
          map['detail'],
        );
        if (msg.isNotEmpty) return msg;
      }
    } catch (_) {
      // Ignore parse errors.
    }

    final text = _decodeBody(resp).trim();
    if (text.isEmpty) return '';
    const maxLen = 160;
    return text.length > maxLen ? '${text.substring(0, maxLen)}…' : text;
  }

  String _formatHttpError({
    required String action,
    required Uri uri,
    required http.Response resp,
  }) {
    final details = _extractErrorDetails(resp);
    final endpoint =
        uri.host.isEmpty ? uri.path : '${uri.host}${uri.path}'.trim();

    final sb = StringBuffer('$action (HTTP ${resp.statusCode})');
    if (details.isNotEmpty) sb.write(': $details');
    if (endpoint.isNotEmpty) sb.write(' [$endpoint]');

    if (_isAuthFailureStatus(resp.statusCode)) {
      if (isOfficialDandanplayUrl(baseUrl) && !_hasAuth) {
        sb.write(' 提示：官方API已强制鉴权，请在弹幕设置中填写AppId/AppSecret，或使用代理/自建danmu_api。');
      } else if (resp.headers['x-error-message'] == 'Invalid Timestamp') {
        sb.write(' 提示：请检查系统时间是否准确。');
      } else if (!isOfficialDandanplayUrl(baseUrl)) {
        final basePath = Uri.tryParse(baseUrl)?.path ?? '';
        if (basePath.isEmpty || basePath == '/') {
          sb.write(' 提示：如果你使用的是danmu_api，请确认URL是否包含token路径段（如/87654321）。');
        }
      }
    } else if (resp.statusCode == 404 && !isOfficialDandanplayUrl(baseUrl)) {
      sb.write(' 提示：如果你使用的是danmu_api，baseUrl可能需要包含token路径段（如/87654321）。');
    }

    return sb.toString();
  }

  Future<DandanplayMatchResponse> match({
    required String fileName,
    String? fileHash,
    required int fileSize,
    required int videoDurationSeconds,
    required String matchMode,
  }) async {
    final uri = _buildUri('/api/v2/match');
    final body = {
      'fileName': fileName,
      'fileHash': fileHash,
      'fileSize': fileSize,
      'videoDuration': videoDurationSeconds,
      'matchMode': matchMode,
    };
    final resp = await _postJson(uri, body);
    if (resp.statusCode != 200) {
      throw Exception(_formatHttpError(
        action: '弹幕匹配失败',
        uri: uri,
        resp: resp,
      ));
    }
    final map = _decodeJsonMap(resp);
    return DandanplayMatchResponse.fromJson(map);
  }

  Future<DandanplayCommentResponse> getComments({
    required int episodeId,
    bool withRelated = true,
    int from = 0,
    int chConvert = 0,
  }) async {
    final uri = _buildUri(
      '/api/v2/comment/$episodeId',
      query: {
        'from': from.toString(),
        'withRelated': withRelated ? 'true' : 'false',
        'chConvert': chConvert.toString(),
      },
    );
    var effectiveUri = uri;
    var resp = await _get(effectiveUri);
    if (resp.statusCode == 302) {
      final location = resp.headers['location']?.trim();
      if (location != null && location.isNotEmpty) {
        final parsed = Uri.tryParse(location);
        if (parsed != null) {
          effectiveUri = parsed.hasScheme ? parsed : uri.resolveUri(parsed);
          if (effectiveUri.host == uri.host) {
            resp = await _get(effectiveUri);
          } else {
            resp = await _client.get(
              effectiveUri,
              headers: const {'Accept': 'application/json'},
            ).timeout(_timeout);
          }
        }
      }
    }
    if (resp.statusCode != 200) {
      throw Exception(_formatHttpError(
        action: '获取弹幕失败',
        uri: effectiveUri,
        resp: resp,
      ));
    }
    final map = _decodeJsonMap(resp);
    return DandanplayCommentResponse.fromJson(map);
  }

  Future<List<DandanplaySearchEpisodeResult>> searchEpisodes({
    required String anime,
    int? episode,
  }) async {
    final q = anime.trim();
    if (q.isEmpty) return const [];

    final query = <String, String>{'anime': q};
    if (episode != null && episode > 0) {
      query['episode'] = episode.toString();
    }

    final uri = _buildUri('/api/v2/search/episodes', query: query);
    final resp = await _get(uri);
    if (resp.statusCode != 200) {
      throw Exception(_formatHttpError(
        action: '搜索弹幕条目失败',
        uri: uri,
        resp: resp,
      ));
    }

    return _extractSearchEpisodes(_decodeJson(resp));
  }

  List<DandanplaySearchEpisodeResult> _extractSearchEpisodes(dynamic decoded) {
    final out = <DandanplaySearchEpisodeResult>[];

    void walk(dynamic node, {String animeHint = ''}) {
      if (node is List) {
        for (final item in node) {
          walk(item, animeHint: animeHint);
        }
        return;
      }
      if (node is! Map) return;

      final map = node.cast<dynamic, dynamic>();
      final animeTitle = _firstNonEmptyString(
        map['animeTitle'],
        map['animeName'],
        map['anime'],
        map['title'],
        animeHint,
      );

      final episodeId = _asInt(
            map['episodeId'] ?? map['id'] ?? map['episodeID'],
          ) ??
          0;
      if (episodeId > 0) {
        final episodeTitle = _firstNonEmptyString(
          map['episodeTitle'],
          map['name'],
          map['title'],
        );
        final episodeNumber = _asInt(
          map['episode'] ?? map['episodeNumber'] ?? map['ep'] ?? map['sort'],
        );
        out.add(
          DandanplaySearchEpisodeResult(
            episodeId: episodeId,
            animeTitle: animeTitle,
            episodeTitle: episodeTitle,
            episodeNumber: episodeNumber,
          ),
        );
      }

      for (final value in map.values) {
        if (value is List || value is Map) {
          walk(value, animeHint: animeTitle.isEmpty ? animeHint : animeTitle);
        }
      }
    }

    walk(decoded);
    final uniq = <int, DandanplaySearchEpisodeResult>{};
    for (final item in out) {
      uniq[item.episodeId] = item;
    }
    return uniq.values.toList(growable: false);
  }

  void close() => _client.close();
}

int? _asInt(dynamic value) {
  if (value == null) return null;
  if (value is int) return value;
  if (value is num) return value.toInt();
  return int.tryParse(value.toString().trim());
}

String _firstNonEmptyString(dynamic a,
    [dynamic b, dynamic c, dynamic d, dynamic e]) {
  final values = [a, b, c, d, e];
  for (final v in values) {
    final s = (v ?? '').toString().trim();
    if (s.isNotEmpty) return s;
  }
  return '';
}

String stripFileExtension(String name) {
  final v = name.trim();
  final idx = v.lastIndexOf('.');
  if (idx <= 0) return v;
  final ext = v.substring(idx + 1).toLowerCase();
  const known = {
    // Video containers.
    'mkv',
    'mp4',
    'm4v',
    'mov',
    'avi',
    'flv',
    'webm',
    'ts',
    'm2ts',
    'mpg',
    'mpeg',
    'wmv',
    'rm',
    'rmvb',
    '3gp',
    // Danmaku files.
    'xml',
  };
  if (!known.contains(ext)) return v;
  return v.substring(0, idx);
}

class _SearchHint {
  final String keyword;
  final int? episodeHint;

  const _SearchHint({required this.keyword, required this.episodeHint});
}

_SearchHint _buildSearchHint(String inputName) {
  final normalized = inputName.replaceAll('_', ' ').trim();
  int? episodeHint;
  int? markerStart;

  void pickMarker(Match? m) {
    if (m == null) return;
    if (markerStart == null || m.start < markerStart!) {
      markerStart = m.start;
    }
  }

  final sePattern = RegExp(
    r'\bS\d{1,2}\s*E(\d{1,3})\b',
    caseSensitive: false,
  );
  final epPattern = RegExp(
    r'\bEP?\s*\.?-?\s*(\d{1,3})\b',
    caseSensitive: false,
  );
  final zhPattern = RegExp(
    r'第\s*(\d{1,3})\s*[话話集]',
    caseSensitive: false,
  );

  final se = sePattern.firstMatch(normalized);
  final ep = epPattern.firstMatch(normalized);
  final zh = zhPattern.firstMatch(normalized);

  if (se != null) {
    episodeHint = int.tryParse(se.group(1)!);
  } else if (ep != null) {
    episodeHint = int.tryParse(ep.group(1)!);
  } else if (zh != null) {
    episodeHint = int.tryParse(zh.group(1)!);
  }

  pickMarker(se);
  pickMarker(ep);
  pickMarker(zh);

  final keywordSeed = (markerStart != null && markerStart! > 0)
      ? normalized.substring(0, markerStart!).trim()
      : normalized;

  var keyword = keywordSeed
      .replaceAll(
        RegExp(r'\bS\d{1,2}\s*E\d{1,3}\b', caseSensitive: false),
        ' ',
      )
      .replaceAll(
        RegExp(r'\bEP?\s*\.?-?\s*\d{1,3}\b', caseSensitive: false),
        ' ',
      )
      .replaceAll(
        RegExp(r'第\s*\d{1,3}\s*[话話集]', caseSensitive: false),
        ' ',
      )
      .replaceAll(RegExp(r'\[[^\]]*]'), ' ')
      .replaceAll(RegExp(r'\([^)]*\)'), ' ')
      .replaceAll(
        RegExp(
          r'\b(2160p|1080p|720p|x265|x264|hevc|av1|web-?dl|webrip|bluray|bdrip|aac|flac|ac3|dts)\b',
          caseSensitive: false,
        ),
        ' ',
      )
      .replaceAll(RegExp(r'\s+'), ' ')
      .trim();
  if (keyword.length > 80) {
    keyword = keyword.substring(0, 80).trim();
  }
  if (keyword.isEmpty) {
    keyword = stripFileExtension(normalized);
  }

  return _SearchHint(keyword: keyword, episodeHint: episodeHint);
}

DandanplaySearchEpisodeResult _pickSearchCandidate(
  List<DandanplaySearchEpisodeResult> candidates,
  int? episodeHint,
) {
  if (candidates.isEmpty) {
    throw StateError('candidates must not be empty');
  }
  if (episodeHint != null && episodeHint > 0) {
    for (final item in candidates) {
      if (item.episodeNumber != null && item.episodeNumber == episodeHint) {
        return item;
      }
    }
  }
  return candidates.first;
}

Future<List<DandanplaySearchEpisodeResult>> _searchEpisodesSmart({
  required DandanplayApiClient client,
  required String keyword,
  int? episodeHint,
}) async {
  final byAnimeOnly = await client.searchEpisodes(anime: keyword);
  if (byAnimeOnly.isNotEmpty) return byAnimeOnly;
  if (episodeHint != null && episodeHint > 0) {
    return client.searchEpisodes(anime: keyword, episode: episodeHint);
  }
  return const [];
}

Future<List<DandanplaySearchCandidate>> searchOnlineDanmakuCandidates({
  required List<String> apiUrls,
  required String keyword,
  int? episodeHint,
  String appId = '',
  String appSecret = '',
}) async {
  final q = keyword.trim();
  if (q.isEmpty) return const [];

  final out = <DandanplaySearchCandidate>[];
  final dedupe = <String>{};
  Object? lastError;

  for (final rawUrl in apiUrls) {
    final inputBaseUrl = rawUrl.trim();
    if (inputBaseUrl.isEmpty) continue;

    final baseUrl = resolveEffectiveDanmakuApiBaseUrl(
      inputBaseUrl: inputBaseUrl,
      appId: appId,
      appSecret: appSecret,
    );
    if (baseUrl.isEmpty) continue;

    final useBuiltInProxy = shouldUseBuiltInProxyForOfficialUrl(
      inputBaseUrl: inputBaseUrl,
      appId: appId,
      appSecret: appSecret,
    );
    final effectiveAppId = useBuiltInProxy ? '' : appId;
    final effectiveAppSecret = useBuiltInProxy ? '' : appSecret;
    final host = Uri.tryParse(inputBaseUrl)?.host ?? inputBaseUrl;

    final client = DandanplayApiClient(
      baseUrl: baseUrl,
      appId: effectiveAppId,
      appSecret: effectiveAppSecret,
    );
    try {
      final episodes = await _searchEpisodesSmart(
        client: client,
        keyword: q,
        episodeHint: episodeHint,
      );
      for (final ep in episodes) {
        if (ep.episodeId <= 0) continue;
        final key = '$inputBaseUrl#${ep.episodeId}';
        if (!dedupe.add(key)) continue;
        out.add(
          DandanplaySearchCandidate(
            inputBaseUrl: inputBaseUrl,
            sourceHost: host,
            episodeId: ep.episodeId,
            animeTitle: ep.animeTitle,
            episodeTitle: ep.episodeTitle,
            episodeNumber: ep.episodeNumber,
          ),
        );
      }
    } catch (e) {
      lastError = e;
    } finally {
      client.close();
    }
  }

  if (out.isEmpty && lastError != null) {
    throw Exception(lastError.toString());
  }

  return out;
}

Future<DanmakuSource?> loadOnlineDanmakuByEpisodeId({
  required String apiUrl,
  required int episodeId,
  required String sourceHost,
  required String title,
  DanmakuChConvert chConvert = DanmakuChConvert.off,
  bool mergeRelated = true,
  String appId = '',
  String appSecret = '',
}) async {
  if (episodeId <= 0) return null;

  final baseUrl = resolveEffectiveDanmakuApiBaseUrl(
    inputBaseUrl: apiUrl,
    appId: appId,
    appSecret: appSecret,
  );
  if (baseUrl.isEmpty) return null;

  final useBuiltInProxy = shouldUseBuiltInProxyForOfficialUrl(
    inputBaseUrl: apiUrl,
    appId: appId,
    appSecret: appSecret,
  );
  final effectiveAppId = useBuiltInProxy ? '' : appId;
  final effectiveAppSecret = useBuiltInProxy ? '' : appSecret;
  final client = DandanplayApiClient(
    baseUrl: baseUrl,
    appId: effectiveAppId,
    appSecret: effectiveAppSecret,
  );
  try {
    final comments = await client.getComments(
      episodeId: episodeId,
      withRelated: mergeRelated,
      chConvert: chConvert.apiValue,
    );
    final items = DanmakuParser.parseDandanplayComments(
      comments.comments,
      shiftSeconds: 0,
    );
    if (items.isEmpty) return null;
    final normalizedTitle =
        title.trim().isEmpty ? 'Episode $episodeId' : title.trim();
    return DanmakuSource(
      name: 'online($sourceHost): $normalizedTitle',
      items: items,
    );
  } finally {
    client.close();
  }
}

DandanplaySearchInputHint suggestDandanplaySearchInput(String rawName) {
  final hint = _buildSearchHint(rawName);
  return DandanplaySearchInputHint(
    keyword: hint.keyword,
    episodeHint: hint.episodeHint,
  );
}

Future<List<DanmakuSource>> loadOnlineDanmakuSources({
  required List<String> apiUrls,
  required String fileName,
  String? fileHash,
  required int fileSizeBytes,
  required int videoDurationSeconds,
  DanmakuMatchMode matchMode = DanmakuMatchMode.auto,
  DanmakuChConvert chConvert = DanmakuChConvert.off,
  String appId = '',
  String appSecret = '',
  bool mergeRelated = true,
  bool throwIfEmpty = false,
}) async {
  final cleanedName = stripFileExtension(fileName);
  final hasHash = fileHash != null && fileHash.trim().isNotEmpty;
  final resolvedMode = switch (matchMode) {
    DanmakuMatchMode.auto => hasHash ? 'hashAndFileName' : 'fileNameOnly',
    DanmakuMatchMode.fileNameOnly => 'fileNameOnly',
    DanmakuMatchMode.hashAndFileName =>
      hasHash ? 'hashAndFileName' : 'fileNameOnly',
  };

  final sources = <DanmakuSource>[];
  final errors = <String>[];
  for (final rawUrl in apiUrls) {
    final inputBaseUrl = rawUrl.trim();
    if (inputBaseUrl.isEmpty) continue;
    final baseUrl = resolveEffectiveDanmakuApiBaseUrl(
      inputBaseUrl: inputBaseUrl,
      appId: appId,
      appSecret: appSecret,
    );
    if (baseUrl.isEmpty) continue;

    final useBuiltInProxy = shouldUseBuiltInProxyForOfficialUrl(
      inputBaseUrl: inputBaseUrl,
      appId: appId,
      appSecret: appSecret,
    );
    final effectiveAppId = useBuiltInProxy ? '' : appId;
    final effectiveAppSecret = useBuiltInProxy ? '' : appSecret;

    final client = DandanplayApiClient(
      baseUrl: baseUrl,
      appId: effectiveAppId,
      appSecret: effectiveAppSecret,
    );
    try {
      final match = await client.match(
        fileName: cleanedName,
        fileHash: fileHash,
        fileSize: fileSizeBytes,
        videoDurationSeconds: videoDurationSeconds,
        matchMode: resolvedMode,
      );
      DandanplayMatchResult? pickedFromMatch;
      DandanplaySearchEpisodeResult? pickedFromSearch;
      if (match.success && match.errorCode == 0 && match.matches.isNotEmpty) {
        pickedFromMatch = match.matches.first;
      } else {
        final hint = _buildSearchHint(cleanedName);
        if (hint.keyword.isNotEmpty) {
          final candidates = await _searchEpisodesSmart(
            client: client,
            keyword: hint.keyword,
            episodeHint: hint.episodeHint,
          );
          if (candidates.isNotEmpty) {
            pickedFromSearch =
                _pickSearchCandidate(candidates, hint.episodeHint);
          }
        }
      }
      if (pickedFromMatch == null && pickedFromSearch == null) continue;

      final episodeId =
          pickedFromMatch?.episodeId ?? pickedFromSearch!.episodeId;
      final shiftSeconds = pickedFromMatch?.shiftSeconds ?? 0;
      final comments = await client.getComments(
        episodeId: episodeId,
        withRelated: mergeRelated,
        chConvert: chConvert.apiValue,
      );

      final items = DanmakuParser.parseDandanplayComments(
        comments.comments,
        shiftSeconds: shiftSeconds,
      );
      if (items.isEmpty) continue;

      final host = Uri.tryParse(inputBaseUrl)?.host ?? inputBaseUrl;
      final animeTitle =
          (pickedFromMatch?.animeTitle ?? pickedFromSearch?.animeTitle ?? '')
              .trim();
      final episodeTitle = (pickedFromMatch?.episodeTitle ??
              pickedFromSearch?.episodeTitle ??
              '')
          .trim();
      final title =
          '${animeTitle.isEmpty ? 'Unknown' : animeTitle} $episodeTitle'.trim();
      sources.add(
        DanmakuSource(
          name: 'online($host): $title',
          items: items,
        ),
      );
    } catch (e) {
      if (errors.length < 5) {
        errors.add('[$inputBaseUrl] $e');
      }
    } finally {
      client.close();
    }
  }

  if (sources.isEmpty && throwIfEmpty && errors.isNotEmpty) {
    throw Exception(errors.join('\n'));
  }
  return sources;
}
