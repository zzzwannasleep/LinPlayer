import '../api/api_interfaces.dart';
import '../api/danmaku/danmaku_service.dart';
import '../api/danmaku/danmaku_source.dart';

/// 一条匹配候选（来自某个源的某部作品的某一集）。
class DanmakuMatchCandidate {
  final String sourceId;
  final String sourceName;
  final String animeId;
  final String animeTitle;
  final String episodeId;
  final String episodeTitle;

  /// 排序分（越大越可信）。
  final double score;

  DanmakuMatchCandidate({
    required this.sourceId,
    required this.sourceName,
    required this.animeId,
    required this.animeTitle,
    required this.episodeId,
    required this.episodeTitle,
    required this.score,
  });
}

/// 用 Emby 元数据（剧名 + 季 + 集号）做精确集数匹配，命中率优于仅按文件名/标题。
class DanmakuMatcher {
  /// 剧集用 seriesName，否则用条目名作为作品标题。
  static String resolveTitle(MediaItem item) {
    final series = item.seriesName?.trim();
    if (series != null && series.isNotEmpty) return series;
    return item.name.trim();
  }

  /// 集号（剧集才有）。
  static int? resolveEpisodeNumber(MediaItem item) => item.indexNumber;

  /// 视频时长（秒），辅助 match 接口。
  static double? resolveDurationSeconds(MediaItem item) {
    final ticks = item.runTimeTicks;
    if (ticks == null || ticks <= 0) return null;
    return ticks / 10000000.0;
  }

  /// 并行向所有启用源做智能匹配，返回按可信度排序的候选列表。
  static Future<List<DanmakuMatchCandidate>> matchAll(
    DanmakuService service,
    MediaItem item,
  ) async {
    final title = resolveTitle(item);
    if (title.isEmpty) return const [];
    final epNum = resolveEpisodeNumber(item);

    final futures = service.allSources.map(
      (source) => _matchOne(source, title, epNum, item),
    );
    final perSource = await Future.wait(futures);
    final all = perSource.expand((e) => e).toList();
    all.sort((a, b) => b.score.compareTo(a.score));
    return all;
  }

  static Future<List<DanmakuMatchCandidate>> _matchOne(
    DanmakuSource source,
    String title,
    int? epNum,
    MediaItem item,
  ) async {
    final out = <DanmakuMatchCandidate>[];
    try {
      // 1) searchEpisodes(anime, episode) —— 服务端按集号收窄。
      var result = await source.searchEpisodes(
        anime: title,
        episode: epNum?.toString(),
      );
      if (result.animes.isEmpty && epNum != null) {
        result = await source.searchEpisodes(anime: title);
      }

      for (final anime in result.animes) {
        final titleScore = _titleScore(title, anime.animeTitle);
        final episodes = anime.episodes ?? const [];
        if (episodes.isEmpty) continue;
        final ep = _pickEpisode(episodes, epNum);
        if (ep == null) continue;
        out.add(DanmakuMatchCandidate(
          sourceId: source.config.id,
          sourceName: source.config.name,
          animeId: anime.animeId,
          animeTitle: anime.animeTitle,
          episodeId: ep.episodeId,
          episodeTitle: ep.episodeTitle,
          score: titleScore + (_episodeMatches(ep, epNum) ? 0.3 : 0.0),
        ));
      }

      // 2) 回退：文件名 match（电影或上面无果时）。
      if (out.isEmpty) {
        final matchResult = await source.match(
          fileName: item.name,
          videoDuration: resolveDurationSeconds(item),
        );
        for (final m in matchResult.matches) {
          out.add(DanmakuMatchCandidate(
            sourceId: source.config.id,
            sourceName: source.config.name,
            animeId: m.animeId,
            animeTitle: m.animeTitle,
            episodeId: m.episodeId,
            episodeTitle: m.episodeTitle,
            score: _titleScore(title, m.animeTitle) + 0.2,
          ));
        }
      }
    } catch (_) {
      // 单源失败忽略。
    }
    return out;
  }

  static DanmakuEpisode? _pickEpisode(List<DanmakuEpisode> episodes, int? epNum) {
    if (episodes.isEmpty) return null;
    if (epNum != null) {
      for (final ep in episodes) {
        if (_episodeMatches(ep, epNum)) return ep;
      }
      // 集号越界时退回按位置取（部分源 episodeNumber 不规整）。
      if (epNum >= 1 && epNum <= episodes.length) return episodes[epNum - 1];
    }
    return episodes.first;
  }

  static bool _episodeMatches(DanmakuEpisode ep, int? epNum) {
    if (epNum == null) return false;
    final n = ep.episodeNumber?.trim();
    if (n == null || n.isEmpty) return false;
    final parsed = int.tryParse(n);
    if (parsed != null) return parsed == epNum;
    // episodeNumber 可能是 "第3话"/"03" 之类，抽数字比对。
    final digits = RegExp(r'\d+').firstMatch(n)?.group(0);
    return digits != null && int.tryParse(digits) == epNum;
  }

  static String _normalize(String s) {
    return s
        .toLowerCase()
        .replaceAll(RegExp(r'[\s\-_:：·・,，.。!！?？\[\]\(\)（）]'), '')
        .replaceAll(RegExp(r'第[一二三四五六七八九十\d]+[季部]'), '')
        .trim();
  }

  /// 标题相似度 0~1。完全相等 1，包含 0.7，词重叠按比例。
  static double _titleScore(String query, String candidate) {
    final q = _normalize(query);
    final c = _normalize(candidate);
    if (q.isEmpty || c.isEmpty) return 0;
    if (q == c) return 1.0;
    if (c.contains(q) || q.contains(c)) return 0.7;
    // 字符二元组 Jaccard，轻量近似。
    final qg = _bigrams(q);
    final cg = _bigrams(c);
    if (qg.isEmpty || cg.isEmpty) return 0;
    final inter = qg.intersection(cg).length;
    final union = qg.union(cg).length;
    return union == 0 ? 0 : (inter / union) * 0.6;
  }

  static Set<String> _bigrams(String s) {
    final set = <String>{};
    for (var i = 0; i < s.length - 1; i++) {
      set.add(s.substring(i, i + 2));
    }
    if (s.length == 1) set.add(s);
    return set;
  }
}
