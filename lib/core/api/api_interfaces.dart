// ============================================================
// API 抽象接口层 - 供后端开发人员接入
//
// 使用说明：
// 1. 实现这些接口的具体类（如 EmbyApiClient）
// 2. 在 providers 中替换为实际实现
// 3. UI层只依赖这些抽象接口，不依赖具体实现
// ============================================================

// ==================== 认证相关 ====================

abstract class AuthApi {
  /// 用户登录
  /// POST /Users/AuthenticateByName
  Future<AuthResult> login(
      {required String username, required String password});

  /// 登出
  /// POST /Sessions/Logout
  Future<void> logout();

  /// 获取当前用户信息
  /// GET /Users/Me
  Future<User> getCurrentUser();

  /// 刷新Token（如支持）
  Future<AuthResult> refreshToken();
}

class AuthResult {
  final String accessToken;
  final String userId;
  final String serverId;
  final User user;

  AuthResult({
    required this.accessToken,
    required this.userId,
    required this.serverId,
    required this.user,
  });
}

// ==================== 用户相关 ====================

abstract class UserApi {
  /// 获取用户资料
  Future<User> getUser(String userId);

  /// 标记为已播放
  Future<void> markAsPlayed(String itemId);

  /// 标记为未播放
  Future<void> markAsUnplayed(String itemId);
}

class User {
  final String id;
  final String name;
  final String? primaryImageTag;
  final bool? hasPassword;
  final List<String>? configuration;

  /// 服务端为该用户配置的权限策略（含是否允许下载）。
  final UserPolicy? policy;

  User({
    required this.id,
    required this.name,
    this.primaryImageTag,
    this.hasPassword,
    this.configuration,
    this.policy,
  });
}

/// 用户权限策略（取自 Emby/Jellyfin 用户对象的 `Policy` 字段）。
class UserPolicy {
  final bool isAdministrator;

  /// 是否允许下载内容（Emby/Jellyfin：`EnableContentDownloading`）。
  final bool enableContentDownloading;

  /// 是否允许同步/离线（部分服务端用 `EnableContentDownloading` 之外的 `EnableSyncTranscoding`/`EnableDownloading`）。
  final bool enableDownloading;

  const UserPolicy({
    this.isAdministrator = false,
    this.enableContentDownloading = false,
    this.enableDownloading = false,
  });

  /// 综合判断该用户是否被服务端许可下载。
  bool get canDownload =>
      isAdministrator || enableContentDownloading || enableDownloading;
}

// ==================== 服务器相关 ====================

abstract class ServerApi {
  /// 获取公开服务器信息（无需认证）
  /// GET /System/Info/Public
  Future<ServerInfo> getPublicInfo(String baseUrl);

  /// 获取系统信息
  /// GET /System/Info
  Future<ServerInfo> getSystemInfo();

  /// 测试连接
  Future<bool> testConnection(String baseUrl);
}

class ServerInfo {
  final String id;
  final String serverName;
  final String version;
  final String? productName;
  final String? operatingSystem;

  ServerInfo({
    required this.id,
    required this.serverName,
    required this.version,
    this.productName,
    this.operatingSystem,
  });
}

// ==================== 首页相关 ====================

abstract class HomeApi {
  /// 获取继续观看列表
  /// GET /Users/{UserId}/Items/Resume
  Future<List<MediaItem>> getResumeItems();

  /// 获取下一集
  /// GET /Shows/NextUp
  Future<List<MediaItem>> getNextUp();

  /// 获取媒体库列表
  /// GET /Users/{userId}/Views
  Future<List<Library>> getLibraries();

  /// 获取媒体数量统计
  /// GET /Items/Counts
  Future<MediaCounts> getMediaCounts();

  /// 获取最新添加
  /// GET /Users/{UserId}/Items/Latest
  Future<List<MediaItem>> getLatestItems(String libraryId, {int limit = 20});

  /// 获取随机推荐
  Future<List<MediaItem>> getRandomRecommendations({int limit = 8});
}

