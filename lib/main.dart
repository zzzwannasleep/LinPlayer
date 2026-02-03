import 'dart:async';

import 'package:dynamic_color/dynamic_color.dart';
import 'package:flutter/material.dart';
import 'package:media_kit/media_kit.dart';
import 'package:lin_player_core/app_config/app_config.dart';
import 'package:lin_player_core/state/media_server_type.dart';
import 'package:lin_player_server_adapters/lin_player_server_adapters.dart';
import 'package:lin_player_prefs/lin_player_prefs.dart';
import 'package:lin_player_state/lin_player_state.dart';
import 'package:lin_player_ui/lin_player_ui.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'home_page.dart';
import 'server_page.dart';
import 'webdav_home_page.dart';
import 'services/app_update_flow.dart';
import 'services/built_in_proxy/built_in_proxy_service.dart';
import 'services/tv_remote/tv_remote_command_dispatcher.dart';
import 'services/tv_remote/tv_remote_service.dart';
import 'tv/tv_background.dart';
import 'tv/tv_shell.dart';

final GlobalKey<NavigatorState> _rootNavigatorKey = GlobalKey<NavigatorState>();

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  // Ensure native media backends (mpv) are ready before any player is created.
  MediaKit.ensureInitialized();
  await DeviceType.init();

  final appConfig = AppConfig.current;
  ServerApiBootstrap.configure(
    userAgentProduct: appConfig.userAgentProduct,
    defaultClientName: appConfig.displayName,
    appVersion: '1.0.0',
  );

  try {
    final info = await PackageInfo.fromPlatform();
    ServerApiBootstrap.configure(
      userAgentProduct: appConfig.userAgentProduct,
      defaultClientName: appConfig.displayName,
      appVersion: '${info.version}+${info.buildNumber}',
    );
  } catch (_) {
    // PackageInfo is best-effort; keep default version if unavailable.
  }

  final appState = AppState();
  await appState.loadFromStorage();

  TvRemoteCommandDispatcher.instance.bindNavigatorKey(_rootNavigatorKey);

  // Best-effort: request the highest refresh rate on Android devices.
  await HighRefreshRate.apply();
  // Best-effort: keep launcher icon in sync with settings (Android only).
  // ignore: unawaited_futures
  AppIconService.setIconId(appState.appIconId);

  if (DeviceType.isTv && appState.tvRemoteEnabled) {
    unawaited(TvRemoteService.instance.start(appState: appState));
  }
  if (DeviceType.isTv) {
    unawaited(BuiltInProxyService.instance.refresh());
  }
  if (DeviceType.isTv && appState.tvBuiltInProxyEnabled) {
    unawaited(() async {
      try {
        await BuiltInProxyService.instance.start();
      } catch (_) {
        // Best-effort; detailed error is shown in Settings -> TV.
      }
    }());
  }
  runApp(AppConfigScope(
    config: appConfig,
    child: LinPlayerApp(appState: appState),
  ));
}

class LinPlayerApp extends StatefulWidget {
  const LinPlayerApp({super.key, required this.appState});

  final AppState appState;

  @override
  State<LinPlayerApp> createState() => _LinPlayerAppState();
}

