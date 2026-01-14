import 'dart:ui';

import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import 'library_page.dart';
import 'library_items_page.dart';
import 'player_screen.dart';
import 'play_network_page.dart';
import 'settings_page.dart';
import 'services/emby_api.dart';
import 'state/app_state.dart';
import 'show_detail_page.dart';
import 'src/ui/theme_sheet.dart';

class HomePage extends StatefulWidget {
  const HomePage({super.key, required this.appState});

  final AppState appState;

  @override
  State<HomePage> createState() => _HomePageState();
}

class _GlobalSearchDelegate extends SearchDelegate<String> {
  _GlobalSearchDelegate({required this.appState});
  final AppState appState;
  List<MediaItem> _results = [];
  bool _loading = false;

  Future<void> _doSearch(String q) async {
    _loading = true;
    try {
      await appState.loadItems(
        parentId: appState.userId ?? '',
        searchTerm: q,
        startIndex: 0,
        includeItemTypes: null,
      );
      _results = appState.getItems(appState.userId ?? '');
    } finally {
      _loading = false;
    }
  }

  @override
  Widget buildResults(BuildContext context) {
    if (_loading) {
      return const Center(child: CircularProgressIndicator());
    }
    if (_results.isEmpty) {
      return const Center(child: Text('没有结果'));
    }
    return ListView.builder(
      itemCount: _results.length,
      itemBuilder: (context, index) {
        final item = _results[index];
        return ListTile(
          leading: const Icon(Icons.search),
          title: Text(item.name),
          subtitle: Text(item.type),
          onTap: () {
            Navigator.of(context).push(
              MaterialPageRoute(
                builder: (_) => ShowDetailPage(
                  itemId: item.id,
                  title: item.name,
                  appState: appState,
                  isTv: false,
                ),
              ),
            );
          },
        );
      },
    );
  }

  @override
  Widget buildSuggestions(BuildContext context) => const SizedBox.shrink();

  @override
  List<Widget>? buildActions(BuildContext context) {
    return [
      IconButton(
        icon: const Icon(Icons.clear),
        onPressed: () {
          query = '';
          _results = [];
          showSuggestions(context);
        },
      )
    ];
  }

  @override
  Widget? buildLeading(BuildContext context) {
    return IconButton(
      icon: const Icon(Icons.arrow_back),
      onPressed: () => close(context, ''),
    );
  }

  @override
  void showResults(BuildContext context) {
    // ignore: use_build_context_synchronously
    _doSearch(query).then((_) => super.showResults(context));
  }
}

