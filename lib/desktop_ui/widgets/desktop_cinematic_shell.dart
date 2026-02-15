import 'dart:ui';

import 'package:flutter/material.dart';

class DesktopCinematicShell extends StatelessWidget {
  const DesktopCinematicShell({
    super.key,
    required this.tabs,
    required this.selectedIndex,
    required this.onSelected,
    required this.child,
    required this.title,
    this.trailingLabel,
    this.trailingIcon = Icons.dns_outlined,
  });

  final List<DesktopCinematicTab> tabs;
  final int selectedIndex;
  final ValueChanged<int> onSelected;
  final Widget child;
  final String title;
  final String? trailingLabel;
  final IconData trailingIcon;

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final background = isDark ? const Color(0xFF060607) : const Color(0xFFF2F4F7);
    final surfaceColor = isDark
        ? const Color(0xCC121212)
        : const Color(0xCCFFFFFF);
    final surfaceBorder = isDark
        ? Colors.white.withValues(alpha: 0.12)
        : Colors.black.withValues(alpha: 0.08);

    return Scaffold(
      backgroundColor: background,
      body: SafeArea(
        child: Stack(
          children: [
            Positioned.fill(child: _DesktopBackdrop(isDark: isDark)),
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
            ? const Color(0xCC1E1E1E)
            : const Color(0xD9FFFFFF);
        final panelBorder = isDark
            ? Colors.white.withValues(alpha: 0.14)
            : Colors.black.withValues(alpha: 0.08);
        final activeBg = isDark
            ? Colors.white.withValues(alpha: 0.16)
            : Colors.black.withValues(alpha: 0.08);
        final activeBorder = isDark
            ? Colors.white.withValues(alpha: 0.3)
            : Colors.black.withValues(alpha: 0.12);
        final inactiveFg = isDark ? Colors.white70 : Colors.black54;
        final activeFg = isDark ? Colors.white : Colors.black87;
        final badgeBg = isDark
            ? Colors.white.withValues(alpha: 0.08)
            : Colors.black.withValues(alpha: 0.05);

        return _GlassPanel(
          blurSigma: 16,
          color: panelColor,
          borderRadius: BorderRadius.circular(28),
          borderColor: panelBorder,
          child: SizedBox(
            width: width,
            child: Padding(
              padding: const EdgeInsets.fromLTRB(10, 10, 10, 10),
              child: Row(
                children: [
                  Text(
                    title,
                    style: textTheme.titleSmall?.copyWith(
                      color: activeFg,
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

class _DesktopBackdrop extends StatelessWidget {
  const _DesktopBackdrop({required this.isDark});

  final bool isDark;

  @override
  Widget build(BuildContext context) {
    return DecoratedBox(
      decoration: BoxDecoration(
        gradient: RadialGradient(
          center: const Alignment(-0.25, -0.85),
          radius: 1.4,
          colors: isDark
              ? [
                  const Color(0xFF1D1F2A).withValues(alpha: 0.7),
                  const Color(0xFF0D0D10),
                  const Color(0xFF040405),
                ]
              : [
                  const Color(0xFFE7ECF8),
                  const Color(0xFFF2F4F7),
                  const Color(0xFFEEF2F7),
                ],
        ),
      ),
      child: Stack(
        children: [
          Positioned(
            left: -120,
            top: -160,
            child: _GlowCircle(
              size: 420,
              color: isDark
                  ? const Color(0xFF4267D9).withValues(alpha: 0.25)
                  : const Color(0xFF5A82E0).withValues(alpha: 0.16),
            ),
          ),
          Positioned(
            right: -80,
            bottom: -120,
            child: _GlowCircle(
              size: 360,
              color: isDark
                  ? const Color(0xFFB54B72).withValues(alpha: 0.18)
                  : const Color(0xFFE283A4).withValues(alpha: 0.14),
            ),
          ),
        ],
      ),
    );
  }
}

class _GlowCircle extends StatelessWidget {
  const _GlowCircle({required this.size, required this.color});

  final double size;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return IgnorePointer(
      child: ClipOval(
        child: ImageFiltered(
          imageFilter: ImageFilter.blur(sigmaX: 80, sigmaY: 80),
          child: Container(
            width: size,
            height: size,
            color: color,
          ),
        ),
      ),
    );
  }
}

class _GlassPanel extends StatelessWidget {
  const _GlassPanel({
    required this.child,
    required this.blurSigma,
    required this.color,
    required this.borderRadius,
    required this.borderColor,
  });

  final Widget child;
  final double blurSigma;
  final Color color;
  final BorderRadius borderRadius;
  final Color borderColor;

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    return ClipRRect(
      borderRadius: borderRadius,
      child: BackdropFilter(
        filter: ImageFilter.blur(sigmaX: blurSigma, sigmaY: blurSigma),
        child: DecoratedBox(
          decoration: BoxDecoration(
            color: color,
            borderRadius: borderRadius,
            border: Border.all(color: borderColor),
            boxShadow: [
              BoxShadow(
                color: isDark
                    ? Colors.black.withValues(alpha: 0.35)
                    : Colors.black.withValues(alpha: 0.12),
                blurRadius: 24,
                offset: const Offset(0, 16),
              ),
            ],
          ),
          child: child,
        ),
      ),
    );
  }
}
