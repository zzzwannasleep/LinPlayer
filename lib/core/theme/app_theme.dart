import 'package:flutter/material.dart';
import 'app_colors.dart';

/// Material 3 主题配置
class AppTheme {
  AppTheme._();
  
  static const double borderRadiusSmall = 4;
  static const double borderRadiusMedium = 8;
  static const double borderRadiusLarge = 12;
  static const double borderRadiusXLarge = 16;
  static const double borderRadiusXXLarge = 24;
  
  static const double spacingUnit = 4;
  static const double spacing1 = 4;
  static const double spacing2 = 8;
  static const double spacing3 = 12;
  static const double spacing4 = 16;
  static const double spacing5 = 24;
  static const double spacing6 = 32;
  static const double spacing7 = 48;
  static const double spacing8 = 64;
  
  static const double textSizeXS = 12;
  static const double textSizeSM = 14;
  static const double textSizeBase = 16;
  static const double textSizeLG = 18;
  static const double textSizeXL = 20;
  static const double textSize2XL = 24;
  static const double textSize3XL = 28;
  static const double textSize4XL = 32;
  static const double textSize5XL = 40;
  static const double textSize6XL = 48;

  static const TextTheme _lightTextTheme = TextTheme(
    displayLarge: TextStyle(
      fontSize: textSize6XL,
      fontWeight: FontWeight.bold,
      color: AppColors.lightText,
    ),
    displayMedium: TextStyle(
      fontSize: textSize5XL,
      fontWeight: FontWeight.bold,
      color: AppColors.lightText,
    ),
    displaySmall: TextStyle(
      fontSize: textSize4XL,
      fontWeight: FontWeight.bold,
      color: AppColors.lightText,
    ),
    headlineLarge: TextStyle(
      fontSize: textSize3XL,
      fontWeight: FontWeight.w600,
      color: AppColors.lightText,
    ),
    headlineMedium: TextStyle(
      fontSize: textSize2XL,
      fontWeight: FontWeight.w600,
      color: AppColors.lightText,
    ),
    headlineSmall: TextStyle(
      fontSize: textSizeXL,
      fontWeight: FontWeight.w600,
      color: AppColors.lightText,
    ),
    titleLarge: TextStyle(
      fontSize: textSizeLG,
      fontWeight: FontWeight.w600,
      color: AppColors.lightText,
    ),
    titleMedium: TextStyle(
      fontSize: textSizeBase,
      fontWeight: FontWeight.w600,
      color: AppColors.lightText,
    ),
    titleSmall: TextStyle(
      fontSize: textSizeSM,
      fontWeight: FontWeight.w500,
      color: AppColors.lightText,
    ),
    bodyLarge: TextStyle(fontSize: textSizeBase, color: AppColors.lightText),
    bodyMedium: TextStyle(fontSize: textSizeSM, color: AppColors.lightText),
    bodySmall: TextStyle(
      fontSize: textSizeXS,
      color: AppColors.lightTextSecondary,
    ),
  );

  static const TextTheme _darkTextTheme = TextTheme(
    displayLarge: TextStyle(
      fontSize: textSize6XL,
      fontWeight: FontWeight.bold,
      color: AppColors.darkText,
    ),
    displayMedium: TextStyle(
      fontSize: textSize5XL,
      fontWeight: FontWeight.bold,
      color: AppColors.darkText,
    ),
    displaySmall: TextStyle(
      fontSize: textSize4XL,
      fontWeight: FontWeight.bold,
      color: AppColors.darkText,
    ),
    headlineLarge: TextStyle(
      fontSize: textSize3XL,
      fontWeight: FontWeight.w600,
      color: AppColors.darkText,
    ),
    headlineMedium: TextStyle(
      fontSize: textSize2XL,
      fontWeight: FontWeight.w600,
      color: AppColors.darkText,
    ),
    headlineSmall: TextStyle(
      fontSize: textSizeXL,
      fontWeight: FontWeight.w600,
      color: AppColors.darkText,
    ),
    titleLarge: TextStyle(
      fontSize: textSizeLG,
      fontWeight: FontWeight.w600,
      color: AppColors.darkText,
    ),
    titleMedium: TextStyle(
      fontSize: textSizeBase,
      fontWeight: FontWeight.w600,
      color: AppColors.darkText,
    ),
    titleSmall: TextStyle(
      fontSize: textSizeSM,
      fontWeight: FontWeight.w500,
      color: AppColors.darkText,
    ),
    bodyLarge: TextStyle(fontSize: textSizeBase, color: AppColors.darkText),
    bodyMedium: TextStyle(fontSize: textSizeSM, color: AppColors.darkText),
    bodySmall: TextStyle(
      fontSize: textSizeXS,
      color: AppColors.darkTextSecondary,
    ),
  );

