import 'dart:ui' show ImageFilter;

import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import 'library_page.dart';
import 'library_items_page.dart';
import 'player_screen.dart';
import 'player_screen_exo.dart';
import 'search_page.dart';
import 'settings_page.dart';
import 'services/cover_cache_manager.dart';
import 'services/emby_api.dart';
import 'state/app_state.dart';
import 'state/preferences.dart';
import 'show_detail_page.dart';
import 'src/ui/app_components.dart';
import 'src/ui/glass_blur.dart';
import 'src/ui/theme_sheet.dart';

class HomePage extends StatefulWidget {
  const HomePage({super.key, required this.appState});

  final AppState appState;

  @override
  State<HomePage> createState() => _HomePageState();
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
      MediaQuery.of(context).orientation == Orientation.landscape &&
      MediaQuery.of(context).size.shortestSide >= 720;

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
                                        hintText:
                                            '例如：https://emby.example.com:8920',
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
                        onPressed: widget.appState.isLoading
                            ? null
                            : widget.appState.refreshDomains,
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
                          final name =
                              d.name.trim().isNotEmpty ? d.name.trim() : d.url;
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
                                    final ctrl = TextEditingController(
                                        text: remark ?? '');
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
                                            onPressed: () =>
                                                Navigator.of(dctx).pop(),
                                            child: const Text('取消'),
                                          ),
                                          FilledButton(
                                            onPressed: () => Navigator.of(dctx)
                                                .pop(ctrl.text),
                                            child: const Text('保存'),
                                          ),
                                        ],
                                      ),
                                    );
                                    if (v == null) return;
                                    await widget.appState
                                        .setDomainRemark(d.url, v);
                                  },
                                ),
                                if (selected) const Icon(Icons.check),
                              ],
                            ),
                            onLongPress: !isCustom
                                ? null
                                : () async {
                                    final action =
                                        await showModalBottomSheet<String>(
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
                                              leading: const Icon(
                                                  Icons.edit_outlined),
                                              title: const Text('编辑'),
                                              onTap: () => Navigator.of(bctx)
                                                  .pop('edit'),
                                            ),
                                            ListTile(
                                              leading: const Icon(
                                                  Icons.delete_outline),
                                              title: const Text('删除'),
                                              onTap: () => Navigator.of(bctx)
                                                  .pop('delete'),
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
                                              onPressed: () =>
                                                  Navigator.of(dctx).pop(false),
                                              child: const Text('取消'),
                                            ),
                                            FilledButton(
                                              onPressed: () =>
                                                  Navigator.of(dctx).pop(true),
                                              child: const Text('删除'),
                                            ),
                                          ],
                                        ),
                                      );
                                      if (ok != true) return;
                                      await widget.appState
                                          .removeCustomDomain(d.url);
                                      return;
                                    }

                                    final nameCtrl =
                                        TextEditingController(text: d.name);
                                    final urlCtrl =
                                        TextEditingController(text: d.url);
                                    final remarkCtrl = TextEditingController(
                                        text: remark ?? '');
                                    final result =
                                        await showDialog<Map<String, String>>(
                                      context: context,
                                      builder: (dctx) => AlertDialog(
                                        title: const Text('编辑自定义线路'),
                                        content: SingleChildScrollView(
                                          child: Column(
                                            mainAxisSize: MainAxisSize.min,
                                            children: [
                                              TextField(
                                                controller: nameCtrl,
                                                decoration:
                                                    const InputDecoration(
                                                        labelText: '名称'),
                                              ),
                                              const SizedBox(height: 10),
                                              TextField(
                                                controller: urlCtrl,
                                                decoration:
                                                    const InputDecoration(
                                                        labelText: '地址'),
                                                keyboardType: TextInputType.url,
                                              ),
                                              const SizedBox(height: 10),
                                              TextField(
                                                controller: remarkCtrl,
                                                decoration:
                                                    const InputDecoration(
                                                        labelText: '备注（可选）'),
                                              ),
                                            ],
                                          ),
                                        ),
                                        actions: [
                                          TextButton(
                                            onPressed: () =>
                                                Navigator.of(dctx).pop(),
                                            child: const Text('取消'),
                                          ),
                                          FilledButton(
                                            onPressed: () {
                                              Navigator.of(dctx).pop({
                                                'name': nameCtrl.text.trim(),
                                                'url': urlCtrl.text.trim(),
                                                'remark':
                                                    remarkCtrl.text.trim(),
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
                                        remark: (result['remark'] ?? '')
                                                .trim()
                                                .isEmpty
                                            ? null
                                            : (result['remark'] ?? '').trim(),
                                      );
                                    } catch (e) {
                                      if (!context.mounted) return;
                                      ScaffoldMessenger.of(context)
                                          .showSnackBar(
                                        SnackBar(content: Text(e.toString())),
                                      );
                                    }
                                  },
                            onTap: () async {
                              await widget.appState.setBaseUrl(d.url);
                              // Best-effort: reload content after line switch.
                              // ignore: unawaited_futures
                              widget.appState
                                  .refreshLibraries()
                                  .then((_) => widget.appState.loadHome());
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
    return AnimatedBuilder(
      animation: widget.appState,
      builder: (context, _) {
        final isTv = _isTv(context);
        final isDesktop = !kIsWeb &&
            (defaultTargetPlatform == TargetPlatform.windows ||
                defaultTargetPlatform == TargetPlatform.linux ||
                defaultTargetPlatform == TargetPlatform.macOS);
        final blurAllowed = !isTv;
        final enableBlur = blurAllowed && widget.appState.enableBlurEffects;
        final useExoCore = !kIsWeb &&
            defaultTargetPlatform == TargetPlatform.android &&
            widget.appState.playerCore == PlayerCore.exo;
        final template = widget.appState.uiTemplate;
        final usesGlassSurfaces = template == UiTemplate.candyGlass ||
            template == UiTemplate.stickerJournal ||
            template == UiTemplate.neonHud ||
            template == UiTemplate.washiWatercolor;
        final useRail = isDesktop &&
            (template == UiTemplate.proTool || template == UiTemplate.neonHud);
        final pages = [
          _HomeBody(
            appState: widget.appState,
            loading: _loading,
            onRefresh: _load,
            isTv: isTv,
            showSearchBar: true,
          ),
          useExoCore
              ? ExoPlayerScreen(appState: widget.appState)
              : PlayerScreen(appState: widget.appState),
          SettingsPage(appState: widget.appState),
        ];

        final appBar = _index == 0
            ? AppBar(
                backgroundColor: Colors.transparent,
                surfaceTintColor: Colors.transparent,
                shadowColor: Colors.transparent,
                elevation: 0,
                scrolledUnderElevation: 0,
                shape: const RoundedRectangleBorder(),
                centerTitle: false,
                title: _ServerGlassButton(
                  enableBlur: enableBlur,
                  useGlass: usesGlassSurfaces,
                  serverName: widget.appState.activeServer?.name ?? 'LinPlayer',
                  iconUrl: widget.appState.activeServer?.iconUrl,
                  onTap: widget.appState.hasActiveServer ? _switchServer : null,
                ),
                actions: [
                  _GlassActionIconButton(
                    icon: Icons.search,
                    tooltip: '搜索',
                    enableBlur: enableBlur,
                    useGlass: usesGlassSurfaces,
                    onPressed: () {
                      Navigator.of(context).push(
                        MaterialPageRoute(
                          builder: (_) => SearchPage(appState: widget.appState),
                        ),
                      );
                    },
                  ),
                  _GlassActionIconButton(
                    icon: Icons.video_library_outlined,
                    tooltip: '媒体库',
                    enableBlur: enableBlur,
                    useGlass: usesGlassSurfaces,
                    onPressed: () {
                      Navigator.of(context).push(
                        MaterialPageRoute(
                          builder: (_) =>
                              LibraryPage(appState: widget.appState),
                        ),
                      );
                    },
                  ),
                  _GlassActionIconButton(
                    icon: Icons.alt_route_outlined,
                    tooltip: '线路',
                    enableBlur: enableBlur,
                    useGlass: usesGlassSurfaces,
                    onPressed: _showRoutePicker,
                  ),
                  _GlassActionIconButton(
                    icon: Icons.palette_outlined,
                    tooltip: '主题',
                    enableBlur: enableBlur,
                    useGlass: usesGlassSurfaces,
                    onPressed: _showThemeSheet,
                  ),
                  const SizedBox(width: 4),
                ],
              )
            : null;

        if (useRail) {
          return Scaffold(
            appBar: appBar,
            body: Row(
              children: [
                GlassNavigationBar(
                  enableBlur: enableBlur,
                  child: NavigationRail(
                    selectedIndex: _index,
                    onDestinationSelected: (i) => setState(() => _index = i),
                    labelType: NavigationRailLabelType.all,
                    destinations: const [
                      NavigationRailDestination(
                        icon: Icon(Icons.home_outlined),
                        label: Text('首页'),
                      ),
                      NavigationRailDestination(
                        icon: Icon(Icons.folder_open),
                        label: Text('本地'),
                      ),
                      NavigationRailDestination(
                        icon: Icon(Icons.settings_outlined),
                        label: Text('设置'),
                      ),
                    ],
                  ),
                ),
                const VerticalDivider(width: 1),
                Expanded(child: pages[_index]),
              ],
            ),
          );
        }
        return Scaffold(
          extendBody: _index == 0,
          appBar: appBar,
          body: pages[_index],
          bottomNavigationBar: isTv
              ? NavigationBar(
                  backgroundColor: Colors.transparent,
                  surfaceTintColor: Colors.transparent,
                  shadowColor: Colors.transparent,
                  elevation: 0,
                  selectedIndex: _index,
                  onDestinationSelected: (i) => setState(() => _index = i),
                  destinations: const [
                    NavigationDestination(
                        icon: Icon(Icons.home_outlined), label: '首页'),
                    NavigationDestination(
                        icon: Icon(Icons.folder_open), label: '本地'),
                    NavigationDestination(
                        icon: Icon(Icons.settings_outlined), label: '设置'),
                  ],
                )
              : _FloatingBottomNav(
                  selectedIndex: _index,
                  onSelected: (i) => setState(() => _index = i),
                  enableBlur: enableBlur,
                  template: template,
                ),
        );
      },
    );
  }
}

class _GlassActionIconButton extends StatelessWidget {
  const _GlassActionIconButton({
    required this.icon,
    required this.tooltip,
    required this.enableBlur,
    required this.useGlass,
    required this.onPressed,
  });

  final IconData icon;
  final String tooltip;
  final bool enableBlur;
  final bool useGlass;
  final VoidCallback? onPressed;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final isDark = scheme.brightness == Brightness.dark;
    final enabled = onPressed != null;

    final bg =
        scheme.surfaceContainerHigh.withValues(alpha: isDark ? 0.72 : 0.92);
    final fg =
        enabled ? scheme.onSurface : scheme.onSurface.withValues(alpha: 0.38);
    final shadowColor = scheme.shadow.withValues(alpha: isDark ? 0.30 : 0.16);

    Widget child = Material(
      color: bg,
      shape: const CircleBorder(),
      elevation: enabled ? 8 : 0,
      shadowColor: shadowColor,
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        customBorder: const CircleBorder(),
        onTap: onPressed,
        child: Center(child: Icon(icon, color: fg, size: 20)),
      ),
    );

    if (useGlass && enableBlur) {
      child = ClipOval(
        child: BackdropFilter(
          filter: ImageFilter.blur(sigmaX: 18, sigmaY: 18),
          child: child,
        ),
      );
    }

    return Semantics(
      button: true,
      enabled: enabled,
      label: tooltip,
      child: Tooltip(
        message: tooltip,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 4),
          child: SizedBox(width: 40, height: 40, child: child),
        ),
      ),
    );
  }
}

