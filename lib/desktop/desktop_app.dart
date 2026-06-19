import 'package:fluent_ui/fluent_ui.dart' as fluent;
import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:macos_ui/macos_ui.dart' as macos;
import '../core/providers/app_providers.dart';
import '../core/services/font_service.dart';
import '../core/theme/app_theme.dart';
import 'platform/desktop_ui_style.dart';
import 'routes/desktop_router.dart';
import 'shell/desktop_nav_model.dart';
import 'theme/desktop_native_theme.dart';
import 'utils/desktop_shortcuts.dart';
import 'utils/desktop_smooth_scroll.dart';
import 'window/desktop_window_chrome.dart';

const _desktopFontFamily = 'Microsoft YaHei UI';
const _desktopFontFallback = <String>[
  'Microsoft YaHei',
  'Segoe UI',
  'PingFang SC',
  'Hiragino Sans GB',
];

const _supportedLocales = <Locale>[
  Locale('zh', 'CN'),
  Locale('en'),
];

const _localizationsDelegates = <LocalizationsDelegate<dynamic>>[
  GlobalMaterialLocalizations.delegate,
  GlobalWidgetsLocalizations.delegate,
  GlobalCupertinoLocalizations.delegate,
];

/// 桌面端应用入口。
///
/// 按平台选择原生外观：
/// - Windows -> [fluent.FluentApp]（仿 WinUI）
/// - macOS   -> [macos.MacosApp]（仿 AppKit）
/// - Linux   -> [MaterialApp]
///
/// 内容层（各业务页面）仍为 Material 实现，因此在 Fluent/Macos 根下需要补充
/// Material 的 Theme / ScaffoldMessenger / Material 祖先，见 [_wrapContent]。
class LinPlayerDesktopApp extends ConsumerWidget {
  const LinPlayerDesktopApp({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    switch (desktopUiStyle) {
      case DesktopUiStyle.fluent:
        return const _FluentDesktopApp();
      case DesktopUiStyle.macos:
        return const _MacosDesktopApp();
      case DesktopUiStyle.material:
        return const _MaterialDesktopApp();
    }
  }
}

ThemeMode _themeModeOf(ThemeModeOption option) => switch (option) {
      ThemeModeOption.light => ThemeMode.light,
      ThemeModeOption.dark => ThemeMode.dark,
      ThemeModeOption.system => ThemeMode.system,
    };

/// 为非 Material 应用根（Fluent / Macos）补齐 Material 运行所需环境，
/// 并叠加标题栏与快捷键。
Widget _wrapContent({
  required Brightness brightness,
  required Widget child,
  bool addTitleBar = true,
  String? customFontFamily,
}) {
  final materialTheme = brightness == Brightness.dark
      ? _desktopTheme(AppTheme.darkTheme, customFontFamily)
      : _desktopTheme(AppTheme.lightTheme, customFontFamily);

  Widget content = child;
  if (addTitleBar) {
    content = Column(
      children: [
        // 沉浸模式（播放页全屏）下隐藏自绘标题栏，实现真正全屏。
        Consumer(
          builder: (context, ref, _) {
            if (ref.watch(desktopImmersiveModeProvider)) {
              return const SizedBox.shrink();
            }
            return AppTitleBar(
              brightness: brightness,
              backgroundColor: materialTheme.scaffoldBackgroundColor,
              leading: _SidebarToggleButton(brightness: brightness),
            );
          },
        ),
        Expanded(child: child),
      ],
    );
  }

  return Theme(
    data: materialTheme,
    child: Material(
      type: MaterialType.transparency,
      child: ScaffoldMessenger(
        child: ScrollConfiguration(
          behavior: const _DesktopAppScrollBehavior(),
          child: DesktopShortcutsWrapper(child: content),
        ),
      ),
    ),
  );
}

// ---------------------------------------------------------------------------
// Windows / Fluent
// ---------------------------------------------------------------------------
class _FluentDesktopApp extends ConsumerWidget {
  const _FluentDesktopApp();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final router = ref.watch(desktopRouterProvider);
    final themeMode = ref.watch(themeModeProvider);
    final locale = ref.watch(localeProvider);
    final fontFamily = ref.watch(customAppFontPathProvider).isEmpty
        ? null
        : FontService.appFontFamily;