class MediaCounts {
  final int movieCount;
  final int episodeCount;
  final int? itemCount;

  const MediaCounts({
    required this.movieCount,
    required this.episodeCount,
    this.itemCount,
  });

  int get totalCount => movieCount + episodeCount;
}

// ==================== 媒体库相关 ====================

abstract class LibraryApi {
  /// 获取媒体库内容
  /// GET /Users/{UserId}/Items
  Future<List<MediaItem>> getLibraryItems({
    required String libraryId,
    String? sortBy,
    String? sortOrder,
    int startIndex = 0,
    int limit = 50,
  });

  /// 获取筛选条件
  /// GET /Items/Filters
  Future<Filters> getFilters(String libraryId);
}

class Filters {
  final List<String> genres;
  final List<String> years;
  final List<String> officialRatings;

  Filters({
    required this.genres,
    required this.years,
    required this.officialRatings,
  });
}

// ==================== 媒体项相关 ====================

abstract class MediaApi {
  /// 获取单项详情
  /// GET /Items/{Id}
  Future<MediaItem> getItemDetails(String itemId);

  /// 获取相似推荐
  /// GET /Items/{Id}/Similar
  Future<List<MediaItem>> getSimilarItems(String itemId);

  /// 获取季列表
  /// GET /Shows/{Id}/Seasons
  Future<List<Season>> getSeasons(String seriesId);

  /// 获取集列表
  /// GET /Shows/{Id}/Episodes
  Future<List<Episode>> getEpisodes(String seriesId, {String? seasonId});

  /// 获取人物参演
  /// GET /Persons/{Name}/Items
  Future<List<Person>> getPersonItems(String personName);
}

class MediaItem {
  final String id;
  final String name;
  final String type; // 'Movie', 'Series', 'Episode', 'Season'
  final Map<String, String>? providerIds;
  final String? presentationUniqueKey;
  final String? path;
  final String? overview;
  final String? primaryImageTag;
  final String? thumbImageTag;
  final String? backdropImageTag;
  // 背景图所属的项目 ID：可能是自身，也可能是父级/剧集（剧集/季无自身背景时回退父级）。
  // 取背景图 URL 时用它而不是 id，否则会 404 退回封面图。
  final String? backdropItemId;
  final double? communityRating;
  final String? officialRating;
  final DateTime? premiereDate;
  final int? runTimeTicks;
  final int? productionYear;
  final List<String>? genres;
  final List<String>? tags;
  final UserData? userData;
  final String? seriesName;
  final int? indexNumber;
  final int? parentIndexNumber;
  final String? seriesId;
  final String? seasonId;
  final String? parentThumbItemId;
  final String? parentThumbImageTag;
  final String? parentPrimaryImageItemId;
  final String? parentPrimaryImageTag;
  final String? seriesThumbImageTag;
  final String? seriesPrimaryImageTag;
  final String? mediaType; // 'Video', 'Audio'
  final String? parentId; // 父级ID（可能是媒体库或文件夹）
  final int? childCount; // 子项数量（剧集的总集数）
  final int? recursiveItemCount; // 递归子项数量（剧集总集数）
  final List<Person>? people;
  final bool? canDownload;
  final List<String>? remoteTrailers;
  final String? logoItemId; // 有 Logo 的项目 ID（自身或父级）
  final String? logoImageTag; // Logo 缓存 tag

  /// 聚合搜索专用的客户端侧来源标记：该条结果来自哪台服务器（ServerConfig.id）。
  ///
  /// 不参与 JSON 解析、不来自服务端——仅在跨服务器聚合搜索时由本地写入，用于让
  /// 封面/海报用正确服务器的 base+token 解析、点击时先切到来源服务器再打开。
  /// 普通（单服务器）场景保持 null，行为与原来完全一致。
  String? sourceServerId;