class _ServerGlassButton extends StatelessWidget {
  const _ServerGlassButton({
    required this.serverName,
    required this.iconUrl,
    required this.onTap,
    required this.enableBlur,
    required this.useGlass,
  });

  final String serverName;
  final String? iconUrl;
  final VoidCallback? onTap;
  final bool enableBlur;
  final bool useGlass;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final isDark = scheme.brightness == Brightness.dark;
    final enabled = onTap != null;

    final bg =
        scheme.surfaceContainerHigh.withValues(alpha: isDark ? 0.74 : 0.94);
    final fg =
        enabled ? scheme.onSurface : scheme.onSurface.withValues(alpha: 0.38);
    final shadowColor = scheme.shadow.withValues(alpha: isDark ? 0.30 : 0.16);
    final radius = BorderRadius.circular(999);

    Widget child = Material(
      color: bg,
      shape: const StadiumBorder(),
      elevation: enabled ? 10 : 0,
      shadowColor: shadowColor,
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        customBorder: const StadiumBorder(),
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 7),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              _ServerIconAvatar(iconUrl: iconUrl, name: serverName, radius: 12),
              const SizedBox(width: 8),
              Flexible(
                child: Text(
                  serverName,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.titleSmall?.copyWith(
                    fontWeight: FontWeight.w700,
                    color: fg,
                  ),
                ),
              ),
              const SizedBox(width: 4),
              Icon(Icons.swap_horiz, size: 18, color: fg),
            ],
          ),
        ),
      ),
    );

    if (useGlass && enableBlur) {
      child = ClipRRect(
        borderRadius: radius,
        child: BackdropFilter(
          filter: ImageFilter.blur(sigmaX: 18, sigmaY: 18),
          child: child,
        ),
      );
    }

    return Semantics(
      button: true,
      enabled: enabled,
      label: '服务器',
      child: Tooltip(
        message: '服务器',
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 220),
          child: child,
        ),
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

