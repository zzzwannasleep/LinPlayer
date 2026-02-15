import 'dart:ui';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:lin_player_prefs/lin_player_prefs.dart';
import 'package:lin_player_state/lin_player_state.dart';

import '../../aggregate_service_page.dart';
import '../../player_screen.dart';
import '../../player_screen_exo.dart';
import '../../settings_page.dart';
import '../widgets/desktop_cinematic_shell.dart';

class DesktopHomePage extends StatefulWidget {
  const DesktopHomePage({super.key, required this.appState});

  final AppState appState;

  @override
  State<DesktopHomePage> createState() => _DesktopHomePageState();
}

class _DesktopHomePageState extends State<DesktopHomePage> {
  int _topNavIndex = 0;
  int _sideTabIndex = 0;
  int _selectedCardIndex = 0;

  static const _topNavEntries = <DesktopCinematicTab>[
    DesktopCinematicTab(label: 'Now Playing', icon: Icons.play_circle_outline),
    DesktopCinematicTab(label: 'Discover', icon: Icons.hub_outlined),
    DesktopCinematicTab(label: 'Local', icon: Icons.folder_open_outlined),
    DesktopCinematicTab(label: 'Settings', icon: Icons.settings_outlined),
  ];

  static const _rightTabs = <String>[
    'Watch Next',
    'Trending',
    'Recommended',
  ];

  static const _recommendationGroups = <List<_RecommendationItem>>[
    [
      _RecommendationItem(
        title: 'War in Ukraine and what it means for the world order',
        meta: '3.84M views | Mar 2022',
        season: 'Season 2 - Episode 1',
        duration: '12:34',
        palette: [Color(0xFF2E3A54), Color(0xFF6A8AA6)],
      ),
      _RecommendationItem(
        title: 'How urban running shoes changed modern street style',
        meta: '1.29M views | Nov 2023',
        season: 'Season 1 - Episode 9',
        duration: '08:16',
        palette: [Color(0xFF4A2F3B), Color(0xFF8A5D74)],
      ),
      _RecommendationItem(
        title: 'Inside the design process of terrain-ready sneakers',
        meta: '986K views | Jan 2024',
        season: 'Season 3 - Episode 4',
        duration: '10:41',
        palette: [Color(0xFF2D4A45), Color(0xFF6CA39A)],
      ),
      _RecommendationItem(
        title: 'The comeback story of classic runners from the 2000s',
        meta: '742K views | Sep 2024',
        season: 'Season 2 - Episode 6',
        duration: '14:02',
        palette: [Color(0xFF4E4330), Color(0xFF9A8660)],
      ),
    ],
    [
      _RecommendationItem(
        title: 'Tokyo midnight visual tour for product cinematography',
        meta: '2.66M views | Dec 2025',
        season: 'Season 5 - Episode 2',
        duration: '06:57',
        palette: [Color(0xFF2B264D), Color(0xFF655AB0)],
      ),
      _RecommendationItem(
        title: 'Minimal techwear collection breakdown and styling notes',
        meta: '1.12M views | Oct 2025',
        season: 'Season 4 - Episode 7',
        duration: '11:09',
        palette: [Color(0xFF203745), Color(0xFF4D7D98)],
      ),
      _RecommendationItem(
        title: 'Camera movement tricks for smooth fashion B-roll',
        meta: '901K views | Aug 2025',
        season: 'Season 1 - Episode 3',
        duration: '09:48',
        palette: [Color(0xFF47313D), Color(0xFF8B6179)],
      ),
      _RecommendationItem(
        title: 'Color grading dark scenes without losing texture',
        meta: '689K views | Jul 2025',
        season: 'Season 2 - Episode 8',
        duration: '07:26',
        palette: [Color(0xFF2F4032), Color(0xFF688D6E)],
      ),
    ],
    [
      _RecommendationItem(
        title: 'New balance heiro and 850 terrain shoes deep review',
        meta: '1.87M views | Feb 2026',
        season: 'Season 1 - Episode 1',
        duration: '15:20',
        palette: [Color(0xFF2A3F60), Color(0xFF6396D2)],
      ),
      _RecommendationItem(
        title: 'Layered outfits pairing guide for trail sneakers',
        meta: '1.04M views | Jan 2026',
        season: 'Season 3 - Episode 11',
        duration: '10:55',
        palette: [Color(0xFF4D2F2F), Color(0xFFA36868)],
      ),
      _RecommendationItem(
        title: 'Building the perfect watch next queue on desktop',
        meta: '534K views | Jan 2026',
        season: 'Season 1 - Episode 5',
        duration: '05:42',
        palette: [Color(0xFF2D474D), Color(0xFF639EA8)],
      ),
      _RecommendationItem(
        title: 'Audio and subtitle setup for long-form sessions',
        meta: '487K views | Dec 2025',
        season: 'Season 2 - Episode 10',
        duration: '09:13',
        palette: [Color(0xFF493C27), Color(0xFF937847)],
      ),
    ],
  ];

