import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:lin_player_prefs/lin_player_prefs.dart';
import 'package:lin_player_state/lin_player_state.dart';
import 'package:lin_player_ui/lin_player_ui.dart';
import 'package:url_launcher/url_launcher.dart';

import 'player_screen.dart';
import 'player_screen_exo.dart';
import 'server_text_import_sheet.dart';
import 'package:lin_player_server_api/services/plex_api.dart';
import 'package:lin_player_core/state/media_server_type.dart';

class ServerPage extends StatefulWidget {
  const ServerPage({super.key, required this.appState});

  final AppState appState;

  @override
  State<ServerPage> createState() => _ServerPageState();
}

class _ServerPageState extends State<ServerPage> {
  bool _isTv(BuildContext context) => DeviceType.isTv;

  Future<void> _openLocalPlayer() async {
    final useExoCore = !kIsWeb &&
        defaultTargetPlatform == TargetPlatform.android &&
        widget.appState.playerCore == PlayerCore.exo;
    await Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => useExoCore
            ? ExoPlayerScreen(appState: widget.appState)
            : PlayerScreen(appState: widget.appState),
      ),
    );
  }

  Future<void> _showAddServerSheet() async {
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (ctx) => _AddServerSheet(
        appState: widget.appState,
        onOpenBulkImport: (sheetContext) async {
          Navigator.of(sheetContext).pop();
          await Future<void>.delayed(const Duration(milliseconds: 120));
          if (!mounted) return;
          await _showBulkImportSheet();
        },
      ),
    );
  }

  Future<void> _showBulkImportSheet() async {
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (ctx) => ServerTextImportSheet(appState: widget.appState),
    );
  }

  Future<void> _showEditServerSheet(ServerProfile server) async {
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (ctx) =>
          _EditServerSheet(appState: widget.appState, server: server),
    );
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: widget.appState,
      builder: (context, _) {
        final servers = widget.appState.servers;
        final loading = widget.appState.isLoading;
        final uiScale = context.uiScale;
        final isTv = _isTv(context);
        final listLayout = widget.appState.serverListLayout;
        final isList = listLayout == ServerListLayout.list;
        final maxCrossAxisExtent = (isTv ? 160.0 : 180.0) * uiScale;

        return Scaffold(
          body: SafeArea(
            child: CustomScrollView(
              slivers: [
                SliverToBoxAdapter(
                  child: Padding(
                    padding: const EdgeInsets.fromLTRB(20, 18, 20, 8),
                    child: Row(
                      children: [
                        Expanded(
                          child: Text(
                            '服务器',
                            style: Theme.of(context)
                                .textTheme
                                .titleLarge
                                ?.copyWith(
                                  fontWeight: FontWeight.w700,
                                  height: 1.1,
                                ),
                          ),
                        ),
                        IconButton(
                          tooltip: isList ? '网格显示' : '条状显示',
                          onPressed: loading
                              ? null
                              : () async {
                                  await widget.appState.setServerListLayout(
                                    isList
                                        ? ServerListLayout.grid
                                        : ServerListLayout.list,
                                  );
                                },
                          icon: Icon(isList
                              ? Icons.grid_view_outlined
                              : Icons.view_list_outlined),
                        ),
                        if (!isTv)
                          IconButton(
                            tooltip: '主题',
                            onPressed: () => showThemeSheet(
                              context,
                              listenable: widget.appState,
                              themeMode: () => widget.appState.themeMode,
                              setThemeMode: widget.appState.setThemeMode,
                              useDynamicColor: () =>
                                  widget.appState.useDynamicColor,
                              setUseDynamicColor:
                                  widget.appState.setUseDynamicColor,
                              uiTemplate: () => widget.appState.uiTemplate,
                              setUiTemplate: widget.appState.setUiTemplate,
                            ),
                            icon: const Icon(Icons.palette_outlined),
                          ),
                        IconButton(
                          tooltip: '添加服务器',
                          onPressed: loading ? null : _showAddServerSheet,
                          icon: const Icon(Icons.add),
                        ),
                      ],
                    ),
                  ),
                ),
                if (loading)
                  const SliverToBoxAdapter(
                    child: Padding(
                      padding: EdgeInsets.symmetric(horizontal: 20),
                      child: LinearProgressIndicator(),
                    ),
                  ),
                if (!isTv)
                  SliverToBoxAdapter(
                    child: Padding(
                      padding: const EdgeInsets.fromLTRB(16, 6, 16, 4),
                      child: Card(
                        clipBehavior: Clip.antiAlias,
                        child: ListTile(
                          leading: const Icon(Icons.folder_open),
                          title: const Text('本地播放'),
                          subtitle: const Text('无需登录，直接播放本地文件'),
                          trailing: const Icon(Icons.chevron_right),
                          onTap: loading ? null : _openLocalPlayer,
                        ),
                      ),
                    ),
                  ),
                if (servers.isEmpty)
                  const SliverFillRemaining(
                    hasScrollBody: false,
                    child: Center(
                      child: Padding(
                        padding: EdgeInsets.all(24),
                        child: Text('还没有服务器，点右上角“+”添加。'),
                      ),
                    ),
                  )
                else
                  SliverPadding(
                    padding: const EdgeInsets.fromLTRB(16, 10, 16, 24),
                    sliver: isList
                        ? SliverList(
                            delegate: SliverChildBuilderDelegate(
                              (context, index) {
                                final server = servers[index];
                                final isActive =
                                    server.id == widget.appState.activeServerId;
                                return Padding(
                                  padding: EdgeInsets.only(
                                      bottom:
                                          index == servers.length - 1 ? 0 : 10),
                                   child: _ServerListTile(
                                     server: server,
                                     active: isActive,
                                     autofocus: isTv && isActive,
                                     onTap: loading
                                         ? null
                                         : () async {
                                            if (server.serverType ==
                                                MediaServerType.plex) {
                                              ScaffoldMessenger.of(context)
                                                  .showSnackBar(
                                                SnackBar(
                                                  content: Text(
                                                    '${server.serverType.label} 暂未支持浏览/播放（仅可保存登录信息）。',
                                                  ),
                                                ),
                                              );
                                              return;
                                            }
                                            if (server.id ==
                                                widget
                                                    .appState.activeServerId) {
                                              await Navigator.of(context)
                                                  .maybePop();
                                              return;
                                            }
                                            await widget.appState
                                                .enterServer(server.id);
                                            if (!context.mounted) return;
                                            await Navigator.of(context)
                                                .maybePop();
                                          },
                                    onLongPress: () =>
                                        _showEditServerSheet(server),
                                  ),
                                );
                              },
                              childCount: servers.length,
                            ),
                          )
                        : SliverGrid.builder(
                            gridDelegate:
                                SliverGridDelegateWithMaxCrossAxisExtent(
                              maxCrossAxisExtent: maxCrossAxisExtent,
                              mainAxisSpacing: 8,
                              crossAxisSpacing: 8,
                              childAspectRatio: 1.2,
                            ),
                            itemCount: servers.length,
                            itemBuilder: (context, index) {
                              final server = servers[index];
                              final isActive =
                                  server.id == widget.appState.activeServerId;
                              return _ServerCard(
                                server: server,
                                active: isActive,
                                autofocus: isTv && isActive,
                                onTap: loading
                                    ? null
                                    : () async {
                                        if (server.serverType ==
                                            MediaServerType.plex) {
                                          ScaffoldMessenger.of(context)
                                              .showSnackBar(
                                            SnackBar(
                                              content: Text(
                                                '${server.serverType.label} 暂未支持浏览/播放（仅可保存登录信息）。',
                                              ),
                                            ),
                                          );
                                          return;
                                        }
                                        if (server.id ==
                                            widget.appState.activeServerId) {
                                          await Navigator.of(context)
                                              .maybePop();
                                          return;
                                        }
                                        await widget.appState
                                            .enterServer(server.id);
                                        if (!context.mounted) return;
                                        await Navigator.of(context).maybePop();
                                      },
                                onLongPress: () => _showEditServerSheet(server),
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
  }
}

class _ServerCard extends StatefulWidget {
  const _ServerCard({
    required this.server,
    required this.active,
    this.autofocus = false,
    required this.onTap,
    required this.onLongPress,
  });

  final ServerProfile server;
  final bool active;
  final bool autofocus;
  final VoidCallback? onTap;
  final VoidCallback onLongPress;

  @override
  State<_ServerCard> createState() => _ServerCardState();
}

class _ServerCardState extends State<_ServerCard> {
  bool _focused = false;
  bool _hovered = false;

  @override
  Widget build(BuildContext context) {
    final server = widget.server;
    final active = widget.active;
    final colorScheme = Theme.of(context).colorScheme;
    final isDark = colorScheme.brightness == Brightness.dark;
    final highlighted = _focused || _hovered;
    final remark = (server.remark ?? '').trim();
    final subtitleText = remark.isNotEmpty
        ? '${server.serverType.label} · $remark'
        : server.serverType.label;

    final borderColor = active
        ? colorScheme.primary.withValues(alpha: 0.55)
        : highlighted
            ? colorScheme.secondary.withValues(alpha: isDark ? 0.65 : 0.55)
            : colorScheme.outlineVariant;
    final borderWidth = (active || highlighted) ? 1.35 : 1.0;

    return InkWell(
      borderRadius: BorderRadius.circular(14),
      autofocus: widget.autofocus,
      onTap: widget.onTap,
      onLongPress: widget.onLongPress,
      onFocusChange: (v) => setState(() => _focused = v),
      onHover: (v) => setState(() => _hovered = v),
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 140),
        curve: Curves.easeOut,
        decoration: BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
            colors: [
              colorScheme.surfaceContainerHigh
                  .withValues(alpha: isDark ? 0.78 : 0.92),
              colorScheme.surfaceContainerHigh
                  .withValues(alpha: isDark ? 0.62 : 0.84),
            ],
          ),
          borderRadius: BorderRadius.circular(14),
          border: Border.all(
            color: borderColor,
            width: borderWidth,
          ),
        ),
        padding: const EdgeInsets.all(8),
        child: Stack(
          children: [
            Align(
              alignment: Alignment.topLeft,
              child: server.lastErrorCode == null
                  ? const SizedBox.shrink()
                  : _ServerErrorBadge(
                      code: server.lastErrorCode!,
                      message: server.lastErrorMessage,
                    ),
            ),
            Align(
              alignment: Alignment.topRight,
              child: active
                  ? const Icon(Icons.check_circle, size: 16)
                  : const SizedBox.shrink(),
            ),
            Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    ServerIconAvatar(
                      iconUrl: server.iconUrl,
                      name: server.name,
                      radius: 12,
                    ),
                  ],
                ),
                const Spacer(),
                Text(
                  server.name,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: Theme.of(context)
                      .textTheme
                      .bodyMedium
                      ?.copyWith(fontWeight: FontWeight.w700),
                ),
                const SizedBox(height: 3),
                Text(
                  subtitleText,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: Theme.of(context)
                      .textTheme
                      .bodySmall
                      ?.copyWith(color: colorScheme.onSurfaceVariant),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class _ServerListTile extends StatefulWidget {
  const _ServerListTile({
    required this.server,
    required this.active,
    this.autofocus = false,
    required this.onTap,
    required this.onLongPress,
  });

  final ServerProfile server;
  final bool active;
  final bool autofocus;
  final VoidCallback? onTap;
  final VoidCallback onLongPress;

  @override
  State<_ServerListTile> createState() => _ServerListTileState();
}

class _ServerListTileState extends State<_ServerListTile> {
  bool _focused = false;
  bool _hovered = false;

  @override
  Widget build(BuildContext context) {
    final server = widget.server;
    final active = widget.active;
    final scheme = Theme.of(context).colorScheme;
    final isDark = scheme.brightness == Brightness.dark;
    final highlighted = _focused || _hovered;
    final remark = (server.remark ?? '').trim();
    final subtitleText = remark.isNotEmpty
        ? '${server.serverType.label} · $remark'
        : server.serverType.label;

    final borderColor = active
        ? scheme.primary.withValues(alpha: 0.55)
        : highlighted
            ? scheme.secondary.withValues(alpha: isDark ? 0.65 : 0.55)
            : scheme.outlineVariant;
    final borderWidth = (active || highlighted) ? 1.35 : 1.0;

    return InkWell(
      borderRadius: BorderRadius.circular(14),
      autofocus: widget.autofocus,
      onTap: widget.onTap,
      onLongPress: widget.onLongPress,
      onFocusChange: (v) => setState(() => _focused = v),
      onHover: (v) => setState(() => _hovered = v),
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 140),
        curve: Curves.easeOut,
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
        decoration: BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
            colors: [
              scheme.surfaceContainerHigh
                  .withValues(alpha: isDark ? 0.74 : 0.92),
              scheme.surfaceContainerHigh
                  .withValues(alpha: isDark ? 0.6 : 0.86),
            ],
          ),
          borderRadius: BorderRadius.circular(14),
          border: Border.all(color: borderColor, width: borderWidth),
        ),
        child: Row(
          children: [
            ServerIconAvatar(
              iconUrl: server.iconUrl,
              name: server.name,
              radius: 14,
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    server.name,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: Theme.of(context)
                        .textTheme
                        .bodyMedium
                        ?.copyWith(fontWeight: FontWeight.w700),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    subtitleText,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: Theme.of(context)
                        .textTheme
                        .bodySmall
                        ?.copyWith(color: scheme.onSurfaceVariant),
                  ),
                ],
              ),
            ),
            if (server.lastErrorCode != null) ...[
              _ServerErrorBadge(
                code: server.lastErrorCode!,
                message: server.lastErrorMessage,
              ),
              const SizedBox(width: 8),
            ],
            if (active) const Icon(Icons.check_circle, size: 18),
          ],
        ),
      ),
    );
  }
}

class _ServerErrorBadge extends StatelessWidget {
  const _ServerErrorBadge({required this.code, this.message});

  final int code;
  final String? message;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final isDark = colorScheme.brightness == Brightness.dark;

    final bg =
        colorScheme.errorContainer.withValues(alpha: isDark ? 0.56 : 0.74);
    final border = colorScheme.error.withValues(alpha: isDark ? 0.55 : 0.4);
    final fg = colorScheme.onErrorContainer;

    final child = Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      decoration: BoxDecoration(
        color: bg,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: border, width: 0.8),
      ),
      child: Text(
        'HTTP $code',
        style: Theme.of(context).textTheme.labelSmall?.copyWith(
              color: fg,
              fontWeight: FontWeight.w700,
            ),
      ),
    );

    final tooltip = (message ?? '').trim();
    if (tooltip.isEmpty) return child;
    return Tooltip(message: tooltip, child: child);
  }
}