class _FloatingBottomNav extends StatelessWidget {
  const _FloatingBottomNav({
    required this.selectedIndex,
    required this.onSelected,
    required this.enableBlur,
    required this.template,
  });

  final int selectedIndex;
  final ValueChanged<int> onSelected;
  final bool enableBlur;
  final UiTemplate template;

  bool get _usesGlassSurfaces =>
      template == UiTemplate.candyGlass ||
      template == UiTemplate.stickerJournal ||
      template == UiTemplate.neonHud ||
      template == UiTemplate.washiWatercolor;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final isDark = scheme.brightness == Brightness.dark;

    Widget buildButton({
      required int index,
      required IconData icon,
      required String tooltip,
    }) {
      final selected = index == selectedIndex;
      final bg = selected
          ? scheme.primary.withValues(alpha: isDark ? 0.90 : 0.96)
          : scheme.surfaceContainerHigh.withValues(alpha: isDark ? 0.78 : 0.92);
      final fg = selected ? scheme.onPrimary : scheme.onSurfaceVariant;
      final elevation = selected ? 10.0 : 5.0;
      final shadowColor = scheme.shadow.withValues(alpha: isDark ? 0.32 : 0.18);

      Widget child = Material(
        color: bg,
        shape: const CircleBorder(),
        elevation: elevation,
        shadowColor: shadowColor,
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          customBorder: const CircleBorder(),
          onTap: () => onSelected(index),
          child: Center(child: Icon(icon, color: fg, size: 22)),
        ),
      );

      if (_usesGlassSurfaces && enableBlur) {
        child = ClipOval(
          child: BackdropFilter(
            filter: ImageFilter.blur(sigmaX: 18, sigmaY: 18),
            child: child,
          ),
        );
      }

      return Semantics(
        button: true,
        selected: selected,
        label: tooltip,
        child: Tooltip(
          message: tooltip,
          child: SizedBox(width: 44, height: 44, child: child),
        ),
      );
    }

    return SafeArea(
      top: false,
      left: false,
      right: false,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 12),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            buildButton(index: 0, icon: Icons.home_outlined, tooltip: '首页'),
            const SizedBox(width: 14),
            buildButton(index: 1, icon: Icons.folder_open, tooltip: '本地'),
            const SizedBox(width: 14),
            buildButton(index: 2, icon: Icons.settings_outlined, tooltip: '设置'),
          ],
        ),
      ),
    );
  }
}

class _HomeBody extends StatelessWidget {
  const _HomeBody({
    required this.appState,
    required this.loading,
    required this.onRefresh,
    required this.isTv,
    required this.showSearchBar,
  });

  final AppState appState;
  final bool loading;
  final Future<void> Function() onRefresh;
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

    final bottomPadding = isTv ? 90.0 : 120.0;

    return Column(
      children: [
        if (showSearchBar) ...[
          const SizedBox(height: 8),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 14),
            child: TextField(
              readOnly: true,
              showCursor: false,
              enableInteractiveSelection: false,
              decoration: const InputDecoration(
                hintText: '搜索片名…',
                prefixIcon: Icon(Icons.search),
              ),
              onTap: () {
                Navigator.of(context).push(
                  MaterialPageRoute(
                    builder: (_) => SearchPage(appState: appState),
                  ),
                );
              },
            ),
          ),
          const SizedBox(height: 8),
        ],
        Expanded(
          child: RefreshIndicator(
            onRefresh: onRefresh,
            child: ListView(
              padding: EdgeInsets.only(bottom: bottomPadding),
              children: [
                const SizedBox(height: 8),
                _RandomRecommendSection(appState: appState, isTv: isTv),
                _ContinueWatchingSection(appState: appState, isTv: isTv),
                if (appState.showHomeLibraryQuickAccess)
                  _LibraryQuickAccessSection(appState: appState, isTv: isTv),
                if (loading) const LinearProgressIndicator(),
                for (final sec in sections)
                  if (sec.items.isNotEmpty) ...[
                    _HomeSectionHeader(
                      template: appState.uiTemplate,
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
                      isTv: isTv,
                    ),
                  ] else
                    const SizedBox.shrink(),
                if (sections.every((e) => e.items.isEmpty) && !loading)
                  const Padding(
                    padding: EdgeInsets.all(24),
                    child: Center(child: Text('暂无可展示内容')),
                  ),
              ],
            ),
          ),
        ),
      ],
    );
  }
}

class _RandomRecommendSection extends StatefulWidget {
  const _RandomRecommendSection({required this.appState, required this.isTv});

  final AppState appState;
  final bool isTv;

  @override
  State<_RandomRecommendSection> createState() =>
      _RandomRecommendSectionState();
}

class _ContinueWatchingSection extends StatefulWidget {
  const _ContinueWatchingSection({
    required this.appState,
    required this.isTv,
  });

  final AppState appState;
  final bool isTv;

  @override
  State<_ContinueWatchingSection> createState() =>
      _ContinueWatchingSectionState();
}

class _ContinueWatchingSectionState extends State<_ContinueWatchingSection> {
  Future<List<MediaItem>>? _future;
  final ScrollController _controller = ScrollController();

