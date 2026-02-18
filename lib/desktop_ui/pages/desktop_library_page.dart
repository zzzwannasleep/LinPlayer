import 'dart:async';

import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:lin_player_server_adapters/lin_player_server_adapters.dart';
import 'package:lin_player_state/lin_player_state.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../library_items_page.dart';
import '../../server_adapters/server_access.dart';
import '../models/desktop_ui_language.dart';
import '../theme/desktop_theme_extension.dart';
import '../widgets/desktop_media_card.dart';
import '../widgets/desktop_page_route.dart';
import '../widgets/desktop_top_bar.dart' show DesktopHomeTab;
import 'desktop_continue_watching_page.dart';
import 'desktop_favorites_items_page.dart';

class DesktopLibraryPage extends StatefulWidget {
  const DesktopLibraryPage({
    super.key,
    required this.appState,
    required this.onOpenItem,
    required this.activeTab,
    this.refreshSignal = 0,
    this.language = DesktopUiLanguage.zhCn,
  });

  final AppState appState;
  final ValueChanged<MediaItem> onOpenItem;
  final DesktopHomeTab activeTab;
  final int refreshSignal;
  final DesktopUiLanguage language;

  @override
  State<DesktopLibraryPage> createState() => _DesktopLibraryPageState();
}

class _DesktopLibraryPageState extends State<DesktopLibraryPage> {
  static const String _kDesktopFavoritesPrefix = 'desktopFavoriteIds_v1:';

  bool _loading = true;
  String? _error;
  Future<List<MediaItem>>? _continueFuture;
  List<MediaItem> _continueItems = const <MediaItem>[];
  final Set<String> _favoriteItemIds = <String>{};

  @override
  void initState() {
    super.initState();
    final hasLocalContinue = widget.appState.hasCachedContinueWatching;
    _continueFuture = widget.appState.loadContinueWatching(forceRefresh: false);
    unawaited(
      _bindContinueFuture(
        _continueFuture!,
        refreshRemoteAfterBind: hasLocalContinue,
      ),
    );
    unawaited(_restoreFavoriteIds());
    unawaited(_bootstrap(forceRefresh: false));
  }

  bool _hasCachedHomeContent() {
    final libraries = widget.appState.libraries;
    if (libraries.isEmpty) return false;
    for (final library in libraries) {
      if (widget.appState.getHome('lib_${library.id}').isNotEmpty) {
        return true;
      }
    }
    return false;
  }

