import 'package:flutter/material.dart';
import '../theme/tv_design_tokens.dart';
import '../theme/tv_metrics.dart';
import 'tv_focusable.dart';

/// TV 左侧导航栏
/// 固定左侧，4 项导航：首页、搜索、服务器、设置
class TvSidebar extends StatefulWidget {
  final int selectedIndex;
  final ValueChanged<int> onItemSelected;
  final bool collapsed;

  const TvSidebar({
    super.key,
    required this.selectedIndex,
    required this.onItemSelected,
    this.collapsed = false,
  });

  @override
  State<TvSidebar> createState() => _TvSidebarState();
}

class _TvSidebarState extends State<TvSidebar> {
  final List<_NavItem> _items = const [
    _NavItem(Icons.home_rounded, '首页'),
    _NavItem(Icons.search_rounded, '搜索'),
    _NavItem(Icons.storage_rounded, '服务器'),
    _NavItem(Icons.settings_rounded, '设置'),
  ];

  @override
  Widget build(BuildContext context) {
    final m = context.tv;
    final width = widget.collapsed
        ? m.sidebarCollapsedWidth
        : m.sidebarWidth;

    return Container(
      width: width,
      color: TvDesignTokens.surface,
      child: Column(
        children: [
          // Logo 区域
          Padding(
            padding: EdgeInsets.all(m.spacingLg),
            child: widget.collapsed
                ? Icon(
                    Icons.play_circle_filled,
                    color: TvDesignTokens.brand,
                    size: m.s(40),
                  )
                : Row(
                    children: [
                      Icon(
                        Icons.play_circle_filled,
                        color: TvDesignTokens.brand,
                        size: m.s(40),
                      ),
                      SizedBox(width: m.spacingSm),
                      Text(
                        'LinPlayer',
                        style: Theme.of(context).textTheme.titleLarge?.copyWith(
                              color: TvDesignTokens.brand,
                              fontWeight: FontWeight.bold,
                            ),
                      ),
                    ],
                  ),
          ),
          const Divider(color: TvDesignTokens.divider),
          // 导航项
          Expanded(
            child: ListView.builder(
              itemCount: _items.length,
              itemBuilder: (context, index) {
                final item = _items[index];
                final isSelected = widget.selectedIndex == index;

                return TvFocusable(
                  autofocus: index == 0,
                  onSelect: () => widget.onItemSelected(index),
                  padding: EdgeInsets.symmetric(
                    horizontal: m.spacingMd,
                    vertical: m.spacingSm,
                  ),
                  child: Container(
                    height: m.sidebarItemHeight,
                    decoration: BoxDecoration(
                      color: isSelected ? TvDesignTokens.brand.withOpacity(0.15) : null,
                      borderRadius: BorderRadius.circular(m.posterRadius),
                    ),
                    child: Row(
                      mainAxisAlignment: widget.collapsed
                          ? MainAxisAlignment.center
                          : MainAxisAlignment.start,
                      children: [
                        Icon(
                          item.icon,
                          color: isSelected ? TvDesignTokens.brand : TvDesignTokens.textSecondary,
                          size: m.sidebarIconSize,
                        ),
                        if (!widget.collapsed) ...[
                          SizedBox(width: m.spacingMd),
                          Text(
                            item.label,
                            style: TextStyle(
                              fontSize: m.sidebarTextSize,
                              color: isSelected ? TvDesignTokens.brand : TvDesignTokens.textSecondary,
                              fontWeight: isSelected ? FontWeight.bold : FontWeight.normal,
                            ),
                          ),
                        ],
                      ],
                    ),
                  ),
                );
              },
            ),
          ),
        ],
      ),
    );
  }
}

class _NavItem {
  final IconData icon;
  final String label;

  const _NavItem(this.icon, this.label);
}
