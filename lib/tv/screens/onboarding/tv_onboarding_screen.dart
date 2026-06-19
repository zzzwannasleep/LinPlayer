import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../../theme/tv_design_tokens.dart';
import '../../theme/tv_metrics.dart';
import '../../widgets/tv_focusable.dart';
import '../../widgets/tv_toast.dart';

/// TV 引导页
/// 3 页引导（遥控器/导航栏/焦点系统），首次启动时展示
class TvOnboardingScreen extends StatefulWidget {
  const TvOnboardingScreen({super.key});

  @override
  State<TvOnboardingScreen> createState() => _TvOnboardingScreenState();
}

class _TvOnboardingScreenState extends State<TvOnboardingScreen> {
  final PageController _pageController = PageController();
  int _currentPage = 0;
  final int _totalPages = 3;

  @override
  void dispose() {
    _pageController.dispose();
    super.dispose();
  }

  void _nextPage() {
    if (_currentPage < _totalPages - 1) {
      _pageController.nextPage(
        duration: TvDesignTokens.pageTransitionDuration,
        curve: TvDesignTokens.pageTransitionCurve,
      );
    } else {
      _finishOnboarding();
    }
  }

  void _previousPage() {
    if (_currentPage > 0) {
      _pageController.previousPage(
        duration: TvDesignTokens.pageTransitionDuration,
        curve: TvDesignTokens.pageTransitionCurve,
      );
    }
  }

  void _finishOnboarding() {
    // TODO: 保存 hasSeenOnboarding 到 shared_preferences
    TvToast.show(context, '欢迎使用 LinPlayer TV！');
    Navigator.pop(context);
  }

  void _skipOnboarding() {
    // TODO: 保存 hasSeenOnboarding 到 shared_preferences
    Navigator.pop(context);
  }

  @override
  Widget build(BuildContext context) {
    final m = context.tv;
    return Scaffold(
      backgroundColor: TvDesignTokens.background,
      body: Focus(
        autofocus: true,
        onKeyEvent: (node, event) {
          if (event is KeyDownEvent) {
            if (event.logicalKey == LogicalKeyboardKey.arrowRight) {
              _nextPage();
              return KeyEventResult.handled;
            } else if (event.logicalKey == LogicalKeyboardKey.arrowLeft) {
              _previousPage();
              return KeyEventResult.handled;
            } else if (event.logicalKey == LogicalKeyboardKey.select ||
                event.logicalKey == LogicalKeyboardKey.enter) {
              if (_currentPage == _totalPages - 1) {
                _finishOnboarding();
              } else {
                _nextPage();
              }
              return KeyEventResult.handled;
            }
          }
          return KeyEventResult.ignored;
        },
        child: Stack(
          children: [
            // 页面内容
            PageView.builder(
              controller: _pageController,
              itemCount: _totalPages,
              onPageChanged: (index) => setState(() => _currentPage = index),
              itemBuilder: (context, index) => _buildPage(index, m),
            ),
            // 跳过按钮
            Positioned(
              top: m.spacingLg,
              right: m.spacingLg,
              child: TvFocusable(
                onSelect: _skipOnboarding,
                child: Container(
                  padding: EdgeInsets.symmetric(
                    horizontal: m.spacingMd,
                    vertical: m.spacingXs,
                  ),
                  decoration: BoxDecoration(
                    color: TvDesignTokens.surface,
                    borderRadius: BorderRadius.circular(m.posterRadius),
                  ),
                  child: Text(
                    '跳过',
                    style: TextStyle(
                      fontSize: m.fontSizeSm,
                      color: TvDesignTokens.textSecondary,
                    ),
                  ),
                ),
              ),
            ),
            // 底部指示器和导航
            Positioned(
              bottom: m.spacingXxl,
              left: 0,
              right: 0,
              child: Column(
                children: [
                  // 圆点指示器
                  Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: List.generate(_totalPages, (index) {
                      return AnimatedContainer(
                        duration: TvDesignTokens.focusAnimationDuration,
                        margin: EdgeInsets.symmetric(horizontal: m.s(4)),
                        width: _currentPage == index ? m.s(24) : m.s(8),
                        height: m.s(8),
                        decoration: BoxDecoration(
                          color: _currentPage == index
                              ? TvDesignTokens.brand
                              : const Color(0x40FFFFFF),
                          borderRadius: BorderRadius.circular(m.s(4)),
                        ),
                      );
                    }),
                  ),
                  SizedBox(height: m.spacingLg),
                  // 完成按钮（最后一页）
                  if (_currentPage == _totalPages - 1)
                    TvFocusable(
                      onSelect: _finishOnboarding,
                      child: Container(
                        padding: EdgeInsets.symmetric(
                          horizontal: m.spacingLg,
                          vertical: m.spacingSm,
                        ),
                        decoration: BoxDecoration(
                          color: TvDesignTokens.brand,
                          borderRadius: BorderRadius.circular(m.posterRadius),
                        ),
                        child: Text(
                          '开始使用',
                          style: TextStyle(
                            fontSize: m.fontSizeMd,
                            color: Colors.white,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                      ),
                    ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildPage(int index, TvMetrics m) {
    final pages = [
      _OnboardingPageData(
        icon: Icons.gamepad,
        title: '使用遥控器导航',
        description: '使用方向键移动焦点，确认键选择，返回键返回',
      ),
      _OnboardingPageData(
        icon: Icons.view_sidebar,
        title: '左侧导航栏',
        description: '按左右键在导航栏和内容区之间切换',
      ),
      _OnboardingPageData(
        icon: Icons.highlight_alt,
        title: '焦点指示',
        description: '当前项高亮放大表示选中，可执行操作',
      ),
    ];

    final page = pages[index];

    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          // 图标
          Container(
            width: m.s(80),
            height: m.s(80),
            decoration: BoxDecoration(
              color: TvDesignTokens.brand.withOpacity(0.15),
              borderRadius: BorderRadius.circular(m.s(40)),
            ),
            child: Icon(
              page.icon,
              color: TvDesignTokens.brand,
              size: m.s(40),
            ),
          ),
          SizedBox(height: m.spacingLg),
          // 标题
          Text(
            page.title,
            style: TextStyle(
              fontSize: m.fontSizeXl,
              color: TvDesignTokens.textPrimary,
              fontWeight: FontWeight.bold,
            ),
          ),
          SizedBox(height: m.spacingMd),
          // 说明
          Padding(
            padding: EdgeInsets.symmetric(horizontal: m.spacingXxl),
            child: Text(
              page.description,
              textAlign: TextAlign.center,
              style: TextStyle(
                fontSize: m.fontSizeMd,
                color: TvDesignTokens.textSecondary,
                height: TvDesignTokens.lineHeightRelaxed,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _OnboardingPageData {
  final IconData icon;
  final String title;
  final String description;

  _OnboardingPageData({
    required this.icon,
    required this.title,
    required this.description,
  });
}
