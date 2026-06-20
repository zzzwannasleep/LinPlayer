import 'dart:convert';
import 'dart:math';

import 'package:crypto/crypto.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import '../providers/app_preferences.dart';
import 'app_logger.dart';

/// 一个服务器的敏感凭据（密码 + 访问令牌）。
class ServerSecret {
  final String? password;
  final String? authToken;
  const ServerSecret({this.password, this.authToken});

  bool get isEmpty =>
      (password == null || password!.isEmpty) &&
      (authToken == null || authToken!.isEmpty);
}

/// 服务器凭据的安全存储（H11）。
///
/// 密码与 authToken 改用 OS 钥匙串（flutter_secure_storage）加密落盘，不再以
/// 明文写入 SharedPreferences。为保持服务器列表的**同步**加载，启动时一次性
/// `readAll()` 进同步缓存（[read] 即从缓存取）。
///
/// 回退：若 OS 安全存储不可用（如部分 Linux 发行版缺 libsecret），降级为
/// SharedPreferences + XOR 混淆（弱保护，但不致崩溃/丢登录）。
class SecureCredentialStore {
  SecureCredentialStore._();
  static final SecureCredentialStore instance = SecureCredentialStore._();
  static final AppLogger _log = AppLogger();

  static const _securePrefix = 'srv_secret_';
  static const _kvPrefix = 'kv_secret_';
  static const _serversPrefsKey = 'linplayer_servers';
  static const _fallbackPrefsKey = 'linplayer_server_secrets_fb';
  static const _kvFallbackPrefsKey = 'linplayer_kv_secrets_fb';
  static const _fbPassphrase = 'LinPlayer::server::cred::fallback::v1';

  /// 启动时把这些旧明文 prefs 字符串键迁移进加密 KV（如翻译引擎 API key，M5）。
  static const _legacyKvKeys = <String>[
    'linplayer_trans_openai',
    'linplayer_trans_anthropic',
    'linplayer_trans_baidu_general',
    'linplayer_trans_baidu_llm',
    'linplayer_trans_tencent',
  ];

  final _storage = const FlutterSecureStorage(
    aOptions: AndroidOptions(encryptedSharedPreferences: true),
  );
  final Map<String, ServerSecret> _cache = {};
  final Map<String, String> _kv = {};
  bool _useFallback = false;
  bool _initialized = false;
  List<int>? _fbKeyCache;

  /// 同步读取服务器凭据（启动后缓存已就绪）。
  ServerSecret? read(String id) => _cache[id];

  /// 同步读取通用加密 KV（启动后缓存已就绪）。
  String? readKv(String key) => _kv[key];

  Future<void> writeKv(String key, String? value) async {
    if (value == null || value.isEmpty) {
      await removeKv(key);
      return;
    }
    _kv[key] = value;
    if (_useFallback) {
      await _persistKvFallback();
      return;
    }
    try {
      await _storage.write(key: '$_kvPrefix$key', value: value);
    } catch (e) {
      _useFallback = true;
      _log.w('SecureCred', '写安全存储(KV)失败，回退混淆: $e');
      await _persistKvFallback();
    }
  }

  Future<void> removeKv(String key) async {
    _kv.remove(key);
    if (_useFallback) {
      await _persistKvFallback();
      return;
    }
    try {
      await _storage.delete(key: '$_kvPrefix$key');
    } catch (_) {}
  }

  Future<void> initialize() async {
    if (_initialized) return;
    _initialized = true;
    // 1) 载入已存密文到同步缓存。
    try {
      final all = await _storage.readAll();
      for (final e in all.entries) {
        if (e.key.startsWith(_securePrefix)) {
          _cache[e.key.substring(_securePrefix.length)] = _decode(e.value);
        } else if (e.key.startsWith(_kvPrefix)) {
          _kv[e.key.substring(_kvPrefix.length)] = e.value;
        }
      }
    } catch (e) {
      _useFallback = true;
      _log.w('SecureCred', 'OS 安全存储不可用，回退混淆存储: $e');
      _loadFallbackCache();
      _loadKvFallbackCache();
    }
    // 2) 迁移旧版本明文落盘的 password/authToken 与通用 KV（翻译 API key 等）。
    await _migrateLegacyPlaintext();
    await _migrateLegacyKv();
  }

  /// 把旧明文 prefs 字符串键搬进加密 KV，并从 prefs 抹除明文。
  Future<void> _migrateLegacyKv() async {
    final prefs = AppPreferencesStore.instance;
    for (final key in _legacyKvKeys) {
      final raw = prefs.getString(key);
      if (raw == null || raw.isEmpty) continue;
      if (!_kv.containsKey(key)) {
        await writeKv(key, raw);
      }
      await prefs.remove(key);
    }
  }

