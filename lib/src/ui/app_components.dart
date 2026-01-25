import 'dart:math' as math;

import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';

import '../../services/cover_cache_manager.dart';
import '../../services/emby_api.dart';
import '../../state/preferences.dart';
import 'app_style.dart';
import 'frosted_card.dart';
import 'rating_badge.dart';

AppStyle _styleOf(BuildContext context) =>
    Theme.of(context).extension<AppStyle>() ?? const AppStyle();

class AppPanel extends StatelessWidget {
  const AppPanel({
    super.key,
    required this.child,
    this.padding,
    this.enableBlur = true,
  });

  final Widget child;
  final EdgeInsetsGeometry? padding;
  final bool enableBlur;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final style = _styleOf(context);
    final radius = BorderRadius.circular(style.panelRadius);
    final content = Padding(padding: padding ?? EdgeInsets.zero, child: child);

    switch (style.template) {
      case UiTemplate.candyGlass:
      case UiTemplate.washiWatercolor:
        return FrostedCard(
          enableBlur: enableBlur,
          padding: padding,
          child: child,
        );
      case UiTemplate.stickerJournal:
        return ClipRRect(
          borderRadius: radius,
          child: DecoratedBox(
            decoration: BoxDecoration(
              color: scheme.surfaceContainerHigh.withValues(
                alpha: scheme.brightness == Brightness.dark ? 0.92 : 0.96,
              ),
              borderRadius: radius,
              border: Border.all(
                color: scheme.secondary.withValues(
                  alpha: scheme.brightness == Brightness.dark ? 0.35 : 0.55,
                ),
                width: style.borderWidth,
              ),
              boxShadow: [
                BoxShadow(
                  color: scheme.shadow.withValues(
                    alpha: scheme.brightness == Brightness.dark ? 0.28 : 0.12,
                  ),
                  blurRadius: 18,
                  offset: const Offset(0, 10),
                ),
              ],
            ),
            child: content,
          ),
        );
      case UiTemplate.neonHud:
        return ClipRRect(
          borderRadius: radius,
          child: DecoratedBox(
            decoration: BoxDecoration(
              color: scheme.surfaceContainerHigh.withValues(
                alpha: scheme.brightness == Brightness.dark ? 0.78 : 0.92,
              ),
              borderRadius: radius,
              border: Border.all(
                color: scheme.primary.withValues(
                  alpha: scheme.brightness == Brightness.dark ? 0.60 : 0.75,
                ),
                width: style.borderWidth + 0.4,
              ),
              boxShadow: [
                BoxShadow(
                  color: scheme.primary.withValues(
                    alpha: scheme.brightness == Brightness.dark ? 0.22 : 0.14,
                  ),
                  blurRadius: 24,
                  spreadRadius: 1,
                ),
              ],
            ),
            child: content,
          ),
        );
      case UiTemplate.pixelArcade:
        return ClipRRect(
          borderRadius: radius,
          child: DecoratedBox(
            decoration: BoxDecoration(
              color: scheme.surfaceContainerHigh,
              borderRadius: radius,
              border: Border.all(
                color: scheme.secondary.withValues(
                  alpha: scheme.brightness == Brightness.dark ? 0.55 : 0.72,
                ),
                width: style.borderWidth + 0.8,
              ),
            ),
            child: content,
          ),
        );
      case UiTemplate.mangaStoryboard:
        return ClipRRect(
          borderRadius: radius,
          child: DecoratedBox(
            decoration: BoxDecoration(
              color: scheme.surface,
              borderRadius: radius,
              border: Border.all(
                color: scheme.onSurface.withValues(
                  alpha: scheme.brightness == Brightness.dark ? 0.55 : 0.80,
                ),
                width: style.borderWidth + 1.0,
              ),
            ),
            child: content,
          ),
        );
      case UiTemplate.minimalCovers:
      case UiTemplate.proTool:
        return Card(
          margin: EdgeInsets.zero,
          child: content,
        );
    }
  }
}