class _HomePageState extends State<HomePage> {
  int _index = 0; // 0 home, 1 local, 2 settings
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() => _loading = true);
    try {
      if (widget.appState.libraries.isEmpty && !widget.appState.isLoading) {
        await widget.appState.refreshLibraries();
      }
      await widget.appState.loadHome();
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  bool _isTv(BuildContext context) =>
      defaultTargetPlatform == TargetPlatform.android &&
      MediaQuery.of(context).size.shortestSide > 600;

  Future<void> _showRoutePicker() async {
    if (widget.appState.domains.isEmpty && !widget.appState.isLoading) {
      // Best effort: prefetch line list.
      // ignore: unawaited_futures
      widget.appState.refreshDomains();
    }

    await showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      builder: (ctx) {
        return AnimatedBuilder(
          animation: widget.appState,
          builder: (context, _) {
            final pluginDomains = widget.appState.domains;
            final customEntries = widget.appState.customDomains
                .map((d) => DomainInfo(name: d.name, url: d.url))
                .toList();
            final current = widget.appState.baseUrl;
            final entries = <({DomainInfo domain, bool isCustom})>[
              for (final d in customEntries) (domain: d, isCustom: true),
              for (final d in pluginDomains) (domain: d, isCustom: false),
            ];
            return Padding(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Row(
                    children: [
                      Expanded(
                        child: Text(
                          '线路',
                          style: Theme.of(context).textTheme.titleLarge,
                        ),
                      ),
                      IconButton(
                        tooltip: '添加自定义线路',
                        onPressed: () async {
                          final nameCtrl = TextEditingController();
                          final urlCtrl = TextEditingController();
                          final remarkCtrl = TextEditingController();
                          final result = await showDialog<Map<String, String>>(
                            context: context,
                            builder: (dctx) => AlertDialog(
                              title: const Text('添加自定义线路'),
                              content: SingleChildScrollView(
                                child: Column(
                                  mainAxisSize: MainAxisSize.min,
                                  children: [
                                    TextField(
                                      controller: nameCtrl,
                                      decoration: const InputDecoration(
                                        labelText: '名称',
                                        hintText: '例如：直连 / 备用 / 移动',
                                      ),
                                    ),
                                    const SizedBox(height: 10),
                                    TextField(
                                      controller: urlCtrl,
                                      decoration: const InputDecoration(
                                        labelText: '地址',
                                        hintText: '例如：https://emby.example.com:8920',
                                      ),
                                      keyboardType: TextInputType.url,
                                    ),
                                    const SizedBox(height: 10),
                                    TextField(
                                      controller: remarkCtrl,
                                      decoration: const InputDecoration(
                                        labelText: '备注（可选）',
                                        hintText: '例如：挂梯 / 移动 / 低延迟…',
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                              actions: [
                                TextButton(
                                  onPressed: () => Navigator.of(dctx).pop(),
                                  child: const Text('取消'),
                                ),
                                FilledButton(
                                  onPressed: () {
                                    Navigator.of(dctx).pop({
                                      'name': nameCtrl.text.trim(),
                                      'url': urlCtrl.text.trim(),
                                      'remark': remarkCtrl.text.trim(),
                                    });
                                  },
                                  child: const Text('保存'),
                                ),
                              ],
                            ),
                          );
                          if (result == null) return;
                          try {
                            await widget.appState.addCustomDomain(
                              name: result['name'] ?? '',
                              url: result['url'] ?? '',
                              remark: (result['remark'] ?? '').trim().isEmpty
                                  ? null
                                  : (result['remark'] ?? '').trim(),
                            );
                          } catch (e) {
                            if (!context.mounted) return;
                            ScaffoldMessenger.of(context).showSnackBar(
                              SnackBar(content: Text(e.toString())),
                            );
                          }
                        },
                        icon: const Icon(Icons.add),
                      ),
                      IconButton(
                        tooltip: '刷新',
                        onPressed: widget.appState.isLoading ? null : widget.appState.refreshDomains,
                        icon: const Icon(Icons.refresh),
                      ),
                    ],
                  ),
                  if (entries.isEmpty && !widget.appState.isLoading)
                    const Padding(
                      padding: EdgeInsets.only(top: 10, bottom: 8),
                      child: Text('暂无线路（未部署扩展时属于正常情况）'),
                    )
                  else
                    Flexible(
                      child: ListView.separated(
                        shrinkWrap: true,
                        itemCount: entries.length,
                        separatorBuilder: (_, __) => const Divider(height: 1),
                        itemBuilder: (context, index) {
                          final entry = entries[index];
                          final d = entry.domain;
                          final isCustom = entry.isCustom;
                          final name = d.name.trim().isNotEmpty ? d.name.trim() : d.url;
                          final remark = widget.appState.domainRemark(d.url);
                          final selected = current == d.url;
                          return ListTile(
                            contentPadding: EdgeInsets.zero,
                            title: Text(
                              name,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                            ),
                            subtitle: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                if ((remark ?? '').trim().isNotEmpty)
                                  Text(
                                    remark!.trim(),
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                  ),
                                Text(
                                  d.url,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                ),
                              ],
                            ),
                            trailing: Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                IconButton(
                                  tooltip: '备注',
                                  icon: const Icon(Icons.edit_outlined),
                                  onPressed: () async {
                                    final ctrl = TextEditingController(text: remark ?? '');
                                    final v = await showDialog<String>(
                                      context: context,
                                      builder: (dctx) => AlertDialog(
                                        title: const Text('线路备注'),
                                        content: TextField(
                                          controller: ctrl,
                                          decoration: const InputDecoration(
                                            hintText: '例如：直连 / 移动 / 挂梯…',
                                          ),
                                        ),
                                        actions: [
                                          TextButton(
                                            onPressed: () => Navigator.of(dctx).pop(),
                                            child: const Text('取消'),
                                          ),
                                          FilledButton(
                                            onPressed: () => Navigator.of(dctx).pop(ctrl.text),
                                            child: const Text('保存'),
                                          ),
                                        ],
                                      ),
                                    );
                                    if (v == null) return;
                                    await widget.appState.setDomainRemark(d.url, v);
                                  },
                                ),
                                if (selected) const Icon(Icons.check),
                              ],
                            ),
                            onLongPress: !isCustom
                                ? null
                                : () async {
                                    final action = await showModalBottomSheet<String>(
                                      context: context,
                                      showDragHandle: true,
                                      builder: (bctx) => SafeArea(
                                        child: Column(
                                          mainAxisSize: MainAxisSize.min,
                                          children: [
                                            ListTile(
                                              title: Text(name),
                                              subtitle: Text(d.url),
                                            ),
                                            const Divider(height: 1),
                                            ListTile(
                                              leading: const Icon(Icons.edit_outlined),
                                              title: const Text('编辑'),
                                              onTap: () => Navigator.of(bctx).pop('edit'),
                                            ),
                                            ListTile(
                                              leading: const Icon(Icons.delete_outline),
                                              title: const Text('删除'),
                                              onTap: () => Navigator.of(bctx).pop('delete'),
                                            ),
                                            const SizedBox(height: 8),
                                          ],
                                        ),
                                      ),
                                    );
                                    if (action == null) return;
                                    if (!context.mounted) return;

                                    if (action == 'delete') {
                                      final ok = await showDialog<bool>(
                                        context: context,
                                        builder: (dctx) => AlertDialog(
                                          title: const Text('删除线路？'),
                                          content: Text('将删除“$name”。'),
                                          actions: [
                                            TextButton(
                                              onPressed: () => Navigator.of(dctx).pop(false),
                                              child: const Text('取消'),
                                            ),
                                            FilledButton(
                                              onPressed: () => Navigator.of(dctx).pop(true),
                                              child: const Text('删除'),
                                            ),
                                          ],
                                        ),
                                      );
                                      if (ok != true) return;
                                      await widget.appState.removeCustomDomain(d.url);
                                      return;
                                    }

                                    final nameCtrl = TextEditingController(text: d.name);
                                    final urlCtrl = TextEditingController(text: d.url);
                                    final remarkCtrl = TextEditingController(text: remark ?? '');
                                    final result = await showDialog<Map<String, String>>(
                                      context: context,
                                      builder: (dctx) => AlertDialog(
                                        title: const Text('编辑自定义线路'),
                                        content: SingleChildScrollView(
                                          child: Column(
                                            mainAxisSize: MainAxisSize.min,
                                            children: [
                                              TextField(
                                                controller: nameCtrl,
                                                decoration: const InputDecoration(labelText: '名称'),
                                              ),
                                              const SizedBox(height: 10),
                                              TextField(
                                                controller: urlCtrl,
                                                decoration: const InputDecoration(labelText: '地址'),
                                                keyboardType: TextInputType.url,
                                              ),
                                              const SizedBox(height: 10),
                                              TextField(
                                                controller: remarkCtrl,
                                                decoration: const InputDecoration(labelText: '备注（可选）'),
                                              ),
                                            ],
                                          ),
                                        ),
                                        actions: [
                                          TextButton(
                                            onPressed: () => Navigator.of(dctx).pop(),
                                            child: const Text('取消'),
                                          ),
                                          FilledButton(
                                            onPressed: () {
                                              Navigator.of(dctx).pop({
                                                'name': nameCtrl.text.trim(),
                                                'url': urlCtrl.text.trim(),
                                                'remark': remarkCtrl.text.trim(),
                                              });
                                            },
                                            child: const Text('保存'),
                                          ),
                                        ],
                                      ),
                                    );
                                    if (result == null) return;
                                    try {
                                      await widget.appState.updateCustomDomain(
                                        d.url,
                                        name: result['name'] ?? '',
                                        url: result['url'] ?? '',
                                        remark: (result['remark'] ?? '').trim().isEmpty
                                            ? null
                                            : (result['remark'] ?? '').trim(),
                                      );
                                    } catch (e) {
                                      if (!context.mounted) return;
                                      ScaffoldMessenger.of(context).showSnackBar(
                                        SnackBar(content: Text(e.toString())),
                                      );
                                    }
                                  },
                            onTap: () async {
                              await widget.appState.setBaseUrl(d.url);
                              // Best-effort: reload content after line switch.
                              // ignore: unawaited_futures
                              widget.appState.refreshLibraries().then((_) => widget.appState.loadHome());
                              if (ctx.mounted) Navigator.of(ctx).pop();
                            },
                          );
                        },
                      ),
                    ),
                ],
              ),
            );
          },
        );
      },
    );
  }

  Future<void> _showThemeSheet() => showThemeSheet(context, widget.appState);

  Future<void> _switchServer() => widget.appState.leaveServer();

  @override
  Widget build(BuildContext context) {
    final isTv = _isTv(context);
    final enableGlass = !isTv;

    final pages = [
      _HomeBody(
        appState: widget.appState,
        loading: _loading,
        onRefresh: _load,
        enableGlass: enableGlass,
        onSearch: (q) {
          if (q.trim().isEmpty) return;
          showSearch(
            context: context,
            delegate: _GlobalSearchDelegate(appState: widget.appState)..query = q.trim(),
          );
        },
        isTv: isTv,
        showSearchBar: true,
      ),
      PlayerScreen(appState: widget.appState),
      SettingsPage(appState: widget.appState),
    ];

    return AnimatedBuilder(
      animation: widget.appState,
      builder: (context, _) {
        return Scaffold(
          appBar: _index == 0
              ? AppBar(
                  title: Text(widget.appState.activeServer?.name ?? 'LinPlayer'),
                  actions: [
                    IconButton(
                      icon: const Icon(Icons.video_library_outlined),
                      tooltip: '媒体库',
                      onPressed: () {
                        Navigator.of(context).push(
                          MaterialPageRoute(builder: (_) => LibraryPage(appState: widget.appState)),
                        );
                      },
                    ),
                    IconButton(
                      icon: const Icon(Icons.alt_route_outlined),
                      tooltip: '线路',
                      onPressed: _showRoutePicker,
                    ),
                    IconButton(
                      icon: const Icon(Icons.palette_outlined),
                      tooltip: '主题',
                      onPressed: _showThemeSheet,
                    ),
                    IconButton(
                      icon: const Icon(Icons.storage_outlined),
                      tooltip: '服务器',
                      onPressed: _switchServer,
                    ),
                  ],
                )
              : null,
          body: pages[_index],
          bottomNavigationBar: NavigationBar(
            selectedIndex: _index,
            onDestinationSelected: (i) => setState(() => _index = i),
            destinations: const [
              NavigationDestination(icon: Icon(Icons.home_outlined), label: '首页'),
              NavigationDestination(icon: Icon(Icons.folder_open), label: '本地'),
              NavigationDestination(icon: Icon(Icons.settings_outlined), label: '设置'),
            ],
          ),
        );
      },
    );
  }
}

