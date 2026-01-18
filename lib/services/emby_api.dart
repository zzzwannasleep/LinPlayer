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
  AuthResult(
      {required this.token, required this.baseUrlUsed, required this.userId});
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
  final String seriesName;
  final String seasonName;
  final int? seasonNumber;
  final int? episodeNumber;
  final bool hasImage;
  final String? parentId;
  final int playbackPositionTicks;
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
    required this.seriesName,
    required this.seasonName,
    required this.seasonNumber,
    required this.episodeNumber,
    required this.hasImage,
    required this.playbackPositionTicks,
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
        seriesName: json['SeriesName'] as String? ?? '',
        seasonName: json['SeasonName'] as String? ?? '',
        seasonNumber: json['ParentIndexNumber'] as int?,
        episodeNumber: json['IndexNumber'] as int?,
        hasImage: (json['ImageTags'] as Map?)?.isNotEmpty == true,
        playbackPositionTicks:
            (json['UserData'] as Map?)?['PlaybackPositionTicks'] as int? ?? 0,
        people: (json['People'] as List?)
                ?.map((e) => MediaPerson.fromJson(e as Map<String, dynamic>))
                .toList() ??
            const [],
        parentId: json['ParentId'] as String?,
      );
}

class PagedResult<T> {
  final List<T> items;
  final int total;
  PagedResult(this.items, this.total);
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

  static String get userAgent => 'LinPlayer/$appVersion';

  static void setAppVersion(String version) {
    final v = version.trim();
    if (v.isNotEmpty) appVersion = v;
  }

  EmbyApi({
    required String hostOrUrl,
    required String preferredScheme,
    String? port,
    http.Client? client,
  })  : _hostOrUrl = hostOrUrl.trim(),
        _preferredScheme = preferredScheme,
        _port = port?.trim(),
        _client = client ??
            IOClient(
              HttpClient()
                ..userAgent = userAgent
                ..badCertificateCallback = (_, __, ___) => true,
            );

  final String _hostOrUrl;
  final String _preferredScheme;
  final String? _port;
  final http.Client _client;

  // Simple device id generator to satisfy Emby header requirements
  static String _randomId() {
    const chars = 'abcdefghijklmnopqrstuvwxyz0123456789';
    final rand = Random();
    return List.generate(16, (_) => chars[rand.nextInt(chars.length)]).join();
  }

  static String _authorizationValue({
    required String deviceId,
    String client = 'LinPlayer',
    String device = 'Flutter',
    String? version,
  }) {
    final v = (version == null || version.trim().isEmpty)
        ? appVersion
        : version.trim();
    return 'MediaBrowser Client="$client", Device="$device", DeviceId="$deviceId", Version="$v"';
  }

  Map<String, String> _authHeader({String? deviceId}) {
    final id = (deviceId == null || deviceId.isEmpty) ? _randomId() : deviceId;
    return {
      'Content-Type': 'application/json',
      'Accept': 'application/json',
      'User-Agent': userAgent,
      'X-Emby-Authorization': _authorizationValue(deviceId: id),
    };
  }

  Map<String, String> _jsonHeaders({
    required String token,
    String? deviceId,
    bool includeContentType = false,
  }) {
    final headers = <String, String>{
      'X-Emby-Token': token,
      'Accept': 'application/json',
      'User-Agent': userAgent,
    };
    if (includeContentType) headers['Content-Type'] = 'application/json';
    if (deviceId != null && deviceId.isNotEmpty) {
      headers['X-Emby-Authorization'] = _authorizationValue(deviceId: deviceId);
    }
    return headers;
  }

