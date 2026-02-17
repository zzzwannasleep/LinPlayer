import 'package:flutter/material.dart';

import '../theme/desktop_theme_extension.dart';

class DesktopNavigationLayout extends StatelessWidget {
  const DesktopNavigationLayout({
    super.key,
    required this.sidebar,
    required this.topBar,
    required this.content,
    this.sidebarVisible = false,
    this.onDismissSidebar,
    this.sidebarWidth = 264,
  });

  final Widget sidebar;
  final Widget topBar;
  final Widget content;
  final bool sidebarVisible;
  final VoidCallback? onDismissSidebar;
  final double sidebarWidth;

  @override
  Widget build(BuildContext context) {
    final desktopTheme = DesktopThemeExtension.of(context);
    final showSidebar = sidebarVisible && sidebarWidth > 0;
    final screenWidth = MediaQuery.sizeOf(context).width;
    final horizontalPadding = screenWidth >= 1120 ? 40.0 : 24.0;

    return Stack(
      children: [
        DecoratedBox(
          decoration: BoxDecoration(
            gradient: LinearGradient(
              begin: Alignment.topLeft,
              end: Alignment.bottomRight,
              colors: [
                desktopTheme.background,
                desktopTheme.backgroundGradientEnd,
              ],
            ),
          ),
          child: const SizedBox.expand(),
        ),
        SafeArea(
          child: Column(
            children: [
              Padding(
                padding: EdgeInsets.fromLTRB(
                    horizontalPadding, 0, horizontalPadding, 0),
                child: topBar,
              ),
              const SizedBox(height: 22),
              Expanded(
                child: Padding(
                  padding: EdgeInsets.fromLTRB(
                    horizontalPadding,
                    0,
                    horizontalPadding,
                    24,
                  ),
                  child: content,
                ),
              ),
            ],
          ),
        ),
        if (showSidebar)
          Positioned.fill(
            child: GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTap: onDismissSidebar,
              child: ColoredBox(
                color: Colors.black.withValues(alpha: 0.32),
              ),
            ),
          ),
        if (showSidebar)
          Positioned(
            top: 72,
            bottom: 24,
            left: 16,
            child: SizedBox(
              width: sidebarWidth,
              child: sidebar,
            ),
          ),
      ],
    );
  }
}
