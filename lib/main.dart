import 'package:flutter/material.dart';

import 'domain_list_page.dart';
import 'login_page.dart';
import 'state/app_state.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
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
        return MaterialApp(
          title: 'LinPlayer',
          debugShowCheckedModeBanner: false,
          theme: ThemeData.dark().copyWith(
            primaryColor: Colors.blue,
            visualDensity: VisualDensity.adaptivePlatformDensity,
            colorScheme: const ColorScheme.dark().copyWith(
              primary: Colors.blue,
              secondary: Colors.blueAccent,
            ),
          ),
          home: isLoggedIn
              ? DomainListPage(appState: appState)
              : LoginPage(appState: appState),
        );
      },
    );
  }
}
