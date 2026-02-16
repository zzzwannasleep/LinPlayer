import 'dart:async';
import 'dart:ui';

import 'package:flutter/material.dart';
import 'package:lin_player_server_adapters/lin_player_server_adapters.dart';
import 'package:lin_player_state/lin_player_state.dart';

import '../../server_adapters/server_access.dart';
import '../theme/desktop_theme_extension.dart';
import '../widgets/desktop_horizontal_section.dart';
import '../widgets/desktop_media_card.dart';

class DesktopLibraryPage extends StatefulWidget {
  const DesktopLibraryPage({
    super.key,
    required this.appState,
    required this.onOpenItem,
    this.refreshSignal = 0,
  });

  final AppState appState;
  final ValueChanged<MediaItem> onOpenItem;
  final int refreshSignal;

  @override
  State<DesktopLibraryPage> createState() => _DesktopLibraryPageState();
}

class _DesktopLibraryPageState extends State<DesktopLibraryPage> {
  bool _loading = true;
  String? _error;
  Future<List<MediaItem>>? _continueFuture;
  Future<List<MediaItem>>? _recommendFuture;

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
        _recommendFuture = widget.appState.loadRandomRecommendations(
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

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: widget.appState,
      builder: (context, _) {
        final desktopTheme = DesktopThemeExtension.of(context);
        final access = resolveServerAccess(appState: widget.appState);
        final libraries = widget.appState.libraries
            .where((lib) => !widget.appState.isLibraryHidden(lib.id))
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
              child: Padding(
                padding: const EdgeInsets.fromLTRB(22, 22, 22, 34),
                child: CustomScrollView(
                  slivers: [
                    if ((effectiveError ?? '').trim().isNotEmpty)
                      SliverToBoxAdapter(
                        child: _ErrorBanner(
                          message: effectiveError!,
                          onRetry: () => _bootstrap(forceRefresh: true),
                        ),
                      ),
                    if ((effectiveError ?? '').trim().isNotEmpty)
                      const SliverToBoxAdapter(child: SizedBox(height: 20)),
                    if (libraries.isNotEmpty)
                      SliverToBoxAdapter(
                        child: _LibraryCategorySection(
                          libraries: libraries,
                          appState: widget.appState,
                          access: access,
                          onOpenItem: widget.onOpenItem,
                        ),
                      ),
                    if (libraries.isNotEmpty)
                      const SliverToBoxAdapter(child: SizedBox(height: 40)),
                    SliverToBoxAdapter(
                      child: _buildFutureSection(
                        title: 'Continue Watching',
                        subtitle: 'Resume from your latest progress',
                        future: _continueFuture ??
                            widget.appState.loadContinueWatching(
                              forceRefresh: false,
                            ),
                        access: access,
                      ),
                    ),
                    const SliverToBoxAdapter(child: SizedBox(height: 40)),
                    SliverToBoxAdapter(
                      child: _buildFutureSection(
                        title: 'Recommended For You',
                        subtitle: 'Random picks from your libraries',
                        future: _recommendFuture ??
                            widget.appState.loadRandomRecommendations(
                              forceRefresh: false,
                            ),
                        access: access,
                      ),
                    ),
                    for (final library in libraries) ...[
                      const SliverToBoxAdapter(child: SizedBox(height: 40)),
                      SliverToBoxAdapter(
                        child: DesktopHorizontalSection(
                          title: library.name,
                          subtitle: 'Latest entries in this library',
                          viewportHeight: 390,
                          emptyLabel: 'No media in this library yet',
                          children: widget.appState
                              .getHome('lib_${library.id}')
                              .map(
                                (item) => DesktopMediaCard(
                                  item: item,
                                  access: access,
                                  width: 214,
                                  onTap: () => widget.onOpenItem(item),
                                ),
                              )
                              .toList(growable: false),
                        ),
                      ),
                    ],
                    if (libraries.isEmpty)
                      const SliverFillRemaining(
                        hasScrollBody: false,
                        child: Center(
                          child: Text('No visible libraries'),
                        ),
                      ),
                  ],
                ),
              ),
            ),
          ),
        );
      },
    );
  }

  Widget _buildFutureSection({
    required String title,
    required String subtitle,
    required Future<List<MediaItem>> future,
    required ServerAccess? access,
  }) {
    return FutureBuilder<List<MediaItem>>(
      future: future,
      builder: (context, snapshot) {
        final items = snapshot.data ?? const <MediaItem>[];
        return DesktopHorizontalSection(
          title: title,
          subtitle: subtitle,
          viewportHeight: 390,
          emptyLabel: snapshot.connectionState == ConnectionState.waiting
              ? 'Loading...'
              : 'No media found',
          children: items
              .map(
                (item) => DesktopMediaCard(
                  item: item,
                  access: access,
                  width: 214,
                  onTap: () => widget.onOpenItem(item),
                ),
              )
              .toList(growable: false),
        );
      },
    );
  }
}

class _LibraryCategorySection extends StatelessWidget {
  const _LibraryCategorySection({
    required this.libraries,
    required this.appState,
    required this.access,
    required this.onOpenItem,
  });

  final List<LibraryInfo> libraries;
  final AppState appState;
  final ServerAccess? access;
  final ValueChanged<MediaItem> onOpenItem;

