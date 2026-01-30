import '../../../server_adapters/server_access.dart';

typedef DurationToTicks = int Function(Duration duration);

class NetworkPlaybackReporter {
  NetworkPlaybackReporter({
    required this.itemId,
    DurationToTicks? toTicks,
    this.progressInterval = const Duration(seconds: 15),
    this.pausedChangedInterval = const Duration(seconds: 1),
    this.completeThreshold = const Duration(seconds: 20),
  }) : _toTicks = toTicks ?? _defaultToTicks;

  final String itemId;
  final Duration progressInterval;
  final Duration pausedChangedInterval;
  final Duration completeThreshold;

  final DurationToTicks _toTicks;

  DateTime? _lastProgressReportAt;
  bool _lastProgressReportPaused = false;
  bool _reportedStart = false;
  bool _reportedStop = false;
  bool _progressReportInFlight = false;

  bool get isStarted => _reportedStart;
  bool get isStopped => _reportedStop;

  void reset() {
    _lastProgressReportAt = null;
    _lastProgressReportPaused = false;
    _reportedStart = false;
    _reportedStop = false;
    _progressReportInFlight = false;
  }

  Future<void> reportPlaybackStartBestEffort({
    required ServerAccess? access,
    required String? playSessionId,
    required String? mediaSourceId,
    required Duration position,
    required bool paused,
  }) async {
    if (_reportedStart || _reportedStop) return;
    final a = access;
    if (a == null) return;
    if (a.auth.baseUrl.isEmpty || a.auth.token.isEmpty) return;

    _reportedStart = true;
    final posTicks = _toTicks(position);
    try {
      final ps = playSessionId;
      final ms = mediaSourceId;
      if (ps != null && ps.isNotEmpty && ms != null && ms.isNotEmpty) {
        await a.adapter.reportPlaybackStart(
          a.auth,
          itemId: itemId,
          mediaSourceId: ms,
          playSessionId: ps,
          positionTicks: posTicks,
          isPaused: paused,
        );
      }
    } catch (_) {}
  }

  void maybeReportPlaybackProgressBestEffort({
    required ServerAccess? access,
    required String? playSessionId,
    required String? mediaSourceId,
    required Duration position,
    required bool paused,
    bool force = false,
  }) {
    if (_reportedStop) return;
    if (_progressReportInFlight) return;
    final a = access;
    if (a == null) return;
    if (a.auth.baseUrl.isEmpty || a.auth.token.isEmpty) return;

    final now = DateTime.now();
    final due = _lastProgressReportAt == null ||
        now.difference(_lastProgressReportAt!) >= progressInterval;
    final pausedChanged = paused != _lastProgressReportPaused &&
        (_lastProgressReportAt == null ||
            now.difference(_lastProgressReportAt!) >= pausedChangedInterval);
    final shouldReport = force || due || pausedChanged;
    if (!shouldReport) return;

    _lastProgressReportAt = now;
    _lastProgressReportPaused = paused;
    _progressReportInFlight = true;

    final ticks = _toTicks(position);

    // ignore: unawaited_futures
    () async {
      try {
        final ps = playSessionId;
        final ms = mediaSourceId;
        if (ps != null && ps.isNotEmpty && ms != null && ms.isNotEmpty) {
          await a.adapter.reportPlaybackProgress(
            a.auth,
            itemId: itemId,
            mediaSourceId: ms,
            playSessionId: ps,
            positionTicks: ticks,
            isPaused: paused,
          );
        } else if (a.auth.userId.isNotEmpty) {
          await a.adapter.updatePlaybackPosition(
            a.auth,
            itemId: itemId,
            positionTicks: ticks,
          );
        }
      } finally {
        _progressReportInFlight = false;
      }
    }();
  }

  Future<void> reportPlaybackStoppedBestEffort({
    required ServerAccess? access,
    required String? playSessionId,
    required String? mediaSourceId,
    required Duration position,
    required Duration duration,
    bool completed = false,
  }) async {
    if (_reportedStop) return;
    _reportedStop = true;

    final a = access;
    if (a == null) return;
    if (a.auth.baseUrl.isEmpty || a.auth.token.isEmpty) return;

    final played = completed ||
        (duration > Duration.zero && position >= duration - completeThreshold);
    final ticks = _toTicks(position);

    try {
      final ps = playSessionId;
      final ms = mediaSourceId;
      if (ps != null && ps.isNotEmpty && ms != null && ms.isNotEmpty) {
        await a.adapter.reportPlaybackStopped(
          a.auth,
          itemId: itemId,
          mediaSourceId: ms,
          playSessionId: ps,
          positionTicks: ticks,
        );
      }
    } catch (_) {}

    try {
      if (a.auth.userId.isNotEmpty) {
        await a.adapter.updatePlaybackPosition(
          a.auth,
          itemId: itemId,
          positionTicks: ticks,
          played: played,
        );
      }
    } catch (_) {}
  }

  static int _defaultToTicks(Duration duration) => duration.inMicroseconds * 10;
}
