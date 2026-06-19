import '../../api/api_interfaces.dart';
import 'download_manager.dart';
import 'download_models.dart';

/// 根据一个媒体条目组装下载元数据并入队。
///
/// - 通过 PlaybackInfo 取真实容器格式与 MediaSourceId（决定文件后缀与下载源）。
/// - 下载地址使用 `/Items/{id}/Download`，由服务端按权限放行。
Future<DownloadItem?> startMediaDownload({
  required ApiClientFactory api,
  required DownloadManager manager,
  required MediaItem item,
  String? mediaSourceIdOverride,
}) async {
  String? container;
  String? mediaSourceId = mediaSourceIdOverride;

  try {
    final pb = await api.playback.getPlaybackInfo(item.id);
    if (pb.mediaSources.isNotEmpty) {
      final src = mediaSourceId != null
          ? pb.mediaSources.firstWhere(
              (s) => s.id == mediaSourceId,
              orElse: () => pb.mediaSources.first,
            )
          : pb.mediaSources.first;
      container = src.container;
      mediaSourceId ??= src.id;
    }
  } catch (_) {
    // 拉取播放信息失败：仍可下载原始文件，容器退回 mkv。
  }

  final url = api.playback.getDownloadUrl(item.id, mediaSourceId: mediaSourceId);

  // 海报：剧集优先用本集封面，否则退回剧集封面。
  String? posterUrl;
  try {
    if (item.type == 'Episode' && (item.primaryImageTag == null) &&
        item.seriesId != null) {
      posterUrl = api.image.getPrimaryImageUrl(item.seriesId!,
          tag: item.seriesPrimaryImageTag, maxWidth: 240);
    } else {
      posterUrl = api.image.getPrimaryImageUrl(item.id,
          tag: item.primaryImageTag, maxWidth: 240);
    }
  } catch (_) {}

  return manager.enqueue(
    itemId: item.id,
    mediaSourceId: mediaSourceId,
    type: item.type,
    title: item.name,
    seriesId: item.seriesId,
    seriesName: item.seriesName,
    seasonNumber: item.parentIndexNumber,
    episodeNumber: item.indexNumber,
    posterUrl: posterUrl,
    container: container ?? 'mkv',
    url: url,
  );
}

/// 结果统计：整剧下载入队结果。
class SeriesDownloadResult {
  final int total; // 全剧总集数
  final int queued; // 本次新入队
  final int skipped; // 已存在/已下载而跳过
  const SeriesDownloadResult(
      {required this.total, required this.queued, required this.skipped});
}

/// 整剧下载：拉取全部季与分集，逐集入队（已存在的自动跳过）。
///
/// 为降低服务器压力，整剧入队不逐集请求 PlaybackInfo，直接用原始文件下载接口；
/// 容器后缀用季/集信息无法得知时退回 mkv（mpv 按内容探测，播放不受影响）。
Future<SeriesDownloadResult> startSeriesDownload({
  required ApiClientFactory api,
  required DownloadManager manager,
  required MediaItem series,
}) async {
  final seriesId = series.type == 'Series' ? series.id : (series.seriesId ?? series.id);
  final seriesName = series.type == 'Series' ? series.name : series.seriesName;

  // 季号映射：seasonId -> 季序号，用于分组展示。
  final seasons = await api.media.getSeasons(seriesId);
  final seasonIndexById = <String, int?>{
    for (final s in seasons) s.id: s.indexNumber,
  };

  // 取全剧分集（不带 seasonId 即返回所有季）。
  final episodes = await api.media.getEpisodes(seriesId);

  var queued = 0;
  var skipped = 0;
  for (final ep in episodes) {
    final before = manager.byItemId(ep.id);
    final posterUrl = (ep.primaryImageTag != null)
        ? api.image.getPrimaryImageUrl(ep.id,
            tag: ep.primaryImageTag, maxWidth: 240)
        : api.image.getPrimaryImageUrl(seriesId,
            tag: series.primaryImageTag ?? ep.seriesPrimaryImageTag,
            maxWidth: 240);

    final added = await manager.enqueue(
      itemId: ep.id,
      type: 'Episode',
      title: ep.name,
      seriesId: seriesId,
      seriesName: seriesName,
      seasonNumber: seasonIndexById[ep.seasonId],
      episodeNumber: ep.indexNumber,
      posterUrl: posterUrl,
      container: 'mkv',
      url: api.playback.getDownloadUrl(ep.id),
    );
    // 已完成或已在队列中的会原样返回（before 非空即视为已存在）。
    if (before != null || added == null) {
      skipped++;
    } else {
      queued++;
    }
  }

  return SeriesDownloadResult(
    total: episodes.length,
    queued: queued,
    skipped: skipped,
  );
}

/// 从下载记录还原一个最简 MediaItem，供离线播放在拉取元数据失败时兜底。
MediaItem mediaItemFromDownload(DownloadItem d) {
  return MediaItem(
    id: d.itemId,
    name: d.title,
    type: d.type,
    seriesId: d.seriesId,
    seriesName: d.seriesName,
    indexNumber: d.episodeNumber,
    parentIndexNumber: d.seasonNumber,
  );
}
