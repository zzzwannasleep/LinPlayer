import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:lin_player_prefs/lin_player_prefs.dart';
import 'package:lin_player_state/lin_player_state.dart';

import '../../player_screen.dart';
import '../../player_screen_exo.dart';
import '../../settings_page.dart';
import '../../webdav_browser_page.dart';
import '../widgets/desktop_cinematic_shell.dart';

class DesktopWebDavHomePage extends StatefulWidget {
  const DesktopWebDavHomePage({super.key, required this.appState});

  final AppState appState;

  @override
  State<DesktopWebDavHomePage> createState() => _DesktopWebDavHomePageState();
}

class _DesktopWebDavHomePageState extends State<DesktopWebDavHomePage> {
  int _index = 0; // 0 webdav, 1 local, 2 settings

  static const _tabs = <DesktopCinematicTab>[
    DesktopCinematicTab(label: 'WebDAV', icon: Icons.cloud_outlined),
    DesktopCinematicTab(label: 'Local', icon: Icons.folder_open_outlined),
    DesktopCinematicTab(label: 'Settings', icon: Icons.settings_outlined),
  ];

  @override
  Widget build(BuildContext context) {
    final appState = widget.appState;
    final server = appState.activeServer;

    final useExoCore = !kIsWeb &&
        defaultTargetPlatform == TargetPlatform.android &&
        appState.playerCore == PlayerCore.exo;

    final pages = [
      if (server == null)
        const Center(child: Text('No active server'))
      else
        WebDavBrowserPage(appState: appState, server: server),
      useExoCore
          ? ExoPlayerScreen(appState: appState)
          : PlayerScreen(appState: appState),
      SettingsPage(appState: appState),
    ];

    return DesktopCinematicShell(
      title: 'Workspace',
      tabs: _tabs,
      selectedIndex: _index,
      onSelected: (index) => setState(() => _index = index),
      trailingLabel: appState.activeServer?.name ?? 'No active server',
      trailingIcon: Icons.cloud_outlined,
      child: IndexedStack(
        index: _index,
        children: pages,
      ),
    );
  }
}
