import 'package:flutter/material.dart';
import 'package:lin_player_state/lin_player_state.dart';

import 'desktop_unified_background.dart';

class DesktopCinematicShell extends StatelessWidget {
  const DesktopCinematicShell({
    super.key,
    required this.appState,
    required this.tabs,
    required this.selectedIndex,
    required this.onSelected,
    required this.child,
    required this.title,
    this.trailingLabel,
    this.trailingIcon = Icons.dns_outlined,
  });

  final AppState appState;
  final List<DesktopCinematicTab> tabs;
  final int selectedIndex;
  final ValueChanged<int> onSelected;
  final Widget child;
  final String title;
  final String? trailingLabel;
  final IconData trailingIcon;

  @override
  Widget build(BuildContext context) {
    final brightness = Theme.of(context).brightness;
    final isDark = brightness == Brightness.dark;
    final background = DesktopUnifiedBackground.baseColorForBrightness(brightness);
    final surfaceColor = isDark
        ? const Color(0xD1111620)
        : const Color(0xECFFFFFF);
    final surfaceBorder = isDark
        ? Colors.white.withValues(alpha: 0.10)
        : Colors.black.withValues(alpha: 0.08);

    return Scaffold(
      backgroundColor: background,
      body: SafeArea(
        child: Stack(
          children: [
            Positioned.fill(
              child: DesktopUnifiedBackground(
                appState: appState,
                baseColor: background,
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 86, 20, 20),
              child: ClipRRect(
                borderRadius: BorderRadius.circular(30),
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    color: surfaceColor,
                    borderRadius: BorderRadius.circular(30),
                    border: Border.all(
                      color: surfaceBorder,
                    ),
                  ),
                  child: child,
                ),
              ),
            ),
            Align(
              alignment: Alignment.topCenter,
              child: Padding(
                padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
                child: _TopPill(
                  tabs: tabs,
                  selectedIndex: selectedIndex,
                  onSelected: onSelected,
                  title: title,
                  trailingLabel: trailingLabel,
                  trailingIcon: trailingIcon,
                  isDark: isDark,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class DesktopCinematicTab {
  const DesktopCinematicTab({
    required this.label,
    required this.icon,
  });

  final String label;
  final IconData icon;
}

class _TopPill extends StatelessWidget {
  const _TopPill({
    required this.tabs,
    required this.selectedIndex,
    required this.onSelected,
    required this.title,
    required this.trailingLabel,
    required this.trailingIcon,
    required this.isDark,
  });

  final List<DesktopCinematicTab> tabs;
  final int selectedIndex;
  final ValueChanged<int> onSelected;
  final String title;
  final String? trailingLabel;
  final IconData trailingIcon;
  final bool isDark;

  @override
  Widget build(BuildContext context) {
    final textTheme = Theme.of(context).textTheme;

    return LayoutBuilder(
      builder: (context, constraints) {
        final targetWidth =
            (constraints.maxWidth * 0.72).clamp(320.0, 980.0).toDouble();
        final width =
            targetWidth > constraints.maxWidth ? constraints.maxWidth : targetWidth;
        final panelColor = isDark
            ? const Color(0xD1111620)
            : const Color(0xECFFFFFF);
        final panelBorder = isDark
            ? Colors.white.withValues(alpha: 0.10)
            : Colors.black.withValues(alpha: 0.08);
        const activeBg = Color(0xFF3B82F6);
        final activeBorder = isDark
            ? const Color(0xFF60A5FA).withValues(alpha: 0.65)
            : const Color(0xFF2563EB).withValues(alpha: 0.45);
        final inactiveFg =
            isDark ? const Color(0xFFB6BDC8) : const Color(0xFF4B5563);
        const activeFg = Colors.white;
        final badgeBg = isDark
            ? Colors.white.withValues(alpha: 0.08)
            : Colors.black.withValues(alpha: 0.05);

        return DecoratedBox(
          decoration: BoxDecoration(
            color: panelColor,
            borderRadius: BorderRadius.circular(28),
            border: Border.all(color: panelBorder),
            boxShadow: [
              BoxShadow(
                color: isDark
                    ? Colors.black.withValues(alpha: 0.28)
                    : Colors.black.withValues(alpha: 0.10),
                blurRadius: 22,
                offset: const Offset(0, 10),
              ),
            ],
          ),
          child: SizedBox(
            width: width,
            child: Padding(
              padding: const EdgeInsets.fromLTRB(10, 10, 10, 10),
              child: Row(
                children: [
                  Text(
                    title,
                    style: textTheme.titleSmall?.copyWith(
                      color: isDark ? Colors.white : const Color(0xFF111827),
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Row(
                      children: [
                        for (var i = 0; i < tabs.length; i++) ...[
                          if (i > 0) const SizedBox(width: 8),
                          Expanded(
                            child: InkWell(
                              borderRadius: BorderRadius.circular(18),
                              onTap: () => onSelected(i),
                              child: AnimatedContainer(
                                duration: const Duration(milliseconds: 160),
                                curve: Curves.easeOut,
                                padding:
                                    const EdgeInsets.symmetric(vertical: 10),
                                decoration: BoxDecoration(
                                  color: i == selectedIndex
                                      ? activeBg
                                      : Colors.transparent,
                                  borderRadius: BorderRadius.circular(18),
                                  border: Border.all(
                                    color: i == selectedIndex
                                        ? activeBorder
                                        : Colors.transparent,
                                  ),
                                ),
                                child: Row(
                                  mainAxisAlignment: MainAxisAlignment.center,
                                  children: [
                                    Icon(
                                      tabs[i].icon,
                                      size: 18,
                                      color: i == selectedIndex
                                          ? activeFg
                                          : inactiveFg,
                                    ),
                                    const SizedBox(width: 8),
                                    Text(
                                      tabs[i].label,
                                      maxLines: 1,
                                      overflow: TextOverflow.ellipsis,
                                      style: textTheme.labelLarge?.copyWith(
                                        color: i == selectedIndex
                                            ? activeFg
                                            : inactiveFg,
                                        fontWeight: i == selectedIndex
                                            ? FontWeight.w600
                                            : FontWeight.w500,
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                            ),
                          ),
                        ],
                      ],
                    ),
                  ),
                  if ((trailingLabel ?? '').isNotEmpty) ...[
                    const SizedBox(width: 12),
                    Container(
                      constraints: const BoxConstraints(maxWidth: 220),
                      padding: const EdgeInsets.symmetric(
                        horizontal: 12,
                        vertical: 9,
                      ),
                      decoration: BoxDecoration(
                        color: badgeBg,
                        borderRadius: BorderRadius.circular(16),
                      ),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Icon(
                            trailingIcon,
                            size: 16,
                            color: inactiveFg,
                          ),
                          const SizedBox(width: 8),
                          Flexible(
                            child: Text(
                              trailingLabel!,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: textTheme.labelMedium?.copyWith(
                                color: inactiveFg,
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ],
                ],
              ),
            ),
          ),
        );
      },
    );
  }
}
