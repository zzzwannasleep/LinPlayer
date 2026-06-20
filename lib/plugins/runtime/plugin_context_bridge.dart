import 'dart:convert';

import 'package:dio/dio.dart';

import '../../core/api/api_interfaces.dart';
import '../../core/providers/media_providers.dart';
import '../../core/providers/server_providers.dart';
import '../../core/services/app_logger.dart';
import '../manager/plugin_extension_registry.dart';
import '../models/plugin_extension_point.dart';
import '../models/plugin_manifest.dart';
import '../models/plugin_permission.dart';
import 'plugin_host_bindings.dart';
import 'plugin_player_bridge.dart';
import 'plugin_storage.dart';
import 'plugin_ui_host.dart';

/// 宿主侧的 ctx.* 调用分发器（每个插件一个实例）。
///
/// 接收引导脚本经 `__lp_host(channel, method, argsJson)` 发来的调用，
/// 做**权限检查**后执行真正的能力，返回 `{ok,value}/{ok,error}` 的 JSON 字符串。
class PluginContextBridge {
  static final AppLogger _log = AppLogger();

  final PluginManifest manifest;
  final PluginGrantedPermissions permissions;
  final PluginStorage storage;
  final PluginExtensionRegistry registry;

  /// HTTPS 域名白名单（来自 manifest 声明、经用户同意展示）。
  /// **空 = 拒绝所有出网**，绝不放行任意主机；且始终强制 HTTPS。
  final List<String> httpAllowedHosts;

  Dio? _httpDio;

  PluginContextBridge({
    required this.manifest,
    required this.permissions,
    required this.storage,
    required this.registry,
    required this.httpAllowedHosts,
  });

  String get pluginId => manifest.id;

  /// 入口：被引擎以 (channel, method, argsJson) 调用，返回 JSON 字符串。
  Future<String> dispatch(String channel, String method, String argsJson) async {
    try {
      final args = (jsonDecode(argsJson) as List).cast<dynamic>();
      final value = await _route(channel, method, args);
      return jsonEncode({'ok': true, 'value': value});
    } on PluginPermissionError catch (e) {
      return jsonEncode({'ok': false, 'error': e.toString()});
    } on PluginStorageQuotaError catch (e) {
      return jsonEncode({'ok': false, 'error': e.toString()});
    } catch (e) {
      _log.w('PluginCtx', '[$pluginId] $channel.$method 失败: $e');
      return jsonEncode({'ok': false, 'error': '$e'});
    }
  }

  void _require(String permissionId) {
    if (!permissions.has(permissionId)) {
      throw PluginPermissionError(pluginId, permissionId);
    }
  }

  Future<dynamic> _route(String channel, String method, List args) async {
    switch (channel) {
      case 'log':
        return _log_(method, args);
      case 'http':
        return _http(method, args);
      case 'storage':
        return _storage(method, args);
      case 'player':
        return _player(method, args);
      case 'ui':
        return _ui(method, args);
      case 'emby':
        return _emby(method, args);
      case 'extensions':
        return _extensions(method, args);
      case 'util':
        return _util(method, args);
      default:
        throw Exception('未知能力通道: $channel');
    }
  }

  // ---- log（始终允许）----
  dynamic _log_(String method, List args) {
    final msg = args.isNotEmpty ? '${args[0]}' : '';
    final tag = 'Plugin:$pluginId';
    switch (method) {
      case 'info':
        _log.i(tag, msg);
        break;
      case 'warn':
        _log.w(tag, msg);
        break;
      case 'error':
        _log.e(tag, msg);
        break;
    }
    return null;
  }

  // ---- http（仅 HTTPS + 白名单）----
  Future<dynamic> _http(String method, List args) async {
    _require(PluginPermissions.http.id);
    final url = '${args[0]}';
    final uri = Uri.parse(url);
    if (uri.scheme.toLowerCase() != 'https') {
      throw Exception('仅允许 HTTPS 请求: $url');
    }
    // 空白名单 = 拒绝所有（fail-closed）：插件必须在 manifest 声明 httpAllowedHosts
    // 并经用户同意，缺省/空绝不等于“放行任意主机”。
    if (!httpAllowedHosts.contains(uri.host)) {
      throw Exception('域名不在白名单内: ${uri.host}');
    }

    final dio = _httpDio ??= Dio(BaseOptions(
      connectTimeout: const Duration(seconds: 15),
      receiveTimeout: const Duration(seconds: 30),
      // 不抛异常，统一返回状态码给插件处理。
      validateStatus: (_) => true,
    ));

    Options buildOptions(Map opts) {
      final headers = <String, dynamic>{};
      final h = opts['headers'];
      if (h is Map) {
        h.forEach((k, v) => headers['$k'] = '$v');
      }
      return Options(headers: headers);
    }

    Response response;
    if (method == 'get') {
      final opts = args.length > 1 && args[1] is Map ? args[1] as Map : {};
      response = await dio.getUri(
        uri.replace(queryParameters: _mergeQuery(uri, opts['query'])),
        options: buildOptions(opts),
      );
    } else if (method == 'post') {
      final body = args.length > 1 ? args[1] : null;
      final opts = args.length > 2 && args[2] is Map ? args[2] as Map : {};
      response = await dio.postUri(
        uri.replace(queryParameters: _mergeQuery(uri, opts['query'])),
        data: _encodeBody(body, opts),
        options: buildOptions(opts),
      );
    } else {
      throw Exception('不支持的 http 方法: $method');
    }

    // 防重定向绕白名单（L1）：白名单主机若 302 跳到名单外/内网，最终 URL 的
    // host 必须仍在白名单，否则拒绝把重定向内容回传给插件。
    final finalHost = response.realUri.host;
    if (!httpAllowedHosts.contains(finalHost)) {
      throw Exception('请求经重定向到了白名单外主机: $finalHost');
    }

    return {
      'status': response.statusCode,
      'headers': response.headers.map,
      'body': _decodeResponse(response.data),
    };
  }

