import 'dart:convert';
import 'dart:math';
import 'dart:io';

import 'package:http/http.dart' as http;
import 'package:http/io_client.dart';

class DomainInfo {
  final String name;
  final String url;

  DomainInfo({required this.name, required this.url});

  factory DomainInfo.fromJson(Map<String, dynamic> json) {
    return DomainInfo(
      name: json['name'] as String? ?? '',
      url: json['url'] as String? ?? '',
    );
  }
}

class LibraryInfo {
  final String id;
  final String name;
  final String type;
  LibraryInfo({required this.id, required this.name, required this.type});

  factory LibraryInfo.fromJson(Map<String, dynamic> json) => LibraryInfo(
        id: json['Id'] as String? ?? '',
        name: json['Name'] as String? ?? '',
        type: json['CollectionType'] as String? ?? '',
      );
}

class AuthResult {
  final String token;
  final String baseUrlUsed;
  final String userId;
  AuthResult({required this.token, required this.baseUrlUsed, required this.userId});
}

class MediaItem {
  final String id;
  final String name;
  final String type;
  final String overview;
  final String seriesName;
  final String seasonName;
  final int? seasonNumber;
  final int? episodeNumber;
  final bool hasImage;
  final String? parentId;
  final int playbackPositionTicks;
  MediaItem({
    required this.id,
    required this.name,
    required this.type,
    required this.overview,
    required this.seriesName,
    required this.seasonName,
    required this.seasonNumber,
    required this.episodeNumber,
    required this.hasImage,
    required this.playbackPositionTicks,
    this.parentId,
  });

  factory MediaItem.fromJson(Map<String, dynamic> json) => MediaItem(
        id: json['Id'] as String? ?? '',
        name: json['Name'] as String? ?? '',
        type: json['Type'] as String? ?? '',
        overview: json['Overview'] as String? ?? '',
        seriesName: json['SeriesName'] as String? ?? '',
        seasonName: json['SeasonName'] as String? ?? '',
        seasonNumber: json['ParentIndexNumber'] as int?,
        episodeNumber: json['IndexNumber'] as int?,
        hasImage: (json['ImageTags'] as Map?)?.isNotEmpty == true,
        playbackPositionTicks:
            (json['UserData'] as Map?)?['PlaybackPositionTicks'] as int? ?? 0,
        parentId: json['ParentId'] as String?,
      );
}

class PagedResult<T> {
  final List<T> items;
  final int total;
  PagedResult(this.items, this.total);
}

class EmbyApi {
  EmbyApi({
    required String hostOrUrl,
    required String preferredScheme,
    String? port,
  })  : _hostOrUrl = hostOrUrl.trim(),
        _preferredScheme = preferredScheme,
        _port = port?.trim();

  final String _hostOrUrl;
  final String _preferredScheme;
  final String? _port;
  final http.Client _client = IOClient(
    HttpClient()
      ..badCertificateCallback = (_, __, ___) => true,
  );

  // Simple device id generator to satisfy Emby header requirements
  static String _randomId() {
    const chars = 'abcdefghijklmnopqrstuvwxyz0123456789';
    final rand = Random();
    return List.generate(16, (_) => chars[rand.nextInt(chars.length)]).join();
  }

  Map<String, String> _authHeader() {
    final deviceId = _randomId();
    return {
      'Content-Type': 'application/json',
      'X-Emby-Authorization':
          'MediaBrowser Client="LinPlayer", Device="Flutter", DeviceId="$deviceId", Version="1.0.0"'
    };
  }

  List<String> _candidates() {
    // If user pasted full URL with scheme, just try it.
    final parsed = Uri.tryParse(_hostOrUrl);
    if (parsed != null && parsed.hasScheme && parsed.host.isNotEmpty) {
      final port = parsed.hasPort ? ':${parsed.port}' : '';
      final path = parsed.path.isNotEmpty ? parsed.path : '';
      return ['${parsed.scheme}://${parsed.host}$port$path'];
    }

    // handle host/path form without scheme
    String hostPart = _hostOrUrl;
    String pathPart = '';
    if (_hostOrUrl.contains('/')) {
      final split = _hostOrUrl.split('/');
      hostPart = split.first;
      pathPart = '/${split.skip(1).join('/')}';
    }

    final withPort = _port != null && _port!.isNotEmpty
        ? [
            '$_preferredScheme://$hostPart:${_port!}$pathPart',
            '${_preferredScheme == 'http' ? 'https' : 'http'}://$hostPart:${_port!}$pathPart'
          ]
        : [
            '$_preferredScheme://$hostPart$pathPart',
            '${_preferredScheme == 'http' ? 'https' : 'http'}://$hostPart$pathPart'
          ];

    // de-dup
    final seen = <String>{};
    final result = <String>[];
    for (final c in withPort) {
      if (seen.add(c)) result.add(c);
    }
    return result;
  }

