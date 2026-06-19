import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../api/api_interfaces.dart';
import '../providers/app_providers.dart';

/// 有界 LRU 保活：让导航级 provider 的结果在内存里保留「最近若干份」。
///
/// 取舍：纯 autoDispose 离开页面即释放（省内存）但返回会重新联网（网络慢则卡）；
/// 纯 keepAlive 返回秒开但浏览越多驻留越多（移动/TV OOM）。这里折中——
/// 每份结果持有一个 KeepAliveLink 钉在内存，超过 [maxEntries] 就放开最旧的那份，
/// 使其在无人 watch 时被 autoDispose 回收。于是：
/// - 返回最近看过的剧/集 → provider 仍在内存，秒开、**不重新联网**；
/// - 内存恒定有界（元数据每份仅几 KB，60 份 ≈ 1-2MB），不再随浏览无限增长；
/// - 标记已看/收藏后用 ref.invalidate 触发重建 → 重新拉取，**不会显示过期状态**
///   （磁盘缓存做不到这点，故元数据不落盘只做有界内存保活）。
class _BoundedKeepAlive {
  _BoundedKeepAlive({required this.maxEntries});

  final int maxEntries;
  // LinkedHashMap 语义：保持插入顺序，最旧的在 keys.first。
  final Map<String, KeepAliveLink> _links = <String, KeepAliveLink>{};

  /// 在 autoDispose provider 体内调用：保活当前结果并登记到 LRU。
  void retain(String key, Ref ref) {
    final link = ref.keepAlive();
    _links.remove(key)?.close(); // 同 key 旧链接先放开（如 invalidate 重建）
    _links[key] = link;
    ref.onDispose(() {
      if (identical(_links[key], link)) _links.remove(key);
    });
    while (_links.length > maxEntries) {
      final oldestKey = _links.keys.first;
      _links.remove(oldestKey)?.close();
    }
  }
}

/// 详情/集/季/演员/相似/播放信息共用一个 LRU（约 12 部剧的往返足够秒开）。
final _metadataKeepAlive = _BoundedKeepAlive(maxEntries: 60);

class EmbyMediaCounts {
  final int movieCount;
  final int episodeCount;
  final int? itemCount;

  const EmbyMediaCounts({
    required this.movieCount,
    required this.episodeCount,
    this.itemCount,
  });

  int get totalCount => movieCount + episodeCount;
}

/// ==========================================
/// 首页数据Providers
/// ==========================================

/// 继续观看
final resumeItemsProvider = FutureProvider<List<MediaItem>>((ref) async {
  ref.keepAlive();
  final api = ref.watch(apiClientProvider);
  return await api.home.getResumeItems();
});

/// 下一集
final nextUpProvider = FutureProvider<List<MediaItem>>((ref) async {
  final api = ref.watch(apiClientProvider);
  return await api.home.getNextUp();
});

/// 媒体库列表（已过滤被屏蔽的）
final librariesProvider = FutureProvider<List<Library>>((ref) async {
  ref.keepAlive();
  final api = ref.watch(apiClientProvider);
  final hiddenLibraries = ref.watch(hiddenLibrariesProvider);
  final allLibraries = await api.home.getLibraries();
  return allLibraries.where((lib) => !hiddenLibraries.contains(lib.id)).toList();
});

/// 最新添加（按媒体库）
final latestItemsProvider = FutureProvider.family<List<MediaItem>, String>((ref, libraryId) async {
  ref.keepAlive();
  final api = ref.watch(apiClientProvider);
  return await api.home.getLatestItems(libraryId, limit: 20);
});

/// 随机推荐
final randomRecommendationsProvider = FutureProvider<List<MediaItem>>((ref) async {
  ref.keepAlive();
  final api = ref.watch(apiClientProvider);
  return await api.home.getRandomRecommendations();
});

final embyMediaCountsProvider = FutureProvider<EmbyMediaCounts>((ref) async {
  ref.keepAlive();
  final api = ref.watch(apiClientProvider);

  try {
    final counts = await api.home.getMediaCounts();
    return EmbyMediaCounts(
      movieCount: counts.movieCount,
      episodeCount: counts.episodeCount,
      itemCount: counts.itemCount,
    );
  } catch (error, stackTrace) {
    debugPrint('[MediaCountsProvider] Failed to load media counts: $error');
    debugPrintStack(
      label: '[MediaCountsProvider] Stack trace',
      stackTrace: stackTrace,
    );
    Error.throwWithStackTrace(error, stackTrace);
  }
});

/// ==========================================
/// 媒体详情Providers
/// ==========================================

/// 媒体项详情
///
/// 内存优化：autoDispose + 有界 LRU 保活（见 [_metadataKeepAlive]）。离开页面后
/// 仍保留最近若干份在内存——返回秒开、不重新联网；超出上限的最旧项被回收，
/// 内存恒定有界。之前全量 keepAlive，浏览每部剧都把详情/季/集/演员/相似永久钉死，
/// 重度浏览必然 OOM（移动/TV 尤甚）。
final mediaItemProvider = FutureProvider.autoDispose.family<MediaItem, String>((ref, itemId) async {
  _metadataKeepAlive.retain('item:$itemId', ref);
  final api = ref.watch(apiClientProvider);
  return await api.media.getItemDetails(itemId);
});

/// 相似推荐
final similarItemsProvider = FutureProvider.autoDispose.family<List<MediaItem>, String>((ref, itemId) async {
  _metadataKeepAlive.retain('similar:$itemId', ref);
  final api = ref.watch(apiClientProvider);
  return await api.media.getSimilarItems(itemId);
});

