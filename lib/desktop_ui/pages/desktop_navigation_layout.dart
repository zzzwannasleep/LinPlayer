import 'package:flutter/material.dart';

import '../theme/desktop_theme_extension.dart';

class DesktopNavigationLayout extends StatelessWidget {
  const DesktopNavigationLayout({
    super.key,
    required this.sidebar,
    required this.topBar,
    required this.content,
    this.sidebarWidth = 264,
  });

  final Widget sidebar;
  final Widget topBar;
  final Widget content;
  final double sidebarWidth;

  @override
  Widget build(BuildContext context) {
    final desktopTheme = DesktopThemeExtension.of(context);

    return DecoratedBox(
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [
            desktopTheme.backgroundGradientStart,
            desktopTheme.backgroundGradientEnd,
          ],
        ),
      ),
      child: Row(
        children: [
          SizedBox(
            width: sidebarWidth,
            child: sidebar,
          ),
          const SizedBox(width: 16),
          Expanded(
            child: Column(
              children: [
                topBar,
                const SizedBox(height: 14),
                Expanded(child: content),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
