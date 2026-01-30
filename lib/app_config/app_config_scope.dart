import 'package:flutter/widgets.dart';

import 'app_config.dart';

class AppConfigScope extends InheritedWidget {
  const AppConfigScope({
    super.key,
    required this.config,
    required super.child,
  });

  final AppConfig config;

  static AppConfig of(BuildContext context) {
    final scope = context.dependOnInheritedWidgetOfExactType<AppConfigScope>();
    assert(scope != null, 'AppConfigScope not found in widget tree.');
    return scope!.config;
  }

  @override
  bool updateShouldNotify(AppConfigScope oldWidget) => oldWidget.config != config;
}

