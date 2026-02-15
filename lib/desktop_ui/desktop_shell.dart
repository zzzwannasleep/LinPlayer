import 'package:flutter/foundation.dart'
    show TargetPlatform, defaultTargetPlatform, kIsWeb;
import 'package:flutter/material.dart';
import 'package:lin_player_state/lin_player_state.dart';

import 'pages/desktop_root_page.dart';

class DesktopShell extends StatelessWidget {
  const DesktopShell({super.key, required this.appState});

  final AppState appState;

  static bool get isDesktopTarget =>
      !kIsWeb &&
      (defaultTargetPlatform == TargetPlatform.windows ||
          defaultTargetPlatform == TargetPlatform.macOS);

  @override
  Widget build(BuildContext context) {
    return buildDesktopRootPage(appState: appState);
  }
}