  @override
  void didUpdateWidget(covariant DesktopLibraryPage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.refreshSignal != widget.refreshSignal) {
      unawaited(_bootstrap(forceRefresh: true));
    }
  }

  Future<void> _bootstrap({required bool forceRefresh}) async {
    final showBlockingLoading = forceRefresh || !_hasCachedHomeContent();
    setState(() {
      _loading = showBlockingLoading;
      _error = null;
    });

    try {
      if (widget.appState.libraries.isEmpty || forceRefresh) {
        await widget.appState.refreshLibraries();
      }
      await widget.appState.loadHome(forceRefresh: forceRefresh);

      if (!mounted) return;
      if (_continueFuture == null) {
        _continueFuture = widget.appState.loadContinueWatching(
          forceRefresh: false,
        );
        unawaited(_bindContinueFuture(_continueFuture!));
      }
      if (forceRefresh) {
        unawaited(_refreshContinueWatchingInBackground());
      }
    } catch (e) {
      if (!mounted) return;
      setState(() => _error = e.toString());
    } finally {
      if (mounted) {
        setState(() => _loading = false);
      }
    }
  }

  Future<void> _bindContinueFuture(
    Future<List<MediaItem>> future, {
    bool refreshRemoteAfterBind = false,
  }) async {
    try {
      final items = await future;
      if (!mounted) return;
      setState(() {
        _continueItems = items;
        _continueFuture = Future.value(items);
      });
      if (refreshRemoteAfterBind) {
        unawaited(_refreshContinueWatchingInBackground());
      }
    } catch (_) {
      // Keep current list when refresh fails.
    }
  }

  Future<void> _refreshContinueWatchingInBackground() async {
    final future = widget.appState.loadContinueWatching(forceRefresh: true);
    setState(() => _continueFuture = future);
    await _bindContinueFuture(future);
  }

  String get _favoriteStorageKey {
    final serverId = widget.appState.activeServerId ?? 'none';
    return '$_kDesktopFavoritesPrefix$serverId';
  }

  Future<void> _restoreFavoriteIds() async {
    final prefs = await SharedPreferences.getInstance();
    final stored = prefs.getStringList(_favoriteStorageKey) ?? const <String>[];
    final normalized = stored
        .map((item) => item.trim())
        .where((item) => item.isNotEmpty)
        .toSet();
    if (!mounted) return;
    setState(() {
      _favoriteItemIds
        ..clear()
        ..addAll(normalized);
    });
  }

  Future<void> _persistFavoriteIds() async {
    final prefs = await SharedPreferences.getInstance();
    final sorted = _favoriteItemIds.toList()..sort();
    await prefs.setStringList(_favoriteStorageKey, sorted);
  }

  Future<void> _openLibraryItemsPage({
    required String parentId,
    required String title,
  }) async {
    await Navigator.of(context).push(
      buildDesktopPageRoute(
        transition: DesktopPageTransitionStyle.push,
        builder: (_) => LibraryItemsPage(
          appState: widget.appState,
          parentId: parentId,
          title: title,
        ),
      ),
    );
  }

  Future<void> _openContinueWatchingPage() async {
    await Navigator.of(context).push(
      buildDesktopPageRoute(
        transition: DesktopPageTransitionStyle.stack,
        builder: (_) => DesktopContinueWatchingPage(
          appState: widget.appState,
          language: widget.language,
          onOpenItem: widget.onOpenItem,
        ),
      ),
    );
  }

  Future<void> _openFavoriteItemsPage({
    required String title,
    required List<MediaItem> items,
  }) async {
    if (items.isEmpty) return;
    await Navigator.of(context).push(
      buildDesktopPageRoute(
        transition: DesktopPageTransitionStyle.stack,
        builder: (_) => DesktopFavoritesItemsPage(
          appState: widget.appState,
          title: title,
          items: items,
          language: widget.language,
          isFavorite: _isFavorite,
          onToggleFavorite: _toggleFavorite,
          onOpenItem: widget.onOpenItem,
        ),
      ),
    );
  }

  void _toggleFavorite(String itemId) {
    setState(() {
      if (_favoriteItemIds.contains(itemId)) {
        _favoriteItemIds.remove(itemId);
      } else {
        _favoriteItemIds.add(itemId);
      }
    });
    unawaited(_persistFavoriteIds());
  }

  bool _isFavorite(String itemId) => _favoriteItemIds.contains(itemId);

  List<MediaItem> _applyActiveTabFilter(List<MediaItem> items) {
    if (widget.activeTab == DesktopHomeTab.home) return items;
    return items
        .where((item) => _favoriteItemIds.contains(item.id))
        .toList(growable: false);
  }

  String _continueTitle(MediaItem item) {
    final type = item.type.trim().toLowerCase();
    if (type == 'episode') {
      final seriesName = item.seriesName.trim();
      if (seriesName.isNotEmpty) return seriesName;
    }
    final name = item.name.trim();
    return name.isEmpty ? '--' : name;
  }

  String _continueSubtitle(MediaItem item) {
    final time = _formatTicksShort(item.playbackPositionTicks);
    final type = item.type.trim().toLowerCase();
    if (type == 'episode') {
      final season = (item.seasonNumber ?? 0).clamp(0, 999);
      final episode = (item.episodeNumber ?? 0).clamp(0, 999);
      if (season > 0 && episode > 0) {
        final mark = 'S${season.toString().padLeft(2, '0')}'
            'E${episode.toString().padLeft(2, '0')}';
        return '$mark | $time';
      }
    }
    return time;
  }

  String _formatTicksShort(int ticks) {
    if (ticks <= 0) return '00:00';
    final duration = Duration(seconds: ticks ~/ 10000000);
    final hours = duration.inHours;
    final minutes = duration.inMinutes.remainder(60);
    final seconds = duration.inSeconds.remainder(60);
    if (hours > 0) {
      return '${hours.toString().padLeft(2, '0')}:'
          '${minutes.toString().padLeft(2, '0')}:'
          '${seconds.toString().padLeft(2, '0')}';
    }
    return '${duration.inMinutes.toString().padLeft(2, '0')}:'
        '${seconds.toString().padLeft(2, '0')}';
  }

  double _contentHorizontalPadding(double width) {
    if (width >= 1700) return 34;
    if (width >= 1360) return 28;
    if (width >= 1080) return 24;
    return 18;
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: widget.appState,
      builder: (context, _) {
        final theme = DesktopThemeExtension.of(context);
        final horizontalPadding =
            _contentHorizontalPadding(MediaQuery.sizeOf(context).width);
        final access = resolveServerAccess(appState: widget.appState);
        final libraries = widget.appState.libraries
            .where((library) => !widget.appState.isLibraryHidden(library.id))
            .toList(growable: false);

        final appStateError = widget.appState.error;
        final effectiveError = (_error ?? '').trim().isNotEmpty
            ? _error
            : ((appStateError ?? '').trim().isNotEmpty && libraries.isEmpty
                ? appStateError
                : null);

        if (_loading && libraries.isEmpty) {
          return const Center(child: CircularProgressIndicator());
        }

        final favoriteMode = widget.activeTab == DesktopHomeTab.favorites;

        final contentChildren = <Widget>[
          if ((effectiveError ?? '').trim().isNotEmpty)
            _ErrorBanner(
              message: effectiveError!,
              onRetry: () => _bootstrap(forceRefresh: true),
              language: widget.language,
            ),
          if ((effectiveError ?? '').trim().isNotEmpty)
            const SizedBox(height: 24),
          _MediaCategorySection(
            libraries: libraries,
            appState: widget.appState,
            access: access,
            language: widget.language,
            onOpenLibrary: (library) {
              unawaited(
                _openLibraryItemsPage(
                  parentId: library.id,
                  title: library.name.trim().isEmpty
                      ? _t(
                          language: widget.language,
                          zh: '\u5a92\u4f53\u5e93',
                          en: 'Library',
                        )
                      : library.name,
                ),
              );
            },
          ),
          const SizedBox(height: 32),
          if (favoriteMode && _favoriteItemIds.isEmpty)
            _FavoritesEmptySection(language: widget.language)
          else
            _buildContinueSection(
              access: access,
              favoriteMode: favoriteMode,
            ),
        ];

        for (final library in libraries) {
          final filtered = _applyActiveTabFilter(
            widget.appState.getHome('lib_${library.id}'),
          );
          if (favoriteMode && filtered.isEmpty) continue;
          contentChildren
            ..add(const SizedBox(height: 32))
            ..add(
              _PosterRailSection(
                prefixTitle: '',
                highlightedTitle: library.name.trim().isEmpty
                    ? _t(
                        language: widget.language,
                        zh: '\u5206\u7c7b',
                        en: 'Category',
                      )
                    : library.name,
                items: filtered,
                access: access,
                loading: false,
                language: widget.language,
                onOpenItem: widget.onOpenItem,
                isFavorite: _isFavorite,
                onToggleFavorite: _toggleFavorite,
                onViewAllTap: filtered.isEmpty
                    ? null
                    : () {
                        if (favoriteMode) {
                          final sectionTitle = library.name.trim().isEmpty
                              ? _t(
                                  language: widget.language,
                                  zh: '\u5a92\u4f53\u5e93',
                                  en: 'Library',
                                )
                              : library.name;
                          unawaited(
                            _openFavoriteItemsPage(
                              title: _t(
                                language: widget.language,
                                zh: '\u559c\u6b22 \u00b7 $sectionTitle',
                                en: 'Favorites · $sectionTitle',
                              ),
                              items: filtered,
                            ),
                          );
                          return;
                        }
                        unawaited(
                          _openLibraryItemsPage(
                            parentId: library.id,
                            title: library.name.trim().isEmpty
                                ? _t(
                                    language: widget.language,
                                    zh: '\u5a92\u4f53\u5e93',
                                    en: 'Library',
                                  )
                                : library.name,
                          ),
                        );
                      },
              ),
            );
        }

        if (!favoriteMode && libraries.isEmpty) {
          contentChildren
            ..add(const SizedBox(height: 20))
            ..add(
              Text(
                _t(
                  language: widget.language,
                  zh: '\u6682\u65e0\u53ef\u89c1\u5a92\u4f53\u5e93',
                  en: 'No visible libraries',
                ),
                style: TextStyle(
                  color: theme.textMuted,
                  fontSize: 13,
                ),
              ),
            );
        }

        return Stack(
          children: [
            const Positioned.fill(child: _DecorativeBackground()),
            CustomScrollView(
              slivers: [
                SliverToBoxAdapter(
                  child: Padding(
                    padding: EdgeInsets.fromLTRB(
                        horizontalPadding, 0, horizontalPadding, 44),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: contentChildren,
                    ),
                  ),
                ),
              ],
            ),
          ],
        );
      },
    );
  }

  Widget _buildContinueSection({
    required ServerAccess? access,
    required bool favoriteMode,
  }) {
    return FutureBuilder<List<MediaItem>>(
      future: _continueFuture ??
          widget.appState.loadContinueWatching(
            forceRefresh: false,
          ),
      builder: (context, snapshot) {
        final sourceItems = snapshot.data ?? _continueItems;
        final items = _applyActiveTabFilter(sourceItems);
        if (favoriteMode &&
            items.isEmpty &&
            snapshot.connectionState != ConnectionState.waiting) {
          return const SizedBox.shrink();
        }
        return _PosterRailSection(
          prefixTitle: '',
          highlightedTitle: _t(
            language: widget.language,
            zh: '\u7ee7\u7eed\u89c2\u770b',
            en: 'Continue',
          ),
          items: items,
          access: access,
          loading: snapshot.connectionState == ConnectionState.waiting &&
              sourceItems.isEmpty,
          language: widget.language,
          onOpenItem: widget.onOpenItem,
          isFavorite: _isFavorite,
          onToggleFavorite: _toggleFavorite,
          cardWidth: 224,
          cardImageAspectRatio: 16 / 9,
          railHeight: 242,
          showCardBadge: false,
          titleBuilder: _continueTitle,
          subtitleBuilder: _continueSubtitle,
          subtitleMaxLines: 2,
          showProgress: true,
          onViewAllTap: items.isEmpty
              ? null
              : () {
                  if (favoriteMode) {
                    unawaited(
                      _openFavoriteItemsPage(
                        title: _t(
                          language: widget.language,
                          zh: '\u559c\u6b22 \u00b7 \u7ee7\u7eed\u89c2\u770b',
                          en: 'Favorites · Continue',
                        ),
                        items: items,
                      ),
                    );
                    return;
                  }
                  unawaited(_openContinueWatchingPage());
                },
        );
      },
    );
  }
}

