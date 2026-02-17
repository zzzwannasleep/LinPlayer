import 'dart:async';

import 'package:flutter/material.dart';
import 'package:lin_player_server_adapters/lin_player_server_adapters.dart';
import 'package:lin_player_state/lin_player_state.dart';

import '../../server_adapters/server_access.dart';
import '../models/desktop_ui_language.dart';
import '../theme/desktop_theme_extension.dart';
import '../widgets/desktop_media_card.dart';

class DesktopContinueWatchingPage extends StatefulWidget {
  const DesktopContinueWatchingPage({
    super.key,
    required this.appState,
    required this.language,
    required this.onOpenItem,
  });

  final AppState appState;
  final DesktopUiLanguage language;
  final ValueChanged<MediaItem> onOpenItem;

  @override
  State<DesktopContinueWatchingPage> createState() =>
      _DesktopContinueWatchingPageState();
}

class _DesktopContinueWatchingPageState
    extends State<DesktopContinueWatchingPage> {
  bool _loading = true;
  String? _error;
  List<MediaItem> _items = const <MediaItem>[];

  @override
  void initState() {
    super.initState();
    unawaited(_load(forceRefresh: true));
  }

  Future<void> _load({required bool forceRefresh}) async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final fetched = await widget.appState
          .loadContinueWatching(forceRefresh: forceRefresh);
      if (!mounted) return;
      setState(() {
        _items = fetched;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = e.toString();
      });
    } finally {
      if (mounted) {
        setState(() => _loading = false);
      }
    }
  }

  void _openItem(MediaItem item) {
    widget.onOpenItem(item);
    Navigator.of(context).pop();
  }

  @override
  Widget build(BuildContext context) {
    final theme = DesktopThemeExtension.of(context);
    final access = resolveServerAccess(appState: widget.appState);
    final title = widget.language.pick(
      zh: '\u7ee7\u7eed\u89c2\u770b',
      en: 'Continue Watching',
    );

    return Scaffold(
      backgroundColor: theme.background,
      appBar: AppBar(
        title: Text(title),
        actions: [
          IconButton(
            tooltip: widget.language.pick(zh: '\u5237\u65b0', en: 'Refresh'),
            onPressed: _loading ? null : () => _load(forceRefresh: true),
            icon: const Icon(Icons.refresh_rounded),
          ),
        ],
      ),
      body: Padding(
        padding: const EdgeInsets.all(16),
        child: _buildBody(access),
      ),
    );
  }

  Widget _buildBody(ServerAccess? access) {
    final theme = DesktopThemeExtension.of(context);
    if (_loading && _items.isEmpty) {
      return const Center(child: CircularProgressIndicator());
    }
    if ((_error ?? '').trim().isNotEmpty) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              _error!,
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 12),
            FilledButton(
              onPressed: () => _load(forceRefresh: true),
              child:
                  Text(widget.language.pick(zh: '\u91cd\u8bd5', en: 'Retry')),
            ),
          ],
        ),
      );
    }
    if (_items.isEmpty) {
      return Center(
        child: Text(
          widget.language
              .pick(zh: '\u6682\u65e0\u7ee7\u7eed\u89c2\u770b', en: 'No items'),
          style: TextStyle(color: theme.textMuted),
        ),
      );
    }

    return LayoutBuilder(
      builder: (context, constraints) {
        const itemWidth = 176.0;
        final crossAxisCount = (constraints.maxWidth / itemWidth).floor();
        final columns = crossAxisCount.clamp(2, 8);
        return GridView.builder(
          itemCount: _items.length,
          gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
            crossAxisCount: columns,
            mainAxisSpacing: 16,
            crossAxisSpacing: 16,
            childAspectRatio: 0.58,
          ),
          itemBuilder: (context, index) {
            final item = _items[index];
            return DesktopMediaCard(
              item: item,
              access: access,
              width: 160,
              showProgress: true,
              onTap: () => _openItem(item),
            );
          },
        );
      },
    );
  }
}
