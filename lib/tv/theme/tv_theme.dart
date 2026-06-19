import 'package:flutter/material.dart';
import 'tv_design_tokens.dart';
import 'tv_metrics.dart';

/// TV 端主题
/// TV 端强制深色模式，所有组件基于 TvDesignTokens。
///
/// 主题中的尺寸（字号 / 间距 / 圆角）通过 [TvMetrics] 按屏幕响应式缩放，
/// 这样 Pad 上由主题默认值渲染的组件（对话框、输入框、默认 Text 等）
/// 也会随屏幕等比缩小，而不会沿用 TV 基准的大号尺寸。
class TvTheme {
  TvTheme._();

  /// TV 基准主题（不缩放）。运行时请用 [themeFor] 传入响应式度量。
  static ThemeData get theme => themeFor(TvMetrics.base);

  /// 按当前屏幕度量构建主题。
  static ThemeData themeFor(TvMetrics m) => ThemeData(
        useMaterial3: true,
        brightness: Brightness.dark,
        scaffoldBackgroundColor: TvDesignTokens.background,
        colorScheme: const ColorScheme.dark(
          primary: TvDesignTokens.brand,
          onPrimary: TvDesignTokens.textPrimary,
          secondary: TvDesignTokens.brandLight,
          onSecondary: TvDesignTokens.textPrimary,
          surface: TvDesignTokens.surface,
          onSurface: TvDesignTokens.textPrimary,
          error: TvDesignTokens.error,
          onError: TvDesignTokens.textPrimary,
        ),
        textTheme: _textTheme(m),
        appBarTheme: _appBarTheme(m),
        cardTheme: _cardTheme(m),
        dividerTheme: _dividerTheme(m),
        iconTheme: _iconTheme(m),
        elevatedButtonTheme: _elevatedButtonTheme(m),
        textButtonTheme: _textButtonTheme(m),
        outlinedButtonTheme: _outlinedButtonTheme(m),
        inputDecorationTheme: _inputDecorationTheme(m),
        scrollbarTheme: _scrollbarTheme(m),
      );

  static TextTheme _textTheme(TvMetrics m) => TextTheme(
        displayLarge: TextStyle(
          fontSize: m.fontSizeXxl,
          fontWeight: TvDesignTokens.fontWeightBold,
          color: TvDesignTokens.textPrimary,
          height: TvDesignTokens.lineHeightTight,
        ),
        displayMedium: TextStyle(
          fontSize: m.fontSizeXl,
          fontWeight: TvDesignTokens.fontWeightBold,
          color: TvDesignTokens.textPrimary,
          height: TvDesignTokens.lineHeightTight,
        ),
        titleLarge: TextStyle(
          fontSize: m.fontSizeLg,
          fontWeight: TvDesignTokens.fontWeightMedium,
          color: TvDesignTokens.textPrimary,
          height: TvDesignTokens.lineHeightNormal,
        ),
        titleMedium: TextStyle(
          fontSize: m.fontSizeMd,
          fontWeight: TvDesignTokens.fontWeightMedium,
          color: TvDesignTokens.textPrimary,
          height: TvDesignTokens.lineHeightNormal,
        ),
        bodyLarge: TextStyle(
          fontSize: m.fontSizeMd,
          fontWeight: TvDesignTokens.fontWeightRegular,
          color: TvDesignTokens.textPrimary,
          height: TvDesignTokens.lineHeightNormal,
        ),
        bodyMedium: TextStyle(
          fontSize: m.fontSizeSm,
          fontWeight: TvDesignTokens.fontWeightRegular,
          color: TvDesignTokens.textSecondary,
          height: TvDesignTokens.lineHeightNormal,
        ),
        bodySmall: TextStyle(
          fontSize: m.fontSizeXs,
          fontWeight: TvDesignTokens.fontWeightRegular,
          color: TvDesignTokens.textDisabled,
          height: TvDesignTokens.lineHeightNormal,
        ),
        labelLarge: TextStyle(
          fontSize: m.fontSizeSm,
          fontWeight: TvDesignTokens.fontWeightMedium,
          color: TvDesignTokens.textPrimary,
          height: TvDesignTokens.lineHeightNormal,
        ),
      );

