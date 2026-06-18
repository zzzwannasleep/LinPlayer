import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_animate/flutter_animate.dart';
import '../theme/tv_design_tokens.dart';

/// TV 焦点包装器
/// 为任何子组件添加 TV 焦点效果（放大、边框、光晕）
/// 支持遥控器方向键导航和确认键触发
class TvFocusable extends StatefulWidget {
  final Widget child;
  final VoidCallback? onSelect;
  final VoidCallback? onFocus;
  final VoidCallback? onBlur;
  final bool autofocus;
  final FocusNode? focusNode;
  final EdgeInsets padding;
  final double scale;
  final bool enableGlow;

  const TvFocusable({
    super.key,
    required this.child,
    this.onSelect,
    this.onFocus,
    this.onBlur,
    this.autofocus = false,
    this.focusNode,
    this.padding = const EdgeInsets.all(TvDesignTokens.spacingSm),
    this.scale = TvDesignTokens.focusScale,
    this.enableGlow = true,
  });

  @override
  State<TvFocusable> createState() => _TvFocusableState();
}

class _TvFocusableState extends State<TvFocusable> {
  bool _isFocused = false;

  @override
  Widget build(BuildContext context) {
    return Focus(
      focusNode: widget.focusNode,
      autofocus: widget.autofocus,
      onFocusChange: (focused) {
        setState(() => _isFocused = focused);
        if (focused) {
          widget.onFocus?.call();
        } else {
          widget.onBlur?.call();
        }
      },
      onKeyEvent: (node, event) {
        if (event is KeyDownEvent || event is KeyRepeatEvent) {
          if (event.logicalKey == LogicalKeyboardKey.select ||
              event.logicalKey == LogicalKeyboardKey.enter ||
              event.logicalKey == LogicalKeyboardKey.space) {
            widget.onSelect?.call();
            return KeyEventResult.handled;
          }
        }
        return KeyEventResult.ignored;
      },
      // 性能要点：
      // - 用单个 flutter_animate 链同时驱动 缩放 + 透明度（一个 controller），
      //   取代原先 AnimatedContainer + AnimatedScale + AnimatedOpacity 三层；
      // - 焦点描边/光晕的阴影是“静态”的，仅做透明度淡入淡出，绝不对 blur 做动画
      //   （动画 blurRadius 是焦点网格掉帧的元凶）；
      // - 外层 RepaintBoundary 把每个卡片的重绘隔离开。
      child: Builder(
        builder: (context) => GestureDetector(
          // TV 界面同时跑在平板/Pad 上：点击 = 聚焦 + 激活，等价于遥控器确认键。
          // opaque 让整张卡片区域可点；嵌套的子手势（如内部按钮）仍由更深层捕获。
          behavior: HitTestBehavior.opaque,
          onTap: () {
            Focus.of(context).requestFocus();
            widget.onSelect?.call();
          },
          child: RepaintBoundary(
        child: Padding(
          padding: widget.padding,
          child: Stack(
            clipBehavior: Clip.none,
            alignment: Alignment.center,
            children: [
              widget.child
                  .animate(target: _isFocused ? 1 : 0)
                  .scaleXY(
                    begin: 1.0,
                    end: widget.scale,
                    duration: TvDesignTokens.focusAnimationDuration,
                    curve: TvDesignTokens.focusAnimationCurve,
                    alignment: Alignment.center,
                  )
                  .fade(
                    begin: TvDesignTokens.nonFocusOpacity,
                    end: 1.0,
                    duration: TvDesignTokens.focusAnimationDuration,
                    curve: TvDesignTokens.focusAnimationCurve,
                  ),
              Positioned.fill(
                child: IgnorePointer(
                  child: AnimatedOpacity(
                    duration: TvDesignTokens.focusAnimationDuration,
                    curve: TvDesignTokens.focusAnimationCurve,
                    opacity: _isFocused ? 1.0 : 0.0,
                    child: DecoratedBox(
                      decoration: BoxDecoration(
                        border: Border.all(
                          color: TvDesignTokens.focusBorder,
                          width: TvDesignTokens.focusBorderWidth,
                        ),
                        borderRadius:
                            BorderRadius.circular(TvDesignTokens.posterRadius),
                        boxShadow: widget.enableGlow
                            ? const [
                                BoxShadow(
                                  color: TvDesignTokens.focusGlow,
                                  blurRadius: TvDesignTokens.focusGlowBlur,
                                  spreadRadius: 4,
                                ),
                              ]
                            : null,
                      ),
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
        ),
      ),
    );
  }
}

/// TV 焦点包装器（无动画版本，用于性能敏感场景）
class TvFocusableStatic extends StatelessWidget {
  final Widget child;
  final VoidCallback? onSelect;
  final bool autofocus;
  final FocusNode? focusNode;
  final EdgeInsets padding;

  const TvFocusableStatic({
    super.key,
    required this.child,
    this.onSelect,
    this.autofocus = false,
    this.focusNode,
    this.padding = const EdgeInsets.all(TvDesignTokens.spacingSm),
  });

  @override
  Widget build(BuildContext context) {
    return Focus(
      focusNode: focusNode,
      autofocus: autofocus,
      onKeyEvent: (node, event) {
        if (event is KeyDownEvent || event is KeyRepeatEvent) {
          if (event.logicalKey == LogicalKeyboardKey.select ||
              event.logicalKey == LogicalKeyboardKey.enter ||
              event.logicalKey == LogicalKeyboardKey.space) {
            onSelect?.call();
            return KeyEventResult.handled;
          }
        }
        return KeyEventResult.ignored;
      },
      child: Builder(
        builder: (context) {
          final focusNode = Focus.of(context);
          final focused = focusNode.hasFocus;
          return GestureDetector(
            // 平板/Pad 触控：点击 = 聚焦 + 激活。
            behavior: HitTestBehavior.opaque,
            onTap: () {
              focusNode.requestFocus();
              onSelect?.call();
            },
            child: Container(
            padding: padding,
            decoration: focused
                ? BoxDecoration(
                    border: Border.all(
                      color: TvDesignTokens.focusBorder,
                      width: TvDesignTokens.focusBorderWidth,
                    ),
                    borderRadius:
                        BorderRadius.circular(TvDesignTokens.posterRadius),
                    boxShadow: [
                      BoxShadow(
                        color: TvDesignTokens.focusGlow,
                        blurRadius: TvDesignTokens.focusGlowBlur,
                        spreadRadius: 4,
                      ),
                    ],
                  )
                : null,
            child: Transform.scale(
              scale: focused ? TvDesignTokens.focusScale : 1.0,
              child: Opacity(
                opacity: focused ? 1.0 : TvDesignTokens.nonFocusOpacity,
                child: child,
              ),
            ),
            ),
          );
        },
      ),
    );
  }
}
