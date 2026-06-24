import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/providers/server_providers.dart';
import '../../../core/sources/anirss/anirss_api.dart';
import '../../../core/sources/anirss/anirss_nav_args.dart';
import '../../../core/sources/anirss/anirss_providers.dart';
import '../../../core/sources/anirss/models/ani.dart';
import '../../../core/sources/anirss/models/tmdb.dart';
import '../../../core/widgets/app_shimmer.dart';
import '../../widgets/anirss/anirss_version_picker.dart';
import '../../widgets/common/media_widgets.dart';

/// Ani-rss 详情页（移动端）。剧/影自适应，版块对齐 Emby。
class AniRssDetailScreen extends ConsumerWidget {
  final AniRssDetailArgs args;
  const AniRssDetailScreen({super.key, required this.args});

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
          SafeArea(child: BackButton(onPressed: () => Navigator.pop(context))),
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
          SafeArea(child: BackButton(onPressed: () => Navigator.pop(context))),
        ],
      );
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
    return CustomScrollView(
      slivers: [
        SliverToBoxAdapter(child: _Header(server: server, ani: ani, detail: detail)),
        if (tmdb?.overview != null && tmdb!.overview!.isNotEmpty)
          SliverToBoxAdapter(child: _Overview(text: tmdb.overview!)),
        if (detail.isMovie)
          SliverToBoxAdapter(child: _MoviePlay(server: server, detail: detail))
        else
          _EpisodesSliver(server: server, detail: detail),
        if (tmdb != null && tmdb.cast.isNotEmpty)
          SliverToBoxAdapter(child: _CastRow(server: server, ani: ani, detail: detail)),
        const SliverToBoxAdapter(child: SizedBox(height: 32)),
      ],
    );
  }
}

/// TMDB 相对路径 → [代理URL, 直链] 候选（代理优先，直链兜底）。
List<String> tmdbImageCandidates(
    ServerConfig server, String token, String? path, String size) {
  if (path == null || path.isEmpty) return const [];
  final full =
      path.startsWith('http') ? path : 'https://image.tmdb.org/t/p/$size$path';
  return [
    AniRssApi.buildProxyImageUrl(server, full, token),
    full,
  ];
}

class _Header extends StatelessWidget {
  final ServerConfig server;
  final AniModel ani;
  final AniDetail detail;
  const _Header({required this.server, required this.ani, required this.detail});

