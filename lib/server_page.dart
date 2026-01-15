import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart';

import 'state/app_state.dart';
import 'state/preferences.dart';
import 'state/server_profile.dart';
import 'src/ui/theme_sheet.dart';

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
        final isTv = _isTv(context);
        final listLayout = widget.appState.serverListLayout;
        final isList = listLayout == ServerListLayout.list;
        final maxCrossAxisExtent = isTv ? 160.0 : 180.0;

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
    final initial = server.name.trim().isNotEmpty
        ? server.name.trim()[0].toUpperCase()
        : '?';
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
                    CircleAvatar(
                      radius: 12,
                      backgroundColor:
                          colorScheme.primary.withValues(alpha: 0.14),
                      child: Text(
                        initial,
                        style: const TextStyle(fontWeight: FontWeight.w700),
                      ),
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
    final initial = server.name.trim().isNotEmpty
        ? server.name.trim()[0].toUpperCase()
        : '?';
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
            CircleAvatar(
              radius: 14,
              backgroundColor: scheme.primary.withValues(alpha: 0.14),
              child: Text(
                initial,
                style: const TextStyle(fontWeight: FontWeight.w700),
              ),
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

  @override
  void initState() {
    super.initState();
    _nameCtrl.addListener(() {
      _nameTouched = _nameCtrl.text.trim().isNotEmpty;
    });
    _hostCtrl.addListener(_maybeParseHostInput);
  }

  @override
  void dispose() {
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
            Text('添加服务器', style: Theme.of(context).textTheme.titleLarge),
            const SizedBox(height: 12),
            TextFormField(
              controller: _nameCtrl,
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
                Expanded(
                  flex: 2,
                  child: DropdownButtonFormField<String>(
                    initialValue: _scheme,
                    decoration: const InputDecoration(labelText: '协议'),
                    items: const [
                      DropdownMenuItem(value: 'https', child: Text('https')),
                      DropdownMenuItem(value: 'http', child: Text('http')),
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
                                _portCtrl.text = _defaultPortForScheme(v);
                              }
                            });
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
                    validator: (v) =>
                        (v == null || v.trim().isEmpty) ? '请输入服务器地址' : null,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 10),
            TextFormField(
              controller: _portCtrl,
              decoration: InputDecoration(
                labelText: '端口（留空默认 ${_scheme == 'http' ? '80' : '443'}）',
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
                labelText: '密码',
                suffixIcon: IconButton(
                  tooltip: _pwdVisible ? '隐藏密码' : '显示密码',
                  icon: Icon(
                      _pwdVisible ? Icons.visibility_off : Icons.visibility),
                  onPressed: () => setState(() => _pwdVisible = !_pwdVisible),
                ),
              ),
              obscureText: !_pwdVisible,
              validator: (v) => (v == null || v.isEmpty) ? '请输入密码' : null,
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

  @override
  void dispose() {
    _nameCtrl.dispose();
    _remarkCtrl.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    await widget.appState.updateServerMeta(
      widget.server.id,
      name: _nameCtrl.text,
      remark: _remarkCtrl.text,
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
