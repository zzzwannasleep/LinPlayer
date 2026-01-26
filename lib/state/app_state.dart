import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../services/backup_crypto.dart';
import '../services/emby_api.dart';
import '../services/webdav_api.dart';
import 'anime4k_preferences.dart';
import 'danmaku_preferences.dart';
import 'interaction_preferences.dart';
import 'local_playback_handoff.dart';
import 'media_server_type.dart';
import 'preferences.dart';
import 'server_profile.dart';

enum BackupServerSecretMode {
  token,
  password,
}

BackupServerSecretMode backupServerSecretModeFromId(String? id) {
  switch (id) {
    case 'password':
      return BackupServerSecretMode.password;
    case 'token':
    default:
      return BackupServerSecretMode.token;
  }
}

extension BackupServerSecretModeX on BackupServerSecretMode {
  String get id {
    switch (this) {
      case BackupServerSecretMode.token:
        return 'token';
      case BackupServerSecretMode.password:
        return 'password';
    }
  }
}

class BackupServerLogin {
  final String username;
  final String password;

  const BackupServerLogin({required this.username, required this.password});
}

typedef BackupServerAuthenticator = Future<AuthResult> Function({
  required String baseUrl,
  required String username,
  required String password,
  required String deviceId,
});

@immutable
class MediaStats {
  final int? movieCount;
  final int? seriesCount;
  final int? episodeCount;

  const MediaStats({
    required this.movieCount,
    required this.seriesCount,
    required this.episodeCount,
  });
}

class AppState extends ChangeNotifier {
  static const _kBackupType = 'lin_player_backup';
  static const _kBackupSchemaVersionV1 = 1;
  static const _kBackupSchemaVersionV2 = 2;
  static const _kServersKey = 'servers_v1';
  static const _kActiveServerIdKey = 'activeServerId_v1';
  static const _kThemeModeKey = 'themeMode_v1';
  static const _kUiScaleFactorKey = 'uiScaleFactor_v1';
  static const _kDynamicColorKey = 'dynamicColor_v1';
  static const _kCompactModeKey = 'compactMode_v1';
  static const _kUiTemplateKey = 'uiTemplate_v1';
  static const _kLegacyThemeTemplateKey = 'themeTemplate_v1';
  static const _kPreferHardwareDecodeKey = 'preferHardwareDecode_v1';
  static const _kPlayerCoreKey = 'playerCore_v1';
  static const _kPreferredAudioLangKey = 'preferredAudioLang_v1';
  static const _kPreferredSubtitleLangKey = 'preferredSubtitleLang_v1';
  static const _kPreferredVideoVersionKey = 'preferredVideoVersion_v1';
  static const _kAppIconIdKey = 'appIconId_v1';
  static const _kServerListLayoutKey = 'serverListLayout_v1';
  static const _kMpvCacheSizeMbKey = 'mpvCacheSizeMb_v1';
  static const _kPlaybackBufferPresetKey = 'playbackBufferPreset_v1';
  static const _kPlaybackBufferBackRatioKey = 'playbackBufferBackRatio_v1';
  static const _kFlushBufferOnSeekKey = 'flushBufferOnSeek_v1';
  static const _kUnlimitedStreamCacheKey = 'unlimitedStreamCache_v1';
  // Legacy key (<= 1.0.0): was used for "unlimited cover cache", but the intent
  // is actually "unlimited stream cache". We still read it for migration.
  static const _kLegacyUnlimitedCoverCacheKey = 'unlimitedCoverCache_v1';
  static const _kEnableBlurEffectsKey = 'enableBlurEffects_v1';
  static const _kExternalMpvPathKey = 'externalMpvPath_v1';
  static const _kAnime4kPresetKey = 'anime4kPreset_v1';
  static const _kDanmakuEnabledKey = 'danmakuEnabled_v1';
  static const _kDanmakuLoadModeKey = 'danmakuLoadMode_v1';
  static const _kDanmakuApiUrlsKey = 'danmakuApiUrls_v1';
  static const _kDanmakuAppIdKey = 'danmakuAppId_v1';
  static const _kDanmakuAppSecretKey = 'danmakuAppSecret_v1';
  static const _kDanmakuOpacityKey = 'danmakuOpacity_v1';
  static const _kDanmakuScaleKey = 'danmakuScale_v1';
  static const _kDanmakuSpeedKey = 'danmakuSpeed_v1';
  static const _kDanmakuBoldKey = 'danmakuBold_v1';
  static const _kDanmakuMaxLinesKey = 'danmakuMaxLines_v1';
  static const _kDanmakuTopMaxLinesKey = 'danmakuTopMaxLines_v1';
  static const _kDanmakuBottomMaxLinesKey = 'danmakuBottomMaxLines_v1';
  static const _kDanmakuRememberSelectedSourceKey =
      'danmakuRememberSelectedSource_v1';
  static const _kDanmakuLastSelectedSourceNameKey =
      'danmakuLastSelectedSourceName_v1';
  static const _kDanmakuMergeDuplicatesKey = 'danmakuMergeDuplicates_v1';
  static const _kDanmakuMergeRelatedKey = 'danmakuMergeRelated_v1';
  static const _kDanmakuPreventOverlapKey = 'danmakuPreventOverlap_v1';
  static const _kDanmakuBlockWordsKey = 'danmakuBlockWords_v1';
  static const _kDanmakuMatchModeKey = 'danmakuMatchMode_v1';
  static const _kDanmakuChConvertKey = 'danmakuChConvert_v1';
  static const _kDanmakuShowHeatmapKey = 'danmakuShowHeatmap_v1';
  static const _kServerIconLibraryUrlsKey = 'serverIconLibraryUrls_v1';
  static const _kShowHomeLibraryQuickAccessKey =
      'showHomeLibraryQuickAccess_v1';
  static const _kAutoUpdateEnabledKey = 'autoUpdateEnabled_v1';
  static const _kAutoUpdateLastCheckedAtMsKey = 'autoUpdateLastCheckedAtMs_v1';

  static const _kServerLibrariesCachePrefix = 'serverLibrariesCache_v1:';
  static const _kServerHomeCachePrefix = 'serverHomeCache_v1:';

  // Interaction & gestures (shared by MPV/Exo).
  static const _kGestureBrightnessKey = 'gestureBrightness_v1';
  static const _kGestureVolumeKey = 'gestureVolume_v1';
  static const _kGestureSeekKey = 'gestureSeek_v1';
  static const _kGestureLongPressSpeedKey = 'gestureLongPressSpeed_v1';
  static const _kLongPressSpeedMultiplierKey = 'longPressSpeedMultiplier_v1';
  static const _kLongPressSlideSpeedKey = 'longPressSlideSpeed_v1';
  static const _kDoubleTapLeftKey = 'doubleTapLeft_v1';
  static const _kDoubleTapCenterKey = 'doubleTapCenter_v1';
  static const _kDoubleTapRightKey = 'doubleTapRight_v1';
  static const _kReturnHomeBehaviorKey = 'returnHomeBehavior_v1';
  static const _kShowSystemTimeInControlsKey = 'showSystemTimeInControls_v1';
  static const _kShowBufferSpeedKey = 'showBufferSpeed_v1';
  static const _kShowBatteryInControlsKey = 'showBatteryInControls_v1';
  static const _kSeekBackwardSecondsKey = 'seekBackwardSeconds_v1';
  static const _kSeekForwardSecondsKey = 'seekForwardSeconds_v1';
  static const _kForceRemoteControlKeysKey = 'forceRemoteControlKeys_v1';

  final List<ServerProfile> _servers = [];
  String? _activeServerId;

  List<DomainInfo> _domains = [];
  List<LibraryInfo> _libraries = [];
  final Map<String, List<MediaItem>> _itemsCache = {};
  final Map<String, int> _itemsTotal = {};
  final Map<String, List<MediaItem>> _homeSections = {};
  List<MediaItem>? _randomRecommendations;
  Future<List<MediaItem>>? _randomRecommendationsInFlight;
  List<MediaItem>? _continueWatching;
  Future<List<MediaItem>>? _continueWatchingInFlight;
  late final String _deviceId = _randomId();
  ThemeMode _themeMode = ThemeMode.system;
  double _uiScaleFactor = 1.0;
  bool _useDynamicColor = true;
  bool _compactMode = _defaultCompactModeForPlatform();
  UiTemplate _uiTemplate = UiTemplate.candyGlass;
  bool _preferHardwareDecode = true;
  PlayerCore _playerCore = PlayerCore.mpv;
  String _preferredAudioLang = '';
  String _preferredSubtitleLang = '';
  VideoVersionPreference _preferredVideoVersion =
      VideoVersionPreference.defaultVersion;
  String _appIconId = 'default';
  ServerListLayout _serverListLayout = ServerListLayout.grid;
  int _mpvCacheSizeMb = 500;
  PlaybackBufferPreset _playbackBufferPreset = PlaybackBufferPreset.seekFast;
  double _playbackBufferBackRatio = 0.05;
  bool _flushBufferOnSeek = true;
  bool _unlimitedStreamCache = false;
  bool _enableBlurEffects = true;
  bool _showHomeLibraryQuickAccess = true;
  bool _autoUpdateEnabled = false;
  int _autoUpdateLastCheckedAtMs = 0;
  String _externalMpvPath = '';
  Anime4kPreset _anime4kPreset = Anime4kPreset.off;
  bool _danmakuEnabled = true;
  DanmakuLoadMode _danmakuLoadMode = DanmakuLoadMode.local;
  List<String> _danmakuApiUrls = ['https://api.dandanplay.net'];
  List<String> _serverIconLibraryUrls = const [];
  String _danmakuAppId = '';
  String _danmakuAppSecret = '';
  double _danmakuOpacity = 1.0;
  double _danmakuScale = 1.0;
  double _danmakuSpeed = 1.0;
  bool _danmakuBold = true;
  int _danmakuMaxLines = 10;
  int _danmakuTopMaxLines = 0;
  int _danmakuBottomMaxLines = 0;
  bool _danmakuRememberSelectedSource = false;
  String _danmakuLastSelectedSourceName = '';
  bool _danmakuMergeDuplicates = false;
  bool _danmakuMergeRelated = true;
  bool _danmakuShowHeatmap = true;
  bool _danmakuPreventOverlap = true;
  String _danmakuBlockWords = '';
  DanmakuMatchMode _danmakuMatchMode = DanmakuMatchMode.auto;
  DanmakuChConvert _danmakuChConvert = DanmakuChConvert.off;

  // Interaction & gestures (shared by MPV/Exo).
  bool _gestureBrightness = true;
  bool _gestureVolume = true;
  bool _gestureSeek = true;
  bool _gestureLongPressSpeed = true;
  double _longPressSpeedMultiplier = 2.5;
  bool _longPressSlideSpeed = true;
  DoubleTapAction _doubleTapLeft = DoubleTapAction.seekBackward;
  DoubleTapAction _doubleTapCenter = DoubleTapAction.playPause;
  DoubleTapAction _doubleTapRight = DoubleTapAction.seekForward;
  ReturnHomeBehavior _returnHomeBehavior = ReturnHomeBehavior.pause;
  bool _showSystemTimeInControls = false;
  bool _showBufferSpeed = true;
  bool _showBatteryInControls = false;
  int _seekBackwardSeconds = 10;
  int _seekForwardSeconds = 20;
  bool _forceRemoteControlKeys = false;
  LocalPlaybackHandoff? _localPlaybackHandoff;
  bool _loading = false;
  String? _error;
  MediaStats? _mediaStats;
  Future<MediaStats>? _mediaStatsInFlight;
  Future<void>? _homeInFlight;
  final Map<String, int> _seriesEpisodeCountCache = {};
  final Map<String, Future<int?>> _seriesEpisodeCountInFlight = {};

  static String _librariesCacheKey(String serverId) =>
      '$_kServerLibrariesCachePrefix$serverId';
  static String _homeCacheKey(String serverId) =>
      '$_kServerHomeCachePrefix$serverId';

  void _restoreServerCaches(SharedPreferences prefs, String serverId) {
    _restoreLibrariesFromCache(prefs, serverId);
    _restoreHomeFromCache(prefs, serverId);
  }

