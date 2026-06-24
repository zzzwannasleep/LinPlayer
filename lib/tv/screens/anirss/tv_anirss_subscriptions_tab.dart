import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/sources/anirss/anirss_api.dart';
import '../../../core/sources/anirss/anirss_match.dart';
import '../../../core/sources/anirss/anirss_providers.dart';
import '../../../core/sources/anirss/models/ani.dart';
import '../../../core/sources/anirss/models/bgm_info.dart';
import '../../../core/sources/anirss/models/torrent_info.dart';
import '../../../ui/screens/anirss/anirss_download_widgets.dart'
    show torrentStateStyle;
import '../../../ui/widgets/common/media_widgets.dart';
import '../../theme/tv_design_tokens.dart';
import '../../theme/tv_metrics.dart';
import '../../widgets/tv_focusable.dart';
import '../../widgets/tv_toast.dart';

/// Ani-rss 订阅 Tab（TV）：添加订阅 / 刷新全部 + 按订阅聚合的下载进度监控。
/// 全部 D-pad 可导航。
class TvAniRssSubscriptionsTab extends ConsumerWidget {
  const TvAniRssSubscriptionsTab({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final m = context.tv;
    final asyncList = ref.watch(aniListProvider);
    final asyncTorrents = ref.watch(torrentsProvider);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _buildToolbar(context, ref, m),
        SizedBox(height: m.spacingMd),
        Expanded(
          child: asyncList.when(
            loading: () => const Center(
                child: CircularProgressIndicator(color: TvDesignTokens.brand)),
            error: (e, _) => _centerHint(m, '加载失败：$e'),
            data: (anis) {
              final torrents = asyncTorrents.valueOrNull ?? const [];
              final match = matchTorrents(anis, torrents);
              return _buildList(context, ref, m, anis, match);
            },
          ),
        ),
      ],
    );
  }

  Widget _buildToolbar(BuildContext context, WidgetRef ref, TvMetrics m) {
    return Row(
      children: [
        TvFocusable(
          autofocus: true,
          padding: EdgeInsets.all(m.s(4)),
          onSelect: () => _openAddPanel(context, ref),
          child: _pillButton(m,
              icon: Icons.add, label: '添加订阅', filled: true),
        ),
        SizedBox(width: m.spacingMd),
        TvFocusable(
          padding: EdgeInsets.all(m.s(4)),
          onSelect: () => _refreshAll(context, ref),
          child: _pillButton(m,
              icon: Icons.refresh_rounded, label: '刷新全部', filled: false),
        ),
      ],
    );
  }

  Widget _pillButton(TvMetrics m,
      {required IconData icon, required String label, required bool filled}) {
    final fg = filled ? Colors.white : TvDesignTokens.textPrimary;
    return Container(
      padding:
          EdgeInsets.symmetric(horizontal: m.spacingLg, vertical: m.spacingSm),
      decoration: BoxDecoration(
        color: filled ? TvDesignTokens.brand : Colors.transparent,
        borderRadius: BorderRadius.circular(999),
        border: filled
            ? null
            : Border.all(color: TvDesignTokens.textSecondary, width: 2),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, color: fg, size: m.s(26)),
          SizedBox(width: m.spacingXs),
          Text(label,
              style: TextStyle(
                  fontSize: m.fontSizeMd,
                  color: fg,
                  fontWeight: FontWeight.bold)),
        ],
      ),
    );
  }

  Widget _buildList(BuildContext context, WidgetRef ref, TvMetrics m,
      List<AniModel> anis, TorrentMatchResult match) {
    final sorted = [...anis]..sort((a, b) {
        final ai = (match.byAni[a.id]?.isNotEmpty ?? false) ? 0 : 1;
        final bi = (match.byAni[b.id]?.isNotEmpty ?? false) ? 0 : 1;
        return ai.compareTo(bi);
      });
    final unmatched = match.unmatched;
    if (sorted.isEmpty && unmatched.isEmpty) {
      return _centerHint(m, '暂无订阅，点「添加订阅」开始');
    }
    return ListView(
      children: [
        for (final ani in sorted)
          _SubscriptionRow(
            ani: ani,
            episodes: match.byAni[ani.id] ?? const [],
          ),
        if (unmatched.isNotEmpty) ...[
          Padding(
            padding: EdgeInsets.fromLTRB(
                m.spacingXs, m.spacingLg, m.spacingXs, m.spacingSm),
            child: Text('未匹配下载',
                style: TextStyle(
                    fontSize: m.fontSizeMd,
                    color: TvDesignTokens.textPrimary,
                    fontWeight: FontWeight.w600)),
          ),
          for (final t in unmatched) _UnmatchedRow(torrent: t),
        ],
      ],
    );
  }

  void _openAddPanel(BuildContext context, WidgetRef ref) {
    final api = ref.read(aniRssApiProvider);
    if (api == null) return;
    showGeneralDialog<void>(
      context: context,
      barrierDismissible: true,
      barrierLabel: '添加订阅',
      barrierColor: Colors.black.withValues(alpha: 0.7),
      pageBuilder: (ctx, _, __) =>
          _AddSubscriptionPanel(api: api, parentRef: ref),
    );
  }

  Future<void> _refreshAll(BuildContext context, WidgetRef ref) async {
    final api = ref.read(aniRssApiProvider);
    if (api == null) return;
    try {
      await api.refreshAll();
      if (context.mounted) TvToast.show(context, '已触发全部订阅刷新');
    } catch (e) {
      if (context.mounted) TvToast.show(context, '刷新失败：$e');
    }
  }

  Widget _centerHint(TvMetrics m, String text) => Center(
        child: Text(text,
            style: TextStyle(
                color: TvDesignTokens.textSecondary,
                fontSize: m.fontSizeMd)),
      );
}

