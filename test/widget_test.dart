import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:lin_player_ui/lin_player_ui.dart';
import 'package:lin_player/main.dart';
import 'package:lin_player_core/app_config/app_config.dart';
import 'package:lin_player_core/state/media_server_type.dart';
import 'package:lin_player_state/app_state.dart';
import 'package:lin_player_state/server_profile.dart';

void main() {
  testWidgets('Shows server screen by default', (WidgetTester tester) async {
    final appState = AppState();
    await tester.pumpWidget(
      AppConfigScope(
        config: AppConfig.current,
        child: LinPlayerApp(appState: appState),
      ),
    );
    expect(find.text('还没有服务器，点右上角“+”添加。'), findsOneWidget);
  });

  testWidgets('Allows passwordless server login', (WidgetTester tester) async {
    final appState = _FakeAppState();
    await tester.pumpWidget(
      AppConfigScope(
        config: AppConfig.current,
        child: LinPlayerApp(appState: appState),
      ),
    );
    expect(find.byTooltip('添加服务器'), findsOneWidget);

    await tester.tap(find.byTooltip('添加服务器'));
    await tester.pumpAndSettle();
    expect(find.text('添加服务器'), findsOneWidget);

    final fields = find.byType(TextFormField);
    // Order in _AddServerSheet: name, remark, host, port, username, password.
    await tester.enterText(fields.at(2), 'emby.example.com');
    await tester.enterText(fields.at(4), 'demo');

    await tester.tap(find.byType(FilledButton));
    await tester.pumpAndSettle();

    expect(find.text('请输入密码'), findsNothing);
    expect(appState.addServerCalled, isTrue);
    expect(appState.lastPassword, '');
  });
}

class _FakeAppState extends AppState {
  bool addServerCalled = false;
  String? lastPassword;

  @override
  Future<void> addServer({
    required String hostOrUrl,
    required String scheme,
    String? port,
    MediaServerType serverType = MediaServerType.emby,
    required String username,
    required String password,
    String? displayName,
    String? remark,
    String? iconUrl,
    List<CustomDomain>? customDomains,
    bool activate = true,
  }) async {
    addServerCalled = true;
    lastPassword = password;
  }
}
