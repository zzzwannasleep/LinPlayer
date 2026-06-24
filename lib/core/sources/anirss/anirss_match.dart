import 'models/ani.dart';
import 'models/torrent_info.dart';

/// 一个下载任务相对某订阅的「某集进度」。
class EpisodeProgress {
  /// 解析出的集号；null 表示未能从种子名解析（仍归属订阅，作未编号项）。
  final double? episodeNumber;
  final double progress;
  final TorrentState state;
  final String torrentName;
  final String? formatSize;

  const EpisodeProgress({
    required this.episodeNumber,
    required this.progress,
    required this.state,
    required this.torrentName,
    this.formatSize,
  });
}

/// 关联结果：按订阅 id 分组的逐集进度 + 未匹配上的种子。
class TorrentMatchResult {
  final Map<String, List<EpisodeProgress>> byAni;
  final List<TorrentInfoModel> unmatched;
  const TorrentMatchResult(this.byAni, this.unmatched);
}

/// 把下载任务关联到订阅与集数。分层启发式：
/// 1. **标签匹配（最准）**：torrent.tags 含订阅标题/自定义标签。
/// 2. **目录匹配**：downloadDir 含订阅 downloadPath/themoviedbName/title。
/// 3. **标题模糊兜底**：归一化后订阅标题是 torrent.name 子串。
/// 解析不到集号则作未编号项；全不匹配进 [TorrentMatchResult.unmatched]，UI 仍渲染。
TorrentMatchResult matchTorrents(
  List<AniModel> anis,
  List<TorrentInfoModel> torrents,
) {
  final byAni = <String, List<EpisodeProgress>>{};
  final unmatched = <TorrentInfoModel>[];

  for (final t in torrents) {
    AniModel? best;
    var bestScore = 0;
    for (final a in anis) {
      final s = _score(a, t);
      if (s > bestScore) {
        bestScore = s;
        best = a;
      }
    }
    if (best == null || bestScore == 0) {
      unmatched.add(t);
      continue;
    }
    byAni.putIfAbsent(best.id, () => []).add(EpisodeProgress(
          episodeNumber: parseEpisode(t.name),
          progress: t.progress,
          state: t.state,
          torrentName: t.name,
          formatSize: t.formatSize,
        ));
  }

  // 每个订阅内按集号排序（未编号排尾）。
  for (final list in byAni.values) {
    list.sort((a, b) => (a.episodeNumber ?? double.infinity)
        .compareTo(b.episodeNumber ?? double.infinity));
  }
  return TorrentMatchResult(byAni, unmatched);
}

/// 单个 (订阅, 种子) 的匹配置信分：3=标签 / 2=目录 / 1=模糊 / 0=不匹配。
int _score(AniModel ani, TorrentInfoModel t) {
  // 1. 标签
  final aniTags = ani.tags.map(_norm).where((e) => e.isNotEmpty).toSet();
  final torTags = t.tags.map(_norm).where((e) => e.isNotEmpty).toSet();
  if (aniTags.isNotEmpty && aniTags.intersection(torTags).isNotEmpty) return 3;
  final titleNorm = _norm(ani.title);
  final tmdbNorm = _norm(ani.themoviedbName ?? '');
  if (torTags.any((tag) =>
      (titleNorm.isNotEmpty && tag.contains(titleNorm)) ||
      (tmdbNorm.isNotEmpty && tag.contains(tmdbNorm)))) {
    return 3;
  }

  // 2. 目录
  final dir = _norm(t.downloadDir ?? '');
  if (dir.isNotEmpty) {
    final dp = _norm(ani.downloadPath ?? '');
    if ((dp.isNotEmpty && dir.contains(dp)) ||
        (tmdbNorm.isNotEmpty && dir.contains(tmdbNorm)) ||
        (titleNorm.isNotEmpty && dir.contains(titleNorm))) {
      return 2;
    }
  }

  // 3. 标题模糊
  final name = _norm(t.name);
  if (name.isNotEmpty) {
    final jpNorm = _norm(ani.jpTitle ?? '');
    if ((titleNorm.length >= 2 && name.contains(titleNorm)) ||
        (jpNorm.length >= 2 && name.contains(jpNorm)) ||
        (tmdbNorm.length >= 2 && name.contains(tmdbNorm))) {
      return 1;
    }
  }
  return 0;
}

/// 归一化：去括号块/季度/清晰度 token、空白与符号，转小写。
String _norm(String s) {
  var x = s.toLowerCase();
  // 去 [..]/【..】/(..) 块
  x = x.replaceAll(RegExp(r'[\[【(][^\]】)]*[\]】)]'), ' ');
  // 去清晰度/编码 token
  x = x.replaceAll(
      RegExp(r'\b(1080p|720p|2160p|4k|x264|x265|hevc|avc|web-?dl|bdrip|baha|cr)\b'),
      ' ');
  // 去 season/第N季
  x = x.replaceAll(RegExp(r'\b(s\d{1,2}|season\s*\d{1,2})\b'), ' ');
  x = x.replaceAll(RegExp(r'第[0-9一二三四五六七八九十]+[季部]'), ' ');
  // 去非字母数字中日韩字符
  x = x.replaceAll(RegExp(r'[^0-9a-z一-鿿぀-ヿ]'), '');
  return x.trim();
}

/// 从种子名解析集号，按字幕组常见约定优先级。
double? parseEpisode(String name) {
  final patterns = <RegExp>[
    RegExp(r'-\s*(\d{1,3}(?:\.5)?)(?=\s|$|\[|\()'), // "- 12" 字幕组约定（行尾/括号也算）
    RegExp(r'\[\s*(\d{1,3}(?:\.5)?)\s*\]'), // "[12]"
    RegExp(r'(?<![A-Za-z])[Ee][Pp]?\s?(\d{1,3}(?:\.5)?)'), // "E12"/"EP 12"（前面非字母，避免误吃单词里的 e）
    RegExp(r'第\s*(\d{1,3}(?:\.5)?)\s*[话話集]'), // "第12话"
    RegExp(r'\s(\d{1,3}(?:\.5)?)\s*(?:v\d)?\s*[\[\(]'), // " 12 ["
  ];
  for (final p in patterns) {
    final m = p.firstMatch(name);
    if (m != null) {
      final v = double.tryParse(m.group(1)!);
      if (v != null) return v;
    }
  }
  return null;
}