  void _restoreLibrariesFromCache(SharedPreferences prefs, String serverId) {
    final raw = prefs.getString(_librariesCacheKey(serverId));
    if (raw == null || raw.trim().isEmpty) return;
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! List) return;
      final libs = <LibraryInfo>[];
      for (final item in decoded) {
        if (item is Map<String, dynamic>) {
          final lib = LibraryInfo.fromJson(item);
          if (lib.id.trim().isEmpty) continue;
          libs.add(lib);
        }
      }
      if (libs.isNotEmpty) {
        _libraries = libs;
      }
    } catch (_) {
      // ignore broken cache
    }
  }

  void _restoreHomeFromCache(SharedPreferences prefs, String serverId) {
    final raw = prefs.getString(_homeCacheKey(serverId));
    if (raw == null || raw.trim().isEmpty) return;
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! Map) return;

      final sections = decoded['sections'];
      if (sections is Map) {
        for (final entry in sections.entries) {
          final key = entry.key.toString();
          if (!key.startsWith('lib_')) continue;
          final list = entry.value;
          if (list is! List) continue;
          final items = <MediaItem>[];
          for (final it in list) {
            if (it is Map<String, dynamic>) {
              items.add(MediaItem.fromJson(it));
            }
          }
          if (items.isNotEmpty) {
            _homeSections[key] = items;
          }
        }
      }

      final totals = decoded['totals'];
      if (totals is Map) {
        for (final entry in totals.entries) {
          final libId = entry.key.toString();
          final v = entry.value;
          if (v is int) {
            _itemsTotal[libId] = v;
          } else if (v is num) {
            _itemsTotal[libId] = v.toInt();
          }
        }
      }
    } catch (_) {
      // ignore broken cache
    }
  }

  Future<void> _persistLibrariesCache() async {
    final serverId = activeServerId;
    if (serverId == null) return;
    final prefs = await SharedPreferences.getInstance();
    final encoded = jsonEncode(_libraries.map((l) => l.toJson()).toList());
    await prefs.setString(_librariesCacheKey(serverId), encoded);
  }

  Future<void> _persistHomeCache() async {
    final serverId = activeServerId;
    if (serverId == null) return;
    final prefs = await SharedPreferences.getInstance();
    final totals = <String, int>{};
    for (final key in _homeSections.keys) {
      if (!key.startsWith('lib_')) continue;
      final libId = key.substring(4);
      final total = _itemsTotal[libId];
      if (total != null) totals[libId] = total;
    }
    final data = <String, dynamic>{
      'sections': _homeSections.map(
        (key, value) => MapEntry(key, value.map((e) => e.toJson()).toList()),
      ),
      'totals': totals,
    };
    await prefs.setString(_homeCacheKey(serverId), jsonEncode(data));
  }

  void _resetPerServerCaches() {
    _mediaStats = null;
    _mediaStatsInFlight = null;
    _homeInFlight = null;
    _seriesEpisodeCountCache.clear();
    _seriesEpisodeCountInFlight.clear();
  }

  Future<MediaStats> loadMediaStats({bool forceRefresh = false}) {
    final inFlight = _mediaStatsInFlight;
    if (inFlight != null) return inFlight;

    if (!forceRefresh) {
      final cached = _mediaStats;
      if (cached != null) return Future.value(cached);
    }

    final future = _fetchMediaStats();
    _mediaStatsInFlight = future;
    return future.then((stats) {
      _mediaStats = stats;
      return stats;
    }).whenComplete(() {
      if (_mediaStatsInFlight == future) _mediaStatsInFlight = null;
    });
  }

  Future<MediaStats> _fetchMediaStats() async {
    final baseUrl = this.baseUrl;
    final token = this.token;
    final userId = this.userId;
    if (baseUrl == null || token == null || userId == null) {
      return const MediaStats(movieCount: 0, seriesCount: 0, episodeCount: 0);
    }

    final api = EmbyApi(
      hostOrUrl: baseUrl,
      preferredScheme: 'https',
      apiPrefix: apiPrefix,
      serverType: serverType,
      deviceId: _deviceId,
    );

    Future<int?> quickTotal(String includeItemTypes) async {
      try {
        final res = await api.fetchItems(
          token: token,
          baseUrl: baseUrl,
          userId: userId,
          includeItemTypes: includeItemTypes,
          recursive: true,
          startIndex: 0,
          limit: 1,
        );
        return res.total;
      } catch (_) {
        return null;
      }
    }

    int? movieCount;
    int? seriesCount;
    int? episodeCount;

    try {
      final counts = await api.fetchItemCounts(
        token: token,
        baseUrl: baseUrl,
        userId: userId,
      );
      movieCount = counts.movieCount;
      seriesCount = counts.seriesCount;
      episodeCount = counts.episodeCount;
    } catch (_) {}

    final futures = <Future<void>>[];
    if (movieCount == null) {
      futures.add(quickTotal('Movie').then((v) => movieCount = v));
    }
    if (seriesCount == null) {
      futures.add(quickTotal('Series').then((v) => seriesCount = v));
    }
    if (episodeCount == null) {
      futures.add(quickTotal('Episode').then((v) => episodeCount = v));
    }
    if (futures.isNotEmpty) await Future.wait(futures);

    return MediaStats(
      movieCount: movieCount,
      seriesCount: seriesCount,
      episodeCount: episodeCount,
    );
  }

  Future<int?> loadSeriesEpisodeCount(
    String seriesId, {
    bool forceRefresh = false,
  }) {
    if (seriesId.trim().isEmpty) return Future.value(null);

    if (!forceRefresh) {
      final cached = _seriesEpisodeCountCache[seriesId];
      if (cached != null) return Future.value(cached);
      final inFlight = _seriesEpisodeCountInFlight[seriesId];
      if (inFlight != null) return inFlight;
    }

    final future = _fetchSeriesEpisodeCount(seriesId);
    _seriesEpisodeCountInFlight[seriesId] = future;
    return future.then((count) {
      if (count != null) _seriesEpisodeCountCache[seriesId] = count;
      return count;
    }).whenComplete(() {
      final current = _seriesEpisodeCountInFlight[seriesId];
      if (current == future) _seriesEpisodeCountInFlight.remove(seriesId);
    });
  }

  Future<int?> _fetchSeriesEpisodeCount(String seriesId) async {
    final baseUrl = this.baseUrl;
    final token = this.token;
    final userId = this.userId;
    if (baseUrl == null || token == null || userId == null) return null;

    final api = EmbyApi(
      hostOrUrl: baseUrl,
      preferredScheme: 'https',
      apiPrefix: apiPrefix,
      serverType: serverType,
      deviceId: _deviceId,
    );

    try {
      final res = await api.fetchItems(
        token: token,
        baseUrl: baseUrl,
        userId: userId,
        parentId: seriesId,
        includeItemTypes: 'Episode',
        recursive: true,
        startIndex: 0,
        limit: 1,
      );
      return res.total;
    } catch (_) {
      return null;
    }
  }

  static String _randomId() {
    const chars = 'abcdefghijklmnopqrstuvwxyz0123456789';
    final rand = DateTime.now().microsecondsSinceEpoch;
    return List.generate(16, (i) => chars[(rand + i * 31) % chars.length])
        .join();
  }

  static bool _defaultCompactModeForPlatform() {
    return defaultTargetPlatform == TargetPlatform.windows ||
        defaultTargetPlatform == TargetPlatform.linux ||
        defaultTargetPlatform == TargetPlatform.macOS;
  }

  List<ServerProfile> get servers => List.unmodifiable(_servers);
  String? get activeServerId => _activeServerId;
  ServerProfile? get activeServer =>
      _servers.firstWhereOrNull((s) => s.id == _activeServerId);

  /// Whether there is an active server profile selected (any type).
  bool get hasActiveServerProfile => activeServer != null && baseUrl != null;

  bool get hasActiveServer =>
      activeServer != null &&
      activeServer!.serverType.isEmbyLike &&
      baseUrl != null &&
      token != null &&
      userId != null;

  String? get baseUrl {
    final v = activeServer?.baseUrl;
    return (v == null || v.trim().isEmpty) ? null : v;
  }

  String? get token {
    final v = activeServer?.token;
    return (v == null || v.trim().isEmpty) ? null : v;
  }

  String? get userId {
    final v = activeServer?.userId;
    return (v == null || v.trim().isEmpty) ? null : v;
  }

  MediaServerType get serverType =>
      activeServer?.serverType ?? MediaServerType.emby;
  String get apiPrefix => activeServer?.apiPrefix ?? 'emby';

  String get deviceId => _deviceId;
  List<DomainInfo> get domains => _domains;
  List<LibraryInfo> get libraries => _libraries;
  List<MediaItem> getItems(String parentId) => _itemsCache[parentId] ?? [];
  int getTotal(String parentId) => _itemsTotal[parentId] ?? 0;
  List<MediaItem> getHome(String key) => _homeSections[key] ?? [];
  ThemeMode get themeMode => _themeMode;
  double get uiScaleFactor => _uiScaleFactor;
  bool get useDynamicColor => _useDynamicColor;
  bool get compactMode => _compactMode;
  UiTemplate get uiTemplate => _uiTemplate;
  Color get themeSeedColor => _uiTemplate.seed;
  Color get themeSecondarySeedColor => _uiTemplate.secondarySeed;

  bool get prefersFancyBackground =>
      _uiTemplate == UiTemplate.candyGlass ||
      _uiTemplate == UiTemplate.stickerJournal ||
      _uiTemplate == UiTemplate.neonHud ||
      _uiTemplate == UiTemplate.washiWatercolor ||
      _uiTemplate == UiTemplate.mangaStoryboard;

  bool get preferHardwareDecode => _preferHardwareDecode;
  PlayerCore get playerCore => _playerCore;
  String get preferredAudioLang => _preferredAudioLang;
  String get preferredSubtitleLang => _preferredSubtitleLang;
  VideoVersionPreference get preferredVideoVersion => _preferredVideoVersion;
  String get appIconId => _appIconId;
  ServerListLayout get serverListLayout => _serverListLayout;
  int get mpvCacheSizeMb => _mpvCacheSizeMb;
  PlaybackBufferPreset get playbackBufferPreset => _playbackBufferPreset;
  double get playbackBufferBackRatio => _playbackBufferBackRatio;
  bool get flushBufferOnSeek => _flushBufferOnSeek;
  bool get unlimitedStreamCache => _unlimitedStreamCache;
  bool get enableBlurEffects => _enableBlurEffects;
  bool get showHomeLibraryQuickAccess => _showHomeLibraryQuickAccess;
  bool get autoUpdateEnabled => _autoUpdateEnabled;
  DateTime? get autoUpdateLastCheckedAt => _autoUpdateLastCheckedAtMs <= 0
      ? null
      : DateTime.fromMillisecondsSinceEpoch(_autoUpdateLastCheckedAtMs);
  String get externalMpvPath => _externalMpvPath;
  Anime4kPreset get anime4kPreset => _anime4kPreset;
  bool get danmakuEnabled => _danmakuEnabled;
  DanmakuLoadMode get danmakuLoadMode => _danmakuLoadMode;
  List<String> get danmakuApiUrls => List.unmodifiable(_danmakuApiUrls);
  List<String> get serverIconLibraryUrls =>
      List.unmodifiable(_serverIconLibraryUrls);
  String get danmakuAppId => _danmakuAppId;
  String get danmakuAppSecret => _danmakuAppSecret;
  double get danmakuOpacity => _danmakuOpacity;
  double get danmakuScale => _danmakuScale;
  double get danmakuSpeed => _danmakuSpeed;
  bool get danmakuBold => _danmakuBold;
  int get danmakuMaxLines => _danmakuMaxLines;
  int get danmakuTopMaxLines => _danmakuTopMaxLines;
  int get danmakuBottomMaxLines => _danmakuBottomMaxLines;
  bool get danmakuRememberSelectedSource => _danmakuRememberSelectedSource;
  String get danmakuLastSelectedSourceName => _danmakuLastSelectedSourceName;
  bool get danmakuMergeDuplicates => _danmakuMergeDuplicates;
  bool get danmakuMergeRelated => _danmakuMergeRelated;
  bool get danmakuShowHeatmap => _danmakuShowHeatmap;
  bool get danmakuPreventOverlap => _danmakuPreventOverlap;
  String get danmakuBlockWords => _danmakuBlockWords;
  DanmakuMatchMode get danmakuMatchMode => _danmakuMatchMode;
  DanmakuChConvert get danmakuChConvert => _danmakuChConvert;

  bool get gestureBrightness => _gestureBrightness;
  bool get gestureVolume => _gestureVolume;
  bool get gestureSeek => _gestureSeek;
  bool get gestureLongPressSpeed => _gestureLongPressSpeed;
  double get longPressSpeedMultiplier => _longPressSpeedMultiplier;
  bool get longPressSlideSpeed => _longPressSlideSpeed;
  DoubleTapAction get doubleTapLeft => _doubleTapLeft;
  DoubleTapAction get doubleTapCenter => _doubleTapCenter;
  DoubleTapAction get doubleTapRight => _doubleTapRight;
  ReturnHomeBehavior get returnHomeBehavior => _returnHomeBehavior;
  bool get showSystemTimeInControls => _showSystemTimeInControls;
  bool get showBufferSpeed => _showBufferSpeed;
  bool get showBatteryInControls => _showBatteryInControls;
  int get seekBackwardSeconds => _seekBackwardSeconds;
  int get seekForwardSeconds => _seekForwardSeconds;
  bool get forceRemoteControlKeys => _forceRemoteControlKeys;

  void setLocalPlaybackHandoff(LocalPlaybackHandoff? handoff) {
    _localPlaybackHandoff = handoff;
  }

  LocalPlaybackHandoff? takeLocalPlaybackHandoff() {
    final handoff = _localPlaybackHandoff;
    _localPlaybackHandoff = null;
    return handoff;
  }

  Iterable<HomeEntry> get homeEntries sync* {
    for (final entry in _homeSections.entries) {
      if (!entry.key.startsWith('lib_')) continue;
      final libId = entry.key.substring(4);
      if (activeServer?.hiddenLibraries.contains(libId) == true) continue;
      if (_libraries.isNotEmpty && !_libraries.any((l) => l.id == libId)) {
        continue;
      }
      final name = _libraries
          .firstWhere(
            (l) => l.id == libId,
            orElse: () => LibraryInfo(id: libId, name: '未知媒体库', type: ''),
          )
          .name;
      yield HomeEntry(key: entry.key, displayName: name, items: entry.value);
    }
  }

  bool get isLoading => _loading;
  String? get error => _error;

  Future<void> loadFromStorage() async {
    final prefs = await SharedPreferences.getInstance();

    _themeMode = _decodeThemeMode(prefs.getString(_kThemeModeKey));
    _uiScaleFactor =
        ((prefs.getDouble(_kUiScaleFactorKey) ?? 1.0).clamp(0.5, 2.0))
            .toDouble();
    _useDynamicColor = prefs.getBool(_kDynamicColorKey) ?? true;
    _compactMode =
        prefs.getBool(_kCompactModeKey) ?? _defaultCompactModeForPlatform();
    final storedTemplateId = prefs.getString(_kUiTemplateKey) ??
        prefs.getString(_kLegacyThemeTemplateKey);
    _uiTemplate = uiTemplateFromId(storedTemplateId);
    if (!prefs.containsKey(_kUiTemplateKey) &&
        prefs.containsKey(_kLegacyThemeTemplateKey)) {
      await prefs.setString(_kUiTemplateKey, _uiTemplate.id);
    }
    _preferHardwareDecode = prefs.getBool(_kPreferHardwareDecodeKey) ?? true;
    _playerCore = playerCoreFromId(prefs.getString(_kPlayerCoreKey));
    _preferredAudioLang = prefs.getString(_kPreferredAudioLangKey) ?? '';
    _preferredSubtitleLang = prefs.getString(_kPreferredSubtitleLangKey) ?? '';
    _preferredVideoVersion = videoVersionPreferenceFromId(
        prefs.getString(_kPreferredVideoVersionKey));
    _appIconId = prefs.getString(_kAppIconIdKey) ?? 'default';
    const supportedAppIcons = {'default', 'pink', 'purple', 'miku'};
    if (!supportedAppIcons.contains(_appIconId)) {
      _appIconId = 'default';
      await prefs.setString(_kAppIconIdKey, _appIconId);
    }
    _serverListLayout =
        serverListLayoutFromId(prefs.getString(_kServerListLayoutKey));
    _mpvCacheSizeMb = prefs.getInt(_kMpvCacheSizeMbKey) ?? 500;
    if (_mpvCacheSizeMb < 200 || _mpvCacheSizeMb > 2048) {
      _mpvCacheSizeMb = _mpvCacheSizeMb.clamp(200, 2048);
      await prefs.setInt(_kMpvCacheSizeMbKey, _mpvCacheSizeMb);
    }
    _playbackBufferPreset = playbackBufferPresetFromId(
      prefs.getString(_kPlaybackBufferPresetKey),
    );
    final fallbackBackRatio =
        _playbackBufferPreset.suggestedBackRatio ?? 0.05;
    _playbackBufferBackRatio =
        (prefs.getDouble(_kPlaybackBufferBackRatioKey) ?? fallbackBackRatio)
            .clamp(0.0, 0.30)
            .toDouble();
    _flushBufferOnSeek = prefs.getBool(_kFlushBufferOnSeekKey) ?? true;
    final hasNewStreamCacheKey = prefs.containsKey(_kUnlimitedStreamCacheKey);
    _unlimitedStreamCache = hasNewStreamCacheKey
        ? (prefs.getBool(_kUnlimitedStreamCacheKey) ?? false)
        : (prefs.getBool(_kLegacyUnlimitedCoverCacheKey) ?? false);
    if (!hasNewStreamCacheKey &&
        prefs.containsKey(_kLegacyUnlimitedCoverCacheKey)) {
      await prefs.setBool(_kUnlimitedStreamCacheKey, _unlimitedStreamCache);
    }
    _enableBlurEffects = prefs.getBool(_kEnableBlurEffectsKey) ?? true;
    _showHomeLibraryQuickAccess =
        prefs.getBool(_kShowHomeLibraryQuickAccessKey) ?? true;
    _autoUpdateEnabled = prefs.getBool(_kAutoUpdateEnabledKey) ?? false;
    _autoUpdateLastCheckedAtMs =
        prefs.getInt(_kAutoUpdateLastCheckedAtMsKey) ?? 0;
    _externalMpvPath = prefs.getString(_kExternalMpvPathKey) ?? '';
    _anime4kPreset = anime4kPresetFromId(prefs.getString(_kAnime4kPresetKey));

    _danmakuEnabled = prefs.getBool(_kDanmakuEnabledKey) ?? true;
    _danmakuLoadMode =
        danmakuLoadModeFromId(prefs.getString(_kDanmakuLoadModeKey));
    final rawUrls = prefs.getStringList(_kDanmakuApiUrlsKey);
    if (rawUrls != null) {
      _danmakuApiUrls = rawUrls
          .map(_normalizeDanmakuApiUrl)
          .where((e) => e.isNotEmpty)
          .toList();
    }

    final rawIconLibraryUrls = prefs.getStringList(_kServerIconLibraryUrlsKey);
    if (rawIconLibraryUrls != null) {
      final seen = <String>{};
      _serverIconLibraryUrls = rawIconLibraryUrls
          .map(_normalizeServerIconLibraryUrl)
          .where((e) => e.isNotEmpty)
          .where((e) => seen.add(e.toLowerCase()))
          .toList(growable: false);
    }
    _danmakuAppId = prefs.getString(_kDanmakuAppIdKey) ?? '';
    _danmakuAppSecret = prefs.getString(_kDanmakuAppSecretKey) ?? '';
    _danmakuOpacity = (prefs.getDouble(_kDanmakuOpacityKey) ?? 1.0)
        .clamp(0.2, 1.0)
        .toDouble();
    _danmakuScale =
        (prefs.getDouble(_kDanmakuScaleKey) ?? 1.0).clamp(0.5, 1.6).toDouble();
    _danmakuSpeed =
        (prefs.getDouble(_kDanmakuSpeedKey) ?? 1.0).clamp(0.4, 2.5).toDouble();
    _danmakuBold = prefs.getBool(_kDanmakuBoldKey) ?? true;
    _danmakuMaxLines = (prefs.getInt(_kDanmakuMaxLinesKey) ?? 10).clamp(1, 40);
    _danmakuTopMaxLines =
        (prefs.getInt(_kDanmakuTopMaxLinesKey) ?? 0).clamp(0, 40);
    _danmakuBottomMaxLines =
        (prefs.getInt(_kDanmakuBottomMaxLinesKey) ?? 0).clamp(0, 40);
    _danmakuRememberSelectedSource =
        prefs.getBool(_kDanmakuRememberSelectedSourceKey) ?? false;
    _danmakuLastSelectedSourceName =
        prefs.getString(_kDanmakuLastSelectedSourceNameKey) ?? '';
    _danmakuMergeDuplicates =
        prefs.getBool(_kDanmakuMergeDuplicatesKey) ?? false;
    _danmakuMergeRelated = prefs.getBool(_kDanmakuMergeRelatedKey) ?? true;
    _danmakuShowHeatmap = prefs.getBool(_kDanmakuShowHeatmapKey) ?? true;
    _danmakuPreventOverlap = prefs.getBool(_kDanmakuPreventOverlapKey) ?? true;
    _danmakuBlockWords = prefs.getString(_kDanmakuBlockWordsKey) ?? '';
    _danmakuMatchMode =
        danmakuMatchModeFromId(prefs.getString(_kDanmakuMatchModeKey));
    _danmakuChConvert =
        danmakuChConvertFromId(prefs.getString(_kDanmakuChConvertKey));

    _gestureBrightness = prefs.getBool(_kGestureBrightnessKey) ?? true;
    _gestureVolume = prefs.getBool(_kGestureVolumeKey) ?? true;
    _gestureSeek = prefs.getBool(_kGestureSeekKey) ?? true;
    _gestureLongPressSpeed = prefs.getBool(_kGestureLongPressSpeedKey) ?? true;
    _longPressSpeedMultiplier =
        (prefs.getDouble(_kLongPressSpeedMultiplierKey) ?? 2.5)
            .clamp(1.0, 4.0)
            .toDouble();
    _longPressSlideSpeed = prefs.getBool(_kLongPressSlideSpeedKey) ?? true;

    if (prefs.containsKey(_kDoubleTapLeftKey)) {
      _doubleTapLeft =
          doubleTapActionFromId(prefs.getString(_kDoubleTapLeftKey));
    }
    if (prefs.containsKey(_kDoubleTapCenterKey)) {
      _doubleTapCenter =
          doubleTapActionFromId(prefs.getString(_kDoubleTapCenterKey));
    }
    if (prefs.containsKey(_kDoubleTapRightKey)) {
      _doubleTapRight =
          doubleTapActionFromId(prefs.getString(_kDoubleTapRightKey));
    }

    _returnHomeBehavior =
        returnHomeBehaviorFromId(prefs.getString(_kReturnHomeBehaviorKey));
    _showSystemTimeInControls =
        prefs.getBool(_kShowSystemTimeInControlsKey) ?? false;
    _showBufferSpeed = prefs.getBool(_kShowBufferSpeedKey) ?? true;
    _showBatteryInControls = prefs.getBool(_kShowBatteryInControlsKey) ?? false;
    _seekBackwardSeconds =
        (prefs.getInt(_kSeekBackwardSecondsKey) ?? 10).clamp(1, 120);
    _seekForwardSeconds =
        (prefs.getInt(_kSeekForwardSecondsKey) ?? 20).clamp(1, 120);
    _forceRemoteControlKeys =
        prefs.getBool(_kForceRemoteControlKeysKey) ?? false;

    final rawServers = prefs.getString(_kServersKey);
    _servers.clear();
    if (rawServers != null && rawServers.trim().isNotEmpty) {
      try {
        final decoded = jsonDecode(rawServers);
        if (decoded is List) {
          for (final item in decoded) {
            if (item is Map<String, dynamic>) {
              final s = ServerProfile.fromJson(item);
              if (s.id.isNotEmpty && s.baseUrl.isNotEmpty) {
                _servers.add(s);
              }
            }
          }
        }
      } catch (_) {
        // ignore broken storage
      }
    }

    // Migration from the old single-server storage keys.
    if (_servers.isEmpty) {
      final baseUrl = prefs.getString('baseUrl');
      final token = prefs.getString('token');
      final userId = prefs.getString('userId');
      if (baseUrl != null && token != null && userId != null) {
        _servers.add(
          ServerProfile(
            id: _randomId(),
            username: '',
            name: _suggestServerName(baseUrl),
            baseUrl: baseUrl,
            token: token,
            userId: userId,
            hiddenLibraries:
                (prefs.getStringList('hiddenLibs') ?? const <String>[]).toSet(),
          ),
        );
        await _persistServers(prefs);
      }
    }

    _activeServerId = prefs.getString(_kActiveServerIdKey);
    if (_activeServerId != null && activeServer == null) {
      _activeServerId = null;
      await prefs.remove(_kActiveServerIdKey);
    }

    final serverId = _activeServerId;
    if (serverId != null && activeServer?.serverType.isEmbyLike == true) {
      _restoreServerCaches(prefs, serverId);
    }

    notifyListeners();
  }

  Map<String, dynamic> exportBackupMap() {
    return {
      'type': _kBackupType,
      'version': _kBackupSchemaVersionV1,
      'createdAt': DateTime.now().toUtc().toIso8601String(),
      'data': {
        'themeMode': _encodeThemeMode(_themeMode),
        'uiScaleFactor': _uiScaleFactor,
        'useDynamicColor': _useDynamicColor,
        'compactMode': _compactMode,
        'uiTemplate': _uiTemplate.id,
        // Legacy alias for older builds/backups.
        'themeTemplate': _uiTemplate.id,
        'preferHardwareDecode': _preferHardwareDecode,
        'playerCore': _playerCore.id,
        'preferredAudioLang': _preferredAudioLang,
        'preferredSubtitleLang': _preferredSubtitleLang,
        'preferredVideoVersion': _preferredVideoVersion.id,
        'appIconId': _appIconId,
        'serverListLayout': _serverListLayout.id,
        'mpvCacheSizeMb': _mpvCacheSizeMb,
        'playbackBufferPreset': _playbackBufferPreset.id,
        'playbackBufferBackRatio': _playbackBufferBackRatio,
        'flushBufferOnSeek': _flushBufferOnSeek,
        'unlimitedStreamCache': _unlimitedStreamCache,
        'enableBlurEffects': _enableBlurEffects,
        'showHomeLibraryQuickAccess': _showHomeLibraryQuickAccess,
        'autoUpdateEnabled': _autoUpdateEnabled,
        'externalMpvPath': _externalMpvPath,
        'anime4kPreset': _anime4kPreset.id,
        'serverIconLibraryUrls': _serverIconLibraryUrls,
        'danmaku': {
          'enabled': _danmakuEnabled,
          'loadMode': _danmakuLoadMode.id,
          'apiUrls': _danmakuApiUrls,
          'appId': _danmakuAppId,
          'appSecret': _danmakuAppSecret,
          'opacity': _danmakuOpacity,
          'scale': _danmakuScale,
          'speed': _danmakuSpeed,
          'bold': _danmakuBold,
          'maxLines': _danmakuMaxLines,
          'topMaxLines': _danmakuTopMaxLines,
          'bottomMaxLines': _danmakuBottomMaxLines,
          'rememberSelectedSource': _danmakuRememberSelectedSource,
          'lastSelectedSourceName': _danmakuLastSelectedSourceName,
          'mergeDuplicates': _danmakuMergeDuplicates,
          'mergeRelated': _danmakuMergeRelated,
          'showHeatmap': _danmakuShowHeatmap,
          'preventOverlap': _danmakuPreventOverlap,
          'blockWords': _danmakuBlockWords,
          'matchMode': _danmakuMatchMode.id,
          'chConvert': _danmakuChConvert.id,
        },
        'interaction': {
          'gestureBrightness': _gestureBrightness,
          'gestureVolume': _gestureVolume,
          'gestureSeek': _gestureSeek,
          'gestureLongPressSpeed': _gestureLongPressSpeed,
          'longPressSpeedMultiplier': _longPressSpeedMultiplier,
          'longPressSlideSpeed': _longPressSlideSpeed,
          'doubleTap': {
            'left': _doubleTapLeft.id,
            'center': _doubleTapCenter.id,
            'right': _doubleTapRight.id,
          },
          'returnHomeBehavior': _returnHomeBehavior.id,
          'showSystemTimeInControls': _showSystemTimeInControls,
          'showBufferSpeed': _showBufferSpeed,
          'showBatteryInControls': _showBatteryInControls,
          'seekBackwardSeconds': _seekBackwardSeconds,
          'seekForwardSeconds': _seekForwardSeconds,
          'forceRemoteControlKeys': _forceRemoteControlKeys,
        },
        'activeServerId': _activeServerId,
        'servers': _servers.map((s) => s.toJson()).toList(),
      },
    };
  }

  String exportBackupJson({bool pretty = true}) {
    final json = exportBackupMap();
    if (!pretty) return jsonEncode(json);
    return const JsonEncoder.withIndent('  ').convert(json);
  }

  Future<String> exportEncryptedBackupJson({
    required String passphrase,
    required BackupServerSecretMode mode,
    Map<String, BackupServerLogin>? serverLogins,
    bool pretty = true,
  }) async {
    final v1 = exportBackupMap();
    final data = _coerceStringKeyedMap(v1['data']);
    if (data == null) throw const FormatException('Invalid backup payload');

    if (mode == BackupServerSecretMode.password) {
      final logins = serverLogins ?? const {};
      final servers = <Map<String, dynamic>>[];
      for (final server in _servers) {
        final login = logins[server.id];
        if (login == null) {
          throw FormatException('Missing server login: ${server.name}');
        }
        servers.add({
          'id': server.id,
          'name': server.name,
          'remark': server.remark,
          'iconUrl': server.iconUrl,
          'baseUrl': server.baseUrl,
          'username': login.username.trim(),
          'password': login.password,
          'hiddenLibraries': server.hiddenLibraries.toList(),
          'domainRemarks': server.domainRemarks,
          'customDomains': server.customDomains.map((e) => e.toJson()).toList(),
        });
      }
      data['servers'] = servers;
    }

    final inner = {
      'mode': mode.id,
      'data': data,
    };

    final encrypted = await BackupCrypto.encryptJson(
      plaintextJson: jsonEncode(inner),
      passphrase: passphrase,
    );

    final wrapper = {
      'type': _kBackupType,
      'version': _kBackupSchemaVersionV2,
      'createdAt': DateTime.now().toUtc().toIso8601String(),
      'crypto': encrypted,
    };
    if (!pretty) return jsonEncode(wrapper);
    return const JsonEncoder.withIndent('  ').convert(wrapper);
  }

  Future<void> importBackupJson(
    String raw, {
    String? passphrase,
    BackupServerAuthenticator? authenticator,
  }) async {
    final decoded = jsonDecode(raw);
    final backup = _coerceStringKeyedMap(decoded);
    if (backup == null) throw const FormatException('Invalid backup JSON');

    final version = _readInt(backup['version'], fallback: 0);
    if (version == _kBackupSchemaVersionV2) {
      final p = (passphrase ?? '').trim();
      if (p.isEmpty) throw const FormatException('Missing passphrase');
      await importEncryptedBackupMap(
        backup,
        passphrase: p,
        authenticator: authenticator,
      );
      return;
    }

    await importBackupMap(backup);
  }

  Future<void> importEncryptedBackupMap(
    Map<String, dynamic> wrapper, {
    required String passphrase,
    BackupServerAuthenticator? authenticator,
  }) async {
    final type = (wrapper['type'] ?? '').toString().trim();
    if (type != _kBackupType) {
      throw FormatException('Invalid backup type: $type');
    }

    final version = _readInt(wrapper['version'], fallback: 0);
    if (version != _kBackupSchemaVersionV2) {
      throw FormatException('Unsupported backup version: $version');
    }

    final crypto = _coerceStringKeyedMap(wrapper['crypto']);
    if (crypto == null) throw const FormatException('Missing crypto payload');

    final decryptedJson = await BackupCrypto.decryptJson(
      encrypted: crypto,
      passphrase: passphrase,
    );
    final decrypted = _coerceStringKeyedMap(jsonDecode(decryptedJson));
    if (decrypted == null) {
      throw const FormatException('Invalid backup payload');
    }

    final mode = backupServerSecretModeFromId(decrypted['mode']?.toString());
    final data = _coerceStringKeyedMap(decrypted['data']);
    if (data == null) throw const FormatException('Invalid backup payload');

    if (mode == BackupServerSecretMode.token) {
      await importBackupMap({
        'type': _kBackupType,
        'version': _kBackupSchemaVersionV1,
        'data': data,
      });
      return;
    }

    final rawServers = data['servers'];
    if (rawServers is! List) {
      throw const FormatException('Invalid backup payload: missing servers');
    }

    final auth = authenticator ?? _authenticateForBackup;
    final nextServers = <ServerProfile>[];

    for (final item in rawServers) {
      final map = _coerceStringKeyedMap(item);
      if (map == null) continue;
      final id = (map['id'] ?? '').toString().trim();
      final name = (map['name'] ?? '').toString().trim();
      final remark = (map['remark'] ?? '').toString().trim();
      final iconUrl = (map['iconUrl'] ?? '').toString().trim();
      final baseUrl = (map['baseUrl'] ?? '').toString().trim();
      final username = (map['username'] ?? '').toString().trim();
      final password = (map['password'] ?? '').toString();

      if (baseUrl.isEmpty || username.isEmpty) continue;

      final result = await auth(
        baseUrl: baseUrl,
        username: username,
        password: password,
        deviceId: _deviceId,
      );

      final hidden = ((map['hiddenLibraries'] as List?)?.cast<String>() ??
              const <String>[])
          .toSet();
      final domainRemarks = (map['domainRemarks'] as Map?)?.map(
            (key, value) => MapEntry(key.toString(), value.toString()),
          ) ??
          <String, String>{};
      final customDomains = (map['customDomains'] as List?)
              ?.whereType<Map>()
              .map((e) => CustomDomain.fromJson(
                  e.map((k, v) => MapEntry(k.toString(), v))))
              .toList() ??
          <CustomDomain>[];

      nextServers.add(
        ServerProfile(
          id: id.isEmpty ? _randomId() : id,
          username: username,
          name: name.isEmpty ? _suggestServerName(result.baseUrlUsed) : name,
          remark: remark.isEmpty ? null : remark,
          iconUrl: iconUrl.isEmpty ? null : iconUrl,
          baseUrl: result.baseUrlUsed,
          token: result.token,
          userId: result.userId,
          hiddenLibraries: hidden,
          domainRemarks: domainRemarks,
          customDomains: customDomains,
        ),
      );
    }

    String? nextActiveServerId = data['activeServerId']?.toString().trim();
    if ((nextActiveServerId ?? '').isEmpty ||
        !nextServers.any((s) => s.id == nextActiveServerId)) {
      nextActiveServerId = null;
    }

    final v1Data = Map<String, dynamic>.from(data)
      ..['servers'] = nextServers.map((s) => s.toJson()).toList()
      ..['activeServerId'] = nextActiveServerId;

    await importBackupMap({
      'type': _kBackupType,
      'version': _kBackupSchemaVersionV1,
      'data': v1Data,
    });
  }

  Future<void> importBackupMap(Map<String, dynamic> backup) async {
    final type = (backup['type'] ?? '').toString().trim();
    if (type != _kBackupType) {
      throw FormatException('Invalid backup type: $type');
    }

    final version = _readInt(backup['version'], fallback: 0);
    if (version != _kBackupSchemaVersionV1) {
      throw FormatException('Unsupported backup version: $version');
    }

    final data = _coerceStringKeyedMap(backup['data']);
    if (data == null) {
      throw const FormatException('Invalid backup payload: missing data');
    }

    final danmakuMap = _coerceStringKeyedMap(data['danmaku']) ?? const {};
    final interactionMap =
        _coerceStringKeyedMap(data['interaction']) ?? const {};
    final doubleTapMap =
        _coerceStringKeyedMap(interactionMap['doubleTap']) ?? const {};

    final nextThemeMode = _decodeThemeMode(data['themeMode']?.toString());
    final nextUiScale = _readDouble(data['uiScaleFactor'], fallback: 1.0)
        .clamp(0.5, 2.0)
        .toDouble();
    final nextUseDynamic = _readBool(data['useDynamicColor'], fallback: true);
    final nextCompactMode = _readBool(
      data['compactMode'],
      fallback: _defaultCompactModeForPlatform(),
    );
    final nextUiTemplate = uiTemplateFromId(
      (data['uiTemplate'] ?? data['themeTemplate'])?.toString(),
    );
    final nextPreferHardware =
        _readBool(data['preferHardwareDecode'], fallback: true);
    final nextPlayerCore = playerCoreFromId(data['playerCore']?.toString());
    final nextPreferredAudioLang =
        (data['preferredAudioLang'] ?? '').toString().trim();
    final nextPreferredSubtitleLang =
        (data['preferredSubtitleLang'] ?? '').toString().trim();
    final nextPreferredVideoVersion =
        videoVersionPreferenceFromId(data['preferredVideoVersion']?.toString());
    final nextAppIconId = (data['appIconId'] ?? 'default').toString().trim();
    final nextServerListLayout =
        serverListLayoutFromId(data['serverListLayout']?.toString());

    final nextMpvCacheSizeMb =
        _readInt(data['mpvCacheSizeMb'], fallback: 500).clamp(200, 2048);
    final nextPlaybackBufferPreset = playbackBufferPresetFromId(
      data['playbackBufferPreset']?.toString(),
    );
    final nextPlaybackBufferBackRatio = _readDouble(
      data['playbackBufferBackRatio'],
      fallback: nextPlaybackBufferPreset.suggestedBackRatio ?? 0.05,
    ).clamp(0.0, 0.30).toDouble();
    final nextFlushBufferOnSeek =
        _readBool(data['flushBufferOnSeek'], fallback: true);
    final nextUnlimitedStreamCache = _readBool(
      data.containsKey('unlimitedStreamCache')
          ? data['unlimitedStreamCache']
          : data['unlimitedCoverCache'],
      fallback: false,
    );
    final nextEnableBlurEffects =
        _readBool(data['enableBlurEffects'], fallback: true);
    final nextShowHomeLibraryQuickAccess =
        _readBool(data['showHomeLibraryQuickAccess'], fallback: true);
    final nextAutoUpdateEnabled =
        _readBool(data['autoUpdateEnabled'], fallback: false);
    final nextExternalMpvPath =
        (data['externalMpvPath'] ?? '').toString().trim();
    final nextAnime4kPreset =
        anime4kPresetFromId(data['anime4kPreset']?.toString());
    final nextServerIconLibraryUrls = () {
      final list = _readStringList(data['serverIconLibraryUrls']);
      final seen = <String>{};
      return list
          .map(_normalizeServerIconLibraryUrl)
          .where((e) => e.isNotEmpty)
          .where((e) => seen.add(e.toLowerCase()))
          .toList(growable: false);
    }();

    final nextDanmakuEnabled = _readBool(danmakuMap['enabled'], fallback: true);
    final nextDanmakuLoadMode =
        danmakuLoadModeFromId(danmakuMap['loadMode']?.toString());
    final nextDanmakuApiUrls = _readStringList(danmakuMap['apiUrls'])
        .map(_normalizeDanmakuApiUrl)
        .where((e) => e.isNotEmpty)
        .toList();
    final nextDanmakuAppId = (danmakuMap['appId'] ?? '').toString().trim();
    final nextDanmakuAppSecret =
        (danmakuMap['appSecret'] ?? '').toString().trim();
    final nextDanmakuOpacity = _readDouble(danmakuMap['opacity'], fallback: 1.0)
        .clamp(0.2, 1.0)
        .toDouble();
    final nextDanmakuScale = _readDouble(danmakuMap['scale'], fallback: 1.0)
        .clamp(0.5, 1.6)
        .toDouble();
    final nextDanmakuSpeed = _readDouble(danmakuMap['speed'], fallback: 1.0)
        .clamp(0.4, 2.5)
        .toDouble();
    final nextDanmakuBold = _readBool(danmakuMap['bold'], fallback: true);
    final nextDanmakuMaxLines =
        _readInt(danmakuMap['maxLines'], fallback: 10).clamp(1, 40);
    final nextDanmakuTopMaxLines =
        _readInt(danmakuMap['topMaxLines'], fallback: 0).clamp(0, 40);
    final nextDanmakuBottomMaxLines =
        _readInt(danmakuMap['bottomMaxLines'], fallback: 0).clamp(0, 40);
    final nextDanmakuRememberSelectedSource =
        _readBool(danmakuMap['rememberSelectedSource'], fallback: false);
    final nextDanmakuLastSelectedSourceName =
        (danmakuMap['lastSelectedSourceName'] ?? '').toString().trim();
    final nextDanmakuMergeDuplicates =
        _readBool(danmakuMap['mergeDuplicates'], fallback: false);
    final nextDanmakuMergeRelated =
        _readBool(danmakuMap['mergeRelated'], fallback: true);
    final nextDanmakuShowHeatmap =
        _readBool(danmakuMap['showHeatmap'], fallback: true);
    final nextDanmakuPreventOverlap =
        _readBool(danmakuMap['preventOverlap'], fallback: true);
    final nextDanmakuBlockWords =
        (danmakuMap['blockWords'] ?? '').toString().trimRight();
    final nextDanmakuMatchMode =
        danmakuMatchModeFromId(danmakuMap['matchMode']?.toString());
    final nextDanmakuChConvert =
        danmakuChConvertFromId(danmakuMap['chConvert']?.toString());

    final nextGestureBrightness =
        _readBool(interactionMap['gestureBrightness'], fallback: true);
    final nextGestureVolume =
        _readBool(interactionMap['gestureVolume'], fallback: true);
    final nextGestureSeek =
        _readBool(interactionMap['gestureSeek'], fallback: true);
    final nextGestureLongPressSpeed =
        _readBool(interactionMap['gestureLongPressSpeed'], fallback: true);
    final nextLongPressSpeedMultiplier =
        _readDouble(interactionMap['longPressSpeedMultiplier'], fallback: 2.5)
            .clamp(1.0, 4.0)
            .toDouble();
    final nextLongPressSlideSpeed =
        _readBool(interactionMap['longPressSlideSpeed'], fallback: true);
    final nextDoubleTapLeft = doubleTapMap.containsKey('left')
        ? doubleTapActionFromId(doubleTapMap['left']?.toString())
        : DoubleTapAction.seekBackward;
    final nextDoubleTapCenter = doubleTapMap.containsKey('center')
        ? doubleTapActionFromId(doubleTapMap['center']?.toString())
        : DoubleTapAction.playPause;
    final nextDoubleTapRight = doubleTapMap.containsKey('right')
        ? doubleTapActionFromId(doubleTapMap['right']?.toString())
        : DoubleTapAction.seekForward;
    final nextReturnHomeBehavior = returnHomeBehaviorFromId(
        interactionMap['returnHomeBehavior']?.toString());
    final nextShowSystemTimeInControls =
        _readBool(interactionMap['showSystemTimeInControls'], fallback: false);
    final nextShowBufferSpeed =
        _readBool(interactionMap['showBufferSpeed'], fallback: true);
    final nextShowBatteryInControls =
        _readBool(interactionMap['showBatteryInControls'], fallback: false);
    final nextSeekBackwardSeconds =
        _readInt(interactionMap['seekBackwardSeconds'], fallback: 10)
            .clamp(1, 120);
    final nextSeekForwardSeconds =
        _readInt(interactionMap['seekForwardSeconds'], fallback: 20)
            .clamp(1, 120);
    final nextForceRemoteControlKeys =
        _readBool(interactionMap['forceRemoteControlKeys'], fallback: false);

    final nextServers = <ServerProfile>[];
    final rawServers = data['servers'];
    if (rawServers is List) {
      for (final item in rawServers) {
        final map = _coerceStringKeyedMap(item);
        if (map == null) continue;
        final s = ServerProfile.fromJson(map);
        if (s.id.isEmpty || s.baseUrl.isEmpty || s.token.isEmpty) continue;
        nextServers.add(s);
      }
    }

    String? nextActiveServerId = data['activeServerId']?.toString().trim();
    if ((nextActiveServerId ?? '').isEmpty ||
        !nextServers.any((s) => s.id == nextActiveServerId)) {
      nextActiveServerId = null;
    }

    _themeMode = nextThemeMode;
    _uiScaleFactor = nextUiScale;
    _useDynamicColor = nextUseDynamic;
    _compactMode = nextCompactMode;
    _uiTemplate = nextUiTemplate;
    _preferHardwareDecode = nextPreferHardware;
    _playerCore = nextPlayerCore;
    _preferredAudioLang = nextPreferredAudioLang;
    _preferredSubtitleLang = nextPreferredSubtitleLang;
    _preferredVideoVersion = nextPreferredVideoVersion;
    _appIconId = nextAppIconId.isEmpty ? 'default' : nextAppIconId;
    const supportedAppIcons = {'default', 'pink', 'purple', 'miku'};
    if (!supportedAppIcons.contains(_appIconId)) {
      _appIconId = 'default';
    }
    _serverListLayout = nextServerListLayout;
    _mpvCacheSizeMb = nextMpvCacheSizeMb;
    _playbackBufferPreset = nextPlaybackBufferPreset;
    _playbackBufferBackRatio = nextPlaybackBufferBackRatio;
    _flushBufferOnSeek = nextFlushBufferOnSeek;
    _unlimitedStreamCache = nextUnlimitedStreamCache;
    _enableBlurEffects = nextEnableBlurEffects;
    _showHomeLibraryQuickAccess = nextShowHomeLibraryQuickAccess;
    _autoUpdateEnabled = nextAutoUpdateEnabled;
    _externalMpvPath = nextExternalMpvPath;
    _anime4kPreset = nextAnime4kPreset;
    _serverIconLibraryUrls = nextServerIconLibraryUrls;
    _danmakuEnabled = nextDanmakuEnabled;
    _danmakuLoadMode = nextDanmakuLoadMode;
    _danmakuApiUrls = nextDanmakuApiUrls.isEmpty
        ? const ['https://api.dandanplay.net']
        : nextDanmakuApiUrls;
    _danmakuAppId = nextDanmakuAppId;
    _danmakuAppSecret = nextDanmakuAppSecret;
    _danmakuOpacity = nextDanmakuOpacity;
    _danmakuScale = nextDanmakuScale;
    _danmakuSpeed = nextDanmakuSpeed;
    _danmakuBold = nextDanmakuBold;
    _danmakuMaxLines = nextDanmakuMaxLines;
    _danmakuTopMaxLines = nextDanmakuTopMaxLines;
    _danmakuBottomMaxLines = nextDanmakuBottomMaxLines;
    _danmakuRememberSelectedSource = nextDanmakuRememberSelectedSource;
    _danmakuLastSelectedSourceName = nextDanmakuLastSelectedSourceName;
    _danmakuMergeDuplicates = nextDanmakuMergeDuplicates;
    _danmakuMergeRelated = nextDanmakuMergeRelated;
    _danmakuShowHeatmap = nextDanmakuShowHeatmap;
    _danmakuPreventOverlap = nextDanmakuPreventOverlap;
    _danmakuBlockWords = nextDanmakuBlockWords;
    _danmakuMatchMode = nextDanmakuMatchMode;
    _danmakuChConvert = nextDanmakuChConvert;

    _gestureBrightness = nextGestureBrightness;
    _gestureVolume = nextGestureVolume;
    _gestureSeek = nextGestureSeek;
    _gestureLongPressSpeed = nextGestureLongPressSpeed;
    _longPressSpeedMultiplier = nextLongPressSpeedMultiplier;
    _longPressSlideSpeed = nextLongPressSlideSpeed;
    _doubleTapLeft = nextDoubleTapLeft;
    _doubleTapCenter = nextDoubleTapCenter;
    _doubleTapRight = nextDoubleTapRight;
    _returnHomeBehavior = nextReturnHomeBehavior;
    _showSystemTimeInControls = nextShowSystemTimeInControls;
    _showBufferSpeed = nextShowBufferSpeed;
    _showBatteryInControls = nextShowBatteryInControls;
    _seekBackwardSeconds = nextSeekBackwardSeconds;
    _seekForwardSeconds = nextSeekForwardSeconds;
    _forceRemoteControlKeys = nextForceRemoteControlKeys;

    _servers
      ..clear()
      ..addAll(nextServers);
    _activeServerId = nextActiveServerId;

    _domains = [];
    _libraries = [];
    _itemsCache.clear();
    _itemsTotal.clear();
    _homeSections.clear();
    _randomRecommendations = null;
    _randomRecommendationsInFlight = null;
    _continueWatching = null;
    _continueWatchingInFlight = null;
    _error = null;
    _loading = false;

    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_kThemeModeKey, _encodeThemeMode(_themeMode));
    await prefs.setDouble(_kUiScaleFactorKey, _uiScaleFactor);
    await prefs.setBool(_kDynamicColorKey, _useDynamicColor);
    await prefs.setBool(_kCompactModeKey, _compactMode);
    await prefs.setString(_kUiTemplateKey, _uiTemplate.id);
    await prefs.setBool(_kPreferHardwareDecodeKey, _preferHardwareDecode);
    await prefs.setString(_kPlayerCoreKey, _playerCore.id);
    await prefs.setString(_kPreferredAudioLangKey, _preferredAudioLang);
    await prefs.setString(_kPreferredSubtitleLangKey, _preferredSubtitleLang);
    await prefs.setString(
      _kPreferredVideoVersionKey,
      _preferredVideoVersion.id,
    );
    await prefs.setString(_kAppIconIdKey, _appIconId);
    await prefs.setString(_kServerListLayoutKey, _serverListLayout.id);
    await prefs.setInt(_kMpvCacheSizeMbKey, _mpvCacheSizeMb);
    await prefs.setString(_kPlaybackBufferPresetKey, _playbackBufferPreset.id);
    await prefs.setDouble(
      _kPlaybackBufferBackRatioKey,
      _playbackBufferBackRatio,
    );
    await prefs.setBool(_kFlushBufferOnSeekKey, _flushBufferOnSeek);
    await prefs.setBool(_kUnlimitedStreamCacheKey, _unlimitedStreamCache);
    await prefs.setBool(_kEnableBlurEffectsKey, _enableBlurEffects);
    await prefs.setBool(
      _kShowHomeLibraryQuickAccessKey,
      _showHomeLibraryQuickAccess,
    );
    await prefs.setBool(_kAutoUpdateEnabledKey, _autoUpdateEnabled);

    if (_externalMpvPath.isEmpty) {
      await prefs.remove(_kExternalMpvPathKey);
    } else {
      await prefs.setString(_kExternalMpvPathKey, _externalMpvPath);
    }

    if (_anime4kPreset.isOff) {
      await prefs.remove(_kAnime4kPresetKey);
    } else {
      await prefs.setString(_kAnime4kPresetKey, _anime4kPreset.id);
    }

    if (_serverIconLibraryUrls.isEmpty) {
      await prefs.remove(_kServerIconLibraryUrlsKey);
    } else {
      await prefs.setStringList(
        _kServerIconLibraryUrlsKey,
        _serverIconLibraryUrls,
      );
    }

    await prefs.setBool(_kDanmakuEnabledKey, _danmakuEnabled);
    await prefs.setString(_kDanmakuLoadModeKey, _danmakuLoadMode.id);
    await prefs.setStringList(_kDanmakuApiUrlsKey, _danmakuApiUrls);
    if (_danmakuAppId.isEmpty) {
      await prefs.remove(_kDanmakuAppIdKey);
    } else {
      await prefs.setString(_kDanmakuAppIdKey, _danmakuAppId);
    }
    if (_danmakuAppSecret.isEmpty) {
      await prefs.remove(_kDanmakuAppSecretKey);
    } else {
      await prefs.setString(_kDanmakuAppSecretKey, _danmakuAppSecret);
    }
    await prefs.setDouble(_kDanmakuOpacityKey, _danmakuOpacity);
    await prefs.setDouble(_kDanmakuScaleKey, _danmakuScale);
    await prefs.setDouble(_kDanmakuSpeedKey, _danmakuSpeed);
    await prefs.setBool(_kDanmakuBoldKey, _danmakuBold);
    await prefs.setInt(_kDanmakuMaxLinesKey, _danmakuMaxLines);
    await prefs.setInt(_kDanmakuTopMaxLinesKey, _danmakuTopMaxLines);
    await prefs.setInt(_kDanmakuBottomMaxLinesKey, _danmakuBottomMaxLines);
    await prefs.setBool(
      _kDanmakuRememberSelectedSourceKey,
      _danmakuRememberSelectedSource,
    );
    if (_danmakuLastSelectedSourceName.isEmpty) {
      await prefs.remove(_kDanmakuLastSelectedSourceNameKey);
    } else {
      await prefs.setString(
        _kDanmakuLastSelectedSourceNameKey,
        _danmakuLastSelectedSourceName,
      );
    }
    await prefs.setBool(_kDanmakuMergeDuplicatesKey, _danmakuMergeDuplicates);
    await prefs.setBool(_kDanmakuMergeRelatedKey, _danmakuMergeRelated);
    await prefs.setBool(_kDanmakuShowHeatmapKey, _danmakuShowHeatmap);
    await prefs.setBool(_kDanmakuPreventOverlapKey, _danmakuPreventOverlap);
    if (_danmakuBlockWords.trim().isEmpty) {
      await prefs.remove(_kDanmakuBlockWordsKey);
    } else {
      await prefs.setString(_kDanmakuBlockWordsKey, _danmakuBlockWords);
    }
    await prefs.setString(_kDanmakuMatchModeKey, _danmakuMatchMode.id);
    await prefs.setString(_kDanmakuChConvertKey, _danmakuChConvert.id);

    await prefs.setBool(_kGestureBrightnessKey, _gestureBrightness);
    await prefs.setBool(_kGestureVolumeKey, _gestureVolume);
    await prefs.setBool(_kGestureSeekKey, _gestureSeek);
    await prefs.setBool(_kGestureLongPressSpeedKey, _gestureLongPressSpeed);
    await prefs.setDouble(
        _kLongPressSpeedMultiplierKey, _longPressSpeedMultiplier);
    await prefs.setBool(_kLongPressSlideSpeedKey, _longPressSlideSpeed);
    await prefs.setString(_kDoubleTapLeftKey, _doubleTapLeft.id);
    await prefs.setString(_kDoubleTapCenterKey, _doubleTapCenter.id);
    await prefs.setString(_kDoubleTapRightKey, _doubleTapRight.id);
    await prefs.setString(_kReturnHomeBehaviorKey, _returnHomeBehavior.id);
    await prefs.setBool(
        _kShowSystemTimeInControlsKey, _showSystemTimeInControls);
    await prefs.setBool(_kShowBufferSpeedKey, _showBufferSpeed);
    await prefs.setBool(_kShowBatteryInControlsKey, _showBatteryInControls);
    await prefs.setInt(_kSeekBackwardSecondsKey, _seekBackwardSeconds);
    await prefs.setInt(_kSeekForwardSecondsKey, _seekForwardSeconds);
    await prefs.setBool(_kForceRemoteControlKeysKey, _forceRemoteControlKeys);

    await _persistServers(prefs);
    if (_activeServerId == null) {
      await prefs.remove(_kActiveServerIdKey);
    } else {
      await prefs.setString(_kActiveServerIdKey, _activeServerId!);
    }

    notifyListeners();
  }

  Future<void> leaveServer() async {
    _activeServerId = null;
    _domains = [];
    _libraries = [];
    _itemsCache.clear();
    _itemsTotal.clear();
    _homeSections.clear();
    _randomRecommendations = null;
    _randomRecommendationsInFlight = null;
    _continueWatching = null;
    _continueWatchingInFlight = null;
    _resetPerServerCaches();
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_kActiveServerIdKey);
    notifyListeners();
  }

  Future<void> addServer({
    required String hostOrUrl,
    required String scheme,
    String? port,
    MediaServerType serverType = MediaServerType.emby,
    required String username,
    required String password,
    String? displayName,
    String? remark,
    String? iconUrl,
    List<CustomDomain>? customDomains,
    bool activate = true,
  }) async {
    _loading = true;
    _error = null;
    notifyListeners();

    final fixedUsername = username.trim();
    final fixedRemark = (remark ?? '').trim();
    final fixedIconUrl = iconUrl?.trim();
    final fixedDisplayName = (displayName ?? '').trim();

    try {
      if (!serverType.isEmbyLike) {
        _error = '当前版本仅支持 Emby/Jellyfin 登录；Plex 请用 Plex 登录入口添加。';
        return;
      }
      final api = EmbyApi(
        hostOrUrl: hostOrUrl,
        preferredScheme: scheme,
        port: port,
        serverType: serverType,
        deviceId: _deviceId,
      );
      final auth = await api.authenticate(
        username: fixedUsername,
        password: password,
        deviceId: _deviceId,
        serverType: serverType,
      );
      final apiForServer = EmbyApi(
        hostOrUrl: auth.baseUrlUsed,
        preferredScheme: scheme,
        apiPrefix: auth.apiPrefixUsed,
        serverType: serverType,
        deviceId: _deviceId,
      );

      String? serverName;
      try {
        serverName = await apiForServer.fetchServerName(auth.baseUrlUsed,
            token: auth.token);
      } catch (_) {
        // best-effort
      }

      final name = fixedDisplayName.isNotEmpty
          ? fixedDisplayName
          : ((serverName ?? '').trim().isNotEmpty
              ? serverName!.trim()
              : _suggestServerName(auth.baseUrlUsed));

      final existingIndex = _servers.indexWhere(
        (s) => s.baseUrl == auth.baseUrlUsed && s.serverType == serverType,
      );

      final resolvedIconUrl = switch (fixedIconUrl) {
        null => existingIndex >= 0 ? _servers[existingIndex].iconUrl : null,
        _ => fixedIconUrl.isEmpty ? null : fixedIconUrl,
      };
      final server = ServerProfile(
        id: existingIndex >= 0 ? _servers[existingIndex].id : _randomId(),
        serverType: serverType,
        username: fixedUsername,
        name: name,
        remark: fixedRemark.isEmpty ? null : fixedRemark,
        iconUrl: resolvedIconUrl,
        baseUrl: auth.baseUrlUsed,
        token: auth.token,
        userId: auth.userId,
        apiPrefix: auth.apiPrefixUsed,
        lastErrorCode: null,
        lastErrorMessage: null,
        hiddenLibraries:
            existingIndex >= 0 ? _servers[existingIndex].hiddenLibraries : null,
        domainRemarks:
            existingIndex >= 0 ? _servers[existingIndex].domainRemarks : null,
        customDomains:
            existingIndex >= 0 ? _servers[existingIndex].customDomains : null,
      );

      if (customDomains != null && customDomains.isNotEmpty) {
        _mergeCustomDomains(server, customDomains);
      }

      if (existingIndex >= 0) {
        _servers[existingIndex] = server;
      } else {
        _servers.add(server);
      }

      final prefs = await SharedPreferences.getInstance();
      await _persistServers(prefs);

      if (!activate) return;

      try {
        final lines = await apiForServer.fetchDomains(
          auth.token,
          auth.baseUrlUsed,
          allowFailure: true,
        );
        final libs = await apiForServer.fetchLibraries(
          token: auth.token,
          baseUrl: auth.baseUrlUsed,
          userId: auth.userId,
        );

        _activeServerId = server.id;
        _domains = lines;
        _libraries = libs;
        _itemsCache.clear();
        _itemsTotal.clear();
        _homeSections.clear();
        _randomRecommendations = null;
        _randomRecommendationsInFlight = null;
        _continueWatching = null;
        _continueWatchingInFlight = null;
        await prefs.setString(_kActiveServerIdKey, server.id);
      } catch (e) {
        final msg = e.toString();
        _error = msg;
        server.lastErrorCode = _extractHttpStatusCode(msg);
        server.lastErrorMessage = msg;
        await _persistServers(prefs);
      }
    } catch (e) {
      final msg = e.toString();
      _error = msg;

      final code = _extractHttpStatusCode(msg);
      final inferredBaseUrl = _tryExtractAuthBaseUrl(msg) ??
          _normalizeServerBaseUrl(
              _normalizeUrl(hostOrUrl, defaultScheme: scheme));

      final existingIndex = _servers.indexWhere(
        (s) => s.baseUrl == inferredBaseUrl && s.serverType == serverType,
      );

      if (existingIndex >= 0) {
        final s = _servers[existingIndex];
        s.lastErrorCode = code;
        s.lastErrorMessage = msg;
      } else {
        final name = fixedDisplayName.isNotEmpty
            ? fixedDisplayName
            : _suggestServerName(inferredBaseUrl);
        final server = ServerProfile(
          id: _randomId(),
          serverType: serverType,
          username: fixedUsername,
          name: name,
          remark: fixedRemark.isEmpty ? null : fixedRemark,
          iconUrl: (fixedIconUrl == null || fixedIconUrl.isEmpty)
              ? null
              : fixedIconUrl,
          baseUrl: inferredBaseUrl,
          token: '',
          userId: '',
          apiPrefix: serverType == MediaServerType.jellyfin ? '' : 'emby',
          lastErrorCode: code,
          lastErrorMessage: msg,
        );
        if (customDomains != null && customDomains.isNotEmpty) {
          _mergeCustomDomains(server, customDomains);
        }
        _servers.add(server);
      }

      final prefs = await SharedPreferences.getInstance();
      await _persistServers(prefs);
    } finally {
      _loading = false;
      notifyListeners();
    }
  }

  Future<void> addPlexServer({
    required String baseUrl,
    required String token,
    String? displayName,
    String? remark,
    String? iconUrl,
    String? plexMachineIdentifier,
  }) async {
    _loading = true;
    _error = null;
    notifyListeners();

    final fixedBaseUrl =
        _normalizeServerBaseUrl(_normalizeUrl(baseUrl, defaultScheme: 'https'));
    final fixedToken = token.trim();
    final fixedName = (displayName ?? '').trim();
    final fixedRemark = (remark ?? '').trim();
    final fixedIconUrl = iconUrl?.trim();
    final fixedMachineId = (plexMachineIdentifier ?? '').trim();

    try {
      if (fixedBaseUrl.isEmpty || !_isValidHttpUrl(fixedBaseUrl)) {
        throw const FormatException('Invalid Plex server url');
      }
      if (fixedToken.isEmpty) {
        throw const FormatException('Missing Plex token');
      }

      final name =
          fixedName.isNotEmpty ? fixedName : _suggestServerName(fixedBaseUrl);

      final existingIndex = _servers.indexWhere(
        (s) =>
            s.baseUrl == fixedBaseUrl && s.serverType == MediaServerType.plex,
      );

      final resolvedIconUrl = switch (fixedIconUrl) {
        null => existingIndex >= 0 ? _servers[existingIndex].iconUrl : null,
        _ => fixedIconUrl.isEmpty ? null : fixedIconUrl,
      };

      final server = ServerProfile(
        id: existingIndex >= 0 ? _servers[existingIndex].id : _randomId(),
        serverType: MediaServerType.plex,
        username: '',
        name: name,
        remark: fixedRemark.isEmpty ? null : fixedRemark,
        iconUrl: resolvedIconUrl,
        baseUrl: fixedBaseUrl,
        token: fixedToken,
        userId: '',
        apiPrefix: '',
        plexMachineIdentifier: fixedMachineId.isEmpty ? null : fixedMachineId,
        lastErrorCode: null,
        lastErrorMessage: null,
        hiddenLibraries:
            existingIndex >= 0 ? _servers[existingIndex].hiddenLibraries : null,
        domainRemarks:
            existingIndex >= 0 ? _servers[existingIndex].domainRemarks : null,
        customDomains:
            existingIndex >= 0 ? _servers[existingIndex].customDomains : null,
      );

      if (existingIndex >= 0) {
        _servers[existingIndex] = server;
      } else {
        _servers.add(server);
      }

      final prefs = await SharedPreferences.getInstance();
      await _persistServers(prefs);
    } catch (e) {
      _error = e.toString();
    } finally {
      _loading = false;
      notifyListeners();
    }
  }

  Future<void> addWebDavServer({
    required String baseUrl,
    required String username,
    required String password,
    String? displayName,
    String? remark,
    String? iconUrl,
    bool activate = true,
  }) async {
    _loading = true;
    _error = null;
    notifyListeners();

    final fixedUsername = username.trim();
    final fixedRemark = (remark ?? '').trim();
    final fixedIconUrl = iconUrl?.trim();
    final fixedName = (displayName ?? '').trim();

    Uri baseUri;
    try {
      baseUri = WebDavApi.normalizeBaseUri(baseUrl);
    } catch (e) {
      _error = e.toString();
      _loading = false;
      notifyListeners();
      return;
    }
    final fixedBaseUrl = baseUri.toString();

    final name =
        fixedName.isNotEmpty ? fixedName : _suggestServerName(fixedBaseUrl);

    final existingIndex = _servers.indexWhere(
      (s) =>
          s.serverType == MediaServerType.webdav &&
          s.baseUrl == fixedBaseUrl &&
          s.username == fixedUsername,
    );

    final resolvedIconUrl = switch (fixedIconUrl) {
      null => existingIndex >= 0 ? _servers[existingIndex].iconUrl : null,
      _ => fixedIconUrl.isEmpty ? null : fixedIconUrl,
    };

    final server = ServerProfile(
      id: existingIndex >= 0 ? _servers[existingIndex].id : _randomId(),
      serverType: MediaServerType.webdav,
      username: fixedUsername,
      name: name,
      remark: fixedRemark.isEmpty ? null : fixedRemark,
      iconUrl: resolvedIconUrl,
      baseUrl: fixedBaseUrl,
      token: password,
      userId: '',
      apiPrefix: '',
      lastErrorCode: null,
      lastErrorMessage: null,
      hiddenLibraries:
          existingIndex >= 0 ? _servers[existingIndex].hiddenLibraries : null,
      domainRemarks:
          existingIndex >= 0 ? _servers[existingIndex].domainRemarks : null,
      customDomains:
          existingIndex >= 0 ? _servers[existingIndex].customDomains : null,
    );

    var shouldActivate = activate;

    try {
      final api = WebDavApi(
        baseUri: baseUri,
        username: fixedUsername,
        password: password,
      );
      await api.validateRoot();
    } catch (e) {
      final msg = e.toString();
      server.lastErrorCode = _extractHttpStatusCode(msg);
      server.lastErrorMessage = msg;
      _error = msg;
      shouldActivate = false;
    }

    try {
      if (existingIndex >= 0) {
        _servers[existingIndex] = server;
      } else {
        _servers.add(server);
      }

      final prefs = await SharedPreferences.getInstance();
      await _persistServers(prefs);

      if (!shouldActivate) return;

      _activeServerId = server.id;
      _domains = [];
      _libraries = [];
      _itemsCache.clear();
      _itemsTotal.clear();
      _homeSections.clear();
      _randomRecommendations = null;
      _randomRecommendationsInFlight = null;
      _continueWatching = null;
      _continueWatchingInFlight = null;
      await prefs.setString(_kActiveServerIdKey, server.id);
    } finally {
      _loading = false;
      notifyListeners();
    }
  }

  Future<void> enterServer(String serverId) async {
    final server = _servers.firstWhereOrNull((s) => s.id == serverId);
    if (server == null) return;

    if (server.serverType == MediaServerType.plex) {
      _error = '${server.serverType.label} 暂未支持浏览/播放（仅可保存登录信息）。';
      notifyListeners();
      return;
    }

    if (_activeServerId != serverId) {
      _activeServerId = serverId;
      _domains = [];
      _libraries = [];
      _itemsCache.clear();
      _itemsTotal.clear();
      _homeSections.clear();
      _randomRecommendations = null;
      _randomRecommendationsInFlight = null;
      _continueWatching = null;
      _continueWatchingInFlight = null;
      _resetPerServerCaches();
      _error = null;

      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(_kActiveServerIdKey, serverId);
      if (activeServer?.serverType.isEmbyLike == true) {
        _restoreServerCaches(prefs, serverId);
      }
      notifyListeners();
    }

    if (!server.serverType.isEmbyLike) return;

    await refreshDomains();
    await refreshLibraries();
    unawaited(loadHome(forceRefresh: true));
  }

  Future<void> removeServer(String serverId) async {
    final idx = _servers.indexWhere((s) => s.id == serverId);
    if (idx < 0) return;
    final removingActive = _activeServerId == serverId;
    _servers.removeAt(idx);
    final prefs = await SharedPreferences.getInstance();
    await _persistServers(prefs);
    if (removingActive) {
      await leaveServer();
    } else {
      notifyListeners();
    }
  }

  Future<void> updateServerMeta(
    String serverId, {
    String? username,
    String? name,
    String? remark,
    String? iconUrl,
  }) async {
    final server = _servers.firstWhereOrNull((s) => s.id == serverId);
    if (server == null) return;
    if (username != null) {
      server.username = username.trim();
    }
    if (name != null && name.trim().isNotEmpty) {
      server.name = name.trim();
    }
    if (remark != null) {
      server.remark = remark.trim().isEmpty ? null : remark.trim();
    }
    if (iconUrl != null) {
      server.iconUrl = iconUrl.trim().isEmpty ? null : iconUrl.trim();
    }
    final prefs = await SharedPreferences.getInstance();
    await _persistServers(prefs);
    notifyListeners();
  }

  Future<void> refreshDomains() async {
    if (baseUrl == null || token == null) return;
    _loading = true;
    notifyListeners();
    try {
      final api = EmbyApi(
        hostOrUrl: baseUrl!,
        preferredScheme: 'https',
        apiPrefix: apiPrefix,
        serverType: serverType,
        deviceId: _deviceId,
      );
      _domains = await api.fetchDomains(token!, baseUrl!, allowFailure: true);
      _error = null;
    } catch (e) {
      _error = e.toString();
    } finally {
      _loading = false;
      notifyListeners();
    }
  }

  Future<void> refreshLibraries() async {
    if (baseUrl == null || token == null || userId == null) return;
    _loading = true;
    notifyListeners();
    try {
      final api = EmbyApi(
        hostOrUrl: baseUrl!,
        preferredScheme: 'https',
        apiPrefix: apiPrefix,
        serverType: serverType,
        deviceId: _deviceId,
      );
      _libraries = await api.fetchLibraries(
        token: token!,
        baseUrl: baseUrl!,
        userId: userId!,
      );
      await _persistLibrariesCache();
      _itemsCache.clear();
      _randomRecommendations = null;
      _randomRecommendationsInFlight = null;
      _continueWatching = null;
      _continueWatchingInFlight = null;
      _error = null;
    } catch (e) {
      _error = e.toString();
    } finally {
      _loading = false;
      notifyListeners();
    }
  }

  Future<void> loadItems({
    required String parentId,
    int startIndex = 0,
    int limit = 30,
    String? includeItemTypes,
    String? searchTerm,
    bool recursive = false,
    bool excludeFolders = true,
    String? sortBy,
    String sortOrder = 'Descending',
  }) async {
    if (baseUrl == null || token == null || userId == null) {
      throw Exception('未选择服务器');
    }
    final api = EmbyApi(
      hostOrUrl: baseUrl!,
      preferredScheme: 'https',
      apiPrefix: apiPrefix,
      serverType: serverType,
      deviceId: _deviceId,
    );
    final result = await api.fetchItems(
      token: token!,
      baseUrl: baseUrl!,
      userId: userId!,
      parentId: parentId,
      startIndex: startIndex,
      limit: limit,
      includeItemTypes: includeItemTypes,
      searchTerm: searchTerm,
      recursive: recursive,
      excludeFolders: excludeFolders,
      sortBy: sortBy,
      sortOrder: sortOrder,
    );
    final list = _itemsCache[parentId] ?? [];
    if (startIndex == 0) {
      _itemsCache[parentId] = result.items;
    } else {
      list.addAll(result.items);
      _itemsCache[parentId] = list;
    }
    _itemsTotal[parentId] = result.total;
    notifyListeners();
  }

  Future<void> loadHome({bool forceRefresh = false}) {
    final inFlight = _homeInFlight;
    if (inFlight != null) return inFlight;

    if (!forceRefresh) {
      if (_homeSections.isNotEmpty) return Future.value();
    }

    final future = _loadHomeInternal(forceRefresh: forceRefresh);
    _homeInFlight = future;
    return future.whenComplete(() {
      if (_homeInFlight == future) _homeInFlight = null;
    });
  }

  Future<void> _loadHomeInternal({required bool forceRefresh}) async {
    if (baseUrl == null || token == null || userId == null) return;
    final api = EmbyApi(
      hostOrUrl: baseUrl!,
      preferredScheme: 'https',
      apiPrefix: apiPrefix,
      serverType: serverType,
      deviceId: _deviceId,
    );
    final libIds = _libraries.map((l) => l.id).toSet();
    if (forceRefresh) {
      // Drop sections for libraries that no longer exist, but keep existing
      // sections as a cache while refreshing.
      _homeSections.removeWhere((key, _) {
        if (!key.startsWith('lib_')) return false;
        final libId = key.substring(4);
        return !libIds.contains(libId);
      });
    }
    for (final lib in _libraries) {
      try {
        final fetched = await api.fetchItems(
          token: token!,
          baseUrl: baseUrl!,
          userId: userId!,
          parentId: lib.id,
          includeItemTypes: 'Series,Movie',
          recursive: true,
          excludeFolders: false,
          limit: 12,
          sortBy: 'DateCreated',
        );
        _homeSections['lib_${lib.id}'] = fetched.items;
        _itemsTotal[lib.id] = fetched.total;
        notifyListeners();
      } catch (_) {
        // ignore failures per library
      }
    }
    await _persistHomeCache();
    notifyListeners();
  }

  Future<List<MediaItem>> loadRandomRecommendations({
    bool forceRefresh = false,
  }) {
    if (!forceRefresh) {
      final cached = _randomRecommendations;
      if (cached != null) return Future.value(cached);
      final inFlight = _randomRecommendationsInFlight;
      if (inFlight != null) return inFlight;
    }

    final future = _fetchRandomRecommendations();
    _randomRecommendationsInFlight = future;
    return future.then((items) {
      _randomRecommendations = items;
      return items;
    }).whenComplete(() {
      if (_randomRecommendationsInFlight == future) {
        _randomRecommendationsInFlight = null;
      }
    });
  }

  Future<List<MediaItem>> _fetchRandomRecommendations() async {
    if (baseUrl == null || token == null || userId == null) return const [];

    final api = EmbyApi(
      hostOrUrl: baseUrl!,
      preferredScheme: 'https',
      apiPrefix: apiPrefix,
      serverType: serverType,
      deviceId: _deviceId,
    );
    // Fetch a few more to increase the chance of getting items with artwork.
    final res = await api.fetchRandomRecommendations(
      token: token!,
      baseUrl: baseUrl!,
      userId: userId!,
      limit: 12,
    );

    final withArtwork = res.items.where((e) => e.hasImage).toList();
    return withArtwork.length >= 6
        ? withArtwork.take(6).toList()
        : res.items.take(6).toList();
  }

  Future<List<MediaItem>> loadContinueWatching({
    bool forceRefresh = false,
  }) {
    if (!forceRefresh) {
      final cached = _continueWatching;
      if (cached != null) return Future.value(cached);
      final inFlight = _continueWatchingInFlight;
      if (inFlight != null) return inFlight;
    }

    final future = _fetchContinueWatching();
    _continueWatchingInFlight = future;
    return future.then((items) {
      _continueWatching = items;
      return items;
    }).whenComplete(() {
      if (_continueWatchingInFlight == future) {
        _continueWatchingInFlight = null;
      }
    });
  }

  Future<List<MediaItem>> _fetchContinueWatching() async {
    if (baseUrl == null || token == null || userId == null) return const [];

    final api = EmbyApi(
      hostOrUrl: baseUrl!,
      preferredScheme: 'https',
      apiPrefix: apiPrefix,
      serverType: serverType,
      deviceId: _deviceId,
    );
    final res = await api.fetchContinueWatching(
      token: token!,
      baseUrl: baseUrl!,
      userId: userId!,
      // Fetch more than we show because we de-duplicate per series (episodes) & may
      // otherwise end up with too few unique shows.
      limit: 60,
    );

    final seen = <String>{};
    final deduped = <MediaItem>[];
    for (final item in res.items) {
      final type = item.type.toLowerCase().trim();
      final key = type == 'episode'
          ? ((item.seriesId ?? '').trim().isNotEmpty
              ? 'series:${item.seriesId}'
              : (item.seriesName.trim().isNotEmpty
                  ? 'seriesName:${item.seriesName.trim()}'
                  : 'item:${item.id}'))
          : 'item:${item.id}';
      if (seen.add(key)) {
        deduped.add(item);
      }
      if (deduped.length >= 20) break;
    }
    return deduped;
  }

  Future<void> setBaseUrl(String url) async {
    final server = activeServer;
    if (server == null) return;
    server.baseUrl = url;
    final prefs = await SharedPreferences.getInstance();
    await _persistServers(prefs);
    notifyListeners();
  }

  String? domainRemark(String url) => activeServer?.domainRemarks[url];

  Future<void> setDomainRemark(String url, String? remark) async {
    final server = activeServer;
    if (server == null) return;
    final v = (remark ?? '').trim();
    if (v.isEmpty) {
      server.domainRemarks.remove(url);
    } else {
      server.domainRemarks[url] = v;
    }
    final prefs = await SharedPreferences.getInstance();
    await _persistServers(prefs);
    notifyListeners();
  }

  List<CustomDomain> get customDomains =>
      activeServer?.customDomains ?? const <CustomDomain>[];

  static String _normalizeUrl(String raw, {String defaultScheme = 'https'}) {
    final v = raw.trim();
    if (v.isEmpty) return '';
    final parsed = Uri.tryParse(v);
    if (parsed != null && parsed.hasScheme) return v;
    return '$defaultScheme://$v';
  }

  static int? _extractHttpStatusCode(String message) {
    final v = message.trim();
    if (v.isEmpty) return null;

    final patterns = <RegExp>[
      RegExp(r'HTTP\s+(\d{3})', caseSensitive: false),
      RegExp(r'[（(](\d{3})[)）]'),
    ];

    for (final re in patterns) {
      final m = re.firstMatch(v);
      if (m == null) continue;
      final code = int.tryParse(m.group(1) ?? '');
      if (code != null && code >= 100 && code <= 599) return code;
    }
    return null;
  }

  static String? _tryExtractAuthBaseUrl(String message) {
    final v = message.trim();
    if (v.isEmpty) return null;

    final matches = RegExp(
      r'(https?://[^\s|]+):\s*HTTP\s*(\d{3})',
      caseSensitive: false,
    ).allMatches(v).toList(growable: false);

    if (matches.isEmpty) return null;

    RegExpMatch pick(RegExpMatch a, RegExpMatch b) {
      final ac = int.tryParse(a.group(2) ?? '') ?? 0;
      final bc = int.tryParse(b.group(2) ?? '') ?? 0;
      final aAuth = ac == 401 || ac == 403;
      final bAuth = bc == 401 || bc == 403;
      if (aAuth != bAuth) return aAuth ? a : b;
      return a;
    }

    var best = matches.first;
    for (final m in matches.skip(1)) {
      best = pick(best, m);
    }

    final url = best.group(1) ?? '';
    final uri = Uri.tryParse(url);
    if (uri == null || uri.host.isEmpty) return null;

    final segs = uri.pathSegments.toList(growable: false);
    if (segs.length < 3) return _normalizeServerBaseUrl(uri.toString());

    final tail =
        segs.skip(segs.length - 3).map((e) => e.toLowerCase()).toList();
    if (tail[0] != 'emby' ||
        tail[1] != 'users' ||
        tail[2] != 'authenticatebyname') {
      return _normalizeServerBaseUrl(uri.toString());
    }

    final kept = segs.take(segs.length - 3).toList(growable: false);
    final path = kept.isEmpty ? '' : '/${kept.join('/')}';
    return _normalizeServerBaseUrl(
      uri.replace(path: path, query: null, fragment: null).toString(),
    );
  }

  static String _normalizeServerBaseUrl(String raw) {
    final v = raw.trim();
    if (v.isEmpty) return '';

    Uri? uri;
    try {
      uri = Uri.parse(v);
    } catch (_) {
      return v;
    }
    if (uri.host.isEmpty) return v;

    final segments = uri.pathSegments.toList(growable: true);
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

    final path = segments.isEmpty ? '' : '/${segments.join('/')}';
    return uri.replace(path: path, query: null, fragment: null).toString();
  }

  static bool _isValidHttpUrl(String raw) {
    final uri = Uri.tryParse(raw);
    if (uri == null) return false;
    return (uri.scheme == 'http' || uri.scheme == 'https') &&
        uri.host.isNotEmpty;
  }

  Future<void> addCustomDomain({
    required String name,
    required String url,
    String? remark,
  }) async {
    final server = activeServer;
    if (server == null) return;

    final fixedUrl = _normalizeUrl(url, defaultScheme: 'https');
    if (!_isValidHttpUrl(fixedUrl)) {
      throw Exception('线路地址不合法：$url');
    }

    final fixedName = name.trim().isEmpty ? fixedUrl : name.trim();
    server.customDomains.removeWhere((d) => d.url == fixedUrl);
    server.customDomains.add(CustomDomain(name: fixedName, url: fixedUrl));

    final r = (remark ?? '').trim();
    if (r.isNotEmpty) {
      server.domainRemarks[fixedUrl] = r;
    }

    final prefs = await SharedPreferences.getInstance();
    await _persistServers(prefs);
    notifyListeners();
  }

  Future<void> updateCustomDomain(
    String oldUrl, {
    required String name,
    required String url,
    String? remark,
  }) async {
    final server = activeServer;
    if (server == null) return;

    final fixedUrl = _normalizeUrl(url, defaultScheme: 'https');
    if (!_isValidHttpUrl(fixedUrl)) {
      throw Exception('线路地址不合法：$url');
    }

    final fixedName = name.trim().isEmpty ? fixedUrl : name.trim();
    final idx = server.customDomains.indexWhere((d) => d.url == oldUrl);
    if (idx < 0) return;

    server.customDomains[idx] = CustomDomain(name: fixedName, url: fixedUrl);

    if (oldUrl != fixedUrl) {
      final oldRemark = server.domainRemarks.remove(oldUrl);
      if (oldRemark != null && oldRemark.trim().isNotEmpty) {
        server.domainRemarks[fixedUrl] = oldRemark;
      }
    }

    final r = (remark ?? '').trim();
    if (r.isNotEmpty) {
      server.domainRemarks[fixedUrl] = r;
    }

    final prefs = await SharedPreferences.getInstance();
    await _persistServers(prefs);
    notifyListeners();
  }

  Future<void> removeCustomDomain(String url) async {
    final server = activeServer;
    if (server == null) return;

    server.customDomains.removeWhere((d) => d.url == url);
    server.domainRemarks.remove(url);

    final prefs = await SharedPreferences.getInstance();
    await _persistServers(prefs);
    notifyListeners();
  }

  void toggleLibraryHidden(String libId) async {
    final server = activeServer;
    if (server == null) return;
    if (server.hiddenLibraries.contains(libId)) {
      server.hiddenLibraries.remove(libId);
    } else {
      server.hiddenLibraries.add(libId);
    }
    final prefs = await SharedPreferences.getInstance();
    await _persistServers(prefs);
    notifyListeners();
  }

  bool isLibraryHidden(String libId) =>
      activeServer?.hiddenLibraries.contains(libId) == true;

  void sortLibrariesByName() {
    _libraries.sort((a, b) => a.name.compareTo(b.name));
    notifyListeners();
  }

  Future<void> setThemeMode(ThemeMode mode) async {
    _themeMode = mode;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_kThemeModeKey, _encodeThemeMode(mode));
    notifyListeners();
  }

  Future<void> setUiScaleFactor(double factor) async {
    final v = factor.clamp(0.5, 2.0).toDouble();
    if (_uiScaleFactor == v) return;
    _uiScaleFactor = v;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setDouble(_kUiScaleFactorKey, v);
    notifyListeners();
  }

  Future<void> setCompactMode(bool enabled) async {
    if (_compactMode == enabled) return;
    _compactMode = enabled;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_kCompactModeKey, enabled);
    notifyListeners();
  }

  Future<void> setUseDynamicColor(bool enabled) async {
    _useDynamicColor = enabled;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_kDynamicColorKey, enabled);
    notifyListeners();
  }

  Future<void> setUiTemplate(UiTemplate template) async {
    if (_uiTemplate == template) return;
    _uiTemplate = template;
    if (template == UiTemplate.proTool) {
      _compactMode = true;
    }
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_kUiTemplateKey, template.id);
    if (template == UiTemplate.proTool) {
      await prefs.setBool(_kCompactModeKey, _compactMode);
    }
    notifyListeners();
  }

  Future<void> setPreferHardwareDecode(bool enabled) async {
    _preferHardwareDecode = enabled;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_kPreferHardwareDecodeKey, enabled);
    notifyListeners();
  }

  Future<void> setPlayerCore(PlayerCore core) async {
    if (_playerCore == core) return;
    _playerCore = core;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_kPlayerCoreKey, core.id);
    notifyListeners();
  }

  Future<void> setPreferredAudioLang(String lang) async {
    _preferredAudioLang = lang.trim();
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_kPreferredAudioLangKey, _preferredAudioLang);
    notifyListeners();
  }

  Future<void> setPreferredSubtitleLang(String lang) async {
    _preferredSubtitleLang = lang.trim();
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_kPreferredSubtitleLangKey, _preferredSubtitleLang);
    notifyListeners();
  }

  Future<void> setPreferredVideoVersion(VideoVersionPreference pref) async {
    _preferredVideoVersion = pref;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_kPreferredVideoVersionKey, pref.id);
    notifyListeners();
  }

  Future<void> setAppIconId(String id) async {
    _appIconId = id.trim().isEmpty ? 'default' : id.trim();
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_kAppIconIdKey, _appIconId);
    notifyListeners();
  }

  Future<void> setServerListLayout(ServerListLayout layout) async {
    if (_serverListLayout == layout) return;
    _serverListLayout = layout;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_kServerListLayoutKey, layout.id);
    notifyListeners();
  }

  Future<void> setMpvCacheSizeMb(int mb) async {
    final v = mb.clamp(200, 2048);
    if (_mpvCacheSizeMb == v) return;
    _mpvCacheSizeMb = v;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setInt(_kMpvCacheSizeMbKey, _mpvCacheSizeMb);
    notifyListeners();
  }

  Future<void> setPlaybackBufferPreset(PlaybackBufferPreset preset) async {
    final suggested = preset.suggestedBackRatio;
    final nextRatio = suggested == null
        ? _playbackBufferBackRatio
        : suggested.clamp(0.0, 0.30).toDouble();
    if (_playbackBufferPreset == preset &&
        (_playbackBufferBackRatio - nextRatio).abs() < 0.00001) {
      return;
    }
    _playbackBufferPreset = preset;
    _playbackBufferBackRatio = nextRatio;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_kPlaybackBufferPresetKey, preset.id);
    await prefs.setDouble(
      _kPlaybackBufferBackRatioKey,
      _playbackBufferBackRatio,
    );
    notifyListeners();
  }

  Future<void> setPlaybackBufferBackRatio(double ratio) async {
    final v = ratio.clamp(0.0, 0.30).toDouble();
    if (_playbackBufferPreset == PlaybackBufferPreset.custom &&
        (_playbackBufferBackRatio - v).abs() < 0.00001) {
      return;
    }
    _playbackBufferPreset = PlaybackBufferPreset.custom;
    _playbackBufferBackRatio = v;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_kPlaybackBufferPresetKey, _playbackBufferPreset.id);
    await prefs.setDouble(
      _kPlaybackBufferBackRatioKey,
      _playbackBufferBackRatio,
    );
    notifyListeners();
  }

  Future<void> setFlushBufferOnSeek(bool enabled) async {
    if (_flushBufferOnSeek == enabled) return;
    _flushBufferOnSeek = enabled;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_kFlushBufferOnSeekKey, enabled);
    notifyListeners();
  }

  Future<void> setUnlimitedStreamCache(bool enabled) async {
    if (_unlimitedStreamCache == enabled) return;
    _unlimitedStreamCache = enabled;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_kUnlimitedStreamCacheKey, enabled);
    notifyListeners();
  }

  static String _normalizeDanmakuApiUrl(String url) {
    final raw = url.trim();
    if (raw.isEmpty) return '';
    try {
      var uri = Uri.parse(raw);
      if (!uri.hasScheme) {
        uri = Uri.parse('https://$raw');
      }
      final normalized = uri.replace(
        fragment: '',
        query: '',
        path: uri.path.replaceAll(RegExp(r'/+$'), ''),
      );
      var text = normalized.toString();
      text = text.replaceAll(RegExp(r'[?#]+$'), '');
      return text.replaceAll(RegExp(r'/+$'), '');
    } catch (_) {
      return raw.replaceAll(RegExp(r'/+$'), '');
    }
  }

  static String _normalizeServerIconLibraryUrl(String url) {
    final raw = url.trim();
    if (raw.isEmpty) return '';
    try {
      var uri = Uri.parse(raw);
      if (!uri.hasScheme) {
        uri = Uri.parse('https://$raw');
      }
      if (uri.scheme != 'http' && uri.scheme != 'https') return '';
      uri = uri.replace(fragment: '');
      var text = uri.toString();
      text = text.replaceAll(RegExp(r'[?#]+$'), '');
      return text;
    } catch (_) {
      return '';
    }
  }

  Future<void> setEnableBlurEffects(bool enabled) async {
    if (_enableBlurEffects == enabled) return;
    _enableBlurEffects = enabled;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_kEnableBlurEffectsKey, enabled);
    notifyListeners();
  }

  Future<void> setShowHomeLibraryQuickAccess(bool enabled) async {
    if (_showHomeLibraryQuickAccess == enabled) return;
    _showHomeLibraryQuickAccess = enabled;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_kShowHomeLibraryQuickAccessKey, enabled);
    notifyListeners();
  }

  Future<void> setAutoUpdateEnabled(bool enabled) async {
    if (_autoUpdateEnabled == enabled) return;
    _autoUpdateEnabled = enabled;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_kAutoUpdateEnabledKey, enabled);
    notifyListeners();
  }

  Future<void> setAutoUpdateLastCheckedAt(DateTime at) async {
    final ms = at.millisecondsSinceEpoch;
    if (_autoUpdateLastCheckedAtMs == ms) return;
    _autoUpdateLastCheckedAtMs = ms;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setInt(_kAutoUpdateLastCheckedAtMsKey, ms);
  }

  Future<void> setExternalMpvPath(String path) async {
    final p = path.trim();
    if (_externalMpvPath == p) return;
    _externalMpvPath = p;
    final prefs = await SharedPreferences.getInstance();
    if (p.isEmpty) {
      await prefs.remove(_kExternalMpvPathKey);
    } else {
      await prefs.setString(_kExternalMpvPathKey, p);
    }
    notifyListeners();
  }

  Future<void> setAnime4kPreset(Anime4kPreset preset) async {
    if (_anime4kPreset == preset) return;
    _anime4kPreset = preset;
    final prefs = await SharedPreferences.getInstance();
    if (_anime4kPreset.isOff) {
      await prefs.remove(_kAnime4kPresetKey);
    } else {
      await prefs.setString(_kAnime4kPresetKey, _anime4kPreset.id);
    }
    notifyListeners();
  }

  Future<void> setDanmakuEnabled(bool enabled) async {
    if (_danmakuEnabled == enabled) return;
    _danmakuEnabled = enabled;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_kDanmakuEnabledKey, enabled);
    notifyListeners();
  }

  Future<void> setDanmakuLoadMode(DanmakuLoadMode mode) async {
    if (_danmakuLoadMode == mode) return;
    _danmakuLoadMode = mode;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_kDanmakuLoadModeKey, mode.id);
    notifyListeners();
  }

  Future<void> setDanmakuApiUrls(List<String> urls) async {
    final normalized =
        urls.map(_normalizeDanmakuApiUrl).where((e) => e.isNotEmpty).toList();
    _danmakuApiUrls = normalized;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setStringList(_kDanmakuApiUrlsKey, normalized);
    notifyListeners();
  }

  Future<void> addDanmakuApiUrl(String url) async {
    final u = _normalizeDanmakuApiUrl(url);
    if (u.isEmpty) return;
    final exists =
        _danmakuApiUrls.any((e) => e.toLowerCase() == u.toLowerCase());
    if (exists) return;
    await setDanmakuApiUrls([..._danmakuApiUrls, u]);
  }

  Future<void> removeDanmakuApiUrlAt(int index) async {
    if (index < 0 || index >= _danmakuApiUrls.length) return;
    final next = [..._danmakuApiUrls]..removeAt(index);
    await setDanmakuApiUrls(next);
  }

  Future<void> reorderDanmakuApiUrls(int oldIndex, int newIndex) async {
    if (oldIndex < 0 || oldIndex >= _danmakuApiUrls.length) return;
    final next = [..._danmakuApiUrls];
    if (newIndex > oldIndex) newIndex -= 1;
    final item = next.removeAt(oldIndex);
    next.insert(newIndex.clamp(0, next.length), item);
    await setDanmakuApiUrls(next);
  }

  Future<void> setServerIconLibraryUrls(List<String> urls) async {
    final seen = <String>{};
    final normalized = urls
        .map(_normalizeServerIconLibraryUrl)
        .where((e) => e.isNotEmpty)
        .where((e) => seen.add(e.toLowerCase()))
        .toList(growable: false);
    _serverIconLibraryUrls = normalized;
    final prefs = await SharedPreferences.getInstance();
    if (normalized.isEmpty) {
      await prefs.remove(_kServerIconLibraryUrlsKey);
    } else {
      await prefs.setStringList(_kServerIconLibraryUrlsKey, normalized);
    }
    notifyListeners();
  }

  Future<bool> addServerIconLibraryUrl(String url) async {
    final u = _normalizeServerIconLibraryUrl(url);
    if (u.isEmpty) return false;
    final exists = _serverIconLibraryUrls.any(
      (e) => e.toLowerCase() == u.toLowerCase(),
    );
    if (exists) return false;
    await setServerIconLibraryUrls([..._serverIconLibraryUrls, u]);
    return true;
  }

  Future<void> removeServerIconLibraryUrlAt(int index) async {
    if (index < 0 || index >= _serverIconLibraryUrls.length) return;
    final next = [..._serverIconLibraryUrls]..removeAt(index);
    await setServerIconLibraryUrls(next);
  }

  Future<void> reorderServerIconLibraryUrls(int oldIndex, int newIndex) async {
    if (oldIndex < 0 || oldIndex >= _serverIconLibraryUrls.length) return;
    final next = [..._serverIconLibraryUrls];
    if (newIndex > oldIndex) newIndex -= 1;
    final item = next.removeAt(oldIndex);
    next.insert(newIndex.clamp(0, next.length), item);
    await setServerIconLibraryUrls(next);
  }

  Future<void> setDanmakuAppId(String id) async {
    final v = id.trim();
    if (_danmakuAppId == v) return;
    _danmakuAppId = v;
    final prefs = await SharedPreferences.getInstance();
    if (v.isEmpty) {
      await prefs.remove(_kDanmakuAppIdKey);
    } else {
      await prefs.setString(_kDanmakuAppIdKey, v);
    }
    notifyListeners();
  }

  Future<void> setDanmakuAppSecret(String secret) async {
    final v = secret.trim();
    if (_danmakuAppSecret == v) return;
    _danmakuAppSecret = v;
    final prefs = await SharedPreferences.getInstance();
    if (v.isEmpty) {
      await prefs.remove(_kDanmakuAppSecretKey);
    } else {
      await prefs.setString(_kDanmakuAppSecretKey, v);
    }
    notifyListeners();
  }

  Future<void> setDanmakuOpacity(double opacity) async {
    final v = opacity.clamp(0.2, 1.0).toDouble();
    if ((_danmakuOpacity - v).abs() < 0.001) return;
    _danmakuOpacity = v;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setDouble(_kDanmakuOpacityKey, v);
    notifyListeners();
  }

  Future<void> setDanmakuScale(double scale) async {
    final v = scale.clamp(0.5, 1.6).toDouble();
    if ((_danmakuScale - v).abs() < 0.001) return;
    _danmakuScale = v;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setDouble(_kDanmakuScaleKey, v);
    notifyListeners();
  }

  Future<void> setDanmakuSpeed(double speed) async {
    final v = speed.clamp(0.4, 2.5).toDouble();
    if ((_danmakuSpeed - v).abs() < 0.001) return;
    _danmakuSpeed = v;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setDouble(_kDanmakuSpeedKey, v);
    notifyListeners();
  }

  Future<void> setDanmakuBold(bool bold) async {
    if (_danmakuBold == bold) return;
    _danmakuBold = bold;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_kDanmakuBoldKey, bold);
    notifyListeners();
  }

  Future<void> setDanmakuMaxLines(int lines) async {
    final v = lines.clamp(1, 40);
    if (_danmakuMaxLines == v) return;
    _danmakuMaxLines = v;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setInt(_kDanmakuMaxLinesKey, v);
    notifyListeners();
  }

  Future<void> setDanmakuTopMaxLines(int lines) async {
    final v = lines.clamp(0, 40);
    if (_danmakuTopMaxLines == v) return;
    _danmakuTopMaxLines = v;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setInt(_kDanmakuTopMaxLinesKey, v);
    notifyListeners();
  }

  Future<void> setDanmakuBottomMaxLines(int lines) async {
    final v = lines.clamp(0, 40);
    if (_danmakuBottomMaxLines == v) return;
    _danmakuBottomMaxLines = v;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setInt(_kDanmakuBottomMaxLinesKey, v);
    notifyListeners();
  }

  Future<void> setDanmakuRememberSelectedSource(bool enabled) async {
    if (_danmakuRememberSelectedSource == enabled) return;
    _danmakuRememberSelectedSource = enabled;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_kDanmakuRememberSelectedSourceKey, enabled);
    notifyListeners();
  }

  Future<void> setDanmakuLastSelectedSourceName(String name) async {
    final v = name.trim();
    if (_danmakuLastSelectedSourceName == v) return;
    _danmakuLastSelectedSourceName = v;
    final prefs = await SharedPreferences.getInstance();
    if (v.isEmpty) {
      await prefs.remove(_kDanmakuLastSelectedSourceNameKey);
    } else {
      await prefs.setString(_kDanmakuLastSelectedSourceNameKey, v);
    }
    notifyListeners();
  }

  Future<void> setDanmakuMergeDuplicates(bool enabled) async {
    if (_danmakuMergeDuplicates == enabled) return;
    _danmakuMergeDuplicates = enabled;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_kDanmakuMergeDuplicatesKey, enabled);
    notifyListeners();
  }

  Future<void> setDanmakuMergeRelated(bool enabled) async {
    if (_danmakuMergeRelated == enabled) return;
    _danmakuMergeRelated = enabled;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_kDanmakuMergeRelatedKey, enabled);
    notifyListeners();
  }

  Future<void> setDanmakuShowHeatmap(bool enabled) async {
    if (_danmakuShowHeatmap == enabled) return;
    _danmakuShowHeatmap = enabled;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_kDanmakuShowHeatmapKey, enabled);
    notifyListeners();
  }

  Future<void> setDanmakuPreventOverlap(bool enabled) async {
    if (_danmakuPreventOverlap == enabled) return;
    _danmakuPreventOverlap = enabled;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_kDanmakuPreventOverlapKey, enabled);
    notifyListeners();
  }

  Future<void> setDanmakuBlockWords(String text) async {
    final v = text.replaceAll('\r\n', '\n').trimRight();
    if (_danmakuBlockWords == v) return;
    _danmakuBlockWords = v;
    final prefs = await SharedPreferences.getInstance();
    if (v.isEmpty) {
      await prefs.remove(_kDanmakuBlockWordsKey);
    } else {
      await prefs.setString(_kDanmakuBlockWordsKey, v);
    }
    notifyListeners();
  }

  Future<void> setDanmakuMatchMode(DanmakuMatchMode mode) async {
    if (_danmakuMatchMode == mode) return;
    _danmakuMatchMode = mode;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_kDanmakuMatchModeKey, mode.id);
    notifyListeners();
  }

  Future<void> setDanmakuChConvert(DanmakuChConvert v) async {
    if (_danmakuChConvert == v) return;
    _danmakuChConvert = v;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_kDanmakuChConvertKey, v.id);
    notifyListeners();
  }

  Future<void> setGestureBrightness(bool enabled) async {
    if (_gestureBrightness == enabled) return;
    _gestureBrightness = enabled;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_kGestureBrightnessKey, enabled);
    notifyListeners();
  }

  Future<void> setGestureVolume(bool enabled) async {
    if (_gestureVolume == enabled) return;
    _gestureVolume = enabled;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_kGestureVolumeKey, enabled);
    notifyListeners();
  }

  Future<void> setGestureSeek(bool enabled) async {
    if (_gestureSeek == enabled) return;
    _gestureSeek = enabled;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_kGestureSeekKey, enabled);
    notifyListeners();
  }

  Future<void> setGestureLongPressSpeed(bool enabled) async {
    if (_gestureLongPressSpeed == enabled) return;
    _gestureLongPressSpeed = enabled;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_kGestureLongPressSpeedKey, enabled);
    notifyListeners();
  }

  Future<void> setLongPressSpeedMultiplier(double multiplier) async {
    final v = multiplier.clamp(1.0, 4.0).toDouble();
    if (_longPressSpeedMultiplier == v) return;
    _longPressSpeedMultiplier = v;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setDouble(_kLongPressSpeedMultiplierKey, v);
    notifyListeners();
  }

  Future<void> setLongPressSlideSpeed(bool enabled) async {
    if (_longPressSlideSpeed == enabled) return;
    _longPressSlideSpeed = enabled;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_kLongPressSlideSpeedKey, enabled);
    notifyListeners();
  }

  Future<void> setDoubleTapLeft(DoubleTapAction action) async {
    if (_doubleTapLeft == action) return;
    _doubleTapLeft = action;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_kDoubleTapLeftKey, action.id);
    notifyListeners();
  }

  Future<void> setDoubleTapCenter(DoubleTapAction action) async {
    if (_doubleTapCenter == action) return;
    _doubleTapCenter = action;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_kDoubleTapCenterKey, action.id);
    notifyListeners();
  }

  Future<void> setDoubleTapRight(DoubleTapAction action) async {
    if (_doubleTapRight == action) return;
    _doubleTapRight = action;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_kDoubleTapRightKey, action.id);
    notifyListeners();
  }

  Future<void> setReturnHomeBehavior(ReturnHomeBehavior behavior) async {
    if (_returnHomeBehavior == behavior) return;
    _returnHomeBehavior = behavior;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_kReturnHomeBehaviorKey, behavior.id);
    notifyListeners();
  }

  Future<void> setShowSystemTimeInControls(bool enabled) async {
    if (_showSystemTimeInControls == enabled) return;
    _showSystemTimeInControls = enabled;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_kShowSystemTimeInControlsKey, enabled);
    notifyListeners();
  }

  Future<void> setShowBufferSpeed(bool enabled) async {
    if (_showBufferSpeed == enabled) return;
    _showBufferSpeed = enabled;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_kShowBufferSpeedKey, enabled);
    notifyListeners();
  }

  Future<void> setShowBatteryInControls(bool enabled) async {
    if (_showBatteryInControls == enabled) return;
    _showBatteryInControls = enabled;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_kShowBatteryInControlsKey, enabled);
    notifyListeners();
  }

  Future<void> setSeekBackwardSeconds(int seconds) async {
    final v = seconds.clamp(1, 120);
    if (_seekBackwardSeconds == v) return;
    _seekBackwardSeconds = v;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setInt(_kSeekBackwardSecondsKey, v);
    notifyListeners();
  }

  Future<void> setSeekForwardSeconds(int seconds) async {
    final v = seconds.clamp(1, 120);
    if (_seekForwardSeconds == v) return;
    _seekForwardSeconds = v;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setInt(_kSeekForwardSecondsKey, v);
    notifyListeners();
  }

  Future<void> setForceRemoteControlKeys(bool enabled) async {
    if (_forceRemoteControlKeys == enabled) return;
    _forceRemoteControlKeys = enabled;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_kForceRemoteControlKeysKey, enabled);
    notifyListeners();
  }

  static ThemeMode _decodeThemeMode(String? raw) {
    switch (raw) {
      case 'light':
        return ThemeMode.light;
      case 'dark':
        return ThemeMode.dark;
      default:
        return ThemeMode.system;
    }
  }

  static String _encodeThemeMode(ThemeMode mode) {
    switch (mode) {
      case ThemeMode.light:
        return 'light';
      case ThemeMode.dark:
        return 'dark';
      case ThemeMode.system:
        return 'system';
    }
  }

  static String _suggestServerName(String baseUrl) {
    try {
      final uri = Uri.parse(baseUrl);
      if (uri.host.isNotEmpty) return uri.host;
    } catch (_) {}
    return baseUrl;
  }

  Future<AuthResult> _authenticateForBackup({
    required String baseUrl,
    required String username,
    required String password,
    required String deviceId,
  }) async {
    final raw = baseUrl.trim();
    if (raw.isEmpty) throw const FormatException('Missing baseUrl');

    Uri? uri;
    try {
      uri = Uri.parse(raw);
    } catch (_) {}

    if (uri == null || uri.host.isEmpty) {
      try {
        uri = Uri.parse('https://$raw');
      } catch (_) {}
    }

    final scheme =
        (uri != null && (uri.scheme == 'http' || uri.scheme == 'https'))
            ? uri.scheme
            : 'https';
    final port = (uri != null && uri.hasPort) ? uri.port.toString() : null;

    final hostOrUrl = (uri != null && uri.host.isNotEmpty)
        ? uri.host + ((uri.path.isNotEmpty && uri.path != '/') ? uri.path : '')
        : raw;

    final api =
        EmbyApi(hostOrUrl: hostOrUrl, preferredScheme: scheme, port: port);
    return api.authenticate(
      username: username,
      password: password,
      deviceId: deviceId,
    );
  }

  Future<void> _persistServers(SharedPreferences prefs) async {
    await prefs.setString(
      _kServersKey,
      jsonEncode(_servers.map((s) => s.toJson()).toList()),
    );
  }

  static Map<String, dynamic>? _coerceStringKeyedMap(dynamic value) {
    if (value is Map<String, dynamic>) return value;
    if (value is Map) {
      return value.map((k, v) => MapEntry(k.toString(), v));
    }
    return null;
  }

  static int _readInt(dynamic value, {required int fallback}) {
    if (value is int) return value;
    if (value is num) return value.round();
    if (value is String) return int.tryParse(value.trim()) ?? fallback;
    return fallback;
  }

  static double _readDouble(dynamic value, {required double fallback}) {
    if (value is double) return value;
    if (value is num) return value.toDouble();
    if (value is String) return double.tryParse(value.trim()) ?? fallback;
    return fallback;
  }

  static bool _readBool(dynamic value, {required bool fallback}) {
    if (value is bool) return value;
    if (value is num) return value != 0;
    if (value is String) {
      final v = value.trim().toLowerCase();
      if (v == 'true' || v == '1' || v == 'yes' || v == 'y') return true;
      if (v == 'false' || v == '0' || v == 'no' || v == 'n') return false;
    }
    return fallback;
  }

  static List<String> _readStringList(dynamic value) {
    if (value is List) {
      return value
          .where((e) => e != null)
          .map((e) => e.toString().trim())
          .where((e) => e.isNotEmpty)
          .toList();
    }
    if (value is String) {
      final v = value.trim();
      if (v.isEmpty) return const [];
      return [v];
    }
    return const [];
  }

  static void _mergeCustomDomains(
      ServerProfile server, List<CustomDomain> domains) {
    for (final domain in domains) {
      final fixedUrl = _normalizeUrl(domain.url, defaultScheme: 'https');
      if (!_isValidHttpUrl(fixedUrl)) continue;
      final fixedName =
          domain.name.trim().isEmpty ? fixedUrl : domain.name.trim();
      server.customDomains.removeWhere((d) => d.url == fixedUrl);
      server.customDomains.add(CustomDomain(name: fixedName, url: fixedUrl));
    }
  }
}

class HomeEntry {
  final String key;
  final String displayName;
  final List<MediaItem> items;
  HomeEntry(
      {required this.key, required this.displayName, required this.items});
}

extension _FirstWhereOrNull<E> on List<E> {
  E? firstWhereOrNull(bool Function(E) test) {
    for (final e in this) {
      if (test(e)) return e;
    }
    return null;
  }
}
