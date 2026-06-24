import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/sources/anirss/anirss_api.dart';
import '../../../core/sources/anirss/anirss_match.dart';
import '../../../core/sources/anirss/anirss_providers.dart';
import '../../../core/sources/anirss/models/ani.dart';
import '../../../core/sources/anirss/models/bgm_info.dart';
import '../../../core/widgets/app_shimmer.dart';
import '../../../ui/screens/anirss/anirss_download_widgets.dart';
import '../../../ui/widgets/common/media_widgets.dart';
import '../../utils/desktop_smooth_scroll.dart';
import '../../widgets/native_feedback.dart';

/// 桌面端 Ani-rss 订阅页：添加订阅入口 + 下载进度监控（按订阅聚合，精确到每集）。
class DesktopAniRssSubscriptionsTab extends ConsumerWidget {
  const DesktopAniRssSubscriptionsTab({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final asyncList = ref.watch(aniListProvider);
    final asyncTorrents = ref.watch(torrentsProvider);

    return Column(
      children: [
        _Toolbar(
          onAdd: () => _showAddDialog(context, ref),
          onRefreshAll: () async {
            final api = ref.read(aniRssApiProvider);
            if (api == null) return;
            await api.refreshAll();
            if (context.mounted) {
              showDesktopMessage(context, '已触发全部订阅刷新');
            }
          },
        ),
        const Divider(height: 1),
        Expanded(
          child: asyncList.when(
            loading: () => const Center(child: AppLoadingIndicator()),
            error: (e, _) => Center(child: Text('$e')),
            data: (anis) {
              final torrents = asyncTorrents.valueOrNull ?? const [];
              final match = matchTorrents(anis, torrents);
              return _SubscriptionList(anis: anis, match: match);
            },
          ),
        ),
      ],
    );
  }

  Future<void> _showAddDialog(BuildContext context, WidgetRef ref) {
    final api = ref.read(aniRssApiProvider);
    if (api == null) return Future.value();
    return showDialog<void>(
      context: context,
      builder: (_) => _AddSubscriptionDialog(api: api, parentRef: ref),
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
      padding: const EdgeInsets.fromLTRB(24, 16, 24, 12),
      child: Row(
        children: [
          FilledButton.icon(
            onPressed: onAdd,
            icon: const Icon(Icons.add),
            label: const Text('搜索并添加订阅'),
          ),
          const SizedBox(width: 12),
          OutlinedButton.icon(
            onPressed: onRefreshAll,
            icon: const Icon(Icons.refresh_rounded),
            label: const Text('刷新全部'),
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

    return DesktopSmoothScrollBuilder(
      builder: (context, controller) => ListView(
        controller: controller,
        padding: const EdgeInsets.fromLTRB(24, 12, 24, 28),
        children: [
          for (final ani in sorted)
            SubscriptionTile(
              ani: ani,
              episodes: match.byAni[ani.id] ?? const [],
              onRefresh: () => _refresh(context, ref, ani),
              onDelete: (deleteFiles) =>
                  _delete(context, ref, ani, deleteFiles),
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
      ),
    );
  }

  Future<void> _refresh(
      BuildContext context, WidgetRef ref, AniModel ani) async {
    final api = ref.read(aniRssApiProvider);
    if (api == null) return;
    await api.refreshAni(ani.id);
    if (context.mounted) {
      showDesktopMessage(context, '已刷新「${ani.title}」');
    }
  }

  Future<void> _delete(BuildContext context, WidgetRef ref, AniModel ani,
      bool deleteFiles) async {
    final api = ref.read(aniRssApiProvider);
    if (api == null) return;
    await api.deleteAni([ani.id], deleteFiles: deleteFiles);
    ref.invalidate(aniListProvider);
    if (context.mounted) {
      showDesktopMessage(context, '已删除「${ani.title}」');
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

/// 桌面端「搜索并添加订阅」对话框（BGM 搜索 → 生成订阅 → addAni）。
class _AddSubscriptionDialog extends StatefulWidget {
  final AniRssApi api;
  final WidgetRef parentRef;
  const _AddSubscriptionDialog({required this.api, required this.parentRef});

  @override
  State<_AddSubscriptionDialog> createState() => _AddSubscriptionDialogState();
}

class _AddSubscriptionDialogState extends State<_AddSubscriptionDialog> {
  final _ctrl = TextEditingController();
  bool _loading = false;
  String? _error;
  String? _addingId;
  List<BgmInfoModel> _results = const [];

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  Future<void> _search() async {
    final q = _ctrl.text.trim();
    if (q.isEmpty) return;
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final r = await widget.api.searchBgm(q);
      if (mounted) setState(() => _results = r);
    } catch (e) {
      if (mounted) setState(() => _error = '$e');
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _add(BgmInfoModel bgm) async {
    setState(() => _addingId = bgm.id);
    try {
      final ani = await widget.api.getAniBySubjectId(bgm.id);
      await widget.api.addAni(ani);
      widget.parentRef.invalidate(aniListProvider);
      if (mounted) {
        Navigator.of(context).pop();
        showDesktopMessage(context, '已添加订阅「${bgm.displayName}」');
      }
    } catch (e) {
      if (mounted) {
        setState(() => _addingId = null);
        showDesktopMessage(context, '添加失败：$e', isError: true);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Dialog(
      clipBehavior: Clip.antiAlias,
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 560, maxHeight: 640),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(24, 20, 24, 20),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Text('搜索并添加订阅',
                      style: Theme.of(context)
                          .textTheme
                          .titleLarge
                          ?.copyWith(fontWeight: FontWeight.w700)),
                  const Spacer(),
                  IconButton(
                    onPressed: () => Navigator.of(context).pop(),
                    icon: const Icon(Icons.close),
                  ),
                ],
              ),
              const SizedBox(height: 12),
              Row(
                children: [
                  Expanded(
                    child: TextField(
                      controller: _ctrl,
                      autofocus: true,
                      textInputAction: TextInputAction.search,
                      onSubmitted: (_) => _search(),
                      decoration: const InputDecoration(
                        hintText: '输入番剧名（BGM 搜索）',
                        border: OutlineInputBorder(),
                        prefixIcon: Icon(Icons.search),
                        isDense: true,
                      ),
                    ),
                  ),
                  const SizedBox(width: 12),
                  FilledButton(
                    onPressed: _loading ? null : _search,
                    child: const Text('搜索'),
                  ),
                ],
              ),
              const SizedBox(height: 16),
              Expanded(child: _buildResults()),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildResults() {
    if (_loading) return const Center(child: AppLoadingIndicator());
    if (_error != null) return Center(child: Text(_error!));
    if (_results.isEmpty) {
      return const Center(
          child: Text('输入关键词后点搜索', style: TextStyle(color: Colors.grey)));
    }
    return DesktopSmoothScrollBuilder(
      builder: (context, controller) => ListView.separated(
        controller: controller,
        itemCount: _results.length,
        separatorBuilder: (_, __) => const Divider(height: 1),
        itemBuilder: (context, i) {
          final bgm = _results[i];
          return ListTile(
            contentPadding: EdgeInsets.zero,
            leading: SizedBox(
              width: 44,
              height: 60,
              child: MediaImage(
                imageUrl: bgm.image,
                fit: BoxFit.cover,
                borderRadius: BorderRadius.circular(6),
              ),
            ),
            title: Text(bgm.displayName,
                maxLines: 1, overflow: TextOverflow.ellipsis),
            subtitle: Text(
              [
                if (bgm.date != null) bgm.date!.split('T').first,
                if (bgm.eps != null) '${bgm.eps} 集',
                if (bgm.score != null && bgm.score! > 0)
                  '★ ${bgm.score!.toStringAsFixed(1)}',
              ].join(' · '),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
            trailing: _addingId == bgm.id
                ? const SizedBox(
                    width: 20,
                    height: 20,
                    child: CircularProgressIndicator(strokeWidth: 2))
                : FilledButton.tonal(
                    onPressed: _addingId != null ? null : () => _add(bgm),
                    child: const Text('添加'),
                  ),
          );
        },
      ),
    );
  }
}
