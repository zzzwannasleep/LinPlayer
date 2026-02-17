import 'dart:async';

import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:lin_player_server_adapters/lin_player_server_adapters.dart';
import 'package:lin_player_state/lin_player_state.dart';

import '../../server_adapters/server_access.dart';
import '../models/desktop_ui_language.dart';
import '../theme/desktop_theme_extension.dart';
import '../widgets/desktop_media_card.dart';
import '../widgets/desktop_top_bar.dart' show DesktopHomeTab;

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
  bool _loading = true;
  String? _error;
  Future<List<MediaItem>>? _continueFuture;
  final Set<String> _favoriteItemIds = <String>{};

  @override
  void initState() {
    super.initState();
    unawaited(_bootstrap(forceRefresh: false));
  }

  @override
  void didUpdateWidget(covariant DesktopLibraryPage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.refreshSignal != widget.refreshSignal) {
      unawaited(_bootstrap(forceRefresh: true));
    }
  }

  Future<void> _bootstrap({required bool forceRefresh}) async {
    setState(() {
      _loading = true;
      _error = null;
    });

    try {
      if (widget.appState.libraries.isEmpty || forceRefresh) {
        await widget.appState.refreshLibraries();
      }
      await widget.appState.loadHome(forceRefresh: true);

      if (!mounted) return;
      setState(() {
        _continueFuture = widget.appState.loadContinueWatching(
          forceRefresh: forceRefresh,
        );
      });
    } catch (e) {
      if (!mounted) return;
      setState(() => _error = e.toString());
    } finally {
      if (mounted) {
        setState(() => _loading = false);
      }
    }
  }

  void _toggleFavorite(String itemId) {
    setState(() {
      if (_favoriteItemIds.contains(itemId)) {
        _favoriteItemIds.remove(itemId);
      } else {
        _favoriteItemIds.add(itemId);
      }
    });
  }

  bool _isFavorite(String itemId) => _favoriteItemIds.contains(itemId);

  List<MediaItem> _applyActiveTabFilter(List<MediaItem> items) {
    if (widget.activeTab == DesktopHomeTab.home) return items;
    return items
        .where((item) => _favoriteItemIds.contains(item.id))
        .toList(growable: false);
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: widget.appState,
      builder: (context, _) {
        final theme = DesktopThemeExtension.of(context);
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
            onOpenItem: widget.onOpenItem,
            language: widget.language,
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
                prefixTitle: _t(
                  language: widget.language,
                  zh: '\u6700\u65b0',
                  en: 'Latest',
                ),
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
                    padding: const EdgeInsets.only(bottom: 44),
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
        final items =
            _applyActiveTabFilter(snapshot.data ?? const <MediaItem>[]);
        if (favoriteMode &&
            items.isEmpty &&
            snapshot.connectionState != ConnectionState.waiting) {
          return const SizedBox.shrink();
        }
        return _PosterRailSection(
          prefixTitle: _t(
            language: widget.language,
            zh: '\u6700\u65b0',
            en: 'Latest',
          ),
          highlightedTitle: _t(
            language: widget.language,
            zh: '\u7ee7\u7eed\u89c2\u770b',
            en: 'Continue',
          ),
          items: items,
          access: access,
          loading: snapshot.connectionState == ConnectionState.waiting,
          language: widget.language,
          onOpenItem: widget.onOpenItem,
          isFavorite: _isFavorite,
          onToggleFavorite: _toggleFavorite,
          showProgress: true,
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

class _MediaCategorySection extends StatelessWidget {
  const _MediaCategorySection({
    required this.libraries,
    required this.appState,
    required this.access,
    required this.onOpenItem,
    required this.language,
  });

  final List<LibraryInfo> libraries;
  final AppState appState;
  final ServerAccess? access;
  final ValueChanged<MediaItem> onOpenItem;
  final DesktopUiLanguage language;

  @override
  Widget build(BuildContext context) {
    final theme = DesktopThemeExtension.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          _t(
            language: language,
            zh: '\u6211\u7684\u5a92\u4f53',
            en: 'My Media',
          ),
          style: TextStyle(
            color: theme.textPrimary,
            fontSize: 20,
            fontWeight: FontWeight.w700,
          ),
        ),
        const SizedBox(height: 16),
        if (libraries.isEmpty)
          Text(
            _t(
              language: language,
              zh: '\u6682\u65e0\u5206\u7c7b',
              en: 'No categories',
            ),
            style: TextStyle(color: theme.textMuted),
          )
        else
          LayoutBuilder(
            builder: (context, constraints) {
              final maxWidth = constraints.maxWidth;
              const spacing = 16.0;
              final columns = (maxWidth / (140 + spacing)).floor().clamp(3, 8);
              final cardWidth = ((maxWidth - (columns - 1) * spacing) / columns)
                  .clamp(120.0, 160.0);
              final cardHeight = cardWidth / 1.4;

              return Wrap(
                spacing: spacing,
                runSpacing: spacing,
                children: libraries.map((library) {
                  final preview = appState.getHome('lib_${library.id}');
                  return _CategoryCard(
                    width: cardWidth,
                    height: cardHeight,
                    library: library,
                    preview: preview,
                    access: access,
                    onOpenItem: onOpenItem,
                    language: language,
                  );
                }).toList(growable: false),
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
    required this.onOpenItem,
    required this.language,
  });

  final double width;
  final double height;
  final LibraryInfo library;
  final List<MediaItem> preview;
  final ServerAccess? access;
  final ValueChanged<MediaItem> onOpenItem;
  final DesktopUiLanguage language;

  @override
  Widget build(BuildContext context) {
    final theme = DesktopThemeExtension.of(context);
    final coverItem = preview.firstWhere(
      (item) => item.hasImage,
      orElse: () => preview.isEmpty
          ? MediaItem(
              id: '',
              name: '',
              type: '',
              overview: '',
              communityRating: null,
              premiereDate: null,
              genres: const [],
              runTimeTicks: null,
              sizeBytes: null,
              container: null,
              providerIds: const {},
              seriesId: null,
              seriesName: '',
              seasonName: '',
              seasonNumber: null,
              episodeNumber: null,
              hasImage: false,
              playbackPositionTicks: 0,
              played: false,
              people: const [],
            )
          : preview.first,
    );
    final imageUrl = coverItem.id.isEmpty
        ? null
        : _imageUrl(
              access: access,
              item: coverItem,
              imageType: 'Backdrop',
              maxWidth: 640,
            ) ??
            _imageUrl(
              access: access,
              item: coverItem,
              imageType: 'Primary',
              maxWidth: 480,
            );

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
      onTap: preview.isEmpty ? null : () => onOpenItem(preview.first),
      child: Stack(
        fit: StackFit.expand,
        children: [
          if ((imageUrl ?? '').isNotEmpty)
            CachedNetworkImage(
              imageUrl: imageUrl!,
              fit: BoxFit.cover,
              placeholder: (_, __) => ColoredBox(color: theme.surfaceElevated),
              errorWidget: (_, __, ___) =>
                  ColoredBox(color: theme.surfaceElevated),
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
  final bool showProgress;

  @override
  Widget build(BuildContext context) {
    final theme = DesktopThemeExtension.of(context);
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
                    TextSpan(text: prefixTitle),
                    const TextSpan(text: '  '),
                    TextSpan(
                      text: sectionTitle,
                      style: TextStyle(color: theme.textMuted),
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
            ),
          ],
        ),
        const SizedBox(height: 16),
        if (loading)
          SizedBox(
            height: 294,
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
            height: 294,
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
            height: 294,
            child: ListView.separated(
              scrollDirection: Axis.horizontal,
              itemCount: items.length,
              itemBuilder: (context, index) {
                final item = items[index];
                return DesktopMediaCard(
                  item: item,
                  access: access,
                  width: 160,
                  imageAspectRatio: 2 / 3,
                  showProgress: showProgress,
                  isFavorite: isFavorite(item.id),
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
  const _ViewAllLink({required this.label});

  final String label;

  @override
  State<_ViewAllLink> createState() => _ViewAllLinkState();
}

class _ViewAllLinkState extends State<_ViewAllLink> {
  bool _hovered = false;

  @override
  Widget build(BuildContext context) {
    final theme = DesktopThemeExtension.of(context);
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      onEnter: (_) => setState(() => _hovered = true),
      onExit: (_) => setState(() => _hovered = false),
      child: Text(
        widget.label,
        style: TextStyle(
          color: _hovered ? theme.accent : theme.link,
          fontSize: 13,
          fontWeight: FontWeight.w400,
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

String? _imageUrl({
  required ServerAccess? access,
  required MediaItem? item,
  required String imageType,
  required int maxWidth,
}) {
  if (access == null || item == null) return null;
  if (imageType == 'Primary' && !item.hasImage) return null;
  return access.adapter.imageUrl(
    access.auth,
    itemId: item.id,
    imageType: imageType,
    maxWidth: maxWidth,
  );
}
