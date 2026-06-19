import 'package:flutter/material.dart';

import '../theme/tv_design_tokens.dart';
import '../theme/tv_metrics.dart';
import 'tv_focusable.dart';

/// TV 主操作按钮 —— 原生实现 + TV 焦点（放大 / 描边 / 品牌色光晕，flutter_animate 驱动）
/// 与遥控器确认键触发。
///
/// 视觉沿用 TDesign 的圆角填充/描边规范，但不引入 tdesign_flutter 依赖
/// （该包在较新 Flutter 上无法编译）。
class TvButton extends StatelessWidget {
  final String text;
  final IconData? icon;
  final VoidCallback? onPressed;
  final bool autofocus;
  final FocusNode? focusNode;

  /// true = 描边按钮（次要操作）；false = 品牌色填充（主操作）。
  final bool outlined;

  const TvButton({
    super.key,
    required this.text,
    this.icon,
    this.onPressed,
    this.autofocus = false,
    this.focusNode,
    this.outlined = false,
  });

  @override
  Widget build(BuildContext context) {
    final m = context.tv;
    final fg = outlined ? TvDesignTokens.textPrimary : Colors.white;
    return TvFocusable(
      autofocus: autofocus,
      focusNode: focusNode,
      onSelect: onPressed,
      scale: 1.08,
      padding: EdgeInsets.all(m.spacingXs),
      child: Container(
        padding: EdgeInsets.symmetric(
          horizontal: m.spacingLg,
          vertical: m.spacingSm,
        ),
        decoration: BoxDecoration(
          color: outlined ? Colors.transparent : TvDesignTokens.brand,
          borderRadius: BorderRadius.circular(999),
          border: outlined
              ? Border.all(color: TvDesignTokens.textSecondary, width: 2)
              : null,
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (icon != null) ...[
              Icon(icon, color: fg, size: m.s(28)),
              SizedBox(width: m.spacingXs),
            ],
            Text(
              text,
              style: TextStyle(
                fontSize: m.fontSizeMd,
                color: fg,
                fontWeight: FontWeight.bold,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
