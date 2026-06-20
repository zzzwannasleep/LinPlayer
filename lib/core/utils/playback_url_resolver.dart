import '../api/api_interfaces.dart';
import 'track_preference.dart';

class PlaybackUrlRequest {
  final String itemId;
  final String? mediaSourceId;
  final String? container;
  final String? playSessionId;
  final bool staticStream;
  final bool allowDirectPlay;
  final bool allowDirectStream;
  final bool allowTranscoding;
  final bool enableAutoStreamCopy;
  final bool enableAutoStreamCopyAudio;
  final bool enableAutoStreamCopyVideo;

  const PlaybackUrlRequest({
    required this.itemId,
    this.mediaSourceId,
    this.container,
    this.playSessionId,
    this.staticStream = true,
    this.allowDirectPlay = true,
    this.allowDirectStream = true,
    this.allowTranscoding = false,
    this.enableAutoStreamCopy = true,
    this.enableAutoStreamCopyAudio = true,
    this.enableAutoStreamCopyVideo = true,
  });

  PlaybackUrlRequest copyWith({
    String? itemId,
    String? mediaSourceId,
    String? container,
    String? playSessionId,
    bool? staticStream,
    bool? allowDirectPlay,
    bool? allowDirectStream,
    bool? allowTranscoding,
    bool? enableAutoStreamCopy,
    bool? enableAutoStreamCopyAudio,
    bool? enableAutoStreamCopyVideo,
  }) {
    return PlaybackUrlRequest(
      itemId: itemId ?? this.itemId,
      mediaSourceId: mediaSourceId ?? this.mediaSourceId,
      container: container ?? this.container,
      playSessionId: playSessionId ?? this.playSessionId,
      staticStream: staticStream ?? this.staticStream,
      allowDirectPlay: allowDirectPlay ?? this.allowDirectPlay,
      allowDirectStream: allowDirectStream ?? this.allowDirectStream,
      allowTranscoding: allowTranscoding ?? this.allowTranscoding,
      enableAutoStreamCopy: enableAutoStreamCopy ?? this.enableAutoStreamCopy,
      enableAutoStreamCopyAudio:
          enableAutoStreamCopyAudio ?? this.enableAutoStreamCopyAudio,
      enableAutoStreamCopyVideo:
          enableAutoStreamCopyVideo ?? this.enableAutoStreamCopyVideo,
    );
  }
}

class PlaybackSelection {
  final MediaSource? mediaSource;
  final PlaybackUrlRequest primaryRequest;
  final PlaybackUrlRequest? fallbackRequest;
  final bool startsWithSoftwareDecoding;
  final String? fallbackReason;

  /// STRM 直链地址：当「STRM 直链播放」开启且媒体源可解析出可用外链时非空。
  /// 调用方应优先用它喂给内核，并把服务端直传流（[primaryRequest] 构建出的 URL）
  /// 作为回退，以兼容部分不支持直链的服务器。
  final String? directPlayUrl;

  const PlaybackSelection({
    required this.mediaSource,
    required this.primaryRequest,
    this.fallbackRequest,
    this.startsWithSoftwareDecoding = false,
    this.fallbackReason,
    this.directPlayUrl,
  });
}

/// 从媒体源解析 STRM 直链地址：仅当其为远端源（`IsRemote` / `Protocol==Http`）且
/// `Path` 是合法的 http(s) 链接时返回该链接，否则返回 null（交回服务端直传）。
String? resolveStrmDirectUrl(MediaSource? source) {
  if (source == null) return null;
  final path = source.path?.trim();
  if (path == null || path.isEmpty) return null;
  final uri = Uri.tryParse(path);
  final isHttp = uri != null &&
      (uri.scheme == 'http' || uri.scheme == 'https') &&
      uri.host.isNotEmpty;
  if (!isHttp) return null;
  final protocol = source.protocol?.trim().toLowerCase();
  final remote = (source.isRemote ?? false) || protocol == 'http';
  return remote ? path : null;
}

MediaSource? resolvePreferredMediaSource(
  PlaybackInfo playbackInfo, {
  String? preferredMediaSourceId,
  String? versionRegex,
}) {
  final mediaSources = playbackInfo.mediaSources;
  if (mediaSources.isEmpty) {
    return null;
  }
  // 1) 用户在详情页 / 导航参数中显式选择的版本优先。
  if (preferredMediaSourceId != null && preferredMediaSourceId.isNotEmpty) {
    final byId = mediaSources
        .where((source) => source.id == preferredMediaSourceId)
        .firstOrNull;
    if (byId != null) return byId;
  }
  // 2) 其次按用户「版本选择」正则偏好反查媒体源。
  final byRegex = matchPreferredMediaSource(mediaSources, versionRegex);
  if (byRegex != null) return byRegex;
  // 3) 兜底取首个。
  return mediaSources.firstOrNull;
}

PlaybackSelection buildPlaybackSelection({
  required PlaybackInfo playbackInfo,
  required String itemId,
  String? preferredMediaSourceId,
  String? versionRegex,
  String? playSessionId,
  bool strmDirectPlay = false,
}) {
  final mediaSource = resolvePreferredMediaSource(
    playbackInfo,
    preferredMediaSourceId: preferredMediaSourceId,
    versionRegex: versionRegex,
  );
  final directPlayUrl =
      strmDirectPlay ? resolveStrmDirectUrl(mediaSource) : null;
  final normalizedContainer = _preferredContainer(mediaSource);
  final primaryRequest = PlaybackUrlRequest(
    itemId: itemId,
    mediaSourceId: mediaSource?.id,
    container: normalizedContainer,
    playSessionId: playSessionId,
    allowDirectPlay: true,
    allowDirectStream: false,
    allowTranscoding: false,
    enableAutoStreamCopy: false,
    enableAutoStreamCopyAudio: false,
    enableAutoStreamCopyVideo: false,
  );
  final fallbackRequest = PlaybackUrlRequest(
    itemId: itemId,
    mediaSourceId: mediaSource?.id,
    container: normalizedContainer,
    playSessionId: playSessionId,
    allowDirectPlay: false,
    allowDirectStream: true,
    allowTranscoding: false,
  );

  return PlaybackSelection(
    mediaSource: mediaSource,
    primaryRequest: primaryRequest,
    fallbackRequest: fallbackRequest,
    fallbackReason: '直连失败后回退到服务端直传流',
    directPlayUrl: directPlayUrl,
  );
}

/// 离线播放用的最简选择：无媒体源、无回退，仅承载 itemId。
/// 实际播放地址由调用方用本地文件覆盖。
PlaybackSelection buildOfflinePlaybackSelection({required String itemId}) {
  return PlaybackSelection(
    mediaSource: null,
    primaryRequest: PlaybackUrlRequest(itemId: itemId),
    fallbackRequest: null,
  );
}

String _preferredContainer(MediaSource? mediaSource) {
  final container = mediaSource?.container?.trim().toLowerCase();
  if (container != null && container.isNotEmpty) {
    return container;
  }
  final videoStream =
      mediaSource?.mediaStreams.where((stream) => stream.isVideo).firstOrNull;
  final codec = videoStream?.codec?.trim().toLowerCase();
  if (codec == 'hevc' || codec == 'h265') {
    return 'mkv';
  }
  return 'mp4';
}