class MediaLabelBadge extends StatelessWidget {
  const MediaLabelBadge({super.key, required this.text});

  final String text;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final style = _styleOf(context);
    final isDark = scheme.brightness == Brightness.dark;

    final (Color bg, Color fg, BorderSide border) = switch (style.template) {
      UiTemplate.neonHud => (
          scheme.surface.withValues(alpha: isDark ? 0.40 : 0.55),
          scheme.onSurface,
          BorderSide(
            color: scheme.primary.withValues(alpha: isDark ? 0.65 : 0.80),
            width: style.borderWidth,
          ),
        ),
      UiTemplate.pixelArcade => (
          scheme.surface.withValues(alpha: isDark ? 0.55 : 0.75),
          scheme.onSurface,
          BorderSide(
            color: scheme.secondary.withValues(alpha: isDark ? 0.65 : 0.80),
            width: style.borderWidth + 0.4,
          ),
        ),
      UiTemplate.mangaStoryboard => (
          scheme.surface.withValues(alpha: isDark ? 0.55 : 0.80),
          scheme.onSurface,
          BorderSide(
            color: scheme.onSurface.withValues(alpha: isDark ? 0.60 : 0.85),
            width: style.borderWidth + 0.6,
          ),
        ),
      _ => (
          Colors.black.withValues(alpha: 0.55),
          Colors.white,
          BorderSide.none,
        ),
    };

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 3),
      decoration: BoxDecoration(
        color: bg,
        borderRadius: BorderRadius.circular(8),
        border: border == BorderSide.none ? null : Border.fromBorderSide(border),
      ),
      child: Text(
        text,
        style: theme.textTheme.labelSmall?.copyWith(
              color: fg,
              fontWeight: FontWeight.w700,
            ) ??
            TextStyle(
              color: fg,
              fontSize: 10,
              fontWeight: FontWeight.w700,
            ),
      ),
    );
  }
}

class MediaPosterTile extends StatelessWidget {
  const MediaPosterTile({
    super.key,
    required this.title,
    required this.imageUrl,
    required this.onTap,
    this.year,
    this.rating,
    this.badgeText,
    this.topRightBadge,
    this.titleMaxLines = 1,
  });

  final String title;
  final String? imageUrl;
  final VoidCallback onTap;
  final String? year;
  final double? rating;
  final String? badgeText;
  final Widget? topRightBadge;
  final int titleMaxLines;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final style = _styleOf(context);
    final isDark = scheme.brightness == Brightness.dark;

    final posterRadius = switch (style.template) {
      UiTemplate.pixelArcade => 8.0,
      UiTemplate.neonHud => 10.0,
      UiTemplate.mangaStoryboard => 6.0,
      UiTemplate.proTool => 10.0,
      _ => 12.0,
    };

    final borderWidth = switch (style.template) {
      UiTemplate.pixelArcade => style.borderWidth + 0.8,
      UiTemplate.mangaStoryboard => style.borderWidth + 1.0,
      UiTemplate.neonHud => style.borderWidth + 0.4,
      _ => style.borderWidth,
    };

    final borderColor = switch (style.template) {
      UiTemplate.neonHud =>
        scheme.primary.withValues(alpha: isDark ? 0.65 : 0.80),
      UiTemplate.pixelArcade =>
        scheme.secondary.withValues(alpha: isDark ? 0.60 : 0.80),
      UiTemplate.mangaStoryboard =>
        scheme.onSurface.withValues(alpha: isDark ? 0.60 : 0.85),
      UiTemplate.stickerJournal =>
        scheme.secondary.withValues(alpha: isDark ? 0.35 : 0.55),
      UiTemplate.proTool => scheme.outlineVariant.withValues(
          alpha: isDark ? 0.45 : 0.65,
        ),
      _ => scheme.outlineVariant.withValues(alpha: isDark ? 0.38 : 0.55),
    };

