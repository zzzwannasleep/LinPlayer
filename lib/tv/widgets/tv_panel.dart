import 'dart:math' as math;
import 'dart:ui';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../theme/tv_design_tokens.dart';
import 'tv_focusable.dart';

/// TV 右侧滑入面板
/// 统一面板组件，所有设置/选择用单面板分组
class TvPanel extends StatefulWidget {
  final String title;
  final List<Widget> children;
  final VoidCallback? onClose;
  final double width;

  const TvPanel({
    super.key,
    required this.title,
    required this.children,
    this.onClose,
    this.width = TvDesignTokens.panelWidth,
  });

  @override
  State<TvPanel> createState() => _TvPanelState();
}

class _TvPanelState extends State<TvPanel>
    with SingleTickerProviderStateMixin {
  late AnimationController _controller;
  late Animation<Offset> _offsetAnimation;
  late Animation<double> _fadeAnimation;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      duration: TvDesignTokens.panelSlideDuration,
      vsync: this,
    );
    _offsetAnimation = Tween<Offset>(
      begin: const Offset(1, 0),
      end: Offset.zero,
    ).animate(CurvedAnimation(
      parent: _controller,
      curve: TvDesignTokens.panelSlideCurve,
    ));
    // 仅面板自身淡入，不再做全屏黑色遮罩。
    _fadeAnimation = CurvedAnimation(
      parent: _controller,
      curve: TvDesignTokens.panelSlideCurve,
    );
    _controller.forward();
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  Future<void> _close() async {
    await _controller.reverse();
    widget.onClose?.call();
  }

  @override
  Widget build(BuildContext context) {
    // 宽度由内容决定，但绝不超过屏幕的 1/3。
    final double maxWidth = MediaQuery.of(context).size.width / 3;
    final double panelWidth = math.min(widget.width, maxWidth);
    const borderRadius =
        BorderRadius.horizontal(left: Radius.circular(20));

    return Stack(
      children: [
        // 透明热区：点击面板外关闭，但不绘制任何黑色遮罩、不挡画面。
        Positioned.fill(
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: _close,
            child: const SizedBox.shrink(),
          ),
        ),
        // 面板
        Focus(
          autofocus: true,
          onKeyEvent: (node, event) {
            if (event is KeyDownEvent &&
                (event.logicalKey == LogicalKeyboardKey.escape ||
                    event.logicalKey == LogicalKeyboardKey.goBack)) {
              _close();
              return KeyEventResult.handled;
            }
            return KeyEventResult.ignored;
          },
          child: Align(
            alignment: Alignment.centerRight,
            child: FadeTransition(
              opacity: _fadeAnimation,
              child: SlideTransition(
                position: _offsetAnimation,
                child: ClipRRect(
                  borderRadius: borderRadius,
                  // 局部毛玻璃：仅面板区域，画面其余部分完全不被遮挡。
                  child: BackdropFilter(
                    filter: ImageFilter.blur(sigmaX: 18, sigmaY: 18),
                    child: Container(
                      width: panelWidth,
                      decoration: BoxDecoration(
                        color: TvDesignTokens.surface.withValues(alpha: 0.86),
                        borderRadius: borderRadius,
                        border: const Border(
                          left:
                              BorderSide(color: TvDesignTokens.divider, width: 1),
                        ),
                        boxShadow: [
                          BoxShadow(
                            color: Colors.black.withValues(alpha: 0.3),
                            blurRadius: 28,
                            offset: const Offset(-8, 0),
                          ),
                        ],
                      ),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          // 标题栏
                          Padding(
                            padding:
                                const EdgeInsets.all(TvDesignTokens.spacingLg),
                            child: Row(
                              children: [
                                Expanded(
                                  child: Text(
                                    widget.title,
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                    style: const TextStyle(
                                      fontSize: TvDesignTokens.fontSizeXl,
                                      color: TvDesignTokens.textPrimary,
                                      fontWeight: FontWeight.bold,
                                    ),
                                  ),
                                ),
                                const SizedBox(width: TvDesignTokens.spacingSm),
                                TvFocusable(
                                  onSelect: _close,
                                  child: const Icon(
                                    Icons.close,
                                    color: TvDesignTokens.textSecondary,
                                    size: 32,
                                  ),
                                ),
                              ],
                            ),
                          ),
                          const Divider(color: TvDesignTokens.divider),
                          // 内容
                          Expanded(
                            child: ListView(
                              padding: const EdgeInsets.all(
                                  TvDesignTokens.spacingLg),
                              children: widget.children,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      ],
    );
  }
}

/// TV 面板选项项
class TvPanelOption extends StatelessWidget {
  final String title;
  final String? subtitle;
  final bool isSelected;
  final Widget? leading;
  final Widget? trailing;
  final VoidCallback? onTap;

  const TvPanelOption({
    super.key,
    required this.title,
    this.subtitle,
    this.isSelected = false,
    this.leading,
    this.trailing,
    this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return TvFocusable(
      onSelect: onTap,
      child: Container(
        padding: const EdgeInsets.all(TvDesignTokens.spacingMd),
        decoration: BoxDecoration(
          color:
              isSelected ? TvDesignTokens.brand.withValues(alpha: 0.15) : null,
          borderRadius: BorderRadius.circular(TvDesignTokens.posterRadius),
        ),
        child: Row(
          children: [
            if (leading != null) ...[
              leading!,
              const SizedBox(width: TvDesignTokens.spacingMd),
            ],
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    title,
                    style: TextStyle(
                      fontSize: TvDesignTokens.fontSizeMd,
                      color: isSelected ? TvDesignTokens.brand : TvDesignTokens.textPrimary,
                      fontWeight: isSelected ? FontWeight.bold : FontWeight.normal,
                    ),
                  ),
                  if (subtitle != null)
                    Text(
                      subtitle!,
                      style: const TextStyle(
                        fontSize: TvDesignTokens.fontSizeSm,
                        color: TvDesignTokens.textSecondary,
                      ),
                    ),
                ],
              ),
            ),
            if (trailing != null) trailing!,
            if (isSelected)
              const Icon(
                Icons.check,
                color: TvDesignTokens.brand,
                size: 24,
              ),
          ],
        ),
      ),
    );
  }
}

/// TV 面板分组标题
class TvPanelSection extends StatelessWidget {
  final String title;

  const TvPanelSection({super.key, required this.title});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(
        top: TvDesignTokens.spacingLg,
        bottom: TvDesignTokens.spacingSm,
      ),
      child: Text(
        title,
        style: const TextStyle(
          fontSize: TvDesignTokens.fontSizeSm,
          color: TvDesignTokens.textSecondary,
          fontWeight: FontWeight.bold,
        ),
      ),
    );
  }
}
