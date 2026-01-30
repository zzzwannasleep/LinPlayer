import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../app_config/app_config_scope.dart';
import '../services/emos_api.dart';
import '../services/emos_sign_in_service.dart';
import '../state/app_state.dart';

class EmosUserInvitePage extends StatefulWidget {
  const EmosUserInvitePage({super.key, required this.appState});

  final AppState appState;

  @override
  State<EmosUserInvitePage> createState() => _EmosUserInvitePageState();
}

class _EmosUserInvitePageState extends State<EmosUserInvitePage> {
  @override
  Widget build(BuildContext context) {
    return DefaultTabController(
      length: 2,
      child: Scaffold(
        appBar: AppBar(
          title: const Text('User & Invite'),
          bottom: const TabBar(
            tabs: [
              Tab(text: 'User'),
              Tab(text: 'Invite'),
            ],
          ),
        ),
        body: TabBarView(
          children: [
            _UserTab(appState: widget.appState),
            _InviteTab(appState: widget.appState),
          ],
        ),
      ),
    );
  }
}

class _UserTab extends StatefulWidget {
  const _UserTab({required this.appState});

  final AppState appState;

  @override
  State<_UserTab> createState() => _UserTabState();
}

class _UserTabState extends State<_UserTab> {
  bool _loading = false;
  String? _error;
  EmosUser? _user;

  EmosApi _api() {
    final config = AppConfigScope.of(context);
    final token = widget.appState.emosSession?.token ?? '';
    return EmosApi(baseUrl: config.emosBaseUrl, token: token);
  }

