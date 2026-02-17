import 'package:flutter/material.dart';

import '../theme/desktop_theme_extension.dart';

class DesktopNavigationLayout extends StatelessWidget {
  const DesktopNavigationLayout({
    super.key,
    required this.sidebar,
    required this.topBar,
    required this.content,
    this.backgroundStartColor,
    this.backgroundEndColor,
    this.sidebarVisible = false,
    this.onDismissSidebar,
    this.sidebarWidth = 264,
    this.topBarVisibility = 1.0,
  });

  final Widget sidebar;
  final Widget topBar;
  final Widget content;
  final Color? backgroundStartColor;
  final Color? backgroundEndColor;
  final bool sidebarVisible;
  final VoidCallback? onDismissSidebar;
  final double sidebarWidth;
  final double topBarVisibility;

  @override
  Widget build(BuildContext context) {
    final desktopTheme = DesktopThemeExtension.of(context);
    final backgroundStart = backgroundStartColor ?? desktopTheme.background;
    final backgroundEnd =
        backgroundEndColor ?? desktopTheme.backgroundGradientEnd;
    final showSidebar = sidebarVisible && sidebarWidth > 0;
    const horizontalPadding = 0.0;
    final topBarTarget = topBarVisibility.clamp(0.0, 1.0).toDouble();

    return Stack(
      children: [
        DecoratedBox(
          decoration: BoxDecoration(
            gradient: LinearGradient(
              begin: Alignment.topLeft,
              end: Alignment.bottomRight,
              colors: [
                backgroundStart,
                backgroundEnd,
              ],
            ),
          ),
          child: const SizedBox.expand(),
        ),
        SafeArea(
          child: Column(
            children: [
              ClipRect(
                child: AnimatedAlign(
                  alignment: Alignment.topCenter,
                  heightFactor: topBarTarget,
                  duration: const Duration(milliseconds: 180),
                  curve: Curves.easeOutCubic,
                  child: AnimatedOpacity(
                    opacity: topBarTarget,
                    duration: const Duration(milliseconds: 180),
                    curve: Curves.easeOutCubic,
                    child: IgnorePointer(
                      ignoring: topBarTarget < 0.05,
                      child: Padding(
                        padding: EdgeInsets.fromLTRB(
                            horizontalPadding, 0, horizontalPadding, 0),
                        child: topBar,
                      ),
                    ),
                  ),
                ),
              ),
              AnimatedContainer(
                duration: const Duration(milliseconds: 180),
                curve: Curves.easeOutCubic,
                height: 22 * topBarTarget,
              ),
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
