import 'dart:math' as math;
import 'dart:ui';

import 'package:flutter/material.dart';

import '../theme/app_colors.dart';
import '../theme/app_motion.dart';

/// 播放页统一的「右侧设置面板」（三端复用：移动 / 桌面 / TV）。
///
/// 设计约束（与产品需求一一对应）：
/// - 停靠屏幕**右侧**，仅左侧圆角；
/// - 宽度**由内容决定**，但**绝不超过屏幕宽度的 1/3**（[PlayerPanelTokens.maxWidthFraction]）；
/// - **不使用黑色遮罩**：barrier 全透明、不挡画面；面板自身用「半透明 + 局部高斯模糊」
///   （仅面板区域，约屏幕 1/3）保证文字清晰，而不是盖一层全屏蒙版；
/// - **适配深 / 浅色**：颜色全部取自 [AppColors] + 当前 `Theme.brightness`，不再写死黑底白字；
/// - 入场动效复用 [AppMotion]（自右向左滑入 + 淡入），与全端动效系统一致；
/// - 细节打磨：标题/选项文字一律 `ellipsis` 防止「字突出来」，圆角统一走 token。
class PlayerPanelTokens {
  PlayerPanelTokens._();

  /// 面板左侧圆角。
  static const double radius = 16;

  /// 选项/分组内部元素圆角。
  static const double itemRadius = 10;

  /// 宽度硬上限：屏幕宽度的 1/3。
  static const double maxWidthFraction = 1 / 3;

  /// 内容未指定宽度时的默认宽度（仍会被 1/3 上限裁剪）。
  static const double defaultWidth = 360;

  /// 高度上限：屏幕高度的 88%。
  static const double maxHeightFraction = 0.88;

  /// 面板局部毛玻璃模糊强度（只作用于面板背后那一条，不是全屏）。
  static const double blurSigma = 16;
}

/// 面板配色：根据明暗模式解析出一套可读的半透明配色。
///
/// 半透明 + 模糊 = 毛玻璃：既能看清文字，又能隐约透出画面，符合「最好不挡画面」。
class PlayerPanelColors {
  const PlayerPanelColors({
    required this.surface,
    required this.headerSurface,
    required this.text,
    required this.textSecondary,
    required this.divider,
    required this.accent,
    required this.selectedFill,
    required this.controlTrack,
  });

  final Color surface;
  final Color headerSurface;
  final Color text;
  final Color textSecondary;
  final Color divider;
  final Color accent;
  final Color selectedFill;
  final Color controlTrack;

  static PlayerPanelColors resolve(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    if (isDark) {
      return PlayerPanelColors(
        // 遮罩浓度调低：面板更通透，画面隐约可见（毛玻璃仍保证文字可读）。
        surface: AppColors.darkSurface.withValues(alpha: 0.62),
        headerSurface: Colors.white.withValues(alpha: 0.04),
        text: AppColors.darkText,
        textSecondary: AppColors.darkTextSecondary,
        divider: Colors.white.withValues(alpha: 0.10),
        accent: AppColors.brand,
        selectedFill: AppColors.brand.withValues(alpha: 0.18),
        controlTrack: Colors.white.withValues(alpha: 0.16),
      );
    }
    return PlayerPanelColors(
      // 遮罩浓度调低（见深色注释）。
      surface: AppColors.lightSurface.withValues(alpha: 0.72),
      headerSurface: Colors.black.withValues(alpha: 0.03),
      text: AppColors.lightText,
      textSecondary: AppColors.lightTextSecondary,
      divider: Colors.black.withValues(alpha: 0.08),
      accent: AppColors.brand,
      selectedFill: AppColors.brand.withValues(alpha: 0.14),
      controlTrack: Colors.black.withValues(alpha: 0.12),
    );
  }
}