enum _PlexAddMode {
  account,
  manual,
}

extension _PlexAddModeX on _PlexAddMode {
  String get label {
    switch (this) {
      case _PlexAddMode.account:
        return '账号登录（推荐）';
      case _PlexAddMode.manual:
        return '手动添加';
    }
  }
}

class _AddServerSheet extends StatefulWidget {
  const _AddServerSheet({required this.appState, this.onOpenBulkImport});

  final AppState appState;
  final Future<void> Function(BuildContext sheetContext)? onOpenBulkImport;

  @override
  State<_AddServerSheet> createState() => _AddServerSheetState();
}

class _AddServerSheetState extends State<_AddServerSheet> {
  final _formKey = GlobalKey<FormState>();
  final _nameCtrl = TextEditingController();
  final _remarkCtrl = TextEditingController();
  final _hostCtrl = TextEditingController();
  final _portCtrl = TextEditingController();
  final _userCtrl = TextEditingController();
  final _pwdCtrl = TextEditingController();
  final _plexTokenCtrl = TextEditingController();

  MediaServerType _serverType = MediaServerType.emby;
  _PlexAddMode _plexMode = _PlexAddMode.account;
  String _scheme = 'https';
  bool _pwdVisible = false;
  bool _plexTokenVisible = false;
  bool _handlingHostParse = false;
  bool _nameTouched = false;

