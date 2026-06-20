import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import '../app_identity.dart';
import '../network/proxy_http_client.dart';
import '../network/proxy_settings.dart';
import 'api_interfaces.dart';

class EmbyApiClient implements ApiClientFactory {
  late Dio _dio;
  String _currentLine;
  String? _authToken;
  String? _userId;
  void Function()? _proxyListenerCancel;

  EmbyApiClient({required String baseUrl, String? authToken, String? userId})
      : _currentLine = baseUrl,
        _authToken = authToken,
        _userId = userId {
    _dio = _createDio(baseUrl, authToken);
    _registerProxyListener();
  }

  static Dio _createDio(String baseUrl, String? authToken) {
    // 确保 baseUrl 以 / 结尾，避免 Dio 拼接路径时丢失子路径
    final normalizedBaseUrl = baseUrl.endsWith('/') ? baseUrl : '$baseUrl/';
    final dio = Dio(BaseOptions(
      baseUrl: normalizedBaseUrl,
      connectTimeout: const Duration(seconds: 15),
      receiveTimeout: const Duration(seconds: 30),
      headers: {
        'Content-Type': 'application/json',
        'Accept': 'application/json',
        'User-Agent': kAppUserAgent,
        'X-Emby-Authorization':
            'MediaBrowser Client="LinPlayer", Device="Mobile", DeviceId="linplayer-mobile", Version="$kAppVersion"',
        'X-Emby-Device-Name': 'Mobile',
        'X-Emby-Device-Id': 'linplayer-mobile',
        'X-Emby-Client': 'LinPlayer',
        'X-Emby-Client-Version': kAppVersion,
        if (authToken != null) 'X-Emby-Token': authToken,
      },
    ));

    // 自签名证书放行 + 用户自定义代理（HTTP/SOCKS）统一接入。
    applyProxyToDio(dio);

    // 兼容性拦截器：把鉴权 token 以 api_key 查询参数附加到所有请求，
    // 同时保留 header 鉴权（X-Emby-Token）。部分服务端依赖查询参数授权，
    // 而把冗长的 X-Emby-Authorization 串塞进 query 会触发 Cloudflare WAF，
    // 因此这里只补 api_key，并主动剔除 query 中的 X-Emby-Authorization。
    dio.interceptors.add(_EmbyAuthQueryCompatInterceptor());

    dio.interceptors
        .add(LogInterceptor(requestBody: true, responseBody: false));
    return dio;
  }

  void _rebuildDio() {
    _dio = _createDio(_currentLine, _authToken);
    _registerProxyListener();
  }

  /// 监听全局代理变更，实时让当前 Dio 重建底层连接。
  void _registerProxyListener() {
    _proxyListenerCancel?.call();
    final dio = _dio;
    _proxyListenerCancel =
        ProxyRuntime.instance.addListener(() => refreshDioProxy(dio));
  }

  String? get userId => _userId;

  @override
  AuthApi get auth => EmbyAuthApi(this);

  @override
  UserApi get user => EmbyUserApi(this);

  @override
  ServerApi get server => EmbyServerApi(this);

  @override
  HomeApi get home => EmbyHomeApi(this);

  @override
  LibraryApi get library => EmbyLibraryApi(this);

  @override
  MediaApi get media => EmbyMediaApi(this);

  @override
  SearchApi get search => EmbySearchApi(this);

  @override
  PlaybackApi get playback => EmbyPlaybackApi(this);

  @override
  FavoriteApi get favorite => EmbyFavoriteApi(this);

  @override
  SessionApi get session => EmbySessionApi(this);

  @override
  ImageApi get image => EmbyImageApi(this);

  @override
  void switchLine(String lineUrl) {
    _currentLine = lineUrl;
    _rebuildDio();
  }

  @override
  String get currentLine => _currentLine;

  @override
  void setAuthToken(String token) {
    _authToken = token;
    _dio.options.headers['X-Emby-Token'] = token;
  }

  @override
  void clearAuth() {
    _authToken = null;
    _userId = null;
    _dio.options.headers.remove('X-Emby-Token');
  }

  /// 包装 Dio.get，自动去掉路径开头的 /，确保 baseUrl 子路径不被丢弃
  Future<Response<T>> get<T>(String path,
      {Map<String, dynamic>? queryParameters, Options? options}) {
    return _dio.get<T>(
      path.startsWith('/') ? path.substring(1) : path,
      queryParameters: queryParameters,
      options: options,
    );
  }

  /// 包装 Dio.post，自动去掉路径开头的 /，确保 baseUrl 子路径不被丢弃
  Future<Response<T>> post<T>(String path,
      {dynamic data, Map<String, dynamic>? queryParameters, Options? options}) {
    return _dio.post<T>(
      path.startsWith('/') ? path.substring(1) : path,
      data: data,
      queryParameters: queryParameters,
      options: options,
    );
  }

  /// 包装 Dio.delete，自动去掉路径开头的 /，确保 baseUrl 子路径不被丢弃
  Future<Response<T>> delete<T>(String path,
      {dynamic data, Map<String, dynamic>? queryParameters, Options? options}) {
    return _dio.delete<T>(
      path.startsWith('/') ? path.substring(1) : path,
      data: data,
      queryParameters: queryParameters,
      options: options,
    );
  }
}

/// 兼容性拦截器：所有 Dio 请求附加 `api_key` 查询参数（同时保留 header 鉴权），
/// 并剔除 query 中的 `X-Emby-Authorization`（其冗长字符串会触发 Cloudflare 等 CDN
/// 的安全策略）。这样既兼容「依赖查询参数授权」的服务端，又不破坏走 CDN 的服务端。
class _EmbyAuthQueryCompatInterceptor extends Interceptor {
  @override
  void onRequest(
      RequestOptions options, RequestInterceptorHandler handler) {
    final token = options.headers['X-Emby-Token'];
    if (token is String &&
        token.isNotEmpty &&
        !options.queryParameters.containsKey('api_key')) {
      options.queryParameters['api_key'] = token;
    }
    options.queryParameters.remove('X-Emby-Authorization');
    handler.next(options);
  }
}

