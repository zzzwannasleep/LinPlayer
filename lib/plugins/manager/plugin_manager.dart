import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import '../../core/providers/app_preferences.dart';
import '../../core/services/app_logger.dart';
import '../models/plugin_extension_point.dart';
import '../models/plugin_info.dart';
import '../models/plugin_manifest.dart';
import '../models/plugin_permission.dart';
import '../runtime/plugin_context_bridge.dart';
import '../runtime/plugin_runtime.dart';
import '../runtime/plugin_storage.dart';
import 'plugin_extension_registry.dart';
import 'plugin_installer.dart';

/// 插件管理器：扫描、安装、卸载、启用/禁用、生命周期管理。
///
/// - 每个启用的插件拥有独立 [PluginRuntime]（独立 QuickJS isolate）；
/// - 启用状态持久化在 shared_preferences；
/// - 插件失控（超时/崩溃）会被自动禁用并标记 faulted，不影响主程序与其他插件。
class PluginManager extends ChangeNotifier {
  static final AppLogger _log = AppLogger();
  static const _enabledKey = 'linplayer_enabled_plugins';
  /// 同时启用插件数的全局上限（每插件独立 isolate ~64MB，限数量即限总内存）。
  static const int maxEnabledPlugins = 16;
  // 每个插件“用户已同意的权限集”，用于检测更新提权（新清单申请了未同意的权限）。
  static const _approvedPermsKey = 'linplayer_plugin_approved_perms';

  /// 全局单例（UI 深处/JS 回调链路使用）。
  static PluginManager? _instance;
  static PluginManager get instance {
    final i = _instance;
    if (i == null) {
      throw StateError('PluginManager 尚未初始化，请先调用 PluginManager.ensureInitialized');
    }
    return i;
  }

  final PluginExtensionRegistry registry;

  late final String _pluginsRootDir;
  late final String _dataRootDir;
  late final PluginInstaller _installer;

  final Map<String, PluginInfo> _plugins = {};
  final Map<String, PluginRuntime> _runtimes = {};
  Set<String> _enabledIds = {};
  // pluginId -> 用户启用时同意的权限 id 集合。
  Map<String, Set<String>> _approvedPerms = {};
  bool _initialized = false;

  PluginManager({PluginExtensionRegistry? registry})
      : registry = registry ?? PluginExtensionRegistry();

  List<PluginInfo> get plugins => _plugins.values.toList(growable: false);
  String get pluginsRootDir => _pluginsRootDir;

  PluginInfo? pluginById(String id) => _plugins[id];
  PluginRuntime? runtimeOf(String id) => _runtimes[id];

  /// 初始化目录、读取启用集合、扫描并激活已启用插件。
  static Future<PluginManager> ensureInitialized(
      {PluginExtensionRegistry? registry}) async {
    if (_instance != null) return _instance!;
    final mgr = PluginManager(registry: registry);
    await mgr._init();
    _instance = mgr;
    return mgr;
  }

  Future<void> _init() async {
    if (_initialized) return;
    final base = await _resolvePluginBaseDir();
    _pluginsRootDir = p.join(base, 'plugins');
    _dataRootDir = p.join(base, 'plugin_data');
    await Directory(_pluginsRootDir).create(recursive: true);
    await Directory(_dataRootDir).create(recursive: true);
    _installer = PluginInstaller(_pluginsRootDir);
    _log.i('PluginManager', '插件目录: $_pluginsRootDir');

    _enabledIds = _readEnabledIds();
    _approvedPerms = _readApprovedPerms();
    _initialized = true;
    await scan();
  }

