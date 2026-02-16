import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:lin_player_server_adapters/lin_player_server_adapters.dart';

import '../theme/desktop_theme_extension.dart';
import '../../server_adapters/server_access.dart';
import 'desktop_media_meta.dart';
import 'hover_effect_wrapper.dart';

class DesktopMediaCard extends StatelessWidget {
  const DesktopMediaCard({
    super.key,
    required this.item,
    required this.access,
    this.onTap,
    this.imageType = 'Primary',
    this.width = 208,
    this.imageAspectRatio = 0.64,
    this.showProgress = true,
    this.subtitleOverride,
  });

  final MediaItem item;
  final ServerAccess? access;
  final VoidCallback? onTap;
  final String imageType;
  final double width;
  final double imageAspectRatio;
  final bool showProgress;
  final String? subtitleOverride;

  @override
  Widget build(BuildContext context) {
    final desktopTheme = DesktopThemeExtension.of(context);
    final imageUrl = _imageUrl();
    final progress = mediaProgress(item);
    final year = mediaYear(item);
    final runtime = mediaRuntimeLabel(item);
    final subtitle = subtitleOverride ??
        [mediaTypeLabel(item), year, runtime]
            .where((part) => part.trim().isNotEmpty)
            .join('  ·  ');

    return SizedBox(
      width: width,
      child: HoverEffectWrapper(
        onTap: onTap,
        borderRadius: BorderRadius.circular(14),
        child: DecoratedBox(
          decoration: BoxDecoration(
            color: desktopTheme.surfaceElevated,
            borderRadius: BorderRadius.circular(14),
            border: Border.all(color: desktopTheme.border),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              AspectRatio(
                aspectRatio: imageAspectRatio,
                child: Stack(
                  fit: StackFit.expand,
                  children: [
                    ClipRRect(
                      borderRadius: const BorderRadius.vertical(
                        top: Radius.circular(14),
                      ),
                      child: _CardImage(
                        imageUrl: imageUrl,
                        title: item.name,
                      ),
                    ),
                    Positioned(
                      top: 10,
                      left: 10,
                      child: _TypePill(label: mediaTypeLabel(item)),
                    ),
                    if (showProgress && progress > 0)
                      Positioned(
                        left: 0,
                        right: 0,
                        bottom: 0,
                        child: LinearProgressIndicator(
                          value: progress,
                          minHeight: 3,
                          backgroundColor: Colors.black.withValues(alpha: 0.36),
                        ),
                      ),
                  ],
                ),
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(10, 10, 10, 12),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      item.name.trim().isEmpty ? 'Untitled' : item.name,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        color: desktopTheme.textPrimary,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    if (subtitle.trim().isNotEmpty) ...[
                      const SizedBox(height: 5),
                      Text(
                        subtitle,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          color: desktopTheme.textMuted,
                          fontSize: 12,
                        ),
                      ),
                    ],
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  String? _imageUrl() {
    final currentAccess = access;
    if (currentAccess == null || !item.hasImage) return null;
    return currentAccess.adapter.imageUrl(
      currentAccess.auth,
      itemId: item.id,
      imageType: imageType,
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
        child: Text(
          title.trim().isEmpty ? 'No Poster' : title,
          maxLines: 2,
          overflow: TextOverflow.ellipsis,
          textAlign: TextAlign.center,
          style: TextStyle(
            color: desktopTheme.textMuted,
            fontWeight: FontWeight.w500,
            fontSize: 12,
          ),
        ),
      ),
    );
  }
}

class _TypePill extends StatelessWidget {
  const _TypePill({required this.label});

  final String label;

  @override
  Widget build(BuildContext context) {
    return DecoratedBox(
      decoration: BoxDecoration(
        color: Colors.black.withValues(alpha: 0.58),
        borderRadius: BorderRadius.circular(999),
        border: Border.all(color: Colors.white.withValues(alpha: 0.22)),
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
        child: Text(
          label,
          style: const TextStyle(
            color: Colors.white,
            fontSize: 11,
            fontWeight: FontWeight.w600,
          ),
        ),
      ),
    );
  }
}
