import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../services/download/download_manager.dart';
import 'app_preferences.dart';
import 'server_providers.dart';

const _kDownloadThreadsKey = 'linplayer_download_threads';

/// 下载线程（分段）数，范围 1–4。控制单文件并发连接数以约束服务器压力。
class DownloadThreadsNotifier extends PreferenceNotifier<int> {
  DownloadThreadsNotifier()
      : super(
          defaultValue: 2,
          readValue: (prefs) {
            final v = prefs.getInt(_kDownloadThreadsKey);
            if (v == null) return null;
            return v.clamp(1, 4).toInt();
          },
          writeValue: (prefs, value) =>
              prefs.setInt(_kDownloadThreadsKey, value.clamp(1, 4).toInt()),
        );

  void setThreads(int v) => state = v.clamp(1, 4).toInt();
}

final downloadThreadsProvider =
    StateNotifierProvider<DownloadThreadsNotifier, int>(
        (ref) => DownloadThreadsNotifier());

/// 全局下载管理器（单例）。
final downloadManagerProvider = Provider<DownloadManager>((ref) {
  final manager = DownloadManager();
  manager.threads = ref.read(downloadThreadsProvider);
  manager.initialize();
  // 线程数变更时同步给管理器（对下一个/重建分段的任务生效）。
  ref.listen<int>(downloadThreadsProvider, (_, next) {
    manager.threads = next;
  });
  ref.onDispose(manager.dispose);
  return manager;
});

/// 当前服务端是否许可该用户下载。
///
/// 优先读用户 `Policy.EnableContentDownloading`；老服务端无 Policy 时退回 true，
/// 实际仍由下载接口 `/Items/{id}/Download` 服务端二次把关。
final downloadPermissionProvider = FutureProvider<bool>((ref) async {
  final server = ref.watch(currentServerProvider);
  if (!serverHasUsableAuth(server)) return false;
  try {
    final api = ref.watch(apiClientProvider);
    final user = await api.auth.getCurrentUser();
    final policy = user.policy;
    if (policy == null) return true; // 无策略信息：不阻断，交由服务端把关
    return policy.canDownload;
  } catch (_) {
    return true; // 拉取失败不阻断，交由下载接口把关
  }
});