  @override
  void initState() {
    super.initState();
    _future = _fetch();
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  Future<List<MediaItem>> _fetch({bool forceRefresh = false}) {
    return widget.appState.loadContinueWatching(forceRefresh: forceRefresh);
  }

  void _reload() {
    setState(() => _future = _fetch(forceRefresh: true));
  }

  Duration _ticksToDuration(int ticks) =>
      Duration(microseconds: (ticks / 10).round());

  String _fmt(Duration d) {
    final h = d.inHours;
    final m = d.inMinutes.remainder(60);
    final s = d.inSeconds.remainder(60);
    if (h > 0) {
      return '${h.toString().padLeft(2, '0')}:${m.toString().padLeft(2, '0')}:${s.toString().padLeft(2, '0')}';
    }
    return '${m.toString().padLeft(2, '0')}:${s.toString().padLeft(2, '0')}';
  }

  String _episodeTag(MediaItem item) {
    final s = item.seasonNumber ?? 0;
    final e = item.episodeNumber ?? 0;
    if (s <= 0 && e <= 0) return '';
    if (s > 0 && e > 0) {
      return 'S${s.toString().padLeft(2, '0')}E${e.toString().padLeft(2, '0')}';
    }
    if (e > 0) return 'E${e.toString().padLeft(2, '0')}';
    return 'S${s.toString().padLeft(2, '0')}';
  }

  bool get _showDesktopArrows {
    if (widget.isTv) return false;
    if (kIsWeb) return false;
    final platform = defaultTargetPlatform;
    return platform == TargetPlatform.windows ||
        platform == TargetPlatform.macOS ||
        platform == TargetPlatform.linux;
  }

  void _scrollBy(double delta) {
    if (!_controller.hasClients) return;
    final max = _controller.position.maxScrollExtent;
    final target = (_controller.offset + delta).clamp(0.0, max);
    _controller.animateTo(
      target,
      duration: const Duration(milliseconds: 220),
      curve: Curves.easeOutCubic,
    );
  }

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<List<MediaItem>>(
      future: _future,
      builder: (context, snap) {
        final items = snap.data ?? const <MediaItem>[];
        final loading = snap.connectionState == ConnectionState.waiting;
        final theme = Theme.of(context);

        if (!loading && snap.hasError && items.isEmpty) {
          return Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: Row(
              children: [
                Expanded(
                  child: Text(
                    '继续观看加载失败',
                    style: theme.textTheme.bodyMedium?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                  ),
                ),
                TextButton.icon(
                  onPressed: _reload,
                  icon: const Icon(Icons.refresh),
                  label: const Text('重试'),
                ),
              ],
            ),
          );
        }

        if (loading && items.isEmpty) {
          return Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 6),
            child: Row(
              children: [
                Expanded(
                  child: Text(
                    '继续观看',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.titleMedium,
                  ),
                ),
                const SizedBox(width: 8),
                const SizedBox(
                  width: 16,
                  height: 16,
                  child: CircularProgressIndicator(strokeWidth: 2),
                ),
              ],
            ),
          );
        }

        if (items.isEmpty) return const SizedBox.shrink();

        return LayoutBuilder(
          builder: (context, constraints) {
            const padding = 14.0;
            const spacing = 10.0;
            final visible = (constraints.maxWidth / 280).clamp(1.4, 4.5);
            final maxCount = items.length < 12 ? items.length : 12;

            final itemWidth =
                (constraints.maxWidth - padding * 2 - spacing * (visible - 1)) /
                    visible;
            final imageHeight = itemWidth * 9 / 16;
            final listHeight = imageHeight + 46;
            final totalContentWidth =
                maxCount * itemWidth + (maxCount - 1) * spacing;
            final viewportWidth = constraints.maxWidth - padding * 2;
            final canScroll = totalContentWidth > viewportWidth + 0.5;
            final scrollStep = itemWidth + spacing;

            return Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 8, 16, 6),
                  child: Row(
                    children: [
                      Expanded(
                        child: Text(
                          '继续观看',
                          style: theme.textTheme.titleMedium,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                      IconButton(
                        tooltip: '刷新',
                        onPressed: loading ? null : _reload,
                        icon: const Icon(Icons.refresh),
                      ),
                    ],
                  ),
                ),
                SizedBox(
                  height: listHeight,
                  child: Stack(
                    children: [
                      ListView.separated(
                        controller: _controller,
                        cacheExtent: 0,
                        padding: const EdgeInsets.symmetric(
                          horizontal: padding,
                        ),
                        scrollDirection: Axis.horizontal,
                        itemCount: maxCount,
                        separatorBuilder: (_, __) =>
                            const SizedBox(width: spacing),
                        itemBuilder: (context, index) {
                          final item = items[index];
                          final isEpisode =
                              item.type.toLowerCase() == 'episode';
                          final title = isEpisode && item.seriesName.isNotEmpty
                              ? item.seriesName
                              : item.name;
                          final pos =
                              _ticksToDuration(item.playbackPositionTicks);
                          final tag = isEpisode ? _episodeTag(item) : '';
                          final sub = [
                            if (tag.isNotEmpty) tag,
                            if (pos > Duration.zero) '观看到 ${_fmt(pos)}',
                          ].join(' · ');

                          final img = item.hasImage
                              ? EmbyApi.imageUrl(
                                  baseUrl: widget.appState.baseUrl!,
                                  itemId: item.id,
                                  token: widget.appState.token!,
                                  imageType: 'Primary',
                                  maxWidth: 640,
                                )
                              : null;

                          return SizedBox(
                            width: itemWidth,
                            child: InkWell(
                              borderRadius: BorderRadius.circular(12),
                              onTap: () {
                                Navigator.of(context).push(
                                  MaterialPageRoute(
                                    builder: (_) => isEpisode
                                        ? EpisodeDetailPage(
                                            episode: item,
                                            appState: widget.appState,
                                            isTv: widget.isTv,
                                          )
                                        : ShowDetailPage(
                                            itemId: item.id,
                                            title: item.name,
                                            appState: widget.appState,
                                            isTv: widget.isTv,
                                          ),
                                  ),
                                );
                              },
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  AspectRatio(
                                    aspectRatio: 16 / 9,
                                    child: ClipRRect(
                                      borderRadius: BorderRadius.circular(12),
                                      child: img != null
                                          ? CachedNetworkImage(
                                              imageUrl: img,
                                              cacheManager:
                                                  CoverCacheManager.instance,
                                              httpHeaders: {
                                                'User-Agent': EmbyApi.userAgent
                                              },
                                              fit: BoxFit.cover,
                                              placeholder: (_, __) =>
                                                  const ColoredBox(
                                                color: Colors.black12,
                                                child: Center(
                                                    child: Icon(Icons.image)),
                                              ),
                                              errorWidget: (_, __, ___) =>
                                                  const ColoredBox(
                                                color: Colors.black12,
                                                child: Center(
                                                    child: Icon(
                                                        Icons.broken_image)),
                                              ),
                                            )
                                          : const ColoredBox(
                                              color: Colors.black12,
                                              child: Center(
                                                  child: Icon(Icons.image)),
                                            ),
                                    ),
                                  ),
                                  const SizedBox(height: 6),
                                  Text(
                                    title,
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                    style: theme.textTheme.bodyMedium?.copyWith(
                                      fontWeight: FontWeight.w700,
                                    ),
                                  ),
                                  if (sub.isNotEmpty)
                                    Padding(
                                      padding: const EdgeInsets.only(top: 2),
                                      child: Text(
                                        sub,
                                        maxLines: 1,
                                        overflow: TextOverflow.ellipsis,
                                        style: theme.textTheme.labelSmall
                                            ?.copyWith(
                                          color: theme
                                              .colorScheme.onSurfaceVariant,
                                          fontWeight: FontWeight.w600,
                                        ),
                                      ),
                                    ),
                                ],
                              ),
                            ),
                          );
                        },
                      ),
                      if (_showDesktopArrows && canScroll) ...[
                        Positioned(
                          left: 2,
                          top: 0,
                          bottom: 0,
                          child: Center(
                            child: Material(
                              color: Colors.transparent,
                              child: IconButton(
                                tooltip: '向左',
                                onPressed: () => _scrollBy(-scrollStep),
                                icon: const Icon(Icons.chevron_left),
                              ),
                            ),
                          ),
                        ),
                        Positioned(
                          right: 2,
                          top: 0,
                          bottom: 0,
                          child: Center(
                            child: Material(
                              color: Colors.transparent,
                              child: IconButton(
                                tooltip: '向右',
                                onPressed: () => _scrollBy(scrollStep),
                                icon: const Icon(Icons.chevron_right),
                              ),
                            ),
                          ),
                        ),
                      ],
                    ],
                  ),
                ),
              ],
            );
          },
        );
      },
    );
  }
}

