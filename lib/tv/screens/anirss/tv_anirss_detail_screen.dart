import 'package:flutter/material.dart';
import 'package:flutter_animate/flutter_animate.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../core/providers/server_providers.dart';
import '../../../core/sources/anirss/anirss_api.dart';
import '../../../core/sources/anirss/anirss_nav_args.dart';
import '../../../core/sources/anirss/anirss_providers.dart';
import '../../../core/sources/anirss/models/ani.dart';
import '../../../core/sources/anirss/models/play_item.dart';
import '../../../ui/screens/source/source_player_screen.dart';
import '../../../ui/widgets/anirss/anirss_version_picker.dart';
import '../../../ui/widgets/common/media_widgets.dart';
import '../../theme/tv_design_tokens.dart';
import '../../theme/tv_metrics.dart';
import '../../widgets/tv_button.dart';
import '../../widgets/tv_focusable.dart';

/// 跳转 TV 直链播放页（复用共享的 sourceEntryFor，但走 TV 路由 `/tv/source-player`）。
void _playTv(BuildContext context, ServerConfig server, PlayItemModel item) {
  context.push(
    '/tv/source-player',
    extra: SourcePlayArgs(server: server, entry: sourceEntryFor(item)),
  );
}

/// Ani-rss 详情页（TV）。Hero 背景 + 标题/评分/类型/简介 + 播放/选集。
/// 剧集多版本 → 自建 TV 版本选择 overlay（D-pad 可导航）。
class TvAniRssDetailScreen extends ConsumerWidget {
  final AniRssDetailArgs args;
  const TvAniRssDetailScreen({super.key, required this.args});

  AniModel get ani => args.ani;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final m = context.tv;
    final asyncDetail = ref.watch(aniDetailProvider(ani));
    return Scaffold(
      backgroundColor: TvDesignTokens.background,
      body: asyncDetail.when(
        loading: () => const Center(
            child: CircularProgressIndicator(color: TvDesignTokens.brand)),
        error: (e, _) => Center(
          child: Padding(
            padding: EdgeInsets.all(m.spacingXl),
            child: Text('加载失败：$e',
                textAlign: TextAlign.center,
                style: TextStyle(
                    color: TvDesignTokens.textSecondary,
                    fontSize: m.fontSizeMd)),
          ),
        ),
        data: (detail) => _Body(server: args.server, ani: ani, detail: detail),
      ),
    );
  }
}

class _Body extends StatelessWidget {
  final ServerConfig server;
  final AniModel ani;
  final AniDetail detail;
  const _Body({required this.server, required this.ani, required this.detail});

  /// TMDB 相对路径 → [代理URL, 直链] 候选（代理优先，直链兜底）。
  List<String> _tmdbCandidates(String? path, String size) {
    if (path == null || path.isEmpty) return const [];
    final full = path.startsWith('http')
        ? path
        : 'https://image.tmdb.org/t/p/$size$path';
    return [
      AniRssApi.buildProxyImageUrl(server, full, detail.token),
      full,
    ];
  }

