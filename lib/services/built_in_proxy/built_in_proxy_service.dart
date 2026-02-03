import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:archive/archive.dart';
import 'package:lin_player_server_api/network/lin_http_client.dart';
import 'package:lin_player_ui/lin_player_ui.dart';
import 'package:path_provider/path_provider.dart';

enum BuiltInProxyState {
  unsupported,
  notInstalled,
  stopped,
  starting,
  running,
  error,
}

@immutable
class BuiltInProxyStatus {
  final BuiltInProxyState state;
  final String message;
  final String? executablePath;
  final String? configPath;
  final String? uiPath;
  final int mixedPort;
  final int controllerPort;
  final int? lastExitCode;
  final String? lastError;

  const BuiltInProxyStatus({
    required this.state,
    required this.message,
    required this.executablePath,
    required this.configPath,
    required this.uiPath,
    required this.mixedPort,
    required this.controllerPort,
    required this.lastExitCode,
    required this.lastError,
  });

  bool get isSupported => state != BuiltInProxyState.unsupported;
  bool get isInstalled =>
      state != BuiltInProxyState.unsupported && executablePath != null;
  bool get isRunning =>
      state == BuiltInProxyState.starting || state == BuiltInProxyState.running;
}

class BuiltInProxyService extends ChangeNotifier {
  BuiltInProxyService._();

  static final BuiltInProxyService instance = BuiltInProxyService._();

  static const int mixedPort = 7890;
  static const int controllerPort = 9090;

  static const Duration _startupTimeout = Duration(seconds: 2);
  static const Duration _shutdownTimeout = Duration(seconds: 2);

  Process? _process;
  int? _lastExitCode;
  String? _lastError;

  BuiltInProxyStatus _status = const BuiltInProxyStatus(
    state: BuiltInProxyState.unsupported,
    message: '仅 Android TV 支持',
    executablePath: null,
    configPath: null,
    uiPath: null,
    mixedPort: mixedPort,
    controllerPort: controllerPort,
    lastExitCode: null,
    lastError: null,
  );

  BuiltInProxyStatus get status => _status;

  bool get isSupported =>
      !kIsWeb &&
      defaultTargetPlatform == TargetPlatform.android &&
      DeviceType.isTv;

  Future<void> refresh() async {
    try {
      final next = await _computeStatus();
      _status = next;
      _syncHttpProxy(next);
      notifyListeners();
    } catch (e) {
      _lastError = e.toString();
      _status = BuiltInProxyStatus(
        state: BuiltInProxyState.error,
        message: '状态读取失败：$e',
        executablePath: null,
        configPath: null,
        uiPath: null,
        mixedPort: mixedPort,
        controllerPort: controllerPort,
        lastExitCode: _lastExitCode,
        lastError: _lastError,
      );
      _syncHttpProxy(_status);
      notifyListeners();
    }
  }

  Future<void> installFromFile(String srcPath) async {
    if (!isSupported) {
      _lastError = '仅 Android TV 支持';
      await refresh();
      throw StateError(_lastError!);
    }

    final src = File(srcPath);
    if (!await src.exists()) {
      throw StateError('文件不存在：$srcPath');
    }

    final exe = await _exeFile();
    await exe.parent.create(recursive: true);
    await src.copy(exe.path);
    await _chmodExecutable(exe.path);
    _lastError = null;
    final uiRoot = await _ensureMetacubexdReady();
    await _ensureConfigPatched(externalUiDir: uiRoot);
    await refresh();
  }

  Future<void> start() async {
    if (!isSupported) {
      _lastError = '仅 Android TV 支持';
      await refresh();
      throw StateError(_lastError!);
    }

    if (_process != null) return;

    final exe = await _exeFile();
    await _ensureMihomoInstalled(exe);

    final uiRoot = await _ensureMetacubexdReady();
    await _ensureConfigPatched(externalUiDir: uiRoot);

    _lastError = null;
    _lastExitCode = null;
    _status = BuiltInProxyStatus(
      state: BuiltInProxyState.starting,
      message: '启动中…',
      executablePath: exe.path,
      configPath: (await _configFile()).path,
      uiPath: uiRoot?.path,
      mixedPort: mixedPort,
      controllerPort: controllerPort,
      lastExitCode: _lastExitCode,
      lastError: _lastError,
    );
    notifyListeners();

    try {
      final workDir = (await _baseDir()).path;
      final process = await Process.start(
        exe.path,
        ['-d', workDir],
        workingDirectory: workDir,
        runInShell: false,
      );
      _process = process;

      process.stdout
          .transform(utf8.decoder)
          .transform(const LineSplitter())
          .listen(_onLogLine);
      process.stderr
          .transform(utf8.decoder)
          .transform(const LineSplitter())
          .listen(_onLogLine);

      unawaited(
        process.exitCode.then((code) async {
          _lastExitCode = code;
          _process = null;
          _lastError ??= 'mihomo 已退出：$code';
          await refresh();
        }),
      );

      await _waitForPort(
        InternetAddress.loopbackIPv4,
        controllerPort,
        timeout: _startupTimeout,
      );
    } catch (e) {
      _process = null;
      _lastError = e.toString();
      await refresh();
      rethrow;
    }

    await refresh();
  }

