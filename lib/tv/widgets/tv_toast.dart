import 'dart:async';
import 'package:flutter/material.dart';
import '../theme/tv_design_tokens.dart';
import '../theme/tv_metrics.dart';

/// TV Toast 提示
/// 中央偏下，3 秒停留，支持动画淡入淡出
class TvToast {
  static OverlayEntry? _currentEntry;
  static Timer? _timer;

  static void show(BuildContext context, String message) {
    _removeCurrent();

    final overlay = Overlay.of(context);
    _currentEntry = OverlayEntry(
      builder: (context) => _TvToastWidget(message: message),
    );
    overlay.insert(_currentEntry!);

    _timer = Timer(TvDesignTokens.toastDuration, () {
      _removeCurrent();
    });
  }

  static void _removeCurrent() {
    _timer?.cancel();
    _currentEntry?.remove();
    _currentEntry = null;
  }
}

class _TvToastWidget extends StatefulWidget {
  final String message;

  const _TvToastWidget({required this.message});

  @override
  State<_TvToastWidget> createState() => _TvToastWidgetState();
}

class _TvToastWidgetState extends State<_TvToastWidget>
    with SingleTickerProviderStateMixin {
  late AnimationController _controller;
  late Animation<double> _animation;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      duration: TvDesignTokens.toastFadeDuration,
      vsync: this,
    );
    _animation = CurvedAnimation(
      parent: _controller,
      curve: Curves.easeInOut,
    );
    _controller.forward();
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final m = context.tv;
    return Positioned(
      bottom: MediaQuery.of(context).size.height * 0.25,
      left: 0,
      right: 0,
      child: FadeTransition(
        opacity: _animation,
        child: Center(
          child: Container(
            padding: EdgeInsets.symmetric(
              vertical: m.toastPaddingVertical,
              horizontal: m.toastPaddingHorizontal,
            ),
            decoration: BoxDecoration(
              color: TvDesignTokens.surfaceElevated,
              borderRadius: BorderRadius.circular(m.toastBorderRadius),
            ),
            child: Text(
              widget.message,
              style: TextStyle(
                fontSize: m.toastFontSize,
                color: TvDesignTokens.textPrimary,
              ),
            ),
          ),
        ),
      ),
    );
  }
}