// ==================== Auth ====================

class EmbyAuthApi implements AuthApi {
  final EmbyApiClient _client;
  EmbyAuthApi(this._client);

  @override
  Future<AuthResult> login(
      {required String username, required String password}) async {
    debugPrint(
        '[EmbyAPI] login: username=$username, baseUrl=${_client.currentLine}');

    try {
      final resp = await _client.post('/Users/AuthenticateByName', data: {
        'Username': username,
        'Pw': password,
      });
      debugPrint('[EmbyAPI] login success: ${resp.statusCode}');
      final d = resp.data as Map<String, dynamic>;
      final userData = d['User'] as Map<String, dynamic>?;
      if (userData == null) {
        throw Exception('Invalid response: User data missing');
      }
      final user = _parseUser(userData);
      if (user.id.isEmpty) {
        throw Exception('Invalid response: User ID missing');
      }
      _client._userId = user.id;
      final token = d['AccessToken'] as String?;
      if (token == null || token.isEmpty) {
        throw Exception('Invalid response: AccessToken missing');
      }
      _client.setAuthToken(token);
      return AuthResult(
        accessToken: token,
        userId: user.id,
        serverId: d['ServerId'] as String? ?? '',
        user: user,
      );
    } on DioException catch (e) {
      debugPrint('[EmbyAPI] login failed: ${e.type} | ${e.message}');
      debugPrint('[EmbyAPI] request URL: ${e.requestOptions.uri}');
      debugPrint('[EmbyAPI] request headers: ${e.requestOptions.headers}');
      debugPrint('[EmbyAPI] request data: ${e.requestOptions.data}');
      debugPrint(
          '[EmbyAPI] response: ${e.response?.statusCode} | ${e.response?.data}');
      rethrow;
    }
  }

  @override
  Future<void> logout() async {
    try {
      await _client.post('/Sessions/Logout');
    } finally {
      _client.clearAuth();
    }
  }

  @override
  Future<User> getCurrentUser() async {
    final uid = _currentUserAliasForScopedRequest(_client);
    final resp = await _client.get('/Users/$uid');
    return _parseUser(resp.data as Map<String, dynamic>);
  }

  @override
  Future<AuthResult> refreshToken() async {
    return await login(
      username: _client._userId ?? '',
      password: '',
    );
  }
}

// ==================== User ====================

class EmbyUserApi implements UserApi {
  final EmbyApiClient _client;
  EmbyUserApi(this._client);

  @override
  Future<User> getUser(String userId) async {
    final resp = await _client.get('/Users/$userId');
    return _parseUser(resp.data as Map<String, dynamic>);
  }

  @override
  Future<void> markAsPlayed(String itemId) async {
    final uid = _requireUserId(_client);
    await _client.post('/Users/$uid/PlayedItems/$itemId');
  }

  @override
  Future<void> markAsUnplayed(String itemId) async {
    final uid = _requireUserId(_client);
    await _client.delete('/Users/$uid/PlayedItems/$itemId');
  }
}

// ==================== Server ====================

class EmbyServerApi implements ServerApi {
  final EmbyApiClient _client;
  EmbyServerApi(this._client);

  @override
  Future<ServerInfo> getPublicInfo(String baseUrl) async {
    // 确保 baseUrl 以 / 结尾
    final normalizedBaseUrl = baseUrl.endsWith('/') ? baseUrl : '$baseUrl/';
    final dio = Dio(BaseOptions(
      baseUrl: normalizedBaseUrl,
      headers: {
        'Content-Type': 'application/json',
        'Accept': 'application/json',
        'User-Agent': kAppUserAgent,
        'X-Emby-Authorization':
            'MediaBrowser Client="LinPlayer", Device="Mobile", DeviceId="linplayer-mobile", Version="$kAppVersion"',
        'X-Emby-Device-Name': 'Mobile',
        'X-Emby-Device-Id': 'linplayer-mobile',
        'X-Emby-Client': 'LinPlayer',
        'X-Emby-Client-Version': kAppVersion,
      },
    ));

    applyProxyToDio(dio);

    debugPrint('[EmbyAPI] getPublicInfo: baseUrl=$normalizedBaseUrl');

    try {
      final resp = await dio.get('System/Info/Public');
      debugPrint('[EmbyAPI] getPublicInfo success: ${resp.statusCode}');
      return _parseServerInfo(resp.data as Map<String, dynamic>);
    } on DioException catch (e) {
      debugPrint('[EmbyAPI] getPublicInfo failed: ${e.type} | ${e.message}');
      debugPrint('[EmbyAPI] request URL: ${e.requestOptions.uri}');
      debugPrint(
          '[EmbyAPI] response: ${e.response?.statusCode} | ${e.response?.data}');
      rethrow;
    }
  }

  @override
  Future<ServerInfo> getSystemInfo() async {
    final resp = await _client.get('/System/Info');
    return _parseServerInfo(resp.data as Map<String, dynamic>);
  }

  @override
  Future<bool> testConnection(String baseUrl) async {
    try {
      // 确保 baseUrl 以 / 结尾
      final normalizedBaseUrl = baseUrl.endsWith('/') ? baseUrl : '$baseUrl/';
      final dio = Dio(BaseOptions(
        baseUrl: normalizedBaseUrl,
        connectTimeout: const Duration(seconds: 5),
        headers: {
          'Content-Type': 'application/json',
          'Accept': 'application/json',
          'User-Agent': kAppUserAgent,
          'X-Emby-Authorization':
              'MediaBrowser Client="LinPlayer", Device="Mobile", DeviceId="linplayer-mobile", Version="$kAppVersion"',
          'X-Emby-Device-Name': 'Mobile',
          'X-Emby-Device-Id': 'linplayer-mobile',
          'X-Emby-Client': 'LinPlayer',
          'X-Emby-Client-Version': kAppVersion,
        },
      ));
      applyProxyToDio(dio);
      await dio.get('System/Info/Public');
      return true;
    } catch (_) {
      return false;
    }
  }
}

// ==================== Home ====================

class EmbyHomeApi implements HomeApi {
  final EmbyApiClient _client;
  EmbyHomeApi(this._client);