  Future<void> stop() async {
    final process = _process;
    if (process == null) {
      await refresh();
      return;
    }

    try {
      process.kill(ProcessSignal.sigterm);
      await process.exitCode.timeout(_shutdownTimeout);
    } catch (_) {
      try {
        process.kill(ProcessSignal.sigkill);
      } catch (_) {}
    } finally {
      _process = null;
    }

    await refresh();
  }

  void _onLogLine(String line) {
    // MVP: keep last error only; avoid unbounded logs.
    // Capture useful hints for UI.
    if (line.trim().isEmpty) return;
    if (_lastError == null &&
        (line.toLowerCase().contains('fatal') ||
            line.toLowerCase().contains('error') ||
            line.toLowerCase().contains('panic'))) {
      _lastError = line.trim();
      notifyListeners();
    }
  }

  Future<BuiltInProxyStatus> _computeStatus() async {
    if (!isSupported) {
      return BuiltInProxyStatus(
        state: BuiltInProxyState.unsupported,
        message: '仅 Android TV 支持',
        executablePath: null,
        configPath: null,
        uiPath: null,
        mixedPort: mixedPort,
        controllerPort: controllerPort,
        lastExitCode: _lastExitCode,
        lastError: _lastError,
      );
    }

    final exe = await _exeFile();
    final cfg = await _configFile();
    final uiPath = () async {
      try {
        final base = await _uiBaseDir();
        final root = Directory('${base.path}/metacubexd');
        final marker = File('${root.path}/.ready');
        if (!await marker.exists()) return null;
        final uiRoot = await _findUiRoot(root);
        return (uiRoot ?? root).path;
      } catch (_) {
        return null;
      }
    }();

    final installed = await exe.exists();
    if (!installed) {
      return BuiltInProxyStatus(
        state: BuiltInProxyState.notInstalled,
        message: '未安装 mihomo（启用后会自动安装；如失败可手动导入）',
        executablePath: null,
        configPath: cfg.path,
        uiPath: await uiPath,
        mixedPort: mixedPort,
        controllerPort: controllerPort,
        lastExitCode: _lastExitCode,
        lastError: _lastError,
      );
    }

    if (_process != null) {
      return BuiltInProxyStatus(
        state: BuiltInProxyState.running,
        message: '运行中（mixed: 127.0.0.1:$mixedPort）',
        executablePath: exe.path,
        configPath: cfg.path,
        uiPath: await uiPath,
        mixedPort: mixedPort,
        controllerPort: controllerPort,
        lastExitCode: _lastExitCode,
        lastError: _lastError,
      );
    }

    if ((_lastError ?? '').trim().isNotEmpty) {
      return BuiltInProxyStatus(
        state: BuiltInProxyState.error,
        message: '启动失败：${_lastError!.trim()}',
        executablePath: exe.path,
        configPath: cfg.path,
        uiPath: await uiPath,
        mixedPort: mixedPort,
        controllerPort: controllerPort,
        lastExitCode: _lastExitCode,
        lastError: _lastError,
      );
    }

    final suffix = _lastExitCode == null ? '' : '（上次退出：$_lastExitCode）';
    return BuiltInProxyStatus(
      state: BuiltInProxyState.stopped,
      message: '未运行$suffix',
      executablePath: exe.path,
      configPath: cfg.path,
      uiPath: await uiPath,
      mixedPort: mixedPort,
      controllerPort: controllerPort,
      lastExitCode: _lastExitCode,
      lastError: _lastError,
    );
  }

