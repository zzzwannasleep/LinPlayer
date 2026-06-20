import 'package:uuid/uuid.dart';

import '../api/danmaku/danmaku_source.dart';
import '../api/emby_api.dart';
import '../providers/server_providers.dart';
import 'server_batch_parser.dart';

/// 把 [ParsedServerBlock] 变成已鉴权的 [ServerConfig] / 弹幕源配置。
///
/// 纯逻辑、不依赖 Riverpod —— 真正落库(serverListProvider / danmakuServiceProvider)
/// 由调用方完成，方便三端 UI 与深链处理复用。
class ServerBatchAdder {
  /// 规范化服务器地址：缺协议时补 https://。
  static String normalizeUrl(String url) {
    var u = url.trim();
    if (u.isEmpty) return u;
    if (!RegExp(r'^https?://', caseSensitive: false).hasMatch(u)) {
      u = 'https://$u';
    }
    return u;
  }

  /// 用块里的线路依次尝试登录，成功即返回带全部线路、已鉴权的 [ServerConfig]。
  ///
  /// [username]/[password] 由调用方决定（通常用户只填一次用户名并一键套用到所有块）。
  /// 自动获取 Emby 服务器名称与图标(touchicon)，名称取不到时回退用户名/线路名。
  static Future<ServerConfig> authenticateBlock(
    ParsedServerBlock block, {
    required String username,
    required String password,
    String? fallbackName,
  }) async {
    final lines = <ServerLine>[
      for (final l in block.lines)
        ServerLine(
          id: const Uuid().v4(),
          name: l.name,
          url: normalizeUrl(l.url),
        ),
    ];
    if (lines.isEmpty) {
      throw Exception('该账号没有可用的服务器线路');
    }

    Object? lastErr;
    for (var i = 0; i < lines.length; i++) {
      final url = lines[i].url;
      try {
        final client = EmbyApiClient(baseUrl: url);
        final auth =
            await client.auth.login(username: username, password: password);
        var name = fallbackName?.trim().isNotEmpty == true
            ? fallbackName!.trim()
            : username;
        try {
          final info = await client.server.getSystemInfo();
          if (info.serverName.isNotEmpty) name = info.serverName;
        } catch (_) {
          // 拿不到系统信息不影响添加，用回退名。
        }
        return ServerConfig(
          id: const Uuid().v4(),
          name: name,
          baseUrl: url,
          iconUrl: buildIconUrl(url),
          lines: lines,
          activeLineIndex: i,
          username: username,
          authToken: auth.accessToken,
          userId: auth.userId,
          password: password,
        );
      } catch (e) {
        lastErr = e;
        // 换下一条线路重试。
      }
    }
    throw Exception('所有线路均登录失败：$lastErr');
  }

  /// Emby 触摸图标地址。Emby 会返回服务器自定义品牌图标，未自定义则是官方默认 Emby 图标；
  /// 取不到(404/超时)时由 UI 的 errorBuilder 回退到内置图标。
  static String buildIconUrl(String baseUrl) {
    var b = baseUrl.trim();
    while (b.endsWith('/')) {
      b = b.substring(0, b.length - 1);
    }
    return '$b/web/touchicon.png';
  }

  /// 把块里的弹幕线路转成全局弹幕源配置（鉴权方式默认「无」，用户可在弹幕设置里改）。
  static List<DanmakuSourceConfig> danmakuSourcesOf(
    ParsedServerBlock block, {
    int basePriority = 0,
  }) {
    final out = <DanmakuSourceConfig>[];
    var p = basePriority;
    for (final l in block.danmakuLines) {
      out.add(DanmakuSourceConfig(
        id: const Uuid().v4(),
        type: DanmakuSourceType.custom,
        name: l.name,
        apiUrl: normalizeUrl(l.url),
        priority: p++,
        authType: DanmakuAuthType.none,
      ));
    }
    return out;
  }
}
