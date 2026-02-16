import 'dart:io';
import 'dart:ui';

import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:lin_player_state/lin_player_state.dart';

class DesktopUnifiedBackground extends StatelessWidget {
  const DesktopUnifiedBackground({
    super.key,
    required this.appState,
    this.baseColor,
  });

  final AppState appState;
  final Color? baseColor;

  static Color baseColorForBrightness(Brightness brightness) {
    return brightness == Brightness.dark
        ? const Color(0xFF080B11)
        : const Color(0xFFF3F5FA);
  }

  @override
  Widget build(BuildContext context) {
    final resolvedBaseColor =
        baseColor ?? baseColorForBrightness(Theme.of(context).brightness);
    final opacity = appState.desktopBackgroundOpacity.clamp(0.0, 1.0).toDouble();
    final blur = appState.desktopBackgroundBlurSigma.clamp(0.0, 30.0).toDouble();
    final image = _buildCustomImage(appState.desktopBackgroundImage);

    Widget? overlay = image;
    if (overlay != null) {
      if (opacity < 1.0) {
        overlay = Opacity(opacity: opacity, child: overlay);
      }
      if (blur > 0.0) {
        overlay = ImageFiltered(
          imageFilter: ImageFilter.blur(sigmaX: blur, sigmaY: blur),
          child: overlay,
        );
      }
    }

    return Stack(
      fit: StackFit.expand,
      children: [
        ColoredBox(color: resolvedBaseColor),
        if (overlay != null) Positioned.fill(child: overlay),
      ],
    );
  }

  Widget? _buildCustomImage(String rawPathOrUrl) {
    final value = rawPathOrUrl.trim();
    if (value.isEmpty) return null;
    final uri = Uri.tryParse(value);
    final isNetwork = uri != null && (uri.scheme == 'http' || uri.scheme == 'https');

    if (isNetwork) {
      return CachedNetworkImage(
        imageUrl: value,
        fit: BoxFit.cover,
        placeholder: (_, __) => const SizedBox.shrink(),
        errorWidget: (_, __, ___) => const SizedBox.shrink(),
        fadeInDuration: const Duration(milliseconds: 200),
      );
    }

    return Image.file(
      File(value),
      fit: BoxFit.cover,
      errorBuilder: (_, __, ___) => const SizedBox.shrink(),
    );
  }
}
