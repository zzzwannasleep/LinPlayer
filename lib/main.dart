import 'dart:async';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:media_kit/media_kit.dart';

import 'app.dart';
import 'core/providers/app_providers.dart';
import 'core/providers/proxy_providers.dart';
import 'core/services/app_logger.dart';
import 'core/services/cache_service.dart';
import 'core/services/crash_diagnostics.dart';
import 'core/services/font_service.dart';
import 'core/theme/app_motion.dart';
import 'core/utils/platform_utils.dart';
import 'desktop/desktop_app.dart';
import 'desktop/window/desktop_window_chrome.dart';
import 'plugins/plugin_system.dart';
import 'tv/tv_app.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  // 日志：尽早初始化文件落盘 + 捕获未处理异常（三端统一、原生输出、可被 AI 读取）。
  await AppLogger().init();
  AppLogger().installErrorHandlers();

  // 统一三端动效基线（时长/曲线），见 core/theme/app_motion.dart
  AppMotion.applyGlobalDefaults();

  // media_kit 仅在非 Android 平台初始化
  // Android 使用原生 MPV (libplayer.so) 通过平台通道调用
  if (!Platform.isAndroid) {
    MediaKit.ensureInitialized();
  }

  await initializeAppPreferences();

  // 启动后台上报上次的原生崩溃回溯（Android），写入可导出的 App 日志便于定位。
  unawaited(CrashDiagnostics.reportRecentExits());

  // 自定义字体：按持久化路径重新加载（FontLoader 不跨进程，需每次启动重做），
  // 必须在构建 UI 前完成，确保首帧即用上用户字体。
  await FontService.initialize();

  // 代理：把持久化的自定义代理配置注入全局运行时（含 SOCKS 主机名预解析），
  // 必须在任何网络请求/客户端构建之前完成，确保首个请求即走代理。
  await initializeProxyRuntime();

  // 桌面端：初始化无边框窗口 + 自绘标题栏
  if (isDesktopPlatform && !isTvPlatform) {
    await initDesktopWindow();
  }

  // 缓存策略（全平台，对内存小的机器友好）：
  // - 内存只保留少量解码位图（~100MB/1000，LRU 回收），不常驻海量图。
  // - 磁盘持久化由 PersistentNetworkImageProvider 负责（图片 6GB 上限 + 14 天过期）。
  // - 视频播放缓存走 mpv 磁盘缓存（见 mpv 适配器），不占内存。
  CacheService.configureMemoryCache();
  // 启动清理放后台，不阻塞启动。
  unawaited(CacheService.runStartupCleanup());

  // 插件系统：共享同一个 ProviderContainer，便于插件 ctx 读取应用状态。
  final container = ProviderContainer();
  await initializePluginSystem(container);

  final Widget appWidget = isTvPlatform
      ? const LinPlayerTvApp()
      : isDesktopPlatform
          ? const LinPlayerDesktopApp()
          : const LinPlayerApp();

  runApp(
    UncontrolledProviderScope(
      container: container,
      child: appWidget,
    ),
  );
}