  /// 解析插件根目录所在的基准目录，目标是「卸载即清理、不残留」。
  ///
  /// - **Windows / Linux**（便携解压）：放在**可执行文件同目录**——删除应用
  ///   文件夹即连同插件一并清理，不散落到 AppData。
  /// - **macOS**（便携解压）：放在 **.app 包同级目录**；若 .app 已被移到
  ///   `/Applications` 等系统位置（不可写）则回退到应用支持目录。
  /// - **移动端 / TV（iOS/Android/tvOS/Android TV）**：放在**应用支持目录**。
  ///   它在应用私有沙盒内，**卸载应用时由系统随沙盒一并删除**（自动清理），
  ///   且不污染用户可见的 Documents（移动端无法把文件放到二进制旁边）。
  /// - 任何便携路径不可写时，统一回退到应用支持目录。
  Future<String> _resolvePluginBaseDir() async {
    if (Platform.isWindows || Platform.isLinux) {
      final dir =
          await _probeWritable(File(Platform.resolvedExecutable).parent.path);
      if (dir != null) return dir;
    } else if (Platform.isMacOS) {
      final sibling = _macAppSiblingDir();
      if (sibling != null) {
        final dir = await _probeWritable(sibling);
        if (dir != null) return dir;
      }
    }
    // 移动端 / TV / 回退：应用支持目录（沙盒内，卸载随应用删除）。
    final support = await getApplicationSupportDirectory();
    return support.path;
  }

  /// 探测目录可写（能创建 plugins/ 子目录）则返回该目录，否则 null。
  Future<String?> _probeWritable(String dir) async {
    try {
      await Directory(p.join(dir, 'plugins')).create(recursive: true);
      return dir;
    } catch (e) {
      _log.w('PluginManager', '目录不可写，回退: $dir ($e)');
      return null;
    }
  }

  /// macOS：返回 .app 包所在的同级目录（便携解压场景）。
  /// 位于 /Applications 或 /System 等系统位置时返回 null（改用应用支持目录）。
  String? _macAppSiblingDir() {
    final exe = Platform.resolvedExecutable; // .../Foo.app/Contents/MacOS/Foo
    const marker = '.app/';
    final idx = exe.indexOf(marker);
    if (idx < 0) return null;
    final appBundle = exe.substring(0, idx + marker.length - 1); // .../Foo.app
    final container = File(appBundle).parent.path; // 含 .app 的文件夹
    if (container == '/Applications' || container.startsWith('/System')) {
      return null;
    }
    return container;
  }

  Set<String> _readEnabledIds() {
    try {
      final list = AppPreferencesStore.instance.getStringList(_enabledKey);
      return list?.toSet() ?? {};
    } catch (_) {
      return {};
    }
  }

  Future<void> _persistEnabledIds() async {
    try {
      await AppPreferencesStore.instance
          .setStringList(_enabledKey, _enabledIds.toList());
    } catch (e) {
      _log.w('PluginManager', '持久化启用状态失败: $e');
    }
  }

  Map<String, Set<String>> _readApprovedPerms() {
    try {
      final raw = AppPreferencesStore.instance.getString(_approvedPermsKey);
      if (raw == null || raw.isEmpty) return {};
      final decoded = jsonDecode(raw) as Map<String, dynamic>;
      return decoded.map(
        (k, v) => MapEntry(k, (v as List).map((e) => '$e').toSet()),
      );
    } catch (_) {
      return {};
    }
  }

  Future<void> _persistApprovedPerms() async {
    try {
      final json = _approvedPerms.map((k, v) => MapEntry(k, v.toList()));
      await AppPreferencesStore.instance
          .setString(_approvedPermsKey, jsonEncode(json));
    } catch (e) {
      _log.w('PluginManager', '持久化已同意权限失败: $e');
    }
  }

  /// 清单申请的权限是否都在用户已同意范围内（无新增 = 通过）。
  bool _permissionsApproved(PluginInfo info) {
    final approved = _approvedPerms[info.id];
    if (approved == null) return false; // 从未同意过
    return info.manifest.permissions.toSet().difference(approved).isEmpty;
  }

