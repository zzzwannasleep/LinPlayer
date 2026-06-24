import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/providers/server_providers.dart';
import '../../../core/sources/anirss/anirss_tab.dart';
import '../../theme/tv_design_tokens.dart';
import '../../theme/tv_metrics.dart';
import '../../widgets/tv_focusable.dart';
import 'tv_anirss_home_tab.dart';
import 'tv_anirss_settings_tab.dart';
import 'tv_anirss_subscriptions_tab.dart';

/// Ani-rss 迷你应用的 TV 外壳：顶部 D-pad 可导航的横向 Tab 条
/// （首页 / 订阅 / 设置），下方渲染所选 Tab 内容。嵌入 TV 首页（保留侧边栏）。
class TvAniRssView extends ConsumerStatefulWidget {
  final ServerConfig server;

  const TvAniRssView({super.key, required this.server});

  @override
  ConsumerState<TvAniRssView> createState() => _TvAniRssViewState();
}

class _TvAniRssViewState extends ConsumerState<TvAniRssView> {
  AniRssTab _tab = AniRssTab.home;

  @override
  Widget build(BuildContext context) {
    final m = context.tv;
    return Scaffold(
      backgroundColor: TvDesignTokens.background,
      body: Padding(
        padding: EdgeInsets.fromLTRB(
            m.spacingXxl, m.spacingXl, m.spacingXxl, m.spacingLg),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _buildTabStrip(m),
            SizedBox(height: m.spacingLg),
            Expanded(child: _buildBody()),
          ],
        ),
      ),
    );
  }

  Widget _buildTabStrip(TvMetrics m) {
    return Row(
      children: [
        Icon(Icons.rss_feed_rounded,
            color: TvDesignTokens.brand, size: m.s(30)),
        SizedBox(width: m.spacingMd),
        Text(
          widget.server.name,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: TextStyle(
            fontSize: m.fontSizeLg,
            color: TvDesignTokens.textPrimary,
            fontWeight: FontWeight.w600,
          ),
        ),
        SizedBox(width: m.spacingXl),
        for (final t in AniRssTab.values)
          Padding(
            padding: EdgeInsets.only(right: m.spacingMd),
            child: TvFocusable(
              autofocus: t == AniRssTab.home,
              padding: EdgeInsets.all(m.s(4)),
              onSelect: () => setState(() => _tab = t),
              onFocus: () => setState(() => _tab = t),
              child: _chip(m, t, selected: _tab == t),
            ),
          ),
      ],
    );
  }

  Widget _chip(TvMetrics m, AniRssTab t, {required bool selected}) {
    return Container(
      padding: EdgeInsets.symmetric(
          horizontal: m.spacingLg, vertical: m.spacingSm),
      decoration: BoxDecoration(
        color: selected
            ? TvDesignTokens.brand.withValues(alpha: 0.18)
            : TvDesignTokens.surface,
        borderRadius: BorderRadius.circular(m.posterRadius),
        border:
            selected ? Border.all(color: TvDesignTokens.brand, width: 2) : null,
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(
            selected ? t.icon : t.outlinedIcon,
            size: m.s(24),
            color: selected ? TvDesignTokens.brand : TvDesignTokens.textSecondary,
          ),
          SizedBox(width: m.spacingSm),
          Text(
            t.label,
            style: TextStyle(
              fontSize: m.fontSizeMd,
              color:
                  selected ? TvDesignTokens.brand : TvDesignTokens.textPrimary,
              fontWeight: selected ? FontWeight.bold : FontWeight.normal,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildBody() {
    switch (_tab) {
      case AniRssTab.home:
        return const TvAniRssHomeTab();
      case AniRssTab.subscriptions:
        return const TvAniRssSubscriptionsTab();
      case AniRssTab.settings:
        return TvAniRssSettingsTab(server: widget.server);
    }
  }
}
