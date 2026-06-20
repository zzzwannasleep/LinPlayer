import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:uuid/uuid.dart';

import '../../api/api_interfaces.dart';
import '../app_logger.dart';
import '../watch_history/watch_history_models.dart';
import '../watch_history/watch_history_service.dart';
import 'mpv_ipc_bridge.dart';

typedef ExternalPlayerApiReader = ApiClientFactory Function();
typedef ExternalPlayerScopeKeyReader = String? Function();
typedef ExternalPlayerThresholdReader = int Function();
typedef MpvIpcBridgeFactory = Future<MpvIpcBridge> Function(String sessionId);

class ExternalPlayerSessionService {
  ExternalPlayerSessionService({
    required WatchHistoryService watchHistory,
    required ExternalPlayerApiReader apiReader,
    required ExternalPlayerScopeKeyReader scopeKeyReader,
    required ExternalPlayerThresholdReader watchedThresholdReader,
    MpvIpcBridgeFactory? bridgeFactory,
    Uuid? uuid,
  })  : _watchHistory = watchHistory,
        _apiReader = apiReader,
        _scopeKeyReader = scopeKeyReader,
        _watchedThresholdReader = watchedThresholdReader,
        _bridgeFactory = bridgeFactory ??
            ((sessionId) => MpvIpcBridge.create(sessionId: sessionId)),
        _uuid = uuid ?? const Uuid();

  static final AppLogger _logger = AppLogger();

  final WatchHistoryService _watchHistory;
  final ExternalPlayerApiReader _apiReader;
  final ExternalPlayerScopeKeyReader _scopeKeyReader;
  final ExternalPlayerThresholdReader _watchedThresholdReader;
  final MpvIpcBridgeFactory _bridgeFactory;
  final Uuid _uuid;

  final Map<String, _TrackedExternalPlayerSession> _sessions =
      <String, _TrackedExternalPlayerSession>{};

  Future<void> launchMpv({
    required String executablePath,
    required MediaItem item,
    required String mediaSourceId,
    required String videoUrl,
    required int startPositionTicks,
    int? mediaSourceRunTimeTicks,
  }) async {
    final sessionId = _uuid.v4();
    final bridge = await _bridgeFactory(sessionId);
    final arguments = <String>[
      '--input-ipc-server=${bridge.endpoint}',
      if (_buildStartArgument(startPositionTicks) case final startArg?)
        '--start=$startArg',
      // 选项终止符：其后的 videoUrl 一律按位置参数处理，永不被解析为 mpv 选项
      // （即便 URL 以 - / -- 开头），杜绝选项注入。
      '--',
      videoUrl,
    ];

    ApiClientFactory? api;
    try {
      api = _apiReader();
    } catch (_) {
      api = null;
    }

    final process = await Process.start(
      executablePath,
      arguments,
      mode: ProcessStartMode.normal,
    );

    final session = _TrackedExternalPlayerSession(
      sessionId: sessionId,
      item: item,
      mediaSourceId: mediaSourceId,
      startPositionTicks: startPositionTicks < 0 ? 0 : startPositionTicks,
      initialRunTimeTicks: mediaSourceRunTimeTicks ?? item.runTimeTicks,
      watchedThresholdPercent: _watchedThresholdReader(),
      scopeKey: _scopeKeyReader(),
      api: api,
      process: process,
      bridge: bridge,
    );
    _sessions[sessionId] = session;

    _attachProcessLogs(session);
    unawaited(process.exitCode.then((exitCode) {
      _enqueueSessionAction(
        session,
        () => _finalizeSession(
          session,
          reason: 'process_exit:$exitCode',
        ),
      );
    }));

    unawaited(_connectAndObserve(session));
  }

  Future<void> dispose() async {
    final sessions = _sessions.values.toList(growable: false);
    for (final session in sessions) {
      await _disposeSession(session);
    }
    _sessions.clear();
  }

  Future<void> _connectAndObserve(
    _TrackedExternalPlayerSession session,
  ) async {
    session.bridgeSubscription = session.bridge.messages.listen(
      (message) {
        _enqueueSessionAction(
          session,
          () => _handleBridgeMessage(session, message),
        );
      },
      onError: (Object error, StackTrace stackTrace) {
        _logger.w(
          'ExternalMpv',
          '[${session.sessionId}] IPC error: $error',
        );
      },
      onDone: () {
        _logger.d(
          'ExternalMpv',
          '[${session.sessionId}] IPC stream closed',
        );
      },
    );

    try {
      await session.bridge.connect();
      if (_isInactive(session)) {
        return;
      }

      session.ipcConnected = true;
      session.currentPositionTicks = session.startPositionTicks;

      await _reportPlaybackStart(session);
      await _writeWatchHistory(
        session,
        positionTicks: session.startPositionTicks,
        incrementPlayCount: true,
        force: true,
      );
      session.lastProgressReportedAt = DateTime.now().toUtc();
      session.lastReportedPositionTicks = session.startPositionTicks;

      await session.bridge.sendCommand(
        const ['observe_property', 1, 'time-pos'],
      );
      await session.bridge.sendCommand(
        const ['observe_property', 2, 'duration'],
      );
      await session.bridge.sendCommand(
        const ['observe_property', 3, 'pause'],
      );

      _logger.i(
        'ExternalMpv',
        '[${session.sessionId}] IPC connected and playback tracking started',
      );
    } catch (error, stackTrace) {
      _logger.eWithStack(
        'ExternalMpv',
        'Failed to connect external MPV IPC for session ${session.sessionId}',
        error,
        stackTrace,
      );
      await session.bridge.close();
    }
  }

