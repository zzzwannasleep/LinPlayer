import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../services/emby_api.dart';
import 'danmaku_preferences.dart';
import 'preferences.dart';
import 'server_profile.dart';

class AppState extends ChangeNotifier {
  static const _kServersKey = 'servers_v1';
  static const _kActiveServerIdKey = 'activeServerId_v1';
  static const _kThemeModeKey = 'themeMode_v1';
  static const _kUiScaleFactorKey = 'uiScaleFactor_v1';
  static const _kDynamicColorKey = 'dynamicColor_v1';
  static const _kThemeTemplateKey = 'themeTemplate_v1';
  static const _kPreferHardwareDecodeKey = 'preferHardwareDecode_v1';
  static const _kPreferredAudioLangKey = 'preferredAudioLang_v1';
  static const _kPreferredSubtitleLangKey = 'preferredSubtitleLang_v1';
  static const _kPreferredVideoVersionKey = 'preferredVideoVersion_v1';
  static const _kAppIconIdKey = 'appIconId_v1';
  static const _kServerListLayoutKey = 'serverListLayout_v1';
  static const _kMpvCacheSizeMbKey = 'mpvCacheSizeMb_v1';
  static const _kUnlimitedCoverCacheKey = 'unlimitedCoverCache_v1';
  static const _kEnableBlurEffectsKey = 'enableBlurEffects_v1';
  static const _kExternalMpvPathKey = 'externalMpvPath_v1';
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
  static const _kDanmakuPreventOverlapKey = 'danmakuPreventOverlap_v1';
  static const _kDanmakuBlockWordsKey = 'danmakuBlockWords_v1';
  static const _kDanmakuMatchModeKey = 'danmakuMatchMode_v1';
  static const _kDanmakuChConvertKey = 'danmakuChConvert_v1';

  final List<ServerProfile> _servers = [];
  String? _activeServerId;

  List<DomainInfo> _domains = [];
  List<LibraryInfo> _libraries = [];
  final Map<String, List<MediaItem>> _itemsCache = {};
  final Map<String, int> _itemsTotal = {};
  final Map<String, List<MediaItem>> _homeSections = {};
  List<MediaItem>? _randomRecommendations;
  Future<List<MediaItem>>? _randomRecommendationsInFlight;
  late final String _deviceId = _randomId();
  ThemeMode _themeMode = ThemeMode.system;
  double _uiScaleFactor = 1.0;
  bool _useDynamicColor = true;
  ThemeTemplate _themeTemplate = ThemeTemplate.defaultBlue;
  bool _preferHardwareDecode = true;
  String _preferredAudioLang = '';
  String _preferredSubtitleLang = '';
  VideoVersionPreference _preferredVideoVersion =
      VideoVersionPreference.defaultVersion;
  String _appIconId = 'default';
  ServerListLayout _serverListLayout = ServerListLayout.grid;
  int _mpvCacheSizeMb = 500;
  bool _unlimitedCoverCache = false;
  bool _enableBlurEffects = true;
  String _externalMpvPath = '';
  bool _danmakuEnabled = true;
  DanmakuLoadMode _danmakuLoadMode = DanmakuLoadMode.local;
  List<String> _danmakuApiUrls = ['https://api.dandanplay.net'];
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
  bool _danmakuPreventOverlap = true;
  String _danmakuBlockWords = '';
  DanmakuMatchMode _danmakuMatchMode = DanmakuMatchMode.auto;
  DanmakuChConvert _danmakuChConvert = DanmakuChConvert.off;
  bool _loading = false;
  String? _error;

  static String _randomId() {
    const chars = 'abcdefghijklmnopqrstuvwxyz0123456789';
    final rand = DateTime.now().microsecondsSinceEpoch;
    return List.generate(16, (i) => chars[(rand + i * 31) % chars.length])
        .join();
  }

  List<ServerProfile> get servers => List.unmodifiable(_servers);
  String? get activeServerId => _activeServerId;
  ServerProfile? get activeServer =>
      _servers.firstWhereOrNull((s) => s.id == _activeServerId);
  bool get hasActiveServer => activeServer != null;

  String? get baseUrl => activeServer?.baseUrl;
  String? get token => activeServer?.token;
  String? get userId => activeServer?.userId;