  String? _iconUrl;
  bool _iconTouched = false;

  PlexPin? _plexPin;
  String? _plexAccountToken;
  List<PlexResource> _plexServers = const [];
  PlexResource? _selectedPlexServer;
  bool _plexLoading = false;
  String? _plexError;

  Timer? _autoMetaDebounce;
  int _autoMetaReqId = 0;
  bool _autoMetaLoading = false;
  String? _autoMetaError;
  String? _autoMetaLastUrl;

  @override
  void initState() {
    super.initState();
    _hostCtrl.addListener(_onHostChanged);
    _portCtrl.addListener(_scheduleAutoMetaFetch);
  }

  @override
  void dispose() {
    _autoMetaDebounce?.cancel();
    _nameCtrl.dispose();
    _remarkCtrl.dispose();
    _hostCtrl.dispose();
    _portCtrl.dispose();
    _userCtrl.dispose();
    _pwdCtrl.dispose();
    _plexTokenCtrl.dispose();
    super.dispose();
  }

  String _defaultPortForScheme(String s) => s == 'http' ? '80' : '443';

  void _maybeParseHostInput() {
    if (_handlingHostParse) return;
    final raw = _hostCtrl.text.trim();
    if (!raw.contains('://')) {
      if (!_nameTouched && _nameCtrl.text.trim().isEmpty && raw.isNotEmpty) {
        _nameCtrl.text = raw.split('/').first;
        _nameCtrl.selection =
            TextSelection.collapsed(offset: _nameCtrl.text.length);
      }
      return;
    }

    final uri = Uri.tryParse(raw);
    if (uri == null || !uri.hasScheme || uri.host.isEmpty) return;
    if (uri.scheme != 'http' && uri.scheme != 'https') return;

    _handlingHostParse = true;
    try {
      if (_scheme != uri.scheme) {
        setState(() => _scheme = uri.scheme);
      }
      if (uri.hasPort) {
        _portCtrl.text = uri.port.toString();
      } else if (_portCtrl.text.trim().isEmpty) {
        _portCtrl.text = _defaultPortForScheme(uri.scheme);
      }

      final hostPart =
          uri.host + ((uri.path.isNotEmpty && uri.path != '/') ? uri.path : '');
      _hostCtrl.value = _hostCtrl.value.copyWith(
        text: hostPart,
        selection: TextSelection.collapsed(offset: hostPart.length),
      );

      if (!_nameTouched && _nameCtrl.text.trim().isEmpty) {
        _nameCtrl.text = uri.host;
        _nameCtrl.selection =
            TextSelection.collapsed(offset: _nameCtrl.text.length);
      }
    } finally {
      _handlingHostParse = false;
    }
  }

