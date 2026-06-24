import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../core/providers/server_providers.dart';
import '../../../core/sources/anirss/anirss_api.dart';
import '../../../core/sources/anirss/anirss_nav_args.dart';
import '../../../core/sources/anirss/anirss_providers.dart';
import '../../../core/sources/anirss/models/ani.dart';
import '../../../core/sources/anirss/models/tmdb.dart';
import '../../../core/widgets/app_shimmer.dart';
import '../../../ui/widgets/anirss/anirss_version_picker.dart';
import '../../../ui/widgets/common/media_widgets.dart';
import '../../utils/desktop_smooth_scroll.dart';

/// Ani-rss 详情页（桌面端）。剧/影自适应，版块对齐 Emby 桌面详情布局。
class DesktopAniRssDetailScreen extends ConsumerWidget {
  final AniRssDetailArgs args;
  const DesktopAniRssDetailScreen({super.key, required this.args});

  AniModel get ani => args.ani;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final asyncDetail = ref.watch(aniDetailProvider(ani));
    return Scaffold(
      body: asyncDetail.when(
        loading: () => _scaffoldLoading(context),
        error: (e, _) => _scaffoldError(context, '$e'),
        data: (detail) => _DetailBody(
          server: args.server,
          ani: ani,
          detail: detail,
        ),
      ),
    );
  }

  Widget _scaffoldLoading(BuildContext context) => Stack(
        children: [
          const Center(child: AppLoadingIndicator()),
          SafeArea(child: BackButton(onPressed: () => context.pop())),
        ],
      );

  Widget _scaffoldError(BuildContext context, String msg) => Stack(
        children: [
          Center(
            child: Padding(
              padding: const EdgeInsets.all(32),
              child: Text(msg, textAlign: TextAlign.center),
            ),
          ),
          SafeArea(child: BackButton(onPressed: () => context.pop())),
        ],
      );
}

/// TMDB 相对路径 → [代理URL, 直链] 候选（代理优先，直链兜底）。
List<String> _tmdbImageCandidates(
    ServerConfig server, String token, String? path, String size) {
  if (path == null || path.isEmpty) return const [];
  final full =
      path.startsWith('http') ? path : 'https://image.tmdb.org/t/p/$size$path';
  return [
    AniRssApi.buildProxyImageUrl(server, full, token),
    full,
  ];
}

class _DetailBody extends StatelessWidget {
  final ServerConfig server;
  final AniModel ani;
  final AniDetail detail;
  const _DetailBody(
      {required this.server, required this.ani, required this.detail});

