import 'dart:async';

import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart';

import 'services/cover_cache_manager.dart';
import 'services/emby_api.dart';
import 'services/server_icon_library.dart';
import 'services/website_metadata.dart';
import 'state/app_state.dart';
import 'state/preferences.dart';
import 'state/server_profile.dart';
import 'src/ui/theme_sheet.dart';
import 'src/ui/ui_scale.dart';

class ServerPage extends StatefulWidget {
  const ServerPage({super.key, required this.appState});

  final AppState appState;

  @override
  State<ServerPage> createState() => _ServerPageState();
}

class _ServerPageState extends State<ServerPage> {
  bool _isTv(BuildContext context) =>
      defaultTargetPlatform == TargetPlatform.android &&
      MediaQuery.of(context).orientation == Orientation.landscape &&
      MediaQuery.of(context).size.shortestSide >= 720;

  Future<void> _showAddServerSheet() async {
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (ctx) => _AddServerSheet(appState: widget.appState),
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
                        IconButton(
                          tooltip: '主题',
                          onPressed: () =>
                              showThemeSheet(context, widget.appState),
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
                                    onTap: loading
                                        ? null
                                        : () async {
                                            await widget.appState
                                                .enterServer(server.id);
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
                                onTap: loading
                                    ? null
                                    : () async {
                                        await widget.appState
                                            .enterServer(server.id);
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
    required this.onTap,
    required this.onLongPress,
  });

  final ServerProfile server;
  final bool active;
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

    final borderColor = active
        ? colorScheme.primary.withValues(alpha: 0.55)
        : highlighted
            ? colorScheme.secondary.withValues(alpha: isDark ? 0.65 : 0.55)
            : colorScheme.outlineVariant;
    final borderWidth = (active || highlighted) ? 1.35 : 1.0;

    return InkWell(
      borderRadius: BorderRadius.circular(14),
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
                    _ServerIconAvatar(
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
                if ((server.remark ?? '').trim().isNotEmpty) ...[
                  const SizedBox(height: 3),
                  Text(
                    server.remark!.trim(),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: Theme.of(context)
                        .textTheme
                        .bodySmall
                        ?.copyWith(color: colorScheme.onSurfaceVariant),
                  ),
                ],
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
    required this.onTap,
    required this.onLongPress,
  });

  final ServerProfile server;
  final bool active;
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

    final borderColor = active
        ? scheme.primary.withValues(alpha: 0.55)
        : highlighted
            ? scheme.secondary.withValues(alpha: isDark ? 0.65 : 0.55)
            : scheme.outlineVariant;
    final borderWidth = (active || highlighted) ? 1.35 : 1.0;

    return InkWell(
      borderRadius: BorderRadius.circular(14),
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
            _ServerIconAvatar(
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
                  if ((server.remark ?? '').trim().isNotEmpty) ...[
                    const SizedBox(height: 2),
                    Text(
                      server.remark!.trim(),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: Theme.of(context)
                          .textTheme
                          .bodySmall
                          ?.copyWith(color: scheme.onSurfaceVariant),
                    ),
                  ],
                ],
              ),
            ),
            if (active) const Icon(Icons.check_circle, size: 18),
          ],
        ),
      ),
    );
  }
}

class _AddServerSheet extends StatefulWidget {
  const _AddServerSheet({required this.appState});

  final AppState appState;

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
  String _scheme = 'https';
  bool _pwdVisible = false;
  bool _handlingHostParse = false;
  bool _nameTouched = false;

