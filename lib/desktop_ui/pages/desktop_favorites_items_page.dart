import 'package:flutter/material.dart';
import 'package:lin_player_server_adapters/lin_player_server_adapters.dart';
import 'package:lin_player_state/lin_player_state.dart';

import '../../server_adapters/server_access.dart';
import '../models/desktop_ui_language.dart';
import '../theme/desktop_theme_extension.dart';
import '../widgets/desktop_media_card.dart';

class DesktopFavoritesItemsPage extends StatefulWidget {
  const DesktopFavoritesItemsPage({
    super.key,
    required this.appState,
    required this.title,
    required this.items,
    required this.language,
    required this.isFavorite,
    required this.onToggleFavorite,
    required this.onOpenItem,
  });

  final AppState appState;
  final String title;
  final List<MediaItem> items;
  final DesktopUiLanguage language;
  final bool Function(String itemId) isFavorite;
  final ValueChanged<String> onToggleFavorite;
  final ValueChanged<MediaItem> onOpenItem;

  @override
  State<DesktopFavoritesItemsPage> createState() =>
      _DesktopFavoritesItemsPageState();
}

class _DesktopFavoritesItemsPageState extends State<DesktopFavoritesItemsPage> {
  late final List<MediaItem> _allItems = () {
    final map = <String, MediaItem>{};
    for (final item in widget.items) {
      final id = item.id.trim();
      if (id.isEmpty) continue;
      map[id] = item;
    }
    return map.values.toList(growable: false);
  }();

  void _openItem(MediaItem item) {
    widget.onOpenItem(item);
    Navigator.of(context).pop();
  }

  @override
  Widget build(BuildContext context) {
    final theme = DesktopThemeExtension.of(context);
    final access = resolveServerAccess(appState: widget.appState);
    final favorites = _allItems
        .where((item) => widget.isFavorite(item.id))
        .toList(growable: false);

    return Scaffold(
      backgroundColor: theme.background,
      appBar: AppBar(
        title: Text(widget.title),
      ),
      body: Padding(
        padding: const EdgeInsets.all(16),
        child: favorites.isEmpty
            ? Center(
                child: Text(
                  widget.language.pick(
                    zh: '\u6682\u65e0\u6536\u85cf',
                    en: 'No favorites',
                  ),
                  style: TextStyle(color: theme.textMuted),
                ),
              )
            : LayoutBuilder(
                builder: (context, constraints) {
                  const itemWidth = 176.0;
                  final count = (constraints.maxWidth / itemWidth).floor();
                  final columns = count.clamp(2, 8);
                  return GridView.builder(
                    itemCount: favorites.length,
                    gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
                      crossAxisCount: columns,
                      mainAxisSpacing: 16,
                      crossAxisSpacing: 16,
                      childAspectRatio: 0.58,
                    ),
                    itemBuilder: (context, index) {
                      final item = favorites[index];
                      return DesktopMediaCard(
                        item: item,
                        access: access,
                        width: 160,
                        isFavorite: widget.isFavorite(item.id),
                        onTap: () => _openItem(item),
                        onToggleFavorite: () {
                          widget.onToggleFavorite(item.id);
                          setState(() {});
                        },
                      );
                    },
                  );
                },
              ),
      ),
    );
  }
}
