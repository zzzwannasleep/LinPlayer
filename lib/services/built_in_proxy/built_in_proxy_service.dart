import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:archive/archive.dart';
import 'package:lin_player_server_api/network/lin_http_client.dart';
import 'package:lin_player_ui/lin_player_ui.dart';
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

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
  static const String _nativeMihomoSoName = 'libmihomo.so';
  static const String _kSubscriptionUrlKey = 'tvBuiltInProxySubscriptionUrl_v1';

  static const Duration _startupTimeout = Duration(seconds: 2);
  static const Duration _shutdownTimeout = Duration(seconds: 2);
  static final List<_CountryGroup> _defaultCountryGroups =
      _CountryGroup.defaultPreset();

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

  Future<String> getSubscriptionUrl() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getString(_kSubscriptionUrlKey) ?? '';
  }

  Future<void> setSubscriptionUrl(String url) async {
    final v = url.trim();
    final prefs = await SharedPreferences.getInstance();
    if (v.isEmpty) {
      await prefs.remove(_kSubscriptionUrlKey);
    } else {
      await prefs.setString(_kSubscriptionUrlKey, v);
    }
  }

  Future<void> prepareConfig() async {
    if (!isSupported) return;
    final uiRoot = await _ensureMetacubexdReady();
    await _ensureConfigPatched(externalUiDir: uiRoot);
    await refresh();
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

    var exe = await _resolveMihomoExecutableForStart();

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
      Process process;
      try {
        process = await Process.start(
          exe.path,
          ['-d', workDir],
          workingDirectory: workDir,
          runInShell: false,
        );
      } on ProcessException catch (e) {
        // Some Android TV ROMs mount app data dirs as "noexec", causing Permission denied.
        // In that case, try running the bundled native-lib executable instead.
        final message = e.toString().toLowerCase();
        final nativeExe = await _nativeMihomoFile();
        final canFallback = nativeExe != null &&
            nativeExe.path != exe.path &&
            await nativeExe.exists() &&
            message.contains('permission denied');
        if (!canFallback) rethrow;

        exe = nativeExe;
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

        process = await Process.start(
          exe.path,
          ['-d', workDir],
          workingDirectory: workDir,
          runInShell: false,
        );
      }
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
    final nativeExe = await _nativeMihomoFile();
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

    final exeExists = await exe.exists();
    final nativeExists = nativeExe != null && await nativeExe.exists();
    final effectiveExe = exeExists
        ? exe
        : nativeExists
            ? nativeExe
            : null;

    if (effectiveExe == null) {
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
        executablePath: effectiveExe.path,
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
        executablePath: effectiveExe.path,
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
      executablePath: effectiveExe.path,
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

  Future<File?> _nativeMihomoFile() async {
    if (!isSupported) return null;
    final dir = await DeviceType.nativeLibraryDir();
    final base = (dir ?? '').trim();
    if (base.isEmpty) return null;
    return File('$base/$_nativeMihomoSoName');
  }

  Future<File> _resolveMihomoExecutableForStart() async {
    // 1) User imported binary (preferred so users can pin versions).
    final exe = await _exeFile();
    if (await exe.exists()) return exe;

    // 2) Bundled native lib (works on devices that disallow exec from app data dirs).
    final nativeExe = await _nativeMihomoFile();
    if (nativeExe != null && await nativeExe.exists()) return nativeExe;

    // 3) Fallback: extract from Flutter assets.
    await _ensureMihomoInstalled(exe);
    return exe;
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

    final subscriptionUrl = (await getSubscriptionUrl()).trim();
    if (subscriptionUrl.isNotEmpty) {
      content = await _buildManagedConfigYaml(subscriptionUrl);
    }

    // Backward-compat: older default config accidentally created a proxy-group named "DIRECT"
    // which self-referenced and caused mihomo to fail with:
    // "loop is detected in ProxyGroup ... [DIRECT]".
    content = _migrateDirectGroupLoop(content);

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

  Future<String> _buildManagedConfigYaml(String subscriptionUrl) async {
    // Best-effort: to hide empty country groups we need to peek into the
    // subscription contents. If it fails, fall back to a common preset.
    final scan = await _tryScanSubscription(subscriptionUrl);
    final countryGroups = scan?.countryGroups ?? _defaultCountryGroups;
    final includeLowRate = scan?.hasLowRate ?? true;
    const lowRateGroupName = '低倍率/LOWRATE节点';

    String q(String value) {
      final fixed = value.replaceAll("'", "''");
      return "'$fixed'";
    }

    // For mihomo `filter:` regex strings, prefer YAML single-quoted strings:
    // - Backslashes are treated literally.
    // - Only single quotes need escaping by doubling.
    String qRe(String value) => q(value);

    final proxyEntryCandidates = <String>[
      'AUTO',
      ...countryGroups.map((g) => g.name),
      if (includeLowRate) lowRateGroupName,
      'MANUAL',
      'DIRECT',
    ];

    final b = StringBuffer()
      ..writeln('# LinPlayer built-in proxy (mihomo) - Managed config')
      ..writeln('# Generated by app. Edits may be overwritten.')
      ..writeln('')
      ..writeln('mode: rule')
      ..writeln('log-level: info')
      ..writeln('ipv6: false')
      ..writeln('')
      ..writeln('mixed-port: $mixedPort')
      ..writeln('socks-port: ${mixedPort + 1}')
      ..writeln('allow-lan: false')
      ..writeln('bind-address: 127.0.0.1')
      ..writeln('')
      ..writeln('external-controller: 127.0.0.1:$controllerPort')
      ..writeln('external-ui: ""')
      ..writeln('secret: ""')
      ..writeln('')
      ..writeln('profile:')
      ..writeln('  store-selected: true')
      ..writeln('')
      ..writeln('proxy-providers:')
      ..writeln('  sub:')
      ..writeln('    type: http')
      ..writeln('    url: ${q(subscriptionUrl)}')
      ..writeln('    interval: 86400')
      ..writeln('    path: ./providers/sub.yaml')
      ..writeln('    proxy: DIRECT')
      ..writeln('    health-check:')
      ..writeln('      enable: true')
      ..writeln("      url: 'http://www.gstatic.com/generate_204'")
      ..writeln('      interval: 600')
      ..writeln('')
      ..writeln('proxy-groups:')
      ..writeln('  - name: AUTO')
      ..writeln('    type: url-test')
      ..writeln('    use: [sub]')
      ..writeln("    url: 'http://www.gstatic.com/generate_204'")
      ..writeln('    interval: 300')
      ..writeln('    tolerance: 50')
      ..writeln('')
      ..writeln('  - name: MANUAL')
      ..writeln('    type: select')
      ..writeln('    use: [sub]')
      ..writeln('    proxies: [DIRECT]')
      ..writeln('');

    for (final g in countryGroups) {
      b
        ..writeln('  - name: ${q(g.name)}')
        ..writeln('    type: select')
        ..writeln('    use: [sub]')
        ..writeln('    filter: ${qRe(g.filterRegex)}')
        ..writeln('');
    }
    if (includeLowRate) {
      b
        ..writeln('  - name: ${q(lowRateGroupName)}')
        ..writeln('    type: select')
        ..writeln('    use: [sub]')
        ..writeln(
          '    filter: ${qRe(r"(?i)(^|[^0-9.])0\.[0-9]{1,3} *(x|倍|倍率)?($|[^0-9.])")}',
        )
        ..writeln('');
    }

    b
      ..writeln('  - name: PROXY')
      ..writeln('    type: select')
      ..writeln('    proxies:');
    for (final name in proxyEntryCandidates) {
      b.writeln('      - ${q(name)}');
    }
    b
      ..writeln('')
      ..writeln('  - name: 漏网之鱼')
      ..writeln('    type: select')
      ..writeln('    proxies: [PROXY, DIRECT]')
      ..writeln('')
      ..writeln('rules:')
      ..writeln('  - IP-CIDR,127.0.0.0/8,DIRECT,no-resolve')
      ..writeln('  - IP-CIDR,10.0.0.0/8,DIRECT,no-resolve')
      ..writeln('  - IP-CIDR,172.16.0.0/12,DIRECT,no-resolve')
      ..writeln('  - IP-CIDR,192.168.0.0/16,DIRECT,no-resolve')
      ..writeln('  - IP-CIDR,169.254.0.0/16,DIRECT,no-resolve')
      ..writeln('  - MATCH,漏网之鱼')
      ..writeln('');

    return b.toString();
  }

  Future<_SubscriptionScanResult?> _tryScanSubscription(String url) async {
    try {
      final names = await _fetchSubscriptionNodeNames(url);
      if (names.isEmpty) return null;
      final countryGroups = _CountryGroup.buildFromNodeNames(names);
      final hasLowRate = names.any(_SubscriptionPatterns.lowRate.hasMatch);
      return _SubscriptionScanResult(
        countryGroups: countryGroups,
        hasLowRate: hasLowRate,
      );
    } catch (_) {
      return null;
    }
  }

  Future<List<String>> _fetchSubscriptionNodeNames(String url) async {
    final uri = Uri.tryParse(url);
    if (uri == null || !uri.hasScheme) return const [];

    final client = HttpClient()
      ..connectionTimeout = const Duration(seconds: 6)
      ..findProxy = (_) => 'DIRECT';

    try {
      final req = await client.getUrl(uri).timeout(const Duration(seconds: 6));
      req.headers.set('accept', '*/*');
      final resp = await req.close().timeout(const Duration(seconds: 6));
      final bytes = await consolidateHttpClientResponseBytes(resp);
      final text = utf8.decode(bytes, allowMalformed: true);
      return _extractSubscriptionNodeNames(text);
    } finally {
      client.close(force: true);
    }
  }

  static List<String> _extractSubscriptionNodeNames(String raw) {
    final text = raw.trim();
    if (text.isEmpty) return const [];

    // 1) Clash/Mihomo YAML (subconverter output).
    final fromYaml = _extractProxyNamesFromYaml(text);
    if (fromYaml.isNotEmpty) return fromYaml;

    // 2) Base64 subscription: decode then retry YAML / URI list.
    final decodedBytes = _tryDecodeBase64(text);
    if (decodedBytes != null) {
      final decodedText =
          utf8.decode(decodedBytes, allowMalformed: true).trim();
      final yaml2 = _extractProxyNamesFromYaml(decodedText);
      if (yaml2.isNotEmpty) return yaml2;
      final uri2 = _extractProxyNamesFromUriList(decodedText);
      if (uri2.isNotEmpty) return uri2;
    }

    // 3) URI list as-is.
    return _extractProxyNamesFromUriList(text);
  }

  static List<String> _extractProxyNamesFromYaml(String raw) {
    final lines = raw.split(RegExp(r'\r?\n'));
    int index = -1;
    for (var i = 0; i < lines.length; i++) {
      final t = lines[i].trimLeft();
      if (t == 'proxies:' || t.startsWith('proxies: ')) {
        index = i;
        break;
      }
    }
    if (index < 0) return const [];

    int indentOf(String s) => s.length - s.trimLeft().length;
    final baseIndent = indentOf(lines[index]);

    final names = <String>[];
    for (var i = index + 1; i < lines.length; i++) {
      final line = lines[i];
      if (line.trim().isEmpty) continue;
      final trimmed = line.trimLeft();
      if (trimmed.startsWith('#')) continue;

      final indent = indentOf(line);
      if (indent <= baseIndent && !trimmed.startsWith('-')) {
        break;
      }

      if (!trimmed.startsWith('-')) continue;

      final inline =
          RegExp(r'-\s*\{\s*name\s*:\s*([^,}]+)').firstMatch(trimmed);
      if (inline != null) {
        final name = _cleanYamlString(inline.group(1)!);
        if (name.isNotEmpty) names.add(name);
        continue;
      }

      final multi = RegExp(r'-\s*name\s*:\s*(.+)$').firstMatch(trimmed);
      if (multi != null) {
        final name = _cleanYamlString(multi.group(1)!);
        if (name.isNotEmpty) names.add(name);
      }
    }
    return names;
  }

  static List<String> _extractProxyNamesFromUriList(String raw) {
    final lines = raw.split(RegExp(r'\r?\n'));
    final names = <String>[];
    for (final line in lines) {
      final s = line.trim();
      if (s.isEmpty || s.startsWith('#')) continue;

      // Most formats use URL fragment (#name).
      final fragIdx = s.indexOf('#');
      if (fragIdx >= 0 && fragIdx + 1 < s.length) {
        final frag = s.substring(fragIdx + 1);
        final decoded = Uri.decodeComponent(frag.replaceAll('+', '%20')).trim();
        if (decoded.isNotEmpty) names.add(decoded);
        continue;
      }

      // vmess://base64(json) uses `ps` as display name.
      if (s.startsWith('vmess://')) {
        final body = s.substring('vmess://'.length).trim();
        final decoded = _tryDecodeBase64(body);
        if (decoded == null) continue;
        try {
          final jsonStr = utf8.decode(decoded, allowMalformed: true);
          final obj = jsonDecode(jsonStr);
          if (obj is Map) {
            final ps = obj['ps']?.toString().trim();
            if (ps != null && ps.isNotEmpty) names.add(ps);
          }
        } catch (_) {}
      }
    }
    return names;
  }

  static String _cleanYamlString(String raw) {
    var s = raw.trim();
    s = s.replaceAll(RegExp(r'\s+#.*$'), '').trim();
    if (s.length >= 2) {
      if ((s.startsWith("'") && s.endsWith("'")) ||
          (s.startsWith('"') && s.endsWith('"'))) {
        s = s.substring(1, s.length - 1);
      }
    }
    s = s.replaceAll("''", "'");
    return s.trim();
  }

  static Uint8List? _tryDecodeBase64(String raw) {
    final s = raw.trim().replaceAll(RegExp(r'\s+'), '');
    if (s.isEmpty) return null;

    String pad(String v) {
      final mod = v.length % 4;
      if (mod == 0) return v;
      return v + ('=' * (4 - mod));
    }

    try {
      return Uint8List.fromList(base64.decode(pad(s)));
    } catch (_) {
      try {
        return Uint8List.fromList(base64Url.decode(pad(s)));
      } catch (_) {
        return null;
      }
    }
  }

  static String _migrateDirectGroupLoop(String raw) {
    // Only touch configs that match the previous (broken) default group:
    // proxy-groups:
    //   - name: DIRECT
    //     type: select
    //     proxies:
    //       - DIRECT
    //
    // And route-all rule:
    //   - MATCH,DIRECT
    //
    // Fix by renaming the group and updating the MATCH rule.
    final hasBrokenGroup = RegExp(
      r'^\s*-\s*name\s*:\s*DIRECT\s*$[\s\S]*?^\s*proxies\s*:\s*$[\s\S]*?^\s*-\s*DIRECT\s*$',
      multiLine: true,
    ).hasMatch(raw);
    if (!hasBrokenGroup) return raw;

    // Avoid clobbering user configs that already define a PROXY group.
    final targetName = RegExp(
      r'^\s*-\s*name\s*:\s*PROXY\s*$',
      multiLine: true,
    ).hasMatch(raw)
        ? 'LP-PROXY'
        : 'PROXY';

    String out = raw;
    out = out.replaceAll(
      RegExp(
        r'^(\s*-\s*name\s*:\s*)DIRECT(\s*)$',
        multiLine: true,
      ),
      r'$1' + targetName + r'$2',
    );
    out = out.replaceAll(
      RegExp(
        r'^(\s*-\s*MATCH\s*,\s*)DIRECT(\s*)$',
        multiLine: true,
      ),
      r'$1' + targetName + r'$2',
    );
    return out;
  }

  Future<void> _chmodExecutable(String path) async {
    // Best-effort; some ROMs may still block execve from app data.
    try {
      final ok = await DeviceType.setExecutable(path);
      if (ok) return;
    } catch (_) {}

    final attempts = <String>[
      'platform=setExecutable(false)',
    ];

    Future<bool> tryRun(String cmd, List<String> args) async {
      try {
        final res = await Process.run(cmd, args, runInShell: false);
        if (res.exitCode == 0) return true;
        attempts.add('$cmd exit=${res.exitCode}');
        return false;
      } catch (e) {
        attempts.add('$cmd error=$e');
        return false;
      }
    }

    if (await tryRun('chmod', ['700', path])) return;
    if (await tryRun('/system/bin/chmod', ['700', path])) return;
    if (await tryRun('/system/bin/toybox', ['chmod', '700', path])) return;
    if (await tryRun('/system/bin/toolbox', ['chmod', '700', path])) return;

    // Keep error around for user-facing diagnosis if start() fails later.
    _lastError ??= '无法设置 mihomo 可执行权限：${attempts.join(', ')}';
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

    // ExoPlayer (video_player) uses HttpURLConnection internally; route it through a process-level
    // ProxySelector so only this app is affected (per-app proxy, not system VPN).
    if (!kIsWeb &&
        defaultTargetPlatform == TargetPlatform.android &&
        DeviceType.isTv) {
      unawaited(() async {
        if (shouldEnable) {
          await DeviceType.setHttpProxy(
            host: '127.0.0.1',
            port: mixedPort,
          );
        } else {
          await DeviceType.clearHttpProxy();
        }
      }());
    }
  }
}

class _SubscriptionPatterns {
  static final RegExp countryCode = RegExp(
    r'(?<![A-Z0-9])([A-Z]{2})(?=[0-9]|[^A-Z0-9]|$)',
  );

  static final RegExp lowRate = RegExp(
    r'(^|[^0-9.])0\.[0-9]{1,3} *(x|倍|倍率)?($|[^0-9.])',
    caseSensitive: false,
  );
}

class _SubscriptionScanResult {
  final List<_CountryGroup> countryGroups;
  final bool hasLowRate;

  const _SubscriptionScanResult({
    required this.countryGroups,
    required this.hasLowRate,
  });
}

class _CountryGroup {
  const _CountryGroup({
    required this.code,
    required this.flagCode,
    required this.matchCodes,
  });

  final String code;
  final String flagCode;
  final List<String> matchCodes;

  String get name {
    final flag = _flagEmoji(flagCode);
    if (flag.isEmpty) return code;
    return '$flag $code';
  }

  String get filterRegex {
    final codes = matchCodes.toSet().toList(growable: false)..sort();
    final body = codes.map(RegExp.escape).join('|');
    return r'(?i)(^|[^A-Z0-9])(?:' + body + r')(?=[0-9]|[^A-Z0-9]|$)';
  }

  static List<_CountryGroup> defaultPreset() {
    return const [
      _CountryGroup(code: 'HK', flagCode: 'HK', matchCodes: ['HK']),
      _CountryGroup(code: 'SG', flagCode: 'SG', matchCodes: ['SG']),
      _CountryGroup(code: 'JP', flagCode: 'JP', matchCodes: ['JP']),
      _CountryGroup(code: 'US', flagCode: 'US', matchCodes: ['US']),
      _CountryGroup(code: 'UK', flagCode: 'GB', matchCodes: ['UK', 'GB']),
      _CountryGroup(code: 'GE', flagCode: 'DE', matchCodes: ['GE', 'DE']),
    ];
  }

  static List<_CountryGroup> buildFromNodeNames(List<String> names) {
    final rawCodes = <String>{};
    for (final name in names) {
      final upper = name.toUpperCase();
      for (final m in _SubscriptionPatterns.countryCode.allMatches(upper)) {
        final code = m.group(1);
        if (code != null && code.isNotEmpty) rawCodes.add(code);
      }
    }

    final groups = <_CountryGroup>[];

    bool take(String code) => rawCodes.remove(code);

    // Germany: users sometimes tag it as "GE" (non-ISO) or "DE" (ISO).
    final hasGE = take('GE');
    final hasDE = take('DE');
    if (hasGE || hasDE) {
      groups.add(
        _CountryGroup(
          code: hasGE ? 'GE' : 'DE',
          flagCode: 'DE',
          matchCodes: [
            if (hasGE) 'GE',
            if (hasDE) 'DE',
          ],
        ),
      );
    }

    // United Kingdom: users may tag it as "UK" (alias) or "GB" (ISO).
    final hasUK = take('UK');
    final hasGB = take('GB');
    if (hasUK || hasGB) {
      groups.add(
        _CountryGroup(
          code: hasUK ? 'UK' : 'GB',
          flagCode: 'GB',
          matchCodes: [
            if (hasUK) 'UK',
            if (hasGB) 'GB',
          ],
        ),
      );
    }

    for (final code in rawCodes) {
      groups.add(_CountryGroup(code: code, flagCode: code, matchCodes: [code]));
    }

    const preferred = <String>[
      'HK',
      'SG',
      'JP',
      'TW',
      'KR',
      'US',
      'UK',
      'GB',
      'GE',
      'DE',
    ];
    int weight(String c) {
      final idx = preferred.indexOf(c);
      return idx < 0 ? 999 : idx;
    }

    groups.sort((a, b) {
      final wa = weight(a.code);
      final wb = weight(b.code);
      if (wa != wb) return wa.compareTo(wb);
      return a.code.compareTo(b.code);
    });
    return groups;
  }

  static String _flagEmoji(String code) {
    final v = code.trim().toUpperCase();
    if (!RegExp(r'^[A-Z]{2}$').hasMatch(v)) return '';
    final a = 0x1F1E6 + (v.codeUnitAt(0) - 0x41);
    final b = 0x1F1E6 + (v.codeUnitAt(1) - 0x41);
    return String.fromCharCode(a) + String.fromCharCode(b);
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
  - name: PROXY
    type: select
    proxies:
      - DIRECT

rules:
  - MATCH,PROXY
''';