  /// 扫描插件目录，加载清单，并激活所有已启用插件。
  Future<void> scan() async {
    final root = Directory(_pluginsRootDir);
    if (!await root.exists()) return;

    _plugins.clear();
    await for (final entry in root.list()) {
      if (entry is! Directory) continue;
      try {
        final info = await _installer.loadFromDirectory(entry.path);
        _plugins[info.id] = info;
      } catch (e) {
        _log.w('PluginManager', '跳过无效插件目录 ${entry.path}: $e');
      }
    }

    // 迁移：本功能上线前已启用、但无“已同意权限”记录的插件，把当前清单权限
    // 视为既往同意（既往不咎），避免升级后被误判提权而全部禁用。
    var migrated = false;
    for (final info in _plugins.values) {
      if (_enabledIds.contains(info.id) &&
          !_approvedPerms.containsKey(info.id)) {
        _approvedPerms[info.id] = info.manifest.permissions.toSet();
        migrated = true;
      }
    }
    if (migrated) await _persistApprovedPerms();

    // 激活已启用的插件；若清单权限超出已同意范围（疑似更新提权），强制禁用待重新授权。
    var forcedDisable = false;
    var activated = 0;
    for (final info in _plugins.values) {
      if (!_enabledIds.contains(info.id)) continue;
      if (_permissionsApproved(info)) {
        if (activated >= maxEnabledPlugins) {
          info.status = PluginStatus.disabled;
          info.error = '超出同时启用插件数上限（$maxEnabledPlugins），未激活';
          _log.w('PluginManager', '插件 ${info.id} 超出并发上限，跳过激活');
          continue;
        }
        await _activate(info);
        activated++;
      } else {
        _enabledIds.remove(info.id);
        forcedDisable = true;
        info.status = PluginStatus.disabled;
        info.error = '插件权限已变更，需要重新授权后再启用';
        _log.w('PluginManager',
            '插件 ${info.id} 申请了未同意的权限，已强制禁用待重新授权');
      }
    }
    if (forcedDisable) await _persistEnabledIds();
    notifyListeners();
  }

  /// 从 .ipk 文件安装（安装后默认禁用，需用户授权后启用）。兼容旧 .lpk。
  Future<PluginInfo> install(String lpkPath) async {
    final info = await _installer.installFromLpkFile(lpkPath);
    // 覆盖安装（同 id 升级/重装）：清除旧的启用态、运行时与已同意权限，强制
    // 重新走授权弹窗，防止新清单悄悄提权后随下次扫描自动获得新权限。
    final wasEnabled = _enabledIds.remove(info.id);
    await _deactivate(info.id);
    if (_approvedPerms.remove(info.id) != null) {
      await _persistApprovedPerms();
    }
    if (wasEnabled) await _persistEnabledIds();
    info.status = PluginStatus.disabled;
    _plugins[info.id] = info;
    notifyListeners();
    return info;
  }

  /// 启用插件（调用方须已通过同意弹窗）。启用即记录用户同意的权限集。
  Future<void> enable(String id) async {
    final info = _plugins[id];
    if (info == null) throw StateError('插件不存在: $id');
    if (!_enabledIds.contains(id) && _enabledIds.length >= maxEnabledPlugins) {
      throw StateError('已达到同时启用插件数上限（$maxEnabledPlugins 个），请先禁用其它插件');
    }
    _enabledIds.add(id);
    _approvedPerms[id] = info.manifest.permissions.toSet();
    await _persistEnabledIds();
    await _persistApprovedPerms();
    await _activate(info);
    notifyListeners();
  }

  /// 禁用插件。
  Future<void> disable(String id) async {
    _enabledIds.remove(id);
    await _persistEnabledIds();
    await _deactivate(id);
    final info = _plugins[id];
    if (info != null) {
      info.status = PluginStatus.disabled;
      info.error = null;
    }
    notifyListeners();
  }

  /// 卸载插件（先禁用，再删除目录）。
  Future<void> uninstall(String id) async {
    await _deactivate(id);
    _enabledIds.remove(id);
    await _persistEnabledIds();
    if (_approvedPerms.remove(id) != null) {
      await _persistApprovedPerms();
    }
    final info = _plugins.remove(id);
    if (info != null) {
      try {
        await _installer.uninstall(info.directory);
      } catch (e) {
        _log.w('PluginManager', '删除插件目录失败: $e');
      }
    }
    notifyListeners();
  }

  /// 触发某扩展的回调（actions/contextMenus/settingsPages 的 handler）。
  Future<dynamic> triggerExtension(PluginExtension ext,
      [List<dynamic> args = const []]) async {
    final runtime = _runtimes[ext.pluginId];
    if (runtime == null) {
      _log.w('PluginManager', '插件未运行，无法触发: ${ext.pluginId}');
      return null;
    }
    final handler = ext.data['handler'];
    return _invokeHandlerValue(runtime, handler, args);
  }

