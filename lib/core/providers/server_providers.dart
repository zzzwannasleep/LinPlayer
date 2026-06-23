import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../api/api_interfaces.dart';
import '../api/emby_api.dart';
import '../network/proxy_http_client.dart';
import '../services/secure_credential_store.dart';
import 'app_preferences.dart';

enum AuthState { unauthenticated, authenticating, authenticated, error }

bool serverHasUsableAuth(ServerConfig? server) {
  final token = server?.authToken;
  return token != null && token.isNotEmpty;
}

/// 服务器取流形态（L0 自调档用，仅影响缓冲/重取流时机，不改控制流）。
/// - [unknown]：未判定，按通用档位。
/// - [cloud302]：国内 302 网盘服（签名 CDN 直链短效，暂停/seek 易过期）→ 重取流 TTL 调短。
/// - [directDisk]：硬盘直传服（长链接稳定，主要风险是跨境抖动）→ 沿用宽松档位。
enum StreamServerKind { unknown, cloud302, directDisk }

StreamServerKind streamServerKindFromName(String? name) {
  switch (name) {
    case 'cloud302':
      return StreamServerKind.cloud302;
    case 'directDisk':
      return StreamServerKind.directDisk;
    default:
      return StreamServerKind.unknown;
  }
}

class ServerConfig {
  final String id;
  final String name;
  final String baseUrl;
  final String? iconUrl;
  final String? remark;
  final List<ServerLine> lines;
  final int activeLineIndex;
  final String? username;
  final String? authToken;
  final String? userId;
  // 登录密码（可选）。用于需要凭据重新登录的场景（如插件登录配套网站）。
  // 仅在用户添加服务器时填写后保存；通过权限 emby.credentials 暴露给插件。
  final String? password;
  // 是否信任该服务器的自签名/无效 TLS 证书（不安全）。默认 false=严格校验。
  // 仅当用户在编辑服务器页显式开启时，才把本服务器的主机加入放行白名单；
  // 不影响更新下载、WebDAV、其它主机的 TLS 校验。
  final bool allowInsecureTls;

  // L0 取流形态：从播放时的 MediaSource 被动推断（远端/直传），仅用于断流恢复调档。
  final StreamServerKind streamKind;

  ServerConfig({
    required this.id,
    required this.name,
    required this.baseUrl,
    this.iconUrl,
    this.remark,
    this.lines = const [],
    this.activeLineIndex = 0,
    this.username,
    this.authToken,
    this.userId,
    this.password,
    this.allowInsecureTls = false,
    this.streamKind = StreamServerKind.unknown,
  });

  String get activeLineUrl {
    if (lines.isEmpty) return baseUrl;
    final safeIndex = activeLineIndex.clamp(0, lines.length - 1);
    return lines[safeIndex].url;
  }

  ServerConfig copyWith({
    String? id,
    String? name,
    String? baseUrl,
    String? iconUrl,
    String? remark,
    List<ServerLine>? lines,
    int? activeLineIndex,
    String? username,
    String? authToken,
    String? userId,
    String? password,
    bool? allowInsecureTls,
    StreamServerKind? streamKind,
  }) {
    return ServerConfig(
      id: id ?? this.id,
      name: name ?? this.name,
      baseUrl: baseUrl ?? this.baseUrl,
      iconUrl: iconUrl ?? this.iconUrl,
      remark: remark ?? this.remark,
      lines: lines ?? this.lines,
      activeLineIndex: activeLineIndex ?? this.activeLineIndex,
      username: username ?? this.username,
      authToken: authToken ?? this.authToken,
      userId: userId ?? this.userId,
      password: password ?? this.password,
      allowInsecureTls: allowInsecureTls ?? this.allowInsecureTls,
      streamKind: streamKind ?? this.streamKind,
    );
  }
}

class ServerLine {
  final String id;
  final String name;
  final String url;
  final String? remark;

  ServerLine({
    required this.id,
    required this.name,
    required this.url,
    this.remark,
  });
}

final authStateProvider = StateProvider<AuthState>((ref) => AuthState.unauthenticated);

final serverListProvider = StateNotifierProvider<ServerListNotifier, List<ServerConfig>>((ref) {
  return ServerListNotifier();
});

final currentServerProvider = StateNotifierProvider<CurrentServerNotifier, ServerConfig?>((ref) {
  final notifier = CurrentServerNotifier(ref.read(serverListProvider));
  ref.listen<List<ServerConfig>>(serverListProvider, (_, next) {
    notifier.syncWithAvailableServers(
      next,
      preferredServerId: notifier.selectedServerId,
    );
  });
  return notifier;
});

final apiClientProvider = Provider<ApiClientFactory>((ref) {
  final server = ref.watch(currentServerProvider);
  if (server == null) throw StateError('未连接服务器，请先添加服务器');
  return EmbyApiClient(
    baseUrl: server.activeLineUrl,
    authToken: server.authToken,
    userId: server.userId,
  );
});

