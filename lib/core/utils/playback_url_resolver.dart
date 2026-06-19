import '../api/api_interfaces.dart';

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

  const PlaybackSelection({
    required this.mediaSource,
    required this.primaryRequest,
    this.fallbackRequest,
    this.startsWithSoftwareDecoding = false,
    this.fallbackReason,
  });
}

MediaSource? resolvePreferredMediaSource(
  PlaybackInfo playbackInfo, {
  String? preferredMediaSourceId,
}) {
  final mediaSources = playbackInfo.mediaSources;
  if (mediaSources.isEmpty) {
    return null;
  }
  if (preferredMediaSourceId == null || preferredMediaSourceId.isEmpty) {
    return mediaSources.firstOrNull;
  }
  return mediaSources
          .where((source) => source.id == preferredMediaSourceId)
          .firstOrNull ??
      mediaSources.firstOrNull;
}

PlaybackSelection buildPlaybackSelection({
  required PlaybackInfo playbackInfo,
  required String itemId,
  String? preferredMediaSourceId,
  String? playSessionId,
}) {
  final mediaSource = resolvePreferredMediaSource(
    playbackInfo,
    preferredMediaSourceId: preferredMediaSourceId,
  );
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
