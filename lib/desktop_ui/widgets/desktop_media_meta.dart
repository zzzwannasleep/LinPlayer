import 'package:lin_player_server_adapters/lin_player_server_adapters.dart';

String mediaYear(MediaItem item) {
  final raw = (item.premiereDate ?? '').trim();
  if (raw.isEmpty) return '';
  final parsed = DateTime.tryParse(raw);
  if (parsed != null) return parsed.year.toString();
  return raw.length >= 4 ? raw.substring(0, 4) : raw;
}

String mediaTypeLabel(MediaItem item) {
  switch (item.type.trim().toLowerCase()) {
    case 'series':
      return 'Series';
    case 'movie':
      return 'Movie';
    case 'episode':
      return 'Episode';
    case 'season':
      return 'Season';
    default:
      return item.type.isEmpty ? 'Media' : item.type;
  }
}

String mediaRuntimeLabel(MediaItem item) {
  final ticks = item.runTimeTicks;
  if (ticks == null || ticks <= 0) return '';
  final totalSeconds = ticks ~/ 10000000;
  if (totalSeconds <= 0) return '';
  final duration = Duration(seconds: totalSeconds);
  final hours = duration.inHours;
  final minutes = duration.inMinutes.remainder(60);
  if (hours <= 0) return '${duration.inMinutes}m';
  return '${hours}h ${minutes}m';
}

double mediaProgress(MediaItem item) {
  final ticks = item.runTimeTicks;
  if (ticks == null || ticks <= 0 || item.playbackPositionTicks <= 0) return 0;
  final value = item.playbackPositionTicks / ticks;
  return value.clamp(0, 1).toDouble();
}
