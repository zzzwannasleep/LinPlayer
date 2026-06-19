import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../core/providers/app_providers.dart';
import '../core/services/font_service.dart';
import '../core/theme/app_theme.dart';
import '../ui/widgets/common/app_update_gate.dart';
import 'theme/tv_metrics.dart';
import 'theme/tv_theme.dart';
import 'routes/tv_router.dart';

/// TV 端应用入口
/// 强制深色模式，TV 专属主题
class LinPlayerTvApp extends ConsumerWidget {
  const LinPlayerTvApp({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final locale = ref.watch(localeProvider);
    final fontFamily = ref.watch(customAppFontPathProvider).isEmpty
        ? null
        : FontService.appFontFamily;

    return MaterialApp.router(
      title: 'LinPlayer TV',
      debugShowCheckedModeBanner: false,
      theme: TvTheme.theme,
      darkTheme: TvTheme.theme,
      themeMode: ThemeMode.dark, // TV 端强制深色模式
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
      // 在 MaterialApp 内部（MediaQuery 可用）按屏幕尺寸应用响应式主题，
      // 使对话框/输入框/默认文本等主题默认值也随 Pad 屏幕等比缩放。
      builder: (context, child) {
        return Theme(
          data: AppTheme.withFontFamily(
              TvTheme.themeFor(context.tv), fontFamily),
          child: AppUpdateGate(child: child ?? const SizedBox.shrink()),
        );
      },
      routerConfig: tvRouter,
    );
  }
}
