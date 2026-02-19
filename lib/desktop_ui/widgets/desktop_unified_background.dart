import 'dart:io';
import 'dart:ui';

import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:lin_player_server_api/network/lin_http_client.dart';
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
    final opacity =
        appState.desktopBackgroundOpacity.clamp(0.0, 1.0).toDouble();
    final blur =
        appState.desktopBackgroundBlurSigma.clamp(0.0, 30.0).toDouble();
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

    if (uri != null && (uri.scheme == 'http' || uri.scheme == 'https')) {
      return CachedNetworkImage(
        imageUrl: value,
        fit: BoxFit.cover,
        httpHeaders: {'User-Agent': LinHttpClientFactory.userAgent},
        placeholder: (_, __) => const SizedBox.shrink(),
        errorWidget: (_, __, ___) => const SizedBox.shrink(),
        fadeInDuration: const Duration(milliseconds: 200),
      );
    }

    if (uri != null && uri.scheme == 'file') {
      final filePath = uri.toFilePath(windows: Platform.isWindows);
      return Image.file(
        File(filePath),
        fit: BoxFit.cover,
        gaplessPlayback: true,
        errorBuilder: (_, __, ___) => const SizedBox.shrink(),
      );
    }

    if (uri == null || !uri.hasScheme) {
      final looksLikeNetwork = _looksLikeNetworkUrlWithoutScheme(value);
      if (looksLikeNetwork) {
        return CachedNetworkImage(
          imageUrl: 'https://$value',
          fit: BoxFit.cover,
          httpHeaders: {'User-Agent': LinHttpClientFactory.userAgent},
          placeholder: (_, __) => const SizedBox.shrink(),
          errorWidget: (_, __, ___) => const SizedBox.shrink(),
          fadeInDuration: const Duration(milliseconds: 200),
        );
      }
    }

    return Image.file(
      File(value),
      fit: BoxFit.cover,
      gaplessPlayback: true,
      errorBuilder: (_, __, ___) => const SizedBox.shrink(),
    );
  }

  bool _looksLikeNetworkUrlWithoutScheme(String value) {
    final v = value.trim();
    if (v.isEmpty) return false;
    if (v.startsWith(r'\\')) return false;
    if (v.startsWith('/') || v.startsWith('~/')) return false;
    if (RegExp(r'^[a-zA-Z]:[\\/]').hasMatch(v)) return false;
    if (v.contains(r'\')) return false;
    if (v.contains(' ')) return false;

    final firstSegment = v.split('/').first;
    if (firstSegment.toLowerCase() == 'localhost') return true;
    return firstSegment.contains('.');
  }
}
