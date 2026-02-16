import 'package:flutter/material.dart';

import '../theme/desktop_theme_extension.dart';

class DesktopActionButtonGroup extends StatelessWidget {
  const DesktopActionButtonGroup({
    super.key,
    this.onPlay,
    this.onToggleFavorite,
    this.isFavorite = false,
  });

  final VoidCallback? onPlay;
  final VoidCallback? onToggleFavorite;
  final bool isFavorite;

  @override
  Widget build(BuildContext context) {
    final desktopTheme = DesktopThemeExtension.of(context);

    return Wrap(
      spacing: 12,
      runSpacing: 12,
      children: [
        FilledButton.icon(
          onPressed: onPlay,
          style: FilledButton.styleFrom(
            backgroundColor: desktopTheme.accent,
            foregroundColor: Colors.white,
            padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 14),
          ),
          icon: const Icon(Icons.play_arrow_rounded),
          label: const Text(
            'Play',
            style: TextStyle(fontWeight: FontWeight.w600),
          ),
        ),
        OutlinedButton.icon(
          onPressed: onToggleFavorite,
          style: OutlinedButton.styleFrom(
            foregroundColor: desktopTheme.textPrimary,
            side: BorderSide(color: desktopTheme.border),
            backgroundColor: desktopTheme.surfaceElevated,
            padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 14),
          ),
          icon: Icon(
            isFavorite ? Icons.favorite_rounded : Icons.favorite_border_rounded,
            color: isFavorite ? const Color(0xFFFF6480) : null,
          ),
          label: Text(
            isFavorite ? 'Favorited' : 'Favorite',
            style: const TextStyle(fontWeight: FontWeight.w600),
          ),
        ),
      ],
    );
  }
}
