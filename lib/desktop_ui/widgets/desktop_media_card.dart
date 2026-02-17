import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:lin_player_server_adapters/lin_player_server_adapters.dart';

import '../../server_adapters/server_access.dart';
import '../theme/desktop_theme_extension.dart';
import 'desktop_media_meta.dart';

class DesktopMediaCard extends StatefulWidget {
  const DesktopMediaCard({
    super.key,
    required this.item,
    required this.access,
    this.onTap,
    this.onTogglePlayed,
    this.onToggleFavorite,
    this.onMore,
    this.imageType = 'Primary',
    this.width = 160,
    this.imageAspectRatio = 2 / 3,
    this.showProgress = false,
    this.showMeta = true,
    this.showBadge = true,
    this.isFavorite = false,
    this.titleOverride,
    this.subtitleOverride,
    this.subtitleMaxLines = 1,
    this.badgeText,
  });

  final MediaItem item;
  final ServerAccess? access;
  final VoidCallback? onTap;
  final VoidCallback? onTogglePlayed;
  final VoidCallback? onToggleFavorite;
  final VoidCallback? onMore;
  final String imageType;
  final double width;
  final double imageAspectRatio;
  final bool showProgress;
  final bool showMeta;
  final bool showBadge;
  final bool isFavorite;
  final String? titleOverride;
  final String? subtitleOverride;
  final int subtitleMaxLines;
  final String? badgeText;

  @override
  State<DesktopMediaCard> createState() => _DesktopMediaCardState();
}

class _DesktopMediaCardState extends State<DesktopMediaCard> {
  bool _hovered = false;
  bool _focused = false;

  bool get _active => _hovered || _focused;

