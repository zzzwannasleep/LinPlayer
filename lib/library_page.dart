import 'package:flutter/material.dart';

import 'package:lin_player_server_adapters/lin_player_server_adapters.dart';
import 'package:lin_player_state/lin_player_state.dart';
import 'package:lin_player_ui/lin_player_ui.dart';
import 'library_items_page.dart';
import 'server_adapters/server_access.dart';

class LibraryPage extends StatefulWidget {
  const LibraryPage({super.key, required this.appState});

  final AppState appState;

  @override
  State<LibraryPage> createState() => _LibraryPageState();
}

class _LibraryPageState extends State<LibraryPage> {
  bool _showHidden = false;

  bool _isTv(BuildContext context) => DeviceType.isTv;

  @override
  Widget build(BuildContext context) {
    final uiScale = context.uiScale;
    return AnimatedBuilder(
      animation: widget.appState,
      builder: (context, _) {
        final enableBlur = !_isTv(context) && widget.appState.enableBlurEffects;
        final access = resolveServerAccess(appState: widget.appState);
        final libs = widget.appState.libraries
            .where((l) =>
                _showHidden ? true : !widget.appState.isLibraryHidden(l.id))
            .toList();
        return Scaffold(
          appBar: GlassAppBar(
            enableBlur: enableBlur,
            child: AppBar(
              title: const Text('媒体库'),
              actions: [
                IconButton(
                  icon: const Icon(Icons.sort_by_alpha),
                  tooltip: '名称排序',
                  onPressed: widget.appState.sortLibrariesByName,
                ),
                IconButton(
                  icon: Icon(
                      _showHidden ? Icons.visibility : Icons.visibility_off),
                  tooltip: _showHidden ? '隐藏已隐藏的库' : '显示已隐藏的库',
                  onPressed: () => setState(() => _showHidden = !_showHidden),
                ),
                IconButton(
                  icon: const Icon(Icons.refresh),
                  onPressed: widget.appState.isLoading
                      ? null
                      : () => widget.appState.refreshLibraries(),
                ),
              ],
            ),
          ),
          body: widget.appState.isLoading
              ? const Center(child: CircularProgressIndicator())
              : libs.isEmpty
                  ? const Center(child: Text('暂无媒体库，点击右上角刷新重试'))
                  : Padding(
                      padding: const EdgeInsets.all(12),
                      child: GridView.builder(
                        gridDelegate: SliverGridDelegateWithMaxCrossAxisExtent(
                          maxCrossAxisExtent: 150 * uiScale,
                          mainAxisSpacing: 6,
                          crossAxisSpacing: 6,
                          childAspectRatio: 1.33,
                        ),
                        itemCount: libs.length,
                        itemBuilder: (context, index) {
                          final LibraryInfo lib = libs[index];
                          final imageUrl = access == null
                              ? ''
                              : access.adapter.imageUrl(
                                  access.auth,
                                  itemId: lib.id,
                                  maxWidth: 400,
                                );
                          return MediaBackdropTile(
                            title: lib.name,
                            imageUrl: imageUrl,
                            onTap: () {
                              Navigator.of(context).push(
                                MaterialPageRoute(
                                  builder: (_) => LibraryItemsPage(
                                    appState: widget.appState,
                                    parentId: lib.id,
                                    title: lib.name,
                                    isTv: _isTv(context),
                                  ),
                                ),
                              );
                            },
                            onLongPress: () {
                              widget.appState.toggleLibraryHidden(lib.id);
                              setState(() {});
                            },
                          );
                        },
                      ),
                    ),
        );
      },
    );
  }
}