  Future<Directory> _baseDir() async {
    final root = await getApplicationSupportDirectory();
    final dir = Directory('${root.path}/built_in_proxy');
    if (!await dir.exists()) {
      await dir.create(recursive: true);
    }
    return dir;
  }

  Future<File> _exeFile() async {
    final dir = await _baseDir();
    return File('${dir.path}/mihomo');
  }

  Future<File> _configFile() async {
    final dir = await _baseDir();
    return File('${dir.path}/config.yaml');
  }

  Future<void> _ensureConfigPatched({required Directory? externalUiDir}) async {
    final file = await _configFile();
    if (!await file.exists()) {
      await file.writeAsString(_defaultConfigYaml, flush: true);
    }

    String content = await file.readAsString();
    if (content.trim().isEmpty) {
      content = _defaultConfigYaml;
    }

    String quoteYamlString(String value) {
      final fixed = value.replaceAll("'", "''");
      return "'$fixed'";
    }

    String upsert(String raw, String key, String value) {
      final re = RegExp(
        '^\\s*${RegExp.escape(key)}\\s*:\\s*.*\$',
        multiLine: true,
      );
      if (re.hasMatch(raw)) {
        return raw.replaceAll(re, '$key: $value');
      }
      final suffix = raw.endsWith('\n') ? '' : '\n';
      return '$raw$suffix$key: $value\n';
    }

    content = upsert(content, 'mixed-port', '$mixedPort');
    content = upsert(content, 'socks-port', '${mixedPort + 1}');
    content = upsert(content, 'allow-lan', 'false');
    content = upsert(content, 'bind-address', '127.0.0.1');
    content =
        upsert(content, 'external-controller', '127.0.0.1:$controllerPort');
    content = upsert(content, 'secret', '""');

    if (externalUiDir != null) {
      content =
          upsert(content, 'external-ui', quoteYamlString(externalUiDir.path));
    }

    await file.writeAsString(content, flush: true);
  }

  Future<void> _chmodExecutable(String path) async {
    try {
      await Process.run('chmod', ['700', path], runInShell: false);
    } catch (_) {
      // Best-effort; if it fails, start() will surface the error.
    }
  }

  static Future<bool> _waitForPort(
    InternetAddress host,
    int port, {
    required Duration timeout,
  }) async {
    final deadline = DateTime.now().add(timeout);
    while (DateTime.now().isBefore(deadline)) {
      try {
        final socket = await Socket.connect(host, port)
            .timeout(const Duration(milliseconds: 180));
        socket.destroy();
        return true;
      } catch (_) {
        await Future<void>.delayed(const Duration(milliseconds: 120));
      }
    }
    return false;
  }

  Future<void> _ensureMihomoInstalled(File exe) async {
    if (await exe.exists()) return;

    final ok = await _installBundledMihomo(exe);
    if (!ok) {
      _lastError = '未安装 mihomo（缺少内置资源，或 ABI 不支持）';
      await refresh();
      throw StateError(_lastError!);
    }
  }

  Future<bool> _installBundledMihomo(File exe) async {
    final primaryAbi = await DeviceType.primaryAbi();
    final abi = _normalizeAndroidAbi(primaryAbi);
    if (abi == null) return false;

    final assetPath = 'assets/tv_proxy/mihomo/android/$abi/mihomo.gz';
    ByteData data;
    try {
      data = await rootBundle.load(assetPath);
    } catch (_) {
      return false;
    }
    final gzBytes = data.buffer.asUint8List();

    late final Uint8List bytes;
    try {
      bytes = Uint8List.fromList(gzip.decode(gzBytes));
    } catch (_) {
      return false;
    }

    await exe.parent.create(recursive: true);
    await exe.writeAsBytes(bytes, flush: true);
    await _chmodExecutable(exe.path);
    return true;
  }

  static String? _normalizeAndroidAbi(String? abi) {
    final v = (abi ?? '').trim().toLowerCase();
    if (v.isEmpty) return null;
    if (v.contains('arm64')) return 'arm64-v8a';
    if (v.contains('armeabi') || v.contains('armv7')) return 'armeabi-v7a';
    if (v.contains('x86_64') || v.contains('amd64')) return 'x86_64';
    if (v.contains('x86') || v.contains('386')) return 'x86';
    return null;
  }

  Future<Directory> _uiBaseDir() async {
    final root = await getApplicationSupportDirectory();
    final dir = Directory('${root.path}/built_in_proxy/ui');
    if (!await dir.exists()) {
      await dir.create(recursive: true);
    }
    return dir;
  }