  Map<String, dynamic>? _mergeQuery(Uri uri, dynamic extra) {
    final merged = <String, dynamic>{...uri.queryParameters};
    if (extra is Map) {
      extra.forEach((k, v) => merged['$k'] = '$v');
    }
    return merged.isEmpty ? null : merged;
  }

  dynamic _encodeBody(dynamic body, Map opts) {
    final contentType =
        (opts['headers'] is Map) ? '${(opts['headers'] as Map)['Content-Type'] ?? ''}' : '';
    if (body is Map || body is List) {
      // 默认按 JSON 发送（dio 会根据 data 类型设置 application/json）。
      return body;
    }
    if (contentType.contains('json') && body is String) {
      try {
        return jsonDecode(body);
      } catch (_) {}
    }
    return body;
  }

  dynamic _decodeResponse(dynamic data) {
    if (data is String) {
      final trimmed = data.trim();
      if (trimmed.startsWith('{') || trimmed.startsWith('[')) {
        try {
          return jsonDecode(trimmed);
        } catch (_) {}
      }
      return data;
    }
    return data; // dio 已解析的 Map/List
  }

  // ---- storage ----
  Future<dynamic> _storage(String method, List args) async {
    _require(PluginPermissions.storage.id);
    switch (method) {
      case 'get':
        return storage.get('${args[0]}');
      case 'set':
        await storage.set('${args[0]}', args.length > 1 ? args[1] : null);
        return null;
      case 'delete':
        await storage.delete('${args[0]}');
        return null;
      case 'keys':
        return storage.keys();
      case 'clear':
        await storage.clear();
        return null;
      default:
        throw Exception('未知 storage 方法: $method');
    }
  }

  // ---- player ----
  Future<dynamic> _player(String method, List args) async {
    final bridge = PluginPlayerBridge.instance;
    switch (method) {
      case 'getCurrentMedia':
        _require(PluginPermissions.playerRead.id);
        return _currentMediaFromProviders() ?? bridge.currentMedia;
      case 'play':
        _require(PluginPermissions.playerControl.id);
        await bridge.hooks?.play?.call();
        return null;
      case 'pause':
        _require(PluginPermissions.playerControl.id);
        await bridge.hooks?.pause?.call();
        return null;
      case 'seek':
        _require(PluginPermissions.playerControl.id);
        final seconds = (args.isNotEmpty ? args[0] : 0) as num;
        await bridge.hooks?.seek
            ?.call(Duration(milliseconds: (seconds * 1000).round()));
        return null;
      default:
        throw Exception('未知 player 方法: $method');
    }
  }

  Map<String, dynamic>? _currentMediaFromProviders() {
    final container = PluginHostBindings.instance.container;
    if (container == null) return null;
    final item = container.read(currentPlayingItemProvider);
    if (item == null) return null;
    return serializeMediaItem(item);
  }

  // ---- ui ----
  Future<dynamic> _ui(String method, List args) async {
    _require(PluginPermissions.ui.id);
    switch (method) {
      case 'showToast':
        PluginUiHost.showToast('${args[0]}');
        return null;
      case 'showDialog':
        return PluginUiHost.showAlert(
            (args.isNotEmpty && args[0] is Map) ? args[0] as Map : {});
      case 'showForm':
        return PluginUiHost.showForm(
            (args.isNotEmpty && args[0] is Map) ? args[0] as Map : {});
      case 'openPage':
        return PluginUiHost.openPage(
          pluginId,
          args.isNotEmpty ? '${args[0]}' : '',
          (args.length > 1 && args[1] is Map) ? args[1] as Map : const {},
        );
      default:
        throw Exception('未知 ui 方法: $method');
    }
  }