  @override
  Widget build(BuildContext context) {
    final tmdb = ani.tmdb;
    return DesktopSmoothScrollBuilder(
      builder: (context, controller) => CustomScrollView(
        controller: controller,
        slivers: [
          SliverToBoxAdapter(
            child: _Header(server: server, ani: ani, detail: detail),
          ),
          SliverPadding(
            padding: const EdgeInsets.fromLTRB(48, 8, 48, 8),
            sliver: SliverToBoxAdapter(
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 1180),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    if (tmdb?.overview != null && tmdb!.overview!.isNotEmpty)
                      _Overview(text: tmdb.overview!),
                    if (detail.isMovie)
                      _MoviePlay(server: server, detail: detail)
                    else
                      _Episodes(server: server, detail: detail),
                    if (tmdb != null && tmdb.cast.isNotEmpty)
                      _CastRow(server: server, detail: detail),
                    const SizedBox(height: 40),
                  ],
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _Header extends StatelessWidget {
  final ServerConfig server;
  final AniModel ani;
  final AniDetail detail;
  const _Header({required this.server, required this.ani, required this.detail});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final tmdb = ani.tmdb;
    final backdrop = [
      ..._tmdbImageCandidates(server, detail.token, tmdb?.backdropPath, 'w1280'),
      if (ani.image != null) ani.image!,
    ];
    final poster = [
      if (ani.image != null) ani.image!,
      ..._tmdbImageCandidates(server, detail.token, tmdb?.posterPath, 'w500'),
    ];
    const heroHeight = 420.0;
    const posterWidth = 200.0;
    const posterHeight = 300.0;

    return SizedBox(
      height: heroHeight,
      child: Stack(
        children: [
          Positioned.fill(
            child: MediaImage(
              imageUrl: backdrop.isEmpty ? null : backdrop.first,
              imageUrls: backdrop,
              fit: BoxFit.cover,
            ),
          ),
          Positioned.fill(
            child: DecoratedBox(
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  begin: Alignment.topCenter,
                  end: Alignment.bottomCenter,
                  colors: [
                    Colors.black.withValues(alpha: 0.3),
                    theme.scaffoldBackgroundColor.withValues(alpha: 0.7),
                    theme.scaffoldBackgroundColor,
                  ],
                  stops: const [0, 0.6, 1],
                ),
              ),
            ),
          ),
          SafeArea(
            child: Padding(
              padding: const EdgeInsets.all(12),
              child: Align(
                alignment: Alignment.topLeft,
                child: BackButton(onPressed: () => context.pop()),
              ),
            ),
          ),
          Positioned(
            left: 48,
            right: 48,
            bottom: 24,
            child: Center(
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 1180),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.end,
                  children: [
                    SizedBox(
                      width: posterWidth,
                      height: posterHeight,
                      child: ClipRRect(
                        borderRadius: BorderRadius.circular(12),
                        child: MediaImage(
                          imageUrl: poster.isEmpty ? null : poster.first,
                          imageUrls: poster,
                          fit: BoxFit.cover,
                        ),
                      ),
                    ),
                    const SizedBox(width: 28),
                    Expanded(child: _titleBlock(context)),
                  ],
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _titleBlock(BuildContext context) {
    final theme = Theme.of(context);
    final tmdb = ani.tmdb;
    final meta = <String>[
      if (ani.releaseDate != null)
        ani.releaseDate!.split('T').first.split(' ').first,
      if (detail.isMovie)
        '电影'
      else if (ani.totalEpisodeNumber != null)
        '共 ${ani.totalEpisodeNumber} 集',
      if (tmdb?.runtime != null) '${tmdb!.runtime} 分钟',
    ];
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(ani.title,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(fontSize: 30, fontWeight: FontWeight.w800)),
        if (ani.jpTitle != null)
          Padding(
            padding: const EdgeInsets.only(top: 4),
            child: Text(ani.jpTitle!,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                    fontSize: 14, color: theme.textTheme.bodySmall?.color)),
          ),
        const SizedBox(height: 12),
        Wrap(
          spacing: 12,
          runSpacing: 8,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: [
            if (ani.rating != null)
              Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const Icon(Icons.star_rounded, size: 18, color: Colors.amber),
                  const SizedBox(width: 4),
                  Text(ani.rating!.toStringAsFixed(1),
                      style: const TextStyle(
                          fontWeight: FontWeight.w700, color: Colors.amber)),
                ],
              ),
            if (meta.isNotEmpty)
              Text(meta.join(' · '), style: const TextStyle(fontSize: 13)),
            if (tmdb != null)
              for (final g in tmdb.genres.take(5))
                Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                  decoration: BoxDecoration(
                    color: theme.colorScheme.surfaceContainerHighest,
                    borderRadius: BorderRadius.circular(6),
                  ),
                  child: Text(g.name, style: const TextStyle(fontSize: 11)),
                ),
          ],
        ),
      ],
    );
  }
}

class _Overview extends StatefulWidget {
  final String text;
  const _Overview({required this.text});
  @override
  State<_Overview> createState() => _OverviewState();
}

class _OverviewState extends State<_Overview> {
  bool _expanded = false;
  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 12),
      child: GestureDetector(
        onTap: () => setState(() => _expanded = !_expanded),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(widget.text,
                maxLines: _expanded ? null : 3,
                overflow: _expanded ? null : TextOverflow.ellipsis,
                style: const TextStyle(fontSize: 14, height: 1.6)),
            const SizedBox(height: 4),
            Text(_expanded ? '收起' : '展开',
                style:
                    TextStyle(fontSize: 13, color: theme.colorScheme.primary)),
          ],
        ),
      ),
    );
  }
}

class _MoviePlay extends StatelessWidget {
  final ServerConfig server;
  final AniDetail detail;
  const _MoviePlay({required this.server, required this.detail});

  @override
  Widget build(BuildContext context) {
    final versions = detail.allVersions;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 12),
      child: Row(
        children: [
          FilledButton.icon(
            onPressed: versions.isEmpty
                ? null
                : () => playSourceItem(context, server, versions.first),
            icon: const Icon(Icons.play_arrow_rounded),
            label: const Padding(
              padding: EdgeInsets.symmetric(horizontal: 12, vertical: 6),
              child: Text('播放'),
            ),
          ),
          if (versions.length > 1) ...[
            const SizedBox(width: 12),
            OutlinedButton(
              onPressed: () => showVersionPicker(context, server, versions),
              child: const Text('选择版本'),
            ),
          ],
        ],
      ),
    );
  }
}