  static const String _mediaFields =
      'Overview,Genres,CommunityRating,OfficialRating,PremiereDate,'
      'RunTimeTicks,ProductionYear,Tags,SeriesName,IndexNumber,'
      'ParentIndexNumber,ImageTags,ParentThumbItemId,ParentThumbImageTag,'
      'ParentPrimaryImageItemId,ParentPrimaryImageTag,SeriesThumbImageTag,'
      'SeriesPrimaryImageTag,BackdropImageTags,ChildCount,RecursiveItemCount,'
      'CanDownload,SupportsSync,ProviderIds,PresentationUniqueKey,Path,'
      'ParentLogoItemId,ParentLogoImageTag,'
      'BackdropImageTags,ParentBackdropItemId,ParentBackdropImageTags';

  @override
  Future<List<MediaItem>> getResumeItems() async {
    final uid = _requireUserId(_client);
    final resp =
        await _client.get('/Users/$uid/Items/Resume', queryParameters: {
      'Limit': 12,
      'MediaTypes': 'Video',
      'Fields': _mediaFields,
    });
    return _parseItemList(resp.data);
  }

  @override
  Future<List<MediaItem>> getNextUp() async {
    final uid = _requireUserId(_client);
    final resp = await _client.get('/Shows/NextUp', queryParameters: {
      'UserId': uid,
      'Limit': 12,
      'Fields': _mediaFields,
    });
    return _parseItemList(resp.data);
  }

  @override
  Future<List<Library>> getLibraries() async {
    final uid = _requireUserId(_client);
    final resp = await _client.get('/Users/$uid/Views');
    final items = (resp.data as Map<String, dynamic>)['Items'] as List<dynamic>;
    return items.map((e) => _parseLibrary(e as Map<String, dynamic>)).toList();
  }

  @override
  Future<MediaCounts> getMediaCounts() async {
    final uid = _requireUserId(_client);
    debugPrint(
        '[EmbyAPI] getMediaCounts: baseUrl=${_client.currentLine}, userId=$uid');

    try {
      final resp = await _client.get('/Items/Counts', queryParameters: {
        'UserId': uid,
      });
      final data = resp.data as Map<String, dynamic>;
      debugPrint('[EmbyAPI] getMediaCounts success: $data');
      return MediaCounts(
        movieCount: (data['MovieCount'] as num?)?.toInt() ?? 0,
        episodeCount: (data['EpisodeCount'] as num?)?.toInt() ?? 0,
        itemCount: (data['ItemCount'] as num?)?.toInt(),
      );
    } on DioException catch (e) {
      debugPrint('[EmbyAPI] getMediaCounts failed: ${e.type} | ${e.message}');
      debugPrint('[EmbyAPI] request URL: ${e.requestOptions.uri}');
      debugPrint(
          '[EmbyAPI] response: ${e.response?.statusCode} | ${e.response?.data}');
      rethrow;
    }
  }

  @override
  Future<List<MediaItem>> getLatestItems(String libraryId,
      {int limit = 20}) async {
    final uid = _requireUserId(_client);
    final resp =
        await _client.get('/Users/$uid/Items/Latest', queryParameters: {
      'ParentId': libraryId,
      'Limit': limit,
      'Fields': _mediaFields,
    });
    final items = resp.data as List<dynamic>;
    return items
        .map((e) => _parseMediaItem(e as Map<String, dynamic>))
        .toList();
  }

  @override
  Future<List<MediaItem>> getRandomRecommendations({int limit = 8}) async {
    final uid = _requireUserId(_client);
    final resp = await _client.get('/Users/$uid/Items', queryParameters: {
      'Limit': limit,
      'SortBy': 'Random',
      'IncludeItemTypes': 'Movie,Series',
      'Recursive': true,
      'Fields': _mediaFields,
    });
    return _parseItemList(resp.data);
  }
}

// ==================== Library ====================

class EmbyLibraryApi implements LibraryApi {
  final EmbyApiClient _client;
  EmbyLibraryApi(this._client);

  static const String _libraryItemFields =
      'Overview,Genres,CommunityRating,OfficialRating,PremiereDate,'
      'RunTimeTicks,ProductionYear,Tags,SeriesName,IndexNumber,'
      'ParentIndexNumber,ImageTags,ParentThumbItemId,ParentThumbImageTag,'
      'ParentPrimaryImageItemId,ParentPrimaryImageTag,SeriesThumbImageTag,'
      'SeriesPrimaryImageTag,ChildCount,RecursiveItemCount,CanDownload,SupportsSync,'
      'ProviderIds,PresentationUniqueKey,Path,'
      'ParentLogoItemId,ParentLogoImageTag,'
      'BackdropImageTags,ParentBackdropItemId,ParentBackdropImageTags';

  @override
  Future<List<MediaItem>> getLibraryItems({
    required String libraryId,
    String? sortBy,
    String? sortOrder,
    int startIndex = 0,
    int limit = 50,
  }) async {
    final uid = _requireUserId(_client);
    final params = <String, dynamic>{
      'ParentId': libraryId,
      'UserId': uid,
      'StartIndex': startIndex,
      'Limit': limit,
      'Recursive': true,
      'IncludeItemTypes': 'Movie,Series',
      'Fields': _libraryItemFields,
    };
    if (sortBy != null) {
      params['SortBy'] = sortBy;
      params['SortOrder'] = sortOrder ?? 'Ascending';
    }
    final resp =
        await _client.get('/Users/$uid/Items', queryParameters: params);
    return _parseItemList(resp.data);
  }

  @override
  Future<Filters> getFilters(String libraryId) async {
    final uid = _requireUserId(_client);
    final resp = await _client.get('/Items/Filters', queryParameters: {
      'UserId': uid,
      'ParentId': libraryId,
    });
    final d = resp.data as Map<String, dynamic>;
    return Filters(
      genres:
          (d['Genres'] as List<dynamic>?)?.map((e) => e.toString()).toList() ??
              [],
      years:
          (d['Years'] as List<dynamic>?)?.map((e) => e.toString()).toList() ??
              [],
      officialRatings: (d['OfficialRatings'] as List<dynamic>?)
              ?.map((e) => e.toString())
              .toList() ??
          [],
    );
  }
}

