import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:http/http.dart' as http;

import '../src/player/danmaku.dart';
import '../state/danmaku_preferences.dart';

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

class DandanplayApiClient {
  DandanplayApiClient({
    required this.baseUrl,
    this.appId = '',
    this.appSecret = '',
    http.Client? client,
  }) : _client = client ?? http.Client();

  final String baseUrl;
  final String appId;
  final String appSecret;
  final http.Client _client;
  static const Duration _timeout = Duration(seconds: 12);

  bool get _hasAuth => appId.trim().isNotEmpty && appSecret.trim().isNotEmpty;

  Uri _buildUri(String apiPath, {Map<String, String>? query}) {
    final base = Uri.parse(baseUrl);
    final basePath = base.path.replaceAll(RegExp(r'/+$'), '');
    final path = '$basePath$apiPath';
    return base.replace(
      path: path,
      queryParameters: query?.isEmpty == true ? null : query,
      fragment: '',
    );
  }

  Map<String, String> _signatureHeaders(Uri uri) {
    if (!_hasAuth) return const {};
    final ts =
        (DateTime.now().toUtc().millisecondsSinceEpoch ~/ 1000).toString();
    final path = uri.path;
    final raw = '$appId$ts$path$appSecret';
    final digest = sha256.convert(utf8.encode(raw));
    final sig = base64.encode(digest.bytes);
    return {
      'X-AppId': appId,
      'X-Timestamp': ts,
      'X-Signature': sig,
    };
  }

  Map<String, String> _credentialHeaders() {
    if (!_hasAuth) return const {};
    return {
      'X-AppId': appId,
      'X-AppSecret': appSecret,
    };
  }

  bool _shouldRetryWithCredentials(http.Response resp) {
    if (resp.statusCode != 403) return false;
    final msg = (resp.headers['x-error-message'] ?? '').toLowerCase();
    return msg.contains('authentication') || msg.contains('signature');
  }

  Future<http.Response> _postJson(Uri uri, Object body) async {
    final headers = <String, String>{
      'Accept': 'application/json',
      'Content-Type': 'application/json',
      ..._signatureHeaders(uri),
    };
    var resp = await _client
        .post(uri, headers: headers, body: jsonEncode(body))
        .timeout(_timeout);
    if (_shouldRetryWithCredentials(resp)) {
      final retryHeaders = <String, String>{
        'Accept': 'application/json',
        'Content-Type': 'application/json',
        ..._credentialHeaders(),
      };
      resp = await _client
          .post(uri, headers: retryHeaders, body: jsonEncode(body))
          .timeout(_timeout);
    }
    return resp;
  }

  Future<http.Response> _get(Uri uri) async {
    final headers = <String, String>{
      'Accept': 'application/json',
      ..._signatureHeaders(uri),
    };
    var resp = await _client.get(uri, headers: headers).timeout(_timeout);
    if (_shouldRetryWithCredentials(resp)) {
      final retryHeaders = <String, String>{
        'Accept': 'application/json',
        ..._credentialHeaders(),
      };
      resp = await _client.get(uri, headers: retryHeaders).timeout(_timeout);
    }
    return resp;
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
      final err = resp.headers['x-error-message'];
      throw Exception(
          '匹配失败(${resp.statusCode})${err == null || err.isEmpty ? '' : '：$err'}');
    }
    final map = jsonDecode(resp.body) as Map<String, dynamic>;
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
    final resp = await _get(uri);
    if (resp.statusCode != 200 && resp.statusCode != 302) {
      final err = resp.headers['x-error-message'];
      throw Exception(
          '获取弹幕失败(${resp.statusCode})${err == null || err.isEmpty ? '' : '：$err'}');
    }
    final map = jsonDecode(resp.body) as Map<String, dynamic>;
    return DandanplayCommentResponse.fromJson(map);
  }

  void close() => _client.close();
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
    final baseUrl = rawUrl.trim();
    if (baseUrl.isEmpty) continue;
    final client = DandanplayApiClient(
      baseUrl: baseUrl,
      appId: appId,
      appSecret: appSecret,
    );
    try {
      final match = await client.match(
        fileName: cleanedName,
        fileHash: fileHash,
        fileSize: fileSizeBytes,
        videoDurationSeconds: videoDurationSeconds,
        matchMode: resolvedMode,
      );
      if (!match.success || match.errorCode != 0) continue;
      if (match.matches.isEmpty) continue;

      final picked = match.matches.first;
      final comments = await client.getComments(
        episodeId: picked.episodeId,
        withRelated: mergeRelated,
        chConvert: chConvert.apiValue,
      );

      final items = DanmakuParser.parseDandanplayComments(
        comments.comments,
        shiftSeconds: picked.shiftSeconds,
      );
      if (items.isEmpty) continue;

      final host = Uri.tryParse(baseUrl)?.host ?? baseUrl;
      final title =
          '${picked.animeTitle.isEmpty ? '未知作品' : picked.animeTitle} ${picked.episodeTitle}'
              .trim();
      sources.add(
        DanmakuSource(
          name: '在线($host)：$title',
          items: items,
        ),
      );
    } catch (e) {
      if (errors.length < 5) {
        errors.add('[$baseUrl] $e');
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
