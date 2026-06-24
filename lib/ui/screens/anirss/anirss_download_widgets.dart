import 'package:flutter/material.dart';

import '../../../core/sources/anirss/anirss_match.dart';
import '../../../core/sources/anirss/models/ani.dart';
import '../../../core/sources/anirss/models/torrent_info.dart';

/// 状态 → 中文标签 + 颜色。
({String label, Color color}) torrentStateStyle(TorrentState s) {
  switch (s) {
    case TorrentState.downloading:
    case TorrentState.forcedDL:
      return (label: '下载中', color: const Color(0xFF2F6FED));
    case TorrentState.stalledDL:
    case TorrentState.queuedDL:
      return (label: '等待中', color: Colors.orange);
    case TorrentState.pausedDL:
    case TorrentState.pausedUP:
      return (label: '已暂停', color: Colors.grey);
    case TorrentState.checking:
      return (label: '校验中', color: Colors.teal);
    case TorrentState.uploading:
    case TorrentState.stalledUP:
    case TorrentState.queuedUP:
    case TorrentState.forcedUP:
      return (label: '做种中', color: const Color(0xFF52B54B));
    case TorrentState.error:
    case TorrentState.missingFiles:
      return (label: '错误', color: Colors.red);
    case TorrentState.unknown:
      return (label: '未知', color: Colors.grey);
  }
}

/// 一个订阅的下载进度卡（可展开看每集）。
class SubscriptionTile extends StatelessWidget {
  final AniModel ani;
  final List<EpisodeProgress> episodes;
  final VoidCallback onRefresh;
  final void Function(bool deleteFiles) onDelete;
  final VoidCallback onToggleEnable;

  const SubscriptionTile({
    super.key,
    required this.ani,
    required this.episodes,
    required this.onRefresh,
    required this.onDelete,
    required this.onToggleEnable,
  });

  @override
  Widget build(BuildContext context) {
    final active = episodes.where((e) => e.progress < 1.0).length;
    final summary = episodes.isEmpty
        ? (ani.enable ? '无下载任务' : '已停用')
        : (active > 0 ? '$active 个下载中 · 共 ${episodes.length}' : '${episodes.length} 个任务');

    return Card(
      margin: const EdgeInsets.symmetric(vertical: 4),
      child: ExpansionTile(
        leading: const Icon(Icons.tv_rounded),
        title: Text(ani.title, maxLines: 1, overflow: TextOverflow.ellipsis),
        subtitle: Text(summary, style: const TextStyle(fontSize: 12)),
        childrenPadding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
        children: [
          if (episodes.isEmpty)
            const Padding(
              padding: EdgeInsets.symmetric(vertical: 8),
              child: Text('当前没有进行中的下载', style: TextStyle(color: Colors.grey)),
            )
          else
            ...episodes.map((e) => _EpisodeProgressRow(e)),
          const Divider(height: 16),
          Row(
            children: [
              TextButton.icon(
                onPressed: onRefresh,
                icon: const Icon(Icons.refresh, size: 18),
                label: const Text('刷新'),
              ),
              TextButton.icon(
                onPressed: onToggleEnable,
                icon: Icon(ani.enable ? Icons.pause : Icons.play_arrow, size: 18),
                label: Text(ani.enable ? '停用' : '启用'),
              ),
              const Spacer(),
              TextButton.icon(
                onPressed: () => _confirmDelete(context),
                icon: const Icon(Icons.delete_outline, size: 18, color: Colors.red),
                label: const Text('删除', style: TextStyle(color: Colors.red)),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Future<void> _confirmDelete(BuildContext context) async {
    var deleteFiles = false;
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setState) => AlertDialog(
          title: Text('删除「${ani.title}」？'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Text('将从 Ani-rss 移除该订阅。'),
              CheckboxListTile(
                contentPadding: EdgeInsets.zero,
                value: deleteFiles,
                onChanged: (v) => setState(() => deleteFiles = v ?? false),
                title: const Text('同时删除已下载文件'),
              ),
            ],
          ),
          actions: [
            TextButton(
                onPressed: () => Navigator.pop(ctx, false), child: const Text('取消')),
            FilledButton(
                onPressed: () => Navigator.pop(ctx, true), child: const Text('删除')),
          ],
        ),
      ),
    );
    if (ok == true) onDelete(deleteFiles);
  }
}

class _EpisodeProgressRow extends StatelessWidget {
  final EpisodeProgress ep;
  const _EpisodeProgressRow(this.ep);

  @override
  Widget build(BuildContext context) {
    final style = torrentStateStyle(ep.state);
    final epLabel = ep.episodeNumber != null
        ? '第 ${_fmtEp(ep.episodeNumber!)} 集'
        : ep.torrentName;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(epLabel,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(fontSize: 13)),
              ),
              const SizedBox(width: 8),
              Text('${(ep.progress * 100).toStringAsFixed(0)}%',
                  style: TextStyle(
                      fontSize: 12, color: style.color, fontWeight: FontWeight.w600)),
              const SizedBox(width: 8),
              Text(style.label, style: TextStyle(fontSize: 11, color: style.color)),
            ],
          ),
          const SizedBox(height: 4),
          ClipRRect(
            borderRadius: BorderRadius.circular(3),
            child: LinearProgressIndicator(
              value: ep.progress,
              minHeight: 5,
              backgroundColor: style.color.withValues(alpha: 0.15),
              valueColor: AlwaysStoppedAnimation(style.color),
            ),
          ),
        ],
      ),
    );
  }

  static String _fmtEp(double e) =>
      e == e.roundToDouble() ? e.toInt().toString() : e.toString();
}

/// 未匹配到订阅的下载任务。
class UnmatchedTorrentTile extends StatelessWidget {
  final TorrentInfoModel torrent;
  const UnmatchedTorrentTile({super.key, required this.torrent});

  @override
  Widget build(BuildContext context) {
    final style = torrentStateStyle(torrent.state);
    return Card(
      margin: const EdgeInsets.symmetric(vertical: 3),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(torrent.name,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(fontSize: 13)),
            const SizedBox(height: 6),
            Row(
              children: [
                Text('${(torrent.progress * 100).toStringAsFixed(0)}%',
                    style: TextStyle(fontSize: 12, color: style.color)),
                const SizedBox(width: 8),
                Text(style.label, style: TextStyle(fontSize: 11, color: style.color)),
                if (torrent.formatSize != null) ...[
                  const Spacer(),
                  Text(torrent.formatSize!,
                      style: const TextStyle(fontSize: 11, color: Colors.grey)),
                ],
              ],
            ),
            const SizedBox(height: 4),
            ClipRRect(
              borderRadius: BorderRadius.circular(3),
              child: LinearProgressIndicator(
                value: torrent.progress,
                minHeight: 5,
                backgroundColor: style.color.withValues(alpha: 0.15),
                valueColor: AlwaysStoppedAnimation(style.color),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