class _DecorativeBackground extends StatelessWidget {
  const _DecorativeBackground();

  @override
  Widget build(BuildContext context) {
    final theme = DesktopThemeExtension.of(context);
    return Stack(
      fit: StackFit.expand,
      children: [
        DecoratedBox(
          decoration: BoxDecoration(
            gradient: LinearGradient(
              begin: Alignment.topCenter,
              end: Alignment.bottomCenter,
              colors: [
                theme.background.withValues(alpha: 0.12),
                Colors.transparent,
              ],
            ),
          ),
        ),
        Positioned(
          left: -80,
          top: -70,
          child: Container(
            width: 260,
            height: 260,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: theme.accent.withValues(alpha: 0.06),
            ),
          ),
        ),
        Positioned(
          right: -60,
          top: 120,
          child: Container(
            width: 220,
            height: 220,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: theme.accent.withValues(alpha: 0.04),
            ),
          ),
        ),
      ],
    );
  }
}

class _MediaCategorySection extends StatefulWidget {
  const _MediaCategorySection({
    required this.libraries,
    required this.appState,
    required this.access,
    required this.language,
    required this.onOpenLibrary,
  });

  final List<LibraryInfo> libraries;
  final AppState appState;
  final ServerAccess? access;
  final DesktopUiLanguage language;
  final ValueChanged<LibraryInfo> onOpenLibrary;

