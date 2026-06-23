import 'package:flutter/material.dart';
import 'package:flutter_animate/flutter_animate.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../core/providers/app_providers.dart';
import '../../../core/providers/server_providers.dart';
import '../../../core/sources/media_source_backend.dart';
import '../../../core/sources/source_browse_controller.dart';
import '../../../core/theme/app_motion.dart';
import 'source_player_screen.dart';

/// 网盘/聚合源文件浏览页（移动端）。
///
/// 面包屑导航 + 文件夹/文件列表 + 源内搜索；点视频 → 直链播放器。
class SourceBrowseScreen extends ConsumerStatefulWidget {
  const SourceBrowseScreen({super.key});

  @override
  ConsumerState<SourceBrowseScreen> createState() => _SourceBrowseScreenState();
}

class _SourceBrowseScreenState extends ConsumerState<SourceBrowseScreen> {
  SourceBrowseController? _controller;
  final _searchCtrl = TextEditingController();
  bool _searching = false;

  @override
  void initState() {
    super.initState();
    final server = ref.read(currentServerProvider);
    if (server != null && server.isFileBrowse) {
      final c = SourceBrowseController(server);
      c.addListener(_onChanged);
      _controller = c;
      c.openRoot();
    }
  }

  void _onChanged() {
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    _controller?.removeListener(_onChanged);
    _searchCtrl.dispose();
    super.dispose();
  }

  Future<bool> _onWillPop() async {
    final c = _controller;
    if (c != null && c.canGoUp && !c.isSearching) {
      await c.goUp();
      return false;
    }
    return true;
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
    final c = _controller;
    if (c == null) {
      return Scaffold(
        appBar: AppBar(title: const Text('浏览')),
        body: const Center(child: Text('当前不是网盘源服务器')),
      );
    }

    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, _) async {
        if (didPop) return;
        final router = GoRouter.of(context);
        if (await _onWillPop() && mounted) {
          // 已在根目录：退回服务器列表。
          router.go('/');
        }
      },
      child: Scaffold(
        appBar: AppBar(
          title: _searching
              ? TextField(
                  controller: _searchCtrl,
                  autofocus: true,
                  decoration: const InputDecoration(
                    hintText: '搜索文件…',
                    border: InputBorder.none,
                  ),
                  onSubmitted: (v) => c.search(v),
                )
              : Text(c.server.name, overflow: TextOverflow.ellipsis),
          actions: [
            IconButton(
              icon: Icon(_searching ? Icons.close : Icons.search),
              onPressed: () {
                setState(() {
                  _searching = !_searching;
                  if (!_searching) {
                    _searchCtrl.clear();
                    c.clearSearch();
                  }
                });
              },
            ),
            if (!_searching)
              IconButton(
                icon: const Icon(Icons.refresh),
                onPressed: () => c.refresh(),
              ),
          ],
        ),
        body: Column(
          children: [
            _buildBreadcrumb(c),
            const Divider(height: 1),
            Expanded(child: _buildBody(c)),
          ],
        ),
      ),
    );
  }

  Widget _buildBreadcrumb(SourceBrowseController c) {
    if (c.isSearching) {
      return Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
        child: Row(
          children: [
            const Icon(Icons.search, size: 16, color: Colors.grey),
            const SizedBox(width: 8),
            Text('搜索结果：${c.searchQuery}',
                style: const TextStyle(color: Colors.grey)),
          ],
        ),
      );
    }
    final crumbs = c.breadcrumb;
    return SizedBox(
      height: 44,
      child: ListView.builder(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: 12),
        itemCount: crumbs.length,
        itemBuilder: (context, i) {
          final isLast = i == crumbs.length - 1;
          return Row(
            children: [
              if (i > 0) const Icon(Icons.chevron_right, size: 18, color: Colors.grey),
              TextButton(
                onPressed: isLast ? null : () => c.goToCrumb(i),
                style: TextButton.styleFrom(
                  padding: const EdgeInsets.symmetric(horizontal: 8),
                  minimumSize: Size.zero,
                  tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                ),
                child: Text(
                  crumbs[i].name,
                  style: TextStyle(
                    fontWeight: isLast ? FontWeight.w600 : FontWeight.normal,
                    color: isLast ? null : const Color(0xFF5B8DEF),
                  ),
                ),
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
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 32),
              child: Text(c.error!, textAlign: TextAlign.center),
            ),
            const SizedBox(height: 16),
            FilledButton.tonal(
              onPressed: () => c.refresh(),
              child: const Text('重试'),
            ),
          ],
        ),
      );
    }
    if (c.entries.isEmpty) {
      return const Center(child: Text('此目录为空'));
    }
    return RefreshIndicator(
      onRefresh: () => c.refresh(),
      child: ListView.builder(
        padding: const EdgeInsets.symmetric(vertical: 8),
        itemCount: c.entries.length,
        itemBuilder: (context, index) {
          final e = c.entries[index];
          return _EntryTile(entry: e, onTap: () => _onTapEntry(e))
              .animate()
              .fadeIn(delay: (index * 18).ms, duration: AppMotion.fast);
        },
      ),
    );
  }
}

class _EntryTile extends StatelessWidget {
  final SourceEntry entry;
  final VoidCallback onTap;

  const _EntryTile({required this.entry, required this.onTap});

  IconData get _icon {
    if (entry.isDir) return Icons.folder_rounded;
    if (entry.isVideo) return Icons.movie_rounded;
    return Icons.insert_drive_file_outlined;
  }

  Color _iconColor(BuildContext context) {
    if (entry.isDir) return const Color(0xFFF6B73C);
    if (entry.isVideo) return const Color(0xFF5B8DEF);
    return Colors.grey;
  }

  @override
  Widget build(BuildContext context) {
    return ListTile(
      leading: Icon(_icon, color: _iconColor(context), size: 30),
      title: Text(entry.name, maxLines: 2, overflow: TextOverflow.ellipsis),
      subtitle: entry.size != null && !entry.isDir
          ? Text(_formatSize(entry.size!))
          : null,
      trailing: entry.isDir
          ? const Icon(Icons.chevron_right, color: Colors.grey)
          : null,
      onTap: onTap,
    );
  }

  String _formatSize(int bytes) {
    if (bytes < 1024) return '$bytes B';
    const units = ['KB', 'MB', 'GB', 'TB'];
    double size = bytes / 1024;
    int unit = 0;
    while (size >= 1024 && unit < units.length - 1) {
      size /= 1024;
      unit++;
    }
    return '${size.toStringAsFixed(size >= 10 ? 0 : 1)} ${units[unit]}';
  }
}
