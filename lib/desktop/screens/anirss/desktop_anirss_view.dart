import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/providers/server_providers.dart';
import '../../../core/sources/anirss/anirss_tab.dart';
import 'desktop_anirss_home_tab.dart';
import 'desktop_anirss_settings_tab.dart';
import 'desktop_anirss_subscriptions_tab.dart';

/// 桌面端 Ani-rss 迷你应用视图：渲染在侧边栏壳的首页内容区。
/// 顶部为分段控件（首页/订阅/设置），下方 IndexedStack 切三个 Tab 主体。
class DesktopAniRssView extends ConsumerStatefulWidget {
  const DesktopAniRssView({super.key});

  @override
  ConsumerState<DesktopAniRssView> createState() => _DesktopAniRssViewState();
}

class _DesktopAniRssViewState extends ConsumerState<DesktopAniRssView> {
  int _index = 0;

  static const _tabs = AniRssTab.values;

  @override
  Widget build(BuildContext context) {
    final server = ref.watch(currentServerProvider);
    return Scaffold(
      body: Column(
        children: [
          _Header(
            title: server?.name ?? 'Ani-rss',
            tabs: _tabs,
            index: _index,
            onSelect: (i) => setState(() => _index = i),
          ),
          const Divider(height: 1),
          Expanded(
            child: IndexedStack(
              index: _index,
              children: const [
                DesktopAniRssHomeTab(),
                DesktopAniRssSubscriptionsTab(),
                DesktopAniRssSettingsTab(),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _Header extends StatelessWidget {
  final String title;
  final List<AniRssTab> tabs;
  final int index;
  final ValueChanged<int> onSelect;

  const _Header({
    required this.title,
    required this.tabs,
    required this.index,
    required this.onSelect,
  });

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(24, 18, 24, 12),
      child: Row(
        children: [
          const Icon(Icons.rss_feed_rounded, color: Color(0xFF5B8DEF)),
          const SizedBox(width: 10),
          Text(title,
              style:
                  const TextStyle(fontSize: 20, fontWeight: FontWeight.w700)),
          const Spacer(),
          _SegmentedTabs(tabs: tabs, index: index, onSelect: onSelect),
        ],
      ),
    );
  }
}

class _SegmentedTabs extends StatelessWidget {
  final List<AniRssTab> tabs;
  final int index;
  final ValueChanged<int> onSelect;

  const _SegmentedTabs({
    required this.tabs,
    required this.index,
    required this.onSelect,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      padding: const EdgeInsets.all(4),
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainerHighest.withValues(alpha: 0.4),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          for (var i = 0; i < tabs.length; i++)
            _SegmentButton(
              tab: tabs[i],
              selected: i == index,
              onTap: () => onSelect(i),
            ),
        ],
      ),
    );
  }
}

class _SegmentButton extends StatelessWidget {
  final AniRssTab tab;
  final bool selected;
  final VoidCallback onTap;

  const _SegmentButton({
    required this.tab,
    required this.selected,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final fg = selected
        ? theme.colorScheme.onSurface
        : theme.colorScheme.onSurfaceVariant;
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      child: GestureDetector(
        onTap: onTap,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 160),
          curve: Curves.easeOut,
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
          decoration: BoxDecoration(
            color: selected ? theme.colorScheme.surface : Colors.transparent,
            borderRadius: BorderRadius.circular(8),
            boxShadow: selected
                ? [
                    BoxShadow(
                      color: Colors.black.withValues(alpha: 0.08),
                      blurRadius: 8,
                      offset: const Offset(0, 2),
                    ),
                  ]
                : null,
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(selected ? tab.icon : tab.outlinedIcon, size: 18, color: fg),
              const SizedBox(width: 6),
              Text(
                tab.label,
                style: TextStyle(
                  fontSize: 13,
                  fontWeight: selected ? FontWeight.w600 : FontWeight.w500,
                  color: fg,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