  Future<AuthResult> authenticate({
    required String username,
    required String password,
  }) async {
    final errors = <String>[];
    for (final base in _candidates()) {
      final url = Uri.parse('$base/emby/Users/AuthenticateByName');
      final body = jsonEncode({
        'Username': username,
        'Pw': password,
        'Password': password,
      });

      try {
        final resp = await _client.post(url, headers: _authHeader(), body: body);
        if (resp.statusCode != 200) {
          errors.add('${url.origin}: HTTP ${resp.statusCode}');
          continue;
        }
        final map = jsonDecode(resp.body) as Map<String, dynamic>;
        final token = map['AccessToken'] as String?;
        final userId = (map['User'] as Map<String, dynamic>?)?['Id'] as String? ?? '';
        if (token == null || token.isEmpty) {
          errors.add('${url.origin}: 未返回 token');
          continue;
        }
        return AuthResult(token: token, baseUrlUsed: base, userId: userId);
      } catch (e) {
        if (e is SocketException) {
          errors.add('${url.origin}: DNS/网络不可达 (${e.message})');
        } else {
          errors.add('${url.origin}: $e');
        }
      }
    }
    throw Exception('登录失败：${errors.join(" | ")}');
  }

  Future<List<DomainInfo>> fetchDomains(
    String token,
    String baseUrl, {
    bool allowFailure = true,
  }) async {
    final url = Uri.parse('$baseUrl/emby/System/Ext/ServerDomains');
    try {
      final resp = await _client.get(url, headers: {
        'X-Emby-Token': token,
        'Accept': 'application/json',
      });
      if (resp.statusCode != 200) {
        if (allowFailure) return [];
        throw Exception('拉取线路失败（${resp.statusCode}）');
      }
      final map = jsonDecode(resp.body) as Map<String, dynamic>;
      final list = (map['data'] as List<dynamic>? ?? [])
          .map((e) => DomainInfo.fromJson(e as Map<String, dynamic>))
          .toList();
      return list;
    } catch (e) {
      if (allowFailure) return [];
      rethrow;
    }
  }

  Future<List<LibraryInfo>> fetchLibraries({
    required String token,
    required String baseUrl,
    required String userId,
  }) async {
    // Emby 官方推荐获取视图的接口：/Users/{userId}/Views
    final url = Uri.parse('$baseUrl/emby/Users/$userId/Views');
    final resp = await _client.get(url, headers: {
      'X-Emby-Token': token,
      'Accept': 'application/json',
    });
    if (resp.statusCode != 200) {
      throw Exception('拉取媒体库失败（${resp.statusCode}）');
    }
    final map = jsonDecode(resp.body) as Map<String, dynamic>;
    final items = (map['Items'] as List<dynamic>? ?? [])
        .map((e) => LibraryInfo.fromJson(e as Map<String, dynamic>))
        .toList();
    return items;
  }

  Future<PagedResult<MediaItem>> fetchItems({
    required String token,
    required String baseUrl,
    required String userId,
    required String parentId,
    int startIndex = 0,
    int limit = 30,
    String? includeItemTypes,
    String? searchTerm,
  }) async {
    final params = StringBuffer(
        'ParentId=$parentId&Fields=Overview,ParentId,ParentIndexNumber,IndexNumber,SeriesName,SeasonName,ImageTags,PrimaryImageAspectRatio');
    params.write('&StartIndex=$startIndex&Limit=$limit');
    if (includeItemTypes != null) params.write('&IncludeItemTypes=$includeItemTypes');
    if (searchTerm != null && searchTerm.isNotEmpty) {
      params.write('&SearchTerm=${Uri.encodeComponent(searchTerm)}');
    }
    final url = Uri.parse('$baseUrl/emby/Users/$userId/Items?${params.toString()}');
    final resp = await _client.get(url, headers: {
      'X-Emby-Token': token,
      'Accept': 'application/json',
    });
    if (resp.statusCode != 200) {
      throw Exception('拉取媒体列表失败（${resp.statusCode}）');
    }
    final map = jsonDecode(resp.body) as Map<String, dynamic>;
    final items = (map['Items'] as List<dynamic>? ?? [])
        .map((e) => MediaItem.fromJson(e as Map<String, dynamic>))
        .toList();
    final total = map['TotalRecordCount'] as int? ?? items.length;
    return PagedResult(items, total);
  }

