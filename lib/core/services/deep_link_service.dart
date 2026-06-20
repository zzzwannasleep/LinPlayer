import 'dart:async';
import 'dart:io';

import 'package:app_links/app_links.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../desktop/routes/desktop_router.dart';
import '../../routes/app_router.dart';
import '../../tv/routes/tv_router.dart';
import '../api/danmaku/danmaku_service.dart';
import '../providers/server_providers.dart';
import '../utils/platform_utils.dart';
import '../utils/server_batch_adder.dart';
import '../utils/server_batch_parser.dart';
import 'app_logger.dart';

/// 处理 `linplayer://` 自定义协议深链。
///
/// 典型用途：第三方 Emby 管理员/机场把开通信息做成「一键跳转」按钮，用户点开浏览器里的
/// `linplayer://add-server?...` 链接 → 唤起本 App → 自动登录并添加服务器(含多线路/弹幕线路)。
///
/// 链接格式：
///   linplayer://add-server?name=<服务器名>&user=<用户名>&pwd=<密码>
///       &line=<线路1>&line=<线路2>&danmaku=<弹幕线路1>
///   或直接塞整段分享文本：linplayer://add-server?text=<urlencoded 文本>
class DeepLinkService {
  final ProviderContainer container;
  final AppLinks _appLinks = AppLinks();
  static final _logger = AppLogger();
  StreamSubscription<Uri>? _sub;

  DeepLinkService(this.container);

  Future<void> init() async {
    await _registerWindowsScheme();
    try {
      final initial = await _appLinks.getInitialLink();
      if (initial != null) {
        // 冷启动：等首帧后再处理，确保路由已挂载可跳转。
        unawaited(Future.delayed(const Duration(milliseconds: 400),
            () => _handle(initial)));
      }
    } catch (e) {
      _logger.w('DeepLink', '读取初始链接失败: $e');
    }
    _sub = _appLinks.uriLinkStream.listen(
      _handle,
      onError: (e) => _logger.w('DeepLink', '链接流错误: $e'),
    );
  }

  void dispose() {
    _sub?.cancel();
  }

  Future<void> _handle(Uri uri) async {
    if (uri.scheme.toLowerCase() != 'linplayer') return;
    final isAddServer =
        uri.host == 'add-server' || uri.path.contains('add-server');
    if (!isAddServer) return;

    _logger.i('DeepLink', '处理添加服务器深链: ${uri.host}${uri.path}');
    final block = _blockFromUri(uri);
    if (block == null || block.isEmpty) {
      _logger.w('DeepLink', '链接里没有可用的服务器线路');
      return;
    }
    final user = uri.queryParameters['user']?.trim() ?? block.username ?? '';
    final pass = uri.queryParameters['pwd'] ?? block.password ?? '';
    final name = uri.queryParameters['name'];
    if (user.isEmpty) {
      _logger.w('DeepLink', '链接缺少用户名，无法登录');
      return;
    }

    // H9/M8/M4/L6：外部链接完全不可信，必须经用户显式确认（展示 host/用户名/
    // 弹幕源数量、明文 HTTP 警告）后，才登录、添加、设为当前并入弹幕源。
    final confirmed = await _confirmAddServer(
      name: name,
      username: user,
      lineUrls: block.lines.map((l) => l.url).toList(),
      danmakuCount: block.danmakuLines.length,
    );
    if (!confirmed) {
      _logger.i('DeepLink', '用户取消（或无 UI 上下文）未添加深链服务器');
      return;
    }

    try {
      final server = await ServerBatchAdder.authenticateBlock(
        block,
        username: user,
        password: pass,
        fallbackName: name,
      );
      container.read(serverListProvider.notifier).addServer(server);
      container.read(currentServerProvider.notifier).state = server;
      container.read(authStateProvider.notifier).state =
          AuthState.authenticated;

      // 弹幕线路并入全局弹幕源。
      final sources = ServerBatchAdder.danmakuSourcesOf(
        block,
        basePriority: container.read(danmakuServiceProvider).sources.length,
      );
      for (final cfg in sources) {
        await container.read(danmakuServiceProvider.notifier).addCustomSource(cfg);
      }

      _logger.i('DeepLink', '已通过深链添加服务器: ${server.name}');
      _goHome();
    } catch (e) {
      _logger.w('DeepLink', '深链添加服务器失败: $e');
    }
  }

  /// 从 URI 构造一个账号块：优先用结构化参数(line/danmaku/user/pwd)，
  /// 否则回退解析 `text` 整段分享文本。
  ParsedServerBlock? _blockFromUri(Uri uri) {
    final text = uri.queryParameters['text'];
    if (text != null && text.trim().isNotEmpty) {
      final blocks = ServerBatchParser.parse(text);
      return blocks.isEmpty ? null : blocks.first;
    }
    final lineUrls = uri.queryParametersAll['line'] ?? const [];
    final danmakuUrls = uri.queryParametersAll['danmaku'] ?? const [];
    if (lineUrls.isEmpty && danmakuUrls.isEmpty) return null;
    return ParsedServerBlock(
      username: uri.queryParameters['user'],
      password: uri.queryParameters['pwd'],
      lines: [
        for (final u in lineUrls)
          if (u.trim().isNotEmpty) ParsedLine(_hostOf(u), u.trim()),
      ],
      danmakuLines: [
        for (final u in danmakuUrls)
          if (u.trim().isNotEmpty) ParsedLine('弹幕', u.trim()),
      ],
    );
  }

