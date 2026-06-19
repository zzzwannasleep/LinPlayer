import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../core/providers/download_providers.dart';
import '../../../core/services/download/download_grouping.dart';
import '../../../core/services/download/download_manager.dart';
import '../../../core/services/download/download_models.dart';
import '../../../core/theme/app_motion.dart';
import '../../widgets/common/media_widgets.dart';

/// 本地下载页（移动端）。
///
/// 按「电影」与「剧集（按剧名聚合）」分组展示用户下载的内容，
/// 支持暂停/恢复/重试/删除，并实时显示分段多线程下载进度。
class DownloadScreen extends ConsumerWidget {
  const DownloadScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final manager = ref.watch(downloadManagerProvider);
    final threads = ref.watch(downloadThreadsProvider);

    return Scaffold(
      appBar: AppBar(
        title: const Text('本地下载'),
        actions: [
          _ThreadSelector(
            threads: threads,
            onChanged: (v) =>
                ref.read(downloadThreadsProvider.notifier).setThreads(v),
          ),
          ListenableBuilder(
            listenable: manager,
            builder: (context, _) {
              final hasCompleted = manager.items
                  .any((d) => d.status == DownloadStatus.completed);
              if (!hasCompleted) return const SizedBox.shrink();
              return TextButton(
                onPressed: () => _clearCompleted(context, manager),
                child: const Text('清除已完成'),
              );
            },
          ),
        ],
      ),
      body: ListenableBuilder(
        listenable: manager,
        builder: (context, _) {
          final groups = groupDownloads(manager.items);
          if (groups.isEmpty) return const _EmptyState();
          return ListView.builder(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 24),
            itemCount: groups.length,
            itemBuilder: (context, index) {
              return _DownloadGroupCard(group: groups[index], manager: manager)
                  .appEntrance(index: index);
            },
          );
        },
      ),
    );
  }

  void _clearCompleted(BuildContext context, DownloadManager manager) {
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('清除已完成'),
        content: const Text('确定要清除所有已完成的下载记录吗？本地文件也会被删除。'),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('取消')),
          FilledButton(
            onPressed: () {
              for (final t in manager.items
                  .where((t) => t.status == DownloadStatus.completed)
                  .toList()) {
                manager.remove(t.id);
              }
              Navigator.pop(context);
            },
            child: const Text('清除'),
          ),
        ],
      ),
    );
  }
}

class _ThreadSelector extends StatelessWidget {
  final int threads;
  final ValueChanged<int> onChanged;
  const _ThreadSelector({required this.threads, required this.onChanged});

  @override
  Widget build(BuildContext context) {
    return PopupMenuButton<int>(
      tooltip: '下载线程数',
      onSelected: onChanged,
      itemBuilder: (context) => [
        for (var i = 1; i <= 4; i++)
          PopupMenuItem(
            value: i,
            child: Row(
              children: [
                Icon(
                  threads == i ? Icons.check : Icons.bolt_outlined,
                  size: 18,
                  color: threads == i
                      ? Theme.of(context).colorScheme.primary
                      : null,
                ),
                const SizedBox(width: 8),
                Text('$i 线程'),
              ],
            ),
          ),
      ],
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 8),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.bolt, size: 18),
            const SizedBox(width: 2),
            Text('$threads'),
          ],
        ),
      ),
    );
  }
}

class _DownloadGroupCard extends StatelessWidget {
  final DownloadGroup group;
  final DownloadManager manager;
  const _DownloadGroupCard({required this.group, required this.manager});

  @override
  Widget build(BuildContext context) {
    if (!group.isSeries) {
      // 电影：单条记录卡片。
      return Card(
        margin: const EdgeInsets.only(bottom: 12),
        clipBehavior: Clip.antiAlias,
        child: _DownloadRow(item: group.items.first, manager: manager),
      );
    }

    // 剧集：剧名头部 + 分集列表。
    final theme = Theme.of(context);
    return Card(
      margin: const EdgeInsets.only(bottom: 12),
      clipBehavior: Clip.antiAlias,
      child: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 12, 12, 4),
            child: Row(
              children: [
                _Thumb(url: group.posterUrl, width: 44, height: 60),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        group.title,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                            fontWeight: FontWeight.w700, fontSize: 15),
                      ),
                      const SizedBox(height: 4),
                      Text(
                        '共 ${group.total} 集 · 已完成 ${group.completed}',
                        style: theme.textTheme.bodySmall,
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
          const Divider(height: 1),
          for (final ep in group.items)
            _DownloadRow(item: ep, manager: manager, compact: true),
        ],
      ),
    );
  }
}

