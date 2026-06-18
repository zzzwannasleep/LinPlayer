import 'dart:convert';

/// 代理协议类型。
///
/// - [http] / [https]：标准 HTTP(S) 代理（通过 CONNECT 隧道转发 https 流量）。
///   Dart 的 `HttpClient.findProxy` 原生支持此类型。
/// - [socks4] / [socks5]：SOCKS 代理，依赖 `socks5_proxy` 包。
///
/// ⚠️ libmpv 仅支持 HTTP 代理（`http-proxy` 属性），不支持 SOCKS。
/// 因此 SOCKS 代理只对 Dart 层请求（API/图片/字幕/下载）生效；
/// 媒体流走 SOCKS 需在 Android TV 上经 mihomo 本地 HTTP 口中转。
enum ProxyType {
  none,
  http,
  https,
  socks4,
  socks5;

  /// 用于持久化的稳定字符串值。
  String get storageKey => name;

  /// 是否为 SOCKS 系列代理。
  bool get isSocks => this == ProxyType.socks4 || this == ProxyType.socks5;

  /// 是否为 HTTP 系列代理（含 https）。
  bool get isHttp => this == ProxyType.http || this == ProxyType.https;

  /// 面向用户的显示名。
  String get label {
    switch (this) {
      case ProxyType.none:
        return '不使用代理';
      case ProxyType.http:
        return 'HTTP';
      case ProxyType.https:
        return 'HTTPS';
      case ProxyType.socks4:
        return 'SOCKS4';
      case ProxyType.socks5:
        return 'SOCKS5';
    }
  }

  static ProxyType fromStorage(String? value) {
    return ProxyType.values.firstWhere(
      (e) => e.storageKey == value,
      orElse: () => ProxyType.none,
    );
  }
}

/// 用户自定义代理配置（三端通用）。
class ProxyConfig {
  final ProxyType type;
  final String host;
  final int port;
  final String username;
  final String password;

  /// 是否让媒体流（libmpv 播放）也走代理。
  ///
  /// 关闭时仅 API/图片/字幕/下载等 Dart 层请求走代理，播放保持直连——
  /// 适合「鉴权接口需要翻墙、但媒体走直连 CDN」的场景。
  final bool proxyMedia;

  const ProxyConfig({
    this.type = ProxyType.none,
    this.host = '',
    this.port = 0,
    this.username = '',
    this.password = '',
    this.proxyMedia = true,
  });

  static const ProxyConfig disabled = ProxyConfig();

  /// 配置是否有效启用（类型非 none 且 host/port 合法）。
  bool get isEnabled =>
      type != ProxyType.none && host.trim().isNotEmpty && port > 0;

  bool get hasCredentials => username.isNotEmpty;

  /// 该配置是否会作用于媒体流（libmpv）。
  /// 仅 HTTP 系列代理且开启 proxyMedia 时为真（mpv 不支持 SOCKS）。
  bool get appliesToMedia => isEnabled && proxyMedia && type.isHttp;

  /// mpv `http-proxy` 属性值，例如 `http://user:pass@host:port`。
  /// 仅 HTTP 系列代理返回非空。
  String? get mpvHttpProxy {
    if (!isEnabled || !type.isHttp) return null;
    final auth = hasCredentials
        ? '${Uri.encodeComponent(username)}:${Uri.encodeComponent(password)}@'
        : '';
    return 'http://$auth$host:$port';
  }

  ProxyConfig copyWith({
    ProxyType? type,
    String? host,
    int? port,
    String? username,
    String? password,
    bool? proxyMedia,
  }) {
    return ProxyConfig(
      type: type ?? this.type,
      host: host ?? this.host,
      port: port ?? this.port,
      username: username ?? this.username,
      password: password ?? this.password,
      proxyMedia: proxyMedia ?? this.proxyMedia,
    );
  }

  Map<String, dynamic> toJson() => {
        'type': type.storageKey,
        'host': host,
        'port': port,
        'username': username,
        'password': password,
        'proxyMedia': proxyMedia,
      };

  factory ProxyConfig.fromJson(Map<String, dynamic> json) {
    return ProxyConfig(
      type: ProxyType.fromStorage(json['type'] as String?),
      host: (json['host'] as String?) ?? '',
      port: (json['port'] as num?)?.toInt() ?? 0,
      username: (json['username'] as String?) ?? '',
      password: (json['password'] as String?) ?? '',
      proxyMedia: (json['proxyMedia'] as bool?) ?? true,
    );
  }

  String encode() => jsonEncode(toJson());

  static ProxyConfig decode(String? raw) {
    if (raw == null || raw.isEmpty) return ProxyConfig.disabled;
    try {
      return ProxyConfig.fromJson(jsonDecode(raw) as Map<String, dynamic>);
    } catch (_) {
      return ProxyConfig.disabled;
    }
  }

  @override
  bool operator ==(Object other) =>
      other is ProxyConfig &&
      other.type == type &&
      other.host == host &&
      other.port == port &&
      other.username == username &&
      other.password == password &&
      other.proxyMedia == proxyMedia;

  @override
  int get hashCode =>
      Object.hash(type, host, port, username, password, proxyMedia);
}

/// 全局代理运行时状态。
///
/// 之所以需要一个单例：构造 `HttpClient` 的工厂回调是同步的，
/// 无法在其中读取 Riverpod。Provider 在配置变更时把最新值写入这里，
/// 网络层的同步工厂读取 [current]，并通过 [addListener] 通知各客户端重建。
class ProxyRuntime {
  ProxyRuntime._();
  static final ProxyRuntime instance = ProxyRuntime._();

  ProxyConfig _current = ProxyConfig.disabled;

  /// 自增版本号，便于客户端判断是否需要重建底层连接。
  int _revision = 0;

  final List<void Function()> _listeners = [];

  ProxyConfig get current => _current;
  int get revision => _revision;

  /// 由 Provider 在配置变更时调用。
  void update(ProxyConfig config) {
    if (config == _current) return;
    _current = config;
    _revision++;
    for (final listener in List<void Function()>.of(_listeners)) {
      try {
        listener();
      } catch (_) {
        // 单个监听者异常不应影响其他监听者。
      }
    }
  }

  /// 注册「代理变更」回调（如重建 Dio / 关闭缓存的 HttpClient）。
  /// 返回取消注册的函数。
  void Function() addListener(void Function() listener) {
    _listeners.add(listener);
    return () => _listeners.remove(listener);
  }
}
