import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../services/watch_history/watch_history_models.dart';
import '../services/watch_history/watch_history_restore_service.dart';
import '../services/watch_history/watch_history_service.dart';
import '../services/watch_history/watch_history_store.dart';
import '../services/watch_history/watch_history_writeback_service.dart';
import 'app_preferences.dart';
import 'media_providers.dart';
import 'server_providers.dart';

final watchHistoryStoreProvider = Provider<WatchHistoryStore>((ref) {
  return WatchHistoryStore();
});

final watchHistoryProvider = Provider<WatchHistoryService>((ref) {
  return WatchHistoryService(
    store: ref.watch(watchHistoryStoreProvider),
  );
});

final watchHistoryRestoreServiceProvider =
    Provider<WatchHistoryRestoreService>((ref) {
  return WatchHistoryRestoreService(
    store: ref.watch(watchHistoryStoreProvider),
    historyService: ref.watch(watchHistoryProvider),
  );
});

final watchHistoryWritebackServiceProvider =
    Provider<WatchHistoryWritebackService>((ref) {
  return WatchHistoryWritebackService(
    store: ref.watch(watchHistoryStoreProvider),
    historyService: ref.watch(watchHistoryProvider),
  );
});

/// 看完 / 进度回传到其它服务器的主开关。默认关闭（会写入其它服务器，需用户主动开启）。
final crossServerWritebackEnabledProvider =
    StateNotifierProvider<PreferenceNotifier<bool>, bool>((ref) {
  return PreferenceNotifier<bool>(
    defaultValue: false,
    readValue: (prefs) => prefs.getBool('linplayer_cross_server_writeback'),
    writeValue: (prefs, value) async {
      await prefs.setBool('linplayer_cross_server_writeback', value);
    },
  );
});

/// 回传目标范围：所有看过的服 / 仅初次看过的服 / 仅最近看过的服。默认所有。
final crossServerWritebackRangeProvider = StateNotifierProvider<
    PreferenceNotifier<CrossServerWritebackRange>,
    CrossServerWritebackRange>((ref) {
  return PreferenceNotifier<CrossServerWritebackRange>(
    defaultValue: CrossServerWritebackRange.all,
    readValue: (prefs) => crossServerWritebackRangeFromWire(
        prefs.getString('linplayer_cross_server_writeback_range')),
    writeValue: (prefs, value) async {
      await prefs.setString('linplayer_cross_server_writeback_range',
          crossServerWritebackRangeToWire(value));
    },
  );
});

/// 回传时是否同时同步播放进度（而不仅是「已看完」标记）。默认开启。
final crossServerWritebackProgressProvider =
    StateNotifierProvider<PreferenceNotifier<bool>, bool>((ref) {
  return PreferenceNotifier<bool>(
    defaultValue: true,
    readValue: (prefs) =>
        prefs.getBool('linplayer_cross_server_writeback_progress'),
    writeValue: (prefs, value) async {
      await prefs.setBool('linplayer_cross_server_writeback_progress', value);
    },
  );
});

final watchHistoryRestoreQueueProvider = StateNotifierProvider<
    WatchHistoryRestoreQueueNotifier, WatchHistoryRestoreQueueState>((ref) {
  return WatchHistoryRestoreQueueNotifier(ref);
});

String? buildWatchHistoryScopeKey(ServerConfig? server) {
  final userId = server?.userId;
  if (server == null || userId == null || userId.isEmpty) {
    return null;
  }
  return '${server.id}:$userId';
}

class WatchHistoryRestoreQueueState {
  const WatchHistoryRestoreQueueState({
    this.scopeKey,
    this.isRefreshing = false,
    this.pending = const [],
    this.skippedRecordIds = const <String>{},
    this.errorMessage,
  });

  final String? scopeKey;
  final bool isRefreshing;
  final List<WatchHistoryRestoreCandidate> pending;
  final Set<String> skippedRecordIds;
  final String? errorMessage;

  WatchHistoryRestoreCandidate? get currentCandidate {
    if (pending.isEmpty) {
      return null;
    }
    return pending.first;
  }