  MediaItem({
    required this.id,
    required this.name,
    required this.type,
    this.providerIds,
    this.presentationUniqueKey,
    this.path,
    this.overview,
    this.primaryImageTag,
    this.thumbImageTag,
    this.backdropImageTag,
    this.backdropItemId,
    this.communityRating,
    this.officialRating,
    this.premiereDate,
    this.runTimeTicks,
    this.productionYear,
    this.genres,
    this.tags,
    this.userData,
    this.seriesName,
    this.indexNumber,
    this.parentIndexNumber,
    this.seriesId,
    this.seasonId,
    this.parentThumbItemId,
    this.parentThumbImageTag,
    this.parentPrimaryImageItemId,
    this.parentPrimaryImageTag,
    this.seriesThumbImageTag,
    this.seriesPrimaryImageTag,
    this.mediaType,
    this.parentId,
    this.childCount,
    this.recursiveItemCount,
    this.people,
    this.canDownload,
    this.remoteTrailers,
    this.logoItemId,
    this.logoImageTag,
  });

  String? get formattedRuntime {
    if (runTimeTicks == null) return null;
    final minutes = (runTimeTicks! / 10000000 / 60).round();
    final hours = minutes ~/ 60;
    final mins = minutes % 60;
    if (hours > 0) {
      return '${hours}h ${mins}m';
    }
    return '${mins}m';
  }

  bool get isWatched => userData?.played ?? false;
  String? get tmdbId {
    final ids = providerIds;
    if (ids == null || ids.isEmpty) return null;
    for (final entry in ids.entries) {
      if (entry.key.toLowerCase() == 'tmdb' && entry.value.isNotEmpty) {
        return entry.value;
      }
    }
    return null;
  }

  String? get imdbId {
    final ids = providerIds;
    if (ids == null || ids.isEmpty) return null;
    for (final entry in ids.entries) {
      if (entry.key.toLowerCase() == 'imdb' && entry.value.isNotEmpty) {
        return entry.value;
      }
    }
    return null;
  }

  double? get progress =>
      userData?.playbackPositionTicks != null && runTimeTicks != null
          ? userData!.playbackPositionTicks! / runTimeTicks!
          : null;
}

class UserData {
  final double? playbackPositionTicks;
  final bool? played;
  final bool? isFavorite;
  final double? playCount;

  UserData({
    this.playbackPositionTicks,
    this.played,
    this.isFavorite,
    this.playCount,
  });
}

class Season {
  final String id;
  final String name;
  final int? indexNumber;
  final String? primaryImageTag;
  final String? thumbImageTag;
  final String seriesId;
  final String? seriesPrimaryImageTag;
  final String? seriesThumbImageTag;

  Season({
    required this.id,
    required this.name,
    this.indexNumber,
    this.primaryImageTag,
    this.thumbImageTag,
    required this.seriesId,
    this.seriesPrimaryImageTag,
    this.seriesThumbImageTag,
  });
}

class Episode {
  final String id;
  final String name;
  final int? indexNumber;
  final String? primaryImageTag;
  final String? thumbImageTag;
  final String seriesId;
  final String seasonId;
  final String? parentThumbItemId;
  final String? parentThumbImageTag;
  final String? parentPrimaryImageItemId;
  final String? parentPrimaryImageTag;
  final String? seriesThumbImageTag;
  final String? seriesPrimaryImageTag;
  final int? runTimeTicks;
  final UserData? userData;
  final String? overview;
  final List<String>? remoteTrailers;

  Episode({
    required this.id,
    required this.name,
    this.indexNumber,
    this.primaryImageTag,
    this.thumbImageTag,
    required this.seriesId,
    required this.seasonId,
    this.parentThumbItemId,
    this.parentThumbImageTag,
    this.parentPrimaryImageItemId,
    this.parentPrimaryImageTag,
    this.seriesThumbImageTag,
    this.seriesPrimaryImageTag,
    this.runTimeTicks,
    this.userData,
    this.overview,
    this.remoteTrailers,
  });

