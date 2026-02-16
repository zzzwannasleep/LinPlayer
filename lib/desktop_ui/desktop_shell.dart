import 'dart:async';

import 'package:flutter/foundation.dart'
    show TargetPlatform, defaultTargetPlatform, kIsWeb;
import 'package:flutter/material.dart';
import 'package:lin_player_core/state/media_server_type.dart';
import 'package:lin_player_server_adapters/lin_player_server_adapters.dart';
import 'package:lin_player_state/lin_player_state.dart';

import '../server_page.dart';
import '../settings_page.dart';
import 'pages/desktop_detail_page.dart';
import 'pages/desktop_library_page.dart';
import 'pages/desktop_navigation_layout.dart';
import 'pages/desktop_search_page.dart';
import 'pages/desktop_server_page.dart';
import 'pages/desktop_webdav_home_page.dart';
import 'theme/desktop_theme_extension.dart';
import 'view_models/desktop_detail_view_model.dart';
import 'widgets/desktop_shortcut_wrapper.dart';
import 'widgets/desktop_sidebar.dart';
import 'widgets/desktop_top_bar.dart';
import 'widgets/focus_traversal_manager.dart';
import 'widgets/window_padding_container.dart';

class DesktopShell extends StatelessWidget {
  const DesktopShell({super.key, required this.appState});

  final AppState appState;

  static bool get isDesktopTarget =>
      !kIsWeb &&
      (defaultTargetPlatform == TargetPlatform.windows ||
          defaultTargetPlatform == TargetPlatform.macOS);

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: appState,
      builder: (context, _) {
        final active = appState.activeServer;

        if (active == null || !appState.hasActiveServerProfile) {
          return DesktopServerPage(appState: appState);
        }
        if (active.serverType == MediaServerType.webdav) {
          return DesktopWebDavHomePage(appState: appState);
        }
        if (!appState.hasActiveServer) {
          return DesktopServerPage(appState: appState);
        }

        return _DesktopWorkspace(
          key: ValueKey<String>('desktop-${appState.activeServerId ?? 'none'}'),
          appState: appState,
        );
      },
    );
  }
}

enum _DesktopSection { library, search, detail }

class _DesktopWorkspace extends StatefulWidget {
  const _DesktopWorkspace({super.key, required this.appState});

  final AppState appState;

  @override
  State<_DesktopWorkspace> createState() => _DesktopWorkspaceState();
}

class _DesktopWorkspaceState extends State<_DesktopWorkspace> {
  _DesktopSection _section = _DesktopSection.library;
  final TextEditingController _searchController = TextEditingController();
  String _searchQuery = '';
  int _refreshSignal = 0;
  DesktopDetailViewModel? _detailViewModel;

  @override
  void dispose() {
    _searchController.dispose();
    _detailViewModel?.dispose();
    super.dispose();
  }

  ThemeData _withDesktopTheme(ThemeData base) {
    final current = base.extension<DesktopThemeExtension>();
    if (current != null) return base;
    return base.copyWith(
      extensions: <ThemeExtension<dynamic>>[
        ...base.extensions.values,
        DesktopThemeExtension.fallback(base.brightness),
      ],
    );
  }

  void _handleSidebarSelection(String id) {
    switch (id) {
      case 'library':
        setState(() => _section = _DesktopSection.library);
        break;
      case 'search':
        setState(() => _section = _DesktopSection.search);
        break;
      case 'servers':
        unawaited(_openServerManager());
        break;
      case 'settings':
        unawaited(_openSettings());
        break;
      case 'detail':
        if (_detailViewModel != null) {
          setState(() => _section = _DesktopSection.detail);
        }
        break;
    }
  }

  void _openDetail(MediaItem item) {
    final next = DesktopDetailViewModel(appState: widget.appState, item: item);
    _detailViewModel?.dispose();
    setState(() {
      _detailViewModel = next;
      _section = _DesktopSection.detail;
    });
    unawaited(next.load(forceRefresh: true));
  }

  void _refreshCurrentPage() {
    setState(() => _refreshSignal += 1);
    if (_section == _DesktopSection.detail && _detailViewModel != null) {
      unawaited(_detailViewModel!.load(forceRefresh: true));
    }
  }