class _DownloadRow extends StatelessWidget {
  final DownloadItem item;
  final DownloadManager manager;
  final bool compact;
  const _DownloadRow({
    required this.item,
    required this.manager,
    this.compact = false,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isCompleted = item.status == DownloadStatus.completed;
    final isFailed = item.status == DownloadStatus.failed;
    final isPaused = item.status == DownloadStatus.paused;
    final isQueued = item.status == DownloadStatus.queued;
    final isDownloading = item.status == DownloadStatus.downloading;

    final title = compact
        ? (episodeLabel(item).isEmpty ? item.title : '${episodeLabel(item)}  ${item.title}')
        : item.title;

    return InkWell(
      onTap: isCompleted ? () => _play(context) : null,
      child: Padding(
        padding: EdgeInsets.fromLTRB(12, compact ? 8 : 12, 8, compact ? 8 : 12),
        child: Row(
          children: [
            if (!compact) ...[
              _Thumb(url: item.posterUrl, width: 52, height: 72),
              const SizedBox(width: 12),
            ],
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontWeight: compact ? FontWeight.w500 : FontWeight.w600,
                      fontSize: compact ? 13 : 15,
                    ),
                  ),
                  const SizedBox(height: 6),
                  if (isDownloading || isPaused || isQueued) ...[
                    ClipRRect(
                      borderRadius: BorderRadius.circular(3),
                      child: LinearProgressIndicator(
                        value: item.totalBytes > 0 ? item.progress : null,
                        minHeight: 4,
                        backgroundColor:
                            theme.colorScheme.surfaceContainerHighest,
                      ),
                    ),
                    const SizedBox(height: 4),
                    Row(
                      children: [
                        Text(
                          _progressText(item),
                          style: theme.textTheme.labelSmall,
                        ),
                        const Spacer(),
                        Text(
                          downloadStatusText(item),
                          style: theme.textTheme.labelSmall?.copyWith(
                            color: theme.colorScheme.primary,
                          ),
                        ),
                      ],
                    ),
                  ] else
                    Row(
                      children: [
                        Icon(
                          isCompleted
                              ? Icons.check_circle
                              : Icons.error_outline,
                          size: 14,
                          color: isCompleted
                              ? theme.colorScheme.primary
                              : theme.colorScheme.error,
                        ),
                        const SizedBox(width: 4),
                        Expanded(
                          child: Text(
                            isCompleted
                                ? '已完成 · ${formatBytes(item.totalBytes)}'
                                : downloadStatusText(item),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: theme.textTheme.labelSmall?.copyWith(
                              color: isCompleted
                                  ? theme.colorScheme.primary
                                  : theme.colorScheme.error,
                            ),
                          ),
                        ),
                      ],
                    ),
                ],
              ),
            ),
            const SizedBox(width: 4),
            _buildActions(context, isCompleted, isFailed, isPaused, isQueued,
                isDownloading),
          ],
        ),
      ),
    );
  }

  Widget _buildActions(BuildContext context, bool isCompleted, bool isFailed,
      bool isPaused, bool isQueued, bool isDownloading) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        if (isCompleted)
          IconButton(
            icon: const Icon(Icons.play_circle_outline),
            onPressed: () => _play(context),
          )
        else if (isFailed)
          IconButton(
            icon: const Icon(Icons.refresh),
            onPressed: () => manager.retry(item.id),
          )
        else if (isPaused)
          IconButton(
            icon: const Icon(Icons.play_arrow),
            onPressed: () => manager.resume(item.id),
          )
        else if (isDownloading || isQueued)
          IconButton(
            icon: const Icon(Icons.pause),
            onPressed: () => manager.pause(item.id),
          ),
        IconButton(
          icon: const Icon(Icons.delete_outline),
          onPressed: () => _confirmDelete(context),
        ),
      ],
    );
  }

  String _progressText(DownloadItem item) {
    if (item.totalBytes <= 0) {
      return formatBytes(item.receivedBytes);
    }
    final pct = (item.progress * 100).toStringAsFixed(0);
    return '$pct%  ·  ${formatBytes(item.receivedBytes)} / ${formatBytes(item.totalBytes)}';
  }

  void _play(BuildContext context) {
    context.push('/player/${item.itemId}');
  }

  void _confirmDelete(BuildContext context) {
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('确认删除'),
        content: Text('确定要删除「${item.title}」吗？本地文件也会被删除。'),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('取消')),
          FilledButton(
            style: FilledButton.styleFrom(
              backgroundColor: Theme.of(context).colorScheme.error,
            ),
            onPressed: () {
              manager.remove(item.id);
              Navigator.pop(context);
            },
            child: const Text('删除'),
          ),
        ],
      ),
    );
  }
}

class _Thumb extends StatelessWidget {
  final String? url;
  final double width;
  final double height;
  const _Thumb({required this.url, required this.width, required this.height});

  @override
  Widget build(BuildContext context) {
    return MediaImage(
      imageUrl: url,
      width: width,
      height: height,
      borderRadius: BorderRadius.circular(6),
      placeholder: Container(
        width: width,
        height: height,
        color: Theme.of(context).colorScheme.surfaceContainerHighest,
        child: const Icon(Icons.movie_outlined, size: 20),
      ),
    );
  }
}

class _EmptyState extends StatelessWidget {
  const _EmptyState();

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(Icons.download_done, size: 64, color: theme.colorScheme.outline),
          const SizedBox(height: 16),
          Text('暂无下载内容',
              style: TextStyle(color: theme.colorScheme.outline)),
          const SizedBox(height: 8),
          Text(
            '在媒体详情页点击「下载」开始',
            style: TextStyle(
                fontSize: 12, color: theme.textTheme.bodySmall?.color),
          ),
        ],
      ),
    );
  }
}
