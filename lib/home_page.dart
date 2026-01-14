import 'dart:ui';

import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import 'library_page.dart';
import 'library_items_page.dart';
import 'player_screen.dart';
import 'play_network_page.dart';
import 'services/emby_api.dart';
import 'state/app_state.dart';
import 'domain_list_page.dart';
import 'show_detail_page.dart';

class HomePage extends StatefulWidget {
  const HomePage({super.key, required this.appState});

  final AppState appState;

  @override
  State<HomePage> createState() => _HomePageState();
}

class _GlobalSearchDelegate extends SearchDelegate<String> {
  _GlobalSearchDelegate({required this.appState});
  final AppState appState;
  List<MediaItem> _results = [];
  bool _loading = false;

  Future<void> _doSearch(String q) async {
    _loading = true;
    try {
      await appState.loadItems(
        parentId: appState.userId ?? '',
        searchTerm: q,
        startIndex: 0,
        includeItemTypes: null,
      );
      _results = appState.getItems(appState.userId ?? '');
    } finally {
      _loading = false;
    }
  }

  @override
  Widget buildResults(BuildContext context) {
    if (_loading) {
      return const Center(child: CircularProgressIndicator());
    }
    if (_results.isEmpty) {
      return const Center(child: Text('没有结果'));
    }
    return ListView.builder(
      itemCount: _results.length,
      itemBuilder: (context, index) {
        final item = _results[index];
        return ListTile(
          leading: const Icon(Icons.search),
          title: Text(item.name),
          subtitle: Text(item.type),
          onTap: () {
            Navigator.of(context).push(
              MaterialPageRoute(
                builder: (_) => ShowDetailPage(
                  itemId: item.id,
                  title: item.name,
                  appState: appState,
                  isTv: false,
                ),
              ),
            );
          },
        );
      },
    );
  }

  @override
  Widget buildSuggestions(BuildContext context) => const SizedBox.shrink();

  @override
  List<Widget>? buildActions(BuildContext context) {
    return [
      IconButton(
        icon: const Icon(Icons.clear),
        onPressed: () {
          query = '';
          _results = [];
          showSuggestions(context);
        },
      )
    ];
  }

  @override
  Widget? buildLeading(BuildContext context) {
    return IconButton(
      icon: const Icon(Icons.arrow_back),
      onPressed: () => close(context, ''),
    );
  }

  @override
  void showResults(BuildContext context) {
    // ignore: use_build_context_synchronously
    _doSearch(query).then((_) => super.showResults(context));
  }
}

class _HomePageState extends State<HomePage> {
  int _index = 0; // 0 home, 1 libraries, 2 local
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() => _loading = true);
    try {
      await widget.appState.loadHome();
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  bool _isTv(BuildContext context) =>
      defaultTargetPlatform == TargetPlatform.android &&
      MediaQuery.of(context).size.shortestSide > 600;

  @override
  Widget build(BuildContext context) {
    final isTv = _isTv(context);
    final enableGlass = !isTv;

    final pages = [
      _HomeBody(
        appState: widget.appState,
        loading: _loading,
        onRefresh: _load,
        enableGlass: enableGlass,
        onSearch: (q) {
          if (q.trim().isEmpty) return;
          showSearch(
            context: context,
            delegate: _GlobalSearchDelegate(appState: widget.appState)..query = q.trim(),
          );
        },
        isTv: isTv,
        showSearchBar: true,
      ),
      LibraryPage(appState: widget.appState),
      const PlayerScreen(),
    ];

    return Scaffold(
      appBar: AppBar(
        title: const Text('LinPlayer'),
        actions: [
          IconButton(
            icon: const Icon(Icons.cloud_queue),
            tooltip: '线路',
            onPressed: () {
              Navigator.of(context).push(
                MaterialPageRoute(builder: (_) => DomainListPage(appState: widget.appState)),
              );
            },
          ),
          IconButton(
            icon: const Icon(Icons.logout),
            tooltip: '退出登录',
            onPressed: widget.appState.logout,
          ),
        ],
      ),
      body: pages[_index],
      bottomNavigationBar: NavigationBar(
        selectedIndex: _index,
        onDestinationSelected: (i) => setState(() => _index = i),
        destinations: const [
          NavigationDestination(icon: Icon(Icons.home_outlined), label: '首页'),
          NavigationDestination(icon: Icon(Icons.video_library_outlined), label: '媒体库'),
          NavigationDestination(icon: Icon(Icons.play_circle_outline), label: '本地'),
        ],
      ),
    );
  }
}

class _HomeBody extends StatelessWidget {
  const _HomeBody({
    required this.appState,
    required this.loading,
    required this.onRefresh,
    required this.enableGlass,
    required this.onSearch,
    required this.isTv,
    required this.showSearchBar,
  });

  final AppState appState;
  final bool loading;
  final Future<void> Function() onRefresh;
  final bool enableGlass;
  final void Function(String) onSearch;
  final bool isTv;
  final bool showSearchBar;

