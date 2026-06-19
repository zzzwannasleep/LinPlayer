import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'dart:convert';
import 'danmaku_source.dart';
import 'danmaku_cache.dart';
import '../api_interfaces.dart';

/// 单个弹幕源的查询结果（并行分源展示时一源一组，用户自己挑）。
class DanmakuSourceGroup {
  final String sourceId;
  final String sourceName;
  final List<DanmakuAnime> animes;
  final List<DanmakuMatchItem> matches;
  final Object? error;

  DanmakuSourceGroup({
    required this.sourceId,
    required this.sourceName,
    this.animes = const [],
    this.matches = const [],
    this.error,
  });

  bool get isEmpty => animes.isEmpty && matches.isEmpty;
}

class DanmakuService {
  final List<DanmakuSource> _sources = [];
  DandanplaySource? _dandanplaySource;

  List<DanmakuSource> get sources => List.unmodifiable(_sources);
  DandanplaySource? get dandanplay => _dandanplaySource;

  void initDandanplay({required String appId, required String appSecret}) {
    _dandanplaySource = DandanplaySource(
      config: DanmakuSourceConfig(
        id: 'dandanplay',
        type: DanmakuSourceType.dandanplay,
        name: '弹弹Play',
        apiUrl: 'https://api.dandanplay.net',
        authType: DanmakuAuthType.dandanplaySignature,
        priority: 0,
      ),
      appId: appId,
      appSecret: appSecret,
    );
  }

  void addSource(DanmakuSourceConfig cfg) {
    _sources.removeWhere((s) => s.config.id == cfg.id);
    _sources.add(CustomDanmakuSource(config: cfg));
    _sources.sort((a, b) => a.config.priority.compareTo(b.config.priority));
  }

  void removeSource(String id) {
    _sources.removeWhere((s) => s.config.id == id);
  }

  /// 参与查询的源：自定义源（已启用）+ 有凭据的官方弹弹Play。
  /// 官方源无凭据时不参与，避免 401 噪音（普通用户主用自建源）。
  List<DanmakuSource> get allSources {
    final list = <DanmakuSource>[];
    if (_dandanplaySource != null && _dandanplaySource!.hasCredentials) {
      list.add(_dandanplaySource!);
    }
    list.addAll(_sources.where((s) => s.config.enabled));
    return list;
  }

  // ============ 并行分源查询（用户自己挑）============

  /// 并行向所有启用源做集数搜索，分源返回。单源失败不影响其他源。
  Future<List<DanmakuSourceGroup>> searchAllGrouped(String keyword) async {
    final srcs = allSources;
    final results = await Future.wait(srcs.map((source) async {
      try {
        final r = await source.searchEpisodes(anime: keyword);
        return DanmakuSourceGroup(
          sourceId: source.config.id,
          sourceName: source.config.name,
          animes: r.animes,
        );
      } catch (e) {
        return DanmakuSourceGroup(
          sourceId: source.config.id,
          sourceName: source.config.name,
          error: e,
        );
      }
    }));
    return results;
  }

  /// 并行向所有启用源做文件名/哈希匹配，分源返回候选。
  Future<List<DanmakuSourceGroup>> matchAllGrouped({
    required String fileName,
    String? fileHash,
    int? fileSize,
    double? videoDuration,
  }) async {
    final srcs = allSources;
    final results = await Future.wait(srcs.map((source) async {
      try {
        final r = await source.match(
          fileName: fileName,
          fileHash: fileHash,
          fileSize: fileSize,
          videoDuration: videoDuration,
        );
        return DanmakuSourceGroup(
          sourceId: source.config.id,
          sourceName: source.config.name,
          matches: r.matches,
        );
      } catch (e) {
        return DanmakuSourceGroup(
          sourceId: source.config.id,
          sourceName: source.config.name,
          error: e,
        );
      }
    }));
    return results;
  }

  // ============ 兼容旧入口（顺序优先）============

  Future<DanmakuMatchResult> matchFromAll({
    required String fileName,
    String? fileHash,
    int? fileSize,
    double? videoDuration,
  }) async {
    for (final source in allSources) {
      try {
        final result = await source.match(
          fileName: fileName,
          fileHash: fileHash,
          fileSize: fileSize,
          videoDuration: videoDuration,
        );
        if (result.isMatched && result.matches.isNotEmpty) return result;
      } catch (_) {
        continue;
      }
    }
    return DanmakuMatchResult(isMatched: false, matches: const []);
  }

  Future<DanmakuSearchResult> searchFromAll(String keyword) async {
    final allAnimes = <DanmakuAnime>[];
    for (final source in allSources) {
      try {
        final result = await source.searchEpisodes(anime: keyword);
        allAnimes.addAll(result.animes);
      } catch (_) {
        continue;
      }
    }
    return DanmakuSearchResult(animes: allAnimes);
  }

  // ============ 取评论（带缓存）============

