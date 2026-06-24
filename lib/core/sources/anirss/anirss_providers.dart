import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../providers/server_providers.dart';
import 'anirss_api.dart';
import 'anirss_token.dart';
import 'models/about.dart';
import 'models/ani.dart';
import 'models/ani_config.dart';
import 'models/play_item.dart';
import 'models/torrent_info.dart';

/// 当前 Ani-rss 服务器的类型化 API（current server 非 anirss 时为 null）。
final aniRssApiProvider = Provider.autoDispose<AniRssApi?>((ref) {
  final server = ref.watch(currentServerProvider);
  if (server == null || server.sourceKind != SourceKind.anirss) return null;
  return AniRssApi(server);
});

/// 首页番剧列表。
final aniListProvider = FutureProvider.autoDispose<List<AniModel>>((ref) async {
  final api = ref.watch(aniRssApiProvider);
  if (api == null) return const [];
  return api.listAni();
});

/// 下载任务实时进度：每 3s 轮询 torrentsInfos；离屏 autoDispose 停止；
/// 单次失败不断流（沿用上次结果）。
final torrentsProvider =
    StreamProvider.autoDispose<List<TorrentInfoModel>>((ref) async* {
  final api = ref.watch(aniRssApiProvider);
  if (api == null) {
    yield const [];
    return;
  }
  List<TorrentInfoModel> last = const [];
  // 立即取一次，之后每 3s 一次。
  while (true) {
    try {
      last = await api.torrentsInfos();
      yield last;
    } catch (e) {
      yield last; // 保持上次，避免 UI 闪烁/报错
    }
    await Future<void>.delayed(const Duration(seconds: 3));
  }
});

/// 详情页数据：playList 分组成集 + 预解析 token（供 proxyImage）。
class AniDetail {
  final AniModel ani;
  final List<EpisodeEntry> episodes;
  final String token;
  const AniDetail({
    required this.ani,
    required this.episodes,
    required this.token,
  });

  bool get isMovie =>
      ani.tmdb?.isMovie == true || (ani.ova && episodes.length <= 1);

  /// 全部版本（电影/单集时取首个）。
  List<PlayItemModel> get allVersions =>
      episodes.expand((e) => e.versions).toList();
}

/// 一集（可含多个版本：不同字幕组/清晰度）。
class EpisodeEntry {
  final double? episode;
  final List<PlayItemModel> versions;
  const EpisodeEntry({required this.episode, required this.versions});

  PlayItemModel get primary => versions.first;
  bool get hasMultipleVersions => versions.length > 1;
  String get label =>
      episode != null ? '第 ${_fmt(episode!)} 集' : primary.decodedName;

  static String _fmt(double e) =>
      e == e.roundToDouble() ? e.toInt().toString() : e.toString();
}

/// 把 PlayItem 列表按集号分组（同集多文件=多版本），未编号各自成项。
List<EpisodeEntry> groupEpisodes(List<PlayItemModel> items) {
  final byKey = <String, List<PlayItemModel>>{};
  final order = <String>[];
  for (final it in items) {
    final key =
        it.episode != null ? 'ep:${it.episode}' : 'file:${it.filename}';
    byKey.putIfAbsent(key, () {
      order.add(key);
      return [];
    }).add(it);
  }
  final entries = order
      .map((k) => EpisodeEntry(episode: byKey[k]!.first.episode, versions: byKey[k]!))
      .toList();
  entries.sort((a, b) =>
      (a.episode ?? double.infinity).compareTo(b.episode ?? double.infinity));
  return entries;
}

final aniDetailProvider =
    FutureProvider.autoDispose.family<AniDetail, AniModel>((ref, ani) async {
  final api = ref.watch(aniRssApiProvider);
  final server = ref.watch(currentServerProvider);
  if (api == null || server == null) {
    throw StateError('无可用的 Ani-rss 服务器');
  }
  final items = await api.playList(ani);
  final token = await AniRssAuth.instance.ensureToken(server);
  return AniDetail(ani: ani, episodes: groupEpisodes(items), token: token);
});

/// 服务端设置（只读源）。
final aniConfigProvider = FutureProvider.autoDispose<ConfigModel>((ref) async {
  final api = ref.watch(aniRssApiProvider);
  if (api == null) return const ConfigModel(<String, dynamic>{});
  return api.config();
});

/// 关于/版本。
final aniAboutProvider = FutureProvider.autoDispose<AboutModel>((ref) async {
  final api = ref.watch(aniRssApiProvider);
  if (api == null) return const AboutModel();
  return api.about();
});

/// 设置页可编辑草稿（从 config 播种，按 key 改，保存回传）。
class ConfigDraftNotifier extends StateNotifier<Map<String, dynamic>> {
  ConfigDraftNotifier() : super(<String, dynamic>{});

  void seed(Map<String, dynamic> config) {
    state = Map<String, dynamic>.from(config);
  }

  void set(String key, dynamic value) {
    state = {...state, key: value};
  }

  dynamic get(String key) => state[key];

  ConfigModel toConfig() => ConfigModel(Map<String, dynamic>.from(state));
}

final configDraftProvider = StateNotifierProvider.autoDispose<ConfigDraftNotifier,
    Map<String, dynamic>>((ref) => ConfigDraftNotifier());

/// 触发首页/详情刷新。
void invalidateAniRss(WidgetRef ref) {
  ref.invalidate(aniListProvider);
}