/// 打开一个右侧设置面板。
///
/// [title] 标题；[children] 面板内容（建议用本文件的 Panel* 组件构建）。
/// [width] 期望宽度，最终会被屏幕 1/3 裁剪；不传则用 [PlayerPanelTokens.defaultWidth]。
/// [titleTrailing] 标题栏右侧（关闭按钮左边）的可选操作区。
Future<T?> showPlayerSettingsPanel<T>({
  required BuildContext context,
  required String title,
  required List<Widget> children,
  double? width,
  Widget? titleTrailing,
}) {
  final mediaQuery = MediaQuery.of(context);
  final double maxWidth = mediaQuery.size.width * PlayerPanelTokens.maxWidthFraction;
  final double panelWidth =
      math.min(width ?? PlayerPanelTokens.defaultWidth, maxWidth);
  final double maxHeight =
      mediaQuery.size.height * PlayerPanelTokens.maxHeightFraction;
  // 让面板继承根 Theme 的明暗，而不是被播放页局部的深色覆盖。
  final ThemeData theme = Theme.of(context);

  return showGeneralDialog<T>(
    context: context,
    barrierDismissible: true,
    barrierLabel: MaterialLocalizations.of(context).modalBarrierDismissLabel,
    // 关键：不要黑色遮罩。透明 barrier —— 画面完全不被盖住。
    barrierColor: Colors.transparent,
    transitionDuration: AppMotion.medium,
    pageBuilder: (dialogContext, animation, secondaryAnimation) {
      return Theme(
        data: theme,
        child: _PlayerSettingsPanel(
          title: title,
          width: panelWidth,
          maxHeight: maxHeight,
          titleTrailing: titleTrailing,
          children: children,
        ),
      );
    },
    transitionBuilder: (context, animation, secondaryAnimation, child) {
      final curved = CurvedAnimation(
        parent: animation,
        curve: AppMotion.standard,
        reverseCurve: AppMotion.reverse,
      );
      return FadeTransition(
        opacity: curved,
        child: SlideTransition(
          position: Tween<Offset>(
            begin: const Offset(1, 0),
            end: Offset.zero,
          ).animate(curved),
          child: child,
        ),
      );
    },
  );
}

class _PlayerSettingsPanel extends StatelessWidget {
  const _PlayerSettingsPanel({
    required this.title,
    required this.width,
    required this.maxHeight,
    required this.children,
    this.titleTrailing,
  });

  final String title;
  final double width;
  final double maxHeight;
  final List<Widget> children;
  final Widget? titleTrailing;

