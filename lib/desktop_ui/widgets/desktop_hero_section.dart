import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:lin_player_server_adapters/lin_player_server_adapters.dart';

import '../../server_adapters/server_access.dart';
import '../theme/desktop_theme_extension.dart';
import 'desktop_media_meta.dart';

class DesktopHeroSection extends StatelessWidget {
  const DesktopHeroSection({
    super.key,
    required this.item,
    required this.access,
    required this.actionButtons,
    this.overview,
  });

  final MediaItem item;
  final ServerAccess? access;
  final Widget actionButtons;
  final String? overview;

  @override
  Widget build(BuildContext context) {
    final desktopTheme = DesktopThemeExtension.of(context);
    final backdropUrl = _imageUrl(type: 'Backdrop', width: 1600);
    final posterUrl = _imageUrl(type: 'Primary', width: 520);

    final meta = <String>[
      mediaTypeLabel(item),
      mediaYear(item),
      mediaRuntimeLabel(item),
      ...item.genres.take(3),
    ].where((part) => part.trim().isNotEmpty).toList(growable: false);

    return ClipRRect(
      borderRadius: BorderRadius.circular(20),
      child: SizedBox(
        height: 420,
        child: Stack(
          fit: StackFit.expand,
          children: [
            if (backdropUrl != null && backdropUrl.isNotEmpty)
              CachedNetworkImage(
                imageUrl: backdropUrl,
                fit: BoxFit.cover,
                placeholder: (_, __) => const SizedBox.shrink(),
                errorWidget: (_, __, ___) => const SizedBox.shrink(),
              ),
            DecoratedBox(
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  begin: Alignment.topCenter,
                  end: Alignment.bottomCenter,
                  colors: [
                    Colors.black.withValues(alpha: 0.18),
                    Colors.black.withValues(alpha: 0.72),
                  ],
                ),
              ),
            ),
            DecoratedBox(
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  begin: Alignment.centerLeft,
                  end: Alignment.centerRight,
                  colors: [
                    desktopTheme.background.withValues(alpha: 0.92),
                    Colors.transparent,
                  ],
                  stops: const [0.0, 0.68],
                ),
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(28, 28, 34, 28),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  ClipRRect(
                    borderRadius: BorderRadius.circular(14),
                    child: SizedBox(
                      width: 220,
                      child: AspectRatio(
                        aspectRatio: 0.68,
                        child: _PosterImage(url: posterUrl, title: item.name),
                      ),
                    ),
                  ),
                  const SizedBox(width: 30),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        const Spacer(),
                        Text(
                          item.name.trim().isEmpty ? 'Untitled' : item.name,
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            color: desktopTheme.textPrimary,
                            fontSize: 38,
                            fontWeight: FontWeight.w800,
                            height: 1.04,
                          ),
                        ),
                        const SizedBox(height: 14),
                        if (meta.isNotEmpty)
                          Wrap(
                            spacing: 8,
                            runSpacing: 8,
                            children: meta
                                .map(
                                  (value) => Container(
                                    padding: const EdgeInsets.symmetric(
                                      horizontal: 10,
                                      vertical: 6,
                                    ),
                                    decoration: BoxDecoration(
                                      color: Colors.black.withValues(alpha: 0.36),
                                      borderRadius: BorderRadius.circular(999),
                                    ),
                                    child: Text(
                                      value,
                                      style: const TextStyle(
                                        color: Colors.white,
                                        fontSize: 12,
                                        fontWeight: FontWeight.w600,
                                      ),
                                    ),
                                  ),
                                )
                                .toList(growable: false),
                          ),
                        const SizedBox(height: 16),
                        if ((overview ?? '').trim().isNotEmpty)
                          Text(
                            overview!,
                            maxLines: 4,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              color: desktopTheme.textMuted,
                              height: 1.45,
                              fontSize: 14,
                            ),
                          ),
                        const SizedBox(height: 20),
                        actionButtons,
                        const Spacer(),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  String? _imageUrl({required String type, required int width}) {
    final currentAccess = access;
    if (currentAccess == null) return null;
    if (!item.hasImage && type == 'Primary') return null;
    return currentAccess.adapter.imageUrl(
      currentAccess.auth,
      itemId: item.id,
      imageType: type,
      maxWidth: width,
    );
  }
}

class _PosterImage extends StatelessWidget {
  const _PosterImage({
    required this.url,
    required this.title,
  });

  final String? url;
  final String title;

  @override
  Widget build(BuildContext context) {
    if (url != null && url!.isNotEmpty) {
      return CachedNetworkImage(
        imageUrl: url!,
        fit: BoxFit.cover,
        placeholder: (_, __) => const SizedBox.shrink(),
        errorWidget: (_, __, ___) => _PosterFallback(title: title),
      );
    }

    return _PosterFallback(title: title);
  }
}

class _PosterFallback extends StatelessWidget {
  const _PosterFallback({required this.title});

  final String title;

  @override
  Widget build(BuildContext context) {
    final desktopTheme = DesktopThemeExtension.of(context);
    return DecoratedBox(
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [
            desktopTheme.surface,
            desktopTheme.surfaceElevated,
          ],
        ),
      ),
      child: Center(
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: Text(
            title.trim().isEmpty ? 'No Poster' : title,
            maxLines: 3,
            overflow: TextOverflow.ellipsis,
            textAlign: TextAlign.center,
            style: TextStyle(color: desktopTheme.textMuted),
          ),
        ),
      ),
    );
  }
}