  @override
  Widget build(BuildContext context) {
    final tmdb = ani.tmdb;
    final backdrop = [
      ...tmdbImageCandidates(server, detail.token, tmdb?.backdropPath, 'w1280'),
      if (ani.image != null) ani.image!,
    ];
    final poster = [
      if (ani.image != null) ani.image!,
      ...tmdbImageCandidates(server, detail.token, tmdb?.posterPath, 'w500'),
    ];
    return Stack(
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
                  Colors.black.withValues(alpha: 0.35),
                  Theme.of(context).scaffoldBackgroundColor.withValues(alpha: 0.7),
                  Theme.of(context).scaffoldBackgroundColor,
                ],
                stops: const [0, 0.65, 1],
              ),
            ),
          ),
        ),
        SafeArea(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              BackButton(onPressed: () => Navigator.pop(context)),
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 20, 16, 12),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.end,
                  children: [
                    SizedBox(
                      width: 110,
                      height: 165,
                      child: MediaImage(
                        imageUrl: poster.isEmpty ? null : poster.first,
                        imageUrls: poster,
                        fit: BoxFit.cover,
                        borderRadius: BorderRadius.circular(10),
                      ),
                    ),
                    const SizedBox(width: 14),
                    Expanded(child: _titleBlock(context)),
                  ],
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _titleBlock(BuildContext context) {
    final tmdb = ani.tmdb;
    final meta = <String>[
      if (ani.releaseDate != null) ani.releaseDate!.split('T').first.split(' ').first,
      if (detail.isMovie) '电影' else if (ani.totalEpisodeNumber != null) '共 ${ani.totalEpisodeNumber} 集',
      if (tmdb?.runtime != null) '${tmdb!.runtime} 分钟',
    ];
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(ani.title,
            style: const TextStyle(fontSize: 20, fontWeight: FontWeight.bold)),
        if (ani.jpTitle != null)
          Padding(
            padding: const EdgeInsets.only(top: 2),
            child: Text(ani.jpTitle!,
                style: TextStyle(
                    fontSize: 12,
                    color: Theme.of(context).textTheme.bodySmall?.color)),
          ),
        const SizedBox(height: 8),
        Row(
          children: [
            if (ani.rating != null) ...[
              const Icon(Icons.star_rounded, size: 16, color: Colors.amber),
              const SizedBox(width: 2),
              Text(ani.rating!.toStringAsFixed(1),
                  style: const TextStyle(
                      fontWeight: FontWeight.w600, color: Colors.amber)),
              const SizedBox(width: 10),
            ],
            Expanded(
              child: Text(meta.join(' · '),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(fontSize: 12)),
            ),
          ],
        ),
        if (tmdb != null && tmdb.genres.isNotEmpty)
          Padding(
            padding: const EdgeInsets.only(top: 8),
            child: Wrap(
              spacing: 6,
              runSpacing: 4,
              children: [
                for (final g in tmdb.genres.take(4))
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                    decoration: BoxDecoration(
                      color: Theme.of(context).colorScheme.surfaceContainerHighest,
                      borderRadius: BorderRadius.circular(6),
                    ),
                    child: Text(g.name, style: const TextStyle(fontSize: 11)),
                  ),
              ],
            ),
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
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 4, 16, 12),
      child: GestureDetector(
        onTap: () => setState(() => _expanded = !_expanded),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(widget.text,
                maxLines: _expanded ? null : 3,
                overflow: _expanded ? null : TextOverflow.ellipsis,
                style: const TextStyle(fontSize: 13, height: 1.5)),
            const SizedBox(height: 2),
            Text(_expanded ? '收起' : '展开',
                style: TextStyle(
                    fontSize: 12, color: Theme.of(context).colorScheme.primary)),
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
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
      child: Row(
        children: [
          Expanded(
            child: FilledButton.icon(
              onPressed: versions.isEmpty
                  ? null
                  : () => playSourceItem(context, server, versions.first),
              icon: const Icon(Icons.play_arrow_rounded),
              label: const Text('播放'),
            ),
          ),
          if (versions.length > 1) ...[
            const SizedBox(width: 8),
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

class _EpisodesSliver extends StatelessWidget {
  final ServerConfig server;
  final AniDetail detail;
  const _EpisodesSliver({required this.server, required this.detail});

  @override
  Widget build(BuildContext context) {
    final eps = detail.episodes;
    if (eps.isEmpty) {
      return const SliverToBoxAdapter(
        child: Padding(
          padding: EdgeInsets.all(24),
          child: Center(child: Text('暂无可播放的剧集文件', style: TextStyle(color: Colors.grey))),
        ),
      );
    }
    return SliverPadding(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
      sliver: SliverList.separated(
        itemCount: eps.length,
        separatorBuilder: (_, __) => const Divider(height: 1),
        itemBuilder: (context, i) {
          final ep = eps[i];
          return ListTile(
            contentPadding: EdgeInsets.zero,
            leading: CircleAvatar(
              radius: 18,
              child: Text(
                ep.episode != null ? _fmt(ep.episode!) : '${i + 1}',
                style: const TextStyle(fontSize: 13),
              ),
            ),
            title: Text(ep.label, maxLines: 1, overflow: TextOverflow.ellipsis),
            subtitle: ep.hasMultipleVersions
                ? Text('${ep.versions.length} 个版本',
                    style: const TextStyle(fontSize: 12))
                : (ep.primary.formatSize != null
                    ? Text(ep.primary.formatSize!,
                        style: const TextStyle(fontSize: 12))
                    : null),
            trailing: const Icon(Icons.play_circle_outline),
            onTap: () => showVersionPicker(context, server, ep.versions),
          );
        },
      ),
    );
  }

  static String _fmt(double e) =>
      e == e.roundToDouble() ? e.toInt().toString() : e.toString();
}

class _CastRow extends StatelessWidget {
  final ServerConfig server;
  final AniModel ani;
  final AniDetail detail;
  const _CastRow({required this.server, required this.ani, required this.detail});

  @override
  Widget build(BuildContext context) {
    final cast = ani.tmdb!.cast;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Padding(
          padding: EdgeInsets.fromLTRB(16, 12, 16, 8),
          child: Text('演员',
              style: TextStyle(fontSize: 15, fontWeight: FontWeight.w700)),
        ),
        SizedBox(
          height: 150,
          child: ListView.separated(
            scrollDirection: Axis.horizontal,
            padding: const EdgeInsets.symmetric(horizontal: 16),
            itemCount: cast.length > 20 ? 20 : cast.length,
            separatorBuilder: (_, __) => const SizedBox(width: 12),
            itemBuilder: (context, i) => _castCard(cast[i]),
          ),
        ),
      ],
    );
  }

  Widget _castCard(TmdbCast c) {
    final img =
        tmdbImageCandidates(server, detail.token, c.profilePath, 'w185');
    return SizedBox(
      width: 78,
      child: Column(
        children: [
          SizedBox(
            width: 70,
            height: 70,
            child: MediaImage(
              imageUrl: img.isEmpty ? null : img.first,
              imageUrls: img,
              fit: BoxFit.cover,
              borderRadius: BorderRadius.circular(35),
            ),
          ),
          const SizedBox(height: 6),
          Text(c.name,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              textAlign: TextAlign.center,
              style: const TextStyle(fontSize: 11, fontWeight: FontWeight.w600)),
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
