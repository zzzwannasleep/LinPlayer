import 'dart:convert';

/// 下载任务状态。
enum DownloadStatus {
  queued, // 排队中
  downloading, // 下载中
  paused, // 已暂停
  completed, // 已完成
  failed, // 失败
  canceled, // 已取消（一般会随即被删除）
}

DownloadStatus _statusFromName(String? name) {
  return DownloadStatus.values.firstWhere(
    (e) => e.name == name,
    orElse: () => DownloadStatus.queued,
  );
}

/// 单个分段（线程）的下载进度。
///
/// 每个分段对应一个 `${filePath}.partN` 临时文件；分段下载完成后再按序拼接成最终文件。
/// 这样可天然支持断点续传（重启后 downloaded = part 文件实际大小）。
class DownloadSegment {
  final int start; // 字节区间起点（含）
  final int end; // 字节区间终点（含）
  int downloaded; // 已下载字节数

  DownloadSegment({
    required this.start,
    required this.end,
    this.downloaded = 0,
  });

  int get length => end - start + 1;
  bool get isComplete => downloaded >= length;

  Map<String, dynamic> toJson() => {
        'start': start,
        'end': end,
        'downloaded': downloaded,
      };

  factory DownloadSegment.fromJson(Map<String, dynamic> j) => DownloadSegment(
        start: (j['start'] as num).toInt(),
        end: (j['end'] as num).toInt(),
        downloaded: (j['downloaded'] as num?)?.toInt() ?? 0,
      );
}

/// 一条下载记录（电影或单集）。
class DownloadItem {
  /// 全局唯一 id：itemId（+ mediaSourceId）。
  final String id;
  final String itemId;
  final String? mediaSourceId;

  /// Emby 媒体类型：'Movie' / 'Episode' / 其它。
  final String type;

  /// 显示标题（电影名或分集名）。
  final String title;

  /// 剧集分组信息（仅 Episode 有意义）。
  final String? seriesId;
  final String? seriesName;
  final int? seasonNumber;
  final int? episodeNumber;

  /// 海报地址，用于下载页展示。
  final String? posterUrl;

  /// 容器格式（mkv/mp4…），决定最终文件后缀。
  final String container;

  /// 下载源地址（已带鉴权参数）。
  final String url;

  /// 最终本地文件路径。
  final String filePath;

  int totalBytes;
  DownloadStatus status;
  String? error;
  final int addedAt; // epoch ms

  /// 分段列表（线程）。空表示尚未探测大小。
  List<DownloadSegment> segments;

  /// 是否支持 Range（决定能否分段/续传）。
  bool supportsRange;

  DownloadItem({
    required this.id,
    required this.itemId,
    this.mediaSourceId,
    required this.type,
    required this.title,
    this.seriesId,
    this.seriesName,
    this.seasonNumber,
    this.episodeNumber,
    this.posterUrl,
    required this.container,
    required this.url,
    required this.filePath,
    this.totalBytes = 0,
    this.status = DownloadStatus.queued,
    this.error,
    required this.addedAt,
    List<DownloadSegment>? segments,
    this.supportsRange = false,
  }) : segments = segments ?? [];

  bool get isEpisode => type == 'Episode';

  int get receivedBytes =>
      segments.fold<int>(0, (sum, s) => sum + s.downloaded);

  /// 进度 0..1（总大小未知时返回 0）。
  double get progress {
    if (status == DownloadStatus.completed) return 1;
    if (totalBytes <= 0) return 0;
    final p = receivedBytes / totalBytes;
    return p.clamp(0, 1).toDouble();
  }

  /// 临时分段文件路径。
  String partPath(int index) => '$filePath.part$index';

  Map<String, dynamic> toJson() => {
        'id': id,
        'itemId': itemId,
        'mediaSourceId': mediaSourceId,
        'type': type,
        'title': title,
        'seriesId': seriesId,
        'seriesName': seriesName,
        'seasonNumber': seasonNumber,
        'episodeNumber': episodeNumber,
        'posterUrl': posterUrl,
        'container': container,
        'url': url,
        'filePath': filePath,
        'totalBytes': totalBytes,
        'status': status.name,
        'error': error,
        'addedAt': addedAt,
        'supportsRange': supportsRange,
        'segments': segments.map((s) => s.toJson()).toList(),
      };

  factory DownloadItem.fromJson(Map<String, dynamic> j) => DownloadItem(
        id: j['id'] as String,
        itemId: j['itemId'] as String,
        mediaSourceId: j['mediaSourceId'] as String?,
        type: j['type'] as String? ?? '',
        title: j['title'] as String? ?? '',
        seriesId: j['seriesId'] as String?,
        seriesName: j['seriesName'] as String?,
        seasonNumber: (j['seasonNumber'] as num?)?.toInt(),
        episodeNumber: (j['episodeNumber'] as num?)?.toInt(),
        posterUrl: j['posterUrl'] as String?,
        container: j['container'] as String? ?? 'mkv',
        url: j['url'] as String? ?? '',
        filePath: j['filePath'] as String? ?? '',
        totalBytes: (j['totalBytes'] as num?)?.toInt() ?? 0,
        status: _statusFromName(j['status'] as String?),
        error: j['error'] as String?,
        addedAt: (j['addedAt'] as num?)?.toInt() ?? 0,
        supportsRange: j['supportsRange'] as bool? ?? false,
        segments: (j['segments'] as List<dynamic>?)
                ?.map((e) =>
                    DownloadSegment.fromJson(e as Map<String, dynamic>))
                .toList() ??
            [],
      );

  static String encodeList(List<DownloadItem> items) =>
      jsonEncode(items.map((e) => e.toJson()).toList());

  static List<DownloadItem> decodeList(String raw) {
    final data = jsonDecode(raw) as List<dynamic>;
    return data
        .map((e) => DownloadItem.fromJson(e as Map<String, dynamic>))
        .toList();
  }
}