  String get deviceId => _deviceId;
  List<DomainInfo> get domains => _domains;
  List<LibraryInfo> get libraries => _libraries;
  List<MediaItem> getItems(String parentId) => _itemsCache[parentId] ?? [];
  int getTotal(String parentId) => _itemsTotal[parentId] ?? 0;
  List<MediaItem> getHome(String key) => _homeSections[key] ?? [];
  ThemeMode get themeMode => _themeMode;
  double get uiScaleFactor => _uiScaleFactor;
  bool get useDynamicColor => _useDynamicColor;
  ThemeTemplate get themeTemplate => _themeTemplate;
  Color get themeSeedColor => _themeTemplate.seed;
  Color get themeSecondarySeedColor => _themeTemplate.secondarySeed;

  bool get preferHardwareDecode => _preferHardwareDecode;
  String get preferredAudioLang => _preferredAudioLang;
  String get preferredSubtitleLang => _preferredSubtitleLang;
  VideoVersionPreference get preferredVideoVersion => _preferredVideoVersion;
  String get appIconId => _appIconId;
  ServerListLayout get serverListLayout => _serverListLayout;
  int get mpvCacheSizeMb => _mpvCacheSizeMb;
  bool get unlimitedCoverCache => _unlimitedCoverCache;
  bool get enableBlurEffects => _enableBlurEffects;
  String get externalMpvPath => _externalMpvPath;
  bool get danmakuEnabled => _danmakuEnabled;
  DanmakuLoadMode get danmakuLoadMode => _danmakuLoadMode;
  List<String> get danmakuApiUrls => List.unmodifiable(_danmakuApiUrls);
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
  bool get danmakuPreventOverlap => _danmakuPreventOverlap;
  String get danmakuBlockWords => _danmakuBlockWords;
  DanmakuMatchMode get danmakuMatchMode => _danmakuMatchMode;
  DanmakuChConvert get danmakuChConvert => _danmakuChConvert;

