import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:http/http.dart' as http;

import 'package:lin_player_core/state/media_server_type.dart';
import '../network/lin_http_client.dart';

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

  Map<String, dynamic> toJson() => {
        'Id': id,
        'Name': name,
        'CollectionType': type,
      };
}

class AuthResult {
  final String token;
  final String baseUrlUsed;
  final String userId;
  final String apiPrefixUsed;
  AuthResult(
      {required this.token,
      required this.baseUrlUsed,
      required this.userId,
      this.apiPrefixUsed = 'emby'});
}

bool _hasAnyImageData(Map<String, dynamic> json) {
  if ((json['ImageTags'] as Map?)?.isNotEmpty == true) return true;
  if ((json['BackdropImageTags'] as List?)?.isNotEmpty == true) return true;
  if ((json['PrimaryImageTag'] ?? '').toString().trim().isNotEmpty) return true;
  if ((json['ThumbImageTag'] ?? '').toString().trim().isNotEmpty) return true;
  if ((json['ParentThumbImageTag'] ?? '').toString().trim().isNotEmpty) {
    return true;
  }
  if ((json['SeriesPrimaryImageTag'] ?? '').toString().trim().isNotEmpty) {
    return true;
  }
  return false;
}

class MediaItem {
  final String id;
  final String name;
  final String type;
  final String overview;
  final double? communityRating;
  final String? premiereDate;
  final List<String> genres;
  final int? runTimeTicks;
  final int? sizeBytes;
  final String? container;
  final Map<String, String> providerIds;
  final String? seriesId;
  final String seriesName;
  final String seasonName;
  final int? seasonNumber;
  final int? episodeNumber;
  final bool hasImage;
  final String? parentId;
  final int playbackPositionTicks;
  final bool played;
  final List<MediaPerson> people;
  MediaItem({
    required this.id,
    required this.name,
    required this.type,
    required this.overview,
    required this.communityRating,
    required this.premiereDate,
    required this.genres,
    required this.runTimeTicks,
    required this.sizeBytes,
    required this.container,
    required this.providerIds,
    required this.seriesId,
    required this.seriesName,
    required this.seasonName,
    required this.seasonNumber,
    required this.episodeNumber,
    required this.hasImage,
    required this.playbackPositionTicks,
    this.played = false,
    required this.people,
    this.parentId,
  });

  factory MediaItem.fromJson(Map<String, dynamic> json) => MediaItem(
        id: json['Id'] as String? ?? '',
        name: json['Name'] as String? ?? '',
        type: json['Type'] as String? ?? '',
        overview: json['Overview'] as String? ?? '',
        communityRating: (json['CommunityRating'] as num?)?.toDouble(),
        premiereDate: json['PremiereDate'] as String?,
        genres: (json['Genres'] as List?)?.cast<String>() ?? const [],
        runTimeTicks: json['RunTimeTicks'] as int?,
        sizeBytes: json['Size'] as int?,
        container: json['Container'] as String?,
        providerIds: (json['ProviderIds'] as Map?)?.map(
              (key, value) => MapEntry(key.toString(), value.toString()),
            ) ??
            const {},
        seriesId: json['SeriesId'] as String?,
        seriesName: json['SeriesName'] as String? ?? '',
        seasonName: json['SeasonName'] as String? ?? '',
        seasonNumber: json['ParentIndexNumber'] as int?,
        episodeNumber: json['IndexNumber'] as int?,
        hasImage: _hasAnyImageData(json),
        playbackPositionTicks:
            (json['UserData'] as Map?)?['PlaybackPositionTicks'] as int? ?? 0,
        played: (json['UserData'] as Map?)?['Played'] == true,
        people: (json['People'] as List?)
                ?.map((e) => MediaPerson.fromJson(e as Map<String, dynamic>))
                .toList() ??
            const [],
        parentId: json['ParentId'] as String?,
      );

  Map<String, dynamic> toJson() => {
        'Id': id,
        'Name': name,
        'Type': type,
        'Overview': overview,
        'CommunityRating': communityRating,
        'PremiereDate': premiereDate,
        'Genres': genres,
        'RunTimeTicks': runTimeTicks,
        'Size': sizeBytes,
        'Container': container,
        'ProviderIds': providerIds,
        'SeriesId': seriesId,
        'SeriesName': seriesName,
        'SeasonName': seasonName,
        'ParentIndexNumber': seasonNumber,
        'IndexNumber': episodeNumber,
        'ImageTags': hasImage ? const {'Primary': 'cached'} : const {},
        'UserData': {
          'PlaybackPositionTicks': playbackPositionTicks,
          'Played': played,
        },
        'People': people.map((e) => e.toJson()).toList(),
        'ParentId': parentId,
      };
}

class PagedResult<T> {
  final List<T> items;
  final int total;
  PagedResult(this.items, this.total);
}

class ItemCounts {
  final int movieCount;
  final int seriesCount;
  final int episodeCount;

  const ItemCounts({
    required this.movieCount,
    required this.seriesCount,
    required this.episodeCount,
  });

