import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_animate/flutter_animate.dart';
import '../theme/tv_design_tokens.dart';
import '../theme/tv_metrics.dart';

/// TV 焦点包装器
/// 为任何子组件添加 TV 焦点效果（放大、边框、光晕）
/// 支持遥控器方向键导航和确认键触发
class TvFocusable extends StatefulWidget {
  final Widget child;
  final VoidCallback? onSelect;
  /// 次级动作：平板/Pad 长按触发；TV 遥控器按「菜单键」(contextMenu) 触发。
  /// 用于「长按进入编辑模式」等场景。
  final VoidCallback? onLongPress;
  final VoidCallback? onFocus;
  final VoidCallback? onBlur;
  final bool autofocus;
  final FocusNode? focusNode;
  /// 内边距，传 null 时按当前屏幕响应式取 spacingSm。
  final EdgeInsets? padding;
  final double scale;
  final bool enableGlow;

  const TvFocusable({
    super.key,
    required this.child,
    this.onSelect,
    this.onLongPress,
    this.onFocus,
    this.onBlur,
    this.autofocus = false,
    this.focusNode,
    this.padding,
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
    final m = context.tv;
    final padding = widget.padding ?? EdgeInsets.all(m.spacingSm);
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
          // 遥控器「菜单键」= 次级动作（进入编辑等）。
          if (widget.onLongPress != null &&
              (event.logicalKey == LogicalKeyboardKey.contextMenu ||
                  event.logicalKey == LogicalKeyboardKey.gameButtonY)) {
            widget.onLongPress!.call();
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
          onLongPress: widget.onLongPress == null
              ? null
              : () {
                  Focus.of(context).requestFocus();
                  widget.onLongPress!.call();
                },
          child: RepaintBoundary(
        child: Padding(
          padding: padding,
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
              // 聚焦指示：仅一层淡淡的品牌蓝覆盖（无白色描边、无大光晕）。
              Positioned.fill(
                child: IgnorePointer(
                  child: AnimatedOpacity(
                    duration: TvDesignTokens.focusAnimationDuration,
                    curve: TvDesignTokens.focusAnimationCurve,
                    opacity: _isFocused ? 1.0 : 0.0,
                    child: DecoratedBox(
                      decoration: BoxDecoration(
                        color: TvDesignTokens.focusOverlay,
                        borderRadius: BorderRadius.circular(m.posterRadius),
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
  /// 内边距，传 null 时按当前屏幕响应式取 spacingSm。
  final EdgeInsets? padding;

  const TvFocusableStatic({
    super.key,
    required this.child,
    this.onSelect,
    this.autofocus = false,
    this.focusNode,
    this.padding,
  });

  @override
  Widget build(BuildContext context) {
    final m = context.tv;
    final padding = this.padding ?? EdgeInsets.all(m.spacingSm);
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
            child: Padding(
            padding: padding,
            child: Transform.scale(
              scale: focused ? TvDesignTokens.focusScale : 1.0,
              child: Opacity(
                opacity: focused ? 1.0 : TvDesignTokens.nonFocusOpacity,
                child: Stack(
                  children: [
                    child,
                    if (focused)
                      Positioned.fill(
                        child: IgnorePointer(
                          child: DecoratedBox(
                            decoration: BoxDecoration(
                              color: TvDesignTokens.focusOverlay,
                              borderRadius:
                                  BorderRadius.circular(m.posterRadius),
                            ),
                          ),
                        ),
                      ),
                  ],
                ),
              ),
            ),
            ),
          );
        },
      ),
    );
  }
}