    final shadowColor = switch (style.template) {
      UiTemplate.neonHud =>
        scheme.primary.withValues(alpha: isDark ? 0.28 : 0.16),
      UiTemplate.stickerJournal =>
        scheme.shadow.withValues(alpha: isDark ? 0.28 : 0.14),
      UiTemplate.candyGlass =>
        scheme.shadow.withValues(alpha: isDark ? 0.22 : 0.12),
      UiTemplate.washiWatercolor =>
        scheme.shadow.withValues(alpha: isDark ? 0.18 : 0.10),
      _ => Colors.transparent,
    };

    final framePainter = switch (style.template) {
      UiTemplate.neonHud => _HudFramePainter(
          color: borderColor.withValues(alpha: isDark ? 0.9 : 1.0),
          width: math.max(1.0, borderWidth),
        ),
      UiTemplate.pixelArcade => _PixelFramePainter(
          color: borderColor,
          width: math.max(1.2, borderWidth),
        ),
      _ => null,
    };

    final image = imageUrl != null
        ? CachedNetworkImage(
            imageUrl: imageUrl!,
            cacheManager: CoverCacheManager.instance,
            httpHeaders: {'User-Agent': EmbyApi.userAgent},
            fit: BoxFit.cover,
            placeholder: (_, __) => const ColoredBox(color: Colors.black12),
            errorWidget: (_, __, ___) =>
                const ColoredBox(color: Colors.black26),
          )
        : const ColoredBox(color: Colors.black26, child: Icon(Icons.image));

    final badge = (badgeText ?? '').trim();

    final poster = DecoratedBox(
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(posterRadius),
        border: Border.all(color: borderColor, width: borderWidth),
        boxShadow: shadowColor == Colors.transparent
            ? null
            : [
                BoxShadow(
                  color: shadowColor,
                  blurRadius: 18,
                  offset: const Offset(0, 10),
                ),
              ],
      ),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(posterRadius),
        child: Stack(
          fit: StackFit.expand,
          children: [
            image,
            if (style.template == UiTemplate.stickerJournal) ...[
              _TapeDecoration(color: scheme.secondaryContainer),
            ],
            if (framePainter != null)
              Positioned.fill(
                child: IgnorePointer(
                  child: CustomPaint(painter: framePainter),
                ),
              ),
            if (rating != null || badge.isNotEmpty)
              Positioned(
                left: 6,
                top: 6,
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    if (rating != null) RatingBadge(rating: rating!),
                    if (rating != null && badge.isNotEmpty)
                      const SizedBox(width: 6),
                    if (badge.isNotEmpty) MediaLabelBadge(text: badge),
                  ],
                ),
              ),
            if (topRightBadge != null)
              Positioned(
                right: 6,
                top: 6,
                child: topRightBadge!,
              ),
          ],
        ),
      ),
    );

    return InkWell(
      borderRadius: BorderRadius.circular(posterRadius),
      onTap: onTap,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          Expanded(child: poster),
          const SizedBox(height: 6),
          Text(
            title,
            style: theme.textTheme.bodySmall?.copyWith(
              fontWeight: FontWeight.w700,
              letterSpacing:
                  style.template == UiTemplate.neonHud ? 0.15 : null,
            ),
            textAlign: TextAlign.center,
            maxLines: math.max(1, titleMaxLines),
            overflow: TextOverflow.ellipsis,
          ),
          if ((year ?? '').trim().isNotEmpty) ...[
            const SizedBox(height: 2),
            Text(
              year!.trim(),
              style: theme.textTheme.labelSmall?.copyWith(
                color: scheme.onSurfaceVariant,
                fontWeight: FontWeight.w600,
                letterSpacing:
                    style.template == UiTemplate.neonHud ? 0.25 : null,
              ),
              textAlign: TextAlign.center,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ],
        ],
      ),
    );
  }
}