  void _onHostChanged() {
    _maybeParseHostInput();
    _scheduleAutoMetaFetch();
  }

  Uri? _buildAutoMetaUri() {
    final hostInput = _hostCtrl.text.trim();
    if (hostInput.isEmpty) return null;

    final withScheme =
        hostInput.contains('://') ? hostInput : '$_scheme://$hostInput';
    final parsed = Uri.tryParse(withScheme);
    if (parsed == null || !parsed.hasScheme || parsed.host.isEmpty) return null;
    if (parsed.scheme != 'http' && parsed.scheme != 'https') return null;

    var uri = parsed;
    final portText = _portCtrl.text.trim();
    if (portText.isNotEmpty) {
      final port = int.tryParse(portText);
      if (port != null && port > 0 && port <= 65535) {
        uri = uri.replace(port: port);
      }
    }
    if (uri.path.isEmpty) {
      uri = uri.replace(path: '/');
    }
    return uri.replace(query: '', fragment: '');
  }

  void _scheduleAutoMetaFetch({bool force = false}) {
    if (!mounted) return;
    if (widget.appState.isLoading) return;

    _autoMetaDebounce?.cancel();
    final uri = _buildAutoMetaUri();
    if (uri == null) {
      if (_autoMetaLoading || _autoMetaError != null) {
        setState(() {
          _autoMetaLoading = false;
          _autoMetaError = null;
        });
      }
      return;
    }

    final urlKey = uri.toString();
    if (!force && urlKey == _autoMetaLastUrl) return;

    _autoMetaDebounce = Timer(
      const Duration(milliseconds: 650),
      () => _fetchAutoMeta(uri, urlKey: urlKey),
    );
  }

  Future<void> _fetchAutoMeta(
    Uri uri, {
    required String urlKey,
    bool overrideIcon = false,
  }) async {
    final reqId = ++_autoMetaReqId;
    setState(() {
      _autoMetaLoading = true;
      _autoMetaError = null;
      _autoMetaLastUrl = urlKey;
    });

    try {
      final meta = await WebsiteMetadataService.instance.fetch(uri);
      if (!mounted || reqId != _autoMetaReqId) return;

      final displayName = (meta.displayName ?? '').trim();
      if (!_nameTouched && displayName.isNotEmpty) {
        _nameCtrl.value = _nameCtrl.value.copyWith(
          text: displayName,
          selection: TextSelection.collapsed(offset: displayName.length),
        );
      }

      final favicon = (meta.faviconUrl ?? '').trim();
      if ((overrideIcon || !_iconTouched) && favicon.isNotEmpty) {
        setState(() {
          _iconTouched = overrideIcon ? false : _iconTouched;
          _iconUrl = favicon;
        });
      }

      setState(() => _autoMetaLoading = false);
    } catch (e) {
      if (!mounted || reqId != _autoMetaReqId) return;
      setState(() {
        _autoMetaLoading = false;
        _autoMetaError = e.toString();
      });
    }
  }

  Future<void> _forceFetchWebsiteMeta() async {
    final uri = _buildAutoMetaUri();
    if (uri == null) return;
    _autoMetaDebounce?.cancel();
    await _fetchAutoMeta(
      uri,
      urlKey: uri.toString(),
      overrideIcon: true,
    );
  }

