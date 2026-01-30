import '../../../state/media_server_type.dart';
import '../../../state/preferences.dart';
import '../../../server_adapters/server_access.dart';
import 'emby_http_headers.dart';
import 'emby_stream_resolver.dart';

class NetworkStreamResolution {
  const NetworkStreamResolution({
    required this.streamUrl,
    required this.httpHeaders,
    required this.mediaSources,
    this.selectedMediaSourceId,
    this.playSessionId,
    this.mediaSourceId,
    this.streamSizeBytes,
  });

  final String streamUrl;
  final Map<String, String> httpHeaders;

  /// Backend-provided media sources, if any.
  final List<Map<String, dynamic>> mediaSources;

  /// Backend-selected media source ID (may be `null` when unknown).
  final String? selectedMediaSourceId;

  /// Backend playback session info (if supported by backend).
  final String? playSessionId;
  final String? mediaSourceId;

  /// Optional resolved stream size in bytes (best-effort).
  final int? streamSizeBytes;
}

abstract class NetworkPlaybackBackend {
  Future<NetworkStreamResolution> resolveStream({
    required String itemId,
    String? selectedMediaSourceId,
    int? seriesMediaSourceIndex,
    int? audioStreamIndex,
    int? subtitleStreamIndex,
    required VideoVersionPreference preferredVideoVersion,
    required bool exoPlayer,
    required bool allowTranscoding,
  });
}

class EmbyLikeNetworkPlaybackBackend implements NetworkPlaybackBackend {
  const EmbyLikeNetworkPlaybackBackend({
    required this.access,
    required this.baseUrl,
    required this.token,
    required this.userId,
    required this.deviceId,
    required this.serverType,
  });

  final ServerAccess? access;
  final String baseUrl;
  final String token;
  final String userId;
  final String deviceId;
  final MediaServerType serverType;

  @override
  Future<NetworkStreamResolution> resolveStream({
    required String itemId,
    String? selectedMediaSourceId,
    int? seriesMediaSourceIndex,
    int? audioStreamIndex,
    int? subtitleStreamIndex,
    required VideoVersionPreference preferredVideoVersion,
    required bool exoPlayer,
    required bool allowTranscoding,
  }) async {
    final res = await resolveEmbyStreamUrl(
      access: access,
      baseUrl: baseUrl,
      token: token,
      userId: userId,
      deviceId: deviceId,
      itemId: itemId,
      preferredVideoVersion: preferredVideoVersion,
      exoPlayer: exoPlayer,
      allowTranscoding: allowTranscoding,
      selectedMediaSourceId: selectedMediaSourceId,
      seriesMediaSourceIndex: seriesMediaSourceIndex,
      audioStreamIndex: audioStreamIndex,
      subtitleStreamIndex: subtitleStreamIndex,
    );

    final headers = buildEmbyHeaders(
      serverType: serverType,
      deviceId: deviceId,
      userId: userId,
      token: token,
    );

    return NetworkStreamResolution(
      streamUrl: res.streamUrl,
      httpHeaders: headers,
      mediaSources: res.mediaSources,
      selectedMediaSourceId: res.selectedMediaSourceId,
      playSessionId: res.playSessionId,
      mediaSourceId: res.mediaSourceId,
      streamSizeBytes: res.streamSizeBytes,
    );
  }
}