  @override
  Widget build(BuildContext context) {
    final sections = <HomeEntry>[];
    for (final entry in appState.homeEntries) {
      final shows = entry.items;
      if (shows.isNotEmpty) {
        sections.add(entry);
      }
    }

    return RefreshIndicator(
      onRefresh: onRefresh,
      child: ListView(
        padding: const EdgeInsets.only(bottom: 16),
        children: [
          if (showSearchBar) ...[
            const SizedBox(height: 12),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: TextField(
                decoration: const InputDecoration(
                  hintText: '搜索片名…',
                  prefixIcon: Icon(Icons.search),
                ),
                textInputAction: TextInputAction.search,
                onSubmitted: onSearch,
              ),
            ),
            const SizedBox(height: 12),
          ],
          if (loading) const LinearProgressIndicator(),
          for (final sec in sections)
            if (sec.items.isNotEmpty) ...[
              _HomeSectionHeader(
                title: sec.displayName,
                onTap: () {
                  if (!sec.key.startsWith('lib_')) return;
                  final libId = sec.key.substring(4);
                  Navigator.of(context).push(
                    MaterialPageRoute(
                      builder: (_) => LibraryItemsPage(
                        appState: appState,
                        parentId: libId,
                        title: sec.displayName,
                        isTv: isTv,
                      ),
                    ),
                  );
                },
              ),
              _HomeSectionCarousel(
                items: sec.items,
                appState: appState,
                enableGlass: enableGlass,
                isTv: isTv,
              ),
            ]
            else
              const SizedBox.shrink(),
          if (sections.every((e) => e.items.isEmpty) && !loading)
            const Padding(
              padding: EdgeInsets.all(24),
              child: Center(child: Text('暂无可展示内容')),
            ),
        ],
      ),
    );
  }
}

class _HomeSectionHeader extends StatelessWidget {
  const _HomeSectionHeader({required this.title, required this.onTap});

  final String title;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 10, 16, 8),
      child: InkWell(
        borderRadius: BorderRadius.circular(12),
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 4),
          child: Row(
            children: [
              Expanded(
                child: Text(
                  title,
                  style: Theme.of(context).textTheme.titleLarge,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              const SizedBox(width: 6),
              const Text('＞', style: TextStyle(color: Colors.white70, fontSize: 20, height: 1)),
            ],
          ),
        ),
      ),
    );
  }
}

class _HomeSectionCarousel extends StatelessWidget {
  const _HomeSectionCarousel({
    required this.items,
    required this.appState,
    required this.enableGlass,
    required this.isTv,
  });

  final List<MediaItem> items;
  final AppState appState;
  final bool enableGlass;
  final bool isTv;

  static const _maxItems = 12;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        const padding = 16.0;
        const spacing = 10.0;
        const visible = 3.0;
        final maxCount = items.length < _maxItems ? items.length : _maxItems;

        final itemWidth =
            (constraints.maxWidth - padding * 2 - spacing * (visible - 1)) / visible;
        final imageHeight = itemWidth * 3 / 2;
        final listHeight = imageHeight + 44; // card padding + title line

        return Padding(
          padding: const EdgeInsets.only(bottom: 6),
          child: SizedBox(
            height: listHeight,
            child: ListView.separated(
              cacheExtent: 0,
              padding: const EdgeInsets.symmetric(horizontal: padding),
              scrollDirection: Axis.horizontal,
              itemCount: maxCount,
              separatorBuilder: (_, __) => const SizedBox(width: spacing),
              itemBuilder: (context, index) {
                final item = items[index];
                return SizedBox(
                  width: itemWidth,
                  child: _HomeCard(
                    item: item,
                    appState: appState,
                    enableGlass: enableGlass,
                    isTv: isTv,
                    onTap: () {
                      final type = item.type.toLowerCase();
                      if (type == 'series') {
                        Navigator.of(context).push(
                          MaterialPageRoute(
                            builder: (_) => ShowDetailPage(
                              itemId: item.id,
                              title: item.name,
                              appState: appState,
                              isTv: isTv,
                            ),
                          ),
                        );
                      } else {
                        Navigator.of(context).push(
                          MaterialPageRoute(
                            builder: (_) => PlayNetworkPage(
                              title: item.name,
                              itemId: item.id,
                              appState: appState,
                              isTv: isTv,
                            ),
                          ),
                        );
                      }
                    },
                  ),
                );
              },
            ),
          ),
        );
      },
    );
  }
}

class _HomeCard extends StatelessWidget {
  const _HomeCard({
    required this.item,
    required this.appState,
    required this.enableGlass,
    required this.isTv,
    required this.onTap,
  });

  final MediaItem item;
  final AppState appState;
  final bool enableGlass;
  final bool isTv;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final image = item.hasImage
        ? EmbyApi.imageUrl(
            baseUrl: appState.baseUrl!,
            itemId: item.id,
            token: appState.token!,
            maxWidth: 320,
          )
        : null;

    final card = Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        AspectRatio(
          aspectRatio: 2 / 3,
          child: ClipRRect(
            borderRadius: BorderRadius.circular(10),
            child: image != null
                ? CachedNetworkImage(
                    imageUrl: image,
                    fit: BoxFit.cover,
                    placeholder: (_, __) =>
                        const Center(child: CircularProgressIndicator(strokeWidth: 2)),
                    errorWidget: (_, __, ___) =>
                        const ColoredBox(color: Colors.black12, child: Icon(Icons.broken_image)),
                  )
                : const ColoredBox(color: Colors.black12, child: Icon(Icons.image)),
          ),
        ),
        const SizedBox(height: 6),
        Text(
          item.name,
          style: Theme.of(context).textTheme.bodySmall?.copyWith(fontWeight: FontWeight.w600),
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
        ),
      ],
    );

    return InkWell(
      borderRadius: BorderRadius.circular(12),
      onTap: onTap,
      child: enableGlass
          ? ClipRRect(
              borderRadius: BorderRadius.circular(12),
              child: BackdropFilter(
                filter: ImageFilter.blur(sigmaX: 10, sigmaY: 10),
                child: Container(
                  padding: const EdgeInsets.all(6),
                  decoration: BoxDecoration(
                    color: Colors.white.withValues(alpha: 0.08),
                    border: Border.all(color: Colors.white.withValues(alpha: 0.1)),
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: card,
                ),
              ),
            )
          : Card(
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
              child: Padding(
                padding: const EdgeInsets.all(6),
                child: card,
              ),
            ),
    );
  }
}