  Future<void> _pickIconFromLibrary() async {
    final pickedUrl = await showModalBottomSheet<String?>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (ctx) => ServerIconLibrarySheet(
        urlsListenable: widget.appState,
        getLibraryUrls: () => widget.appState.serverIconLibraryUrls,
        addLibraryUrl: widget.appState.addServerIconLibraryUrl,
        removeLibraryUrlAt: widget.appState.removeServerIconLibraryUrlAt,
        reorderLibraryUrls: widget.appState.reorderServerIconLibraryUrls,
        selectedUrl: _iconUrl,
      ),
    );
    if (!mounted || pickedUrl == null) return;
    setState(() {
      _iconTouched = true;
      _iconUrl = pickedUrl.trim().isEmpty ? null : pickedUrl.trim();
    });
  }

  void _clearIcon() {
    setState(() {
      _iconTouched = true;
      _iconUrl = null;
    });
  }

  void _applyDefaultPort() {
    _portCtrl.text = _serverType == MediaServerType.plex
        ? '32400'
        : _defaultPortForScheme(_scheme);
    setState(() {});
  }

  void _setServerType(MediaServerType type) {
    if (_serverType == type) return;
    setState(() {
      _serverType = type;
      if (type == MediaServerType.plex && _portCtrl.text.trim().isEmpty) {
        _portCtrl.text = '32400';
      }
      _plexMode = _PlexAddMode.account;
      _plexError = null;
      _plexPin = null;
      _plexAccountToken = null;
      _plexServers = const [];
      _selectedPlexServer = null;
    });
  }

  PlexApi _buildPlexApi() {
    return PlexApi(
      clientIdentifier: widget.appState.deviceId,
      product: AppConfigScope.of(context).displayName,
      device: 'Flutter',
      platform: 'Flutter',
      version: '1.0.0',
    );
  }

  Future<void> _startPlexLogin({required bool fillTokenOnly}) async {
    if (_plexLoading) return;
    setState(() {
      _plexLoading = true;
      _plexError = null;
      if (!fillTokenOnly) {
        _plexServers = const [];
        _selectedPlexServer = null;
      }
    });

    try {
      final api = _buildPlexApi();
      final pin = await api.createPin();
      if (!mounted) return;
      setState(() {
        _plexPin = pin;
        _plexAccountToken = null;
      });

      final authUrl = api.buildAuthUrl(code: pin.code);
      final launched = await launchUrl(
        Uri.parse(authUrl),
        mode: LaunchMode.externalApplication,
      );
      if (!launched) {
        throw Exception('无法打开浏览器进行 Plex 授权');
      }

      final deadline = (pin.expiresAt ??
              DateTime.now().toUtc().add(const Duration(minutes: 10)))
          .toLocal();
      PlexPin latest = pin;
      while (mounted && DateTime.now().isBefore(deadline)) {
        await Future<void>.delayed(const Duration(seconds: 2));
        latest = await api.fetchPin(pin.id);
        final t = (latest.authToken ?? '').trim();
        if (t.isNotEmpty) break;
      }

      final authToken = (latest.authToken ?? '').trim();
      if (authToken.isEmpty) {
        throw Exception('等待 Plex 授权超时/未完成授权');
      }

      if (!mounted) return;

      if (fillTokenOnly) {
        _plexTokenCtrl.text = authToken;
        setState(() {
          _plexAccountToken = authToken;
          _plexLoading = false;
        });
        return;
      }

      final resources = await api.fetchResources(authToken: authToken);
      final servers = resources.where((r) => r.isServer).toList(growable: false)
        ..sort((a, b) => a.name.compareTo(b.name));

      if (!mounted) return;
      setState(() {
        _plexAccountToken = authToken;
        _plexServers = servers;
        _selectedPlexServer = servers.isEmpty ? null : servers.first;
        _plexLoading = false;
      });

      final picked = servers.isEmpty ? null : servers.first;
      if (picked != null &&
          !_nameTouched &&
          _nameCtrl.text.trim().isEmpty &&
          picked.name.trim().isNotEmpty) {
        _nameCtrl.text = picked.name.trim();
        _nameCtrl.selection =
            TextSelection.collapsed(offset: _nameCtrl.text.length);
      }
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _plexLoading = false;
        _plexError = e.toString();
      });
    }
  }

  Future<void> _submit() async {
    if (!_formKey.currentState!.validate()) return;
    FocusScope.of(context).unfocus();

    if (_serverType == MediaServerType.plex) {
      if (_plexMode == _PlexAddMode.account) {
        final selected = _selectedPlexServer;
        final serverUri = selected?.pickBestConnectionUri();
        final token = (selected?.accessToken ?? _plexAccountToken ?? '').trim();
        if (selected == null || (serverUri ?? '').trim().isEmpty) {
          setState(() => _plexError = '请选择 Plex 服务器');
          return;
        }
        if (token.isEmpty) {
          setState(() => _plexError = '未获取到 Plex Token（请重新登录）');
          return;
        }
        await widget.appState.addPlexServer(
          baseUrl: serverUri!.trim(),
          token: token,
          displayName:
              _nameCtrl.text.trim().isEmpty ? null : _nameCtrl.text.trim(),
          remark:
              _remarkCtrl.text.trim().isEmpty ? null : _remarkCtrl.text.trim(),
          iconUrl: _iconUrl,
          plexMachineIdentifier: selected.clientIdentifier,
        );
      } else {
        final uri = _buildAutoMetaUri();
        if (uri == null) return;
        await widget.appState.addPlexServer(
          baseUrl: uri.toString(),
          token: _plexTokenCtrl.text.trim(),
          displayName:
              _nameCtrl.text.trim().isEmpty ? null : _nameCtrl.text.trim(),
          remark:
              _remarkCtrl.text.trim().isEmpty ? null : _remarkCtrl.text.trim(),
          iconUrl: _iconUrl,
        );
      }
    } else if (_serverType == MediaServerType.webdav) {
      final uri = _buildAutoMetaUri();
      if (uri == null) return;
      await widget.appState.addWebDavServer(
        baseUrl: uri.toString(),
        username: _userCtrl.text.trim(),
        password: _pwdCtrl.text,
        displayName:
            _nameCtrl.text.trim().isEmpty ? null : _nameCtrl.text.trim(),
        remark:
            _remarkCtrl.text.trim().isEmpty ? null : _remarkCtrl.text.trim(),
        iconUrl: _iconUrl,
      );
    } else {
      // Emby/Jellyfin
      final hostInput = _hostCtrl.text.trim();
      await widget.appState.addServer(
        hostOrUrl: hostInput,
        scheme: _scheme,
        port: _portCtrl.text.trim().isEmpty ? null : _portCtrl.text.trim(),
        serverType: _serverType,
        username: _userCtrl.text.trim(),
        password: _pwdCtrl.text,
        displayName:
            _nameCtrl.text.trim().isEmpty ? null : _nameCtrl.text.trim(),
        remark:
            _remarkCtrl.text.trim().isEmpty ? null : _remarkCtrl.text.trim(),
        iconUrl: _iconUrl,
      );
    }
    if (!mounted) return;
    if (widget.appState.error != null) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(widget.appState.error!)),
      );
      return;
    }
    Navigator.of(context).pop();
  }

  @override
  Widget build(BuildContext context) {
    final viewInsets = MediaQuery.of(context).viewInsets;
    final config = AppConfigScope.of(context);
    final serverTypes = MediaServerType.values
        .where(config.features.allowedServerTypes.contains)
        .toList(growable: false);
    final loading = widget.appState.isLoading;
    final showHostFields = _serverType.isEmbyLike ||
        _serverType == MediaServerType.webdav ||
        (_serverType == MediaServerType.plex &&
            _plexMode == _PlexAddMode.manual);
    final showUserPass =
        _serverType.isEmbyLike || _serverType == MediaServerType.webdav;
    final showPlexToken =
        _serverType == MediaServerType.plex && _plexMode == _PlexAddMode.manual;

    return Padding(
      padding:
          EdgeInsets.only(left: 16, right: 16, bottom: viewInsets.bottom + 16),
      child: Form(
        key: _formKey,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Flexible(
              child: SingleChildScrollView(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Row(
                      children: [
                        Expanded(
                          child: Text(
                            '添加服务器',
                            style: Theme.of(context).textTheme.titleLarge,
                          ),
                        ),
                        if (widget.onOpenBulkImport != null &&
                            _serverType.isEmbyLike)
                          TextButton.icon(
                            onPressed: loading
                                ? null
                                : () => unawaited(
                                    widget.onOpenBulkImport!(context)),
                            icon: const Icon(Icons.playlist_add_outlined),
                            label: const Text('批量导入'),
                          ),
                      ],
                    ),
                    const SizedBox(height: 12),
                    SegmentedButton<MediaServerType>(
                      segments: serverTypes
                          .map(
                            (t) => ButtonSegment<MediaServerType>(
                              value: t,
                              label: Text(t.label),
                            ),
                          )
                          .toList(growable: false),
                      selected: <MediaServerType>{_serverType},
                      onSelectionChanged:
                          loading ? null : (s) => _setServerType(s.first),
                    ),
                    if (_serverType == MediaServerType.plex) ...[
                      const SizedBox(height: 12),
                      SegmentedButton<_PlexAddMode>(
                        segments: _PlexAddMode.values
                            .map(
                              (m) => ButtonSegment<_PlexAddMode>(
                                value: m,
                                label: Text(m.label),
                              ),
                            )
                            .toList(growable: false),
                        selected: <_PlexAddMode>{_plexMode},
                        onSelectionChanged: loading
                            ? null
                            : (s) => setState(() {
                                  _plexMode = s.first;
                                  _plexError = null;
                                }),
                      ),
                      if (_plexMode == _PlexAddMode.account) ...[
                        const SizedBox(height: 10),
                        FilledButton.icon(
                          onPressed: (_plexLoading || loading)
                              ? null
                              : () => _startPlexLogin(fillTokenOnly: false),
                          icon: _plexLoading
                              ? const SizedBox(
                                  height: 18,
                                  width: 18,
                                  child:
                                      CircularProgressIndicator(strokeWidth: 2),
                                )
                              : const Icon(Icons.login),
                          label: Text(
                            _plexAccountToken == null
                                ? '登录 Plex 获取服务器列表'
                                : '重新登录 Plex',
                          ),
                        ),
                        if ((_plexPin?.code ?? '').trim().isNotEmpty) ...[
                          const SizedBox(height: 6),
                          Text(
                            '授权码：${_plexPin!.code}（在浏览器完成授权后返回）',
                            style:
                                Theme.of(context).textTheme.bodySmall?.copyWith(
                                      color: Theme.of(context)
                                          .colorScheme
                                          .onSurfaceVariant,
                                    ),
                          ),
                        ],
                        if ((_plexError ?? '').trim().isNotEmpty) ...[
                          const SizedBox(height: 6),
                          Text(
                            _plexError!.trim(),
                            style: Theme.of(context)
                                .textTheme
                                .bodySmall
                                ?.copyWith(
                                  color: Theme.of(context).colorScheme.error,
                                ),
                          ),
                        ],
                        if (_plexAccountToken != null &&
                            _plexServers.isNotEmpty) ...[
                          const SizedBox(height: 10),
                          DropdownButtonFormField<PlexResource>(
                            initialValue: _selectedPlexServer,
                            items: _plexServers
                                .map(
                                  (r) => DropdownMenuItem<PlexResource>(
                                    value: r,
                                    child: Text(
                                      r.name.isEmpty
                                          ? r.clientIdentifier
                                          : r.name,
                                    ),
                                  ),
                                )
                                .toList(growable: false),
                            onChanged: loading
                                ? null
                                : (v) => setState(() {
                                      _selectedPlexServer = v;
                                      _plexError = null;
                                      if (v != null &&
                                          !_nameTouched &&
                                          _nameCtrl.text.trim().isEmpty &&
                                          v.name.trim().isNotEmpty) {
                                        _nameCtrl.text = v.name.trim();
                                        _nameCtrl.selection =
                                            TextSelection.collapsed(
                                          offset: _nameCtrl.text.length,
                                        );
                                      }
                                    }),
                            decoration: const InputDecoration(
                              labelText: '选择 Plex 服务器',
                            ),
                            validator: (_) =>
                                (_selectedPlexServer == null) ? '请选择服务器' : null,
                          ),
                          const SizedBox(height: 4),
                          Builder(
                            builder: (context) {
                              final uri =
                                  _selectedPlexServer?.pickBestConnectionUri();
                              if ((uri ?? '').trim().isEmpty) {
                                return const SizedBox.shrink();
                              }
                              return Text(
                                '连接：$uri',
                                style: Theme.of(context)
                                    .textTheme
                                    .bodySmall
                                    ?.copyWith(
                                      color: Theme.of(context)
                                          .colorScheme
                                          .onSurfaceVariant,
                                    ),
                              );
                            },
                          ),
                        ],
                      ],
                    ],
                    const SizedBox(height: 12),
                    TextFormField(
                      controller: _nameCtrl,
                      onChanged: (_) => _nameTouched = true,
                      decoration: const InputDecoration(labelText: '服务器名称（可选）'),
                    ),
                    const SizedBox(height: 10),
                    TextFormField(
                      controller: _remarkCtrl,
                      decoration: const InputDecoration(labelText: '备注（可选）'),
                    ),
                    if (showHostFields) ...[
                      const SizedBox(height: 10),
                      Row(
                        children: [
                          ServerIconAvatar(
                            iconUrl: _iconUrl,
                            name: _nameCtrl.text,
                            radius: 16,
                          ),
                          const SizedBox(width: 12),
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                const Text('服务器图标（可选）'),
                                const SizedBox(height: 2),
                                Text(
                                  _iconTouched
                                      ? '已自定义'
                                      : (_iconUrl == null ||
                                              _iconUrl!.trim().isEmpty)
                                          ? '未设置'
                                          : '已自动获取',
                                  style: Theme.of(context)
                                      .textTheme
                                      .bodySmall
                                      ?.copyWith(
                                        color: Theme.of(context)
                                            .colorScheme
                                            .onSurfaceVariant,
                                      ),
                                ),
                              ],
                            ),
                          ),
                          IconButton(
                            tooltip: '自动获取网站信息',
                            onPressed: loading ? null : _forceFetchWebsiteMeta,
                            icon: const Icon(Icons.travel_explore_outlined),
                          ),
                          IconButton(
                            tooltip: '从图标库选择',
                            onPressed: loading ? null : _pickIconFromLibrary,
                            icon: const Icon(Icons.collections_outlined),
                          ),
                          IconButton(
                            tooltip: '清除图标',
                            onPressed: loading ? null : _clearIcon,
                            icon: const Icon(Icons.close),
                          ),
                        ],
                      ),
                      if (showPlexToken) ...[
                        const SizedBox(height: 10),
                        FilledButton.icon(
                          onPressed: (_plexLoading || loading)
                              ? null
                              : () => _startPlexLogin(fillTokenOnly: true),
                          icon: _plexLoading
                              ? const SizedBox(
                                  height: 18,
                                  width: 18,
                                  child:
                                      CircularProgressIndicator(strokeWidth: 2),
                                )
                              : const Icon(Icons.login),
                          label: Text(
                            _plexAccountToken == null
                                ? '登录 Plex 获取 Token'
                                : '重新登录 Plex（刷新 Token）',
                          ),
                        ),
                        const SizedBox(height: 10),
                        TextFormField(
                          controller: _plexTokenCtrl,
                          decoration: InputDecoration(
                            labelText: 'Plex Token',
                            suffixIcon: IconButton(
                              tooltip:
                                  _plexTokenVisible ? '隐藏 Token' : '显示 Token',
                              icon: Icon(
                                _plexTokenVisible
                                    ? Icons.visibility_off
                                    : Icons.visibility,
                              ),
                              onPressed: () => setState(
                                () => _plexTokenVisible = !_plexTokenVisible,
                              ),
                            ),
                          ),
                          obscureText: !_plexTokenVisible,
                          validator: (v) {
                            if (!showPlexToken) return null;
                            return (v == null || v.trim().isEmpty)
                                ? '请输入 Plex Token'
                                : null;
                          },
                        ),
                      ],
                      if (_autoMetaLoading) ...[
                        const SizedBox(height: 8),
                        const Row(
                          children: [
                            SizedBox(
                              height: 16,
                              width: 16,
                              child: CircularProgressIndicator(strokeWidth: 2),
                            ),
                            SizedBox(width: 10),
                            Expanded(child: Text('正在自动获取网站名称和 favicon…')),
                          ],
                        ),
                      ] else if ((_autoMetaError ?? '').trim().isNotEmpty) ...[
                        const SizedBox(height: 6),
                        Text(
                          '自动获取失败，可手动设置名称/图标。',
                          style:
                              Theme.of(context).textTheme.bodySmall?.copyWith(
                                    color: Theme.of(context)
                                        .colorScheme
                                        .onSurfaceVariant,
                                  ),
                        ),
                      ],
                      const SizedBox(height: 10),
                      Row(
                        children: [
                          Expanded(
                            flex: 2,
                            child: DropdownButtonFormField<String>(
                              initialValue: _scheme,
                              decoration:
                                  const InputDecoration(labelText: '协议'),
                              items: const [
                                DropdownMenuItem(
                                    value: 'https', child: Text('https')),
                                DropdownMenuItem(
                                    value: 'http', child: Text('http')),
                              ],
                              onChanged: loading
                                  ? null
                                  : (v) {
                                      if (v == null) return;
                                      setState(() {
                                        _scheme = v;
                                        if (_portCtrl.text.isEmpty ||
                                            _portCtrl.text == '80' ||
                                            _portCtrl.text == '443') {
                                          _portCtrl.text =
                                              _defaultPortForScheme(v);
                                        }
                                      });
                                      _scheduleAutoMetaFetch(force: true);
                                    },
                            ),
                          ),
                          const SizedBox(width: 10),
                          Expanded(
                            flex: 5,
                            child: TextFormField(
                              controller: _hostCtrl,
                              decoration: const InputDecoration(
                                labelText: '服务器地址',
                                hintText: '例如：emby.example.com 或 1.2.3.4',
                              ),
                              keyboardType: TextInputType.url,
                              validator: (v) => (v == null || v.trim().isEmpty)
                                  ? '请输入服务器地址'
                                  : null,
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 10),
                      TextFormField(
                        controller: _portCtrl,
                        decoration: InputDecoration(
                          labelText:
                              '端口（留空默认 ${_scheme == 'http' ? '80' : '443'}）',
                          suffixIcon: IconButton(
                            tooltip: '使用默认端口',
                            icon: const Icon(Icons.refresh),
                            onPressed: loading ? null : _applyDefaultPort,
                          ),
                        ),
                        keyboardType: TextInputType.number,
                        validator: (v) {
                          if (v == null || v.trim().isEmpty) return null;
                          final n = int.tryParse(v.trim());
                          if (n == null || n <= 0 || n > 65535) return '端口不合法';
                          return null;
                        },
                      ),
                      if (showUserPass) ...[
                        const SizedBox(height: 10),
                        TextFormField(
                          controller: _userCtrl,
                          decoration: const InputDecoration(labelText: '账号'),
                          validator: (v) {
                            if (_serverType.isEmbyLike &&
                                (v == null || v.trim().isEmpty)) {
                              return '请输入账号';
                            }
                            return null;
                          },
                        ),
                        const SizedBox(height: 10),
                        TextFormField(
                          controller: _pwdCtrl,
                          decoration: InputDecoration(
                            labelText: '密码（可选）',
                            suffixIcon: IconButton(
                              tooltip: _pwdVisible ? '隐藏密码' : '显示密码',
                              icon: Icon(
                                _pwdVisible
                                    ? Icons.visibility_off
                                    : Icons.visibility,
                              ),
                              onPressed: () =>
                                  setState(() => _pwdVisible = !_pwdVisible),
                            ),
                          ),
                          obscureText: !_pwdVisible,
                        ),
                      ],
                    ],
                  ],
                ),
              ),
            ),
            const SizedBox(height: 14),
            SizedBox(
              width: double.infinity,
              height: 44,
              child: FilledButton(
                onPressed: loading ? null : _submit,
                child: loading
                    ? const SizedBox(
                        height: 18,
                        width: 18,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Text('连接并保存'),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _EditServerSheet extends StatefulWidget {
  const _EditServerSheet({required this.appState, required this.server});

  final AppState appState;
  final ServerProfile server;

  @override
  State<_EditServerSheet> createState() => _EditServerSheetState();
}

class _EditServerSheetState extends State<_EditServerSheet> {
  late final TextEditingController _nameCtrl =
      TextEditingController(text: widget.server.name);
  late final TextEditingController _remarkCtrl =
      TextEditingController(text: widget.server.remark);

  String? _iconUrl;
  bool _iconLoading = false;

  @override
  void initState() {
    super.initState();
    _iconUrl = widget.server.iconUrl;
  }

  @override
  void dispose() {
    _nameCtrl.dispose();
    _remarkCtrl.dispose();
    super.dispose();
  }

  Future<void> _pickIconFromLibrary() async {
    final pickedUrl = await showModalBottomSheet<String?>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (ctx) => ServerIconLibrarySheet(
        urlsListenable: widget.appState,
        getLibraryUrls: () => widget.appState.serverIconLibraryUrls,
        addLibraryUrl: widget.appState.addServerIconLibraryUrl,
        removeLibraryUrlAt: widget.appState.removeServerIconLibraryUrlAt,
        reorderLibraryUrls: widget.appState.reorderServerIconLibraryUrls,
        selectedUrl: _iconUrl,
      ),
    );
    if (!mounted || pickedUrl == null) return;
    setState(() {
      _iconUrl = pickedUrl.trim().isEmpty ? null : pickedUrl.trim();
    });
  }

  Future<void> _autoFetchIcon() async {
    final uri = Uri.tryParse(widget.server.baseUrl);
    if (uri == null) return;

    setState(() => _iconLoading = true);
    try {
      final meta = await WebsiteMetadataService.instance.fetch(uri);
      if (!mounted) return;
      final favicon = (meta.faviconUrl ?? '').trim();
      if (favicon.isNotEmpty) {
        setState(() => _iconUrl = favicon);
      }
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('自动获取失败：$e')),
      );
    } finally {
      if (mounted) setState(() => _iconLoading = false);
    }
  }

  void _clearIcon() {
    setState(() => _iconUrl = null);
  }

  Future<void> _save() async {
    final iconArg = _iconUrl == widget.server.iconUrl ? null : (_iconUrl ?? '');
    await widget.appState.updateServerMeta(
      widget.server.id,
      name: _nameCtrl.text,
      remark: _remarkCtrl.text,
      iconUrl: iconArg,
    );
    if (!mounted) return;
    Navigator.of(context).pop();
  }

  Future<void> _confirmDelete() async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('删除服务器？'),
        content: Text('将删除“${widget.server.name}”。'),
        actions: [
          TextButton(
              onPressed: () => Navigator.of(ctx).pop(false),
              child: const Text('取消')),
          FilledButton(
              onPressed: () => Navigator.of(ctx).pop(true),
              child: const Text('删除')),
        ],
      ),
    );
    if (ok != true) return;
    await widget.appState.removeServer(widget.server.id);
    if (!mounted) return;
    Navigator.of(context).pop();
  }

  @override
  Widget build(BuildContext context) {
    final viewInsets = MediaQuery.of(context).viewInsets;
    return Padding(
      padding:
          EdgeInsets.only(left: 16, right: 16, bottom: viewInsets.bottom + 16),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text('编辑服务器', style: Theme.of(context).textTheme.titleLarge),
          const SizedBox(height: 12),
          TextField(
            controller: _nameCtrl,
            decoration: const InputDecoration(labelText: '服务器名称'),
          ),
          const SizedBox(height: 10),
          TextField(
            controller: _remarkCtrl,
            decoration: const InputDecoration(labelText: '备注（可选，小字显示）'),
          ),
          const SizedBox(height: 10),
          Row(
            children: [
              ServerIconAvatar(
                iconUrl: _iconUrl,
                name: _nameCtrl.text,
                radius: 16,
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const Text('服务器图标'),
                    const SizedBox(height: 2),
                    Text(
                      (_iconUrl == null || _iconUrl!.trim().isEmpty)
                          ? '未设置'
                          : '已设置',
                      style: Theme.of(context).textTheme.bodySmall?.copyWith(
                            color:
                                Theme.of(context).colorScheme.onSurfaceVariant,
                          ),
                    ),
                  ],
                ),
              ),
              IconButton(
                tooltip: '自动获取 favicon',
                onPressed: _iconLoading ? null : _autoFetchIcon,
                icon: _iconLoading
                    ? const SizedBox(
                        height: 18,
                        width: 18,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Icon(Icons.travel_explore_outlined),
              ),
              IconButton(
                tooltip: '从图标库选择',
                onPressed: _pickIconFromLibrary,
                icon: const Icon(Icons.collections_outlined),
              ),
              IconButton(
                tooltip: '清除图标',
                onPressed: _clearIcon,
                icon: const Icon(Icons.close),
              ),
            ],
          ),
          const SizedBox(height: 14),
          Row(
            children: [
              Expanded(
                child: OutlinedButton(
                  onPressed: _confirmDelete,
                  child: const Text('删除'),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: FilledButton(
                  onPressed: _save,
                  child: const Text('保存'),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}