  bool get _signedIn => widget.appState.hasEmosSession;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_signedIn && !_loading && _user == null && _error == null) {
      unawaited(_reload());
    }
  }

  Future<void> _reload() async {
    if (_loading) return;
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final user = await _api().fetchUser();
      if (!mounted) return;
      setState(() => _user = user);
    } catch (e) {
      if (!mounted) return;
      setState(() => _error = e.toString());
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _signIn() async {
    final config = AppConfigScope.of(context);
    await EmosSignInService.signInAndBootstrap(
      appState: widget.appState,
      baseUrl: config.emosBaseUrl,
      appName: config.displayName,
    );
    await _reload();
  }

  Future<void> _editPseudonym() async {
    final ctrl = TextEditingController();
    try {
      final name = await showDialog<String>(
        context: context,
        builder: (dctx) => AlertDialog(
          title: const Text('Update pseudonym'),
          content: TextField(
            controller: ctrl,
            decoration: const InputDecoration(labelText: 'Name'),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(dctx).pop(),
              child: const Text('Cancel'),
            ),
            FilledButton(
              onPressed: () => Navigator.of(dctx).pop(ctrl.text),
              child: const Text('Save'),
            ),
          ],
        ),
      );
      if ((name ?? '').trim().isEmpty) return;
      await _api().updatePseudonym(name!.trim());
      await _reload();
    } finally {
      ctrl.dispose();
    }
  }

  Future<void> _toggleShowEmpty() async {
    await _api().toggleShowEmptyLibraries();
    await _reload();
  }

  Future<void> _agreeUpload() async {
    await _api().agreeUploadAgreement();
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('Upload agreement accepted')),
    );
  }

  Future<void> _resetEmyaPassword() async {
    final ctrl = TextEditingController();
    try {
      final pwd = await showDialog<String>(
        context: context,
        barrierDismissible: false,
        builder: (dctx) => AlertDialog(
          title: const Text('Reset Emya password'),
          content: TextField(
            controller: ctrl,
            obscureText: true,
            decoration: const InputDecoration(labelText: 'New password'),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(dctx).pop(),
              child: const Text('Cancel'),
            ),
            FilledButton(
              onPressed: () => Navigator.of(dctx).pop(ctrl.text),
              child: const Text('Reset'),
            ),
          ],
        ),
      );
      if ((pwd ?? '').trim().isEmpty) return;
      await _api().resetEmyaPassword(pwd!.trim());
      await _reload();
    } finally {
      ctrl.dispose();
    }
  }

  Future<void> _showTempEmyaPassword() async {
    final res = await _api().fetchEmyaLoginPassword();
    if (!mounted) return;
    await showDialog<void>(
      context: context,
      builder: (dctx) => AlertDialog(
        title: const Text('Temporary password'),
        content: SelectableText(res.password),
        actions: [
          TextButton(
            onPressed: () async {
              await Clipboard.setData(ClipboardData(text: res.password));
              if (!dctx.mounted) return;
              Navigator.of(dctx).pop();
              if (!mounted) return;
              ScaffoldMessenger.of(context).showSnackBar(
                const SnackBar(content: Text('Copied')),
              );
            },
            child: const Text('Copy'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(dctx).pop(),
            child: const Text('OK'),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: widget.appState,
      builder: (context, _) {
        if (!_signedIn) {
          return Center(
            child: Padding(
              padding: const EdgeInsets.all(24),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const Text('Not signed in'),
                  const SizedBox(height: 12),
                  FilledButton(
                    onPressed: _loading ? null : _signIn,
                    child: const Text('Sign in'),
                  ),
                ],
              ),
            ),
          );
        }

        final user = _user;
        return ListView(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 24),
          children: [
            if (_loading) const LinearProgressIndicator(),
            if (_error != null)
              Padding(
                padding: const EdgeInsets.only(top: 8),
                child: Text(
                  _error!,
                  style: TextStyle(color: Theme.of(context).colorScheme.error),
                ),
              ),
            Card(
              child: Column(
                children: [
                  ListTile(
                    leading: CircleAvatar(
                      child: user?.avatar?.trim().isNotEmpty == true
                          ? ClipOval(
                              child: Image.network(
                                user!.avatar!,
                                width: 40,
                                height: 40,
                                fit: BoxFit.cover,
                              ),
                            )
                          : const Icon(Icons.person_outline),
                    ),
                    title: Text(user?.username ?? 'User'),
                    subtitle: Text('User ID: ${user?.userId ?? '-'}'),
                    trailing: IconButton(
                      tooltip: 'Refresh',
                      icon: const Icon(Icons.refresh),
                      onPressed: _loading ? null : _reload,
                    ),
                  ),
                  const Divider(height: 1),
                  ListTile(
                    leading: const Icon(Icons.link_outlined),
                    title: const Text('Emya URL'),
                    subtitle: Text(user?.emyaUrl ?? '-'),
                    onTap: (user?.emyaUrl ?? '').trim().isEmpty
                        ? null
                        : () async {
                            await Clipboard.setData(
                              ClipboardData(text: user!.emyaUrl),
                            );
                            if (!context.mounted) return;
                            ScaffoldMessenger.of(context).showSnackBar(
                              const SnackBar(content: Text('Copied')),
                            );
                          },
                  ),
                ],
              ),
            ),
            const SizedBox(height: 12),
            Card(
              child: Column(
                children: [
                  ListTile(
                    leading: const Icon(Icons.edit_outlined),
                    title: const Text('Update pseudonym'),
                    trailing: const Icon(Icons.chevron_right),
                    onTap: _loading ? null : _editPseudonym,
                  ),
                  const Divider(height: 1),
                  ListTile(
                    leading: const Icon(Icons.visibility_outlined),
                    title: const Text('Toggle show empty libraries'),
                    trailing: const Icon(Icons.chevron_right),
                    onTap: _loading ? null : _toggleShowEmpty,
                  ),
                  const Divider(height: 1),
                  ListTile(
                    leading: const Icon(Icons.verified_outlined),
                    title: const Text('Agree upload agreement'),
                    trailing: const Icon(Icons.chevron_right),
                    onTap: _loading ? null : _agreeUpload,
                  ),
                  const Divider(height: 1),
                  ListTile(
                    leading: const Icon(Icons.password_outlined),
                    title: const Text('Temporary Emya password'),
                    trailing: const Icon(Icons.chevron_right),
                    onTap: _loading ? null : _showTempEmyaPassword,
                  ),
                  const Divider(height: 1),
                  ListTile(
                    leading: const Icon(Icons.key_outlined),
                    title: const Text('Reset Emya password'),
                    trailing: const Icon(Icons.chevron_right),
                    onTap: _loading ? null : _resetEmyaPassword,
                  ),
                ],
              ),
            ),
          ],
        );
      },
    );
  }
}

