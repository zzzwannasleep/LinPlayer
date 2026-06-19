import 'package:flutter/material.dart';
import '../../utils/media_helpers.dart';

/// 动态背景包装器 — 确保内容文字在背景上始终可读。
///
/// 关键：亮度由 [backgroundColor] 的真实亮度推导，而非写死 dark：
/// 深色背景 → 浅色字（走暗色 Material），浅色背景 → 深色字（走亮色 Material）。
/// 这样浅色模式（背景为浅色）下文字自动变深、不再看不清。
///
/// 同时设置五维：
/// 1. [Theme] `brightness` — 让 Material 组件走对应明暗路径
/// 2. [Theme] `colorScheme` — 基于品牌色生成对应 variant，确保 surface/onSurface 正确
/// 3. [Theme] `textTheme.apply()` — 让显式读取主题颜色的 widget 拿到前景色
/// 4. [Theme] `iconTheme` — 让 Icon/IconButton 图标可见
/// 5. [DefaultTextStyle.merge] — 让不含显式颜色的 [Text] widget 继承前景色
class DynamicBackground extends StatelessWidget {
  final Color backgroundColor;
  final Widget child;

  /// 是否用 [backgroundColor] 填充 scaffold 背景。设为 false 时背景透明，
  /// 让下层壁纸图透出（亮度/前景色仍按 [backgroundColor] 推导）。
  final bool opaque;

  const DynamicBackground({
    required this.backgroundColor,
    required this.child,
    this.opaque = true,
    super.key,
  });

  @override
  Widget build(BuildContext context) {
    final parentTheme = Theme.of(context);
    final foregroundColor = readableTextColorForBackground(backgroundColor);
    // 深色就用浅色字、浅色就用深色字：亮度由背景实际亮度决定。
    final brightness = backgroundColor.computeLuminance() < 0.32
        ? Brightness.dark
        : Brightness.light;
    final scheme = ColorScheme.fromSeed(
      seedColor: parentTheme.colorScheme.primary,
      brightness: brightness,
    );
    final scaffoldColor = opaque ? backgroundColor : Colors.transparent;
    return DefaultTextStyle.merge(
      style: TextStyle(color: foregroundColor),
      child: Theme(
        data: parentTheme.copyWith(
          brightness: brightness,
          colorScheme: scheme,
          scaffoldBackgroundColor: scaffoldColor,
          cardTheme: parentTheme.cardTheme.copyWith(color: scheme.surface),
          textTheme: parentTheme.textTheme.apply(
                bodyColor: foregroundColor,
                displayColor: foregroundColor,
              ),
          iconTheme: parentTheme.iconTheme.copyWith(
                color: foregroundColor,
              ),
          appBarTheme: parentTheme.appBarTheme.copyWith(
                backgroundColor: opaque ? backgroundColor : Colors.transparent,
                foregroundColor: foregroundColor,
                titleTextStyle: parentTheme.appBarTheme.titleTextStyle?.copyWith(
                  color: foregroundColor,
                ),
              ),
        ),
        child: child,
      ),
    );
  }
}