// ==================== Media ====================

class EmbyMediaApi implements MediaApi {
  final EmbyApiClient _client;
  EmbyMediaApi(this._client);

  static const String _detailFields =
      'Overview,Genres,CommunityRating,OfficialRating,PremiereDate,'
      'RunTimeTicks,ProductionYear,Tags,SeriesName,IndexNumber,'
      'ParentIndexNumber,People,Studios,ImageTags,ParentThumbItemId,'
      'ParentThumbImageTag,ParentPrimaryImageItemId,ParentPrimaryImageTag,'
      'SeriesThumbImageTag,SeriesPrimaryImageTag,BackdropImageTags,'
      'ChildCount,RecursiveItemCount,CanDownload,SupportsSync,ProviderIds,'
      'PresentationUniqueKey,Path,'
      'ParentLogoItemId,ParentLogoImageTag,'
      'BackdropImageTags,ParentBackdropItemId,ParentBackdropImageTags';

  @override
  Future<MediaItem> getItemDetails(String itemId) async {
    if (itemId.isEmpty) {
      throw Exception('无效的媒体ID');
    }
    final uid = _client._userId;
    final params = <String, dynamic>{
      'Fields': _detailFields,
    };
    if (uid != null) params['UserId'] = uid;
    try {
      final resp = await _client.get('/Items/$itemId', queryParameters: params);
      return _parseMediaItem(resp.data as Map<String, dynamic>);
    } on DioException catch (e) {
      if (e.response?.statusCode == 404 && uid != null) {
        try {
          final resp = await _client.get('/Users/$uid/Items/$itemId',
              queryParameters: params);
          return _parseMediaItem(resp.data as Map<String, dynamic>);
        } catch (_) {
          // fallback 失败，继续抛出原始错误
        }
      }
      rethrow;
    }
  }

  @override
  Future<List<MediaItem>> getSimilarItems(String itemId) async {
    final uid = _requireUserId(_client);
    final resp = await _client.get('/Items/$itemId/Similar', queryParameters: {
      'UserId': uid,
      'Limit': 12,
      'Fields': _detailFields,
    });
    final items = (resp.data as Map<String, dynamic>)['Items'] as List<dynamic>;
    return items
        .map((e) => _parseMediaItem(e as Map<String, dynamic>))
        .toList();
  }

  @override
  Future<List<Season>> getSeasons(String seriesId) async {
    final uid = _requireUserId(_client);
    final resp =
        await _client.get('/Shows/$seriesId/Seasons', queryParameters: {
      'UserId': uid,
      'Fields': 'Overview,ImageTags,SeriesPrimaryImageTag,SeriesThumbImageTag',
    });
    final items = (resp.data as Map<String, dynamic>)['Items'] as List<dynamic>;
    return items
        .map((e) => _parseSeason(e as Map<String, dynamic>, seriesId))
        .toList();
  }

  @override
  Future<List<Episode>> getEpisodes(String seriesId, {String? seasonId}) async {
    final uid = _requireUserId(_client);
    final params = <String, dynamic>{
      'UserId': uid,
      'Fields':
          'Overview,RunTimeTicks,ImageTags,ParentThumbItemId,ParentThumbImageTag,ParentPrimaryImageItemId,ParentPrimaryImageTag,SeriesThumbImageTag,SeriesPrimaryImageTag,CanDownload,SupportsSync',
    };
    if (seasonId != null) params['SeasonId'] = seasonId;
    final resp =
        await _client.get('/Shows/$seriesId/Episodes', queryParameters: params);
    final items = (resp.data as Map<String, dynamic>)['Items'] as List<dynamic>;
    return items.map((e) => _parseEpisode(e as Map<String, dynamic>)).toList();
  }

  @override
  Future<List<Person>> getPersonItems(String personName) async {
    final uid = _requireUserId(_client);
    final resp =
        await _client.get('/Persons/$personName/Items', queryParameters: {
      'UserId': uid,
      'Limit': 20,
    });
    final items = (resp.data as Map<String, dynamic>)['Items'] as List<dynamic>;
    return items
        .map((e) => _parsePersonFromItem(e as Map<String, dynamic>))
        .toList();
  }
}

// ==================== Search ====================

class EmbySearchApi implements SearchApi {
  final EmbyApiClient _client;
  EmbySearchApi(this._client);

  @override
  Future<List<MediaItem>> getSearchHints(String query) async {
    final uid = _requireUserId(_client);
    final resp = await _client.get('/Search/Hints', queryParameters: {
      'UserId': uid,
      'SearchTerm': query,
      'Limit': 20,
    });
    final hints =
        (resp.data as Map<String, dynamic>)['SearchHints'] as List<dynamic>;
    return hints
        .map((e) => _parseMediaItem(e as Map<String, dynamic>))
        .toList();
  }

  @override
  Future<List<MediaItem>> search(String query, {bool recursive = true}) async {
    final uid = _requireUserId(_client);
    final resp = await _client.get('/Users/$uid/Items', queryParameters: {
      'SearchTerm': query,
      'Recursive': recursive,
      'Limit': 50,
      'Fields':
          'Overview,Genres,CommunityRating,OfficialRating,PremiereDate,RunTimeTicks,ProductionYear,Tags,SeriesName,IndexNumber,ParentIndexNumber,ProviderIds,PresentationUniqueKey,Path',
    });
    return _parseItemList(resp.data);
  }

  @override
  Future<Map<String, List<MediaItem>>> searchAggregate(String query) async {
    final uid = _requireUserId(_client);
    final resp = await _client.get('/Users/$uid/Items', queryParameters: {
      'SearchTerm': query,
      'Recursive': true,
      'Limit': 50,
      'Fields':
          'Overview,Genres,CommunityRating,OfficialRating,PremiereDate,RunTimeTicks,ProductionYear,Tags,SeriesName,IndexNumber,ParentIndexNumber,ProviderIds,PresentationUniqueKey,Path',
    });
    final items = _parseItemList(resp.data);
    final serverName = _client._dio.options.baseUrl;
    return {serverName: items};
  }
}

