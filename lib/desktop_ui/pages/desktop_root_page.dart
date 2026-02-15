import 'package:flutter/material.dart';
import 'package:lin_player_core/state/media_server_type.dart';
import 'package:lin_player_state/lin_player_state.dart';

import 'desktop_home_page.dart';
import 'desktop_server_page.dart';
import 'desktop_webdav_home_page.dart';

Widget buildDesktopRootPage({required AppState appState}) {
  final active = appState.activeServer;

  if (active == null || !appState.hasActiveServerProfile) {
    return DesktopServerPage(appState: appState);
  }
  if (active.serverType == MediaServerType.webdav) {
    return DesktopWebDavHomePage(appState: appState);
  }
  if (appState.hasActiveServer) {
    return DesktopHomePage(appState: appState);
  }
  return DesktopServerPage(appState: appState);
}