  String? _iconUrl;
  bool _iconTouched = false;

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
      builder: (ctx) => _ServerIconLibrarySheet(selectedUrl: _iconUrl),
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
    _portCtrl.text = _defaultPortForScheme(_scheme);
    setState(() {});
  }

  Future<void> _submit() async {
    if (!_formKey.currentState!.validate()) return;
    FocusScope.of(context).unfocus();
    // Auto-complete scheme if user only typed host/path.
    final hostInput = _hostCtrl.text.trim();
    final hostOrUrl =
        hostInput.contains('://') ? hostInput : '$_scheme://$hostInput';
    await widget.appState.addServer(
      hostOrUrl: hostOrUrl,
      scheme: _scheme,
      port: _portCtrl.text.trim().isEmpty ? null : _portCtrl.text.trim(),
      username: _userCtrl.text.trim(),
      password: _pwdCtrl.text,
      displayName: _nameCtrl.text.trim().isEmpty ? null : _nameCtrl.text.trim(),
      remark: _remarkCtrl.text.trim().isEmpty ? null : _remarkCtrl.text.trim(),
      iconUrl: _iconUrl,
    );
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
    final loading = widget.appState.isLoading;

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
                    Text('添加服务器',
                        style: Theme.of(context).textTheme.titleLarge),
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
                    const SizedBox(height: 10),
                    Row(
                      children: [
                        _ServerIconAvatar(
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
                        style: Theme.of(context).textTheme.bodySmall?.copyWith(
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
                            decoration: const InputDecoration(labelText: '协议'),
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
                    const SizedBox(height: 10),
                    TextFormField(
                      controller: _userCtrl,
                      decoration: const InputDecoration(labelText: '账号'),
                      validator: (v) =>
                          (v == null || v.trim().isEmpty) ? '请输入账号' : null,
                    ),
                    const SizedBox(height: 10),
                    TextFormField(
                      controller: _pwdCtrl,
                      decoration: InputDecoration(
                        labelText: '密码（可选）',
                        suffixIcon: IconButton(
                          tooltip: _pwdVisible ? '隐藏密码' : '显示密码',
                          icon: Icon(_pwdVisible
                              ? Icons.visibility_off
                              : Icons.visibility),
                          onPressed: () =>
                              setState(() => _pwdVisible = !_pwdVisible),
                        ),
                      ),
                      obscureText: !_pwdVisible,
                    ),
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
      builder: (ctx) => _ServerIconLibrarySheet(selectedUrl: _iconUrl),
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
              _ServerIconAvatar(
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

class _ServerIconAvatar extends StatelessWidget {
  const _ServerIconAvatar({
    required this.iconUrl,
    required this.name,
    required this.radius,
  });

  final String? iconUrl;
  final String name;
  final double radius;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final initial = name.trim().isNotEmpty ? name.trim()[0].toUpperCase() : '?';
    final url = (iconUrl ?? '').trim();
    final backgroundColor = scheme.primary.withValues(alpha: 0.14);

    Widget fallback() => CircleAvatar(
          radius: radius,
          backgroundColor: backgroundColor,
          child: Text(
            initial,
            style: const TextStyle(fontWeight: FontWeight.w700),
          ),
        );

    if (url.isEmpty) return fallback();

    return CachedNetworkImage(
      imageUrl: url,
      cacheManager: CoverCacheManager.instance,
      httpHeaders: {'User-Agent': EmbyApi.userAgent},
      imageBuilder: (_, provider) => CircleAvatar(
        radius: radius,
        backgroundColor: backgroundColor,
        backgroundImage: provider,
      ),
      placeholder: (_, __) => fallback(),
      errorWidget: (_, __, ___) => fallback(),
    );
  }
}

class _ServerIconLibrarySheet extends StatefulWidget {
  const _ServerIconLibrarySheet({required this.selectedUrl});

  final String? selectedUrl;

  @override
  State<_ServerIconLibrarySheet> createState() =>
      _ServerIconLibrarySheetState();
}

class _ServerIconLibrarySheetState extends State<_ServerIconLibrarySheet> {
  final _queryCtrl = TextEditingController();

  @override
  void dispose() {
    _queryCtrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final viewInsets = MediaQuery.of(context).viewInsets;
    return Padding(
      padding:
          EdgeInsets.only(left: 16, right: 16, bottom: viewInsets.bottom + 16),
      child: FutureBuilder<ServerIconLibrary>(
        future: ServerIconLibrary.loadDefault(),
        builder: (context, snapshot) {
          final lib = snapshot.data;
          return Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                '选择图标',
                style: Theme.of(context).textTheme.titleLarge,
              ),
              const SizedBox(height: 12),
              TextField(
                controller: _queryCtrl,
                decoration: const InputDecoration(
                  labelText: '搜索',
                  prefixIcon: Icon(Icons.search),
                ),
                onChanged: (_) => setState(() {}),
              ),
              const SizedBox(height: 10),
              if (snapshot.connectionState == ConnectionState.waiting)
                const Padding(
                  padding: EdgeInsets.symmetric(vertical: 24),
                  child: CircularProgressIndicator(),
                )
              else if (snapshot.hasError)
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 24),
                  child: Text('加载图标库失败：${snapshot.error}'),
                )
              else if (lib == null || lib.icons.isEmpty)
                const Padding(
                  padding: EdgeInsets.symmetric(vertical: 24),
                  child: Text('图标库为空'),
                )
              else
                Expanded(
                  child: _IconList(
                    icons: lib.icons,
                    query: _queryCtrl.text,
                    selectedUrl: widget.selectedUrl,
                    onPick: (url) => Navigator.of(context).pop(url),
                  ),
                ),
            ],
          );
        },
      ),
    );
  }
}

class _IconList extends StatelessWidget {
  const _IconList({
    required this.icons,
    required this.query,
    required this.selectedUrl,
    required this.onPick,
  });

  final List<ServerIconEntry> icons;
  final String query;
  final String? selectedUrl;
  final ValueChanged<String> onPick;

  @override
  Widget build(BuildContext context) {
    final q = query.trim().toLowerCase();
    final filtered = q.isEmpty
        ? icons
        : icons
            .where((e) => e.name.toLowerCase().contains(q))
            .toList(growable: false);

    return ListView.separated(
      itemCount: filtered.length,
      separatorBuilder: (_, __) => const Divider(height: 1),
      itemBuilder: (context, index) {
        final icon = filtered[index];
        final selected = (selectedUrl ?? '').trim() == icon.url.trim();
        return ListTile(
          leading:
              _ServerIconAvatar(iconUrl: icon.url, name: icon.name, radius: 18),
          title: Text(icon.name),
          trailing: selected ? const Icon(Icons.check) : null,
          onTap: () => onPick(icon.url),
        );
      },
    );
  }
}
