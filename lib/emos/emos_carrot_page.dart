import 'dart:async';

import 'package:flutter/material.dart';

import '../app_config/app_config_scope.dart';
import '../services/emos_api.dart';
import '../state/app_state.dart';

class EmosCarrotHistoryItem {
  const EmosCarrotHistoryItem({
    required this.triggerType,
    required this.triggerTypeString,
    required this.type,
    required this.point,
    required this.expiredAt,
    required this.createdAt,
  });

  final String triggerType;
  final String triggerTypeString;
  final String type; // earn/cost
  final int point;
  final String? expiredAt;
  final String createdAt;

  factory EmosCarrotHistoryItem.fromJson(Map<String, dynamic> json) {
    return EmosCarrotHistoryItem(
      triggerType: (json['trigger_type'] as String? ?? '').trim(),
      triggerTypeString: (json['trigger_type_string'] as String? ?? '').trim(),
      type: (json['type'] as String? ?? '').trim(),
      point: (json['point'] as num?)?.toInt() ?? 0,
      expiredAt: (json['expired_at'] as String?)?.trim(),
      createdAt: (json['created_at'] as String? ?? '').trim(),
    );
  }
}

class EmosCarrotPage extends StatefulWidget {
  const EmosCarrotPage({super.key, required this.appState});

  final AppState appState;

  @override
  State<EmosCarrotPage> createState() => _EmosCarrotPageState();
}

class _EmosCarrotPageState extends State<EmosCarrotPage> {
  bool _loading = false;
  String? _error;
  List<EmosCarrotHistoryItem> _items = const [];
  String _filterType = '';

  final _transferUserIdCtrl = TextEditingController();
  final _transferAmountCtrl = TextEditingController();

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

  @override
  void dispose() {
    _transferUserIdCtrl.dispose();
    _transferAmountCtrl.dispose();
    super.dispose();
  }

  Future<void> _reload() async {
    if (_loading) return;
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final raw = await _api().fetchCarrotHistory(
        type: _filterType.trim().isEmpty ? null : _filterType.trim(),
      );
      final map = raw as Map<String, dynamic>;
      final list = (map['items'] as List<dynamic>? ?? const [])
          .whereType<Map>()
          .map((e) => EmosCarrotHistoryItem.fromJson(e.cast<String, dynamic>()))
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

  Future<void> _transfer() async {
    final userId = _transferUserIdCtrl.text.trim();
    final amount = int.tryParse(_transferAmountCtrl.text.trim()) ?? 0;
    if (userId.isEmpty || amount <= 0) return;
    if (_loading) return;

    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      await _api().transferCarrot(userId: userId, carrot: amount);
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Transferred')),
      );
      await _reload();
    } catch (e) {
      if (!mounted) return;
      setState(() => _error = e.toString());
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: widget.appState,
      builder: (context, _) {
        if (!widget.appState.hasEmosSession) {
          return const Scaffold(body: Center(child: Text('Not signed in')));
        }

        return Scaffold(
          appBar: AppBar(
            title: const Text('Carrot'),
            actions: [
              IconButton(
                tooltip: 'Refresh',
                onPressed: _loading ? null : _reload,
                icon: const Icon(Icons.refresh),
              ),
            ],
          ),
          body: RefreshIndicator(
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
                      style: TextStyle(
                        color: Theme.of(context).colorScheme.error,
                      ),
                    ),
                  ),
                Card(
                  child: Padding(
                    padding: const EdgeInsets.all(16),
                    child: Column(
                      children: [
                        DropdownMenu<String>(
                          initialSelection: _filterType,
                          label: const Text('Filter'),
                          dropdownMenuEntries: const [
                            DropdownMenuEntry(value: '', label: 'All'),
                            DropdownMenuEntry(value: 'earn', label: 'Earn'),
                            DropdownMenuEntry(value: 'cost', label: 'Cost'),
                          ],
                          onSelected: (v) async {
                            setState(() => _filterType = v ?? '');
                            await _reload();
                          },
                        ),
                        const SizedBox(height: 12),
                        TextField(
                          controller: _transferUserIdCtrl,
                          decoration: const InputDecoration(
                            labelText: 'Transfer to (user_id)',
                            prefixIcon: Icon(Icons.person_outline),
                          ),
                        ),
                        const SizedBox(height: 12),
                        TextField(
                          controller: _transferAmountCtrl,
                          keyboardType: TextInputType.number,
                          decoration: const InputDecoration(
                            labelText: 'Carrot amount',
                            prefixIcon: Icon(Icons.local_florist_outlined),
                          ),
                        ),
                        const SizedBox(height: 12),
                        Row(
                          children: [
                            Expanded(
                              child: FilledButton.icon(
                                onPressed: _loading ? null : _transfer,
                                icon: const Icon(Icons.send_outlined),
                                label: const Text('Transfer'),
                              ),
                            ),
                          ],
                        ),
                      ],
                    ),
                  ),
                ),
                const SizedBox(height: 12),
                if (!_loading && _error == null && _items.isEmpty)
                  const Padding(
                    padding: EdgeInsets.all(24),
                    child: Center(child: Text('No history')),
                  ),
                ..._items.map(
                  (e) => Card(
                    child: ListTile(
                      leading: Icon(
                        e.type == 'earn'
                            ? Icons.add_circle_outline
                            : Icons.remove_circle_outline,
                      ),
                      title: Text(
                        e.triggerTypeString.isEmpty
                            ? e.triggerType
                            : e.triggerTypeString,
                      ),
                      subtitle: Text(
                        [
                          '${e.type} · ${e.point}',
                          'Created: ${e.createdAt}',
                          if ((e.expiredAt ?? '').trim().isNotEmpty)
                            'Expires: ${e.expiredAt}',
                        ].join('\n'),
                      ),
                    ),
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

