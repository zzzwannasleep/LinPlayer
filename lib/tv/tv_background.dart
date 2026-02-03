import 'dart:io';

import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:lin_player_prefs/lin_player_prefs.dart';
import 'package:lin_player_state/lin_player_state.dart';

class TvBackground extends StatelessWidget {
  const TvBackground({super.key, required this.appState});

  final AppState appState;

  @override
  Widget build(BuildContext context) {
    final mode = appState.tvBackgroundMode;
    final scheme = Theme.of(context).colorScheme;

    Widget? backdrop;
    switch (mode) {
      case TvBackgroundMode.none:
        backdrop = null;
      case TvBackgroundMode.solidColor:
        backdrop = ColoredBox(color: Color(appState.tvBackgroundColor));
      case TvBackgroundMode.image:
        backdrop = _buildImage(appState.tvBackgroundImage);
      case TvBackgroundMode.randomApi:
        backdrop = _buildRandomApi();
    }

    if (backdrop == null) {
      return const SizedBox.shrink();
    }

    return IgnorePointer(
      child: Stack(
        fit: StackFit.expand,
        children: [
          backdrop,
          DecoratedBox(
            decoration: BoxDecoration(
              gradient: LinearGradient(
                begin: Alignment.topCenter,
                end: Alignment.bottomCenter,
                colors: [
                  Colors.black.withValues(alpha: 0.35),
                  Colors.black.withValues(alpha: 0.55),
                ],
              ),
            ),
          ),
          ColoredBox(color: scheme.surface.withValues(alpha: 0.08)),
        ],
      ),
    );
  }

  Widget _buildRandomApi() {
    final base = appState.tvBackgroundRandomApiUrl.trim();
    if (base.isEmpty) {
      return const ColoredBox(color: Color(0xFF0B0B0B));
    }
    final nonce = appState.tvBackgroundRandomNonce;
    final sep = base.contains('?') ? '&' : '?';
    final url = '$base${sep}t=$nonce';
    return _buildNetworkImage(url);
  }

  Widget _buildImage(String raw) {
    final v = raw.trim();
    if (v.isEmpty) {
      return const ColoredBox(color: Color(0xFF0B0B0B));
    }
    final uri = Uri.tryParse(v);
    if (uri != null && (uri.scheme == 'http' || uri.scheme == 'https')) {
      return _buildNetworkImage(v);
    }
    return Image.file(
      File(v),
      fit: BoxFit.cover,
      errorBuilder: (_, __, ___) => const ColoredBox(color: Color(0xFF0B0B0B)),
    );
  }

  Widget _buildNetworkImage(String url) {
    return CachedNetworkImage(
      imageUrl: url,
      fit: BoxFit.cover,
      fadeInDuration: const Duration(milliseconds: 180),
      fadeOutDuration: const Duration(milliseconds: 120),
      placeholder: (_, __) => const ColoredBox(color: Color(0xFF0B0B0B)),
      errorWidget: (_, __, ___) => const ColoredBox(color: Color(0xFF0B0B0B)),
    );
  }
}