  Future<void> _handleBridgeMessage(
    _TrackedExternalPlayerSession session,
    Map<String, dynamic> message,
  ) async {
    if (_isInactive(session)) {
      return;
    }

    final event = message['event']?.toString();
    if (event == 'property-change') {
      final propertyName = message['name']?.toString();
      switch (propertyName) {
        case 'time-pos':
          final seconds = _toDouble(message['data']);
          if (seconds == null) {
            return;
          }
          session.currentPositionTicks = _secondsToTicks(seconds);
          await _maybeReportProgress(session);
          return;
        case 'duration':
          final seconds = _toDouble(message['data']);
          if (seconds != null) {
            session.currentDurationTicks = _secondsToTicks(seconds);
          }
          return;
        case 'pause':
          final paused = _toBool(message['data']);
          if (paused == null || paused == session.isPaused) {
            return;
          }
          session.isPaused = paused;
          if (paused) {
            await _reportProgress(session, force: true);
          }
          return;
      }
      return;
    }

    if (event == 'end-file') {
      final reason = message['reason']?.toString();
      await _finalizeSession(
        session,
        reachedEof: reason == 'eof',
        reason: 'end-file:${reason ?? 'unknown'}',
      );
    }
  }

  Future<void> _maybeReportProgress(
    _TrackedExternalPlayerSession session,
  ) async {
    if (!session.ipcConnected || _isInactive(session)) {
      return;
    }

    final now = DateTime.now().toUtc();
    final lastReportAt = session.lastProgressReportedAt;
    final lastPositionTicks = session.lastReportedPositionTicks;
    final positionDelta =
        (session.currentPositionTicks - lastPositionTicks).abs();
    final reachedInterval =
        lastReportAt == null || now.difference(lastReportAt).inSeconds >= 10;
    final largeSeek = positionDelta >= _secondsToTicks(30);

    if (!reachedInterval && !largeSeek) {
      return;
    }

    await _reportProgress(session);
  }

  Future<void> _reportPlaybackStart(
    _TrackedExternalPlayerSession session,
  ) async {
    final api = session.api;
    if (api == null) {
      return;
    }

    try {
      await api.playback.reportPlaybackStart(
        PlaybackStartInfo(
          itemId: session.item.id,
          mediaSourceId: session.mediaSourceId,
        ),
      );
    } catch (error, stackTrace) {
      _logger.eWithStack(
        'ExternalMpv',
        'Failed to report playback start for session ${session.sessionId}',
        error,
        stackTrace,
      );
    }
  }

  Future<void> _reportProgress(
    _TrackedExternalPlayerSession session, {
    bool force = false,
  }) async {
    if (!session.ipcConnected || _isInactive(session)) {
      return;
    }

    final positionTicks =
        mathMax(session.currentPositionTicks, session.startPositionTicks);
    final api = session.api;
    if (api != null) {
      try {
        await api.playback.reportPlaybackProgress(
          PlaybackProgressInfo(
            itemId: session.item.id,
            mediaSourceId: session.mediaSourceId,
            positionTicks: positionTicks,
            isPaused: session.isPaused,
          ),
        );
      } catch (error, stackTrace) {
        _logger.eWithStack(
          'ExternalMpv',
          'Failed to report playback progress for session ${session.sessionId}',
          error,
          stackTrace,
        );
      }
    }

    await _writeWatchHistory(
      session,
      positionTicks: positionTicks,
      force: force,
    );

    session.lastProgressReportedAt = DateTime.now().toUtc();
    session.lastReportedPositionTicks = positionTicks;
  }

  Future<void> _writeWatchHistory(
    _TrackedExternalPlayerSession session, {
    required int positionTicks,
    bool incrementPlayCount = false,
    bool force = false,
  }) async {
    final scopeKey = session.scopeKey;
    final api = session.api;
    if (scopeKey == null || api == null) {
      return;
    }

    try {
      await _watchHistory.capturePlayback(
        scopeKey: scopeKey,
        api: api,
        item: session.item,
        positionTicks: positionTicks,
        source: WatchHistoryWriteSource.externalMpv,
        watchedThresholdPercent: session.watchedThresholdPercent,
        incrementPlayCount: incrementPlayCount,
        force: force,
      );
    } catch (error, stackTrace) {
      _logger.eWithStack(
        'ExternalMpv',
        'Failed to persist local watch history for session ${session.sessionId}',
        error,
        stackTrace,
      );
    }
  }