  static Uri _normalizeAuthBase(Uri uri) {
    final segments = uri.pathSegments.toList(growable: true);

    // Users often paste the web UI url: /web or /web/index.html.
    while (segments.isNotEmpty) {
      final last = segments.last.toLowerCase();
      final secondLast =
          segments.length >= 2 ? segments[segments.length - 2].toLowerCase() : null;

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

    // de-dup
    final seen = <String>{};
    final result = <String>[];
    for (final c in withPort) {
      for (final v in _expandAuthBaseVariants(c)) {
        if (seen.add(v)) result.add(v);
      }
    }
    return result;
  }

  Future<AuthResult> authenticate({
    required String username,
    required String password,
    String? deviceId,
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
        final resp = await _client.post(
          url,
          headers: _authHeader(deviceId: deviceId),
          body: body,
        );
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

  Future<String?> fetchServerName(
    String baseUrl, {
    String? token,
  }) async {
    final urls = [
      Uri.parse('$baseUrl/emby/System/Info/Public'),
      Uri.parse('$baseUrl/emby/System/Info'),
    ];

    for (final url in urls) {
      try {
        final headers = <String, String>{
          'Accept': 'application/json',
          'User-Agent': userAgent,
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
    final url = Uri.parse('$baseUrl/emby/System/Ext/ServerDomains');
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
    final url = Uri.parse('$baseUrl/emby/Users/$userId/Views');
    final resp = await _client.get(url, headers: _jsonHeaders(token: token));
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
    String? parentId,
    int startIndex = 0,
    int limit = 30,
    String? includeItemTypes,
    String? searchTerm,
    bool recursive = false,
    bool excludeFolders = true,
    String? sortBy,
    String sortOrder = 'Descending',
  }) async {
    final params = <String>[
      if (parentId != null && parentId.isNotEmpty) 'ParentId=$parentId',
      'Fields=Overview,ParentId,ParentIndexNumber,IndexNumber,SeriesName,SeasonName,ImageTags,PrimaryImageAspectRatio,RunTimeTicks,Size,Container,Genres,CommunityRating,PremiereDate',
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
        Uri.parse('$baseUrl/emby/Users/$userId/Items?${params.join('&')}');
    final resp = await _client.get(url, headers: _jsonHeaders(token: token));
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
        '$baseUrl/emby/Users/$userId/Items'
        '?Filters=IsResumable'
        '&IncludeItemTypes=Episode,Movie'
        '&Recursive=true'
        '&SortBy=DatePlayed'
        '&SortOrder=Descending'
        '&Limit=$limit'
        '&Fields=Overview,ParentId,ParentIndexNumber,IndexNumber,SeriesName,SeasonName,ImageTags,UserData');
    final resp = await _client.get(url, headers: _jsonHeaders(token: token));
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
    final url = Uri.parse('$baseUrl/emby/Users/$userId/Items'
        '?ParentId=$libraryId'
        '&IncludeItemTypes=${onlyEpisodes ? 'Episode' : 'Episode,Movie'}'
        '&Recursive=true'
        '&SortBy=DateCreated'
        '&SortOrder=Descending'
        '&Fields=Overview,ParentId,ParentIndexNumber,IndexNumber,SeriesName,SeasonName,ImageTags,UserData'
        '&Limit=$limit');
    final resp = await _client.get(url, headers: {
      ..._jsonHeaders(token: token),
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
  }) async {
    final deviceProfile = {
      "Name": "LinPlayer",
      "MaxStreamingBitrate": 120000000,
      "DirectPlayProfiles": [
        {"Container": "mp4,mkv,mov,avi,ts,flv,webm", "Type": "Video"},
        {"Container": "mp3,aac,flac,wav,ogg", "Type": "Audio"}
      ],
      "TranscodingProfiles": [],
      "DeviceId": deviceId,
    };

    Future<http.Response> postReq() => _client.post(
          Uri.parse('$baseUrl/emby/Items/$itemId/PlaybackInfo'),
          headers: _jsonHeaders(
            token: token,
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
              '$baseUrl/emby/Items/$itemId/PlaybackInfo?UserId=$userId&DeviceId=$deviceId'),
          headers: _jsonHeaders(token: token, deviceId: deviceId),
        );

    http.Response resp = await getReq();
    if (resp.statusCode >= 500 || resp.statusCode == 404) {
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
      path: 'Sessions/Playing/Progress',
      body: <String, dynamic>{
        if (userId != null && userId.isNotEmpty) 'UserId': userId,
        'ItemId': itemId,
        'MediaSourceId': mediaSourceId,
        'PlaySessionId': playSessionId,
        'PositionTicks': positionTicks,
        'IsPaused': isPaused,
        'CanSeek': true,
        'EventName': 'timeupdate',
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
    final url = Uri.parse('$baseUrl/emby/Users/$userId/Items/$itemId/UserData');
    final body = <String, dynamic>{
      'PlaybackPositionTicks': positionTicks,
      if (played != null) 'Played': played,
    };
    final resp = await _client.post(
      url,
      headers: _jsonHeaders(token: token, includeContentType: true),
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
    required String path,
    required Map<String, dynamic> body,
  }) async {
    final resp = await _client.post(
      Uri.parse('$baseUrl/emby/$path'),
      headers: _jsonHeaders(
        token: token,
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
        '$baseUrl/emby/Users/$userId/Items/$itemId?Fields=Overview,ParentId,ParentIndexNumber,IndexNumber,SeriesName,SeasonName,ImageTags,UserData,ProviderIds,CommunityRating,PremiereDate,ProductionYear,Genres,People,RunTimeTicks,Size,Container');
    final resp = await _client.get(url, headers: _jsonHeaders(token: token));
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
    String imageType = 'Primary',
    int? maxWidth,
  }) {
    final mw = maxWidth != null ? '&maxWidth=$maxWidth' : '';
    return '$baseUrl/emby/Items/$itemId/Images/$imageType?quality=90$mw&api_key=$token';
  }

  static String personImageUrl({
    required String baseUrl,
    required String personId,
    required String token,
    int? maxWidth,
  }) {
    final mw = maxWidth != null ? '&maxWidth=$maxWidth' : '';
    return '$baseUrl/emby/Items/$personId/Images/Primary?quality=90$mw&api_key=$token';
  }

  Future<List<ChapterInfo>> fetchChapters({
    required String token,
    required String baseUrl,
    required String itemId,
  }) async {
    final url = Uri.parse('$baseUrl/emby/Items/$itemId/Chapters');
    final resp = await _client.get(url, headers: _jsonHeaders(token: token));
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

  Future<PagedResult<MediaItem>> fetchSimilar({
    required String token,
    required String baseUrl,
    required String userId,
    required String itemId,
    int limit = 10,
  }) async {
    final url = Uri.parse(
        '$baseUrl/emby/Users/$userId/Items/$itemId/Similar?Limit=$limit&Fields=Overview,ImageTags,ProviderIds,CommunityRating,Genres,ProductionYear');
    final resp = await _client.get(url, headers: _jsonHeaders(token: token));
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
