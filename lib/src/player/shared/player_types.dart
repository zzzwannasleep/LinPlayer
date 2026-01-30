enum OrientationMode { auto, landscape, portrait }

enum GestureMode { none, brightness, volume, seek, speed }

String formatClock(Duration d) {
  String two(int v) => v.toString().padLeft(2, '0');
  final h = d.inHours;
  final m = d.inMinutes.remainder(60);
  final s = d.inSeconds.remainder(60);
  return h > 0 ? '${two(h)}:${two(m)}:${two(s)}' : '${two(m)}:${two(s)}';
}

Duration safeSeekTarget(
  Duration target,
  Duration total, {
  Duration rewind = const Duration(seconds: 5),
}) {
  if (target <= Duration.zero) return Duration.zero;
  if (total <= Duration.zero) return target;
  if (target < total) return target;
  final fallback = total - rewind;
  return fallback > Duration.zero ? fallback : Duration.zero;
}
