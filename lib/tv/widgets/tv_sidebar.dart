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
      // 导航项整体垂直居中；每项内容（图标 + 文字）水平居中，
      // 更贴合 Pad 触控与 TV 对称布局，不再堆在左上角。
      child: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: List.generate(_items.length, (index) {
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
                alignment: Alignment.center,
                padding: EdgeInsets.symmetric(horizontal: m.spacingMd),
                decoration: BoxDecoration(
                  color: isSelected
                      ? TvDesignTokens.brand.withOpacity(0.15)
                      : null,
                  borderRadius: BorderRadius.circular(m.posterRadius),
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Icon(
                      item.icon,
                      color: isSelected
                          ? TvDesignTokens.brand
                          : TvDesignTokens.textSecondary,
                      size: m.sidebarIconSize,
                    ),
                    if (!widget.collapsed) ...[
                      SizedBox(width: m.spacingMd),
                      Text(
                        item.label,
                        style: TextStyle(
                          fontSize: m.sidebarTextSize,
                          color: isSelected
                              ? TvDesignTokens.brand
                              : TvDesignTokens.textSecondary,
                          fontWeight:
                              isSelected ? FontWeight.bold : FontWeight.normal,
                        ),
                      ),
                    ],
                  ],
                ),
              ),
            );
          }),
        ),
      ),
    );
  }
}

class _NavItem {
  final IconData icon;
  final String label;

  const _NavItem(this.icon, this.label);
}