  /// 把自定义字体家族名套用到一份 [ThemeData] 的全部文本主题上。
  /// [family] 为空时原样返回（用系统默认字体）。供三端在构建 MaterialApp 时调用。
  static ThemeData withFontFamily(ThemeData base, String? family) {
    if (family == null || family.isEmpty) return base;
    return base.copyWith(
      textTheme: base.textTheme.apply(fontFamily: family),
      primaryTextTheme: base.primaryTextTheme.apply(fontFamily: family),
    );
  }

  static ThemeData get lightTheme {
    return ThemeData(
      useMaterial3: true,
      brightness: Brightness.light,
      colorScheme: const ColorScheme.light(
        primary: AppColors.brand,
        onPrimary: Colors.white,
        secondary: AppColors.brandLight,
        onSecondary: Colors.white,
        surface: AppColors.lightSurface,
        onSurface: AppColors.lightText,
        error: AppColors.error,
        onError: Colors.white,
      ),
      scaffoldBackgroundColor: AppColors.lightBackground,
      cardTheme: CardThemeData(
        elevation: 0,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(borderRadiusLarge),
        ),
        color: AppColors.lightSurface,
      ),
      appBarTheme: const AppBarTheme(
        elevation: 0,
        centerTitle: true,
        backgroundColor: AppColors.lightBackground,
        foregroundColor: AppColors.lightText,
        titleTextStyle: TextStyle(
          fontSize: textSizeLG,
          fontWeight: FontWeight.w600,
          color: AppColors.lightText,
        ),
      ),
      bottomNavigationBarTheme: const BottomNavigationBarThemeData(
        backgroundColor: AppColors.lightSurface,
        selectedItemColor: AppColors.brand,
        unselectedItemColor: AppColors.lightTextSecondary,
        type: BottomNavigationBarType.fixed,
        elevation: 0,
      ),
      dividerTheme: const DividerThemeData(
        color: AppColors.lightDivider,
        thickness: 1,
      ),
      textTheme: _lightTextTheme,
      scrollbarTheme: ScrollbarThemeData(
        thickness: WidgetStateProperty.all(8),
        radius: const Radius.circular(4),
        thumbColor: WidgetStateProperty.all(const Color(0xFF5B8DEF).withValues(alpha: 0.3)),
        trackColor: WidgetStateProperty.all(Colors.transparent),
      ),
    );
  }

  static ThemeData get darkTheme {
    return ThemeData(
      useMaterial3: true,
      brightness: Brightness.dark,
      colorScheme: const ColorScheme.dark(
        primary: AppColors.brandLight,
        onPrimary: Colors.black,
        secondary: AppColors.brand,
        onSecondary: Colors.white,
        surface: AppColors.darkSurface,
        onSurface: AppColors.darkText,
        error: AppColors.error,
        onError: Colors.white,
      ),
      scaffoldBackgroundColor: AppColors.darkBackground,
      cardTheme: CardThemeData(
        elevation: 0,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(borderRadiusLarge),
        ),
        color: AppColors.darkSurface,
      ),
      appBarTheme: const AppBarTheme(
        elevation: 0,
        centerTitle: true,
        backgroundColor: AppColors.darkBackground,
        foregroundColor: AppColors.darkText,
        titleTextStyle: TextStyle(
          fontSize: textSizeLG,
          fontWeight: FontWeight.w600,
          color: AppColors.darkText,
        ),
      ),
      bottomNavigationBarTheme: const BottomNavigationBarThemeData(
        backgroundColor: AppColors.darkSurface,
        selectedItemColor: AppColors.brandLight,
        unselectedItemColor: AppColors.darkTextSecondary,
        type: BottomNavigationBarType.fixed,
        elevation: 0,
      ),
      dividerTheme: const DividerThemeData(
        color: AppColors.darkDivider,
        thickness: 1,
      ),
      textTheme: _darkTextTheme,
      scrollbarTheme: ScrollbarThemeData(
        thickness: WidgetStateProperty.all(8),
        radius: const Radius.circular(4),
        thumbColor: WidgetStateProperty.all(const Color(0xFF5B8DEF).withValues(alpha: 0.4)),
        trackColor: WidgetStateProperty.all(Colors.transparent),
      ),
    );
  }
}