  String? get formattedRuntime {
    if (runTimeTicks == null) return null;
    final minutes = (runTimeTicks! / 10000000 / 60).round();
    final hours = minutes ~/ 60;
    final mins = minutes % 60;
    if (hours > 0) {
      return '${hours}h ${mins}m';
    }
    return '${mins}m';
  }
}

class Person {
  final String id;
  final String name;
  final String? primaryImageTag;
  final String? role;
  final String? type; // 'Actor', 'Director', etc.

  Person({
    required this.id,
    required this.name,
    this.primaryImageTag,
    this.role,
    this.type,
  });
}

class Library {
  final String id;
  final String name;
  final String? primaryImageTag;
  final String collectionType; // 'movies', 'tvshows', etc.

  Library({
    required this.id,
    required this.name,
    this.primaryImageTag,
    required this.collectionType,
  });
}

// ==================== 搜索相关 ====================

abstract class SearchApi {
  /// 搜索建议
  /// GET /Search/Hints
  Future<List<MediaItem>> getSearchHints(String query);

  /// 搜索
  /// GET /Users/{UserId}/Items?SearchTerm=...
  Future<List<MediaItem>> search(String query, {bool recursive = true});

  /// 聚合搜索（跨服务器）
  Future<Map<String, List<MediaItem>>> searchAggregate(String query);
}

// ==================== 播放相关 ====================

abstract class PlaybackApi {
  /// 获取播放信息
  /// POST /Items/{Id}/PlaybackInfo
  Future<PlaybackInfo> getPlaybackInfo(String itemId);

  /// 获取视频流
  /// GET /Videos/{Id}/stream
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
  });

  /// 获取字幕流URL
  /// GET /Videos/{itemId}/{mediaSourceId}/Subtitles/{index}/Stream.{codec}
  String getSubtitleStreamUrl(
      String itemId, String mediaSourceId, int index, String codec);

  /// 获取离线下载地址（原始文件，服务端按下载权限放行）。
  /// GET /Items/{Id}/Download
  String getDownloadUrl(String itemId, {String? mediaSourceId});

  /// 播放开始上报
  /// POST /Sessions/Playing
  Future<void> reportPlaybackStart(PlaybackStartInfo info);

  /// 播放进度上报
  /// POST /Sessions/Playing/Progress
  Future<void> reportPlaybackProgress(PlaybackProgressInfo info);

  /// 播放停止上报
  /// POST /Sessions/Playing/Stopped
  Future<void> reportPlaybackStopped(PlaybackStopInfo info);
}

class PlaybackInfo {
  final String itemId;
  final List<MediaSource> mediaSources;
  final List<PlaybackDeviceProfile>? deviceProfiles;

  PlaybackInfo({
    required this.itemId,
    required this.mediaSources,
    this.deviceProfiles,
  });
}

class MediaSource {
  final String id;
  final String? name;
  final String? path;
  final String? container;
  final int? size;
  final int? runTimeTicks;
  final List<MediaStream> mediaStreams;

  /// 媒体源协议（Emby `Protocol`）：`File` / `Http` 等。STRM 远端源通常为 `Http`。
  final String? protocol;

  /// 是否为远端源（Emby `IsRemote`）。STRM 指向外链时为 true。
  final bool? isRemote;

  MediaSource({
    required this.id,
    this.name,
    this.path,
    this.container,
    this.size,
    this.runTimeTicks,
    required this.mediaStreams,
    this.protocol,
    this.isRemote,
  });

  /// 代表该媒体源画质的视频流：取**分辨率最高**的一条，而非第一条。
  ///
  /// 关键修复：以前用 `firstOrNull` 取第一条视频流，部分媒体源把低清流排在前面，
  /// 导致 4K 资源被显示成 1080p。这里按宽/高挑最大的一条，画质标签才准。
  MediaStream? get primaryVideoStream {
    MediaStream? best;
    for (final s in mediaStreams) {
      if (!s.isVideo) continue;
      if (best == null) {
        best = s;
        continue;
      }
      final bestPx = (best.width ?? 0) * (best.height ?? 1);
      final curPx = (s.width ?? 0) * (s.height ?? 1);
      if (curPx > bestPx) best = s;
    }
    return best;
  }

