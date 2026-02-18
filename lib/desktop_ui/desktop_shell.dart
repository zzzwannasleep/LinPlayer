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
import '../settings_page.dart';
import 'mock/desktop_ui_preview_page.dart';
import 'models/desktop_ui_language.dart';
import 'pages/desktop_detail_page.dart';
import 'pages/desktop_library_page.dart';
import 'pages/desktop_navigation_layout.dart';
import 'pages/desktop_search_page.dart';
import 'pages/desktop_server_page.dart';
import 'pages/desktop_webdav_home_page.dart';
import 'theme/desktop_theme_extension.dart';
import 'view_models/desktop_detail_view_model.dart';
import 'widgets/desktop_page_route.dart';
import 'widgets/desktop_shortcut_wrapper.dart';
import 'widgets/desktop_sidebar.dart';
import 'widgets/desktop_sidebar_item.dart' show DesktopSidebarServerAction;
import 'widgets/desktop_top_bar.dart';
import 'widgets/desktop_unified_background.dart';
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

enum _DesktopSectionTransition { push, pull, fade, flip, stack }

class _DesktopWorkspace extends StatefulWidget {
  const _DesktopWorkspace({super.key, required this.appState});

  final AppState appState;

  @override
  State<_DesktopWorkspace> createState() => _DesktopWorkspaceState();
}

class _DesktopWorkspaceState extends State<_DesktopWorkspace> {
  static const double _kTopBarFadeDistance = 220.0;

  _DesktopSection _section = _DesktopSection.library;
  DesktopHomeTab _homeTab = DesktopHomeTab.home;
  bool _sidebarCollapsed = true;
  final TextEditingController _searchController = TextEditingController();
  String _searchQuery = '';
  int _refreshSignal = 0;
  DesktopDetailViewModel? _detailViewModel;
  MediaStats? _mediaStats;
  bool _loadingMediaStats = false;
  int _mediaStatsRequestVersion = 0;
  double _topBarVisibility = 1.0;
  _DesktopSectionTransition _sectionTransition = _DesktopSectionTransition.fade;

  @override
  void initState() {
    super.initState();
    unawaited(_loadMediaStats());
  }

  @override
  void dispose() {
    _searchController.dispose();
    _detailViewModel?.dispose();
    super.dispose();
  }

  DesktopUiLanguage get _uiLanguage =>
      _desktopUiLanguageFromCode(widget.appState.desktopUiLanguage);

  DesktopUiLanguage _desktopUiLanguageFromCode(String code) {
    switch (code.trim().toLowerCase()) {
      case 'en':
      case 'enus':
      case 'en-us':
      case 'en_us':
        return DesktopUiLanguage.enUs;
      default:
        return DesktopUiLanguage.zhCn;
    }
  }