  @override
  Widget build(BuildContext context) {
    final desktopTheme = DesktopThemeExtension.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Expanded(
              child: Text(
                'Categories',
                style: TextStyle(
                  color: desktopTheme.textPrimary,
                  fontSize: 24,
                  fontWeight: FontWeight.w700,
                ),
              ),
            ),
            Text(
              'Browse',
              style: TextStyle(
                color: desktopTheme.textMuted,
                fontSize: 13,
                fontWeight: FontWeight.w600,
              ),
            ),
          ],
        ),
        const SizedBox(height: 16),
        SizedBox(
          height: 210,
          child: ListView.separated(
            scrollDirection: Axis.horizontal,
            itemCount: libraries.length,
            itemBuilder: (context, index) {
              final library = libraries[index];
              final preview = appState.getHome('lib_${library.id}');
              return _LibraryCategoryCard(
                library: library,
                preview: preview,
                access: access,
                onOpenItem: onOpenItem,
              );
            },
            separatorBuilder: (_, __) => const SizedBox(width: 16),
          ),
        ),
      ],
    );
  }
}

class _LibraryCategoryCard extends StatelessWidget {
  const _LibraryCategoryCard({
    required this.library,
    required this.preview,
    required this.access,
    required this.onOpenItem,
  });

  final LibraryInfo library;
  final List<MediaItem> preview;
  final ServerAccess? access;
  final ValueChanged<MediaItem> onOpenItem;

  static const List<List<Color>> _palette = [
    [Color(0xFF0E3951), Color(0xFF1E3A8A)],
    [Color(0xFF173353), Color(0xFF0F766E)],
    [Color(0xFF2A235D), Color(0xFF155E75)],
    [Color(0xFF233C71), Color(0xFF0E7490)],
  ];

  @override
  Widget build(BuildContext context) {
    final gradient = _palette[library.id.hashCode.abs() % _palette.length];
    final collage = preview.take(4).toList(growable: false);

    return SizedBox(
      width: 390,
      child: InkWell(
        borderRadius: BorderRadius.circular(20),
        onTap: preview.isEmpty ? null : () => onOpenItem(preview.first),
        child: DecoratedBox(
          decoration: BoxDecoration(
            gradient: LinearGradient(
              begin: Alignment.topLeft,
              end: Alignment.bottomRight,
              colors: gradient,
            ),
            borderRadius: BorderRadius.circular(20),
            boxShadow: [
              BoxShadow(
                color: Colors.black.withValues(alpha: 0.30),
                blurRadius: 18,
                offset: const Offset(0, 10),
              ),
            ],
          ),
          child: Padding(
            padding: const EdgeInsets.all(18),
            child: Row(
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        library.name.trim().isEmpty ? 'Library' : library.name,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          color: Colors.white,
                          fontSize: 22,
                          fontWeight: FontWeight.w700,
                          height: 1.15,
                        ),
                      ),
                      const SizedBox(height: 10),
                      Text(
                        library.type.trim().isEmpty
                            ? 'Collection'
                            : library.type.toUpperCase(),
                        style: const TextStyle(
                          color: Color(0xD6D3DEF0),
                          fontSize: 12,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                      const SizedBox(height: 6),
                      Text(
                        '${preview.length} items',
                        style: TextStyle(
                          color: Colors.white.withValues(alpha: 0.86),
                          fontSize: 12,
                          fontWeight: FontWeight.w500,
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(width: 14),
                SizedBox(
                  width: 124,
                  child: Stack(
                    clipBehavior: Clip.none,
                    children: [
                      for (var i = 0; i < 4; i++)
                        _CollagePoster(
                          left: 24.0 * i,
                          top: 12.0 * i,
                          item: i < collage.length ? collage[i] : null,
                          access: access,
                          placeholderLabel: '${i + 1}',
                        ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _CollagePoster extends StatelessWidget {
  const _CollagePoster({
    required this.left,
    required this.top,
    required this.item,
    required this.access,
    required this.placeholderLabel,
  });

  final double left;
  final double top;
  final MediaItem? item;
  final ServerAccess? access;
  final String placeholderLabel;

  @override
  Widget build(BuildContext context) {
    String? imageUrl;
    final currentAccess = access;
    if (item != null && currentAccess != null && item!.hasImage) {
      imageUrl = currentAccess.adapter.imageUrl(
        currentAccess.auth,
        itemId: item!.id,
        imageType: 'Primary',
        maxWidth: 280,
      );
    }

    final image = imageUrl;

    return Positioned(
      left: left,
      top: top,
      child: ClipRRect(
        borderRadius: BorderRadius.circular(12),
        child: SizedBox(
          width: 56,
          height: 84,
          child: image != null && image.isNotEmpty
              ? Image.network(
                  image,
                  fit: BoxFit.cover,
                  errorBuilder: (_, __, ___) =>
                      _collageFallback(context, placeholderLabel),
                )
              : _collageFallback(context, placeholderLabel),
        ),
      ),
    );
  }

  Widget _collageFallback(BuildContext context, String label) {
    final desktopTheme = DesktopThemeExtension.of(context);
    return DecoratedBox(
      decoration: BoxDecoration(
        color: desktopTheme.surfaceElevated,
      ),
      child: Center(
        child: Text(
          label,
          style: TextStyle(
            color: desktopTheme.textMuted,
            fontSize: 12,
            fontWeight: FontWeight.w700,
          ),
        ),
      ),
    );
  }
}

class _ErrorBanner extends StatelessWidget {
  const _ErrorBanner({
    required this.message,
    required this.onRetry,
  });

  final String message;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    return DecoratedBox(
      decoration: BoxDecoration(
        color: const Color(0x2EE14E4E),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: const Color(0x66FF8C8C)),
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
              ),
            ),
            const SizedBox(width: 10),
            TextButton(
              onPressed: onRetry,
              child: const Text('Retry'),
            ),
          ],
        ),
      ),
    );
  }
}