  Future<Directory?> _ensureMetacubexdReady() async {
    final base = await _uiBaseDir();
    final root = Directory('${base.path}/metacubexd');
    final marker = File('${root.path}/.ready');
    if (await marker.exists()) {
      final uiRoot = await _findUiRoot(root);
      return uiRoot ?? root;
    }

    ByteData data;
    try {
      data = await rootBundle
          .load('assets/tv_proxy/metacubexd/compressed-dist.tgz');
    } catch (_) {
      // UI assets are optional; proxy can still run without panel.
      return null;
    }

    final tgz = data.buffer.asUint8List();
    late final Archive tar;
    try {
      final gz = GZipDecoder().decodeBytes(tgz, verify: false);
      tar = TarDecoder().decodeBytes(gz, verify: false);
    } catch (_) {
      return null;
    }

    if (await root.exists()) {
      try {
        await root.delete(recursive: true);
      } catch (_) {}
    }
    await root.create(recursive: true);

    for (final entry in tar.files) {
      final name = entry.name;
      if (name.trim().isEmpty) continue;

      final fixedName = name.replaceAll('\\', '/');
      final outPath = '${root.path}/$fixedName';

      if (entry.isFile) {
        final outFile = File(outPath);
        await outFile.parent.create(recursive: true);
        await outFile.writeAsBytes(entry.content as List<int>, flush: true);
      } else {
        await Directory(outPath).create(recursive: true);
      }
    }

    try {
      await marker.writeAsString('ok', flush: true);
    } catch (_) {}

    final uiRoot = await _findUiRoot(root);
    return uiRoot ?? root;
  }

  Future<Directory?> _findUiRoot(Directory root) async {
    final direct = File('${root.path}/index.html');
    if (await direct.exists()) return root;
    final dist = Directory('${root.path}/dist');
    if (await File('${dist.path}/index.html').exists()) return dist;

    // Fall back: scan one-level children for index.html.
    try {
      await for (final ent in root.list(followLinks: false)) {
        if (ent is Directory) {
          if (await File('${ent.path}/index.html').exists()) return ent;
        }
      }
    } catch (_) {}
    return null;
  }

  static bool _isPrivateIpv4(InternetAddress ip) {
    if (ip.type != InternetAddressType.IPv4) return false;
    final b = ip.rawAddress;
    if (b.length != 4) return false;
    final a = b[0];
    final c = b[1];
    if (a == 10) return true;
    if (a == 127) return true;
    if (a == 169 && c == 254) return true;
    if (a == 192 && c == 168) return true;
    if (a == 172 && c >= 16 && c <= 31) return true;
    return false;
  }

  static String _httpProxyResolver(Uri uri) {
    final scheme = uri.scheme.toLowerCase();
    if (scheme != 'http' && scheme != 'https') return 'DIRECT';

    final host = uri.host.trim();
    if (host.isEmpty) return 'DIRECT';
    if (host == 'localhost') return 'DIRECT';
    if (host == '127.0.0.1') return 'DIRECT';

    final ip = InternetAddress.tryParse(host);
    if (ip != null && _isPrivateIpv4(ip)) return 'DIRECT';

    return 'PROXY 127.0.0.1:$mixedPort';
  }

  static String? proxyUrlForUri(Uri uri) {
    return _httpProxyResolver(uri) == 'DIRECT'
        ? null
        : 'http://127.0.0.1:$mixedPort';
  }

  static void _syncHttpProxy(BuiltInProxyStatus status) {
    final shouldEnable = status.state == BuiltInProxyState.running;
    LinHttpClientFactory.setRuntimeProxyResolver(
      shouldEnable ? _httpProxyResolver : null,
    );
  }
}

const String _defaultConfigYaml = r'''# LinPlayer built-in proxy (mihomo) - MVP
#
# Security: bind to 127.0.0.1 only.
# This config intentionally starts in DIRECT mode (no subscriptions).
#
mixed-port: 7890
socks-port: 7891
allow-lan: false
bind-address: 127.0.0.1
mode: rule
log-level: info
ipv6: false

external-controller: 127.0.0.1:9090
external-ui: ""
secret: ""

proxies: []
proxy-groups:
  - name: DIRECT
    type: select
    proxies:
      - DIRECT

rules:
  - MATCH,DIRECT
''';
