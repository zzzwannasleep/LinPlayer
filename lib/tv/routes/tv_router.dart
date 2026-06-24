import 'package:go_router/go_router.dart';
import '../screens/home/tv_home_screen.dart';
import '../screens/search/tv_search_screen.dart';
import '../screens/library/tv_library_screen.dart';
import '../screens/server/tv_server_screen.dart';
import '../screens/server/tv_add_server_screen.dart';
import '../screens/server/tv_edit_server_screen.dart';
import '../screens/source/tv_source_picker_screen.dart';
import '../screens/source/tv_source_login_screen.dart';
import '../../ui/screens/source/source_player_screen.dart';
import '../../core/sources/source_kind.dart';
import '../screens/settings/tv_settings_screen.dart';
import '../screens/settings/tv_lan_control_screen.dart';
import '../screens/anirss/tv_anirss_detail_screen.dart';
import '../../core/sources/anirss/anirss_nav_args.dart';
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
    // 添加服务器第一步：源类型选择器（独立页面）。
    GoRoute(
      path: '/tv/add-server',
      builder: (context, state) => const TvSourcePickerScreen(),
    ),
    // Emby 分支：复用现有添加流程。
    GoRoute(
      path: '/tv/add-emby',
      builder: (context, state) => const TvAddServerScreen(),
    ),
    // 网盘/聚合源登录页（按 :kind 分发）。
    GoRoute(
      path: '/tv/add-source/:kind',
      builder: (context, state) => TvSourceLoginScreen(
        kind: sourceKindFromName(state.pathParameters['kind']),
      ),
    ),
    // 网盘/聚合源：直链播放页（共用实现，含 D-pad 遥控）。
    GoRoute(
      path: '/tv/source-player',
      builder: (context, state) {
        final args = state.extra as SourcePlayArgs;
        return SourcePlayerScreen(server: args.server, entry: args.entry);
      },
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
    // Ani-rss 详情页（独立页面，无导航栏；Ani 对象经 extra 传）
    GoRoute(
      path: '/tv/anirss-detail',
      builder: (context, state) =>
          TvAniRssDetailScreen(args: state.extra as AniRssDetailArgs),
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
        } else if (path.startsWith('/tv/scan')) {
          selectedIndex = 3;
        } else if (path.startsWith('/tv/settings')) {
          selectedIndex = 4;
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
        // 扫码（局域网遥控 + 手机端添加服务器）：侧边栏直达。
        GoRoute(
          path: '/tv/scan',
          builder: (context, state) => const TvLanControlScreen(),
        ),
        GoRoute(
          path: '/tv/settings',
          builder: (context, state) => const TvSettingsScreen(),
        ),
      ],
    ),
  ],
);