  @override
  Widget build(BuildContext context) {
    final m = context.tv;
    final tmdb = ani.tmdb;
    final overview = tmdb?.overview;
    return SingleChildScrollView(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _buildHero(m),
          Padding(
            padding: EdgeInsets.all(m.spacingXl),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                if (detail.isMovie)
                  _MovieActions(server: server, detail: detail)
                else
                  _EpisodeList(server: server, detail: detail),
                if (overview != null && overview.isNotEmpty) ...[
                  SizedBox(height: m.spacingLg),
                  _buildSynopsis(m, overview),
                ],
                SizedBox(height: m.spacingXxl),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildHero(TvMetrics m) {
    final tmdb = ani.tmdb;
    final backdrop = [
      ..._tmdbCandidates(tmdb?.backdropPath, 'w1280'),
      if (ani.image != null) ani.image!,
    ];
    return SizedBox(
      height: m.s(420),
      child: Stack(
        fit: StackFit.expand,
        children: [
          if (backdrop.isNotEmpty)
            MediaImage(
              imageUrl: backdrop.first,
              imageUrls: backdrop.length > 1 ? backdrop.sublist(1) : null,
              width: double.infinity,
              height: double.infinity,
              fit: BoxFit.cover,
            )
          else
            const ColoredBox(color: TvDesignTokens.surfaceElevated),
          Container(
            decoration: BoxDecoration(
              gradient: LinearGradient(
                begin: Alignment.topCenter,
                end: Alignment.bottomCenter,
                colors: [
                  Colors.transparent,
                  TvDesignTokens.background.withValues(alpha: 0.8),
                  TvDesignTokens.background,
                ],
                stops: const [0.4, 0.82, 1.0],
              ),
            ),
          ),
          Positioned(
            left: m.spacingXl,
            right: m.spacingXl,
            bottom: m.spacingLg,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  ani.title,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: m.fontSizeXxl,
                    color: TvDesignTokens.textPrimary,
                    fontWeight: FontWeight.bold,
                  ),
                ),
                if (ani.jpTitle != null)
                  Padding(
                    padding: EdgeInsets.only(top: m.s(2)),
                    child: Text(
                      ani.jpTitle!,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: m.fontSizeSm,
                        color: TvDesignTokens.textSecondary,
                      ),
                    ),
                  ),
                SizedBox(height: m.spacingSm),
                Row(
                  children: [
                    if (ani.rating != null) ...[
                      Container(
                        padding: EdgeInsets.symmetric(
                            horizontal: m.spacingSm, vertical: m.s(4)),
                        decoration: BoxDecoration(
                          color: TvDesignTokens.brand,
                          borderRadius: BorderRadius.circular(m.s(4)),
                        ),
                        child: Text(
                          '★ ${ani.rating!.toStringAsFixed(1)}',
                          style: TextStyle(
                            fontSize: m.fontSizeSm,
                            color: Colors.white,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                      ),
                      SizedBox(width: m.spacingMd),
                    ],
                    Expanded(
                      child: Text(
                        _metaLine(),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontSize: m.fontSizeSm,
                          color: TvDesignTokens.textSecondary,
                        ),
                      ),
                    ),
                  ],
                ),
                if (tmdb != null && tmdb.genres.isNotEmpty) ...[
                  SizedBox(height: m.spacingSm),
                  Wrap(
                    spacing: m.spacingSm,
                    runSpacing: m.spacingXs,
                    children: [
                      for (final g in tmdb.genres.take(4))
                        Container(
                          padding: EdgeInsets.symmetric(
                              horizontal: m.spacingSm, vertical: m.s(4)),
                          decoration: BoxDecoration(
                            color: TvDesignTokens.surface,
                            borderRadius: BorderRadius.circular(m.s(6)),
                          ),
                          child: Text(g.name,
                              style: TextStyle(
                                  fontSize: m.fontSizeXs,
                                  color: TvDesignTokens.textPrimary)),
                        ),
                    ],
                  ),
                ],
              ],
            ).animate().fadeIn(duration: TvDesignTokens.contentFadeDuration),
          ),
        ],
      ),
    );
  }

  String _metaLine() {
    final tmdb = ani.tmdb;
    final parts = <String>[
      if (ani.releaseDate != null)
        ani.releaseDate!.split('T').first.split(' ').first,
      if (detail.isMovie)
        '电影'
      else if (ani.totalEpisodeNumber != null)
        '共 ${ani.totalEpisodeNumber} 集',
      if (tmdb?.runtime != null) '${tmdb!.runtime} 分钟',
    ];
    return parts.join(' · ');
  }

  Widget _buildSynopsis(TvMetrics m, String overview) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          '简介',
          style: TextStyle(
            fontSize: m.fontSizeLg,
            color: TvDesignTokens.textPrimary,
            fontWeight: FontWeight.bold,
          ),
        ),
        SizedBox(height: m.spacingSm),
        Text(
          overview,
          style: TextStyle(
            fontSize: m.fontSizeSm,
            color: TvDesignTokens.textSecondary,
            height: TvDesignTokens.lineHeightRelaxed,
          ),
        ),
      ],
    );
  }
}

