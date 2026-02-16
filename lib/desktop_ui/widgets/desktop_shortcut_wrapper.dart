import 'package:flutter/material.dart';

class DesktopShortcutWrapper extends StatelessWidget {
  const DesktopShortcutWrapper({
    super.key,
    required this.child,
    this.shortcuts,
    this.actions,
    this.enabled = false,
  });

  final Widget child;
  final Map<ShortcutActivator, Intent>? shortcuts;
  final Map<Type, Action<Intent>>? actions;

  /// Reserved integration switch for global desktop shortcuts.
  final bool enabled;

  @override
  Widget build(BuildContext context) {
    if (!enabled || shortcuts == null || actions == null) {
      return child;
    }

    return Shortcuts(
      shortcuts: shortcuts!,
      child: Actions(
        actions: actions!,
        child: child,
      ),
    );
  }
}
