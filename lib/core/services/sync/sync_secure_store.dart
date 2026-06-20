import 'dart:convert';
import 'package:crypto/crypto.dart';

import '../../providers/app_preferences.dart';
import '../secure_credential_store.dart';
import 'sync_models.dart';

/// 同步账号令牌的持久化（L5：改用 OS 安全存储真加密）。
///
/// Trakt/Bangumi 的 access/refresh token 改存 [SecureCredentialStore] 的加密 KV
/// （OS 钥匙串）。旧版本曾用「静态密钥 XOR 混淆 + base64」写在 SharedPreferences
/// （可逆，仅防 grep），这里在**读取时惰性迁移**：解混淆后写入加密 KV 并抹除旧值。
class SyncSecureStore {
  SyncSecureStore._();

  // 仅用于迁移旧 XOR 混淆值的口令/密钥（新写入不再使用 XOR）。
  static const String _legacyPassphrase = 'LinPlayer::sync::token::v1';
  static const String _keyPrefix = 'sync_account_';
  static List<int>? _legacyKeyCache;

  static List<int> get _legacyKey =>
      _legacyKeyCache ??= sha256.convert(utf8.encode(_legacyPassphrase)).bytes;

  static String? _deobfuscate(String encoded) {
    try {
      final bytes = base64Decode(encoded);
      final key = _legacyKey;
      final out = List<int>.filled(bytes.length, 0);
      for (var i = 0; i < bytes.length; i++) {
        out[i] = bytes[i] ^ key[i % key.length];
      }
      return utf8.decode(out);
    } catch (_) {
      return null;
    }
  }

  static String _prefKey(SyncService service) => '$_keyPrefix${service.id}';

  static SyncAccount? read(SyncService service) {
    final key = _prefKey(service);
    // 新：加密 KV（同步缓存）。
    final kv = SecureCredentialStore.instance.readKv(key);
    if (kv != null) return SyncAccount.decode(kv);
    // 旧：XOR 混淆值 → 惰性迁移到加密 KV。
    final legacy = AppPreferencesStore.instance.getString(key);
    if (legacy == null || legacy.isEmpty) return null;
    final plain = _deobfuscate(legacy);
    if (plain == null) return null;
    // 异步迁移，不阻塞本次读取。
    SecureCredentialStore.instance.writeKv(key, plain);
    AppPreferencesStore.instance.remove(key);
    return SyncAccount.decode(plain);
  }

  static Future<void> write(SyncAccount account) async {
    await SecureCredentialStore.instance
        .writeKv(_prefKey(account.service), account.encode());
  }

  static Future<void> clear(SyncService service) async {
    final key = _prefKey(service);
    await SecureCredentialStore.instance.removeKv(key);
    // 清理可能残留的旧混淆值。
    await AppPreferencesStore.instance.remove(key);
  }
}