  static AppBarTheme _appBarTheme(TvMetrics m) => AppBarTheme(
        backgroundColor: Colors.transparent,
        elevation: 0,
        centerTitle: false,
        titleTextStyle: TextStyle(
          fontSize: m.fontSizeXl,
          fontWeight: TvDesignTokens.fontWeightMedium,
          color: TvDesignTokens.textPrimary,
        ),
        iconTheme: IconThemeData(
          color: TvDesignTokens.textPrimary,
          size: m.s(32),
        ),
      );

  static CardThemeData _cardTheme(TvMetrics m) => CardThemeData(
        color: TvDesignTokens.surface,
        elevation: 0,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.all(Radius.circular(m.posterRadius)),
        ),
      );

  static DividerThemeData _dividerTheme(TvMetrics m) => DividerThemeData(
        color: TvDesignTokens.divider,
        thickness: 1,
        space: m.spacingMd,
      );

  static IconThemeData _iconTheme(TvMetrics m) => IconThemeData(
        color: TvDesignTokens.textPrimary,
        size: m.s(32),
      );

  static ElevatedButtonThemeData _elevatedButtonTheme(TvMetrics m) =>
      ElevatedButtonThemeData(
        style: ElevatedButton.styleFrom(
          backgroundColor: TvDesignTokens.brand,
          foregroundColor: TvDesignTokens.textPrimary,
          padding: EdgeInsets.symmetric(
            horizontal: m.spacingLg,
            vertical: m.spacingSm,
          ),
          textStyle: TextStyle(
            fontSize: m.fontSizeMd,
            fontWeight: TvDesignTokens.fontWeightMedium,
          ),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(m.posterRadius),
          ),
        ),
      );

  static TextButtonThemeData _textButtonTheme(TvMetrics m) =>
      TextButtonThemeData(
        style: TextButton.styleFrom(
          foregroundColor: TvDesignTokens.brand,
          padding: EdgeInsets.symmetric(
            horizontal: m.spacingMd,
            vertical: m.spacingSm,
          ),
          textStyle: TextStyle(
            fontSize: m.fontSizeMd,
            fontWeight: TvDesignTokens.fontWeightMedium,
          ),
        ),
      );

  static OutlinedButtonThemeData _outlinedButtonTheme(TvMetrics m) =>
      OutlinedButtonThemeData(
        style: OutlinedButton.styleFrom(
          foregroundColor: TvDesignTokens.textPrimary,
          side: const BorderSide(color: TvDesignTokens.divider, width: 2),
          padding: EdgeInsets.symmetric(
            horizontal: m.spacingLg,
            vertical: m.spacingSm,
          ),
          textStyle: TextStyle(
            fontSize: m.fontSizeMd,
            fontWeight: TvDesignTokens.fontWeightMedium,
          ),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(m.posterRadius),
          ),
        ),
      );

  static InputDecorationTheme _inputDecorationTheme(TvMetrics m) =>
      InputDecorationTheme(
        filled: true,
        fillColor: TvDesignTokens.surface,
        border: OutlineInputBorder(
          borderRadius: BorderRadius.all(Radius.circular(m.posterRadius)),
          borderSide: const BorderSide(color: TvDesignTokens.divider),
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.all(Radius.circular(m.posterRadius)),
          borderSide: const BorderSide(color: TvDesignTokens.divider),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.all(Radius.circular(m.posterRadius)),
          borderSide: const BorderSide(color: TvDesignTokens.brand, width: 2),
        ),
        contentPadding: EdgeInsets.symmetric(
          horizontal: m.spacingMd,
          vertical: m.spacingSm,
        ),
        hintStyle: TextStyle(
          fontSize: m.fontSizeMd,
          color: TvDesignTokens.textDisabled,
        ),
        labelStyle: TextStyle(
          fontSize: m.fontSizeMd,
          color: TvDesignTokens.textSecondary,
        ),
      );

  static ScrollbarThemeData _scrollbarTheme(TvMetrics m) => ScrollbarThemeData(
        thickness: WidgetStatePropertyAll(m.s(8.0)),
        radius: Radius.circular(m.s(4)),
        thumbColor: const WidgetStatePropertyAll(TvDesignTokens.textDisabled),
        trackColor: const WidgetStatePropertyAll(Colors.transparent),
      );
}