/// 一个订阅行：可聚焦，确认键展开/折叠每集进度；菜单键打开操作菜单。
class _SubscriptionRow extends ConsumerStatefulWidget {
  final AniModel ani;
  final List<EpisodeProgress> episodes;
  const _SubscriptionRow({required this.ani, required this.episodes});

  @override
  ConsumerState<_SubscriptionRow> createState() => _SubscriptionRowState();
}

class _SubscriptionRowState extends ConsumerState<_SubscriptionRow> {
  bool _expanded = false;

  AniModel get ani => widget.ani;
  List<EpisodeProgress> get episodes => widget.episodes;

  @override
  Widget build(BuildContext context) {
    final m = context.tv;
    final active = episodes.where((e) => e.progress < 1.0).length;
    final summary = episodes.isEmpty
        ? (ani.enable ? '无下载任务' : '已停用')
        : (active > 0
            ? '$active 个下载中 · 共 ${episodes.length}'
            : '${episodes.length} 个任务');
    return Padding(
      padding: EdgeInsets.only(bottom: m.spacingSm),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          TvFocusable(
            padding: EdgeInsets.all(m.s(4)),
            onSelect: () => setState(() => _expanded = !_expanded),
            onLongPress: () => _openActions(context),
            child: Container(
              padding: EdgeInsets.symmetric(
                  horizontal: m.spacingLg, vertical: m.spacingMd),
              decoration: BoxDecoration(
                color: TvDesignTokens.surface,
                borderRadius: BorderRadius.circular(m.posterRadius),
              ),
              child: Row(
                children: [
                  Icon(Icons.tv_rounded,
                      color: TvDesignTokens.brand, size: m.s(28)),
                  SizedBox(width: m.spacingMd),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text(ani.title,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                                fontSize: m.fontSizeMd,
                                color: TvDesignTokens.textPrimary)),
                        Text(summary,
                            style: TextStyle(
                                fontSize: m.fontSizeXs,
                                color: TvDesignTokens.textSecondary)),
                      ],
                    ),
                  ),
                  SizedBox(width: m.spacingMd),
                  Icon(Icons.more_horiz,
                      color: TvDesignTokens.textSecondary, size: m.s(24)),
                  SizedBox(width: m.spacingSm),
                  Icon(_expanded ? Icons.expand_less : Icons.expand_more,
                      color: TvDesignTokens.textSecondary, size: m.s(26)),
                ],
              ),
            ),
          ),
          if (_expanded)
            Padding(
              padding: EdgeInsets.fromLTRB(
                  m.spacingLg, m.spacingSm, m.spacingLg, m.spacingSm),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  if (episodes.isEmpty)
                    Text('当前没有进行中的下载',
                        style: TextStyle(
                            fontSize: m.fontSizeSm,
                            color: TvDesignTokens.textSecondary))
                  else
                    for (final e in episodes) _EpisodeProgressRow(ep: e),
                  SizedBox(height: m.spacingSm),
                  Row(
                    children: [
                      TvFocusable(
                        padding: EdgeInsets.all(m.s(4)),
                        onSelect: () => _refresh(context),
                        child: _action(m, Icons.refresh, '刷新'),
                      ),
                      SizedBox(width: m.spacingSm),
                      TvFocusable(
                        padding: EdgeInsets.all(m.s(4)),
                        onSelect: () => _toggle(context),
                        child: _action(
                            m,
                            ani.enable ? Icons.pause : Icons.play_arrow,
                            ani.enable ? '停用' : '启用'),
                      ),
                      SizedBox(width: m.spacingSm),
                      TvFocusable(
                        padding: EdgeInsets.all(m.s(4)),
                        onSelect: () => _confirmDelete(context),
                        child: _action(m, Icons.delete_outline, '删除',
                            danger: true),
                      ),
                    ],
                  ),
                ],
              ),
            ),
        ],
      ),
    );
  }

  Widget _action(TvMetrics m, IconData icon, String label,
      {bool danger = false}) {
    final c = danger ? TvDesignTokens.error : TvDesignTokens.textPrimary;
    return Container(
      padding:
          EdgeInsets.symmetric(horizontal: m.spacingMd, vertical: m.spacingSm),
      decoration: BoxDecoration(
        color: TvDesignTokens.surfaceElevated,
        borderRadius: BorderRadius.circular(m.posterRadius),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: m.s(22), color: c),
          SizedBox(width: m.spacingXs),
          Text(label, style: TextStyle(fontSize: m.fontSizeSm, color: c)),
        ],
      ),
    );
  }

  void _openActions(BuildContext context) {
    setState(() => _expanded = true);
  }

  Future<void> _refresh(BuildContext context) async {
    final api = ref.read(aniRssApiProvider);
    if (api == null) return;
    try {
      await api.refreshAni(ani.id);
      if (context.mounted) TvToast.show(context, '已刷新「${ani.title}」');
    } catch (e) {
      if (context.mounted) TvToast.show(context, '刷新失败：$e');
    }
  }

  Future<void> _toggle(BuildContext context) async {
    final api = ref.read(aniRssApiProvider);
    if (api == null) return;
    try {
      await api.batchEnable([ani.id], !ani.enable);
      ref.invalidate(aniListProvider);
    } catch (e) {
      if (context.mounted) TvToast.show(context, '操作失败：$e');
    }
  }

  Future<void> _confirmDelete(BuildContext context) async {
    final m = context.tv;
    final deleteFiles = await showGeneralDialog<bool>(
      context: context,
      barrierDismissible: true,
      barrierLabel: '删除订阅',
      barrierColor: Colors.black.withValues(alpha: 0.7),
      pageBuilder: (ctx, _, __) => Center(
        child: Material(
          color: Colors.transparent,
          child: Container(
            width: m.s(560),
            padding: EdgeInsets.all(m.spacingXl),
            decoration: BoxDecoration(
              color: TvDesignTokens.surface,
              borderRadius: BorderRadius.circular(m.posterRadius),
            ),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('删除「${ani.title}」？',
                    style: TextStyle(
                        fontSize: m.fontSizeLg,
                        color: TvDesignTokens.textPrimary,
                        fontWeight: FontWeight.bold)),
                SizedBox(height: m.spacingSm),
                Text('将从 Ani-rss 移除该订阅。',
                    style: TextStyle(
                        fontSize: m.fontSizeSm,
                        color: TvDesignTokens.textSecondary)),
                SizedBox(height: m.spacingLg),
                TvFocusable(
                  autofocus: true,
                  padding: EdgeInsets.all(m.s(4)),
                  onSelect: () => Navigator.of(ctx).pop(false),
                  child: _dialogBtn(m, '仅移除订阅', filled: true),
                ),
                SizedBox(height: m.spacingSm),
                TvFocusable(
                  padding: EdgeInsets.all(m.s(4)),
                  onSelect: () => Navigator.of(ctx).pop(true),
                  child: _dialogBtn(m, '移除并删除已下载文件', danger: true),
                ),
              ],
            ),
          ),
        ),
      ),
    );
    if (deleteFiles == null) return;
    final api = ref.read(aniRssApiProvider);
    if (api == null) return;
    try {
      await api.deleteAni([ani.id], deleteFiles: deleteFiles);
      ref.invalidate(aniListProvider);
      if (context.mounted) TvToast.show(context, '已删除「${ani.title}」');
    } catch (e) {
      if (context.mounted) TvToast.show(context, '删除失败：$e');
    }
  }

  Widget _dialogBtn(TvMetrics m, String label,
      {bool filled = false, bool danger = false}) {
    final Color bg = danger
        ? TvDesignTokens.error
        : (filled ? TvDesignTokens.brand : TvDesignTokens.surfaceElevated);
    return Container(
      width: double.infinity,
      padding:
          EdgeInsets.symmetric(horizontal: m.spacingLg, vertical: m.spacingMd),
      decoration: BoxDecoration(
        color: bg,
        borderRadius: BorderRadius.circular(m.posterRadius),
      ),
      child: Text(label,
          textAlign: TextAlign.center,
          style: TextStyle(
              fontSize: m.fontSizeMd,
              color: Colors.white,
              fontWeight: FontWeight.w600)),
    );
  }
}