  Future<void> _finalizeSession(
    _TrackedExternalPlayerSession session, {
    bool reachedEof = false,
    required String reason,
  }) async {
    if (session.completed) {
      return;
    }
    session.completed = true;

    final effectiveRuntimeTicks = session.effectiveRunTimeTicks;
    if (reachedEof &&
        effectiveRuntimeTicks != null &&
        effectiveRuntimeTicks > 0) {
      session.currentPositionTicks =
          mathMax(session.currentPositionTicks, effectiveRuntimeTicks);
    }

    if (session.ipcConnected) {
      final stopPositionTicks =
          mathMax(session.currentPositionTicks, session.startPositionTicks);
      final api = session.api;
      if (api != null) {
        try {
          await api.playback.reportPlaybackStopped(
            PlaybackStopInfo(
              itemId: session.item.id,
              mediaSourceId: session.mediaSourceId,
              positionTicks: stopPositionTicks,
            ),
          );
        } catch (error, stackTrace) {
          _logger.eWithStack(
            'ExternalMpv',
            'Failed to report playback stop for session ${session.sessionId}',
            error,
            stackTrace,
          );
        }
      }

      await _writeWatchHistory(
        session,
        positionTicks: stopPositionTicks,
        force: true,
      );
    } else {
      _logger.w(
        'ExternalMpv',
        '[${session.sessionId}] Session finished without IPC; skipped unreliable stop persistence ($reason)',
      );
    }

    _logger.i(
      'ExternalMpv',
      '[${session.sessionId}] Session finalized: $reason',
    );
    await _disposeSession(session);
  }

  Future<void> _disposeSession(_TrackedExternalPlayerSession session) async {
    _sessions.remove(session.sessionId);

    final bridgeSubscription = session.bridgeSubscription;
    session.bridgeSubscription = null;
    await bridgeSubscription?.cancel();

    await session.bridge.close();

    final stdoutSubscription = session.stdoutSubscription;
    session.stdoutSubscription = null;
    await stdoutSubscription?.cancel();

    final stderrSubscription = session.stderrSubscription;
    session.stderrSubscription = null;
    await stderrSubscription?.cancel();
  }

  void _attachProcessLogs(_TrackedExternalPlayerSession session) {
    session.stdoutSubscription = session.process.stdout
        .transform(const Utf8Decoder(allowMalformed: true))
        .transform(const LineSplitter())
        .listen((line) {
      if (line.trim().isEmpty) {
        return;
      }
      _logger.d('ExternalMpv', '[${session.sessionId}] stdout: $line');
    });

    session.stderrSubscription = session.process.stderr
        .transform(const Utf8Decoder(allowMalformed: true))
        .transform(const LineSplitter())
        .listen((line) {
      if (line.trim().isEmpty) {
        return;
      }
      _logger.w('ExternalMpv', '[${session.sessionId}] stderr: $line');
    });
  }

  void _enqueueSessionAction(
    _TrackedExternalPlayerSession session,
    Future<void> Function() action,
  ) {
    session.pendingAction =
        session.pendingAction.catchError((_) {}).then((_) => action());
  }

  bool _isInactive(_TrackedExternalPlayerSession session) {
    return session.completed || !_sessions.containsKey(session.sessionId);
  }

  static String? _buildStartArgument(int ticks) {
    final seconds = ticks / 10000000;
    if (seconds < 5) {
      return null;
    }
    return seconds.toStringAsFixed(3);
  }

  static double? _toDouble(Object? value) {
    if (value is num) {
      return value.toDouble();
    }
    return double.tryParse(value?.toString() ?? '');
  }

  static bool? _toBool(Object? value) {
    if (value is bool) {
      return value;
    }
    if (value is num) {
      return value != 0;
    }
    final normalized = value?.toString().toLowerCase();
    if (normalized == 'true') {
      return true;
    }
    if (normalized == 'false') {
      return false;
    }
    return null;
  }

  static int _secondsToTicks(double seconds) {
    return (seconds * 10000000).round();
  }
}

class _TrackedExternalPlayerSession {
  _TrackedExternalPlayerSession({
    required this.sessionId,
    required this.item,
    required this.mediaSourceId,
    required this.startPositionTicks,
    required this.initialRunTimeTicks,
    required this.watchedThresholdPercent,
    required this.scopeKey,
    required this.api,
    required this.process,
    required this.bridge,
  }) : currentPositionTicks = startPositionTicks;

  final String sessionId;
  final MediaItem item;
  final String mediaSourceId;
  final int startPositionTicks;
  final int? initialRunTimeTicks;
  final int watchedThresholdPercent;
  final String? scopeKey;
  final ApiClientFactory? api;
  final Process process;
  final MpvIpcBridge bridge;

  StreamSubscription<Map<String, dynamic>>? bridgeSubscription;
  StreamSubscription<String>? stdoutSubscription;
  StreamSubscription<String>? stderrSubscription;
  Future<void> pendingAction = Future<void>.value();

  bool ipcConnected = false;
  bool completed = false;
  bool isPaused = false;
  int currentPositionTicks;
  int? currentDurationTicks;
  DateTime? lastProgressReportedAt;
  int lastReportedPositionTicks = 0;

  int? get effectiveRunTimeTicks => currentDurationTicks ?? initialRunTimeTicks;
}

int mathMax(int left, int right) => left >= right ? left : right;