  @override
  Widget build(BuildContext context) {
    final useExoCore = !kIsWeb &&
        defaultTargetPlatform == TargetPlatform.android &&
        widget.appState.playerCore == PlayerCore.exo;

    final content = switch (_topNavIndex) {
      0 => _buildNowPlayingWorkspace(context),
      1 => AggregateServicePage(appState: widget.appState),
      2 => useExoCore
          ? ExoPlayerScreen(appState: widget.appState)
          : PlayerScreen(appState: widget.appState),
      _ => SettingsPage(appState: widget.appState),
    };

    return DesktopCinematicShell(
      title: 'Playback',
      tabs: _topNavEntries,
      selectedIndex: _topNavIndex,
      onSelected: (index) => setState(() => _topNavIndex = index),
      trailingLabel: widget.appState.activeServer?.name ?? 'Lin Player',
      trailingIcon: Icons.play_circle_outline,
      child: AnimatedSwitcher(
        duration: const Duration(milliseconds: 180),
        switchInCurve: Curves.easeOutCubic,
        switchOutCurve: Curves.easeInCubic,
        child: KeyedSubtree(
          key: ValueKey<int>(_topNavIndex),
          child: content,
        ),
      ),
    );
  }

  Widget _buildNowPlayingWorkspace(BuildContext context) {
    final cards = _recommendationGroups[_sideTabIndex];
    final selectedCard =
        cards[_selectedCardIndex.clamp(0, cards.length - 1).toInt()];

    return LayoutBuilder(
      builder: (context, constraints) {
        final showRightPanel = constraints.maxWidth >= 1120;
        final panelWidth = showRightPanel
            ? (constraints.maxWidth * 0.28).clamp(320.0, 420.0).toDouble()
            : constraints.maxWidth;
        final playerHeight = (constraints.maxHeight *
                (showRightPanel ? 0.62 : 0.5))
            .clamp(220.0, showRightPanel ? 620.0 : 520.0)
            .toDouble();
        final compactPanelHeight = constraints.maxHeight - playerHeight - 18;
        final showCompactPanel = !showRightPanel && compactPanelHeight > 140;

        final playerSurface = SizedBox(
          height: playerHeight,
          child: _MainPlayerSurface(
            title: 'New balance heiro and 850 terrain shoes',
            subtitle: 'New Balance - Heiro',
            accent: selectedCard.palette.last,
          ),
        );

        return Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Expanded(
              child: Column(
                children: [
                  playerSurface,
                  if (showCompactPanel) ...[
                    const SizedBox(height: 18),
                    SizedBox(
                      height: compactPanelHeight,
                      child: _RightPanel(
                        tabs: _rightTabs,
                        selectedTab: _sideTabIndex,
                        onTabChanged: (index) {
                          setState(() {
                            _sideTabIndex = index;
                            _selectedCardIndex = 0;
                          });
                        },
                        items: cards,
                        selectedCard: _selectedCardIndex,
                        onCardSelected: (index) =>
                            setState(() => _selectedCardIndex = index),
                      ),
                    ),
                  ],
                ],
              ),
            ),
            if (showRightPanel) ...[
              const SizedBox(width: 22),
              SizedBox(
                width: panelWidth,
                height: playerHeight,
                child: _RightPanel(
                  tabs: _rightTabs,
                  selectedTab: _sideTabIndex,
                  onTabChanged: (index) {
                    setState(() {
                      _sideTabIndex = index;
                      _selectedCardIndex = 0;
                    });
                  },
                  items: cards,
                  selectedCard: _selectedCardIndex,
                  onCardSelected: (index) =>
                      setState(() => _selectedCardIndex = index),
                ),
              ),
            ],
          ],
        );
      },
    );
  }
}

