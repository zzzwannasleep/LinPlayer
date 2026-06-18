import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../network/proxy_http_client.dart';
import '../network/proxy_settings.dart';
import 'app_preferences.dart';

const String _proxyPrefKey = 'linplayer_proxy_config';

ProxyConfig _readProxyConfig() {
  return ProxyConfig.decode(
    AppPreferencesStore.instance.getString(_proxyPrefKey),
  );
}

/// 在 runApp 之前调用：把持久化的代理配置注入全局运行时，
/// 并完成 SOCKS 主机名预解析，确保首个网络请求即走代理。
Future<void> initializeProxyRuntime() async {
  final config = _readProxyConfig();
  await prewarmProxy(config);
  ProxyRuntime.instance.update(config);
}

final proxyConfigProvider =
    StateNotifierProvider<ProxyConfigNotifier, ProxyConfig>((ref) {
  return ProxyConfigNotifier();
});

class ProxyConfigNotifier extends StateNotifier<ProxyConfig> {
  ProxyConfigNotifier() : super(_readProxyConfig()) {
    // 保证 Provider 首次读取时运行时已同步（防御性，正常已在启动时初始化）。
    ProxyRuntime.instance.update(state);
  }

  /// 保存并即时生效（持久化 + 预解析 + 通知各客户端重建）。
  Future<void> save(ProxyConfig config) async {
    state = config;
    try {
      await AppPreferencesStore.instance.setString(_proxyPrefKey, config.encode());
    } catch (_) {
      // 写入失败不影响内存态。
    }
    await prewarmProxy(config);
    ProxyRuntime.instance.update(config);
  }

  Future<void> disable() => save(ProxyConfig.disabled);
}