class _LibraryQuickAccessSection extends StatefulWidget {
  const _LibraryQuickAccessSection(
      {required this.appState, required this.isTv});

  final AppState appState;
  final bool isTv;

  @override
  State<_LibraryQuickAccessSection> createState() =>
      _LibraryQuickAccessSectionState();
}

class _LibraryQuickAccessSectionState
    extends State<_LibraryQuickAccessSection> {
  final ScrollController _controller = ScrollController();

  bool get _showDesktopArrows {
    if (widget.isTv) return false;
    if (kIsWeb) return false;
    final platform = defaultTargetPlatform;
    return platform == TargetPlatform.windows ||
        platform == TargetPlatform.macOS ||
        platform == TargetPlatform.linux;
  }

  void _scrollBy(double delta) {
    if (!_controller.hasClients) return;
    final max = _controller.position.maxScrollExtent;
    final target = (_controller.offset + delta).clamp(0.0, max);
    _controller.animateTo(
      target,
      duration: const Duration(milliseconds: 220),
      curve: Curves.easeOutCubic,
    );
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final baseUrl = widget.appState.baseUrl;
    final token = widget.appState.token;
    if (baseUrl == null || token == null) return const SizedBox.shrink();

    final libs = widget.appState.libraries
        .where((l) => !widget.appState.isLibraryHidden(l.id))
        .toList(growable: false);
    if (libs.isEmpty) return const SizedBox.shrink();

    return LayoutBuilder(
      builder: (context, constraints) {
        const padding = 14.0;
        const spacing = 10.0;
        final visible = (constraints.maxWidth / 240).clamp(1.8, 6.0);
        final itemWidth =
            (constraints.maxWidth - padding * 2 - spacing * (visible - 1)) /
                visible;
        final imageHeight = itemWidth * 9 / 16;
        final listHeight = imageHeight + 44;
        final totalContentWidth =
            libs.length * itemWidth + (libs.length - 1) * spacing;
        final viewportWidth = constraints.maxWidth - padding * 2;
        final canScroll = totalContentWidth > viewportWidth + 0.5;
        final scrollStep = itemWidth + spacing;

        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _HomeSectionHeader(
              template: widget.appState.uiTemplate,
              title: '媒体库',
              count: 0,
              onTap: () {
                Navigator.of(context).push(
                  MaterialPageRoute(
                    builder: (_) => LibraryPage(appState: widget.appState),
                  ),
                );
              },
            ),
            SizedBox(
              height: listHeight,
              child: Stack(
                children: [
                  ListView.separated(
                    controller: _controller,
                    cacheExtent: 0,
                    padding: const EdgeInsets.symmetric(horizontal: padding),
                    scrollDirection: Axis.horizontal,
                    itemCount: libs.length,
                    separatorBuilder: (_, __) => const SizedBox(width: spacing),
                    itemBuilder: (context, index) {
                      final lib = libs[index];
                      final imageUrl = EmbyApi.imageUrl(
                        baseUrl: baseUrl,
                        itemId: lib.id,
                        token: token,
                        maxWidth: 640,
                      );
                      return SizedBox(
                        width: itemWidth,
                        child: MediaBackdropTile(
                          title: lib.name,
                          imageUrl: imageUrl,
                          onTap: () {
                            Navigator.of(context).push(
                              MaterialPageRoute(
                                builder: (_) => LibraryItemsPage(
                                  appState: widget.appState,
                                  parentId: lib.id,
                                  title: lib.name,
                                  isTv: widget.isTv,
                                ),
                              ),
                            );
                          },
                        ),
                      );
                    },
                  ),
                  if (_showDesktopArrows && canScroll) ...[
                    Positioned(
                      left: 2,
                      top: 0,
                      bottom: 0,
                      child: Center(
                        child: Material(
                          color: Colors.transparent,
                          child: IconButton(
                            tooltip: '向左',
                            onPressed: () => _scrollBy(-scrollStep),
                            icon: const Icon(Icons.chevron_left),
                          ),
                        ),
                      ),
                    ),
                    Positioned(
                      right: 2,
                      top: 0,
                      bottom: 0,
                      child: Center(
                        child: Material(
                          color: Colors.transparent,
                          child: IconButton(
                            tooltip: '向右',
                            onPressed: () => _scrollBy(scrollStep),
                            icon: const Icon(Icons.chevron_right),
                          ),
                        ),
                      ),
                    ),
                  ],
                ],
              ),
            ),
          ],
        );
      },
    );
  }
}

