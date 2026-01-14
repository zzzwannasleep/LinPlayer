import 'package:dynamic_color/dynamic_color.dart';
import 'package:flutter/material.dart';
import 'package:media_kit/media_kit.dart';
import 'package:package_info_plus/package_info_plus.dart';

import 'home_page.dart';
import 'server_page.dart';
import 'services/emby_api.dart';
import 'state/app_state.dart';
import 'src/ui/app_theme.dart';
import 'src/ui/app_icon_service.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  // Ensure native media backends (mpv) are ready before any player is created.
  MediaKit.ensureInitialized();

  try {
    final info = await PackageInfo.fromPlatform();
    EmbyApi.setAppVersion('${info.version}+${info.buildNumber}');
  } catch (_) {
    // PackageInfo is best-effort; keep default version if unavailable.
  }

  final appState = AppState();
  await appState.loadFromStorage();
  // Best-effort: keep launcher icon in sync with settings (Android only).
  // ignore: unawaited_futures
  AppIconService.setIconId(appState.appIconId);
  runApp(LinPlayerApp(appState: appState));
}

class LinPlayerApp extends StatelessWidget {
  const LinPlayerApp({super.key, required this.appState});

  final AppState appState;

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: appState,
      builder: (context, _) {
        final isLoggedIn = appState.hasActiveServer;
        return DynamicColorBuilder(
          builder: (lightDynamic, darkDynamic) {
            final useDynamic = appState.useDynamicColor;
            return MaterialApp(
              title: 'LinPlayer',
              debugShowCheckedModeBanner: false,
              themeMode: appState.themeMode,
              theme: AppTheme.light(
                dynamicScheme: useDynamic ? lightDynamic : null,
                seed: appState.themeSeedColor,
                secondarySeed: appState.themeSecondarySeedColor,
              ),
              darkTheme: AppTheme.dark(
                dynamicScheme: useDynamic ? darkDynamic : null,
                seed: appState.themeSeedColor,
                secondarySeed: appState.themeSecondarySeedColor,
              ),
              home: isLoggedIn ? HomePage(appState: appState) : ServerPage(appState: appState),
            );
          },
        );
      },
    );
  }
}