  factory ItemCounts.fromJson(Map<String, dynamic> json) => ItemCounts(
        movieCount: json['MovieCount'] as int? ?? 0,
        seriesCount: json['SeriesCount'] as int? ?? 0,
        episodeCount: json['EpisodeCount'] as int? ?? 0,
      );
}

class MediaPerson {
  final String name;
  final String role;
  final String type;
  final String id;
  final String? primaryImageTag;
  MediaPerson({
    required this.name,
    required this.role,
    required this.type,
    required this.id,
    required this.primaryImageTag,
  });

  factory MediaPerson.fromJson(Map<String, dynamic> json) => MediaPerson(
        name: json['Name'] as String? ?? '',
        role: json['Role'] as String? ?? '',
        type: json['Type'] as String? ?? '',
        id: json['Id'] as String? ?? '',
        primaryImageTag: json['PrimaryImageTag'] as String?,
      );

  Map<String, dynamic> toJson() => {
        'Name': name,
        'Role': role,
        'Type': type,
        'Id': id,
        'PrimaryImageTag': primaryImageTag,
      };
}

class ChapterInfo {
  final String name;
  final int startTicks;
  ChapterInfo({required this.name, required this.startTicks});

  Duration get start => Duration(microseconds: (startTicks / 10).round());

  factory ChapterInfo.fromJson(Map<String, dynamic> json) => ChapterInfo(
        name: json['Name'] as String? ?? '',
        startTicks: json['StartPositionTicks'] as int? ?? 0,
      );
}

class IntroTimestamps {
  final int startTicks;
  final int endTicks;

  const IntroTimestamps({required this.startTicks, required this.endTicks});

  Duration get start => Duration(microseconds: (startTicks / 10).round());
  Duration get end => Duration(microseconds: (endTicks / 10).round());

  bool get isValid => startTicks >= 0 && endTicks > startTicks;

  static int? _readTicks(dynamic value) {
    if (value is int) return value;
    if (value is num) return value.toInt();
    if (value is String) return int.tryParse(value.trim());
    return null;
  }

  static IntroTimestamps? tryParse(Map<String, dynamic> json) {
    final start = _readTicks(
      json['IntroStartPositionTicks'] ??
          json['IntroStartTicks'] ??
          json['IntroStart'] ??
          json['StartPositionTicks'] ??
          json['StartTicks'] ??
          json['Start'],
    );
    final end = _readTicks(
      json['IntroEndPositionTicks'] ??
          json['IntroEndTicks'] ??
          json['IntroEnd'] ??
          json['EndPositionTicks'] ??
          json['EndTicks'] ??
          json['End'],
    );
    if (start == null || end == null) return null;
    final out = IntroTimestamps(startTicks: start, endTicks: end);
    return out.isValid ? out : null;
  }
}

class PlaybackInfoResult {
  final String playSessionId;
  final String mediaSourceId;
  final List<dynamic> mediaSources;
  PlaybackInfoResult({
    required this.playSessionId,
    required this.mediaSourceId,
    required this.mediaSources,
  });
}

class EmbyApi {
  static String appVersion = '1.0.0';
  static String userAgentProduct = 'LinPlayer';
  static String defaultClientName = 'LinPlayer';

  static String get userAgent => LinHttpClientFactory.userAgent;

  static void _syncUserAgent() {
    LinHttpClientFactory.setUserAgent('$userAgentProduct/$appVersion');
  }

  static void setUserAgentProduct(String product) {
    final v = product.trim();
    if (v.isNotEmpty) {
      userAgentProduct = v;
      _syncUserAgent();
    }
  }

  static void setDefaultClientName(String name) {
    final v = name.trim();
    if (v.isNotEmpty) defaultClientName = v;
  }

  static void setAppVersion(String version) {
    final v = version.trim();
    if (v.isNotEmpty) {
      appVersion = v;
      _syncUserAgent();
    }
  }

  static String _authorizationValue({
    required MediaServerType serverType,
    required String deviceId,
    String? client,
    String device = 'Flutter',
    String? version,
    String? userId,
    String? token,
  }) {
    final v = (version == null || version.trim().isEmpty)
        ? appVersion
        : version.trim();

    final scheme =
        serverType == MediaServerType.jellyfin ? 'MediaBrowser' : 'Emby';

    final clientName = (client == null || client.trim().isEmpty)
        ? defaultClientName
        : client.trim();

    final parts = <String>[
      if (userId != null && userId.trim().isNotEmpty)
        'UserId="${userId.trim()}"',
      'Client="$clientName"',
      'Device="$device"',
      'DeviceId="$deviceId"',
      'Version="$v"',
      if (token != null && token.trim().isNotEmpty) 'Token="${token.trim()}"',
    ];
    return '$scheme ${parts.join(', ')}';
  }

  static Map<String, String> buildAuthorizationHeaders({
    required MediaServerType serverType,
    required String deviceId,
    String? client,
    String device = 'Flutter',
    String? version,
    String? userId,
    String? token,
  }) {
    final value = _authorizationValue(
      serverType: serverType,
      deviceId: deviceId,
      client: client,
      device: device,
      version: version,
      userId: userId,
      token: token,
    );

    // Emby doc uses "Authorization: Emby ...". Jellyfin commonly uses
    // "X-Emby-Authorization: MediaBrowser ...". Keep compatibility with both.
    return switch (serverType) {
      MediaServerType.jellyfin => {
          'X-Emby-Authorization': value,
        },
      _ => {
          'Authorization': value,
          'X-Emby-Authorization': value,
        },
    };
  }