/// 按服务器 ID 缓存的只读 ApiClient。
///
/// 聚合搜索的结果可能来自非当前服务器，解析其封面/海报、跨服务器打开前都需要
/// 对应服务器的 client。用 family 缓存复用同一实例，避免在卡片 build 路径里反复
/// `new EmbyApiClient` 泄漏 ProxyRuntime 监听（见 [EmbyApiClient.dispose]）。
/// 未登录或不存在的服务器返回 null，调用方回退到当前服务器。
final serverApiClientProvider =
    Provider.family<ApiClientFactory?, String>((ref, serverId) {
  final server =
      ref.watch(serverListProvider).where((s) => s.id == serverId).firstOrNull;
  if (server == null || (server.authToken ?? '').isEmpty) return null;
  final client = EmbyApiClient(
    baseUrl: server.activeLineUrl,
    authToken: server.authToken,
    userId: server.userId,
  );
  ref.onDispose(client.dispose);
  return client;
});

final currentUserProvider = FutureProvider<User?>((ref) async {
  final currentServer = ref.watch(currentServerProvider);
  if (!serverHasUsableAuth(currentServer)) return null;

  try {
    final api = ref.watch(apiClientProvider);
    return await api.user.getUser('current');
  } catch (_) {
    return null;
  }
});

class CurrentServerNotifier extends StateNotifier<ServerConfig?> {
  CurrentServerNotifier([List<ServerConfig> availableServers = const []])
      : super(_restoreCurrentServer(availableServers));

  static const _currentServerKey = 'linplayer_current_server_id';

  String? get selectedServerId => state?.id;

  static ServerConfig? _restoreCurrentServer(
    List<ServerConfig> servers, {
    String? preferredServerId,
  }) {
    try {
      final serverId =
          preferredServerId ?? AppPreferencesStore.instance.getString(_currentServerKey);
      if (serverId != null) {
        final saved = servers.where((server) => server.id == serverId).firstOrNull;
        if (saved != null) {
          return saved;
        }
      }
    } catch (_) {
      // Ignore restore failures and fall back below.
    }
    return servers.firstOrNull;
  }

  Future<void> loadFromSaved(
    List<ServerConfig> servers, {
    String? preferredServerId,
  }) async {
    syncWithAvailableServers(
      servers,
      preferredServerId: preferredServerId,
    );
  }

  void syncWithAvailableServers(
    List<ServerConfig> servers, {
    String? preferredServerId,
  }) {
    state = _restoreCurrentServer(
      servers,
      preferredServerId: preferredServerId,
    );
  }

  Future<void> _saveCurrentServer() async {
    try {
      final prefs = AppPreferencesStore.instance;
      if (state != null) {
        await prefs.setString(_currentServerKey, state!.id);
      } else {
        await prefs.remove(_currentServerKey);
      }
    } catch (_) {
      // Ignore persistence failures and keep the in-memory state.
    }
  }

  @override
  set state(ServerConfig? value) {
    super.state = value;
    _saveCurrentServer();
  }

  void clear() {
    state = null;
  }
}

class ServerListNotifier extends StateNotifier<List<ServerConfig>> {
  ServerListNotifier() : super(_loadServersSync()) {
    // 初始加载不经过 set state 覆写，这里补一次白名单同步。
    _syncInsecureTlsHosts();
  }

  static const _serversKey = 'linplayer_servers';

  // 任何服务器列表变更都重建“放行不安全 TLS”的主机白名单。
  @override
  set state(List<ServerConfig> value) {
    super.state = value;
    _syncInsecureTlsHosts();
  }

  void _syncInsecureTlsHosts() {
    final hosts = <String>{};
    for (final server in state) {
      if (!server.allowInsecureTls) continue;
      for (final url in [server.baseUrl, ...server.lines.map((l) => l.url)]) {
        final host = Uri.tryParse(url.trim())?.host;
        if (host != null && host.isNotEmpty) hosts.add(host);
      }
    }
    setInsecureTlsHosts(hosts);
  }

  static List<ServerConfig> _loadServersSync() {
    try {
      final jsonStr = AppPreferencesStore.instance.getString(_serversKey);
      if (jsonStr != null) {
        final List<dynamic> jsonList = jsonDecode(jsonStr);
        final servers = jsonList
            .map((entry) => _serverConfigFromJson(entry as Map<String, dynamic>))
            .toList();
        debugPrint('[ServerList] Loaded ${servers.length} servers');
        for (final server in servers) {
          debugPrint(
            '[ServerList] Loaded ${server.name}: authToken=${server.authToken != null ? 'present' : 'null'}, userId=${server.userId}',
          );
        }
        return servers;
      }
    } catch (e) {
      debugPrint('[ServerList] Load failed: $e');
    }
    return const [];
  }

  Future<void> _saveServers() async {
    try {
      // 持久化到 SharedPreferences 时**剥离**密码/Token（含密的明文不落 prefs）。
      final jsonList =
          state.map((s) => _serverConfigToJson(s, includeSecrets: false)).toList();
      await AppPreferencesStore.instance.setString(_serversKey, jsonEncode(jsonList));
      // 密码/Token 写入 OS 安全存储。
      for (final server in state) {
        await SecureCredentialStore.instance.write(
          server.id,
          password: server.password,
          authToken: server.authToken,
        );
      }
    } catch (e) {
      debugPrint('[ServerList] Save failed: $e');
    }
  }