class _RandomRecommendSectionState extends State<_RandomRecommendSection> {
  final PageController _controller = PageController();
  Future<List<MediaItem>>? _future;
  int _page = 0;
  Set<String> _lastImageUrls = <String>{};

  @override
  void initState() {
    super.initState();
    _future = _fetch();
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  Future<List<MediaItem>> _fetch({bool forceRefresh = false}) async {
    final baseUrl = widget.appState.baseUrl;
    final token = widget.appState.token;
    final userId = widget.appState.userId;
    if (baseUrl == null || token == null || userId == null) return const [];

    final picked = await widget.appState.loadRandomRecommendations(
      forceRefresh: forceRefresh,
    );

    // Pre-cache banner images to avoid reloading when swiping back & forth.
    final urls = <String>{};
    for (final item in picked) {
      urls.add(
        EmbyApi.imageUrl(
          baseUrl: baseUrl,
          itemId: item.id,
          token: token,
          imageType: 'Backdrop',
          maxWidth: 1280,
        ),
      );
      urls.add(
        EmbyApi.imageUrl(
          baseUrl: baseUrl,
          itemId: item.id,
          token: token,
          imageType: 'Primary',
          maxWidth: 720,
        ),
      );
    }
    _lastImageUrls = urls;
    if (!mounted) return picked;
    for (final url in urls) {
      // ignore: unawaited_futures
      precacheImage(
        CachedNetworkImageProvider(
          url,
          cacheManager: CoverCacheManager.instance,
          headers: {'User-Agent': EmbyApi.userAgent},
        ),
        context,
      );
    }

    return picked;
  }

  void _reload() {
    for (final url in _lastImageUrls) {
      // ignore: unawaited_futures
      CoverCacheManager.instance.removeFile(url);
      PaintingBinding.instance.imageCache.evict(
        CachedNetworkImageProvider(
          url,
          cacheManager: CoverCacheManager.instance,
          headers: {'User-Agent': EmbyApi.userAgent},
        ),
      );
    }
    _lastImageUrls = <String>{};
    setState(() {
      _page = 0;
      _future = _fetch(forceRefresh: true);
    });
    if (_controller.hasClients) _controller.jumpToPage(0);
  }

  String _yearOf(MediaItem item) {
    final d = (item.premiereDate ?? '').trim();
    if (d.isEmpty) return '';
    final parsed = DateTime.tryParse(d);
    if (parsed != null) return parsed.year.toString();
    return d.length >= 4 ? d.substring(0, 4) : '';
  }

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<List<MediaItem>>(
      future: _future,
      builder: (context, snap) {
        final items = snap.data ?? const <MediaItem>[];
        final loading = snap.connectionState == ConnectionState.waiting;
        final theme = Theme.of(context);
        final isDesktop = kIsWeb ||
            defaultTargetPlatform == TargetPlatform.windows ||
            defaultTargetPlatform == TargetPlatform.linux ||
            defaultTargetPlatform == TargetPlatform.macOS;
        const bannerAspectRatio = 32 / 9;

        if (!loading && snap.hasError && items.isEmpty) {
          return Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: Row(
              children: [
                Expanded(
                  child: Text(
                    '随机推荐加载失败',
                    style: theme.textTheme.bodyMedium?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                  ),
                ),
                TextButton.icon(
                  onPressed: _reload,
                  icon: const Icon(Icons.refresh),
                  label: const Text('重试'),
                ),
              ],
            ),
          );
        }

        // Keep a lightweight placeholder so the top of the page doesn't jump.
        if (loading && items.isEmpty) {
          return Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: AspectRatio(
              aspectRatio: bannerAspectRatio,
              child: ClipRRect(
                borderRadius: BorderRadius.circular(16),
                child: ColoredBox(
                  color: theme.colorScheme.surfaceContainerHighest,
                  child: const Center(
                    child: CircularProgressIndicator(strokeWidth: 2),
                  ),
                ),
              ),
            ),
          );
        }

        if (items.isEmpty) return const SizedBox.shrink();

        final baseUrl = widget.appState.baseUrl!;
        final token = widget.appState.token!;

        Widget bannerImage(MediaItem item) {
          final backdrop = EmbyApi.imageUrl(
            baseUrl: baseUrl,
            itemId: item.id,
            token: token,
            imageType: 'Backdrop',
            maxWidth: 1280,
          );
          final primary = EmbyApi.imageUrl(
            baseUrl: baseUrl,
            itemId: item.id,
            token: token,
            imageType: 'Primary',
            maxWidth: 720,
          );

          Widget placeholder() => const ColoredBox(
                color: Colors.black12,
                child: Center(
                  child: CircularProgressIndicator(strokeWidth: 2),
                ),
              );

          Widget broken() =>
              const ColoredBox(color: Colors.black12, child: Icon(Icons.image));

          return CachedNetworkImage(
            imageUrl: backdrop,
            cacheManager: CoverCacheManager.instance,
            httpHeaders: {'User-Agent': EmbyApi.userAgent},
            fit: BoxFit.cover,
            placeholder: (_, __) => placeholder(),
            errorWidget: (_, __, ___) => CachedNetworkImage(
              imageUrl: primary,
              cacheManager: CoverCacheManager.instance,
              httpHeaders: {'User-Agent': EmbyApi.userAgent},
              fit: BoxFit.cover,
              placeholder: (_, __) => placeholder(),
              errorWidget: (_, __, ___) => broken(),
            ),
          );
        }

        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 6),
              child: Row(
                children: [
                  Expanded(
                    child: Text(
                      '随机推荐',
                      style: theme.textTheme.titleMedium,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                  IconButton(
                    tooltip: '换一换',
                    onPressed: loading ? null : _reload,
                    icon: const Icon(Icons.refresh),
                  ),
                ],
              ),
            ),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: AspectRatio(
                aspectRatio: bannerAspectRatio,
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(16),
                  child: Stack(
                    fit: StackFit.expand,
                    children: [
                      PageView.builder(
                        controller: _controller,
                        itemCount: items.length,
                        onPageChanged: (i) => setState(() => _page = i),
                        itemBuilder: (context, index) {
                          final item = items[index];
                          final year = _yearOf(item);
                          final rating = item.communityRating;

                          return Material(
                            color: Colors.transparent,
                            child: InkWell(
                              onTap: () {
                                Navigator.of(context).push(
                                  MaterialPageRoute(
                                    builder: (_) => ShowDetailPage(
                                      itemId: item.id,
                                      title: item.name,
                                      appState: widget.appState,
                                      isTv: widget.isTv,
                                    ),
                                  ),
                                );
                              },
                              child: Stack(
                                fit: StackFit.expand,
                                children: [
                                  bannerImage(item),
                                  const DecoratedBox(
                                    decoration: BoxDecoration(
                                      gradient: LinearGradient(
                                        begin: Alignment.bottomCenter,
                                        end: Alignment.center,
                                        colors: [
                                          Color(0xCC000000),
                                          Color(0x33000000),
                                          Colors.transparent,
                                        ],
                                      ),
                                    ),
                                  ),
                                  Positioned(
                                    left: 12,
                                    right: 12,
                                    bottom: 10,
                                    child: Column(
                                      crossAxisAlignment:
                                          CrossAxisAlignment.start,
                                      children: [
                                        Text(
                                          item.name,
                                          maxLines: 1,
                                          overflow: TextOverflow.ellipsis,
                                          style: theme.textTheme.titleSmall
                                              ?.copyWith(
                                            color: Colors.white,
                                            fontWeight: FontWeight.w700,
                                          ),
                                        ),
                                        const SizedBox(height: 3),
                                        DefaultTextStyle(
                                          style: theme.textTheme.labelMedium
                                                  ?.copyWith(
                                                color: Colors.white70,
                                              ) ??
                                              const TextStyle(
                                                  color: Colors.white70),
                                          child: Row(
                                            children: [
                                              if (rating != null) ...[
                                                const Icon(
                                                  Icons.star,
                                                  size: 14,
                                                  color: Colors.amber,
                                                ),
                                                const SizedBox(width: 3),
                                                Text(rating.toStringAsFixed(1)),
                                              ],
                                              if (year.isNotEmpty) ...[
                                                if (rating != null)
                                                  const SizedBox(width: 10),
                                                Text(year),
                                              ],
                                            ],
                                          ),
                                        ),
                                      ],
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          );
                        },
                      ),
                      if (isDesktop && items.length > 1) ...[
                        Positioned(
                          left: 6,
                          top: 0,
                          bottom: 0,
                          child: Center(
                            child: _BannerNavButton(
                              icon: Icons.chevron_left,
                              tooltip: '上一个',
                              onPressed: () {
                                if (items.isEmpty) return;
                                final target =
                                    _page <= 0 ? items.length - 1 : _page - 1;
                                _controller.animateToPage(
                                  target,
                                  duration: const Duration(milliseconds: 220),
                                  curve: Curves.easeOutCubic,
                                );
                              },
                            ),
                          ),
                        ),
                        Positioned(
                          right: 6,
                          top: 0,
                          bottom: 0,
                          child: Center(
                            child: _BannerNavButton(
                              icon: Icons.chevron_right,
                              tooltip: '下一个',
                              onPressed: () {
                                if (items.isEmpty) return;
                                final target = (_page + 1) % items.length;
                                _controller.animateToPage(
                                  target,
                                  duration: const Duration(milliseconds: 220),
                                  curve: Curves.easeOutCubic,
                                );
                              },
                            ),
                          ),
                        ),
                      ],
                    ],
                  ),
                ),
              ),
            ),
            const SizedBox(height: 6),
            Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: List.generate(items.length, (i) {
                final selected = i == _page;
                final color = selected
                    ? theme.colorScheme.primary
                    : theme.colorScheme.onSurfaceVariant.withValues(alpha: 0.5);
                return AnimatedContainer(
                  duration: const Duration(milliseconds: 180),
                  margin: const EdgeInsets.symmetric(horizontal: 2.5),
                  width: selected ? 12 : 5,
                  height: 5,
                  decoration: BoxDecoration(
                    color: color,
                    borderRadius: BorderRadius.circular(999),
                  ),
                );
              }),
            ),
            const SizedBox(height: 4),
          ],
        );
      },
    );
  }
}

