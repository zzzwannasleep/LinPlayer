import 'dart:ui';

import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import 'services/emby_api.dart';
import 'state/app_state.dart';
import 'play_network_page.dart';

class LibraryItemsPage extends StatefulWidget {
  const LibraryItemsPage({
    super.key,
    required this.appState,
    required this.parentId,
    required this.title,
  });

  final AppState appState;
  final String parentId;
  final String title;

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
      MediaQuery.of(context).size.shortestSide > 600;

  @override
  Widget build(BuildContext context) {
    final items = widget.appState.getItems(widget.parentId);
    final enableGlass = !_isTv(context);

    return Scaffold(
      appBar: AppBar(
        title: Text(widget.title),
      ),
      body: Column(
        children: [
          Expanded(
            child: items.isEmpty && _loadingMore
                ? const Center(child: CircularProgressIndicator())
                : ListView.builder(
                    controller: _scroll,
                    itemCount: items.length + (_loadingMore ? 1 : 0),
                    itemBuilder: (context, index) {
                      if (index >= items.length) {
                        return const Padding(
                          padding: EdgeInsets.symmetric(vertical: 16),
                          child: Center(child: CircularProgressIndicator()),
                        );
                      }
                      final item = items[index];
                      return _ItemCard(
                        item: item,
                        appState: widget.appState,
                        enableGlass: enableGlass,
                        isTv: _isTv(context),
                        onOpenFolder: () {
                          Navigator.of(context).push(
                            MaterialPageRoute(
                              builder: (_) => LibraryItemsPage(
                                appState: widget.appState,
                                parentId: item.id,
                                title: item.name,
                              ),
                            ),
                          );
                        },
                        onPlay: () {
                          final url =
                              '${widget.appState.baseUrl}/emby/Videos/${item.id}/stream?static=true&MediaSourceId=${item.id}&api_key=${widget.appState.token}';
                          Navigator.of(context).push(
                            MaterialPageRoute(
                              builder: (_) => PlayNetworkPage(
                                title: item.name,
                                streamUrl: url,
                              ),
                            ),
                          );
                        },
                      );
                    },
                  ),
          ),
        ],
      ),
    );
  }
}

class _ItemCard extends StatelessWidget {
  const _ItemCard({
    required this.item,
    required this.appState,
    required this.enableGlass,
    required this.onOpenFolder,
    required this.onPlay,
    required this.isTv,
  });

  final MediaItem item;
  final AppState appState;
  final bool enableGlass;
  final VoidCallback onOpenFolder;
  final VoidCallback onPlay;
  final bool isTv;

  bool get _isPlayable => item.type == 'Movie' || item.type == 'Episode';
  bool get _isFolder =>
      item.type == 'Series' ||
      item.type == 'Season' ||
      item.type == 'BoxSet' ||
      item.type == 'CollectionFolder' ||
      item.type == 'Folder';

  @override
  Widget build(BuildContext context) {
    final image = item.hasImage
        ? EmbyApi.imageUrl(
            baseUrl: appState.baseUrl!,
            itemId: item.id,
            token: appState.token!,
            maxWidth: 400,
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
    if (item.overview.isNotEmpty) {
      subtitle = '$subtitle · ${item.overview}';
    }

    final cardContent = Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        ClipRRect(
          borderRadius: BorderRadius.circular(10),
          child: image != null
              ? CachedNetworkImage(
                  imageUrl: image,
                  width: 90,
                  height: 130,
                  fit: BoxFit.cover,
                  placeholder: (_, __) =>
                      const SizedBox(width: 90, height: 130, child: Icon(Icons.image)),
                  errorWidget: (_, __, ___) =>
                      const SizedBox(width: 90, height: 130, child: Icon(Icons.broken_image)),
                )
              : const SizedBox(
                  width: 90,
                  height: 130,
                  child: Icon(Icons.image),
                ),
        ),
        const SizedBox(width: 12),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                item.name,
                style: Theme.of(context).textTheme.titleMedium,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
              ),
              const SizedBox(height: 6),
              Text(
                subtitle,
                maxLines: 3,
                overflow: TextOverflow.ellipsis,
                style: Theme.of(context).textTheme.bodyMedium,
              ),
              const SizedBox(height: 8),
              Row(
                children: [
                  if (_isPlayable)
                    FilledButton.tonal(
                      onPressed: onPlay,
                      child: const Text('播放'),
                    ),
                  if (_isFolder) ...[
                    const SizedBox(width: 8),
                    OutlinedButton(
                      onPressed: onOpenFolder,
                      child: const Text('进入'),
                    )
                  ],
                ],
              )
            ],
          ),
        ),
      ],
    );

    Widget decorated;
    if (enableGlass && !isTv) {
      decorated = ClipRRect(
        borderRadius: BorderRadius.circular(16),
        child: BackdropFilter(
          filter: ImageFilter.blur(sigmaX: 12, sigmaY: 12),
          child: Container(
            decoration: BoxDecoration(
              color: Colors.white.withValues(alpha: 0.06),
              border: Border.all(color: Colors.white.withValues(alpha: 0.1)),
              borderRadius: BorderRadius.circular(16),
            ),
            padding: const EdgeInsets.all(12),
            child: cardContent,
          ),
        ),
      );
    } else if (isTv) {
      decorated = FocusableActionDetector(
        mouseCursor: SystemMouseCursors.click,
        child: Card(
          elevation: 4,
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
          child: Padding(
            padding: const EdgeInsets.all(12),
            child: cardContent,
          ),
        ),
        onShowFocusHighlight: (focused) {
          // noop; focus style via InkWell below
        },
      );
      decorated = InkWell(
        focusColor: Colors.blue.withValues(alpha: 0.2),
        hoverColor: Colors.blue.withValues(alpha: 0.05),
        borderRadius: BorderRadius.circular(12),
        onTap: _isPlayable ? onPlay : onOpenFolder,
        child: decorated,
      );
    } else {
      decorated = Card(
        elevation: 2,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: cardContent,
        ),
      );
    }

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      child: decorated,
    );
  }
}
