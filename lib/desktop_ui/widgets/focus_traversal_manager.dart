import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

class FocusTraversalManager extends StatelessWidget {
  const FocusTraversalManager({
    super.key,
    required this.child,
    this.autofocusRoot = true,
  });

  final Widget child;
  final bool autofocusRoot;

  @override
  Widget build(BuildContext context) {
    final traversalTree = FocusTraversalGroup(
      policy: OrderedTraversalPolicy(),
      child: child,
    );

    if (!autofocusRoot) {
      return _withKeyboardTraversal(traversalTree);
    }

    return Focus(
      autofocus: true,
      skipTraversal: true,
      child: _withKeyboardTraversal(traversalTree),
    );
  }

  Widget _withKeyboardTraversal(Widget child) {
    return Shortcuts(
      shortcuts: const <ShortcutActivator, Intent>{
        SingleActivator(LogicalKeyboardKey.arrowLeft):
            DirectionalFocusIntent(TraversalDirection.left),
        SingleActivator(LogicalKeyboardKey.arrowRight):
            DirectionalFocusIntent(TraversalDirection.right),
        SingleActivator(LogicalKeyboardKey.arrowUp):
            DirectionalFocusIntent(TraversalDirection.up),
        SingleActivator(LogicalKeyboardKey.arrowDown):
            DirectionalFocusIntent(TraversalDirection.down),
        SingleActivator(LogicalKeyboardKey.tab): NextFocusIntent(),
        SingleActivator(LogicalKeyboardKey.tab, shift: true):
            PreviousFocusIntent(),
      },
      child: Actions(
        actions: <Type, Action<Intent>>{
          DirectionalFocusIntent: DirectionalFocusAction(),
          NextFocusIntent: NextFocusAction(),
          PreviousFocusIntent: PreviousFocusAction(),
        },
        child: child,
      ),
    );
  }
}