  /// 取当前平台路由器的根导航器 context（用于弹确认框）。拿不到返回 null。
  BuildContext? _navContext() {
    try {
      if (isTvPlatform) {
        return tvRouter.routerDelegate.navigatorKey.currentContext;
      }
      if (isDesktopPlatform) {
        return container
            .read(desktopRouterProvider)
            .routerDelegate
            .navigatorKey
            .currentContext;
      }
      return container
          .read(appRouterProvider)
          .routerDelegate
          .navigatorKey
          .currentContext;
    } catch (_) {
      return null;
    }
  }

  /// 弹出确认框：用户同意才返回 true。无 UI 上下文（拿不到导航器）一律返回
  /// false——安全默认：不确认就不自动添加，杜绝网页/二维码 drive-by。
  Future<bool> _confirmAddServer({
    String? name,
    required String username,
    required List<String> lineUrls,
    required int danmakuCount,
  }) async {
    final context = _navContext();
    if (context == null || !context.mounted) {
      _logger.w('DeepLink', '无可用 UI 上下文，拒绝自动添加服务器');
      return false;
    }
    final hosts = lineUrls.map(_hostOf).toSet().join('、');
    final hasHttp = lineUrls.any((u) => ServerBatchAdder.normalizeUrl(u)
        .toLowerCase()
        .startsWith('http://'));
    final result = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('通过链接添加服务器？'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text('有外部链接请求添加并登录以下服务器，确认前请核实来源可信：',
                style: TextStyle(fontSize: 13)),
            const SizedBox(height: 12),
            if (name != null && name.trim().isNotEmpty) Text('名称：$name'),
            Text('主机：${hosts.isEmpty ? '（未知）' : hosts}'),
            Text('用户名：$username'),
            if (danmakuCount > 0) Text('附带弹幕源：$danmakuCount 条'),
            if (hasHttp) ...[
              const SizedBox(height: 8),
              const Text('⚠ 含明文 HTTP 线路，账号密码将以明文传输',
                  style: TextStyle(color: Colors.orange, fontSize: 12)),
            ],
          ],
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('取消')),
          FilledButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('添加并登录')),
        ],
      ),
    );
    return result ?? false;
  }

  void _goHome() {
    try {
      if (isTvPlatform) {
        tvRouter.go('/tv/home');
      } else if (isDesktopPlatform) {
        container.read(desktopRouterProvider).go('/');
      } else {
        container.read(appRouterProvider).go('/home');
      }
    } catch (e) {
      // 路由尚未就绪(冷启动竞态)时忽略：服务器已添加并设为当前，
      // 用户回到首页即可见。
      _logger.w('DeepLink', '跳转首页失败(忽略): $e');
    }
  }

  String _hostOf(String url) {
    try {
      final u = Uri.parse(ServerBatchAdder.normalizeUrl(url));
      if (u.host.isNotEmpty) return u.host;
    } catch (_) {}
    return '线路';
  }

  /// Windows：把 `linplayer://` 协议注册到当前用户(HKCU，免管理员)，指向本 exe，
  /// 这样浏览器点链接才能唤起本程序。
  ///
  /// 用「写 .reg 文件 + reg import」而非 `reg add`：后者对空值(URL Protocol)和带空格
  /// 路径的引号(如 C:\Program Files\…)处理不可靠，会把命令存成没引号、运行即失败。
  /// .reg 文件按 UTF-8 无 BOM 写入(File.writeAsString 默认)，reg import 可正确解析。
  Future<void> _registerWindowsScheme() async {
    if (!Platform.isWindows) return;
    try {
      final exe = Platform.resolvedExecutable;
      // 路径转义到 .reg 语法：反斜杠翻倍、引号转义。
      final exeEsc = exe.replaceAll(r'\', r'\\').replaceAll('"', r'\"');
      const q = '"';
      const bsq = r'\"'; // .reg 里表示一个字面引号
      final command = '@=$q$bsq$exeEsc$bsq $bsq%1$bsq$q';
      final content = [
        'Windows Registry Editor Version 5.00',
        '',
        r'[HKEY_CURRENT_USER\Software\Classes\linplayer]',
        '@="URL:LinPlayer Protocol"',
        '"URL Protocol"=""',
        '',
        r'[HKEY_CURRENT_USER\Software\Classes\linplayer\shell\open\command]',
        command,
        '',
      ].join('\r\n');
      final file = File('${Directory.systemTemp.path}\\linplayer_scheme.reg');
      await file.writeAsString(content);
      await Process.run('reg', ['import', file.path]);
    } catch (e) {
      _logger.w('DeepLink', 'Windows 协议注册失败: $e');
    }
  }
}
