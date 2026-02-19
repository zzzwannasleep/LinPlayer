import 'dart:ui';

import 'package:flutter/material.dart';

import '../models/desktop_ui_language.dart';
import '../theme/desktop_theme_extension.dart';

enum DesktopHomeTab { home, favorites }

class DesktopTopBar extends StatelessWidget {
  const DesktopTopBar({
    super.key,
    required this.title,
    required this.serverName,
    required this.searchController,
    required this.onSearchSubmitted,
    required this.onSearchChanged,
    this.movieCount,
    this.seriesCount,
    this.statsLoading = false,
    this.language = DesktopUiLanguage.zhCn,
    this.showSearch = true,
    this.backEnabled = true,
    this.onBack,
    this.onToggleSidebar,
    this.onRefresh,
    this.onOpenRouteManager,
    this.onOpenSettings,
    this.homeTab = DesktopHomeTab.home,
    this.onHomeTabChanged,
    this.searchHint = '\u641c\u7d22\u5267\u96c6\u6216\u7535\u5f71',
  });

  final String title;
  final String serverName;
  final TextEditingController searchController;
  final ValueChanged<String> onSearchSubmitted;
  final ValueChanged<String> onSearchChanged;
  final int? movieCount;
  final int? seriesCount;
  final bool statsLoading;
  final DesktopUiLanguage language;
  final bool showSearch;
  final bool backEnabled;
  final VoidCallback? onBack;
  final VoidCallback? onToggleSidebar;
  final VoidCallback? onRefresh;
  final VoidCallback? onOpenRouteManager;
  final VoidCallback? onOpenSettings;
  final DesktopHomeTab homeTab;
  final ValueChanged<DesktopHomeTab>? onHomeTabChanged;
  final String searchHint;

  String _t({
    required String zh,
    required String en,
  }) {
    return language.pick(zh: zh, en: en);
  }

