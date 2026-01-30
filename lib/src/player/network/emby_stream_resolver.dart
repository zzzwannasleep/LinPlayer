import '../../../server_adapters/server_access.dart';
import '../../../state/preferences.dart';
import 'emby_media_source_utils.dart';

class EmbyStreamResolution {
  const EmbyStreamResolution({
    required this.streamUrl,
    required this.mediaSources,
    this.selectedMediaSourceId,
    this.playSessionId,
    this.mediaSourceId,
    this.streamSizeBytes,
  });

  final String streamUrl;
  final List<Map<String, dynamic>> mediaSources;
  final String? selectedMediaSourceId;
  final String? playSessionId;
  final String? mediaSourceId;
  final int? streamSizeBytes;
}

Future<EmbyStreamResolution> resolveEmbyStreamUrl({
  required ServerAccess? access,
  required String baseUrl,
  required String token,
  required String userId,
  required String deviceId,
  required String itemId,
  required VideoVersionPreference preferredVideoVersion,
  bool exoPlayer = false,
  bool allowTranscoding = false,
  String? selectedMediaSourceId,
  int? seriesMediaSourceIndex,
  int? audioStreamIndex,
  int? subtitleStreamIndex,
}) async {
  String applyQueryPrefs(String url) {
    final uri = Uri.parse(url);
    final params = Map<String, String>.from(uri.queryParameters);
    if (!params.containsKey('api_key')) params['api_key'] = token;
    if (audioStreamIndex != null) {
      params['AudioStreamIndex'] = audioStreamIndex.toString();
    }
    if (subtitleStreamIndex != null && subtitleStreamIndex >= 0) {
      params['SubtitleStreamIndex'] = subtitleStreamIndex.toString();
    }
    return uri.replace(queryParameters: params).toString();
  }

  String resolve(String candidate) {
    final resolved = Uri.parse(baseUrl).resolve(candidate).toString();
    return applyQueryPrefs(resolved);
  }

  try {
    final effectiveAccess = access;
    if (effectiveAccess == null) throw StateError('No server access');

    final info = await effectiveAccess.adapter.fetchPlaybackInfo(
      effectiveAccess.auth,
      itemId: itemId,
      exoPlayer: exoPlayer,
    );
    final sources = info.mediaSources.cast<Map<String, dynamic>>();

    Map<String, dynamic>? mediaSource;
    String? effectiveSelectedId = (selectedMediaSourceId ?? '').trim().isEmpty
        ? null
        : selectedMediaSourceId!.trim();

    if (sources.isNotEmpty) {
      if (effectiveSelectedId == null &&
          seriesMediaSourceIndex != null &&
          seriesMediaSourceIndex >= 0 &&
          seriesMediaSourceIndex < sources.length) {
        final id = (sources[seriesMediaSourceIndex]['Id'] as String?)?.trim();
        if (id != null && id.isNotEmpty) {
          effectiveSelectedId = id;
        }
      }

      if (effectiveSelectedId == null) {
        final preferredId =
            embyPickPreferredMediaSourceId(sources, preferredVideoVersion);
        if (preferredId != null && preferredId.isNotEmpty) {
          effectiveSelectedId = preferredId;
        }
      }

      if (effectiveSelectedId != null && effectiveSelectedId.isNotEmpty) {
        mediaSource = sources.firstWhere(
          (s) => (s['Id'] as String? ?? '') == effectiveSelectedId,
          orElse: () => sources.first,
        );
      } else {
        mediaSource = sources.first;
      }
    }

    final playSessionId = info.playSessionId;
    final mediaSourceId =
        (mediaSource?['Id'] as String?)?.trim().isNotEmpty == true
            ? (mediaSource!['Id'] as String).trim()
            : info.mediaSourceId;
    final sizeBytes = embyAsInt(mediaSource?['Size']);

    final directStreamUrl =
        (mediaSource?['DirectStreamUrl'] as String?)?.trim();
    if (directStreamUrl != null && directStreamUrl.isNotEmpty) {
      return EmbyStreamResolution(
        streamUrl: resolve(directStreamUrl),
        playSessionId: playSessionId,
        mediaSourceId: mediaSourceId,
        streamSizeBytes: sizeBytes,
        mediaSources: List<Map<String, dynamic>>.from(sources),
        selectedMediaSourceId: effectiveSelectedId,
      );
    }

    if (allowTranscoding) {
      final transcodingUrl =
          (mediaSource?['TranscodingUrl'] as String?)?.trim();
      if (transcodingUrl != null && transcodingUrl.isNotEmpty) {
        return EmbyStreamResolution(
          streamUrl: resolve(transcodingUrl),
          playSessionId: playSessionId,
          mediaSourceId: mediaSourceId,
          streamSizeBytes: sizeBytes,
          mediaSources: List<Map<String, dynamic>>.from(sources),
          selectedMediaSourceId: effectiveSelectedId,
        );
      }
    }

    return EmbyStreamResolution(
      streamUrl: applyQueryPrefs(
        '$baseUrl/emby/Videos/$itemId/stream?static=true&MediaSourceId=$mediaSourceId'
        '&PlaySessionId=$playSessionId&UserId=$userId&DeviceId=$deviceId&api_key=$token',
      ),
      playSessionId: playSessionId,
      mediaSourceId: mediaSourceId,
      streamSizeBytes: sizeBytes,
      mediaSources: List<Map<String, dynamic>>.from(sources),
      selectedMediaSourceId: effectiveSelectedId,
    );
  } catch (_) {
    return EmbyStreamResolution(
      streamUrl: applyQueryPrefs(
        '$baseUrl/emby/Videos/$itemId/stream?static=true&UserId=$userId'
        '&DeviceId=$deviceId&api_key=$token',
      ),
      mediaSources: const [],
    );
  }
}
