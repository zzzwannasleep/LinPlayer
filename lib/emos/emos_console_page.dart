import 'dart:async';

import 'package:flutter/material.dart';

import '../app_config/app_config_scope.dart';
import '../app_config/app_product.dart';
import '../services/emos_sign_in_service.dart';
import '../state/app_state.dart';
import 'emos_carrot_page.dart';
import 'emos_proxy_lines_page.dart';
import 'emos_rank_page.dart';
import 'emos_upload_page.dart';
import 'emos_user_invite_page.dart';
import 'emos_video_manager_page.dart';
import 'emos_watchlists_page.dart';

class EmosConsolePage extends StatefulWidget {
  const EmosConsolePage({super.key, required this.appState});

  final AppState appState;

  @override
  State<EmosConsolePage> createState() => _EmosConsolePageState();
}

class _EmosConsolePageState extends State<EmosConsolePage> {
  bool _busy = false;

  Future<void> _signIn() async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      final config = AppConfigScope.of(context);
      await EmosSignInService.signInAndBootstrap(
        appState: widget.appState,
        baseUrl: config.emosBaseUrl,
        appName: config.displayName,
      );
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Emos sign-in failed: $e')),
      );
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _signOut() async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      await widget.appState.clearEmosSession();
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _openPlaceholder(String title) async {
    await Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => _EmosPlaceholderPage(title: title),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final config = AppConfigScope.of(context);
    final isEmos = config.product == AppProduct.emos;

    if (!isEmos) {
      return const Scaffold(
        body: Center(child: Text('Emos Console is only available in EmosPlayer')),
      );
    }

    return AnimatedBuilder(
      animation: widget.appState,
      builder: (context, _) {
        final session = widget.appState.emosSession;
        final signedIn =
            widget.appState.hasEmosSession && (session?.username.trim() ?? '').isNotEmpty;

        return Scaffold(
          appBar: AppBar(
            title: const Text('Emos Console'),
          ),
          body: ListView(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 24),
            children: [
              if (_busy) const LinearProgressIndicator(),
              Card(
                child: ListTile(
                  leading: const Icon(Icons.account_circle_outlined),
                  title: Text(signedIn ? session!.username : 'Not signed in'),
                  subtitle: Text('Base URL: ${config.emosBaseUrl}'),
                  trailing: FilledButton.tonal(
                    onPressed: _busy ? null : (signedIn ? _signOut : _signIn),
                    child: Text(signedIn ? 'Sign out' : 'Sign in'),
                  ),
                ),
              ),
              const SizedBox(height: 12),
              Card(
                child: Column(
                  children: [
                    ListTile(
                      leading: const Icon(Icons.person_outline),
                      title: const Text('User & Invite'),
                      trailing: const Icon(Icons.chevron_right),
                      onTap: _busy
                          ? null
                          : () {
                              Navigator.of(context).push(
                                MaterialPageRoute<void>(
                                  builder: (_) => EmosUserInvitePage(
                                    appState: widget.appState,
                                  ),
                                ),
                              );
                            },
                    ),
                    const Divider(height: 1),
                    ListTile(
                      leading: const Icon(Icons.alt_route_outlined),
                      title: const Text('Proxy Lines'),
                      trailing: const Icon(Icons.chevron_right),
                      onTap: _busy
                          ? null
                          : () {
                              Navigator.of(context).push(
                                MaterialPageRoute<void>(
                                  builder: (_) => EmosProxyLinesPage(
                                    appState: widget.appState,
                                  ),
                                ),
                              );
                            },
                    ),
                    const Divider(height: 1),
                    ListTile(
                      leading: const Icon(Icons.list_alt_outlined),
                      title: const Text('Watchlists'),
                      trailing: const Icon(Icons.chevron_right),
                      onTap: _busy
                          ? null
                          : () {
                              Navigator.of(context).push(
                                MaterialPageRoute<void>(
                                  builder: (_) => EmosWatchlistsPage(
                                    appState: widget.appState,
                                  ),
                                ),
                              );
                            },
                    ),
                    const Divider(height: 1),
                    ListTile(
                      leading: const Icon(Icons.video_library_outlined),
                      title: const Text('Video Manager'),
                      trailing: const Icon(Icons.chevron_right),
                      onTap: _busy
                          ? null
                          : () {
                              Navigator.of(context).push(
                                MaterialPageRoute<void>(
                                  builder: (_) => EmosVideoManagerPage(
                                    appState: widget.appState,
                                  ),
                                ),
                              );
                            },
                    ),
                    const Divider(height: 1),
                    ListTile(
                      leading: const Icon(Icons.cloud_upload_outlined),
                      title: const Text('Upload'),
                      trailing: const Icon(Icons.chevron_right),
                      onTap: _busy
                          ? null
                          : () {
                              Navigator.of(context).push(
                                MaterialPageRoute<void>(
                                  builder: (_) => EmosUploadPage(
                                    appState: widget.appState,
                                  ),
                                ),
                              );
                            },
                    ),
                    const Divider(height: 1),
                    ListTile(
                      leading: const Icon(Icons.leaderboard_outlined),
                      title: const Text('Rank'),
                      trailing: const Icon(Icons.chevron_right),
                      onTap: _busy
                          ? null
                          : () {
                              Navigator.of(context).push(
                                MaterialPageRoute<void>(
                                  builder: (_) => EmosRankPage(
                                    appState: widget.appState,
                                  ),
                                ),
                              );
                            },
                    ),
                    const Divider(height: 1),
                    ListTile(
                      leading: const Icon(Icons.local_florist_outlined),
                      title: const Text('Carrot'),
                      trailing: const Icon(Icons.chevron_right),
                      onTap: _busy
                          ? null
                          : () {
                              Navigator.of(context).push(
                                MaterialPageRoute<void>(
                                  builder: (_) => EmosCarrotPage(
                                    appState: widget.appState,
                                  ),
                                ),
                              );
                            },
                    ),
                    const Divider(height: 1),
                    ListTile(
                      leading: const Icon(Icons.help_outline),
                      title: const Text('Seek (optional)'),
                      subtitle: const Text('Pending decision'),
                      trailing: const Icon(Icons.chevron_right),
                      onTap: _busy ? null : () => _openPlaceholder('Seek'),
                    ),
                  ],
                ),
              ),
            ],
          ),
        );
      },
    );
  }
}

class _EmosPlaceholderPage extends StatelessWidget {
  const _EmosPlaceholderPage({required this.title});

  final String title;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text(title)),
      body: const Center(child: Text('TODO')),
    );
  }
}
