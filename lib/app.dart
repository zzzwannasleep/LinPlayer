import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'core/providers/app_providers.dart';
import 'core/services/font_service.dart';
import 'core/theme/app_theme.dart';
import 'routes/app_router.dart';
import 'ui/widgets/common/app_update_gate.dart';

class LinPlayerApp extends ConsumerWidget {
  const LinPlayerApp({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final router = ref.watch(appRouterProvider);
    final themeMode = ref.watch(themeModeProvider);
    final locale = ref.watch(localeProvider);
    // 自定义全局字体：路径非空即套用已加载的字体家族。
    final fontFamily = ref.watch(customAppFontPathProvider).isEmpty
        ? null
        : FontService.appFontFamily;

    return MaterialApp.router(
      title: 'Linplayer',
      debugShowCheckedModeBanner: false,
      theme: AppTheme.withFontFamily(AppTheme.lightTheme, fontFamily),
      darkTheme: AppTheme.withFontFamily(AppTheme.darkTheme, fontFamily),
      locale: locale,
      localizationsDelegates: const [
        GlobalMaterialLocalizations.delegate,
        GlobalWidgetsLocalizations.delegate,
        GlobalCupertinoLocalizations.delegate,
      ],
      supportedLocales: const [
        Locale('zh', 'CN'),
        Locale('en'),
      ],
      themeMode: switch (themeMode) {
        ThemeModeOption.light => ThemeMode.light,
        ThemeModeOption.dark => ThemeMode.dark,
        ThemeModeOption.system => ThemeMode.system,
      },
      routerConfig: router,
      builder: (context, child) =>
          AppUpdateGate(child: child ?? const SizedBox.shrink()),
    );
  }
}