  Iterable<HomeEntry> get homeEntries sync* {
    for (final entry in _homeSections.entries) {
      if (!entry.key.startsWith('lib_')) continue;
      final libId = entry.key.substring(4);
      if (activeServer?.hiddenLibraries.contains(libId) == true) continue;
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
    _themeTemplate = themeTemplateFromId(prefs.getString(_kThemeTemplateKey));
    _preferHardwareDecode = prefs.getBool(_kPreferHardwareDecodeKey) ?? true;
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
    _unlimitedCoverCache = prefs.getBool(_kUnlimitedCoverCacheKey) ?? false;
    _enableBlurEffects = prefs.getBool(_kEnableBlurEffectsKey) ?? true;
    _externalMpvPath = prefs.getString(_kExternalMpvPathKey) ?? '';

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
    _danmakuPreventOverlap = prefs.getBool(_kDanmakuPreventOverlapKey) ?? true;
    _danmakuBlockWords = prefs.getString(_kDanmakuBlockWordsKey) ?? '';
    _danmakuMatchMode =
        danmakuMatchModeFromId(prefs.getString(_kDanmakuMatchModeKey));
    _danmakuChConvert =
        danmakuChConvertFromId(prefs.getString(_kDanmakuChConvertKey));

    final rawServers = prefs.getString(_kServersKey);
    _servers.clear();
    if (rawServers != null && rawServers.trim().isNotEmpty) {
      try {
        final decoded = jsonDecode(rawServers);
        if (decoded is List) {
          for (final item in decoded) {
            if (item is Map<String, dynamic>) {
              final s = ServerProfile.fromJson(item);
              if (s.id.isNotEmpty &&
                  s.baseUrl.isNotEmpty &&
                  s.token.isNotEmpty) {
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
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_kActiveServerIdKey);
    notifyListeners();
  }

  Future<void> addServer({
    required String hostOrUrl,
    required String scheme,
    String? port,
    required String username,
    required String password,
    String? displayName,
    String? remark,
  }) async {
    _loading = true;
    _error = null;
    notifyListeners();

    try {
      final api =
          EmbyApi(hostOrUrl: hostOrUrl, preferredScheme: scheme, port: port);
      final auth = await api.authenticate(
        username: username,
        password: password,
        deviceId: _deviceId,
      );

      String? serverName;
      try {
        serverName =
            await api.fetchServerName(auth.baseUrlUsed, token: auth.token);
      } catch (_) {
        // best-effort
      }

      final lines = await api.fetchDomains(auth.token, auth.baseUrlUsed,
          allowFailure: true);
      final libs = await api.fetchLibraries(
        token: auth.token,
        baseUrl: auth.baseUrlUsed,
        userId: auth.userId,
      );

      final name = (displayName ?? '').trim().isNotEmpty
          ? displayName!.trim()
          : ((serverName ?? '').trim().isNotEmpty
              ? serverName!.trim()
              : _suggestServerName(auth.baseUrlUsed));

      final existingIndex =
          _servers.indexWhere((s) => s.baseUrl == auth.baseUrlUsed);
      final server = ServerProfile(
        id: existingIndex >= 0 ? _servers[existingIndex].id : _randomId(),
        name: name,
        remark: (remark ?? '').trim().isEmpty ? null : remark!.trim(),
        baseUrl: auth.baseUrlUsed,
        token: auth.token,
        userId: auth.userId,
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

      _activeServerId = server.id;
      _domains = lines;
      _libraries = libs;
      _itemsCache.clear();
      _itemsTotal.clear();
      _homeSections.clear();
      _randomRecommendations = null;
      _randomRecommendationsInFlight = null;

      final prefs = await SharedPreferences.getInstance();
      await _persistServers(prefs);
      await prefs.setString(_kActiveServerIdKey, server.id);
    } catch (e) {
      _error = e.toString();
    } finally {
      _loading = false;
      notifyListeners();
    }
  }

  Future<void> enterServer(String serverId) async {
    if (_activeServerId != serverId) {
      final server = _servers.firstWhereOrNull((s) => s.id == serverId);
      if (server == null) return;

      _activeServerId = serverId;
      _domains = [];
      _libraries = [];
      _itemsCache.clear();
      _itemsTotal.clear();
      _homeSections.clear();
      _randomRecommendations = null;
      _randomRecommendationsInFlight = null;
      _error = null;

      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(_kActiveServerIdKey, serverId);
      notifyListeners();
    }

    await refreshDomains();
    await refreshLibraries();
    await loadHome();
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
    String? name,
    String? remark,
  }) async {
    final server = _servers.firstWhereOrNull((s) => s.id == serverId);
    if (server == null) return;
    if (name != null && name.trim().isNotEmpty) {
      server.name = name.trim();
    }
    if (remark != null) {
      server.remark = remark.trim().isEmpty ? null : remark.trim();
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
      final api = EmbyApi(hostOrUrl: baseUrl!, preferredScheme: 'https');
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
      final api = EmbyApi(hostOrUrl: baseUrl!, preferredScheme: 'https');
      _libraries = await api.fetchLibraries(
        token: token!,
        baseUrl: baseUrl!,
        userId: userId!,
      );
      _itemsCache.clear();
      _itemsTotal.clear();
      _homeSections.clear();
      _randomRecommendations = null;
      _randomRecommendationsInFlight = null;
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
    final api = EmbyApi(hostOrUrl: baseUrl!, preferredScheme: 'https');
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

  Future<void> loadHome() async {
    if (baseUrl == null || token == null || userId == null) return;
    final api = EmbyApi(hostOrUrl: baseUrl!, preferredScheme: 'https');
    final Map<String, List<MediaItem>> libraryShows = {};
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
        libraryShows['lib_${lib.id}'] = fetched.items;
        _itemsTotal[lib.id] = fetched.total;
      } catch (_) {
        // ignore failures per library
      }
    }
    _homeSections
      ..clear()
      ..addAll(libraryShows);
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

    final api = EmbyApi(hostOrUrl: baseUrl!, preferredScheme: 'https');
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

  Future<void> setUseDynamicColor(bool enabled) async {
    _useDynamicColor = enabled;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_kDynamicColorKey, enabled);
    notifyListeners();
  }

  Future<void> setThemeTemplate(ThemeTemplate template) async {
    _themeTemplate = template;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_kThemeTemplateKey, template.id);
    notifyListeners();
  }

  Future<void> setPreferHardwareDecode(bool enabled) async {
    _preferHardwareDecode = enabled;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_kPreferHardwareDecodeKey, enabled);
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

  Future<void> setUnlimitedCoverCache(bool enabled) async {
    if (_unlimitedCoverCache == enabled) return;
    _unlimitedCoverCache = enabled;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_kUnlimitedCoverCacheKey, enabled);
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
      return normalized.toString().replaceAll(RegExp(r'/+$'), '');
    } catch (_) {
      return raw.replaceAll(RegExp(r'/+$'), '');
    }
  }

  Future<void> setEnableBlurEffects(bool enabled) async {
    if (_enableBlurEffects == enabled) return;
    _enableBlurEffects = enabled;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_kEnableBlurEffectsKey, enabled);
    notifyListeners();
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

  Future<void> _persistServers(SharedPreferences prefs) async {
    await prefs.setString(
      _kServersKey,
      jsonEncode(_servers.map((s) => s.toJson()).toList()),
    );
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
