import 'dart:io' show Platform;

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/services.dart';

bool canControlSystemUi({required bool isTv}) {
  if (kIsWeb) return false;
  if (isTv) return false;
  return Platform.isAndroid || Platform.isIOS;
}

Future<void> enterImmersiveMode({required bool isTv}) async {
  if (!canControlSystemUi(isTv: isTv)) return;
  try {
    await SystemChrome.setEnabledSystemUIMode(
      SystemUiMode.immersiveSticky,
      overlays: const [],
    );
  } catch (_) {}
}

Future<void> exitImmersiveMode({
  required bool isTv,
  bool resetOrientations = false,
}) async {
  if (!canControlSystemUi(isTv: isTv)) return;
  try {
    await SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
  } catch (_) {}
  if (!resetOrientations) return;
  try {
    await SystemChrome.setPreferredOrientations(const []);
  } catch (_) {}
}
