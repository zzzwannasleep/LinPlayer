import 'dart:async';

import 'package:flutter/material.dart';

import '../app_config/app_config_scope.dart';
import '../services/emos_api.dart';
import '../state/app_state.dart';

class EmosUserBrief {
  const EmosUserBrief({
    required this.userId,
    required this.username,
    this.avatar,
  });

  final String userId;
  final String username;
  final String? avatar;

  factory EmosUserBrief.fromJson(Map<String, dynamic> json) {
    return EmosUserBrief(
      userId: (json['user_id'] as String? ?? '').trim(),
      username: (json['username'] as String? ?? '').trim(),
      avatar: (json['avatar'] as String?)?.trim(),
    );
  }
}

class EmosWatch {
  const EmosWatch({
    required this.id,
    required this.subscribeId,
    required this.name,
    required this.description,
    required this.isPublic,
    required this.carrot,
    required this.tags,
    required this.imagePoster,
    required this.imagePosterUrl,
    required this.isShowEmpty,
    required this.isSelf,
    required this.isEditVideo,
    required this.isSubscribe,
    required this.subscribeCount,
    required this.videoCount,
    required this.maintainers,
    required this.author,
    required this.updatedAt,
  });

  final int id;
  final int? subscribeId;
  final String name;
  final String description;
  final bool isPublic;
  final int carrot;
  final List<String> tags;
  final String imagePoster;
  final String imagePosterUrl;
  final bool isShowEmpty;
  final bool isSelf;
  final bool isEditVideo;
  final bool isSubscribe;
  final int subscribeCount;
  final int videoCount;
  final List<EmosUserBrief> maintainers;
  final EmosUserBrief? author;
  final DateTime? updatedAt;

  factory EmosWatch.fromJson(Map<String, dynamic> json) {
    return EmosWatch(
      id: (json['id'] as num?)?.toInt() ?? 0,
      subscribeId: (json['subscribe_id'] as num?)?.toInt(),
      name: (json['name'] as String? ?? '').trim(),
      description: (json['description'] as String? ?? '').trim(),
      isPublic: json['is_public'] == true,
      carrot: (json['carrot'] as num?)?.toInt() ?? 0,
      tags: (json['tags'] as List<dynamic>? ?? const [])
          .map((e) => e.toString().trim())
          .where((e) => e.isNotEmpty)
          .toList(),
      imagePoster: (json['image_poster'] as String? ?? '').trim(),
      imagePosterUrl: (json['image_poster_url'] as String? ?? '').trim(),
      isShowEmpty: json['is_show_empty'] == true,
      isSelf: json['is_self'] == true,
      isEditVideo: json['is_edit_video'] == true,
      isSubscribe: json['is_subscribe'] == true,
      subscribeCount: (json['subscribe_count'] as num?)?.toInt() ?? 0,
      videoCount: (json['video_count'] as num?)?.toInt() ?? 0,
      maintainers: (json['maintainers'] as List<dynamic>? ?? const [])
          .whereType<Map>()
          .map((e) => EmosUserBrief.fromJson(e.cast<String, dynamic>()))
          .toList(),
      author: json['author'] is Map
          ? EmosUserBrief.fromJson(
              (json['author'] as Map).cast<String, dynamic>(),
            )
          : null,
      updatedAt: DateTime.tryParse((json['updated_at'] as String? ?? '').trim()),
    );
  }
}

class EmosPaged<T> {
  const EmosPaged({
    required this.page,
    required this.pageSize,
    required this.total,
    required this.items,
  });

  final int page;
  final int pageSize;
  final int total;
  final List<T> items;
}

class EmosWatchlistsPage extends StatefulWidget {
  const EmosWatchlistsPage({super.key, required this.appState});

  final AppState appState;

  @override
  State<EmosWatchlistsPage> createState() => _EmosWatchlistsPageState();
}