  @override
  State<_MediaCategorySection> createState() => _MediaCategorySectionState();
}

class _MediaCategorySectionState extends State<_MediaCategorySection> {
  final ScrollController _controller = ScrollController();

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _onPointerSignal(PointerSignalEvent event) {
    if (event is! PointerScrollEvent || !_controller.hasClients) return;
    final delta = event.scrollDelta.dy.abs() > event.scrollDelta.dx.abs()
        ? event.scrollDelta.dy
        : event.scrollDelta.dx;
    if (delta == 0) return;
    final target = (_controller.offset + delta).clamp(
      _controller.position.minScrollExtent,
      _controller.position.maxScrollExtent,
    );
    _controller.jumpTo(target);
  }

  void _centerLibraryCard({
    required int index,
    required double cardWidth,
    required double spacing,
  }) {
    if (!_controller.hasClients) return;
    final viewport = _controller.position.viewportDimension;
    final itemCenter = index * (cardWidth + spacing) + (cardWidth / 2);
    final target = (itemCenter - (viewport / 2)).clamp(
      _controller.position.minScrollExtent,
      _controller.position.maxScrollExtent,
    );
    _controller.animateTo(
      target,
      duration: const Duration(milliseconds: 260),
      curve: Curves.easeOutCubic,
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = DesktopThemeExtension.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          _t(
            language: widget.language,
            zh: '\u5a92\u4f53\u5e93',
            en: 'Libraries',
          ),
          style: TextStyle(
            color: theme.textPrimary,
            fontSize: 20,
            fontWeight: FontWeight.w700,
          ),
        ),
        const SizedBox(height: 16),
        if (widget.libraries.isEmpty)
          Text(
            _t(
              language: widget.language,
              zh: '\u6682\u65e0\u5206\u7c7b',
              en: 'No categories',
            ),
            style: TextStyle(color: theme.textMuted),
          )
        else
          LayoutBuilder(
            builder: (context, constraints) {
              const spacing = 16.0;
              final cardWidth =
                  (constraints.maxWidth * 0.2).clamp(156.0, 220.0);
              final cardHeight = cardWidth / 1.62;

              return SizedBox(
                height: cardHeight,
                child: Listener(
                  onPointerSignal: _onPointerSignal,
                  child: ListView.separated(
                    controller: _controller,
                    scrollDirection: Axis.horizontal,
                    physics: const BouncingScrollPhysics(),
                    itemCount: widget.libraries.length,
                    separatorBuilder: (_, __) => const SizedBox(width: spacing),
                    itemBuilder: (context, index) {
                      final library = widget.libraries[index];
                      final preview =
                          widget.appState.getHome('lib_${library.id}');
                      return _CategoryCard(
                        width: cardWidth,
                        height: cardHeight,
                        library: library,
                        preview: preview,
                        access: widget.access,
                        language: widget.language,
                        onTap: () {
                          _centerLibraryCard(
                            index: index,
                            cardWidth: cardWidth,
                            spacing: spacing,
                          );
                          widget.onOpenLibrary(library);
                        },
                      );
                    },
                  ),
                ),
              );
            },
          ),
      ],
    );
  }
}

