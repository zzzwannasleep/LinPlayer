import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import '../theme/tv_design_tokens.dart';
import '../widgets/tv_sidebar.dart';

/// TV Shell
/// 左侧导航栏 + 右侧内容区
/// 处理导航栏和内容区之间的焦点切换
class TvShell extends StatefulWidget {
  final Widget child;
  final int selectedIndex;

  const TvShell({
    super.key,
    required this.child,
    required this.selectedIndex,
  });

  @override
  State<TvShell> createState() => _TvShellState();
}

class _TvShellState extends State<TvShell> {
  final FocusNode _sidebarFocusNode = FocusNode();
  final FocusNode _contentFocusNode = FocusNode();

  static const List<String> _routes = [
    '/tv/home',
    '/tv/search',
    '/tv/server',
    '/tv/scan',
    '/tv/settings',
  ];

  @override
  void dispose() {
    _sidebarFocusNode.dispose();
    _contentFocusNode.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: TvDesignTokens.background,
      body: Row(
        children: [
          // 左侧导航栏
          Focus(
            focusNode: _sidebarFocusNode,
            child: TvSidebar(
              selectedIndex: widget.selectedIndex,
              onItemSelected: (index) {
                _navigateToPage(index);
              },
            ),
          ),
          // 右侧内容区
          Expanded(
            child: Focus(
              focusNode: _contentFocusNode,
              child: widget.child,
            ),
          ),
        ],
      ),
    );
  }

  void _navigateToPage(int index) {
    if (index >= 0 && index < _routes.length) {
      context.go(_routes[index]);
    }
  }
}