  /// 画质档位标签（如 "4K"/"1080p"），取自 [primaryVideoStream]。
  String get qualityLabel => primaryVideoStream?.resolution ?? '';
}

class MediaStream {
  final int index;
  final String type; // 'Video', 'Audio', 'Subtitle'
  final String? codec;
  final String? language;
  final String? title;
  final bool? isDefault;
  final bool? isExternal;
  final String? displayTitle;
  final String? path;
  final String? deliveryUrl;
  final String? deliveryMethod;
  final bool? isExternalUrl;
  final String? videoCodec;
  final int? width;
  final int? height;
  final int? channels;
  final int? bitRate;
  final String? videoRange; // 'SDR' / 'HDR'
  final String? videoRangeType; // 'SDR' / 'HDR10' / 'HLG' / 'DOVI' / 'DOVIWithHDR10' ...

  MediaStream({
    required this.index,
    required this.type,
    this.codec,
    this.language,
    this.title,
    this.isDefault,
    this.isExternal,
    this.displayTitle,
    this.path,
    this.deliveryUrl,
    this.deliveryMethod,
    this.isExternalUrl,
    this.videoCodec,
    this.width,
    this.height,
    this.channels,
    this.bitRate,
    this.videoRange,
    this.videoRangeType,
  });

  bool get isVideo => type == 'Video';
  bool get isAudio => type == 'Audio';
  bool get isSubtitle => type == 'Subtitle';

  /// 是否为杜比视界(Dolby Vision)视频流。
  ///
  /// 多信号判定：① Emby 的 VideoRangeType 含 DOVI；② 编解码标签为 DV 专属
  /// (dvhe/dvh1/dav1)；③ 标题/显示名含 "dolby vision"/"dovi"。任一命中即认定。
  bool get isDolbyVision {
    final rt = (videoRangeType ?? '').toUpperCase();
    if (rt.contains('DOVI') || rt.contains('DOLBYVISION')) return true;
    final tags = '${codec ?? ''} ${videoCodec ?? ''}'.toLowerCase();
    if (tags.contains('dvhe') ||
        tags.contains('dvh1') ||
        tags.contains('dav1')) {
      return true;
    }
    final text = '${displayTitle ?? ''} ${title ?? ''}'.toLowerCase();
    if (text.contains('dolby vision') || text.contains('dovi')) return true;
    return false;
  }

  String readableLabel({List<MediaStream>? siblings}) {
    if (displayTitle != null && displayTitle!.isNotEmpty) return displayTitle!;
    if (title != null && title!.isNotEmpty) return title!;
    final lang = _languageName(language);
    final codecStr = codec?.toUpperCase() ?? '';
    final ext = isExternal == true ? '外挂' : '内封';
    if (siblings != null && siblings.length > 1) {
      final pos = siblings.indexWhere((s) => s.index == index);
      if (pos >= 0) {
        final label = codecStr.isNotEmpty
            ? '$lang $codecStr #${pos + 1} ($ext)'
            : '$lang #${pos + 1} ($ext)';
        return label;
      }
    }
    if (codecStr.isNotEmpty) return '$lang $codecStr ($ext)';
    return '$lang ($ext)';
  }

  static String _languageName(String? code) {
    if (code == null || code.isEmpty) return '未知';
    const map = {
      'chi': '中文',
      'zh': '中文',
      'chs': '简体中文',
      'cht': '繁体中文',
      'zho': '中文',
      'eng': '英语',
      'en': '英语',
      'jpn': '日语',
      'ja': '日语',
      'kor': '韩语',
      'ko': '韩语',
      'fre': '法语',
      'fra': '法语',
      'ger': '德语',
      'deu': '德语',
      'spa': '西班牙语',
      'por': '葡萄牙语',
      'rus': '俄语',
      'ita': '意大利语',
      'tha': '泰语',
      'vie': '越南语',
      'und': '未知',
    };
    return map[code.toLowerCase()] ?? code;
  }

