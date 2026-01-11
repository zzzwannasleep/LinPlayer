import 'package:flutter/material.dart';
import 'package:media_kit/media_kit.dart';

import 'login_page.dart';
import 'home_page.dart';
import 'state/app_state.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  // Ensure native media backends (mpv) are ready before any player is created.
  MediaKit.ensureInitialized();
  final appState = AppState();
  await appState.loadFromStorage();
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
        final isLoggedIn = appState.token != null;
        const seed = Colors.blue;
        return MaterialApp(
          title: 'LinPlayer',
          debugShowCheckedModeBanner: false,
          themeMode: ThemeMode.system,
          theme: ThemeData(
            useMaterial3: true,
            colorScheme: ColorScheme.fromSeed(seedColor: seed, brightness: Brightness.light),
            visualDensity: VisualDensity.adaptivePlatformDensity,
          ),
          darkTheme: ThemeData(
            useMaterial3: true,
            colorScheme: ColorScheme.fromSeed(seedColor: seed, brightness: Brightness.dark),
            visualDensity: VisualDensity.adaptivePlatformDensity,
          ),
          home: isLoggedIn ? HomePage(appState: appState) : LoginPage(appState: appState),
        );
      },
    );
  }
}
