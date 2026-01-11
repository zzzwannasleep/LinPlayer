import 'package:flutter_test/flutter_test.dart';

import 'package:lin_player/main.dart';
import 'package:lin_player/state/app_state.dart';

void main() {
  testWidgets('Shows login screen by default', (WidgetTester tester) async {
    final appState = AppState();
    await tester.pumpWidget(LinPlayerApp(appState: appState));
    expect(find.text('登录'), findsWidgets); // 标题+按钮都会出现“登录”
  });
}