  EmbyApi({
    required String hostOrUrl,
    required String preferredScheme,
    String? port,
    String apiPrefix = 'emby',
    this.serverType = MediaServerType.emby,
    String? deviceId,
    String? clientName,
    String? deviceName,
    http.Client? client,
  })  : _hostOrUrl = hostOrUrl.trim(),
        _preferredScheme = preferredScheme,
        _port = port?.trim(),
        apiPrefix = _normalizeApiPrefix(apiPrefix),
        deviceId = (deviceId == null || deviceId.trim().isEmpty)
            ? _randomId()
            : deviceId.trim(),
        clientName = (clientName == null || clientName.trim().isEmpty)
            ? defaultClientName
            : clientName.trim(),
        deviceName = (deviceName == null || deviceName.trim().isEmpty)
            ? 'Flutter'
            : deviceName.trim(),
        _client = client ?? LinHttpClientFactory.createClient();

  final String _hostOrUrl;
  final String _preferredScheme;
  final String? _port;
  final String apiPrefix;
  final MediaServerType serverType;
  final String deviceId;
  final String clientName;
  final String deviceName;
  final http.Client _client;

  static String _normalizeApiPrefix(String raw) {
    var v = raw.trim();
    while (v.startsWith('/')) {
      v = v.substring(1);
    }
    while (v.endsWith('/')) {
      v = v.substring(0, v.length - 1);
    }
    return v;
  }

  static String _apiUrlWithPrefix(
    String baseUrl,
    String apiPrefix,
    String path,
  ) {
    var base = baseUrl.trim();
    while (base.endsWith('/')) {
      base = base.substring(0, base.length - 1);
    }

    final fixedPrefix = _normalizeApiPrefix(apiPrefix);
    final prefixPart = fixedPrefix.isEmpty ? '' : '/$fixedPrefix';

    final fixedPath =
        path.trim().startsWith('/') ? path.trim() : '/${path.trim()}';
    return '$base$prefixPart$fixedPath';
  }

  String _apiUrl(String baseUrl, String path) {
    return _apiUrlWithPrefix(baseUrl, apiPrefix, path);
  }

  // Simple device id generator to satisfy Emby header requirements
  static String _randomId() {
    const chars = 'abcdefghijklmnopqrstuvwxyz0123456789';
    final rand = Random();
    return List.generate(16, (_) => chars[rand.nextInt(chars.length)]).join();
  }

  Map<String, String> _authHeader({
    String? deviceId,
    MediaServerType serverType = MediaServerType.emby,
  }) {
    final id = (deviceId == null || deviceId.trim().isEmpty)
        ? this.deviceId
        : deviceId.trim();
    return {
      'Content-Type': 'application/json',
      'Accept': 'application/json',
      'User-Agent': userAgent,
      ...buildAuthorizationHeaders(
        serverType: serverType,
        deviceId: id,
        client: clientName,
        device: deviceName,
        version: appVersion,
      ),
    };
  }

  Map<String, String> _jsonHeaders({
    required String token,
    String? userId,
    String? deviceId,
    bool includeContentType = false,
  }) {
    final resolvedDeviceId = (deviceId == null || deviceId.trim().isEmpty)
        ? this.deviceId
        : deviceId.trim();
    final headers = <String, String>{
      'X-Emby-Token': token,
      'Accept': 'application/json',
      'User-Agent': userAgent,
      ...buildAuthorizationHeaders(
        serverType: serverType,
        deviceId: resolvedDeviceId,
        client: clientName,
        device: deviceName,
        version: appVersion,
        userId: userId,
      ),
    };
    if (includeContentType) headers['Content-Type'] = 'application/json';
    return headers;
  }

  static Uri _normalizeAuthBase(Uri uri) {
    final segments = uri.pathSegments.toList(growable: true);

    // Users often paste the web UI url: /web or /web/index.html.
    while (segments.isNotEmpty) {
      final last = segments.last.toLowerCase();
      final secondLast = segments.length >= 2
          ? segments[segments.length - 2].toLowerCase()
          : null;

      if (secondLast == 'web' && last == 'index.html') {
        segments.removeLast();
        segments.removeLast();
        continue;
      }
      if (last == 'web') {
        segments.removeLast();
        continue;
      }
      break;
    }

    // Normalize to the "root" before the API prefix. We will try both:
    //   {root}/emby/... (normal deployments)
    //   {root}/emby/emby/... (when server base URL is set to /emby)
    while (segments.isNotEmpty && segments.last.toLowerCase() == 'emby') {
      segments.removeLast();
    }

    final normalizedPath = segments.isEmpty ? '' : '/${segments.join('/')}';
    return uri.replace(path: normalizedPath, query: null, fragment: null);
  }