class _InviteTab extends StatefulWidget {
  const _InviteTab({required this.appState});

  final AppState appState;

  @override
  State<_InviteTab> createState() => _InviteTabState();
}

class _InviteTabState extends State<_InviteTab> {
  bool _loading = false;
  dynamic _info;
  dynamic _history;
  String? _error;
  final _inviteUserIdCtrl = TextEditingController();

  EmosApi _api() {
    final config = AppConfigScope.of(context);
    final token = widget.appState.emosSession?.token ?? '';
    return EmosApi(baseUrl: config.emosBaseUrl, token: token);
  }

  bool get _signedIn => widget.appState.hasEmosSession;

  @override
  void dispose() {
    _inviteUserIdCtrl.dispose();
    super.dispose();
  }

  String _pretty(dynamic data) {
    try {
      return const JsonEncoder.withIndent('  ').convert(data);
    } catch (_) {
      return data.toString();
    }
  }

  Future<void> _showJson(String title, dynamic data) async {
    await showDialog<void>(
      context: context,
      builder: (dctx) => AlertDialog(
        title: Text(title),
        content: SizedBox(
          width: double.maxFinite,
          child: SingleChildScrollView(
            child: SelectableText(_pretty(data)),
          ),
        ),
        actions: [
          FilledButton(
            onPressed: () => Navigator.of(dctx).pop(),
            child: const Text('OK'),
          ),
        ],
      ),
    );
  }

  Future<void> _run(Future<void> Function() action) async {
    if (_loading) return;
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      await action();
    } catch (e) {
      if (!mounted) return;
      setState(() => _error = e.toString());
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _loadInfo() async {
    await _run(() async {
      _info = await _api().fetchInviteInfo();
    });
    if (!mounted || _info == null) return;
    await _showJson('Invite info', _info);
  }

  Future<void> _loadHistory() async {
    await _run(() async {
      _history = await _api().fetchInviteHistory();
    });
    if (!mounted || _history == null) return;
    await _showJson('Invite history', _history);
  }

  Future<void> _invite() async {
    final id = _inviteUserIdCtrl.text.trim();
    if (id.isEmpty) return;
    await _run(() async {
      final res = await _api().inviteUser(inviteUserId: id);
      if (!mounted) return;
      await _showJson('Invite result', res);
    });
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: widget.appState,
      builder: (context, _) {
        if (!_signedIn) {
          return const Center(child: Text('Not signed in'));
        }

        return ListView(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 24),
          children: [
            if (_loading) const LinearProgressIndicator(),
            if (_error != null)
              Padding(
                padding: const EdgeInsets.only(top: 8),
                child: Text(
                  _error!,
                  style: TextStyle(color: Theme.of(context).colorScheme.error),
                ),
              ),
            Card(
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Column(
                  children: [
                    TextField(
                      controller: _inviteUserIdCtrl,
                      decoration: const InputDecoration(
                        labelText: 'Invite user id',
                        prefixIcon: Icon(Icons.person_add_alt_outlined),
                      ),
                      onSubmitted: (_) => _invite(),
                    ),
                    const SizedBox(height: 12),
                    Row(
                      children: [
                        Expanded(
                          child: FilledButton.icon(
                            onPressed: _loading ? null : _invite,
                            icon: const Icon(Icons.send_outlined),
                            label: const Text('Invite'),
                          ),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 12),
            Card(
              child: Column(
                children: [
                  ListTile(
                    leading: const Icon(Icons.info_outline),
                    title: const Text('Invite info'),
                    trailing: const Icon(Icons.chevron_right),
                    onTap: _loading ? null : _loadInfo,
                  ),
                  const Divider(height: 1),
                  ListTile(
                    leading: const Icon(Icons.history_outlined),
                    title: const Text('Invite history'),
                    trailing: const Icon(Icons.chevron_right),
                    onTap: _loading ? null : _loadHistory,
                  ),
                ],
              ),
            ),
          ],
        );
      },
    );
  }
}