class _LinPlayerAppState extends State<LinPlayerApp>
    with WidgetsBindingObserver {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      unawaited(HighRefreshRate.apply(force: true));
    }
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: widget.appState,
      builder: (context, _) {
        final appConfig = AppConfigScope.of(context);
        final appState = widget.appState;
        final active = appState.activeServer;
        final home = DeviceType.isTv
            ? TvShell(appState: appState)
            : switch (active?.serverType) {
                null => ServerPage(appState: appState),
                _ when !appState.hasActiveServerProfile =>
                  ServerPage(appState: appState),
                _ when active!.serverType == MediaServerType.webdav =>
                  WebDavHomePage(appState: appState),
                _ when appState.hasActiveServer => HomePage(appState: appState),
                _ => ServerPage(appState: appState),
              };
        return DynamicColorBuilder(
          builder: (lightDynamic, darkDynamic) {
            final useDynamic = appState.useDynamicColor;
            return MaterialApp(
              navigatorKey: _rootNavigatorKey,
              key: ValueKey<String>('nav:${appState.activeServerId ?? 'none'}'),
              title: appConfig.displayName,
              debugShowCheckedModeBanner: false,
              themeMode: appState.themeMode,
              theme: AppTheme.light(
                dynamicScheme: useDynamic ? lightDynamic : null,
                template: appState.uiTemplate,
                compact: appState.compactMode,
              ),
              darkTheme: AppTheme.dark(
                dynamicScheme: useDynamic ? darkDynamic : null,
                template: appState.uiTemplate,
                compact: appState.compactMode,
              ),
              builder: (context, child) {
                if (child == null) return const SizedBox.shrink();

                final isTv = DeviceType.isTv;

                final scale = (UiScaleScope.autoScaleFor(context) *
                        appState.uiScaleFactor *
                        (isTv ? 0.75 : 1.0))
                    .clamp(0.25, 2.0)
                    .toDouble();

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
                final scaledTheme = scale == 1.0
                    ? theme
                    : theme.copyWith(
                        iconTheme: theme.iconTheme.copyWith(
                          size: (theme.iconTheme.size ?? 24) * scale,
                        ),
                        appBarTheme: theme.appBarTheme.copyWith(
                          toolbarHeight: (theme.appBarTheme.toolbarHeight ??
                                  kToolbarHeight) *
                              scale,
                        ),
                        navigationBarTheme: theme.navigationBarTheme.copyWith(
                          height:
                              (theme.navigationBarTheme.height ?? 80) * scale,
                        ),
                        listTileTheme: theme.listTileTheme.copyWith(
                          contentPadding:
                              scaleInsets(theme.listTileTheme.contentPadding),
                          horizontalTitleGap:
                              theme.listTileTheme.horizontalTitleGap == null
                                  ? null
                                  : theme.listTileTheme.horizontalTitleGap! *
                                      scale,
                          minVerticalPadding:
                              theme.listTileTheme.minVerticalPadding == null
                                  ? null
                                  : theme.listTileTheme.minVerticalPadding! *
                                      scale,
                        ),
                        chipTheme: theme.chipTheme.copyWith(
                          padding: scaleInsets(theme.chipTheme.padding),
                          labelPadding:
                              scaleInsets(theme.chipTheme.labelPadding),
                        ),
                        inputDecorationTheme:
                            theme.inputDecorationTheme.copyWith(
                          contentPadding: scaleInsets(
                              theme.inputDecorationTheme.contentPadding),
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
                final textScaler = scale == 1.0
                    ? mediaQuery.textScaler
                    : TextScaler.linear(userScale * scale);

                final style = scaledTheme.extension<AppStyle>();
                final hasBackdrop = style != null &&
                    style.backgroundIntensity > 0 &&
                    (style.background != AppBackgroundKind.none ||
                        style.pattern != AppPatternKind.none);

                final backgroundIntensity = (!hasBackdrop || isTv)
                    ? 0.0
                    : (appState.enableBlurEffects ? 1.0 : 0.65);

                final tvBackgroundEnabled =
                    isTv && appState.tvBackgroundMode != TvBackgroundMode.none;

                final appChild = isTv
                    ? (tvBackgroundEnabled
                        ? Stack(
                            fit: StackFit.expand,
                            children: [
                              TvBackground(appState: appState),
                              child,
                            ],
                          )
                        : child)
                    : (backgroundIntensity <= 0
                        ? child
                        : Stack(
                            fit: StackFit.expand,
                            children: [
                              GlassBackground(intensity: backgroundIntensity),
                              child,
                            ],
                          ));

                return UiScaleScope(
                  scale: scale,
                  child: MediaQuery(
                    data: mediaQuery.copyWith(textScaler: textScaler),
                    child: Theme(
                      data: scaledTheme,
                      child: AppUpdateAutoChecker(
                        appState: appState,
                        child: appChild,
                      ),
                    ),
                  ),
                );
              },
              home: home,
            );
          },
        );
      },
    );
  }
}