class _BannerNavButton extends StatelessWidget {
  const _BannerNavButton({
    required this.icon,
    required this.tooltip,
    required this.onPressed,
  });

  final IconData icon;
  final String tooltip;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Colors.black38,
      shape: const CircleBorder(),
      clipBehavior: Clip.antiAlias,
      child: IconButton(
        tooltip: tooltip,
        onPressed: onPressed,
        icon: Icon(icon, color: Colors.white),
      ),
    );
  }
}

class _HomeSectionHeader extends StatelessWidget {
  const _HomeSectionHeader({
    required this.template,
    required this.title,
    required this.count,
    required this.onTap,
  });

  final UiTemplate template;
  final String title;
  final int count;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final isDark = scheme.brightness == Brightness.dark;

    String formatCount(int n) => n
        .toString()
        .replaceAllMapped(RegExp(r'(\\d)(?=(\\d{3})+$)'), (m) => '${m[1]},');

    final borderRadius = BorderRadius.circular(
      switch (template) {
        UiTemplate.pixelArcade => 10,
        UiTemplate.neonHud => 12,
        UiTemplate.mangaStoryboard => 12,
        UiTemplate.stickerJournal => 16,
        _ => 12,
      },
    );

    final titleStyle = theme.textTheme.titleMedium?.copyWith(
      fontWeight: switch (template) {
        UiTemplate.neonHud => FontWeight.w800,
        UiTemplate.mangaStoryboard => FontWeight.w800,
        _ => FontWeight.w700,
      },
      letterSpacing: template == UiTemplate.neonHud ? 0.25 : null,
    );