class MediaBackdropTile extends StatelessWidget {
  const MediaBackdropTile({
    super.key,
    required this.title,
    required this.imageUrl,
    required this.onTap,
    this.onLongPress,
    this.subtitle,
    this.badgeText,
  });

  final String title;
  final String? subtitle;
  final String imageUrl;
  final String? badgeText;
  final VoidCallback onTap;
  final VoidCallback? onLongPress;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final style = _styleOf(context);
    final isDark = scheme.brightness == Brightness.dark;

    final radius = switch (style.template) {
      UiTemplate.pixelArcade => 10.0,
      UiTemplate.neonHud => 12.0,
      UiTemplate.mangaStoryboard => 10.0,
      _ => 14.0,
    };

    final borderWidth = switch (style.template) {
      UiTemplate.pixelArcade => style.borderWidth + 0.8,
      UiTemplate.mangaStoryboard => style.borderWidth + 1.0,
      UiTemplate.neonHud => style.borderWidth + 0.4,
      _ => style.borderWidth,
    };

    final borderColor = switch (style.template) {
      UiTemplate.neonHud =>
        scheme.primary.withValues(alpha: isDark ? 0.65 : 0.80),
      UiTemplate.pixelArcade =>
        scheme.secondary.withValues(alpha: isDark ? 0.60 : 0.80),
      UiTemplate.mangaStoryboard =>
        scheme.onSurface.withValues(alpha: isDark ? 0.60 : 0.85),
      UiTemplate.stickerJournal =>
        scheme.secondary.withValues(alpha: isDark ? 0.35 : 0.55),
      UiTemplate.proTool => scheme.outlineVariant.withValues(
          alpha: isDark ? 0.45 : 0.65,
        ),
      _ => scheme.outlineVariant.withValues(alpha: isDark ? 0.38 : 0.55),
    };

    final framePainter = switch (style.template) {
      UiTemplate.neonHud => _HudFramePainter(
          color: borderColor.withValues(alpha: isDark ? 0.9 : 1.0),
          width: math.max(1.0, borderWidth),
        ),
      UiTemplate.pixelArcade => _PixelFramePainter(
          color: borderColor,
          width: math.max(1.2, borderWidth),
        ),
      _ => null,
    };

    final image = CachedNetworkImage(
      imageUrl: imageUrl,
      cacheManager: CoverCacheManager.instance,
      httpHeaders: {'User-Agent': EmbyApi.userAgent},
      fit: BoxFit.cover,
      placeholder: (_, __) => const ColoredBox(
        color: Colors.black12,
        child: Center(child: Icon(Icons.image_outlined)),
      ),
      errorWidget: (_, __, ___) => const ColoredBox(
        color: Colors.black26,
        child: Center(child: Icon(Icons.broken_image_outlined)),
      ),
    );

    final badge = (badgeText ?? '').trim();

    final cover = DecoratedBox(
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(radius),
        border: Border.all(color: borderColor, width: borderWidth),
      ),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(radius),
        child: Stack(
          fit: StackFit.expand,
          children: [
            image,
            if (framePainter != null)
              Positioned.fill(
                child: IgnorePointer(child: CustomPaint(painter: framePainter)),
              ),
            if (badge.isNotEmpty)
              Positioned(left: 8, top: 8, child: MediaLabelBadge(text: badge)),
          ],
        ),
      ),
    );

    return InkWell(
      borderRadius: BorderRadius.circular(radius),
      onTap: onTap,
      onLongPress: onLongPress,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          AspectRatio(aspectRatio: 16 / 9, child: cover),
          const SizedBox(height: 6),
          Text(
            title,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: theme.textTheme.bodyMedium?.copyWith(
              fontWeight: FontWeight.w800,
              letterSpacing:
                  style.template == UiTemplate.neonHud ? 0.15 : null,
            ),
          ),
          if ((subtitle ?? '').trim().isNotEmpty) ...[
            const SizedBox(height: 2),
            Text(
              subtitle!.trim(),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: theme.textTheme.labelSmall?.copyWith(
                color: scheme.onSurfaceVariant,
                fontWeight: FontWeight.w600,
              ),
            ),
          ],
        ],
      ),
    );
  }
}