  static Iterable<String> _expandAuthBaseVariants(String rawBase) sync* {
    final normalized = _normalizeAuthBase(Uri.parse(rawBase));

    // Base without "/emby" suffix.
    yield normalized.toString();

    // Base with one "/emby" suffix. The API paths in this project always add
    // another "/emby", so this makes requests like:
    //   {base}/emby/...  -> /emby/emby/... when baseUrl ends with /emby
    final withEmbySegments = [...normalized.pathSegments, 'emby'];
    final withEmby = normalized.replace(path: '/${withEmbySegments.join('/')}');
    if (withEmby.toString() != normalized.toString()) {
      yield withEmby.toString();
    }
  }

  List<String> _candidates() {
    // If user pasted full URL with scheme, just try it.
    final parsed = Uri.tryParse(_hostOrUrl);
    if (parsed != null && parsed.hasScheme && parsed.host.isNotEmpty) {
      final port = parsed.hasPort
          ? ':${parsed.port}'
          : (_port != null && _port!.trim().isNotEmpty
              ? ':${_port!.trim()}'
              : '');
      final path =
          parsed.path.isNotEmpty && parsed.path != '/' ? parsed.path : '';
      final raw = '${parsed.scheme}://${parsed.host}$port$path';
      return _expandAuthBaseVariants(raw).toList();
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

    // De-dup while interleaving variants across schemes, so we don't spend
    // multiple timeouts on a wrong scheme before trying the fallback.
    final expanded = withPort
        .map((c) => _expandAuthBaseVariants(c).toList(growable: false))
        .toList(growable: false);

    final seen = <String>{};
    final result = <String>[];
    var maxLen = 0;
    for (final list in expanded) {
      if (list.length > maxLen) maxLen = list.length;
    }
    for (var i = 0; i < maxLen; i++) {
      for (final list in expanded) {
        if (i >= list.length) continue;
        final v = list[i];
        if (seen.add(v)) result.add(v);
      }
    }
    return result;
  }

  Future<AuthResult> authenticate({
    required String username,
    required String password,
    String? deviceId,
    MediaServerType serverType = MediaServerType.emby,
  }) async {
    final errors = <String>[];
    for (final base in _candidates()) {
      final prefixes = serverType == MediaServerType.jellyfin
          ? const ['', 'jellyfin', 'emby']
          : const ['emby'];
      for (final prefix in prefixes) {
        final url = Uri.parse(
          _apiUrlWithPrefix(base, prefix, 'Users/AuthenticateByName'),
        );
        final body = jsonEncode({
          'Username': username,
          'Pw': password,
          'Password': password,
        });

        try {
          final resp = await _client
              .post(
                url,
                headers:
                    _authHeader(deviceId: deviceId, serverType: serverType),
                body: body,
              )
              .timeout(const Duration(seconds: 6));
          if (resp.statusCode != 200) {
            errors.add('${url.toString()}: HTTP ${resp.statusCode}');
            continue;
          }
          final map = jsonDecode(resp.body) as Map<String, dynamic>;
          final token = map['AccessToken'] as String?;
          final userId =
              (map['User'] as Map<String, dynamic>?)?['Id'] as String? ?? '';
          if (token == null || token.isEmpty) {
            errors.add('${url.origin}: 未返回 token');
            continue;
          }
          return AuthResult(
            token: token,
            baseUrlUsed: base,
            userId: userId,
            apiPrefixUsed: _normalizeApiPrefix(prefix),
          );
        } catch (e) {
          if (e is SocketException) {
            errors.add('${url.origin}: DNS/网络不可达 (${e.message})');
          } else {
            errors.add('${url.origin}: $e');
          }
        }
      }
    }
    throw Exception('登录失败：${errors.join(" | ")}');
  }

  Future<String?> fetchServerName(
    String baseUrl, {
    String? token,
  }) async {
    final urls = [
      Uri.parse(_apiUrl(baseUrl, 'System/Info/Public')),
      Uri.parse(_apiUrl(baseUrl, 'System/Info')),
    ];

    for (final url in urls) {
      try {
        final headers = <String, String>{
          'Accept': 'application/json',
          'User-Agent': userAgent,
          ...buildAuthorizationHeaders(
            serverType: serverType,
            deviceId: deviceId,
            client: clientName,
            device: deviceName,
            version: appVersion,
          ),
          if (token != null && token.trim().isNotEmpty)
            'X-Emby-Token': token.trim(),
        };
        final resp = await _client.get(url, headers: headers);
        if (resp.statusCode != 200) continue;
        final map = jsonDecode(resp.body);
        if (map is! Map) continue;
        final name =
            (map['ServerName'] ?? map['Name'] ?? map['ApplicationName'])
                ?.toString();
        if (name != null && name.trim().isNotEmpty) {
          return name.trim();
        }
      } catch (_) {
        // best-effort
      }
    }

    return null;
  }

  Future<List<DomainInfo>> fetchDomains(
    String token,
    String baseUrl, {
    bool allowFailure = true,
  }) async {
    final url = Uri.parse(_apiUrl(baseUrl, 'System/Ext/ServerDomains'));
    try {
      final resp = await _client.get(url, headers: {
        ..._jsonHeaders(token: token),
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
    final url = Uri.parse(_apiUrl(baseUrl, 'Users/$userId/Views'));
    final resp = await _client.get(
      url,
      headers: _jsonHeaders(token: token, userId: userId),
    );
    if (resp.statusCode != 200) {
      throw Exception('拉取媒体库失败（${resp.statusCode}）');
    }
    final map = jsonDecode(resp.body) as Map<String, dynamic>;
    final items = (map['Items'] as List<dynamic>? ?? [])
        .map((e) => LibraryInfo.fromJson(e as Map<String, dynamic>))
        .toList();
    return items;
  }

  Future<ItemCounts> fetchItemCounts({
    required String token,
    required String baseUrl,
    required String userId,
  }) async {
    final candidates = <String>[
      'Items/Counts?UserId=$userId',
      'Users/$userId/Items/Counts',
    ];

    http.Response? lastResp;
    for (final path in candidates) {
      try {
        final url = Uri.parse(_apiUrl(baseUrl, path));
        final resp = await _client.get(url,
            headers: _jsonHeaders(token: token, userId: userId));
        lastResp = resp;
        if (resp.statusCode != 200) continue;
        final map = jsonDecode(resp.body) as Map<String, dynamic>;
        return ItemCounts.fromJson(map);
      } catch (_) {
        continue;
      }
    }

    final code = lastResp?.statusCode;
    throw Exception('获取媒体统计失败${code == null ? '' : '（$code）'}');
  }

  Future<PagedResult<MediaItem>> fetchItems({
    required String token,
    required String baseUrl,
    required String userId,
    String? parentId,
    int startIndex = 0,
    int limit = 30,
    String? includeItemTypes,
    String? searchTerm,
    bool recursive = false,
    bool excludeFolders = true,
    String? sortBy,
    String sortOrder = 'Descending',
    String? fields,
  }) async {
    final resolvedFields = (fields == null || fields.trim().isEmpty)
        ? 'Overview,ParentId,ParentIndexNumber,IndexNumber,SeriesName,SeasonName,ImageTags,PrimaryImageTag,ThumbImageTag,ParentThumbImageTag,SeriesPrimaryImageTag,BackdropImageTags,PrimaryImageAspectRatio,RunTimeTicks,Size,Container,Genres,CommunityRating,PremiereDate'
        : fields.trim();
    final params = <String>[
      if (parentId != null && parentId.isNotEmpty) 'ParentId=$parentId',
      'Fields=$resolvedFields',
      'StartIndex=$startIndex',
      'Limit=$limit',
      'Recursive=$recursive',
    ];
    if (excludeFolders) {
      params.add('Filters=IsNotFolder');
    }
    if (includeItemTypes != null) {
      params.add('IncludeItemTypes=$includeItemTypes');
    }
    if (sortBy != null && sortBy.isNotEmpty) {
      params.addAll(['SortBy=$sortBy', 'SortOrder=$sortOrder']);
    }
    if (searchTerm != null && searchTerm.isNotEmpty) {
      params.add('SearchTerm=${Uri.encodeComponent(searchTerm)}');
    }
    final url =
        Uri.parse(_apiUrl(baseUrl, 'Users/$userId/Items?${params.join('&')}'));
    final resp = await _client.get(url,
        headers: _jsonHeaders(token: token, userId: userId));
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

  Future<PagedResult<MediaItem>> fetchRandomRecommendations({
    required String token,
    required String baseUrl,
    required String userId,
    int limit = 6,
    String includeItemTypes = 'Movie,Series',
  }) {
    return fetchItems(
      token: token,
      baseUrl: baseUrl,
      userId: userId,
      includeItemTypes: includeItemTypes,
      limit: limit,
      recursive: true,
      sortBy: 'Random',
      sortOrder: 'Ascending',
    );
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
      excludeFolders: false,
      limit: 100,
      sortBy: 'SortName',
      sortOrder: 'Ascending',
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
      sortBy: 'IndexNumber',
      sortOrder: 'Ascending',
    );
  }

  Future<PagedResult<MediaItem>> fetchContinueWatching({
    required String token,
    required String baseUrl,
    required String userId,
    int limit = 30,
  }) async {
    final url = Uri.parse(
      _apiUrl(
        baseUrl,
        'Users/$userId/Items'
        '?Filters=IsResumable'
        '&IncludeItemTypes=Episode,Movie'
        '&Recursive=true'
        '&SortBy=DatePlayed'
        '&SortOrder=Descending'
        '&Limit=$limit'
        '&Fields=Overview,ParentId,SeriesId,ParentIndexNumber,IndexNumber,SeriesName,SeasonName,ImageTags,PrimaryImageTag,ThumbImageTag,ParentThumbImageTag,SeriesPrimaryImageTag,BackdropImageTags,UserData',
      ),
    );
    final resp = await _client.get(url,
        headers: _jsonHeaders(token: token, userId: userId));
    if (resp.statusCode != 200) {
      throw Exception('获取继续观看失败（${resp.statusCode}）');
    }
    final map = jsonDecode(resp.body) as Map<String, dynamic>;
    final parsed = (map['Items'] as List<dynamic>? ?? [])
        .map((e) => MediaItem.fromJson(e as Map<String, dynamic>))
        .toList();

    // Prefer items with real progress. Some servers may omit UserData (or return 0)
    // even when `IsResumable` is requested; in that case, keep the raw list.
    final withProgress =
        parsed.where((e) => e.playbackPositionTicks > 0).toList();
    final items = withProgress.isNotEmpty ? withProgress : parsed;
    final total = map['TotalRecordCount'] as int? ?? items.length;
    return PagedResult(items, total);
  }

  Future<PagedResult<MediaItem>> fetchNextUp({
    required String token,
    required String baseUrl,
    required String userId,
    int limit = 30,
  }) async {
    final url = Uri.parse(
      _apiUrl(
        baseUrl,
        'Shows/NextUp'
        '?UserId=$userId'
        '&Limit=$limit'
        '&EnableUserData=true'
        '&EnableImages=true'
        '&ImageTypeLimit=1'
        '&EnableImageTypes=Primary,Thumb,Backdrop'
        '&Fields=Overview,ParentId,ProviderIds',
      ),
    );
    final resp = await _client.get(url,
        headers: _jsonHeaders(token: token, userId: userId));
    if (resp.statusCode != 200) {
      throw Exception('FetchNextUp failed (${resp.statusCode})');
    }
    final map = jsonDecode(resp.body) as Map<String, dynamic>;
    final items = (map['Items'] as List<dynamic>? ?? [])
        .map((e) => MediaItem.fromJson(e as Map<String, dynamic>))
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
        parentId:
            userId, // Emby ignores ParentId when searching latest with types
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
    bool onlyEpisodes = true,
  }) async {
    final url = Uri.parse(
      _apiUrl(
        baseUrl,
        'Users/$userId/Items'
        '?ParentId=$libraryId'
        '&IncludeItemTypes=${onlyEpisodes ? 'Episode' : 'Episode,Movie'}'
        '&Recursive=true'
        '&SortBy=DateCreated'
        '&SortOrder=Descending'
        '&Fields=Overview,ParentId,ParentIndexNumber,IndexNumber,SeriesName,SeasonName,ImageTags,PrimaryImageTag,ThumbImageTag,ParentThumbImageTag,SeriesPrimaryImageTag,BackdropImageTags,UserData'
        '&Limit=$limit',
      ),
    );
    final resp = await _client.get(url, headers: {
      ..._jsonHeaders(token: token, userId: userId),
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

  Future<PlaybackInfoResult> fetchPlaybackInfo({
    required String token,
    required String baseUrl,
    required String userId,
    required String deviceId,
    required String itemId,
    bool exoPlayer = false,
  }) async {
    final profileName = exoPlayer ? '$clientName-Exo' : clientName;
    final deviceProfile = exoPlayer
        ? {
            "Name": profileName,
            "MaxStreamingBitrate": 120000000,
            "DirectPlayProfiles": [
              {
                "Container": "mp4,mkv,mov,avi,ts,flv,webm",
                "Type": "Video",
                "AudioCodec": "aac,mp3",
              },
              {
                "Container": "mp3,aac,m4a",
                "Type": "Audio",
                "AudioCodec": "aac,mp3",
              },
            ],
            "TranscodingProfiles": [
              {
                "Container": "ts",
                "Type": "Video",
                "Protocol": "hls",
                "VideoCodec": "h264",
                "AudioCodec": "aac",
                "Context": "Streaming",
              },
            ],
            "DeviceId": deviceId,
          }
        : {
            "Name": profileName,
            "MaxStreamingBitrate": 120000000,
            "DirectPlayProfiles": [
              {"Container": "mp4,mkv,mov,avi,ts,flv,webm", "Type": "Video"},
              {"Container": "mp3,aac,flac,wav,ogg", "Type": "Audio"}
            ],
            "TranscodingProfiles": [],
            "DeviceId": deviceId,
          };

    Future<http.Response> postReq() => _client.post(
          Uri.parse(_apiUrl(baseUrl, 'Items/$itemId/PlaybackInfo')),
          headers: _jsonHeaders(
            token: token,
            userId: userId,
            deviceId: deviceId,
            includeContentType: true,
          ),
          body: jsonEncode({
            'UserId': userId,
            'DeviceProfile': deviceProfile,
          }),
        );
    Future<http.Response> getReq() => _client.get(
          Uri.parse(
            _apiUrl(
              baseUrl,
              'Items/$itemId/PlaybackInfo?UserId=$userId&DeviceId=$deviceId',
            ),
          ),
          headers:
              _jsonHeaders(token: token, userId: userId, deviceId: deviceId),
        );

    // For ExoPlayer we must POST with DeviceProfile, otherwise the server may
    // return a direct-play URL for an audio codec Exo can't decode (video-only).
    http.Response resp = exoPlayer ? await postReq() : await getReq();
    if (exoPlayer && resp.statusCode != 200) {
      // Some servers/proxies only allow GET on this endpoint.
      resp = await getReq();
      if (resp.statusCode >= 500 || resp.statusCode == 404) {
        resp = await postReq();
      }
    } else if (!exoPlayer &&
        (resp.statusCode >= 500 || resp.statusCode == 404)) {
      resp = await postReq();
    }
    if (resp.statusCode != 200) {
      throw Exception('获取播放信息失败(${resp.statusCode})');
    }
    final map = jsonDecode(resp.body) as Map<String, dynamic>;
    var session = map['PlaySessionId'] as String? ?? '';
    var sources = (map['MediaSources'] as List?) ?? [];

    if (session.isEmpty || sources.isEmpty) {
      // Fallback: some servers return 200 but require POST body to include DeviceProfile.
      final resp2 = await postReq();
      if (resp2.statusCode == 200) {
        final map2 = jsonDecode(resp2.body) as Map<String, dynamic>;
        session = map2['PlaySessionId'] as String? ?? '';
        sources = (map2['MediaSources'] as List?) ?? [];
      }
    }
    if (session.isEmpty || sources.isEmpty) {
      throw Exception('播放信息缺失');
    }
    final ms = sources.first as Map<String, dynamic>;
    final mediaSourceId = ms['Id'] as String? ?? itemId;
    return PlaybackInfoResult(
      playSessionId: session,
      mediaSourceId: mediaSourceId,
      mediaSources: sources,
    );
  }

  Future<void> reportPlaybackStart({
    required String token,
    required String baseUrl,
    required String deviceId,
    required String itemId,
    required String mediaSourceId,
    required String playSessionId,
    required int positionTicks,
    bool isPaused = false,
    String? userId,
  }) async {
    await _postPlaybackEvent(
      token: token,
      baseUrl: baseUrl,
      deviceId: deviceId,
      userId: userId,
      path: 'Sessions/Playing',
      body: <String, dynamic>{
        if (userId != null && userId.isNotEmpty) 'UserId': userId,
        'ItemId': itemId,
        'MediaSourceId': mediaSourceId,
        'PlaySessionId': playSessionId,
        'PositionTicks': positionTicks,
        'IsPaused': isPaused,
        'CanSeek': true,
      },
    );
  }

  Future<void> reportPlaybackProgress({
    required String token,
    required String baseUrl,
    required String deviceId,
    required String itemId,
    required String mediaSourceId,
    required String playSessionId,
    required int positionTicks,
    bool isPaused = false,
    String? userId,
  }) async {
    await _postPlaybackEvent(
      token: token,
      baseUrl: baseUrl,
      deviceId: deviceId,
      userId: userId,
      path: 'Sessions/Playing/Progress',
      body: <String, dynamic>{
        if (userId != null && userId.isNotEmpty) 'UserId': userId,
        'ItemId': itemId,
        'MediaSourceId': mediaSourceId,
        'PlaySessionId': playSessionId,
        'PositionTicks': positionTicks,
        'IsPaused': isPaused,
        'CanSeek': true,
        'EventName': 'TimeUpdate',
      },
    );
  }

  Future<void> reportPlaybackStopped({
    required String token,
    required String baseUrl,
    required String deviceId,
    required String itemId,
    required String mediaSourceId,
    required String playSessionId,
    required int positionTicks,
    String? userId,
  }) async {
    await _postPlaybackEvent(
      token: token,
      baseUrl: baseUrl,
      deviceId: deviceId,
      userId: userId,
      path: 'Sessions/Playing/Stopped',
      body: <String, dynamic>{
        if (userId != null && userId.isNotEmpty) 'UserId': userId,
        'ItemId': itemId,
        'MediaSourceId': mediaSourceId,
        'PlaySessionId': playSessionId,
        'PositionTicks': positionTicks,
      },
    );
  }

  Future<void> updatePlaybackPosition({
    required String token,
    required String baseUrl,
    required String userId,
    required String itemId,
    required int positionTicks,
    bool? played,
  }) async {
    final url =
        Uri.parse(_apiUrl(baseUrl, 'Users/$userId/Items/$itemId/UserData'));
    final body = <String, dynamic>{
      'PlaybackPositionTicks': positionTicks,
      if (played != null) 'Played': played,
    };
    final resp = await _client.post(
      url,
      headers: _jsonHeaders(
        token: token,
        userId: userId,
        includeContentType: true,
      ),
      body: jsonEncode(body),
    );
    if (resp.statusCode != 200 && resp.statusCode != 204) {
      throw Exception('UpdateUserData failed (${resp.statusCode})');
    }
  }

  Future<void> _postPlaybackEvent({
    required String token,
    required String baseUrl,
    required String deviceId,
    String? userId,
    required String path,
    required Map<String, dynamic> body,
  }) async {
    final resp = await _client.post(
      Uri.parse(_apiUrl(baseUrl, path)),
      headers: _jsonHeaders(
        token: token,
        userId: userId,
        deviceId: deviceId,
        includeContentType: true,
      ),
      body: jsonEncode(body),
    );
    if (resp.statusCode != 200 && resp.statusCode != 204) {
      throw Exception('PlaybackEvent failed ($path, ${resp.statusCode})');
    }
  }

  Future<MediaItem> fetchItemDetail({
    required String token,
    required String baseUrl,
    required String userId,
    required String itemId,
  }) async {
    final url = Uri.parse(
      _apiUrl(
        baseUrl,
        'Users/$userId/Items/$itemId'
        '?Fields=Overview,ParentId,ParentIndexNumber,IndexNumber,SeriesName,SeasonName,ImageTags,PrimaryImageTag,ThumbImageTag,ParentThumbImageTag,SeriesPrimaryImageTag,BackdropImageTags,UserData,ProviderIds,CommunityRating,PremiereDate,ProductionYear,Genres,People,RunTimeTicks,Size,Container',
      ),
    );
    final resp = await _client.get(url,
        headers: _jsonHeaders(token: token, userId: userId));
    if (resp.statusCode != 200) {
      throw Exception('获取详情失败(${resp.statusCode})');
    }
    final map = jsonDecode(resp.body) as Map<String, dynamic>;
    return MediaItem.fromJson(map);
  }

  static String imageUrl({
    required String baseUrl,
    required String itemId,
    required String token,
    String apiPrefix = 'emby',
    String imageType = 'Primary',
    int? maxWidth,
  }) {
    final mw = maxWidth != null ? '&maxWidth=$maxWidth' : '';
    return _apiUrlWithPrefix(
      baseUrl,
      apiPrefix,
      'Items/$itemId/Images/$imageType?quality=90$mw&api_key=$token',
    );
  }

  static String personImageUrl({
    required String baseUrl,
    required String personId,
    required String token,
    String apiPrefix = 'emby',
    int? maxWidth,
  }) {
    final mw = maxWidth != null ? '&maxWidth=$maxWidth' : '';
    return _apiUrlWithPrefix(
      baseUrl,
      apiPrefix,
      'Items/$personId/Images/Primary?quality=90$mw&api_key=$token',
    );
  }

  Future<List<ChapterInfo>> fetchChapters({
    required String token,
    required String baseUrl,
    required String itemId,
    String? userId,
  }) async {
    final url = Uri.parse(_apiUrl(baseUrl, 'Items/$itemId/Chapters'));
    final resp = await _client.get(url,
        headers: _jsonHeaders(token: token, userId: userId));
    // 404 means the item has no chapters on many servers.
    if (resp.statusCode == 404) {
      return const [];
    }
    if (resp.statusCode != 200) {
      throw Exception('获取章节失败(${resp.statusCode})');
    }
    final list = (jsonDecode(resp.body)['Items'] as List?) ?? [];
    return list
        .map((e) => ChapterInfo.fromJson(e as Map<String, dynamic>))
        .toList();
  }

  Future<IntroTimestamps?> fetchIntroTimestamps({
    required String token,
    required String baseUrl,
    required String itemId,
    String? userId,
  }) async {
    final headers = _jsonHeaders(token: token, userId: userId);
    final uid = (userId ?? '').trim();

    Uri withUser(Uri uri) {
      if (uid.isEmpty) return uri;
      final params = <String, String>{...uri.queryParameters, 'UserId': uid};
      return uri.replace(queryParameters: params);
    }

    final candidates = [
      'Episodes/$itemId/IntroTimestamps',
      'Items/$itemId/IntroTimestamps',
      'Videos/$itemId/IntroTimestamps',
    ];

    for (final path in candidates) {
      final uri = withUser(Uri.parse(_apiUrl(baseUrl, path)));
      final resp = await _client.get(uri, headers: headers);
      if (resp.statusCode == 404) continue;
      if (resp.statusCode == 204) return null;
      if (resp.statusCode != 200) {
        throw Exception('获取片头信息失败(${resp.statusCode})');
      }
      final decoded = jsonDecode(resp.body);
      final map = decoded is Map<String, dynamic> ? decoded : null;
      if (map == null) return null;
      return IntroTimestamps.tryParse(map);
    }

    return null;
  }

  Future<PagedResult<MediaItem>> fetchSimilar({
    required String token,
    required String baseUrl,
    required String userId,
    required String itemId,
    int limit = 10,
  }) async {
    final url = Uri.parse(
      _apiUrl(
        baseUrl,
        'Users/$userId/Items/$itemId/Similar?Limit=$limit&Fields=Overview,ImageTags,PrimaryImageTag,ThumbImageTag,SeriesPrimaryImageTag,BackdropImageTags,ProviderIds,CommunityRating,Genres,ProductionYear',
      ),
    );
    final resp = await _client.get(url,
        headers: _jsonHeaders(token: token, userId: userId));
    if (resp.statusCode == 404) {
      return PagedResult(const [], 0);
    }
    if (resp.statusCode != 200) {
      throw Exception('获取相似条目失败(${resp.statusCode})');
    }
    final map = jsonDecode(resp.body) as Map<String, dynamic>;
    final items = (map['Items'] as List<dynamic>? ?? [])
        .map((e) => MediaItem.fromJson(e as Map<String, dynamic>))
        .toList();
    final total = map['TotalRecordCount'] as int? ?? items.length;
    return PagedResult(items, total);
  }
}
