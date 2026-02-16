import 'dart:async';

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

        return DecoratedBox(
          decoration: BoxDecoration(
            color: desktopTheme.surface.withValues(alpha: 0.72),
            borderRadius: BorderRadius.circular(18),
            border: Border.all(color: desktopTheme.border),
          ),
          child: Padding(
            padding: const EdgeInsets.fromLTRB(20, 20, 20, 30),
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
                const SliverToBoxAdapter(child: SizedBox(height: 30)),
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
                  const SliverToBoxAdapter(child: SizedBox(height: 30)),
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