  /// 分辨率档位标签。
  ///
  /// 关键修复：以前只看 `height` 分档，2.39:1 的 4K 电影（3840×1608）高度只有
  /// 1608，会被错判成 "1080p"。改为**以宽度为主**分档（宽度不受裁切比例影响），
  /// 高度作兜底，4K 宽屏电影才能正确显示为 4K。
  String get resolution {
    final w = width ?? 0;
    final h = height ?? 0;
    if (w <= 0 && h <= 0) return '';
    if (w >= 7600 || h >= 4300) return '8K';
    if (w >= 3600 || h >= 2000) return '4K';
    if (w >= 1800 || h >= 1000) return '1080p';
    if (w >= 1200 || h >= 700) return '720p';
    if (w >= 640 || h >= 480) return '480p';
    if (h > 0) return '${h}p';
    return '';
  }

  /// 规范化的视频编码名（HEVC / H.264 / AV1 …）。
  String get videoCodecLabel {
    final c = (videoCodec ?? codec ?? '').toLowerCase();
    if (c.isEmpty) return '';
    if (c.contains('hevc') || c.contains('h265') || c.contains('h.265')) {
      return 'HEVC';
    }
    if (c.contains('avc') || c.contains('h264') || c.contains('h.264')) {
      return 'H.264';
    }
    if (c.contains('av1')) return 'AV1';
    if (c.contains('vp9')) return 'VP9';
    if (c.contains('vp8')) return 'VP8';
    if (c.contains('mpeg4')) return 'MPEG-4';
    if (c.contains('mpeg2')) return 'MPEG-2';
    if (c.contains('vc1') || c.contains('vc-1')) return 'VC-1';
    return c.toUpperCase();
  }

  /// HDR/动态范围标签：Dolby Vision / HDR10+ / HDR10 / HLG / HDR / 空(SDR)。
  String get videoRangeLabel {
    if (isDolbyVision) return 'Dolby Vision';
    final rt = '${videoRangeType ?? ''} ${videoRange ?? ''}'.toUpperCase();
    if (rt.contains('HDR10PLUS') || rt.contains('HDR10+')) return 'HDR10+';
    if (rt.contains('HDR10')) return 'HDR10';
    if (rt.contains('HLG')) return 'HLG';
    if (rt.contains('PQ')) return 'HDR';
    if (rt.contains('HDR')) return 'HDR';
    return '';
  }

  /// 「动态范围 + 编码」组合标签，如 "Dolby Vision HEVC" / "HDR10 HEVC" / "H.264"。
  String get videoFormatLabel {
    final range = videoRangeLabel;
    final codecName = videoCodecLabel;
    if (range.isNotEmpty && codecName.isNotEmpty) return '$range $codecName';
    if (range.isNotEmpty) return range;
    return codecName;
  }
}

class PlaybackDeviceProfile {
  // 设备能力配置
  final String name;
  final int? maxStreamingBitrate;

  PlaybackDeviceProfile({
    required this.name,
    this.maxStreamingBitrate,
  });
}

class PlaybackStartInfo {
  final String itemId;
  final String mediaSourceId;
  final String? audioStreamIndex;
  final String? subtitleStreamIndex;
  final String? playMethod;

  PlaybackStartInfo({
    required this.itemId,
    required this.mediaSourceId,
    this.audioStreamIndex,
    this.subtitleStreamIndex,
    this.playMethod,
  });
}

class PlaybackProgressInfo {
  final String itemId;
  final String mediaSourceId;
  final int positionTicks;
  final bool isPaused;
  final bool isMuted;
  final double volumeLevel;

  PlaybackProgressInfo({
    required this.itemId,
    required this.mediaSourceId,
    required this.positionTicks,
    this.isPaused = false,
    this.isMuted = false,
    this.volumeLevel = 1.0,
  });
}

class PlaybackStopInfo {
  final String itemId;
  final String mediaSourceId;
  final int positionTicks;

