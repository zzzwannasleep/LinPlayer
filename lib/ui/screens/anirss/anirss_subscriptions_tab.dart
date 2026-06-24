import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/sources/anirss/anirss_match.dart';
import '../../../core/sources/anirss/anirss_providers.dart';
import '../../../core/sources/anirss/models/ani.dart';
import '../../../core/widgets/app_shimmer.dart';
import 'anirss_add_subscription_sheet.dart';
import 'anirss_download_widgets.dart';

/// 订阅页：添加订阅入口 + 下载进度监控（按订阅聚合，精确到每集）。
class AniRssSubscriptionsTab extends ConsumerWidget {
  const AniRssSubscriptionsTab({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final asyncList = ref.watch(aniListProvider);
    final asyncTorrents = ref.watch(torrentsProvider);

    return Column(
      children: [
        _Toolbar(
          onAdd: () => showAniRssAddSubscriptionSheet(context, ref),
          onRefreshAll: () async {
            final api = ref.read(aniRssApiProvider);
            if (api == null) return;
            await api.refreshAll();
            if (context.mounted) {
              ScaffoldMessenger.of(context).showSnackBar(
                const SnackBar(content: Text('已触发全部订阅刷新')),
              );
            }
          },
        ),
        Expanded(
          child: asyncList.when(
            loading: () => const Center(child: AppLoadingIndicator()),
            error: (e, _) => Center(child: Text('$e')),
            data: (anis) {
              final torrents = asyncTorrents.valueOrNull ?? const [];
              final match = matchTorrents(anis, torrents);
              return _SubscriptionList(
                anis: anis,
                match: match,
              );
            },
          ),
        ),
      ],
    );
  }
}

class _Toolbar extends StatelessWidget {
  final VoidCallback onAdd;
  final Future<void> Function() onRefreshAll;
  const _Toolbar({required this.onAdd, required this.onRefreshAll});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
      child: Row(
        children: [
          Expanded(
            child: FilledButton.icon(
              onPressed: onAdd,
              icon: const Icon(Icons.add),
              label: const Text('搜索并添加订阅'),
            ),
          ),
          const SizedBox(width: 8),
          IconButton(
            tooltip: '刷新全部订阅',
            onPressed: onRefreshAll,
            icon: const Icon(Icons.refresh_rounded),
          ),
        ],
      ),
    );
  }
}

class _SubscriptionList extends ConsumerWidget {
  final List<AniModel> anis;
  final TorrentMatchResult match;
  const _SubscriptionList({required this.anis, required this.match});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    // 有活动下载的订阅排前面。
    final sorted = [...anis]..sort((a, b) {
        final ai = (match.byAni[a.id]?.isNotEmpty ?? false) ? 0 : 1;
        final bi = (match.byAni[b.id]?.isNotEmpty ?? false) ? 0 : 1;
        return ai.compareTo(bi);
      });
    final unmatched = match.unmatched;

    return ListView(
      padding: const EdgeInsets.fromLTRB(12, 8, 12, 24),
      children: [
        for (final ani in sorted)
          SubscriptionTile(
            ani: ani,
            episodes: match.byAni[ani.id] ?? const [],
            onRefresh: () => _refresh(context, ref, ani),
            onDelete: (deleteFiles) => _delete(context, ref, ani, deleteFiles),
            onToggleEnable: () => _toggle(context, ref, ani),
          ),
        if (unmatched.isNotEmpty) ...[
          const Padding(
            padding: EdgeInsets.fromLTRB(8, 16, 8, 8),
            child: Text('未匹配下载',
                style: TextStyle(fontWeight: FontWeight.w600)),
          ),
          for (final t in unmatched) UnmatchedTorrentTile(torrent: t),
        ],
      ],
    );
  }

  Future<void> _refresh(
      BuildContext context, WidgetRef ref, AniModel ani) async {
    final api = ref.read(aniRssApiProvider);
    if (api == null) return;
    await api.refreshAni(ani.id);
    if (context.mounted) {
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text('已刷新「${ani.title}」')));
    }
  }

  Future<void> _delete(BuildContext context, WidgetRef ref, AniModel ani,
      bool deleteFiles) async {
    final api = ref.read(aniRssApiProvider);
    if (api == null) return;
    await api.deleteAni([ani.id], deleteFiles: deleteFiles);
    ref.invalidate(aniListProvider);
    if (context.mounted) {
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text('已删除「${ani.title}」')));
    }
  }

  Future<void> _toggle(
      BuildContext context, WidgetRef ref, AniModel ani) async {
    final api = ref.read(aniRssApiProvider);
    if (api == null) return;
    await api.batchEnable([ani.id], !ani.enable);
    ref.invalidate(aniListProvider);
  }
}