  @override
  Widget build(BuildContext context) {
    final theme = DesktopThemeExtension.of(context);
    final iconColor = theme.textPrimary;
    final background =
        showSearch ? theme.headerScrolledBackground : theme.headerBackground;
    final background2 = showSearch
        ? theme.headerScrolledBackground.withValues(alpha: 0.96)
        : theme.headerScrolledBackground.withValues(alpha: 0.86);

    return ClipRRect(
      borderRadius: BorderRadius.circular(14),
      child: BackdropFilter(
        filter: ImageFilter.blur(sigmaX: 12, sigmaY: 12),
        child: DecoratedBox(
          decoration: BoxDecoration(
            gradient: LinearGradient(
              begin: Alignment.topCenter,
              end: Alignment.bottomCenter,
              colors: [background, background2],
            ),
            borderRadius: BorderRadius.circular(14),
          ),
          child: SizedBox(
            height: 60,
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12),
              child: Row(
                children: [
                  SizedBox(
                    width: 560,
                    child: Row(
                      children: [
                        _HeaderIconButton(
                          icon: Icons.arrow_back_rounded,
                          tooltip:
                              _t(zh: '\u8fd4\u56de (Esc)', en: 'Back (Esc)'),
                          onTap: backEnabled ? onBack : null,
                          color: (backEnabled && onBack != null)
                              ? iconColor
                              : iconColor.withValues(alpha: 0.38),
                        ),
                        const SizedBox(width: 6),
                        _HeaderIconButton(
                          icon: Icons.menu_rounded,
                          tooltip: _t(zh: '\u83dc\u5355', en: 'Menu'),
                          onTap: onToggleSidebar,
                          color: onToggleSidebar != null
                              ? iconColor
                              : iconColor.withValues(alpha: 0.38),
                        ),
                        const SizedBox(width: 10),
                        _LogoBadge(theme: theme),
                        const SizedBox(width: 12),
                        Expanded(
                          child: _ServerSummaryBadge(
                            language: language,
                            serverName: serverName,
                            movieCount: movieCount,
                            seriesCount: seriesCount,
                            statsLoading: statsLoading,
                            theme: theme,
                          ),
                        ),
                      ],
                    ),
                  ),
                  Expanded(
                    child: Center(
                      child: showSearch
                          ? _SearchCenter(
                              title: title,
                              controller: searchController,
                              hintText: searchHint,
                              onSubmitted: onSearchSubmitted,
                              onChanged: onSearchChanged,
                              textColor: theme.textPrimary,
                            )
                          : _TopPillTabs(
                              language: language,
                              selected: homeTab,
                              onChanged: onHomeTabChanged,
                            ),
                    ),
                  ),
                  SizedBox(
                    width: 280,
                    child: Align(
                      alignment: Alignment.centerRight,
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          _HeaderIconButton(
                            icon: Icons.search_rounded,
                            tooltip: _t(zh: '\u641c\u7d22', en: 'Search'),
                            onTap: () =>
                                onSearchSubmitted(searchController.text),
                            color: iconColor,
                          ),
                          const SizedBox(width: 6),
                          _HeaderIconButton(
                            icon: Icons.alt_route_rounded,
                            tooltip: _t(
                              zh: '\u7ebf\u8def\u7ba1\u7406',
                              en: 'Route Manager',
                            ),
                            onTap: onOpenRouteManager,
                            color: iconColor,
                          ),
                          const SizedBox(width: 6),
                          _HeaderIconButton(
                            icon: Icons.settings_outlined,
                            tooltip: _t(zh: '\u8bbe\u7f6e', en: 'Settings'),
                            onTap: onOpenSettings,
                            color: iconColor,
                          ),
                          if (onRefresh != null && showSearch) ...[
                            const SizedBox(width: 6),
                            _HeaderIconButton(
                              icon: Icons.refresh_rounded,
                              tooltip: _t(zh: '\u5237\u65b0', en: 'Refresh'),
                              onTap: onRefresh,
                              color: iconColor,
                            ),
                          ],
                        ],
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

class _ServerSummaryBadge extends StatelessWidget {
  const _ServerSummaryBadge({
    required this.language,
    required this.serverName,
    required this.movieCount,
    required this.seriesCount,
    required this.statsLoading,
    required this.theme,
  });

  final DesktopUiLanguage language;
  final String serverName;
  final int? movieCount;
  final int? seriesCount;
  final bool statsLoading;
  final DesktopThemeExtension theme;

  String _t({
    required String zh,
    required String en,
  }) {
    return language.pick(zh: zh, en: en);
  }

  String _countText(int? value) {
    if (value != null) return '$value';
    return statsLoading ? '...' : '--';
  }

  @override
  Widget build(BuildContext context) {
    final normalizedName = serverName.trim();
    final title = normalizedName.isEmpty
        ? _t(zh: '\u672a\u547d\u540d\u670d\u52a1\u5668', en: 'Unnamed server')
        : normalizedName;
    final summary = '${_t(zh: '\u7535\u5f71', en: 'Movies')} '
        '${_countText(movieCount)} | '
        '${_t(zh: '\u5267\u96c6', en: 'Series')} '
        '${_countText(seriesCount)}';

    return Container(
      height: 42,
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      decoration: BoxDecoration(
        color: theme.surfaceElevated.withValues(alpha: 0.55),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: theme.border.withValues(alpha: 0.68)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Text(
            title,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              color: theme.textPrimary,
              fontSize: 13,
              height: 1.0,
              fontWeight: FontWeight.w600,
            ),
          ),
          const SizedBox(height: 4),
          Text(
            summary,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              color: theme.textMuted,
              fontSize: 11.5,
              height: 1.0,
              fontWeight: FontWeight.w500,
            ),
          ),
        ],
      ),
    );
  }
}

class _SearchCenter extends StatelessWidget {
  const _SearchCenter({
    required this.title,
    required this.controller,
    required this.hintText,
    required this.onSubmitted,
    required this.onChanged,
    required this.textColor,
  });

  final String title;
  final TextEditingController controller;
  final String hintText;
  final ValueChanged<String> onSubmitted;
  final ValueChanged<String> onChanged;
  final Color textColor;

  @override
  Widget build(BuildContext context) {
    final theme = DesktopThemeExtension.of(context);
    return ConstrainedBox(
      constraints: const BoxConstraints(maxWidth: 720),
      child: Row(
        children: [
          Flexible(
            flex: 3,
            child: Text(
              title,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                color: textColor,
                fontSize: 18,
                fontWeight: FontWeight.w700,
              ),
            ),
          ),
          const SizedBox(width: 14),
          Expanded(
            flex: 5,
            child: TextField(
              controller: controller,
              onChanged: onChanged,
              onSubmitted: onSubmitted,
              textInputAction: TextInputAction.search,
              style: TextStyle(color: theme.textPrimary, fontSize: 14),
              decoration: InputDecoration(
                isDense: true,
                hintText: hintText,
                hintStyle: TextStyle(
                  color: theme.textMuted.withValues(alpha: 0.9),
                  fontSize: 13,
                ),
                prefixIcon: Icon(
                  Icons.search_rounded,
                  size: 20,
                  color: theme.textMuted,
                ),
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(999),
                  borderSide: BorderSide(color: theme.border),
                ),
                enabledBorder: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(999),
                  borderSide: BorderSide(color: theme.border),
                ),
                focusedBorder: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(999),
                  borderSide: BorderSide(color: theme.focus, width: 1.4),
                ),
                fillColor: theme.surfaceElevated.withValues(alpha: 0.78),
                filled: true,
                contentPadding:
                    const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _LogoBadge extends StatelessWidget {
  const _LogoBadge({required this.theme});

  final DesktopThemeExtension theme;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        ClipRRect(
          borderRadius: BorderRadius.circular(8),
          child: SizedBox(
            width: 30,
            height: 30,
            child: Image.asset(
              'assets/app_icon.jpg',
              fit: BoxFit.cover,
            ),
          ),
        ),
        const SizedBox(width: 8),
        Text(
          'LinPlayer',
          style: TextStyle(
            color: theme.textPrimary,
            fontSize: 24,
            fontWeight: FontWeight.w500,
            letterSpacing: 0.2,
          ),
        ),
      ],
    );
  }
}

class _TopPillTabs extends StatelessWidget {
  const _TopPillTabs({
    required this.language,
    required this.selected,
    required this.onChanged,
  });

  final DesktopUiLanguage language;
  final DesktopHomeTab selected;
  final ValueChanged<DesktopHomeTab>? onChanged;

  String _t({
    required String zh,
    required String en,
  }) {
    return language.pick(zh: zh, en: en);
  }

  @override
  Widget build(BuildContext context) {
    final theme = DesktopThemeExtension.of(context);
    final homeActive = selected == DesktopHomeTab.home;

    return Container(
      width: 248,
      height: 40,
      padding: const EdgeInsets.all(3.5),
      decoration: BoxDecoration(
        color: theme.topTabBackground,
        borderRadius: BorderRadius.circular(24),
        border: Border.all(color: theme.border.withValues(alpha: 0.8)),
      ),
      child: Stack(
        fit: StackFit.expand,
        children: [
          AnimatedAlign(
            duration: const Duration(milliseconds: 280),
            curve: Curves.easeOutBack,
            alignment:
                homeActive ? Alignment.centerLeft : Alignment.centerRight,
            child: FractionallySizedBox(
              widthFactor: 0.5,
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 1),
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    color: theme.topTabActiveBackground,
                    borderRadius: BorderRadius.circular(18),
                    boxShadow: [
                      BoxShadow(
                        color: theme.accent.withValues(alpha: 0.22),
                        blurRadius: 10,
                        offset: const Offset(0, 2),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
          Row(
            children: [
              Expanded(
                child: _TopPillActionButton(
                  label: _t(zh: '\u4e3b\u9875', en: 'Home'),
                  active: selected == DesktopHomeTab.home,
                  activeColor: theme.textPrimary,
                  inactiveColor: theme.topTabInactiveForeground,
                  onTap: onChanged == null
                      ? null
                      : () => onChanged!(DesktopHomeTab.home),
                ),
              ),
              Expanded(
                child: _TopPillActionButton(
                  label: _t(zh: '\u559c\u6b22', en: 'Favorites'),
                  active: selected == DesktopHomeTab.favorites,
                  activeColor: theme.textPrimary,
                  inactiveColor: theme.topTabInactiveForeground,
                  onTap: onChanged == null
                      ? null
                      : () => onChanged!(DesktopHomeTab.favorites),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _TopPillActionButton extends StatefulWidget {
  const _TopPillActionButton({
    required this.label,
    required this.active,
    required this.activeColor,
    required this.inactiveColor,
    this.onTap,
  });

  final String label;
  final bool active;
  final Color activeColor;
  final Color inactiveColor;
  final VoidCallback? onTap;

  @override
  State<_TopPillActionButton> createState() => _TopPillActionButtonState();
}

class _TopPillActionButtonState extends State<_TopPillActionButton> {
  bool _hovered = false;
  bool _pressed = false;

  @override
  Widget build(BuildContext context) {
    final enabled = widget.onTap != null;
    final scale = _pressed ? 0.96 : (_hovered ? 1.02 : 1.0);
    final slide = _pressed
        ? const Offset(0, 0.05)
        : (_hovered ? const Offset(0, -0.03) : Offset.zero);

    return MouseRegion(
      cursor: enabled ? SystemMouseCursors.click : SystemMouseCursors.basic,
      onEnter: (_) => setState(() => _hovered = true),
      onExit: (_) {
        if (!_hovered && !_pressed) return;
        setState(() {
          _hovered = false;
          _pressed = false;
        });
      },
      child: AnimatedScale(
        scale: scale,
        duration: const Duration(milliseconds: 140),
        curve: Curves.easeOutCubic,
        child: AnimatedSlide(
          offset: slide,
          duration: const Duration(milliseconds: 140),
          curve: Curves.easeOutCubic,
          child: Material(
            color: Colors.transparent,
            child: InkWell(
              borderRadius: BorderRadius.circular(18),
              onTap: widget.onTap,
              onTapDown:
                  enabled ? (_) => setState(() => _pressed = true) : null,
              onTapCancel:
                  enabled ? () => setState(() => _pressed = false) : null,
              onTapUp: enabled ? (_) => setState(() => _pressed = false) : null,
              child: Center(
                child: AnimatedDefaultTextStyle(
                  duration: const Duration(milliseconds: 150),
                  curve: Curves.easeOutCubic,
                  style: TextStyle(
                    color: widget.active
                        ? widget.activeColor
                        : widget.inactiveColor,
                    fontSize: 14,
                    fontWeight:
                        widget.active ? FontWeight.w700 : FontWeight.w500,
                  ),
                  child: Text(widget.label),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _HeaderIconButton extends StatefulWidget {
  const _HeaderIconButton({
    required this.icon,
    required this.tooltip,
    required this.color,
    this.onTap,
  });

  final IconData icon;
  final String tooltip;
  final Color color;
  final VoidCallback? onTap;

  @override
  State<_HeaderIconButton> createState() => _HeaderIconButtonState();
}

class _HeaderIconButtonState extends State<_HeaderIconButton> {
  bool _hovered = false;
  bool _pressed = false;

  @override
  Widget build(BuildContext context) {
    final theme = DesktopThemeExtension.of(context);
    final enabled = widget.onTap != null;
    final scale = _pressed ? 0.9 : (_hovered ? 1.05 : 1.0);
    final slide = _pressed
        ? const Offset(0, 0.06)
        : (_hovered ? const Offset(0, -0.04) : Offset.zero);
    final background = _pressed
        ? theme.topTabActiveBackground.withValues(alpha: 0.86)
        : (_hovered
            ? theme.topTabBackground.withValues(alpha: 0.9)
            : Colors.transparent);

    return Tooltip(
      message: widget.tooltip,
      child: MouseRegion(
        cursor: enabled ? SystemMouseCursors.click : SystemMouseCursors.basic,
        onEnter: (_) => setState(() => _hovered = true),
        onExit: (_) {
          if (!_hovered && !_pressed) return;
          setState(() {
            _hovered = false;
            _pressed = false;
          });
        },
        child: AnimatedScale(
          scale: scale,
          duration: const Duration(milliseconds: 130),
          curve: Curves.easeOutCubic,
          child: AnimatedSlide(
            offset: slide,
            duration: const Duration(milliseconds: 130),
            curve: Curves.easeOutCubic,
            child: AnimatedContainer(
              duration: const Duration(milliseconds: 160),
              curve: Curves.easeOutCubic,
              width: 34,
              height: 34,
              decoration: BoxDecoration(
                color: background,
                borderRadius: BorderRadius.circular(18),
                border: Border.all(
                  color: (_hovered || _pressed)
                      ? theme.border.withValues(alpha: 0.84)
                      : Colors.transparent,
                ),
                boxShadow: (_hovered || _pressed)
                    ? [
                        BoxShadow(
                          color: theme.shadowColor.withValues(alpha: 0.45),
                          blurRadius: 10,
                          offset: const Offset(0, 3),
                        ),
                      ]
                    : const [],
              ),
              child: Material(
                color: Colors.transparent,
                child: InkWell(
                  borderRadius: BorderRadius.circular(18),
                  onTap: widget.onTap,
                  onTapDown:
                      enabled ? (_) => setState(() => _pressed = true) : null,
                  onTapCancel:
                      enabled ? () => setState(() => _pressed = false) : null,
                  onTapUp:
                      enabled ? (_) => setState(() => _pressed = false) : null,
                  child: Icon(widget.icon, size: 22, color: widget.color),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
