import 'package:flutter/widgets.dart';
import 'tv_design_tokens.dart';

/// TV / Pad 端响应式度量
///
/// [TvDesignTokens] 中的尺寸是按 1920×1080 的 TV 基准设计的固定值。
/// 在 Pad（更小的横屏）上直接使用这些值会显得过大、留白失衡。
///
/// [TvMetrics] 以屏幕实际尺寸为依据计算一个缩放因子，并按比例输出所有
/// **尺寸类** token（间距 / 海报 / 侧边栏 / Hero / 播放器 / 字号 等）。
/// 颜色、时长、曲线、字重等与尺寸无关的常量仍直接使用 [TvDesignTokens]。
///
/// 用法：在 build 中取 `final m = context.tv;`，把原先的
/// `TvDesignTokens.spacingLg` 改写为 `m.spacingLg`（需去掉外层 const）。
/// 对于散落的字面量尺寸用 `m.s(420)`，字号用 `m.fs(12)`。
class TvMetrics {
  /// 设计基准（标准 TV 10-foot UI）。
  static const double designWidth = 1920.0;
  static const double designHeight = 1080.0;

  /// 布局缩放因子（间距 / 尺寸）。
  final double scale;

  /// 字号缩放因子，下限收得更紧以保证可读性。
  final double fontScale;

  const TvMetrics._(this.scale, this.fontScale);

  /// TV 基准（不缩放），用于无 context 的静态场景（如默认主题）。
  static const TvMetrics base = TvMetrics._(1.0, 1.0);

  factory TvMetrics.fromSize(Size size) {
    // 仅横屏适配：以较受限的一边决定缩放，保证整屏内容不溢出。
    final double raw = size.width <= 0 || size.height <= 0
        ? 1.0
        : (size.width / designWidth) < (size.height / designHeight)
            ? size.width / designWidth
            : size.height / designHeight;
    // 布局可以缩得更小；字号收紧下限避免在 Pad 上过小难读。
    final double s = raw.clamp(0.6, 1.1);
    final double fs = raw.clamp(0.75, 1.1);
    return TvMetrics._(s, fs);
  }

  /// 当前是否为平板尺寸（相对 TV 明显更小的屏）。
  bool get isCompact => scale < 0.85;

  /// 通用尺寸缩放（间距、宽高、半径等）。
  double s(double v) => v * scale;

  /// 通用字号缩放。
  double fs(double v) => v * fontScale;

  // === 间距 ===
  double get spacingXs => TvDesignTokens.spacingXs * scale;
  double get spacingSm => TvDesignTokens.spacingSm * scale;
  double get spacingMd => TvDesignTokens.spacingMd * scale;
  double get spacingLg => TvDesignTokens.spacingLg * scale;
  double get spacingXl => TvDesignTokens.spacingXl * scale;
  double get spacingXxl => TvDesignTokens.spacingXxl * scale;

  // === 导航栏 ===
  double get sidebarWidth => TvDesignTokens.sidebarWidth * scale;
  double get sidebarCollapsedWidth =>
      TvDesignTokens.sidebarCollapsedWidth * scale;
  double get sidebarItemHeight => TvDesignTokens.sidebarItemHeight * scale;
  double get sidebarIconSize => TvDesignTokens.sidebarIconSize * scale;
  double get sidebarTextSize => TvDesignTokens.sidebarTextSize * fontScale;

  // === 海报尺寸 ===
  double get posterWidth16_9 => TvDesignTokens.posterWidth16_9 * scale;
  double get posterHeight16_9 => TvDesignTokens.posterHeight16_9 * scale;
  double get posterWidth2_3 => TvDesignTokens.posterWidth2_3 * scale;
  double get posterHeight2_3 => TvDesignTokens.posterHeight2_3 * scale;
  double get posterRadius => TvDesignTokens.posterRadius * scale;
  double get posterSpacing => TvDesignTokens.posterSpacing * scale;

  // === Hero Banner ===
  double get heroHeight => TvDesignTokens.heroHeight * scale;
  double get heroOverlayHeight => TvDesignTokens.heroOverlayHeight * scale;
  double get heroTitleSize => TvDesignTokens.heroTitleSize * fontScale;
  double get heroSubtitleSize => TvDesignTokens.heroSubtitleSize * fontScale;

  // === 播放页 ===
  double get playerControlBarHeight =>
      TvDesignTokens.playerControlBarHeight * scale;
  double get playerTopBarHeight => TvDesignTokens.playerTopBarHeight * scale;
  double get playerProgressBarHeight =>
      TvDesignTokens.playerProgressBarHeight * scale;
  double get playerProgressBarFocusedHeight =>
      TvDesignTokens.playerProgressBarFocusedHeight * scale;
  double get playerProgressBarBottomMargin =>
      TvDesignTokens.playerProgressBarBottomMargin * scale;

  // === 面板 ===
  double get panelWidth => TvDesignTokens.panelWidth * scale;

  // === Toast ===
  double get toastPaddingVertical =>
      TvDesignTokens.toastPaddingVertical * scale;
  double get toastPaddingHorizontal =>
      TvDesignTokens.toastPaddingHorizontal * scale;
  double get toastBorderRadius => TvDesignTokens.toastBorderRadius * scale;
  double get toastFontSize => TvDesignTokens.toastFontSize * fontScale;

  // === 键盘 ===
  double get keyboardKeyWidth => TvDesignTokens.keyboardKeyWidth * scale;
  double get keyboardKeyHeight => TvDesignTokens.keyboardKeyHeight * scale;
  double get keyboardKeySpacing => TvDesignTokens.keyboardKeySpacing * scale;
  double get keyboardFontSize => TvDesignTokens.keyboardFontSize * fontScale;

  // === 字体 ===
  double get fontSizeXs => TvDesignTokens.fontSizeXs * fontScale;
  double get fontSizeSm => TvDesignTokens.fontSizeSm * fontScale;
  double get fontSizeMd => TvDesignTokens.fontSizeMd * fontScale;
  double get fontSizeLg => TvDesignTokens.fontSizeLg * fontScale;
  double get fontSizeXl => TvDesignTokens.fontSizeXl * fontScale;
  double get fontSizeXxl => TvDesignTokens.fontSizeXxl * fontScale;
}

/// 通过 [BuildContext] 获取响应式度量。
///
/// 依赖 [MediaQuery.sizeOf]，因此屏幕尺寸/旋转变化时会自动重建。
extension TvMetricsContext on BuildContext {
  TvMetrics get tv => TvMetrics.fromSize(MediaQuery.sizeOf(this));
}
