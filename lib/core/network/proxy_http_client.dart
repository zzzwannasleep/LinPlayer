import 'dart:io';

import 'package:dio/dio.dart';
import 'package:dio/io.dart';
import 'package:socks5_proxy/socks_client.dart';

import 'proxy_settings.dart';

/// 把用户代理配置应用到 Dart 的 `HttpClient` / Dio。
///
/// 设计要点：
/// - 构造 `HttpClient` 的工厂回调是同步的，因此 SOCKS 代理所需的
///   [InternetAddress] 必须提前解析好并缓存（见 [prewarmProxy]）。
/// - HTTP(S) 代理走 `HttpClient.findProxy`；SOCKS 走 `socks5_proxy`
///   的 `connectionFactory`。
/// - 所有 HttpClient 一律放行自签名证书，保持与原有行为一致（兼容性优先）。

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
    ..badCertificateCallback =
        ((X509Certificate cert, String host, int port) => true);
  _applyProxy(client, ProxyRuntime.instance.current, _socksResolution);
  return client;
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
    ..badCertificateCallback =
        ((X509Certificate cert, String host, int port) => true)
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
