import 'dart:async';

import 'package:flutter/material.dart';
import 'package:lin_player_server_adapters/lin_player_server_adapters.dart';
import 'package:lin_player_state/lin_player_state.dart';

import '../../server_adapters/server_access.dart';
import '../theme/desktop_theme_extension.dart';
import '../widgets/desktop_media_card.dart';

class DesktopSearchPage extends StatefulWidget {
  const DesktopSearchPage({
    super.key,
    required this.appState,
    required this.query,
    required this.onOpenItem,
    this.refreshSignal = 0,
  });

  final AppState appState;
  final String query;
  final ValueChanged<MediaItem> onOpenItem;
  final int refreshSignal;

  @override
  State<DesktopSearchPage> createState() => _DesktopSearchPageState();
}

class _DesktopSearchPageState extends State<DesktopSearchPage> {
  bool _loading = false;
  String? _error;
  List<MediaItem> _results = const <MediaItem>[];
  int _searchSeq = 0;
  String _activeQuery = '';

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
        _error = 'No active media server session';
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
          'Type in the top search box to find media',
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
          'No results for "$query"',
          style: TextStyle(color: desktopTheme.textMuted),
        ),
      );
    } else {
      body = LayoutBuilder(
        builder: (context, constraints) {
          final available = constraints.maxWidth;
          final crossAxisCount = (available / 230).floor().clamp(2, 8).toInt();
          return GridView.builder(
            padding: const EdgeInsets.all(16),
            gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
              crossAxisCount: crossAxisCount,
              mainAxisSpacing: 16,
              crossAxisSpacing: 16,
              childAspectRatio: 0.55,
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

    return DecoratedBox(
      decoration: BoxDecoration(
        color: desktopTheme.surface.withValues(alpha: 0.72),
        borderRadius: BorderRadius.circular(18),
        border: Border.all(color: desktopTheme.border),
      ),
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
    );
  }
}