  /// 触发任意 handler 值（兼容 {__handler__:id} 与字符串函数名）。
  Future<dynamic> _invokeHandlerValue(
      PluginRuntime runtime, dynamic handler, List<dynamic> args) async {
    if (handler is Map && handler['__handler__'] != null) {
      return runtime.invokeHandler('${handler['__handler__']}', args);
    }
    if (handler is String && handler.isNotEmpty) {
      return runtime.invokeNamed(handler, args);
    }
    return null;
  }

  /// 调用插件内某个具名字段的 handler（如设置页的 load/submit）。
  Future<dynamic> invokeExtensionField(
      PluginExtension ext, String field, List<dynamic> args) async {
    final runtime = _runtimes[ext.pluginId];
    if (runtime == null) return null;
    return _invokeHandlerValue(runtime, ext.data[field], args);
  }

  // ---- 内部：激活/停用 ----

  Future<void> _activate(PluginInfo info) async {
    if (_runtimes.containsKey(info.id)) return; // 已激活
    info.status = PluginStatus.loading;
    info.error = null;
    notifyListeners();

    try {
      final source = await File(info.entryPath).readAsString();
      final permissions = PluginGrantedPermissions(info.manifest.permissions);
      final storage = PluginStorage(
        pluginId: info.id,
        dataDir: p.join(_dataRootDir, info.id),
      );
      final bridge = PluginContextBridge(
        manifest: info.manifest,
        permissions: permissions,
        storage: storage,
        registry: registry,
        httpAllowedHosts: _allowedHostsOf(info.manifest),
      );
      final runtime = PluginRuntime(
        manifest: info.manifest,
        mainJsSource: source,
        bridge: bridge,
        permissions: permissions,
        onFault: (reason) => _handleFault(info.id, reason),
      );
      _runtimes[info.id] = runtime;

      // 注册 manifest 静态声明的扩展点。
      _registerManifestExtensions(info.manifest);

      await runtime.load();

      info.status = PluginStatus.enabled;
      _log.i('PluginManager', '插件已启用: ${info.id}');
    } catch (e, st) {
      _log.eWithStack('PluginManager', '启用插件失败: ${info.id}', e, st);
      info.status = PluginStatus.error;
      info.error = '$e';
      await _deactivate(info.id);
    }
    notifyListeners();
  }

  void _registerManifestExtensions(PluginManifest manifest) {
    for (final decl in manifest.extensions) {
      final data = Map<String, dynamic>.from(decl.data);
      final id = '${data['id'] ?? 'static_${decl.type.id}_${data.hashCode}'}';
      registry.register(PluginExtension(
        pluginId: manifest.id,
        type: decl.type,
        id: id,
        data: data,
        fromManifest: true,
      ));
    }
  }

  Future<void> _deactivate(String id) async {
    registry.removeAllForPlugin(id);
    final runtime = _runtimes.remove(id);
    if (runtime != null) {
      try {
        await runtime.dispose();
      } catch (e) {
        _log.w('PluginManager', '释放插件运行时失败 $id: $e');
      }
    }
  }

  void _handleFault(String id, String reason) {
    final info = _plugins[id];
    if (info != null) {
      info.status = PluginStatus.error;
      info.error = reason;
      info.faulted = true;
    }
    // 失控插件强制禁用（从启用集合移除并清理运行时）。
    _enabledIds.remove(id);
    unawaited(_persistEnabledIds());
    unawaited(_deactivate(id));
    notifyListeners();
  }

  List<String> _allowedHostsOf(PluginManifest manifest) {
    final raw = manifest.raw['httpAllowedHosts'];
    if (raw is List) {
      return raw.map((e) => '$e').toList();
    }
    return const [];
  }

  @override
  void dispose() {
    for (final r in _runtimes.values) {
      unawaited(r.dispose());
    }
    _runtimes.clear();
    super.dispose();
  }
}
