import 'dart:convert';

import 'package:cryptography/cryptography.dart';
import 'package:uuid/uuid.dart';

import '../providers/server_providers.dart';

/// 通用配置（CommonConfig）—— **免密码、跨客户端**的服务器配置互导格式。
///
/// 兼容 Richasy/Rodel 的 `common-config`：每个服务器配置(snake_case JSON)各自用
/// AES-256-CBC/PKCS7 加密成 base64,装进容器 `{from, version, export_time, configs[], _key}`。
/// 容器里带 `_key`(解密密钥)即可让**任意实现本格式的客户端无需密码直接解开**。
///
/// 安全性说明:这是「混淆级」加密——密钥随文件分发(或内置在客户端),
/// 能挡住随手读取明文凭据,但**不防被提取密钥后解密**。需要真正保密请用
/// `BackupCrypto`(口令模式)或 `sealTo`(加密给设备公钥)。
class CommonConfig {
  CommonConfig._();

  static const String clientId = 'LinPlayer';
  static const String formatVersion = '1.0';
  static const _uuid = Uuid();

  /// LinPlayer 内置默认密钥(32B)。导出时同时写入 `_key`,所以即便对方没有这把
  /// 内置密钥也能解;它主要作为「文件未带 `_key`」时的回退。
  static const List<int> _builtinKey = [
    0x4c, 0x69, 0x6e, 0x50, 0x6c, 0x61, 0x79, 0x65, // "LinPlayer"
    0x72, 0x2d, 0x63, 0x6f, 0x6d, 0x6d, 0x6f, 0x6e, // "r-common"
    0x2d, 0x63, 0x6f, 0x6e, 0x66, 0x69, 0x67, 0x2d, // "-config-"
    0x6b, 0x65, 0x79, 0x2d, 0x76, 0x31, 0x21, 0x00, // "key-v1!\0"
  ];

  static final AesCbc _aes =
      AesCbc.with256bits(macAlgorithm: MacAlgorithm.empty);

  /// 是否为通用配置容器(含 configs 数组)。
  static bool isCommonConfig(Map<String, dynamic> json) =>
      json['configs'] is List;

  // ---- 单个配置的 AES-256-CBC/PKCS7(IV = 密钥前 16 字节)--------------------

  static Future<String> _encryptConfig(String plaintext, List<int> key) async {
    final box = await _aes.encrypt(
      utf8.encode(plaintext),
      secretKey: SecretKey(key),
      nonce: key.sublist(0, 16), // Richasy 约定:IV 取密钥前 16 字节
    );
    return base64Encode(box.cipherText);
  }

  static Future<String> _decryptConfig(String b64, List<int> key) async {
    final clear = await _aes.decrypt(
      SecretBox(base64Decode(b64), nonce: key.sublist(0, 16), mac: Mac.empty),
      secretKey: SecretKey(key),
    );
    return utf8.decode(clear);
  }

  // ---- ServerConfig <-> CommonServiceConfig(snake_case)---------------------

  static Map<String, dynamic> _serverToCommon(ServerConfig s) => {
        'type': 'emby',
        'id': s.id,
        'name': s.name,
        'url': s.baseUrl,
        'username': s.username,
        'user_id': s.userId,
        'password': s.password,
        'access_token': s.authToken,
        'icon': s.iconUrl,
        'lines': s.lines
            .map((l) => {
                  'id': l.id,
                  'name': l.name,
                  'url': l.url,
                  'remark': l.remark,
                })
            .toList(),
        'options': {
          'active_line_index': s.activeLineIndex,
          'allow_insecure_tls': s.allowInsecureTls,
          if (s.remark != null) 'remark': s.remark,
        },
      };

  static ServerConfig _commonToServer(Map<String, dynamic> j) {
    final options = (j['options'] as Map?)?.cast<String, dynamic>() ??
        const <String, dynamic>{};
    final lines = (j['lines'] as List<dynamic>?)
            ?.whereType<Map>()
            .map((raw) {
              final l = raw.cast<String, dynamic>();
              return ServerLine(
                id: (l['id'] as String?) ?? _uuid.v4(),
                name: (l['name'] as String?) ?? '线路',
                url: (l['url'] as String?) ?? '',
                remark: l['remark'] as String?,
              );
            })
            .where((l) => l.url.isNotEmpty)
            .toList() ??
        const <ServerLine>[];
    return ServerConfig(
      id: (j['id'] as String?) ?? _uuid.v4(),
      name: (j['name'] as String?) ?? '服务器',
      baseUrl: (j['url'] as String?) ?? '',
      iconUrl: j['icon'] as String?,
      remark: options['remark'] as String?,
      lines: lines,
      activeLineIndex: (options['active_line_index'] as num?)?.toInt() ?? 0,
      username: j['username'] as String?,
      authToken: j['access_token'] as String?,
      userId: j['user_id'] as String?,
      password: j['password'] as String?,
      allowInsecureTls: options['allow_insecure_tls'] as bool? ?? false,
    );
  }

  // ---- 容器构建 / 解析 -------------------------------------------------------

  /// 把服务器列表打包成通用配置容器(可 `jsonEncode`)。
  /// [includeKey] 为 true 时写入 `_key`,任何客户端都能免密解;
  /// false 时只有持内置密钥的客户端能解(更不易被随手读取,但仍是混淆级)。
  /// [extra] 写入 `additional_data`(明文,放 LinPlayer 偏好等无密内容)。
  static Future<Map<String, dynamic>> build(
    List<ServerConfig> servers, {
    bool includeKey = true,
    int? exportTimeUnix,
    Map<String, dynamic>? extra,
  }) async {
    const key = _builtinKey;
    final configs = <String>[];
    for (final s in servers) {
      configs.add(await _encryptConfig(jsonEncode(_serverToCommon(s)), key));
    }
    return {
      'from': clientId,
      'version': formatVersion,
      'export_time': exportTimeUnix ?? 0,
      'configs': configs,
      if (extra != null) 'additional_data': extra,
      if (includeKey) '_key': base64Encode(key),
    };
  }

  /// 解析通用配置容器为服务器列表。优先用文件里的 `_key`,否则回退内置密钥。
  /// 解不开的单条会被跳过(不同客户端可能用了未知的私有密钥)。
  static Future<List<ServerConfig>> parse(Map<String, dynamic> json) async {
    final keyB64 = json['_key'];
    final key = (keyB64 is String && keyB64.isNotEmpty)
        ? base64Decode(keyB64)
        : _builtinKey;
    final configs = (json['configs'] as List<dynamic>? ?? const [])
        .whereType<String>()
        .toList();
    final servers = <ServerConfig>[];
    for (final c in configs) {
      try {
        final map = jsonDecode(await _decryptConfig(c, key)) as Map<String, dynamic>;
        final s = _commonToServer(map);
        if (s.baseUrl.isNotEmpty) servers.add(s);
      } catch (_) {
        // 跳过解不开/格式不符的单条。
      }
    }
    return servers;
  }

  /// 读取容器里的 `additional_data`(LinPlayer 偏好等),无则返回 null。
  static Map<String, dynamic>? additionalData(Map<String, dynamic> json) =>
      (json['additional_data'] as Map?)?.cast<String, dynamic>();
}