  @override
  Widget build(BuildContext context) {
    final theme = DesktopThemeExtension.of(context);
    final imageUrls = _imageCandidates();
    final progress = mediaProgress(widget.item);
    final subtitle = widget.subtitleOverride ?? _defaultSubtitle(widget.item);
    final customTitle = (widget.titleOverride ?? '').trim();
    final title = customTitle.isEmpty
        ? (widget.item.name.trim().isEmpty ? 'Untitled' : widget.item.name)
        : customTitle;
    final badge = (widget.badgeText ?? _defaultBadge(widget.item)).trim();

    return SizedBox(
      width: widget.width,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          FocusableActionDetector(
            onShowHoverHighlight: (value) => setState(() => _hovered = value),
            onShowFocusHighlight: (value) => setState(() => _focused = value),
            mouseCursor: widget.onTap != null
                ? SystemMouseCursors.click
                : SystemMouseCursors.basic,
            child: AnimatedScale(
              scale: _active ? 1.05 : 1.0,
              duration: const Duration(milliseconds: 180),
              curve: Curves.easeOutCubic,
              child: DecoratedBox(
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(8),
                  boxShadow: _active
                      ? [
                          BoxShadow(
                            color: theme.shadowColor,
                            blurRadius: 16,
                            offset: const Offset(0, 8),
                          ),
                        ]
                      : null,
                ),
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(8),
                  child: Material(
                    color: Colors.transparent,
                    child: InkWell(
                      onTap: widget.onTap,
                      child: AspectRatio(
                        aspectRatio: widget.imageAspectRatio,
                        child: Stack(
                          fit: StackFit.expand,
                          children: [
                            _CardImage(
                              imageUrls: imageUrls,
                              title: widget.item.name,
                            ),
                            if (widget.showBadge && badge.isNotEmpty)
                              Positioned(
                                top: 8,
                                right: 8,
                                child: _Badge(
                                  text: badge,
                                  color: theme.posterBadgeBackground,
                                ),
                              ),
                            AnimatedOpacity(
                              opacity: _active ? 1 : 0,
                              duration: const Duration(milliseconds: 170),
                              curve: Curves.easeOutCubic,
                              child: DecoratedBox(
                                decoration: BoxDecoration(
                                  color: theme.posterOverlay,
                                ),
                                child: Stack(
                                  children: [
                                    Center(
                                      child: Container(
                                        width: 48,
                                        height: 48,
                                        decoration: BoxDecoration(
                                          color: theme.accent,
                                          shape: BoxShape.circle,
                                        ),
                                        child: const Icon(
                                          Icons.play_arrow_rounded,
                                          color: Colors.white,
                                          size: 24,
                                        ),
                                      ),
                                    ),
                                    Positioned(
                                      left: 0,
                                      right: 0,
                                      bottom: 0,
                                      child: SizedBox(
                                        height: 40,
                                        child: Row(
                                          mainAxisAlignment:
                                              MainAxisAlignment.spaceEvenly,
                                          children: [
                                            _OverlayIconButton(
                                              icon: widget.item.played
                                                  ? Icons.check_rounded
                                                  : Icons.check_outlined,
                                              active: widget.item.played,
                                              activeColor: theme.accent,
                                              onTap: widget.onTogglePlayed,
                                              background:
                                                  theme.posterControlBackground,
                                            ),
                                            _OverlayIconButton(
                                              icon: widget.isFavorite
                                                  ? Icons.favorite_rounded
                                                  : Icons
                                                      .favorite_border_rounded,
                                              active: widget.isFavorite,
                                              activeColor:
                                                  const Color(0xFFFF6B81),
                                              onTap: widget.onToggleFavorite,
                                              background:
                                                  theme.posterControlBackground,
                                            ),
                                            _OverlayIconButton(
                                              icon: Icons.more_horiz_rounded,
                                              active: false,
                                              activeColor: Colors.white,
                                              onTap: widget.onMore,
                                              background:
                                                  theme.posterControlBackground,
                                            ),
                                          ],
                                        ),
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                            ),
                            if (widget.showProgress && progress > 0)
                              Positioned(
                                left: 0,
                                right: 0,
                                bottom: 0,
                                child: SizedBox(
                                  height: 4,
                                  child: Stack(
                                    children: [
                                      ColoredBox(
                                        color:
                                            Colors.black.withValues(alpha: 0.4),
                                      ),
                                      FractionallySizedBox(
                                        alignment: Alignment.centerLeft,
                                        widthFactor: progress,
                                        child: ColoredBox(color: theme.accent),
                                      ),
                                    ],
                                  ),
                                ),
                              ),
                          ],
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
          if (widget.showMeta) ...[
            const SizedBox(height: 8),
            Text(
              title,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                color: theme.textPrimary,
                fontSize: 14,
                fontWeight: FontWeight.w500,
              ),
            ),
            const SizedBox(height: 4),
            Text(
              subtitle,
              maxLines: widget.subtitleMaxLines.clamp(1, 3),
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                color: theme.textMuted,
                fontSize: 12,
                fontWeight: FontWeight.w400,
              ),
            ),
          ],
        ],
      ),
    );
  }

  String _defaultSubtitle(MediaItem item) {
    final year = mediaYear(item);
    final status = item.played ? 'Played' : 'Now';
    return year.isEmpty ? status : '$year · $status';
  }

  String _defaultBadge(MediaItem item) {
    final type = item.type.trim().toLowerCase();
    final episode = item.episodeNumber ?? 0;
    if (type == 'episode' && episode > 0) return '$episode';
    final season = item.seasonNumber ?? 0;
    if (type == 'season' && season > 0) return 'S$season';
    return '';
  }

  List<String> _imageCandidates() {
    final currentAccess = widget.access;
    if (currentAccess == null) return const <String>[];

    final urls = <String>[];
    final primaryType =
        widget.imageType.trim().isEmpty ? 'Primary' : widget.imageType.trim();

    void addCandidate({
      required String? itemId,
      required String imageType,
      required int maxWidth,
    }) {
      final id = (itemId ?? '').trim();
      if (id.isEmpty) return;
      final url = currentAccess.adapter.imageUrl(
        currentAccess.auth,
        itemId: id,
        imageType: imageType,
        maxWidth: maxWidth,
      );
      if (url.trim().isEmpty || urls.contains(url)) return;
      urls.add(url);
    }

    addCandidate(
      itemId: widget.item.id,
      imageType: primaryType,
      maxWidth: primaryType.toLowerCase() == 'backdrop' ? 920 : 560,
    );
    if (primaryType.toLowerCase() == 'primary') {
      addCandidate(itemId: widget.item.id, imageType: 'Thumb', maxWidth: 560);
      addCandidate(
        itemId: widget.item.id,
        imageType: 'Backdrop',
        maxWidth: 920,
      );
    }
    addCandidate(
        itemId: widget.item.parentId, imageType: 'Primary', maxWidth: 560);
    addCandidate(
        itemId: widget.item.parentId, imageType: 'Thumb', maxWidth: 560);
    addCandidate(
        itemId: widget.item.seriesId, imageType: 'Primary', maxWidth: 560);
    addCandidate(
      itemId: widget.item.seriesId,
      imageType: 'Backdrop',
      maxWidth: 920,
    );

    return urls;
  }
}

class _CardImage extends StatefulWidget {
  const _CardImage({
    required this.imageUrls,
    required this.title,
  });

  final List<String> imageUrls;
  final String title;

  @override
  State<_CardImage> createState() => _CardImageState();
}

class _CardImageState extends State<_CardImage> {
  int _currentIndex = 0;

  @override
  void didUpdateWidget(covariant _CardImage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.imageUrls.join('|') != widget.imageUrls.join('|')) {
      _currentIndex = 0;
    }
  }

  @override
  Widget build(BuildContext context) {
    final candidates = widget.imageUrls
        .map((value) => value.trim())
        .where((value) => value.isNotEmpty)
        .toList(growable: false);
    if (candidates.isNotEmpty && _currentIndex < candidates.length) {
      final imageUrl = candidates[_currentIndex];
      return CachedNetworkImage(
        key: ValueKey<String>('${widget.title}-$imageUrl'),
        imageUrl: imageUrl,
        fit: BoxFit.cover,
        placeholder: (_, __) => const _ImageFallback(),
        errorWidget: (_, __, ___) {
          if (_currentIndex < candidates.length - 1) {
            WidgetsBinding.instance.addPostFrameCallback((_) {
              if (!mounted) return;
              setState(() => _currentIndex += 1);
            });
          }
          return _ImageFallback(title: widget.title);
        },
      );
    }
    return _ImageFallback(title: widget.title);
  }
}

class _ImageFallback extends StatelessWidget {
  const _ImageFallback({this.title = ''});

  final String title;

  @override
  Widget build(BuildContext context) {
    final theme = DesktopThemeExtension.of(context);
    return DecoratedBox(
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [theme.surface, theme.surfaceElevated],
        ),
      ),
      child: Center(
        child: Padding(
          padding: const EdgeInsets.all(10),
          child: Text(
            title.trim().isEmpty ? 'No Poster' : title,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            textAlign: TextAlign.center,
            style: TextStyle(
              color: theme.textMuted,
              fontWeight: FontWeight.w500,
              fontSize: 12,
            ),
          ),
        ),
      ),
    );
  }
}

class _OverlayIconButton extends StatelessWidget {
  const _OverlayIconButton({
    required this.icon,
    required this.active,
    required this.activeColor,
    required this.background,
    this.onTap,
  });

  final IconData icon;
  final bool active;
  final Color activeColor;
  final Color background;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final fg = active ? activeColor : Colors.white;
    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(999),
        child: Ink(
          width: 28,
          height: 28,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            color: background,
          ),
          child: Icon(icon, size: 16, color: fg),
        ),
      ),
    );
  }
}

class _Badge extends StatelessWidget {
  const _Badge({required this.text, required this.color});

  final String text;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 24,
      height: 24,
      decoration: BoxDecoration(
        color: color,
        shape: BoxShape.circle,
      ),
      alignment: Alignment.center,
      child: Text(
        text,
        style: const TextStyle(
          color: Colors.white,
          fontSize: 11,
          fontWeight: FontWeight.w700,
          height: 1.0,
        ),
      ),
    );
  }
}
