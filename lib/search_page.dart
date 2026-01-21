import 'dart:async';

import 'package:flutter/material.dart';

import 'services/emby_api.dart';
import 'show_detail_page.dart';
import 'src/device/device_type.dart';
import 'src/ui/app_components.dart';
import 'src/ui/glass_blur.dart';
import 'src/ui/ui_scale.dart';
import 'state/app_state.dart';

class SearchPage extends StatefulWidget {
  const SearchPage({
    super.key,
    required this.appState,
    this.initialQuery = '',
  });

  final AppState appState;
  final String initialQuery;

  @override
  State<SearchPage> createState() => _SearchPageState();
}

class _SearchPageState extends State<SearchPage> {
  late final TextEditingController _controller;
  Timer? _debounce;
  int _searchSeq = 0;

  bool _loading = false;
  String? _error;
  List<MediaItem> _results = const [];

  @override
  void initState() {
    super.initState();
    _controller = TextEditingController(text: widget.initialQuery);
    if (widget.initialQuery.trim().isNotEmpty) {
      _scheduleSearch(widget.initialQuery.trim(), immediate: true);
    }
  }

  @override
  void dispose() {
    _debounce?.cancel();
    _controller.dispose();
    super.dispose();
  }

  bool _isTv(BuildContext context) => DeviceType.isTv;

  void _scheduleSearch(String query, {bool immediate = false}) {
    _debounce?.cancel();
    if (immediate) {
      _doSearch(query);
      return;
    }
    _debounce = Timer(const Duration(milliseconds: 280), () {
      _doSearch(query);
    });
  }

  Future<void> _doSearch(String raw) async {
    final query = raw.trim();
    final seq = ++_searchSeq;

    if (query.isEmpty) {
      setState(() {
        _loading = false;
        _error = null;
        _results = const [];
      });
      return;
    }

    final baseUrl = widget.appState.baseUrl;
    final token = widget.appState.token;
    final userId = widget.appState.userId;
    if (baseUrl == null || token == null || userId == null) {
      setState(() {
        _loading = false;
        _error = '未连接服务器';
        _results = const [];
      });
      return;
    }

    setState(() {
      _loading = true;
      _error = null;
    });

    try {
      final api = EmbyApi(
        hostOrUrl: baseUrl,
        preferredScheme: 'https',
        apiPrefix: widget.appState.apiPrefix,
      );
      final fetched = await api.fetchItems(
        token: token,
        baseUrl: baseUrl,
        userId: userId,
        searchTerm: query,
        includeItemTypes: 'Series,Movie',
        recursive: true,
        excludeFolders: false,
        limit: 60,
        sortBy: 'SortName',
        sortOrder: 'Ascending',
      );

      if (!mounted || seq != _searchSeq) return;

      final normalizedQuery = query.toLowerCase();
      final exact = fetched.items
          .where((e) => e.name.trim().toLowerCase() == normalizedQuery)
          .toList(growable: false);
      final results = exact.isNotEmpty ? exact : fetched.items;

      setState(() {
        _results = results;
      });
    } catch (e) {
      if (!mounted || seq != _searchSeq) return;
      setState(() {
        _error = e.toString();
        _results = const [];
      });
    } finally {
      if (mounted && seq == _searchSeq) {
        setState(() {
          _loading = false;
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final uiScale = context.uiScale;
    final isTv = _isTv(context);
    final enableBlur = !isTv && widget.appState.enableBlurEffects;
    final maxCrossAxisExtent = (isTv ? 160.0 : 180.0) * uiScale;

    final query = _controller.text.trim();

    Widget content;
    if (query.isEmpty) {
      content = const Center(child: Text('输入剧名开始搜索'));
    } else if (_error != null) {
      content = Center(child: Text(_error!));
    } else if (_results.isEmpty) {
      content = _loading
          ? const Center(child: CircularProgressIndicator())
          : const Center(child: Text('没有结果'));
    } else {
      content = Padding(
        padding: const EdgeInsets.all(12),
        child: GridView.builder(
          gridDelegate: SliverGridDelegateWithMaxCrossAxisExtent(
            maxCrossAxisExtent: maxCrossAxisExtent,
            mainAxisSpacing: 10,
            crossAxisSpacing: 10,
            childAspectRatio: 0.7,
          ),
          itemCount: _results.length,
          itemBuilder: (context, index) {
            final item = _results[index];
            return _SearchGridItem(
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
      );
    }

    final body = query.isEmpty
        ? content
        : Column(
            children: [
              if (_loading && _results.isNotEmpty)
                const LinearProgressIndicator(minHeight: 2),
              Expanded(child: content),
            ],
          );

    return Scaffold(
      appBar: GlassAppBar(
        enableBlur: enableBlur,
        child: AppBar(
          titleSpacing: 0,
          title: Padding(
            padding: const EdgeInsets.only(right: 12),
            child: TextField(
              controller: _controller,
              autofocus: true,
              decoration: const InputDecoration(
                hintText: '搜索剧名',
                border: InputBorder.none,
              ),
              textInputAction: TextInputAction.search,
              onChanged: (v) => _scheduleSearch(v),
              onSubmitted: (v) => _scheduleSearch(v, immediate: true),
            ),
          ),
          actions: [
            IconButton(
              tooltip: '清空',
              icon: const Icon(Icons.clear),
              onPressed: () {
                _controller.clear();
                _scheduleSearch('', immediate: true);
              },
            ),
          ],
        ),
      ),
      body: body,
    );
  }
}

class _SearchGridItem extends StatelessWidget {
  const _SearchGridItem({
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

    final badge =
        item.type == 'Movie' ? '电影' : (item.type == 'Series' ? '剧集' : '');

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
