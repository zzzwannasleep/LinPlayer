import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart';
import 'package:cached_network_image/cached_network_image.dart';

import 'services/emby_api.dart';
import 'state/app_state.dart';
import 'library_items_page.dart';

class LibraryPage extends StatefulWidget {
  const LibraryPage({super.key, required this.appState});

  final AppState appState;

  @override
  State<LibraryPage> createState() => _LibraryPageState();
}

class _LibraryPageState extends State<LibraryPage> {
  bool _showHidden = false;

  bool _isTv(BuildContext context) =>
      defaultTargetPlatform == TargetPlatform.android &&
      MediaQuery.of(context).size.shortestSide > 600;

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: widget.appState,
      builder: (context, _) {
        final libs = widget.appState.libraries
            .where((l) => _showHidden ? true : !widget.appState.isLibraryHidden(l.id))
            .toList();
        return Scaffold(
          appBar: AppBar(
            title: const Text('媒体库'),
            actions: [
              IconButton(
                icon: const Icon(Icons.sort_by_alpha),
                tooltip: '名称排序',
                onPressed: widget.appState.sortLibrariesByName,
              ),
              IconButton(
                icon: Icon(_showHidden ? Icons.visibility : Icons.visibility_off),
                tooltip: _showHidden ? '隐藏已隐藏的库' : '显示已隐藏的库',
                onPressed: () => setState(() => _showHidden = !_showHidden),
              ),
              IconButton(
                icon: const Icon(Icons.refresh),
                onPressed:
                    widget.appState.isLoading ? null : () => widget.appState.refreshLibraries(),
              ),
            ],
          ),
          body: widget.appState.isLoading
              ? const Center(child: CircularProgressIndicator())
              : libs.isEmpty
                  ? const Center(child: Text('暂无媒体库，点击右上角刷新重试'))
                  : Padding(
                      padding: const EdgeInsets.all(12),
                      child: GridView.builder(
                        gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
                          maxCrossAxisExtent: 170,
                          mainAxisSpacing: 8,
                          crossAxisSpacing: 8,
                          childAspectRatio: 1.33,
                        ),
                        itemCount: libs.length,
                        itemBuilder: (context, index) {
                          final LibraryInfo lib = libs[index];
                          final imageUrl = EmbyApi.imageUrl(
                            baseUrl: widget.appState.baseUrl!,
                            itemId: lib.id,
                            token: widget.appState.token!,
                            maxWidth: 400,
                          );
                          return InkWell(
                            borderRadius: BorderRadius.circular(12),
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
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                AspectRatio(
                                  aspectRatio: 16 / 9,
                                  child: ClipRRect(
                                    borderRadius: BorderRadius.circular(12),
                                    child: CachedNetworkImage(
                                      imageUrl: imageUrl,
                                      fit: BoxFit.cover,
                                      placeholder: (_, __) => const ColoredBox(
                                        color: Colors.black12,
                                        child: Center(child: Icon(Icons.image)),
                                      ),
                                      errorWidget: (_, __, ___) => const ColoredBox(
                                        color: Colors.black12,
                                        child: Center(child: Icon(Icons.folder)),
                                      ),
                                    ),
                                  ),
                                ),
                                const SizedBox(height: 6),
                                Text(
                                  lib.name,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: Theme.of(context).textTheme.titleMedium,
                                ),
                              ],
                            ),
                          );
                        },
                      ),
                    ),
        );
      },
    );
  }
}