class _HomeBody extends StatelessWidget {
  const _HomeBody({
    required this.appState,
    required this.loading,
    required this.onRefresh,
    required this.enableGlass,
    required this.onSearch,
    required this.isTv,
    required this.showSearchBar,
  });

  final AppState appState;
  final bool loading;
  final Future<void> Function() onRefresh;
  final bool enableGlass;
  final void Function(String) onSearch;
  final bool isTv;
  final bool showSearchBar;

  @override
  Widget build(BuildContext context) {
    final sections = <HomeEntry>[];
    for (final entry in appState.homeEntries) {
      final shows = entry.items;
      if (shows.isNotEmpty) {
        sections.add(entry);
      }
    }

    return RefreshIndicator(
      onRefresh: onRefresh,
      child: ListView(
        padding: const EdgeInsets.only(bottom: 16),
        children: [
          if (showSearchBar) ...[
            const SizedBox(height: 8),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 14),
              child: TextField(
                decoration: const InputDecoration(
                  hintText: '搜索片名…',
                  prefixIcon: Icon(Icons.search),
                ),
                textInputAction: TextInputAction.search,
                onSubmitted: onSearch,
              ),
            ),
            const SizedBox(height: 8),
          ],
          if (loading) const LinearProgressIndicator(),
           for (final sec in sections)
             if (sec.items.isNotEmpty) ...[
               _HomeSectionHeader(
                 title: sec.displayName,
                 count: sec.key.startsWith('lib_')
                     ? appState.getTotal(sec.key.substring(4))
                     : 0,
                 onTap: () {
                   if (!sec.key.startsWith('lib_')) return;
                   final libId = sec.key.substring(4);
                   Navigator.of(context).push(
                    MaterialPageRoute(
                      builder: (_) => LibraryItemsPage(
                        appState: appState,
                        parentId: libId,
                        title: sec.displayName,
                        isTv: isTv,
                      ),
                    ),
                  );
                },
              ),
              _HomeSectionCarousel(
                items: sec.items,
                appState: appState,
                enableGlass: enableGlass,
                isTv: isTv,
              ),
            ]
            else
              const SizedBox.shrink(),
          if (sections.every((e) => e.items.isEmpty) && !loading)
            const Padding(
              padding: EdgeInsets.all(24),
              child: Center(child: Text('暂无可展示内容')),
            ),
        ],
      ),
    );
  }
}