  WatchHistoryRestoreQueueState copyWith({
    Object? scopeKey = _sentinel,
    bool? isRefreshing,
    List<WatchHistoryRestoreCandidate>? pending,
    Set<String>? skippedRecordIds,
    Object? errorMessage = _sentinel,
  }) {
    return WatchHistoryRestoreQueueState(
      scopeKey:
          identical(scopeKey, _sentinel) ? this.scopeKey : scopeKey as String?,
      isRefreshing: isRefreshing ?? this.isRefreshing,
      pending: pending ?? this.pending,
      skippedRecordIds: skippedRecordIds ?? this.skippedRecordIds,
      errorMessage: identical(errorMessage, _sentinel)
          ? this.errorMessage
          : errorMessage as String?,
    );
  }

  static const Object _sentinel = Object();
}

class WatchHistoryRestoreQueueNotifier
    extends StateNotifier<WatchHistoryRestoreQueueState> {
  WatchHistoryRestoreQueueNotifier(this._ref)
      : super(const WatchHistoryRestoreQueueState());

  final Ref _ref;
  bool _refreshing = false;

  Future<void> refresh() async {
    if (_refreshing) {
      return;
    }
    final server = _ref.read(currentServerProvider);
    final scopeKey = buildWatchHistoryScopeKey(server);
    if (scopeKey == null || !serverHasUsableAuth(server)) {
      state = const WatchHistoryRestoreQueueState();
      return;
    }

    _refreshing = true;
    final nextSkipped =
        state.scopeKey == scopeKey ? state.skippedRecordIds : <String>{};
    state = state.copyWith(
      scopeKey: scopeKey,
      isRefreshing: true,
      skippedRecordIds: nextSkipped,
      errorMessage: null,
    );

    try {
      final result =
          await _ref.read(watchHistoryRestoreServiceProvider).scanAndRestore(
                scopeKey: scopeKey,
                api: _ref.read(apiClientProvider),
              );
      final pending = result.promptCandidates
          .where(
            (candidate) => !nextSkipped.contains(candidate.record.recordId),
          )
          .toList(growable: false);
      state = state.copyWith(
        scopeKey: scopeKey,
        isRefreshing: false,
        pending: pending,
        skippedRecordIds: nextSkipped,
        errorMessage: null,
      );
      if (result.autoRestoredCount > 0) {
        _ref.invalidate(resumeItemsProvider);
      }
    } catch (_) {
      state = state.copyWith(
        isRefreshing: false,
        pending: const [],
        errorMessage: '恢复扫描失败',
      );
    } finally {
      _refreshing = false;
    }
  }

  Future<bool> restoreCurrent() async {
    final candidate = state.currentCandidate;
    if (candidate == null) {
      return false;
    }

    final restored =
        await _ref.read(watchHistoryRestoreServiceProvider).restoreCandidate(
              api: _ref.read(apiClientProvider),
              candidate: candidate,
            );
    if (!restored) {
      state = state.copyWith(errorMessage: '恢复失败，请稍后重试');
      return false;
    }

    state = state.copyWith(
      pending: state.pending.skip(1).toList(growable: false),
      errorMessage: null,
    );
    _ref.invalidate(resumeItemsProvider);
    return true;
  }

  void skipCurrent() {
    final candidate = state.currentCandidate;
    if (candidate == null) {
      return;
    }

    final skipped = {...state.skippedRecordIds, candidate.record.recordId};
    state = state.copyWith(
      pending: state.pending.skip(1).toList(growable: false),
      skippedRecordIds: skipped,
      errorMessage: null,
    );
  }

  Future<void> deleteCurrentRecord() async {
    final candidate = state.currentCandidate;
    if (candidate == null) {
      return;
    }
    await _ref
        .read(watchHistoryProvider)
        .deleteRecord(candidate.record.recordId);
    state = state.copyWith(
      pending: state.pending.skip(1).toList(growable: false),
      errorMessage: null,
    );
  }
}
