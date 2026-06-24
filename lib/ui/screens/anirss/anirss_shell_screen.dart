import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/providers/server_providers.dart';
import '../../../core/sources/anirss/anirss_tab.dart';
import 'anirss_home_tab.dart';
import 'anirss_settings_tab.dart';
import 'anirss_subscriptions_tab.dart';

/// Ani-rss 迷你应用外壳（移动端）：自带底部 3 Tab。
/// 经 `/browse` 全屏路由进入（当 currentServer.sourceKind == anirss）。
class AniRssShellScreen extends ConsumerStatefulWidget {
  const AniRssShellScreen({super.key});

  @override
  ConsumerState<AniRssShellScreen> createState() => _AniRssShellScreenState();
}

class _AniRssShellScreenState extends ConsumerState<AniRssShellScreen> {
  int _index = 0;

  static const _tabs = AniRssTab.values;

  @override
  Widget build(BuildContext context) {
    final server = ref.watch(currentServerProvider);
    return Scaffold(
      appBar: AppBar(
        title: Text(server?.name ?? 'Ani-rss'),
        centerTitle: false,
      ),
      body: IndexedStack(
        index: _index,
        children: const [
          AniRssHomeTab(),
          AniRssSubscriptionsTab(),
          AniRssSettingsTab(),
        ],
      ),
      bottomNavigationBar: NavigationBar(
        selectedIndex: _index,
        onDestinationSelected: (i) => setState(() => _index = i),
        destinations: [
          for (final t in _tabs)
            NavigationDestination(
              icon: Icon(t.outlinedIcon),
              selectedIcon: Icon(t.icon),
              label: t.label,
            ),
        ],
      ),
    );
  }
}
