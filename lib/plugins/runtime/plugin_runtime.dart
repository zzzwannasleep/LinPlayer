import 'dart:async';
import 'dart:convert';

import '../../core/services/app_logger.dart';
import '../engine/plugin_js_engine.dart';
import '../engine/qjs_plugin_engine.dart';
import '../models/plugin_manifest.dart';
import '../models/plugin_permission.dart';
import 'plugin_bootstrap_js.dart';
import 'plugin_context_bridge.dart';
import 'plugin_player_bridge.dart';

/// 单个插件的运行时：持有独立的 JS 引擎 + ctx 桥，负责加载、事件转发、回调触发。
///
/// 安全约束：
///  - 每次进入 JS 的调用都有 [callTimeout]（30s 墙钟）超时；
///  - 超时被视为插件失控 —— 销毁引擎并回调 [onFault] 让管理器禁用插件；
///  - 任何 JS 异常都被捕获，不会冒泡到主程序；
///  - 同时启用的插件数由 `PluginManager.maxEnabledPlugins` 全局封顶，间接约束
///    总内存（每插件独立 isolate，堆上限约 64MB）。
class PluginRuntime {
  static final AppLogger _log = AppLogger();

  /// 单次进入 JS 的墙钟超时（失控/卡死保护）。
  ///
  /// 说明：插件运行在独立 isolate，即便陷入死循环也不会阻塞主程序；本超时用于
  /// 判定「该插件失控」并停止与之通信（禁用）。由于异步能力（http 登录 + 重试等）
  /// 合法地可能耗时较久，这里用 30s 墙钟作为卡死阈值；纯同步 CPU 的预算需依赖
  /// 原生中断（见 docs/PLUGINS.md 的超时说明）。
  static const Duration callTimeout = Duration(seconds: 30);

  final PluginManifest manifest;
  final String mainJsSource;
  final PluginContextBridge bridge;
  final PluginGrantedPermissions permissions;

  /// 插件失控（超时/崩溃）回调，参数为原因。
  final void Function(String reason)? onFault;

  late final PluginJsEngine _engine;
  StreamSubscription<PluginPlayerEvent>? _playerSub;
  bool _disposed = false;
  bool _faulted = false;

  PluginRuntime({
    required this.manifest,
    required this.mainJsSource,
    required this.bridge,
    required this.permissions,
    this.onFault,
    PluginJsEngine? engine,
  }) {
    _engine = engine ?? QjsPluginEngine(manifest.id);
  }

  String get pluginId => manifest.id;
  bool get isFaulted => _faulted;

  /// 启动引擎、执行 main.js、注入元信息、触发 onEnable，并订阅播放器事件。
  Future<void> load() async {
    await _engine.start(
      bootstrapJs: kPluginBootstrapJs,
      pluginJs: mainJsSource,
      dispatcher: bridge.dispatch,
    );

    // 注入插件元信息到 ctx.plugin。
    await _guarded(() => _engine.evaluate(
          '__lp_setMeta(${jsonEncode({
                'id': manifest.id,
                'name': manifest.name,
                'version': manifest.version,
              })})',
          timeout: callTimeout,
        ));

    // 生命周期：onEnable。
    await _guarded(() => _engine.invoke('onEnable', '[]', timeout: callTimeout));

    // 订阅播放器事件（仅当声明了 player.read）。
    if (permissions.has(PluginPermissions.playerRead.id)) {
      _playerSub = PluginPlayerBridge.instance.events.listen(_onPlayerEvent);
    }
  }

  void _onPlayerEvent(PluginPlayerEvent event) {
    if (_disposed || _faulted) return;
    final payload = jsonEncode([event.type, event.data]);
    _guarded(() => _engine.invoke('__event', payload, timeout: callTimeout));
  }

  /// 触发一个插件回调（actions/contextMenus/settingsPages 等的 handler）。
  /// 返回 handler 的结果（已解析的 JSON），失败返回 null。
  Future<dynamic> invokeHandler(String handlerId, List<dynamic> args) async {
    if (_disposed || _faulted) return null;
    final payload = jsonEncode([handlerId, args]);
    final raw = await _guarded(
        () => _engine.invoke('__handler', payload, timeout: callTimeout));
    return _parseResult(raw);
  }

  /// 触发一个全局命名函数（manifest 静态扩展点声明的字符串 handler）。
  Future<dynamic> invokeNamed(String fnName, List<dynamic> args) async {
    if (_disposed || _faulted) return null;
    final payload = jsonEncode([fnName, args]);
    final raw = await _guarded(
        () => _engine.invoke('__named', payload, timeout: callTimeout));
    return _parseResult(raw);
  }

  /// 触发一个命名事件（如自定义生命周期），data 为可序列化对象。
  Future<dynamic> emitEvent(String event, Object? data) async {
    if (_disposed || _faulted) return null;
    final payload = jsonEncode([event, data]);
    final raw = await _guarded(
        () => _engine.invoke('__event', payload, timeout: callTimeout));
    return _parseResult(raw);
  }

  dynamic _parseResult(dynamic raw) {
    if (raw is! String) return raw;
    try {
      final decoded = jsonDecode(raw);
      if (decoded is Map && decoded.containsKey('__error__')) {
        _log.w('PluginRuntime', '[$pluginId] 回调返回错误: ${decoded['__error__']}');
        return null;
      }
      return decoded;
    } catch (_) {
      return raw;
    }
  }

  /// 统一保护：捕获超时与异常，超时则触发失控处理。
  Future<dynamic> _guarded(Future<dynamic> Function() action) async {
    try {
      return await action();
    } on PluginTimeoutError catch (e) {
      _fault('执行超时：$e');
      return null;
    } on PluginEngineError catch (e) {
      _fault('引擎错误：$e');
      return null;
    } catch (e) {
      // 普通 JS 异常不视为失控，仅记录。
      _log.w('PluginRuntime', '[$pluginId] 调用异常: $e');
      return null;
    }
  }

  void _fault(String reason) {
    if (_faulted) return;
    _faulted = true;
    _log.e('PluginRuntime', '[$pluginId] 插件已被禁用：$reason');
    onFault?.call(reason);
  }

  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    await _playerSub?.cancel();
    _playerSub = null;
    // 触发 onDisable（best-effort，不等待太久）。
    if (!_faulted && !_engine.isDisposed) {
      try {
        await _engine
            .invoke('onDisable', '[]', timeout: callTimeout)
            .catchError((_) => 'null');
      } catch (_) {}
    }
    await _engine.dispose();
    bridge.dispose();
  }
}
