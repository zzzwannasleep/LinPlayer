import 'dart:io';

import 'package:http/http.dart' as http;
import 'package:http/io_client.dart';

typedef LinProxyResolver = String Function(Uri uri);
typedef LinBadCertificateCallback = bool Function(
  X509Certificate cert,
  String host,
  int port,
);

class LinHttpClientConfig {
  const LinHttpClientConfig({
    this.userAgent = 'LinPlayer/1.0.0',
    this.allowBadCertificates = true,
    this.badCertificateCallback,
    this.connectionTimeout,
    this.idleTimeout = const Duration(seconds: 15),
    this.maxConnectionsPerHost,
    this.proxyResolver,
  });

  final String userAgent;
  final bool allowBadCertificates;
  final LinBadCertificateCallback? badCertificateCallback;
  final Duration? connectionTimeout;
  final Duration idleTimeout;
  final int? maxConnectionsPerHost;
  final LinProxyResolver? proxyResolver;

  LinHttpClientConfig copyWith({
    String? userAgent,
    bool? allowBadCertificates,
    LinBadCertificateCallback? badCertificateCallback,
    Duration? connectionTimeout,
    Duration? idleTimeout,
    int? maxConnectionsPerHost,
    LinProxyResolver? proxyResolver,
  }) {
    return LinHttpClientConfig(
      userAgent: userAgent ?? this.userAgent,
      allowBadCertificates: allowBadCertificates ?? this.allowBadCertificates,
      badCertificateCallback:
          badCertificateCallback ?? this.badCertificateCallback,
      connectionTimeout: connectionTimeout ?? this.connectionTimeout,
      idleTimeout: idleTimeout ?? this.idleTimeout,
      maxConnectionsPerHost:
          maxConnectionsPerHost ?? this.maxConnectionsPerHost,
      proxyResolver: proxyResolver ?? this.proxyResolver,
    );
  }
}

/// Centralized HTTP client factory/config.
///
/// This is the "network choke point" for:
/// - User-Agent
/// - proxy routing (`HttpClient.findProxy`)
/// - TLS certificate policy
/// - basic timeouts / connection limits
class LinHttpClientFactory {
  static LinHttpClientConfig _config = const LinHttpClientConfig();

  static LinHttpClientConfig get config => _config;

  static void configure(LinHttpClientConfig config) {
    _config = config;
  }

  static String get userAgent => _config.userAgent;

  static void setUserAgent(String userAgent) {
    final fixed = userAgent.trim();
    if (fixed.isEmpty) return;
    _config = _config.copyWith(userAgent: fixed);
  }

  static HttpClient createHttpClient([LinHttpClientConfig? override]) {
    final c = override ?? _config;
    final client = HttpClient();

    final ua = c.userAgent.trim();
    if (ua.isNotEmpty) client.userAgent = ua;

    if (c.connectionTimeout != null) {
      client.connectionTimeout = c.connectionTimeout;
    }
    client.idleTimeout = c.idleTimeout;

    if (c.maxConnectionsPerHost != null) {
      client.maxConnectionsPerHost = c.maxConnectionsPerHost!;
    }

    if (c.proxyResolver != null) {
      client.findProxy = c.proxyResolver!;
    }

    final badCert = c.badCertificateCallback;
    if (badCert != null) {
      client.badCertificateCallback = badCert;
    } else if (c.allowBadCertificates) {
      client.badCertificateCallback = (_, __, ___) => true;
    }

    return client;
  }

  static http.Client createClient([LinHttpClientConfig? override]) {
    return IOClient(createHttpClient(override));
  }
}