  Future<void> write(String id,
      {required String? password, required String? authToken}) async {
    final secret = ServerSecret(password: password, authToken: authToken);
    if (secret.isEmpty) {
      await remove(id);
      return;
    }
    _cache[id] = secret;
    if (_useFallback) {
      await _persistFallback();
      return;
    }
    try {
      await _storage.write(key: '$_securePrefix$id', value: _encode(secret));
    } catch (e) {
      _useFallback = true;
      _log.w('SecureCred', '写安全存储失败，回退混淆: $e');
      await _persistFallback();
    }
  }

  Future<void> remove(String id) async {
    _cache.remove(id);
    if (_useFallback) {
      await _persistFallback();
      return;
    }
    try {
      await _storage.delete(key: '$_securePrefix$id');
    } catch (_) {}
  }

  // ---- 编解码 ----
  String _encode(ServerSecret s) =>
      jsonEncode({'p': s.password, 't': s.authToken});

  ServerSecret _decode(String raw) {
    try {
      final m = jsonDecode(raw) as Map<String, dynamic>;
      return ServerSecret(
          password: m['p'] as String?, authToken: m['t'] as String?);
    } catch (_) {
      return const ServerSecret();
    }
  }

  // ---- 迁移 ----
  Future<void> _migrateLegacyPlaintext() async {
    final prefs = AppPreferencesStore.instance;
    final raw = prefs.getString(_serversPrefsKey);
    if (raw == null || raw.isEmpty) return;
    try {
      final list = jsonDecode(raw) as List<dynamic>;
      var changed = false;
      for (final entry in list) {
        if (entry is! Map) continue;
        final id = entry['id']?.toString();
        if (id == null) continue;
        final pw = entry['password'] as String?;
        final tk = entry['authToken'] as String?;
        final hasPlain =
            (pw != null && pw.isNotEmpty) || (tk != null && tk.isNotEmpty);
        if (!hasPlain) continue;
        if (!_cache.containsKey(id)) {
          await write(id, password: pw, authToken: tk);
        }
        entry.remove('password');
        entry.remove('authToken');
        changed = true;
      }
      if (changed) {
        await prefs.setString(_serversPrefsKey, jsonEncode(list));
        _log.i('SecureCred', '已迁移服务器明文凭据到安全存储');
      }
    } catch (e) {
      _log.w('SecureCred', '迁移明文凭据失败: $e');
    }
  }

  // ---- 回退：SharedPreferences + XOR 混淆 ----
  List<int> get _fbKey =>
      _fbKeyCache ??= sha256.convert(utf8.encode(_fbPassphrase)).bytes;

  String _xor(String plain) {
    final bytes = utf8.encode(plain);
    final key = _fbKey;
    final out = List<int>.filled(bytes.length, 0);
    for (var i = 0; i < bytes.length; i++) {
      out[i] = bytes[i] ^ key[i % key.length];
    }
    return base64Encode(out);
  }

  String? _unxor(String encoded) {
    try {
      final bytes = base64Decode(encoded);
      final key = _fbKey;
      final out = List<int>.filled(bytes.length, 0);
      for (var i = 0; i < bytes.length; i++) {
        out[i] = bytes[i] ^ key[i % key.length];
      }
      return utf8.decode(out);
    } catch (_) {
      return null;
    }
  }

  void _loadFallbackCache() {
    try {
      final raw = AppPreferencesStore.instance.getString(_fallbackPrefsKey);
      if (raw == null || raw.isEmpty) return;
      final plain = _unxor(raw);
      if (plain == null) return;
      final m = jsonDecode(plain) as Map<String, dynamic>;
      for (final e in m.entries) {
        _cache[e.key] = _decode(jsonEncode(e.value));
      }
    } catch (_) {}
  }

  Future<void> _persistFallback() async {
    try {
      final m = _cache
          .map((k, v) => MapEntry(k, {'p': v.password, 't': v.authToken}));
      await AppPreferencesStore.instance
          .setString(_fallbackPrefsKey, _xor(jsonEncode(m)));
    } catch (e) {
      _log.w('SecureCred', '回退存储写入失败: $e');
    }
  }

  void _loadKvFallbackCache() {
    try {
      final raw = AppPreferencesStore.instance.getString(_kvFallbackPrefsKey);
      if (raw == null || raw.isEmpty) return;
      final plain = _unxor(raw);
      if (plain == null) return;
      final m = jsonDecode(plain) as Map<String, dynamic>;
      for (final e in m.entries) {
        _kv[e.key] = '${e.value}';
      }
    } catch (_) {}
  }

  Future<void> _persistKvFallback() async {
    try {
      await AppPreferencesStore.instance
          .setString(_kvFallbackPrefsKey, _xor(jsonEncode(_kv)));
    } catch (e) {
      _log.w('SecureCred', '回退存储(KV)写入失败: $e');
    }
  }
}

/// 生成随机盐/字节（供需要随机源的地方复用）。
List<int> secureRandomBytes(int n) {
  final r = Random.secure();
  return List<int>.generate(n, (_) => r.nextInt(256));
}
