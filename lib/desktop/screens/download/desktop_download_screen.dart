import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../core/providers/download_providers.dart';
import '../../../core/services/download/download_grouping.dart';
import '../../../core/services/download/download_manager.dart';
import '../../../core/services/download/download_models.dart';
import '../../../ui/widgets/common/media_widgets.dart';
import '../../utils/desktop_smooth_scroll.dart';

/// 桌面端「下载」栏目。
class DesktopDownloadScreen extends ConsumerWidget {
  const DesktopDownloadScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final manager = ref.watch(downloadManagerProvider);
    final threads = ref.watch(downloadThreadsProvider);
    final theme = Theme.of(context);

    return Scaffold(
      body: ListenableBuilder(
        listenable: manager,
        builder: (context, _) {
          final groups = groupDownloads(manager.items);
          final hasCompleted =
              manager.items.any((d) => d.status == DownloadStatus.completed);
          return DesktopSmoothScrollBuilder(
            builder: (context, controller) => CustomScrollView(
              controller: controller,
              slivers: [
                SliverToBoxAdapter(
                  child: Padding(
                    padding: const EdgeInsets.fromLTRB(24, 18, 24, 10),
                    child: Row(
                      children: [
                        Text(
                          '本地下载',
                          style: theme.textTheme.headlineSmall
                              ?.copyWith(fontWeight: FontWeight.w700),
                        ),
                        const SizedBox(width: 12),
                        _ActiveBadge(manager: manager),
                        const Spacer(),
                        _ThreadDropdown(
                          threads: threads,
                          onChanged: (v) => ref
                              .read(downloadThreadsProvider.notifier)
                              .setThreads(v),
                        ),
                        if (hasCompleted) ...[
                          const SizedBox(width: 8),
                          TextButton.icon(
                            onPressed: () => _clearCompleted(context, manager),
                            icon: const Icon(Icons.cleaning_services_outlined,
                                size: 18),
                            label: const Text('清除已完成'),
                          ),
                        ],
                      ],
                    ),
                  ),
                ),
                if (groups.isEmpty)
                  const SliverFillRemaining(
                    hasScrollBody: false,
                    child: _EmptyState(),
                  )
                else
                  SliverPadding(
                    padding: const EdgeInsets.fromLTRB(24, 4, 24, 32),
                    sliver: SliverList.builder(
                      itemCount: groups.length,
                      itemBuilder: (context, index) => Padding(
                        padding: const EdgeInsets.only(bottom: 14),
                        child: _GroupCard(
                            group: groups[index], manager: manager),
                      ),
                    ),
                  ),
              ],
            ),
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

class _ActiveBadge extends StatelessWidget {
  final DownloadManager manager;
  const _ActiveBadge({required this.manager});

  @override
  Widget build(BuildContext context) {
    final active = manager.items
        .where((e) =>
            e.status == DownloadStatus.downloading ||
            e.status == DownloadStatus.queued)
        .length;
    if (active == 0) return const SizedBox.shrink();
    final theme = Theme.of(context);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
      decoration: BoxDecoration(
        color: theme.colorScheme.primary.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(999),
      ),
      child: Text(
        '进行中 $active',
        style: theme.textTheme.labelSmall?.copyWith(
          fontWeight: FontWeight.w700,
          color: theme.colorScheme.primary,
        ),
      ),
    );
  }
}

class _ThreadDropdown extends StatelessWidget {
  final int threads;
  final ValueChanged<int> onChanged;
  const _ThreadDropdown({required this.threads, required this.onChanged});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 2),
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainerHighest.withValues(alpha: 0.4),
        borderRadius: BorderRadius.circular(999),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Icon(Icons.bolt, size: 16),
          const SizedBox(width: 4),
          Text('下载线程', style: theme.textTheme.labelMedium),
          const SizedBox(width: 6),
          DropdownButton<int>(
            value: threads,
            isDense: true,
            underline: const SizedBox.shrink(),
            borderRadius: BorderRadius.circular(12),
            items: [
              for (var i = 1; i <= 4; i++)
                DropdownMenuItem(value: i, child: Text('$i')),
            ],
            onChanged: (v) {
              if (v != null) onChanged(v);
            },
          ),
        ],
      ),
    );
  }
}

class _GroupCard extends StatelessWidget {
  final DownloadGroup group;
  final DownloadManager manager;
  const _GroupCard({required this.group, required this.manager});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainerHighest.withValues(alpha: 0.3),
        borderRadius: BorderRadius.circular(14),
      ),
      clipBehavior: Clip.antiAlias,
      child: Column(
        children: [
          if (group.isSeries)
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 14, 16, 8),
              child: Row(
                children: [
                  _Thumb(url: group.posterUrl, width: 46, height: 64),
                  const SizedBox(width: 14),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(group.title,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(
                                fontWeight: FontWeight.w700, fontSize: 16)),
                        const SizedBox(height: 4),
                        Text('共 ${group.total} 集 · 已完成 ${group.completed}',
                            style: theme.textTheme.bodySmall),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          if (group.isSeries) const Divider(height: 1),
          for (var i = 0; i < group.items.length; i++) ...[
            if (i > 0) const Divider(height: 1, indent: 16, endIndent: 16),
            _Row(
                item: group.items[i],
                manager: manager,
                compact: group.isSeries),
          ],
        ],
      ),
    );
  }
}