  /// 从指定源取某集弹幕，命中缓存秒载。[sourceId] 为空时退回逐源尝试。
  Future<List<DanmakuItem>> getComments(
    String episodeId, {
    String? sourceId,
    bool useCache = true,
  }) async {
    if (sourceId != null && sourceId.isNotEmpty) {
      if (useCache) {
        final cached = await DanmakuCache.instance.get(sourceId, episodeId);
        if (cached != null && cached.isNotEmpty) return cached;
      }
      final source = _findSource(sourceId);
      if (source != null) {
        try {
          final items = await source.getComments(episodeId: episodeId);
          if (items.isNotEmpty) {
            if (useCache) {
              await DanmakuCache.instance.put(sourceId, episodeId, items);
            }
            return items;
          }
        } catch (_) {}
      }
    }
    return getCommentsFromAll(episodeId, preferredSourceId: sourceId);
  }

  Future<List<DanmakuItem>> getCommentsFromAll(
    String episodeId, {
    String? preferredSourceId,
    bool useCache = true,
  }) async {
    Future<List<DanmakuItem>> fetch(DanmakuSource source) async {
      final sid = source.config.id;
      if (useCache) {
        final cached = await DanmakuCache.instance.get(sid, episodeId);
        if (cached != null && cached.isNotEmpty) return cached;
      }
      final items = await source.getComments(episodeId: episodeId);
      if (items.isNotEmpty && useCache) {
        await DanmakuCache.instance.put(sid, episodeId, items);
      }
      return items;
    }

    if (preferredSourceId != null) {
      final source = _findSource(preferredSourceId);
      if (source != null) {
        try {
          final items = await fetch(source);
          if (items.isNotEmpty) return items;
        } catch (_) {}
      }
    }
    for (final source in allSources) {
      if (source.config.id == preferredSourceId) continue;
      try {
        final items = await fetch(source);
        if (items.isNotEmpty) return items;
      } catch (_) {
        continue;
      }
    }
    return const [];
  }

  DanmakuSource? _findSource(String id) {
    if (_dandanplaySource?.config.id == id) return _dandanplaySource;
    try {
      return _sources.firstWhere((s) => s.config.id == id);
    } catch (_) {
      return null;
    }
  }
}

class DanmakuConfigRepository {
  static const _key = 'danmaku_custom_sources';

  Future<List<DanmakuSourceConfig>> loadSources() async {
    final prefs = await SharedPreferences.getInstance();
    final jsonStr = prefs.getString(_key);
    if (jsonStr == null) return [];
    final list = jsonDecode(jsonStr) as List<dynamic>;
    return list
        .whereType<Map<String, dynamic>>()
        .map(_fromJson)
        .toList();
  }

  Future<void> saveSources(List<DanmakuSourceConfig> sources) async {
    final prefs = await SharedPreferences.getInstance();
    final list = sources.map(_toJson).toList();
    await prefs.setString(_key, jsonEncode(list));
  }

  DanmakuSourceConfig _fromJson(Map<String, dynamic> json) {
    return DanmakuSourceConfig(
      id: json['id'] as String,
      type: json['type'] == 'dandanplay'
          ? DanmakuSourceType.dandanplay
          : DanmakuSourceType.custom,
      name: json['name'] as String,
      apiUrl: json['apiUrl'] as String,
      priority: json['priority'] as int? ?? 0,
      enabled: json['enabled'] as bool? ?? true,
      authType: danmakuAuthTypeFromName(json['authType'] as String?),
      token: json['token'] as String?,
      appId: json['appId'] as String?,
      appSecret: json['appSecret'] as String?,
    );
  }

  Map<String, dynamic> _toJson(DanmakuSourceConfig config) {
    return {
      'id': config.id,
      'type': config.type.name,
      'name': config.name,
      'apiUrl': config.apiUrl,
      'priority': config.priority,
      'enabled': config.enabled,
      'authType': config.authType.name,
      if (config.token != null) 'token': config.token,
      if (config.appId != null) 'appId': config.appId,
      if (config.appSecret != null) 'appSecret': config.appSecret,
    };
  }
}

final danmakuServiceProvider =
    StateNotifierProvider<DanmakuServiceNotifier, DanmakuService>((ref) {
  return DanmakuServiceNotifier();
});

class DanmakuServiceNotifier extends StateNotifier<DanmakuService> {
  final DanmakuConfigRepository _repo = DanmakuConfigRepository();

  DanmakuServiceNotifier() : super(DanmakuService()) {
    _init();
  }

  Future<void> _init() async {
    // 官方弹弹Play 凭据仅编译期注入（Action 环境变量 DANDANPLAY_APP_ID /
    // DANDANPLAY_APP_SECRET，后者可多行、一行一个），按签名验证模式调用。
    // 普通用户无凭据、也不应手填（硬编码会被滥用）。
    state.initDandanplay(
      appId: const String.fromEnvironment('DANDANPLAY_APP_ID', defaultValue: ''),
      appSecret:
          const String.fromEnvironment('DANDANPLAY_APP_SECRET', defaultValue: ''),
    );
    final sources = await _repo.loadSources();
    for (final cfg in sources) {
      state.addSource(cfg);
    }
    state = state;
  }

  Future<void> addCustomSource(DanmakuSourceConfig config) async {
    state.addSource(config);
    final sources = state.sources.map((s) => s.config).toList();
    await _repo.saveSources(sources);
    state = state;
  }

  Future<void> removeCustomSource(String id) async {
    state.removeSource(id);
    final sources = state.sources.map((s) => s.config).toList();
    await _repo.saveSources(sources);
    state = state;
  }
}