class _EmosWatchlistsPageState extends State<EmosWatchlistsPage>
    with SingleTickerProviderStateMixin {
  late final TabController _tabController;
  final _mineKey = GlobalKey<_WatchListTabState>();
  final _subKey = GlobalKey<_WatchListTabState>();
  final _publicKey = GlobalKey<_WatchListTabState>();

  @override
  void initState() {
    super.initState();
    _tabController = TabController(length: 3, vsync: this);
  }

  @override
  void dispose() {
    _tabController.dispose();
    super.dispose();
  }

  Future<void> _refreshCurrent() async {
    final idx = _tabController.index;
    final key = switch (idx) {
      0 => _mineKey,
      1 => _subKey,
      _ => _publicKey,
    };
    await key.currentState?.reload();
  }

  Future<void> _createWatch() async {
    final created = await Navigator.of(context).push<bool>(
      MaterialPageRoute(
        builder: (_) => EmosWatchEditPage(appState: widget.appState),
      ),
    );
    if (created == true) {
      await _refreshCurrent();
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
            title: const Text('Watchlists'),
            bottom: TabBar(
              controller: _tabController,
              tabs: const [
                Tab(text: 'Mine'),
                Tab(text: 'Subscribed'),
                Tab(text: 'Public'),
              ],
            ),
            actions: [
              IconButton(
                tooltip: 'Refresh',
                onPressed: _refreshCurrent,
                icon: const Icon(Icons.refresh),
              ),
            ],
          ),
          floatingActionButton: FloatingActionButton(
            onPressed: _createWatch,
            child: const Icon(Icons.add),
          ),
          body: TabBarView(
            controller: _tabController,
            children: [
              _WatchListTab(
                key: _mineKey,
                appState: widget.appState,
                isSelf: true,
              ),
              _WatchListTab(
                key: _subKey,
                appState: widget.appState,
                isSubscribe: true,
              ),
              _WatchListTab(
                key: _publicKey,
                appState: widget.appState,
                isPublic: true,
              ),
            ],
          ),
        );
      },
    );
  }
}

class _WatchListTab extends StatefulWidget {
  const _WatchListTab({
    super.key,
    required this.appState,
    this.isSelf,
    this.isSubscribe,
    this.isPublic,
  });

  final AppState appState;
  final bool? isSelf;
  final bool? isSubscribe;
  final bool? isPublic;

  @override
  State<_WatchListTab> createState() => _WatchListTabState();
}

class _WatchListTabState extends State<_WatchListTab> {
  bool _loading = false;
  String? _error;
  EmosPaged<EmosWatch>? _page;
  String _query = '';

  EmosApi _api() {
    final config = AppConfigScope.of(context);
    final token = widget.appState.emosSession?.token ?? '';
    return EmosApi(baseUrl: config.emosBaseUrl, token: token);
  }

  @override
  void initState() {
    super.initState();
    unawaited(reload());
  }

