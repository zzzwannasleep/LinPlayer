import '../../../state/preferences.dart';

int? embyAsInt(dynamic value) {
  if (value is int) return value;
  if (value is num) return value.toInt();
  if (value is String) return int.tryParse(value);
  return null;
}

List<Map<String, dynamic>> embyStreamsOfType(
  Map<String, dynamic> mediaSource,
  String type,
) {
  final streams = (mediaSource['MediaStreams'] as List?) ?? const [];
  return streams
      .where((e) => (e as Map)['Type'] == type)
      .map((e) => e as Map<String, dynamic>)
      .toList();
}

String embyMediaSourceTitle(Map<String, dynamic> mediaSource) {
  return (mediaSource['Name'] as String?) ??
      (mediaSource['Container'] as String?) ??
      '默认版本';
}

String? embyPickPreferredMediaSourceId(
  List<Map<String, dynamic>> sources,
  VideoVersionPreference preference,
) {
  if (sources.isEmpty) return null;
  if (preference == VideoVersionPreference.defaultVersion) return null;

  int heightOf(Map<String, dynamic> mediaSource) {
    final videos = embyStreamsOfType(mediaSource, 'Video');
    final video = videos.isNotEmpty ? videos.first : null;
    return embyAsInt(video?['Height']) ?? 0;
  }

  int bitrateOf(Map<String, dynamic> mediaSource) =>
      embyAsInt(mediaSource['Bitrate']) ?? 0;

  String videoCodecOf(Map<String, dynamic> mediaSource) {
    final codec = (mediaSource['VideoCodec'] as String?)?.trim();
    if (codec != null && codec.isNotEmpty) return codec.toLowerCase();

    final videos = embyStreamsOfType(mediaSource, 'Video');
    final video = videos.isNotEmpty ? videos.first : null;
    final codec2 = (video?['Codec'] as String?)?.trim() ?? '';
    return codec2.toLowerCase();
  }

  bool isHevc(Map<String, dynamic> mediaSource) {
    final codec = videoCodecOf(mediaSource);
    return codec.contains('hevc') ||
        codec.contains('h265') ||
        codec.contains('h.265') ||
        codec.contains('x265');
  }

  bool isAvc(Map<String, dynamic> mediaSource) {
    final codec = videoCodecOf(mediaSource);
    return codec.contains('avc') ||
        codec.contains('h264') ||
        codec.contains('h.264') ||
        codec.contains('x264');
  }

  Map<String, dynamic>? pickBest(
    List<Map<String, dynamic>> list, {
    required int Function(Map<String, dynamic> mediaSource) primary,
    required int Function(Map<String, dynamic> mediaSource) secondary,
    required bool higherIsBetter,
  }) {
    if (list.isEmpty) return null;
    Map<String, dynamic> chosen = list.first;
    var bestPrimary = primary(chosen);
    var bestSecondary = secondary(chosen);
    for (final mediaSource in list.skip(1)) {
      final p = primary(mediaSource);
      final s = secondary(mediaSource);
      final better = higherIsBetter
          ? (p > bestPrimary || (p == bestPrimary && s > bestSecondary))
          : (p < bestPrimary || (p == bestPrimary && s < bestSecondary));
      if (better) {
        chosen = mediaSource;
        bestPrimary = p;
        bestSecondary = s;
      }
    }
    return chosen;
  }

  Map<String, dynamic>? chosen;
  switch (preference) {
    case VideoVersionPreference.highestResolution:
      chosen = pickBest(
        sources,
        primary: heightOf,
        secondary: bitrateOf,
        higherIsBetter: true,
      );
      break;
    case VideoVersionPreference.lowestBitrate:
      chosen = pickBest(
        sources,
        primary: (mediaSource) =>
            bitrateOf(mediaSource) == 0 ? 1 << 30 : bitrateOf(mediaSource),
        secondary: heightOf,
        higherIsBetter: false,
      );
      break;
    case VideoVersionPreference.preferHevc:
      final hevc = sources.where(isHevc).toList();
      chosen = pickBest(
        hevc.isNotEmpty ? hevc : sources,
        primary: heightOf,
        secondary: bitrateOf,
        higherIsBetter: true,
      );
      break;
    case VideoVersionPreference.preferAvc:
      final avc = sources.where(isAvc).toList();
      chosen = pickBest(
        avc.isNotEmpty ? avc : sources,
        primary: heightOf,
        secondary: bitrateOf,
        higherIsBetter: true,
      );
      break;
    case VideoVersionPreference.defaultVersion:
      break;
  }

  final id = chosen?['Id']?.toString();
  return (id == null || id.trim().isEmpty) ? null : id.trim();
}

String embyMediaSourceSubtitle(Map<String, dynamic> mediaSource) {
  final size = mediaSource['Size'];
  final sizeGb =
      size is num ? (size / (1024 * 1024 * 1024)).toStringAsFixed(1) : null;
  final bitrate = embyAsInt(mediaSource['Bitrate']);
  final bitrateMbps =
      bitrate != null ? (bitrate / 1000000).toStringAsFixed(1) : null;

  final videoStreams = embyStreamsOfType(mediaSource, 'Video');
  final video = videoStreams.isNotEmpty ? videoStreams.first : null;
  final height = embyAsInt(video?['Height']);
  final codec =
      (mediaSource['VideoCodec'] as String?) ?? (video?['Codec'] as String?);

  final parts = <String>[];
  if (height != null) parts.add('${height}p');
  if (codec != null && codec.isNotEmpty) parts.add(codec.toUpperCase());
  if (sizeGb != null) parts.add('$sizeGb GB');
  if (bitrateMbps != null) parts.add('$bitrateMbps Mbps');
  return parts.isEmpty ? '直连播放' : parts.join(' / ');
}
