import 'package:flutter/material.dart';

import 'services/emby_api.dart';
import 'state/app_state.dart';
import 'show_detail_page.dart';
import 'src/device/device_type.dart';
import 'src/ui/app_components.dart';
import 'src/ui/glass_blur.dart';
import 'src/ui/ui_scale.dart';

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
    if (_scroll.position.pixels > _scroll.position.maxScrollExtent - 320) {
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

  bool _isTv(BuildContext context) => DeviceType.isTv;

  @override
  Widget build(BuildContext context) {
    final items = widget.appState.getItems(widget.parentId);
    final uiScale = context.uiScale;
    final isTv = _isTv(context);
    final enableBlur = !isTv && widget.appState.enableBlurEffects;
    final maxCrossAxisExtent = (isTv ? 160.0 : 180.0) * uiScale;

    return Scaffold(
      appBar: GlassAppBar(
        enableBlur: enableBlur,
        child: AppBar(
          title: Text(widget.title),
        ),
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
    required this.onTap,
  });

  final MediaItem item;
  final AppState appState;
  final VoidCallback onTap;

  String _yearOf() {
    final d = (item.premiereDate ?? '').trim();
    if (d.isEmpty) return '';
    final parsed = DateTime.tryParse(d);
    if (parsed != null) return parsed.year.toString();
    return d.length >= 4 ? d.substring(0, 4) : '';
  }

  @override
  Widget build(BuildContext context) {
    final image = item.hasImage
        ? EmbyApi.imageUrl(
            baseUrl: appState.baseUrl!,
            itemId: item.id,
            token: appState.token!,
            apiPrefix: appState.apiPrefix,
            imageType: 'Primary',
            maxWidth: 320,
          )
        : null;

    final year = _yearOf();
    final rating = item.communityRating;

    String badge = '';
    if (item.type == 'Movie') {
      badge = '电影';
    } else if (item.type == 'Series') {
      badge = '剧集';
    }

    return MediaPosterTile(
      title: item.name,
      imageUrl: image,
      year: year,
      rating: rating,
      badgeText: badge,
      onTap: onTap,
    );
  }
}
