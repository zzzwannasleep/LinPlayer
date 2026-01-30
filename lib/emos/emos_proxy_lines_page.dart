import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../app_config/app_config_scope.dart';
import '../services/emos_api.dart';
import '../state/app_state.dart';

class EmosProxyLine {
  const EmosProxyLine({
    required this.id,
    required this.name,
    required this.url,
    required this.tagline,
    required this.isSelf,
    this.createdAt,
  });

  final int id;
  final String name;
  final String url;
  final String tagline;
  final bool isSelf;
  final DateTime? createdAt;

  factory EmosProxyLine.fromJson(Map<String, dynamic> json) {
    return EmosProxyLine(
      id: (json['id'] as num?)?.toInt() ?? 0,
      name: (json['name'] as String? ?? '').trim(),
      url: (json['url'] as String? ?? '').trim(),
      tagline: (json['tagline'] as String? ?? '').trim(),
      isSelf: json['is_self'] == true,
      createdAt: DateTime.tryParse((json['created_at'] as String? ?? '').trim()),
    );
  }
}

class EmosProxyLinesPage extends StatefulWidget {
  const EmosProxyLinesPage({super.key, required this.appState});

  final AppState appState;

  @override
  State<EmosProxyLinesPage> createState() => _EmosProxyLinesPageState();
}

class _EmosProxyLinesPageState extends State<EmosProxyLinesPage> {
  bool _loading = false;
  String? _error;
  List<EmosProxyLine> _lines = const [];
  bool _onlySelf = false;

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
      final raw = await _api().fetchProxyLines(onlySelf: _onlySelf);
      final list = (raw as List<dynamic>? ?? const [])
          .whereType<Map>()
          .map((e) => EmosProxyLine.fromJson(e.cast<String, dynamic>()))
          .toList();
      if (!mounted) return;
      setState(() => _lines = list);
    } catch (e) {
      if (!mounted) return;
      setState(() => _error = e.toString());
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _addLine() async {
    final nameCtrl = TextEditingController();
    final urlCtrl = TextEditingController();
    final tagCtrl = TextEditingController();
    try {
      final ok = await showDialog<bool>(
        context: context,
        barrierDismissible: false,
        builder: (dctx) => AlertDialog(
          title: const Text('Add proxy line'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextField(
                controller: nameCtrl,
                decoration: const InputDecoration(labelText: 'Name'),
              ),
              TextField(
                controller: urlCtrl,
                decoration: const InputDecoration(labelText: 'URL'),
              ),
              TextField(
                controller: tagCtrl,
                decoration: const InputDecoration(labelText: 'Tagline'),
              ),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(dctx).pop(false),
              child: const Text('Cancel'),
            ),
            FilledButton(
              onPressed: () => Navigator.of(dctx).pop(true),
              child: const Text('Add'),
            ),
          ],
        ),
      );
      if (ok != true) return;
      final name = nameCtrl.text.trim();
      final url = urlCtrl.text.trim();
      if (name.isEmpty || url.isEmpty) return;
      await _api().createProxyLine(
        name: name,
        url: url,
        tagline: tagCtrl.text.trim(),
      );
      await _reload();
    } finally {
      nameCtrl.dispose();
      urlCtrl.dispose();
      tagCtrl.dispose();
    }
  }

  Future<void> _deleteLine(EmosProxyLine line) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (dctx) => AlertDialog(
        title: const Text('Delete proxy line?'),
        content: Text('${line.name}\n${line.url}'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dctx).pop(false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(dctx).pop(true),
            child: const Text('Delete'),
          ),
        ],
      ),
    );
    if (ok != true) return;
    await _api().deleteProxyLine(id: line.id);
    await _reload();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: widget.appState,
      builder: (context, _) {
        if (!widget.appState.hasEmosSession) {
          return const Scaffold(
            body: Center(child: Text('Not signed in')),
          );
        }

        return Scaffold(
          appBar: AppBar(
            title: const Text('Proxy Lines'),
            actions: [
              IconButton(
                tooltip: 'Refresh',
                onPressed: _loading ? null : _reload,
                icon: const Icon(Icons.refresh),
              ),
              PopupMenuButton<bool>(
                tooltip: 'Filter',
                initialValue: _onlySelf,
                onSelected: (v) async {
                  if (v == _onlySelf) return;
                  setState(() => _onlySelf = v);
                  await _reload();
                },
                itemBuilder: (context) => const [
                  PopupMenuItem<bool>(
                    value: false,
                    child: Text('All'),
                  ),
                  PopupMenuItem<bool>(
                    value: true,
                    child: Text('Only mine'),
                  ),
                ],
              ),
            ],
          ),
          floatingActionButton: FloatingActionButton(
            onPressed: _loading ? null : _addLine,
            child: const Icon(Icons.add),
          ),
          body: ListView(
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
              if (_lines.isEmpty && !_loading && _error == null)
                const Padding(
                  padding: EdgeInsets.all(24),
                  child: Center(child: Text('No proxy lines')),
                ),
              ..._lines.map(
                (line) => Card(
                  child: ListTile(
                    leading: const Icon(Icons.alt_route_outlined),
                    title: Text(line.name.isEmpty ? '(no name)' : line.name),
                    subtitle: Text(
                      [
                        if (line.tagline.isNotEmpty) line.tagline,
                        line.url,
                      ].join('\n'),
                    ),
                    trailing: line.isSelf
                        ? IconButton(
                            tooltip: 'Delete',
                            icon: const Icon(Icons.delete_outline),
                            onPressed: _loading ? null : () => _deleteLine(line),
                          )
                        : null,
                    onTap: line.url.isEmpty
                        ? null
                        : () async {
                            await Clipboard.setData(
                              ClipboardData(text: line.url),
                            );
                            if (!context.mounted) return;
                            ScaffoldMessenger.of(context).showSnackBar(
                              const SnackBar(content: Text('Copied')),
                            );
                          },
                  ),
                ),
              ),
            ],
          ),
        );
      },
    );
  }
}

