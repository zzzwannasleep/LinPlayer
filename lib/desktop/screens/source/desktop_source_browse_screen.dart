import 'package:flutter/material.dart';
import 'package:flutter_animate/flutter_animate.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../core/providers/app_providers.dart';
import '../../../core/providers/server_providers.dart';
import '../../../core/sources/media_source_backend.dart';
import '../../../core/sources/source_browse_controller.dart';
import '../../../core/theme/app_motion.dart';
import '../../../ui/screens/source/source_player_screen.dart';
import '../../utils/desktop_smooth_scroll.dart';

/// 桌面端网盘/聚合源浏览视图（嵌入侧边栏壳的首页内容区）。
class DesktopSourceBrowseView extends ConsumerStatefulWidget {
  const DesktopSourceBrowseView({super.key});

  @override
  ConsumerState<DesktopSourceBrowseView> createState() =>
      _DesktopSourceBrowseViewState();
}

class _DesktopSourceBrowseViewState
    extends ConsumerState<DesktopSourceBrowseView> {
  SourceBrowseController? _controller;
  String? _boundServerId;
  final _searchCtrl = TextEditingController();

  @override
  void dispose() {
    _controller?.removeListener(_onChanged);
    _searchCtrl.dispose();
    super.dispose();
  }

  void _onChanged() {
    if (mounted) setState(() {});
  }

  void _bind(ServerConfig server) {
    _controller?.removeListener(_onChanged);
    final c = SourceBrowseController(server);
    c.addListener(_onChanged);
    _controller = c;
    _boundServerId = server.id;
    _searchCtrl.clear();
    c.openRoot();
  }

  void _onTapEntry(SourceEntry e) {
    final c = _controller;
    if (c == null) return;
    if (e.isDir) {
      c.enterDir(e);
    } else if (e.isVideo) {
      context.push('/source-player',
          extra: SourcePlayArgs(server: c.server, entry: e));
    } else {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('暂不支持播放该文件类型')),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final server = ref.watch(currentServerProvider);
    if (server == null || !server.isFileBrowse) {
      return const SizedBox.shrink();
    }
    if (_boundServerId != server.id) {
      // currentServer 切换（含首次）：重建浏览控制器。
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted && _boundServerId != server.id) _bind(server);
      });
    }
    final c = _controller;
    return Scaffold(
      body: Column(
        children: [
          _buildHeader(server, c),
          if (c != null) _buildBreadcrumb(c),
          const Divider(height: 1),
          Expanded(child: c == null ? const SizedBox.shrink() : _buildBody(c)),
        ],
      ),
    );
  }

  Widget _buildHeader(ServerConfig server, SourceBrowseController? c) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(24, 18, 24, 12),
      child: Row(
        children: [
          const Icon(Icons.cloud_outlined, color: Color(0xFF5B8DEF)),
          const SizedBox(width: 10),
          Text(server.name,
              style:
                  const TextStyle(fontSize: 20, fontWeight: FontWeight.w700)),
          const Spacer(),
          SizedBox(
            width: 280,
            child: TextField(
              controller: _searchCtrl,
              decoration: InputDecoration(
                isDense: true,
                hintText: '搜索文件…',
                prefixIcon: const Icon(Icons.search, size: 20),
                filled: true,
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(10),
                  borderSide: BorderSide.none,
                ),
              ),
              onSubmitted: (v) => c?.search(v),
            ),
          ),
          const SizedBox(width: 8),
          IconButton(
            icon: const Icon(Icons.refresh),
            tooltip: '刷新',
            onPressed: () => c?.refresh(),
          ),
        ],
      ),
    );
  }

  Widget _buildBreadcrumb(SourceBrowseController c) {
    if (c.isSearching) {
      return Padding(
        padding: const EdgeInsets.fromLTRB(24, 0, 24, 10),
        child: Align(
          alignment: Alignment.centerLeft,
          child: Text('搜索结果：${c.searchQuery}',
              style: const TextStyle(color: Colors.grey)),
        ),
      );
    }
    final crumbs = c.breadcrumb;
    return Container(
      height: 38,
      alignment: Alignment.centerLeft,
      padding: const EdgeInsets.symmetric(horizontal: 16),
      child: ListView.builder(
        scrollDirection: Axis.horizontal,
        itemCount: crumbs.length,
        itemBuilder: (context, i) {
          final isLast = i == crumbs.length - 1;
          return Row(
            children: [
              if (i > 0)
                const Icon(Icons.chevron_right, size: 18, color: Colors.grey),
              TextButton(
                onPressed: isLast ? null : () => c.goToCrumb(i),
                child: Text(crumbs[i].name,
                    style: TextStyle(
                        fontWeight:
                            isLast ? FontWeight.w600 : FontWeight.normal)),
              ),
            ],
          );
        },
      ),
    );
  }

  Widget _buildBody(SourceBrowseController c) {
    if (c.loading && c.entries.isEmpty) {
      return const Center(child: CircularProgressIndicator());
    }
    if (c.error != null) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.error_outline, size: 40, color: Colors.grey),
            const SizedBox(height: 12),
            Text(c.error!),
            const SizedBox(height: 16),
            FilledButton.tonal(
                onPressed: () => c.refresh(), child: const Text('重试')),
          ],
        ),
      );
    }
    if (c.entries.isEmpty) {
      return const Center(child: Text('此目录为空'));
    }
    return DesktopSmoothScrollBuilder(
      builder: (context, controller) => GridView.builder(
        controller: controller,
        padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 16),
        gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
          maxCrossAxisExtent: 320,
          childAspectRatio: 4.2,
          crossAxisSpacing: 12,
          mainAxisSpacing: 12,
        ),
        itemCount: c.entries.length,
        itemBuilder: (context, index) {
          final e = c.entries[index];
          return _DesktopEntryCard(entry: e, onTap: () => _onTapEntry(e))
              .animate()
              .fadeIn(delay: (index * 14).ms, duration: AppMotion.fast);
        },
      ),
    );
  }
}

class _DesktopEntryCard extends StatefulWidget {
  final SourceEntry entry;
  final VoidCallback onTap;

  const _DesktopEntryCard({required this.entry, required this.onTap});

  @override
  State<_DesktopEntryCard> createState() => _DesktopEntryCardState();
}

class _DesktopEntryCardState extends State<_DesktopEntryCard> {
  bool _hover = false;

  IconData get _icon {
    if (widget.entry.isDir) return Icons.folder_rounded;
    if (widget.entry.isVideo) return Icons.movie_rounded;
    return Icons.insert_drive_file_outlined;
  }

  Color get _color {
    if (widget.entry.isDir) return const Color(0xFFF6B73C);
    if (widget.entry.isVideo) return const Color(0xFF5B8DEF);
    return Colors.grey;
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      onEnter: (_) => setState(() => _hover = true),
      onExit: (_) => setState(() => _hover = false),
      child: GestureDetector(
        onTap: widget.onTap,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 110),
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
          decoration: BoxDecoration(
            color: _hover
                ? theme.colorScheme.surfaceContainerHighest
                : theme.colorScheme.surface,
            borderRadius: BorderRadius.circular(10),
            border: Border.all(
              color: theme.colorScheme.outlineVariant.withValues(alpha: 0.3),
            ),
          ),
          child: Row(
            children: [
              Icon(_icon, color: _color, size: 26),
              const SizedBox(width: 12),
              Expanded(
                child: Text(
                  widget.entry.name,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(fontSize: 13),
                ),
              ),
              if (widget.entry.isDir)
                const Icon(Icons.chevron_right, size: 18, color: Colors.grey),
            ],
          ),
        ),
      ),
    );
  }
}
