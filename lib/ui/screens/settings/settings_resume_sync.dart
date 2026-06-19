part of 'settings_screen.dart';

/// 同步记录 / 跨服务器续播设置页（移动端 + 桌面端共用）。
///
/// 与本地观看记录联动：在一个服务器看过的进度，换到另一个服务器打开同一部影片
/// 或同一集时，自动续播到所有服务器中记录的最新进度，无需重新拖拉。
class ResumeSyncScreen extends ConsumerStatefulWidget {
  const ResumeSyncScreen({super.key});

  @override
  ConsumerState<ResumeSyncScreen> createState() => _ResumeSyncScreenState();
}

class _ResumeSyncScreenState extends ConsumerState<ResumeSyncScreen> {
  int? _recordCount;

  @override
  void initState() {
    super.initState();
    _loadCount();
  }

  Future<void> _loadCount() async {
    final records = await ref.read(watchHistoryProvider).loadAll();
    if (mounted) {
      setState(() => _recordCount = records.length);
    }
  }

  Future<void> _clearRecords() async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('清除本地观看记录'),
        content: const Text(
          '将删除本机保存的全部观看记录（含各服务器的续播进度）。'
          '此操作不会影响服务器自身的播放进度，但清除后将无法跨服务器续播历史内容。确定继续？',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('清除'),
          ),
        ],
      ),
    );
    if (ok != true) return;
    await ref.read(watchHistoryProvider).clearAll();
    if (!mounted) return;
    setState(() => _recordCount = 0);
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('已清除本地观看记录')),
    );
  }

  Future<void> _pickWritebackRange() async {
    final current = ref.read(crossServerWritebackRangeProvider);
    await showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('回传目标'),
        content: RadioGroup<CrossServerWritebackRange>(
          groupValue: current,
          onChanged: (value) {
            if (value != null) {
              ref.read(crossServerWritebackRangeProvider.notifier).state = value;
            }
            Navigator.pop(ctx);
          },
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              RadioListTile<CrossServerWritebackRange>(
                title: Text(crossServerWritebackRangeLabel(
                    CrossServerWritebackRange.all)),
                subtitle: const Text('每台有本地记录的服务器都同步'),
                value: CrossServerWritebackRange.all,
              ),
              RadioListTile<CrossServerWritebackRange>(
                title: Text(crossServerWritebackRangeLabel(
                    CrossServerWritebackRange.first)),
                subtitle: const Text('只更新你最早看的那台（通常是主库）'),
                value: CrossServerWritebackRange.first,
              ),
              RadioListTile<CrossServerWritebackRange>(
                title: Text(crossServerWritebackRangeLabel(
                    CrossServerWritebackRange.latest)),
                subtitle: const Text('只更新除当前服外最近看过的那台'),
                value: CrossServerWritebackRange.latest,
              ),
            ],
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final enabled = ref.watch(crossServerResumeProvider);
    final writebackEnabled = ref.watch(crossServerWritebackEnabledProvider);
    final writebackRange = ref.watch(crossServerWritebackRangeProvider);
    final writebackProgress = ref.watch(crossServerWritebackProgressProvider);
    return Scaffold(
      appBar: AppBar(title: const Text('同步记录')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          const Padding(
            padding: EdgeInsets.symmetric(horizontal: 4, vertical: 8),
            child: Text(
              '基于本机的观看记录，在不同服务器之间同步续播进度。'
              '在一个服务器看了一集，换到另一个服务器打开同一部影片或同一集时，'
              '会自动续播到最新进度，无需重新拖拉。',
              style: TextStyle(fontSize: 13, color: Colors.grey),
            ),
          ),
          Card(
            child: SwitchListTile(
              secondary: const Icon(Icons.sync_alt),
              title: const Text('跨服务器续播'),
              subtitle: const Text('换服务器观看同一内容时自动续播到最新进度'),
              value: enabled,
              onChanged: (value) => ref
                  .read(crossServerResumeProvider.notifier)
                  .state = value,
            ),
          ),
          const Padding(
            padding: EdgeInsets.fromLTRB(4, 16, 4, 8),
            child: Text(
              '记录回传',
              style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600),
            ),
          ),
          const Padding(
            padding: EdgeInsets.symmetric(horizontal: 4),
            child: Text(
              '看完或停止时，把「已看完 / 播放进度」写回其它服务器上的同一内容，'
              '让各服务器的观看状态保持一致。该功能会写入其它服务器，请按需开启。',
              style: TextStyle(fontSize: 13, color: Colors.grey),
            ),
          ),
          const SizedBox(height: 8),
          Card(
            child: SwitchListTile(
              secondary: const Icon(Icons.cloud_upload_outlined),
              title: const Text('看完后回传到其它服务器'),
              subtitle: const Text('把已看完 / 进度同步到其它服务器'),
              value: writebackEnabled,
              onChanged: (value) => ref
                  .read(crossServerWritebackEnabledProvider.notifier)
                  .state = value,
            ),
          ),
          if (writebackEnabled) ...[
            Card(
              child: ListTile(
                leading: const Icon(Icons.dns_outlined),
                title: const Text('回传目标'),
                subtitle: Text(crossServerWritebackRangeLabel(writebackRange)),
                trailing: const Icon(Icons.chevron_right),
                onTap: _pickWritebackRange,
              ),
            ),
            Card(
              child: SwitchListTile(
                secondary: const Icon(Icons.timelapse),
                title: const Text('同步播放进度'),
                subtitle: const Text('不仅回传「已看完」，也回传当前播放进度'),
                value: writebackProgress,
                onChanged: (value) => ref
                    .read(crossServerWritebackProgressProvider.notifier)
                    .state = value,
              ),
            ),
          ],
          const Padding(
            padding: EdgeInsets.fromLTRB(4, 16, 4, 8),
            child: Text(
              '本地记录',
              style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600),
            ),
          ),
          Card(
            child: ListTile(
              leading: const Icon(Icons.history),
              title: const Text('本地观看记录'),
              subtitle: Text(
                _recordCount == null ? '统计中…' : '共 $_recordCount 条',
              ),
            ),
          ),
          Card(
            child: ListTile(
              leading: const Icon(Icons.delete_outline, color: Colors.redAccent),
              title: const Text('清除本地观看记录'),
              subtitle: const Text('删除本机保存的全部续播记录'),
              onTap: (_recordCount ?? 0) == 0 ? null : _clearRecords,
            ),
          ),
          const Padding(
            padding: EdgeInsets.all(12),
            child: Text(
              '说明：续播匹配优先使用 TMDB / 唯一标识，其次使用片名与季集号，'
              '因此不同服务器上的同一内容也能匹配。该功能只读取本机记录，不会上传任何数据。',
              style: TextStyle(fontSize: 12, color: Colors.grey),
            ),
          ),
        ],
      ),
    );
  }
}
