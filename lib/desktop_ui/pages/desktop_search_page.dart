import 'dart:async';
import 'dart:ui';

import 'package:flutter/material.dart';
import 'package:lin_player_server_adapters/lin_player_server_adapters.dart';
import 'package:lin_player_state/lin_player_state.dart';

import '../../server_adapters/server_access.dart';
import '../models/desktop_ui_language.dart';
import '../theme/desktop_theme_extension.dart';
import '../widgets/desktop_media_card.dart';

class DesktopSearchPage extends StatefulWidget {
  const DesktopSearchPage({
    super.key,
    required this.appState,
    required this.query,
    required this.onOpenItem,
    this.refreshSignal = 0,
    this.language = DesktopUiLanguage.zhCn,
  });

  final AppState appState;
  final String query;
  final ValueChanged<MediaItem> onOpenItem;
  final int refreshSignal;
  final DesktopUiLanguage language;

  @override
  State<DesktopSearchPage> createState() => _DesktopSearchPageState();
}

class _DesktopSearchPageState extends State<DesktopSearchPage> {
  bool _loading = false;
  String? _error;
  List<MediaItem> _results = const <MediaItem>[];
  int _searchSeq = 0;
  String _activeQuery = '';

  String _t({
    required String zh,
    required String en,
  }) {
    return widget.language.pick(zh: zh, en: en);
  }

  @override
  void initState() {
    super.initState();
    _activeQuery = widget.query.trim();
    if (_activeQuery.isNotEmpty) {
      unawaited(_search(_activeQuery));
    }
  }

  @override
  void didUpdateWidget(covariant DesktopSearchPage oldWidget) {
    super.didUpdateWidget(oldWidget);
    final nextQuery = widget.query.trim();
    final queryChanged = nextQuery != _activeQuery;
    final refreshChanged = oldWidget.refreshSignal != widget.refreshSignal;

    if (queryChanged) {
      _activeQuery = nextQuery;
      unawaited(_search(_activeQuery));
      return;
    }

    if (refreshChanged && _activeQuery.isNotEmpty) {
      unawaited(_search(_activeQuery));
    }
  }

  Future<void> _search(String raw) async {
    final query = raw.trim();
    final seq = ++_searchSeq;

    if (query.isEmpty) {
      setState(() {
        _loading = false;
        _error = null;
        _results = const <MediaItem>[];
      });
      return;
    }

    final access = resolveServerAccess(appState: widget.appState);
    if (access == null) {
      setState(() {
        _loading = false;
        _error = _t(
          zh: '\u5f53\u524d\u672a\u8fde\u63a5\u5a92\u4f53\u670d\u52a1\u5668',
          en: 'No active media server session',
        );
        _results = const <MediaItem>[];
      });
      return;
    }

    setState(() {
      _loading = true;
      _error = null;
    });

    try {
      final result = await access.adapter.fetchItems(
        access.auth,
        searchTerm: query,
        includeItemTypes: 'Series,Movie',
        recursive: true,
        excludeFolders: false,
        limit: 80,
        sortBy: 'SortName',
        sortOrder: 'Ascending',
      );

      if (!mounted || seq != _searchSeq) return;

      final normalized = query.toLowerCase();
      final exactMatch = result.items
          .where((item) => item.name.trim().toLowerCase() == normalized)
          .toList(growable: false);

      setState(() {
        _results = exactMatch.isNotEmpty ? exactMatch : result.items;
      });
    } catch (e) {
      if (!mounted || seq != _searchSeq) return;
      setState(() {
        _error = e.toString();
        _results = const <MediaItem>[];
      });
    } finally {
      if (mounted && seq == _searchSeq) {
        setState(() => _loading = false);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final desktopTheme = DesktopThemeExtension.of(context);
    final access = resolveServerAccess(appState: widget.appState);
    final query = widget.query.trim();

    Widget body;
    if (query.isEmpty) {
      body = Center(
        child: Text(
          _t(
            zh: '\u8bf7\u5728\u9876\u90e8\u641c\u7d22\u6846\u8f93\u5165\u5173\u952e\u8bcd',
            en: 'Type in the top search box to find media',
          ),
          style: TextStyle(color: desktopTheme.textMuted),
        ),
      );
    } else if (_loading && _results.isEmpty) {
      body = const Center(child: CircularProgressIndicator());
    } else if ((_error ?? '').trim().isNotEmpty) {
      body = Center(child: Text(_error!));
    } else if (_results.isEmpty) {
      body = Center(
        child: Text(
          _t(
            zh: '\u672a\u627e\u5230\u201c$query\u201d\u7684\u7ed3\u679c',
            en: 'No results for "$query"',
          ),
          style: TextStyle(color: desktopTheme.textMuted),
        ),
      );
    } else {
      body = LayoutBuilder(
        builder: (context, constraints) {
          final available = constraints.maxWidth;
          final crossAxisCount = (available / 230).floor().clamp(2, 8).toInt();
          return GridView.builder(
            padding: const EdgeInsets.fromLTRB(16, 10, 16, 24),
            gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
              crossAxisCount: crossAxisCount,
              mainAxisSpacing: 18,
              crossAxisSpacing: 16,
              childAspectRatio: 0.62,
            ),
            itemCount: _results.length,
            itemBuilder: (context, index) {
              final item = _results[index];
              return DesktopMediaCard(
                item: item,
                access: access,
                width: 208,
                onTap: () => widget.onOpenItem(item),
              );
            },
          );
        },
      );
    }

    return ClipRRect(
      borderRadius: BorderRadius.circular(20),
      child: BackdropFilter(
        filter: ImageFilter.blur(sigmaX: 16, sigmaY: 16),
        child: DecoratedBox(
          decoration: BoxDecoration(
            color: desktopTheme.surface.withValues(alpha: 0.66),
            borderRadius: BorderRadius.circular(20),
            border: Border.all(color: desktopTheme.border),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(18, 14, 18, 8),
                child: Row(
                  children: [
                    Expanded(
                      child: Text(
                        query.isEmpty
                            ? _t(zh: '\u641c\u7d22', en: 'Search')
                            : _t(
                                zh: '\u201c$query\u201d\u7684\u7ed3\u679c',
                                en: 'Results for "$query"',
                              ),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          color: desktopTheme.textPrimary,
                          fontSize: 20,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                    ),
                    if (query.isNotEmpty)
                      Text(
                        _t(
                          zh: '\u5171 ${_results.length} \u9879',
                          en: '${_results.length} items',
                        ),
                        style: TextStyle(
                          color: desktopTheme.textMuted,
                          fontSize: 13,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                  ],
                ),
              ),
              const SizedBox(height: 4),
              Expanded(
                child: Stack(
                  children: [
                    Positioned.fill(child: body),
                    if (_loading && _results.isNotEmpty)
                      const Positioned(
                        left: 0,
                        right: 0,
                        top: 0,
                        child: LinearProgressIndicator(minHeight: 2),
                      ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
