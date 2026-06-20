import 'dart:convert';

import 'package:cryptography/cryptography.dart';

import 'secure_credential_store.dart' show secureRandomBytes;

/// 备份文件的口令加密（H12）。
///
/// 整包明文 JSON 用「PBKDF2-HMAC-SHA256 派生密钥 + AES-256-GCM」加密，输出一个
/// 自描述的 JSON 包装（含算法/迭代次数/盐/nonce/密文/认证标签）。导入端据此
/// 还原。格式文档见 `docs/BACKUP_FORMAT.md`。
class BackupCrypto {
  BackupCrypto._();

  static const int _iterations = 120000;
  static final AesGcm _aes = AesGcm.with256bits();

  static Pbkdf2 _pbkdf2(int iterations) => Pbkdf2(
        macAlgorithm: Hmac.sha256(),
        iterations: iterations,
        bits: 256,
      );

  /// 是否为本格式的加密备份。
  static bool isEncrypted(Map<String, dynamic> json) =>
      json['linplayer_encrypted_backup'] != null;

  /// 用口令加密明文 JSON 字符串，返回可 `jsonEncode` 的包装 Map。
  static Future<Map<String, dynamic>> encrypt(
      String plaintext, String passphrase) async {
    final salt = secureRandomBytes(16);
    final key = await _pbkdf2(_iterations)
        .deriveKeyFromPassword(password: passphrase, nonce: salt);
    final nonce = _aes.newNonce();
    final box = await _aes.encrypt(
      utf8.encode(plaintext),
      secretKey: key,
      nonce: nonce,
    );
    return {
      'linplayer_encrypted_backup': 1,
      'kdf': 'pbkdf2-hmac-sha256',
      'cipher_alg': 'aes-256-gcm',
      'iterations': _iterations,
      'salt': base64Encode(salt),
      'nonce': base64Encode(nonce),
      'cipher': base64Encode(box.cipherText),
      'mac': base64Encode(box.mac.bytes),
    };
  }

  /// 用口令解密包装 Map，返回明文 JSON 字符串。口令错误或数据被篡改会抛异常
  /// （AES-GCM 认证失败）。
  static Future<String> decrypt(
      Map<String, dynamic> wrapper, String passphrase) async {
    final iterations = (wrapper['iterations'] as num?)?.toInt() ?? _iterations;
    final salt = base64Decode('${wrapper['salt']}');
    final nonce = base64Decode('${wrapper['nonce']}');
    final cipher = base64Decode('${wrapper['cipher']}');
    final mac = base64Decode('${wrapper['mac']}');
    final key = await _pbkdf2(iterations)
        .deriveKeyFromPassword(password: passphrase, nonce: salt);
    final box = SecretBox(cipher, nonce: nonce, mac: Mac(mac));
    final clear = await _aes.decrypt(box, secretKey: key);
    return utf8.decode(clear);
  }
}