// ==================== Playback ====================

class EmbyPlaybackApi implements PlaybackApi {
  final EmbyApiClient _client;
  EmbyPlaybackApi(this._client);

  @override
  Future<PlaybackInfo> getPlaybackInfo(String itemId) async {
    final uid = _requireUserId(_client);
    final resp = await _client.post('/Items/$itemId/PlaybackInfo', data: {
      'UserId': uid,
      'StartTimeTicks': 0,
      'IsPlayback': true,
      'AutoOpenLiveStream': true,
    });
    return _parsePlaybackInfo(resp.data as Map<String, dynamic>, itemId);
  }

  @override
  String getVideoStreamUrl(
    String itemId, {
    String? mediaSourceId,
    String? container,
    String? playSessionId,
    bool staticStream = true,
    bool allowDirectPlay = true,
    bool allowDirectStream = true,
    bool allowTranscoding = false,
    bool enableAutoStreamCopy = true,
    bool enableAutoStreamCopyAudio = true,
    bool enableAutoStreamCopyVideo = true,
  }) {
    final base = _client._currentLine.endsWith('/')
        ? _client._currentLine.substring(0, _client._currentLine.length - 1)
        : _client._currentLine;
    final token = _client._authToken;
    final normalizedContainer = (container ?? 'mkv').trim().toLowerCase();
    final safeContainer =
        normalizedContainer.isEmpty ? 'mkv' : normalizedContainer;
    final params = <String>[
      'static=$staticStream',
      'download=false',
      'EnableAutoStreamCopy=$enableAutoStreamCopy',
      'EnableAutoStreamCopyAudio=$enableAutoStreamCopyAudio',
      'EnableAutoStreamCopyVideo=$enableAutoStreamCopyVideo',
      'EnableDirectPlay=$allowDirectPlay',
      'EnableDirectStream=$allowDirectStream',
      'EnableTranscoding=$allowTranscoding',
      if (mediaSourceId != null && mediaSourceId.isNotEmpty)
        'MediaSourceId=${Uri.encodeQueryComponent(mediaSourceId)}',
      if (playSessionId != null && playSessionId.isNotEmpty)
        'PlaySessionId=${Uri.encodeQueryComponent(playSessionId)}',
      if (token != null) 'api_key=${Uri.encodeQueryComponent(token)}',
    ];
    return '$base/Videos/$itemId/stream.$safeContainer?${params.join('&')}';
  }

  @override
  String getSubtitleStreamUrl(
      String itemId, String mediaSourceId, int index, String codec) {
    final base = _client._currentLine;
    final token = _client._authToken;
    return '$base/Videos/$itemId/$mediaSourceId/Subtitles/$index/Stream.$codec${token != null ? '?api_key=$token' : ''}';
  }

  @override
  String getDownloadUrl(String itemId, {String? mediaSourceId}) {
    final base = _client._currentLine.endsWith('/')
        ? _client._currentLine.substring(0, _client._currentLine.length - 1)
        : _client._currentLine;
    final token = _client._authToken;
    final params = <String>[
      if (mediaSourceId != null && mediaSourceId.isNotEmpty)
        'MediaSourceId=${Uri.encodeQueryComponent(mediaSourceId)}',
      if (token != null) 'api_key=${Uri.encodeQueryComponent(token)}',
    ];
    final query = params.isEmpty ? '' : '?${params.join('&')}';
    return '$base/Items/$itemId/Download$query';
  }

  @override
  Future<void> reportPlaybackStart(PlaybackStartInfo info) async {
    await _client.post('/Sessions/Playing', data: {
      'ItemId': info.itemId,
      'MediaSourceId': info.mediaSourceId,
      'AudioStreamIndex': info.audioStreamIndex,
      'SubtitleStreamIndex': info.subtitleStreamIndex,
      'PlayMethod': info.playMethod ?? 'DirectStream',
    });
  }

  @override
  Future<void> reportPlaybackProgress(PlaybackProgressInfo info) async {
    await _client.post('/Sessions/Playing/Progress', data: {
      'ItemId': info.itemId,
      'MediaSourceId': info.mediaSourceId,
      'PositionTicks': info.positionTicks,
      'IsPaused': info.isPaused,
      'IsMuted': info.isMuted,
      'VolumeLevel': (info.volumeLevel * 100).round(),
    });
  }

  @override
  Future<void> reportPlaybackStopped(PlaybackStopInfo info) async {
    await _client.post('/Sessions/Playing/Stopped', data: {
      'ItemId': info.itemId,
      'MediaSourceId': info.mediaSourceId,
      'PositionTicks': info.positionTicks,
    });
  }
}

// ==================== Favorite ====================

class EmbyFavoriteApi implements FavoriteApi {
  final EmbyApiClient _client;
  EmbyFavoriteApi(this._client);

  static const String _favoriteFields =
      'Overview,Genres,CommunityRating,OfficialRating,PremiereDate,'
      'RunTimeTicks,ProductionYear,Tags,SeriesName,IndexNumber,'
      'ParentIndexNumber,ImageTags,ParentThumbItemId,ParentThumbImageTag,'
      'ParentPrimaryImageItemId,ParentPrimaryImageTag,SeriesThumbImageTag,'
      'SeriesPrimaryImageTag,BackdropImageTags,ChildCount,RecursiveItemCount,'
      'CanDownload,SupportsSync,ParentLogoItemId,ParentLogoImageTag';

  @override
  Future<List<MediaItem>> getFavorites() async {
    final uid = _requireUserId(_client);
    final resp = await _client.get('/Users/$uid/Items', queryParameters: {
      'Filters': 'IsFavorite',
      'Recursive': true,
      'IncludeItemTypes': 'Movie,Series,Season,Episode',
      'SortBy': 'DateCreated,SortName',
      'SortOrder': 'Descending',
      'Limit': 200,
      'Fields': _favoriteFields,
    });
    return _parseItemList(resp.data);
  }

  @override
  Future<void> addFavorite(String itemId) async {
    final uid = _requireUserId(_client);
    await _client.post('/Users/$uid/FavoriteItems/$itemId');
  }

