import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../services/backup_crypto.dart';
import '../services/emby_api.dart';
import 'anime4k_preferences.dart';
import 'danmaku_preferences.dart';
import 'local_playback_handoff.dart';
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
  static const _kDanmakuPreventOverlapKey = 'danmakuPreventOverlap_v1';
  static const _kDanmakuBlockWordsKey = 'danmakuBlockWords_v1';
  static const _kDanmakuMatchModeKey = 'danmakuMatchMode_v1';
  static const _kDanmakuChConvertKey = 'danmakuChConvert_v1';
  static const _kServerIconLibraryUrlsKey = 'serverIconLibraryUrls_v1';
  static const _kShowHomeLibraryQuickAccessKey =
      'showHomeLibraryQuickAccess_v1';

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
  bool _unlimitedStreamCache = false;
  bool _enableBlurEffects = true;
  bool _showHomeLibraryQuickAccess = true;
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
  bool _danmakuPreventOverlap = true;
  String _danmakuBlockWords = '';
  DanmakuMatchMode _danmakuMatchMode = DanmakuMatchMode.auto;
  DanmakuChConvert _danmakuChConvert = DanmakuChConvert.off;
  LocalPlaybackHandoff? _localPlaybackHandoff;
  bool _loading = false;
  String? _error;

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
  bool get hasActiveServer =>
      activeServer != null && baseUrl != null && token != null && userId != null;

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
  bool get unlimitedStreamCache => _unlimitedStreamCache;
  bool get enableBlurEffects => _enableBlurEffects;
  bool get showHomeLibraryQuickAccess => _showHomeLibraryQuickAccess;
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
  bool get danmakuPreventOverlap => _danmakuPreventOverlap;
  String get danmakuBlockWords => _danmakuBlockWords;
  DanmakuMatchMode get danmakuMatchMode => _danmakuMatchMode;
  DanmakuChConvert get danmakuChConvert => _danmakuChConvert;

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
        'unlimitedStreamCache': _unlimitedStreamCache,
        'enableBlurEffects': _enableBlurEffects,
        'showHomeLibraryQuickAccess': _showHomeLibraryQuickAccess,
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
          'preventOverlap': _danmakuPreventOverlap,
          'blockWords': _danmakuBlockWords,
          'matchMode': _danmakuMatchMode.id,
          'chConvert': _danmakuChConvert.id,
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
    final nextDanmakuPreventOverlap =
        _readBool(danmakuMap['preventOverlap'], fallback: true);
    final nextDanmakuBlockWords =
        (danmakuMap['blockWords'] ?? '').toString().trimRight();
    final nextDanmakuMatchMode =
        danmakuMatchModeFromId(danmakuMap['matchMode']?.toString());
    final nextDanmakuChConvert =
        danmakuChConvertFromId(danmakuMap['chConvert']?.toString());

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
    _unlimitedStreamCache = nextUnlimitedStreamCache;
    _enableBlurEffects = nextEnableBlurEffects;
    _showHomeLibraryQuickAccess = nextShowHomeLibraryQuickAccess;
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
    _danmakuPreventOverlap = nextDanmakuPreventOverlap;
    _danmakuBlockWords = nextDanmakuBlockWords;
    _danmakuMatchMode = nextDanmakuMatchMode;
    _danmakuChConvert = nextDanmakuChConvert;

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
    await prefs.setBool(_kUnlimitedStreamCacheKey, _unlimitedStreamCache);
    await prefs.setBool(_kEnableBlurEffectsKey, _enableBlurEffects);
    await prefs.setBool(
      _kShowHomeLibraryQuickAccessKey,
      _showHomeLibraryQuickAccess,
    );

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
    await prefs.setBool(_kDanmakuPreventOverlapKey, _danmakuPreventOverlap);
    if (_danmakuBlockWords.trim().isEmpty) {
      await prefs.remove(_kDanmakuBlockWordsKey);
    } else {
      await prefs.setString(_kDanmakuBlockWordsKey, _danmakuBlockWords);
    }
    await prefs.setString(_kDanmakuMatchModeKey, _danmakuMatchMode.id);
    await prefs.setString(_kDanmakuChConvertKey, _danmakuChConvert.id);

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
      final api =
          EmbyApi(hostOrUrl: hostOrUrl, preferredScheme: scheme, port: port);
      final auth = await api.authenticate(
        username: fixedUsername,
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

      final name = fixedDisplayName.isNotEmpty
          ? fixedDisplayName
          : ((serverName ?? '').trim().isNotEmpty
              ? serverName!.trim()
              : _suggestServerName(auth.baseUrlUsed));

      final existingIndex =
          _servers.indexWhere((s) => s.baseUrl == auth.baseUrlUsed);

      final resolvedIconUrl = switch (fixedIconUrl) {
        null => existingIndex >= 0 ? _servers[existingIndex].iconUrl : null,
        _ => fixedIconUrl.isEmpty ? null : fixedIconUrl,
      };
      final server = ServerProfile(
        id: existingIndex >= 0 ? _servers[existingIndex].id : _randomId(),
        username: fixedUsername,
        name: name,
        remark: fixedRemark.isEmpty ? null : fixedRemark,
        iconUrl: resolvedIconUrl,
        baseUrl: auth.baseUrlUsed,
        token: auth.token,
        userId: auth.userId,
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
        final lines = await api.fetchDomains(
          auth.token,
          auth.baseUrlUsed,
          allowFailure: true,
        );
        final libs = await api.fetchLibraries(
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

      final existingIndex =
          _servers.indexWhere((s) => s.baseUrl == inferredBaseUrl);

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
          username: fixedUsername,
          name: name,
          remark: fixedRemark.isEmpty ? null : fixedRemark,
          iconUrl: (fixedIconUrl == null || fixedIconUrl.isEmpty)
              ? null
              : fixedIconUrl,
          baseUrl: inferredBaseUrl,
          token: '',
          userId: '',
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
      _continueWatching = null;
      _continueWatchingInFlight = null;
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

    final api = EmbyApi(hostOrUrl: baseUrl!, preferredScheme: 'https');
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

    final tail = segs.skip(segs.length - 3).map((e) => e.toLowerCase()).toList();
    if (tail[0] != 'emby' || tail[1] != 'users' || tail[2] != 'authenticatebyname') {
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

  static void _mergeCustomDomains(ServerProfile server, List<CustomDomain> domains) {
    for (final domain in domains) {
      final fixedUrl = _normalizeUrl(domain.url, defaultScheme: 'https');
      if (!_isValidHttpUrl(fixedUrl)) continue;
      final fixedName = domain.name.trim().isEmpty ? fixedUrl : domain.name.trim();
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