class _MainPlayerSurface extends StatelessWidget {
  const _MainPlayerSurface({
    required this.title,
    required this.subtitle,
    required this.accent,
  });

  final String title;
  final String subtitle;
  final Color accent;

  @override
  Widget build(BuildContext context) {
    final textTheme = Theme.of(context).textTheme;
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final surfaceColor =
        isDark ? const Color(0x96141416) : const Color(0xCCFFFFFF);
    final surfaceBorder = isDark
        ? Colors.white.withValues(alpha: 0.14)
        : Colors.black.withValues(alpha: 0.08);
    final chipBg = isDark
        ? Colors.black.withValues(alpha: 0.36)
        : Colors.white.withValues(alpha: 0.72);
    final chipFg = isDark ? Colors.white : Colors.black87;
    final controlColor = isDark
        ? const Color(0xD9101011)
        : const Color(0xE6FFFFFF);
    final controlBorder = isDark
        ? Colors.white.withValues(alpha: 0.12)
        : Colors.black.withValues(alpha: 0.08);
    final titleColor = isDark ? Colors.white : Colors.black87;
    final subtitleColor = isDark ? Colors.white70 : Colors.black54;
    final iconColor = isDark ? Colors.white70 : Colors.black54;
    final primaryIconColor = isDark ? Colors.white : Colors.black87;
    final dividerColor = isDark
        ? Colors.white.withValues(alpha: 0.15)
        : Colors.black.withValues(alpha: 0.12);
    final playerGradient = isDark
        ? [
            const Color(0xFF1B2A49),
            accent.withValues(alpha: 0.85),
            const Color(0xFF402338),
          ]
        : [
            const Color(0xFFE7EEFF),
            accent.withValues(alpha: 0.4),
            const Color(0xFFFDE8F2),
          ];
    final thumbGradient = isDark
        ? [accent.withValues(alpha: 0.8), const Color(0xFF1F2F4A)]
        : [accent.withValues(alpha: 0.55), const Color(0xFFD7E1FB)];

    return _GlassPanel(
      blurSigma: 14,
      color: surfaceColor,
      borderRadius: BorderRadius.circular(30),
      borderColor: surfaceBorder,
      child: ClipRRect(
        borderRadius: BorderRadius.circular(30),
        child: Stack(
          fit: StackFit.expand,
          children: [
            DecoratedBox(
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  begin: Alignment.topLeft,
                  end: Alignment.bottomRight,
                  colors: playerGradient,
                ),
              ),
            ),
            Positioned(
              left: 28,
              top: 24,
              child: Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 12, vertical: 7),
                decoration: BoxDecoration(
                  color: chipBg,
                  borderRadius: BorderRadius.circular(14),
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(
                      Icons.play_arrow_rounded,
                      color: chipFg,
                      size: 16,
                    ),
                    const SizedBox(width: 6),
                    Text(
                      'Now Playing',
                      style: textTheme.labelMedium?.copyWith(
                        color: chipFg,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ],
                ),
              ),
            ),
            Positioned(
              left: 26,
              right: 26,
              bottom: 20,
              child: _GlassPanel(
                blurSigma: 18,
                color: controlColor,
                borderRadius: BorderRadius.circular(24),
                borderColor: controlBorder,
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(14, 10, 14, 10),
                  child: Row(
                    children: [
                      const _ControlIcon(icon: Icons.fast_rewind_rounded),
                      const _ControlIcon(
                        icon: Icons.pause_rounded,
                        emphasized: true,
                      ),
                      const _ControlIcon(icon: Icons.fast_forward_rounded),
                      const SizedBox(width: 10),
                      Container(
                        width: 1,
                        height: 34,
                        color: dividerColor,
                      ),
                      const SizedBox(width: 12),
                      ClipRRect(
                        borderRadius: BorderRadius.circular(10),
                        child: Container(
                          width: 44,
                          height: 44,
                          decoration: BoxDecoration(
                            gradient: LinearGradient(
                              colors: thumbGradient,
                            ),
                          ),
                        ),
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              title,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: textTheme.titleSmall?.copyWith(
                                color: titleColor,
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                            const SizedBox(height: 2),
                            Text(
                              subtitle,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: textTheme.bodySmall?.copyWith(
                                color: subtitleColor,
                              ),
                            ),
                          ],
                        ),
                      ),
                      Icon(Icons.more_horiz, color: iconColor),
                      const SizedBox(width: 14),
                      Container(
                        width: 1,
                        height: 34,
                        color: dividerColor,
                      ),
                      const SizedBox(width: 10),
                      Icon(Icons.closed_caption_outlined, color: iconColor),
                      const SizedBox(width: 12),
                      Icon(Icons.playlist_play, color: iconColor),
                      const SizedBox(width: 12),
                      Icon(Icons.volume_up_outlined, color: primaryIconColor),
                    ],
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _RightPanel extends StatelessWidget {
  const _RightPanel({
    required this.tabs,
    required this.selectedTab,
    required this.onTabChanged,
    required this.items,
    required this.selectedCard,
    required this.onCardSelected,
  });

  final List<String> tabs;
  final int selectedTab;
  final ValueChanged<int> onTabChanged;
  final List<_RecommendationItem> items;
  final int selectedCard;
  final ValueChanged<int> onCardSelected;

  @override
  Widget build(BuildContext context) {
    final textTheme = Theme.of(context).textTheme;
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final panelColor =
        isDark ? const Color(0xA61A1A1C) : const Color(0xD9FFFFFF);
    final panelBorder = isDark
        ? Colors.white.withValues(alpha: 0.14)
        : Colors.black.withValues(alpha: 0.08);
    final tabPanelColor =
        isDark ? const Color(0xB31C1C1F) : const Color(0xF2FFFFFF);
    final tabPanelBorder = isDark
        ? Colors.white.withValues(alpha: 0.08)
        : Colors.black.withValues(alpha: 0.06);
    final activeTabBg = isDark
        ? Colors.white.withValues(alpha: 0.14)
        : Colors.black.withValues(alpha: 0.08);
    final activeText = isDark ? Colors.white : Colors.black87;
    final inactiveText = isDark ? Colors.white54 : Colors.black54;
    final cardBg = isDark
        ? Colors.white.withValues(alpha: 0.06)
        : Colors.white.withValues(alpha: 0.78);
    final selectedCardBorder = isDark
        ? Colors.white.withValues(alpha: 0.34)
        : Colors.black.withValues(alpha: 0.2);
    final normalCardBorder = isDark
        ? Colors.white.withValues(alpha: 0.09)
        : Colors.black.withValues(alpha: 0.08);
    final metaColor = isDark ? Colors.white54 : Colors.black54;
    final bodyColor = isDark ? Colors.white : Colors.black87;
    final subColor = isDark ? Colors.white60 : Colors.black54;
    final durationBg = isDark
        ? Colors.black.withValues(alpha: 0.58)
        : Colors.black.withValues(alpha: 0.66);

    return _GlassPanel(
      blurSigma: 14,
      color: panelColor,
      borderRadius: BorderRadius.circular(26),
      borderColor: panelBorder,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(14, 14, 14, 12),
        child: Column(
          children: [
            _GlassPanel(
              blurSigma: 12,
              color: tabPanelColor,
              borderRadius: BorderRadius.circular(16),
              borderColor: tabPanelBorder,
              child: Padding(
                padding: const EdgeInsets.all(6),
                child: Row(
                  children: [
                    for (var i = 0; i < tabs.length; i++) ...[
                      if (i > 0) const SizedBox(width: 6),
                      Expanded(
                        child: InkWell(
                          borderRadius: BorderRadius.circular(12),
                          onTap: () => onTabChanged(i),
                          child: AnimatedContainer(
                            duration: const Duration(milliseconds: 140),
                            padding: const EdgeInsets.symmetric(vertical: 8),
                            decoration: BoxDecoration(
                              color: i == selectedTab
                                  ? activeTabBg
                                  : Colors.transparent,
                              borderRadius: BorderRadius.circular(12),
                            ),
                            child: Center(
                              child: Text(
                                tabs[i],
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: textTheme.labelMedium?.copyWith(
                                  color: i == selectedTab
                                      ? activeText
                                      : inactiveText,
                                  fontWeight: i == selectedTab
                                      ? FontWeight.w600
                                      : FontWeight.w500,
                                ),
                              ),
                            ),
                          ),
                        ),
                      ),
                    ],
                  ],
                ),
              ),
            ),
            const SizedBox(height: 12),
            Expanded(
              child: ListView.separated(
                itemCount: items.length,
                separatorBuilder: (_, __) => const SizedBox(height: 12),
                itemBuilder: (context, index) {
                  final item = items[index];
                  final selected = index == selectedCard;

                  return InkWell(
                    onTap: () => onCardSelected(index),
                    borderRadius: BorderRadius.circular(16),
                    child: AnimatedContainer(
                      duration: const Duration(milliseconds: 140),
                      padding: const EdgeInsets.all(10),
                      decoration: BoxDecoration(
                        color: cardBg,
                        borderRadius: BorderRadius.circular(16),
                        border: Border.all(
                          color: selected
                              ? selectedCardBorder
                              : normalCardBorder,
                        ),
                      ),
                      child: Row(
                        children: [
                          ClipRRect(
                            borderRadius: BorderRadius.circular(12),
                            child: SizedBox(
                              width: 126,
                              height: 82,
                              child: Stack(
                                fit: StackFit.expand,
                                children: [
                                  DecoratedBox(
                                    decoration: BoxDecoration(
                                      gradient: LinearGradient(
                                        begin: Alignment.topLeft,
                                        end: Alignment.bottomRight,
                                        colors: item.palette,
                                      ),
                                    ),
                                  ),
                                  Positioned(
                                    right: 6,
                                    bottom: 6,
                                    child: Container(
                                      padding: const EdgeInsets.symmetric(
                                          horizontal: 6, vertical: 2),
                                      decoration: BoxDecoration(
                                        color: durationBg,
                                        borderRadius: BorderRadius.circular(8),
                                      ),
                                      child: Text(
                                        item.duration,
                                        style: textTheme.labelSmall?.copyWith(
                                          color: Colors.white,
                                          fontSize: 11,
                                        ),
                                      ),
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          ),
                          const SizedBox(width: 10),
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(
                                  item.meta,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: textTheme.labelSmall?.copyWith(
                                    color: metaColor,
                                  ),
                                ),
                                const SizedBox(height: 4),
                                Text(
                                  item.title,
                                  maxLines: 2,
                                  overflow: TextOverflow.ellipsis,
                                  style: textTheme.bodyMedium?.copyWith(
                                    color: bodyColor,
                                    fontWeight: FontWeight.w600,
                                    height: 1.22,
                                  ),
                                ),
                                const SizedBox(height: 4),
                                Text(
                                  item.season,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: textTheme.bodySmall?.copyWith(
                                    color: subColor,
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ],
                      ),
                    ),
                  );
                },
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _ControlIcon extends StatelessWidget {
  const _ControlIcon({required this.icon, this.emphasized = false});

  final IconData icon;
  final bool emphasized;

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final bg = emphasized
        ? (isDark
            ? Colors.white.withValues(alpha: 0.22)
            : Colors.black.withValues(alpha: 0.12))
        : (isDark
            ? Colors.white.withValues(alpha: 0.1)
            : Colors.black.withValues(alpha: 0.06));
    final fg = emphasized
        ? (isDark ? Colors.white : Colors.black87)
        : (isDark ? Colors.white70 : Colors.black54);

    return Container(
      margin: const EdgeInsets.only(right: 6),
      width: 36,
      height: 36,
      decoration: BoxDecoration(
        color: bg,
        borderRadius: BorderRadius.circular(12),
      ),
      child: Icon(
        icon,
        size: 20,
        color: fg,
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

class _RecommendationItem {
  const _RecommendationItem({
    required this.title,
    required this.meta,
    required this.season,
    required this.duration,
    required this.palette,
  });

  final String title;
  final String meta;
  final String season;
  final String duration;
  final List<Color> palette;
}

