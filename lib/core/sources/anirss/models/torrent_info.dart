/// 下载任务状态（对应 swagger TorrentsInfo.state 枚举的常见值）。
enum TorrentState {
  downloading,
  stalledDL,
  queuedDL,
  pausedDL,
  forcedDL,
  checking,
  uploading,
  stalledUP,
  queuedUP,
  pausedUP,
  forcedUP,
  error,
  missingFiles,
  unknown,
}

TorrentState torrentStateFromName(String? s) {
  switch (s) {
    case 'downloading':
    case 'metaDownload':
    case 'forcedMetaDownload':
      return TorrentState.downloading;
    case 'stalledDL':
      return TorrentState.stalledDL;
    case 'queuedDL':
      return TorrentState.queuedDL;
    case 'pausedDL':
    case 'stoppedDL':
      return TorrentState.pausedDL;
    case 'forcedDL':
      return TorrentState.forcedDL;
    case 'checkingDL':
    case 'checkingUP':
    case 'checkingResumeData':
    case 'checkingDisk':
      return TorrentState.checking;
    case 'uploading':
      return TorrentState.uploading;
    case 'stalledUP':
      return TorrentState.stalledUP;
    case 'queuedUP':
      return TorrentState.queuedUP;
    case 'pausedUP':
    case 'stoppedUP':
      return TorrentState.pausedUP;
    case 'forcedUP':
      return TorrentState.forcedUP;
    case 'error':
      return TorrentState.error;
    case 'missingFiles':
      return TorrentState.missingFiles;
    default:
      return TorrentState.unknown;
  }
}

/// 一个下载任务（`/api/torrentsInfos` 的 `TorrentsInfo`）。
class TorrentInfoModel {
  final String id;
  final String? hash;
  final String name;
  final TorrentState state;
  final List<String> tags;
  final int completed;
  final int size;

  /// 进度 0..1。
  final double progress;
  final String? formatSize;
  final String? downloadDir;

  const TorrentInfoModel({
    required this.id,
    required this.name,
    required this.state,
    required this.progress,
    this.hash,
    this.tags = const [],
    this.completed = 0,
    this.size = 0,
    this.formatSize,
    this.downloadDir,
  });

  static TorrentInfoModel fromJson(Map<String, dynamic> m) => TorrentInfoModel(
        id: m['id']?.toString() ?? m['hash']?.toString() ?? '',
        hash: m['hash']?.toString(),
        name: m['name']?.toString() ?? '',
        state: torrentStateFromName(m['state']?.toString()),
        tags: (m['tags'] as List?)?.map((e) => e.toString()).toList() ??
            const [],
        completed: (m['completed'] as num?)?.toInt() ?? 0,
        size: (m['size'] as num?)?.toInt() ?? 0,
        progress: ((m['progress'] as num?)?.toDouble() ?? 0).clamp(0.0, 1.0),
        formatSize: m['formatSize']?.toString(),
        downloadDir: m['downloadDir']?.toString(),
      );

  bool get isComplete =>
      progress >= 1.0 ||
      state == TorrentState.uploading ||
      state == TorrentState.stalledUP ||
      state == TorrentState.pausedUP ||
      state == TorrentState.queuedUP ||
      state == TorrentState.forcedUP;

  bool get isDownloading =>
      state == TorrentState.downloading ||
      state == TorrentState.forcedDL ||
      state == TorrentState.stalledDL ||
      state == TorrentState.queuedDL;

  bool get isError =>
      state == TorrentState.error || state == TorrentState.missingFiles;
}
