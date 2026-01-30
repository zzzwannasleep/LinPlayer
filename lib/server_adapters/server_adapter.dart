import '../services/emby_api.dart';
import '../state/media_server_type.dart';

class ServerAuthSession {
  const ServerAuthSession({
    required this.token,
    required this.baseUrl,
    required this.userId,
    required this.apiPrefix,
    required this.preferredScheme,
  });

  final String token;
  final String baseUrl;
  final String userId;
  final String apiPrefix;
  final String preferredScheme;
}

abstract class MediaServerAdapter {
  MediaServerType get serverType;
  String get deviceId;

  Future<ServerAuthSession> authenticate({
    required String hostOrUrl,
    required String scheme,
    String? port,
    required String username,
    required String password,
  });

  Future<String?> fetchServerName(ServerAuthSession auth);

  Future<List<DomainInfo>> fetchDomains(
    ServerAuthSession auth, {
    required bool allowFailure,
  });

  Future<List<LibraryInfo>> fetchLibraries(ServerAuthSession auth);

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
  });

  Future<PagedResult<MediaItem>> fetchContinueWatching(
    ServerAuthSession auth, {
    int limit = 30,
  });

  Future<MediaItem> fetchItemDetail(
    ServerAuthSession auth, {
    required String itemId,
  });

  Future<PagedResult<MediaItem>> fetchSeasons(
    ServerAuthSession auth, {
    required String seriesId,
  });

  Future<PagedResult<MediaItem>> fetchEpisodes(
    ServerAuthSession auth, {
    required String seasonId,
  });

  Future<PagedResult<MediaItem>> fetchSimilar(
    ServerAuthSession auth, {
    required String itemId,
    int limit = 10,
  });

  Future<PlaybackInfoResult> fetchPlaybackInfo(
    ServerAuthSession auth, {
    required String itemId,
    bool exoPlayer = false,
  });

  Future<List<ChapterInfo>> fetchChapters(
    ServerAuthSession auth, {
    required String itemId,
  });

  Future<void> reportPlaybackStart(
    ServerAuthSession auth, {
    required String itemId,
    required String mediaSourceId,
    required String playSessionId,
    required int positionTicks,
    bool isPaused = false,
  });

  Future<void> reportPlaybackProgress(
    ServerAuthSession auth, {
    required String itemId,
    required String mediaSourceId,
    required String playSessionId,
    required int positionTicks,
    bool isPaused = false,
  });

  Future<void> reportPlaybackStopped(
    ServerAuthSession auth, {
    required String itemId,
    required String mediaSourceId,
    required String playSessionId,
    required int positionTicks,
  });

  Future<void> updatePlaybackPosition(
    ServerAuthSession auth, {
    required String itemId,
    required int positionTicks,
    bool? played,
  });
}
