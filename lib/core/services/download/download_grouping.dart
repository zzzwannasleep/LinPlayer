import 'download_models.dart';

/// 下载分组：电影各自成组；剧集按「剧名」聚合，组内再按季/集排序。
class DownloadGroup {
  final String key;
  final String title;
  final bool isSeries;
  final String? posterUrl;
  final List<DownloadItem> items;

  DownloadGroup({
    required this.key,
    required this.title,
    required this.isSeries,
    required this.posterUrl,
    required this.items,
  });

  int get total => items.length;
  int get completed =>
      items.where((e) => e.status == DownloadStatus.completed).length;
  bool get hasActive => items.any((e) =>
      e.status == DownloadStatus.downloading ||
      e.status == DownloadStatus.queued);
  int get latestAddedAt =>
      items.fold<int>(0, (m, e) => e.addedAt > m ? e.addedAt : m);
}

/// 把扁平任务列表整理成分组列表（按最近添加时间倒序）。
List<DownloadGroup> groupDownloads(List<DownloadItem> items) {
  final movies = <DownloadItem>[];
  final series = <String, List<DownloadItem>>{};

  for (final it in items) {
    if (it.type == 'Episode' &&
        (it.seriesName != null && it.seriesName!.isNotEmpty)) {
      series.putIfAbsent(it.seriesId ?? it.seriesName!, () => []).add(it);
    } else {
      movies.add(it);
    }
  }

  final groups = <DownloadGroup>[];

  for (final m in movies) {
    groups.add(DownloadGroup(
      key: m.id,
      title: m.title,
      isSeries: false,
      posterUrl: m.posterUrl,
      items: [m],
    ));
  }

  series.forEach((key, eps) {
    eps.sort((a, b) {
      final s = (a.seasonNumber ?? 0).compareTo(b.seasonNumber ?? 0);
      if (s != 0) return s;
      return (a.episodeNumber ?? 0).compareTo(b.episodeNumber ?? 0);
    });
    groups.add(DownloadGroup(
      key: key,
      title: eps.first.seriesName ?? eps.first.title,
      isSeries: true,
      posterUrl: eps.first.posterUrl,
      items: eps,
    ));
  });

  groups.sort((a, b) => b.latestAddedAt.compareTo(a.latestAddedAt));
  return groups;
}

/// 单集副标题，如「S1 · E03」。
String episodeLabel(DownloadItem it) {
  final s = it.seasonNumber;
  final e = it.episodeNumber;
  final parts = <String>[];
  if (s != null) parts.add('S$s');
  if (e != null) parts.add('E${e.toString().padLeft(2, '0')}');
  return parts.join(' · ');
}

String formatBytes(int bytes) {
  if (bytes <= 0) return '0 B';
  const units = ['B', 'KB', 'MB', 'GB', 'TB'];
  var size = bytes.toDouble();
  var i = 0;
  while (size >= 1024 && i < units.length - 1) {
    size /= 1024;
    i++;
  }
  final fixed = size >= 100 || i == 0 ? 0 : 1;
  return '${size.toStringAsFixed(fixed)} ${units[i]}';
}

String downloadStatusText(DownloadItem it) {
  switch (it.status) {
    case DownloadStatus.queued:
      return '排队中';
    case DownloadStatus.downloading:
      return '下载中';
    case DownloadStatus.paused:
      return '已暂停';
    case DownloadStatus.completed:
      return '已完成';
    case DownloadStatus.failed:
      return it.error ?? '下载失败';
    case DownloadStatus.canceled:
      return '已取消';
  }
}
