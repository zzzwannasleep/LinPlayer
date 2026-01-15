import 'package:dynamic_color/dynamic_color.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_displaymode/flutter_displaymode.dart';
import 'package:media_kit/media_kit.dart';
import 'package:package_info_plus/package_info_plus.dart';

import 'home_page.dart';
import 'server_page.dart';
import 'services/emby_api.dart';
import 'state/app_state.dart';
import 'src/ui/app_theme.dart';
import 'src/ui/app_icon_service.dart';
import 'src/ui/ui_scale.dart';

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

  // Best-effort: request the highest refresh rate on Android devices.
  if (!kIsWeb && defaultTargetPlatform == TargetPlatform.android) {
    try {
      await FlutterDisplayMode.setHighRefreshRate();
    } catch (_) {}
  }
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
              key: ValueKey<String>('nav:${appState.activeServerId ?? 'none'}'),
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
              builder: (context, child) {
                if (child == null) return const SizedBox.shrink();

                final scale = context.uiScale;
                if (scale == 1.0) return child;

                EdgeInsetsGeometry? scaleInsets(EdgeInsetsGeometry? insets) {
                  if (insets == null) return null;
                  final resolved = insets.resolve(Directionality.of(context));
                  return EdgeInsets.fromLTRB(
                    resolved.left * scale,
                    resolved.top * scale,
                    resolved.right * scale,
                    resolved.bottom * scale,
                  );
                }

                final theme = Theme.of(context);
                final scaledTheme = theme.copyWith(
                  iconTheme: theme.iconTheme.copyWith(
                    size: (theme.iconTheme.size ?? 24) * scale,
                  ),
                  appBarTheme: theme.appBarTheme.copyWith(
                    toolbarHeight:
                        (theme.appBarTheme.toolbarHeight ?? kToolbarHeight) *
                            scale,
                  ),
                  navigationBarTheme: theme.navigationBarTheme.copyWith(
                    height: (theme.navigationBarTheme.height ?? 80) * scale,
                  ),
                  listTileTheme: theme.listTileTheme.copyWith(
                    contentPadding:
                        scaleInsets(theme.listTileTheme.contentPadding),
                    horizontalTitleGap:
                        theme.listTileTheme.horizontalTitleGap == null
                            ? null
                            : theme.listTileTheme.horizontalTitleGap! * scale,
                    minVerticalPadding:
                        theme.listTileTheme.minVerticalPadding == null
                            ? null
                            : theme.listTileTheme.minVerticalPadding! * scale,
                  ),
                  chipTheme: theme.chipTheme.copyWith(
                    padding: scaleInsets(theme.chipTheme.padding),
                    labelPadding: scaleInsets(theme.chipTheme.labelPadding),
                  ),
                  inputDecorationTheme: theme.inputDecorationTheme.copyWith(
                    contentPadding:
                        scaleInsets(theme.inputDecorationTheme.contentPadding),
                  ),
                  dividerTheme: theme.dividerTheme.copyWith(
                    thickness: theme.dividerTheme.thickness == null
                        ? null
                        : theme.dividerTheme.thickness! * scale,
                    space: theme.dividerTheme.space == null
                        ? null
                        : theme.dividerTheme.space! * scale,
                    indent: theme.dividerTheme.indent == null
                        ? null
                        : theme.dividerTheme.indent! * scale,
                    endIndent: theme.dividerTheme.endIndent == null
                        ? null
                        : theme.dividerTheme.endIndent! * scale,
                  ),
                );

                final mediaQuery = MediaQuery.of(context);
                const probe = 14.0;
                final userScale = mediaQuery.textScaler.scale(probe) / probe;
                final textScaler = TextScaler.linear(userScale * scale);

                return MediaQuery(
                  data: mediaQuery.copyWith(textScaler: textScaler),
                  child: Theme(data: scaledTheme, child: child),
                );
              },
              home: isLoggedIn
                  ? HomePage(appState: appState)
                  : ServerPage(appState: appState),
            );
          },
        );
      },
    );
  }
}