/// 季列表
final seasonsProvider = FutureProvider.autoDispose.family<List<Season>, String>((ref, seriesId) async {
  _metadataKeepAlive.retain('seasons:$seriesId', ref);
  final api = ref.watch(apiClientProvider);
  return await api.media.getSeasons(seriesId);
});

/// 集列表
final episodesProvider = FutureProvider.autoDispose.family<List<Episode>, ({String seriesId, String? seasonId})>(
  (ref, params) async {
    _metadataKeepAlive.retain('episodes:${params.seriesId}:${params.seasonId}', ref);
    final api = ref.watch(apiClientProvider);
    return await api.media.getEpisodes(params.seriesId, seasonId: params.seasonId);
  },
);

/// 演职人员
final personsProvider = FutureProvider.autoDispose.family<List<Person>, String>((ref, itemId) async {
  _metadataKeepAlive.retain('persons:$itemId', ref);
  final api = ref.watch(apiClientProvider);
  final item = await api.media.getItemDetails(itemId);
  return item.people ?? const <Person>[];
});

/// ==========================================
/// 媒体库详情Providers
/// ==========================================

/// 媒体库内容
final libraryItemsProvider = FutureProvider.autoDispose.family<List<MediaItem>, ({String libraryId, String? sortBy, String? sortOrder})>(
  (ref, params) async {
    final api = ref.watch(apiClientProvider);
    return await api.library.getLibraryItems(
      libraryId: params.libraryId,
      sortBy: params.sortBy,
      sortOrder: params.sortOrder,
    );
  },
);

/// 筛选条件
final filtersProvider = FutureProvider.autoDispose.family<Filters, String>((ref, libraryId) async {
  final api = ref.watch(apiClientProvider);
  return await api.library.getFilters(libraryId);
});

/// ==========================================
/// 收藏 Providers
/// ==========================================

final favoritesRefreshTickProvider = StateProvider<int>((ref) => 0);

final favoriteItemsProvider = FutureProvider<List<MediaItem>>((ref) async {
  ref.keepAlive();
  ref.watch(favoritesRefreshTickProvider);
  final hiddenLibraries = ref.watch(hiddenLibrariesProvider);
  final api = ref.watch(apiClientProvider);
  final items = await api.favorite.getFavorites();

  return items.where((item) {
    if (item.parentId != null && hiddenLibraries.contains(item.parentId)) {
      return false;
    }
    return item.userData?.isFavorite ?? true;
  }).toList();
});

void refreshFavorites(WidgetRef ref) {
  ref.read(favoritesRefreshTickProvider.notifier).state++;
  ref.invalidate(favoriteItemsProvider);
}

/// ==========================================
/// 搜索Providers
/// ==========================================

/// 搜索关键词
final searchQueryProvider = StateProvider<String>((ref) => '');

/// 聚合搜索开关
final aggregateSearchProvider = StateProvider<bool>((ref) => false);

/// 搜索结果
final searchResultsProvider = FutureProvider.autoDispose<List<MediaItem>>((ref) async {
  final query = ref.watch(searchQueryProvider);
  final isAggregate = ref.watch(aggregateSearchProvider);
  final hiddenLibraries = ref.watch(hiddenLibrariesProvider);

  if (query.isEmpty) return [];

  final api = ref.watch(apiClientProvider);

  List<MediaItem> results;
  if (isAggregate) {
    final aggregateResults = await api.search.searchAggregate(query);
    results = aggregateResults.values.expand((list) => list).toList();
  } else {
    results = await api.search.search(query);
  }

  // 排除被屏蔽媒体库的结果（通过parentId匹配）
  return results.where((item) {
    if (item.parentId != null && hiddenLibraries.contains(item.parentId)) return false;
    return true;
  }).toList();
});

/// 搜索历史
final searchHistoryProvider = StateNotifierProvider<SearchHistoryNotifier, List<String>>((ref) {
  return SearchHistoryNotifier();
});

class SearchHistoryNotifier extends StateNotifier<List<String>> {
  SearchHistoryNotifier() : super([]);
  
  void addQuery(String query) {
    if (query.isEmpty) return;
    state = [
      query,
      ...state.where((q) => q != query),
    ].take(20).toList();
  }
  
  void removeQuery(String query) {
    state = state.where((q) => q != query).toList();
  }
  
  void clear() {
    state = [];
  }
}

/// ==========================================
/// 播放Providers
/// ==========================================

/// 播放信息
final playbackInfoProvider = FutureProvider.autoDispose.family<PlaybackInfo, String>((ref, itemId) async {
  _metadataKeepAlive.retain('playback:$itemId', ref);
  final api = ref.watch(apiClientProvider);
  return await api.playback.getPlaybackInfo(itemId);
});

/// 当前播放项
final currentPlayingItemProvider = StateProvider<MediaItem?>((ref) => null);

/// 播放进度
final playbackProgressProvider = StateProvider<double>((ref) => 0.0);

/// 播放状态
final isPlayingProvider = StateProvider<bool>((ref) => false);

/// 音量
final volumeProvider = StateProvider<double>((ref) => 1.0);

/// 播放速度
final playbackSpeedProvider = StateProvider<double>((ref) => 1.0);

/// 字幕轨道
final subtitleTrackProvider = StateProvider<int?>((ref) => null);

/// 次字幕轨道（第二个字幕）
final secondarySubtitleTrackProvider = StateProvider<int?>((ref) => null);

/// 音频轨道
final audioTrackProvider = StateProvider<int?>((ref) => null);

/// 当前选择的媒体源
final selectedMediaSourceProvider = StateProvider<String?>((ref) => null);
