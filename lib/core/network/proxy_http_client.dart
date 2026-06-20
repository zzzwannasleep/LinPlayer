import 'dart:io';

import 'package:dio/dio.dart';
import 'package:dio/io.dart';
import 'package:socks5_proxy/socks_client.dart';

import '../app_identity.dart';
import 'proxy_settings.dart';

/// 把用户代理配置应用到 Dart 的 `HttpClient` / Dio。
///
/// 设计要点：
/// - 构造 `HttpClient` 的工厂回调是同步的，因此 SOCKS 代理所需的
///   [InternetAddress] 必须提前解析好并缓存（见 [prewarmProxy]）。
/// - HTTP(S) 代理走 `HttpClient.findProxy`；SOCKS 走 `socks5_proxy`
///   的 `connectionFactory`。
/// - TLS 默认走系统标准校验。仅当某个主机被用户显式批准（见
///   [setInsecureTlsHosts]，由服务器配置的 `allowInsecureTls` 开关驱动）
///   才放行自签名/无效证书；更新下载、WebDAV、图片 CDN 等其它主机始终严格校验。

/// 已被用户显式批准“放行自签名/无效证书”的主机名集合（小写）。
///
/// 默认空集合 = 全局严格 TLS 校验。由 [setInsecureTlsHosts] 在服务器
/// 列表变化时整体重建，只收录开启了 `allowInsecureTls` 的服务器自身的
/// baseUrl/线路主机，因此放行范围被收敛到“用户主动信任的那台服务器”。
final Set<String> _insecureTlsHosts = <String>{};

/// 用允许放行不安全 TLS 的主机名整体替换白名单（大小写不敏感）。
void setInsecureTlsHosts(Iterable<String> hosts) {
  _insecureTlsHosts
    ..clear()
    ..addAll(
      hosts.map((h) => h.trim().toLowerCase()).where((h) => h.isNotEmpty),
    );
}

/// 坏证书回调：默认拒绝（返回 false），仅放行白名单内主机。
bool _allowBadCertificate(X509Certificate cert, String host, int port) {
  return _insecureTlsHosts.contains(host.toLowerCase());
}

class _SocksResolution {
  final String host;
  final InternetAddress address;
  const _SocksResolution(this.host, this.address);
}

_SocksResolution? _socksResolution;

/// 预解析 SOCKS 代理主机名为 IP，并缓存供同步工厂使用。
///
/// Provider 在写入 [ProxyRuntime] 之前应 await 此函数，确保 SOCKS
/// 主机名（非 IP）能被同步工厂消费。HTTP 代理无需解析。
Future<void> prewarmProxy(ProxyConfig config) async {
  if (!config.isEnabled || !config.type.isSocks) {
    _socksResolution = null;
    return;
  }
  final host = config.host.trim();
  // 已是 IP，直接用。
  final parsed = InternetAddress.tryParse(host);
  if (parsed != null) {
    _socksResolution = _SocksResolution(host, parsed);
    return;
  }
  // 复用已解析结果。
  if (_socksResolution?.host == host) return;
  try {
    final results = await InternetAddress.lookup(host);
    if (results.isNotEmpty) {
      _socksResolution = _SocksResolution(host, results.first);
    }
  } catch (_) {
    // 解析失败时清空，工厂会退回直连（代理在解析成功后生效）。
    _socksResolution = null;
  }
}

/// 把代理配置应用到一个已创建的 `HttpClient`（[resolution] 为 SOCKS 已解析地址）。
void _applyProxy(
    HttpClient client, ProxyConfig config, _SocksResolution? resolution) {
  if (!config.isEnabled) return;

  if (config.type.isHttp) {
    final hostPort = '${config.host.trim()}:${config.port}';
    client.findProxy = (uri) => 'PROXY $hostPort';
    if (config.hasCredentials) {
      client.addProxyCredentials(
        config.host.trim(),
        config.port,
        '',
        HttpClientBasicCredentials(config.username, config.password),
      );
    }
    return;
  }

  // SOCKS4/5：需要已解析的 InternetAddress。
  final addr = resolution?.host == config.host.trim()
      ? resolution!.address
      : InternetAddress.tryParse(config.host.trim());
  if (addr == null) {
    // 主机名尚未解析完成，本次退回直连，待 prewarm 完成后重建。
    return;
  }
  SocksTCPClient.assignToHttpClient(client, [
    ProxySettings(
      addr,
      config.port,
      username: config.hasCredentials ? config.username : null,
      password: config.hasCredentials ? config.password : null,
    ),
  ]);
}