  PlaybackStopInfo({
    required this.itemId,
    required this.mediaSourceId,
    required this.positionTicks,
  });
}

// ==================== 收藏相关 ====================

abstract class FavoriteApi {
  /// 获取收藏列表
  /// GET /Users/{UserId}/Items?Filters=IsFavorite
  Future<List<MediaItem>> getFavorites();

  /// 添加到收藏
  /// POST /Users/{UserId}/FavoriteItems/{Id}
  Future<void> addFavorite(String itemId);

  /// 取消收藏
  /// DELETE /Users/{UserId}/FavoriteItems/{Id}
  Future<void> removeFavorite(String itemId);
}

// ==================== 会话相关 ====================

abstract class SessionApi {
  /// 获取会话列表
  /// GET /Sessions
  Future<List<Session>> getSessions();
}

class Session {
  final String id;
  final String? userName;
  final String? client;
  final String? deviceName;
  final bool? isNowPlaying;
  final NowPlayingItem? nowPlayingItem;

  Session({
    required this.id,
    this.userName,
    this.client,
    this.deviceName,
    this.isNowPlaying,
    this.nowPlayingItem,
  });
}

class NowPlayingItem {
  final String id;
  final String name;
  final String? seriesName;
  final int? runTimeTicks;
  final int? playbackPositionTicks;

  NowPlayingItem({
    required this.id,
    required this.name,
    this.seriesName,
    this.runTimeTicks,
    this.playbackPositionTicks,
  });
}

// ==================== 图片相关 ====================

abstract class ImageApi {
  /// 获取图片URL
  String getImageUrl({
    required String itemId,
    String? imageTag,
    String imageType = 'Primary',
    int? maxWidth,
    int? maxHeight,
    double quality = 90,
    String? format,
  });

  /// 获取主封面
  String getPrimaryImageUrl(String itemId,
      {String? tag, int? maxWidth, String? format});

  /// 获取缩略图/横图
  String getThumbImageUrl(String itemId,
      {String? tag, int? maxWidth, String? format});

  /// 获取背景图
  String getBackdropImageUrl(String itemId,
      {String? tag, int? maxWidth, String? format});

  /// 获取 Logo 图片（艺术字标题）
  String? getLogoImageUrl(String itemId, {String? tag, int? maxWidth});
}

// ==================== 弹幕相关 ====================

class DanmakuItem {
  final double time;
  final String text;
  final int type; // 1=滚动, 4=底部, 5=顶部 (弹弹Play标准)
  final int color; // 十进制RGB (16777215=白色)
  final double size;
  final String? source; // 弹幕来源标识
  final String? cid; // 弹幕唯一ID
  final String? userId; // 用户ID/Hash
  final int count; // 合并计数（去重后同一弹幕出现的次数）

  DanmakuItem({
    required this.time,
    required this.text,
    this.type = 1,
    this.color = 16777215,
    this.size = 25,
    this.source,
    this.cid,
    this.userId,
    this.count = 1,
  });

  Map<String, dynamic> toJson() => {
        't': time,
        'm': text,
        'y': type,
        'c': color,
        's': size,
        if (source != null) 'src': source,
        if (cid != null) 'id': cid,
        if (userId != null) 'u': userId,
      };

  factory DanmakuItem.fromJson(Map<String, dynamic> j) => DanmakuItem(
        time: (j['t'] as num?)?.toDouble() ?? 0,
        text: j['m'] as String? ?? '',
        type: (j['y'] as num?)?.toInt() ?? 1,
        color: (j['c'] as num?)?.toInt() ?? 16777215,
        size: (j['s'] as num?)?.toDouble() ?? 25,
        source: j['src'] as String?,
        cid: j['id'] as String?,
        userId: j['u'] as String?,
      );
}