  TextTheme _stripTextDecorations(TextTheme textTheme) {
    TextStyle? clear(TextStyle? style) =>
        style?.copyWith(decoration: TextDecoration.none);
    return textTheme.copyWith(
      displayLarge: clear(textTheme.displayLarge),
      displayMedium: clear(textTheme.displayMedium),
      displaySmall: clear(textTheme.displaySmall),
      headlineLarge: clear(textTheme.headlineLarge),
      headlineMedium: clear(textTheme.headlineMedium),
      headlineSmall: clear(textTheme.headlineSmall),
      titleLarge: clear(textTheme.titleLarge),
      titleMedium: clear(textTheme.titleMedium),
      titleSmall: clear(textTheme.titleSmall),
      bodyLarge: clear(textTheme.bodyLarge),
      bodyMedium: clear(textTheme.bodyMedium),
      bodySmall: clear(textTheme.bodySmall),
      labelLarge: clear(textTheme.labelLarge),
      labelMedium: clear(textTheme.labelMedium),
      labelSmall: clear(textTheme.labelSmall),
    );
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
      textTheme: _stripTextDecorations(base.textTheme),
      primaryTextTheme: _stripTextDecorations(base.primaryTextTheme),
      extensions: extensions,
    );
  }

  void _handleServerSelected(String serverId) {
    _hideSidebar();
    if (_section != _DesktopSection.library || _topBarVisibility < 1.0) {
      setState(() {
        _sectionTransition = _DesktopSectionTransition.fade;
        _section = _DesktopSection.library;
        _topBarVisibility = 1.0;
      });
    }
    if (serverId == widget.appState.activeServerId) return;
    unawaited(widget.appState.enterServer(serverId));
  }

  List<DesktopSidebarServer> _buildSidebarServers() {
    return widget.appState.servers
        .map(
          (server) => DesktopSidebarServer(
            id: server.id,
            name: server.name.trim().isEmpty ? server.baseUrl : server.name,
            subtitle: _buildServerSubtitleText(server),
            serverType: server.serverType,
            iconUrl: server.iconUrl,
          ),
        )
        .toList(growable: false);
  }

  String _buildServerSubtitleText(ServerProfile server) {
    final remark = (server.remark ?? '').trim();
    return remark;
  }

  ServerProfile? _serverById(String serverId) {
    for (final server in widget.appState.servers) {
      if (server.id == serverId) return server;
    }
    return null;
  }

  void _showInfo(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(message)),
    );
  }

  void _handleSidebarServerAction(
    String serverId,
    DesktopSidebarServerAction action,
  ) {
    switch (action) {
      case DesktopSidebarServerAction.editIcon:
        unawaited(_editServerIcon(serverId));
        break;
      case DesktopSidebarServerAction.editRemark:
        unawaited(_editServerRemark(serverId));
        break;
      case DesktopSidebarServerAction.editPassword:
        unawaited(_editServerPassword(serverId));
        break;
      case DesktopSidebarServerAction.editRoute:
        unawaited(_editServerRoute(serverId));
        break;
      case DesktopSidebarServerAction.deleteServer:
        unawaited(_deleteServer(serverId));
        break;
    }
  }

  Future<void> _editServerIcon(String serverId) async {
    final server = _serverById(serverId);
    if (server == null) return;

    final iconCtrl = TextEditingController(text: server.iconUrl ?? '');
    final result = await showDialog<String>(
      context: context,
      builder: (dialogContext) {
        return AlertDialog(
          title: Text(
            _uiLanguage.pick(
              zh: '修改图标',
              en: 'Edit icon',
            ),
          ),
          content: TextField(
            controller: iconCtrl,
            decoration: InputDecoration(
              labelText: _uiLanguage.pick(zh: '图标地址', en: 'Icon URL'),
              hintText: 'https://example.com/icon.png',
            ),
            keyboardType: TextInputType.url,
          ),
          actions: [
            TextButton(
              onPressed: iconCtrl.clear,
              child: Text(_uiLanguage.pick(zh: '清空', en: 'Clear')),
            ),
            TextButton(
              onPressed: () => Navigator.of(dialogContext).pop(),
              child: Text(_uiLanguage.pick(zh: '取消', en: 'Cancel')),
            ),
            FilledButton(
              onPressed: () =>
                  Navigator.of(dialogContext).pop(iconCtrl.text.trim()),
              child: Text(_uiLanguage.pick(zh: '保存', en: 'Save')),
            ),
          ],
        );
      },
    );
    iconCtrl.dispose();
    if (result == null) return;

    await widget.appState.updateServerMeta(serverId, iconUrl: result);
    _showInfo(_uiLanguage.pick(zh: '图标已更新', en: 'Icon updated'));
  }

  Future<void> _editServerRemark(String serverId) async {
    final server = _serverById(serverId);
    if (server == null) return;

    final remarkCtrl = TextEditingController(text: server.remark ?? '');
    final result = await showDialog<String>(
      context: context,
      builder: (dialogContext) {
        return AlertDialog(
          title: Text(
            _uiLanguage.pick(
              zh: '修改备注',
              en: 'Edit remark',
            ),
          ),
          content: TextField(
            controller: remarkCtrl,
            decoration: InputDecoration(
              labelText: _uiLanguage.pick(zh: '备注', en: 'Remark'),
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(dialogContext).pop(),
              child: Text(_uiLanguage.pick(zh: '取消', en: 'Cancel')),
            ),
            FilledButton(
              onPressed: () => Navigator.of(dialogContext).pop(remarkCtrl.text),
              child: Text(_uiLanguage.pick(zh: '保存', en: 'Save')),
            ),
          ],
        );
      },
    );
    remarkCtrl.dispose();
    if (result == null) return;

    await widget.appState.updateServerMeta(serverId, remark: result);
    _showInfo(_uiLanguage.pick(zh: '备注已更新', en: 'Remark updated'));
  }

  Future<void> _editServerPassword(String serverId) async {
    final server = _serverById(serverId);
    if (server == null) return;

    final usernameCtrl = TextEditingController(text: server.username);
    final passwordCtrl = TextEditingController();
    final showUsername = server.serverType != MediaServerType.plex;
    final secretLabel = _uiLanguage.pick(
      zh: server.serverType == MediaServerType.plex ? '令牌' : '密码',
      en: server.serverType == MediaServerType.plex ? 'Token' : 'Password',
    );

    final payload = await showDialog<Map<String, String>>(
      context: context,
      builder: (dialogContext) {
        var obscure = true;
        return StatefulBuilder(
          builder: (context, setDialogState) {
            return AlertDialog(
              title: Text(
                _uiLanguage.pick(
                  zh: '修改密码',
                  en: 'Edit password',
                ),
              ),
              content: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  if (showUsername) ...[
                    TextField(
                      controller: usernameCtrl,
                      decoration: InputDecoration(
                        labelText: _uiLanguage.pick(zh: '用户名', en: 'Username'),
                      ),
                    ),
                    const SizedBox(height: 10),
                  ],
                  TextField(
                    controller: passwordCtrl,
                    obscureText: obscure,
                    decoration: InputDecoration(
                      labelText: secretLabel,
                      suffixIcon: IconButton(
                        tooltip: _uiLanguage.pick(zh: '显示/隐藏', en: 'Show/Hide'),
                        onPressed: () =>
                            setDialogState(() => obscure = !obscure),
                        icon: Icon(
                          obscure
                              ? Icons.visibility_outlined
                              : Icons.visibility_off_outlined,
                        ),
                      ),
                    ),
                  ),
                ],
              ),
              actions: [
                TextButton(
                  onPressed: () => Navigator.of(dialogContext).pop(),
                  child: Text(_uiLanguage.pick(zh: '取消', en: 'Cancel')),
                ),
                FilledButton(
                  onPressed: () => Navigator.of(dialogContext).pop({
                    'username': usernameCtrl.text.trim(),
                    'password': passwordCtrl.text,
                  }),
                  child: Text(_uiLanguage.pick(zh: '保存', en: 'Save')),
                ),
              ],
            );
          },
        );
      },
    );

    usernameCtrl.dispose();
    passwordCtrl.dispose();
    if (payload == null) return;

    final nextPassword = (payload['password'] ?? '').trim();
    if (nextPassword.isEmpty) {
      _showInfo(_uiLanguage.pick(zh: '密码不能为空', en: 'Password is required'));
      return;
    }

    try {
      await widget.appState.updateServerPassword(
        serverId,
        password: nextPassword,
        username: showUsername ? payload['username'] : null,
      );

      if (serverId == widget.appState.activeServerId &&
          server.serverType.isEmbyLike) {
        await widget.appState.refreshDomains();
        await widget.appState.refreshLibraries();
        await widget.appState.loadHome(forceRefresh: true);
        await _loadMediaStats(forceRefresh: true);
      }

      _showInfo(_uiLanguage.pick(zh: '密码已更新', en: 'Password updated'));
    } catch (e) {
      _showInfo(e.toString());
    }
  }

  Future<void> _editServerRoute(String serverId) async {
    final server = _serverById(serverId);
    if (server == null) return;

    final routeCtrl = TextEditingController(text: server.baseUrl);
    final result = await showDialog<String>(
      context: context,
      builder: (dialogContext) {
        return AlertDialog(
          title: Text(
            _uiLanguage.pick(
              zh: '修改线路',
              en: 'Edit route',
            ),
          ),
          content: TextField(
            controller: routeCtrl,
            keyboardType: TextInputType.url,
            decoration: InputDecoration(
              labelText: _uiLanguage.pick(zh: '线路地址', en: 'Route URL'),
              hintText: 'https://emby.example.com:8920',
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(dialogContext).pop(),
              child: Text(_uiLanguage.pick(zh: '取消', en: 'Cancel')),
            ),
            FilledButton(
              onPressed: () =>
                  Navigator.of(dialogContext).pop(routeCtrl.text.trim()),
              child: Text(_uiLanguage.pick(zh: '保存', en: 'Save')),
            ),
          ],
        );
      },
    );
    routeCtrl.dispose();
    if (result == null) return;

    try {
      await widget.appState.updateServerRoute(serverId, url: result);
      if (serverId == widget.appState.activeServerId &&
          server.serverType.isEmbyLike) {
        await widget.appState.refreshDomains();
        await widget.appState.refreshLibraries();
        await widget.appState.loadHome(forceRefresh: true);
        await _loadMediaStats(forceRefresh: true);
      }
      _showInfo(_uiLanguage.pick(zh: '线路已更新', en: 'Route updated'));
    } catch (e) {
      _showInfo(e.toString());
    }
  }

  Future<void> _deleteServer(String serverId) async {
    final server = _serverById(serverId);
    if (server == null) return;

    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) {
        return AlertDialog(
          title: Text(_uiLanguage.pick(
            zh: '删除服务器？',
            en: 'Delete server?',
          )),
          content: Text(
            _uiLanguage.pick(
              zh: '将删除“${server.name}”。',
              en: 'This will remove "${server.name}".',
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(dialogContext).pop(false),
              child: Text(_uiLanguage.pick(zh: '取消', en: 'Cancel')),
            ),
            FilledButton(
              onPressed: () => Navigator.of(dialogContext).pop(true),
              child: Text(_uiLanguage.pick(zh: '删除', en: 'Delete')),
            ),
          ],
        );
      },
    );
    if (confirmed != true) return;

    await widget.appState.removeServer(serverId);
    _showInfo(_uiLanguage.pick(zh: '服务器已删除', en: 'Server deleted'));
  }

  Future<void> _loadMediaStats({bool forceRefresh = false}) async {
    final requestVersion = ++_mediaStatsRequestVersion;
    if (mounted) {
      setState(() => _loadingMediaStats = true);
    }
    try {
      final stats =
          await widget.appState.loadMediaStats(forceRefresh: forceRefresh);
      if (!mounted || requestVersion != _mediaStatsRequestVersion) return;
      setState(() => _mediaStats = stats);
    } catch (_) {
      // Keep existing stats if loading fails.
    } finally {
      if (mounted && requestVersion == _mediaStatsRequestVersion) {
        setState(() => _loadingMediaStats = false);
      }
    }
  }

  void _handleHomeTabChanged(DesktopHomeTab tab) {
    setState(() {
      _sectionTransition = _DesktopSectionTransition.stack;
      _homeTab = tab;
      _section = _DesktopSection.library;
      _topBarVisibility = 1.0;
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
      _sectionTransition = _DesktopSectionTransition.push;
      _detailViewModel = next;
      _section = _DesktopSection.detail;
      _topBarVisibility = 1.0;
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
      buildDesktopPageRoute(
        transition: DesktopPageTransitionStyle.push,
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
    unawaited(_loadMediaStats(forceRefresh: true));
  }

  Future<void> _openSettings() async {
    await Navigator.of(context).push(
      buildDesktopPageRoute(
        transition: DesktopPageTransitionStyle.stack,
        builder: (_) => SettingsPage(appState: widget.appState),
      ),
    );
  }

  Future<void> _openRouteManager() async {
    if (widget.appState.domains.isEmpty && !widget.appState.isLoading) {
      unawaited(widget.appState.refreshDomains());
    }

    final desktopTheme = DesktopThemeExtension.of(context);
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final sheetBackground = desktopTheme.surface.withValues(
      alpha: isDark ? 0.95 : 0.98,
    );
    await showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      backgroundColor: sheetBackground,
      builder: (sheetContext) {
        return AnimatedBuilder(
          animation: widget.appState,
          builder: (context, _) {
            final current = widget.appState.baseUrl;
            final customEntries = widget.appState.customDomains
                .map((d) => DomainInfo(name: d.name, url: d.url))
                .toList(growable: false);
            final pluginDomains = widget.appState.domains;
            final entries = buildRouteEntries(
              currentUrl: current,
              customEntries: customEntries,
              pluginDomains: pluginDomains,
            );

            return SafeArea(
              child: Padding(
                padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Expanded(
                          child: Text(
                            _uiLanguage.pick(
                              zh: '\u7ebf\u8def\u7ba1\u7406',
                              en: 'Route Manager',
                            ),
                            style: const TextStyle(
                              fontSize: 18,
                              fontWeight: FontWeight.w700,
                            ),
                          ),
                        ),
                        IconButton(
                          tooltip: _uiLanguage.pick(
                            zh: '\u6dfb\u52a0\u81ea\u5b9a\u4e49\u7ebf\u8def',
                            en: 'Add custom route',
                          ),
                          onPressed: _addCustomRoute,
                          icon: const Icon(Icons.add),
                        ),
                        IconButton(
                          tooltip: _uiLanguage.pick(
                            zh: '\u5237\u65b0',
                            en: 'Refresh',
                          ),
                          onPressed: widget.appState.isLoading
                              ? null
                              : widget.appState.refreshDomains,
                          icon: const Icon(Icons.refresh),
                        ),
                      ],
                    ),
                    const SizedBox(height: 4),
                    if (entries.isEmpty && !widget.appState.isLoading)
                      Padding(
                        padding: const EdgeInsets.symmetric(vertical: 16),
                        child: Text(
                          _uiLanguage.pick(
                            zh: '\u6682\u65e0\u53ef\u7528\u7ebf\u8def\uff08\u672a\u90e8\u7f72\u6269\u5c55\u65f6\u5c5e\u4e8e\u6b63\u5e38\u60c5\u51b5\uff09',
                            en: 'No routes available',
                          ),
                        ),
                      )
                    else
                      Flexible(
                        child: ListView.separated(
                          shrinkWrap: true,
                          itemCount: entries.length,
                          separatorBuilder: (_, __) => const Divider(height: 1),
                          itemBuilder: (context, index) {
                            final entry = entries[index];
                            final domain = entry.domain;
                            final selected = current == domain.url;
                            final remark =
                                widget.appState.domainRemark(domain.url);
                            return ListTile(
                              dense: true,
                              contentPadding: EdgeInsets.zero,
                              title: Text(
                                domain.name.trim().isEmpty
                                    ? domain.url
                                    : domain.name.trim(),
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                              ),
                              subtitle: Text(
                                [
                                  if ((remark ?? '').trim().isNotEmpty)
                                    remark!.trim(),
                                  domain.url,
                                ].join(' | '),
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                              ),
                              trailing: selected
                                  ? Icon(Icons.check,
                                      color: desktopTheme.accent)
                                  : null,
                              onLongPress: !entry.isCustom
                                  ? null
                                  : () => _removeCustomRoute(domain.url),
                              onTap: () async {
                                if (selected) {
                                  Navigator.of(sheetContext).pop();
                                  return;
                                }
                                await widget.appState.setBaseUrl(domain.url);
                                await widget.appState.refreshLibraries();
                                await widget.appState.loadHome(
                                  forceRefresh: true,
                                );
                                await _loadMediaStats(forceRefresh: true);
                                if (!sheetContext.mounted) return;
                                Navigator.of(sheetContext).pop();
                              },
                            );
                          },
                        ),
                      ),
                  ],
                ),
              ),
            );
          },
        );
      },
    );
  }

  Future<void> _addCustomRoute() async {
    final nameCtrl = TextEditingController();
    final urlCtrl = TextEditingController();
    final remarkCtrl = TextEditingController();

    final result = await showDialog<Map<String, String>>(
      context: context,
      builder: (dialogContext) {
        return AlertDialog(
          title: Text(
            _uiLanguage.pick(
              zh: '\u6dfb\u52a0\u81ea\u5b9a\u4e49\u7ebf\u8def',
              en: 'Add custom route',
            ),
          ),
          content: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                TextField(
                  controller: nameCtrl,
                  decoration: InputDecoration(
                    labelText: _uiLanguage.pick(zh: '\u540d\u79f0', en: 'Name'),
                    hintText: _uiLanguage.pick(
                      zh: '\u4f8b\u5982\uff1a\u76f4\u8fde / \u5907\u7528',
                      en: 'e.g. Primary / Backup',
                    ),
                  ),
                ),
                const SizedBox(height: 10),
                TextField(
                  controller: urlCtrl,
                  decoration: InputDecoration(
                    labelText: _uiLanguage.pick(zh: '\u5730\u5740', en: 'URL'),
                    hintText: 'https://emby.example.com:8920',
                  ),
                  keyboardType: TextInputType.url,
                ),
                const SizedBox(height: 10),
                TextField(
                  controller: remarkCtrl,
                  decoration: InputDecoration(
                    labelText: _uiLanguage.pick(
                      zh: '\u5907\u6ce8\uff08\u53ef\u9009\uff09',
                      en: 'Remark (optional)',
                    ),
                    hintText: _uiLanguage.pick(
                      zh: '\u4f8b\u5982\uff1a\u79fb\u52a8\u7f51\u7edc',
                      en: 'e.g. Mobile network',
                    ),
                  ),
                ),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(dialogContext).pop(),
              child: Text(_uiLanguage.pick(zh: '\u53d6\u6d88', en: 'Cancel')),
            ),
            FilledButton(
              onPressed: () {
                Navigator.of(dialogContext).pop({
                  'name': nameCtrl.text.trim(),
                  'url': urlCtrl.text.trim(),
                  'remark': remarkCtrl.text.trim(),
                });
              },
              child: Text(_uiLanguage.pick(zh: '\u4fdd\u5b58', en: 'Save')),
            ),
          ],
        );
      },
    );
    nameCtrl.dispose();
    urlCtrl.dispose();
    remarkCtrl.dispose();

    if (result == null) return;
    try {
      await widget.appState.addCustomDomain(
        name: result['name'] ?? '',
        url: result['url'] ?? '',
        remark: (result['remark'] ?? '').trim().isEmpty
            ? null
            : (result['remark'] ?? '').trim(),
      );
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(e.toString())),
      );
    }
  }

  Future<void> _removeCustomRoute(String url) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) {
        return AlertDialog(
          title: Text(_uiLanguage.pick(
            zh: '\u5220\u9664\u7ebf\u8def\uff1f',
            en: 'Delete route?',
          )),
          content: Text(
            _uiLanguage.pick(
              zh: '\u5c06\u5220\u9664\u8be5\u81ea\u5b9a\u4e49\u7ebf\u8def\u3002',
              en: 'This custom route will be removed.',
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(dialogContext).pop(false),
              child: Text(_uiLanguage.pick(zh: '\u53d6\u6d88', en: 'Cancel')),
            ),
            FilledButton(
              onPressed: () => Navigator.of(dialogContext).pop(true),
              child: Text(_uiLanguage.pick(zh: '\u5220\u9664', en: 'Delete')),
            ),
          ],
        );
      },
    );
    if (confirmed != true) return;
    await widget.appState.removeCustomDomain(url);
  }

  void _handleSearchChanged(String value) {
    _searchQuery = value;
  }

  void _handleSearchSubmitted(String value) {
    setState(() {
      _sectionTransition = _DesktopSectionTransition.flip;
      _searchQuery = value.trim();
      _searchController.value = TextEditingValue(
        text: _searchQuery,
        selection: TextSelection.collapsed(offset: _searchQuery.length),
      );
      _section = _DesktopSection.search;
      _topBarVisibility = 1.0;
    });
  }

  void _setTopBarVisibility(double value) {
    final next = value.clamp(0.0, 1.0).toDouble();
    if ((next - _topBarVisibility).abs() <= 0.001 || !mounted) return;
    setState(() => _topBarVisibility = next);
  }

  void _updateTopBarVisibilityByScrollDelta(double delta) {
    if (delta.abs() < 0.1) return;
    final next = _topBarVisibility - (delta / _kTopBarFadeDistance);
    _setTopBarVisibility(next);
  }

  bool _handleContentScrollNotification(ScrollNotification notification) {
    if (notification.depth != 0) return false;
    final axis = axisDirectionToAxis(notification.metrics.axisDirection);
    if (axis != Axis.vertical) return false;

    final pixels = notification.metrics.pixels;
    if (pixels <= 0) {
      _setTopBarVisibility(1.0);
      return false;
    }

    if (notification is ScrollUpdateNotification) {
      final delta = notification.scrollDelta ?? 0;
      _updateTopBarVisibilityByScrollDelta(delta);
      return false;
    }

    if (notification is OverscrollNotification) {
      _updateTopBarVisibilityByScrollDelta(notification.overscroll);
      return false;
    }

    if (notification is ScrollEndNotification && pixels <= 1) {
      _setTopBarVisibility(1.0);
      return false;
    }

    return false;
  }

  Widget _buildContent() {
    switch (_section) {
      case _DesktopSection.library:
        return DesktopLibraryPage(
          key: ValueKey<String>('library-${_homeTab.name}-$_refreshSignal'),
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
          language: _uiLanguage,
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
          language: _uiLanguage,
          onOpenItem: _openDetail,
          onPlayPressed: _onPlayCurrentDetail,
        );
    }
  }

  Widget _buildContentTransition(Widget child, Animation<double> animation) {
    final curved = CurvedAnimation(
      parent: animation,
      curve: Curves.easeOutCubic,
      reverseCurve: Curves.easeInCubic,
    );

    switch (_sectionTransition) {
      case _DesktopSectionTransition.push:
        return FadeTransition(
          opacity: Tween<double>(begin: 0.24, end: 1.0).animate(curved),
          child: SlideTransition(
            position: Tween<Offset>(
              begin: const Offset(0.07, 0),
              end: Offset.zero,
            ).animate(curved),
            child: child,
          ),
        );
      case _DesktopSectionTransition.pull:
        return FadeTransition(
          opacity: Tween<double>(begin: 0.30, end: 1.0).animate(curved),
          child: SlideTransition(
            position: Tween<Offset>(
              begin: const Offset(-0.06, 0),
              end: Offset.zero,
            ).animate(curved),
            child: child,
          ),
        );
      case _DesktopSectionTransition.fade:
        return FadeTransition(
          opacity: curved,
          child: child,
        );
      case _DesktopSectionTransition.flip:
        return FadeTransition(
          opacity: Tween<double>(begin: 0.2, end: 1.0).animate(curved),
          child: AnimatedBuilder(
            animation: curved,
            child: child,
            builder: (context, child) {
              final matrix = Matrix4.identity()
                ..setEntry(3, 2, 0.0013)
                ..rotateY((1 - curved.value) * 0.09);
              return Transform(
                alignment: Alignment.center,
                transform: matrix,
                child: child,
              );
            },
          ),
        );
      case _DesktopSectionTransition.stack:
        return FadeTransition(
          opacity: Tween<double>(begin: 0.0, end: 1.0).animate(curved),
          child: ScaleTransition(
            scale: Tween<double>(begin: 0.965, end: 1.0).animate(curved),
            child: child,
          ),
        );
    }
  }

  @override
  Widget build(BuildContext context) {
    final themed = _withDesktopTheme(Theme.of(context));

    return Theme(
      data: themed,
      child: DefaultTextStyle.merge(
        style: const TextStyle(decoration: TextDecoration.none),
        child: Builder(
          builder: (context) {
            final desktopTheme = DesktopThemeExtension.of(context);
            final isDark = Theme.of(context).brightness == Brightness.dark;
            final hasCustomBackground =
                widget.appState.desktopBackgroundImage.trim().isNotEmpty;
            final isDetailSection = _section == _DesktopSection.detail;
            final baseBackground = desktopTheme.background;
            final contentBackgroundStart = isDetailSection
                ? desktopTheme.background
                : desktopTheme.backgroundGradientStart;
            final contentBackgroundEnd = isDetailSection
                ? desktopTheme.background
                : desktopTheme.backgroundGradientEnd;
            final overlayBackgroundStart = hasCustomBackground
                ? contentBackgroundStart.withValues(
                    alpha: isDark ? 0.68 : 0.82,
                  )
                : contentBackgroundStart;
            final overlayBackgroundEnd = hasCustomBackground
                ? contentBackgroundEnd.withValues(
                    alpha: isDark ? 0.74 : 0.88,
                  )
                : contentBackgroundEnd;
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
            final sidebarServers = _buildSidebarServers();

            return ColoredBox(
              color: baseBackground,
              child: Stack(
                fit: StackFit.expand,
                children: [
                  Positioned.fill(
                    child: DesktopUnifiedBackground(
                      appState: widget.appState,
                      baseColor: baseBackground,
                    ),
                  ),
                  SafeArea(
                    child: DesktopShortcutWrapper(
                      child: FocusTraversalManager(
                        child: WindowPaddingContainer(
                          padding: EdgeInsets.zero,
                          dragRegionHeight: 0,
                          child: DesktopNavigationLayout(
                            backgroundStartColor: overlayBackgroundStart,
                            backgroundEndColor: overlayBackgroundEnd,
                            sidebarWidth: 264,
                            sidebarVisible: !_sidebarCollapsed,
                            onDismissSidebar: _hideSidebar,
                            sidebar: DesktopSidebar(
                              servers: sidebarServers,
                              selectedServerId: widget.appState.activeServerId,
                              onSelected: _handleServerSelected,
                              onServerAction: _handleSidebarServerAction,
                              collapsed: _sidebarCollapsed,
                            ),
                            topBar: DesktopTopBar(
                              title: title,
                              serverName:
                                  widget.appState.activeServer?.name ?? '',
                              movieCount: _mediaStats?.movieCount,
                              seriesCount: _mediaStats?.seriesCount,
                              statsLoading: _loadingMediaStats,
                              language: _uiLanguage,
                              showSearch: _section != _DesktopSection.library,
                              homeTab: _homeTab,
                              onHomeTabChanged: _handleHomeTabChanged,
                              showBack: _section == _DesktopSection.detail,
                              onBack: () => setState(() {
                                _sectionTransition =
                                    _DesktopSectionTransition.pull;
                                _section = _DesktopSection.library;
                                _topBarVisibility = 1.0;
                              }),
                              onToggleSidebar: _toggleSidebar,
                              searchController: _searchController,
                              onSearchChanged: _handleSearchChanged,
                              onSearchSubmitted: _handleSearchSubmitted,
                              onRefresh: _refreshCurrentPage,
                              onOpenRouteManager: _openRouteManager,
                              onOpenSettings: _openSettings,
                              searchHint: _uiLanguage.pick(
                                zh: '\u641c\u7d22\u5267\u96c6\u6216\u7535\u5f71',
                                en: 'Search series or movies',
                              ),
                            ),
                            content: AnimatedSwitcher(
                              duration: const Duration(milliseconds: 360),
                              switchInCurve: Curves.easeOutCubic,
                              switchOutCurve: Curves.easeInCubic,
                              transitionBuilder: _buildContentTransition,
                              child: NotificationListener<ScrollNotification>(
                                onNotification:
                                    _handleContentScrollNotification,
                                child: _buildContent(),
                              ),
                            ),
                            topBarVisibility: _topBarVisibility,
                          ),
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            );
          },
        ),
      ),
    );
  }
}