/// 创建一个应用了当前代理配置的 `HttpClient`。
HttpClient createProxiedHttpClient() {
  final client = HttpClient()
    ..badCertificateCallback = _allowBadCertificate
    // 统一默认 UA：部分 CDN（含 Emby 图片）会拒绝空/Dart 默认 UA 导致封面空白。
    // Dio 请求自带显式 User-Agent 头，会覆盖此默认值，互不冲突。
    ..userAgent = kAppUserAgent;
  _applyProxy(client, ProxyRuntime.instance.current, _socksResolution);
  return client;
}

/// 创建一个应用了当前代理、但**始终**走严格 TLS 校验的 `HttpClient`。
///
/// 用于更新下载、安装包获取等绝不能放行坏证书的场景：不设置
/// [badCertificateCallback]，因此完全不受 [setInsecureTlsHosts] 白名单影响，
/// 即使用户为某服务器开了“信任自签名证书”，更新下载仍强制严格校验。
HttpClient createStrictProxiedHttpClient() {
  final client = HttpClient()..userAgent = kAppUserAgent;
  _applyProxy(client, ProxyRuntime.instance.current, _socksResolution);
  return client;
}

/// 让一个 Dio 实例走当前代理，但强制严格 TLS（更新下载等安全敏感场景）。
void applyStrictProxyToDio(Dio dio) {
  final adapter = dio.httpClientAdapter;
  if (adapter is IOHttpClientAdapter) {
    adapter.createHttpClient = createStrictProxiedHttpClient;
  } else {
    dio.httpClientAdapter = IOHttpClientAdapter(
      createHttpClient: createStrictProxiedHttpClient,
    );
  }
}

/// 用给定配置（而非全局配置）做一次连通性测试，供设置页「测试连接」使用。
Future<({bool ok, String message})> testProxyConnection(
  ProxyConfig config, {
  String testUrl = 'https://www.gstatic.com/generate_204',
}) async {
  if (!config.isEnabled) {
    return (ok: false, message: '代理未启用或配置不完整');
  }

  _SocksResolution? resolution;
  if (config.type.isSocks) {
    final host = config.host.trim();
    final parsed = InternetAddress.tryParse(host);
    if (parsed != null) {
      resolution = _SocksResolution(host, parsed);
    } else {
      try {
        final results = await InternetAddress.lookup(host);
        if (results.isNotEmpty) {
          resolution = _SocksResolution(host, results.first);
        }
      } catch (_) {
        return (ok: false, message: '无法解析代理主机名: $host');
      }
    }
  }

  final client = HttpClient()
    ..badCertificateCallback = _allowBadCertificate
    ..connectionTimeout = const Duration(seconds: 10);
  _applyProxy(client, config, resolution);

  try {
    final request = await client
        .getUrl(Uri.parse(testUrl))
        .timeout(const Duration(seconds: 12));
    final response = await request.close().timeout(const Duration(seconds: 12));
    await response.drain<void>();
    client.close(force: true);
    return (ok: true, message: '连接成功（HTTP ${response.statusCode}）');
  } catch (e) {
    client.close(force: true);
    return (ok: false, message: '连接失败: $e');
  }
}

/// 让一个 Dio 实例的底层连接走当前代理配置。
///
/// 注意：Dio 的 `IOHttpClientAdapter` 会缓存创建出的 `HttpClient`，
/// 因此代理变更后需要 [refreshDioProxy] 强制其重建。
void applyProxyToDio(Dio dio) {
  final adapter = dio.httpClientAdapter;
  if (adapter is IOHttpClientAdapter) {
    adapter.createHttpClient = createProxiedHttpClient;
  } else {
    dio.httpClientAdapter = IOHttpClientAdapter(
      createHttpClient: createProxiedHttpClient,
    );
  }
}

/// 代理变更后强制 Dio 关闭缓存连接并按新配置重建。
void refreshDioProxy(Dio dio) {
  final adapter = dio.httpClientAdapter;
  if (adapter is IOHttpClientAdapter) {
    adapter.close(force: true);
    adapter.createHttpClient = createProxiedHttpClient;
  }
}
