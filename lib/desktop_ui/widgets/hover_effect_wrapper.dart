import 'package:flutter/material.dart';
import '../theme/desktop_theme_extension.dart';

class HoverEffectWrapper extends StatefulWidget {
  const HoverEffectWrapper({
    super.key,
    required this.child,
    this.onTap,
    this.padding,
    this.borderRadius = const BorderRadius.all(Radius.circular(14)),
    this.hoverScale = 1.03,
    this.duration = const Duration(milliseconds: 140),
    this.autofocus = false,
    this.canRequestFocus = true,
  });

  final Widget child;
  final VoidCallback? onTap;
  final EdgeInsetsGeometry? padding;
  final BorderRadius borderRadius;
  final double hoverScale;
  final Duration duration;
  final bool autofocus;
  final bool canRequestFocus;

  @override
  State<HoverEffectWrapper> createState() => _HoverEffectWrapperState();
}

class _HoverEffectWrapperState extends State<HoverEffectWrapper> {
  bool _hovered = false;
  bool _focused = false;

  @override
  Widget build(BuildContext context) {
    final desktopTheme = DesktopThemeExtension.of(context);
    final highlighted = _hovered || _focused;

    return FocusableActionDetector(
      enabled: widget.canRequestFocus,
      autofocus: widget.autofocus,
      onShowHoverHighlight: (value) => setState(() => _hovered = value),
      onShowFocusHighlight: (value) => setState(() => _focused = value),
      mouseCursor: widget.onTap != null
          ? SystemMouseCursors.click
          : SystemMouseCursors.basic,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: widget.onTap,
        child: AnimatedScale(
          scale: highlighted ? widget.hoverScale : 1.0,
          duration: widget.duration,
          curve: Curves.easeOutCubic,
          child: AnimatedContainer(
            duration: widget.duration,
            curve: Curves.easeOutCubic,
            padding: widget.padding,
            decoration: BoxDecoration(
              borderRadius: widget.borderRadius,
              border: Border.all(
                color: _focused
                    ? desktopTheme.focus
                    : (highlighted
                        ? desktopTheme.hover
                        : Colors.transparent),
                width: _focused ? 1.6 : 1.0,
              ),
              boxShadow: highlighted
                  ? [
                      BoxShadow(
                        color: Colors.black.withValues(alpha: 0.22),
                        blurRadius: 18,
                        offset: const Offset(0, 8),
                      ),
                    ]
                  : null,
            ),
            child: ClipRRect(
              borderRadius: widget.borderRadius,
              child: widget.child,
            ),
          ),
        ),
      ),
    );
  }
}
