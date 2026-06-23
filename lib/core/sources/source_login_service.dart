import 'package:uuid/uuid.dart';

import '../providers/server_providers.dart';
import 'anirss_backend.dart';
import 'media_source_backend.dart';
import 'openlist_backend.dart';
import 'quark_backend.dart';
import 'source_http.dart';

/// 账密登录并构造（尚未持久化的）网盘源 [ServerConfig]。
///
/// UI 拿到返回值后自行 `serverListProvider.addServer(...)` 落库、设为当前服务器，
/// 保持 core 层不依赖 Riverpod。登录失败抛 [SourceException]。
class SourceLoginService {
  static const _uuid = Uuid();

  /// OpenList / AList 账密登录。
  static Future<ServerConfig> loginOpenList({
    required String name,
    required String baseUrl,
    required String username,
    required String password,
  }) async {
    final base = normalizeBaseUrl(baseUrl);
    final token = await OpenListBackend.login(base, username, password);
    final host = Uri.tryParse(base)?.host ?? base;
    return ServerConfig(
      id: _uuid.v4(),
      name: name.trim().isEmpty ? host : name.trim(),
      baseUrl: base,
      username: username.trim(),
      password: password,
      authToken: token,
      sourceKind: SourceKind.openlist,
    );
  }

  /// 夸克网盘 Cookie 登录：保存 Cookie 并列根目录验证有效性。
  static Future<ServerConfig> loginQuarkCookie({
    required String name,
    required String cookie,
  }) async {
    final trimmed = cookie.trim();
    if (trimmed.isEmpty) throw SourceException('请粘贴夸克 Cookie');
    final server = ServerConfig(
      id: _uuid.v4(),
      name: name.trim().isEmpty ? '夸克网盘' : name.trim(),
      baseUrl: QuarkBackend.api,
      authToken: trimmed, // Cookie 存 authToken
      sourceKind: SourceKind.quark,
    );
    // 列根目录验证 Cookie 是否有效。
    await QuarkBackend().verifyCookie(server);
    return server;
  }

  /// Ani-rss 账密登录。
  static Future<ServerConfig> loginAniRss({
    required String name,
    required String baseUrl,
    required String username,
    required String password,
  }) async {
    final base = normalizeBaseUrl(baseUrl);
    final token = await AniRssBackend.login(base, username, password);
    final host = Uri.tryParse(base)?.host ?? base;
    return ServerConfig(
      id: _uuid.v4(),
      name: name.trim().isEmpty ? host : name.trim(),
      baseUrl: base,
      username: username.trim(),
      password: password,
      authToken: token,
      sourceKind: SourceKind.anirss,
    );
  }
}