/// 电影/单集：播放按钮 + 选择版本。
class _MovieActions extends StatelessWidget {
  final ServerConfig server;
  final AniDetail detail;
  const _MovieActions({required this.server, required this.detail});

  @override
  Widget build(BuildContext context) {
    final m = context.tv;
    final versions = detail.allVersions;
    return Row(
      children: [
        TvButton(
          text: '播放',
          icon: Icons.play_arrow,
          autofocus: true,
          onPressed: versions.isEmpty
              ? null
              : () => _playTv(context, server, versions.first),
        ),
        if (versions.length > 1) ...[
          SizedBox(width: m.spacingMd),
          TvButton(
            text: '选择版本',
            icon: Icons.layers_outlined,
            outlined: true,
            onPressed: () =>
                showTvVersionPicker(context, server, versions),
          ),
        ],
      ],
    );
  }
}

/// 剧集：焦点可导航的剧集列表，多版本集打开 TV 版本选择 overlay。
class _EpisodeList extends StatelessWidget {
  final ServerConfig server;
  final AniDetail detail;
  const _EpisodeList({required this.server, required this.detail});

  @override
  Widget build(BuildContext context) {
    final m = context.tv;
    final eps = detail.episodes;
    if (eps.isEmpty) {
      return Padding(
        padding: EdgeInsets.symmetric(vertical: m.spacingLg),
        child: Text('暂无可播放的剧集文件',
            style: TextStyle(
                color: TvDesignTokens.textSecondary,
                fontSize: m.fontSizeMd)),
      );
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          '共 ${eps.length} 集',
          style: TextStyle(
            fontSize: m.fontSizeLg,
            color: TvDesignTokens.textPrimary,
            fontWeight: FontWeight.bold,
          ),
        ),
        SizedBox(height: m.spacingMd),
        Wrap(
          spacing: m.spacingMd,
          runSpacing: m.spacingMd,
          children: [
            for (final entry in eps.asMap().entries)
              TvFocusable(
                padding: EdgeInsets.all(m.s(4)),
                onSelect: () => _onSelect(context, entry.value),
                child: _epChip(m, entry.value, entry.key),
              ).animate().fadeIn(
                    delay: Duration(milliseconds: 16 * (entry.key % 12)),
                    duration: TvDesignTokens.contentFadeDuration,
                  ),
          ],
        ),
      ],
    );
  }

  void _onSelect(BuildContext context, EpisodeEntry entry) {
    if (entry.hasMultipleVersions) {
      showTvVersionPicker(context, server, entry.versions);
    } else {
      _playTv(context, server, entry.primary);
    }
  }

  Widget _epChip(TvMetrics m, EpisodeEntry entry, int index) {
    final epText = entry.episode != null ? _fmt(entry.episode!) : '${index + 1}';
    return Container(
      width: m.s(180),
      padding: EdgeInsets.symmetric(
          horizontal: m.spacingMd, vertical: m.spacingSm),
      decoration: BoxDecoration(
        color: TvDesignTokens.surface,
        borderRadius: BorderRadius.circular(m.posterRadius),
      ),
      child: Row(
        children: [
          Container(
            width: m.s(40),
            height: m.s(40),
            alignment: Alignment.center,
            decoration: const BoxDecoration(
              color: TvDesignTokens.surfaceElevated,
              shape: BoxShape.circle,
            ),
            child: Text(
              epText,
              style: TextStyle(
                fontSize: m.fontSizeSm,
                color: TvDesignTokens.textPrimary,
                fontWeight: FontWeight.bold,
              ),
            ),
          ),
          SizedBox(width: m.spacingSm),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  '第 $epText 集',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: m.fontSizeSm,
                    color: TvDesignTokens.textPrimary,
                  ),
                ),
                Text(
                  entry.hasMultipleVersions
                      ? '${entry.versions.length} 个版本'
                      : (entry.primary.formatSize ?? '点击播放'),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: m.fs(12),
                    color: TvDesignTokens.textSecondary,
                  ),
                ),
              ],
            ),
          ),
          Icon(
            entry.hasMultipleVersions
                ? Icons.layers_outlined
                : Icons.play_circle_outline,
            color: TvDesignTokens.textSecondary,
            size: m.s(24),
          ),
        ],
      ),
    );
  }

  static String _fmt(double e) =>
      e == e.roundToDouble() ? e.toInt().toString() : e.toString();
}