class DanmakuAnime {
  final String animeId;
  final String animeTitle;
  final String? bangumiId;
  final String? type;
  final String? typeDescription;
  final String? imageUrl;
  final int? year;
  final int? episodeCount;
  final List<DanmakuEpisode>? episodes;
  /// 弹弹play 作品详情里的「Bangumi.tv 页面地址」，形如 https://bgm.tv/subject/123。
  /// 用于反查 bgm.tv subject id（作品详情接口才会返回）。
  final String? bangumiUrl;
  /// 该结果来自哪个弹幕源（并行分源展示时用户挑选后，回此源取评论）。
  final String? sourceId;
  final String? sourceName;

  DanmakuAnime({
    required this.animeId,
    required this.animeTitle,
    this.bangumiId,
    this.type,
    this.typeDescription,
    this.imageUrl,
    this.year,
    this.episodeCount,
    this.episodes,
    this.bangumiUrl,
    this.sourceId,
    this.sourceName,
  });

  DanmakuAnime copyWith({
    String? sourceId,
    String? sourceName,
    List<DanmakuEpisode>? episodes,
  }) {
    return DanmakuAnime(
      animeId: animeId,
      animeTitle: animeTitle,
      bangumiId: bangumiId,
      type: type,
      typeDescription: typeDescription,
      imageUrl: imageUrl,
      year: year,
      episodeCount: episodeCount,
      episodes: episodes ?? this.episodes,
      bangumiUrl: bangumiUrl,
      sourceId: sourceId ?? this.sourceId,
      sourceName: sourceName ?? this.sourceName,
    );
  }
}

class DanmakuEpisode {
  final String episodeId;
  final String episodeTitle;
  final String? episodeNumber;
  final String? sourceId;
  final String? sourceName;

  DanmakuEpisode({
    required this.episodeId,
    required this.episodeTitle,
    this.episodeNumber,
    this.sourceId,
    this.sourceName,
  });

  DanmakuEpisode copyWith({String? sourceId, String? sourceName}) {
    return DanmakuEpisode(
      episodeId: episodeId,
      episodeTitle: episodeTitle,
      episodeNumber: episodeNumber,
      sourceId: sourceId ?? this.sourceId,
      sourceName: sourceName ?? this.sourceName,
    );
  }
}

class DanmakuMatchResult {
  final bool isMatched;
  final List<DanmakuMatchItem> matches;

  DanmakuMatchResult({
    required this.isMatched,
    required this.matches,
  });
}

class DanmakuMatchItem {
  final String episodeId;
  final String animeId;
  final String animeTitle;
  final String episodeTitle;
  final String? type;
  final String? typeDescription;
  final int? shift;
  final String? sourceId;
  final String? sourceName;

  DanmakuMatchItem({
    required this.episodeId,
    required this.animeId,
    required this.animeTitle,
    required this.episodeTitle,
    this.type,
    this.typeDescription,
    this.shift,
    this.sourceId,
    this.sourceName,
  });

  DanmakuMatchItem copyWith({String? sourceId, String? sourceName}) {
    return DanmakuMatchItem(
      episodeId: episodeId,
      animeId: animeId,
      animeTitle: animeTitle,
      episodeTitle: episodeTitle,
      type: type,
      typeDescription: typeDescription,
      shift: shift,
      sourceId: sourceId ?? this.sourceId,
      sourceName: sourceName ?? this.sourceName,
    );
  }
}

class DanmakuSearchResult {
  final List<DanmakuAnime> animes;
  final bool hasMore;

  DanmakuSearchResult({
    required this.animes,
    this.hasMore = false,
  });
}

// ==================== API工厂 ====================

/// API工厂接口 - 每个服务器实例一个
abstract class ApiClientFactory {
  AuthApi get auth;
  UserApi get user;
  ServerApi get server;
  HomeApi get home;
  LibraryApi get library;
  MediaApi get media;
  SearchApi get search;
  PlaybackApi get playback;
  FavoriteApi get favorite;
  SessionApi get session;
  ImageApi get image;

  /// 切换活跃线路
  void switchLine(String lineUrl);

  /// 获取当前线路
  String get currentLine;

  /// 设置认证Token
  void setAuthToken(String token);

  /// 清除认证
  void clearAuth();
}
