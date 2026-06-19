import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import '../../core/providers/app_providers.dart';
import '../../core/theme/app_motion.dart';
import '../../plugins/plugin_system.dart';
import '../screens/detail/desktop_media_detail_screen.dart';
import '../screens/player/desktop_player_screen.dart';
import '../screens/search/desktop_search_screen.dart';
import '../../ui/screens/settings/settings_screen.dart';
import '../../ui/screens/server/edit_server_screen.dart';
import '../../ui/screens/server/icon_select_screen.dart';
import '../../ui/screens/server/server_lines_screen.dart';
import '../screens/favorites/desktop_favorites_screen.dart';
import '../screens/download/desktop_download_screen.dart';
import '../screens/home/desktop_home_screen.dart';
import '../screens/library/desktop_library_screen.dart';
import '../screens/library/desktop_library_detail_screen.dart';
import '../screens/server/desktop_server_screen.dart';
import '../screens/server/desktop_add_server_screen.dart';
import '../shell/desktop_shell.dart';

final _rootNavigatorKey = GlobalKey<NavigatorState>();

final desktopRouterProvider = Provider<GoRouter>((ref) {
  final startupPage = ref.watch(startupPageProvider);
  // 把桌面根导航器交给插件系统，供插件 UI（Toast/Dialog/表单/openPage）使用。
  attachPluginNavigator(_rootNavigatorKey);
  return GoRouter(
    navigatorKey: _rootNavigatorKey,
    initialLocation: desktopStartupLocationFor(startupPage),
    redirect: (context, state) {
      final servers = ref.read(serverListProvider);
      final isAuthRoute = state.uri.path == '/servers' || state.uri.path == '/add-server';
      if (servers.isEmpty && !isAuthRoute) {
        return '/servers';
      }
      return null;
    },
    routes: [
      // 主壳路由 - 带侧边栏。
      // 用 StatefulShellRoute.indexedStack：每个一级 Tab 是独立分支，切换时
      // 用 IndexedStack 保活，不重建页面、不重新拉取数据/解码图片 → 切换即时、
      // 海报不再“刷新”。详情/播放等全屏页仍是壳外的顶级路由。
      StatefulShellRoute.indexedStack(
        builder: (context, state, navigationShell) {
          return DesktopShell(navigationShell: navigationShell);
        },
        branches: [
          // 分支 0：首页（含续播页）
          StatefulShellBranch(
            routes: [
              GoRoute(
                path: '/',
                pageBuilder: (context, state) => _buildFadePage(
                  child: const DesktopHomeScreen(),
                  state: state,
                ),
              ),
              GoRoute(
                path: resumeRoutePath,
                pageBuilder: (context, state) => _buildFadePage(
                  child: const DesktopResumeScreen(),
                  state: state,
                ),
              ),
            ],
          ),
          // 分支 1：媒体库（含库详情）
          StatefulShellBranch(
            routes: [
              GoRoute(
                path: '/libraries',
                pageBuilder: (context, state) => _buildFadePage(
                  child: const DesktopLibraryScreen(),
                  state: state,
                ),
              ),
              GoRoute(
                path: '/library/:id',
                pageBuilder: (context, state) => _buildFadePage(
                  child: DesktopLibraryDetailScreen(
                    libraryId: state.pathParameters['id']!,
                  ),
                  state: state,
                ),
              ),
            ],
          ),
          // 分支 2：收藏
          StatefulShellBranch(
            routes: [
              GoRoute(
                path: '/favorites',
                pageBuilder: (context, state) => _buildFadePage(
                  child: const DesktopFavoritesScreen(),
                  state: state,
                ),
              ),
            ],
          ),
          // 分支 3：下载
          StatefulShellBranch(
            routes: [
              GoRoute(
                path: '/downloads',
                pageBuilder: (context, state) => _buildFadePage(
                  child: const DesktopDownloadScreen(),
                  state: state,
                ),
              ),
            ],
          ),
          // 分支 4：服务器
          StatefulShellBranch(
            routes: [
              GoRoute(
                path: '/servers',
                pageBuilder: (context, state) => _buildFadePage(
                  child: const DesktopServerScreen(),
                  state: state,
                ),
              ),
            ],
          ),
          // 分支 5：设置
          StatefulShellBranch(
            routes: [
              GoRoute(
                path: '/settings',
                pageBuilder: (context, state) => _buildFadePage(
                  child: const SettingsScreen(),
                  state: state,
                ),
              ),
            ],
          ),
        ],
      ),
      // 全屏路由 - 无侧边栏
      GoRoute(
        path: '/detail/:id',
        pageBuilder: (context, state) => _buildSlidePage(
          child: DesktopMediaDetailScreen(
            itemId: state.pathParameters['id']!,
          ),
          state: state,
        ),
      ),
      GoRoute(
        path: '/season/:id',
        pageBuilder: (context, state) => _buildSlidePage(
          child: DesktopMediaDetailScreen(
            itemId: state.pathParameters['id']!,
          ),
          state: state,
        ),
      ),
      GoRoute(
        path: '/episode/:id',
        pageBuilder: (context, state) => _buildSlidePage(
          child: DesktopMediaDetailScreen(
            itemId: state.pathParameters['id']!,
          ),
          state: state,
        ),
      ),
      GoRoute(
        path: '/player/:id',
        pageBuilder: (context, state) => _buildFadePage(
          child: DesktopPlayerScreen(
            itemId: state.pathParameters['id']!,
            mediaSourceId: state.uri.queryParameters['mediaSourceId'],
          ),
          state: state,
        ),
      ),
      GoRoute(
        path: '/search',
        pageBuilder: (context, state) => _buildSlidePage(
          child: const DesktopSearchScreen(),
          state: state,
          fromRight: true,
        ),
      ),
      GoRoute(
        path: '/add-server',
        pageBuilder: (context, state) => _buildSlidePage(
          child: const DesktopAddServerScreen(),
          state: state,
          fromRight: true,
        ),
      ),
      GoRoute(
        path: '/edit-server/:serverId',
        pageBuilder: (context, state) => _buildSlidePage(
          child: EditServerScreen(
            serverId: state.pathParameters['serverId']!,
          ),
          state: state,
          fromRight: true,
        ),
      ),
      GoRoute(
        path: '/server-lines/:serverId',
        pageBuilder: (context, state) => _buildSlidePage(
          child: ServerLinesScreen(
            serverId: state.pathParameters['serverId']!,
          ),
          state: state,
          fromRight: true,
        ),
      ),
      GoRoute(
        path: '/server-icons/:serverId',
        pageBuilder: (context, state) => _buildSlidePage(
          child: IconSelectScreen(
            serverId: state.pathParameters['serverId']!,
          ),
          state: state,
          fromRight: true,
        ),
      ),
    ],
  );
});