  Future<void> reload() async {
    if (_loading) return;
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final raw = await _api().fetchWatches(
        name: _query.trim().isEmpty ? null : _query.trim(),
        isSelf: widget.isSelf == true ? '1' : null,
        isSubscribe: widget.isSubscribe == true ? '1' : null,
        isPublic: widget.isPublic == true ? '1' : null,
      );
      final map = raw as Map<String, dynamic>;
      final items = (map['items'] as List<dynamic>? ?? const [])
          .whereType<Map>()
          .map((e) => EmosWatch.fromJson(e.cast<String, dynamic>()))
          .toList();
      final page = EmosPaged<EmosWatch>(
        page: (map['page'] as num?)?.toInt() ?? 1,
        pageSize: (map['page_size'] as num?)?.toInt() ?? items.length,
        total: (map['total'] as num?)?.toInt() ?? items.length,
        items: items,
      );
      if (!mounted) return;
      setState(() => _page = page);
    } catch (e) {
      if (!mounted) return;
      setState(() => _error = e.toString());
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _toggleSubscribe(EmosWatch watch) async {
    await _api().toggleWatchSubscribe('${watch.id}');
    await reload();
  }

  Future<void> _openDetail(EmosWatch watch) async {
    final changed = await Navigator.of(context).push<bool>(
      MaterialPageRoute(
        builder: (_) => EmosWatchDetailPage(
          appState: widget.appState,
          initial: watch,
        ),
      ),
    );
    if (changed == true) {
      await reload();
    }
  }

  @override
  Widget build(BuildContext context) {
    final items = _page?.items ?? const <EmosWatch>[];
    return RefreshIndicator(
      onRefresh: reload,
      child: ListView(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 24),
        children: [
          TextField(
            decoration: const InputDecoration(
              labelText: 'Search',
              prefixIcon: Icon(Icons.search),
            ),
            onChanged: (v) => setState(() => _query = v),
            onSubmitted: (_) => reload(),
          ),
          const SizedBox(height: 12),
          if (_loading) const LinearProgressIndicator(),
          if (_error != null)
            Padding(
              padding: const EdgeInsets.only(top: 8),
              child: Text(
                _error!,
                style: TextStyle(color: Theme.of(context).colorScheme.error),
              ),
            ),
          if (!_loading && _error == null && items.isEmpty)
            const Padding(
              padding: EdgeInsets.all(24),
              child: Center(child: Text('No watchlists')),
            ),
          ...items.map(
            (w) => Card(
              child: ListTile(
                leading: w.imagePosterUrl.isNotEmpty
                    ? ClipRRect(
                        borderRadius: BorderRadius.circular(6),
                        child: Image.network(
                          w.imagePosterUrl,
                          width: 44,
                          height: 44,
                          fit: BoxFit.cover,
                        ),
                      )
                    : const Icon(Icons.list_alt_outlined),
                title: Text(w.name.isEmpty ? '(no name)' : w.name),
                subtitle: Text(
                  [
                    if (w.tags.isNotEmpty) w.tags.join(' · '),
                    'Videos: ${w.videoCount} · Subs: ${w.subscribeCount}',
                  ].join('\n'),
                ),
                trailing: IconButton(
                  tooltip: w.isSubscribe ? 'Unsubscribe' : 'Subscribe',
                  icon: Icon(
                    w.isSubscribe ? Icons.star_rounded : Icons.star_border_rounded,
                  ),
                  onPressed: _loading ? null : () => _toggleSubscribe(w),
                ),
                onTap: () => _openDetail(w),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class EmosWatchEditPage extends StatefulWidget {
  const EmosWatchEditPage({
    super.key,
    required this.appState,
    this.initial,
  });

  final AppState appState;
  final EmosWatch? initial;

  @override
  State<EmosWatchEditPage> createState() => _EmosWatchEditPageState();
}

class _EmosWatchEditPageState extends State<EmosWatchEditPage> {
  bool _saving = false;

  late final TextEditingController _nameCtrl;
  late final TextEditingController _descCtrl;
  late final TextEditingController _tagsCtrl;
  late final TextEditingController _pointCtrl;
  late final TextEditingController _posterCtrl;
  bool _isPublic = true;
  bool _showEmpty = true;

  EmosApi _api() {
    final config = AppConfigScope.of(context);
    final token = widget.appState.emosSession?.token ?? '';
    return EmosApi(baseUrl: config.emosBaseUrl, token: token);
  }

  @override
  void initState() {
    super.initState();
    final w = widget.initial;
    _nameCtrl = TextEditingController(text: w?.name ?? '');
    _descCtrl = TextEditingController(text: w?.description ?? '');
    _tagsCtrl = TextEditingController(text: (w?.tags ?? const []).join(', '));
    _pointCtrl = TextEditingController(text: (w?.carrot ?? 0).toString());
    _posterCtrl = TextEditingController(text: w?.imagePoster ?? '');
    _isPublic = w?.isPublic ?? true;
    _showEmpty = w?.isShowEmpty ?? true;
  }

  @override
  void dispose() {
    _nameCtrl.dispose();
    _descCtrl.dispose();
    _tagsCtrl.dispose();
    _pointCtrl.dispose();
    _posterCtrl.dispose();
    super.dispose();
  }

  List<String> _parseTags(String raw) {
    return raw
        .split(RegExp(r'[,\\n]'))
        .map((e) => e.trim())
        .where((e) => e.isNotEmpty)
        .toSet()
        .toList();
  }

  Future<void> _save() async {
    final name = _nameCtrl.text.trim();
    if (name.isEmpty) return;

    if (_saving) return;
    setState(() => _saving = true);
    try {
      final point = int.tryParse(_pointCtrl.text.trim()) ?? 0;
      final body = <String, Object?>{
        'id': widget.initial?.id,
        'name': name,
        'description': _descCtrl.text.trim(),
        'is_public': _isPublic,
        'point': point,
        'tags': _parseTags(_tagsCtrl.text),
        'is_show_empty': _showEmpty,
        'image_poster': _posterCtrl.text.trim().isEmpty
            ? null
            : _posterCtrl.text.trim(),
      };
      await _api().upsertWatch(body);
      if (!mounted) return;
      Navigator.of(context).pop(true);
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Save failed: $e')),
      );
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final editing = widget.initial != null;
    return Scaffold(
      appBar: AppBar(
        title: Text(editing ? 'Edit watchlist' : 'New watchlist'),
        actions: [
          TextButton(
            onPressed: _saving ? null : _save,
            child: const Text('Save'),
          ),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 24),
        children: [
          if (_saving) const LinearProgressIndicator(),
          TextField(
            controller: _nameCtrl,
            decoration: const InputDecoration(labelText: 'Name'),
          ),
          const SizedBox(height: 12),
          TextField(
            controller: _descCtrl,
            maxLines: 6,
            decoration: const InputDecoration(labelText: 'Description'),
          ),
          const SizedBox(height: 12),
          TextField(
            controller: _tagsCtrl,
            decoration: const InputDecoration(
              labelText: 'Tags',
              hintText: 'Comma separated',
            ),
          ),
          const SizedBox(height: 12),
          TextField(
            controller: _pointCtrl,
            keyboardType: TextInputType.number,
            decoration: const InputDecoration(labelText: 'Required carrot'),
          ),
          const SizedBox(height: 12),
          TextField(
            controller: _posterCtrl,
            decoration: const InputDecoration(
              labelText: 'Poster file_id',
              hintText: 'Optional',
            ),
          ),
          const SizedBox(height: 12),
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            value: _isPublic,
            title: const Text('Public'),
            onChanged: _saving ? null : (v) => setState(() => _isPublic = v),
          ),
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            value: _showEmpty,
            title: const Text('Show empty media'),
            onChanged: _saving ? null : (v) => setState(() => _showEmpty = v),
          ),
        ],
      ),
    );
  }
}

class EmosWatchDetailPage extends StatefulWidget {
  const EmosWatchDetailPage({
    super.key,
    required this.appState,
    required this.initial,
  });

  final AppState appState;
  final EmosWatch initial;

  @override
  State<EmosWatchDetailPage> createState() => _EmosWatchDetailPageState();
}

class _EmosWatchDetailPageState extends State<EmosWatchDetailPage> {
  bool _loading = false;
  String? _error;
  late EmosWatch _watch = widget.initial;

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
      final raw = await _api().fetchWatches(watchId: '${_watch.id}');
      final map = raw as Map<String, dynamic>;
      final items = (map['items'] as List<dynamic>? ?? const [])
          .whereType<Map>()
          .map((e) => EmosWatch.fromJson(e.cast<String, dynamic>()))
          .toList();
      if (items.isNotEmpty) {
        _watch = items.first;
      }
      if (!mounted) return;
      setState(() {});
    } catch (e) {
      if (!mounted) return;
      setState(() => _error = e.toString());
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _toggleSubscribe() async {
    await _api().toggleWatchSubscribe('${_watch.id}');
    await _reload();
    if (!mounted) return;
    Navigator.of(context).pop(true);
  }

  Future<void> _edit() async {
    final ok = await Navigator.of(context).push<bool>(
      MaterialPageRoute(
        builder: (_) => EmosWatchEditPage(
          appState: widget.appState,
          initial: _watch,
        ),
      ),
    );
    if (ok == true) {
      await _reload();
      if (!mounted) return;
      Navigator.of(context).pop(true);
    }
  }

  Future<void> _delete() async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (dctx) => AlertDialog(
        title: const Text('Delete watchlist?'),
        content: Text(_watch.name),
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
    await _api().deleteWatch('${_watch.id}');
    if (!mounted) return;
    Navigator.of(context).pop(true);
  }

  Future<void> _updateMaintainers() async {
    final ctrl = TextEditingController(
      text: _watch.maintainers.map((e) => e.userId).join(', '),
    );
    try {
      final raw = await showDialog<String>(
        context: context,
        builder: (dctx) => AlertDialog(
          title: const Text('Maintainers (user_id)'),
          content: TextField(
            controller: ctrl,
            maxLines: 3,
            decoration: const InputDecoration(hintText: 'Comma separated'),
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
      if ((raw ?? '').trim().isEmpty) return;
      final ids = raw!
          .split(RegExp(r'[,\\n]'))
          .map((e) => e.trim())
          .where((e) => e.isNotEmpty)
          .toList();
      await _api()
          .updateWatchMaintainers(watchId: '${_watch.id}', maintainers: ids);
      await _reload();
    } finally {
      ctrl.dispose();
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
            title: Text(_watch.name.isEmpty ? 'Watchlist' : _watch.name),
            actions: [
              IconButton(
                tooltip: 'Refresh',
                onPressed: _reload,
                icon: const Icon(Icons.refresh),
              ),
              IconButton(
                tooltip: _watch.isSubscribe ? 'Unsubscribe' : 'Subscribe',
                onPressed: _toggleSubscribe,
                icon: Icon(
                  _watch.isSubscribe
                      ? Icons.star_rounded
                      : Icons.star_border_rounded,
                ),
              ),
              if (_watch.isSelf)
                IconButton(
                  tooltip: 'Edit',
                  onPressed: _edit,
                  icon: const Icon(Icons.edit_outlined),
                ),
              if (_watch.isSelf)
                IconButton(
                  tooltip: 'Delete',
                  onPressed: _delete,
                  icon: const Icon(Icons.delete_outline),
                ),
            ],
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
              Card(
                child: Column(
                  children: [
                    ListTile(
                      leading: _watch.imagePosterUrl.isNotEmpty
                          ? ClipRRect(
                              borderRadius: BorderRadius.circular(8),
                              child: Image.network(
                                _watch.imagePosterUrl,
                                width: 52,
                                height: 52,
                                fit: BoxFit.cover,
                              ),
                            )
                          : const Icon(Icons.list_alt_outlined),
                      title: Text(_watch.name),
                      subtitle: Text(
                        [
                          if (_watch.tags.isNotEmpty) _watch.tags.join(' · '),
                          'Videos: ${_watch.videoCount} · Subs: ${_watch.subscribeCount}',
                        ].join('\n'),
                      ),
                    ),
                    if (_watch.description.isNotEmpty) ...[
                      const Divider(height: 1),
                      ListTile(
                        leading: const Icon(Icons.description_outlined),
                        title: const Text('Description'),
                        subtitle: Text(_watch.description),
                      ),
                    ],
                    const Divider(height: 1),
                    ListTile(
                      leading: const Icon(Icons.people_outline),
                      title: const Text('Maintainers'),
                      subtitle: Text(
                        _watch.maintainers.isEmpty
                            ? '-'
                            : _watch.maintainers
                                .map((e) => e.username)
                                .join(', '),
                      ),
                      trailing:
                          _watch.isSelf ? const Icon(Icons.chevron_right) : null,
                      onTap: _watch.isSelf ? _updateMaintainers : null,
                    ),
                    const Divider(height: 1),
                    ListTile(
                      leading: const Icon(Icons.person_outline),
                      title: const Text('Author'),
                      subtitle: Text(_watch.author?.username ?? '-'),
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

