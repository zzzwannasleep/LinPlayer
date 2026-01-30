import '../../state/media_server_type.dart';
import '../../services/emby_api.dart';
import '../server_adapter.dart';

class EmosServerAdapter implements MediaServerAdapter {
  EmosServerAdapter({required this.serverType, required this.deviceId});

  @override
  final MediaServerType serverType;

  @override
  final String deviceId;

  @override
  Future<ServerAuthSession> authenticate({
    required String hostOrUrl,
    required String scheme,
    String? port,
    required String username,
    required String password,
  }) {
    throw UnimplementedError('TODO: implement EmosServerAdapter.authenticate');
  }

  @override
  Future<String?> fetchServerName(ServerAuthSession auth) {
    throw UnimplementedError('TODO: implement EmosServerAdapter.fetchServerName');
  }

  @override
  Future<List<DomainInfo>> fetchDomains(
    ServerAuthSession auth, {
    required bool allowFailure,
  }) {
    throw UnimplementedError('TODO: implement EmosServerAdapter.fetchDomains');
  }

  @override
  Future<List<LibraryInfo>> fetchLibraries(ServerAuthSession auth) {
    throw UnimplementedError('TODO: implement EmosServerAdapter.fetchLibraries');
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
    throw UnimplementedError('TODO: implement EmosServerAdapter.fetchItems');
  }

  @override
  Future<PagedResult<MediaItem>> fetchContinueWatching(
    ServerAuthSession auth, {
    int limit = 30,
  }) {
    throw UnimplementedError(
      'TODO: implement EmosServerAdapter.fetchContinueWatching',
    );
  }

  @override
  Future<MediaItem> fetchItemDetail(
    ServerAuthSession auth, {
    required String itemId,
  }) {
    throw UnimplementedError('TODO: implement EmosServerAdapter.fetchItemDetail');
  }

  @override
  Future<PagedResult<MediaItem>> fetchSeasons(
    ServerAuthSession auth, {
    required String seriesId,
  }) {
    throw UnimplementedError('TODO: implement EmosServerAdapter.fetchSeasons');
  }

  @override
  Future<PagedResult<MediaItem>> fetchEpisodes(
    ServerAuthSession auth, {
    required String seasonId,
  }) {
    throw UnimplementedError('TODO: implement EmosServerAdapter.fetchEpisodes');
  }

  @override
  Future<PagedResult<MediaItem>> fetchSimilar(
    ServerAuthSession auth, {
    required String itemId,
    int limit = 10,
  }) {
    throw UnimplementedError('TODO: implement EmosServerAdapter.fetchSimilar');
  }

  @override
  Future<PlaybackInfoResult> fetchPlaybackInfo(
    ServerAuthSession auth, {
    required String itemId,
    bool exoPlayer = false,
  }) {
    throw UnimplementedError('TODO: implement EmosServerAdapter.fetchPlaybackInfo');
  }

  @override
  Future<List<ChapterInfo>> fetchChapters(
    ServerAuthSession auth, {
    required String itemId,
  }) {
    throw UnimplementedError('TODO: implement EmosServerAdapter.fetchChapters');
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
    throw UnimplementedError('TODO: implement EmosServerAdapter.reportPlaybackStart');
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
    throw UnimplementedError(
      'TODO: implement EmosServerAdapter.reportPlaybackProgress',
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
    throw UnimplementedError(
      'TODO: implement EmosServerAdapter.reportPlaybackStopped',
    );
  }

  @override
  Future<void> updatePlaybackPosition(
    ServerAuthSession auth, {
    required String itemId,
    required int positionTicks,
    bool? played,
  }) {
    throw UnimplementedError(
      'TODO: implement EmosServerAdapter.updatePlaybackPosition',
    );
  }
}