CustomTransitionPage<void> _buildFadePage({
  required Widget child,
  required GoRouterState state,
}) {
  return CustomTransitionPage<void>(
    key: state.pageKey,
    child: child,
    transitionsBuilder: (context, animation, secondaryAnimation, child) {
      return FadeTransition(
        opacity: CurvedAnimation(
          parent: animation,
          curve: AppMotion.standard,
        ),
        child: child,
      );
    },
    transitionDuration: const Duration(milliseconds: 180),
    reverseTransitionDuration: const Duration(milliseconds: 120),
  );
}

CustomTransitionPage<void> _buildSlidePage({
  required Widget child,
  required GoRouterState state,
  bool fromRight = false,
}) {
  return CustomTransitionPage<void>(
    key: state.pageKey,
    child: child,
    transitionsBuilder: (context, animation, secondaryAnimation, child) {
      final curved = CurvedAnimation(
        parent: animation,
        curve: AppMotion.standard,
        reverseCurve: AppMotion.reverse,
      );
      return SlideTransition(
        position: Tween<Offset>(
          begin: fromRight ? const Offset(0.1, 0) : const Offset(-0.1, 0),
          end: Offset.zero,
        ).animate(curved),
        child: FadeTransition(
          opacity: Tween<double>(begin: 0.9, end: 1).animate(curved),
          child: child,
        ),
      );
    },
    transitionDuration: const Duration(milliseconds: 200),
    reverseTransitionDuration: const Duration(milliseconds: 160),
  );
}