  void addServer(ServerConfig server) {
    state = [...state, server];
    _saveServers();
  }

  void removeServer(String id) {
    state = state.where((server) => server.id != id).toList();
    SecureCredentialStore.instance.remove(id);
    _saveServers();
  }

  void updateServer(ServerConfig server) {
    state = state.map((entry) => entry.id == server.id ? server : entry).toList();
    _saveServers();
  }

  void replaceServers(List<ServerConfig> servers) {
    state = List<ServerConfig>.from(servers);
    _saveServers();
  }

  void reorderServers(int oldIndex, int newIndex) {
    final servers = List<ServerConfig>.from(state);
    if (oldIndex < newIndex) {
      newIndex -= 1;
    }
    final server = servers.removeAt(oldIndex);
    servers.insert(newIndex, server);
    state = servers;
    _saveServers();
  }

  void setActiveLine(String serverId, int lineIndex) {
    state = state.map((server) {
      if (server.id == serverId) {
        final safeIndex = server.lines.isEmpty
            ? 0
            : lineIndex.clamp(0, server.lines.length - 1);
        return server.copyWith(activeLineIndex: safeIndex);
      }
      return server;
    }).toList();
    _saveServers();
  }

  /// L0：回填服务器取流形态（首次播放时按 MediaSource 推断）。无变化则跳过，避免无谓持久化。
  void setStreamKind(String serverId, StreamServerKind kind) {
    var changed = false;
    final next = state.map((server) {
      if (server.id == serverId && server.streamKind != kind) {
        changed = true;
        return server.copyWith(streamKind: kind);
      }
      return server;
    }).toList();
    if (!changed) return;
    state = next;
    _saveServers();
  }
}

/// 序列化服务器配置。[includeSecrets] 为 false 时**不写入**密码/Token
/// （用于 SharedPreferences 持久化，密文改存 OS 安全存储）；备份导出需带凭据
/// 时传 true（备份会另行用口令加密整包，见 H12）。
Map<String, dynamic> _serverConfigToJson(ServerConfig server,
    {bool includeSecrets = true}) {
  return {
    'id': server.id,
    'name': server.name,
    'baseUrl': server.baseUrl,
    'iconUrl': server.iconUrl,
    'remark': server.remark,
    'lines': server.lines
        .map((line) => {
              'id': line.id,
              'name': line.name,
              'url': line.url,
              'remark': line.remark,
            })
        .toList(),
    'activeLineIndex': server.activeLineIndex,
    'username': server.username,
    if (includeSecrets) 'authToken': server.authToken,
    'userId': server.userId,
    if (includeSecrets) 'password': server.password,
    'allowInsecureTls': server.allowInsecureTls,
    'streamKind': server.streamKind.name,
  };
}

ServerConfig _serverConfigFromJson(Map<String, dynamic> json) {
  final lines = (json['lines'] as List<dynamic>?)
          ?.map(
            (line) => ServerLine(
              id: line['id'] as String,
              name: line['name'] as String,
              url: line['url'] as String,
              remark: line['remark'] as String?,
            ),
          )
          .toList() ??
      const <ServerLine>[];
  final activeLineIndex = json['activeLineIndex'] as int? ?? 0;
  final id = json['id'] as String;
  // 优先用 JSON 内的明文（备份恢复路径已解密带上），否则从 OS 安全存储取
  // （SharedPreferences 持久化路径已剥离密码/Token）。
  final secret = SecureCredentialStore.instance.read(id);

  return ServerConfig(
    id: id,
    name: json['name'] as String,
    baseUrl: json['baseUrl'] as String,
    iconUrl: json['iconUrl'] as String?,
    remark: json['remark'] as String?,
    lines: lines,
    activeLineIndex: lines.isEmpty
        ? 0
        : activeLineIndex.clamp(0, lines.length - 1),
    username: _emptyToNull(json['username'] as String?),
    authToken: _emptyToNull(json['authToken'] as String?) ?? secret?.authToken,
    userId: _emptyToNull(json['userId'] as String?),
    password: _emptyToNull(json['password'] as String?) ?? secret?.password,
    // 迁移：旧版本服务器无此字段，过去对所有主机放行坏证书。为不破坏现有
    // （含自签名 Emby）用户的连接，缺字段时默认 true 保留原放行行为；放行范围
    // 已收敛到本服务器自身主机。新加服务器走构造默认 false（严格校验）。
    allowInsecureTls: json['allowInsecureTls'] as bool? ?? true,
    // 迁移：旧数据无此字段 → unknown，首次播放时按 MediaSource 推断回填。
    streamKind: streamServerKindFromName(json['streamKind'] as String?),
  );
}

Map<String, dynamic> serverConfigToJson(ServerConfig server) => _serverConfigToJson(server);

ServerConfig serverConfigFromJson(Map<String, dynamic> json) => _serverConfigFromJson(json);

String? _emptyToNull(String? value) {
  if (value == null || value.isEmpty) return null;
  return value;
}
