import 'dart:ui';

import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import 'library_page.dart';
import 'player_screen.dart';
import 'play_network_page.dart';
import 'services/emby_api.dart';
import 'state/app_state.dart';
import 'domain_list_page.dart';
import 'library_items_page.dart';

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
                builder: (_) => LibraryItemsPage(
                  appState: appState,
                  parentId: item.id,
                  title: item.name,
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
  });

  final AppState appState;
  final bool loading;
  final Future<void> Function() onRefresh;
  final bool enableGlass;
  final void Function(String) onSearch;

  @override
  Widget build(BuildContext context) {
    final sections = <(String, List<MediaItem>)>[];
    if (appState.getHome('continue').isNotEmpty) {
      sections.add(('继续观看', appState.getHome('continue')));
    }
    for (final entry in appState.homeEntries) {
      // 仅展示可播放条目，避免文件夹/分类
      final playable = entry.items.where((e) => e.type == 'Episode' || e.type == 'Movie').toList();
      if (playable.isNotEmpty) {
        sections.add(('${entry.displayName} · 最新', playable));
      }
    }
    sections.add(('最新电影', appState.getHome('movies')));
    sections.add(('最新剧集', appState.getHome('episodes')));

    return RefreshIndicator(
      onRefresh: onRefresh,
      child: ListView(
        padding: const EdgeInsets.only(bottom: 16),
        children: [
          const SizedBox(height: 12),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: TextField(
              decoration: InputDecoration(
                hintText: '搜索片名…',
                prefixIcon: const Icon(Icons.search),
                border: OutlineInputBorder(borderRadius: BorderRadius.circular(12)),
                contentPadding: const EdgeInsets.symmetric(vertical: 10, horizontal: 12),
              ),
              textInputAction: TextInputAction.search,
              onSubmitted: onSearch,
            ),
          ),
          const SizedBox(height: 12),
          if (loading) const LinearProgressIndicator(),
          for (final sec in sections)
            if (sec.$2.isNotEmpty) ...[
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                child: Text(sec.$1, style: Theme.of(context).textTheme.titleLarge),
              ),
              SizedBox(
                height: 240,
                child: ListView.separated(
                  padding: const EdgeInsets.symmetric(horizontal: 16),
                  scrollDirection: Axis.horizontal,
                  itemBuilder: (context, index) {
                    final item = sec.$2[index];
                    return _HomeCard(
                      item: item,
                      appState: appState,
                      enableGlass: enableGlass,
                    );
                  },
                  separatorBuilder: (_, __) => const SizedBox(width: 12),
                  itemCount: sec.$2.length,
                ),
              ),
            ]
            else
              const SizedBox.shrink(),
          if (sections.every((e) => e.$2.isEmpty) && !loading)
            const Padding(
              padding: EdgeInsets.all(24),
              child: Center(child: Text('暂无可展示内容')),
            ),
        ],
      ),
    );
  }
}

class _HomeCard extends StatelessWidget {
  const _HomeCard({
    required this.item,
    required this.appState,
    required this.enableGlass,
  });

  final MediaItem item;
  final AppState appState;
  final bool enableGlass;

  bool get _isPlayable => item.type == 'Movie' || item.type == 'Episode';

  @override
  Widget build(BuildContext context) {
    final image = item.hasImage
        ? EmbyApi.imageUrl(
            baseUrl: appState.baseUrl!,
            itemId: item.id,
            token: appState.token!,
            maxWidth: 500,
          )
        : null;

    String subtitle = item.type;
    if (item.type == 'Episode') {
      final s = item.seasonNumber ?? 0;
      final e = item.episodeNumber ?? 0;
      subtitle = 'S${s.toString().padLeft(2, '0')}E${e.toString().padLeft(2, '0')}';
      if (item.seriesName.isNotEmpty) {
        subtitle = '${item.seriesName} · $subtitle';
      }
    }

    final card = SizedBox(
      width: 200,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          AspectRatio(
            // 16:9 横版封面
            aspectRatio: 16 / 9,
            child: ClipRRect(
              borderRadius: BorderRadius.circular(12),
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
            style: Theme.of(context).textTheme.bodyLarge,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
          ),
        ],
      ),
    );

    return InkWell(
      borderRadius: BorderRadius.circular(14),
      onTap: _isPlayable
          ? () {
              final url =
                  '${appState.baseUrl}/emby/Videos/${item.id}/stream?static=true&MediaSourceId=${item.id}&api_key=${appState.token}';
              Navigator.of(context).push(
                MaterialPageRoute(
                  builder: (_) => PlayNetworkPage(
                    title: item.name,
                    streamUrl: url,
                  ),
                ),
              );
            }
          : () {
              Navigator.of(context).push(
                MaterialPageRoute(
                  builder: (_) => LibraryItemsPage(
                    appState: appState,
                    parentId: item.id,
                    title: item.name,
                  ),
                ),
              );
            },
      child: enableGlass
          ? ClipRRect(
              borderRadius: BorderRadius.circular(14),
              child: BackdropFilter(
                filter: ImageFilter.blur(sigmaX: 10, sigmaY: 10),
                child: Container(
                  padding: const EdgeInsets.all(8),
                  decoration: BoxDecoration(
                    color: Colors.white.withValues(alpha: 0.08),
                    border: Border.all(color: Colors.white.withValues(alpha: 0.1)),
                    borderRadius: BorderRadius.circular(14),
                  ),
                  child: card,
                ),
              ),
            )
          : Card(
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
              child: Padding(
                padding: const EdgeInsets.all(8),
                child: card,
              ),
            ),
    );
  }
}