    Widget? leading = switch (template) {
      UiTemplate.candyGlass => Container(
          width: 10,
          height: 18,
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(8),
            gradient: LinearGradient(
              begin: Alignment.topCenter,
              end: Alignment.bottomCenter,
              colors: [
                scheme.primary.withValues(alpha: isDark ? 0.95 : 1.0),
                scheme.secondary.withValues(alpha: isDark ? 0.85 : 0.95),
              ],
            ),
          ),
        ),
      UiTemplate.stickerJournal => Icon(
          Icons.local_offer_outlined,
          size: 18,
          color: scheme.secondary.withValues(alpha: isDark ? 0.9 : 1.0),
        ),
      UiTemplate.neonHud => Container(
          width: 14,
          height: 14,
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(3),
            border: Border.all(
              color: scheme.primary.withValues(alpha: isDark ? 0.8 : 0.95),
              width: 1.4,
            ),
          ),
        ),
      UiTemplate.pixelArcade => Container(
          width: 14,
          height: 14,
          decoration: BoxDecoration(
            color: scheme.secondary.withValues(alpha: isDark ? 0.55 : 0.75),
            borderRadius: BorderRadius.circular(3),
            border: Border.all(
              color: scheme.secondary.withValues(alpha: isDark ? 0.85 : 0.95),
              width: 1.4,
            ),
          ),
        ),
      UiTemplate.mangaStoryboard => Container(
          width: 6,
          height: 18,
          decoration: BoxDecoration(
            color: scheme.onSurface.withValues(alpha: isDark ? 0.55 : 0.85),
            borderRadius: BorderRadius.circular(3),
          ),
        ),
      UiTemplate.washiWatercolor => Container(
          width: 10,
          height: 18,
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(8),
            gradient: LinearGradient(
              begin: Alignment.topCenter,
              end: Alignment.bottomCenter,
              colors: [
                scheme.tertiary.withValues(alpha: isDark ? 0.7 : 0.85),
                scheme.primary.withValues(alpha: isDark ? 0.6 : 0.75),
              ],
            ),
          ),
        ),
      _ => null,
    };

    Widget countWidget;
    if (count <= 0) {
      countWidget = const SizedBox.shrink();
    } else {
      final text = formatCount(count);
      countWidget = switch (template) {
        UiTemplate.stickerJournal => Container(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
            decoration: BoxDecoration(
              color: scheme.secondaryContainer
                  .withValues(alpha: isDark ? 0.55 : 0.8),
              borderRadius: BorderRadius.circular(14),
              border: Border.all(
                color: scheme.secondary.withValues(alpha: isDark ? 0.35 : 0.55),
              ),
            ),
            child: Text(
              text,
              style: theme.textTheme.labelLarge?.copyWith(
                fontWeight: FontWeight.w800,
                color: scheme.onSecondaryContainer,
              ),
            ),
          ),
        UiTemplate.neonHud => Container(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
            decoration: BoxDecoration(
              color: scheme.surface.withValues(alpha: isDark ? 0.35 : 0.55),
              borderRadius: BorderRadius.circular(12),
              border: Border.all(
                color: scheme.primary.withValues(alpha: isDark ? 0.65 : 0.8),
                width: 1.1,
              ),
            ),
            child: Text(
              text,
              style: theme.textTheme.labelLarge?.copyWith(
                fontWeight: FontWeight.w800,
                letterSpacing: 0.25,
              ),
            ),
          ),
        UiTemplate.pixelArcade => Container(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
            decoration: BoxDecoration(
              color: scheme.surface.withValues(alpha: isDark ? 0.5 : 0.7),
              borderRadius: BorderRadius.circular(10),
              border: Border.all(
                color: scheme.secondary.withValues(alpha: isDark ? 0.65 : 0.8),
                width: 1.4,
              ),
            ),
            child: Text(
              text,
              style: theme.textTheme.labelLarge?.copyWith(
                fontWeight: FontWeight.w900,
              ),
            ),
          ),
        UiTemplate.mangaStoryboard => Container(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
            decoration: BoxDecoration(
              color: scheme.surface.withValues(alpha: isDark ? 0.55 : 0.85),
              borderRadius: BorderRadius.circular(10),
              border: Border.all(
                color: scheme.onSurface.withValues(alpha: isDark ? 0.65 : 0.85),
                width: 1.5,
              ),
            ),
            child: Text(
              text,
              style: theme.textTheme.labelLarge?.copyWith(
                fontWeight: FontWeight.w900,
              ),
            ),
          ),
        _ => Text(
            text,
            style: theme.textTheme.labelLarge?.copyWith(
              color: scheme.onSurfaceVariant,
              fontWeight: FontWeight.w700,
            ),
          ),
      };
    }

    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 6),
      child: InkWell(
        borderRadius: borderRadius,
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 2),
          child: Row(
            children: [
              if (leading != null) ...[
                leading,
                const SizedBox(width: 10),
              ],
              Expanded(
                child: switch (template) {
                  UiTemplate.stickerJournal => Container(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 10, vertical: 6),
                      decoration: BoxDecoration(
                        color: scheme.surface.withValues(
                          alpha: isDark ? 0.28 : 0.45,
                        ),
                        borderRadius: BorderRadius.circular(14),
                        border: Border.all(
                          color: scheme.secondary.withValues(
                            alpha: isDark ? 0.25 : 0.4,
                          ),
                        ),
                      ),
                      child: Text(
                        title,
                        style: titleStyle,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                  _ => Text(
                      title,
                      style: titleStyle,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                },
              ),
              const SizedBox(width: 6),
              countWidget,
              const SizedBox(width: 2),
              Icon(
                Icons.chevron_right,
                size: 18,
                color: scheme.onSurfaceVariant,
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
    required this.isTv,
  });

  final List<MediaItem> items;
  final AppState appState;
  final bool isTv;

  static const _maxItems = 12;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        const padding = 14.0;
        const spacing = 8.0;
        final visible = (constraints.maxWidth / 180).clamp(2.2, 8.0);
        final maxCount = items.length < _maxItems ? items.length : _maxItems;

        final itemWidth =
            (constraints.maxWidth - padding * 2 - spacing * (visible - 1)) /
                visible;
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
                    isTv: isTv,
                    onTap: () {
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
    required this.isTv,
    required this.onTap,
  });

  final MediaItem item;
  final AppState appState;
  final bool isTv;
  final VoidCallback onTap;

  String _yearOf() {
    final d = (item.premiereDate ?? '').trim();
    if (d.isEmpty) return '';
    final parsed = DateTime.tryParse(d);
    if (parsed != null) return parsed.year.toString();
    return d.length >= 4 ? d.substring(0, 4) : '';
  }

  @override
  Widget build(BuildContext context) {
    final image = item.hasImage
        ? EmbyApi.imageUrl(
            baseUrl: appState.baseUrl!,
            itemId: item.id,
            token: appState.token!,
            maxWidth: isTv ? 320 : 240,
          )
        : null;

    final year = _yearOf();
    final rating = item.communityRating;

    final badge =
        item.type == 'Movie' ? '电影' : (item.type == 'Series' ? '剧集' : '');

    return MediaPosterTile(
      title: item.name,
      imageUrl: image,
      year: year,
      rating: rating,
      badgeText: badge,
      onTap: onTap,
    );
  }
}