    return fluent.FluentApp.router(
      title: 'Linplayer',
      debugShowCheckedModeBanner: false,
      theme: buildFluentTheme(Brightness.light),
      darkTheme: buildFluentTheme(Brightness.dark),
      themeMode: _themeModeOf(themeMode),
      locale: locale,
      supportedLocales: _supportedLocales,
      localizationsDelegates: const [
        ..._localizationsDelegates,
        fluent.FluentLocalizations.delegate,
      ],
      routerConfig: router,
      builder: (context, child) {
        final brightness = fluent.FluentTheme.of(context).brightness;
        return _wrapContent(
          brightness: brightness,
          customFontFamily: fontFamily,
          child: child ?? const SizedBox.shrink(),
        );
      },
    );
  }
}

// ---------------------------------------------------------------------------
// macOS / macos_ui
// ---------------------------------------------------------------------------
class _MacosDesktopApp extends ConsumerWidget {
  const _MacosDesktopApp();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final router = ref.watch(desktopRouterProvider);
    final themeMode = ref.watch(themeModeProvider);
    final locale = ref.watch(localeProvider);
    final fontFamily = ref.watch(customAppFontPathProvider).isEmpty
        ? null
        : FontService.appFontFamily;

    return macos.MacosApp.router(
      title: 'Linplayer',
      debugShowCheckedModeBanner: false,
      theme: buildMacosTheme(Brightness.light),
      darkTheme: buildMacosTheme(Brightness.dark),
      themeMode: _themeModeOf(themeMode),
      locale: locale,
      supportedLocales: _supportedLocales,
      localizationsDelegates: _localizationsDelegates,
      routerConfig: router,
      builder: (context, child) {
        final brightness = macos.MacosTheme.of(context).brightness;
        return _wrapContent(
          brightness: brightness,
          customFontFamily: fontFamily,
          child: child ?? const SizedBox.shrink(),
        );
      },
    );
  }
}

// ---------------------------------------------------------------------------
// Linux / Material
// ---------------------------------------------------------------------------
class _MaterialDesktopApp extends ConsumerWidget {
  const _MaterialDesktopApp();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final router = ref.watch(desktopRouterProvider);
    final themeMode = ref.watch(themeModeProvider);
    final locale = ref.watch(localeProvider);
    final fontFamily = ref.watch(customAppFontPathProvider).isEmpty
        ? null
        : FontService.appFontFamily;

    return MaterialApp.router(
      title: 'Linplayer',
      debugShowCheckedModeBanner: false,
      theme: _desktopTheme(AppTheme.lightTheme, fontFamily),
      darkTheme: _desktopTheme(AppTheme.darkTheme, fontFamily),
      locale: locale,
      localizationsDelegates: _localizationsDelegates,
      supportedLocales: _supportedLocales,
      scrollBehavior: const _DesktopAppScrollBehavior(),
      themeMode: _themeModeOf(themeMode),
      routerConfig: router,
      builder: (context, child) {
        final brightness = Theme.of(context).brightness;
        return DesktopShortcutsWrapper(
          child: Column(
            children: [
              // 沉浸模式（播放页全屏）下隐藏自绘标题栏，实现真正全屏。
              Consumer(
                builder: (context, ref, _) {
                  if (ref.watch(desktopImmersiveModeProvider)) {
                    return const SizedBox.shrink();
                  }
                  return AppTitleBar(
                    brightness: brightness,
                    backgroundColor: Theme.of(context).scaffoldBackgroundColor,
                    leading: _SidebarToggleButton(brightness: brightness),
                  );
                },
              ),
              Expanded(child: child!),
            ],
          ),
        );
      },
    );
  }
}

/// 标题栏里的侧边栏汉堡按钮：切换 [sidebarCollapsedProvider]，
/// 三端外壳据此收起/展开侧边栏。放在标题栏可保证任何显示模式下都可点击。
class _SidebarToggleButton extends ConsumerStatefulWidget {
  final Brightness brightness;

  const _SidebarToggleButton({required this.brightness});

  @override
  ConsumerState<_SidebarToggleButton> createState() =>
      _SidebarToggleButtonState();
}

class _SidebarToggleButtonState extends ConsumerState<_SidebarToggleButton> {
  bool _hovered = false;

  @override
  Widget build(BuildContext context) {
    final isDark = widget.brightness == Brightness.dark;
    final fg = isDark
        ? Colors.white.withValues(alpha: 0.85)
        : Colors.black.withValues(alpha: 0.75);
    final hoverBg = isDark
        ? Colors.white.withValues(alpha: 0.10)
        : Colors.black.withValues(alpha: 0.06);

    return MouseRegion(
      cursor: SystemMouseCursors.click,
      onEnter: (_) => setState(() => _hovered = true),
      onExit: (_) => setState(() => _hovered = false),
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: () => ref.read(sidebarCollapsedProvider.notifier).state =
            !ref.read(sidebarCollapsedProvider),
        child: Container(
          width: 34,
          height: 28,
          decoration: BoxDecoration(
            color: _hovered ? hoverBg : Colors.transparent,
            borderRadius: BorderRadius.circular(6),
          ),
          child: Icon(Icons.menu_rounded, size: 16, color: fg),
        ),
      ),
    );
  }
}