class _CategoryCard extends StatelessWidget {
  const _CategoryCard({
    required this.width,
    required this.height,
    required this.library,
    required this.preview,
    required this.access,
    required this.language,
    this.onTap,
  });

  final double width;
  final double height;
  final LibraryInfo library;
  final List<MediaItem> preview;
  final ServerAccess? access;
  final DesktopUiLanguage language;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final theme = DesktopThemeExtension.of(context);
    final imageCandidates = <String>[];
    final libraryCoverCandidates = _libraryImageCandidates(
      access: access,
      library: library,
    );
    for (final url in libraryCoverCandidates) {
      if (!imageCandidates.contains(url)) {
        imageCandidates.add(url);
      }
    }
    for (final item in preview.take(8)) {
      final urls = _coverImageCandidates(access: access, item: item);
      for (final url in urls) {
        if (!imageCandidates.contains(url)) {
          imageCandidates.add(url);
        }
      }
      if (imageCandidates.length >= 12) break;
    }

    final label = library.name.trim().isEmpty
        ? _t(
            language: language,
            zh: '\u5206\u7c7b',
            en: 'Category',
          )
        : library.name;

    return _HoverScaleCard(
      width: width,
      height: height,
      borderRadius: 8,
      onTap: onTap,
      child: Stack(
        fit: StackFit.expand,
        children: [
          if (imageCandidates.isNotEmpty)
            _CategoryCoverImage(
              imageUrls: imageCandidates,
              placeholder: ColoredBox(color: theme.surfaceElevated),
            )
          else
            DecoratedBox(
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  begin: Alignment.topLeft,
                  end: Alignment.bottomRight,
                  colors: [theme.surfaceElevated, theme.surface],
                ),
              ),
            ),
          Positioned.fill(
            child: DecoratedBox(
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  begin: Alignment.topCenter,
                  end: Alignment.bottomCenter,
                  colors: [
                    Colors.transparent,
                    theme.categoryOverlay,
                  ],
                  stops: const [0.45, 1.0],
                ),
              ),
            ),
          ),
          Positioned(
            left: 10,
            right: 10,
            bottom: 8,
            child: Text(
              label,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              textAlign: TextAlign.center,
              style: TextStyle(
                color: theme.textPrimary,
                fontSize: 12,
                fontWeight: FontWeight.w500,
                shadows: const [
                  Shadow(
                    color: Colors.black54,
                    blurRadius: 8,
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _CategoryCoverImage extends StatefulWidget {
  const _CategoryCoverImage({
    required this.imageUrls,
    required this.placeholder,
  });

  final List<String> imageUrls;
  final Widget placeholder;

  @override
  State<_CategoryCoverImage> createState() => _CategoryCoverImageState();
}

class _CategoryCoverImageState extends State<_CategoryCoverImage> {
  int _currentIndex = 0;

  @override
  void didUpdateWidget(covariant _CategoryCoverImage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.imageUrls.join('|') != widget.imageUrls.join('|')) {
      _currentIndex = 0;
    }
  }

  @override
  Widget build(BuildContext context) {
    final urls = widget.imageUrls
        .map((value) => value.trim())
        .where((value) => value.isNotEmpty)
        .toList(growable: false);
    if (urls.isEmpty || _currentIndex >= urls.length) {
      return widget.placeholder;
    }

    final imageUrl = urls[_currentIndex];
    return CachedNetworkImage(
      key: ValueKey<String>('category-$imageUrl'),
      imageUrl: imageUrl,
      fit: BoxFit.cover,
      placeholder: (_, __) => widget.placeholder,
      errorWidget: (_, __, ___) {
        if (_currentIndex < urls.length - 1) {
          WidgetsBinding.instance.addPostFrameCallback((_) {
            if (!mounted) return;
            setState(() => _currentIndex += 1);
          });
        }
        return widget.placeholder;
      },
    );
  }
}

class _PosterRailSection extends StatelessWidget {
  const _PosterRailSection({
    required this.prefixTitle,
    required this.highlightedTitle,
    required this.items,
    required this.access,
    required this.loading,
    required this.language,
    required this.onOpenItem,
    required this.isFavorite,
    required this.onToggleFavorite,
    this.onViewAllTap,
    this.cardWidth = 160,
    this.cardImageAspectRatio = 2 / 3,
    this.railHeight = 294,
    this.showCardBadge = true,
    this.titleBuilder,
    this.subtitleBuilder,
    this.subtitleMaxLines = 1,
    this.showProgress = false,
  });

  final String prefixTitle;
  final String highlightedTitle;
  final List<MediaItem> items;
  final ServerAccess? access;
  final bool loading;
  final DesktopUiLanguage language;
  final ValueChanged<MediaItem> onOpenItem;
  final bool Function(String itemId) isFavorite;
  final ValueChanged<String> onToggleFavorite;
  final VoidCallback? onViewAllTap;
  final double cardWidth;
  final double cardImageAspectRatio;
  final double railHeight;
  final bool showCardBadge;
  final String Function(MediaItem item)? titleBuilder;
  final String Function(MediaItem item)? subtitleBuilder;
  final int subtitleMaxLines;
  final bool showProgress;

  @override
  Widget build(BuildContext context) {
    final theme = DesktopThemeExtension.of(context);
    final trimmedPrefix = prefixTitle.trim();
    final sectionTitle = highlightedTitle.trim().isEmpty
        ? _t(language: language, zh: '\u5206\u533a', en: 'Section')
        : highlightedTitle;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Expanded(
              child: RichText(
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                text: TextSpan(
                  style: TextStyle(
                    color: theme.textPrimary,
                    fontSize: 20,
                    fontWeight: FontWeight.w700,
                  ),
                  children: [
                    if (trimmedPrefix.isNotEmpty) TextSpan(text: trimmedPrefix),
                    if (trimmedPrefix.isNotEmpty) const TextSpan(text: '  '),
                    TextSpan(
                      text: sectionTitle,
                      style: TextStyle(
                        color: trimmedPrefix.isEmpty
                            ? theme.textPrimary
                            : theme.textMuted,
                      ),
                    ),
                  ],
                ),
              ),
            ),
            _ViewAllLink(
              label: _t(
                language: language,
                zh: '\u67e5\u770b\u5168\u90e8',
                en: 'View all',
              ),
              onTap: onViewAllTap,
            ),
          ],
        ),
        const SizedBox(height: 16),
        if (loading)
          SizedBox(
            height: railHeight,
            child: Center(
              child: Text(
                _t(
                    language: language,
                    zh: '\u52a0\u8f7d\u4e2d...',
                    en: 'Loading...'),
                style: TextStyle(color: theme.textMuted),
              ),
            ),
          )
        else if (items.isEmpty)
          SizedBox(
            height: railHeight,
            child: Center(
              child: Text(
                _t(
                    language: language,
                    zh: '\u6682\u65e0\u5185\u5bb9',
                    en: 'No media found'),
                style: TextStyle(color: theme.textMuted),
              ),
            ),
          )
        else
          SizedBox(
            height: railHeight,
            child: ListView.separated(
              scrollDirection: Axis.horizontal,
              itemCount: items.length,
              itemBuilder: (context, index) {
                final item = items[index];
                return DesktopMediaCard(
                  item: item,
                  access: access,
                  width: cardWidth,
                  imageAspectRatio: cardImageAspectRatio,
                  showProgress: showProgress,
                  showBadge: showCardBadge,
                  isFavorite: isFavorite(item.id),
                  titleOverride: titleBuilder?.call(item),
                  subtitleOverride: subtitleBuilder?.call(item),
                  subtitleMaxLines: subtitleMaxLines,
                  onTap: () => onOpenItem(item),
                  onToggleFavorite: () => onToggleFavorite(item.id),
                );
              },
              separatorBuilder: (_, __) => const SizedBox(width: 16),
            ),
          ),
      ],
    );
  }
}