  Future<PagedResult<MediaItem>> fetchSeasons({
    required String token,
    required String baseUrl,
    required String userId,
    required String seriesId,
  }) {
    return fetchItems(
      token: token,
      baseUrl: baseUrl,
      userId: userId,
      parentId: seriesId,
      includeItemTypes: 'Season',
      limit: 100,
    );
  }

  Future<PagedResult<MediaItem>> fetchEpisodes({
    required String token,
    required String baseUrl,
    required String userId,
    required String seasonId,
  }) {
    return fetchItems(
      token: token,
      baseUrl: baseUrl,
      userId: userId,
      parentId: seasonId,
      includeItemTypes: 'Episode',
      limit: 200,
    );
  }

  Future<PagedResult<MediaItem>> fetchContinueWatching({
    required String token,
    required String baseUrl,
    required String userId,
    int limit = 30,
  }) async {
    final url = Uri.parse(
        '$baseUrl/emby/Users/$userId/Items?Filters=IsResumable&SortBy=DatePlayed&SortOrder=Descending&Limit=$limit&Fields=Overview,ParentId,ParentIndexNumber,IndexNumber,SeriesName,SeasonName,ImageTags');
    final resp = await _client.get(url, headers: {
      'X-Emby-Token': token,
      'Accept': 'application/json',
    });
    if (resp.statusCode != 200) {
      throw Exception('获取继续观看失败（${resp.statusCode}）');
    }
    final map = jsonDecode(resp.body) as Map<String, dynamic>;
    final items = (map['Items'] as List<dynamic>? ?? [])
        .map((e) => MediaItem.fromJson(e as Map<String, dynamic>))
        // 只保留真正有播放进度的
        .where((e) => e.playbackPositionTicks > 0)
        .toList();
    final total = map['TotalRecordCount'] as int? ?? items.length;
    return PagedResult(items, total);
  }

  Future<PagedResult<MediaItem>> fetchLatestMovies({
    required String token,
    required String baseUrl,
    required String userId,
    int limit = 30,
  }) =>
      fetchItems(
        token: token,
        baseUrl: baseUrl,
        userId: userId,
        parentId: userId, // Emby ignores ParentId when searching latest with types
        includeItemTypes: 'Movie',
        limit: limit,
        startIndex: 0,
        searchTerm: null,
      );

  Future<PagedResult<MediaItem>> fetchLatestEpisodes({
    required String token,
    required String baseUrl,
    required String userId,
    int limit = 30,
  }) =>
      fetchItems(
        token: token,
        baseUrl: baseUrl,
        userId: userId,
        parentId: userId,
        includeItemTypes: 'Episode',
        limit: limit,
        startIndex: 0,
        searchTerm: null,
      );

  Future<PagedResult<MediaItem>> fetchLatestFromLibrary({
    required String token,
    required String baseUrl,
    required String userId,
    required String libraryId,
    int limit = 12,
  }) async {
    final url = Uri.parse(
        '$baseUrl/emby/Users/$userId/Items'
        '?ParentId=$libraryId'
        '&IncludeItemTypes=Episode'
        '&Recursive=true'
        '&SortBy=DateCreated'
        '&SortOrder=Descending'
        '&Fields=Overview,ParentId,ParentIndexNumber,IndexNumber,SeriesName,SeasonName,ImageTags,UserData'
        '&Limit=$limit');
    final resp = await _client.get(url, headers: {
      'X-Emby-Token': token,
      'Accept': 'application/json',
    });
    if (resp.statusCode != 200) {
      throw Exception('获取库最新内容失败（${resp.statusCode}）');
    }
    final map = jsonDecode(resp.body) as Map<String, dynamic>;
    final items = (map['Items'] as List<dynamic>? ?? [])
        .map((e) => MediaItem.fromJson(e as Map<String, dynamic>))
        .toList();
    final total = map['TotalRecordCount'] as int? ?? items.length;
    return PagedResult(items, total);
  }

  static String imageUrl({
    required String baseUrl,
    required String itemId,
    required String token,
    String imageType = 'Primary',
    int? maxWidth,
  }) {
    final mw = maxWidth != null ? '&maxWidth=$maxWidth' : '';
    return '$baseUrl/emby/Items/$itemId/Images/$imageType?quality=90$mw&api_key=$token';
  }
}
