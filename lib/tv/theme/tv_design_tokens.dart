import 'package:flutter/material.dart';
import '../../core/theme/app_colors.dart';

/// TV 端专属设计 Tokens
/// TV 端强制深色模式，所有值基于 TV 设计文档
class TvDesignTokens {
  TvDesignTokens._();

  // === 颜色 ===
  static const Color background = Color(0xFF121212);
  static const Color surface = Color(0xFF1E1E1E);
  static const Color surfaceElevated = Color(0xFF2A2A2A);
  static const Color textPrimary = Color(0xFFFFFFFF);
  static const Color textSecondary = Color(0xFFAAAAAA);
  static const Color textDisabled = Color(0xFF666666);
  static const Color divider = Color(0xFF333333);
  static const Color brand = AppColors.brand;
  static const Color brandLight = AppColors.brandLight;
  static const Color brandDark = AppColors.brandDark;
  static const Color error = AppColors.error;
  static const Color success = AppColors.success;

  // === 焦点状态 ===
  // 选中/聚焦改为「微微放大 + 品牌色蓝色覆盖」，不再用白色描边大放大（过丑）。
  static const Color focusBorder = Color(0xFFFFFFFF);
  static const Color focusGlow = Color(0x4D5B8DEF); // 品牌色 30% 透明度
  static const double focusScale = 1.04;
  static const double focusBorderWidth = 3.0;
  static const double focusGlowBlur = 20.0;
  /// 聚焦时叠加在卡片上的品牌色覆盖（半透明蓝）。
  static const Color focusOverlay = Color(0x335B8DEF);
  static const Duration focusAnimationDuration = Duration(milliseconds: 250);
  static const Curve focusAnimationCurve = Curves.easeInOut;

  // === 非焦点状态 ===
  static const double nonFocusOpacity = 0.8;

  // === 间距 (TV 2x 基准) ===
  static const double spacingXs = 8.0;
  static const double spacingSm = 16.0;
  static const double spacingMd = 24.0;
  static const double spacingLg = 32.0;
  static const double spacingXl = 48.0;
  static const double spacingXxl = 64.0;

  // === 导航栏 ===
  static const double sidebarWidth = 240.0;
  static const double sidebarCollapsedWidth = 80.0;
  static const double sidebarItemHeight = 64.0;
  static const double sidebarIconSize = 32.0;
  static const double sidebarTextSize = 24.0;

  // === 海报尺寸 ===
  static const double posterWidth16_9 = 280.0;
  static const double posterHeight16_9 = 157.5; // 280 * 9/16
  static const double posterWidth2_3 = 200.0;
  static const double posterHeight2_3 = 300.0; // 200 * 3/2
  static const double posterRadius = 8.0;
  static const double posterSpacing = 16.0;

  // === Hero Banner ===
  static const double heroHeight = 450.0;
  static const double heroOverlayHeight = 200.0;
  static const double heroTitleSize = 36.0;
  static const double heroSubtitleSize = 20.0;
  static const Duration heroAutoPlayInterval = Duration(seconds: 10);
  static const Duration heroTransitionDuration = Duration(milliseconds: 500);
  static const Curve heroTransitionCurve = Curves.easeInOut;

  // === 播放页 ===
  static const double playerControlBarHeight = 120.0;
  static const double playerTopBarHeight = 80.0;
  static const double playerProgressBarHeight = 4.0;
  static const double playerProgressBarFocusedHeight = 8.0;
  static const double playerProgressBarBottomMargin = 120.0;
  static const double playerSeekStep = 10.0; // 秒
  static const Duration playerControlHideDelay = Duration(seconds: 5);
  static const Duration playerControlFadeDuration = Duration(milliseconds: 400);
  static const Duration playerControlShowDuration = Duration(milliseconds: 300);

  // === 面板 ===
  static const double panelWidth = 400.0;
  static const Duration panelSlideDuration = Duration(milliseconds: 300);
  static const Curve panelSlideCurve = Curves.easeInOut;

  // === Toast ===
  static const Duration toastDuration = Duration(seconds: 3);
  static const Duration toastFadeDuration = Duration(milliseconds: 300);
  static const double toastPaddingVertical = 16.0;
  static const double toastPaddingHorizontal = 32.0;
  static const double toastBorderRadius = 8.0;
  static const double toastFontSize = 20.0;

  // === 动画 ===
  static const Duration pageTransitionDuration = Duration(milliseconds: 400);
  static const Curve pageTransitionCurve = Curves.easeInOut;
  static const Duration contentFadeDuration = Duration(milliseconds: 300);
  static const Curve contentFadeCurve = Curves.easeInOut;
  static const Duration shimmerDuration = Duration(milliseconds: 1500);

  // === 键盘 ===
  static const double keyboardKeyWidth = 56.0;
  static const double keyboardKeyHeight = 56.0;
  static const double keyboardKeySpacing = 8.0;
  static const double keyboardFontSize = 24.0;

  // === 字体 ===
  static const double fontSizeXs = 14.0;
  static const double fontSizeSm = 18.0;
  static const double fontSizeMd = 24.0; // TV 基准
  static const double fontSizeLg = 28.0;
  static const double fontSizeXl = 32.0;
  static const double fontSizeXxl = 36.0;

  // === 行高 ===
  static const double lineHeightTight = 1.2;
  static const double lineHeightNormal = 1.4;
  static const double lineHeightRelaxed = 1.6;

  // === 字重 ===
  static const FontWeight fontWeightRegular = FontWeight.w400;
  static const FontWeight fontWeightMedium = FontWeight.w500;
  static const FontWeight fontWeightBold = FontWeight.w700;

  // === 滚动 ===
  static const Duration scrollDuration = Duration(milliseconds: 300);
  static const Curve scrollCurve = Curves.easeInOut;
}