  @override
  Widget build(BuildContext context) {
    final colors = PlayerPanelColors.resolve(context);
    const borderRadius =
        BorderRadius.horizontal(left: Radius.circular(PlayerPanelTokens.radius));

    return Align(
      alignment: Alignment.centerRight,
      child: Material(
        type: MaterialType.transparency,
        child: ClipRRect(
          borderRadius: borderRadius,
          // 局部毛玻璃：只模糊面板背后这一条，不是全屏遮罩。
          child: BackdropFilter(
            filter: ImageFilter.blur(
              sigmaX: PlayerPanelTokens.blurSigma,
              sigmaY: PlayerPanelTokens.blurSigma,
            ),
            child: Container(
              width: width,
              constraints: BoxConstraints(maxHeight: maxHeight),
              decoration: BoxDecoration(
                color: colors.surface,
                borderRadius: borderRadius,
                border: Border(
                  left: BorderSide(color: colors.divider, width: 1),
                ),
                boxShadow: [
                  BoxShadow(
                    color: Colors.black.withValues(alpha: 0.22),
                    blurRadius: 24,
                    offset: const Offset(-6, 0),
                  ),
                ],
              ),
              child: DefaultTextStyle.merge(
                style: TextStyle(color: colors.text),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    _PanelHeader(
                      title: title,
                      colors: colors,
                      trailing: titleTrailing,
                    ),
                    Flexible(
                      child: ListView(
                        shrinkWrap: true,
                        padding: const EdgeInsets.symmetric(vertical: 8),
                        children: children,
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _PanelHeader extends StatelessWidget {
  const _PanelHeader({
    required this.title,
    required this.colors,
    this.trailing,
  });

  final String title;
  final PlayerPanelColors colors;
  final Widget? trailing;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.fromLTRB(20, 16, 12, 14),
      decoration: BoxDecoration(
        color: colors.headerSurface,
        border: Border(bottom: BorderSide(color: colors.divider, width: 1)),
      ),
      child: Row(
        children: [
          Expanded(
            child: Text(
              title,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                color: colors.text,
                fontSize: 16,
                fontWeight: FontWeight.w600,
                letterSpacing: 0.2,
              ),
            ),
          ),
          if (trailing != null) ...[trailing!, const SizedBox(width: 4)],
          _PanelIconButton(
            icon: Icons.close_rounded,
            color: colors.textSecondary,
            onTap: () => Navigator.of(context).maybePop(),
          ),
        ],
      ),
    );
  }
}

class _PanelIconButton extends StatelessWidget {
  const _PanelIconButton({
    required this.icon,
    required this.color,
    required this.onTap,
  });

  final IconData icon;
  final Color color;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(20),
        child: Padding(
          padding: const EdgeInsets.all(6),
          child: Icon(icon, color: color, size: 20),
        ),
      ),
    );
  }
}

// ===========================================================================
// TDesign 风格的面板内容组件（半透明面板上可读、统一圆角、文字防溢出）。
// ===========================================================================

/// 分组标题（小号、次要色、字间距）。TDesign 列表分组规范。
class PanelSectionTitle extends StatelessWidget {
  const PanelSectionTitle(this.title, {super.key});

  final String title;

  @override
  Widget build(BuildContext context) {
    final colors = PlayerPanelColors.resolve(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 14, 20, 6),
      child: Text(
        title,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: TextStyle(
          color: colors.textSecondary,
          fontSize: 12.5,
          fontWeight: FontWeight.w600,
          letterSpacing: 0.4,
        ),
      ),
    );
  }
}

/// 单选项行：左标题(+副标题)，选中时整行高亮 + 右侧勾选（品牌色）。
class PanelOptionTile extends StatelessWidget {
  const PanelOptionTile({
    super.key,
    required this.label,
    required this.selected,
    required this.onTap,
    this.subtitle,
    this.leading,
    this.trailing,
  });

  final String label;
  final String? subtitle;
  final bool selected;
  final VoidCallback onTap;
  final Widget? leading;
  final Widget? trailing;

  @override
  Widget build(BuildContext context) {
    final colors = PlayerPanelColors.resolve(context);
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 2),
      child: Material(
        color: selected ? colors.selectedFill : Colors.transparent,
        borderRadius: BorderRadius.circular(PlayerPanelTokens.itemRadius),
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(PlayerPanelTokens.itemRadius),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 11),
            child: Row(
              children: [
                if (leading != null) ...[
                  IconTheme(
                    data: IconThemeData(
                      color: selected ? colors.accent : colors.textSecondary,
                      size: 20,
                    ),
                    child: leading!,
                  ),
                  const SizedBox(width: 12),
                ],
                Expanded(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        label,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          color: selected ? colors.accent : colors.text,
                          fontSize: 14.5,
                          fontWeight:
                              selected ? FontWeight.w600 : FontWeight.w500,
                        ),
                      ),
                      if (subtitle != null) ...[
                        const SizedBox(height: 2),
                        Text(
                          subtitle!,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            color: colors.textSecondary,
                            fontSize: 12,
                          ),
                        ),
                      ],
                    ],
                  ),
                ),
                if (trailing != null) trailing!,
                if (trailing == null && selected)
                  Icon(Icons.check_rounded, color: colors.accent, size: 20),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// 滑块行：标题 + 当前值 + Slider。统一的 SliderTheme（品牌色）。
class PanelSliderRow extends StatelessWidget {
  const PanelSliderRow({
    super.key,
    required this.label,
    required this.value,
    required this.min,
    required this.max,
    required this.onChanged,
    this.divisions,
    this.valueLabel,
  });