/// TV 版本选择 overlay（D-pad 可导航的全屏列表）。选中即播放。
/// 不复用 Material 的 showVersionPicker 底部弹层。
Future<void> showTvVersionPicker(
  BuildContext context,
  ServerConfig server,
  List<PlayItemModel> versions,
) async {
  if (versions.length == 1) {
    _playTv(context, server, versions.first);
    return;
  }
  final selected = await showGeneralDialog<PlayItemModel>(
    context: context,
    barrierDismissible: true,
    barrierLabel: '选择版本',
    barrierColor: Colors.black.withValues(alpha: 0.7),
    pageBuilder: (ctx, _, __) => _TvVersionPickerOverlay(versions: versions),
  );
  if (selected != null && context.mounted) {
    _playTv(context, server, selected);
  }
}

class _TvVersionPickerOverlay extends StatelessWidget {
  final List<PlayItemModel> versions;
  const _TvVersionPickerOverlay({required this.versions});

  @override
  Widget build(BuildContext context) {
    final m = context.tv;
    return Center(
      child: Material(
        color: Colors.transparent,
        child: Container(
          width: m.s(720),
          constraints: BoxConstraints(maxHeight: m.s(640)),
          padding: EdgeInsets.all(m.spacingXl),
          decoration: BoxDecoration(
            color: TvDesignTokens.surface,
            borderRadius: BorderRadius.circular(m.posterRadius),
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                '选择版本',
                style: TextStyle(
                  fontSize: m.fontSizeLg,
                  color: TvDesignTokens.textPrimary,
                  fontWeight: FontWeight.bold,
                ),
              ),
              SizedBox(height: m.spacingMd),
              Flexible(
                child: ListView.builder(
                  shrinkWrap: true,
                  itemCount: versions.length,
                  itemBuilder: (context, i) {
                    final v = versions[i];
                    return Padding(
                      padding: EdgeInsets.only(bottom: m.spacingSm),
                      child: TvFocusable(
                        autofocus: i == 0,
                        padding: EdgeInsets.all(m.s(4)),
                        onSelect: () => Navigator.of(context).pop(v),
                        child: Container(
                          padding: EdgeInsets.symmetric(
                              horizontal: m.spacingLg,
                              vertical: m.spacingMd),
                          decoration: BoxDecoration(
                            color: TvDesignTokens.surfaceElevated,
                            borderRadius: BorderRadius.circular(m.posterRadius),
                          ),
                          child: Row(
                            children: [
                              Icon(Icons.movie_outlined,
                                  color: TvDesignTokens.brand, size: m.s(28)),
                              SizedBox(width: m.spacingMd),
                              Expanded(
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  mainAxisSize: MainAxisSize.min,
                                  children: [
                                    Text(
                                      versionLabel(v),
                                      maxLines: 1,
                                      overflow: TextOverflow.ellipsis,
                                      style: TextStyle(
                                        fontSize: m.fontSizeMd,
                                        color: TvDesignTokens.textPrimary,
                                      ),
                                    ),
                                    Text(
                                      v.decodedName,
                                      maxLines: 1,
                                      overflow: TextOverflow.ellipsis,
                                      style: TextStyle(
                                        fontSize: m.fontSizeXs,
                                        color: TvDesignTokens.textSecondary,
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
                    );
                  },
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