  // ---- emby ----
  Future<dynamic> _emby(String method, List args) async {
    final container = PluginHostBindings.instance.container;
    if (container == null) throw Exception('应用未就绪');

    switch (method) {
      case 'getServerUrl':
        _require(PluginPermissions.embyRead.id);
        return container.read(currentServerProvider)?.activeLineUrl;
      case 'getServerInfo':
        _require(PluginPermissions.embyRead.id);
        final s = container.read(currentServerProvider);
        if (s == null) return null;
        return {
          'url': s.activeLineUrl,
          'baseUrl': s.baseUrl,
          'name': s.name,
          'username': s.username,
          'userId': s.userId,
        };
      case 'getCurrentUser':
        _require(PluginPermissions.embyRead.id);
        final user = await container.read(currentUserProvider.future);
        if (user == null) return null;
        return {'id': user.id, 'name': user.name};
      case 'getCredentials':
        _require(PluginPermissions.embyCredentials.id);
        final s = container.read(currentServerProvider);
        if (s == null) return null;
        // M1：逐次确认 + 明文密码警告，用户拒绝则视为本次未授权。
        final approved =
            await PluginUiHost.confirmCredentialAccess(manifest.name);
        if (!approved) {
          throw PluginPermissionError(
              pluginId, PluginPermissions.embyCredentials.id);
        }
        return {
          'username': s.username,
          'password': s.password,
          'url': s.activeLineUrl,
        };
      case 'apiRequest':
        _require(PluginPermissions.embyApi.id);
        return _embyApiRequest(
            container, (args.isNotEmpty && args[0] is Map) ? args[0] as Map : {});
      default:
        throw Exception('未知 emby 方法: $method');
    }
  }

  Future<dynamic> _embyApiRequest(container, Map opts) async {
    final server = container.read(currentServerProvider) as ServerConfig?;
    if (server == null) throw Exception('未连接服务器');
    final base = server.activeLineUrl;
    final path = '${opts['path'] ?? ''}';
    final httpMethod = '${opts['method'] ?? 'GET'}'.toUpperCase();

    final dio = Dio(BaseOptions(
      baseUrl: base,
      connectTimeout: const Duration(seconds: 15),
      receiveTimeout: const Duration(seconds: 30),
      validateStatus: (_) => true,
      headers: {
        if (server.authToken != null) 'X-Emby-Token': server.authToken,
        'X-Emby-Client': 'Linplayer',
      },
    ));

    final query = (opts['query'] is Map)
        ? (opts['query'] as Map).map((k, v) => MapEntry('$k', v))
        : null;
    final baseUri = Uri.parse(base);
    final resolved = baseUri.resolve(path);
    // 防 SSRF：path 形如 `//evil.com/x` 或绝对 URL 会改写主机，但仍会带上
    // X-Emby-Token。解析后必须仍指向同一服务器，否则拒绝，杜绝 Token 外泄。
    if (resolved.scheme != baseUri.scheme ||
        resolved.host != baseUri.host ||
        resolved.port != baseUri.port) {
      throw Exception('apiRequest 路径越权指向了其它主机: ${resolved.host}');
    }
    final response = await dio.requestUri(
      resolved.replace(
        queryParameters: query?.map((k, v) => MapEntry(k, '$v')),
      ),
      data: opts['body'],
      options: Options(method: httpMethod),
    );
    return {
      'status': response.statusCode,
      'body': _decodeResponse(response.data),
    };
  }

  // ---- extensions ----
  Future<dynamic> _extensions(String method, List args) async {
    _require(PluginPermissions.extensions.id);
    switch (method) {
      case 'register':
        final type = PluginExtensionType.fromId('${args[0]}');
        if (type == null) throw Exception('未知扩展点类型: ${args[0]}');
        final desc =
            (args.length > 1 && args[1] is Map) ? args[1] as Map : const {};
        final id = '${desc['id'] ?? 'ext_${DateTime.now().microsecondsSinceEpoch}'}';
        final ok = registry.register(PluginExtension(
          pluginId: pluginId,
          type: type,
          id: id,
          data: Map<String, dynamic>.from(desc),
        ));
        return {'id': id, 'registered': ok};
      case 'unregister':
        final type = PluginExtensionType.fromId('${args[0]}');
        if (type == null) throw Exception('未知扩展点类型: ${args[0]}');
        registry.unregister(pluginId, type, '${args[1]}');
        return null;
      default:
        throw Exception('未知 extensions 方法: $method');
    }
  }

  // ---- util（无需权限）----
  Future<dynamic> _util(String method, List args) async {
    switch (method) {
      case 'sleep':
        // 退避/重试用的延时，封顶 10s（避免占用单次调用预算过久）。
        final ms = (args.isNotEmpty ? args[0] : 0) as num;
        final clamped = ms.clamp(0, 10000).toInt();
        await Future<void>.delayed(Duration(milliseconds: clamped));
        return null;
      default:
        throw Exception('未知 util 方法: $method');
    }
  }

  void dispose() {
    _httpDio?.close(force: true);
    _httpDio = null;
  }
}

/// 把 [MediaItem] 序列化为传给插件的精简对象。
Map<String, dynamic> serializeMediaItem(MediaItem item) {
  return {
    'id': item.id,
    'name': item.name,
    'type': item.type,
    'seriesName': item.seriesName,
    'indexNumber': item.indexNumber,
    'parentIndexNumber': item.parentIndexNumber,
    'overview': item.overview,
    'productionYear': item.productionYear,
    'runTimeTicks': item.runTimeTicks,
    'seriesId': item.seriesId,
    'seasonId': item.seasonId,
  };
}
