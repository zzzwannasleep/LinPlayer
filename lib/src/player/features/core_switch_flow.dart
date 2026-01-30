import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../../../state/app_state.dart';
import '../../../state/local_playback_handoff.dart';
import '../../../state/preferences.dart';

const String _exoOnlyAndroidMessage = 'Exo 内核仅支持 Android';

Future<bool> switchPlayerCoreOrToast({
  required BuildContext context,
  required AppState appState,
  required PlayerCore target,
}) async {
  if (target == PlayerCore.exo &&
      (kIsWeb || defaultTargetPlatform != TargetPlatform.android)) {
    if (context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text(_exoOnlyAndroidMessage)),
      );
    }
    return false;
  }

  await appState.setPlayerCore(target);
  return true;
}

LocalPlaybackHandoff? buildLocalPlaybackHandoffFromPlatformFiles({
  required List<PlatformFile> playlist,
  required int currentIndex,
  required Duration position,
  required bool wasPlaying,
}) {
  final items = playlist
      .where((f) => (f.path ?? '').trim().isNotEmpty)
      .map(
        (f) => LocalPlaybackItem(
          name: f.name,
          path: f.path!.trim(),
          size: f.size,
        ),
      )
      .toList();
  if (items.isEmpty) return null;

  final idx = currentIndex < 0
      ? 0
      : currentIndex >= items.length
          ? items.length - 1
          : currentIndex;

  return LocalPlaybackHandoff(
    playlist: items,
    index: idx,
    position: position,
    wasPlaying: wasPlaying,
  );
}
