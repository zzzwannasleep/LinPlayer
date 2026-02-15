import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:lin_player_prefs/lin_player_prefs.dart';
import 'package:lin_player_state/lin_player_state.dart';

import '../../player_screen.dart';
import '../../player_screen_exo.dart';
import '../../server_page.dart';
import '../../settings_page.dart';
import '../widgets/desktop_cinematic_shell.dart';

class DesktopServerPage extends StatefulWidget {
  const DesktopServerPage({super.key, required this.appState});

  final AppState appState;

  @override
  State<DesktopServerPage> createState() => _DesktopServerPageState();
}

class _DesktopServerPageState extends State<DesktopServerPage> {
  int _index = 0; // 0 servers, 1 local, 2 settings

  static const _tabs = <DesktopCinematicTab>[
    DesktopCinematicTab(label: 'Servers', icon: Icons.storage_outlined),
    DesktopCinematicTab(label: 'Local', icon: Icons.folder_open_outlined),
    DesktopCinematicTab(label: 'Settings', icon: Icons.settings_outlined),
  ];

  @override
  Widget build(BuildContext context) {
    final useExoCore = !kIsWeb &&
        defaultTargetPlatform == TargetPlatform.android &&
        widget.appState.playerCore == PlayerCore.exo;

    final pages = [
      ServerPage(
        appState: widget.appState,
        showInlineLocalEntry: false,
      ),
      useExoCore
          ? ExoPlayerScreen(appState: widget.appState)
          : PlayerScreen(appState: widget.appState),
      SettingsPage(appState: widget.appState),
    ];

    return DesktopCinematicShell(
      title: 'Workspace',
      tabs: _tabs,
      selectedIndex: _index,
      onSelected: (index) => setState(() => _index = index),
      trailingLabel: widget.appState.activeServer?.name ?? 'No active server',
      trailingIcon: Icons.dns_outlined,
      child: IndexedStack(
        index: _index,
        children: pages,
      ),
    );
  }
}