class _HomeSectionHeader extends StatelessWidget {
  const _HomeSectionHeader({required this.title, required this.count, required this.onTap});

  final String title;
  final int count;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    String formatCount(int n) => n
        .toString()
        .replaceAllMapped(RegExp(r'(\\d)(?=(\\d{3})+$)'), (m) => '${m[1]},');

    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 6),
      child: InkWell(
        borderRadius: BorderRadius.circular(12),
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 2),
          child: Row(
            children: [
              Expanded(
                child: Text(
                  title,
                  style: Theme.of(context).textTheme.titleMedium,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              const SizedBox(width: 6),
              if (count > 0)
                Text(
                  formatCount(count),
                  style: Theme.of(context)
                      .textTheme
                      .labelLarge
                      ?.copyWith(color: Theme.of(context).colorScheme.onSurfaceVariant),
                ),
              const SizedBox(width: 2),
              Icon(
                Icons.chevron_right,
                size: 18,
                color: Theme.of(context).colorScheme.onSurfaceVariant,
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _HomeSectionCarousel extends StatelessWidget {
  const _HomeSectionCarousel({
    required this.items,
    required this.appState,
    required this.enableGlass,
    required this.isTv,
  });

  final List<MediaItem> items;
  final AppState appState;
  final bool enableGlass;
  final bool isTv;

  static const _maxItems = 12;

  @override
  Widget build(BuildContext context) {
        return LayoutBuilder(
      builder: (context, constraints) {
        const padding = 14.0;
        const spacing = 8.0;
        const visible = 4.0;
        final maxCount = items.length < _maxItems ? items.length : _maxItems;

        final itemWidth =
            (constraints.maxWidth - padding * 2 - spacing * (visible - 1)) / visible;
        final imageHeight = itemWidth * 3 / 2;
        final listHeight = imageHeight + 44; // card padding + title line

        return Padding(
          padding: const EdgeInsets.only(bottom: 6),
          child: SizedBox(
            height: listHeight,
            child: ListView.separated(
              cacheExtent: 0,
              padding: const EdgeInsets.symmetric(horizontal: padding),
              scrollDirection: Axis.horizontal,
              itemCount: maxCount,
              separatorBuilder: (_, __) => const SizedBox(width: spacing),
              itemBuilder: (context, index) {
                final item = items[index];
                return SizedBox(
                  width: itemWidth,
                  child: _HomeCard(
                    item: item,
                    appState: appState,
                    enableGlass: enableGlass,
                    isTv: isTv,
                    onTap: () {
                      final type = item.type.toLowerCase();
                      if (type == 'series') {
                        Navigator.of(context).push(
                          MaterialPageRoute(
                            builder: (_) => ShowDetailPage(
                              itemId: item.id,
                              title: item.name,
                              appState: appState,
                              isTv: isTv,
                            ),
                          ),
                        );
                      } else {
                        Navigator.of(context).push(
                          MaterialPageRoute(
                            builder: (_) => PlayNetworkPage(
                              title: item.name,
                              itemId: item.id,
                              appState: appState,
                              isTv: isTv,
                            ),
                          ),
                        );
                      }
                    },
                  ),
                );
              },
            ),
          ),
        );
      },
    );
  }
}

class _HomeCard extends StatelessWidget {
  const _HomeCard({
    required this.item,
    required this.appState,
    required this.enableGlass,
    required this.isTv,
    required this.onTap,
  });

  final MediaItem item;
  final AppState appState;
  final bool enableGlass;
  final bool isTv;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final image = item.hasImage
        ? EmbyApi.imageUrl(
            baseUrl: appState.baseUrl!,
            itemId: item.id,
            token: appState.token!,
            maxWidth: 240,
          )
        : null;

    final card = Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        AspectRatio(
          aspectRatio: 2 / 3,
          child: ClipRRect(
            borderRadius: BorderRadius.circular(10),
            child: image != null
                ? CachedNetworkImage(
                    imageUrl: image,
                    httpHeaders: {'User-Agent': EmbyApi.userAgent},
                    fit: BoxFit.cover,
                    placeholder: (_, __) =>
                        const Center(child: CircularProgressIndicator(strokeWidth: 2)),
                    errorWidget: (_, __, ___) =>
                        const ColoredBox(color: Colors.black12, child: Icon(Icons.broken_image)),
                  )
                : const ColoredBox(color: Colors.black12, child: Icon(Icons.image)),
          ),
        ),
        const SizedBox(height: 6),
        Text(
          item.name,
          style: Theme.of(context).textTheme.bodySmall?.copyWith(fontWeight: FontWeight.w600),
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
        ),
      ],
    );

    return InkWell(
      borderRadius: BorderRadius.circular(12),
      onTap: onTap,
      child: enableGlass
          ? ClipRRect(
              borderRadius: BorderRadius.circular(12),
              child: BackdropFilter(
                filter: ImageFilter.blur(sigmaX: 10, sigmaY: 10),
                child: Container(
                  padding: const EdgeInsets.all(6),
                  decoration: BoxDecoration(
                    color: Colors.white.withValues(alpha: 0.08),
                    border: Border.all(color: Colors.white.withValues(alpha: 0.1)),
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: card,
                ),
              ),
            )
          : Card(
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
              child: Padding(
                padding: const EdgeInsets.all(6),
                child: card,
              ),
            ),
    );
  }
}
