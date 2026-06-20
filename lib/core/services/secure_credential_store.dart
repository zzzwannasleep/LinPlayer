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
  static const _serversPrefsKey = 'linplayer_servers';
  static const _fallbackPrefsKey = 'linplayer_server_secrets_fb';
  static const _fbPassphrase = 'LinPlayer::server::cred::fallback::v1';

  final _storage = const FlutterSecureStorage(
    aOptions: AndroidOptions(encryptedSharedPreferences: true),
  );
  final Map<String, ServerSecret> _cache = {};
  bool _useFallback = false;
  bool _initialized = false;
  List<int>? _fbKeyCache;

  /// 同步读取（启动后缓存已就绪）。
  ServerSecret? read(String id) => _cache[id];

  Future<void> initialize() async {
    if (_initialized) return;
    _initialized = true;
    // 1) 载入已存密文到同步缓存。
    try {
      final all = await _storage.readAll();
      for (final e in all.entries) {
        if (e.key.startsWith(_securePrefix)) {
          _cache[e.key.substring(_securePrefix.length)] = _decode(e.value);
        }
      }
    } catch (e) {
      _useFallback = true;
      _log.w('SecureCred', 'OS 安全存储不可用，回退混淆存储: $e');
      _loadFallbackCache();
    }
    // 2) 迁移旧版本明文落盘的 password/authToken。
    await _migrateLegacyPlaintext();
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
}

/// 生成随机盐/字节（供需要随机源的地方复用）。
List<int> secureRandomBytes(int n) {
  final r = Random.secure();
  return List<int>.generate(n, (_) => r.nextInt(256));
}
