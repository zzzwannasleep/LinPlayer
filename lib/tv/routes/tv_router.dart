import 'package:go_router/go_router.dart';
import '../screens/home/tv_home_screen.dart';
import '../screens/search/tv_search_screen.dart';
import '../screens/library/tv_library_screen.dart';
import '../screens/server/tv_server_screen.dart';
import '../screens/server/tv_add_server_screen.dart';
import '../screens/server/tv_edit_server_screen.dart';
import '../screens/settings/tv_settings_screen.dart';
import '../screens/settings/tv_lan_control_screen.dart';
import '../screens/detail/tv_detail_screen.dart';
import '../screens/player/tv_player_screen.dart';
import '../screens/onboarding/tv_onboarding_screen.dart';
import '../shell/tv_shell.dart';

/// TV 端路由配置
/// 所有页面通过 Shell 包装，保持左侧导航栏
final tvRouter = GoRouter(
  initialLocation: '/tv/home',
  routes: [
    // 引导页（独立页面，无导航栏）
    GoRoute(
      path: '/tv/onboarding',
      builder: (context, state) => const TvOnboardingScreen(),
    ),
    // 播放页（独立页面，全屏）
    GoRoute(
      path: '/tv/player',
      builder: (context, state) {
        final mediaId = state.uri.queryParameters['mediaId'];
        final episodeId = state.uri.queryParameters['episodeId'];
        return TvPlayerScreen(
          mediaId: mediaId,
          episodeId: episodeId,
        );
      },
    ),
    // 添加服务器（独立页面，全屏表单）
    GoRoute(
      path: '/tv/add-server',
      builder: (context, state) => const TvAddServerScreen(),
    ),
    // 编辑服务器（名称/信息/图标/线路，独立页面）
    GoRoute(
      path: '/tv/edit-server/:serverId',
      builder: (context, state) => TvEditServerScreen(
        serverId: state.pathParameters['serverId'],
      ),
    ),
    // 手机扫码遥控（局域网）
    GoRoute(
      path: '/tv/lan-control',
      builder: (context, state) => const TvLanControlScreen(),
    ),
    // 详情页（独立页面，无导航栏）
    GoRoute(
      path: '/tv/detail/:mediaId',
      builder: (context, state) {
        final mediaId = state.pathParameters['mediaId'];
        return TvDetailScreen(mediaId: mediaId);
      },
    ),
    // 主页面（带导航栏 Shell）
    ShellRoute(
      builder: (context, state, child) {
        final path = state.uri.path;
        int selectedIndex = 0;
        if (path.startsWith('/tv/search')) {
          selectedIndex = 1;
        } else if (path.startsWith('/tv/server')) {
          selectedIndex = 2;
        } else if (path.startsWith('/tv/settings')) {
          selectedIndex = 3;
        }
        return TvShell(
          selectedIndex: selectedIndex,
          child: child,
        );
      },
      routes: [
        GoRoute(
          path: '/tv/home',
          builder: (context, state) => const TvHomeScreen(),
        ),
        GoRoute(
          path: '/tv/search',
          builder: (context, state) => const TvSearchScreen(),
        ),
        GoRoute(
          path: '/tv/library',
          builder: (context, state) => TvLibraryScreen(
            initialLibraryId: state.uri.queryParameters['libraryId'],
          ),
        ),
        GoRoute(
          path: '/tv/server',
          builder: (context, state) => const TvServerScreen(),
        ),
        GoRoute(
          path: '/tv/settings',
          builder: (context, state) => const TvSettingsScreen(),
        ),
      ],
    ),
  ],
);