ThemeData _desktopTheme(ThemeData base, [String? customFamily]) {
  TextStyle? s(TextStyle? style,
          {double? fontSize,
          double? height,
          FontWeight? fontWeight,
          double? letterSpacing}) =>
      _desktopTextStyle(style,
          fontSize: fontSize,
          height: height,
          fontWeight: fontWeight,
          letterSpacing: letterSpacing,
          customFamily: customFamily);

  final textTheme = base.textTheme.copyWith(
    displayLarge: s(base.textTheme.displayLarge),
    displayMedium: s(base.textTheme.displayMedium),
    displaySmall: s(
      base.textTheme.displaySmall,
      fontSize: 30,
      height: 1.08,
      fontWeight: FontWeight.w700,
      letterSpacing: -0.4,
    ),
    headlineLarge: s(base.textTheme.headlineLarge),
    headlineMedium: s(base.textTheme.headlineMedium),
    headlineSmall: s(
      base.textTheme.headlineSmall,
      fontSize: 20,
      height: 1.15,
      fontWeight: FontWeight.w700,
      letterSpacing: -0.2,
    ),
    titleLarge: s(
      base.textTheme.titleLarge,
      fontSize: 18,
      height: 1.18,
      fontWeight: FontWeight.w700,
    ),
    titleMedium: s(
      base.textTheme.titleMedium,
      fontSize: 16,
      height: 1.22,
      fontWeight: FontWeight.w700,
    ),
    titleSmall: s(
      base.textTheme.titleSmall,
      fontSize: 14,
      height: 1.3,
      fontWeight: FontWeight.w600,
    ),
    bodyLarge: s(
      base.textTheme.bodyLarge,
      fontSize: 16,
      height: 1.45,
      fontWeight: FontWeight.w600,
    ),
    bodyMedium: s(
      base.textTheme.bodyMedium,
      fontSize: 14,
      height: 1.42,
      fontWeight: FontWeight.w600,
    ),
    bodySmall: s(
      base.textTheme.bodySmall,
      fontSize: 12,
      height: 1.36,
      fontWeight: FontWeight.w500,
    ),
    labelLarge: s(
      base.textTheme.labelLarge,
      fontSize: 14,
      height: 1.2,
      fontWeight: FontWeight.w700,
    ),
    labelMedium: s(
      base.textTheme.labelMedium,
      fontSize: 12,
      height: 1.2,
      fontWeight: FontWeight.w600,
    ),
    labelSmall: s(
      base.textTheme.labelSmall,
      fontSize: 11,
      height: 1.18,
      fontWeight: FontWeight.w500,
    ),
  );

  return base.copyWith(
    scaffoldBackgroundColor: base.scaffoldBackgroundColor,
    textTheme: textTheme,
    primaryTextTheme: textTheme,
    appBarTheme: base.appBarTheme.copyWith(
      titleTextStyle: textTheme.titleLarge,
    ),
  );
}

TextStyle? _desktopTextStyle(
  TextStyle? style, {
  double? fontSize,
  double? height,
  FontWeight? fontWeight,
  double? letterSpacing,
  String? customFamily,
}) {
  return style?.copyWith(
    // 用户自定义字体优先；桌面默认字体退为 fallback 之首，保证中文/缺字回退。
    fontFamily: customFamily ?? _desktopFontFamily,
    fontFamilyFallback: customFamily != null
        ? const [_desktopFontFamily, ..._desktopFontFallback]
        : _desktopFontFallback,
    fontSize: fontSize,
    height: height,
    fontWeight: fontWeight,
    letterSpacing: letterSpacing,
  );
}

class _DesktopAppScrollBehavior extends MaterialScrollBehavior {
  const _DesktopAppScrollBehavior();

  @override
  ScrollPhysics getScrollPhysics(BuildContext context) {
    return const ClampingScrollPhysics();
  }

  @override
  Widget buildScrollbar(
    BuildContext context,
    Widget child,
    ScrollableDetails details,
  ) {
    final controller = details.controller;
    if (controller is DesktopSmoothScrollController) {
      return Scrollbar(
        controller: controller,
        thumbVisibility: true,
        interactive: true,
        child: child,
      );
    }
    return super.buildScrollbar(context, child, details);
  }
}