  @override
  Future<void> removeFavorite(String itemId) async {
    final uid = _requireUserId(_client);
    await _client._dio.delete('/Users/$uid/FavoriteItems/$itemId');
  }
}

// ==================== Session ====================

class EmbySessionApi implements SessionApi {
  final EmbyApiClient _client;
  EmbySessionApi(this._client);

  @override
  Future<List<Session>> getSessions() async {
    final resp = await _client.get('/Sessions');
    final items = resp.data as List<dynamic>;
    return items.map((e) => _parseSession(e as Map<String, dynamic>)).toList();
  }
}

// ==================== Image ====================

class EmbyImageApi implements ImageApi {
  final EmbyApiClient _client;
  EmbyImageApi(this._client);

  @override
  String getImageUrl({
    required String itemId,
    String? imageTag,
    String imageType = 'Primary',
    int? maxWidth,
    int? maxHeight,
    double quality = 90,
    String? format,
  }) {
    final base = _client._currentLine;
    final buf = StringBuffer('$base/Items/$itemId/Images/$imageType');
    final params = <String, String>{};
    if (maxWidth != null) params['maxWidth'] = maxWidth.toString();
    if (maxHeight != null) params['maxHeight'] = maxHeight.toString();
    params['quality'] = quality.round().toString();
    if (format != null && format.isNotEmpty) params['format'] = format;
    if (_client._authToken != null) params['api_key'] = _client._authToken!;
    if (imageTag != null) params['tag'] = imageTag;
    if (params.isNotEmpty) {
      buf.write('?');
      buf.write(params.entries.map((e) => '${e.key}=${e.value}').join('&'));
    }
    return buf.toString();
  }

  @override
  String getPrimaryImageUrl(String itemId,
      {String? tag, int? maxWidth, String? format}) {
    return getImageUrl(
        itemId: itemId,
        imageTag: tag,
        imageType: 'Primary',
        maxWidth: maxWidth,
        format: format);
  }

  @override
  String getThumbImageUrl(String itemId,
      {String? tag, int? maxWidth, String? format}) {
    return getImageUrl(
        itemId: itemId,
        imageTag: tag,
        imageType: 'Thumb',
        maxWidth: maxWidth,
        format: format);
  }

  @override
  String getBackdropImageUrl(String itemId,
      {String? tag, int? maxWidth, String? format}) {
    // 不再强制 maxHeight:450（会把全屏背景图压成低清导致发虚）；
    // 由调用方传入的 maxWidth 决定清晰度，未传时给一个适合背景的默认值。
    return getImageUrl(
      itemId: itemId,
      imageTag: tag,
      imageType: 'Backdrop',
      maxWidth: maxWidth ?? 1280,
      format: format,
    );
  }

  @override
  String? getLogoImageUrl(String itemId, {String? tag, int? maxWidth}) {
    if (tag == null || tag.isEmpty) return null;
    return getImageUrl(
      itemId: itemId,
      imageTag: tag,
      imageType: 'Logo',
      maxWidth: maxWidth ?? 400,
    );
  }
}

// ==================== Danmaku (deprecated - see danmaku/ module) ====================

// ==================== Parse Helpers ====================

String _requireUserId(EmbyApiClient c) {
  final uid = c._userId;
  if (uid == null || uid.isEmpty) {
    // 如果 authToken 存在，使用 "Me" 作为当前用户的别名（Emby API 支持）
    if (c._authToken != null && c._authToken!.isNotEmpty) {
      return 'Me';
    }
    throw Exception('Not authenticated: userId missing');
  }
  return uid;
}

String _currentUserAliasForScopedRequest(EmbyApiClient c) {
  if (c._authToken != null && c._authToken!.isNotEmpty) {
    return 'Me';
  }
  return _requireUserId(c);
}

User _parseUser(Map<String, dynamic> d) {
  return User(
    id: d['Id'] ?? d['UserId'] ?? '',
    name: d['Name'] ?? '',
    primaryImageTag: d['PrimaryImageTag']?.toString(),
    hasPassword: d['HasPassword'] as bool?,
    configuration: (d['Configuration'] as Map<String, dynamic>?)?.keys.toList(),
    policy: _parseUserPolicy(d['Policy']),
  );
}

UserPolicy? _parseUserPolicy(dynamic raw) {
  if (raw is! Map<String, dynamic>) return null;
  bool readBool(String key) => raw[key] as bool? ?? false;
  return UserPolicy(
    isAdministrator: readBool('IsAdministrator'),
    enableContentDownloading: readBool('EnableContentDownloading'),
    // 不同服务端字段差异：Jellyfin 用 EnableContentDownloading，
    // 部分 Emby 版本另有 EnableDownloading / EnableSync。
    enableDownloading:
        readBool('EnableDownloading') || readBool('EnableSync'),
  );
}

ServerInfo _parseServerInfo(Map<String, dynamic> d) {
  return ServerInfo(
    id: d['Id']?.toString() ?? '',
    serverName: d['ServerName'] ?? '',
    version: d['Version'] ?? '',
    productName: d['ProductName']?.toString(),
    operatingSystem: d['OperatingSystem']?.toString(),
  );
}

List<MediaItem> _parseItemList(dynamic data) {
  final d = data as Map<String, dynamic>;
  final items = (d['Items'] ?? d) as List<dynamic>;
  return items.map((e) => _parseMediaItem(e as Map<String, dynamic>)).toList();
}