class _HoverScaleCard extends StatefulWidget {
  const _HoverScaleCard({
    required this.child,
    required this.width,
    required this.height,
    required this.borderRadius,
    this.onTap,
  });

  final Widget child;
  final double width;
  final double height;
  final double borderRadius;
  final VoidCallback? onTap;

  @override
  State<_HoverScaleCard> createState() => _HoverScaleCardState();
}

class _HoverScaleCardState extends State<_HoverScaleCard> {
  bool _hovered = false;
  bool _focused = false;

  bool get _active => _hovered || _focused;

  @override
  Widget build(BuildContext context) {
    final theme = DesktopThemeExtension.of(context);
    return FocusableActionDetector(
      onShowHoverHighlight: (value) => setState(() => _hovered = value),
      onShowFocusHighlight: (value) => setState(() => _focused = value),
      mouseCursor: widget.onTap != null
          ? SystemMouseCursors.click
          : SystemMouseCursors.basic,
      child: AnimatedScale(
        scale: _active ? 1.05 : 1.0,
        duration: const Duration(milliseconds: 180),
        curve: Curves.easeOutCubic,
        child: SizedBox(
          width: widget.width,
          height: widget.height,
          child: DecoratedBox(
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(widget.borderRadius),
              boxShadow: _active
                  ? [
                      BoxShadow(
                        color: theme.shadowColor.withValues(alpha: 0.9),
                        blurRadius: 16,
                        offset: const Offset(0, 8),
                      ),
                    ]
                  : null,
            ),
            child: ClipRRect(
              borderRadius: BorderRadius.circular(widget.borderRadius),
              child: Material(
                color: Colors.transparent,
                child: InkWell(
                  onTap: widget.onTap,
                  child: widget.child,
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _ViewAllLink extends StatefulWidget {
  const _ViewAllLink({
    required this.label,
    this.onTap,
  });

  final String label;
  final VoidCallback? onTap;

  @override
  State<_ViewAllLink> createState() => _ViewAllLinkState();
}

class _ViewAllLinkState extends State<_ViewAllLink> {
  bool _hovered = false;

  @override
  Widget build(BuildContext context) {
    final theme = DesktopThemeExtension.of(context);
    return MouseRegion(
      cursor: widget.onTap != null
          ? SystemMouseCursors.click
          : SystemMouseCursors.basic,
      onEnter: (_) => setState(() => _hovered = true),
      onExit: (_) => setState(() => _hovered = false),
      child: GestureDetector(
        onTap: widget.onTap,
        child: Text(
          widget.label,
          style: TextStyle(
            color: _hovered ? theme.accent : theme.link,
            fontSize: 13,
            fontWeight: FontWeight.w400,
          ),
        ),
      ),
    );
  }
}

class _FavoritesEmptySection extends StatelessWidget {
  const _FavoritesEmptySection({required this.language});

  final DesktopUiLanguage language;

  @override
  Widget build(BuildContext context) {
    final theme = DesktopThemeExtension.of(context);
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 30),
      decoration: BoxDecoration(
        color: theme.surface.withValues(alpha: 0.65),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: theme.border),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            _t(
              language: language,
              zh: '\u8fd8\u6ca1\u6709\u6536\u85cf',
              en: 'No favorites yet',
            ),
            style: TextStyle(
              color: theme.textPrimary,
              fontSize: 18,
              fontWeight: FontWeight.w700,
            ),
          ),
          const SizedBox(height: 8),
          Text(
            _t(
              language: language,
              zh: '\u5728\u4e3b\u9875\u5361\u7247\u70b9\u51fb\u7231\u5fc3\uff0c\u5c31\u4f1a\u51fa\u73b0\u5728\u8fd9\u91cc',
              en: 'Tap heart on cards from Home to collect favorites here.',
            ),
            style: TextStyle(
              color: theme.textMuted,
              fontSize: 13,
            ),
          ),
        ],
      ),
    );
  }
}

class _ErrorBanner extends StatelessWidget {
  const _ErrorBanner({
    required this.message,
    required this.onRetry,
    required this.language,
  });

  final String message;
  final VoidCallback onRetry;
  final DesktopUiLanguage language;

  @override
  Widget build(BuildContext context) {
    final theme = DesktopThemeExtension.of(context);
    return DecoratedBox(
      decoration: BoxDecoration(
        color: const Color(0x29FF5A5A),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: const Color(0x66FF7F7F)),
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
        child: Row(
          children: [
            const Icon(Icons.warning_amber_rounded, color: Color(0xFFFFB3B3)),
            const SizedBox(width: 10),
            Expanded(
              child: Text(
                message,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(color: theme.textPrimary),
              ),
            ),
            const SizedBox(width: 10),
            TextButton(
              onPressed: onRetry,
              child: Text(
                _t(language: language, zh: '\u91cd\u8bd5', en: 'Retry'),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

String _t({
  required DesktopUiLanguage language,
  required String zh,
  required String en,
}) {
  return language.pick(zh: zh, en: en);
}

String? _imageUrlById({
  required ServerAccess? access,
  required String? itemId,
  required String imageType,
  required int maxWidth,
}) {
  if (access == null) return null;
  final id = (itemId ?? '').trim();
  if (id.isEmpty) return null;
  return access.adapter.imageUrl(
    access.auth,
    itemId: id,
    imageType: imageType,
    maxWidth: maxWidth,
  );
}

List<String> _libraryImageCandidates({
  required ServerAccess? access,
  required LibraryInfo library,
}) {
  final urls = <String>[];
  final libraryId = library.id.trim();
  if (libraryId.isEmpty) return urls;

  void add({
    required String imageType,
    required int maxWidth,
  }) {
    final url = _imageUrlById(
      access: access,
      itemId: libraryId,
      imageType: imageType,
      maxWidth: maxWidth,
    );
    if (url == null || url.trim().isEmpty || urls.contains(url)) return;
    urls.add(url);
  }

  add(imageType: 'Primary', maxWidth: 900);
  add(imageType: 'Thumb', maxWidth: 900);
  add(imageType: 'Backdrop', maxWidth: 1280);
  add(imageType: 'Banner', maxWidth: 1280);
  return urls;
}

List<String> _coverImageCandidates({
  required ServerAccess? access,
  required MediaItem item,
}) {
  final urls = <String>[];

  void add({
    required String? itemId,
    required String imageType,
    required int maxWidth,
  }) {
    final url = _imageUrlById(
      access: access,
      itemId: itemId,
      imageType: imageType,
      maxWidth: maxWidth,
    );
    if (url == null || url.trim().isEmpty || urls.contains(url)) return;
    urls.add(url);
  }

  add(itemId: item.id, imageType: 'Backdrop', maxWidth: 640);
  add(itemId: item.id, imageType: 'Primary', maxWidth: 480);
  add(itemId: item.id, imageType: 'Thumb', maxWidth: 480);
  add(itemId: item.parentId, imageType: 'Primary', maxWidth: 480);
  add(itemId: item.parentId, imageType: 'Thumb', maxWidth: 480);
  add(itemId: item.seriesId, imageType: 'Primary', maxWidth: 480);
  add(itemId: item.seriesId, imageType: 'Backdrop', maxWidth: 640);

  return urls;
}
