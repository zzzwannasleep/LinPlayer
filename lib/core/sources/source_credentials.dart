import 'dart:convert';

import '../services/secure_credential_store.dart';

/// 文件浏览型源的「附加凭据」安全存储。
///
/// ServerConfig 自带 username/password/authToken 三个字段，能覆盖账密型源
/// （OpenList/Ani-rss）的主令牌。但夸克还需要 cookie / refresh_token /
/// access_token / client_id 等多项，统一以一个 JSON Map 存进
/// [SecureCredentialStore] 的加密 KV（键 `src_cred_<serverId>`）。
class SourceCredentialStore {
  SourceCredentialStore._();
  static final SourceCredentialStore instance = SourceCredentialStore._();

  static String _key(String serverId) => 'src_cred_$serverId';

  /// 同步读取（启动后 SecureCredentialStore 缓存已就绪）。
  Map<String, String> read(String serverId) {
    final raw = SecureCredentialStore.instance.readKv(_key(serverId));
    if (raw == null || raw.isEmpty) return <String, String>{};
    try {
      final m = jsonDecode(raw) as Map<String, dynamic>;
      return m.map((k, v) => MapEntry(k, v?.toString() ?? ''));
    } catch (_) {
      return <String, String>{};
    }
  }

  Future<void> write(String serverId, Map<String, String> creds) async {
    if (creds.isEmpty) {
      await remove(serverId);
      return;
    }
    await SecureCredentialStore.instance.writeKv(_key(serverId), jsonEncode(creds));
  }

  /// 合并补丁（局部更新某几项，如刷新后的 access_token）。
  Future<void> merge(String serverId, Map<String, String> patch) async {
    final cur = read(serverId);
    cur.addAll(patch);
    await write(serverId, cur);
  }

  Future<void> remove(String serverId) async {
    await SecureCredentialStore.instance.removeKv(_key(serverId));
  }
}