class _Episodes extends StatelessWidget {
  final ServerConfig server;
  final AniDetail detail;
  const _Episodes({required this.server, required this.detail});

  @override
  Widget build(BuildContext context) {
    final eps = detail.episodes;
    if (eps.isEmpty) {
      return const Padding(
        padding: EdgeInsets.symmetric(vertical: 24),
        child: Center(
            child: Text('暂无可播放的剧集文件',
                style: TextStyle(color: Colors.grey))),
      );
    }
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Padding(
            padding: EdgeInsets.only(bottom: 8),
            child: Text('剧集',
                style: TextStyle(fontSize: 16, fontWeight: FontWeight.w700)),
          ),
          for (var i = 0; i < eps.length; i++)
            _EpisodeRow(server: server, ep: eps[i], index: i),
        ],
      ),
    );
  }
}

class _EpisodeRow extends StatefulWidget {
  final ServerConfig server;
  final EpisodeEntry ep;
  final int index;
  const _EpisodeRow(
      {required this.server, required this.ep, required this.index});

  @override
  State<_EpisodeRow> createState() => _EpisodeRowState();
}

class _EpisodeRowState extends State<_EpisodeRow> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final ep = widget.ep;
    final subtitle = ep.hasMultipleVersions
        ? '${ep.versions.length} 个版本'
        : (ep.primary.formatSize ?? '');
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      onEnter: (_) => setState(() => _hover = true),
      onExit: (_) => setState(() => _hover = false),
      child: GestureDetector(
        onTap: () => showVersionPicker(context, widget.server, ep.versions),
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 110),
          margin: const EdgeInsets.symmetric(vertical: 3),
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
          decoration: BoxDecoration(
            color: _hover
                ? theme.colorScheme.surfaceContainerHighest
                : theme.colorScheme.surface,
            borderRadius: BorderRadius.circular(10),
            border: Border.all(
              color: theme.colorScheme.outlineVariant.withValues(alpha: 0.3),
            ),
          ),
          child: Row(
            children: [
              CircleAvatar(
                radius: 18,
                child: Text(
                  ep.episode != null ? _fmt(ep.episode!) : '${widget.index + 1}',
                  style: const TextStyle(fontSize: 13),
                ),
              ),
              const SizedBox(width: 14),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(ep.label,
                        maxLines: 1, overflow: TextOverflow.ellipsis),
                    if (subtitle.isNotEmpty)
                      Padding(
                        padding: const EdgeInsets.only(top: 2),
                        child: Text(subtitle,
                            style: TextStyle(
                                fontSize: 12,
                                color: theme.textTheme.bodySmall?.color)),
                      ),
                  ],
                ),
              ),
              const Icon(Icons.play_circle_outline, color: Colors.grey),
            ],
          ),
        ),
      ),
    );
  }

  static String _fmt(double e) =>
      e == e.roundToDouble() ? e.toInt().toString() : e.toString();
}

class _CastRow extends StatelessWidget {
  final ServerConfig server;
  final AniDetail detail;
  const _CastRow({required this.server, required this.detail});

  @override
  Widget build(BuildContext context) {
    final cast = detail.ani.tmdb!.cast;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Padding(
          padding: EdgeInsets.fromLTRB(0, 16, 0, 12),
          child: Text('演员',
              style: TextStyle(fontSize: 16, fontWeight: FontWeight.w700)),
        ),
        SizedBox(
          height: 160,
          child: ListView.separated(
            scrollDirection: Axis.horizontal,
            itemCount: cast.length > 20 ? 20 : cast.length,
            separatorBuilder: (_, __) => const SizedBox(width: 14),
            itemBuilder: (context, i) => _castCard(cast[i]),
          ),
        ),
      ],
    );
  }

  Widget _castCard(TmdbCast c) {
    final img =
        _tmdbImageCandidates(server, detail.token, c.profilePath, 'w185');
    return SizedBox(
      width: 84,
      child: Column(
        children: [
          SizedBox(
            width: 76,
            height: 76,
            child: MediaImage(
              imageUrl: img.isEmpty ? null : img.first,
              imageUrls: img,
              fit: BoxFit.cover,
              borderRadius: BorderRadius.circular(38),
            ),
          ),
          const SizedBox(height: 6),
          Text(c.name,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              textAlign: TextAlign.center,
              style:
                  const TextStyle(fontSize: 11, fontWeight: FontWeight.w600)),
          if (c.character != null)
            Text(c.character!,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                textAlign: TextAlign.center,
                style: const TextStyle(fontSize: 10, color: Colors.grey)),
        ],
      ),
    );
  }
}
