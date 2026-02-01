import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';

import '../services/cover_cache_manager.dart';
import 'package:lin_player_server_api/network/lin_http_client.dart';
import '../services/server_icon_library.dart';

class ServerIconAvatar extends StatelessWidget {
  const ServerIconAvatar({
    super.key,
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
      httpHeaders: {'User-Agent': LinHttpClientFactory.userAgent},
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

class ServerIconLibrarySheet extends StatefulWidget {
  const ServerIconLibrarySheet({
    super.key,
    required this.urlsListenable,
    required this.getLibraryUrls,
    required this.addLibraryUrl,
    required this.removeLibraryUrlAt,
    required this.reorderLibraryUrls,
    required this.selectedUrl,
  });

  /// Notifies when [getLibraryUrls] may have changed.
  final Listenable urlsListenable;

  /// Returns current icon library urls (the list may change over time).
  final List<String> Function() getLibraryUrls;

  /// Adds a new icon library url. Returns `true` when inserted successfully.
  final Future<bool> Function(String url) addLibraryUrl;

  /// Removes a url at [index].
  final void Function(int index) removeLibraryUrlAt;

  /// Reorders urls (same signature as Flutter's `ReorderableListView`).
  final void Function(int oldIndex, int newIndex) reorderLibraryUrls;

  final String? selectedUrl;

  @override
  State<ServerIconLibrarySheet> createState() => _ServerIconLibrarySheetState();
}

class _ServerIconLibrarySheetState extends State<ServerIconLibrarySheet> {
  static const _allLibrariesId = '__all__';
  final _queryCtrl = TextEditingController();
  late List<String> _urlsSnapshot;
  late Future<ServerIconLibraries> _libsFuture;
  String _selectedLibraryId = _allLibrariesId;

  @override
  void initState() {
    super.initState();
    _urlsSnapshot = widget.getLibraryUrls();
    _libsFuture = _loadLibraries();
    widget.urlsListenable.addListener(_onUrlsChanged);
  }

  @override
  void dispose() {
    widget.urlsListenable.removeListener(_onUrlsChanged);
    _queryCtrl.dispose();
    super.dispose();
  }

  bool _sameStringList(List<String> a, List<String> b) {
    if (identical(a, b)) return true;
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (a[i] != b[i]) return false;
    }
    return true;
  }

  void _onUrlsChanged() {
    final next = widget.getLibraryUrls();
    if (_sameStringList(_urlsSnapshot, next)) return;
    _urlsSnapshot = next;
    if (mounted) setState(() => _libsFuture = _loadLibraries());
  }

  Future<ServerIconLibraries> _loadLibraries({bool refresh = false}) {
    return ServerIconLibrary.loadAll(
      extraUrls: widget.getLibraryUrls(),
      refresh: refresh,
    );
  }

  Future<void> _openLibraryManager() async {
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (ctx) => _ServerIconLibraryManagerSheet(
        urlsListenable: widget.urlsListenable,
        getLibraryUrls: widget.getLibraryUrls,
        addLibraryUrl: widget.addLibraryUrl,
        removeLibraryUrlAt: widget.removeLibraryUrlAt,
        reorderLibraryUrls: widget.reorderLibraryUrls,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final viewInsets = MediaQuery.of(context).viewInsets;
    return Padding(
      padding:
          EdgeInsets.only(left: 16, right: 16, bottom: viewInsets.bottom + 16),
      child: FutureBuilder<ServerIconLibraries>(
        future: _libsFuture,
        builder: (context, snapshot) {
          final libs = snapshot.data;
          final sources = libs?.sources ?? const <ServerIconLibrarySource>[];
          final available =
              sources.where((s) => s.library != null).toList(growable: false);
          final errorCount = sources.where((s) => s.error != null).length;

          final validIds = {
            _allLibrariesId,
            ...available.map((s) => s.id),
          };
          final dropdownValue = validIds.contains(_selectedLibraryId)
              ? _selectedLibraryId
              : _allLibrariesId;
          if (_selectedLibraryId != dropdownValue) {
            WidgetsBinding.instance.addPostFrameCallback((_) {
              if (!mounted) return;
              setState(() => _selectedLibraryId = dropdownValue);
            });
          }

          List<ServerIconEntry> icons = const [];
          Map<String, String>? subtitleByUrl;

          if (libs != null && available.isNotEmpty) {
            if (dropdownValue == _allLibrariesId) {
              final seen = <String>{};
              final merged = <ServerIconEntry>[];
              final subtitles = <String, String>{};
              for (final src in available) {
                final lib = src.library;
                if (lib == null) continue;
                final srcName = src.displayName;
                for (final icon in lib.icons) {
                  final url = icon.url.trim();
                  if (url.isEmpty) continue;
                  if (!seen.add(url)) continue;
                  merged.add(icon);
                  subtitles[url] = srcName;
                }
              }
              icons = merged;
              subtitleByUrl = available.length > 1 ? subtitles : null;
            } else {
              final src = available.firstWhere((s) => s.id == dropdownValue);
              icons = src.library?.icons ?? const [];
              subtitleByUrl = null;
            }
          }

          return Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Row(
                children: [
                  Expanded(
                    child: Text(
                      '选择图标',
                      style: Theme.of(context).textTheme.titleLarge,
                    ),
                  ),
                  IconButton(
                    tooltip: '管理图标库',
                    icon: const Icon(Icons.library_add_outlined),
                    onPressed: _openLibraryManager,
                  ),
                  IconButton(
                    tooltip: '刷新图标库',
                    icon: const Icon(Icons.refresh),
                    onPressed: () => setState(
                      () => _libsFuture = _loadLibraries(refresh: true),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 12),
              if (widget.getLibraryUrls().isNotEmpty)
                DropdownButtonFormField<String>(
                  key: ValueKey(Object.hashAll(available.map((s) => s.id))),
                  initialValue: dropdownValue,
                  decoration: const InputDecoration(
                    labelText: '图标库',
                    prefixIcon: Icon(Icons.collections_outlined),
                  ),
                  items: [
                    const DropdownMenuItem(
                      value: _allLibrariesId,
                      child: Text('全部图标库'),
                    ),
                    ...available.map(
                      (s) => DropdownMenuItem(
                        value: s.id,
                        child: Text(s.displayName),
                      ),
                    ),
                  ],
                  onChanged: (v) {
                    if (v == null) return;
                    setState(() => _selectedLibraryId = v);
                  },
                ),
              if (widget.getLibraryUrls().isNotEmpty)
                const SizedBox(height: 10),
              TextField(
                controller: _queryCtrl,
                decoration: const InputDecoration(
                  labelText: '搜索',
                  prefixIcon: Icon(Icons.search),
                ),
                onChanged: (_) => setState(() {}),
              ),
              const SizedBox(height: 10),
              if (errorCount > 0 &&
                  snapshot.connectionState != ConnectionState.waiting)
                Padding(
                  padding: const EdgeInsets.only(bottom: 8),
                  child: Row(
                    children: [
                      Icon(
                        Icons.warning_amber_outlined,
                        size: 18,
                        color: Theme.of(context).colorScheme.error,
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Text(
                          '有 $errorCount 个图标库加载失败',
                          style:
                              Theme.of(context).textTheme.bodySmall?.copyWith(
                                    color: Theme.of(context).colorScheme.error,
                                  ),
                        ),
                      ),
                      TextButton(
                        onPressed: _openLibraryManager,
                        child: const Text('管理'),
                      ),
                    ],
                  ),
                ),
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
              else if (icons.isEmpty)
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 24),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(
                        widget.getLibraryUrls().isEmpty ? '尚未添加图标库' : '图标库为空',
                      ),
                      if (widget.getLibraryUrls().isEmpty) ...[
                        const SizedBox(height: 10),
                        FilledButton(
                          onPressed: _openLibraryManager,
                          child: const Text('添加图标库'),
                        ),
                      ],
                    ],
                  ),
                )
              else
                Expanded(
                  child: _IconList(
                    icons: icons,
                    query: _queryCtrl.text,
                    selectedUrl: widget.selectedUrl,
                    subtitleByUrl: subtitleByUrl,
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

class _ServerIconLibraryManagerSheet extends StatefulWidget {
  const _ServerIconLibraryManagerSheet({
    required this.urlsListenable,
    required this.getLibraryUrls,
    required this.addLibraryUrl,
    required this.removeLibraryUrlAt,
    required this.reorderLibraryUrls,
  });

  final Listenable urlsListenable;
  final List<String> Function() getLibraryUrls;
  final Future<bool> Function(String url) addLibraryUrl;
  final void Function(int index) removeLibraryUrlAt;
  final void Function(int oldIndex, int newIndex) reorderLibraryUrls;

  @override
  State<_ServerIconLibraryManagerSheet> createState() =>
      _ServerIconLibraryManagerSheetState();
}

class _ServerIconLibraryManagerSheetState
    extends State<_ServerIconLibraryManagerSheet> {
  final _urlCtrl = TextEditingController();
  bool _adding = false;

  @override
  void dispose() {
    _urlCtrl.dispose();
    super.dispose();
  }

  Future<void> _addUrl() async {
    final v = _urlCtrl.text.trim();
    if (v.isEmpty) return;
    setState(() => _adding = true);
    final ok = await widget.addLibraryUrl(v);
    if (!mounted) return;
    setState(() => _adding = false);
    if (!ok) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('添加失败：链接无效或已存在')),
      );
      return;
    }
    setState(() => _urlCtrl.clear());
  }

  @override
  Widget build(BuildContext context) {
    final viewInsets = MediaQuery.of(context).viewInsets;
    return Padding(
      padding:
          EdgeInsets.only(left: 16, right: 16, bottom: viewInsets.bottom + 16),
      child: AnimatedBuilder(
        animation: widget.urlsListenable,
        builder: (context, _) {
          final urls = widget.getLibraryUrls();
          return Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                '图标库',
                style: Theme.of(context).textTheme.titleLarge,
              ),
              const SizedBox(height: 8),
              Text(
                '添加返回 JSON 的图标库链接（格式：{name, description, icons:[{name,url}] }）',
                style: Theme.of(context).textTheme.bodySmall?.copyWith(
                      color: Theme.of(context).colorScheme.onSurfaceVariant,
                    ),
              ),
              const SizedBox(height: 12),
              Row(
                children: [
                  Expanded(
                    child: TextField(
                      controller: _urlCtrl,
                      decoration: const InputDecoration(
                        labelText: '添加图标库链接',
                        hintText: 'https://example.com/server_icons.json',
                      ),
                      onSubmitted: (_) => _addUrl(),
                    ),
                  ),
                  const SizedBox(width: 12),
                  FilledButton(
                    onPressed: _adding ? null : _addUrl,
                    child: _adding
                        ? const SizedBox(
                            height: 16,
                            width: 16,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        : const Text('添加'),
                  ),
                ],
              ),
              const SizedBox(height: 10),
              if (urls.isEmpty)
                const Padding(
                  padding: EdgeInsets.symmetric(vertical: 8),
                  child: Align(
                    alignment: Alignment.centerLeft,
                    child: Text(
                      '尚未添加自定义图标库',
                      style: TextStyle(fontSize: 12),
                    ),
                  ),
                )
              else
                ReorderableListView.builder(
                  shrinkWrap: true,
                  physics: const NeverScrollableScrollPhysics(),
                  buildDefaultDragHandles: false,
                  itemCount: urls.length,
                  onReorder: widget.reorderLibraryUrls,
                  itemBuilder: (context, index) {
                    final url = urls[index];
                    return ListTile(
                      key: ValueKey(url),
                      contentPadding: EdgeInsets.zero,
                      leading: ReorderableDragStartListener(
                        index: index,
                        child: const Icon(Icons.drag_handle),
                      ),
                      title: Text(url),
                      trailing: IconButton(
                        tooltip: '删除',
                        icon: const Icon(Icons.delete_outline),
                        onPressed: () => widget.removeLibraryUrlAt(index),
                      ),
                    );
                  },
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
    this.subtitleByUrl,
    required this.onPick,
  });

  final List<ServerIconEntry> icons;
  final String query;
  final String? selectedUrl;
  final Map<String, String>? subtitleByUrl;
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
        final subtitle = subtitleByUrl?[icon.url]?.trim();
        return ListTile(
          leading: ServerIconAvatar(
            iconUrl: icon.url,
            name: icon.name,
            radius: 18,
          ),
          title: Text(icon.name),
          subtitle: (subtitle ?? '').isEmpty ? null : Text(subtitle!),
          trailing: selected ? const Icon(Icons.check) : null,
          onTap: () => onPick(icon.url),
        );
      },
    );
  }
}
