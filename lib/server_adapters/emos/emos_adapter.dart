import '../../state/media_server_type.dart';
import '../../services/emby_api.dart';
import '../server_adapter.dart';

class EmosServerAdapter implements MediaServerAdapter {
  EmosServerAdapter({required this.serverType, required this.deviceId});

  @override
  final MediaServerType serverType;

  @override
  final String deviceId;

  EmbyApi _apiFor(ServerAuthSession auth) {
    return EmbyApi(
      hostOrUrl: auth.baseUrl,
      preferredScheme: auth.preferredScheme,
      apiPrefix: auth.apiPrefix,
      serverType: serverType,
      deviceId: deviceId,
    );
  }

  @override
  Future<ServerAuthSession> authenticate({
    required String hostOrUrl,
    required String scheme,
    String? port,
    required String username,
    required String password,
  }) {
    final api = EmbyApi(
      hostOrUrl: hostOrUrl,
      preferredScheme: scheme,
      port: port,
      serverType: serverType,
      deviceId: deviceId,
    );
    return api
        .authenticate(
          username: username,
          password: password,
          deviceId: deviceId,
          serverType: serverType,
        )
        .then(
          (auth) => ServerAuthSession(
            token: auth.token,
            baseUrl: auth.baseUrlUsed,
            userId: auth.userId,
            apiPrefix: auth.apiPrefixUsed,
            preferredScheme: scheme,
          ),
        );
  }

  @override
  Future<String?> fetchServerName(ServerAuthSession auth) {
    return _apiFor(auth).fetchServerName(auth.baseUrl, token: auth.token);
  }

  @override
  Future<List<DomainInfo>> fetchDomains(
    ServerAuthSession auth, {
    required bool allowFailure,
  }) {
    return _apiFor(auth).fetchDomains(
      auth.token,
      auth.baseUrl,
      allowFailure: allowFailure,
    );
  }

  @override
  Future<List<LibraryInfo>> fetchLibraries(ServerAuthSession auth) {
    return _apiFor(auth).fetchLibraries(
      token: auth.token,
      baseUrl: auth.baseUrl,
      userId: auth.userId,
    );
  }

  @override
  Future<PagedResult<MediaItem>> fetchItems(
    ServerAuthSession auth, {
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
  }) {
    return _apiFor(auth).fetchItems(
      token: auth.token,
      baseUrl: auth.baseUrl,
      userId: auth.userId,
      parentId: parentId,
      startIndex: startIndex,
      limit: limit,
      includeItemTypes: includeItemTypes,
      searchTerm: searchTerm,
      recursive: recursive,
      excludeFolders: excludeFolders,
      sortBy: sortBy,
      sortOrder: sortOrder,
      fields: fields,
    );
  }

  @override
  Future<PagedResult<MediaItem>> fetchContinueWatching(
    ServerAuthSession auth, {
    int limit = 30,
  }) {
    return _apiFor(auth).fetchContinueWatching(
      token: auth.token,
      baseUrl: auth.baseUrl,
      userId: auth.userId,
      limit: limit,
    );
  }

  @override
  Future<MediaItem> fetchItemDetail(
    ServerAuthSession auth, {
    required String itemId,
  }) {
    return _apiFor(auth).fetchItemDetail(
      token: auth.token,
      baseUrl: auth.baseUrl,
      userId: auth.userId,
      itemId: itemId,
    );
  }

  @override
  Future<PagedResult<MediaItem>> fetchSeasons(
    ServerAuthSession auth, {
    required String seriesId,
  }) {
    return _apiFor(auth).fetchSeasons(
      token: auth.token,
      baseUrl: auth.baseUrl,
      userId: auth.userId,
      seriesId: seriesId,
    );
  }

  @override
  Future<PagedResult<MediaItem>> fetchEpisodes(
    ServerAuthSession auth, {
    required String seasonId,
  }) {
    return _apiFor(auth).fetchEpisodes(
      token: auth.token,
      baseUrl: auth.baseUrl,
      userId: auth.userId,
      seasonId: seasonId,
    );
  }

  @override
  Future<PagedResult<MediaItem>> fetchSimilar(
    ServerAuthSession auth, {
    required String itemId,
    int limit = 10,
  }) {
    return _apiFor(auth).fetchSimilar(
      token: auth.token,
      baseUrl: auth.baseUrl,
      userId: auth.userId,
      itemId: itemId,
      limit: limit,
    );
  }

  @override
  Future<PlaybackInfoResult> fetchPlaybackInfo(
    ServerAuthSession auth, {
    required String itemId,
    bool exoPlayer = false,
  }) {
    return _apiFor(auth).fetchPlaybackInfo(
      token: auth.token,
      baseUrl: auth.baseUrl,
      userId: auth.userId,
      deviceId: deviceId,
      itemId: itemId,
      exoPlayer: exoPlayer,
    );
  }

  @override
  Future<List<ChapterInfo>> fetchChapters(
    ServerAuthSession auth, {
    required String itemId,
  }) {
    return _apiFor(auth).fetchChapters(
      token: auth.token,
      baseUrl: auth.baseUrl,
      userId: auth.userId,
      itemId: itemId,
    );
  }

  @override
  Future<void> reportPlaybackStart(
    ServerAuthSession auth, {
    required String itemId,
    required String mediaSourceId,
    required String playSessionId,
    required int positionTicks,
    bool isPaused = false,
  }) {
    return _apiFor(auth).reportPlaybackStart(
      token: auth.token,
      baseUrl: auth.baseUrl,
      deviceId: deviceId,
      itemId: itemId,
      mediaSourceId: mediaSourceId,
      playSessionId: playSessionId,
      positionTicks: positionTicks,
      isPaused: isPaused,
      userId: auth.userId,
    );
  }

  @override
  Future<void> reportPlaybackProgress(
    ServerAuthSession auth, {
    required String itemId,
    required String mediaSourceId,
    required String playSessionId,
    required int positionTicks,
    bool isPaused = false,
  }) {
    return _apiFor(auth).reportPlaybackProgress(
      token: auth.token,
      baseUrl: auth.baseUrl,
      deviceId: deviceId,
      itemId: itemId,
      mediaSourceId: mediaSourceId,
      playSessionId: playSessionId,
      positionTicks: positionTicks,
      isPaused: isPaused,
      userId: auth.userId,
    );
  }

  @override
  Future<void> reportPlaybackStopped(
    ServerAuthSession auth, {
    required String itemId,
    required String mediaSourceId,
    required String playSessionId,
    required int positionTicks,
  }) {
    return _apiFor(auth).reportPlaybackStopped(
      token: auth.token,
      baseUrl: auth.baseUrl,
      deviceId: deviceId,
      itemId: itemId,
      mediaSourceId: mediaSourceId,
      playSessionId: playSessionId,
      positionTicks: positionTicks,
      userId: auth.userId,
    );
  }

  @override
  Future<void> updatePlaybackPosition(
    ServerAuthSession auth, {
    required String itemId,
    required int positionTicks,
    bool? played,
  }) {
    return _apiFor(auth).updatePlaybackPosition(
      token: auth.token,
      baseUrl: auth.baseUrl,
      userId: auth.userId,
      itemId: itemId,
      positionTicks: positionTicks,
      played: played,
    );
  }
}
