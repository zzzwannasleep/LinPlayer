import 'dart:async';

import 'package:flutter/foundation.dart'
    show TargetPlatform, defaultTargetPlatform, kIsWeb;
import 'package:flutter/material.dart';
import 'package:lin_player_core/state/media_server_type.dart';
import 'package:lin_player_prefs/lin_player_prefs.dart';
import 'package:lin_player_server_adapters/lin_player_server_adapters.dart';
import 'package:lin_player_state/lin_player_state.dart';

import '../play_network_page.dart';
import '../play_network_page_exo.dart';
import '../server_page.dart';
import '../settings_page.dart';
import 'mock/desktop_ui_preview_page.dart';
import 'models/desktop_ui_language.dart';
import 'pages/desktop_detail_page.dart';
import 'pages/desktop_library_page.dart';
import 'pages/desktop_navigation_layout.dart';
import 'pages/desktop_search_page.dart';
import 'pages/desktop_server_page.dart';
import 'pages/desktop_ui_settings_page.dart';
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
  static const bool uiPreviewMode = bool.fromEnvironment(
    'LINPLAYER_DESKTOP_UI_PREVIEW',
    defaultValue: false,
  );

  static bool get isDesktopTarget =>
      !kIsWeb &&
      (defaultTargetPlatform == TargetPlatform.windows ||
          defaultTargetPlatform == TargetPlatform.macOS);

  @override
  Widget build(BuildContext context) {
    if (uiPreviewMode) {
      return const DesktopUiPreviewPage();
    }
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
  DesktopHomeTab _homeTab = DesktopHomeTab.home;
  bool _sidebarCollapsed = true;
  DesktopUiLanguage _uiLanguage = DesktopUiLanguage.zhCn;
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
    final fallback = DesktopThemeExtension.fallback(base.brightness);
    final existing = base.extension<DesktopThemeExtension>();
    final desktopTheme = existing ?? fallback;
    final extensions = base.extensions.values
        .where((ext) => ext is! DesktopThemeExtension)
        .toList();
    extensions.add(desktopTheme);

    final scheme = ColorScheme.fromSeed(
      seedColor: desktopTheme.accent,
      brightness: base.brightness,
    ).copyWith(
      primary: desktopTheme.accent,
      surface: desktopTheme.surface,
    );

    return base.copyWith(
      colorScheme: scheme,
      scaffoldBackgroundColor: desktopTheme.background,
      canvasColor: desktopTheme.background,
      cardColor: desktopTheme.surface,
      extensions: extensions,
    );
  }

  void _handleSidebarSelection(String id) {
    _hideSidebar();
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
        unawaited(_openDesktopUiSettings());
        break;
      case 'detail':
        if (_detailViewModel != null) {
          setState(() => _section = _DesktopSection.detail);
        }
        break;
    }
  }

  void _handleHomeTabChanged(DesktopHomeTab tab) {
    setState(() {
      _homeTab = tab;
      _section = _DesktopSection.library;
    });
  }

  void _toggleSidebar() {
    setState(() => _sidebarCollapsed = !_sidebarCollapsed);
  }

  void _hideSidebar() {
    if (_sidebarCollapsed) return;
    setState(() => _sidebarCollapsed = true);
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

  void _onPlayCurrentDetail() {
    unawaited(_playCurrentDetail());
  }

  Future<void> _playCurrentDetail() async {
    final vm = _detailViewModel;
    if (vm == null) return;

    final playable = _resolvePlayableItem(vm);
    if (playable == null) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('No playable media found for this item'),
        ),
      );
      return;
    }

    final start = playable.playbackPositionTicks > 0
        ? _ticksToDuration(playable.playbackPositionTicks)
        : null;
    final useExoCore = !kIsWeb &&
        defaultTargetPlatform == TargetPlatform.android &&
        widget.appState.playerCore == PlayerCore.exo;

    await Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => useExoCore
            ? ExoPlayNetworkPage(
                title: playable.name,
                itemId: playable.id,
                appState: widget.appState,
                server: vm.server,
                startPosition: start,
              )
            : PlayNetworkPage(
                title: playable.name,
                itemId: playable.id,
                appState: widget.appState,
                server: vm.server,
                startPosition: start,
              ),
      ),
    );

    if (!mounted) return;
    await vm.load(forceRefresh: true);
  }

  MediaItem? _resolvePlayableItem(DesktopDetailViewModel vm) {
    final detail = vm.detail;
    final type = detail.type.trim().toLowerCase();
    if (type == 'series' || type == 'season') {
      if (vm.episodes.isEmpty) return null;
      return vm.episodes.firstWhere(
        (item) => item.playbackPositionTicks > 0,
        orElse: () => vm.episodes.first,
      );
    }
    return detail;
  }

  Duration _ticksToDuration(int ticks) =>
      Duration(microseconds: (ticks / 10).round());

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

  Future<void> _openDesktopUiSettings() async {
    final selected = await Navigator.of(context).push<DesktopUiLanguage>(
      MaterialPageRoute(
        builder: (_) => DesktopUiSettingsPage(
          initialLanguage: _uiLanguage,
          onOpenSystemSettings: _openSettings,
        ),
      ),
    );
    if (!mounted || selected == null) return;
    setState(() => _uiLanguage = selected);
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
          activeTab: _homeTab,
          language: _uiLanguage,
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
          return Center(
            child: Text(
              _uiLanguage.pick(
                  zh: '\u672a\u9009\u62e9\u8be6\u60c5\u5185\u5bb9',
                  en: 'No detail selected'),
            ),
          );
        }
        return DesktopDetailPage(
          key: ValueKey<String>(vm.detail.id),
          viewModel: vm,
          onOpenItem: _openDetail,
          onPlayPressed: _onPlayCurrentDetail,
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
            _DesktopSection.library => _uiLanguage.pick(
                zh: _homeTab == DesktopHomeTab.home
                    ? '\u4e3b\u9875'
                    : '\u559c\u6b22',
                en: _homeTab == DesktopHomeTab.home ? 'Home' : 'Favorites',
              ),
            _DesktopSection.search => _uiLanguage.pick(
                zh: '\u641c\u7d22',
                en: 'Search',
              ),
            _DesktopSection.detail => _detailViewModel?.detail.name ??
                _uiLanguage.pick(
                  zh: '\u8be6\u60c5',
                  en: 'Media Detail',
                ),
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
                      sidebarWidth: 264,
                      sidebarVisible: !_sidebarCollapsed,
                      onDismissSidebar: _hideSidebar,
                      sidebar: DesktopSidebar(
                        destinations: <DesktopSidebarDestination>[
                          DesktopSidebarDestination(
                            id: 'library',
                            label: _uiLanguage.pick(
                              zh: '\u5a92\u4f53\u5e93',
                              en: 'Library',
                            ),
                            icon: Icons.video_library_outlined,
                          ),
                          DesktopSidebarDestination(
                            id: 'search',
                            label: _uiLanguage.pick(
                              zh: '\u641c\u7d22',
                              en: 'Search',
                            ),
                            icon: Icons.search_rounded,
                          ),
                          DesktopSidebarDestination(
                            id: 'detail',
                            label: _uiLanguage.pick(
                              zh: '\u8be6\u60c5',
                              en: 'Detail',
                            ),
                            icon: Icons.movie_outlined,
                            enabled: _detailViewModel != null,
                          ),
                          DesktopSidebarDestination(
                            id: 'servers',
                            label: _uiLanguage.pick(
                              zh: '\u670d\u52a1\u5668',
                              en: 'Servers',
                            ),
                            icon: Icons.storage_outlined,
                          ),
                          DesktopSidebarDestination(
                            id: 'settings',
                            label: _uiLanguage.pick(
                              zh: '\u8bbe\u7f6e',
                              en: 'Settings',
                            ),
                            icon: Icons.settings_outlined,
                          ),
                        ],
                        selectedId: selectedSidebarId,
                        onSelected: _handleSidebarSelection,
                        serverLabel: widget.appState.activeServer?.name,
                        collapsed: _sidebarCollapsed,
                      ),
                      topBar: DesktopTopBar(
                        title: title,
                        language: _uiLanguage,
                        showSearch: _section != _DesktopSection.library,
                        homeTab: _homeTab,
                        onHomeTabChanged: _handleHomeTabChanged,
                        showBack: _section == _DesktopSection.detail,
                        onBack: () => setState(
                          () => _section = _DesktopSection.library,
                        ),
                        onToggleSidebar: _toggleSidebar,
                        searchController: _searchController,
                        onSearchChanged: _handleSearchChanged,
                        onSearchSubmitted: _handleSearchSubmitted,
                        onRefresh: _refreshCurrentPage,
                        onOpenSettings: _openDesktopUiSettings,
                        searchHint: _uiLanguage.pick(
                          zh: '\u641c\u7d22\u5267\u96c6\u6216\u7535\u5f71',
                          en: 'Search series or movies',
                        ),
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
