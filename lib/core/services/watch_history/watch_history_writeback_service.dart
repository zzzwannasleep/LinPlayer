import '../../api/api_interfaces.dart';
import '../../api/emby_api.dart';
import '../../providers/server_providers.dart';
import 'watch_history_matcher.dart';
import 'watch_history_models.dart';
import 'watch_history_service.dart';
import 'watch_history_store.dart';

/// 看完 / 进度回传到「其它服务器」的目标范围。
enum CrossServerWritebackRange {
  /// 所有有本地记录的其它服务器。
  all,

  /// 仅最早看过该内容的那台服务器（通常是主库）。
  first,

  /// 仅除当前服外、最近看过该内容的那台服务器。
  latest,
}

CrossServerWritebackRange crossServerWritebackRangeFromWire(String? value) {
  switch (value) {
    case 'first':
      return CrossServerWritebackRange.first;
    case 'latest':
      return CrossServerWritebackRange.latest;
    case 'all':
    default:
      return CrossServerWritebackRange.all;
  }
}

String crossServerWritebackRangeToWire(CrossServerWritebackRange range) {
  switch (range) {
    case CrossServerWritebackRange.all:
      return 'all';
    case CrossServerWritebackRange.first:
      return 'first';
    case CrossServerWritebackRange.latest:
      return 'latest';
  }
}

String crossServerWritebackRangeLabel(CrossServerWritebackRange range) {
  switch (range) {
    case CrossServerWritebackRange.all:
      return '所有看过的服务器';
    case CrossServerWritebackRange.first:
      return '仅初次看过的服务器';
    case CrossServerWritebackRange.latest:
      return '仅最近看过的服务器';
  }
}

/// 把当前服务器上的「已看完 / 播放进度」回传到其它服务器上的同一内容。
///
/// 依据：每条观看记录都带 `scopeKey`（serverId:userId）与 `lastEmbyItemId`
/// （该服务器上的条目 id）。匹配复用 [matchWatchHistoryRecordToCandidate]，
/// 因此不同服务器上的同一影片 / 同一集也能对应上。仅写入其它服务器，不动当前服。
class WatchHistoryWritebackService {
  WatchHistoryWritebackService({
    required WatchHistoryStore store,
    required WatchHistoryService historyService,
  })  : _store = store,
        _history = historyService;

  final WatchHistoryStore _store;
  final WatchHistoryService _history;

  /// 会话内去重：避免对同一目标条目反复写入（按分钟粒度 + 是否已看完）。
  final Set<String> _done = <String>{};

  Future<void> propagate({
    required String currentScopeKey,
    required ApiClientFactory currentApi,
    required MediaItem item,
    required int positionTicks,
    required bool played,
    required List<ServerConfig> servers,
    required CrossServerWritebackRange range,
    required bool includeProgress,
  }) async {
    if (!played && (!includeProgress || positionTicks <= 0)) {
      return;
    }

    final all = await _store.loadAll();
    if (all.isEmpty) {
      return;
    }
    final seriesTmdbId = await _history.resolveSeriesTmdbId(currentApi, item);

    // 找出其它 scope 中与当前条目匹配、且带有效条目 id 的记录，按 scope 去重保留最近一条。
    final byScope = <String, WatchHistoryRecord>{};
    for (final record in all) {
      if (record.scopeKey == currentScopeKey) {
        continue;
      }
      final itemId = record.lastEmbyItemId;
      if (itemId == null || itemId.isEmpty) {
        continue;
      }
      final match = matchWatchHistoryRecordToCandidate(
        record: record,
        candidate: item,
        candidateSeriesTmdbId: seriesTmdbId,
        uniqueCandidate: true,
      );
      if (match.confidence != WatchHistoryMatchConfidence.strong &&
          match.confidence != WatchHistoryMatchConfidence.possible) {
        continue;
      }
      final existing = byScope[record.scopeKey];
      if (existing == null ||
          record.lastPlayedAt.isAfter(existing.lastPlayedAt)) {
        byScope[record.scopeKey] = record;
      }
    }
    if (byScope.isEmpty) {
      return;
    }

    var targets = byScope.values.toList();
    switch (range) {
      case CrossServerWritebackRange.all:
        break;
      case CrossServerWritebackRange.first:
        targets.sort((a, b) =>
            a.effectiveFirstPlayedAt.compareTo(b.effectiveFirstPlayedAt));
        targets = targets.take(1).toList();
      case CrossServerWritebackRange.latest:
        targets.sort((a, b) => b.lastPlayedAt.compareTo(a.lastPlayedAt));
        targets = targets.take(1).toList();
    }

    final positionBucket = positionTicks ~/ (60 * 10000000); // 1 分钟粒度
    for (final target in targets) {
      final serverId = _serverIdFromScope(target.scopeKey);
      final server =
          servers.where((entry) => entry.id == serverId).firstOrNull;
      if (server == null) {
        continue;
      }
      final token = server.authToken;
      if (token == null || token.isEmpty) {
        continue;
      }
      final itemId = target.lastEmbyItemId!;
      final dedupKey = '$serverId|$itemId|$played|$positionBucket';
      if (_done.contains(dedupKey)) {
        continue;
      }

      final api = EmbyApiClient(
        baseUrl: server.activeLineUrl,
        authToken: token,
        userId: server.userId,
      );
      try {
        if (played) {
          await api.user.markAsPlayed(itemId);
        } else if (includeProgress && positionTicks > 0) {
          await api.playback.reportPlaybackStart(
            PlaybackStartInfo(itemId: itemId, mediaSourceId: itemId),
          );
          await api.playback.reportPlaybackProgress(
            PlaybackProgressInfo(
              itemId: itemId,
              mediaSourceId: itemId,
              positionTicks: positionTicks,
              isPaused: true,
            ),
          );
          await api.playback.reportPlaybackStopped(
            PlaybackStopInfo(
              itemId: itemId,
              mediaSourceId: itemId,
              positionTicks: positionTicks,
            ),
          );
        } else {
          continue;
        }
        _done.add(dedupKey);
        // 同步更新本地的目标记录，保持本地状态一致。
        await _store.saveRecord(
          target.copyWith(
            played: played || target.played,
            lastPositionTicks:
                positionTicks > target.lastPositionTicks && !target.played
                    ? positionTicks
                    : target.lastPositionTicks,
          ),
        );
      } catch (_) {
        // 回传失败忽略，不影响当前播放与本地记录。
      }
    }
  }

  /// scopeKey 形如 `serverId:userId`，serverId 与 userId 均不含冒号，取最后一个冒号前为 serverId。
  String _serverIdFromScope(String scopeKey) {
    final idx = scopeKey.lastIndexOf(':');
    return idx <= 0 ? scopeKey : scopeKey.substring(0, idx);
  }
}
