import 'package:flutter/material.dart';
import 'package:media_kit_video/media_kit_video.dart';
import 'package:video_player_android/exo_tracks.dart' as vp_android;

double subtitleBottomPaddingPx(int positionStep) {
  final step = positionStep.clamp(0, 20);
  return (step * 5.0).clamp(0.0, 200.0).toDouble();
}

SubtitleViewConfiguration buildMpvSubtitleViewConfiguration({
  required double fontSize,
  required int positionStep,
  required bool bold,
}) {
  const base = SubtitleViewConfiguration();
  final bottom = subtitleBottomPaddingPx(positionStep);
  return SubtitleViewConfiguration(
    visible: base.visible,
    style: base.style.copyWith(
      fontSize: fontSize.clamp(12.0, 60.0),
      fontWeight: bold ? FontWeight.w600 : FontWeight.normal,
    ),
    textAlign: base.textAlign,
    textScaler: base.textScaler,
    padding: base.padding.copyWith(bottom: bottom),
  );
}

TextStyle buildSubtitleOverlayTextStyle({
  required double fontSize,
  required bool bold,
}) {
  return TextStyle(
    height: 1.4,
    fontSize: fontSize.clamp(12.0, 60.0),
    fontWeight: bold ? FontWeight.w600 : FontWeight.normal,
    color: Colors.white,
    shadows: const [
      Shadow(
        blurRadius: 6,
        offset: Offset(2, 2),
        color: Colors.black,
      ),
    ],
  );
}

Future<void> applyMpvSubtitleOptions({
  required dynamic platform,
  required double delaySeconds,
  required bool assOverrideForce,
}) async {
  try {
    await platform.setProperty('sub-delay', delaySeconds.toStringAsFixed(3));
  } catch (_) {}
  try {
    await platform.setProperty(
      'sub-ass-override',
      assOverrideForce ? 'force' : 'no',
    );
  } catch (_) {}
}

Future<void> applyExoSubtitleOptions({
  required int playerId,
  required double delaySeconds,
  required double fontSize,
  required int positionStep,
  required bool bold,
}) async {
  final api = vp_android.VideoPlayerInstanceApi(
    messageChannelSuffix: playerId.toString(),
  );

  try {
    await api.setSubtitleDelay((delaySeconds * 1000).round());
  } catch (_) {}

  try {
    await api.setSubtitleStyle(
      vp_android.SubtitleStyleMessage(
        fontSize: fontSize.clamp(8.0, 96.0),
        bottomPadding: subtitleBottomPaddingPx(positionStep),
        bold: bold,
      ),
    );
  } catch (_) {}
}