class _TapeDecoration extends StatelessWidget {
  const _TapeDecoration({required this.color});

  final Color color;

  @override
  Widget build(BuildContext context) {
    return Positioned.fill(
      child: IgnorePointer(
        child: Stack(
          children: [
            Positioned(
              left: 8,
              top: 6,
              child: Transform.rotate(
                angle: -0.18,
                child: Container(
                  width: 34,
                  height: 10,
                  decoration: BoxDecoration(
                    color: color.withValues(alpha: 0.55),
                    borderRadius: BorderRadius.circular(4),
                  ),
                ),
              ),
            ),
            Positioned(
              right: 10,
              bottom: 10,
              child: Transform.rotate(
                angle: 0.15,
                child: Container(
                  width: 40,
                  height: 10,
                  decoration: BoxDecoration(
                    color: color.withValues(alpha: 0.45),
                    borderRadius: BorderRadius.circular(4),
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _HudFramePainter extends CustomPainter {
  const _HudFramePainter({required this.color, required this.width});

  final Color color;
  final double width;

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = width
      ..strokeCap = StrokeCap.square;

    final inset = width / 2;
    final r = Rect.fromLTWH(inset, inset, size.width - width, size.height - width);
    const corner = 14.0;
    const leg = 18.0;

    void cornerL(Offset o, Offset dx, Offset dy) {
      canvas.drawLine(o, o + dx * leg, paint);
      canvas.drawLine(o, o + dy * leg, paint);
    }

    cornerL(r.topLeft, const Offset(1, 0), const Offset(0, 1));
    cornerL(r.topRight, const Offset(-1, 0), const Offset(0, 1));
    cornerL(r.bottomLeft, const Offset(1, 0), const Offset(0, -1));
    cornerL(r.bottomRight, const Offset(-1, 0), const Offset(0, -1));

    // Subtle inner line.
    final innerPaint = Paint()
      ..color = color.withValues(alpha: 0.35)
      ..style = PaintingStyle.stroke
      ..strokeWidth = math.max(1, width - 0.4);
    final inner = r.deflate(corner);
    canvas.drawRRect(
      RRect.fromRectAndRadius(inner, const Radius.circular(10)),
      innerPaint,
    );
  }

  @override
  bool shouldRepaint(covariant _HudFramePainter oldDelegate) =>
      oldDelegate.color != color || oldDelegate.width != width;
}

class _PixelFramePainter extends CustomPainter {
  const _PixelFramePainter({required this.color, required this.width});

  final Color color;
  final double width;

  @override
  void paint(Canvas canvas, Size size) {
    final w = width.clamp(1.0, 4.0);
    final paint = Paint()
      ..color = color
      ..style = PaintingStyle.fill;

    const px = 6.0;
    void block(double x, double y) {
      canvas.drawRect(Rect.fromLTWH(x, y, px, px), paint);
    }

    // Four corners.
    block(4, 4);
    block(size.width - px - 4, 4);
    block(4, size.height - px - 4);
    block(size.width - px - 4, size.height - px - 4);

    // Edges (a few random-ish blocks).
    final topY = 4 + w;
    final bottomY = size.height - px - 4 - w;
    for (int i = 0; i < 3; i++) {
      final x = 18.0 + i * 22.0;
      if (x + px < size.width - 18) {
        block(x, topY);
        block(size.width - x - px, bottomY);
      }
    }
  }

  @override
  bool shouldRepaint(covariant _PixelFramePainter oldDelegate) =>
      oldDelegate.color != color || oldDelegate.width != width;
}
