import 'dart:async';

import 'package:flutter/material.dart';

import '../app_config/app_config_scope.dart';
import '../services/emos_api.dart';
import '../state/app_state.dart';

class EmosRankEntry {
  const EmosRankEntry({
    required this.index,
    required this.value,
    required this.username,
    required this.avatar,
  });

  final int index;
  final int value;
  final String username;
  final String? avatar;

  factory EmosRankEntry.fromJson(Map<String, dynamic> json) {
    return EmosRankEntry(
      index: (json['index'] as num?)?.toInt() ?? 0,
      value: (json['carrot'] as num?)?.toInt() ??
          (json['size'] as num?)?.toInt() ??
          0,
      username: (json['username'] as String? ?? '').trim(),
      avatar: (json['avatar'] as String?)?.trim(),
    );
  }
}

class EmosRankPage extends StatefulWidget {
  const EmosRankPage({super.key, required this.appState});

  final AppState appState;

  @override
  State<EmosRankPage> createState() => _EmosRankPageState();
}

class _EmosRankPageState extends State<EmosRankPage> {
  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: widget.appState,
      builder: (context, _) {
        if (!widget.appState.hasEmosSession) {
          return const Scaffold(body: Center(child: Text('Not signed in')));
        }

        return DefaultTabController(
          length: 2,
          child: Scaffold(
            appBar: AppBar(
              title: const Text('Rank'),
              bottom: const TabBar(
                tabs: [
                  Tab(text: 'Carrot'),
                  Tab(text: 'Upload'),
                ],
              ),
            ),
            body: TabBarView(
              children: [
                _RankTab(appState: widget.appState, kind: _RankKind.carrot),
                _RankTab(appState: widget.appState, kind: _RankKind.upload),
              ],
            ),
          ),
        );
      },
    );
  }
}

enum _RankKind { carrot, upload }

class _RankTab extends StatefulWidget {
  const _RankTab({required this.appState, required this.kind});

  final AppState appState;
  final _RankKind kind;

  @override
  State<_RankTab> createState() => _RankTabState();
}

class _RankTabState extends State<_RankTab> {
  bool _loading = false;
  String? _error;
  List<EmosRankEntry> _items = const [];

  EmosApi _api() {
    final config = AppConfigScope.of(context);
    final token = widget.appState.emosSession?.token ?? '';
    return EmosApi(baseUrl: config.emosBaseUrl, token: token);
  }

  @override
  void initState() {
    super.initState();
    unawaited(_reload());
  }

  Future<void> _reload() async {
    if (_loading) return;
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final raw = switch (widget.kind) {
        _RankKind.carrot => await _api().fetchCarrotRank(),
        _RankKind.upload => await _api().fetchUploadRank(),
      };
      final list = (raw as List<dynamic>? ?? const [])
          .whereType<Map>()
          .map((e) => EmosRankEntry.fromJson(e.cast<String, dynamic>()))
          .toList();
      if (!mounted) return;
      setState(() => _items = list);
    } catch (e) {
      if (!mounted) return;
      setState(() => _error = e.toString());
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final label = widget.kind == _RankKind.carrot ? 'carrot' : 'size';
    return RefreshIndicator(
      onRefresh: _reload,
      child: ListView(
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
          if (!_loading && _error == null && _items.isEmpty)
            const Padding(
              padding: EdgeInsets.all(24),
              child: Center(child: Text('No data')),
            ),
          ..._items.map(
            (e) => Card(
              child: ListTile(
                leading: CircleAvatar(
                  child: e.avatar?.trim().isNotEmpty == true
                      ? ClipOval(
                          child: Image.network(
                            e.avatar!,
                            width: 40,
                            height: 40,
                            fit: BoxFit.cover,
                          ),
                        )
                      : Text(e.index > 0 ? '${e.index}' : '#'),
                ),
                title: Text(e.username.isEmpty ? '(unknown)' : e.username),
                subtitle: Text('$label: ${e.value}'),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

