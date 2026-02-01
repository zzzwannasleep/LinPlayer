import 'package:lin_player_core/state/media_server_type.dart';
import 'package:lin_player_server_api/services/emby_api.dart';

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

  /// Headers suitable for streaming (mpv/exo) or other authenticated requests.
  ///
  /// For emby-like servers this includes `X-Emby-Token` and the Emby/Jellyfin
  /// Authorization headers.
  Map<String, String> buildStreamHeaders(ServerAuthSession auth);

  String imageUrl(
    ServerAuthSession auth, {
    required String itemId,
    String imageType = 'Primary',
    int? maxWidth,
  });

  String personImageUrl(
    ServerAuthSession auth, {
    required String personId,
    int? maxWidth,
  });

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