class _Row extends StatelessWidget {
  final DownloadItem item;
  final DownloadManager manager;
  final bool compact;
  const _Row(
      {required this.item, required this.manager, this.compact = false});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isCompleted = item.status == DownloadStatus.completed;
    final isFailed = item.status == DownloadStatus.failed;
    final isPaused = item.status == DownloadStatus.paused;
    final isQueued = item.status == DownloadStatus.queued;
    final isDownloading = item.status == DownloadStatus.downloading;

    final title = compact
        ? (episodeLabel(item).isEmpty
            ? item.title
            : '${episodeLabel(item)}   ${item.title}')
        : item.title;

    return InkWell(
      onTap: isCompleted ? () => context.push('/player/${item.itemId}') : null,
      child: Padding(
        padding: EdgeInsets.fromLTRB(16, compact ? 10 : 14, 12, compact ? 10 : 14),
        child: Row(
          children: [
            if (!compact) ...[
              _Thumb(url: item.posterUrl, width: 48, height: 68),
              const SizedBox(width: 14),
            ],
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                          fontWeight:
                              compact ? FontWeight.w500 : FontWeight.w600,
                          fontSize: compact ? 14 : 15)),
                  const SizedBox(height: 6),
                  if (isDownloading || isPaused || isQueued) ...[
                    Row(
                      children: [
                        Expanded(
                          child: ClipRRect(
                            borderRadius: BorderRadius.circular(3),
                            child: LinearProgressIndicator(
                              value: item.totalBytes > 0 ? item.progress : null,
                              minHeight: 5,
                              backgroundColor:
                                  theme.colorScheme.surfaceContainerHighest,
                            ),
                          ),
                        ),
                        const SizedBox(width: 12),
                        Text(_progressText(item),
                            style: theme.textTheme.labelSmall),
                      ],
                    ),
                    const SizedBox(height: 3),
                    Text(downloadStatusText(item),
                        style: theme.textTheme.labelSmall
                            ?.copyWith(color: theme.colorScheme.primary)),
                  ] else
                    Row(
                      children: [
                        Icon(
                            isCompleted
                                ? Icons.check_circle
                                : Icons.error_outline,
                            size: 15,
                            color: isCompleted
                                ? theme.colorScheme.primary
                                : theme.colorScheme.error),
                        const SizedBox(width: 5),
                        Text(
                            isCompleted
                                ? '已完成 · ${formatBytes(item.totalBytes)}'
                                : downloadStatusText(item),
                            style: theme.textTheme.labelSmall?.copyWith(
                                color: isCompleted
                                    ? theme.colorScheme.primary
                                    : theme.colorScheme.error)),
                      ],
                    ),
                ],
              ),
            ),
            const SizedBox(width: 8),
            if (isCompleted)
              IconButton(
                  tooltip: '播放',
                  icon: const Icon(Icons.play_circle_outline),
                  onPressed: () => context.push('/player/${item.itemId}'))
            else if (isFailed)
              IconButton(
                  tooltip: '重试',
                  icon: const Icon(Icons.refresh),
                  onPressed: () => manager.retry(item.id))
            else if (isPaused)
              IconButton(
                  tooltip: '继续',
                  icon: const Icon(Icons.play_arrow),
                  onPressed: () => manager.resume(item.id))
            else if (isDownloading || isQueued)
              IconButton(
                  tooltip: '暂停',
                  icon: const Icon(Icons.pause),
                  onPressed: () => manager.pause(item.id)),
            IconButton(
              tooltip: '删除',
              icon: const Icon(Icons.delete_outline),
              onPressed: () => _confirmDelete(context),
            ),
          ],
        ),
      ),
    );
  }

  String _progressText(DownloadItem item) {
    if (item.totalBytes <= 0) return formatBytes(item.receivedBytes);
    final pct = (item.progress * 100).toStringAsFixed(0);
    return '$pct%  ${formatBytes(item.receivedBytes)} / ${formatBytes(item.totalBytes)}';
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
                backgroundColor: Theme.of(context).colorScheme.error),
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
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.download_done, size: 72, color: theme.colorScheme.outline),
          const SizedBox(height: 16),
          Text('暂无下载内容',
              style: TextStyle(color: theme.colorScheme.outline, fontSize: 16)),
          const SizedBox(height: 8),
          Text('在媒体详情页点击「下载」即可离线保存',
              style: TextStyle(
                  fontSize: 13, color: theme.textTheme.bodySmall?.color)),
        ],
      ),
    );
  }
}
