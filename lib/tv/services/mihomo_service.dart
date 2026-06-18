import 'dart:convert';

import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/network/proxy_settings.dart';
import '../../core/providers/app_preferences.dart';
import '../../core/providers/proxy_providers.dart';

/// 一条机场/代理订阅。
class ProxySubscription {
  final String id;
  final String name;
  final String url;

  const ProxySubscription({
    required this.id,
    required this.name,
    required this.url,
  });

  ProxySubscription copyWith({String? name, String? url}) => ProxySubscription(
        id: id,
        name: name ?? this.name,
        url: url ?? this.url,
      );

  Map<String, dynamic> toJson() => {'id': id, 'name': name, 'url': url};

  factory ProxySubscription.fromJson(Map<String, dynamic> json) =>
      ProxySubscription(
        id: json['id'] as String,
        name: (json['name'] as String?) ?? '订阅',
        url: (json['url'] as String?) ?? '',
      );
}

/// mihomo 运行参数（固定本地回环端口；TV 单机使用无需可配）。
class MihomoPorts {
  static const int mixedPort = 7890;
  static const int controllerPort = 9090;

  /// zashboard 面板地址（external-ui 由 external-controller 在 /ui/ 提供）。
  static const String dashboardUrl = 'http://127.0.0.1:9090/ui/';
}

/// 根据订阅列表生成 mihomo config.yaml。
///
/// 用 proxy-providers 让内核自己拉取/解析订阅，避免在 Dart 侧解析各种机场格式。
/// secret 留空：external-controller 仅监听 127.0.0.1，TV 本机回环访问无需鉴权，
/// 面板同源连接也更省心。
String generateMihomoConfig(List<ProxySubscription> subs) {
  final valid = subs.where((s) => s.url.trim().isNotEmpty).toList();
  final buf = StringBuffer();
  buf.writeln('mixed-port: ${MihomoPorts.mixedPort}');
  buf.writeln('allow-lan: false');
  buf.writeln('mode: rule');
  buf.writeln('log-level: info');
  buf.writeln('ipv6: false');
  buf.writeln('external-controller: 127.0.0.1:${MihomoPorts.controllerPort}');
  buf.writeln('secret: ""');
  buf.writeln('external-ui: ui');
  buf.writeln('profile:');
  buf.writeln('  store-selected: true');

  if (valid.isEmpty) {
    // 无订阅时给一个直连兜底，保证内核能正常起停。
    buf.writeln('proxies: []');
    buf.writeln('proxy-groups:');
    buf.writeln('  - name: PROXY');
    buf.writeln('    type: select');
    buf.writeln('    proxies: [DIRECT]');
    buf.writeln('rules:');
    buf.writeln('  - MATCH,PROXY');
    return buf.toString();
  }

  buf.writeln('proxy-providers:');
  for (var i = 0; i < valid.length; i++) {
    final key = 'sub$i';
    buf.writeln('  $key:');
    buf.writeln('    type: http');
    buf.writeln('    url: "${valid[i].url.trim()}"');
    buf.writeln('    interval: 3600');
    buf.writeln('    path: ./providers/$key.yaml');
    buf.writeln('    health-check:');
    buf.writeln('      enable: true');
    buf.writeln('      url: https://www.gstatic.com/generate_204');
    buf.writeln('      interval: 300');
  }

  final useList = [for (var i = 0; i < valid.length; i++) 'sub$i'];
  buf.writeln('proxy-groups:');
  buf.writeln('  - name: PROXY');
  buf.writeln('    type: select');
  buf.writeln('    use:');
  for (final u in useList) {
    buf.writeln('      - $u');
  }
  buf.writeln('  - name: AUTO');
  buf.writeln('    type: url-test');
  buf.writeln('    url: https://www.gstatic.com/generate_204');
  buf.writeln('    interval: 300');
  buf.writeln('    use:');
  for (final u in useList) {
    buf.writeln('      - $u');
  }
  buf.writeln('rules:');
  // 局域网/本机直连，避免把 LAN 内的 Emby 经境外节点绕行。
  buf.writeln('  - IP-CIDR,127.0.0.0/8,DIRECT,no-resolve');
  buf.writeln('  - IP-CIDR,10.0.0.0/8,DIRECT,no-resolve');
  buf.writeln('  - IP-CIDR,172.16.0.0/12,DIRECT,no-resolve');
  buf.writeln('  - IP-CIDR,192.168.0.0/16,DIRECT,no-resolve');
  buf.writeln('  - MATCH,PROXY');
  return buf.toString();
}

/// 与原生 ProxyBridge 通信的薄封装。
class MihomoCore {
  static const _channel = MethodChannel('com.linplayer/proxy');