MediaItem _parseMediaItem(Map<String, dynamic> d) {
  final ud = d['UserData'] as Map<String, dynamic>?;
  final int? childCount = d['ChildCount'] as int?;
  final int? recursiveItemCount = d['RecursiveItemCount'] as int?;
  final people = (d['People'] as List<dynamic>?)
      ?.map((e) => _parsePersonFromItem(e as Map<String, dynamic>))
      .toList();
  final backdrop = _extractBackdrop(d);
  return MediaItem(
    id: d['Id']?.toString() ?? '',
    name: d['Name'] ?? '',
    type: d['Type'] ?? '',
    providerIds: _parseProviderIds(d['ProviderIds']),
    presentationUniqueKey: d['PresentationUniqueKey']?.toString(),
    path: d['Path']?.toString(),
    overview: d['Overview']?.toString(),
    primaryImageTag: _extractImageTag(d, 'Primary'),
    thumbImageTag: _extractImageTag(d, 'Thumb'),
    backdropImageTag: backdrop?.tag,
    backdropItemId: backdrop?.itemId,
    communityRating: (d['CommunityRating'] as num?)?.toDouble(),
    officialRating: d['OfficialRating']?.toString(),
    premiereDate: _parseDate(d['PremiereDate']),
    runTimeTicks: _parseTicks(d['RunTimeTicks']),
    productionYear: d['ProductionYear'] as int?,
    genres: (d['Genres'] as List<dynamic>?)?.map((e) => e.toString()).toList(),
    tags: (d['Tags'] as List<dynamic>?)?.map((e) => e.toString()).toList(),
    userData: ud != null
        ? UserData(
            playbackPositionTicks:
                _parseTicksDouble(ud['PlaybackPositionTicks']),
            played: ud['Played'] as bool?,
            isFavorite: ud['IsFavorite'] as bool?,
            playCount: (ud['PlayCount'] as num?)?.toDouble(),
          )
        : null,
    seriesName: d['SeriesName']?.toString(),
    indexNumber: d['IndexNumber'] as int?,
    parentIndexNumber: d['ParentIndexNumber'] as int?,
    seriesId: d['SeriesId']?.toString(),
    seasonId: d['SeasonId']?.toString(),
    parentThumbItemId: d['ParentThumbItemId']?.toString(),
    parentThumbImageTag: d['ParentThumbImageTag']?.toString(),
    parentPrimaryImageItemId: d['ParentPrimaryImageItemId']?.toString(),
    parentPrimaryImageTag: d['ParentPrimaryImageTag']?.toString(),
    seriesThumbImageTag: d['SeriesThumbImageTag']?.toString(),
    seriesPrimaryImageTag: d['SeriesPrimaryImageTag']?.toString(),
    mediaType: d['MediaType']?.toString(),
    parentId: d['ParentId']?.toString(),
    childCount: recursiveItemCount ?? childCount,
    recursiveItemCount: recursiveItemCount,
    people: people,
    canDownload: d['CanDownload'] as bool? ?? d['SupportsSync'] as bool?,
    remoteTrailers: (d['RemoteTrailers'] as List<dynamic>?)
        ?.map((e) {
          if (e is Map<String, dynamic>) {
            return e['Url']?.toString() ?? e['url']?.toString();
          }
          return e?.toString();
        })
        .where((url) => url != null && url.isNotEmpty)
        .cast<String>()
        .toList(),
    logoItemId: _extractLogoItemId(d),
    logoImageTag: _extractLogoImageTag(d),
  );
}

Map<String, String>? _parseProviderIds(dynamic value) {
  if (value is! Map) {
    return null;
  }
  final providerIds = <String, String>{};
  value.forEach((key, entryValue) {
    final normalizedKey = key?.toString();
    final normalizedValue = entryValue?.toString();
    if (normalizedKey == null ||
        normalizedKey.isEmpty ||
        normalizedValue == null ||
        normalizedValue.isEmpty) {
      return;
    }
    providerIds[normalizedKey] = normalizedValue;
  });
  if (providerIds.isEmpty) {
    return null;
  }
  return providerIds;
}

String? _extractImageTag(Map<String, dynamic> d, String type) {
  final tags = d['ImageTags'] as Map<String, dynamic>?;
  final value = tags?[type]?.toString();
  if (value == null || value.isEmpty) return null;
  return value;
}

/// 背景图（Backdrop）来源。
///
/// Emby 的背景图**不在** `ImageTags` 里，而在独立的 `BackdropImageTags` 数组；
/// 剧集/季等自身没有背景图时，Emby 通过 `ParentBackdropImageTags` +
/// `ParentBackdropItemId` 提供父级（剧集）的背景图。
/// 之前误读 `ImageTags['Backdrop']` 导致背景图恒为 null、详情页退回封面图。
class _BackdropRef {
  final String tag;
  final String itemId;
  const _BackdropRef(this.tag, this.itemId);
}

_BackdropRef? _extractBackdrop(Map<String, dynamic> d) {
  String? firstTag(dynamic list) {
    if (list is List) {
      for (final e in list) {
        final tag = e?.toString();
        if (tag != null && tag.isNotEmpty) return tag;
      }
    }
    return null;
  }

  // 自身背景图
  final ownTag = firstTag(d['BackdropImageTags']);
  final ownId = d['Id']?.toString();
  if (ownTag != null && ownId != null && ownId.isNotEmpty) {
    return _BackdropRef(ownTag, ownId);
  }

  // 回退：父级（剧集）背景图
  final parentTag = firstTag(d['ParentBackdropImageTags']);
  final parentId = d['ParentBackdropItemId']?.toString();
  if (parentTag != null && parentId != null && parentId.isNotEmpty) {
    return _BackdropRef(parentTag, parentId);
  }

  return null;
}

/// 提取 Logo 项目 ID：优先使用自身，否则使用父级
String? _extractLogoItemId(Map<String, dynamic> d) {
  final tags = d['ImageTags'] as Map<String, dynamic>?;
  if (tags?.containsKey('Logo') == true) {
    return d['Id']?.toString();
  }
  final parentId = d['ParentLogoItemId']?.toString();
  return (parentId != null && parentId.isNotEmpty) ? parentId : null;
}

/// 提取 Logo 缓存 tag：优先使用自身，否则使用父级
String? _extractLogoImageTag(Map<String, dynamic> d) {
  final tags = d['ImageTags'] as Map<String, dynamic>?;
  final ownTag = tags?['Logo']?.toString();
  if (ownTag != null && ownTag.isNotEmpty) return ownTag;
  final parentTag = d['ParentLogoImageTag']?.toString();
  return (parentTag != null && parentTag.isNotEmpty) ? parentTag : null;
}

int? _parseTicks(dynamic v) {
  if (v == null) return null;
  if (v is int) return v;
  if (v is double) return v.round();
  return int.tryParse(v.toString());
}