  Future<void> _openSettings() async {
    await Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => SettingsPage(appState: widget.appState),
      ),
    );
  }

  Future<void> _openServerManager() async {
    await Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => ServerPage(
          appState: widget.appState,
          desktopLayout: true,
        ),
      ),
    );
  }

  void _handleSearchChanged(String value) {
    _searchQuery = value;
  }

  void _handleSearchSubmitted(String value) {
    setState(() {
      _searchQuery = value.trim();
      _searchController.value = TextEditingValue(
        text: _searchQuery,
        selection: TextSelection.collapsed(offset: _searchQuery.length),
      );
      _section = _DesktopSection.search;
    });
  }

  Widget _buildContent() {
    switch (_section) {
      case _DesktopSection.library:
        return DesktopLibraryPage(
          key: ValueKey<int>(_refreshSignal),
          appState: widget.appState,
          refreshSignal: _refreshSignal,
          onOpenItem: _openDetail,
        );
      case _DesktopSection.search:
        return DesktopSearchPage(
          key: ValueKey<String>('$_searchQuery-$_refreshSignal'),
          appState: widget.appState,
          query: _searchQuery,
          refreshSignal: _refreshSignal,
          onOpenItem: _openDetail,
        );
      case _DesktopSection.detail:
        final vm = _detailViewModel;
        if (vm == null) {
          return const Center(child: Text('No detail selected'));
        }
        return DesktopDetailPage(
          key: ValueKey<String>(vm.detail.id),
          viewModel: vm,
          onOpenItem: _openDetail,
          onPlayPressed: () {},
        );
    }
  }

  @override
  Widget build(BuildContext context) {
    final themed = _withDesktopTheme(Theme.of(context));

    return Theme(
      data: themed,
      child: Builder(
        builder: (context) {
          final desktopTheme = DesktopThemeExtension.of(context);
          final title = switch (_section) {
            _DesktopSection.library => 'Library',
            _DesktopSection.search => 'Search',
            _DesktopSection.detail =>
              _detailViewModel?.detail.name ?? 'Media Detail',
          };
          final selectedSidebarId = switch (_section) {
            _DesktopSection.library => 'library',
            _DesktopSection.search => 'search',
            _DesktopSection.detail => 'detail',
          };

          return ColoredBox(
            color: desktopTheme.background,
            child: SafeArea(
              child: DesktopShortcutWrapper(
                child: FocusTraversalManager(
                  child: WindowPaddingContainer(
                    child: DesktopNavigationLayout(
                      sidebar: DesktopSidebar(
                        destinations: <DesktopSidebarDestination>[
                          const DesktopSidebarDestination(
                            id: 'library',
                            label: 'Library',
                            icon: Icons.video_library_outlined,
                          ),
                          const DesktopSidebarDestination(
                            id: 'search',
                            label: 'Search',
                            icon: Icons.search_rounded,
                          ),
                          DesktopSidebarDestination(
                            id: 'detail',
                            label: 'Detail',
                            icon: Icons.movie_outlined,
                            enabled: _detailViewModel != null,
                          ),
                          const DesktopSidebarDestination(
                            id: 'servers',
                            label: 'Servers',
                            icon: Icons.storage_outlined,
                          ),
                          const DesktopSidebarDestination(
                            id: 'settings',
                            label: 'Settings',
                            icon: Icons.settings_outlined,
                          ),
                        ],
                        selectedId: selectedSidebarId,
                        onSelected: _handleSidebarSelection,
                        serverLabel: widget.appState.activeServer?.name,
                      ),
                      topBar: DesktopTopBar(
                        title: title,
                        showBack: _section == _DesktopSection.detail,
                        onBack: () => setState(
                          () => _section = _DesktopSection.library,
                        ),
                        searchController: _searchController,
                        onSearchChanged: _handleSearchChanged,
                        onSearchSubmitted: _handleSearchSubmitted,
                        onRefresh: _refreshCurrentPage,
                        onOpenSettings: _openSettings,
                      ),
                      content: AnimatedSwitcher(
                        duration: const Duration(milliseconds: 180),
                        child: _buildContent(),
                      ),
                    ),
                  ),
                ),
              ),
            ),
          );
        },
      ),
    );
  }
}