  Future<bool> isCoreAvailable() async {
    try {
      return (await _channel.invokeMethod<bool>('isCoreAvailable')) ?? false;
    } catch (_) {
      return false;
    }
  }

  Future<bool> isRunning() async {
    try {
      return (await _channel.invokeMethod<bool>('isRunning')) ?? false;
    } catch (_) {
      return false;
    }
  }

  Future<void> start(String config) =>
      _channel.invokeMethod('start', {'config': config});

  Future<void> stop() => _channel.invokeMethod('stop');
}

class MihomoState {
  final bool enabled;
  final bool running;
  final bool coreAvailable;
  final List<ProxySubscription> subscriptions;

  const MihomoState({
    this.enabled = false,
    this.running = false,
    this.coreAvailable = false,
    this.subscriptions = const [],
  });

  MihomoState copyWith({
    bool? enabled,
    bool? running,
    bool? coreAvailable,
    List<ProxySubscription>? subscriptions,
  }) =>
      MihomoState(
        enabled: enabled ?? this.enabled,
        running: running ?? this.running,
        coreAvailable: coreAvailable ?? this.coreAvailable,
        subscriptions: subscriptions ?? this.subscriptions,
      );
}

const _kSubsKey = 'linplayer_mihomo_subs';
const _kEnabledKey = 'linplayer_mihomo_enabled';

class MihomoController extends StateNotifier<MihomoState> {
  MihomoController(this._ref) : super(const MihomoState()) {
    _load();
  }

  final Ref _ref;
  final MihomoCore _core = MihomoCore();

  void _load() {
    final prefs = AppPreferencesStore.instance;
    final raw = prefs.getString(_kSubsKey);
    final subs = <ProxySubscription>[];
    if (raw != null && raw.isNotEmpty) {
      try {
        for (final e in jsonDecode(raw) as List) {
          subs.add(ProxySubscription.fromJson(e as Map<String, dynamic>));
        }
      } catch (_) {}
    }
    final enabled = prefs.getBool(_kEnabledKey) ?? false;
    state = state.copyWith(subscriptions: subs, enabled: enabled);
    _refreshRuntime(autoStart: enabled);
  }

  Future<void> _refreshRuntime({bool autoStart = false}) async {
    final available = await _core.isCoreAvailable();
    final running = available && await _core.isRunning();
    state = state.copyWith(coreAvailable: available, running: running);
    // 上次启用且内核可用但未在运行（如重启后），自动拉起。
    if (autoStart && available && !running && state.enabled) {
      await enable();
    }
  }

  Future<void> _persistSubs() async {
    try {
      await AppPreferencesStore.instance.setString(
        _kSubsKey,
        jsonEncode(state.subscriptions.map((e) => e.toJson()).toList()),
      );
    } catch (_) {}
  }

  Future<void> addSubscription(String name, String url) async {
    final id = DateTime.now().microsecondsSinceEpoch.toString();
    final sub = ProxySubscription(
        id: id, name: name.trim().isEmpty ? '订阅' : name.trim(), url: url.trim());
    state = state.copyWith(subscriptions: [...state.subscriptions, sub]);
    await _persistSubs();
    if (state.running) await enable(); // 热更新配置
  }

  Future<void> removeSubscription(String id) async {
    state = state.copyWith(
      subscriptions: state.subscriptions.where((s) => s.id != id).toList(),
    );
    await _persistSubs();
    if (state.running) await enable();
  }

  /// 启用：生成配置 → 启动内核 → 将全局代理指向本地 mixed 端口（API/图片/mpv 流均经此）。
  Future<void> enable() async {
    final config = generateMihomoConfig(state.subscriptions);
    await _core.start(config);
    await _ref.read(proxyConfigProvider.notifier).save(
          const ProxyConfig(
            type: ProxyType.http,
            host: '127.0.0.1',
            port: MihomoPorts.mixedPort,
            proxyMedia: true,
          ),
        );
    await AppPreferencesStore.instance.setBool(_kEnabledKey, true);
    state = state.copyWith(enabled: true, running: true);
  }

  /// 停用：停内核 + 清除全局代理（回到直连）。
  Future<void> disable() async {
    await _core.stop();
    await _ref.read(proxyConfigProvider.notifier).disable();
    await AppPreferencesStore.instance.setBool(_kEnabledKey, false);
    state = state.copyWith(enabled: false, running: false);
  }

  /// 重新拉取订阅并重载配置（内核运行时生效）。
  Future<void> refresh() async {
    if (state.running) await enable();
  }
}

final mihomoControllerProvider =
    StateNotifierProvider<MihomoController, MihomoState>(
  (ref) => MihomoController(ref),
);
