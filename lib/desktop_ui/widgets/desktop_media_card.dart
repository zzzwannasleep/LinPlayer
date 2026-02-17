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
    this.subtitleOverride,
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
  final String? subtitleOverride;
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
    final imageUrl = _imageUrl();
    final progress = mediaProgress(widget.item);
    final subtitle = widget.subtitleOverride ?? _defaultSubtitle(widget.item);
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
                              imageUrl: imageUrl,
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
              widget.item.name.trim().isEmpty ? 'Untitled' : widget.item.name,
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
              maxLines: 1,
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
    final episode = item.episodeNumber ?? 0;
    if (episode > 0) return '$episode';
    final season = item.seasonNumber ?? 0;
    if (season > 0) return '$season';
    return '${(item.id.hashCode.abs() % 99) + 1}';
  }

  String? _imageUrl() {
    final currentAccess = widget.access;
    if (currentAccess == null) return null;
    if (widget.imageType == 'Primary' && !widget.item.hasImage) return null;
    return currentAccess.adapter.imageUrl(
      currentAccess.auth,
      itemId: widget.item.id,
      imageType: widget.imageType,
      maxWidth: 560,
    );
  }
}

class _CardImage extends StatelessWidget {
  const _CardImage({
    required this.imageUrl,
    required this.title,
  });

  final String? imageUrl;
  final String title;

  @override
  Widget build(BuildContext context) {
    if (imageUrl != null && imageUrl!.isNotEmpty) {
      return CachedNetworkImage(
        imageUrl: imageUrl!,
        fit: BoxFit.cover,
        placeholder: (_, __) => const _ImageFallback(),
        errorWidget: (_, __, ___) => _ImageFallback(title: title),
      );
    }
    return _ImageFallback(title: title);
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
