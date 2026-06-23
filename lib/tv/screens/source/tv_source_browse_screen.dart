import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../core/providers/server_providers.dart';
import '../../../core/sources/media_source_backend.dart';
import '../../../core/sources/source_browse_controller.dart';
import '../../../ui/screens/source/source_player_screen.dart';
import '../../theme/tv_design_tokens.dart';
import '../../theme/tv_metrics.dart';
import '../../widgets/tv_focusable.dart';

/// TV 端网盘/聚合源浏览视图（嵌入 TV 首页，保留侧边栏）。D-pad 焦点导航。
class TvSourceBrowseView extends ConsumerStatefulWidget {
  final ServerConfig server;

  const TvSourceBrowseView({super.key, required this.server});

  @override
  ConsumerState<TvSourceBrowseView> createState() =>
      _TvSourceBrowseViewState();
}

class _TvSourceBrowseViewState extends ConsumerState<TvSourceBrowseView> {
  late SourceBrowseController _controller;

  @override
  void initState() {
    super.initState();
    _controller = SourceBrowseController(widget.server);
    _controller.addListener(_onChanged);
    _controller.openRoot();
  }

  @override
  void didUpdateWidget(covariant TvSourceBrowseView oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.server.id != widget.server.id) {
      _controller.removeListener(_onChanged);
      _controller = SourceBrowseController(widget.server);
      _controller.addListener(_onChanged);
      _controller.openRoot();
    }
  }

  void _onChanged() {
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    _controller.removeListener(_onChanged);
    super.dispose();
  }

  void _onSelectEntry(SourceEntry e) {
    if (e.isDir) {
      _controller.enterDir(e);
    } else if (e.isVideo) {
      context.push('/tv/source-player',
          extra: SourcePlayArgs(server: _controller.server, entry: e));
    }
  }

  @override
  Widget build(BuildContext context) {
    final m = context.tv;
    final c = _controller;
    return Scaffold(
      backgroundColor: TvDesignTokens.background,
      body: Padding(
        padding: EdgeInsets.fromLTRB(
            m.spacingXxl, m.spacingXl, m.spacingXxl, m.spacingLg),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _buildHeader(m, c),
            SizedBox(height: m.spacingLg),
            Expanded(child: _buildBody(m, c)),
          ],
        ),
      ),
    );
  }

  Widget _buildHeader(TvMetrics m, SourceBrowseController c) {
    final crumbs = c.breadcrumb;
    return Row(
      children: [
        Icon(Icons.cloud_outlined,
            color: TvDesignTokens.brand, size: m.s(30)),
        SizedBox(width: m.spacingMd),
        Expanded(
          child: Text(
            crumbs.map((e) => e.name).join('  ›  '),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              fontSize: m.fontSizeLg,
              color: TvDesignTokens.textPrimary,
              fontWeight: FontWeight.w600,
            ),
          ),
        ),
        if (c.canGoUp)
          TvFocusable(
            padding: EdgeInsets.all(m.s(4)),
            onSelect: () => c.goUp(),
            child: Container(
              padding: EdgeInsets.symmetric(
                  horizontal: m.spacingLg, vertical: m.spacingSm),
              decoration: BoxDecoration(
                color: TvDesignTokens.surface,
                borderRadius: BorderRadius.circular(m.posterRadius),
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(Icons.arrow_upward,
                      size: m.s(22), color: TvDesignTokens.textPrimary),
                  SizedBox(width: m.spacingSm),
                  Text('上一级',
                      style: TextStyle(
                          fontSize: m.fontSizeSm,
                          color: TvDesignTokens.textPrimary)),
                ],
              ),
            ),
          ),
      ],
    );
  }

  Widget _buildBody(TvMetrics m, SourceBrowseController c) {
    if (c.loading && c.entries.isEmpty) {
      return const Center(
          child: CircularProgressIndicator(color: TvDesignTokens.brand));
    }
    if (c.error != null) {
      return Center(
        child: Text(c.error!,
            style: TextStyle(
                fontSize: m.fontSizeMd, color: TvDesignTokens.error)),
      );
    }
    if (c.entries.isEmpty) {
      return Center(
        child: Text('此目录为空',
            style: TextStyle(
                fontSize: m.fontSizeMd, color: TvDesignTokens.textSecondary)),
      );
    }
    return ListView.builder(
      itemCount: c.entries.length,
      itemBuilder: (context, i) {
        final e = c.entries[i];
        return Padding(
          padding: EdgeInsets.only(bottom: m.spacingMd),
          child: TvFocusable(
            autofocus: i == 0,
            padding: EdgeInsets.all(m.s(4)),
            onSelect: () => _onSelectEntry(e),
            child: _row(m, e),
          ),
        );
      },
    );
  }

  Widget _row(TvMetrics m, SourceEntry e) {
    final IconData icon;
    final Color color;
    if (e.isDir) {
      icon = Icons.folder_rounded;
      color = const Color(0xFFF6B73C);
    } else if (e.isVideo) {
      icon = Icons.movie_rounded;
      color = TvDesignTokens.brand;
    } else {
      icon = Icons.insert_drive_file_outlined;
      color = TvDesignTokens.textSecondary;
    }
    return Container(
      padding: EdgeInsets.symmetric(
          horizontal: m.spacingLg, vertical: m.spacingMd),
      decoration: BoxDecoration(
        color: TvDesignTokens.surface,
        borderRadius: BorderRadius.circular(m.posterRadius),
      ),
      child: Row(
        children: [
          Icon(icon, color: color, size: m.s(30)),
          SizedBox(width: m.spacingLg),
          Expanded(
            child: Text(
              e.name,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                  fontSize: m.fontSizeMd, color: TvDesignTokens.textPrimary),
            ),
          ),
          if (e.isDir)
            Icon(Icons.chevron_right,
                color: TvDesignTokens.textSecondary, size: m.s(26)),
        ],
      ),
    );
  }
}