  final String label;
  final double value;
  final double min;
  final double max;
  final ValueChanged<double> onChanged;
  final int? divisions;
  final String? valueLabel;

  @override
  Widget build(BuildContext context) {
    final colors = PlayerPanelColors.resolve(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 8, 16, 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  label,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    color: colors.text,
                    fontSize: 14,
                    fontWeight: FontWeight.w500,
                  ),
                ),
              ),
              Text(
                valueLabel ?? value.toStringAsFixed(1),
                style: TextStyle(
                  color: colors.accent,
                  fontSize: 13,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ],
          ),
          SliderTheme(
            data: SliderTheme.of(context).copyWith(
              trackHeight: 3,
              activeTrackColor: colors.accent,
              inactiveTrackColor: colors.controlTrack,
              thumbColor: colors.accent,
              overlayColor: colors.accent.withValues(alpha: 0.16),
              thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 7),
              overlayShape: const RoundSliderOverlayShape(overlayRadius: 14),
            ),
            child: Slider(
              value: value.clamp(min, max),
              min: min,
              max: max,
              divisions: divisions,
              onChanged: onChanged,
            ),
          ),
        ],
      ),
    );
  }
}

/// 开关行：标题(+副标题) + Switch。
class PanelSwitchRow extends StatelessWidget {
  const PanelSwitchRow({
    super.key,
    required this.label,
    required this.value,
    required this.onChanged,
    this.subtitle,
  });

  final String label;
  final String? subtitle;
  final bool value;
  final ValueChanged<bool> onChanged;

  @override
  Widget build(BuildContext context) {
    final colors = PlayerPanelColors.resolve(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 6, 14, 6),
      child: Row(
        children: [
          Expanded(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  label,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    color: colors.text,
                    fontSize: 14,
                    fontWeight: FontWeight.w500,
                  ),
                ),
                if (subtitle != null) ...[
                  const SizedBox(height: 2),
                  Text(
                    subtitle!,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      color: colors.textSecondary,
                      fontSize: 12,
                    ),
                  ),
                ],
              ],
            ),
          ),
          const SizedBox(width: 8),
          Switch(
            value: value,
            onChanged: onChanged,
            activeThumbColor: colors.accent,
          ),
        ],
      ),
    );
  }
}

/// 操作按钮行（如「导入外挂字幕」「翻译字幕」）：TDesign 描边/填充按钮风格。
class PanelActionTile extends StatelessWidget {
  const PanelActionTile({
    super.key,
    required this.label,
    required this.icon,
    required this.onTap,
    this.filled = false,
  });

  final String label;
  final IconData icon;
  final VoidCallback onTap;
  final bool filled;

  @override
  Widget build(BuildContext context) {
    final colors = PlayerPanelColors.resolve(context);
    final Color fg = filled ? Colors.white : colors.accent;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
      child: Material(
        color: filled ? colors.accent : Colors.transparent,
        borderRadius: BorderRadius.circular(PlayerPanelTokens.itemRadius),
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(PlayerPanelTokens.itemRadius),
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 11),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(PlayerPanelTokens.itemRadius),
              border: filled
                  ? null
                  : Border.all(color: colors.accent.withValues(alpha: 0.6)),
            ),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Icon(icon, color: fg, size: 18),
                const SizedBox(width: 8),
                Flexible(
                  child: Text(
                    label,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      color: fg,
                      fontSize: 14,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// 面板内分隔线。
class PanelDivider extends StatelessWidget {
  const PanelDivider({super.key});

  @override
  Widget build(BuildContext context) {
    final colors = PlayerPanelColors.resolve(context);
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      child: Divider(height: 1, thickness: 1, color: colors.divider),
    );
  }
}