class _EpisodeProgressRow extends StatelessWidget {
  final EpisodeProgress ep;
  const _EpisodeProgressRow({required this.ep});

  @override
  Widget build(BuildContext context) {
    final m = context.tv;
    final style = torrentStateStyle(ep.state);
    final epLabel = ep.episodeNumber != null
        ? '第 ${_fmtEp(ep.episodeNumber!)} 集'
        : ep.torrentName;
    return Padding(
      padding: EdgeInsets.symmetric(vertical: m.spacingXs),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(epLabel,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                        fontSize: m.fontSizeSm,
                        color: TvDesignTokens.textPrimary)),
              ),
              SizedBox(width: m.spacingSm),
              Text('${(ep.progress * 100).toStringAsFixed(0)}%',
                  style: TextStyle(
                      fontSize: m.fontSizeXs,
                      color: style.color,
                      fontWeight: FontWeight.w600)),
              SizedBox(width: m.spacingSm),
              Text(style.label,
                  style: TextStyle(fontSize: m.fs(12), color: style.color)),
            ],
          ),
          SizedBox(height: m.s(4)),
          ClipRRect(
            borderRadius: BorderRadius.circular(m.s(3)),
            child: LinearProgressIndicator(
              value: ep.progress,
              minHeight: m.s(5),
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

class _UnmatchedRow extends StatelessWidget {
  final TorrentInfoModel torrent;
  const _UnmatchedRow({required this.torrent});

  @override
  Widget build(BuildContext context) {
    final m = context.tv;
    final style = torrentStateStyle(torrent.state);
    return Padding(
      padding: EdgeInsets.only(bottom: m.spacingSm),
      child: Container(
        padding: EdgeInsets.all(m.spacingMd),
        decoration: BoxDecoration(
          color: TvDesignTokens.surface,
          borderRadius: BorderRadius.circular(m.posterRadius),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(torrent.name,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                    fontSize: m.fontSizeSm,
                    color: TvDesignTokens.textPrimary)),
            SizedBox(height: m.spacingXs),
            Row(
              children: [
                Text('${(torrent.progress * 100).toStringAsFixed(0)}%',
                    style:
                        TextStyle(fontSize: m.fontSizeXs, color: style.color)),
                SizedBox(width: m.spacingSm),
                Text(style.label,
                    style: TextStyle(fontSize: m.fs(12), color: style.color)),
                if (torrent.formatSize != null) ...[
                  const Spacer(),
                  Text(torrent.formatSize!,
                      style: TextStyle(
                          fontSize: m.fs(12),
                          color: TvDesignTokens.textSecondary)),
                ],
              ],
            ),
            SizedBox(height: m.s(4)),
            ClipRRect(
              borderRadius: BorderRadius.circular(m.s(3)),
              child: LinearProgressIndicator(
                value: torrent.progress,
                minHeight: m.s(5),
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

/// 添加订阅 overlay：文本框 → searchBgm → 结果列表（焦点行）→ getAniBySubjectId+addAni。
class _AddSubscriptionPanel extends StatefulWidget {
  final AniRssApi api;
  final WidgetRef parentRef;
  const _AddSubscriptionPanel({required this.api, required this.parentRef});

  @override
  State<_AddSubscriptionPanel> createState() => _AddSubscriptionPanelState();
}

class _AddSubscriptionPanelState extends State<_AddSubscriptionPanel> {
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
        TvToast.show(context, '已添加订阅「${bgm.displayName}」');
      }
    } catch (e) {
      if (mounted) {
        setState(() => _addingId = null);
        TvToast.show(context, '添加失败：$e');
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final m = context.tv;
    return Center(
      child: Material(
        color: Colors.transparent,
        child: Container(
          width: m.s(820),
          constraints: BoxConstraints(maxHeight: m.s(760)),
          padding: EdgeInsets.all(m.spacingXl),
          decoration: BoxDecoration(
            color: TvDesignTokens.surface,
            borderRadius: BorderRadius.circular(m.posterRadius),
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('搜索并添加订阅',
                  style: TextStyle(
                      fontSize: m.fontSizeLg,
                      color: TvDesignTokens.textPrimary,
                      fontWeight: FontWeight.bold)),
              SizedBox(height: m.spacingMd),
              Row(
                children: [
                  Expanded(
                    child: Container(
                      padding: EdgeInsets.symmetric(horizontal: m.spacingMd),
                      decoration: BoxDecoration(
                        color: TvDesignTokens.surfaceElevated,
                        borderRadius: BorderRadius.circular(m.posterRadius),
                      ),
                      child: TextField(
                        controller: _ctrl,
                        autofocus: true,
                        style: TextStyle(
                            fontSize: m.fontSizeMd,
                            color: TvDesignTokens.textPrimary),
                        textInputAction: TextInputAction.search,
                        onSubmitted: (_) => _search(),
                        decoration: const InputDecoration(
                          hintText: '输入番剧名（BGM 搜索）',
                          hintStyle:
                              TextStyle(color: TvDesignTokens.textDisabled),
                          border: InputBorder.none,
                          icon: Icon(Icons.search,
                              color: TvDesignTokens.textSecondary),
                        ),
                      ),
                    ),
                  ),
                  SizedBox(width: m.spacingMd),
                  TvFocusable(
                    padding: EdgeInsets.all(m.s(4)),
                    onSelect: _loading ? null : _search,
                    child: Container(
                      padding: EdgeInsets.symmetric(
                          horizontal: m.spacingLg, vertical: m.spacingMd),
                      decoration: BoxDecoration(
                        color: TvDesignTokens.brand,
                        borderRadius: BorderRadius.circular(m.posterRadius),
                      ),
                      child: Text('搜索',
                          style: TextStyle(
                              fontSize: m.fontSizeMd,
                              color: Colors.white,
                              fontWeight: FontWeight.bold)),
                    ),
                  ),
                ],
              ),
              SizedBox(height: m.spacingMd),
              Flexible(child: _buildResults(m)),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildResults(TvMetrics m) {
    if (_loading) {
      return const Center(
          child: CircularProgressIndicator(color: TvDesignTokens.brand));
    }
    if (_error != null) {
      return Center(
          child: Text(_error!,
              style: TextStyle(
                  fontSize: m.fontSizeSm, color: TvDesignTokens.error)));
    }
    if (_results.isEmpty) {
      return Center(
          child: Text('输入关键词后点搜索',
              style: TextStyle(
                  fontSize: m.fontSizeSm,
                  color: TvDesignTokens.textSecondary)));
    }
    return ListView.builder(
      shrinkWrap: true,
      itemCount: _results.length,
      itemBuilder: (context, i) {
        final bgm = _results[i];
        final meta = [
          if (bgm.date != null) bgm.date!.split('T').first,
          if (bgm.eps != null) '${bgm.eps} 集',
          if (bgm.score != null && bgm.score! > 0)
            '★ ${bgm.score!.toStringAsFixed(1)}',
        ].join(' · ');
        return Padding(
          padding: EdgeInsets.only(bottom: m.spacingSm),
          child: TvFocusable(
            padding: EdgeInsets.all(m.s(4)),
            onSelect: _addingId != null ? null : () => _add(bgm),
            child: Container(
              padding: EdgeInsets.all(m.spacingMd),
              decoration: BoxDecoration(
                color: TvDesignTokens.surfaceElevated,
                borderRadius: BorderRadius.circular(m.posterRadius),
              ),
              child: Row(
                children: [
                  SizedBox(
                    width: m.s(48),
                    height: m.s(66),
                    child: MediaImage(
                      imageUrl: bgm.image,
                      fit: BoxFit.cover,
                      borderRadius: BorderRadius.circular(m.s(6)),
                    ),
                  ),
                  SizedBox(width: m.spacingMd),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text(bgm.displayName,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                                fontSize: m.fontSizeMd,
                                color: TvDesignTokens.textPrimary)),
                        if (meta.isNotEmpty)
                          Text(meta,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(
                                  fontSize: m.fontSizeXs,
                                  color: TvDesignTokens.textSecondary)),
                      ],
                    ),
                  ),
                  SizedBox(width: m.spacingMd),
                  _addingId == bgm.id
                      ? SizedBox(
                          width: m.s(24),
                          height: m.s(24),
                          child: const CircularProgressIndicator(
                              strokeWidth: 2,
                              color: TvDesignTokens.brand))
                      : Icon(Icons.add_circle_outline,
                          color: TvDesignTokens.brand, size: m.s(28)),
                ],
              ),
            ),
          ),
        );
      },
    );
  }
}
