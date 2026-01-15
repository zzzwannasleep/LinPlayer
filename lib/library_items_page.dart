import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import 'services/emby_api.dart';
import 'state/app_state.dart';
import 'show_detail_page.dart';

class LibraryItemsPage extends StatefulWidget {
  const LibraryItemsPage({
    super.key,
    required this.appState,
    required this.parentId,
    required this.title,
    this.isTv = false,
  });

  final AppState appState;
  final String parentId;
  final String title;
  final bool isTv;

  @override
  State<LibraryItemsPage> createState() => _LibraryItemsPageState();
}

class _LibraryItemsPageState extends State<LibraryItemsPage> {
  final _scroll = ScrollController();
  bool _loadingMore = false;

  @override
  void initState() {
    super.initState();
    _load(reset: true);
    _scroll.addListener(_onScroll);
  }

  void _onScroll() {
    if (_loadingMore) return;
    if (_scroll.position.pixels >
        _scroll.position.maxScrollExtent - 320) {
      _load(reset: false);
    }
  }

  Future<void> _load({required bool reset}) async {
    final items = widget.appState.getItems(widget.parentId);
    final total = widget.appState.getTotal(widget.parentId);
    final start = reset ? 0 : items.length;
    if (!reset && items.length >= total && total != 0) return;
    setState(() => _loadingMore = true);
    try {
      await widget.appState.loadItems(
        parentId: widget.parentId,
        startIndex: start,
        limit: 30,
        includeItemTypes: 'Series,Movie',
        recursive: true,
        excludeFolders: false,
        sortBy: 'DateCreated',
      );
    } finally {
      if (mounted) setState(() => _loadingMore = false);
    }
  }

  @override
  void dispose() {
    _scroll.dispose();
    super.dispose();
  }

  bool _isTv(BuildContext context) =>
      defaultTargetPlatform == TargetPlatform.android &&
      MediaQuery.of(context).orientation == Orientation.landscape &&
      MediaQuery.of(context).size.shortestSide >= 720;

  @override
  Widget build(BuildContext context) {
    final items = widget.appState.getItems(widget.parentId);
    final isTv = _isTv(context);
    final enableGlass = !isTv;
    final maxCrossAxisExtent = isTv ? 160.0 : 180.0;

    return Scaffold(
      appBar: AppBar(
        title: Text(widget.title),
      ),
      body: items.isEmpty && _loadingMore
          ? const Center(child: CircularProgressIndicator())
          : Padding(
              padding: const EdgeInsets.all(12),
                child: GridView.builder(
                  controller: _scroll,
                  gridDelegate: SliverGridDelegateWithMaxCrossAxisExtent(
                    maxCrossAxisExtent: maxCrossAxisExtent,
                    mainAxisSpacing: 10,
                    crossAxisSpacing: 10,
                    childAspectRatio: 0.7,
                  ),
                itemCount: items.length + (_loadingMore ? 1 : 0),
                itemBuilder: (context, index) {
                  if (index >= items.length) {
                    return const Center(child: CircularProgressIndicator());
                  }
                  final item = items[index];
                  return _GridItem(
                    item: item,
                    appState: widget.appState,
                    enableGlass: enableGlass,
                    isTv: isTv,
                    onTap: () {
                      Navigator.of(context).push(
                        MaterialPageRoute(
                          builder: (_) => ShowDetailPage(
                            itemId: item.id,
                            title: item.name,
                            appState: widget.appState,
                            isTv: isTv,
                          ),
                        ),
                      );
                    },
                  );
                },
              ),
            ),
    );
  }
}

class _GridItem extends StatelessWidget {
  const _GridItem({
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
            imageType: 'Primary',
            maxWidth: 320,
          )
        : null;

    String badge = '';
    if (item.type == 'Episode') {
      final s = item.seasonNumber ?? 0;
      final e = item.episodeNumber ?? 0;
      badge = 'S${s.toString().padLeft(2, '0')}E${e.toString().padLeft(2, '0')}';
    } else if (item.type == 'Movie') {
      badge = '电影';
    }

    final poster = ClipRRect(
      borderRadius: BorderRadius.circular(10),
      child: Stack(
        children: [
          Positioned.fill(
            child: image != null
                ? CachedNetworkImage(
                    imageUrl: image,
                    httpHeaders: {'User-Agent': EmbyApi.userAgent},
                    fit: BoxFit.cover,
                    placeholder: (_, __) => const ColoredBox(color: Colors.black12),
                    errorWidget: (_, __, ___) => const ColoredBox(color: Colors.black26),
                  )
                : const ColoredBox(color: Colors.black26),
          ),
          if (badge.isNotEmpty)
            Positioned(
              left: 6,
              top: 6,
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 3),
                decoration: BoxDecoration(
                  color: Colors.black.withValues(alpha: 0.55),
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Text(
                  badge,
                  style: const TextStyle(fontSize: 10, fontWeight: FontWeight.w600),
                ),
              ),
            ),
        ],
      ),
    );

    return InkWell(
      borderRadius: BorderRadius.circular(10),
      onTap: onTap,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(child: poster),
          const SizedBox(height: 6),
          Text(
            item.name,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: Theme.of(context).textTheme.bodySmall?.copyWith(fontWeight: FontWeight.w600),
          ),
        ],
      ),
    );
  }
}