double? _parseTicksDouble(dynamic v) {
  final t = _parseTicks(v);
  return t?.toDouble();
}

DateTime? _parseDate(dynamic v) {
  if (v == null) return null;
  return DateTime.tryParse(v.toString());
}

Library _parseLibrary(Map<String, dynamic> d) {
  return Library(
    id: d['Id']?.toString() ?? '',
    name: d['Name'] ?? '',
    primaryImageTag: _extractImageTag(d, 'Primary'),
    collectionType: d['CollectionType']?.toString() ?? 'mixed',
  );
}

Season _parseSeason(Map<String, dynamic> d, String seriesId) {
  return Season(
    id: d['Id']?.toString() ?? '',
    name: d['Name'] ?? '',
    indexNumber: d['IndexNumber'] as int?,
    primaryImageTag: _extractImageTag(d, 'Primary'),
    thumbImageTag: _extractImageTag(d, 'Thumb'),
    seriesId: d['SeriesId']?.toString() ?? seriesId,
    seriesPrimaryImageTag: d['SeriesPrimaryImageTag']?.toString(),
    seriesThumbImageTag: d['SeriesThumbImageTag']?.toString(),
  );
}

Episode _parseEpisode(Map<String, dynamic> d) {
  final ud = d['UserData'] as Map<String, dynamic>?;
  return Episode(
    id: d['Id']?.toString() ?? '',
    name: d['Name'] ?? '',
    indexNumber: d['IndexNumber'] as int?,
    primaryImageTag:
        _extractImageTag(d, 'Primary') ?? d['PrimaryImageTag']?.toString(),
    thumbImageTag:
        _extractImageTag(d, 'Thumb') ?? d['ThumbImageTag']?.toString(),
    seriesId: d['SeriesId']?.toString() ?? '',
    seasonId: d['SeasonId']?.toString() ?? '',
    parentThumbItemId: d['ParentThumbItemId']?.toString(),
    parentThumbImageTag: d['ParentThumbImageTag']?.toString(),
    parentPrimaryImageItemId: d['ParentPrimaryImageItemId']?.toString(),
    parentPrimaryImageTag: d['ParentPrimaryImageTag']?.toString(),
    seriesThumbImageTag: d['SeriesThumbImageTag']?.toString(),
    seriesPrimaryImageTag: d['SeriesPrimaryImageTag']?.toString(),
    runTimeTicks: _parseTicks(d['RunTimeTicks']),
    userData: ud != null
        ? UserData(
            playbackPositionTicks:
                _parseTicksDouble(ud['PlaybackPositionTicks']),
            played: ud['Played'] as bool?,
            isFavorite: ud['IsFavorite'] as bool?,
          )
        : null,
    overview: d['Overview']?.toString(),
  );
}

Person _parsePersonFromItem(Map<String, dynamic> d) {
  return Person(
    id: d['Id']?.toString() ?? '',
    name: d['Name'] ?? '',
    primaryImageTag:
        _extractImageTag(d, 'Primary') ?? d['PrimaryImageTag']?.toString(),
    role: d['Role']?.toString(),
    type: d['Type']?.toString(),
  );
}

Session _parseSession(Map<String, dynamic> d) {
  final npi = d['NowPlayingItem'] as Map<String, dynamic>?;
  return Session(
    id: d['Id']?.toString() ?? '',
    userName: d['UserName']?.toString(),
    client: d['Client']?.toString(),
    deviceName: d['DeviceName']?.toString(),
    isNowPlaying: d['IsNowPlaying'] as bool?,
    nowPlayingItem: npi != null
        ? NowPlayingItem(
            id: npi['Id']?.toString() ?? '',
            name: npi['Name'] ?? '',
            seriesName: npi['SeriesName']?.toString(),
            runTimeTicks: _parseTicks(npi['RunTimeTicks']),
            playbackPositionTicks: _parseTicks(npi['PlaybackPositionTicks']),
          )
        : null,
  );
}

PlaybackInfo _parsePlaybackInfo(Map<String, dynamic> d, String itemId) {
  final sources = (d['MediaSources'] as List<dynamic>?) ?? [];
  return PlaybackInfo(
    itemId: d['ItemId']?.toString() ?? itemId,
    mediaSources: sources
        .map((e) => _parseMediaSource(e as Map<String, dynamic>))
        .toList(),
  );
}

MediaSource _parseMediaSource(Map<String, dynamic> d) {
  final streams = (d['MediaStreams'] as List<dynamic>?) ?? [];
  return MediaSource(
    id: d['Id']?.toString() ?? '',
    name: d['Name']?.toString(),
    path: d['Path']?.toString(),
    container: d['Container']?.toString(),
    size: d['Size'] as int?,
    runTimeTicks: _parseTicks(d['RunTimeTicks']),
    protocol: d['Protocol']?.toString(),
    isRemote: d['IsRemote'] as bool?,
    mediaStreams: streams
        .map((e) => _parseMediaStream(e as Map<String, dynamic>))
        .toList(),
  );
}

MediaStream _parseMediaStream(Map<String, dynamic> d) {
  return MediaStream(
    index: d['Index'] as int? ?? 0,
    type: d['Type'] ?? '',
    codec: d['Codec']?.toString(),
    language: d['Language']?.toString(),
    title: d['Title']?.toString(),
    isDefault: d['IsDefault'] as bool?,
    isExternal: d['IsExternal'] as bool?,
    displayTitle: d['DisplayTitle']?.toString(),
    path: d['Path']?.toString(),
    deliveryUrl: d['DeliveryUrl']?.toString(),
    deliveryMethod: d['DeliveryMethod']?.toString(),
    isExternalUrl: d['IsExternalUrl'] as bool?,
    videoCodec: d['VideoCodec']?.toString() ?? d['Codec']?.toString(),
    width: d['Width'] as int?,
    height: d['Height'] as int?,
    channels: d['Channels'] as int?,
    bitRate: d['BitRate'] as int?,
    videoRange: d['VideoRange']?.toString(),
    videoRangeType: d['VideoRangeType']?.toString(),
  );
}
