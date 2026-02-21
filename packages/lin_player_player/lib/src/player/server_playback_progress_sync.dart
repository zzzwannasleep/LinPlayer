import 'dart:async';

import 'package:lin_player_server_adapters/lin_player_server_adapters.dart';

class ServerPlaybackProgressSync {
  ServerPlaybackProgressSync({
    required this.adapter,
    required this.auth,
    required this.itemId,
    required this.getPosition,
    required this.isPlaying,
    this.getPlaySessionId,
    this.getMediaSourceId,
    this.interval = const Duration(seconds: 5),
    this.requestTimeout = const Duration(seconds: 5),
  });

  final MediaServerAdapter adapter;
  final ServerAuthSession auth;
  final String itemId;
  final Duration Function() getPosition;
  final bool Function() isPlaying;
  final String? Function()? getPlaySessionId;
  final String? Function()? getMediaSourceId;
  final Duration interval;
  final Duration requestTimeout;

  Timer? _timer;
  bool _syncInFlight = false;
  int _lastSyncedSecond = -1;

  bool get isRunning => _timer != null;

  static int _toTicks(Duration d) => d.inMicroseconds * 10;

  void reset() {
    _lastSyncedSecond = -1;
  }

  void start() {
    if (_timer != null) return;
    if (auth.baseUrl.trim().isEmpty || auth.token.trim().isEmpty) return;
    if (auth.userId.trim().isEmpty) return;
    _timer = Timer.periodic(interval, (_) {
      // ignore: unawaited_futures
      syncBestEffort();
    });
  }

  void stop() {
    _timer?.cancel();
    _timer = null;
  }

  void dispose() {
    stop();
  }

  Future<Duration?> fetchServerProgressDurationBestEffort() async {
    if (auth.baseUrl.trim().isEmpty || auth.token.trim().isEmpty) return null;
    if (auth.userId.trim().isEmpty) return null;

    try {
      final detail = await adapter
          .fetchItemDetail(auth, itemId: itemId)
          .timeout(requestTimeout);
      final ticks = detail.playbackPositionTicks;
      if (ticks <= 0) return null;
      return Duration(microseconds: (ticks / 10).round());
    } catch (_) {
      return null;
    }
  }

  Future<void> syncBestEffort({Duration? position}) async {
    if (auth.baseUrl.trim().isEmpty || auth.token.trim().isEmpty) return;
    if (auth.userId.trim().isEmpty) return;
    if (_syncInFlight) return;

    final raw = position ?? getPosition();
    final safe = raw < Duration.zero ? Duration.zero : raw;
    final second = safe.inSeconds;
    if (second == _lastSyncedSecond) return;

    _syncInFlight = true;
    try {
      final ticks = _toTicks(safe);
      final paused = !isPlaying();

      final ps = getPlaySessionId?.call();
      final ms = getMediaSourceId?.call();
      if (ps != null && ps.isNotEmpty && ms != null && ms.isNotEmpty) {
        try {
          await adapter
              .reportPlaybackProgress(
                auth,
                itemId: itemId,
                mediaSourceId: ms,
                playSessionId: ps,
                positionTicks: ticks,
                isPaused: paused,
              )
              .timeout(requestTimeout);
        } catch (_) {}
      }

      try {
        await adapter
            .updatePlaybackPosition(
              auth,
              itemId: itemId,
              positionTicks: ticks,
            )
            .timeout(requestTimeout);
      } catch (_) {}

      _lastSyncedSecond = second;
    } finally {
      _syncInFlight = false;
    }
  }
}

